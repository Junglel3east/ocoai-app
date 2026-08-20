"""
Daily analysis → Discord webhook poster — On-Chain Oracle AI.

Posts today's persisted BTC/ETH (configurable) daily breakdowns to a Discord
channel via Incoming Webhook. Full Grok reports are too long for Discord, so
this sends compact embeds (bias, conviction, Entry/TP1/TP2/SL, short summary).

Set DISCORD_WEBHOOK_URL on Railway. Never commit the webhook URL.
"""

from __future__ import annotations

import json
import logging
import os
import re
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Optional
from urllib.parse import urlparse

import requests

from x_daily_poster import parse_report_metadata

logger = logging.getLogger("ocoai.discord_daily_poster")

_DISCORD_WEBHOOK_HOSTS = {"discord.com", "discordapp.com"}
_DESCRIPTION_MAX = 350
_EMBED_COLOR_CYAN = 0x00BFFF
_BIAS_COLORS = {
    "Bullish": 0x22C55E,
    "Bearish": 0xEF4444,
    "Neutral": _EMBED_COLOR_CYAN,
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


def redact_webhook_url(url: str) -> str:
    """Safe log form — never print the webhook token."""
    text = (url or "").strip()
    if not text:
        return "(empty)"
    try:
        parsed = urlparse(text)
        parts = [p for p in parsed.path.split("/") if p]
        token_tail = parts[-1][-4:] if parts else ""
        return f"{parsed.scheme}://{parsed.netloc}/api/webhooks/…{token_tail}"
    except Exception:
        return "(unparseable)"


def is_discord_webhook_url(url: str) -> bool:
    text = (url or "").strip()
    if not text:
        return False
    try:
        parsed = urlparse(text)
    except Exception:
        return False
    host = (parsed.netloc or "").lower()
    if host.startswith("www."):
        host = host[4:]
    if parsed.scheme != "https" or host not in _DISCORD_WEBHOOK_HOSTS:
        return False
    parts = [p for p in parsed.path.split("/") if p]
    # /api/webhooks/{id}/{token}
    return len(parts) >= 4 and parts[0] == "api" and parts[1] == "webhooks"


class DiscordDailyPosterConfig:
    """Runtime configuration from environment variables."""

    def __init__(self) -> None:
        self.webhook_url = (os.getenv("DISCORD_WEBHOOK_URL") or "").strip()
        # On when a valid webhook is present unless explicitly disabled.
        self.enabled = _env_bool("DISCORD_DAILY_ENABLED", True) and bool(self.webhook_url)
        self.post_coins: tuple[str, ...] = _parse_coin_list(
            os.getenv("DISCORD_DAILY_COINS", "BTC,ETH"),
            ("BTC", "ETH"),
        )
        self.username = (os.getenv("DISCORD_WEBHOOK_USERNAME") or "On-Chain Oracle AI").strip()
        data_dir = Path(os.getenv("CITADEL_DATA_DIR", str(Path(__file__).resolve().parent / "data")))
        self.state_file = data_dir / "discord_daily_posts.json"

    def webhook_ready(self) -> bool:
        return is_discord_webhook_url(self.webhook_url)

    def missing_fields(self) -> list[str]:
        if self.webhook_ready():
            return []
        if not self.webhook_url:
            return ["DISCORD_WEBHOOK_URL"]
        return ["DISCORD_WEBHOOK_URL (invalid Discord webhook URL)"]


def _truncate(text: str, limit: int) -> str:
    text = re.sub(r"\s+", " ", (text or "").strip())
    if len(text) <= limit:
        return text
    return text[: max(0, limit - 1)].rstrip() + "…"


def _load_state(path: Path) -> dict[str, Any]:
    if not path.is_file():
        return {}
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
        return raw if isinstance(raw, dict) else {}
    except Exception as exc:
        logger.error("discord_daily_state_read_failed path=%s err=%s", path, exc)
        return {}


def _save_state(path: Path, state: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(state, indent=2), encoding="utf-8")
    tmp.replace(path)


def already_posted_today(config: DiscordDailyPosterConfig, day: str) -> bool:
    state = _load_state(config.state_file)
    record = state.get(day)
    return isinstance(record, dict) and bool(record.get("posted_at"))


def _price_field(levels: dict[str, Optional[float]], key: str, format_usd: Callable[[float], str]) -> str:
    value = levels.get(key)
    if value is None:
        return "—"
    return format_usd(value)


def build_coin_embed(
    entry: dict[str, Any],
    *,
    parse_trade_levels: Callable[[str], dict[str, Optional[float]]],
    format_usd: Callable[[float], str],
) -> dict[str, Any]:
    coin = str(entry.get("coin") or "").upper()
    report = str(entry.get("report") or "")
    meta = parse_report_metadata(report)
    levels = parse_trade_levels(report)
    bias = str(meta.get("bias") or "Neutral")
    conviction = meta.get("conviction")
    conv_line = f" · {conviction}% conviction" if conviction is not None else ""
    summary = _truncate(str(meta.get("summary") or ""), _DESCRIPTION_MAX)
    if not summary:
        summary = "Open the app for the full 1D report."

    return {
        "title": f"${coin} Daily · {bias}{conv_line}",
        "description": summary,
        "color": _BIAS_COLORS.get(bias, _EMBED_COLOR_CYAN),
        "fields": [
            {"name": "Entry", "value": _price_field(levels, "entry", format_usd), "inline": True},
            {"name": "TP1 (40%)", "value": _price_field(levels, "tp1", format_usd), "inline": True},
            {"name": "TP2 (60%)", "value": _price_field(levels, "tp2", format_usd), "inline": True},
            {"name": "SL", "value": _price_field(levels, "sl", format_usd), "inline": True},
        ],
        "footer": {"text": "On-Chain Oracle AI · full report in the app"},
    }


def build_webhook_payload(
    day: str,
    entries: list[dict[str, Any]],
    *,
    username: str,
    parse_trade_levels: Callable[[str], dict[str, Optional[float]]],
    format_usd: Callable[[float], str],
) -> dict[str, Any]:
    coins = [str(e.get("coin") or "").upper() for e in entries]
    coin_str = " · ".join(f"${c}" for c in coins)
    embeds = [
        build_coin_embed(entry, parse_trade_levels=parse_trade_levels, format_usd=format_usd)
        for entry in entries
    ]
    return {
        "username": username[:80],
        "content": f"🔮 **Daily 1D Analysis** — {day} · {coin_str}",
        "allowed_mentions": {"parse": []},
        "embeds": embeds[:10],
    }


class DiscordDailyPoster:
    def __init__(self, config: Optional[DiscordDailyPosterConfig] = None) -> None:
        self.config = config or DiscordDailyPosterConfig()

    def post_webhook(self, payload: dict[str, Any]) -> dict[str, Any]:
        url = self.config.webhook_url
        # wait=true returns the created message so we can store an id
        response = requests.post(
            url,
            params={"wait": "true"},
            json=payload,
            timeout=30,
        )
        if response.status_code >= 400:
            raise RuntimeError(f"Discord webhook error {response.status_code}: {response.text[:400]}")
        if not response.text:
            return {}
        try:
            body = response.json()
        except Exception:
            return {}
        return body if isinstance(body, dict) else {}

    def post_daily_embeds(
        self,
        day: str,
        entries: list[dict[str, Any]],
        *,
        parse_trade_levels: Callable[[str], dict[str, Optional[float]]],
        format_usd: Callable[[float], str],
    ) -> dict[str, Any]:
        cfg = self.config
        if not cfg.enabled:
            return {"skipped": True, "reason": "disabled"}
        if not cfg.webhook_ready():
            missing = ", ".join(cfg.missing_fields())
            return {"skipped": True, "reason": f"missing_webhook: {missing}"}
        if already_posted_today(cfg, day):
            return {"skipped": True, "reason": "already_posted", "day": day}

        wanted = {c.upper() for c in cfg.post_coins}
        filtered = [e for e in entries if str(e.get("coin", "")).upper() in wanted]
        if not filtered:
            return {"skipped": True, "reason": "no_matching_entries", "wanted": list(wanted)}

        coins_order = [c for c in cfg.post_coins if any(str(e.get("coin", "")).upper() == c for e in filtered)]
        filtered.sort(key=lambda e: coins_order.index(str(e.get("coin", "")).upper()))

        payload = build_webhook_payload(
            day,
            filtered,
            username=cfg.username,
            parse_trade_levels=parse_trade_levels,
            format_usd=format_usd,
        )
        message = self.post_webhook(payload)
        message_id = str(message.get("id") or "")
        logger.info(
            "discord_daily_posted day=%s coins=%s webhook=%s message_id=%s",
            day,
            ",".join(coins_order),
            redact_webhook_url(cfg.webhook_url),
            message_id or "(none)",
        )

        state = _load_state(cfg.state_file)
        state[day] = {
            "posted_at": datetime.now(timezone.utc).isoformat(),
            "message_id": message_id,
            "coins": coins_order,
        }
        _save_state(cfg.state_file, state)

        return {
            "success": True,
            "day": day,
            "message_id": message_id,
            "coins": coins_order,
        }


def post_daily_analyses_to_discord(
    day: str,
    entries: list[dict[str, Any]],
    *,
    parse_trade_levels: Callable[[str], dict[str, Optional[float]]],
    format_usd: Callable[[float], str],
    config: Optional[DiscordDailyPosterConfig] = None,
) -> dict[str, Any]:
    """Synchronous entry point (safe to run in asyncio.to_thread)."""
    poster = DiscordDailyPoster(config)
    try:
        return poster.post_daily_embeds(
            day,
            entries,
            parse_trade_levels=parse_trade_levels,
            format_usd=format_usd,
        )
    except Exception as exc:
        logger.exception("discord_daily_post_failed day=%s err=%s", day, exc)
        return {"success": False, "day": day, "error": str(exc)}


def post_today_from_store(
    *,
    load_store: Callable[[], dict[str, Any]],
    day_key: str,
    parse_trade_levels: Callable[[str], dict[str, Optional[float]]],
    format_usd: Callable[[float], str],
    config: Optional[DiscordDailyPosterConfig] = None,
) -> dict[str, Any]:
    """Load today's persisted analyses and post (for cron / scheduler)."""
    store = load_store()
    if store.get("day") != day_key:
        return {"skipped": True, "reason": "no_store_for_day", "day": day_key}
    raw = store.get("analyses")
    if not isinstance(raw, list) or not raw:
        return {"skipped": True, "reason": "empty_analyses", "day": day_key}
    return post_daily_analyses_to_discord(
        day_key,
        raw,
        parse_trade_levels=parse_trade_levels,
        format_usd=format_usd,
        config=config,
    )
