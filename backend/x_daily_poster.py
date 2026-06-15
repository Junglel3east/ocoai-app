"""
Daily analysis → X (Twitter) poster — On-Chain Oracle AI.

Posts today's persisted daily analyses as a reply thread on @OnChainOracleA.
Uses Twitter API v2 (POST /2/tweets) with OAuth 1.0a User Context.

Enable with X_DAILY_POST_ENABLED=true and set OAuth credentials on Railway.
"""

from __future__ import annotations

import json
import logging
import os
import re
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Optional

import requests
from requests_oauthlib import OAuth1

logger = logging.getLogger("ocoai.x_daily_poster")

_TWEET_MAX = 280
_X_API_TWEETS_URL = "https://api.twitter.com/2/tweets"

_BIAS_RE = re.compile(
    r"\*\*Overall Bias\*\*\s*:?\s*([^\n(]+?)(?:\s*\(Confidence:\s*(\d+)\s*%?\)|\s*$)",
    re.IGNORECASE,
)
_BIAS_FALLBACK_RE = re.compile(
    r"Overall Bias\s*:?\s*([^\n(]+?)(?:\s*\(Confidence:\s*(\d+)\s*%?\)|\s*$)",
    re.IGNORECASE,
)
_CONVICTION_RE = re.compile(
    r"(?:Confidence|Conviction)\s*:?\s*(\d{1,3})\s*%",
    re.IGNORECASE,
)
_SUMMARY_STOP = r"(?:\n\*\*|\n\n|\n(?:Entry|TRADE LEVELS)|\Z)"
_SUMMARY_RE = re.compile(
    rf"\*\*Confluence Summary\*\*\s*:?\s*(.+?){_SUMMARY_STOP}",
    re.IGNORECASE | re.DOTALL,
)
_SUMMARY_FALLBACK_RE = re.compile(
    rf"Confluence Summary\s*:?\s*(.+?){_SUMMARY_STOP}",
    re.IGNORECASE | re.DOTALL,
)

_COIN_HASHTAGS: dict[str, str] = {
    "BTC": "#BTC #Bitcoin",
    "ETH": "#ETH #Ethereum",
    "SOL": "#SOL #Solana",
    "XRP": "#XRP #Ripple",
    "BNB": "#BNB",
}


def _env_bool(name: str, default: bool = False) -> bool:
    raw = (os.getenv(name) or "").strip().lower()
    if not raw:
        return default
    return raw in {"1", "true", "yes", "on"}


def _parse_coin_list(raw: str, default: tuple[str, ...]) -> tuple[str, ...]:
    if not raw.strip():
        return default
    coins = tuple(c.strip().upper() for c in raw.split(",") if c.strip())
    return coins or default


class XDailyPosterConfig:
    """Runtime configuration from environment variables."""

    def __init__(self) -> None:
        self.enabled = _env_bool("X_DAILY_POST_ENABLED", False)
        self.api_key = (os.getenv("X_API_KEY") or os.getenv("TWITTER_API_KEY") or "").strip()
        self.api_secret = (
            os.getenv("X_API_SECRET") or os.getenv("TWITTER_API_SECRET") or ""
        ).strip()
        self.access_token = (
            os.getenv("X_ACCESS_TOKEN") or os.getenv("TWITTER_ACCESS_TOKEN") or ""
        ).strip()
        self.access_token_secret = (
            os.getenv("X_ACCESS_TOKEN_SECRET") or os.getenv("TWITTER_ACCESS_TOKEN_SECRET") or ""
        ).strip()
        self.bearer_token = (os.getenv("X_BEARER_TOKEN") or os.getenv("TWITTER_BEARER_TOKEN") or "").strip()
        self.handle = (os.getenv("X_ACCOUNT_HANDLE") or "@OnChainOracleA").strip()
        self.post_coins: tuple[str, ...] = _parse_coin_list(
            os.getenv("X_DAILY_POST_COINS", "BTC,ETH,SOL,XRP"),
            ("BTC", "ETH", "SOL", "XRP"),
        )
        data_dir = Path(os.getenv("CITADEL_DATA_DIR", str(Path(__file__).resolve().parent / "data")))
        self.state_file = data_dir / "x_daily_posts.json"

    def oauth_ready(self) -> bool:
        return bool(self.api_key and self.api_secret and self.access_token and self.access_token_secret)

    def missing_fields(self) -> list[str]:
        missing: list[str] = []
        if not self.api_key:
            missing.append("X_API_KEY")
        if not self.api_secret:
            missing.append("X_API_SECRET")
        if not self.access_token:
            missing.append("X_ACCESS_TOKEN")
        if not self.access_token_secret:
            missing.append("X_ACCESS_TOKEN_SECRET")
        return missing


def normalize_bias_label(raw: str) -> str:
    """Map report bias text to Bullish / Bearish / Neutral."""
    text = raw.strip().lower()
    if "bull" in text or "long" in text:
        return "Bullish"
    if "bear" in text or "short" in text:
        return "Bearish"
    return "Neutral"


def parse_report_metadata(report: str) -> dict[str, Any]:
    """Extract bias, conviction %, and confluence summary from daily report text."""
    text = (report or "").strip()
    bias_raw = ""
    conviction: Optional[int] = None

    for pattern in (_BIAS_RE, _BIAS_FALLBACK_RE):
        match = pattern.search(text)
        if match:
            bias_raw = (match.group(1) or "").strip()
            if match.lastindex and match.lastindex >= 2 and match.group(2):
                conviction = int(match.group(2))
            break

    if conviction is None:
        conv_match = _CONVICTION_RE.search(text)
        if conv_match:
            conviction = min(100, max(0, int(conv_match.group(1))))

    summary = ""
    for pattern in (_SUMMARY_RE, _SUMMARY_FALLBACK_RE):
        match = pattern.search(text)
        if match:
            summary = re.sub(r"\s+", " ", (match.group(1) or "").strip())
            break

    return {
        "bias_raw": bias_raw,
        "bias": normalize_bias_label(bias_raw) if bias_raw else "Neutral",
        "conviction": conviction,
        "summary": summary,
    }


def _format_price(value: Optional[float]) -> str:
    if value is None:
        return "—"
    if value >= 1000:
        return f"${value:,.0f}"
    if value >= 1:
        return f"${value:,.2f}"
    if value >= 0.01:
        return f"${value:,.4f}"
    return f"${value:,.6f}"


def _truncate(text: str, limit: int) -> str:
    text = text.strip()
    if len(text) <= limit:
        return text
    return text[: max(0, limit - 1)].rstrip() + "…"


def format_coin_tweet(
    entry: dict[str, Any],
    *,
    parse_trade_levels: Callable[[str], dict[str, Optional[float]]],
    format_usd: Callable[[float], str],
) -> str:
    """Build a single coin tweet (≤280 chars)."""
    coin = str(entry.get("coin") or "").upper()
    report = str(entry.get("report") or "")
    meta = parse_report_metadata(report)
    levels = parse_trade_levels(report)

    bias = meta["bias"]
    conviction = meta["conviction"]
    conv_line = f" ({conviction}% conviction)" if conviction is not None else ""

    lines = [
        f"${coin} Daily · {bias}{conv_line}",
        "",
        f"Entry: {format_usd(levels['entry']) if levels.get('entry') is not None else '—'}",
        f"TP1 (40%): {format_usd(levels['tp1']) if levels.get('tp1') is not None else '—'}",
        f"TP2 (60%): {format_usd(levels['tp2']) if levels.get('tp2') is not None else '—'}",
        f"SL: {format_usd(levels['sl']) if levels.get('sl') is not None else '—'}",
    ]

    summary = meta.get("summary") or ""
    if summary:
        lines.extend(["", _truncate(summary, 120)])

    tags = f"#OnChainOracle #Crypto {_COIN_HASHTAGS.get(coin, f'#{coin}')}"
    lines.extend(["", tags.strip()])

    tweet = "\n".join(lines)
    return _truncate(tweet, _TWEET_MAX)


def format_thread_header(day: str, coins: list[str], handle: str) -> str:
    coin_str = " · ".join(f"${c}" for c in coins)
    text = (
        f"🔮 On-Chain Oracle AI — Daily 1D Analysis\n"
        f"{day} · {coin_str}\n"
        f"Thread 👇 · {handle}\n"
        f"#OnChainOracle #Crypto #Trading"
    )
    return _truncate(text, _TWEET_MAX)


def _load_state(path: Path) -> dict[str, Any]:
    if not path.is_file():
        return {}
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
        return raw if isinstance(raw, dict) else {}
    except Exception as exc:
        logger.error("x_daily_state_read_failed path=%s err=%s", path, exc)
        return {}


def _save_state(path: Path, state: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(state, indent=2), encoding="utf-8")
    tmp.replace(path)


def already_posted_today(config: XDailyPosterConfig, day: str) -> bool:
    state = _load_state(config.state_file)
    record = state.get(day)
    return isinstance(record, dict) and bool(record.get("posted_at"))


class XDailyPoster:
    """Twitter API v2 client for daily analysis threads."""

    def __init__(self, config: Optional[XDailyPosterConfig] = None) -> None:
        self.config = config or XDailyPosterConfig()

    def _oauth(self) -> OAuth1:
        return OAuth1(
            self.config.api_key,
            client_secret=self.config.api_secret,
            resource_owner_key=self.config.access_token,
            resource_owner_secret=self.config.access_token_secret,
        )

    def post_tweet(self, text: str, *, reply_to_tweet_id: Optional[str] = None) -> dict[str, Any]:
        payload: dict[str, Any] = {"text": text[:_TWEET_MAX]}
        if reply_to_tweet_id:
            payload["reply"] = {"in_reply_to_tweet_id": reply_to_tweet_id}

        response = requests.post(
            _X_API_TWEETS_URL,
            json=payload,
            auth=self._oauth(),
            timeout=30,
        )
        if response.status_code >= 400:
            detail = response.text[:500]
            raise RuntimeError(f"X API error {response.status_code}: {detail}")

        body = response.json()
        data = body.get("data") if isinstance(body, dict) else None
        if not isinstance(data, dict) or not data.get("id"):
            raise RuntimeError(f"X API unexpected response: {body!r}")
        return data

    def post_daily_thread(
        self,
        day: str,
        entries: list[dict[str, Any]],
        *,
        parse_trade_levels: Callable[[str], dict[str, Optional[float]]],
        format_usd: Callable[[float], str],
    ) -> dict[str, Any]:
        """Post header + one reply per coin. Idempotent per calendar day."""
        cfg = self.config
        if not cfg.enabled:
            return {"skipped": True, "reason": "disabled"}

        if not cfg.oauth_ready():
            missing = ", ".join(cfg.missing_fields())
            return {"skipped": True, "reason": f"missing_oauth_credentials: {missing}"}

        if already_posted_today(cfg, day):
            return {"skipped": True, "reason": "already_posted", "day": day}

        wanted = {c.upper() for c in cfg.post_coins}
        filtered = [e for e in entries if str(e.get("coin", "")).upper() in wanted]
        if not filtered:
            return {"skipped": True, "reason": "no_matching_entries", "wanted": list(wanted)}

        coins_order = [c for c in cfg.post_coins if any(str(e.get("coin", "")).upper() == c for e in filtered)]
        filtered.sort(key=lambda e: coins_order.index(str(e.get("coin", "")).upper()))

        tweet_ids: list[str] = []
        header = format_thread_header(day, coins_order, cfg.handle)
        header_data = self.post_tweet(header)
        root_id = str(header_data["id"])
        tweet_ids.append(root_id)
        logger.info("x_daily_header_posted day=%s tweet_id=%s", day, root_id)

        for entry in filtered:
            coin = str(entry.get("coin", "")).upper()
            text = format_coin_tweet(entry, parse_trade_levels=parse_trade_levels, format_usd=format_usd)
            data = self.post_tweet(text, reply_to_tweet_id=root_id)
            tweet_id = str(data["id"])
            tweet_ids.append(tweet_id)
            logger.info("x_daily_coin_posted day=%s coin=%s tweet_id=%s", day, coin, tweet_id)

        state = _load_state(cfg.state_file)
        state[day] = {
            "posted_at": datetime.now(timezone.utc).isoformat(),
            "root_tweet_id": root_id,
            "tweet_ids": tweet_ids,
            "coins": coins_order,
            "handle": cfg.handle,
        }
        _save_state(cfg.state_file, state)

        return {
            "success": True,
            "day": day,
            "root_tweet_id": root_id,
            "tweet_ids": tweet_ids,
            "coins": coins_order,
        }


def post_daily_analyses_to_x(
    day: str,
    entries: list[dict[str, Any]],
    *,
    parse_trade_levels: Callable[[str], dict[str, Optional[float]]],
    format_usd: Callable[[float], str],
    config: Optional[XDailyPosterConfig] = None,
) -> dict[str, Any]:
    """Synchronous entry point (safe to run in asyncio.to_thread)."""
    poster = XDailyPoster(config)
    try:
        return poster.post_daily_thread(
            day,
            entries,
            parse_trade_levels=parse_trade_levels,
            format_usd=format_usd,
        )
    except Exception as exc:
        logger.exception("x_daily_post_failed day=%s err=%s", day, exc)
        return {"success": False, "day": day, "error": str(exc)}


def post_today_from_store(
    *,
    load_store: Callable[[], dict[str, Any]],
    day_key: str,
    parse_trade_levels: Callable[[str], dict[str, Optional[float]]],
    format_usd: Callable[[float], str],
    config: Optional[XDailyPosterConfig] = None,
) -> dict[str, Any]:
    """Load today's persisted analyses and post (for cron / scheduler)."""
    store = load_store()
    if store.get("day") != day_key:
        return {"skipped": True, "reason": "no_store_for_day", "day": day_key}
    raw = store.get("analyses")
    if not isinstance(raw, list) or not raw:
        return {"skipped": True, "reason": "empty_analyses", "day": day_key}
    return post_daily_analyses_to_x(
        day_key,
        raw,
        parse_trade_levels=parse_trade_levels,
        format_usd=format_usd,
        config=config,
    )
