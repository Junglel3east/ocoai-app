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
  Start: uvicorn api:app --host 0.0.0.0 --port $PORT --timeout-keep-alive 120 --timeout-graceful-shutdown 180

Endpoints (lib/main.dart):
  GET  /health, GET /
  GET  /coins
  POST /analyze   — analysis + trade setup (mode: analysis | tradesetup)
  POST /trade-setup, /trade_setup, /tradesetup — aliases → same handler (mode=tradesetup)
  POST /review    — report performance review
  POST /chat      — Expert Oracle Trader AI chat
  POST /exchange_keys — Oracle Citadel exchange key storage (encrypted secret)
  POST /execute_trade — Oracle Citadel trade execution (Flutter Send to Citadel)

Price chain (analysis): Mobula → CoinGecko (aggressive) → Binance Spot/Futures
Derivatives (/analyze): funding, OI, long/short ratio, liquidations (Binance Futures)
Trade levels format (Oracle Citadel / Flutter parsing):
  Entry at $X, TP1 (40%) at $X, TP2 (60%) at $X, SL at $X (R:R X.X:1)
"""

from __future__ import annotations

import asyncio
import base64
import hashlib
import hmac
import json
import logging
import os
from datetime import datetime, timezone
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
from fastapi.responses import JSONResponse
from pydantic import AliasChoices, BaseModel, ConfigDict, Field, ValidationError, field_validator

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

# Outbound HTTP for prices / CoinGecko (keep relatively short).
REQUEST_TIMEOUT = int(os.getenv("REQUEST_TIMEOUT", "20"))

# Mobula — live price + liquidity (free tier: demo API; production: set MOBULA_API_KEY on Railway)
# Get a key: https://admin.mobula.io — leave empty to use demo-api.mobula.io (rate-limited).
MOBULA_API_KEY = (os.getenv("MOBULA_API_KEY") or "").strip()
MOBULA_API_BASE_URL = os.getenv("MOBULA_API_BASE_URL", "https://api.mobula.io/api/1").rstrip("/")
MOBULA_DEMO_API_BASE_URL = "https://demo-api.mobula.io/api/1"
# Grok HTTP client timeouts (requests tuple: connect, read).
GROK_CONNECT_TIMEOUT = int(os.getenv("GROK_CONNECT_TIMEOUT", "20"))
GROK_TIMEOUT = int(os.getenv("GROK_TIMEOUT", "120"))
# Hard cap for entire Grok call inside async handler (thread pool + wait_for).
ANALYZE_ROUTE_TIMEOUT = int(os.getenv("ANALYZE_ROUTE_TIMEOUT", "180"))
GROK_WORKERS = int(os.getenv("GROK_WORKERS", "4"))
# Uvicorn — long /analyze responses behind Railway proxy (see railway.json startCommand).
UVICORN_TIMEOUT_KEEP_ALIVE = int(os.getenv("UVICORN_TIMEOUT_KEEP_ALIVE", "120"))
UVICORN_TIMEOUT_GRACEFUL_SHUTDOWN = int(os.getenv("UVICORN_TIMEOUT_GRACEFUL_SHUTDOWN", "180"))
API_HOST = os.getenv("API_HOST", "0.0.0.0")
# Railway sets PORT; fall back to API_PORT then 8000 for local `python api.py`
API_PORT = int(os.getenv("PORT", os.getenv("API_PORT", "8000")))

# Oracle Citadel — exchange key storage (encrypted secrets on disk under backend/data/).
CITADEL_ENCRYPTION_KEY = (os.getenv("CITADEL_ENCRYPTION_KEY") or "").strip()
# Mount a Railway volume at /data and set CITADEL_DATA_DIR=/data so keys survive redeploys.
_CITADEL_DATA_DIR = Path(os.getenv("CITADEL_DATA_DIR", str(_BACKEND_DIR / "data")))
_CITADEL_KEYS_FILE = _CITADEL_DATA_DIR / "exchange_keys.json"

# BloFin Open API — demo/testnet uses a separate host from live production.
BLOFIN_DEMO_API_BASE_URL = "https://demo-trading-openapi.blofin.com"
BLOFIN_LIVE_API_BASE_URL = os.getenv(
    "BLOFIN_LIVE_API_BASE_URL",
    "https://openapi.blofin.com",
)
# BloFin trade placement (Oracle Citadel MARKET orders)
BLOFIN_TRADE_ORDER_PATH = "/api/v1/trade/order"
BLOFIN_TRADE_ORDER_TPSL_PATH = "/api/v1/trade/order-tpsl"
BLOFIN_ORDER_DETAIL_PATH = "/api/v1/trade/order-detail"
BLOFIN_ACCOUNT_BALANCE_PATH = "/api/v1/account/balance"
BLOFIN_MARKET_INSTRUMENTS_PATH = "/api/v1/market/instruments"
BLOFIN_MARKET_MARK_PRICE_PATH = "/api/v1/market/mark-price"
BLOFIN_MARKET_TICKERS_PATH = "/api/v1/market/tickers"
BLOFIN_SET_LEVERAGE_PATH = "/api/v1/account/set-leverage"
BLOFIN_DEFAULT_LEVERAGE = 5
BLOFIN_ORDER_SIZE = os.getenv("BLOFIN_ORDER_SIZE", "0.1")
BLOFIN_MARGIN_MODE = os.getenv("BLOFIN_MARGIN_MODE", "cross")
# Oracle Citadel execute_trade — position size ceiling (% of account risked per trade)
EXECUTE_TRADE_MAX_RISK_PERCENT = 100.0
EXECUTE_TRADE_DEFAULT_RISK_PERCENT = 1.0
BLOFIN_POST_ORDER_CONFIRM_DELAY_SEC = 1.5
# MARKET fill confirmation — poll order-detail after placement (fills can lag API orderId).
BLOFIN_MARKET_FILL_CONFIRM_MAX_POLLS = 5
BLOFIN_MARKET_FILL_CONFIRM_POLL_SEC = 0.6
# Passphrase is required by BloFin REST auth; set on Railway or save per-user later.
BLOFIN_PASSPHRASE = (os.getenv("BLOFIN_PASSPHRASE") or os.getenv("CITADEL_BLOFIN_PASSPHRASE") or "").strip()

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

# Blocking Grok/price work off the event loop — prevents Railway proxy stalls.
_GROK_EXECUTOR = ThreadPoolExecutor(max_workers=GROK_WORKERS, thread_name_prefix="oracle-grok")


class GrokError(Exception):
    """Raised when xAI/Grok cannot return a usable completion (caller may use fallback text)."""

    def __init__(
        self,
        message: str,
        *,
        status_code: Optional[int] = None,
        response_body: str = "",
        cause: Optional[BaseException] = None,
    ) -> None:
        super().__init__(message)
        self.user_message = message
        self.status_code = status_code
        self.response_body = response_body
        self.cause = cause


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
    user_id: Optional[str] = Field(None, max_length=128)


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


class ExchangeKeysRequest(BaseModel):
    """
    Oracle Citadel key link — matches Flutter (api_key/api_secret) and explicit names.
    App API key may also be sent via X-API-Key header.
    """

    model_config = ConfigDict(extra="ignore", populate_by_name=True)

    user_id: str = Field(..., min_length=1, max_length=128)
    app_api_key: Optional[str] = Field(
        None,
        max_length=512,
        validation_alias=AliasChoices("app_api_key", "app_key"),
    )
    exchange_api_key: str = Field(
        ...,
        min_length=1,
        max_length=512,
        validation_alias=AliasChoices("exchange_api_key", "api_key", "exchange_key"),
    )
    exchange_secret: str = Field(
        ...,
        min_length=1,
        max_length=512,
        validation_alias=AliasChoices("exchange_secret", "api_secret", "exchange_secret_key"),
    )
    risk_percent: float = Field(1.0, ge=0.1, le=100.0)
    # Optional exchange id (e.g. "blofin", "coinbase"). Demo URL only for BloFin + use_demo_mode.
    exchange: Optional[str] = Field(None, max_length=64)
    use_demo_mode: bool = Field(
        False,
        validation_alias=AliasChoices("use_demo_mode", "demo_mode"),
    )

    @field_validator("user_id", "exchange_api_key", "exchange_secret", mode="before")
    @classmethod
    def _strip_required_strings(cls, value: Any) -> Any:
        if isinstance(value, str):
            return value.strip()
        return value

    @field_validator("app_api_key", mode="before")
    @classmethod
    def _strip_optional_app_key(cls, value: Any) -> Any:
        if value is None:
            return None
        if isinstance(value, str):
            return value.strip() or None
        return value

    @field_validator("exchange", mode="before")
    @classmethod
    def _strip_optional_exchange(cls, value: Any) -> Any:
        if value is None:
            return None
        if isinstance(value, str):
            return value.strip().lower() or None
        return value


class ExecuteTradeRequest(BaseModel):
    """
    Oracle Citadel trade execution — MARKET only (BloFin).
    """

    model_config = ConfigDict(extra="ignore", populate_by_name=True)

    user_id: str = Field(..., min_length=1, max_length=128)
    coin: str = Field(..., min_length=1, max_length=32)
    direction: str = Field(..., min_length=1, max_length=16)
    entry_price: float = Field(..., gt=0, validation_alias=AliasChoices("entry_price", "entry"))
    stop_loss: float = Field(..., gt=0, validation_alias=AliasChoices("stop_loss", "sl"))
    tp1: float = Field(..., gt=0)
    tp2: float = Field(..., gt=0)
    risk_percent: float = Field(1.0, ge=0.1, le=100.0)
    leverage: float = Field(float(BLOFIN_DEFAULT_LEVERAGE), ge=1.0, le=100.0)
    order_type: str = Field("market", max_length=16)

    @field_validator("user_id", "coin", "direction", mode="before")
    @classmethod
    def _strip_trade_strings(cls, value: Any) -> Any:
        if isinstance(value, str):
            return value.strip()
        return value

    @field_validator("coin", mode="after")
    @classmethod
    def _upper_coin(cls, value: str) -> str:
        return value.upper()

    @field_validator("direction", mode="after")
    @classmethod
    def _normalize_direction(cls, value: str) -> str:
        lower = value.lower()
        if lower in {"long", "buy"}:
            return "long"
        if lower in {"short", "sell"}:
            return "short"
        raise ValueError("direction must be long or short")

    @field_validator("order_type", mode="before")
    @classmethod
    def _normalize_order_type(cls, value: Any) -> str:
        return "market"


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
# Market data — Mobula (primary for /analyze) → CoinGecko → Binance
# ---------------------------------------------------------------------------


def _mobula_request_base() -> str:
    """Production API when key is set; otherwise Mobula demo (free tier, rate-limited)."""
    return MOBULA_API_BASE_URL if MOBULA_API_KEY else MOBULA_DEMO_API_BASE_URL


def fetch_mobula_price(coin: str) -> Optional[dict[str, Any]]:
    """
    Mobula /market/data — depth-weighted price, liquidity, on-chain + off-chain volume.
    https://api.mobula.io/api/1/market/data?symbol=BTC&shouldFetchPriceChange=24h
    """
    upper = (coin or "").strip().upper()
    if not upper:
        return None

    base = _mobula_request_base()
    url = f"{base}/market/data"
    params = {"symbol": upper, "shouldFetchPriceChange": "24h"}
    headers: dict[str, str] = {"Accept": "application/json"}
    if MOBULA_API_KEY:
        headers["Authorization"] = MOBULA_API_KEY

    try:
        started = time.perf_counter()
        response = requests.get(
            url,
            params=params,
            headers=headers,
            timeout=REQUEST_TIMEOUT,
        )
        elapsed_ms = (time.perf_counter() - started) * 1000
        if response.status_code != 200:
            logger.warning(
                "mobula_price_http coin=%s status=%s elapsed_ms=%.0f base=%s",
                upper,
                response.status_code,
                elapsed_ms,
                base,
            )
            return None

        payload = response.json()
        data = payload.get("data") if isinstance(payload, dict) else None
        if not isinstance(data, dict):
            logger.warning("mobula_price_no_data coin=%s elapsed_ms=%.0f", upper, elapsed_ms)
            return None

        price = float(data.get("price") or 0)
        if price <= 0:
            return None

        change_24h = float(data.get("price_change_24h") or 0)
        on_chain_vol = float(data.get("volume") or 0)
        off_chain_vol = float(data.get("off_chain_volume") or 0)
        liquidity = float(data.get("liquidity") or 0)
        liquidity_max = float(data.get("liquidityMax") or 0)
        market_cap = float(data.get("market_cap") or 0)

        logger.info(
            "mobula_price_ok coin=%s price=%.6f change_24h=%.2f liquidity=%.0f "
            "on_chain_vol=%.0f off_chain_vol=%.0f elapsed_ms=%.0f",
            upper,
            price,
            change_24h,
            liquidity,
            on_chain_vol,
            off_chain_vol,
            elapsed_ms,
        )

        return {
            "price": price,
            "change_24h_pct": change_24h,
            "volume_24h_usd": on_chain_vol + off_chain_vol if (on_chain_vol or off_chain_vol) else on_chain_vol,
            "liquidity_usd": liquidity,
            "liquidity_max_usd": liquidity_max,
            "market_cap_usd": market_cap,
            "on_chain_volume_usd": on_chain_vol,
            "off_chain_volume_usd": off_chain_vol,
            "source": "mobula",
            "mobula_name": data.get("name"),
            "mobula_rank": data.get("rank"),
            "price_change_1h": data.get("price_change_1h"),
            "price_change_7d": data.get("price_change_7d"),
        }
    except Exception as exc:
        logger.warning("mobula_price_error coin=%s err=%s", upper, exc)
        return None


def format_mobula_market_prompt_block(market: dict[str, Any]) -> str:
    """Rich Mobula context for Grok — liquidity, volume split, on-chain vs CEX (analyze/trade-setup)."""
    if market.get("source") != "mobula":
        return ""

    liq = market.get("liquidity_usd")
    liq_max = market.get("liquidity_max_usd")
    mcap = market.get("market_cap_usd")
    on_vol = market.get("on_chain_volume_usd")
    off_vol = market.get("off_chain_volume_usd")
    ch1h = market.get("price_change_1h")
    ch7d = market.get("price_change_7d")
    rank = market.get("mobula_rank")
    name = market.get("mobula_name") or market.get("coin", "")

    def _usd(val: Any) -> str:
        try:
            v = float(val)
        except (TypeError, ValueError):
            return "n/a"
        if v >= 1e9:
            return f"${v / 1e9:.2f}B"
        if v >= 1e6:
            return f"${v / 1e6:.1f}M"
        if v >= 1e3:
            return f"${v / 1e3:.1f}K"
        return format_usd(v)

    def _pct(part: float, whole: float) -> str:
        if whole <= 0:
            return "n/a"
        return f"{100.0 * part / whole:.0f}%"

    on_f = float(on_vol or 0)
    off_f = float(off_vol or 0)
    vol_total = on_f + off_f
    vol_mix = ""
    if vol_total > 0:
        vol_mix = (
            f"Volume mix: {_pct(on_f, vol_total)} on-chain / {_pct(off_f, vol_total)} off-chain (CEX) — "
        )
        if on_f > off_f * 1.25:
            vol_mix += "spot/DEX-led flow; treat perp squeezes as secondary until CEX confirms."
        elif off_f > on_f * 1.25:
            vol_mix += "CEX/perp-led flow; weight funding, OI, and liqs heavily in **Liquidity & Sentiment**."
        else:
            vol_mix += "balanced flow; require derivatives + structure alignment before sizing up."

    liq_f = float(liq or 0)
    liq_read = ""
    if liq_f > 0 and vol_total > 0:
        liq_to_vol = liq_f / vol_total
        if liq_to_vol < 0.05:
            liq_read = "Thin liquidity vs volume — slippage and stop-run risk elevated; favor limits at OB/FVG."
        elif liq_to_vol > 0.35:
            liq_read = "Deep pool liquidity vs volume — cleaner mean-reversion at VWAP; breakouts need volume confirmation."
        else:
            liq_read = "Moderate liquidity depth — standard execution; watch sweep-and-reject at pools."

    lines = [
        "═══ MOBULA LIVE MARKET — AUTHORITATIVE ON-CHAIN + LIQUIDITY (MUST DRIVE THE REPORT) ═══",
        f"Asset: {name} | Depth-weighted live price already in RULE 0 block above",
        f"DEX liquidity (pools): {_usd(liq)} | Max pool liquidity: {_usd(liq_max)}",
        f"Market cap: {_usd(mcap)}" + (f" | Mobula rank: #{rank}" if rank else ""),
        f"24h volume — on-chain: {_usd(on_vol)} | off-chain (CEX): {_usd(off_vol)} | total: {_usd(vol_total)}",
    ]
    if vol_mix:
        lines.append(vol_mix)
    if liq_read:
        lines.append(f"Liquidity read: {liq_read}")
    if ch1h is not None:
        try:
            lines.append(f"Mobula momentum: 1h {float(ch1h):+.2f}% | 7d {float(ch7d or 0):+.2f}%")
        except (TypeError, ValueError):
            pass
    lines.extend(
        [
            "MANDATORY MOBULA USAGE (non-negotiable):",
            "• **Volume-Weighted Analysis** — cite Daily VWAP vs live price AND whether flow is on-chain-led or CEX-led.",
            "• **Liquidity & Sentiment** — open with liquidity/slippage/trap read from Mobula, then fuse derivatives.",
            "• **Overall Bias** / **Confluence Summary** / **If I Were to Trade Today...** — price Mobula into the verdict.",
            "• Do NOT dump raw numbers; translate into edge (trap risk, chase risk, squeeze fuel, stand-aside).",
        ]
    )
    return "\n".join(lines) + "\n\n"


def format_market_data_fallback_note(market: dict[str, Any]) -> str:
    """When Mobula misses, tell the model not to invent on-chain stats."""
    if market.get("source") in {"mobula", "blofin", "blofin_demo"}:
        return ""
    return (
        "═══ ON-CHAIN / MOBULA ═══\n"
        "Mobula live feed unavailable for this tick — do NOT invent DEX liquidity or on-chain volume. "
        "Infer liquidity from structure + Binance derivatives only; state 'on-chain depth unverified' once in "
        "**Liquidity & Sentiment** if relevant.\n\n"
    )


# ---------------------------------------------------------------------------
# Binance Spot / Futures + CoinGecko (fallbacks)
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


def fetch_coingecko_market(
    symbol: str,
    *,
    no_cache: bool = False,
    cache_bust_ms: Optional[int] = None,
) -> Optional[dict[str, Any]]:
    coin_id = resolve_coingecko_id(symbol)
    if not coin_id:
        return None

    try:
        # Aggressive cache-bust: headers + unique query param per request (proxies/CDNs)
        headers: dict[str, str] = {}
        if no_cache:
            headers = {
                "Cache-Control": "no-cache, no-store, must-revalidate",
                "Pragma": "no-cache",
                "Expires": "0",
            }
        params: dict[str, str] = {
            "ids": coin_id,
            "vs_currencies": "usd",
            "include_24hr_change": "true",
            "include_24hr_vol": "true",
        }
        if no_cache:
            params["_"] = str(cache_bust_ms or int(time.time() * 1000))

        response = requests.get(
            "https://api.coingecko.com/api/v3/simple/price",
            params=params,
            headers=headers,
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


def fetch_coingecko_market_aggressive(symbol: str) -> Optional[dict[str, Any]]:
    """
    Two back-to-back cache-busted CoinGecko pulls; returns the latest successful tick.
    Called immediately before Grok (analysis + trade setup) — not cached from earlier requests.
    """
    upper = symbol.upper()
    last: Optional[dict[str, Any]] = None
    base_ms = int(time.time() * 1000)
    for attempt in range(2):
        snap = fetch_coingecko_market(upper, no_cache=True, cache_bust_ms=base_ms + attempt)
        if snap:
            last = snap
    return last


def _citadel_blofin_linked_record(user_id: Optional[str]) -> Optional[dict[str, Any]]:
    """Return saved Citadel record when user has BloFin exchange keys linked."""
    uid = (user_id or "").strip()
    if not uid:
        return None
    record = get_citadel_user_record(uid)
    if not record or not record.get("exchange_api_key"):
        return None
    exchange = str(record.get("exchange") or "").lower()
    api_base = str(record.get("api_base_url") or "").lower()
    if (
        "blofin" in exchange
        or bool(record.get("use_demo_mode"))
        or "blofin" in api_base
        or exchange in ("", "unspecified")
    ):
        return record
    return None


def fetch_blofin_live_price(
    coin: str,
    *,
    api_base_url: Optional[str] = None,
    demo: bool = False,
) -> Optional[dict[str, Any]]:
    """
    Public BloFin mark price (+ optional 24h change from tickers) for AI + UI.
    No auth required — uses user's linked demo/live host when provided.
    """
    upper = (coin or "").strip().upper()
    if not upper:
        return None

    inst_id = upper if "-" in upper else f"{upper}-USDT"
    base = (api_base_url or BLOFIN_LIVE_API_BASE_URL).rstrip("/")
    source = "blofin_demo" if demo else "blofin"

    mark_price: Optional[float] = None
    index_price: Optional[float] = None
    change_24h_pct = 0.0

    try:
        mark_resp = requests.get(
            f"{base}{BLOFIN_MARKET_MARK_PRICE_PATH}",
            params={"instId": inst_id},
            timeout=REQUEST_TIMEOUT,
        )
        if mark_resp.status_code == 200:
            payload = mark_resp.json()
            rows = payload.get("data") if isinstance(payload, dict) else None
            if isinstance(rows, list) and rows and isinstance(rows[0], dict):
                row = rows[0]
                mark_price = _parse_blofin_price_token(row.get("markPrice"))
                index_price = _parse_blofin_price_token(row.get("indexPrice"))
    except Exception as exc:
        logger.warning("blofin_mark_price_error coin=%s inst=%s err=%s", upper, inst_id, exc)

    try:
        tick_resp = requests.get(
            f"{base}{BLOFIN_MARKET_TICKERS_PATH}",
            params={"instId": inst_id},
            timeout=REQUEST_TIMEOUT,
        )
        if tick_resp.status_code == 200:
            payload = tick_resp.json()
            rows = payload.get("data") if isinstance(payload, dict) else None
            if isinstance(rows, list) and rows and isinstance(rows[0], dict):
                row = rows[0]
                if mark_price is None:
                    mark_price = _parse_blofin_price_token(row.get("last"))
                open_24h = _parse_blofin_price_token(row.get("open24h"))
                last_px = _parse_blofin_price_token(row.get("last")) or mark_price
                if open_24h and last_px:
                    change_24h_pct = (last_px - open_24h) / open_24h * 100.0
    except Exception as exc:
        logger.warning("blofin_ticker_error coin=%s inst=%s err=%s", upper, inst_id, exc)

    if mark_price is None or mark_price <= 0:
        logger.warning("blofin_live_price_miss coin=%s inst=%s base=%s", upper, inst_id, base)
        return None

    logger.info(
        "blofin_live_price_ok coin=%s inst=%s price=%.6f change_24h=%.2f source=%s base=%s",
        upper,
        inst_id,
        mark_price,
        change_24h_pct,
        source,
        base,
    )
    return {
        "price": mark_price,
        "change_24h_pct": change_24h_pct,
        "volume_24h_usd": None,
        "source": source,
        "blofin_inst_id": inst_id,
        "blofin_mark_price": mark_price,
        "blofin_index_price": index_price,
    }


def fetch_live_price_for_analysis(coin: str, user_id: Optional[str] = None) -> dict[str, Any]:
    """
    Fresh price for AI analysis/trade setup: BloFin (when user linked), then Mobula,
    CoinGecko (aggressive), then Binance.
    Does not change prompts or report section format — only enriches market context when Mobula hits.
    """
    upper = coin.upper()
    refresh_coingecko_symbol_index(force=True)

    fetched_at = time.time()

    blofin_record = _citadel_blofin_linked_record(user_id)
    if blofin_record:
        blofin = fetch_blofin_live_price(
            upper,
            api_base_url=blofin_record.get("api_base_url"),
            demo=bool(
                blofin_record.get("use_demo_mode")
                or blofin_record.get("environment") == "demo"
            ),
        )
        if blofin:
            age_ms = (time.time() - fetched_at) * 1000
            logger.info(
                "live_price_for_ai coin=%s source=%s price=%.6f age_ms=%.0f",
                upper,
                blofin["source"],
                blofin["price"],
                age_ms,
            )
            return {"coin": upper, "fetched_at": fetched_at, **blofin}

        logger.warning(
            "live_price_for_ai coin=%s blofin_miss user=%s — falling back to mobula/coingecko",
            upper,
            (user_id or "")[:16],
        )

    mobula = fetch_mobula_price(upper)
    if mobula:
        age_ms = (time.time() - fetched_at) * 1000
        logger.info(
            "live_price_for_ai coin=%s source=mobula price=%.6f liquidity=%.0f age_ms=%.0f",
            upper,
            mobula["price"],
            mobula.get("liquidity_usd") or 0,
            age_ms,
        )
        return {"coin": upper, "fetched_at": fetched_at, **mobula}

    logger.warning("live_price_for_ai coin=%s mobula_miss — trying coingecko", upper)
    snapshot = fetch_coingecko_market_aggressive(upper)
    if snapshot:
        age_ms = (time.time() - fetched_at) * 1000
        logger.info(
            "live_price_for_ai coin=%s source=coingecko price=%.6f age_ms=%.0f",
            upper,
            snapshot["price"],
            age_ms,
        )
        return {"coin": upper, "fetched_at": fetched_at, **snapshot}

    logger.warning("live_price_for_ai coin=%s coingecko_miss — falling back to binance", upper)
    symbol = binance_usdt_symbol(coin)
    for fetcher in (fetch_binance_spot, fetch_binance_futures):
        snap = fetcher(symbol)
        if snap:
            logger.info(
                "live_price_for_ai coin=%s source=%s price=%.6f",
                upper,
                snap["source"],
                snap["price"],
            )
            return {"coin": upper, "fetched_at": time.time(), **snap}

    raise HTTPException(
        status_code=502,
        detail=f"Unable to fetch a live price for {upper}. Try a major USDT-listed symbol.",
    )


def fetch_market_snapshot(coin: str) -> dict[str, Any]:
    """General price lookup (review, etc.). Analysis/trade setup uses fetch_live_price_for_analysis."""
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
        return f"Longs crowded — funding +{rate_pct:.4f}% (counter-long risk)"
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

    return f"""═══ LIVE DERIVATIVES — BINANCE FUTURES (leverage positioning read; NEVER list as four sentences) ═══
Funding: {funding_val} → {derivatives['funding_label']}
Open Interest: {oi_val} → {derivatives['oi_label']}
Long/Short accounts (5m): {ls_val} → {derivatives['ls_label']}
Recent liquidations: {liq_val} → {derivatives['liq_label']}

TRADER INSTRUCTION — synthesize into **Liquidity & Sentiment** as ONE story:
• Who is paying whom (funding)? Is OI rising with trend (conviction) or against it (shorts/longs adding)?
• Are accounts lopsided (L/S) into a level where stops cluster? Did liqs mark exhaustion or fuel continuation?
• Map to order flow: squeeze setup, cascade risk, counter crowded extension, liquidity grab, or stand aside until reset.
• Good: "Shorts are paying to hold the book while OI bleeds off the highs — long liqs already printed;
  only short breakdown while Daily VWAP caps."
• Bad: four separate clauses restating each metric.
• **Confluence Summary**, **Overall Bias**, and **If I Were to Trade Today...** must price this in.
• If MOBULA block is above: derivatives confirm or fight the on-chain/liquidity read — say which wins.
• Never write "N/A" or "unavailable" in the report — translate gaps into neutral positioning language."""


def format_usd(price: float) -> str:
    if price >= 1000:
        return f"${price:,.0f}"
    if price >= 1:
        return f"${price:,.2f}"
    if price >= 0.01:
        return f"${price:,.4f}"
    return f"${price:,.6f}"


# ---------------------------------------------------------------------------
# Trade level parsing (Oracle Citadel / Flutter) — extraction only, not AI prompts
# ---------------------------------------------------------------------------

_LEVEL_LABELS = {
    "entry": "Entry",
    "tp1": "TP1",
    "tp2": "TP2",
    "sl": "Stop Loss",
}

# Canonical one-liner from trade-setup prompts (order may vary slightly in text).
_CANONICAL_TRADE_LEVELS_RE = re.compile(
    r"entry\s+at\s+\$?\s*([0-9][0-9,]*(?:\.[0-9]+)?)"
    r".{0,120}?tp\s*[-_]?\s*1\s*(?:\(\s*40\s*%?\s*(?:\s+of\s+position)?\s*\))?\s+at\s+\$?\s*([0-9][0-9,]*(?:\.[0-9]+)?)"
    r".{0,120}?tp\s*[-_]?\s*2\s*(?:\(\s*60\s*%?\s*(?:\s+of\s+position)?\s*\))?\s+at\s+\$?\s*([0-9][0-9,]*(?:\.[0-9]+)?)"
    r".{0,120}?s(?:top\s*[-_]?\s*loss|l)\s+at\s+\$?\s*([0-9][0-9,]*(?:\.[0-9]+)?)",
    re.IGNORECASE | re.DOTALL,
)

# Alternate ordering: SL before Entry, etc.
_CANONICAL_TRADE_LEVELS_ALT_RE = re.compile(
    r"tp\s*[-_]?\s*1\s*(?:\(\s*40\s*%?\s*(?:\s+of\s+position)?\s*\))?\s+at\s+\$?\s*([0-9][0-9,]*(?:\.[0-9]+)?)"
    r".{0,120}?tp\s*[-_]?\s*2\s*(?:\(\s*60\s*%?\s*(?:\s+of\s+position)?\s*\))?\s+at\s+\$?\s*([0-9][0-9,]*(?:\.[0-9]+)?)"
    r".{0,120}?s(?:top\s*[-_]?\s*loss|l)\s+at\s+\$?\s*([0-9][0-9,]*(?:\.[0-9]+)?)"
    r".{0,120}?entry\s+at\s+\$?\s*([0-9][0-9,]*(?:\.[0-9]+)?)",
    re.IGNORECASE | re.DOTALL,
)

# Per-field fallback patterns — tried in order until a price is found.
_LEVEL_FIELD_PATTERNS: dict[str, list[re.Pattern[str]]] = {
    "entry": [
        re.compile(
            r"(?:^|[\n\r\*\-])\s*entry(?:\s+price|\s+zone|\s+level)?\s*(?:at|@|:|is|=|-)?\s*\$?\s*"
            r"([0-9][0-9,]*(?:\.[0-9]+)?)",
            re.IGNORECASE | re.MULTILINE,
        ),
        re.compile(r"entry\s*[=:]\s*\$?\s*([0-9][0-9,]*(?:\.[0-9]+)?)", re.IGNORECASE),
        re.compile(r"buy\s+(?:at|@|:)\s*\$?\s*([0-9][0-9,]*(?:\.[0-9]+)?)", re.IGNORECASE),
    ],
    "tp1": [
        re.compile(
            r"tp\s*[-_]?\s*1\s*(?:\(\s*40\s*%?\s*(?:\s+of\s+position)?\s*\))?\s*(?:at|@|:|is|=|-)?\s*\$?\s*"
            r"([0-9][0-9,]*(?:\.[0-9]+)?)",
            re.IGNORECASE,
        ),
        re.compile(
            r"take\s*[-_]?\s*profit\s*[-_]?\s*1\s*(?:at|@|:|is|=|-)?\s*\$?\s*([0-9][0-9,]*(?:\.[0-9]+)?)",
            re.IGNORECASE,
        ),
        re.compile(
            r"target\s*[-_]?\s*1\s*(?:at|@|:|is|=|-)?\s*\$?\s*([0-9][0-9,]*(?:\.[0-9]+)?)",
            re.IGNORECASE,
        ),
        re.compile(r"t\.?p\.?\s*1\s*[=:]\s*\$?\s*([0-9][0-9,]*(?:\.[0-9]+)?)", re.IGNORECASE),
    ],
    "tp2": [
        re.compile(
            r"tp\s*[-_]?\s*2\s*(?:\(\s*60\s*%?\s*(?:\s+of\s+position)?\s*\))?\s*(?:at|@|:|is|=|-)?\s*\$?\s*"
            r"([0-9][0-9,]*(?:\.[0-9]+)?)",
            re.IGNORECASE,
        ),
        re.compile(
            r"take\s*[-_]?\s*profit\s*[-_]?\s*2\s*(?:at|@|:|is|=|-)?\s*\$?\s*([0-9][0-9,]*(?:\.[0-9]+)?)",
            re.IGNORECASE,
        ),
        re.compile(
            r"target\s*[-_]?\s*2\s*(?:at|@|:|is|=|-)?\s*\$?\s*([0-9][0-9,]*(?:\.[0-9]+)?)",
            re.IGNORECASE,
        ),
        re.compile(r"t\.?p\.?\s*2\s*[=:]\s*\$?\s*([0-9][0-9,]*(?:\.[0-9]+)?)", re.IGNORECASE),
    ],
    "sl": [
        re.compile(
            r"s(?:top\s*[-_]?\s*loss|l)\s*(?:at|@|:|is|=|-)?\s*\$?\s*([0-9][0-9,]*(?:\.[0-9]+)?)",
            re.IGNORECASE,
        ),
        re.compile(
            r"stop\s*[-_]?\s*loss\s*(?:at|@|:|is|=|-)?\s*\$?\s*([0-9][0-9,]*(?:\.[0-9]+)?)",
            re.IGNORECASE,
        ),
        re.compile(r"invalidation\s*(?:at|@|:|is|=|-)?\s*\$?\s*([0-9][0-9,]*(?:\.[0-9]+)?)", re.IGNORECASE),
    ],
}

_RR_TEXT_PATTERNS = [
    re.compile(
        r"(?:r\s*:?\s*r|risk\s*[-:]?\s*reward)\s*(?:ratio)?\s*[:=]?\s*([0-9]+(?:\.[0-9]+)?)\s*:?\s*1",
        re.IGNORECASE,
    ),
    re.compile(r"reward\s*[-:]\s*risk\s*[:=]?\s*([0-9]+(?:\.[0-9]+)?)", re.IGNORECASE),
]


def _normalize_report_for_parsing(report: str) -> str:
    """Strip markdown emphasis so **Entry** and Entry parse the same."""
    text = report or ""
    text = re.sub(r"\*+", "", text)
    text = text.replace("—", "-").replace("–", "-")
    return text


def _parse_price_token(raw: str) -> Optional[float]:
    if not raw:
        return None
    cleaned = raw.strip().replace(",", "").replace(" ", "")
    cleaned = re.sub(r"[^\d.]+$", "", cleaned)
    try:
        value = float(cleaned)
    except ValueError:
        return None
    return value if value > 0 else None


def _first_match_price(patterns: list[re.Pattern[str]], text: str) -> Optional[float]:
    for pattern in patterns:
        match = pattern.search(text)
        if match:
            price = _parse_price_token(match.group(1))
            if price is not None:
                return price
    return None


def parse_trade_levels(report: str) -> dict[str, Optional[float]]:
    """
    Extract Entry, TP1, TP2, SL, and R:R from AI report text.
    Does not change prompts — only tolerates wording/format variation.
    """
    text = _normalize_report_for_parsing(report)
    levels: dict[str, Optional[float]] = {
        "entry": None,
        "tp1": None,
        "tp2": None,
        "sl": None,
        "rr": None,
    }

    canonical = _CANONICAL_TRADE_LEVELS_RE.search(text)
    if canonical:
        levels["entry"] = _parse_price_token(canonical.group(1))
        levels["tp1"] = _parse_price_token(canonical.group(2))
        levels["tp2"] = _parse_price_token(canonical.group(3))
        levels["sl"] = _parse_price_token(canonical.group(4))
    else:
        alt = _CANONICAL_TRADE_LEVELS_ALT_RE.search(text)
        if alt:
            levels["tp1"] = _parse_price_token(alt.group(1))
            levels["tp2"] = _parse_price_token(alt.group(2))
            levels["sl"] = _parse_price_token(alt.group(3))
            levels["entry"] = _parse_price_token(alt.group(4))

    for field, patterns in _LEVEL_FIELD_PATTERNS.items():
        if levels[field] is not None:
            continue
        levels[field] = _first_match_price(patterns, text)

    for pattern in _RR_TEXT_PATTERNS:
        match = pattern.search(text)
        if match:
            levels["rr"] = _parse_price_token(match.group(1))
            break

    entry, tp1, sl = levels["entry"], levels["tp1"], levels["sl"]
    if levels["rr"] is None and entry is not None and tp1 is not None and sl is not None:
        levels["rr"] = compute_rr(entry, tp1, sl)

    return levels


def missing_trade_level_labels(levels: dict[str, Optional[float]]) -> list[str]:
    """Human-readable list of levels still missing after parsing."""
    required = ("entry", "tp1", "tp2", "sl")
    return [_LEVEL_LABELS[key] for key in required if levels.get(key) is None]


def trade_levels_error_message(levels: dict[str, Optional[float]]) -> Optional[str]:
    """Clear Citadel-facing error when parsing failed."""
    missing = missing_trade_level_labels(levels)
    if not missing:
        return None
    return (
        f"Could not parse {', '.join(missing)} from this report. "
        "Include a TRADE LEVELS line: Entry at $X, TP1 (40%) at $X, TP2 (60%) at $X, SL at $X (R:R X.X:1)."
    )


def compute_rr(entry: float, tp1: float, sl: float) -> Optional[float]:
    risk = abs(entry - sl)
    reward = abs(tp1 - entry)
    if risk <= 0:
        return None
    return reward / risk


def audit_trade_levels(report: str, live_price: float, *, scalp_mode: bool = False) -> None:
    levels = parse_trade_levels(report)
    missing = missing_trade_level_labels(levels)
    if missing:
        logger.warning(
            "trade_levels_incomplete missing=%s parsed=%s",
            ",".join(missing),
            {k: levels.get(k) for k in ("entry", "tp1", "tp2", "sl", "rr")},
        )
        return

    entry, tp1, tp2, sl = levels["entry"], levels["tp1"], levels["tp2"], levels["sl"]
    rr = levels.get("rr") or compute_rr(entry, tp1, sl)
    if rr is not None:
        if rr < MIN_RR_TP1:
            logger.warning(
                "rr_below_floor rr=%.2f floor=%.1f entry=%s tp1=%s tp2=%s sl=%s",
                rr,
                MIN_RR_TP1,
                entry,
                tp1,
                tp2,
                sl,
            )
        else:
            logger.info(
                "rr_ok rr=%.2f entry=%s tp1=%s tp2=%s sl=%s",
                rr,
                entry,
                tp1,
                tp2,
                sl,
            )

    if live_price > 0 and entry is not None:
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
# Oracle Citadel — exchange keys (encrypted at rest)
# ---------------------------------------------------------------------------


def _citadel_encryption_key_bytes(*, salt: bytes = b"") -> bytes:
    """32-byte key derived from CITADEL_ENCRYPTION_KEY (set on Railway for production)."""
    seed = CITADEL_ENCRYPTION_KEY or "oracle-citadel-dev-only-change-in-production"
    material = seed.encode("utf-8") + salt
    return hashlib.sha256(material).digest()


def encrypt_secret_at_rest(plaintext: str) -> str:
    """
    Encrypt exchange secret for disk storage (PBKDF2-derived key + per-record salt + XOR).
    Prefix enc2: distinguishes new records from legacy enc1/xor-only blobs.
    """
    if not plaintext:
        raise ValueError("exchange_secret is empty")
    salt = os.urandom(16)
    key = _citadel_encryption_key_bytes(salt=salt)
    data = plaintext.encode("utf-8")
    xored = bytes(b ^ key[i % len(key)] for i, b in enumerate(data))
    payload = base64.b64encode(xored).decode("ascii")
    salt_b64 = base64.b64encode(salt).decode("ascii")
    return f"enc2:{salt_b64}:{payload}"


def decrypt_secret_at_rest(ciphertext: str) -> Optional[str]:
    """Decrypt stored secret for post-save verification (never log plaintext)."""
    if not ciphertext:
        return None
    try:
        if ciphertext.startswith("enc2:"):
            _, salt_b64, payload = ciphertext.split(":", 2)
            salt = base64.b64decode(salt_b64.encode("ascii"))
            key = _citadel_encryption_key_bytes(salt=salt)
            xored = base64.b64decode(payload.encode("ascii"))
            plain = bytes(b ^ key[i % len(key)] for i, b in enumerate(xored))
            return plain.decode("utf-8")
        # Legacy: bare base64 XOR with global key only
        key = _citadel_encryption_key_bytes()
        xored = base64.b64decode(ciphertext.encode("ascii"))
        plain = bytes(b ^ key[i % len(key)] for i, b in enumerate(xored))
        return plain.decode("utf-8")
    except (ValueError, OSError, UnicodeDecodeError) as exc:
        logger.error("citadel_secret_decrypt_failed err=%s", exc)
        return None


def _load_citadel_key_store() -> dict[str, Any]:
    if not _CITADEL_KEYS_FILE.is_file():
        return {}
    try:
        raw = json.loads(_CITADEL_KEYS_FILE.read_text(encoding="utf-8"))
        return raw if isinstance(raw, dict) else {}
    except (OSError, json.JSONDecodeError) as exc:
        logger.error("citadel_store_read_failed path=%s err=%s", _CITADEL_KEYS_FILE, exc)
        return {}


def _save_citadel_key_store(store: dict[str, Any]) -> None:
    _CITADEL_DATA_DIR.mkdir(parents=True, exist_ok=True)
    tmp = _CITADEL_KEYS_FILE.with_suffix(".json.tmp")
    payload = json.dumps(store, indent=2)
    tmp.write_text(payload, encoding="utf-8")
    tmp.replace(_CITADEL_KEYS_FILE)
    if not _CITADEL_KEYS_FILE.is_file():
        raise OSError(f"citadel key file missing after write: {_CITADEL_KEYS_FILE}")


def resolve_citadel_exchange_profile(
    exchange: Optional[str],
    use_demo_mode: bool,
) -> dict[str, Any]:
    """
    Oracle Citadel MARKET execution is BloFin-only. Empty/unspecified exchange defaults to BloFin
    (demo host when use_demo_mode is True, live host otherwise).
    """
    raw = (exchange or "").strip().lower()
    is_blofin = "blofin" in raw or raw in ("", "unspecified")

    if use_demo_mode and is_blofin:
        return {
            "exchange": "blofin",
            "environment": "demo",
            "api_base_url": BLOFIN_DEMO_API_BASE_URL,
            "blofin_demo": True,
            "demo_rejected": False,
        }

    if is_blofin:
        return {
            "exchange": "blofin",
            "environment": "live",
            "api_base_url": BLOFIN_LIVE_API_BASE_URL,
            "blofin_demo": False,
            "demo_rejected": False,
        }

    if use_demo_mode:
        return {
            "exchange": raw or "unspecified",
            "environment": "live",
            "api_base_url": None,
            "blofin_demo": False,
            "demo_rejected": True,
        }

    return {
        "exchange": raw or "unspecified",
        "environment": "live",
        "api_base_url": None,
        "blofin_demo": False,
        "demo_rejected": False,
    }


def _normalize_citadel_exchange_record(record: dict[str, Any]) -> dict[str, Any]:
    """
    Upgrade legacy Citadel rows saved with exchange='' / 'unspecified' to BloFin.
    Citadel MARKET orders only execute on BloFin (demo or live).
    """
    exchange = str(record.get("exchange") or "").strip().lower()
    api_base = str(record.get("api_base_url") or "").strip().lower()
    use_demo = bool(record.get("use_demo_mode")) or "demo-trading-openapi.blofin.com" in api_base

    if "blofin" in exchange and exchange not in ("", "unspecified"):
        normalized = dict(record)
        if use_demo:
            normalized["exchange"] = "blofin"
            normalized["environment"] = "demo"
            normalized["api_base_url"] = BLOFIN_DEMO_API_BASE_URL
            normalized["use_demo_mode"] = True
        return normalized

    if exchange in ("", "unspecified") or use_demo or "blofin" in api_base:
        normalized = dict(record)
        normalized["exchange"] = "blofin"
        if use_demo:
            normalized["environment"] = "demo"
            normalized["api_base_url"] = BLOFIN_DEMO_API_BASE_URL
            normalized["use_demo_mode"] = True
        else:
            normalized["environment"] = record.get("environment") or "live"
            normalized["api_base_url"] = record.get("api_base_url") or BLOFIN_LIVE_API_BASE_URL
        return normalized

    return record


def _normalize_exchange_keys_payload(raw: dict[str, Any]) -> dict[str, Any]:
    """
    Map Flutter / legacy JSON field names before Pydantic validation.
    Flutter Citadel setup sends api_key + api_secret (exchange creds), not exchange_api_key.
    """
    data = dict(raw)
    if not data.get("exchange_api_key") and data.get("api_key"):
        data["exchange_api_key"] = data["api_key"]
    if not data.get("exchange_secret") and data.get("api_secret"):
        data["exchange_secret"] = data["api_secret"]
    if "use_demo_mode" not in data and "demo_mode" in data:
        data["use_demo_mode"] = data["demo_mode"]
    return data


def _parse_exchange_keys_request(
    raw_body: dict[str, Any],
    *,
    header_app_key: str,
) -> ExchangeKeysRequest:
    normalized = _normalize_exchange_keys_payload(raw_body)
    if header_app_key and not normalized.get("app_api_key"):
        normalized["app_api_key"] = header_app_key
    return ExchangeKeysRequest.model_validate(normalized)


def save_exchange_keys_record(
    *,
    user_id: str,
    app_api_key: str,
    exchange_api_key: str,
    exchange_secret: str,
    risk_percent: float,
    exchange: Optional[str] = None,
    use_demo_mode: bool = False,
) -> dict[str, Any]:
    profile = resolve_citadel_exchange_profile(exchange, use_demo_mode)
    encrypted_secret = encrypt_secret_at_rest(exchange_secret)
    store = _load_citadel_key_store()
    store[user_id] = {
        "user_id": user_id,
        "app_api_key": app_api_key,
        "exchange_api_key": exchange_api_key,
        "exchange_secret_encrypted": encrypted_secret,
        "risk_percent": risk_percent,
        "exchange": profile["exchange"],
        "use_demo_mode": use_demo_mode,
        "environment": profile["environment"],
        "api_base_url": profile["api_base_url"],
        "updated_at": datetime.now(timezone.utc).isoformat(),
    }
    _save_citadel_key_store(store)

    # Verify round-trip encrypt/decrypt and on-disk persistence (no secrets in logs).
    reloaded = _load_citadel_key_store()
    record = reloaded.get(user_id) if isinstance(reloaded, dict) else None
    if not record:
        raise OSError(f"citadel record not found after save for user_id={user_id}")
    stored_cipher = record.get("exchange_secret_encrypted", "")
    if decrypt_secret_at_rest(stored_cipher) != exchange_secret:
        raise OSError(f"citadel secret verification failed for user_id={user_id}")

    file_bytes = _CITADEL_KEYS_FILE.stat().st_size if _CITADEL_KEYS_FILE.is_file() else 0
    profile["persisted"] = True
    profile["store_user_count"] = len(reloaded)
    profile["store_file_bytes"] = file_bytes
    profile["encryption_prefix"] = (
        stored_cipher.split(":", 1)[0] if isinstance(stored_cipher, str) and ":" in stored_cipher else "legacy"
    )
    return profile


def get_citadel_user_record(user_id: str) -> Optional[dict[str, Any]]:
    """Load saved Oracle Citadel credentials for [user_id] (no secrets returned in API)."""
    store = _load_citadel_key_store()
    record = store.get(user_id)
    if not isinstance(record, dict):
        return None
    return _normalize_citadel_exchange_record(record)


def _execute_trade_log_payload(body: dict[str, Any]) -> dict[str, Any]:
    """Log-safe view of execute_trade JSON — never includes API keys or secrets."""
    return {
        "user_id": body.get("user_id"),
        "coin": body.get("coin"),
        "direction": body.get("direction"),
        "order_type": body.get("order_type"),
        "entry_price": body.get("entry_price", body.get("entry")),
        "stop_loss": body.get("stop_loss", body.get("sl")),
        "tp1": body.get("tp1"),
        "tp2": body.get("tp2"),
        "risk_percent": body.get("risk_percent"),
        "leverage": body.get("leverage"),
    }


def _coerce_positive_float(value: Any) -> Optional[float]:
    try:
        parsed = float(value)
    except (TypeError, ValueError):
        return None
    return parsed if parsed > 0 else None


def _normalize_execute_trade_payload(raw: dict[str, Any]) -> dict[str, Any]:
    """Map Flutter payloads — Oracle Citadel accepts MARKET orders only."""
    data = dict(raw)
    data["order_type"] = "market"
    entry_raw = data.get("entry_price", data.get("entry"))
    entry_is_market = isinstance(entry_raw, str) and entry_raw.strip().lower() == "market"
    if entry_is_market:
        sl = _coerce_positive_float(data.get("stop_loss") or data.get("sl"))
        tp1 = _coerce_positive_float(data.get("tp1"))
        ref = (tp1 + sl) / 2 if sl is not None and tp1 is not None else None
        data["entry_price"] = ref if ref is not None else _coerce_positive_float(data.get("entry_price")) or 1.0
    return data


def _parse_execute_trade_request(raw_body: dict[str, Any]) -> ExecuteTradeRequest:
    """Validate execute_trade payload (MARKET-only Citadel)."""
    return ExecuteTradeRequest.model_validate(_normalize_execute_trade_payload(raw_body))


def _parse_blofin_price_token(value: Any) -> Optional[float]:
    if value is None:
        return None
    try:
        parsed = float(str(value).replace(",", "").strip())
    except (TypeError, ValueError):
        return None
    return parsed if parsed > 0 else None


def _citadel_suggested_stop_loss(
    *,
    direction: str,
    fill_entry: float,
    planned_entry: float,
    original_sl: float,
) -> float:
    """Preserve planned risk distance from fill entry (desk-style SL adjustment)."""
    risk_distance = abs(planned_entry - original_sl)
    if direction == "long":
        return fill_entry - risk_distance
    return fill_entry + risk_distance


# ---------------------------------------------------------------------------
# BloFin — Oracle Citadel MARKET execution
# ---------------------------------------------------------------------------

_INSTRUMENT_SPEC_CACHE: dict[str, tuple[float, dict[str, Any]]] = {}
# Cached egress IP — fetched only when BloFin reports IP whitelist failure (for Railway → BloFin setup).
_CITADEL_EGRESS_IP_CACHE: tuple[float, str] = (0.0, "")


def _citadel_egress_ip_for_whitelist() -> str:
    """Public IP Railway uses for outbound REST (whitelist this in BloFin Demo API settings)."""
    global _CITADEL_EGRESS_IP_CACHE
    now = time.time()
    if _CITADEL_EGRESS_IP_CACHE[1] and (now - _CITADEL_EGRESS_IP_CACHE[0]) < 300:
        return _CITADEL_EGRESS_IP_CACHE[1]
    try:
        response = requests.get("https://api.ipify.org?format=json", timeout=5)
        if response.status_code == 200 and isinstance(response.json(), dict):
            ip = str(response.json().get("ip") or "").strip()
            if ip:
                _CITADEL_EGRESS_IP_CACHE = (now, ip)
                return ip
    except Exception as exc:
        logger.warning("citadel_egress_ip_lookup_failed err=%s", exc)
    return ""


def _resolve_effective_risk_percent(risk_percent: Optional[float]) -> tuple[float, float]:
    """
    Respect Flutter risk_percent; default 1.0%; clamp to 100% max position size.
    Returns (effective_percent, raw_requested_percent).
    """
    try:
        requested = float(risk_percent) if risk_percent is not None else EXECUTE_TRADE_DEFAULT_RISK_PERCENT
    except (TypeError, ValueError):
        requested = EXECUTE_TRADE_DEFAULT_RISK_PERCENT
    if requested <= 0:
        requested = EXECUTE_TRADE_DEFAULT_RISK_PERCENT
    effective = min(requested, EXECUTE_TRADE_MAX_RISK_PERCENT)
    return effective, requested


def _blofin_inst_id(coin: str) -> str:
    symbol = (coin or "").strip().upper()
    return symbol if "-" in symbol else f"{symbol}-USDT"


def _blofin_canonical_json(body: dict[str, Any]) -> str:
    """Compact JSON — must match exact POST bytes signed (BloFin rejects extra spaces)."""
    return json.dumps(body, separators=(",", ":"), ensure_ascii=False)


def _blofin_sign_headers(
    *,
    api_key: str,
    api_secret: str,
    passphrase: str,
    method: str,
    path: str,
    body_str: str = "",
) -> dict[str, str]:
    """BloFin REST signature headers (secrets never logged)."""
    timestamp = str(int(time.time() * 1000))
    nonce = uuid.uuid4().hex
    msg = f"{path}{method.upper()}{timestamp}{nonce}{body_str}"
    hex_sig = hmac.new(api_secret.encode("utf-8"), msg.encode("utf-8"), hashlib.sha256).hexdigest()
    signature = base64.b64encode(hex_sig.encode("utf-8")).decode("ascii")
    return {
        "ACCESS-KEY": api_key,
        "ACCESS-SIGN": signature,
        "ACCESS-TIMESTAMP": timestamp,
        "ACCESS-NONCE": nonce,
        "ACCESS-PASSPHRASE": passphrase,
        "Content-Type": "application/json",
    }


def _blofin_safe_response_log(data: Any) -> Any:
    """Log-safe BloFin JSON — full outcome fields without secrets."""
    if not isinstance(data, dict):
        return data
    out: dict[str, Any] = {}
    if "code" in data:
        out["code"] = data.get("code")
    if "msg" in data:
        out["msg"] = data.get("msg")
    payload = data.get("data")
    if isinstance(payload, list) and payload:
        first = payload[0] if isinstance(payload[0], dict) else {}
        out["data"] = _blofin_safe_order_row(first)
    elif isinstance(payload, dict):
        out["data"] = _blofin_safe_order_row(payload)
    return out


def _blofin_safe_order_row(row: dict[str, Any]) -> dict[str, Any]:
    """Single order row / detail — ids, fill state, errors (no keys)."""
    return {
        "orderId": row.get("orderId"),
        "clientOrderId": row.get("clientOrderId"),
        "code": row.get("code"),
        "msg": row.get("msg"),
        "state": row.get("state"),
        "orderType": row.get("orderType"),
        "side": row.get("side"),
        "instId": row.get("instId"),
        "size": row.get("size"),
        "filledSize": row.get("filledSize"),
        "filled_amount": row.get("filled_amount"),
        "averagePrice": row.get("averagePrice"),
        "price": row.get("price"),
    }


def _blofin_first_data_row(response_json: dict[str, Any]) -> dict[str, Any]:
    data = response_json.get("data")
    if isinstance(data, list) and data and isinstance(data[0], dict):
        return data[0]
    if isinstance(data, dict):
        return data
    return {}


def _blofin_parse_place_order_response(
    response_json: dict[str, Any],
    *,
    http_status: int,
) -> dict[str, Any]:
    """
    BloFin returns HTTP 200 with top-level code \"0\" even when the order event fails.
    Success requires top code 0 AND per-order data[].code == \"0\" AND an orderId.
    """
    top_code = str(response_json.get("code", ""))
    top_msg = response_json.get("msg")
    row = _blofin_first_data_row(response_json)
    row_code = str(row.get("code", top_code))
    row_msg = row.get("msg") or top_msg
    order_id = row.get("orderId")
    order_id_str = str(order_id) if order_id else None
    ok = (
        http_status == 200
        and top_code == "0"
        and row_code == "0"
        and bool(order_id_str)
    )
    return {
        "ok": ok,
        "http_status": http_status,
        "code": row_code if row else top_code,
        "top_code": top_code,
        "msg": row_msg,
        "order_id": order_id_str,
        "filled_size": row.get("filledSize"),
        "remaining_size": _blofin_remaining_size(row),
        "state": row.get("state"),
        "response": response_json,
    }


def _blofin_remaining_size(row: dict[str, Any]) -> Optional[str]:
    try:
        total = float(row.get("size") or 0)
        filled = float(row.get("filledSize") or 0)
    except (TypeError, ValueError):
        return None
    remaining = max(0.0, total - filled)
    return f"{remaining:.8f}".rstrip("0").rstrip(".")


def _blofin_private_request(
    *,
    base_url: str,
    api_key: str,
    api_secret: str,
    passphrase: str,
    method: str,
    path: str,
    body: Optional[dict[str, Any]] = None,
    request_id: str = "?",
    log_tag: str = "blofin_request",
) -> tuple[int, str, Any]:
    """
    Signed BloFin REST call — returns (http_status, raw_text, parsed_or_none).
    POST/PUT: sign and send the same compact JSON string (fixes 152409 signature errors).
    """
    url = f"{base_url.rstrip('/')}{path}"
    body_str = ""
    if body is not None and method.upper() in {"POST", "PUT"}:
        body_str = _blofin_canonical_json(body)
    headers = _blofin_sign_headers(
        api_key=api_key,
        api_secret=api_secret,
        passphrase=passphrase,
        method=method,
        path=path,
        body_str=body_str,
    )
    started = time.perf_counter()
    try:
        if method.upper() == "GET":
            response = requests.get(url, headers=headers, timeout=REQUEST_TIMEOUT)
        else:
            # Must use data=body_str — NOT json=body (different serialization breaks signature).
            response = requests.post(
                url,
                headers=headers,
                data=body_str.encode("utf-8"),
                timeout=REQUEST_TIMEOUT,
            )
    except requests.RequestException as exc:
        elapsed_ms = (time.perf_counter() - started) * 1000
        logger.error(
            "%s_http_error request_id=%s method=%s path=%s elapsed_ms=%.1f err=%s",
            log_tag,
            request_id,
            method,
            path,
            elapsed_ms,
            exc,
        )
        raise

    elapsed_ms = (time.perf_counter() - started) * 1000
    raw_text = response.text or ""
    logger.info(
        "%s_http_response request_id=%s method=%s path=%s status=%s elapsed_ms=%.1f body_preview=%s",
        log_tag,
        request_id,
        method,
        path,
        response.status_code,
        elapsed_ms,
        raw_text[:2000],
    )
    try:
        parsed = response.json()
    except json.JSONDecodeError:
        logger.error(
            "%s_invalid_json request_id=%s status=%s body_preview=%s",
            log_tag,
            request_id,
            response.status_code,
            raw_text[:2000],
        )
        return response.status_code, raw_text, None
    logger.info(
        "%s_parsed request_id=%s payload=%s",
        log_tag,
        request_id,
        _blofin_safe_response_log(parsed) if isinstance(parsed, dict) else parsed,
    )
    return response.status_code, raw_text, parsed


def _blofin_fetch_instrument_spec(
    *,
    base_url: str,
    inst_id: str,
    request_id: str = "?",
) -> dict[str, Any]:
    """Public instruments spec — contractValue, minSize, lotSize (cached 5 min)."""
    cache_key = f"{base_url}|{inst_id}"
    cached = _INSTRUMENT_SPEC_CACHE.get(cache_key)
    if cached and (time.time() - cached[0]) < 300:
        return cached[1]

    url = f"{base_url.rstrip('/')}{BLOFIN_MARKET_INSTRUMENTS_PATH}"
    try:
        response = requests.get(
            url,
            params={"instId": inst_id},
            timeout=REQUEST_TIMEOUT,
        )
        if response.status_code != 200:
            raise ValueError(f"instruments_http_{response.status_code}")
        payload = response.json()
        rows = payload.get("data") if isinstance(payload, dict) else None
        if not isinstance(rows, list) or not rows:
            raise ValueError("instruments_empty")
        row = rows[0] if isinstance(rows[0], dict) else {}
        spec = {
            "instId": inst_id,
            "contractValue": float(row.get("contractValue") or 0.001),
            "minSize": float(row.get("minSize") or 0.1),
            "lotSize": float(row.get("lotSize") or 0.1),
            "maxMarketSize": float(row.get("maxMarketSize") or 1_000_000),
        }
        _INSTRUMENT_SPEC_CACHE[cache_key] = (time.time(), spec)
        logger.info(
            "blofin_instrument_spec request_id=%s inst=%s spec=%s",
            request_id,
            inst_id,
            spec,
        )
        return spec
    except Exception as exc:
        logger.warning(
            "blofin_instrument_spec_fallback request_id=%s inst=%s err=%s",
            request_id,
            inst_id,
            exc,
        )
        return {
            "instId": inst_id,
            "contractValue": 0.001,
            "minSize": float(BLOFIN_ORDER_SIZE),
            "lotSize": float(BLOFIN_ORDER_SIZE),
            "maxMarketSize": 1_000_000.0,
        }


def _blofin_fetch_available_usdt(
    *,
    base_url: str,
    api_key: str,
    api_secret: str,
    passphrase: str,
    request_id: str = "?",
) -> Optional[float]:
    """USDT available balance for risk-based contract sizing."""
    path = f"{BLOFIN_ACCOUNT_BALANCE_PATH}?productType=USDT-FUTURES"
    http_status, _raw, parsed = _blofin_private_request(
        base_url=base_url,
        api_key=api_key,
        api_secret=api_secret,
        passphrase=passphrase,
        method="GET",
        path=path,
        request_id=request_id,
        log_tag="blofin_balance",
    )
    if not isinstance(parsed, dict) or http_status != 200 or str(parsed.get("code")) != "0":
        return None
    data = parsed.get("data")
    if not isinstance(data, dict):
        return None
    details = data.get("details")
    if isinstance(details, list):
        for item in details:
            if isinstance(item, dict) and str(item.get("currency", "")).upper() == "USDT":
                try:
                    return float(item.get("available") or item.get("availableEquity") or 0)
                except (TypeError, ValueError):
                    continue
    try:
        return float(data.get("totalEquity") or 0)
    except (TypeError, ValueError):
        return None


def _blofin_format_contract_size(contracts: float, lot_size: float) -> str:
    """Format size string to BloFin lot increment."""
    lot = lot_size if lot_size > 0 else 0.1
    steps = max(1, int(contracts / lot))
    aligned = steps * lot
    if lot >= 1:
        return str(int(aligned)) if aligned == int(aligned) else f"{aligned:.4f}".rstrip("0").rstrip(".")
    decimals = max(1, len(f"{lot:.10f}".rstrip("0").split(".")[-1]))
    return f"{aligned:.{decimals}f}".rstrip("0").rstrip(".")


def _blofin_calculate_order_size(
    *,
    coin: str,
    entry_price: float,
    stop_loss: float,
    risk_percent: float,
    base_url: str,
    api_key: str,
    api_secret: str,
    passphrase: str,
    request_id: str = "?",
) -> tuple[str, dict[str, Any]]:
    """
    Risk-based contract count: risk_usdt = available * risk%; size from SL distance.
    Falls back to env BLOFIN_ORDER_SIZE if balance unavailable (logged).
    """
    inst_id = _blofin_inst_id(coin)
    spec = _blofin_fetch_instrument_spec(base_url=base_url, inst_id=inst_id, request_id=request_id)
    contract_value = float(spec["contractValue"])
    min_size = float(spec["minSize"])
    lot_size = float(spec["lotSize"])
    max_market = float(spec["maxMarketSize"])

    sl_distance = abs(float(entry_price) - float(stop_loss))
    meta: dict[str, Any] = {
        "inst_id": inst_id,
        "contract_value": contract_value,
        "min_size": min_size,
        "lot_size": lot_size,
        "sl_distance": sl_distance,
        "risk_percent": risk_percent,
    }

    if sl_distance <= 0:
        size_str = _blofin_format_contract_size(min_size, lot_size)
        meta["fallback"] = "invalid_sl_distance"
        return size_str, meta

    available = _blofin_fetch_available_usdt(
        base_url=base_url,
        api_key=api_key,
        api_secret=api_secret,
        passphrase=passphrase,
        request_id=request_id,
    )
    meta["available_usdt"] = available

    if available is None or available <= 0:
        fallback = max(min_size, float(BLOFIN_ORDER_SIZE))
        meta["fallback"] = "balance_unavailable"
        logger.warning(
            "blofin_size_fallback_balance request_id=%s inst=%s size=%s",
            request_id,
            inst_id,
            fallback,
        )
        return _blofin_format_contract_size(fallback, lot_size), meta

    risk_usdt = available * (risk_percent / 100.0)
    loss_per_contract = sl_distance * contract_value
    if loss_per_contract <= 0:
        contracts = min_size
    else:
        contracts = risk_usdt / loss_per_contract

    contracts = max(min_size, min(contracts, max_market))
    steps = int(contracts / lot_size)
    if steps < 1:
        steps = 1
    contracts = steps * lot_size
    meta.update(
        {
            "risk_usdt": risk_usdt,
            "loss_per_contract": loss_per_contract,
            "contracts": contracts,
        }
    )
    return _blofin_format_contract_size(contracts, lot_size), meta


def _blofin_coerce_contract_qty(value: Any) -> float:
    """Parse BloFin contract qty fields (filledSize, size, etc.)."""
    if value is None:
        return 0.0
    try:
        return float(str(value).replace(",", "").strip())
    except (TypeError, ValueError):
        return 0.0


def _blofin_market_fill_satisfied(
    *,
    filled_size: Any = None,
    filled_amount: Any = None,
    state: Any = None,
) -> bool:
    """
    True when the MARKET entry actually filled contracts (position can exist).
    BloFin may return orderId with state=live and filledSize=0 before fill completes — poll until qty > 0.
    (state is logged; partially_canceled with filledSize>0 still counts as filled.)
    """
    _ = state  # retained for callers / logs; fill qty is the gate
    filled_qty = max(
        _blofin_coerce_contract_qty(filled_size),
        _blofin_coerce_contract_qty(filled_amount),
    )
    return filled_qty > 0


def _blofin_fetch_order_detail(
    *,
    base_url: str,
    api_key: str,
    api_secret: str,
    passphrase: str,
    inst_id: str,
    order_id: str,
    request_id: str = "?",
) -> dict[str, Any]:
    """Post-placement confirmation — filled qty, state, avg price."""
    path = f"{BLOFIN_ORDER_DETAIL_PATH}?instId={inst_id}&orderId={order_id}"
    http_status, _raw, parsed = _blofin_private_request(
        base_url=base_url,
        api_key=api_key,
        api_secret=api_secret,
        passphrase=passphrase,
        method="GET",
        path=path,
        request_id=request_id,
        log_tag="blofin_order_detail",
    )
    if not isinstance(parsed, dict):
        return {"ok": False, "http_status": http_status}
    row = _blofin_first_data_row(parsed)
    ok = http_status == 200 and str(parsed.get("code")) == "0"
    filled_size = row.get("filledSize")
    filled_amount = row.get("filled_amount")
    state = row.get("state")
    return {
        "ok": ok,
        "http_status": http_status,
        "state": state,
        "filled_size": filled_size,
        "filled_amount": filled_amount,
        "size": row.get("size"),
        "average_price": row.get("averagePrice"),
        "order_type": row.get("orderType"),
        "fill_ok": ok and _blofin_market_fill_satisfied(
            filled_size=filled_size,
            filled_amount=filled_amount,
            state=state,
        ),
        "response": _blofin_safe_response_log(parsed),
    }


async def _blofin_confirm_market_fill(
    *,
    base_url: str,
    api_key: str,
    api_secret: str,
    passphrase: str,
    inst_id: str,
    order_id: str,
    placement: dict[str, Any],
    request_id: str = "?",
) -> dict[str, Any]:
    """
    Wait for a real MARKET fill before Citadel reports success.
    Uses placement row first, then polls GET order-detail (fills can lag orderId).
    """
    if _blofin_market_fill_satisfied(
        filled_size=placement.get("filled_size"),
        state=placement.get("state"),
    ):
        logger.info(
            "execute_trade_market_fill_confirmed request_id=%s order_id=%s source=placement "
            "state=%s filled=%s",
            request_id,
            order_id,
            placement.get("state"),
            placement.get("filled_size"),
        )
        return {
            "fill_ok": True,
            "ok": True,
            "state": placement.get("state"),
            "filled_size": placement.get("filled_size"),
            "size": None,
            "average_price": None,
            "poll_attempt": 0,
            "source": "placement",
        }

    await asyncio.sleep(BLOFIN_POST_ORDER_CONFIRM_DELAY_SEC)

    last: dict[str, Any] = {"fill_ok": False, "ok": False}
    for attempt in range(1, BLOFIN_MARKET_FILL_CONFIRM_MAX_POLLS + 1):
        detail = _blofin_fetch_order_detail(
            base_url=base_url,
            api_key=api_key,
            api_secret=api_secret,
            passphrase=passphrase,
            inst_id=inst_id,
            order_id=order_id,
            request_id=request_id,
        )
        last = {**detail, "poll_attempt": attempt, "source": "order_detail"}
        if detail.get("fill_ok"):
            logger.info(
                "execute_trade_market_fill_confirmed request_id=%s order_id=%s source=order_detail "
                "poll=%s state=%s filled=%s avg=%s",
                request_id,
                order_id,
                attempt,
                detail.get("state"),
                detail.get("filled_size"),
                detail.get("average_price"),
            )
            return last
        if attempt < BLOFIN_MARKET_FILL_CONFIRM_MAX_POLLS:
            await asyncio.sleep(BLOFIN_MARKET_FILL_CONFIRM_POLL_SEC)

    logger.warning(
        "execute_trade_market_fill_unconfirmed request_id=%s order_id=%s polls=%s "
        "last_state=%s last_filled=%s last_ok=%s",
        request_id,
        order_id,
        BLOFIN_MARKET_FILL_CONFIRM_MAX_POLLS,
        last.get("state"),
        last.get("filled_size"),
        last.get("ok"),
    )
    return last


def _normalize_citadel_leverage(value: Any) -> int:
    """Clamp Citadel leverage to BloFin-safe 1x–100x (default 5x)."""
    try:
        parsed = int(float(value))
    except (TypeError, ValueError):
        parsed = BLOFIN_DEFAULT_LEVERAGE
    return max(1, min(100, parsed))


def _blofin_set_leverage(
    *,
    base_url: str,
    api_key: str,
    api_secret: str,
    passphrase: str,
    coin: str,
    leverage: int,
    request_id: str = "?",
) -> dict[str, Any]:
    """Set BloFin account leverage before MARKET placement (net / cross)."""
    inst_id = _blofin_inst_id(coin)
    body = {
        "instId": inst_id,
        "leverage": str(leverage),
        "marginMode": BLOFIN_MARGIN_MODE,
        "positionSide": "net",
    }
    http_status, raw_text, parsed = _blofin_private_request(
        base_url=base_url,
        api_key=api_key,
        api_secret=api_secret,
        passphrase=passphrase,
        method="POST",
        path=BLOFIN_SET_LEVERAGE_PATH,
        body=body,
        request_id=request_id,
        log_tag="blofin_set_leverage",
    )
    ok = False
    code: Any = None
    msg: Optional[str] = None
    if isinstance(parsed, dict):
        code = parsed.get("code")
        msg = parsed.get("msg")
        ok = str(code) == "0"
    return {
        "ok": ok,
        "http_status": http_status,
        "code": code,
        "msg": msg,
        "leverage": leverage,
        "inst_id": inst_id,
        "response": _blofin_safe_response_log(parsed) if isinstance(parsed, dict) else (raw_text or "")[:500],
    }


def _blofin_place_order(
    *,
    base_url: str,
    api_key: str,
    api_secret: str,
    passphrase: str,
    coin: str,
    direction: str,
    order_type: str,
    size: str,
    price: Optional[str] = None,
    tp1: Optional[float] = None,
    sl: Optional[float] = None,
    client_order_id: Optional[str] = None,
    request_id: str = "?",
) -> dict[str, Any]:
    """
    Place order on BloFin.
    MARKET: orderType=market — no price field (BloFin rejects price on market orders).
    LIMIT: orderType=limit + price (not used by Citadel — MARKET-only).
    TP/SL: trigger prices + -1 market execution + triggerPriceType=last per BloFin docs.
    """
    inst_id = _blofin_inst_id(coin)
    side = "buy" if direction == "long" else "sell"
    normalized_type = order_type.strip().lower()
    if normalized_type not in {"market", "limit"}:
        normalized_type = "limit"

    body: dict[str, Any] = {
        "instId": inst_id,
        "marginMode": BLOFIN_MARGIN_MODE,
        "positionSide": "net",
        "side": side,
        "orderType": normalized_type,
        "size": str(size),
        "reduceOnly": "false",
    }
    if client_order_id:
        body["clientOrderId"] = client_order_id[:32]
    # MARKET: never send price — immediate execution at best available.
    if normalized_type == "limit" and price is not None:
        body["price"] = str(price)
    if tp1 is not None:
        body["tpTriggerPrice"] = str(tp1)
        body["tpOrderPrice"] = "-1"
        body["tpTriggerPriceType"] = "last"
    if sl is not None:
        body["slTriggerPrice"] = str(sl)
        body["slOrderPrice"] = "-1"
        body["slTriggerPriceType"] = "last"

    logger.info(
        "blofin_order_request request_id=%s order_type=%s inst_id=%s side=%s size=%s body=%s",
        request_id,
        normalized_type,
        inst_id,
        side,
        size,
        body,
    )

    http_status, raw_text, parsed = _blofin_private_request(
        base_url=base_url,
        api_key=api_key,
        api_secret=api_secret,
        passphrase=passphrase,
        method="POST",
        path=BLOFIN_TRADE_ORDER_PATH,
        body=body,
        request_id=request_id,
        log_tag="blofin_place_order",
    )

    if not isinstance(parsed, dict):
        return {
            "ok": False,
            "http_status": http_status,
            "code": "invalid_json",
            "msg": "BloFin returned non-JSON",
            "order_id": None,
            "raw_preview": (raw_text or "")[:2000],
        }

    result = _blofin_parse_place_order_response(parsed, http_status=http_status)
    result["order_params"] = body

    if result.get("ok"):
        logger.info(
            "blofin_order_outcome_success request_id=%s order_id=%s order_type=%s inst=%s side=%s "
            "size=%s filled=%s remaining=%s state=%s",
            request_id,
            result.get("order_id"),
            normalized_type,
            inst_id,
            side,
            size,
            result.get("filled_size"),
            result.get("remaining_size"),
            result.get("state"),
        )
    else:
        logger.warning(
            "blofin_order_outcome_failure request_id=%s http=%s top_code=%s code=%s msg=%s "
            "order_id=%s raw=%s",
            request_id,
            http_status,
            result.get("top_code"),
            result.get("code"),
            result.get("msg"),
            result.get("order_id"),
            _blofin_safe_response_log(parsed),
        )

    return result


def _blofin_tp_close_side(direction: str) -> str:
    """Side for reduce-only take-profit legs (closes long/short)."""
    return "sell" if direction == "long" else "buy"


def _blofin_dual_tp_contract_sizes(
    total_size: str,
    *,
    lot_size: float,
    min_size: float,
) -> tuple[str, str]:
    """Split position into TP1 (40%) and TP2 (60%) contract counts, lot-aligned."""
    try:
        total = float(total_size)
    except (TypeError, ValueError):
        total = float(min_size)
    lot = lot_size if lot_size > 0 else 0.1
    min_s = min_size if min_size > 0 else lot

    if total < min_s * 2:
        half = max(min_s, total / 2.0)
        tp1 = _blofin_format_contract_size(half, lot)
        tp2 = _blofin_format_contract_size(max(min_s, total - float(tp1)), lot)
        return tp1, tp2

    tp1_raw = total * 0.4
    remaining = max(min_s, total - tp1_raw)
    tp1_steps = max(1, int(tp1_raw / lot))
    tp1_val = tp1_steps * lot
    tp2_val = max(min_s, remaining)
    tp2_steps = max(1, int(tp2_val / lot))
    tp2_val = min(remaining, tp2_steps * lot)
    if tp1_val + tp2_val > total:
        tp2_val = max(min_s, total - tp1_val)
    return _blofin_format_contract_size(tp1_val, lot), _blofin_format_contract_size(tp2_val, lot)


def _blofin_parse_tpsl_response(
    response_json: dict[str, Any],
    *,
    http_status: int,
) -> dict[str, Any]:
    """Parse POST /api/v1/trade/order-tpsl."""
    top_code = str(response_json.get("code", ""))
    top_msg = response_json.get("msg")
    data = response_json.get("data")
    row = data if isinstance(data, dict) else {}
    row_code = str(row.get("code", top_code))
    row_msg = row.get("msg") or top_msg
    tpsl_id = row.get("tpslId")
    tpsl_id_str = str(tpsl_id) if tpsl_id else None
    ok = http_status == 200 and top_code == "0" and row_code == "0" and bool(tpsl_id_str)
    return {
        "ok": ok,
        "http_status": http_status,
        "code": row_code,
        "top_code": top_code,
        "msg": row_msg,
        "tpsl_id": tpsl_id_str,
        "response": response_json,
    }


def _blofin_place_tpsl_take_profit(
    *,
    base_url: str,
    api_key: str,
    api_secret: str,
    passphrase: str,
    coin: str,
    direction: str,
    tp_price: float,
    size: str,
    client_order_id: Optional[str] = None,
    request_id: str = "?",
) -> dict[str, Any]:
    """Reduce-only take-profit via BloFin order-tpsl (MARKET dual-TP legs)."""
    inst_id = _blofin_inst_id(coin)
    body: dict[str, Any] = {
        "instId": inst_id,
        "marginMode": BLOFIN_MARGIN_MODE,
        "positionSide": "net",
        "side": _blofin_tp_close_side(direction),
        "tpTriggerPrice": str(tp_price),
        "tpOrderPrice": "-1",
        "tpTriggerPriceType": "last",
        "size": str(size),
        "reduceOnly": "true",
    }
    if client_order_id:
        body["clientOrderId"] = client_order_id[:32]

    http_status, raw_text, parsed = _blofin_private_request(
        base_url=base_url,
        api_key=api_key,
        api_secret=api_secret,
        passphrase=passphrase,
        method="POST",
        path=BLOFIN_TRADE_ORDER_TPSL_PATH,
        body=body,
        request_id=request_id,
        log_tag="blofin_place_tpsl_tp",
    )

    if not isinstance(parsed, dict):
        return {
            "ok": False,
            "http_status": http_status,
            "code": "invalid_json",
            "msg": "BloFin TP/SL returned non-JSON",
            "tpsl_id": None,
            "raw_preview": (raw_text or "")[:2000],
        }

    result = _blofin_parse_tpsl_response(parsed, http_status=http_status)
    result["order_params"] = body
    return result


def _resolve_blofin_passphrase(record: dict[str, Any]) -> str:
    """Passphrase for BloFin headers — env or optional per-user field (never logged)."""
    stored = (record.get("exchange_passphrase") or "").strip()
    return stored or BLOFIN_PASSPHRASE


def _blofin_user_friendly_error(code: Any, msg: Optional[str]) -> str:
    """Map BloFin API errors to short, actionable Citadel snackbar messages."""
    text = (msg or "").strip()
    code_str = str(code or "")
    lower = text.lower()
    if code_str == "152409" or "signature verification failed" in lower:
        return (
            "Signature verification failed - please double-check API Key, Secret, "
            "and Passphrase in Citadel Setup."
        )
    if code_str == "152406" or ("ip" in lower and "whitelist" in lower):
        return (
            "IP whitelist error - add your Railway server IP to BloFin Demo API settings "
            "(see whitelist_ip in the error response or Railway logs)."
        )
    return text or "BloFin could not place the MARKET order. Try again."


def _blofin_is_ip_whitelist_error(code: Any, msg: Optional[str]) -> bool:
    text = (msg or "").lower()
    code_str = str(code or "")
    return code_str == "152406" or ("ip" in text and "whitelist" in text)


def _validate_citadel_trade_geometry(
    *,
    direction: str,
    entry: float,
    sl: float,
    tp1: float,
    tp2: float,
) -> Optional[str]:
    """Basic long/short level sanity — returns user-facing error or None if OK."""
    if direction == "long":
        if sl >= entry:
            return "For a long trade, stop loss must be below entry."
        if tp1 <= entry or tp2 <= entry:
            return "For a long trade, take-profit levels must be above entry."
        if tp2 < tp1:
            return "For a long trade, TP2 should be at or above TP1."
    else:
        if sl <= entry:
            return "For a short trade, stop loss must be above entry."
        if tp1 >= entry or tp2 >= entry:
            return "For a short trade, take-profit levels must be below entry."
        if tp2 > tp1:
            return "For a short trade, TP2 should be at or below TP1."
    return None


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
    """
    Synchronous Grok call — run via [run_grok_in_executor] from async routes.
    Raises [GrokError] (not HTTPException) so /analyze can return a fallback report.
    """
    if not GROK_API_KEY:
        raise GrokError("GROK_API_KEY is not configured on the server.")

    started = time.perf_counter()
    timeout_tuple = (GROK_CONNECT_TIMEOUT, GROK_TIMEOUT)
    system_len = len(system_prompt)
    user_len = len(user_prompt)
    logger.info(
        "grok_request_start model=%s connect_s=%s read_s=%s system_chars=%d user_chars=%d "
        "temperature=%.2f max_tokens=%d",
        GROK_MODEL,
        GROK_CONNECT_TIMEOUT,
        GROK_TIMEOUT,
        system_len,
        user_len,
        temperature,
        max_tokens,
    )

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
            timeout=timeout_tuple,
        )
    except requests.Timeout as exc:
        elapsed_ms = (time.perf_counter() - started) * 1000
        logger.error(
            "grok_timeout elapsed_ms=%.0f connect_s=%s read_s=%s err=%s",
            elapsed_ms,
            GROK_CONNECT_TIMEOUT,
            GROK_TIMEOUT,
            exc,
        )
        raise GrokError(
            f"Grok timed out after {GROK_TIMEOUT}s (connect {GROK_CONNECT_TIMEOUT}s).",
            cause=exc,
        ) from exc
    except requests.RequestException as exc:
        elapsed_ms = (time.perf_counter() - started) * 1000
        logger.error(
            "grok_request_failed elapsed_ms=%.0f type=%s err=%s",
            elapsed_ms,
            type(exc).__name__,
            exc,
            exc_info=True,
        )
        raise GrokError("Grok network error — AI service unreachable.", cause=exc) from exc

    elapsed_ms = (time.perf_counter() - started) * 1000

    if response.status_code != 200:
        body_preview = (response.text or "")[:800]
        logger.error(
            "grok_http_error status=%s elapsed_ms=%.0f body=%s",
            response.status_code,
            elapsed_ms,
            body_preview,
        )
        raise GrokError(
            f"Grok HTTP {response.status_code}.",
            status_code=response.status_code,
            response_body=body_preview,
        )

    try:
        payload = response.json()
        content = payload["choices"][0]["message"]["content"]
    except (KeyError, IndexError, TypeError, ValueError) as exc:
        logger.error(
            "grok_malformed_json elapsed_ms=%.0f body=%s",
            elapsed_ms,
            (response.text or "")[:400],
            exc_info=True,
        )
        raise GrokError("Malformed Grok response payload.", cause=exc) from exc

    if not isinstance(content, str) or not content.strip():
        raise GrokError("Grok returned empty content.")

    logger.info(
        "grok_request_complete model=%s elapsed_ms=%.0f response_chars=%d",
        GROK_MODEL,
        elapsed_ms,
        len(content),
    )
    return content.strip()


async def run_grok_in_executor(
    *,
    system_prompt: str,
    user_prompt: str,
    temperature: float,
    max_tokens: int,
) -> str:
    """Run [call_grok] in a worker thread with an asyncio deadline (Railway-safe)."""
    logger.info(
        "grok_executor_start route_timeout_s=%s user_chars=%d max_tokens=%d",
        ANALYZE_ROUTE_TIMEOUT,
        len(user_prompt),
        max_tokens,
    )
    loop = asyncio.get_running_loop()
    started = time.perf_counter()
    try:
        result = await asyncio.wait_for(
            loop.run_in_executor(
                _GROK_EXECUTOR,
                lambda: call_grok(
                    system_prompt=system_prompt,
                    user_prompt=user_prompt,
                    temperature=temperature,
                    max_tokens=max_tokens,
                ),
            ),
            timeout=ANALYZE_ROUTE_TIMEOUT,
        )
    except asyncio.TimeoutError:
        elapsed_ms = (time.perf_counter() - started) * 1000
        logger.error(
            "grok_executor_timeout elapsed_ms=%.0f route_timeout_s=%s",
            elapsed_ms,
            ANALYZE_ROUTE_TIMEOUT,
        )
        raise
    except GrokError:
        elapsed_ms = (time.perf_counter() - started) * 1000
        logger.error("grok_executor_failed elapsed_ms=%.0f", elapsed_ms)
        raise
    else:
        elapsed_ms = (time.perf_counter() - started) * 1000
        logger.info(
            "grok_executor_complete elapsed_ms=%.0f response_chars=%d",
            elapsed_ms,
            len(result),
        )
        return result


def build_analyze_fallback_report(
    *,
    coin: str,
    mode: str,
    market: dict[str, Any],
    reason: str,
) -> str:
    """
    User-visible report when Grok fails — keeps Flutter flow alive (success=true + report).
    Same section headers the app already parses/displays.
    """
    price = float(market.get("price") or 0)
    source = market.get("source") or "unknown"
    mode_label = "Trade Setup" if mode == "tradesetup" else "Analysis"

    trade_levels_note = ""
    if mode == "tradesetup":
        trade_levels_note = (
            "\n**TRADE LEVELS**: Omitted — regenerate when Oracle AI is available.\n"
        )

    body = f"""**Asset**: {coin} | ${price:,.4f} | —

**Overall Bias**: Neutral (Confidence: 0%)

**Oracle Status**: {mode_label} could not be generated right now.

**Key Drivers**:
• Live price (${price:,.4f}) from {source} was captured successfully
• AI engine error: {reason}
• Tap Quick Analyze or Trade Setup again in 1–2 minutes

**Confluence Summary**: No AI edge this request — infrastructure timeout or upstream outage.

**If I Were to Trade Today...**: Stand flat until Oracle AI completes a full read. Forced entries without the model are negative EV.

**Risks & Watchlist**:
• Grok/xAI latency or rate limits on Railway
• Verify `GROK_API_KEY` in Railway Variables if this repeats
{trade_levels_note}
"""
    return ensure_disclaimer(body.strip())


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
    logger.info(
        "grok_chat_request_start model=%s connect_s=%s read_s=%s history_msgs=%d user_chars=%d max_tokens=%d",
        GROK_MODEL,
        GROK_CONNECT_TIMEOUT,
        GROK_TIMEOUT,
        len(messages) - 1,
        len(message),
        max_tokens,
    )
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
            timeout=(GROK_CONNECT_TIMEOUT, GROK_TIMEOUT),
        )
    except requests.Timeout as exc:
        logger.error(
            "grok_chat_timeout connect_s=%s read_s=%s err=%s",
            GROK_CONNECT_TIMEOUT,
            GROK_TIMEOUT,
            exc,
        )
        raise HTTPException(
            status_code=504,
            detail=f"AI chat timed out after {GROK_TIMEOUT}s.",
        ) from exc
    except requests.RequestException as exc:
        logger.error("grok_chat_failed err=%s", exc, exc_info=True)
        raise HTTPException(status_code=502, detail="AI service unreachable.") from exc

    elapsed_ms = (time.perf_counter() - started) * 1000

    if response.status_code != 200:
        logger.error(
            "grok_chat_http_error status=%s elapsed_ms=%.0f body=%s",
            response.status_code,
            elapsed_ms,
            (response.text or "")[:400],
        )
        raise HTTPException(status_code=502, detail="AI service returned an error.")

    try:
        content = response.json()["choices"][0]["message"]["content"]
    except (KeyError, IndexError, ValueError) as exc:
        logger.error("grok_chat_malformed elapsed_ms=%.0f", elapsed_ms, exc_info=True)
        raise HTTPException(status_code=502, detail="Malformed AI response.") from exc

    logger.info(
        "grok_chat_request_complete elapsed_ms=%.0f response_chars=%d",
        elapsed_ms,
        len(content),
    )
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
    Master system prompt — seasoned leverage trader voice. Preserves exact Flutter headings.
    """
    scalp_active = f"""
═══════════════════════════════════════
⚡ SCALP MODE ACTIVE — BEST SETUP ON THE BOARD OR FLAT
═══════════════════════════════════════
Scalp / quick-move / scalping / short-term detected. Deliver the single highest-probability scalp on the
board RIGHT NOW — or state "NO SCALP — STAY FLAT" and OMIT **TRADE LEVELS**. Forcing a B-setup is how
accounts bleed.

SCALP DOCTRINE (mandatory when proposing a scalp):
• MTF MAP: Exact TFs — e.g. "5m execution | 15m structure | 1h veto". Horizon: minutes to ~90 min max.
• PRICE: Entry at live spot or named limit at OB/FVG/Daily VWAP — ≤0.8% drift majors, ≤1.2% high-beta alts.
• TRIGGER: Precise event — Daily VWAP reclaim/reject, EMA 5/20 displacement, liquidity sweep + reclaim,
  BOS/CHOCH retest, inducement grab + mitigation, RSI through 50 with volume expansion. Vague momentum = NO SCALP.
• ORDER FLOW / DERIVATIVES: Funding extreme + L/S skew + liq prints = who is trapped; counter crowded side or
  ride the cascade. OI rising into breakout = real; OI flat on rip = suspect.
• SL: Beyond sweep wick / micro structure / Daily VWAP failure — majors ~0.12–0.55%. State invalidation in
  price AND time ("dead after 12× 5m bars").
• TP1 (40% of position): Nearest liquidity pool / partial fill of FVG — ≥{MIN_RR_TP1:.1f}:1 R:R
  (target {TARGET_RR_TP1:.1f}:1+). TP2 (60% of position): Extension into next HTF pool only.
• PSYCH: Note FOMO trap, chase risk, or "no edge until X clears" when applicable.
• LABEL: **If I Were to Trade Today...** → "[Long/Short] SCALP Setup:" — trigger, invalidation, time-box.
"""

    scalp_standby = f"""
═══════════════════════════════════════
SCALP PROTOCOL (auto: scalp / quick move / scalping / short-term / ≤45m TF)
═══════════════════════════════════════
On scalp intent: surgical entry, Daily VWAP battlefield, order-flow + derivatives filter, micro SL,
≥{MIN_RR_TP1:.1f}:1 R:R on TP1. Best scalp available or explicit flat — half-measures are for tourists.
"""

    shared = f"""You are On-Chain Oracle AI — the voice of a seasoned, no-BS crypto leverage trader. You speak
to funded perp traders who live on liquidity sweeps, inducement, order blocks, FVGs, BOS/CHOCH, mitigation,
displacement, equal highs/lows, and liquidity grabs. Full-cycle survivor. Verdicts, not commentary.
You have seen every liquidation cascade, funding squeeze, and fake breakout — and you price them.

IDENTITY: Sharp, professional, relatable — like an experienced trader explaining setups to other leverage
traders. Maximum conviction. Zero fluff. Real money on every word. Call the trade, name the invalidation,
or command FLAT.

VOICE: Direct, confident, straightforward. Crisp clauses. Active verbs. Price-specific. Psychology-aware.
No hedge-fund jargon. No tutorial voice. No influencer hype.

FORBIDDEN (instant credibility kill):
"might", "could", "possibly", "perhaps", "maybe", "it seems", "appears to", "I think", "I believe",
"interesting", "worth watching", "mixed signals" without a verdict, "let me know", "would you like",
"consider", "potentially", "somewhat", "moderately", metric laundry lists, separate sentences for
funding/OI/L-S/liqs, chatbot warmth, tutorial tone.
AVOID hedge-fund jargon: "regime", "tape", "fade", "session" (use Daily VWAP / Previous Day VWAP instead).

REQUIRED LEXICON (woven naturally): liquidity sweep, inducement, order block, FVG (fair value gap),
BOS (break of structure), CHOCH, mitigation, displacement, equal highs/lows, liquidity grab, invalidation,
acceptance, rejection, liquidity pool, premium/discount, crowded longs/shorts, squeeze fuel, cascade,
trapped positioning, stop run, breaker, imbalance, HTF veto, Daily VWAP, Previous Day VWAP.

═══════════════════════════════════════
RULE 0 — LIVE PRICE (ZERO TOLERANCE)
═══════════════════════════════════════
• User prompt = sole authoritative price. Never memory. Never round for convenience.
• **Asset**: EXACT coin | live price | 24h % from prompt.
• Entry / TP1 / TP2 / SL anchored to live NOW. State drift % vs spot when entry is a limit.
• Long: SL < Entry < TP1 ≤ TP2. Short: TP2 ≤ TP1 < Entry < SL. Wrong geometry → fix or omit levels.

═══════════════════════════════════════
RULE 1 — RISK:REWARD & LEVEL PRECISION (NON-NEGOTIABLE)
═══════════════════════════════════════
• Minimum {MIN_RR_TP1:.1f}:1 R:R on TP1 vs |Entry − SL|. Target {TARGET_RR_TP1:.1f}:1+. Never ship <2.0:1.
• TRADE LEVELS — exact parser format (Oracle Citadel / Flutter):
  Entry at $XXXXX, TP1 (40%) at $XXXXX, TP2 (60%) at $XXXXX, SL at $XXXXX (R:R X.X:1)
  Then inline: Reward = |TP1 − Entry| = $X | Risk = |Entry − SL| = $X | R:R = X.X:1
• TP1 (40% of position) = first high-probability liquidity objective (Citadel MARKET closes 40% here).
• TP2 (60% of position) = structural extension / runner (Citadel closes remaining 60% here).
• SL = invalidation beyond sweep, OB loss, or Daily VWAP failure — not arbitrary %.
• No valid ≥{MIN_RR_TP1:.1f}:1 → OMIT **TRADE LEVELS**. Capital preservation wins.

═══════════════════════════════════════
RULE 2 — ADVANCED CONFLUENCE STACK
═══════════════════════════════════════
• MTF: Weekly/Daily/4h bias → requested TF direction → LTF trigger. State ALIGNED or CONFLICTED; conflict
  slashes confidence and demands patience unless a catalyst overrides (funding flip, liq cascade).
• VWAP: Daily VWAP, Previous Day VWAP, weekly, monthly — premium vs discount, clusters within ~0.3–0.8%,
  acceptance/rejection, mean-reversion magnets. Never say "session VWAP".
• STRUCTURE: BOS/CHOCH, order blocks, FVGs, inducement, mitigation, displacement, range highs/lows,
  equal highs/lows (liquidity targets), liquidity sweeps and grabs.
• MOMENTUM: EMA 5/20 stack, RSI (>50 bull / <50 bear) + divergence only WITH structure,
  MACD histogram expansion/contraction, volume on breaks vs fakeouts.
• ON-CHAIN / MOBULA (when MOBULA block present — mandatory): DEX liquidity, on-chain vs CEX volume mix,
  slippage/trap risk, spot-led vs perp-led flow. Weave into VWAP read AND **Liquidity & Sentiment** lead.
• MACRO (when relevant): BTC/ETH risk tone, DXY/rates proxy read, risk-on/off filter for alts.
• PREMIUM BREVITY: Tight trader prose. No filler. Each **Key Drivers** bullet: 2–4 crisp sentences max.
  One positioning story in **Liquidity & Sentiment** — never repeat Mobula numbers in **Technicals**.

═══════════════════════════════════════
RULE 3 — LEVERAGE & DERIVATIVES MASTERY (prose integration — NOT a data dump)
═══════════════════════════════════════
User prompt supplies live Binance Futures: funding rate, open interest, 5m long/short accounts,
recent liquidations. Mobula may add liquidity/volume context.

**Liquidity & Sentiment** — ONE authoritative paragraph:
  Tell the positioning story: Who is crowded? Who just got liquidated? Is OI rising with price
  (new money) or rising against price (shorts adding)? Is funding paying shorts to hold the book?
  Are liqs fueling continuation or marking exhaustion? Tie to order flow (stop runs, cascade risk,
  squeeze setup, liquidity grab). Read like a leverage trader sizing a perp — never "Funding is X. OI is Y."

**Confluence Summary** — EXACTLY one sentence. Grade STRONG / MODERATE / WEAK. Fuse structure + VWAP +
  momentum + derivatives + liquidity when available.

Derivatives OVERRIDE or CONFIRM technical bias: extreme positive funding + crowded longs = counter-long fuel;
negative funding + rising OI + short liqs = squeeze blueprint; OI collapse after spike = move spent.

═══════════════════════════════════════
RULE 4 — CONVICTION, PSYCHOLOGY & EDGE CASES
═══════════════════════════════════════
• **Overall Bias**: Mildly Bullish / Mildly Bearish / Neutral + Confidence %. 80%+ requires MTF +
  structure + derivatives + liquidity alignment. Neutral = discipline, not indecision.
• **If I Were to Trade Today...**: Execution card — NOT a summary. Labeled lines:
  Trigger | Entry (market/limit + level) | Invalidation (price + break) | Time box | Size stance |
  Thesis flip | Plan B or STAND DOWN. Scalp → "[Long/Short] SCALP Setup:" with minutes-level trigger.
  If flat: state exactly what must print before you deploy capital.
• **Risks & Watchlist**: 2–3 bullets — killer scenarios, event risk, level breaks that void thesis,
  psychological traps (chase, revenge, over-leverage after win).
• WEAK / conflicted / no catalyst → NO **TRADE LEVELS**. "Stand down" is a position.

═══════════════════════════════════════
RULE 5 — DISCLAIMER (terminal — exact text)
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
- [Long/Short] Setup: (or [Long/Short] SCALP Setup: if scalping)
  Trigger: ... | Entry: ... | Invalidation: ... | Time box: ... | Size: ... | Flip if: ... | Plan B: ...

**Risks & Watchlist**:
- 2-3 bullet points max.

**TRADE LEVELS** (when applicable):
Entry at $XXXXX, TP1 (40%) at $XXXXX, TP2 (60%) at $XXXXX, SL at $XXXXX (R:R X.X:1)

**Disclaimer**: (exact line above)
"""

    if mode == "tradesetup":
        return (
            shared
            + f"""
═══════════════════════════════════════
MODE: TRADE SETUP — ONE SHOT, EXECUTION-READY
═══════════════════════════════════════
• Deliver ONE A+ leverage setup. Long OR Short per direction lock. No A/B menus.
• **TRADE LEVELS** mandatory unless no ≥{MIN_RR_TP1:.1f}:1 edge exists — then defend flat in **If I Were to Trade Today...**
  with the exact trigger that would unlock the trade (price + structure + derivatives reset).
• **If I Were to Trade Today...** must read like an execution card: executable trigger, not commentary.
• Confluence bar: Daily VWAP + order blocks/FVGs + structure + momentum + funding/OI/L-S/liqs.
• TP1 (40% of position) ≥ {MIN_RR_TP1:.1f}:1 (target {TARGET_RR_TP1:.1f}:1+). TP2 (60% of position) =
  next liquidity pool / HTF objective.
• Include invalidation price, optional runner logic, and leverage-awareness (cascade/squeeze risk).
• Scalp TF: full SCALP DOCTRINE — no weak entries.
"""
        )

    return (
        shared
        + f"""
═══════════════════════════════════════
MODE: MARKET ANALYSIS — VERDICT FIRST, LEVELS WHEN EARNED
═══════════════════════════════════════
• Lead with bias and edge. Integrate macro tone, derivatives, and on-chain liquidity when provided.
• **TRADE LEVELS** only on MODERATE/STRONG confluence with ≥{MIN_RR_TP1:.1f}:1 R:R — otherwise omit and
  state what must develop before capital is deployed.
• WEAK / MTF conflict / crowded positioning without catalyst → flat is the professional call.
"""
    )


# ---------------------------------------------------------------------------
# Oracle Trader AI Chat — veteran desk (POST /chat only)
# ---------------------------------------------------------------------------

_CHAT_COIN_PATTERN = re.compile(
    r"\b("
    r"BTC|ETH|SOL|BNB|XRP|ADA|DOGE|AVAX|LINK|DOT|MATIC|POL|LTC|TRX|SHIB|"
    r"ATOM|UNI|NEAR|APT|ARB|OP|SUI|PEPE|WIF|BONK|HYPE|RENDER|FET|TAO|INJ"
    r")\b",
    re.IGNORECASE,
)


def detect_chat_coin_symbol(*texts: str) -> Optional[str]:
    """Best-effort ticker from user message + history (for live context injection)."""
    for blob in texts:
        if not blob:
            continue
        match = _CHAT_COIN_PATTERN.search(blob.upper())
        if match:
            return match.group(1).upper()
    return None


def build_chat_market_context_note(coin: str) -> tuple[str, list[str]]:
    """
    Pull live context for chat (Mobula → snapshot fallback + derivatives).
    Returns (context block, limitation notes) — never raises; safe for chat.
    """
    upper = coin.upper()
    lines: list[str] = [f"═══ LIVE DESK DATA — {upper} (server-fed, use in your answer) ═══"]
    limitations: list[str] = []

    mobula = fetch_mobula_price(upper)
    price: Optional[float] = None
    if mobula:
        price = float(mobula["price"])
        lines.append(
            f"Price: {format_usd(price)} | 24h {mobula['change_24h_pct']:+.2f}% | source: Mobula (depth-weighted)"
        )
        if mobula.get("liquidity_usd"):
            lines.append(f"DEX liquidity: ${mobula['liquidity_usd']:,.0f}")
        if mobula.get("on_chain_volume_usd") or mobula.get("off_chain_volume_usd"):
            lines.append(
                f"Volume 24h — on-chain: ${float(mobula.get('on_chain_volume_usd') or 0):,.0f} | "
                f"off-chain: ${float(mobula.get('off_chain_volume_usd') or 0):,.0f}"
            )
    else:
        limitations.append(f"Mobula live quote unavailable for {upper}")
        try:
            snap = fetch_market_snapshot(upper)
            price = float(snap["price"])
            lines.append(
                f"Price: {format_usd(price)} | 24h {snap['change_24h_pct']:+.2f}% | source: {snap.get('source', 'fallback')}"
            )
        except HTTPException:
            limitations.append(f"No live price feed for {upper} — analyze from principles; ask user for symbol/chart")

    try:
        deriv = fetch_derivatives_snapshot(upper, spot_price=price)
        if deriv.get("has_futures_data"):
            lines.append(f"Funding: {deriv.get('funding_label', 'n/a')}")
            lines.append(f"Open interest: {deriv.get('oi_label', 'n/a')}")
            lines.append(f"Positioning: {deriv.get('ls_label', 'n/a')}")
            lines.append(f"Liquidations: {deriv.get('liq_label', 'n/a')}")
        else:
            limitations.append("Binance Futures derivatives snapshot unavailable")
    except Exception as exc:
        logger.debug("chat_derivatives_context_skip coin=%s err=%s", upper, exc)
        limitations.append("Derivatives data temporarily unavailable")

    if limitations:
        lines.append("DATA GAPS (state briefly to user after delivering value): " + "; ".join(limitations))

    return "\n".join(lines), limitations


def enrich_chat_user_message(
    message: str,
    history: list[dict[str, str]],
) -> tuple[str, Optional[str]]:
    """Append live market context when a coin is mentioned."""
    history_blob = " ".join(item.get("content", "") for item in history[-6:])
    coin = detect_chat_coin_symbol(message, history_blob)
    if not coin:
        return message.strip(), None

    context_note, _ = build_chat_market_context_note(coin)
    enriched = (
        f"{message.strip()}\n\n"
        f"[Server context for {coin} — use if relevant, do not recite as a raw data dump]\n"
        f"{context_note}"
    )
    return enriched, coin


def default_chat_system_prompt() -> str:
    """Master chat persona — aligned with analyze/trade-setup leverage trader identity."""
    return f"""You are Oracle Trader AI — the same seasoned, no-BS crypto leverage trader behind On-Chain Oracle
AI reports. You speak to funded perp traders who watch liquidity sweeps, inducement, order blocks, FVGs,
BOS/CHOCH, mitigation, displacement, equal highs/lows, and liquidity grabs. Calm, decisive, never defensive.

MISSION: Every reply must deliver REAL EDGE — even on vague questions. You always attempt a full trader-quality
read with whatever you have. If data is thin, you still call structure, scenarios, and risk — then state
limitations in one short line at the end. Never open with "I can't" or "I'm unable" without first giving
actionable value.

VOICE: Sharp, professional, relatable — like an experienced leverage trader on a live call. Short paragraphs.
Price-specific when possible. Zero fluff. Zero excuses. No influencer hype. No tutorial voice.
AVOID hedge-fund jargon: "regime", "tape", "fade", "session". Use Daily VWAP and Previous Day VWAP.

FORBIDDEN OPENERS / FILLER:
"I can't", "I'm unable", "I don't have access" (without prior value), "might", "could", "maybe",
"possibly", "it seems", "as an AI", hedging without a verdict, metric laundry lists, apologizing.

REQUIRED BEHAVIOR:
• LEAD WITH THE CALL: bias, edge, or flat — then support it (MTF, Daily VWAP, structure, derivatives).
• LEVERAGE MASTERY: funding, OI, long/short ratio, liquidation cascades, squeeze/cascade, crowded side,
  order flow, stop runs, liquidity pools, liquidity sweeps, inducement, mitigation.
• TECHNICAL DEPTH: Daily VWAP, Previous Day VWAP, weekly/monthly VWAP, order blocks, FVGs, BOS/CHOCH,
  premium/discount, equal highs/lows, displacement, HTF/LTF alignment, macro risk-on/off for alts.
• LEVELS (when user wants a trade): Entry at $X, TP1 (40%) at $X, TP2 (60%) at $X, SL at $X (R:R X.X:1).
  TP1 = 40% of position (min {MIN_RR_TP1:.1f}:1 R:R, target {TARGET_RR_TP1:.1f}:1+). TP2 = 60% runner.
  SL = structural invalidation beyond sweep/OB/Daily VWAP.
• RISK & PSYCH: size for invalidation, FOMO/chase/revenge, event risk, when to stand down.
• PROACTIVE TRADER SERVICE — end EVERY reply with:
  — 1–2 sharp follow-up questions (specific, not generic), AND
  — 1 concrete next step (e.g. "pull 15m for trigger", "watch funding flip", "stand aside until Daily VWAP reclaim").
• ALTERNATIVES: when main idea is weak, offer Plan A / Plan B (e.g. breakout long vs short into resistance).
• Server-fed [LIVE DESK DATA] blocks are authoritative when present — weave into prose, not bullet dumps.
• Do NOT append the formal report disclaimer unless user asks for a full written report.
• Chat format: conversational markdown OK; no mandatory report headings unless user requests a full report.

You are talking to a leverage trader who paid for edge. Sound like you have real money on the line."""


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
        trade_block = f"""
**TRADE LEVELS** (MANDATORY unless truly no edge — exact format, min {MIN_RR_TP1:.1f}:1 R:R, target {TARGET_RR_TP1:.1f}:1+):
Entry at $XXXXX, TP1 (40%) at $XXXXX, TP2 (60%) at $XXXXX, SL at $XXXXX (R:R X.X:1)
Reward = |TP1 − Entry| = $X | Risk = |Entry − SL| = $X | R:R = X.X:1
TP1 (40% of position) = first liquidity pool / partial FVG fill. TP2 (60% of position) = HTF extension.
SL = structural invalidation.
"""
    else:
        trade_block = f"""
**TRADE LEVELS** (only if ≥{MIN_RR_TP1:.1f}:1 R:R edge exists — otherwise OMIT this section entirely):
Entry at $XXXXX, TP1 (40%) at $XXXXX, TP2 (60%) at $XXXXX, SL at $XXXXX (R:R X.X:1)
Reward = |TP1 − Entry| = $X | Risk = |Entry − SL| = $X | R:R = X.X:1
TP1 (40% of position) = first target. TP2 (60% of position) = runner / HTF extension.
"""

    return f"""
Deliver using this **exact structure** (headings unchanged — maximum depth inside each section):

**Asset**: {coin} | {price_str} | {change_pct:+.2f}%

**Overall Bias**: [Mildly Bullish / Mildly Bearish / Neutral] (Confidence: XX%)
State HTF bias, HTF veto, and whether derivatives confirm or fight the read.

**Key Drivers**:
- Volume-Weighted Analysis: Daily VWAP, Previous Day VWAP, weekly / monthly VWAP — premium vs discount,
  acceptance vs rejection, cluster zones (~0.3–0.8%), mean-reversion vs trend continuation.
- Liquidity & Sentiment: ONE paragraph — funding, OI delta, long/short positioning, recent liqs,
  cascade/squeeze risk, order-flow implication. Mobula liquidity/volume if in prompt. No metric list.
- Heikin Ashi Analysis: Trend quality, indecision wicks, reversal vs continuation read on requested TF.
- Fibonacci Retracements: Active retracement zone (0.382–0.618 etc.), golden pocket confluence with VWAP/OB.
- Technicals: MACD, RSI, EMAs — momentum read, divergence only with structure, volume confirmation on breaks.
- Market Structure: BOS/CHOCH, order blocks, FVGs, inducement, mitigation, displacement, equal highs/lows,
  liquidity sweeps/grabs, range boundaries, liquidity targets.

**Confluence Summary**: Exactly ONE sentence. Grade STRONG / MODERATE / WEAK. State the edge in plain
trader language — fuse technicals + derivatives + liquidity.

**If I Were to Trade Today...**
- [Long/Short] Setup: (or [Long/Short] SCALP Setup: if scalping)
  Write as an execution card (keep labels; one line each):
  Trigger: [exact event — Daily VWAP reclaim/reject, sweep+hold, BOS retest, inducement+mitigation, funding flip]
  Entry: [market now | limit at $X OB/FVG] — drift vs live spot if limit
  Invalidation: [$X + what structure breaks] — hard stop thesis
  Time box: [bars / hours — especially scalps]
  Size: [full | half | stand down — FOMO/chase/event risk]
  Flip if: [price + condition that makes opposite true]
  Plan B: [breakout vs counter-trend alternate] OR "STAND DOWN — [one line what must develop]"
  Mobula-led assets: reference liquidity/volume mix once (slippage or trap), not a data dump.

**Risks & Watchlist**:
- 2–3 bullets: killer invalidation scenarios, macro/event risk, psychological traps, edge cases.

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
    mobula_block = format_mobula_market_prompt_block(market)
    market_fallback_note = format_market_data_fallback_note(market)
    has_mobula = market.get("source") == "mobula"
    has_blofin = market.get("source") in {"blofin", "blofin_demo"}

    scalp_banner = ""
    if scalp_mode:
        scalp_banner = f"""
═══ ⚡ SCALP / QUICK-MOVE — SURGICAL OR FLAT ═══
Deliver the single best scalp on the board: live-price entry, named trigger (Daily VWAP/OB/sweep/BOS/CHOCH),
funding/OI/L-S filter, micro invalidation, time-box. Label "[Long/Short] SCALP Setup". TP1 ≥{MIN_RR_TP1:.1f}:1 R:R.
Weak edge → "NO SCALP — STAY FLAT" and OMIT **TRADE LEVELS**.
"""

    price_raw = f"{price:.8f}".rstrip("0").rstrip(".")
    max_entry_drift = "0.8%" if scalp_mode else "3%"

    fetched_at = market.get("fetched_at")
    price_source = market.get("source", "unknown")
    freshness_line = ""
    if fetched_at:
        ts = datetime.fromtimestamp(float(fetched_at), tz=timezone.utc).strftime(
            "%Y-%m-%d %H:%M:%S UTC"
        )
        age_sec = max(0.0, time.time() - float(fetched_at))
        source_note = {
            "mobula": "Mobula depth-weighted live feed",
            "coingecko": "CoinGecko aggressive pull (cache-busted)",
            "binance_spot": "Binance spot 24h ticker",
            "binance_futures": "Binance futures 24h ticker",
            "blofin": "BloFin live mark price (user-linked exchange)",
            "blofin_demo": "BloFin Demo mark price (user-linked exchange)",
        }.get(price_source, price_source)
        freshness_line = (
            f"PRICE FETCHED AT: {ts} ({age_sec:.2f}s ago — {source_note})\n"
            f"USE THIS PRICE ONLY: all Entry/TP/SL must anchor to {price_str} as of this timestamp.\n"
        )

    mode_label = "TRADE SETUP (execution-ready)" if mode == "tradesetup" else "MARKET ANALYSIS"
    mobula_priority = (
        "MOBULA DATA IS LIVE — liquidity, on-chain vs CEX volume, and pool depth MUST shape bias, "
        "Liquidity & Sentiment, and your trade card. Lead with on-chain/liquidity read when relevant."
        if has_mobula
        else (
            "BLOFIN MARK PRICE IS LIVE — user-linked exchange tick; anchor Entry/TP/SL to this mark for "
            "execution parity with Oracle Citadel. Cross-check structure + derivatives."
            if has_blofin
            else "No Mobula tick — do not fabricate on-chain stats; lean on derivatives + structure."
        )
    )
    mode_close = (
        "TRADE SETUP MODE: One shot. **TRADE LEVELS** required unless flat — then execution card explains "
        "what unlocks the trade. **If I Were to Trade Today...** = execution card (Trigger/Entry/Invalidation/...)."
        if mode == "tradesetup"
        else "ANALYSIS MODE: Verdict-first. **TRADE LEVELS** only if edge ≥ "
        f"{MIN_RR_TP1:.1f}:1 — else omit and use **If I Were to Trade Today...** for stand-down + unlock conditions."
    )

    return f"""Generate a premium, high-conviction On-Chain Oracle AI report — seasoned leverage trader voice.
{mode_label}. Decisive. Zero hedging. {mobula_priority}
{scalp_banner}
═══════════════════════════════════════════════════════════
AUTHORITATIVE LIVE PRICE — RULE 0 (ZERO TOLERANCE)
═══════════════════════════════════════════════════════════
CURRENT LIVE PRICE: {price_str} (raw: {price_raw} USD)
24h CHANGE: {change_pct:+.2f}%
SOURCE: {market.get('source', 'unknown')}
{freshness_line}MANDATORY:
• **Asset** line EXACTLY: {coin.upper()} | {price_str} | {change_pct:+.2f}%
• Every Entry / TP1 (40%) / TP2 (60%) / SL vs {price_str} NOW — limits must name structure (OB, FVG, Daily VWAP, pool).
• **TRADE LEVELS** one-liner MUST use: Entry at $X, TP1 (40%) at $X, TP2 (60%) at $X, SL at $X (R:R X.X:1)
• Entry within ~{max_entry_drift} of live for {'scalp' if scalp_mode else 'active'} unless limit at level.
• Long: SL < Entry < TP1 ≤ TP2. Short: TP2 ≤ TP1 < Entry < SL. Show R:R math inline.
• Use Daily VWAP and Previous Day VWAP — never "session VWAP" or "previous session".

═══ REQUEST CONTEXT ═══
**Asset**: {coin.upper()} | {price_str} | {change_pct:+.2f}%
Timeframe: {timeframe} | Mode: {mode} | {mode_label}
Direction: {direction_instruction(direction)}
24h Volume (aggregate): {volume_text}

═══ LIVE MARKET DATA — ORDER OF AUTHORITY (synthesize; never list metrics alone) ═══
{mobula_block}{market_fallback_note}{derivatives_block}
Cross-check: Mobula liquidity/volume mix ↔ funding/OI/L-S/liqs ↔ Daily VWAP/structure on {timeframe}.
**Liquidity & Sentiment** opens with liquidity/trap/slippage read when Mobula present, then derivatives story.

═══ ANALYTICAL DEPTH CHECKLIST (Key Drivers — tight prose) ═══
• MTF: Weekly/Daily/4h → {timeframe} → LTF trigger. ALIGNED or CONFLICTED.
• Daily VWAP, Previous Day VWAP, premium/discount; tie to Mobula volume/flow character if provided.
• Order blocks, FVGs, BOS/CHOCH, inducement, mitigation, displacement, pools, liquidity sweeps/grabs.
• Macro (BTC/ETH risk-on/off) for alts when relevant.
• Psychology: chase/FOMO/revenge only when price invites the mistake.
• Voice: direct leverage trader — no "regime", "tape", "fade", or "session" jargon.

{mode_close}
**If I Were to Trade Today...** = execution card (Trigger | Entry | Invalidation | Time box | Size | Flip | Plan B).
Premium brevity: no repetition across sections. One verdict in **Confluence Summary**.

{report_structure_block(coin=coin.upper(), price=price, change_pct=change_pct, mode=mode)}

End with the exact disclaimer line only."""


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
    # Never block app boot if CoinGecko is slow — /health must come up for Railway.
    try:
        logger.info("startup | refreshing CoinGecko symbol index")
        refresh_coingecko_symbol_index(force=True)
    except Exception as exc:
        logger.warning("startup | CoinGecko index refresh failed (non-fatal): %s", exc, exc_info=True)

    logger.info(
        "startup | timeouts request=%ss grok_connect=%ss grok_read=%ss analyze_route=%ss "
        "uvicorn_keep_alive=%ss uvicorn_graceful_shutdown=%ss",
        REQUEST_TIMEOUT,
        GROK_CONNECT_TIMEOUT,
        GROK_TIMEOUT,
        ANALYZE_ROUTE_TIMEOUT,
        UVICORN_TIMEOUT_KEEP_ALIVE,
        UVICORN_TIMEOUT_GRACEFUL_SHUTDOWN,
    )
    if not GROK_API_KEY:
        logger.warning(
            "startup | GROK_API_KEY not set — set Railway Variable GROK_API_KEY "
            "or backend/.env locally; /analyze and /chat will return 500"
        )
    else:
        logger.info("startup | grok_model=%s configured (key present)", GROK_MODEL)
    yield
    logger.info("shutdown | shutting down Grok executor")
    _GROK_EXECUTOR.shutdown(wait=False, cancel_futures=True)


# redirect_slashes=False — avoids POST /analyze → 307 → /analyze/ (body lost → 404 on clients)
app = FastAPI(
    title="On-Chain Oracle AI API",
    version="2.5.0",
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

    try:
        response = await call_next(request)
    except HTTPException as exc:
        elapsed_ms = (time.perf_counter() - started) * 1000
        detail = exc.detail if isinstance(exc.detail, str) else str(exc.detail)
        logger.warning(
            "http_http_exception request_id=%s %s %s status=%s detail=%s elapsed_ms=%.1f",
            request_id,
            request.method,
            request.url.path,
            exc.status_code,
            detail,
            elapsed_ms,
        )
        return JSONResponse(
            status_code=exc.status_code,
            content={"success": False, "detail": detail, "request_id": request_id},
            headers={"X-Request-ID": request_id},
        )
    except Exception as exc:
        elapsed_ms = (time.perf_counter() - started) * 1000
        logger.exception(
            "http_unhandled request_id=%s %s %s elapsed_ms=%.1f err=%s",
            request_id,
            request.method,
            request.url.path,
            elapsed_ms,
            exc,
        )
        return JSONResponse(
            status_code=500,
            content={
                "success": False,
                "detail": "Internal server error. Check server logs.",
                "request_id": request_id,
            },
            headers={"X-Request-ID": request_id},
        )

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


@app.exception_handler(GrokError)
async def grok_error_handler(request: Request, exc: GrokError) -> JSONResponse:
    """Non-analyze routes still surface Grok failures as JSON errors."""
    req_id = getattr(request.state, "request_id", "?")
    logger.error(
        "grok_error_handler request_id=%s path=%s msg=%s upstream_status=%s",
        req_id,
        request.url.path,
        exc.user_message,
        exc.status_code,
    )
    return JSONResponse(
        status_code=502,
        content={
            "success": False,
            "detail": exc.user_message,
            "request_id": req_id,
            "error": "grok_unavailable",
        },
        headers={"X-Request-ID": req_id},
    )


@app.get("/")
async def root() -> dict[str, Any]:
    """Railway/public root — confirms service is this API (not a static 404 page)."""
    return {
        "service": "On-Chain Oracle AI API",
        "status": "ok",
        "health": "/health",
        "analyze": "POST /analyze (mode=analysis|tradesetup)",
        "trade_setup": "POST /trade-setup (alias)",
        "exchange_keys": "POST /exchange_keys (also POST /api/exchange_keys)",
        "execute_trade": "POST /execute_trade (also POST /api/execute_trade)",
    }


@app.get("/health")
async def health() -> dict[str, Any]:
    """
    Railway healthcheck + Flutter ping — must stay fast and never call Grok/CoinGecko.
    """
    try:
        return {
            "status": "ok",
            "version": "2.5.0",
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "grok_configured": bool(GROK_API_KEY),
            "grok_model": GROK_MODEL,
            "timeouts": {
                "grok_connect_seconds": GROK_CONNECT_TIMEOUT,
                "grok_read_seconds": GROK_TIMEOUT,
                "analyze_route_seconds": ANALYZE_ROUTE_TIMEOUT,
                "price_request_seconds": REQUEST_TIMEOUT,
                "uvicorn_keep_alive_seconds": UVICORN_TIMEOUT_KEEP_ALIVE,
                "uvicorn_graceful_shutdown_seconds": UVICORN_TIMEOUT_GRACEFUL_SHUTDOWN,
            },
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
                "exchange_keys": [
                    "POST /exchange_keys",
                    "POST /exchange_keys/",
                    "POST /api/exchange_keys",
                    "POST /api/exchange_keys/",
                ],
                "execute_trade": [
                    "POST /execute_trade",
                    "POST /execute_trade/",
                    "POST /api/execute_trade",
                    "POST /api/execute_trade/",
                ],
            },
            "citadel_encryption_configured": bool(CITADEL_ENCRYPTION_KEY),
        }
    except Exception as exc:
        # Last resort — still return 200 so Railway does not mark the service dead.
        logger.exception("health_endpoint_error: %s", exc)
        return {"status": "ok", "version": "2.5.0", "degraded": True}


@app.get("/live_price")
async def get_live_price(coin: str, user_id: Optional[str] = None) -> dict[str, Any]:
    """Lightweight live price for Oracle Vision / Trade Setup UI."""
    upper = (coin or "").strip().upper()
    if not upper:
        raise HTTPException(status_code=400, detail="coin is required.")
    uid = (user_id or "").strip() or None
    try:
        market = fetch_live_price_for_analysis(upper, user_id=uid)
    except HTTPException:
        raise
    except Exception as exc:
        logger.warning("live_price_endpoint_fail coin=%s err=%s", upper, exc)
        raise HTTPException(status_code=502, detail=f"Unable to fetch live price for {upper}.") from exc
    return {
        "success": True,
        "coin": upper,
        "price": market["price"],
        "change_24h_pct": market.get("change_24h_pct"),
        "source": market.get("source"),
        "fetched_at": market.get("fetched_at"),
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
    Grok runs in a thread pool with 120s-class timeouts; failures return a fallback report (not 502).
    """
    req_id = getattr(http_request.state, "request_id", "?")
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
    grok_fallback = False

    try:
        # Live market (BloFin when linked, else Mobula/CG/Binance) → prompts unchanged structurally
        user_id = (request.user_id or "").strip() or None
        market = fetch_live_price_for_analysis(coin, user_id=user_id)

        scalp_mode = is_scalp_context(
            timeframe=request.timeframe,
            direction=request.direction,
            mode=mode,
            system_prompt=request.system_prompt or "",
        )

        derivatives = fetch_derivatives_snapshot(coin, spot_price=float(market["price"]))

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

        logger.info(
            "analyze request_id=%s coin=%s mode=%s tf=%s dir=%s scalp=%s price=%.6f src=%s "
            "mobula_liq=%s on_chain_vol=%s deriv=%s",
            req_id,
            coin,
            mode,
            request.timeframe,
            direction,
            scalp_mode,
            market["price"],
            market.get("source"),
            market.get("liquidity_usd") if market.get("source") == "mobula" else None,
            market.get("on_chain_volume_usd") if market.get("source") == "mobula" else None,
            derivatives["has_futures_data"],
        )

        # Slightly lower temperature — tighter, more decisive veteran voice (same headings)
        temperature = 0.34 if scalp_mode else (0.36 if mode == "analysis" else 0.33)
        max_tokens = 1750 if mode == "tradesetup" or scalp_mode else 1520

        try:
            report = await run_grok_in_executor(
                system_prompt=system_prompt,
                user_prompt=user_prompt,
                temperature=temperature,
                max_tokens=max_tokens,
            )
        except asyncio.TimeoutError as exc:
            grok_fallback = True
            reason = f"analyze route exceeded {ANALYZE_ROUTE_TIMEOUT}s"
            logger.error(
                "analyze_grok_timeout request_id=%s coin=%s mode=%s %s",
                req_id,
                coin,
                mode,
                reason,
                exc_info=True,
            )
            report = build_analyze_fallback_report(
                coin=coin, mode=mode, market=market, reason=reason
            )
        except GrokError as exc:
            grok_fallback = True
            logger.error(
                "analyze_grok_failed request_id=%s coin=%s mode=%s msg=%s http=%s body=%s",
                req_id,
                coin,
                mode,
                exc.user_message,
                exc.status_code,
                (exc.response_body or "")[:200],
                exc_info=exc.cause is not None,
            )
            report = build_analyze_fallback_report(
                coin=coin, mode=mode, market=market, reason=exc.user_message
            )

        report = ensure_disclaimer(report)
        if not grok_fallback:
            try:
                audit_trade_levels(report, float(market["price"]), scalp_mode=scalp_mode)
            except HTTPException as audit_exc:
                logger.warning(
                    "analyze_trade_audit_failed request_id=%s coin=%s detail=%s",
                    req_id,
                    coin,
                    audit_exc.detail,
                )

        return {
            "success": True,
            "coin": coin,
            "current_price": market["price"],
            "price_source": market.get("source"),
            "report": report,
            "grok_fallback": grok_fallback,
        }

    except HTTPException:
        raise
    except Exception as exc:
        logger.exception(
            "analyze_unhandled request_id=%s coin=%s mode=%s err=%s",
            req_id,
            coin,
            mode,
            exc,
        )
        raise HTTPException(
            status_code=500,
            detail="Analyze request failed unexpectedly. Check server logs.",
        ) from exc


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

    try:
        review_text = call_grok(
            system_prompt=build_review_system_prompt(),
            user_prompt=build_review_user_prompt(coin, previous_report, market),
            temperature=0.50,
            max_tokens=1150,
        )
    except GrokError as exc:
        logger.error("review_grok_failed request_id=%s coin=%s msg=%s", req_id, coin, exc.user_message)
        return JSONResponse(
            status_code=502,
            content={
                "success": False,
                "detail": exc.user_message,
                "coin": coin,
                "request_id": req_id,
                "error": "grok_unavailable",
            },
            headers={"X-Request-ID": req_id},
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
    """
    Expert Oracle Trader AI chat — server-side veteran prompt + optional live market injection.
    Client system_prompt is ignored so chat stays aligned with analyze/trade-setup identity.
    """
    message = request.message.strip()
    if not message:
        raise HTTPException(status_code=400, detail="message is required.")

    req_id = getattr(http_request.state, "request_id", "?")
    history = [{"role": m.role, "content": m.content} for m in request.history]

    # Always use backend veteran prompt (Flutter legacy system_prompt not applied to chat).
    system_prompt = default_chat_system_prompt()
    client_prompt_len = len((request.system_prompt or "").strip())
    if client_prompt_len:
        logger.info(
            "chat_client_system_prompt_ignored request_id=%s client_chars=%d using=server_veteran_prompt",
            req_id,
            client_prompt_len,
        )

    enriched_message, context_coin = enrich_chat_user_message(message, history)

    logger.info(
        "chat_request request_id=%s msg_len=%d history=%d context_coin=%s enriched_len=%d",
        req_id,
        len(message),
        len(history),
        context_coin or "none",
        len(enriched_message),
    )

    try:
        reply = call_grok_chat(
            system_prompt=system_prompt,
            history=history,
            message=enriched_message,
            temperature=0.62,
            max_tokens=1400,
        )
    except HTTPException:
        raise
    except Exception as exc:
        logger.exception("chat_unhandled request_id=%s err=%s", req_id, exc)
        raise HTTPException(
            status_code=500,
            detail="Chat failed unexpectedly. Retry in a moment.",
        ) from exc

    logger.info(
        "chat_success request_id=%s reply_chars=%d context_coin=%s",
        req_id,
        len(reply),
        context_coin or "none",
    )

    return {
        "success": True,
        "reply": reply,
        "request_id": req_id,
        "context_coin": context_coin,
    }


async def _handle_exchange_keys(http_request: Request) -> JSONResponse:
    """
    POST /exchange_keys — persist Oracle Citadel credentials (encrypted secret on disk).

    Accepts (body JSON, any combination):
      user_id, app_api_key, exchange_api_key, exchange_secret, risk_percent
    Flutter aliases: api_key, api_secret, demo_mode / use_demo_mode, X-API-Key header.

    Also mounted at /api/exchange_keys (same handler) to avoid 404 when clients use /api prefix.
    """
    req_id = getattr(http_request.state, "request_id", "?")
    path = http_request.url.path
    header_app_key = (http_request.headers.get("X-API-Key") or http_request.headers.get("x-api-key") or "").strip()

    logger.info(
        "exchange_keys_request_start request_id=%s path=%s has_x_api_key=%s content_type=%s",
        req_id,
        path,
        bool(header_app_key),
        http_request.headers.get("content-type", ""),
    )

    try:
        raw_body = await http_request.json()
    except json.JSONDecodeError as exc:
        logger.warning(
            "exchange_keys_invalid_json request_id=%s path=%s err=%s",
            req_id,
            path,
            exc,
        )
        return JSONResponse(
            status_code=400,
            content={
                "success": False,
                "detail": "Request body must be valid JSON.",
                "user_message": "Invalid request. Send JSON with user_id and exchange keys.",
                "request_id": req_id,
            },
            headers={"X-Request-ID": req_id},
        )

    if not isinstance(raw_body, dict):
        return JSONResponse(
            status_code=400,
            content={
                "success": False,
                "detail": "Request body must be a JSON object.",
                "user_message": "Invalid request format.",
                "request_id": req_id,
            },
            headers={"X-Request-ID": req_id},
        )

    body_keys = sorted(raw_body.keys())
    logger.info(
        "exchange_keys_body_keys request_id=%s keys=%s risk_percent=%s exchange=%s demo=%s",
        req_id,
        body_keys,
        raw_body.get("risk_percent"),
        raw_body.get("exchange"),
        raw_body.get("use_demo_mode", raw_body.get("demo_mode")),
    )

    try:
        request = _parse_exchange_keys_request(raw_body, header_app_key=header_app_key)
    except ValidationError as exc:
        logger.warning(
            "exchange_keys_validation_failed request_id=%s errors=%s",
            req_id,
            exc.errors(),
        )
        return JSONResponse(
            status_code=422,
            content={
                "success": False,
                "detail": "Invalid exchange keys payload.",
                "user_message": "Check user_id, exchange API key, secret, and risk percent.",
                "errors": exc.errors(),
                "request_id": req_id,
            },
            headers={"X-Request-ID": req_id},
        )

    user_id = request.user_id.strip()
    app_api_key = (request.app_api_key or header_app_key).strip()

    if not user_id:
        return JSONResponse(
            status_code=400,
            content={
                "success": False,
                "detail": "user_id is required.",
                "user_message": "User ID is required for Oracle Citadel.",
                "request_id": req_id,
            },
            headers={"X-Request-ID": req_id},
        )

    if not app_api_key:
        logger.warning(
            "exchange_keys_missing_app_api_key request_id=%s user_id=%s path=%s",
            req_id,
            user_id,
            path,
        )
        return JSONResponse(
            status_code=400,
            content={
                "success": False,
                "detail": "app_api_key is required (body field app_api_key or X-API-Key header).",
                "user_message": "App API Key is required for Oracle Citadel.",
                "request_id": req_id,
            },
            headers={"X-Request-ID": req_id},
        )

    if header_app_key and request.app_api_key and header_app_key != request.app_api_key:
        return JSONResponse(
            status_code=400,
            content={
                "success": False,
                "detail": "X-API-Key header does not match app_api_key in body.",
                "user_message": "App API Key mismatch. Use the same key in the header and form.",
                "request_id": req_id,
            },
            headers={"X-Request-ID": req_id},
        )

    exchange_api_key = request.exchange_api_key.strip()
    exchange_secret = request.exchange_secret.strip()
    if not exchange_api_key or not exchange_secret:
        return JSONResponse(
            status_code=400,
            content={
                "success": False,
                "detail": "exchange_api_key and exchange_secret are required.",
                "user_message": "Exchange API Key and Secret are required.",
                "request_id": req_id,
            },
            headers={"X-Request-ID": req_id},
        )

    profile = resolve_citadel_exchange_profile(request.exchange, request.use_demo_mode)
    if profile.get("demo_rejected"):
        return JSONResponse(
            status_code=400,
            content={
                "success": False,
                "detail": "Demo/Testnet mode is only supported for BloFin (exchange must contain 'blofin').",
                "user_message": "Demo mode is for BloFin only. Turn off Demo or set exchange to blofin.",
                "request_id": req_id,
            },
            headers={"X-Request-ID": req_id},
        )

    if not CITADEL_ENCRYPTION_KEY:
        logger.warning(
            "exchange_keys_encryption_key_missing request_id=%s user_id=%s "
            "(using dev fallback — set CITADEL_ENCRYPTION_KEY on Railway)",
            req_id,
            user_id,
        )

    try:
        saved_profile = save_exchange_keys_record(
            user_id=user_id,
            app_api_key=app_api_key,
            exchange_api_key=exchange_api_key,
            exchange_secret=exchange_secret,
            risk_percent=float(request.risk_percent),
            exchange=request.exchange,
            use_demo_mode=request.use_demo_mode,
        )
        if saved_profile.get("blofin_demo"):
            logger.info(
                "exchange_keys_saved request_id=%s user_id=%s exchange=blofin environment=demo "
                "base_url=%s risk_percent=%.2f persisted=%s store_users=%s file_bytes=%s enc=%s path=%s",
                req_id,
                user_id,
                saved_profile.get("api_base_url"),
                request.risk_percent,
                saved_profile.get("persisted"),
                saved_profile.get("store_user_count"),
                saved_profile.get("store_file_bytes"),
                saved_profile.get("encryption_prefix"),
                _CITADEL_KEYS_FILE,
            )
        else:
            logger.info(
                "exchange_keys_saved request_id=%s user_id=%s exchange=%s environment=%s "
                "demo_mode=%s risk_percent=%.2f persisted=%s store_users=%s file_bytes=%s enc=%s path=%s",
                req_id,
                user_id,
                saved_profile.get("exchange"),
                saved_profile.get("environment"),
                request.use_demo_mode,
                request.risk_percent,
                saved_profile.get("persisted"),
                saved_profile.get("store_user_count"),
                saved_profile.get("store_file_bytes"),
                saved_profile.get("encryption_prefix"),
                _CITADEL_KEYS_FILE,
            )
        return JSONResponse(
            status_code=200,
            content={
                "success": True,
                "saved": True,
                "user_id": user_id,
                "message": "Exchange keys saved securely.",
                "exchange": saved_profile.get("exchange"),
                "environment": saved_profile.get("environment"),
                "api_base_url": saved_profile.get("api_base_url"),
                "use_demo_mode": request.use_demo_mode,
                "risk_percent": request.risk_percent,
                "persisted": saved_profile.get("persisted", True),
            },
            headers={"X-Request-ID": req_id},
        )
    except (OSError, ValueError) as exc:
        logger.exception(
            "exchange_keys_save_failed request_id=%s user_id=%s path=%s store=%s err=%s",
            req_id,
            user_id,
            path,
            _CITADEL_KEYS_FILE,
            exc,
        )
        return JSONResponse(
            status_code=500,
            content={
                "success": False,
                "detail": "Could not persist exchange keys on the server.",
                "user_message": "Server could not save your keys. Try again or contact support.",
                "request_id": req_id,
            },
            headers={"X-Request-ID": req_id},
        )


async def _handle_exchange_keys_status(http_request: Request) -> JSONResponse:
    """GET /exchange_keys/status — verify server has linked keys for user_id (no secrets returned)."""
    req_id = getattr(http_request.state, "request_id", "?")
    header_app_key = (http_request.headers.get("X-API-Key") or http_request.headers.get("x-api-key") or "").strip()
    user_id = (http_request.query_params.get("user_id") or "").strip()

    if not user_id:
        return JSONResponse(
            status_code=400,
            content={
                "success": False,
                "linked": False,
                "detail": "user_id query parameter is required.",
                "user_message": "Citadel user id missing.",
                "request_id": req_id,
            },
            headers={"X-Request-ID": req_id},
        )
    if not header_app_key:
        return JSONResponse(
            status_code=401,
            content={
                "success": False,
                "linked": False,
                "detail": "X-API-Key header is required.",
                "user_message": "App API Key is required. Open Oracle Citadel Setup and save your App API Key.",
                "error_code": "credentials_missing",
                "request_id": req_id,
            },
            headers={"X-Request-ID": req_id},
        )

    record = get_citadel_user_record(user_id)
    if not record:
        logger.info("exchange_keys_status_missing request_id=%s user_id=%s", req_id, user_id)
        return JSONResponse(
            status_code=404,
            content={
                "success": False,
                "linked": False,
                "detail": f"No exchange keys on file for user_id={user_id}.",
                "user_message": "Exchange keys not found on server. Re-link BloFin keys in Oracle Citadel Setup.",
                "error_code": "credentials_missing",
                "request_id": req_id,
            },
            headers={"X-Request-ID": req_id},
        )

    stored_app_key = (record.get("app_api_key") or "").strip()
    if not stored_app_key or stored_app_key != header_app_key:
        return JSONResponse(
            status_code=403,
            content={
                "success": False,
                "linked": False,
                "detail": "X-API-Key does not match saved app_api_key for this user_id.",
                "user_message": "App API Key mismatch. Re-save Oracle Citadel Setup with matching keys.",
                "error_code": "credentials_mismatch",
                "request_id": req_id,
            },
            headers={"X-Request-ID": req_id},
        )

    return JSONResponse(
        status_code=200,
        content={
            "success": True,
            "linked": True,
            "user_id": user_id,
            "exchange": record.get("exchange"),
            "environment": record.get("environment"),
            "use_demo_mode": bool(record.get("use_demo_mode")),
            "api_base_url": record.get("api_base_url"),
            "updated_at": record.get("updated_at"),
            "request_id": req_id,
        },
        headers={"X-Request-ID": req_id},
    )


# Fixed Citadel key-save routes — /api/* aliases prevent 404 when clients prefix /api
@app.get("/exchange_keys/status")
@app.get("/exchange_keys/status/")
@app.get("/api/exchange_keys/status")
@app.get("/api/exchange_keys/status/")
async def exchange_keys_status(http_request: Request) -> JSONResponse:
    return await _handle_exchange_keys_status(http_request)


@app.post("/exchange_keys")
@app.post("/exchange_keys/")
@app.post("/api/exchange_keys")
@app.post("/api/exchange_keys/")
async def exchange_keys(http_request: Request) -> JSONResponse:
    return await _handle_exchange_keys(http_request)


async def _handle_execute_trade(http_request: Request) -> JSONResponse:
    """
    POST /execute_trade — Oracle Citadel MARKET execution only (BloFin).

    Accepts JSON:
      user_id, coin, direction, entry_price, stop_loss, tp1, tp2, risk_percent, order_type=market
    Auth: X-API-Key header must match app_api_key saved via POST /exchange_keys.
    """
    req_id = getattr(http_request.state, "request_id", "?")
    path = http_request.url.path
    header_app_key = (http_request.headers.get("X-API-Key") or http_request.headers.get("x-api-key") or "").strip()

    logger.info(
        "execute_trade_request_start request_id=%s path=%s has_x_api_key=%s",
        req_id,
        path,
        bool(header_app_key),
    )

    try:
        raw_body = await http_request.json()
    except json.JSONDecodeError as exc:
        logger.warning("execute_trade_invalid_json request_id=%s err=%s", req_id, exc)
        return JSONResponse(
            status_code=400,
            content={
                "success": False,
                "detail": "Request body must be valid JSON.",
                "user_message": "Invalid trade request.",
                "request_id": req_id,
            },
            headers={"X-Request-ID": req_id},
        )

    if not isinstance(raw_body, dict):
        return JSONResponse(
            status_code=400,
            content={
                "success": False,
                "detail": "Request body must be a JSON object.",
                "user_message": "Invalid trade request format.",
                "request_id": req_id,
            },
            headers={"X-Request-ID": req_id},
        )

    logger.info(
        "execute_trade_payload request_id=%s payload=%s",
        req_id,
        _execute_trade_log_payload(raw_body),
    )

    try:
        trade = _parse_execute_trade_request(raw_body)
    except ValidationError as exc:
        logger.warning(
            "execute_trade_validation_failed request_id=%s errors=%s",
            req_id,
            exc.errors(),
        )
        return JSONResponse(
            status_code=422,
            content={
                "success": False,
                "detail": "Invalid trade payload.",
                "user_message": "Check coin, direction (long/short), entry, SL, TP1, TP2, and risk %.",
                "errors": exc.errors(),
                "request_id": req_id,
            },
            headers={"X-Request-ID": req_id},
        )

    user_id = trade.user_id
    if not header_app_key:
        return JSONResponse(
            status_code=401,
            content={
                "success": False,
                "detail": "X-API-Key header is required.",
                "user_message": "App API Key is required. Open Oracle Citadel Setup and save your App API Key.",
                "error_code": "credentials_missing",
                "request_id": req_id,
            },
            headers={"X-Request-ID": req_id},
        )

    record = get_citadel_user_record(user_id)
    if not record:
        logger.warning(
            "execute_trade_no_credentials request_id=%s user_id=%s",
            req_id,
            user_id,
        )
        return JSONResponse(
            status_code=404,
            content={
                "success": False,
                "detail": f"No exchange keys on file for user_id={user_id}.",
                "user_message": "Exchange keys not found on server. Re-link BloFin keys in Oracle Citadel Setup (Save with API Key + Secret).",
                "error_code": "credentials_missing",
                "request_id": req_id,
            },
            headers={"X-Request-ID": req_id},
        )

    stored_app_key = (record.get("app_api_key") or "").strip()
    if not stored_app_key or stored_app_key != header_app_key:
        logger.warning(
            "execute_trade_app_key_mismatch request_id=%s user_id=%s",
            req_id,
            user_id,
        )
        return JSONResponse(
            status_code=403,
            content={
                "success": False,
                "detail": "X-API-Key does not match saved Citadel credentials.",
                "user_message": "App API Key mismatch. Re-save credentials in Oracle Citadel Setup.",
                "error_code": "credentials_missing",
                "request_id": req_id,
            },
            headers={"X-Request-ID": req_id},
        )

    exchange_api_key = (record.get("exchange_api_key") or "").strip()
    exchange_secret_enc = record.get("exchange_secret_encrypted") or ""
    if not exchange_api_key or not exchange_secret_enc:
        return JSONResponse(
            status_code=404,
            content={
                "success": False,
                "detail": "Exchange API key or encrypted secret missing on server.",
                "user_message": "Exchange keys incomplete. Re-link keys in Oracle Citadel Setup.",
                "error_code": "credentials_missing",
                "request_id": req_id,
            },
            headers={"X-Request-ID": req_id},
        )

    exchange_secret = decrypt_secret_at_rest(exchange_secret_enc)
    if exchange_secret is None:
        logger.error(
            "execute_trade_secret_decrypt_failed request_id=%s user_id=%s",
            req_id,
            user_id,
        )
        return JSONResponse(
            status_code=500,
            content={
                "success": False,
                "detail": "Could not decrypt stored exchange secret.",
                "user_message": "Server credential error. Re-save exchange keys in Citadel Setup.",
                "request_id": req_id,
            },
            headers={"X-Request-ID": req_id},
        )

    order_type = "market"
    effective_risk, requested_risk = _resolve_effective_risk_percent(trade.risk_percent)
    exchange = record.get("exchange") or "unspecified"
    environment = record.get("environment") or "live"
    api_base_url = record.get("api_base_url") or BLOFIN_LIVE_API_BASE_URL
    trade_id = uuid.uuid4().hex[:16]

    if effective_risk < requested_risk:
        logger.info(
            "execute_trade_risk_capped request_id=%s requested=%.2f effective=%.2f max=%.2f",
            req_id,
            requested_risk,
            effective_risk,
            EXECUTE_TRADE_MAX_RISK_PERCENT,
        )

    logger.info(
        "execute_trade_parsed request_id=%s trade_id=%s user_id=%s order_type=%s coin=%s direction=%s "
        "entry=%s sl=%s tp1=%s tp2=%s risk_requested=%.2f risk_effective=%.2f exchange=%s "
        "environment=%s base_url=%s",
        req_id,
        trade_id,
        user_id,
        order_type,
        trade.coin,
        trade.direction,
        trade.entry_price,
        trade.stop_loss,
        trade.tp1,
        trade.tp2,
        requested_risk,
        effective_risk,
        exchange,
        environment,
        api_base_url,
    )

    if "blofin" not in str(exchange).lower():
        logger.warning(
            "execute_trade_market_unsupported_exchange request_id=%s exchange=%s",
            req_id,
            exchange,
        )
        return JSONResponse(
            status_code=400,
            content={
                "success": False,
                "detail": f"Oracle Citadel requires BloFin (exchange={exchange}).",
                "user_message": "Link BloFin keys in Oracle Citadel Setup to execute MARKET orders.",
                "request_id": req_id,
            },
            headers={"X-Request-ID": req_id},
        )

    geometry_err = _validate_citadel_trade_geometry(
        direction=trade.direction,
        entry=trade.entry_price,
        sl=trade.stop_loss,
        tp1=trade.tp1,
        tp2=trade.tp2,
    )
    if geometry_err:
        logger.warning(
            "execute_trade_geometry_rejected request_id=%s reason=%s",
            req_id,
            geometry_err,
        )
        return JSONResponse(
            status_code=400,
            content={
                "success": False,
                "detail": geometry_err,
                "user_message": geometry_err,
                "request_id": req_id,
            },
            headers={"X-Request-ID": req_id},
        )

    passphrase = _resolve_blofin_passphrase(record)
    if not passphrase:
        logger.error(
            "execute_trade_blofin_passphrase_missing request_id=%s user_id=%s",
            req_id,
            user_id,
        )
        return JSONResponse(
            status_code=500,
            content={
                "success": False,
                "detail": "BloFin API passphrase is not configured on the server.",
                "user_message": "Server BloFin passphrase missing. Set BLOFIN_PASSPHRASE on Railway.",
                "request_id": req_id,
            },
            headers={"X-Request-ID": req_id},
        )

    inst_id = _blofin_inst_id(trade.coin)

    # Reference price for sizing (live Mobula/CG/Binance — not sent as limit price on market).
    try:
        live = fetch_live_price_for_analysis(trade.coin)
        reference_price = float(live["price"])
    except Exception as exc:
        logger.warning(
            "execute_trade_market_price_fallback request_id=%s coin=%s err=%s using_entry=%s",
            req_id,
            trade.coin,
            exc,
            trade.entry_price,
        )
        reference_price = float(trade.entry_price)

    order_size, size_meta = _blofin_calculate_order_size(
        coin=trade.coin,
        entry_price=reference_price,
        stop_loss=trade.stop_loss,
        risk_percent=effective_risk,
        base_url=api_base_url,
        api_key=exchange_api_key,
        api_secret=exchange_secret,
        passphrase=passphrase,
        request_id=req_id,
    )

    effective_leverage = _normalize_citadel_leverage(trade.leverage)

    lev_result = _blofin_set_leverage(
        base_url=api_base_url,
        api_key=exchange_api_key,
        api_secret=exchange_secret,
        passphrase=passphrase,
        coin=trade.coin,
        leverage=effective_leverage,
        request_id=req_id,
    )
    if lev_result.get("ok"):
        logger.info("Leverage set to %sx on BloFin", effective_leverage)
        logger.info(
            "blofin_set_leverage_ok request_id=%s inst=%s margin=%s",
            req_id,
            inst_id,
            BLOFIN_MARGIN_MODE,
        )
    else:
        logger.warning(
            "blofin_set_leverage_failed request_id=%s inst=%s leverage=%sx http=%s code=%s msg=%s "
            "— continuing with MARKET order (exchange may use prior leverage)",
            req_id,
            inst_id,
            effective_leverage,
            lev_result.get("http_status"),
            lev_result.get("code"),
            lev_result.get("msg"),
        )

    logger.info(
        "execute_trade_market_dispatch request_id=%s trade_id=%s blofin_base=%s inst=%s "
        "reference_price=%.6f order_size=%s leverage=%sx size_meta=%s",
        req_id,
        trade_id,
        api_base_url,
        inst_id,
        reference_price,
        order_size,
        effective_leverage,
        size_meta,
    )

    blofin_result = _blofin_place_order(
        base_url=api_base_url,
        api_key=exchange_api_key,
        api_secret=exchange_secret,
        passphrase=passphrase,
        coin=trade.coin,
        direction=trade.direction,
        order_type="market",
        size=order_size,
        tp1=None,
        sl=trade.stop_loss,
        client_order_id=trade_id[:32],
        request_id=req_id,
    )

    blofin_order_id = blofin_result.get("order_id")
    order_params = blofin_result.get("order_params") or {}

    if blofin_result.get("ok") and blofin_order_id:
        # Fill confirmation — success only when contracts actually filled (not just orderId).
        confirm = await _blofin_confirm_market_fill(
            base_url=api_base_url,
            api_key=exchange_api_key,
            api_secret=exchange_secret,
            passphrase=passphrase,
            inst_id=inst_id,
            order_id=blofin_order_id,
            placement=blofin_result,
            request_id=req_id,
        )
        logger.info(
            "execute_trade_post_confirm request_id=%s trade_id=%s order_id=%s confirm=%s",
            req_id,
            trade_id,
            blofin_order_id,
            {
                "fill_ok": confirm.get("fill_ok"),
                "state": confirm.get("state"),
                "filled_size": confirm.get("filled_size"),
                "average_price": confirm.get("average_price"),
                "poll_attempt": confirm.get("poll_attempt"),
                "source": confirm.get("source"),
            },
        )

        if not confirm.get("fill_ok"):
            logger.warning(
                "execute_trade_market_unfilled request_id=%s trade_id=%s order_id=%s "
                "environment=%s base_url=%s state=%s filled=%s order_size=%s",
                req_id,
                trade_id,
                blofin_order_id,
                environment,
                api_base_url,
                confirm.get("state"),
                confirm.get("filled_size"),
                order_size,
            )
            return JSONResponse(
                status_code=502,
                content={
                    "success": False,
                    "status": "failed",
                    "order_type": "market",
                    "trade_id": trade_id,
                    "order_id": blofin_order_id,
                    "detail": (
                        "BloFin accepted the MARKET order but no contracts were filled. "
                        f"state={confirm.get('state')!s} filledSize={confirm.get('filled_size')!s}"
                    ),
                    "user_message": (
                        "MARKET order was submitted to BloFin but did not fill — no position opened. "
                        "Check Demo margin, minimum size, and that Citadel Demo mode matches your BloFin "
                        f"account ({environment}). Order ID {blofin_order_id} may appear in order history only."
                    ),
                    "blofin_confirm": {
                        "state": confirm.get("state"),
                        "filled_size": confirm.get("filled_size"),
                        "average_price": confirm.get("average_price"),
                    },
                    "api_base_url": api_base_url,
                    "request_id": req_id,
                },
                headers={"X-Request-ID": req_id},
            )

        logger.info(
            "execute_trade_market_outcome request_id=%s trade_id=%s "
            "Order placed successfully - Order ID: %s state=%s filled=%s avg=%s",
            req_id,
            trade_id,
            blofin_order_id,
            confirm.get("state"),
            confirm.get("filled_size"),
            confirm.get("average_price"),
        )

        # Dual TP (40% / 60%) — separate order-tpsl legs after confirmed MARKET fill + SL on entry.
        position_size = (
            confirm.get("filled_size")
            or confirm.get("size")
            or order_size
        )
        position_size_str = str(position_size)
        spec = _blofin_fetch_instrument_spec(
            base_url=api_base_url,
            inst_id=inst_id,
            request_id=req_id,
        )
        tp1_size, tp2_size = _blofin_dual_tp_contract_sizes(
            position_size_str,
            lot_size=float(spec["lotSize"]),
            min_size=float(spec["minSize"]),
        )

        tp1_tpsl_id: Optional[str] = None
        tp2_tpsl_id: Optional[str] = None
        tp_warnings: list[str] = []

        tp1_result = _blofin_place_tpsl_take_profit(
            base_url=api_base_url,
            api_key=exchange_api_key,
            api_secret=exchange_secret,
            passphrase=passphrase,
            coin=trade.coin,
            direction=trade.direction,
            tp_price=trade.tp1,
            size=tp1_size,
            client_order_id=f"{trade_id[:28]}m1",
            request_id=req_id,
        )
        tp1_tpsl_id = tp1_result.get("tpsl_id")
        if tp1_result.get("ok"):
            logger.info(
                "market_tp1_40pct_placed request_id=%s trade_id=%s tpsl_id=%s size=%s trigger=%s",
                req_id,
                trade_id,
                tp1_tpsl_id,
                tp1_size,
                trade.tp1,
            )
        else:
            logger.warning(
                "market_tp1_40pct_failed request_id=%s trade_id=%s code=%s msg=%s size=%s",
                req_id,
                trade_id,
                tp1_result.get("code"),
                tp1_result.get("msg"),
                tp1_size,
            )
            tp_warnings.append(f"TP1 (40%) not placed: {tp1_result.get('msg') or 'unknown'}")

        tp2_result = _blofin_place_tpsl_take_profit(
            base_url=api_base_url,
            api_key=exchange_api_key,
            api_secret=exchange_secret,
            passphrase=passphrase,
            coin=trade.coin,
            direction=trade.direction,
            tp_price=trade.tp2,
            size=tp2_size,
            client_order_id=f"{trade_id[:28]}m2",
            request_id=req_id,
        )
        tp2_tpsl_id = tp2_result.get("tpsl_id")
        if tp2_result.get("ok"):
            logger.info(
                "market_tp2_60pct_placed request_id=%s trade_id=%s tpsl_id=%s size=%s trigger=%s",
                req_id,
                trade_id,
                tp2_tpsl_id,
                tp2_size,
                trade.tp2,
            )
        else:
            logger.warning(
                "market_tp2_60pct_failed request_id=%s trade_id=%s code=%s msg=%s size=%s",
                req_id,
                trade_id,
                tp2_result.get("code"),
                tp2_result.get("msg"),
                tp2_size,
            )
            tp_warnings.append(f"TP2 (60%) not placed: {tp2_result.get('msg') or 'unknown'}")

        planned_entry = float(trade.entry_price)
        original_sl = float(trade.stop_loss)
        fill_entry = _parse_blofin_price_token(confirm.get("average_price")) or reference_price
        suggested_sl = _citadel_suggested_stop_loss(
            direction=trade.direction,
            fill_entry=fill_entry,
            planned_entry=planned_entry,
            original_sl=original_sl,
        )

        return JSONResponse(
            status_code=200,
            content={
                "success": True,
                "status": "success",
                "order_type": "market",
                "trade_id": trade_id,
                "order_id": blofin_order_id,
                "tp1_tpsl_id": tp1_tpsl_id,
                "tp2_tpsl_id": tp2_tpsl_id,
                "tp1_size": tp1_size,
                "tp2_size": tp2_size,
                "user_id": user_id,
                "coin": trade.coin,
                "direction": trade.direction,
                "stop_loss": trade.stop_loss,
                "tp1": trade.tp1,
                "tp2": trade.tp2,
                "risk_percent": effective_risk,
                "risk_percent_requested": requested_risk,
                "order_size": order_size,
                "exchange": exchange,
                "environment": environment,
                "planned_entry_price": planned_entry,
                "fill_entry_price": fill_entry,
                "original_stop_loss": original_sl,
                "suggested_stop_loss": suggested_sl,
                "message": f"MARKET order placed for {trade.coin} {trade.direction.upper()}.",
                "user_message": (
                    f"MARKET order executed on BloFin ({environment}). "
                    f"{trade.coin} {trade.direction.upper()} · Order ID {blofin_order_id}"
                ),
                "blofin_confirm": {
                    "state": confirm.get("state"),
                    "filled_size": confirm.get("filled_size"),
                    "average_price": confirm.get("average_price"),
                },
                "post_trade_review": {
                    "planned_entry_price": planned_entry,
                    "fill_entry_price": fill_entry,
                    "original_stop_loss": original_sl,
                    "suggested_stop_loss": suggested_sl,
                },
                "tp_warnings": tp_warnings,
                "request_id": req_id,
            },
            headers={"X-Request-ID": req_id},
        )

    logger.warning(
        "execute_trade_market_failure request_id=%s trade_id=%s http=%s code=%s msg=%s "
        "order_params=%s blofin_response=%s",
        req_id,
        trade_id,
        blofin_result.get("http_status"),
        blofin_result.get("code"),
        blofin_result.get("msg"),
        order_params,
        _blofin_safe_response_log(blofin_result.get("response"))
        if isinstance(blofin_result.get("response"), dict)
        else blofin_result.get("response"),
    )
    friendly = _blofin_user_friendly_error(
        blofin_result.get("code"),
        blofin_result.get("msg"),
    )
    fail_body: dict[str, Any] = {
        "success": False,
        "status": "failed",
        "order_type": "market",
        "trade_id": trade_id,
        "detail": blofin_result.get("msg") or "BloFin MARKET order rejected.",
        "user_message": friendly,
        "blofin_code": blofin_result.get("code"),
        "request_id": req_id,
    }
    if _blofin_is_ip_whitelist_error(blofin_result.get("code"), blofin_result.get("msg")):
        egress_ip = _citadel_egress_ip_for_whitelist()
        if egress_ip:
            fail_body["whitelist_ip"] = egress_ip
            logger.warning(
                "execute_trade_market_ip_whitelist request_id=%s trade_id=%s "
                "whitelist_this_ip_in_blofin=%s",
                req_id,
                trade_id,
                egress_ip,
            )
    return JSONResponse(
        status_code=502,
        content=fail_body,
        headers={"X-Request-ID": req_id},
    )

# Oracle Citadel execute — /api/* aliases prevent 404 (mirrors exchange_keys pattern)
@app.post("/execute_trade")
@app.post("/execute_trade/")
@app.post("/api/execute_trade")
@app.post("/api/execute_trade/")
async def execute_trade(http_request: Request) -> JSONResponse:
    return await _handle_execute_trade(http_request)


if __name__ == "__main__":
    # Keep-alive 120s + graceful shutdown 180s — match Railway startCommand (long Grok /analyze).
    uvicorn.run(
        "api:app",
        host=API_HOST,
        port=API_PORT,
        reload=False,
        timeout_keep_alive=UVICORN_TIMEOUT_KEEP_ALIVE,
        timeout_graceful_shutdown=UVICORN_TIMEOUT_GRACEFUL_SHUTDOWN,
    )
