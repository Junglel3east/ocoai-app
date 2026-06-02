"""
On-Chain Oracle AI — Production FastAPI backend (Flutter app).

Fully self-contained. Does NOT import from Telegram bot (main.py / bot.py).

Run locally:
  cd backend
  pip install -r requirements.txt
  cp .env.example .env   # set GROK_API_KEY
  python api.py

Deploy (Railway):
  Service root directory: backend
  Variables: GROK_API_KEY (required)
  Start: uvicorn api:app --host 0.0.0.0 --port $PORT  (see railway.json / Procfile)

Endpoints (lib/main.dart):
  GET  /health, GET /
  GET  /coins
  POST /analyze   — analysis + trade setup (mode: analysis | tradesetup)
  POST /trade-setup, /trade_setup, /tradesetup — aliases → same handler (mode=tradesetup)
  POST /review    — report performance review
  POST /chat      — Expert Oracle Trader AI chat

Price chain: Binance Spot → Binance Futures → CoinGecko
Derivatives (/analyze): funding, OI, long/short ratio, liquidations (Binance Futures)
Trade levels format (Oracle Citadel / Flutter parsing):
  Entry at $X, TP1 at $X, TP2 at $X, SL at $X (R:R X.X:1)
"""

from __future__ import annotations

import logging
import os
import re
import time
import uuid
from concurrent.futures import ThreadPoolExecutor
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Any, Optional

import requests
import uvicorn
from dotenv import load_dotenv
from fastapi import FastAPI, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field

# ---------------------------------------------------------------------------
# Environment — Railway Variables + optional local .env (never commit .env)
# ---------------------------------------------------------------------------

_BACKEND_DIR = Path(__file__).resolve().parent
_PROJECT_ROOT = _BACKEND_DIR.parent

# Local dev: load .env if present. Railway injects vars directly (no .env file).
_env_file = _BACKEND_DIR / ".env"
_root_env = _PROJECT_ROOT / ".env"
if _env_file.is_file():
    load_dotenv(_env_file)
if _root_env.is_file():
    load_dotenv(_root_env)

# Required on Railway: Variables → GROK_API_KEY
GROK_API_KEY = (os.getenv("GROK_API_KEY") or "").strip()
GROK_MODEL = os.getenv("GROK_MODEL", "grok-4")
GROK_API_URL = os.getenv("GROK_API_URL", "https://api.x.ai/v1/chat/completions")

REQUEST_TIMEOUT = int(os.getenv("REQUEST_TIMEOUT", "15"))
GROK_TIMEOUT = int(os.getenv("GROK_TIMEOUT", "90"))
API_HOST = os.getenv("API_HOST", "0.0.0.0")
# Railway sets PORT; fall back to API_PORT then 8000 for local `python api.py`
API_PORT = int(os.getenv("PORT", os.getenv("API_PORT", "8000")))

MIN_RR_TP1 = 2.1
TARGET_RR_TP1 = 2.3

DISCLAIMER = (
    "**Disclaimer**: This is for informational and educational purposes only. "
    "Not financial advice. Always DYOR."
)

LOG_LEVEL = os.getenv("LOG_LEVEL", "INFO").upper()
logging.basicConfig(
    level=getattr(logging, LOG_LEVEL, logging.INFO),
    format="%(asctime)s | %(levelname)-8s | %(name)s | %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
logger = logging.getLogger("oracle.backend")

# Symbol (uppercase) → CoinGecko coin id (seed + dynamic refresh)
_SYMBOL_TO_COINGECKO_ID: dict[str, str] = {
    "BTC": "bitcoin",
    "ETH": "ethereum",
    "SOL": "solana",
    "BNB": "binancecoin",
    "XRP": "ripple",
    "ADA": "cardano",
    "DOGE": "dogecoin",
    "AVAX": "avalanche-2",
    "DOT": "polkadot",
    "LINK": "chainlink",
    "MATIC": "matic-network",
    "POL": "polygon-ecosystem-token",
    "LTC": "litecoin",
    "TRX": "tron",
    "SHIB": "shiba-inu",
    "ATOM": "cosmos",
    "UNI": "uniswap",
    "NEAR": "near",
    "APT": "aptos",
    "ARB": "arbitrum",
    "OP": "optimism",
    "SUI": "sui",
    "PEPE": "pepe",
    "FIL": "filecoin",
    "ICP": "internet-computer",
    "HBAR": "hedera-hashgraph",
    "VET": "vechain",
    "MKR": "maker",
    "AAVE": "aave",
    "INJ": "injective-protocol",
    "RENDER": "render-token",
    "FET": "fetch-ai",
    "TAO": "bittensor",
    "WIF": "dogwifcoin",
    "BONK": "bonk",
    "HYPE": "hyperliquid",
}

_COINGECKO_CACHE_LOADED_AT = 0.0
_COINGECKO_CACHE_TTL_SECONDS = 6 * 60 * 60


# ---------------------------------------------------------------------------
# Pydantic models — match Flutter payloads exactly
# ---------------------------------------------------------------------------


class AnalyzeRequest(BaseModel):
    coin: str
    timeframe: str = "1h"
    mode: str = "analysis"
    direction: str = "Smart Direction"
    report_style: str = "professional"
    system_prompt: Optional[str] = None
    refresh_price: bool = True
    request_ts: Optional[int] = None


class ReviewRequest(BaseModel):
    coin: str
    previous_report: str = Field(..., min_length=1)


class ChatMessage(BaseModel):
    role: str
    content: str


class ChatRequest(BaseModel):
    message: str = Field(..., min_length=1)
    history: list[ChatMessage] = Field(default_factory=list)
    system_prompt: Optional[str] = None
    request_ts: Optional[int] = None


def normalize_analyze_mode(raw: Optional[str], *, default: str = "analysis") -> str:
    """
    Flutter sends mode=tradesetup on POST /analyze.
    Aliases (trade-setup, trade_setup) map to the same internal mode.
    """
    token = (raw or default).strip().lower().replace("-", "").replace("_", "")
    if token in {"analysis", "analyze"}:
        return "analysis"
    if token in {"tradesetup", "setup", "trade"}:
        return "tradesetup"
    return token


# ---------------------------------------------------------------------------
# CoinGecko symbol index
# ---------------------------------------------------------------------------


def refresh_coingecko_symbol_index(force: bool = False) -> None:
    global _COINGECKO_CACHE_LOADED_AT

    now = time.time()
    if not force and (now - _COINGECKO_CACHE_LOADED_AT) < _COINGECKO_CACHE_TTL_SECONDS:
        return

    try:
        for page in (1, 2):
            response = requests.get(
                "https://api.coingecko.com/api/v3/coins/markets",
                params={
                    "vs_currency": "usd",
                    "order": "market_cap_desc",
                    "per_page": 250,
                    "page": page,
                    "sparkline": "false",
                },
                timeout=REQUEST_TIMEOUT,
            )
            if response.status_code != 200:
                logger.warning("CoinGecko markets page %d HTTP %s", page, response.status_code)
                break
            for coin in response.json():
                symbol = str(coin.get("symbol", "")).upper()
                coin_id = coin.get("id")
                if symbol and coin_id and symbol not in _SYMBOL_TO_COINGECKO_ID:
                    _SYMBOL_TO_COINGECKO_ID[symbol] = coin_id
        _COINGECKO_CACHE_LOADED_AT = now
        logger.info("CoinGecko index refreshed | symbols=%d", len(_SYMBOL_TO_COINGECKO_ID))
    except Exception as exc:
        logger.warning("CoinGecko index refresh failed: %s", exc)


def resolve_coingecko_id(symbol: str) -> Optional[str]:
    refresh_coingecko_symbol_index()
    upper = symbol.upper()

    if upper in _SYMBOL_TO_COINGECKO_ID:
        return _SYMBOL_TO_COINGECKO_ID[upper]

    try:
        response = requests.get(
            "https://api.coingecko.com/api/v3/search",
            params={"query": upper},
            timeout=REQUEST_TIMEOUT,
        )
        if response.status_code != 200:
            return None

        coins = response.json().get("coins", [])
        for coin in coins:
            if str(coin.get("symbol", "")).upper() == upper:
                coin_id = coin.get("id")
                if coin_id:
                    _SYMBOL_TO_COINGECKO_ID[upper] = coin_id
                    return coin_id

        if coins:
            coin_id = coins[0].get("id")
            if coin_id:
                _SYMBOL_TO_COINGECKO_ID[upper] = coin_id
                return coin_id
    except Exception as exc:
        logger.warning("CoinGecko search failed symbol=%s err=%s", upper, exc)

    return None


# ---------------------------------------------------------------------------
# Market data — Binance Spot → Futures → CoinGecko
# ---------------------------------------------------------------------------


def binance_usdt_symbol(coin: str) -> str:
    return f"{coin.upper()}USDT"


def fetch_binance_spot(symbol: str) -> Optional[dict[str, Any]]:
    try:
        response = requests.get(
            "https://api.binance.com/api/v3/ticker/24hr",
            params={"symbol": symbol},
            timeout=REQUEST_TIMEOUT,
        )
        if response.status_code != 200:
            return None
        data = response.json()
        price = float(data["lastPrice"])
        if price <= 0:
            return None
        return {
            "price": price,
            "change_24h_pct": float(data.get("priceChangePercent", 0)),
            "volume_24h_usd": float(data.get("quoteVolume", 0)),
            "source": "binance_spot",
        }
    except Exception as exc:
        logger.debug("Binance spot miss symbol=%s err=%s", symbol, exc)
        return None


def fetch_binance_futures(symbol: str) -> Optional[dict[str, Any]]:
    try:
        response = requests.get(
            "https://fapi.binance.com/fapi/v1/ticker/24hr",
            params={"symbol": symbol},
            timeout=REQUEST_TIMEOUT,
        )
        if response.status_code != 200:
            return None
        data = response.json()
        price = float(data["lastPrice"])
        if price <= 0:
            return None
        return {
            "price": price,
            "change_24h_pct": float(data.get("priceChangePercent", 0)),
            "volume_24h_usd": float(data.get("quoteVolume", 0)),
            "source": "binance_futures",
        }
    except Exception as exc:
        logger.debug("Binance futures miss symbol=%s err=%s", symbol, exc)
        return None


def fetch_coingecko_market(symbol: str) -> Optional[dict[str, Any]]:
    coin_id = resolve_coingecko_id(symbol)
    if not coin_id:
        return None

    try:
        response = requests.get(
            "https://api.coingecko.com/api/v3/simple/price",
            params={
                "ids": coin_id,
                "vs_currencies": "usd",
                "include_24hr_change": "true",
                "include_24hr_vol": "true",
            },
            timeout=REQUEST_TIMEOUT,
        )
        if response.status_code != 200:
            return None

        payload = response.json().get(coin_id, {})
        price = float(payload.get("usd", 0))
        if price <= 0:
            return None

        return {
            "price": price,
            "change_24h_pct": float(payload.get("usd_24h_change") or 0),
            "volume_24h_usd": float(payload.get("usd_24h_vol") or 0),
            "source": "coingecko",
            "coin_id": coin_id,
        }
    except Exception as exc:
        logger.debug("CoinGecko price miss symbol=%s err=%s", symbol, exc)
        return None


def fetch_market_snapshot(coin: str) -> dict[str, Any]:
    symbol = binance_usdt_symbol(coin)
    upper = coin.upper()

    for fetcher in (fetch_binance_spot, fetch_binance_futures):
        snapshot = fetcher(symbol)
        if snapshot:
            logger.info(
                "price_resolved coin=%s source=%s price=%.6f",
                upper,
                snapshot["source"],
                snapshot["price"],
            )
            return {"coin": upper, **snapshot}

    snapshot = fetch_coingecko_market(upper)
    if snapshot:
        logger.info(
            "price_resolved coin=%s source=coingecko price=%.6f",
            upper,
            snapshot["price"],
        )
        return {"coin": upper, **snapshot}

    raise HTTPException(
        status_code=502,
        detail=f"Unable to fetch a live price for {upper}. Try a major USDT-listed symbol.",
    )


# ---------------------------------------------------------------------------
# Binance Futures derivatives — funding, OI, L/S ratio, liquidations
# ---------------------------------------------------------------------------


def _binance_futures_get(path: str, params: dict[str, Any]) -> Optional[Any]:
    """GET helper for Binance USD-M Futures with graceful failure."""
    try:
        response = requests.get(
            f"https://fapi.binance.com{path}",
            params=params,
            timeout=REQUEST_TIMEOUT,
        )
        if response.status_code != 200:
            logger.debug("binance_futures %s HTTP %s", path, response.status_code)
            return None
        return response.json()
    except Exception as exc:
        logger.debug("binance_futures %s err=%s", path, exc)
        return None


def fetch_funding_rate(coin: str) -> Optional[float]:
    """Last funding rate (%), from premiumIndex."""
    data = _binance_futures_get("/fapi/v1/premiumIndex", {"symbol": binance_usdt_symbol(coin)})
    if not data:
        return None
    try:
        return float(data["lastFundingRate"]) * 100
    except (KeyError, TypeError, ValueError):
        return None


def fetch_open_interest(coin: str) -> Optional[float]:
    """Open interest in contracts, from openInterest."""
    data = _binance_futures_get("/fapi/v1/openInterest", {"symbol": binance_usdt_symbol(coin)})
    if not data:
        return None
    try:
        return float(data["openInterest"])
    except (KeyError, TypeError, ValueError):
        return None


def fetch_long_short_ratio(coin: str, *, period: str = "5m") -> Optional[dict[str, float]]:
    """
    Global long/short account ratio (latest 5m bucket).
    Returns longShortRatio, longAccount, shortAccount as fractions (0–1).
    """
    data = _binance_futures_get(
        "/fapi/v1/globalLongShortAccountRatio",
        {"symbol": binance_usdt_symbol(coin), "period": period, "limit": 1},
    )
    if not data or not isinstance(data, list) or not data:
        return None
    row = data[-1]
    try:
        return {
            "long_short_ratio": float(row["longShortRatio"]),
            "long_account_pct": float(row["longAccount"]) * 100,
            "short_account_pct": float(row["shortAccount"]) * 100,
        }
    except (KeyError, TypeError, ValueError):
        return None


def fetch_recent_liquidations(coin: str, *, limit: int = 20) -> Optional[dict[str, Any]]:
    """
    Recent force-liquidation orders (allForceOrders).
    SELL side ≈ long liquidations; BUY side ≈ short liquidations.
    """
    data = _binance_futures_get(
        "/fapi/v1/allForceOrders",
        {"symbol": binance_usdt_symbol(coin), "limit": limit},
    )
    if not data or not isinstance(data, list):
        return None

    long_liq_usd = 0.0
    short_liq_usd = 0.0
    long_count = 0
    short_count = 0

    for order in data:
        try:
            qty = float(order.get("executedQty") or order.get("origQty") or 0)
            price = float(order.get("avgPrice") or order.get("price") or 0)
            notional = qty * price
            if notional <= 0:
                continue
            side = str(order.get("side", "")).upper()
            if side == "SELL":
                long_liq_usd += notional
                long_count += 1
            elif side == "BUY":
                short_liq_usd += notional
                short_count += 1
        except (TypeError, ValueError):
            continue

    return {
        "long_liq_usd": long_liq_usd,
        "short_liq_usd": short_liq_usd,
        "long_count": long_count,
        "short_count": short_count,
        "total_count": long_count + short_count,
    }


def _label_funding(rate_pct: Optional[float]) -> str:
    if rate_pct is None:
        return "Funding neutral"
    if rate_pct >= 0.05:
        return f"Longs crowded — funding +{rate_pct:.4f}% (fade-long risk)"
    if rate_pct >= 0.01:
        return f"Mild long bias — funding +{rate_pct:.4f}%"
    if rate_pct <= -0.05:
        return f"Shorts crowded — funding {rate_pct:.4f}% (squeeze fuel)"
    if rate_pct <= -0.01:
        return f"Mild short bias — funding {rate_pct:.4f}%"
    return f"Funding neutral — {rate_pct:.4f}%"


def _label_open_interest(oi_contracts: Optional[float], spot_price: Optional[float] = None) -> str:
    if oi_contracts is None:
        return "OI stable"
    oi_str = f"{oi_contracts:,.0f} contracts"
    if spot_price and spot_price > 0:
        oi_usd = oi_contracts * spot_price
        if oi_usd >= 1_000_000_000:
            return f"OI elevated — {oi_str} (~${oi_usd / 1e9:.2f}B notional)"
        if oi_usd >= 1_000_000:
            return f"OI active — {oi_str} (~${oi_usd / 1e6:.1f}M notional)"
        return f"OI {oi_str} (~{format_usd(oi_usd)} notional)"
    return f"OI {oi_str}"


def _label_long_short(ls: Optional[dict[str, float]]) -> str:
    if not ls:
        return "Long/Short balanced"
    ratio = ls["long_short_ratio"]
    long_pct = ls["long_account_pct"]
    short_pct = ls["short_account_pct"]
    if ratio >= 1.25:
        return f"Long-heavy — {long_pct:.1f}% long / {short_pct:.1f}% short (ratio {ratio:.2f})"
    if ratio <= 0.80:
        return f"Short-heavy — {long_pct:.1f}% long / {short_pct:.1f}% short (ratio {ratio:.2f})"
    return f"Long/Short balanced — {long_pct:.1f}% long / {short_pct:.1f}% short (ratio {ratio:.2f})"


def _label_liquidations(liq: Optional[dict[str, Any]]) -> str:
    if not liq or liq["total_count"] == 0:
        return "Liquidation flow quiet"
    long_usd = liq["long_liq_usd"]
    short_usd = liq["short_liq_usd"]
    total = long_usd + short_usd
    if total <= 0:
        return "Liquidation flow quiet"

    def _fmt_usd(v: float) -> str:
        if v >= 1_000_000:
            return f"${v / 1e6:.2f}M"
        if v >= 1_000:
            return f"${v / 1e3:.1f}K"
        return format_usd(v)

    if long_usd > short_usd * 1.5:
        return (
            f"Long liquidations dominant — {_fmt_usd(long_usd)} long vs {_fmt_usd(short_usd)} short "
            f"({liq['total_count']} recent force orders)"
        )
    if short_usd > long_usd * 1.5:
        return (
            f"Short liquidations dominant — {_fmt_usd(short_usd)} short vs {_fmt_usd(long_usd)} long "
            f"({liq['total_count']} recent force orders)"
        )
    return (
        f"Mixed liquidation flow — {_fmt_usd(long_usd)} long / {_fmt_usd(short_usd)} short "
        f"({liq['total_count']} recent force orders)"
    )


def fetch_derivatives_snapshot(coin: str, *, spot_price: Optional[float] = None) -> dict[str, Any]:
    """
    Aggregate real-time Binance Futures derivatives for /analyze.
    Fetches funding, OI, 5m long/short ratio, and recent liquidations in parallel.
    Always returns human-readable labels — never raw N/A.
    """
    symbol = binance_usdt_symbol(coin)

    with ThreadPoolExecutor(max_workers=4) as pool:
        fut_funding = pool.submit(fetch_funding_rate, coin)
        fut_oi = pool.submit(fetch_open_interest, coin)
        fut_ls = pool.submit(fetch_long_short_ratio, coin)
        fut_liq = pool.submit(fetch_recent_liquidations, coin)
        funding = fut_funding.result()
        oi = fut_oi.result()
        ls = fut_ls.result()
        liq = fut_liq.result()

    snapshot = {
        "symbol": symbol,
        "funding_rate_pct": funding,
        "funding_label": _label_funding(funding),
        "open_interest": oi,
        "open_interest_usd": (oi * spot_price) if oi and spot_price else None,
        "oi_label": _label_open_interest(oi, spot_price),
        "long_short": ls,
        "ls_label": _label_long_short(ls),
        "liquidations": liq,
        "liq_label": _label_liquidations(liq),
        "has_futures_data": any(x is not None for x in (funding, oi, ls, liq)),
    }

    logger.info(
        "derivatives coin=%s funding=%s oi=%s ls=%s liq_orders=%s",
        coin.upper(),
        f"{funding:.4f}%" if funding is not None else "fallback",
        f"{oi:,.0f}" if oi is not None else "fallback",
        f"{ls['long_short_ratio']:.2f}" if ls else "fallback",
        liq["total_count"] if liq else 0,
    )
    return snapshot


def format_derivatives_prompt_block(derivatives: dict[str, Any]) -> str:
    """Structured derivatives context for the LLM user prompt."""
    funding = derivatives["funding_rate_pct"]
    funding_val = f"{funding:.4f}%" if funding is not None else "unavailable — treat as neutral"
    oi = derivatives["open_interest"]
    oi_val = f"{oi:,.0f} contracts" if oi is not None else "unavailable — treat as stable"
    ls = derivatives["long_short"]
    if ls:
        ls_val = (
            f"ratio {ls['long_short_ratio']:.2f} | "
            f"{ls['long_account_pct']:.1f}% long accounts / {ls['short_account_pct']:.1f}% short"
        )
    else:
        ls_val = "unavailable — treat as balanced"

    liq = derivatives["liquidations"]
    if liq and liq["total_count"] > 0:
        liq_val = (
            f"{liq['total_count']} force orders | "
            f"long liq ~${liq['long_liq_usd']:,.0f} | short liq ~${liq['short_liq_usd']:,.0f}"
        )
    else:
        liq_val = "quiet — no meaningful recent force orders"

    return f"""═══ LIVE DERIVATIVES DATA (Binance Futures — weave into prose, never list mechanically) ═══
Funding: {funding_val} → {derivatives['funding_label']}
Open Interest: {oi_val} → {derivatives['oi_label']}
Long/Short (5m): {ls_val} → {derivatives['ls_label']}
Liquidations (last 20): {liq_val} → {derivatives['liq_label']}

HOW TO USE THIS DATA (critical — read before writing):
• **Liquidity & Sentiment** = ONE flowing paragraph of veteran desk prose. Weave funding, OI, positioning,
  and liquidation flow into a single positioning verdict — who is trapped, who is crowded, what the
  squeeze/cascade risk is. NEVER enumerate metrics as "Funding: … OI: … L/S: …" — that reads like a bot.
  Good: "Longs are stacked — elevated funding, 62% long accounts, and fresh long liquidations suggest
  trapped exposure above; fade rallies into VWAP unless structure reclaims."
  Bad: "Funding is neutral. OI is stable. Long/short is balanced. Liquidations are quiet."
• **Confluence Summary** MUST reflect derivatives when they confirm or contradict structure/VWAP/momentum.
  Embed the positioning read inside the edge sentence — not as a separate data recap.
• **Overall Bias** and **If I Were to Trade Today...** shift when derivatives align with or fight the
  technical thesis (crowded + extended = caution; liq cascade + structure break = follow impulse).
• In user-facing text: use the smart labels above as natural language — never "N/A", "unavailable", or raw API dumps."""


def format_usd(price: float) -> str:
    if price >= 1000:
        return f"${price:,.0f}"
    if price >= 1:
        return f"${price:,.2f}"
    if price >= 0.01:
        return f"${price:,.4f}"
    return f"${price:,.6f}"


# ---------------------------------------------------------------------------
# Trade level validation (Oracle Citadel / Flutter extractTradeLevel)
# ---------------------------------------------------------------------------

_TRADE_LEVEL_PATTERNS = {
    "entry": re.compile(r"entry\s*(?:at|:)?\s*\$?\s*([0-9]+(?:[.,][0-9]+)?)", re.I),
    "tp1": re.compile(r"tp1\s*(?:at|:)?\s*\$?\s*([0-9]+(?:[.,][0-9]+)?)", re.I),
    "tp2": re.compile(r"tp2\s*(?:at|:)?\s*\$?\s*([0-9]+(?:[.,][0-9]+)?)", re.I),
    "sl": re.compile(r"sl\s*(?:at|:)?\s*\$?\s*([0-9]+(?:[.,][0-9]+)?)", re.I),
}


def parse_trade_levels(report: str) -> dict[str, Optional[float]]:
    levels: dict[str, Optional[float]] = {k: None for k in _TRADE_LEVEL_PATTERNS}
    for key, pattern in _TRADE_LEVEL_PATTERNS.items():
        match = pattern.search(report)
        if match:
            levels[key] = float(match.group(1).replace(",", ""))
    return levels


def compute_rr(entry: float, tp1: float, sl: float) -> Optional[float]:
    risk = abs(entry - sl)
    reward = abs(tp1 - entry)
    if risk <= 0:
        return None
    return reward / risk


def audit_trade_levels(report: str, live_price: float, *, scalp_mode: bool = False) -> None:
    levels = parse_trade_levels(report)
    entry, tp1, sl = levels["entry"], levels["tp1"], levels["sl"]
    if entry is None or tp1 is None or sl is None:
        return

    rr = compute_rr(entry, tp1, sl)
    if rr is not None:
        if rr < MIN_RR_TP1:
            logger.warning(
                "rr_below_floor rr=%.2f floor=%.1f entry=%s tp1=%s sl=%s",
                rr,
                MIN_RR_TP1,
                entry,
                tp1,
                sl,
            )
        else:
            logger.info("rr_ok rr=%.2f entry=%s tp1=%s sl=%s", rr, entry, tp1, sl)

    if live_price > 0:
        drift_pct = abs(entry - live_price) / live_price * 100
        max_drift = 2.5 if scalp_mode else 8.0
        if drift_pct > max_drift:
            logger.warning(
                "entry_drift entry=%.6f live=%.6f drift_pct=%.1f max=%.1f scalp=%s",
                entry,
                live_price,
                drift_pct,
                max_drift,
                scalp_mode,
            )


# ---------------------------------------------------------------------------
# Grok / xAI
# ---------------------------------------------------------------------------


def call_grok(
    *,
    system_prompt: str,
    user_prompt: str,
    temperature: float = 0.4,
    max_tokens: int = 1600,
) -> str:
    if not GROK_API_KEY:
        raise HTTPException(status_code=500, detail="GROK_API_KEY is not configured.")

    started = time.perf_counter()
    try:
        response = requests.post(
            GROK_API_URL,
            headers={
                "Authorization": f"Bearer {GROK_API_KEY}",
                "Content-Type": "application/json",
            },
            json={
                "model": GROK_MODEL,
                "messages": [
                    {"role": "system", "content": system_prompt},
                    {"role": "user", "content": user_prompt},
                ],
                "temperature": temperature,
                "max_tokens": max_tokens,
            },
            timeout=GROK_TIMEOUT,
        )
    except requests.RequestException as exc:
        logger.error("grok_request_failed err=%s", exc)
        raise HTTPException(status_code=502, detail="AI service unreachable.") from exc

    elapsed_ms = (time.perf_counter() - started) * 1000

    if response.status_code != 200:
        logger.error("grok_http_error status=%s body=%s", response.status_code, response.text[:400])
        raise HTTPException(status_code=502, detail="AI service returned an error.")

    try:
        content = response.json()["choices"][0]["message"]["content"]
    except (KeyError, IndexError, ValueError) as exc:
        raise HTTPException(status_code=502, detail="Malformed AI response.") from exc

    logger.info("grok_ok model=%s elapsed_ms=%.0f chars=%d", GROK_MODEL, elapsed_ms, len(content))
    return content.strip()


def call_grok_chat(
    *,
    system_prompt: str,
    history: list[dict[str, str]],
    message: str,
    temperature: float = 0.55,
    max_tokens: int = 900,
) -> str:
    if not GROK_API_KEY:
        raise HTTPException(status_code=500, detail="GROK_API_KEY is not configured.")

    messages: list[dict[str, str]] = [{"role": "system", "content": system_prompt}]
    for item in history:
        role = (item.get("role") or "").strip().lower()
        content = (item.get("content") or "").strip()
        if role in {"user", "assistant"} and content:
            messages.append({"role": role, "content": content})
    messages.append({"role": "user", "content": message.strip()})

    started = time.perf_counter()
    try:
        response = requests.post(
            GROK_API_URL,
            headers={
                "Authorization": f"Bearer {GROK_API_KEY}",
                "Content-Type": "application/json",
            },
            json={
                "model": GROK_MODEL,
                "messages": messages,
                "temperature": temperature,
                "max_tokens": max_tokens,
            },
            timeout=GROK_TIMEOUT,
        )
    except requests.RequestException as exc:
        logger.error("grok_chat_failed err=%s", exc)
        raise HTTPException(status_code=502, detail="AI service unreachable.") from exc

    elapsed_ms = (time.perf_counter() - started) * 1000

    if response.status_code != 200:
        logger.error("grok_chat_http_error status=%s", response.status_code)
        raise HTTPException(status_code=502, detail="AI service returned an error.")

    try:
        content = response.json()["choices"][0]["message"]["content"]
    except (KeyError, IndexError, ValueError) as exc:
        raise HTTPException(status_code=502, detail="Malformed AI response.") from exc

    logger.info("grok_chat_ok elapsed_ms=%.0f chars=%d", elapsed_ms, len(content))
    return content.strip()


def strip_trailing_questions(text: str) -> str:
    if DISCLAIMER not in text:
        return text.rstrip()

    head, _ = text.rsplit(DISCLAIMER, 1)
    lines = head.rstrip().splitlines()
    while lines:
        last = lines[-1].strip()
        if not last:
            lines.pop()
            continue
        if last.endswith("?"):
            lines.pop()
            continue
        if re.search(
            r"(let me know|would you like|want me to|if you('d| would) like|feel free to ask)",
            last,
            re.I,
        ):
            lines.pop()
            continue
        break

    return "\n".join(lines).rstrip() + "\n\n" + DISCLAIMER


def ensure_disclaimer(text: str) -> str:
    cleaned = text.strip()
    if DISCLAIMER not in cleaned:
        cleaned = f"{cleaned}\n\n{DISCLAIMER}"
    return strip_trailing_questions(cleaned)


# ---------------------------------------------------------------------------
# Prompts — veteran desk analyst (maximum conviction)
# ---------------------------------------------------------------------------


# Scalp detection — short TF or explicit scalp language in request
_SCALP_TIMEFRAMES = frozenset({"5m", "10m", "15m", "20m", "30m", "1m", "3m"})
_SCALP_KEYWORDS = (
    "scalp",
    "scalping",
    "scalping setup",
    "scalp setup",
    "quick move",
    "quick scalp",
    "quick trade",
    "fast trade",
    "short-term",
    "short term",
    "short term trade",
    "intra-day",
    "intraday",
    "in and out",
    "micro move",
)


def is_scalp_context(
    *,
    timeframe: str = "",
    direction: str = "",
    mode: str = "",
    system_prompt: str = "",
) -> bool:
    """True when user wants a short-term / scalp read."""
    blob = " ".join([timeframe, direction, mode, system_prompt]).lower()
    if any(kw in blob for kw in _SCALP_KEYWORDS):
        return True
    tf = timeframe.strip().lower()
    if tf in _SCALP_TIMEFRAMES:
        return True
    # Numeric minute timeframes under 45m → scalp context
    m = re.match(r"^(\d+)\s*m(?:in)?$", tf)
    if m and int(m.group(1)) <= 45:
        return True
    return False


def default_system_prompt(mode: str, *, scalp_mode: bool = False) -> str:
    """
    Elite veteran system prompt — 15+ years real capital, zero filler, natural derivatives integration.
    Preserves exact Flutter report structure.
    """
    scalp_active = f"""
═══════════════════════════════════════
⚡ SCALP MODE ACTIVE — BEST SETUP ON THE BOARD OR FLAT
═══════════════════════════════════════
Scalp / quick-move / scalping setup / short-term detected. Deliver the absolute best high-probability
scalp available RIGHT NOW — or "NO SCALP — STAY FLAT" with TRADE LEVELS omitted. Never force a weak scalp.

SCALP DOCTRINE (all required when proposing a scalp):
• TIMEFRAME: State exact TFs — e.g. "5m trigger | 15m bias | 1h filter". Horizon: minutes to ~90 min.
• PRICE: Entry anchored to live spot — ≤0.8% majors, ≤1.2% high-beta alts only at named structure.
• TRIGGER: Name the exact event — VWAP reclaim/reject, EMA 5/20 bounce, sweep + reclaim, BOS retest,
  RSI impulse through 50/55/45. Generic "momentum looks good" is forbidden.
• MOMENTUM: EMA 5/20 + RSI direction + MACD histogram + volume vs prior 5–10 bars — all aligned or NO SCALP.
• VWAP: Session VWAP is the scalp battlefield — state position, acceptance/rejection, distance %.
• DERIVATIVES: Fold funding/OI/positioning/liqs into the scalp thesis — crowded side + liq flow =
  fade or follow; never ignore live positioning on a scalp call.
• SL: Micro invalidation beyond sweep wick / VWAP flip / structure — majors ~0.12–0.55%.
• TP1: First liquidity pocket, ≥{MIN_RR_TP1:.1f}:1 R:R (target {TARGET_RR_TP1:.1f}:1+). TP2 = extension only.
• TIME-BOX: "Valid next X bars on [TF]" or invalidation condition stated explicitly.
• LABEL: **If I Were to Trade Today...** → "[Long/Short] SCALP Setup:" with trigger + invalidation in desk language.
"""

    scalp_standby = f"""
═══════════════════════════════════════
SCALP PROTOCOL (auto: scalp / quick move / scalping setup / short-term / ≤45m TF)
═══════════════════════════════════════
On scalp intent: surgical entries, session VWAP, momentum trigger, micro SL, derivatives filter,
≥{MIN_RR_TP1:.1f}:1 R:R on TP1. Best scalp on the board or explicit refusal — no half-measures.
"""

    shared = f"""You are On-Chain Oracle AI — elite veteran crypto trader. 15+ years. Real capital every session.
Prop desk, institutional flow, full-cycle survivor. You deliver verdicts, not essays. Call the trade or call FLAT.

VOICE: Orders to a trading desk. Sharp. Decisive. High conviction. You risk real money on every call.
Write like a trader who has made and lost seven figures and respects edge above ego.

FORBIDDEN (never appear in output):
"might", "could", "possibly", "perhaps", "maybe", "it seems", "appears to", "I think", "I believe",
"interesting", "worth watching", "mixed signals" without verdict, "let me know", "would you like",
"consider", "potentially", "somewhat", "moderately", bullet-dumping raw metrics, listing funding/OI/L-S
as separate sentences, chatbot warmth, tutorial tone.

REQUIRED: edge, invalidation, acceptance, rejection, liquidity pool, sweep, crowded, squeeze fuel,
trapped traders, continuation, failed breakdown — woven into verdict-driven prose.

═══════════════════════════════════════
RULE 0 — LIVE PRICE (ZERO TOLERANCE)
═══════════════════════════════════════
• User prompt = ONLY authoritative live price. Not memory. Not estimates.
• **Asset** line: EXACT coin | live price | 24h % from prompt.
• Every Entry / TP1 / TP2 / SL vs live price NOW. Pre-flight: entry drift %, SL/TP direction correct.
• Long: SL < Entry < TP1 ≤ TP2. Short: TP2 ≤ TP1 < Entry < SL. Stale levels → adapt or omit.

═══════════════════════════════════════
RULE 1 — RISK:REWARD (NON-NEGOTIABLE)
═══════════════════════════════════════
• Minimum {MIN_RR_TP1:.1f}:1 R:R on TP1 vs |Entry − SL|. Target {TARGET_RR_TP1:.1f}:1+. Never below 2.0:1.
• TRADE LEVELS format (Oracle Citadel / Flutter parser):
  Entry at $XXXXX, TP1 at $XXXXX, TP2 at $XXXXX, SL at $XXXXX (R:R X.X:1)
  Reward = |TP1 − Entry| = $X | Risk = |Entry − SL| = $X | R:R = X.X:1
• No valid ≥{MIN_RR_TP1:.1f}:1 → omit TRADE LEVELS. Stay flat is alpha preservation.

═══════════════════════════════════════
RULE 2 — ANALYTICAL STACK
═══════════════════════════════════════
• MTF: Daily/4h → requested TF → LTF trigger. ALIGNED or CONFLICTED — conflict cuts confidence.
• VWAP stack, structure (BOS/CHoCH, liquidity), momentum (EMA 5/20, RSI, MACD, volume).
• Key Drivers bullets: verdict-driven prose ending in directional implication — not indicator laundry lists.

═══════════════════════════════════════
RULE 3 — DERIVATIVES (natural integration — NOT mechanical)
═══════════════════════════════════════
Live Binance Futures data in user prompt: funding, OI, 5m long/short accounts, recent liquidations.

**Liquidity & Sentiment** — write ONE cohesive paragraph:
  Weave all four data points into a positioning story: who is crowded, who got liquidated, whether OI
  confirms conviction or signals exhaustion. Read like a prop desk note, not a data feed recap.
  FORBIDDEN: "Funding is X. OI is Y. Long/short is Z. Liquidations are W." in separate clauses.

**Confluence Summary** — one decisive sentence that fuses structure/VWAP/momentum WITH positioning
  when derivatives matter. Example: "MODERATE — price holds above daily VWAP while short-heavy accounts
  and negative funding provide squeeze fuel into the 4h liquidity pool."

Derivatives shift **Overall Bias** and **If I Were to Trade Today...** when they confirm or fight the
technical read. Crowded + extended = fade risk. Liq cascade + structure break = follow impulse.

═══════════════════════════════════════
RULE 4 — CONVICTION & DISCIPLINE
═══════════════════════════════════════
• **Overall Bias**: Mildly Bullish / Mildly Bearish / Neutral + Confidence %. Side when evidence supports.
  75%+ needs MTF + structure + derivatives alignment. Neutral is discipline, not weakness.
• **Confluence Summary**: EXACTLY one sentence. STRONG / MODERATE / WEAK grade. State the edge plainly.
• WEAK confluence or MTF conflict without catalyst → no TRADE LEVELS. Wait is the veteran call.
• **If I Were to Trade Today...**: Trigger, invalidation, thesis flip. Scalp → "[Long/Short] SCALP Setup:".

═══════════════════════════════════════
RULE 5 — DISCLAIMER (terminal)
═══════════════════════════════════════
{DISCLAIMER}

{scalp_active if scalp_mode else scalp_standby}

═══════════════════════════════════════
REPORT STRUCTURE — EXACT HEADINGS (Flutter — DO NOT rename or reorder)
═══════════════════════════════════════

**Asset**: [COIN] | $[LIVE PRICE] | [24h %]

**Overall Bias**: [Mildly Bullish / Mildly Bearish / Neutral] (Confidence: XX%)

**Key Drivers**:
- Volume-Weighted Analysis: ...
- Liquidity & Sentiment: ...
- Heikin Ashi Analysis: ...
- Fibonacci Retracements: ...
- Technicals: MACD, RSI, EMAs...
- Market Structure: ...

**Confluence Summary**: One decisive, high-conviction sentence.

**If I Were to Trade Today...**
- [Long/Short] Setup: — or [Long/Short] SCALP Setup: when scalping

**Risks & Watchlist**:
- 2-3 bullet points max.

**TRADE LEVELS** (when applicable):
Entry at $XXXXX, TP1 at $XXXXX, TP2 at $XXXXX, SL at $XXXXX (R:R X.X:1)

**Disclaimer**: (exact line above)
"""

    if mode == "tradesetup":
        return (
            shared
            + f"""
═══════════════════════════════════════
MODE: TRADE SETUP — EXECUTE OR DEFEND FLAT
═══════════════════════════════════════
• ONE setup only. Long OR Short per direction constraint. No menus. No "either/or."
• TRADE LEVELS mandatory unless genuinely no ≥{MIN_RR_TP1:.1f}:1 edge — then explain why flat in If I Were to Trade Today.
• Confluence bar: VWAP + structure + momentum + derivatives must justify the call.
• TP1 ≥ {MIN_RR_TP1:.1f}:1 (target {TARGET_RR_TP1:.1f}:1+). TP2 = next structural objective.
• Scalp TF: full SCALP DOCTRINE — surgical, time-boxed, derivatives-filtered.
"""
        )

    return (
        shared
        + f"""
═══════════════════════════════════════
MODE: MARKET ANALYSIS — VERDICT FIRST
═══════════════════════════════════════
• Sharp bias. Explicit edge. Price-accurate throughout. Derivatives integrated.
• TRADE LEVELS only when MODERATE/STRONG confluence AND ≥{MIN_RR_TP1:.1f}:1 R:R exists.
• WEAK or conflicted → no levels. "Wait for clarity" is the veteran call. Discipline beats FOMO.
"""
    )


def default_chat_system_prompt() -> str:
    return f"""You are Oracle Trader AI — elite veteran crypto trader. 15+ years. Millions made. Real capital daily.

Voice: desk orders. Maximum conviction. Zero filler. Flat or fire — no middle ground.

Rules:
• LIVE PRICE is law — never cite stale or guessed prices.
• Minimum {MIN_RR_TP1:.1f}:1 R:R on TP1 (target {TARGET_RR_TP1:.1f}:1+).
• Format: Entry at $X, TP1 at $X, TP2 at $X, SL at $X (R:R X.X:1)
• SCALP / quick move / short-term: surgical best scalp — tight levels, VWAP, momentum, micro invalidation,
  derivatives filter, time-box — or say NO SCALP. Never force.
• Use funding/OI/positioning/liquidations when discussing bias. No N/A — use neutral smart labels.
• Expert Plan depth. No report disclaimer unless asked."""


def normalize_direction(direction: str) -> str:
    value = (direction or "Smart Direction").strip()
    lowered = value.lower()
    if lowered in {"long", "long only"}:
        return "Long Only"
    if lowered in {"short", "short only"}:
        return "Short Only"
    if lowered in {"smart", "smart direction"}:
        return "Smart Direction"
    return value


def direction_instruction(direction: str) -> str:
    if direction == "Long Only":
        return "Force LONG-only. No shorts."
    if direction == "Short Only":
        return "Force SHORT-only. No longs."
    return "Select highest-probability direction (Long or Short) from structure + confluence."


def report_structure_block(*, coin: str, price: float, change_pct: float, mode: str) -> str:
    price_str = format_usd(price)

    if mode == "tradesetup":
        trade_block = """
**TRADE LEVELS** (MANDATORY — exact format, minimum 2.1:1 R:R, target 2.3:1+):
Entry at $XXXXX, TP1 at $XXXXX, TP2 at $XXXXX, SL at $XXXXX (R:R X.X:1)
Reward = |TP1 − Entry| = $X | Risk = |Entry − SL| = $X | R:R = X.X:1
"""
    else:
        trade_block = """
**TRADE LEVELS** (only if ≥2.1:1 R:R setup exists — otherwise omit section):
Entry at $XXXXX, TP1 at $XXXXX, TP2 at $XXXXX, SL at $XXXXX (R:R X.X:1)
Reward = |TP1 − Entry| = $X | Risk = |Entry − SL| = $X | R:R = X.X:1
"""

    return f"""
Use this **exact structure**:

**Asset**: {coin} | {price_str} | {change_pct:+.2f}%

**Overall Bias**: [Mildly Bullish / Mildly Bearish / Neutral] (Confidence: XX%)

**Key Drivers**:
- Volume-Weighted Analysis: ...
- Liquidity & Sentiment: One flowing paragraph — weave live funding, OI, positioning, liquidations into a positioning verdict (not a metric list).
- Heikin Ashi Analysis: ...
- Fibonacci Retracements: ...
- Technicals: MACD, RSI, EMAs...
- Market Structure: ...

**Confluence Summary**: One decisive, high-conviction sentence — grade STRONG / MODERATE / WEAK, state the edge.

**If I Were to Trade Today...**
- [Long/Short] Setup: Professional desk language — trigger, invalidation, thesis flip conditions.
  Examples:
  • "Short on rejection at daily VWAP with bearish RSI divergence"
  • "Long on reclaim and hold of weekly VWAP confluence"
  • "Continuation lower on breakdown below 0.618 Fib with volume"
  • "Favor shorts into previous-week VWAP resistance"

**Risks & Watchlist**:
- 2-3 bullet points max.

{trade_block}

{DISCLAIMER}
"""


def build_analyze_user_prompt(
    *,
    coin: str,
    timeframe: str,
    mode: str,
    direction: str,
    market: dict[str, Any],
    scalp_mode: bool = False,
    derivatives: Optional[dict[str, Any]] = None,
) -> str:
    price = float(market["price"])
    change_pct = float(market["change_24h_pct"])
    price_str = format_usd(price)

    if derivatives is None:
        derivatives = fetch_derivatives_snapshot(coin, spot_price=price)

    volume_text = (
        f"${market['volume_24h_usd']:,.0f}" if market.get("volume_24h_usd") else "Volume light"
    )

    derivatives_block = format_derivatives_prompt_block(derivatives)

    scalp_banner = ""
    if scalp_mode:
        scalp_banner = """
═══ ⚡ SCALP / QUICK-MOVE / SCALPING SETUP — BEST SCALP OR NO SCALP ═══
Deliver the absolute best high-probability scalp: tight entry vs live price, micro SL, named momentum trigger,
session VWAP context, derivatives filter, time-box. Label "[Long/Short] SCALP Setup". TP1 ≥2.1:1 R:R.
If edge is weak → "NO SCALP — STAY FLAT" and omit TRADE LEVELS.
"""

    price_raw = f"{price:.8f}".rstrip("0").rstrip(".")
    max_entry_drift = "0.8%" if scalp_mode else "3%"

    return f"""Generate an elite veteran-grade, high-conviction report for On-Chain Oracle AI.
{scalp_banner}
═══════════════════════════════════════════════════════════
AUTHORITATIVE LIVE PRICE — RULE 0 (ZERO TOLERANCE FOR ERROR)
═══════════════════════════════════════════════════════════
CURRENT LIVE PRICE: {price_str} (raw: {price_raw} USD)
24h CHANGE: {change_pct:+.2f}%
SOURCE: {market.get('source', 'unknown')}

MANDATORY:
• **Asset** line MUST show EXACTLY: {coin.upper()} | {price_str} | {change_pct:+.2f}%
• ALL Entry/TP/SL levels positioned vs {price_str} RIGHT NOW — not historical, not estimated.
• Entry should be within ~{max_entry_drift} of live for {'scalp' if scalp_mode else 'active'} setups unless limit at named structure.
• Verify Long: SL < Entry, TP above Entry. Short: SL > Entry, TP below Entry.

═══ REQUEST CONTEXT ═══
**Asset**: {coin.upper()} | {price_str} | {change_pct:+.2f}%
Timeframe: {timeframe} | Mode: {mode}
Direction: {direction_instruction(direction)}
24h Volume: {volume_text}

{derivatives_block}

═══ VWAP (weave into Key Drivers) ═══
Daily + Previous Day + Weekly + Monthly VWAP. Flag clusters ~0.3–0.8%.

Write like a veteran desk — sharp, decisive, zero filler. Derivatives in prose, not lists. Call the shot.

{report_structure_block(coin=coin.upper(), price=price, change_pct=change_pct, mode=mode)}

End with exact disclaimer only."""


def build_review_system_prompt() -> str:
    return f"""You are On-Chain Oracle AI reviewing a prior analysis or trade setup.

Rules:
- Honest, constructive, professional.
- Use exact section headings for mobile parsing.
- Score line: Score: X/10
- No follow-up questions.
- Final line EXACTLY:
{DISCLAIMER}
"""


def build_review_user_prompt(coin: str, previous_report: str, market: dict[str, Any]) -> str:
    return f"""Review this report for {coin.upper()}.

Previous Report:
{previous_report}

Current Market:
- Price: {format_usd(market['price'])}
- 24h Change: {market['change_24h_pct']:+.2f}%
- Source: {market.get('source', 'unknown')}

**What Got Right**
- bullets

**What Didn't**
- bullets

**Current Status**
- bullets vs original thesis and levels

Score: X/10

Then disclaimer."""


# ---------------------------------------------------------------------------
# FastAPI application
# ---------------------------------------------------------------------------


@asynccontextmanager
async def lifespan(app: FastAPI):
    logger.info("startup | refreshing CoinGecko symbol index")
    refresh_coingecko_symbol_index(force=True)
    if not GROK_API_KEY:
        logger.warning(
            "startup | GROK_API_KEY not set — set Railway Variable GROK_API_KEY "
            "or backend/.env locally; /analyze and /chat will return 500"
        )
    else:
        logger.info("startup | grok_model=%s configured (key present)", GROK_MODEL)
    yield
    logger.info("shutdown")


# redirect_slashes=False — avoids POST /analyze → 307 → /analyze/ (body lost → 404 on clients)
app = FastAPI(
    title="On-Chain Oracle AI API",
    version="2.3.0",
    description="Production backend for the Flutter mobile app",
    lifespan=lifespan,
    redirect_slashes=False,
)

# CORS — Flutter mobile/web; preflight OPTIONS handled by middleware
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=False,
    allow_methods=["GET", "POST", "OPTIONS", "HEAD"],
    allow_headers=["*"],
    expose_headers=["X-Request-ID"],
)


@app.middleware("http")
async def request_logging_middleware(request: Request, call_next):
    request_id = uuid.uuid4().hex[:12]
    request.state.request_id = request_id
    started = time.perf_counter()

    response = await call_next(request)

    elapsed_ms = (time.perf_counter() - started) * 1000
    logger.info(
        "http request_id=%s %s %s status=%s elapsed_ms=%.1f",
        request_id,
        request.method,
        request.url.path,
        response.status_code,
        elapsed_ms,
    )
    response.headers["X-Request-ID"] = request_id
    return response


@app.get("/")
async def root() -> dict[str, Any]:
    """Railway/public root — confirms service is this API (not a static 404 page)."""
    return {
        "service": "On-Chain Oracle AI API",
        "status": "ok",
        "health": "/health",
        "analyze": "POST /analyze (mode=analysis|tradesetup)",
        "trade_setup": "POST /trade-setup (alias)",
    }


@app.get("/health")
async def health() -> dict[str, Any]:
    """Flutter startup ping — includes Grok configuration status."""
    return {
        "status": "ok",
        "version": "2.3.0",
        "grok_configured": bool(GROK_API_KEY),
        "grok_model": GROK_MODEL,
        "routes": {
            "analyze": ["POST /analyze", "POST /analyze/"],
            "trade_setup": [
                "POST /trade-setup",
                "POST /trade_setup",
                "POST /tradesetup",
                "POST /analyze (mode=tradesetup)",
            ],
            "review": ["POST /review"],
            "chat": ["POST /chat"],
        },
    }


@app.get("/coins")
async def list_coins(limit: int = 150) -> dict[str, Any]:
    refresh_coingecko_symbol_index()
    symbols = list(_SYMBOL_TO_COINGECKO_ID.keys())[: max(1, min(limit, 250))]
    return {"success": True, "coins": symbols, "count": len(symbols)}


async def _handle_analyze(
    request: AnalyzeRequest,
    http_request: Request,
    *,
    mode_override: Optional[str] = None,
) -> dict[str, Any]:
    """
    Shared handler for POST /analyze and trade-setup aliases.
    AI prompts, Grok calls, and response JSON shape are unchanged.
    """
    coin = request.coin.strip().upper()
    if not coin:
        raise HTTPException(status_code=400, detail="coin is required.")

    mode = normalize_analyze_mode(mode_override or request.mode)
    if mode not in {"analysis", "tradesetup"}:
        raise HTTPException(
            status_code=400,
            detail="mode must be 'analysis' or 'tradesetup' (aliases: trade-setup, trade_setup).",
        )

    direction = normalize_direction(request.direction)
    market = fetch_market_snapshot(coin)

    scalp_mode = is_scalp_context(
        timeframe=request.timeframe,
        direction=request.direction,
        mode=mode,
        system_prompt=request.system_prompt or "",
    )

    derivatives = fetch_derivatives_snapshot(coin, spot_price=float(market["price"]))

    # Veteran backend prompt is authoritative (Flutter-compatible structure preserved)
    system_prompt = default_system_prompt(mode, scalp_mode=scalp_mode)
    user_prompt = build_analyze_user_prompt(
        coin=coin,
        timeframe=request.timeframe,
        mode=mode,
        direction=direction,
        market=market,
        scalp_mode=scalp_mode,
        derivatives=derivatives,
    )

    req_id = getattr(http_request.state, "request_id", "?")
    logger.info(
        "analyze request_id=%s coin=%s mode=%s tf=%s dir=%s scalp=%s price=%.6f src=%s deriv=%s",
        req_id,
        coin,
        mode,
        request.timeframe,
        direction,
        scalp_mode,
        market["price"],
        market.get("source"),
        derivatives["has_futures_data"],
    )

    report = call_grok(
        system_prompt=system_prompt,
        user_prompt=user_prompt,
        temperature=0.36 if scalp_mode else (0.39 if mode == "analysis" else 0.35),
        max_tokens=1800 if mode == "tradesetup" or scalp_mode else 1580,
    )
    report = ensure_disclaimer(report)
    audit_trade_levels(report, float(market["price"]), scalp_mode=scalp_mode)

    return {
        "success": True,
        "coin": coin,
        "current_price": market["price"],
        "report": report,
    }


@app.post("/analyze")
@app.post("/analyze/")
async def analyze(request: AnalyzeRequest, http_request: Request):
    """Primary Flutter endpoint (Quick Analyze + Trade Setup via mode field)."""
    return await _handle_analyze(request, http_request)


@app.post("/trade-setup")
@app.post("/trade_setup")
@app.post("/tradesetup")
async def trade_setup(request: AnalyzeRequest, http_request: Request):
    """
    Explicit trade-setup routes (fixes 404 if client calls /trade-setup instead of /analyze).
    Same AI logic as POST /analyze with mode=tradesetup.
    """
    return await _handle_analyze(request, http_request, mode_override="tradesetup")


# Optional /api/* aliases (some Railway/proxy configs expose APIs under /api)
@app.post("/api/analyze")
@app.post("/api/analyze/")
async def analyze_api_prefix(request: AnalyzeRequest, http_request: Request):
    return await _handle_analyze(request, http_request)


@app.post("/api/trade-setup")
@app.post("/api/trade_setup")
@app.post("/api/tradesetup")
async def trade_setup_api_prefix(request: AnalyzeRequest, http_request: Request):
    return await _handle_analyze(request, http_request, mode_override="tradesetup")


@app.get("/api/health")
async def health_api_prefix() -> dict[str, Any]:
    return await health()


@app.post("/review")
@app.post("/review/")
async def review(request: ReviewRequest, http_request: Request):
    coin = request.coin.strip().upper()
    if not coin:
        raise HTTPException(status_code=400, detail="coin is required.")

    previous_report = request.previous_report.strip()
    if not previous_report:
        raise HTTPException(status_code=400, detail="previous_report is required.")

    market = fetch_market_snapshot(coin)
    req_id = getattr(http_request.state, "request_id", "?")
    logger.info("review request_id=%s coin=%s price=%.6f", req_id, coin, market["price"])

    review_text = call_grok(
        system_prompt=build_review_system_prompt(),
        user_prompt=build_review_user_prompt(coin, previous_report, market),
        temperature=0.50,
        max_tokens=1150,
    )
    review_text = ensure_disclaimer(review_text)

    return {
        "success": True,
        "coin": coin,
        "current_price": market["price"],
        "review": review_text,
    }


@app.post("/chat")
@app.post("/chat/")
async def chat(request: ChatRequest, http_request: Request):
    message = request.message.strip()
    if not message:
        raise HTTPException(status_code=400, detail="message is required.")

    system_prompt = (request.system_prompt or "").strip() or default_chat_system_prompt()
    history = [{"role": m.role, "content": m.content} for m in request.history]

    req_id = getattr(http_request.state, "request_id", "?")
    logger.info("chat request_id=%s msg_len=%d history=%d", req_id, len(message), len(history))

    reply = call_grok_chat(
        system_prompt=system_prompt,
        history=history,
        message=message,
        temperature=0.55,
        max_tokens=900,
    )

    return {"success": True, "reply": reply}


if __name__ == "__main__":
    uvicorn.run("api:app", host=API_HOST, port=API_PORT, reload=False)
