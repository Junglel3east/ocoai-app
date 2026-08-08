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
  GET  /daily_analyses — today's scheduled Home daily analysis batch (BTC, ETH, SOL, XRP)
  POST /internal/cron/post_daily_x — optional Railway cron: post today's analyses to X

Price chain (analysis): Mobula → CoinGecko Pro → CoinGecko free → Binance Spot/Futures → BloFin (Citadel-linked fallback)
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
from zoneinfo import ZoneInfo
import re
import threading
import time
import uuid
from concurrent.futures import ThreadPoolExecutor
from contextlib import asynccontextmanager
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Optional, Union

import requests
import uvicorn
from dotenv import load_dotenv
from fastapi import FastAPI, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from pydantic import AliasChoices, BaseModel, ConfigDict, Field, ValidationError, field_validator

from x_daily_poster import (
    XDailyPosterConfig,
    post_daily_analyses_to_x,
    post_today_from_store,
)

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

# Dedicated CoinGecko Pro service (imported after load_dotenv so env is resolved).
import coingecko_service as cg
import bitunix_service as bux

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
# CoinGecko Pro — fast CEX reference when MOBULA_API_KEY + key set on Railway
COINGECKO_PRO_API_KEY = (os.getenv("COINGECKO_PRO_API_KEY") or "").strip()
COINGECKO_PUBLIC_API_BASE = "https://api.coingecko.com/api/v3"
COINGECKO_PRO_API_BASE = "https://pro-api.coingecko.com/api/v3"
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
_APP_API_KEYS_FILE = _CITADEL_DATA_DIR / "app_api_keys.json"

# Home "Daily Analysis" — auto-generated BTC/ETH/SOL/XRP batch (7:30 AM America/Chicago).
DAILY_ANALYSIS_ENABLED = os.getenv("DAILY_ANALYSIS_ENABLED", "true").strip().lower() in {
    "1",
    "true",
    "yes",
    "on",
}
DAILY_ANALYSIS_TZ = os.getenv("DAILY_ANALYSIS_TZ", "America/Chicago")
DAILY_ANALYSIS_HOUR = int(os.getenv("DAILY_ANALYSIS_HOUR", "7"))
DAILY_ANALYSIS_MINUTE = int(os.getenv("DAILY_ANALYSIS_MINUTE", "30"))
DAILY_ANALYSIS_COINS: tuple[str, ...] = ("BTC", "ETH", "SOL", "XRP")
_DAILY_ANALYSIS_FILE = _CITADEL_DATA_DIR / "daily_analyses.json"
_daily_scheduler_task: Optional[asyncio.Task] = None
_x_daily_post_scheduler_task: Optional[asyncio.Task] = None
_last_daily_run_day: Optional[str] = None

# X (Twitter) — auto-post daily analysis thread after batch save (OAuth 1.0a User Context).
_X_DAILY_CONFIG = XDailyPosterConfig()
X_DAILY_POST_ENABLED = _X_DAILY_CONFIG.enabled
X_CRON_SECRET = (os.getenv("X_CRON_SECRET") or os.getenv("CRON_SECRET") or "").strip()
# Seconds after 7:30 AM Chicago before the X scheduler reads persisted analyses (batch may still be running).
X_DAILY_POST_DELAY_SECONDS = int(os.getenv("X_DAILY_POST_DELAY_SECONDS", "120"))

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
BLOFIN_POSITIONS_PATH = "/api/v1/account/positions"
BLOFIN_CLOSE_POSITION_PATH = "/api/v1/trade/close-position"
BLOFIN_ORDERS_TPSL_PENDING_PATH = "/api/v1/trade/orders-tpsl-pending"
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
# Passphrase env fallbacks — per-user encrypted passphrase in Citadel store takes priority.
# Railway: BLOFIN_PASSPHRASE (demo) + Blofin_Passpharse_live or BLOFIN_PASSPHRASE_LIVE (live).
BLOFIN_PASSPHRASE = (os.getenv("BLOFIN_PASSPHRASE") or os.getenv("CITADEL_BLOFIN_PASSPHRASE") or "").strip()


def _blofin_env_passphrase(use_demo: bool) -> str:
    """Server-side passphrase fallback when user did not save one in Citadel Setup."""
    if use_demo:
        return (
            (os.getenv("BLOFIN_PASSPHRASE_DEMO") or "").strip()
            or BLOFIN_PASSPHRASE
        )
    live_candidates = [
        os.getenv("BLOFIN_PASSPHRASE_LIVE"),
        os.getenv("Blofin_Passpharse_live"),  # common Railway typo
        os.getenv("Blofin_Passphrase_live"),
        os.getenv("BLOFIN_LIVE_PASSPHRASE"),
        BLOFIN_PASSPHRASE,
    ]
    for raw in live_candidates:
        if raw and str(raw).strip():
            return str(raw).strip()
    return ""

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


def _grok_user_friendly_message(status_code: int, body: str) -> str:
    """Turn xAI HTTP errors into actionable Citadel/analyze messages."""
    preview = (body or "").strip()
    parsed: dict[str, Any] = {}
    if preview.startswith("{"):
        try:
            raw = json.loads(preview)
            if isinstance(raw, dict):
                parsed = raw
        except json.JSONDecodeError:
            parsed = {}

    err_text = str(parsed.get("error") or parsed.get("message") or "").strip()
    code = str(parsed.get("code") or "").strip().lower()
    combined = f"{code} {err_text} {preview}".lower()

    if status_code == 403 and (
        "credit" in combined
        or "permission-denied" in combined
        or "subscription" in combined
        or "available resources" in combined
    ):
        return (
            "xAI API credits exhausted or access denied. "
            "Add credits at https://console.x.ai/ and confirm GROK_API_KEY on Railway has an active balance."
        )
    if status_code == 401:
        return "Grok API key rejected (HTTP 401). Verify GROK_API_KEY on Railway."
    if status_code == 429:
        return "Grok rate limit hit (HTTP 429). Wait 1–2 minutes and retry Trade Setup."
    if err_text:
        return f"Grok HTTP {status_code}: {err_text[:240]}"
    return f"Grok HTTP {status_code}."


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
    vision_confluence_pct: Optional[float] = Field(None, ge=0, le=100)
    # Oracle Flux chart indicator snapshot (optional — backward compatible if omitted).
    oracle_flux: Optional[dict[str, Any]] = Field(
        None,
        validation_alias=AliasChoices("oracle_flux", "oracleFlux", "flux"),
    )
    # Generic chart context blob; may nest oracle_flux / oracleFlux / flux.
    chart_context: Optional[Union[dict[str, Any], str]] = Field(
        None,
        validation_alias=AliasChoices("chart_context", "chartContext"),
    )
    # User's chosen leverage — Citadel-configured when sent by Flutter; else server defaults to 5x.
    leverage: Optional[float] = Field(None, ge=1.0, le=100.0)


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
    exchange_passphrase: Optional[str] = Field(
        None,
        max_length=256,
        validation_alias=AliasChoices(
            "exchange_passphrase",
            "api_passphrase",
            "passphrase",
            "blofin_passphrase",
        ),
    )
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

    @field_validator("exchange_passphrase", mode="before")
    @classmethod
    def _strip_optional_passphrase(cls, value: Any) -> Any:
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


class AppApiKeyRegisterRequest(BaseModel):
    """Register or refresh the App API Key → user_id mapping (Flutter secure storage key)."""

    model_config = ConfigDict(extra="ignore")

    user_id: str = Field(..., min_length=1, max_length=128)
    app_api_key: Optional[str] = Field(
        None,
        max_length=512,
        validation_alias=AliasChoices("app_api_key", "app_key"),
    )

    @field_validator("user_id", mode="before")
    @classmethod
    def _strip_user_id(cls, value: Any) -> Any:
        if isinstance(value, str):
            return value.strip()
        return value

    @field_validator("app_api_key", mode="before")
    @classmethod
    def _strip_app_key(cls, value: Any) -> Any:
        if value is None:
            return None
        if isinstance(value, str):
            return value.strip() or None
        return value


class ExecuteTradeRequest(BaseModel):
    """
    Oracle Citadel trade execution — MARKET or LIMIT (BloFin).
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
    use_demo_mode: Optional[bool] = Field(
        None,
        validation_alias=AliasChoices("use_demo_mode", "demo_mode"),
    )

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
        if value is None:
            return "market"
        token = str(value).strip().lower()
        if token == "limit":
            return "limit"
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


def _coingecko_api_base() -> str:
    return cg.api_base()


def _coingecko_request_headers(*, no_cache: bool = False) -> dict[str, str]:
    return cg.build_headers(no_cache=no_cache)


def refresh_coingecko_symbol_index(force: bool = False) -> None:
    global _COINGECKO_CACHE_LOADED_AT

    now = time.time()
    # Symbol→id mapping — forced refresh capped at 1/min so the Home 7s
    # live-price polling never hammers CoinGecko with 500-row index pulls.
    min_age = 60.0 if force else _COINGECKO_CACHE_TTL_SECONDS
    if (now - _COINGECKO_CACHE_LOADED_AT) < min_age:
        return

    try:
        primed = 0
        for page in (1, 2):
            rows = cg.fetch_market_data(page=page, per_page=250)
            if not rows:
                break
            for coin in rows:
                symbol = str(coin.get("symbol", "")).upper()
                coin_id = coin.get("id")
                if symbol and coin_id and symbol not in _SYMBOL_TO_COINGECKO_ID:
                    _SYMBOL_TO_COINGECKO_ID[symbol] = coin_id
            # Reuse the rich rows we already paid for: warm the live-price cache
            # so top-market lookups need no extra per-coin calls.
            primed += cg.prime_price_cache(rows)
        _COINGECKO_CACHE_LOADED_AT = now
        logger.info(
            "CoinGecko index refreshed | symbols=%d primed=%d usage=%s",
            len(_SYMBOL_TO_COINGECKO_ID),
            primed,
            cg.usage_stats().get("by_endpoint", {}),
        )
    except Exception as exc:
        logger.warning("CoinGecko index refresh failed: %s", exc)


def resolve_coingecko_id(symbol: str) -> Optional[str]:
    refresh_coingecko_symbol_index()
    upper = symbol.upper()

    if upper in _SYMBOL_TO_COINGECKO_ID:
        return _SYMBOL_TO_COINGECKO_ID[upper]

    try:
        coins = cg.search(upper)
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
            vol_mix += "CEX/perp-led flow; weight funding, OI, and liqs in **Volume-Weighted Analysis** and **Confluence Summary**."
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
            "• **Volume-Weighted Analysis** — cite Daily VWAP vs live price, on-chain vs CEX flow, and derivatives positioning.",
            "• **Overall Bias** / **Confluence Summary** / **If I Were to Trade Today...** — price Mobula into the verdict.",
            "• Do NOT dump raw numbers; translate into edge (trap risk, chase risk, squeeze fuel, stand-aside).",
        ]
    )
    return "\n".join(lines) + "\n\n"


def format_market_data_fallback_note(market: dict[str, Any]) -> str:
    """When Mobula misses, tell the model not to invent on-chain stats."""
    if market.get("source") in {"mobula", "blofin", "blofin_demo", "coingecko_pro"}:
        return ""
    return (
        "═══ ON-CHAIN / MOBULA ═══\n"
        "Mobula live feed unavailable for this tick — do NOT invent DEX liquidity or on-chain volume. "
        "Infer liquidity from structure + Binance derivatives only; state 'on-chain depth unverified' once in "
        "**Volume-Weighted Analysis** or **Confluence Summary** if relevant.\n\n"
    )


def _compact_usd_label(val: Any) -> str:
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


def format_live_price_banner(market: dict[str, Any]) -> str:
    """Single-line live price + source for prompts (Mobula / CoinGecko Pro / fallbacks)."""
    price = format_usd(float(market["price"]))
    change = float(market.get("change_24h_pct") or 0)
    source = market.get("source", "unknown")

    if source == "mobula":
        liq = _compact_usd_label(market.get("liquidity_usd"))
        on_vol = float(market.get("on_chain_volume_usd") or 0)
        off_vol = float(market.get("off_chain_volume_usd") or 0)
        vol_note = ""
        if on_vol > 0 or off_vol > 0:
            vol_note = (
                f" | On-chain vol: {_compact_usd_label(on_vol)}"
                f" | CEX vol: {_compact_usd_label(off_vol)}"
            )
        return f"LIVE PRICE from Mobula: {price} | 24h {change:+.2f}% | Liquidity: {liq}{vol_note}"

    if source == "coingecko_pro":
        vol = _compact_usd_label(market.get("volume_24h_usd"))
        ch1h = market.get("change_1h_pct")
        h1 = f" | 1h {float(ch1h):+.2f}%" if ch1h is not None else ""
        return f"LIVE PRICE from CoinGecko Pro: {price}{h1} | 24h {change:+.2f}% | CEX Volume: {vol}"

    if source == "coingecko":
        vol = _compact_usd_label(market.get("volume_24h_usd"))
        return f"LIVE PRICE from CoinGecko: {price} | 24h {change:+.2f}% | Volume: {vol}"

    if source in {"blofin", "blofin_demo"}:
        label = "BloFin Demo" if source == "blofin_demo" else "BloFin"
        return f"LIVE PRICE from {label}: {price} | 24h {change:+.2f}% | Citadel-linked mark"

    if source in {"binance_spot", "binance_futures"}:
        label = "Binance Spot" if source == "binance_spot" else "Binance Futures"
        vol = _compact_usd_label(market.get("volume_24h_usd"))
        vol_suffix = f" | Volume: {vol}" if vol != "n/a" else ""
        return f"LIVE PRICE from {label}: {price} | 24h {change:+.2f}%{vol_suffix}"

    return f"LIVE PRICE ({source}): {price} | 24h {change:+.2f}%"


def format_coingecko_pro_prompt_block(market: dict[str, Any]) -> str:
    """CoinGecko Pro / public CEX context when Mobula is unavailable."""
    source = market.get("source")
    if source not in {"coingecko_pro", "coingecko"}:
        return ""

    vol = market.get("volume_24h_usd")
    label = "COINGECKO PRO" if source == "coingecko_pro" else "COINGECKO"
    lines = [
        f"═══ {label} LIVE CEX REFERENCE — RELIABLE SPOT/PERP ANCHOR ═══",
        f"CEX 24h volume: {_compact_usd_label(vol)} | Use for CEX-led flow read when Mobula absent.",
    ]

    # Multi-timeframe momentum (Pro /coins/markets) — sharper trend/MTF context.
    momentum_bits: list[str] = []
    for tf_label, tf_key in (
        ("1h", "change_1h_pct"),
        ("24h", "change_24h_pct"),
        ("7d", "change_7d_pct"),
        ("30d", "change_30d_pct"),
    ):
        val = market.get(tf_key)
        if val is not None:
            momentum_bits.append(f"{tf_label} {float(val):+.2f}%")
    if momentum_bits:
        lines.append(
            "Momentum (price change): " + " | ".join(momentum_bits)
            + " — align bias with multi-timeframe trend, flag divergences."
        )

    hi = market.get("high_24h")
    lo = market.get("low_24h")
    if hi and lo:
        lines.append(
            f"24h range: {format_usd(float(lo))} – {format_usd(float(hi))} "
            "— use for intraday support/resistance and stop placement context."
        )

    mcap = market.get("market_cap_usd")
    if mcap:
        lines.append(f"Market cap: {_compact_usd_label(mcap)} (liquidity/size context).")

    lines.extend(
        [
            "MANDATORY: Weight CEX volume + Binance derivatives (funding/OI/L-S/liqs) in **Volume-Weighted Analysis** "
            "and **Confluence Summary**.",
            "Do NOT invent DEX pool depth — state CEX-led flow explicitly when on-chain data is missing.",
        ]
    )
    return "\n".join(lines) + "\n\n"


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
    cache_bust_ms: Optional[int] = None,  # retained for call-site compatibility
) -> Optional[dict[str, Any]]:
    """Single-coin market dict via the CoinGecko service.

    On Pro this uses /coins/markets (rich: price, 1h/24h/7d/30d momentum, volume,
    market cap, 24h hi/lo) with a /simple/price fallback. Returns the legacy keys
    plus the richer fields for AI context.
    """
    coin_id = resolve_coingecko_id(symbol)
    if not coin_id:
        return None
    try:
        return cg.fetch_price(coin_id, no_cache=no_cache)
    except Exception as exc:
        logger.debug("CoinGecko price miss symbol=%s err=%s", symbol, exc)
        return None


def fetch_coingecko_market_aggressive(symbol: str) -> Optional[dict[str, Any]]:
    """
    Two back-to-back cache-busted CoinGecko pulls; returns the latest successful tick.
    Called immediately before Grok (analysis + trade setup) — not cached from earlier requests.
    """
    coin_id = resolve_coingecko_id(symbol.upper())
    if not coin_id:
        return None
    return cg.fetch_price_aggressive(coin_id, attempts=2)


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
    Fresh price for AI analysis/trade setup:
    1. Mobula (on-chain liquidity, real volume, DEX data)
    2. CoinGecko Pro when COINGECKO_PRO_API_KEY is set (else public CoinGecko)
    3. Binance Spot/Futures free fallbacks
    4. BloFin mark price when Citadel-linked (execution parity last resort)
    """
    upper = coin.upper()
    refresh_coingecko_symbol_index(force=True)

    fetched_at = time.time()

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

    cg_label = "coingecko_pro" if COINGECKO_PRO_API_KEY else "coingecko"
    logger.warning(
        "live_price_for_ai coin=%s mobula_miss — trying %s",
        upper,
        cg_label,
    )
    snapshot = fetch_coingecko_market_aggressive(upper)
    if snapshot:
        age_ms = (time.time() - fetched_at) * 1000
        logger.info(
            "live_price_for_ai coin=%s source=%s price=%.6f age_ms=%.0f",
            upper,
            snapshot.get("source", cg_label),
            snapshot["price"],
            age_ms,
        )
        return {"coin": upper, "fetched_at": fetched_at, **snapshot}

    logger.warning("live_price_for_ai coin=%s %s_miss — falling back to binance", upper, cg_label)
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
                "live_price_for_ai coin=%s source=%s price=%.6f age_ms=%.0f (citadel fallback)",
                upper,
                blofin["source"],
                blofin["price"],
                age_ms,
            )
            return {"coin": upper, "fetched_at": fetched_at, **blofin}

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

    return f"""═══ LIVE DERIVATIVES — BINANCE FUTURES (perp positioning read; NEVER list as four sentences) ═══
Funding: {funding_val} → {derivatives['funding_label']}
Open Interest: {oi_val} → {derivatives['oi_label']}
Long/Short accounts (5m): {ls_val} → {derivatives['ls_label']}
Recent liquidations: {liq_val} → {derivatives['liq_label']}

TRADER INSTRUCTION — weave derivatives into **Volume-Weighted Analysis**, **Market Structure**, and
**Confluence Summary** (never as a separate Liquidity & Sentiment heading):
• Who is paying whom (funding)? Is OI rising with trend (conviction) or against it (shorts/longs adding)?
• Are accounts lopsided (L/S) into a level where stops cluster? Did liqs mark exhaustion or fuel continuation?
• Map to positioning: squeeze setup, cascade risk, counter crowded extension, liquidity grab, or stand aside until reset.
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


def _load_app_api_key_store() -> dict[str, str]:
    """Maps app_api_key → user_id for X-API-Key auth on analyze/trade-setup."""
    if not _APP_API_KEYS_FILE.is_file():
        return {}
    try:
        raw = json.loads(_APP_API_KEYS_FILE.read_text(encoding="utf-8"))
        if not isinstance(raw, dict):
            return {}
        return {str(k).strip(): str(v).strip() for k, v in raw.items() if k and v}
    except (OSError, json.JSONDecodeError) as exc:
        logger.error("app_api_key_store_read_failed path=%s err=%s", _APP_API_KEYS_FILE, exc)
        return {}


def _save_app_api_key_store(store: dict[str, str]) -> None:
    _CITADEL_DATA_DIR.mkdir(parents=True, exist_ok=True)
    tmp = _APP_API_KEYS_FILE.with_suffix(".json.tmp")
    payload = json.dumps(store, indent=2)
    tmp.write_text(payload, encoding="utf-8")
    tmp.replace(_APP_API_KEYS_FILE)


def register_app_api_key(user_id: str, app_api_key: str) -> dict[str, Any]:
    """Persist App API Key → user_id; sync into Citadel exchange record when present."""
    uid = (user_id or "").strip()
    key = (app_api_key or "").strip()
    if not uid or not key:
        raise ValueError("user_id and app_api_key are required")

    store = _load_app_api_key_store()
    store[key] = uid
    _save_app_api_key_store(store)

    citadel = _load_citadel_key_store()
    record = citadel.get(uid)
    if isinstance(record, dict):
        record = dict(record)
        record["app_api_key"] = key
        citadel[uid] = record
        _save_citadel_key_store(citadel)

    return {"user_id": uid, "app_api_key": key, "registered": True}


def resolve_user_id_from_app_key(app_api_key: str) -> Optional[str]:
    key = (app_api_key or "").strip()
    if not key:
        return None
    uid = _load_app_api_key_store().get(key)
    if uid:
        return uid
    # Fallback: legacy Citadel rows keyed by user_id with matching app_api_key field.
    for uid_candidate, record in _load_citadel_key_store().items():
        if not isinstance(record, dict):
            continue
        stored = (record.get("app_api_key") or "").strip()
        if stored and stored == key:
            register_app_api_key(str(uid_candidate), key)
            return str(uid_candidate)
    return None


def resolve_analyze_user_id(
    request: AnalyzeRequest,
    http_request: Request,
) -> Optional[str]:
    """Identify user from body user_id and/or X-API-Key header."""
    header_app_key = (
        http_request.headers.get("X-API-Key") or http_request.headers.get("x-api-key") or ""
    ).strip()
    body_user_id = (request.user_id or "").strip() or None

    if not header_app_key:
        return body_user_id

    resolved = resolve_user_id_from_app_key(header_app_key)
    if resolved:
        if body_user_id and body_user_id != resolved:
            logger.warning(
                "analyze_user_id_mismatch header_resolved=%s body=%s",
                resolved,
                body_user_id,
            )
        return resolved

    if body_user_id:
        register_app_api_key(body_user_id, header_app_key)
        return body_user_id

    return None


def resolve_citadel_exchange_profile(
    exchange: Optional[str],
    use_demo_mode: bool,
) -> dict[str, Any]:
    """
    Oracle Citadel execution: BloFin (demo or live) or Bitunix (live only).
    Empty/unspecified exchange defaults to BloFin.
    """
    raw = (exchange or "").strip().lower()
    is_bitunix = "bitunix" in raw
    is_blofin = "blofin" in raw or raw in ("", "unspecified")

    if is_bitunix:
        if use_demo_mode:
            # Bitunix is live-only — coerce demo off instead of rejecting the save.
            use_demo_mode = False
        return {
            "exchange": "bitunix",
            "environment": "live",
            "api_base_url": bux.BITUNIX_LIVE_API_BASE_URL,
            "blofin_demo": False,
            "demo_rejected": False,
        }

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

    if "bitunix" in exchange:
        normalized = dict(record)
        normalized["exchange"] = "bitunix"
        normalized["environment"] = "live"
        normalized["api_base_url"] = bux.BITUNIX_LIVE_API_BASE_URL
        normalized["use_demo_mode"] = False
        return normalized

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
    if not data.get("exchange_passphrase") and data.get("passphrase"):
        data["exchange_passphrase"] = data["passphrase"]
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
    exchange_passphrase: Optional[str] = None,
) -> dict[str, Any]:
    profile = resolve_citadel_exchange_profile(exchange, use_demo_mode)
    effective_demo = use_demo_mode
    if profile.get("exchange") == "bitunix":
        effective_demo = False
    encrypted_secret = encrypt_secret_at_rest(exchange_secret)
    store = _load_citadel_key_store()
    prior = store.get(user_id) if isinstance(store.get(user_id), dict) else {}
    passphrase_plain = (exchange_passphrase or "").strip()
    if passphrase_plain:
        encrypted_passphrase = encrypt_secret_at_rest(passphrase_plain)
    else:
        encrypted_passphrase = prior.get("exchange_passphrase_encrypted")

    row: dict[str, Any] = {
        "user_id": user_id,
        "app_api_key": app_api_key,
        "exchange_api_key": exchange_api_key,
        "exchange_secret_encrypted": encrypted_secret,
        "risk_percent": risk_percent,
        "exchange": profile["exchange"],
        "use_demo_mode": effective_demo,
        "environment": profile["environment"],
        "api_base_url": profile["api_base_url"],
        "updated_at": datetime.now(timezone.utc).isoformat(),
    }
    if encrypted_passphrase:
        row["exchange_passphrase_encrypted"] = encrypted_passphrase
    store[user_id] = row
    _save_citadel_key_store(store)
    register_app_api_key(user_id, app_api_key)

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


def _coerce_demo_mode_flag(value: Any) -> Optional[bool]:
    """Parse use_demo_mode / demo_mode from JSON (bool, 0/1, true/false strings)."""
    if value is None:
        return None
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return bool(value)
    text = str(value).strip().lower()
    if text in {"", "null", "none"}:
        return None
    if text in {"1", "true", "yes", "on"}:
        return True
    if text in {"0", "false", "no", "off"}:
        return False
    return None


def _record_prefers_blofin_demo(record: dict[str, Any]) -> bool:
    return bool(record.get("use_demo_mode")) or (
        "demo-trading-openapi.blofin.com"
        in str(record.get("api_base_url") or "").lower()
    )


def _resolve_execute_trade_blofin_profile(
    record: dict[str, Any],
    raw_body: dict[str, Any],
    *,
    user_id: str,
    req_id: str,
) -> dict[str, Any]:
    """
    Pick BloFin demo vs live host for this trade.
    Flutter's use_demo_mode wins over stale server rows (demo keys on live host → 152401).
    """
    client_demo = _coerce_demo_mode_flag(
        raw_body.get("use_demo_mode", raw_body.get("demo_mode"))
    )
    record_demo = _record_prefers_blofin_demo(record)
    use_demo = record_demo if client_demo is None else client_demo
    profile = resolve_citadel_exchange_profile(record.get("exchange") or "blofin", use_demo)
    api_base = profile.get("api_base_url") or BLOFIN_LIVE_API_BASE_URL

    if client_demo is not None and client_demo != record_demo:
        try:
            store = _load_citadel_key_store()
            row = store.get(user_id)
            if isinstance(row, dict):
                row["use_demo_mode"] = use_demo
                row["environment"] = profile["environment"]
                row["api_base_url"] = api_base
                row["exchange"] = profile["exchange"]
                row["updated_at"] = datetime.now(timezone.utc).isoformat()
                store[user_id] = row
                _save_citadel_key_store(store)
                logger.info(
                    "citadel_demo_profile_synced request_id=%s user_id=%s use_demo=%s base=%s",
                    req_id,
                    user_id,
                    use_demo,
                    api_base,
                )
        except Exception as exc:
            logger.warning(
                "citadel_demo_profile_sync_failed request_id=%s user_id=%s err=%s",
                req_id,
                user_id,
                exc,
            )

    if client_demo is not None and client_demo != record_demo:
        logger.info(
            "execute_trade_demo_override request_id=%s user_id=%s record_demo=%s "
            "client_demo=%s base=%s",
            req_id,
            user_id,
            record_demo,
            client_demo,
            api_base,
        )

    return {
        "exchange": profile["exchange"],
        "environment": profile["environment"],
        "api_base_url": api_base,
        "use_demo_mode": use_demo,
    }


def _resolve_execute_trade_exchange_profile(
    record: dict[str, Any],
    raw_body: dict[str, Any],
    *,
    user_id: str,
    req_id: str,
) -> dict[str, Any]:
    """Route execute_trade to BloFin (demo/live) or Bitunix (live only)."""
    exchange = str(record.get("exchange") or "blofin").strip().lower()
    if "bitunix" in exchange:
        client_demo = _coerce_demo_mode_flag(
            raw_body.get("use_demo_mode", raw_body.get("demo_mode"))
        )
        if client_demo:
            logger.info(
                "execute_trade_bitunix_demo_ignored request_id=%s user_id=%s",
                req_id,
                user_id,
            )
        return {
            "exchange": "bitunix",
            "environment": "live",
            "api_base_url": bux.BITUNIX_LIVE_API_BASE_URL,
            "use_demo_mode": False,
        }
    return _resolve_execute_trade_blofin_profile(
        record, raw_body, user_id=user_id, req_id=req_id
    )


def _record_is_bitunix(record: dict[str, Any]) -> bool:
    return "bitunix" in str(record.get("exchange") or "").lower()


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
        "use_demo_mode": body.get("use_demo_mode", body.get("demo_mode")),
    }


def _coerce_positive_float(value: Any) -> Optional[float]:
    try:
        parsed = float(value)
    except (TypeError, ValueError):
        return None
    return parsed if parsed > 0 else None


def _normalize_execute_trade_payload(raw: dict[str, Any]) -> dict[str, Any]:
    """Map Flutter payloads; MARKET when order_type=market or entry_price=\"market\"."""
    data = dict(raw)
    order_token = str(data.get("order_type", "market")).strip().lower()
    entry_raw = data.get("entry_price", data.get("entry"))
    entry_is_market = isinstance(entry_raw, str) and entry_raw.strip().lower() == "market"
    is_market = order_token == "market" or entry_is_market

    if is_market:
        data["order_type"] = "market"
        if entry_is_market:
            sl = _coerce_positive_float(data.get("stop_loss") or data.get("sl"))
            tp1 = _coerce_positive_float(data.get("tp1"))
            ref = (tp1 + sl) / 2 if sl is not None and tp1 is not None else None
            data["entry_price"] = ref if ref is not None else _coerce_positive_float(data.get("entry_price")) or 1.0
    else:
        data["order_type"] = "limit"
    return data


def _is_market_trade_request(trade: ExecuteTradeRequest, raw_body: dict[str, Any]) -> bool:
    """True when client requests immediate market entry."""
    if trade.order_type == "market":
        return True
    entry_raw = raw_body.get("entry_price", raw_body.get("entry"))
    return isinstance(entry_raw, str) and entry_raw.strip().lower() == "market"


def _parse_execute_trade_request(raw_body: dict[str, Any]) -> ExecuteTradeRequest:
    """Validate execute_trade payload (MARKET + LIMIT)."""
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
# Cached egress IP — fetched when an exchange reports IP/WAF failure (Railway → exchange API whitelist).
_CITADEL_EGRESS_IP_CACHE: tuple[float, str] = (0.0, "")


def _citadel_egress_ip_live_lookup() -> str:
    """Live outbound IP from this service (ipify), cached 5 minutes."""
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


def _citadel_egress_ips_for_whitelist() -> list[str]:
    """
    IPs to whitelist at the exchange. Prefer CITADEL_EGRESS_IPS (comma-separated Railway static pool),
    plus live ipify lookup from the running service.
    """
    ips: list[str] = []
    env_raw = (os.getenv("CITADEL_EGRESS_IPS") or "").strip()
    if env_raw:
        for part in env_raw.split(","):
            ip = part.strip()
            if ip and ip not in ips:
                ips.append(ip)
    live = _citadel_egress_ip_live_lookup()
    if live and live not in ips:
        ips.insert(0, live)
    return ips


def _citadel_egress_ip_for_whitelist() -> str:
    """Primary outbound IP (live lookup first, else first static pool entry)."""
    ips = _citadel_egress_ips_for_whitelist()
    return ips[0] if ips else ""


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
    leverage: float,
    base_url: str,
    api_key: str,
    api_secret: str,
    passphrase: str,
    request_id: str = "?",
) -> tuple[str, dict[str, Any]]:
    """
    Position-size % of account → margin budget → notional (× leverage) → contracts.
    Capped by available balance so BloFin never gets an impossible margin request.
    Falls back to env BLOFIN_ORDER_SIZE if balance unavailable (logged).
    """
    inst_id = _blofin_inst_id(coin)
    spec = _blofin_fetch_instrument_spec(base_url=base_url, inst_id=inst_id, request_id=request_id)
    contract_value = float(spec["contractValue"])
    min_size = float(spec["minSize"])
    lot_size = float(spec["lotSize"])
    max_market = float(spec["maxMarketSize"])
    entry = float(entry_price)
    sl_distance = abs(entry - float(stop_loss))
    lev = max(1.0, float(leverage))

    meta: dict[str, Any] = {
        "inst_id": inst_id,
        "contract_value": contract_value,
        "min_size": min_size,
        "lot_size": lot_size,
        "sl_distance": sl_distance,
        "risk_percent": risk_percent,
        "leverage": lev,
    }

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

    # Position size slider = % of available USDT deployed as margin (not SL-risk math).
    margin_budget = available * (float(risk_percent) / 100.0)
    margin_budget = min(margin_budget, available * 0.98)
    notional_per_contract = entry * contract_value

    if notional_per_contract <= 0:
        contracts = min_size
        meta["fallback"] = "invalid_notional_per_contract"
    else:
        notional_target = margin_budget * lev
        contracts = notional_target / notional_per_contract

        # Hard cap: required margin must fit available balance (prevents 103003 insufficient margin).
        max_margin = available * 0.98
        max_contracts_by_balance = (max_margin * lev) / notional_per_contract
        contracts = min(contracts, max_contracts_by_balance)

        # Soft cap: if SL is very tight, don't oversize beyond loss implied by margin budget.
        if sl_distance > 0:
            loss_per_contract = sl_distance * contract_value
            if loss_per_contract > 0:
                max_by_sl = margin_budget / loss_per_contract
                contracts = min(contracts, max_by_sl)
                meta["loss_per_contract"] = loss_per_contract

    contracts = max(min_size, min(contracts, max_market))
    steps = max(1, int(contracts / lot_size))
    contracts = steps * lot_size
    meta.update(
        {
            "margin_budget_usdt": margin_budget,
            "notional_target_usdt": margin_budget * lev,
            "notional_per_contract": notional_per_contract,
            "contracts": contracts,
            "required_margin_usdt": (contracts * notional_per_contract) / lev if lev > 0 else None,
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


def _blofin_limit_order_accepted(
    *,
    state: Any = None,
    filled_size: Any = None,
    filled_amount: Any = None,
) -> tuple[bool, str]:
    """
    LIMIT success = resting on book (live) OR already filled (price traded through limit).
    Returns (ok, limit_status) where limit_status is resting|filled.
    """
    token = str(state or "").strip().lower()
    if token in {"live", "partially_filled"}:
        return True, "resting"
    if _blofin_market_fill_satisfied(
        filled_size=filled_size,
        filled_amount=filled_amount,
        state=state,
    ):
        return True, "filled"
    if token == "filled":
        return True, "filled"
    return False, ""


async def _blofin_confirm_limit_order(
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
    Confirm LIMIT placement succeeded — resting on book OR filled immediately.
    """
    ok, limit_status = _blofin_limit_order_accepted(
        state=placement.get("state"),
        filled_size=placement.get("filled_size"),
        filled_amount=placement.get("filled_amount"),
    )
    if ok:
        logger.info(
            "execute_trade_limit_confirmed request_id=%s order_id=%s source=placement "
            "state=%s limit_status=%s filled=%s",
            request_id,
            order_id,
            placement.get("state"),
            limit_status,
            placement.get("filled_size"),
        )
        return {
            "limit_ok": True,
            "live_ok": limit_status == "resting",
            "ok": True,
            "limit_status": limit_status,
            "state": placement.get("state"),
            "filled_size": placement.get("filled_size"),
            "average_price": placement.get("average_price"),
            "size": placement.get("remaining_size"),
            "poll_attempt": 0,
            "source": "placement",
        }

    await asyncio.sleep(BLOFIN_POST_ORDER_CONFIRM_DELAY_SEC)

    last: dict[str, Any] = {"limit_ok": False, "live_ok": False, "ok": False}
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
        ok, limit_status = _blofin_limit_order_accepted(
            state=detail.get("state"),
            filled_size=detail.get("filled_size"),
            filled_amount=detail.get("filled_amount"),
        )
        limit_ok = bool(detail.get("ok")) and ok
        last = {
            **detail,
            "limit_ok": limit_ok,
            "live_ok": limit_ok and limit_status == "resting",
            "limit_status": limit_status if limit_ok else "",
            "poll_attempt": attempt,
            "source": "order_detail",
        }
        if limit_ok:
            logger.info(
                "execute_trade_limit_confirmed request_id=%s order_id=%s source=order_detail "
                "poll=%s state=%s limit_status=%s filled=%s avg=%s",
                request_id,
                order_id,
                attempt,
                detail.get("state"),
                limit_status,
                detail.get("filled_size"),
                detail.get("average_price"),
            )
            return last
        if attempt < BLOFIN_MARKET_FILL_CONFIRM_MAX_POLLS:
            await asyncio.sleep(BLOFIN_MARKET_FILL_CONFIRM_POLL_SEC)

    logger.warning(
        "execute_trade_limit_unconfirmed request_id=%s order_id=%s polls=%s "
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
    LIMIT: orderType=limit + price (Citadel limit path).
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


def _blofin_place_tpsl_stop_loss(
    *,
    base_url: str,
    api_key: str,
    api_secret: str,
    passphrase: str,
    coin: str,
    direction: str,
    sl_price: float,
    size: str,
    client_order_id: Optional[str] = None,
    request_id: str = "?",
) -> dict[str, Any]:
    """Reduce-only stop-loss via BloFin order-tpsl (after MARKET fill)."""
    inst_id = _blofin_inst_id(coin)
    body: dict[str, Any] = {
        "instId": inst_id,
        "marginMode": BLOFIN_MARGIN_MODE,
        "positionSide": "net",
        "side": _blofin_tp_close_side(direction),
        "slTriggerPrice": str(sl_price),
        "slOrderPrice": "-1",
        "slTriggerPriceType": "last",
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
        log_tag="blofin_place_tpsl_sl",
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


def _resolve_blofin_passphrase(
    record: dict[str, Any],
    *,
    use_demo: Optional[bool] = None,
) -> str:
    """Passphrase for BloFin headers — per-user encrypted value, then live/demo env (never logged)."""
    enc = (record.get("exchange_passphrase_encrypted") or "").strip()
    if enc:
        decrypted = decrypt_secret_at_rest(enc)
        if decrypted:
            return decrypted.strip()

    is_demo = use_demo if use_demo is not None else _record_prefers_blofin_demo(record)
    return _blofin_env_passphrase(is_demo)


def _blofin_verify_exchange_credentials(
    *,
    base_url: str,
    api_key: str,
    api_secret: str,
    passphrase: str,
    request_id: str = "?",
) -> dict[str, Any]:
    """Lightweight signed GET — confirms key/secret/passphrase match the target host."""
    path = f"{BLOFIN_ACCOUNT_BALANCE_PATH}?productType=USDT-FUTURES"
    http_status, _raw, parsed = _blofin_private_request(
        base_url=base_url,
        api_key=api_key,
        api_secret=api_secret,
        passphrase=passphrase,
        method="GET",
        path=path,
        request_id=request_id,
        log_tag="blofin_verify_keys",
    )
    ok = (
        isinstance(parsed, dict)
        and http_status == 200
        and str(parsed.get("code")) == "0"
    )
    code = str(parsed.get("code", "")) if isinstance(parsed, dict) else ""
    msg = parsed.get("msg") if isinstance(parsed, dict) else None
    return {
        "ok": ok,
        "http_status": http_status,
        "code": code,
        "msg": msg,
    }


def _citadel_coin_from_inst_id(inst_id: str) -> str:
    raw = (inst_id or "").strip().upper()
    if "-" in raw:
        return raw.split("-")[0]
    return raw.replace("USDT", "").replace("USD", "")


def _citadel_position_direction(pos_qty: float, position_side: str) -> str:
    side = (position_side or "net").strip().lower()
    if side == "long":
        return "long"
    if side == "short":
        return "short"
    return "long" if pos_qty >= 0 else "short"


def _blofin_fetch_positions(
    *,
    base_url: str,
    api_key: str,
    api_secret: str,
    passphrase: str,
    inst_id: Optional[str] = None,
    request_id: str = "?",
) -> list[dict[str, Any]]:
    """Open BloFin positions — normalized for Citadel Live Positions UI."""
    path = BLOFIN_POSITIONS_PATH
    if inst_id:
        path = f"{path}?instId={inst_id}"
    http_status, _raw, parsed = _blofin_private_request(
        base_url=base_url,
        api_key=api_key,
        api_secret=api_secret,
        passphrase=passphrase,
        method="GET",
        path=path,
        request_id=request_id,
        log_tag="blofin_positions",
    )
    if not isinstance(parsed, dict) or http_status != 200 or str(parsed.get("code")) != "0":
        return []
    rows = parsed.get("data")
    if not isinstance(rows, list):
        return []

    out: list[dict[str, Any]] = []
    for row in rows:
        if not isinstance(row, dict):
            continue
        try:
            qty = float(row.get("positions") or 0)
        except (TypeError, ValueError):
            qty = 0.0
        if abs(qty) <= 0:
            continue
        inst = str(row.get("instId") or "")
        direction = _citadel_position_direction(qty, str(row.get("positionSide") or "net"))
        try:
            entry = float(row.get("averagePrice") or 0)
            mark = float(row.get("markPrice") or 0)
            upnl = float(row.get("unrealizedPnl") or 0)
            upnl_ratio = float(row.get("unrealizedPnlRatio") or 0) * 100.0
            liq = float(row.get("liquidationPrice") or 0)
            lev = float(row.get("leverage") or 1)
        except (TypeError, ValueError):
            continue
        out.append(
            {
                "positionId": str(row.get("positionId") or ""),
                "instId": inst,
                "coin": _citadel_coin_from_inst_id(inst),
                "direction": direction,
                "entryPrice": entry,
                "markPrice": mark,
                "size": abs(qty),
                "leverage": lev,
                "unrealizedPnl": upnl,
                "unrealizedPnlPct": upnl_ratio,
                "liquidationPrice": liq,
                "marginMode": str(row.get("marginMode") or BLOFIN_MARGIN_MODE),
                "positionSide": str(row.get("positionSide") or "net"),
            }
        )
    return out


def _blofin_close_position(
    *,
    base_url: str,
    api_key: str,
    api_secret: str,
    passphrase: str,
    inst_id: str,
    margin_mode: str,
    position_side: str,
    request_id: str = "?",
) -> dict[str, Any]:
    body = {
        "instId": inst_id,
        "marginMode": margin_mode or BLOFIN_MARGIN_MODE,
        "positionSide": position_side or "net",
    }
    http_status, raw_text, parsed = _blofin_private_request(
        base_url=base_url,
        api_key=api_key,
        api_secret=api_secret,
        passphrase=passphrase,
        method="POST",
        path=BLOFIN_CLOSE_POSITION_PATH,
        body=body,
        request_id=request_id,
        log_tag="blofin_close_position",
    )
    if not isinstance(parsed, dict):
        return {
            "ok": False,
            "http_status": http_status,
            "code": "invalid_json",
            "msg": "BloFin close-position returned non-JSON",
            "raw_preview": (raw_text or "")[:500],
        }
    ok = http_status == 200 and str(parsed.get("code")) == "0"
    return {
        "ok": ok,
        "http_status": http_status,
        "code": parsed.get("code"),
        "msg": parsed.get("msg"),
        "response": _blofin_safe_response_log(parsed),
    }


def _blofin_fetch_tpsl_pending(
    *,
    base_url: str,
    api_key: str,
    api_secret: str,
    passphrase: str,
    inst_id: Optional[str] = None,
    request_id: str = "?",
) -> list[dict[str, Any]]:
    path = BLOFIN_ORDERS_TPSL_PENDING_PATH
    if inst_id:
        path = f"{path}?instId={inst_id}"
    http_status, _raw, parsed = _blofin_private_request(
        base_url=base_url,
        api_key=api_key,
        api_secret=api_secret,
        passphrase=passphrase,
        method="GET",
        path=path,
        request_id=request_id,
        log_tag="blofin_tpsl_pending",
    )
    if not isinstance(parsed, dict) or http_status != 200 or str(parsed.get("code")) != "0":
        return []
    rows = parsed.get("data")
    if not isinstance(rows, list):
        return []
    return [r for r in rows if isinstance(r, dict)]


def _blofin_place_trailing_stop_order(
    *,
    base_url: str,
    api_key: str,
    api_secret: str,
    passphrase: str,
    inst_id: str,
    direction: str,
    mark_price: float,
    callback_pct: float,
    size: str,
    request_id: str = "?",
) -> dict[str, Any]:
    cb = max(0.1, min(float(callback_pct), 25.0))
    mark = float(mark_price)
    if mark <= 0:
        return {"ok": False, "msg": "Invalid mark price for trailing stop."}
    sl_price = mark * (1.0 - cb / 100.0) if direction == "long" else mark * (1.0 + cb / 100.0)
    http_status, raw_text, parsed = _blofin_private_request(
        base_url=base_url,
        api_key=api_key,
        api_secret=api_secret,
        passphrase=passphrase,
        method="POST",
        path=BLOFIN_TRADE_ORDER_TPSL_PATH,
        body={
            "instId": inst_id,
            "marginMode": BLOFIN_MARGIN_MODE,
            "positionSide": "net",
            "side": _blofin_tp_close_side(direction),
            "slTriggerPrice": str(sl_price),
            "slOrderPrice": "-1",
            "slTriggerPriceType": "mark",
            "size": str(size),
            "reduceOnly": "true",
        },
        request_id=request_id,
        log_tag="blofin_trailing_stop",
    )
    if not isinstance(parsed, dict):
        return {
            "ok": False,
            "http_status": http_status,
            "code": "invalid_json",
            "msg": "BloFin trailing stop returned non-JSON",
            "raw_preview": (raw_text or "")[:500],
        }
    result = _blofin_parse_tpsl_response(parsed, http_status=http_status)
    result["sl_trigger_price"] = sl_price
    result["callback_pct"] = cb
    return result


def _citadel_resolve_blofin_session(
    http_request: Request,
    user_id: str,
) -> tuple[Optional[dict[str, Any]], Optional[JSONResponse]]:
    """Auth + decrypt BloFin credentials for Citadel position endpoints."""
    req_id = getattr(http_request.state, "request_id", "?")
    header_app_key = (http_request.headers.get("X-API-Key") or http_request.headers.get("x-api-key") or "").strip()
    if not user_id:
        return None, JSONResponse(
            status_code=400,
            content={
                "success": False,
                "detail": "user_id is required.",
                "user_message": "Citadel user id missing.",
                "request_id": req_id,
            },
            headers={"X-Request-ID": req_id},
        )
    if not header_app_key:
        return None, JSONResponse(
            status_code=401,
            content={
                "success": False,
                "detail": "X-API-Key header is required.",
                "user_message": "App API Key required. Open Oracle Citadel Setup.",
                "error_code": "credentials_missing",
                "request_id": req_id,
            },
            headers={"X-Request-ID": req_id},
        )
    record = get_citadel_user_record(user_id)
    if not record:
        return None, JSONResponse(
            status_code=404,
            content={
                "success": False,
                "detail": f"No exchange keys for user_id={user_id}.",
                "user_message": "Exchange keys not found. Re-link in Citadel Setup.",
                "error_code": "credentials_missing",
                "request_id": req_id,
            },
            headers={"X-Request-ID": req_id},
        )
    stored_app_key = (record.get("app_api_key") or "").strip()
    if not stored_app_key or stored_app_key != header_app_key:
        return None, JSONResponse(
            status_code=403,
            content={
                "success": False,
                "detail": "X-API-Key mismatch.",
                "user_message": "App API Key mismatch. Re-save Citadel Setup.",
                "error_code": "credentials_mismatch",
                "request_id": req_id,
            },
            headers={"X-Request-ID": req_id},
        )
    exchange_api_key = (record.get("exchange_api_key") or "").strip()
    exchange_secret_enc = record.get("exchange_secret_encrypted") or ""
    if not exchange_api_key or not exchange_secret_enc:
        return None, JSONResponse(
            status_code=404,
            content={
                "success": False,
                "detail": "Exchange credentials incomplete.",
                "user_message": "Exchange keys incomplete. Re-link in Citadel Setup.",
                "request_id": req_id,
            },
            headers={"X-Request-ID": req_id},
        )
    exchange_secret = decrypt_secret_at_rest(exchange_secret_enc)
    if exchange_secret is None:
        return None, JSONResponse(
            status_code=500,
            content={
                "success": False,
                "detail": "Could not decrypt exchange secret.",
                "user_message": "Server credential error. Re-save exchange keys.",
                "request_id": req_id,
            },
            headers={"X-Request-ID": req_id},
        )
    passphrase = _resolve_blofin_passphrase(
        record,
        use_demo=_record_prefers_blofin_demo(record),
    )
    if not passphrase:
        return None, JSONResponse(
            status_code=500,
            content={
                "success": False,
                "detail": "BloFin passphrase not configured.",
                "user_message": (
                    "BloFin passphrase missing for this environment. "
                    "Re-save keys with passphrase in Citadel Setup, or set BLOFIN_PASSPHRASE_LIVE / "
                    "Blofin_Passpharse_live on Railway for live."
                ),
                "request_id": req_id,
            },
            headers={"X-Request-ID": req_id},
        )
    blofin_profile = _resolve_execute_trade_blofin_profile(record, {}, user_id=user_id, req_id=req_id)
    api_base_url = blofin_profile.get("api_base_url") or BLOFIN_LIVE_API_BASE_URL
    return {
        "req_id": req_id,
        "user_id": user_id,
        "api_key": exchange_api_key,
        "api_secret": exchange_secret,
        "passphrase": passphrase,
        "api_base_url": api_base_url,
        "record": record,
    }, None


def _citadel_resolve_exchange_session(
    http_request: Request,
    user_id: str,
) -> tuple[Optional[dict[str, Any]], Optional[JSONResponse]]:
    """Auth + decrypt exchange credentials for Citadel position/trade endpoints."""
    req_id = getattr(http_request.state, "request_id", "?")
    header_app_key = (http_request.headers.get("X-API-Key") or http_request.headers.get("x-api-key") or "").strip()
    if not user_id:
        return None, JSONResponse(
            status_code=400,
            content={
                "success": False,
                "detail": "user_id is required.",
                "user_message": "Citadel user id missing.",
                "request_id": req_id,
            },
            headers={"X-Request-ID": req_id},
        )
    if not header_app_key:
        return None, JSONResponse(
            status_code=401,
            content={
                "success": False,
                "detail": "X-API-Key header is required.",
                "user_message": "App API Key required. Open Oracle Citadel Setup.",
                "error_code": "credentials_missing",
                "request_id": req_id,
            },
            headers={"X-Request-ID": req_id},
        )
    record = get_citadel_user_record(user_id)
    if not record:
        return None, JSONResponse(
            status_code=404,
            content={
                "success": False,
                "detail": f"No exchange keys for user_id={user_id}.",
                "user_message": "Exchange keys not found. Re-link in Citadel Setup.",
                "error_code": "credentials_missing",
                "request_id": req_id,
            },
            headers={"X-Request-ID": req_id},
        )
    stored_app_key = (record.get("app_api_key") or "").strip()
    if not stored_app_key or stored_app_key != header_app_key:
        return None, JSONResponse(
            status_code=403,
            content={
                "success": False,
                "detail": "X-API-Key mismatch.",
                "user_message": "App API Key mismatch. Re-save Citadel Setup.",
                "error_code": "credentials_mismatch",
                "request_id": req_id,
            },
            headers={"X-Request-ID": req_id},
        )
    exchange_api_key = (record.get("exchange_api_key") or "").strip()
    exchange_secret_enc = record.get("exchange_secret_encrypted") or ""
    if not exchange_api_key or not exchange_secret_enc:
        return None, JSONResponse(
            status_code=404,
            content={
                "success": False,
                "detail": "Exchange credentials incomplete.",
                "user_message": "Exchange keys incomplete. Re-link in Citadel Setup.",
                "request_id": req_id,
            },
            headers={"X-Request-ID": req_id},
        )
    exchange_secret = decrypt_secret_at_rest(exchange_secret_enc)
    if exchange_secret is None:
        return None, JSONResponse(
            status_code=500,
            content={
                "success": False,
                "detail": "Could not decrypt exchange secret.",
                "user_message": "Server credential error. Re-save exchange keys.",
                "request_id": req_id,
            },
            headers={"X-Request-ID": req_id},
        )

    if _record_is_bitunix(record):
        return {
            "req_id": req_id,
            "user_id": user_id,
            "exchange": "bitunix",
            "api_key": exchange_api_key,
            "api_secret": exchange_secret,
            "passphrase": None,
            "api_base_url": bux.BITUNIX_LIVE_API_BASE_URL,
            "record": record,
        }, None

    passphrase = _resolve_blofin_passphrase(
        record,
        use_demo=_record_prefers_blofin_demo(record),
    )
    if not passphrase:
        return None, JSONResponse(
            status_code=500,
            content={
                "success": False,
                "detail": "BloFin passphrase not configured.",
                "user_message": (
                    "BloFin passphrase missing for this environment. "
                    "Re-save keys with passphrase in Citadel Setup, or set BLOFIN_PASSPHRASE_LIVE / "
                    "Blofin_Passpharse_live on Railway for live."
                ),
                "request_id": req_id,
            },
            headers={"X-Request-ID": req_id},
        )
    blofin_profile = _resolve_execute_trade_blofin_profile(record, {}, user_id=user_id, req_id=req_id)
    api_base_url = blofin_profile.get("api_base_url") or BLOFIN_LIVE_API_BASE_URL
    return {
        "req_id": req_id,
        "user_id": user_id,
        "exchange": "blofin",
        "api_key": exchange_api_key,
        "api_secret": exchange_secret,
        "passphrase": passphrase,
        "api_base_url": api_base_url,
        "record": record,
    }, None


def _blofin_user_friendly_error(code: Any, msg: Optional[str]) -> str:
    """Map BloFin API errors to short, actionable Citadel snackbar messages."""
    text = (msg or "").strip()
    code_str = str(code or "")
    lower = text.lower()
    if code_str == "152401" or "access key does not exist" in lower:
        return (
            "BloFin rejected your API key for this environment. "
            "BloFin Demo keys require 'Use Demo/Testnet Mode' ON in Oracle Citadel Setup. "
            "Live keys require Demo OFF."
        )
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
    if code_str == "103003" or "insufficient margin" in lower:
        return (
            "Insufficient margin on BloFin for this position size. "
            "Lower position size % or leverage and try again."
        )
    if code_str in ("152011", "152012", "152013") or "brokerid" in lower.replace(" ", ""):
        return (
            "Your BloFin API key is linked to a broker (created via 'Connect to "
            "Third-Party Applications'). Oracle Citadel needs a standard key. "
            "On BloFin: delete this key, create a new 'API Key' (not the "
            "third-party/broker option), enable 'Trade', then re-save the "
            "Key/Secret/Passphrase in Citadel Setup."
        )
    if code_str == "152404":
        return (
            "BloFin authenticated your key but blocked the trade (code 152404). "
            "Your live API key is missing the 'Trade' permission. On BloFin: "
            "API Management -> edit your key -> enable Trade (Read alone is not enough), "
            "then save the new Key/Secret/Passphrase in Citadel Setup. "
            "Also confirm USDT-M Futures is activated on your live account."
        )
    if "operation is not supported" in lower or "unsupported operation" in lower:
        return (
            "BloFin rejected this order (operation not supported). "
            "Most often the API key lacks 'Trade' permission, or USDT-M Futures "
            "is not activated on this account. Enable Trade on the key, confirm "
            "Demo mode matches your keys, and you are trading USDT perpetual swaps."
        )
    return text or "BloFin could not place the MARKET order. Try again."


def _blofin_is_ip_whitelist_error(code: Any, msg: Optional[str]) -> bool:
    text = (msg or "").lower()
    code_str = str(code or "")
    return code_str == "152406" or ("ip" in text and "whitelist" in text)


def _attach_bitunix_whitelist_ip_if_needed(
    fail_body: dict[str, Any],
    *,
    code: Any = None,
    msg: Optional[str] = None,
    http_status: Optional[int] = None,
) -> None:
    if not bux.is_waf_or_ip_block(code, msg, http_status):
        return
    ips = _citadel_egress_ips_for_whitelist()
    if not ips:
        return
    fail_body["whitelist_ip"] = ips[0]
    fail_body["whitelist_ips"] = ips
    logger.info("bitunix_whitelist_ips_attached ips=%s", ",".join(ips))


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
            _grok_user_friendly_message(response.status_code, body_preview),
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
• xAI/Grok credits or rate limits — add credits at https://console.x.ai/ if Oracle Status shows HTTP 403
• Grok/xAI latency on Railway
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
# Prompts — leverage trader voice (maximum conviction)
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


def oracle_flux_doctrine_block() -> str:
    """
    Oracle Flux + Flux Oscillator doctrine — master-level dual-layer framework for Grok.
    TradingView: Oracle Flux PUB;mQP80cUC (overlay) | Oracle Flux Oscillator PUB;mUlI6Xj4 (pane)
    """
    return """═══════════════════════════════════════
ORACLE FLUX SYSTEM — DUAL-LAYER MASTERY (OVERLAY = WHERE, OSCILLATOR = WHEN)
═══════════════════════════════════════
You run BOTH Oracle Flux (overlay, PUB;mQP80cUC) and the Flux Oscillator (pane, PUB;mUlI6Xj4) on every
chart. They are ONE system read as two layers: the OVERLAY gives you WHERE (auto-Fib levels, EMA/structure
state, signal flags, Score, Engines, Chop), the OSCILLATOR gives you WHEN (Flux Wave timing, Money Flow
momentum, diamonds, pinch/rollover, divergence, OB/OS exhaustion). A master NEVER quotes one layer without
cross-checking the other — location without timing is early, timing without location is noise. When live
Flux values arrive in the user prompt, cite them. When they do not, infer BOTH layers from price action:
Daily VWAP confluence, Fib reactions, Heikin Ashi quality, momentum divergence, and range/chop behavior
exactly as Flux would score them.

LAYER 1 — ORACLE FLUX OVERLAY (levels, structure, state — the WHERE):
• Oracle Score (0–100): composite edge grade. 70+ aligned with HTF = high conviction; sub-50 or fighting
  Daily/4H = downgrade hard or stand down. Score ramping across refreshes = building edge; decaying = fading.
• Conviction % / Conviction label: Flux's graded confidence — fuse with your Overall Bias %; do not ignore
  a 75%+ Flux Conviction when structure + derivatives agree.
• Auto-Fibs (overlay-drawn): 0.236 / 0.382 / 0.5 / 0.618 / 0.786 off the live swing. Golden pocket
  (0.618–0.65) hold + inflow = continuation long; 0.786 rejection at VWAP/OB = classic Flux short. A Fib
  level is only actionable when the oscillator confirms the reaction (Wave turn, diamond, or divergence).
• EMA stack / trend ribbon: EMA 5/20 alignment and slope = trend engine state. Price riding the stack with
  clean HA bodies = continuation permission; EMA compression/flip at a Fib or VWAP = regime change watch.
• Heikin Ashi (Flux-integrated): clean bodies in trend direction = continuation; doji clusters at Fib/VWAP
  = indecision / reversal watch — demand an oscillator event before acting on it.
• STRONG BUY / STRONG SELL (overlay flags): high-priority triggers when aligned with HTF + Daily VWAP +
  derivatives. Veto or ignore when they fight Daily/4H structure — never chase a STRONG BUY into HTF supply.
• Engines (Trend, Momentum, Volume, Structure — when listed): all green = trend continuation permission;
  mixed or red vs your directional call = conflict — name it and cut size or flat.
• Chop Strength: range/chop index — high = messy two-way market; cap conviction, prefer stand-down or
  tight scalp only with clear sweep trigger. Low chop + aligned Engines = trend permission.
• Money Flow state: inflow = bid-led accumulation; outflow = distribution / offer pressure. Outflow +
  rejection at Fib/VWAP = short fuel. Inflow + reclaim = long fuel.
• VWAP confluence: Daily VWAP, Previous Day VWAP, weekly/monthly anchors — Flux weights these heavily.
  Reclaim + inflow + Oracle Score ramp = long bias. Reject + outflow + 0.786 Fib = short bias.

LAYER 2 — FLUX OSCILLATOR (timing, momentum, exhaustion — the WHEN):
• Flux Wave (WT1/WT2 composite: WaveTrend + VWAP momentum + Money Flow): your momentum truth line.
  Cross up through zero = bullish impulse; rollover down through zero = bearish impulse. Crosses INSIDE
  OB/OS zones outrank zero crosses — a bullish cross below -60 is a springboard, above +60 it is late.
• OB/OS zones (±60 / ±80): +80 = extended, exhaustion watch; -80 = capitulation watch. Wave parked in an
  extreme WITH the HTF trend = strength, not an auto-fade — only fade extremes at HTF levels with a
  reversal print (diamond, divergence, or pinch).
• Diamonds (reversal diamonds): highest-quality oscillator print. Diamond at ±80 + HTF level + divergence
  = A+ reversal trigger; diamond mid-range without location = noise, ignore it.
• Money Flow fill: expanding fill in trade direction = fuel; fill contracting while price pushes = move
  running on fumes — tighten stops, stop adding.
• Pinch dots / rollover dots: exhaustion markers — pinch at overbought + HTF resistance = fade fuel;
  rollover at oversold + HTF support = bounce fuel. Cite when inferring exhaustion.
• Oscillator STRONG BUY/SELL dots: LTF trigger confirmation — pair with overlay STRONG flags for A+ entries.
• Divergence (regular/hidden): price vs Flux Wave / Money Flow. Regular bear at resistance + outflow =
  distribution; hidden bull at support + inflow = squeeze setup. Hidden divergence is trend-continuation
  fuel — grade it ABOVE regular divergence when it agrees with Daily/4H.

DUAL-LAYER CONFLUENCE MATRIX (decision logic — apply on every read):
• A+ LONG: golden-pocket/0.618 hold or VWAP reclaim + overlay STRONG BUY + inflow + Engines green + Wave
  crossing up from ≤-60 (or buy diamond / hidden bull divergence) + low Chop, aligned Daily/4H → 75–90%.
• A+ SHORT: 0.786 rejection at VWAP/OB + overlay STRONG SELL + outflow + Wave rolling over in OB (or sell
  diamond / regular bear divergence) + low Chop, aligned Daily/4H → mirror grade.
• Overlay signal WITHOUT oscillator confirmation = location without timing — wait for the Wave turn,
  diamond, or divergence; call it "trigger pending", not a live trade.
• Oscillator extreme AGAINST overlay trend = exhaustion warning — take profit / tighten stops on the trend
  trade; it is NOT an auto-reversal without a diamond or divergence at an HTF level.
• Layers CONFLICT (e.g. STRONG BUY flag but Wave rolling over in OB, or inflow but bear divergence) =
  name the conflict explicitly, downgrade to MODERATE/WEAK, cut size or stand down.
• Both layers agree but FIGHT Daily/4H = counter-trend — cap conviction at 45%, demand printed reversal
  evidence (sweep + reclaim, displacement, funding flip) before any trade card.
• High Chop degrades oscillator signals FIRST — in chop, only sweep-trigger scalps; ignore mid-range
  diamonds and zero crosses.

FLUX INTEGRATION RULES:
• Lead **Key Drivers** with an "Oracle Flux Analysis" bullet that reads BOTH layers (overlay state + the
  oscillator timing that confirms or denies it) when Flux data is present OR when you can infer a clear
  Flux read from structure/VWAP/Fib/HA/momentum on the requested TF.
• **Confluence Summary** must grade STRONG/MODERATE/WEAK using the dual-layer matrix (Score, Money Flow,
  Engines, Chop, Wave, diamonds/divergence) fused with derivatives + liquidity — one decisive sentence.
• **If I Were to Trade Today...**: Trigger must reference Flux events when relevant (STRONG flag,
  0.786 Fib rejection, Flux Wave zero/OB-OS cross, diamond, pinch/rollover, divergence, VWAP reclaim + inflow).
• High Chop Strength + conflicted Engines = "STAND DOWN" or half size — no debate.
• Flux confirms HTF → add conviction. Flux fights HTF → HTF wins; name the veto explicitly.
• Sharp trader tone: "Flux Score 78, inflow, Engines green, Wave curling up from -71 with a buy diamond —
  STRONG BUY aligned with the Daily VWAP reclaim. Long above 94.2k; chop 62 so no runner fantasy."
  Not a tutorial on what Flux is."""


def default_system_prompt(
    mode: str,
    *,
    scalp_mode: bool = False,
    leverage: Optional[float] = None,
    citadel_leverage: bool = False,
) -> str:
    """
    Master system prompt — seasoned leverage trader voice. Preserves exact Flutter headings.
    [leverage] = user's actual leverage (Citadel-configured or request-supplied); 5x default.
    [citadel_leverage] = True when the value comes from the user's Citadel settings (drives the
    mandatory leverage disclosure line in every setup).
    """
    lev = float(leverage) if leverage and 1.0 <= float(leverage) <= 100.0 else float(BLOFIN_DEFAULT_LEVERAGE)
    # Price move on the stop that equals 1% account risk at this leverage (1% / leverage).
    stop_move_pct = 1.0 / lev
    leverage_disclosure = (
        f"Citadel leverage setting ({lev:.0f}x)"
        if citadel_leverage
        else f"assumed {lev:.0f}x default"
    )
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
• DERIVATIVES / POSITIONING: Funding extreme + L/S skew + liq prints = who is trapped; counter crowded side or
  ride the cascade. OI rising into breakout = real; OI flat on rip = suspect.
• SL: Beyond sweep wick / micro structure / Daily VWAP failure — majors ~0.12–0.55% at default {BLOFIN_DEFAULT_LEVERAGE}x.
  State invalidation in price AND time ("dead after 12× 5m bars").
• TP1 (40% of position): Nearest liquidity pool / partial fill of FVG — ≥{MIN_RR_TP1:.1f}:1 R:R
  (target {TARGET_RR_TP1:.1f}:1+). TP2 (60% of position): Extension into next HTF pool only.
• PSYCH: Note FOMO trap, chase risk, or "no edge until X clears" when applicable.
• LABEL: **If I Were to Trade Today...** → "[Long/Short] SCALP Setup:" — trigger, invalidation, time-box.
"""

    scalp_standby = f"""
═══════════════════════════════════════
SCALP PROTOCOL (auto: scalp / quick move / scalping / short-term / ≤45m TF)
═══════════════════════════════════════
On scalp intent: surgical entry, Daily VWAP battlefield, derivatives + liquidity filter, micro SL,
≥{MIN_RR_TP1:.1f}:1 R:R on TP1. Best scalp available or explicit flat — half-measures are for tourists.
"""

    shared = f"""You are On-Chain Oracle AI — an elite crypto leverage trader, the final boss of on-chain and
technical analysis. You live and breathe 5x–100x perps. You speak to funded perp traders who watch liquidity
sweeps, inducement, order blocks, FVGs, BOS/CHOCH, mitigation, displacement, previous highs/lows, fakeouts,
liquidity grabs, sweeping, and reclaiming. Verdicts, not commentary. You have survived every liquidation
cascade, funding squeeze, and fakeout breakout — and you price them before they print.

IDENTITY: Raw, direct, no BS — a sharp leverage trader with 8+ years on futures, calling the board live to
another funded trader. Think Jason Casper / Nick Cipher / Crypto Face energy: confident, practical, zero
fluff. Real money on every word. Aggressive when the edge is real, brutally honest when the setup is messy.
Call the trade, name the invalidation, or command FLAT. Confident — never arrogant. Call out bullshit setups
when you see them; a B-grade setup gets named as one.

VOICE: Short, clear sentences. Active verbs. Price-specific. Talk like one experienced trader to another —
zero hedge-fund talk, zero tutorial voice, zero influencer hype, zero academic phrasing. Lead with edge,
probability, and risk. Be honest about how clean or messy the setup actually is.

TONE EXEMPLAR (match this cadence):
"BTC 1D reclaiming Daily VWAP with strong bid absorption + funding flipping positive. Clean sweep below the
prior lows, buyers stepped in — strong LONG bias here. Below 64.8k I'm out, no debate."

FORBIDDEN (instant credibility kill):
"thesis", "invalidation thesis", "liquidity grabs as primary targets", and academic/hedge-fund framing of any
kind. Also banned: "might", "could", "possibly", "perhaps", "maybe", "it seems", "appears to", "I think",
"I believe", "interesting", "worth watching", "mixed signals" without a verdict, "let me know", "would you
like", "consider", "potentially", "somewhat", "moderately", metric laundry lists, separate sentences for
funding/OI/L-S/liqs, chatbot warmth, tutorial tone.
BANNED JARGON — never use: "session VWAP", "previous session", "tape", "regime", "fade", "macro tape",
"weighted momentum", "Oracle flow", "balanced session", "institutional", "institutional desk", "macro tone",
"order flow footprint", "footprint", "delta profile", "auction market", "smart money desk".
USE INSTEAD: Daily VWAP, Previous Day VWAP, liquidity sweep, inducement, order block, FVG, BOS, CHOCH,
mitigation, displacement, reclaiming, sweeping, liquidity grab, previous highs/lows, fakeout, crowded longs/shorts.

REQUIRED LEXICON (woven naturally): liquidity sweep, inducement, order block, FVG (fair value gap),
BOS (break of structure), CHOCH, mitigation, displacement, reclaiming, sweeping, previous highs/lows,
fakeout, liquidity grab, invalidation, acceptance, rejection, liquidity pool, premium/discount,
crowded longs/shorts, squeeze fuel, cascade, trapped positioning, stop run, breaker, imbalance, HTF veto,
Daily VWAP, Previous Day VWAP.

═══════════════════════════════════════
RULE 0 — LIVE PRICE (ZERO TOLERANCE)
═══════════════════════════════════════
• User prompt = sole authoritative price. Never memory. Never round for convenience.
• **Asset**: EXACT coin | live price | 24h % from prompt.
• SOURCE DISCLOSURE (mandatory): name the price source once, early and naturally — e.g.
  "LIVE from Mobula — $X with $YM pool depth" or "LIVE from CoinGecko Pro". Put it inside
  the first **Key Drivers** bullet — NEVER alter the **Asset** line format.
• Entry / TP1 / TP2 / SL anchored to live NOW. State drift % vs spot when entry is a limit.
• Long: SL < Entry < TP1 ≤ TP2. Short: TP2 ≤ TP1 < Entry < SL. Wrong geometry → fix or omit levels.

═══════════════════════════════════════
RULE 0.5 — LEVERAGE (EVERY SETUP, EVERY CALCULATION)
═══════════════════════════════════════
Always base every Trade Setup, risk calculation, and R:R on the user's chosen leverage.

• If Citadel is configured and leverage is set, use that exact leverage.
• Otherwise default to {BLOFIN_DEFAULT_LEVERAGE}x leverage.

ACTIVE LEVERAGE FOR THIS REQUEST: {lev:.0f}x ({leverage_disclosure})

EXPLICIT LEVERAGE MATH (state it, don't imply it):
• At {lev:.0f}x a 1% account risk ≈ {stop_move_pct:.2f}% price move on the stop.
• State the stop distance in % AND what it means for the account at {lev:.0f}x
  (e.g. "SL {stop_move_pct:.2f}% below entry = 1% account risk at {lev:.0f}x").
• Never park the SL inside the liquidation cascade zone at this leverage — invalidation goes beyond
  the sweep/OB, outside the cluster where stops get run.
• Adjust stop distance, position size, and targets realistically for the chosen leverage.
  Be conservative and professional — leverage amplifies, it does not forgive.

MANDATORY DISCLOSURE: every Trade Setup must include one short line stating the leverage basis,
exactly: "Leverage basis: {leverage_disclosure}". Place it with the TRADE LEVELS block.

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
RULE 2 — GOD-MODE CONFLUENCE STACK (deep integration, zero blind spots)
═══════════════════════════════════════
• MTF: Weekly/Daily/4h bias → requested TF direction → LTF trigger. State ALIGNED or CONFLICTED; conflict
  slashes confidence and demands patience unless a catalyst overrides (funding flip, liq cascade).
• TREND LAW: NEVER fight the higher timeframe blindly. Counter-trend trades demand printed reversal
  evidence (sweep + reclaim, displacement through structure, funding flip) — otherwise trade with the
  Daily/4H or stand down. Counter-trend = reduced size, tighter time box, stated as counter-trend.
• VWAP: Daily VWAP, Previous Day VWAP, weekly, monthly — premium vs discount, clusters within ~0.3–0.8%,
  reclaiming/rejecting Daily VWAP, sweeping prior highs/lows. NEVER "session VWAP" or "previous session".
• STRUCTURE: BOS/CHOCH, order blocks, FVGs, inducement, mitigation, displacement, previous highs/lows
  (liquidity targets), liquidity sweeps, liquidity grabs, fakeouts, sweeping + reclaiming.
• MOMENTUM: EMA 5/20 stack, RSI (>50 bullish structure / <50 bearish structure) + divergence only WITH
  structure, MACD histogram expansion/contraction, volume on breaks vs fakeouts.
• ON-CHAIN / MOBULA (when MOBULA block present — mandatory): DEX liquidity depth, on-chain vs CEX volume
  delta, slippage/trap risk, spot-led vs perp-led flow. Weave into **Volume-Weighted Analysis** and **Market Structure**.
• LIQUIDATION CLUSTERS & BOOK PRESSURE: where are stops stacked, where does the cascade accelerate,
  which side of the book is thin. Liq clusters are targets AND invalidation guides — price hunts them.
• BTC/ETH LEAD (when relevant): risk-on/off for alts, correlation breaks, HTF veto from majors.
• ORACLE FLUX + FLUX OSCILLATOR (PUB;mQP80cUC / PUB;mUlI6Xj4): CORE high-conviction framework — not optional
  garnish. TWO layers, one system: overlay = WHERE (Score, Conviction, auto-Fibs — especially 0.786, EMA
  stack, HA quality, Engines, STRONG BUY/SELL, Chop, Money Flow, VWAP confluence); oscillator = WHEN (Flux
  Wave zero/OB-OS crosses, reversal diamonds, Money Flow fill, pinch/rollover dots, regular/hidden
  divergence). NEVER read one layer without cross-checking the other — overlay signal without oscillator
  timing = trigger pending; oscillator extreme against overlay trend = exhaustion warning, not auto-reversal.
  Live Flux block in user prompt = cite values; no block = infer BOTH layers from structure/VWAP/Fib/HA/
  momentum. STRONG flags are high-priority when HTF-aligned; veto when they fight Daily/4H. High Chop =
  range/chop — cut conviction or stand down.
• PREMIUM BREVITY: Tight trader prose. No filler. Each **Key Drivers** bullet: 2–4 crisp sentences max.
  Do not repeat the same Mobula or derivatives numbers across bullets.

═══════════════════════════════════════
RULE 3 — LEVERAGE & DERIVATIVES MASTERY (prose integration — NOT a data dump)
═══════════════════════════════════════
User prompt supplies live Binance Futures: funding rate, open interest, 5m long/short accounts,
recent liquidations. Mobula may add liquidity/volume context.

Weave derivatives into **Volume-Weighted Analysis**, **Market Structure**, and **Confluence Summary**
(prose integration — NOT a data dump, and NEVER as a separate Liquidity & Sentiment heading):
  Tell the positioning story: Who is crowded? Who just got liquidated? Is OI rising with price
  (new money) or rising against price (shorts adding)? Is funding paying shorts to hold the book?
  Are liqs fueling continuation or marking exhaustion? Tie to stop runs, cascade risk,
  squeeze setup, liquidity grab. Read like a leverage trader sizing a perp — never "Funding is X. OI is Y."

**Confluence Summary** — EXACTLY one sentence. Grade STRONG / MODERATE / WEAK. Fuse structure + VWAP +
  momentum + derivatives + liquidity + Oracle Flux dual-layer (Score, Money Flow, Engines, Chop, STRONG
  flags, Flux Wave, diamonds/divergence) — always.

Derivatives OVERRIDE or CONFIRM technical bias: extreme positive funding + crowded longs = counter-long fuel;
negative funding + rising OI + short liqs = squeeze blueprint; OI collapse after spike = move spent.

{oracle_flux_doctrine_block()}

═══════════════════════════════════════
RULE 4 — CONVICTION, PSYCHOLOGY & EDGE CASES
═══════════════════════════════════════
• **Overall Bias**: Mildly Bullish / Mildly Bearish / Neutral + Confidence %. 80%+ requires MTF +
  structure + derivatives + liquidity alignment. Neutral = discipline, not indecision.
• **If I Were to Trade Today...**: Execution card — NOT a summary. Labeled lines:
  Trigger | Entry (market/limit + level) | Invalidation (price + break) | Time box | Size stance |
  Flip if | Plan B or STAND DOWN. Scalp → "[Long/Short] SCALP Setup:" with minutes-level trigger.
  If flat: state exactly what must print before you deploy capital.
• **Risks & Watchlist**: 2–3 bullets — killer scenarios, event risk, level breaks that void the trade,
  psychological traps (chase, revenge, over-leverage after win).
• WEAK / conflicted / no catalyst → NO **TRADE LEVELS**. "Stand down" is a position.

═══════════════════════════════════════
RULE 4.5 — ORACLE VISION / PULSE: HIGHER-TIMEFRAME TREND DISCIPLINE
═══════════════════════════════════════
Vision-sourced setups answer to the higher timeframe FIRST. No exceptions.
• ALWAYS check Daily + 4H bias BEFORE assigning high conviction. A lower-TF signal that fights
  Daily/4H structure is a counter-trend trade — grade it like one.
• Clear bearish trend (price below Daily VWAP, lower highs/lower lows, heavy selling volume):
  heavily reduce LONG conviction. Favor shorts — or call "No Trade / Caution" when nothing aligns.
• MACRO FILTER: When the Daily bias is strongly bearish, LONG conviction is CAPPED at 45% MAX —
  unless very strong liquidity reversal evidence prints (sweep + reclaim of previous lows,
  aggressive bid absorption, funding reset/flip). Mirror logic for shorts in strongly bullish Dailies.
• NEVER stamp high-conviction longs across the board during a market dump. A dump is a short
  board or a stand-down board — not a discount rack.
• Short squeeze heat and long liquidation clusters remain valid signals — but they are context,
  not a trade by themselves. Balance squeeze/liq reads against the Daily + 4H trend before grading.
• High conviction (70%+) is reserved for setups ALIGNED with the higher-timeframe trend.

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
- Oracle Flux Analysis: Oracle Score, Conviction, Money Flow, Flux Wave, Engines, STRONG BUY/SELL, Chop
  Strength, Fib rejections (0.786 key), VWAP confluence, pinch/rollover (oscillator), divergence — live
  Flux values when block present; otherwise infer from structure/HA/VWAP on requested TF.
- Volume-Weighted Analysis: ...
- Heikin Ashi Analysis: ...
- Market Structure: ...

FORBIDDEN Key Drivers bullets (do NOT output these headings): Liquidity & Sentiment, Fibonacci Retracements,
Technicals. Weave fib levels, MACD/RSI/EMA, and derivatives/positioning into the bullets above instead.

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
• Confluence bar: Oracle Flux (Score/Money Flow/Engines/Chop/STRONG) + Daily VWAP + order blocks/FVGs +
  structure + momentum + funding/OI/L-S/liqs.
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
• Lead with bias and edge — stream-trader voice. Integrate BTC/ETH lead, derivatives, and on-chain liquidity.
• **TRADE LEVELS** only on MODERATE/STRONG confluence with ≥{MIN_RR_TP1:.1f}:1 R:R — otherwise omit and
  state what must develop before capital is deployed.
• WEAK / MTF conflict / crowded positioning without catalyst → flat is the professional call.
"""
    )


# ---------------------------------------------------------------------------
# Oracle Trader AI Chat (POST /chat only)
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
    lines: list[str] = [
        f"═══ LIVE ORACLE DATA — {upper} (Oracle Desk / Chat — server-fed, weave into prose) ═══"
    ]
    limitations: list[str] = []

    mobula = fetch_mobula_price(upper)
    price: Optional[float] = None
    if mobula:
        price = float(mobula["price"])
        lines.append(format_live_price_banner(mobula))
        if mobula.get("liquidity_usd"):
            lines.append(f"Pool liquidity depth: {_compact_usd_label(mobula['liquidity_usd'])}")
        on_vol = float(mobula.get("on_chain_volume_usd") or 0)
        off_vol = float(mobula.get("off_chain_volume_usd") or 0)
        if on_vol > 0 or off_vol > 0:
            total = on_vol + off_vol
            on_pct = 100.0 * on_vol / total if total > 0 else 0
            lines.append(
                f"Volume delta: {on_pct:.0f}% on-chain / {100.0 - on_pct:.0f}% CEX — "
                "weight conviction by which side leads flow."
            )
    else:
        limitations.append(f"Mobula live quote unavailable for {upper}")
        cg_snap = fetch_coingecko_market_aggressive(upper)
        if cg_snap:
            price = float(cg_snap["price"])
            lines.append(format_live_price_banner(cg_snap))
            lines.append(format_coingecko_pro_prompt_block(cg_snap).strip())
        else:
            try:
                snap = fetch_market_snapshot(upper)
                price = float(snap["price"])
                lines.append(format_live_price_banner(snap))
            except HTTPException:
                limitations.append(
                    f"No live price feed for {upper} — analyze from principles; ask user for symbol/chart"
                )

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
    return f"""You are Oracle Trader AI — the same elite, battle-hardened crypto leverage trader behind On-Chain
Oracle AI reports. The final boss of on-chain and technical analysis. You live in 5x–100x perps. You speak to
funded perp traders who watch liquidity sweeps, inducement, order blocks, FVGs, BOS/CHOCH, mitigation,
displacement, previous highs/lows, fakeouts, and liquidity grabs. Raw, direct, decisive — never defensive.

MISSION: Every reply must deliver REAL EDGE — even on vague questions. You always attempt a full trader-quality
read with whatever you have. If data is thin, you still call structure, scenarios, and risk — then state
limitations in one short line at the end. Never open with "I can't" or "I'm unable" without first giving
actionable value. Be aggressive when the edge is real, brutally honest about risk when it is not.

VOICE: Sharp, professional, relatable — like an experienced leverage trader on a live call. Short paragraphs.
Price-specific when possible. Zero fluff. Zero excuses. No influencer hype. No tutorial voice.
BANNED hedge-fund talk: "regime", "tape", "fade", "session", "institutional", "order flow footprint",
"smart money desk". Use Daily VWAP and Previous Day VWAP.

FORBIDDEN OPENERS / FILLER:
"I can't", "I'm unable", "I don't have access" (without prior value), "might", "could", "maybe",
"possibly", "it seems", "as an AI", hedging without a verdict, metric laundry lists, apologizing.

REQUIRED BEHAVIOR:
• LEAD WITH THE CALL: bias, edge, or flat — then support it (MTF, Daily VWAP, structure, derivatives).
• SOURCE DISCLOSURE: when a [LIVE ORACLE DATA] block is present, cite the feed once naturally
  (e.g. "LIVE from Mobula — $X") so the trader knows the read is on fresh data.
• TREND LAW: never fight the Daily/4H blindly. Counter-trend ideas demand printed reversal evidence
  (sweep + reclaim, displacement, funding flip) — otherwise call it counter-trend and size it down or stand down.
• LEVERAGE MASTERY: funding, OI, long/short ratio, liquidation cascades, squeeze/cascade, crowded side,
  stop runs, liquidity pools, liquidity sweeps, inducement, mitigation. Default {BLOFIN_DEFAULT_LEVERAGE}x unless Citadel leverage specified.
  When giving levels, state the stop distance % and what it means for the account at the active leverage
  (at 5x, a 1% account risk ≈ 0.20% price move on the stop).
• TECHNICAL DEPTH: Daily VWAP, Previous Day VWAP, weekly/monthly VWAP, order blocks, FVGs, BOS/CHOCH,
  premium/discount, previous highs/lows, fakeouts, displacement, HTF/LTF alignment, DEX vs CEX volume delta,
  liquidation clusters, macro risk-on/off for alts.
• ORACLE FLUX + FLUX OSCILLATOR (PUB;mQP80cUC / PUB;mUlI6Xj4): core high-conviction framework on every
  chart read — two layers, one system. Overlay = WHERE: Oracle Score, Conviction, Money Flow (inflow/
  outflow), auto-Fibs (0.786 key, golden pocket), EMA stack, HA quality, Engines, STRONG BUY/SELL, Chop
  Strength, VWAP confluence. Oscillator = WHEN: Flux Wave zero/OB-OS (±60/±80) crosses, reversal diamonds,
  Money Flow fill, pinch/rollover dots, regular/hidden divergence. Cross-check both before any call:
  overlay level without oscillator timing = trigger pending; Wave extreme against the trend = exhaustion
  warning, not auto-reversal — demand a diamond or divergence at an HTF level to fade. When [ORACLE FLUX]
  live values are in context, cite them. When not, infer BOTH layers from VWAP/Fib/HA/momentum. STRONG
  flags = high-priority when HTF-aligned; veto when fighting Daily/4H. High Chop = stand down or scalp only
  (mid-range diamonds and zero crosses don't count in chop). Weave Flux into bias and levels — never a
  standalone reason to trade without structure + derivatives backing it.
• LEVELS (when user wants a trade): Entry at $X, TP1 (40%) at $X, TP2 (60%) at $X, SL at $X (R:R X.X:1).
  TP1 = 40% of position (min {MIN_RR_TP1:.1f}:1 R:R, target {TARGET_RR_TP1:.1f}:1+). TP2 = 60% runner.
  SL = structural invalidation beyond sweep/OB/Daily VWAP.
• RISK & PSYCH: size for invalidation, FOMO/chase/revenge, event risk, when to stand down.
• PROACTIVE TRADER SERVICE — end EVERY reply with:
  — 1–2 sharp follow-up questions (specific, not generic), AND
  — 1 concrete next step (e.g. "pull 15m for trigger", "watch funding flip", "stand aside until Daily VWAP reclaim").
• ALTERNATIVES: when main idea is weak, offer Plan A / Plan B (e.g. breakout long vs short into resistance).
• Server-fed [LIVE ORACLE DATA] blocks are authoritative when present — weave into prose, not bullet dumps.
• Do NOT append the formal report disclaimer unless user asks for a full written report.
• Chat format: conversational markdown OK; no mandatory report headings unless user requests a full report.

You are talking to a leverage trader who paid for edge. Sound like you have real money on the line.

{oracle_flux_doctrine_block()}"""


# ---------------------------------------------------------------------------
# Oracle Flux — chart indicator context (optional confirmation layer for Grok)
# Parses structured Flux payloads when present; no-op when absent (100% backward compatible).
# ---------------------------------------------------------------------------

_FLUX_FIELD_ALIASES: dict[str, tuple[str, ...]] = {
    "oracle_score": ("oracle_score", "oracleScore", "score", "flux_score", "fluxScore"),
    "conviction_pct": (
        "conviction_pct",
        "convictionPct",
        "conviction_percent",
        "convictionPercent",
        "conviction",
    ),
    "conviction_label": ("conviction_label", "convictionLabel", "conviction_state", "convictionState"),
    "money_flow": (
        "money_flow",
        "moneyFlow",
        "money_flow_state",
        "moneyFlowState",
        "mf_state",
        "mfState",
    ),
    "nearest_fib": (
        "nearest_fib",
        "nearestFib",
        "nearest_fib_level",
        "nearestFibLevel",
        "fib_level",
        "fibLevel",
        "fib",
    ),
    "strong_buy": ("strong_buy", "strongBuy", "strong_buy_active", "strongBuyActive"),
    "strong_sell": ("strong_sell", "strongSell", "strong_sell_active", "strongSellActive"),
    "chop_strength": ("chop_strength", "chopStrength", "chop", "chop_index", "chopIndex"),
    "direction_bias": ("direction_bias", "directionBias", "bias", "flux_bias", "fluxBias"),
    "engines": ("engines", "flux_engines", "fluxEngines", "engine_states", "engineStates"),
    # Flux Oscillator (pane, PUB;mUlI6Xj4) — optional timing-layer fields.
    "flux_wave": ("flux_wave", "fluxWave", "wave", "wave_value", "waveValue", "wt1", "wt"),
    "wave_state": (
        "wave_state",
        "waveState",
        "wave_cross",
        "waveCross",
        "wave_signal",
        "waveSignal",
    ),
    "diamond": (
        "diamond",
        "diamonds",
        "reversal_diamond",
        "reversalDiamond",
        "diamond_signal",
        "diamondSignal",
    ),
    "divergence": ("divergence", "div", "divergence_type", "divergenceType", "divergence_state"),
    "oscillator_zone": (
        "oscillator_zone",
        "oscillatorZone",
        "ob_os",
        "obOs",
        "ob_os_zone",
        "obOsZone",
        "oscillator_state",
        "oscillatorState",
    ),
}


@dataclass
class OracleFluxSnapshot:
    """Normalized Oracle Flux (overlay) + Flux Oscillator (pane) read for AI prompt injection."""

    oracle_score: Optional[float] = None
    conviction_pct: Optional[float] = None
    conviction_label: Optional[str] = None
    money_flow: Optional[str] = None
    nearest_fib: Optional[str] = None
    strong_buy: Optional[bool] = None
    strong_sell: Optional[bool] = None
    engines: dict[str, str] = field(default_factory=dict)
    chop_strength: Optional[float] = None
    direction_bias: Optional[str] = None
    # Oscillator (timing layer) — all optional; legacy payloads simply leave them None.
    flux_wave: Optional[float] = None
    wave_state: Optional[str] = None
    diamond: Optional[str] = None
    divergence: Optional[str] = None
    oscillator_zone: Optional[str] = None

    def has_signal(self) -> bool:
        return any(
            [
                self.oracle_score is not None,
                self.conviction_pct is not None,
                bool(self.conviction_label),
                bool(self.money_flow),
                bool(self.nearest_fib),
                self.strong_buy is True,
                self.strong_sell is True,
                bool(self.engines),
                self.chop_strength is not None,
                bool(self.direction_bias),
                self.flux_wave is not None,
                bool(self.wave_state),
                bool(self.diamond),
                bool(self.divergence),
                bool(self.oscillator_zone),
            ]
        )


def _flux_first_value(data: dict[str, Any], *keys: str) -> Any:
    for key in keys:
        if key in data and data[key] is not None:
            return data[key]
    lower_map = {str(k).lower(): v for k, v in data.items()}
    for key in keys:
        hit = lower_map.get(key.lower())
        if hit is not None:
            return hit
    return None


def _flux_coerce_float(value: Any) -> Optional[float]:
    if value is None:
        return None
    if isinstance(value, (int, float)):
        return float(value)
    text = str(value).strip().replace("%", "")
    if not text:
        return None
    try:
        return float(text)
    except ValueError:
        match = re.search(r"-?\d+(?:\.\d+)?", text)
        if match:
            try:
                return float(match.group(0))
            except ValueError:
                return None
    return None


def _flux_coerce_bool(value: Any) -> Optional[bool]:
    if value is None:
        return None
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return bool(value)
    text = str(value).strip().lower()
    if text in {"1", "true", "yes", "y", "on", "active", "present", "detected"}:
        return True
    if text in {"0", "false", "no", "n", "off", "inactive", "none", "absent"}:
        return False
    return None


def _flux_normalize_money_flow(value: Any) -> Optional[str]:
    if value is None:
        return None
    text = str(value).strip().lower().replace("_", " ").replace("-", " ")
    if not text:
        return None
    if any(token in text for token in ("inflow", "in flow", "accumulation", "accumulating", "buying pressure")):
        return "inflow"
    if any(token in text for token in ("outflow", "out flow", "distribution", "distributing", "selling pressure")):
        return "outflow"
    if any(token in text for token in ("neutral", "flat", "balanced", "sideways", "mixed")):
        return "neutral"
    if "bull" in text:
        return "inflow"
    if "bear" in text:
        return "outflow"
    return text


def _flux_normalize_fib(value: Any) -> Optional[str]:
    if value is None:
        return None
    text = str(value).strip().lower().replace("fib", "").strip()
    if not text:
        return None
    match = re.search(r"(?:0?\.\d{1,3}|1\.0{0,3})", text)
    if match:
        fib = match.group(0)
        if fib.startswith("."):
            return f"0{fib}"
        return fib
    return text


def _flux_parse_engines(value: Any) -> dict[str, str]:
    engines: dict[str, str] = {}
    if value is None:
        return engines
    if isinstance(value, dict):
        for name, state in value.items():
            label = str(name).strip()
            state_text = str(state).strip()
            if label and state_text:
                engines[label] = state_text
        return engines
    if isinstance(value, list):
        for item in value:
            if isinstance(item, dict):
                engines.update(_flux_parse_engines(item))
            elif isinstance(item, str) and ":" in item:
                name, state = item.split(":", 1)
                engines[name.strip()] = state.strip()
        return engines
    if isinstance(value, str):
        for chunk in re.split(r"[|;]", value):
            chunk = chunk.strip()
            if not chunk:
                continue
            if ":" in chunk:
                name, state = chunk.split(":", 1)
                engines[name.strip()] = state.strip()
            elif " " in chunk:
                name, state = chunk.split(" ", 1)
                engines[name.strip()] = state.strip()
    return engines


def _flux_clean_text(value: Any) -> Optional[str]:
    """Normalize a free-form oscillator field (diamond / divergence / wave state / zone)."""
    if value is None:
        return None
    if isinstance(value, bool):
        return "active" if value else None
    text = str(value).strip()
    if not text or text.lower() in {"none", "false", "0", "off", "inactive", "absent", "n/a", "na"}:
        return None
    return text


def _flux_split_conviction(value: Any) -> tuple[Optional[float], Optional[str]]:
    pct = _flux_coerce_float(value)
    if pct is not None and 0 <= pct <= 100:
        return pct, None
    if pct is not None and pct > 100:
        return None, str(value).strip()
    text = str(value).strip() if value is not None else ""
    if not text:
        return None, None
    return None, text


def parse_oracle_flux(raw: Any) -> Optional[OracleFluxSnapshot]:
    """Parse a Flux payload dict (or JSON string) into a normalized snapshot."""
    if raw is None:
        return None
    if isinstance(raw, str):
        text = raw.strip()
        if not text:
            return None
        try:
            raw = json.loads(text)
        except json.JSONDecodeError:
            return None
    if not isinstance(raw, dict):
        return None

    snap = OracleFluxSnapshot()
    snap.oracle_score = _flux_coerce_float(
        _flux_first_value(raw, *_FLUX_FIELD_ALIASES["oracle_score"])
    )
    conviction_raw = _flux_first_value(raw, *_FLUX_FIELD_ALIASES["conviction_pct"])
    snap.conviction_pct, snap.conviction_label = _flux_split_conviction(conviction_raw)
    label_only = _flux_first_value(raw, *_FLUX_FIELD_ALIASES["conviction_label"])
    if label_only and not snap.conviction_label:
        snap.conviction_label = str(label_only).strip()
    snap.money_flow = _flux_normalize_money_flow(
        _flux_first_value(raw, *_FLUX_FIELD_ALIASES["money_flow"])
    )
    snap.nearest_fib = _flux_normalize_fib(
        _flux_first_value(raw, *_FLUX_FIELD_ALIASES["nearest_fib"])
    )
    snap.strong_buy = _flux_coerce_bool(
        _flux_first_value(raw, *_FLUX_FIELD_ALIASES["strong_buy"])
    )
    snap.strong_sell = _flux_coerce_bool(
        _flux_first_value(raw, *_FLUX_FIELD_ALIASES["strong_sell"])
    )
    snap.chop_strength = _flux_coerce_float(
        _flux_first_value(raw, *_FLUX_FIELD_ALIASES["chop_strength"])
    )
    bias = _flux_first_value(raw, *_FLUX_FIELD_ALIASES["direction_bias"])
    snap.direction_bias = str(bias).strip() if bias is not None else None
    snap.engines = _flux_parse_engines(_flux_first_value(raw, *_FLUX_FIELD_ALIASES["engines"]))
    # Oscillator (timing layer) — optional; absent on legacy payloads.
    snap.flux_wave = _flux_coerce_float(_flux_first_value(raw, *_FLUX_FIELD_ALIASES["flux_wave"]))
    snap.wave_state = _flux_clean_text(_flux_first_value(raw, *_FLUX_FIELD_ALIASES["wave_state"]))
    snap.diamond = _flux_clean_text(_flux_first_value(raw, *_FLUX_FIELD_ALIASES["diamond"]))
    snap.divergence = _flux_clean_text(_flux_first_value(raw, *_FLUX_FIELD_ALIASES["divergence"]))
    snap.oscillator_zone = _flux_clean_text(
        _flux_first_value(raw, *_FLUX_FIELD_ALIASES["oscillator_zone"])
    )

    if snap.has_signal():
        return snap
    return None


def _flux_dict_has_markers(data: dict[str, Any]) -> bool:
    lowered = {str(k).lower() for k in data.keys()}
    markers = {
        "oracle_score",
        "oraclescore",
        "conviction",
        "money_flow",
        "moneyflow",
        "chop_strength",
        "chopstrength",
        "strong_buy",
        "strongbuy",
        "strong_sell",
        "strongsell",
        "nearest_fib",
        "nearestfib",
        "engines",
        "flux_engines",
        "flux_wave",
        "fluxwave",
        "wave_state",
        "wavestate",
        "diamond",
        "diamonds",
        "divergence",
        "oscillator_zone",
        "oscillatorzone",
    }
    return bool(lowered & markers)


def extract_oracle_flux_from_request(request: AnalyzeRequest) -> Optional[OracleFluxSnapshot]:
    """Collect Flux data from optional request fields without breaking legacy clients."""
    candidates: list[dict[str, Any]] = []

    if isinstance(request.oracle_flux, dict):
        candidates.append(request.oracle_flux)

    ctx = request.chart_context
    if isinstance(ctx, dict):
        nested = (
            ctx.get("oracle_flux")
            or ctx.get("oracleFlux")
            or ctx.get("flux")
        )
        if isinstance(nested, dict):
            candidates.append(nested)
        elif _flux_dict_has_markers(ctx):
            candidates.append(ctx)
    elif isinstance(ctx, str) and ctx.strip():
        try:
            parsed = json.loads(ctx)
        except json.JSONDecodeError:
            parsed = None
        if isinstance(parsed, dict):
            nested = (
                parsed.get("oracle_flux")
                or parsed.get("oracleFlux")
                or parsed.get("flux")
            )
            if isinstance(nested, dict):
                candidates.append(nested)
            elif _flux_dict_has_markers(parsed):
                candidates.append(parsed)

    for raw in candidates:
        snap = parse_oracle_flux(raw)
        if snap is not None:
            logger.info(
                "oracle_flux_parsed score=%s conviction=%s money_flow=%s fib=%s strong_buy=%s strong_sell=%s "
                "chop=%s wave=%s diamond=%s divergence=%s",
                snap.oracle_score,
                snap.conviction_pct if snap.conviction_pct is not None else snap.conviction_label,
                snap.money_flow,
                snap.nearest_fib,
                snap.strong_buy,
                snap.strong_sell,
                snap.chop_strength,
                snap.flux_wave if snap.flux_wave is not None else snap.wave_state,
                snap.diamond,
                snap.divergence,
            )
            return snap
    return None


def format_oracle_flux_prompt_block(flux: Optional[OracleFluxSnapshot]) -> str:
    """Inject live Flux snapshot when present; always prepend doctrine for Grok depth."""
    doctrine = oracle_flux_doctrine_block()
    if flux is None or not flux.has_signal():
        return (
            "═══ ORACLE FLUX — LIVE SNAPSHOT NOT PROVIDED (infer Flux read from structure) ═══\n"
            "Charts run Oracle Flux PUB;mQP80cUC + Flux Oscillator PUB;mUlI6Xj4. No live Flux payload "
            "in this request — infer Oracle Score, Money Flow, Flux Wave, Engines, Chop, STRONG flags, "
            "Fib rejections, and VWAP confluence from price action on the requested TF. Apply full Flux "
            "doctrine below.\n\n"
            f"{doctrine}\n\n"
        )

    lines = [
        "═══ ORACLE FLUX — LIVE CHART READ (PUB;mQP80cUC + PUB;mUlI6Xj4) — CORE CONVICTION INPUT ═══",
        "Treat these as authoritative Flux values. Fuse with HTF structure + derivatives; HTF veto wins on conflict.",
        "Weave into Oracle Flux Analysis, Confluence Summary, and trade trigger (e.g. \"Score 74 + 0.786 Fib "
        "rejection + Money Flow outflow + STRONG SELL + Wave rolling over in OB → high-conviction short\").",
        "High Chop Strength = range/chop — downgrade conviction or stand down unless clean sweep trigger.",
    ]

    overlay_lines: list[str] = []
    if flux.oracle_score is not None:
        overlay_lines.append(f"Oracle Score: {flux.oracle_score:.0f}/100")
    if flux.conviction_pct is not None:
        overlay_lines.append(f"Flux Conviction: {flux.conviction_pct:.0f}%")
    elif flux.conviction_label:
        overlay_lines.append(f"Flux Conviction: {flux.conviction_label}")
    if flux.money_flow:
        overlay_lines.append(f"Money Flow: {flux.money_flow}")
    if flux.nearest_fib:
        overlay_lines.append(f"Nearest Fib level: {flux.nearest_fib} (rejection/hold context)")
    if flux.strong_buy is True:
        overlay_lines.append("STRONG BUY: active on chart")
    if flux.strong_sell is True:
        overlay_lines.append("STRONG SELL: active on chart")
    if flux.engines:
        engine_text = " | ".join(f"{name}: {state}" for name, state in flux.engines.items())
        overlay_lines.append(f"Engines: {engine_text}")
    if flux.chop_strength is not None:
        overlay_lines.append(f"Chop Strength: {flux.chop_strength:.0f} (higher = messier range)")
    if flux.direction_bias:
        overlay_lines.append(f"Flux directional bias: {flux.direction_bias}")

    oscillator_lines: list[str] = []
    if flux.flux_wave is not None:
        oscillator_lines.append(
            f"Flux Wave: {flux.flux_wave:+.0f} (±60 OB/OS, ±80 extreme — crosses inside zones outrank zero crosses)"
        )
    if flux.wave_state:
        oscillator_lines.append(f"Wave state: {flux.wave_state}")
    if flux.diamond:
        oscillator_lines.append(f"Reversal diamond: {flux.diamond} (A+ only at HTF level + divergence)")
    if flux.divergence:
        oscillator_lines.append(f"Divergence: {flux.divergence} (hidden = continuation fuel; regular = reversal watch)")
    if flux.oscillator_zone:
        oscillator_lines.append(f"Oscillator zone: {flux.oscillator_zone}")

    if overlay_lines:
        lines.append("— OVERLAY (WHERE — levels/structure/state):")
        lines.extend(overlay_lines)
    if oscillator_lines:
        lines.append("— OSCILLATOR (WHEN — timing/momentum/exhaustion):")
        lines.extend(oscillator_lines)
        lines.append(
            "Cross-check layers NOW: overlay signal without oscillator confirmation = trigger pending; "
            "oscillator extreme against overlay trend = exhaustion warning, not auto-reversal."
        )
    elif overlay_lines:
        lines.append(
            "No live oscillator fields in this payload — infer Flux Wave posture, diamonds, and divergence "
            "from momentum/HA/volume on the requested TF before grading conviction."
        )

    lines.append(
        "Mandatory: Oracle Flux Analysis bullet in **Key Drivers** reading BOTH layers + "
        "dual-layer-weighted **Confluence Summary**."
    )
    lines.append("")
    lines.append(doctrine)
    return "\n".join(lines) + "\n\n"


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
- Oracle Flux Analysis: Oracle Score, Conviction, Money Flow, Flux Wave, Engines, STRONG BUY/SELL, Chop
  Strength, Fib rejections (0.786 key), VWAP confluence, pinch/rollover, divergence — cite live Flux when
  in prompt; otherwise infer from structure/HA/VWAP on requested TF.
- Volume-Weighted Analysis: Daily VWAP, Previous Day VWAP, weekly / monthly VWAP — premium vs discount,
  acceptance vs rejection, cluster zones (~0.3–0.8%), mean-reversion vs trend continuation. Weave
  on-chain/CEX flow and derivatives positioning here when relevant.
- Heikin Ashi Analysis: Trend quality, indecision wicks, reversal vs continuation read on requested TF.
- Market Structure: BOS/CHOCH, order blocks, FVGs, inducement, mitigation, displacement, previous highs/lows,
  liquidity sweeps/grabs, range boundaries, liquidity targets. Include fib confluence and momentum context
  inline when relevant — do NOT use separate Fibonacci or Technicals headings.

FORBIDDEN Key Drivers bullets — never output: Liquidity & Sentiment, Fibonacci Retracements, Technicals.

**Confluence Summary**: Exactly ONE sentence. Grade STRONG / MODERATE / WEAK. State the edge in plain
trader language — fuse Oracle Flux (Score, Money Flow, Engines, Chop, STRONG flags) + structure +
derivatives + liquidity.

**If I Were to Trade Today...**
- [Long/Short] Setup: (or [Long/Short] SCALP Setup: if scalping)
  Write as an execution card (keep labels; one line each):
  Trigger: [exact event — Daily VWAP reclaim/reject, sweep+hold, BOS retest, inducement+mitigation, funding flip]
  Entry: [market now | limit at $X OB/FVG] — drift vs live spot if limit
  Invalidation: [$X + what structure breaks] — hard stop, no debate
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


def resolve_prompt_leverage(
    *,
    user_id: Optional[str] = None,
    system_prompt: Optional[str] = None,
    request_leverage: Optional[float] = None,
) -> tuple[float, bool]:
    """
    User's actual leverage for every analysis / trade-setup prompt.
    Priority: explicit request value → leverage named in client system prompt →
    Citadel record (last leverage used on execute_trade) → 5x default.
    Returns (leverage, is_user_set); is_user_set=False means the 5x default was
    assumed — drives the "assumed 5x default" disclosure in the report.
    """
    if request_leverage is not None:
        try:
            lev = float(request_leverage)
            if 1.0 <= lev <= 100.0:
                return lev, True
        except (TypeError, ValueError):
            pass

    if system_prompt:
        for pattern in (
            r"leverage[^\d]{0,12}(\d{1,3})\s*x",
            r"(\d{1,3})\s*x\s*leverage",
            r"leverage\s*[:=]\s*(\d{1,3})",
        ):
            match = re.search(pattern, system_prompt, re.IGNORECASE)
            if match:
                try:
                    lev = float(match.group(1))
                    if 1.0 <= lev <= 100.0:
                        return lev, True
                except (TypeError, ValueError):
                    pass

    if user_id:
        record = _citadel_blofin_linked_record(user_id)
        if record:
            try:
                stored = float(record.get("leverage") or 0)
                if 1.0 <= stored <= 100.0:
                    return stored, True
            except (TypeError, ValueError):
                pass

    return float(BLOFIN_DEFAULT_LEVERAGE), False


def remember_citadel_leverage(user_id: str, leverage: float) -> None:
    """Persist last-used Citadel leverage so future analyses use the user's exact setting."""
    try:
        store = _load_citadel_key_store()
        record = store.get(user_id)
        if not isinstance(record, dict):
            return
        lev = max(1.0, min(100.0, float(leverage)))
        if record.get("leverage") == lev:
            return
        record["leverage"] = lev
        store[user_id] = record
        _save_citadel_key_store(store)
        logger.info("citadel_leverage_remembered user_id=%s leverage=%sx", user_id[:16], lev)
    except Exception as exc:
        logger.warning("citadel_leverage_remember_failed user_id=%s err=%s", (user_id or "")[:16], exc)


def build_analyze_user_prompt(
    *,
    coin: str,
    timeframe: str,
    mode: str,
    direction: str,
    market: dict[str, Any],
    scalp_mode: bool = False,
    derivatives: Optional[dict[str, Any]] = None,
    vision_confluence_pct: Optional[float] = None,
    oracle_flux: Optional[OracleFluxSnapshot] = None,
    user_id: Optional[str] = None,
    system_prompt: Optional[str] = None,
    leverage: Optional[float] = None,
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
    coingecko_block = format_coingecko_pro_prompt_block(market)
    flux_block = format_oracle_flux_prompt_block(oracle_flux)
    market_fallback_note = format_market_data_fallback_note(market)
    live_price_banner = format_live_price_banner(market)
    prompt_leverage, leverage_is_user_set = resolve_prompt_leverage(
        user_id=user_id,
        system_prompt=system_prompt,
        request_leverage=leverage,
    )
    has_mobula = market.get("source") == "mobula"
    has_blofin = market.get("source") in {"blofin", "blofin_demo"}
    has_cg_pro = market.get("source") == "coingecko_pro"

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
            "coingecko_pro": "CoinGecko Pro (authenticated, cache-busted)",
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
        "MOBULA DATA IS LIVE — liquidity, on-chain vs CEX volume delta, and pool depth MUST shape bias, "
        "Volume-Weighted Analysis, conviction %, and your trade card. Lead with on-chain/liquidity read. "
        "Cite the source once in the report: \"LIVE from Mobula\"."
        if has_mobula
        else (
            "COINGECKO PRO IS LIVE — fast CEX reference; fuse CEX volume + Binance derivatives for conviction. "
            "Cite the source once in the report: \"LIVE from CoinGecko Pro\"."
            if has_cg_pro
            else (
                "BLOFIN MARK PRICE IS LIVE — Citadel-linked tick; anchor Entry/TP/SL for execution parity. "
                "Cite the source once in the report: \"LIVE from BloFin\"."
                if has_blofin
                else (
                    "No Mobula tick — do not fabricate on-chain stats; lean on CEX volume + derivatives + structure. "
                    f"Cite the price source once in the report: \"LIVE from {price_source}\"."
                )
            )
        )
    )
    stop_move_pct = 1.0 / prompt_leverage
    leverage_disclosure = (
        f"Citadel leverage setting ({prompt_leverage:.0f}x)"
        if leverage_is_user_set
        else f"assumed {prompt_leverage:.0f}x default"
    )
    leverage_line = (
        f"ACTIVE LEVERAGE FOR THIS SETUP: {prompt_leverage:.0f}x"
        + (" (Citadel configured — use this EXACT leverage)" if leverage_is_user_set else " (default)")
        + f"\nAt {prompt_leverage:.0f}x: 1% account risk = ~{stop_move_pct:.2f}% price move on the stop. "
        f"EXPLICITLY state stop distance %, the account risk it represents at {prompt_leverage:.0f}x, and the R:R "
        f"(e.g. \"SL {stop_move_pct:.2f}% below entry = 1% account risk at {prompt_leverage:.0f}x\"). "
        f"Never park the SL inside the liquidation cascade zone at {prompt_leverage:.0f}x — invalidation beyond the sweep/OB. "
        "Be conservative and professional — leverage amplifies, it does not forgive. "
        f"Include the disclosure line \"Leverage basis: {leverage_disclosure}\" with the TRADE LEVELS block."
    )
    mode_close = (
        "TRADE SETUP MODE: One shot. **TRADE LEVELS** required unless flat — then execution card explains "
        "what unlocks the trade. **If I Were to Trade Today...** = execution card (Trigger/Entry/Invalidation/...)."
        if mode == "tradesetup"
        else "ANALYSIS MODE: Verdict-first. **TRADE LEVELS** only if edge ≥ "
        f"{MIN_RR_TP1:.1f}:1 — else omit and use **If I Were to Trade Today...** for stand-down + unlock conditions."
    )

    vision_block = ""
    if vision_confluence_pct is not None:
        vision_block = f"""
═══ ORACLE VISION PULSE — DATA-BACKED CONFLUENCE (re-score before shipping levels) ═══
Vision read: {vision_confluence_pct:.0f}% {direction} confluence on {timeframe}.
HTF FIRST (mandatory): Establish Daily + 4H bias BEFORE grading this pulse. A {timeframe} signal that
fights Daily/4H structure is counter-trend — grade it like one, never rubber-stamp it.
TREND FILTER:
• Clear bearish HTF (price below Daily VWAP, lower highs/lower lows, heavy sell volume) → heavily
  reduce LONG conviction; favor the short side or call "No Trade / Caution" outright.
• MACRO CAP: Daily strongly bearish → LONG conviction capped at 45% MAX unless very strong liquidity
  reversal evidence (sweep + reclaim of previous lows, aggressive bid absorption, funding reset/flip).
• A market dump is not a discount rack — do NOT print high-conviction longs across the board.
• Squeeze heat / long-liq clusters are context, not a trade — weigh them against the HTF trend.
• 70%+ conviction is reserved for setups aligned with the Daily + 4H trend.
WEIGHTING: Re-grade conviction using Mobula liquidity + on-chain/CEX volume delta + Binance derivatives.
• Thin liquidity vs volume → haircut conviction 5–15%. Volume delta confirms direction → add 5–10%.
• Funding/OI/L-S fights Vision bias → call the veto explicitly; do not rubber-stamp the pulse.
• Trade levels must be sharp at {prompt_leverage:.0f}x: tight invalidation beyond sweep/OB, TP1 ≥ {MIN_RR_TP1:.1f}:1 R:R.
Align Entry/SL/TP1/TP2 with Vision unless Daily VWAP + structure (or the HTF trend filter) veto — name the veto.
"""

    return f"""Generate a premium, high-conviction On-Chain Oracle AI report — sharp leverage trader on stream.
{mode_label}. Decisive. Zero hedging. {mobula_priority}

TONE EXEMPLAR (match cadence — technical but conversational):
"BTC 1D reclaiming Daily VWAP with strong bid absorption + funding flipping positive. Clear liquidity sweep
below previous lows — strong LONG bias here."
{scalp_banner}
{vision_block}{flux_block}
═══════════════════════════════════════════════════════════
AUTHORITATIVE LIVE PRICE — RULE 0 (ZERO TOLERANCE)
═══════════════════════════════════════════════════════════
{live_price_banner}
CURRENT LIVE PRICE: {price_str} (raw: {price_raw} USD)
24h CHANGE: {change_pct:+.2f}%
SOURCE: {market.get('source', 'unknown')}
{freshness_line}{leverage_line}
MANDATORY:
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
{mobula_block}{coingecko_block}{market_fallback_note}{derivatives_block}
Cross-check: Mobula liquidity + volume delta ↔ CoinGecko CEX vol ↔ funding/OI/L-S/liqs ↔ Daily VWAP/structure
on {timeframe} ↔ Oracle Flux dual-layer (overlay: Score, Money Flow, Engines, Chop, STRONG flags, Fib/VWAP
confluence ↔ oscillator: Flux Wave, diamonds, divergence, OB/OS, pinch/rollover — layers must agree or name the conflict).
Flux block above (live or inferred) must shape Oracle Flux Analysis, conviction %, and trade trigger.
Weave Mobula liquidity and derivatives into **Volume-Weighted Analysis** and **Market Structure** — never
as a separate Liquidity & Sentiment heading.
Oracle Vision / Desk conviction must be data-backed — no generic % without citing liquidity or positioning.

═══ ANALYTICAL DEPTH CHECKLIST (Key Drivers — tight stream-trader prose) ═══
• Oracle Flux first — read BOTH layers: overlay WHERE (Score, Conviction, Money Flow, Engines,
  STRONG BUY/SELL, Chop Strength, 0.786/0.618 Fib rejections, EMA stack, VWAP confluence) then oscillator
  WHEN (Flux Wave zero/OB-OS cross, diamonds, pinch/rollover, regular/hidden divergence) — live values or
  inferred read. State whether the layers CONFIRM each other or CONFLICT; a level without timing is
  trigger-pending, an oscillator extreme against trend is exhaustion, not auto-reversal.
• MTF: Weekly/Daily/4h → {timeframe} → LTF trigger. ALIGNED or CONFLICTED — name HTF veto if present.
• TREND LAW: never fight the Daily/4H blindly — counter-trend demands printed reversal evidence
  (sweep + reclaim, displacement, funding flip) or the call is trade-with-trend / stand down.
• Daily VWAP + Previous Day VWAP: reclaiming, rejecting, sweeping, premium/discount vs live price.
• Structure: order blocks, FVGs, BOS/CHOCH, inducement, mitigation, displacement, previous highs/lows,
  fakeouts, liquidity sweeps, liquidity grabs.
• Derivatives woven into story — funding flip, OI build, crowded side, liq cascade fuel (never metric dump).
• Liquidation clusters + book pressure: where stops are stacked, where the cascade accelerates, which side
  of the book is thin — clusters are targets AND invalidation guides.
• DEX vs CEX volume delta (when Mobula present): who leads the move — spot on-chain or perp CEX flow.
• BTC/ETH lead for alts when relevant — not macro jargon.
• Psychology: chase/FOMO/revenge only when price invites the mistake.
• BANNED words: session VWAP, previous session, tape, regime, fade, macro tape, weighted momentum,
  Oracle flow, balanced session, institutional, order flow footprint. USE: Daily VWAP, Previous Day VWAP,
  liquidity sweep, previous highs/lows, fakeout, reclaiming, sweeping, inducement, mitigation.

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
- bullets vs original call and levels

Score: X/10

Then disclaimer."""


# ---------------------------------------------------------------------------
# Daily Analysis — scheduled batch (7:30 AM CST/CDT) + GET /daily_analyses
# ---------------------------------------------------------------------------


def _chicago_day_key(dt: Optional[datetime] = None) -> str:
    local = dt or datetime.now(ZoneInfo(DAILY_ANALYSIS_TZ))
    return local.strftime("%Y-%m-%d")


def _load_daily_analysis_store() -> dict[str, Any]:
    if not _DAILY_ANALYSIS_FILE.is_file():
        return {}
    try:
        raw = json.loads(_DAILY_ANALYSIS_FILE.read_text(encoding="utf-8"))
        return raw if isinstance(raw, dict) else {}
    except Exception as exc:
        logger.error("daily_analysis_read_failed path=%s err=%s", _DAILY_ANALYSIS_FILE, exc)
        return {}


def _persist_daily_analysis_batch(day: str, entries: list[dict[str, Any]]) -> None:
    """Replace on-disk store with today's batch only (prior days are dropped)."""
    payload = {
        "day": day,
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "analyses": entries,
    }
    _CITADEL_DATA_DIR.mkdir(parents=True, exist_ok=True)
    tmp = _DAILY_ANALYSIS_FILE.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(payload, indent=2), encoding="utf-8")
    tmp.replace(_DAILY_ANALYSIS_FILE)


def _init_daily_scheduler_state() -> None:
    global _last_daily_run_day
    store = _load_daily_analysis_store()
    day = store.get("day")
    if isinstance(day, str) and day:
        _last_daily_run_day = day


async def _generate_daily_analysis_entry(coin: str, day: str) -> dict[str, Any]:
    """Build one daily analysis row using the same Grok pipeline as POST /analyze."""
    normalized = coin.strip().upper()
    mode = "analysis"
    direction = normalize_direction("Smart Direction")
    timeframe = "1D"
    market = fetch_live_price_for_analysis(normalized)
    derivatives = fetch_derivatives_snapshot(normalized, spot_price=float(market["price"]))
    system_prompt = default_system_prompt(mode, scalp_mode=False)
    user_prompt = build_analyze_user_prompt(
        coin=normalized,
        timeframe=timeframe,
        mode=mode,
        direction=direction,
        market=market,
        scalp_mode=False,
        derivatives=derivatives,
    )
    try:
        report = await run_grok_in_executor(
            system_prompt=system_prompt,
            user_prompt=user_prompt,
            temperature=0.36,
            max_tokens=1520,
        )
    except asyncio.TimeoutError:
        reason = f"daily analysis exceeded {ANALYZE_ROUTE_TIMEOUT}s"
        logger.error("daily_analysis_grok_timeout coin=%s %s", normalized, reason)
        report = build_analyze_fallback_report(
            coin=normalized, mode=mode, market=market, reason=reason
        )
    except GrokError as exc:
        logger.error(
            "daily_analysis_grok_failed coin=%s msg=%s http=%s",
            normalized,
            exc.user_message,
            exc.status_code,
        )
        report = build_analyze_fallback_report(
            coin=normalized, mode=mode, market=market, reason=exc.user_message
        )
    report = ensure_disclaimer(report)
    local_now = datetime.now(ZoneInfo(DAILY_ANALYSIS_TZ))
    return {
        "id": f"{day}_{normalized}",
        "coin": normalized,
        "report": report,
        "bias": "",
        "current_price": market["price"],
        "price_source": market.get("source"),
        "analysisDay": day,
        "source": "analysis",
        "time": f"{local_now.month}/{local_now.day} {local_now.hour}:{local_now.minute:02d}",
    }


async def _run_daily_analysis_batch(*, reason: str = "scheduled") -> None:
    global _last_daily_run_day
    day = _chicago_day_key()
    logger.info("daily_analysis_batch_start day=%s reason=%s coins=%s", day, reason, DAILY_ANALYSIS_COINS)
    entries: list[dict[str, Any]] = []
    for coin in DAILY_ANALYSIS_COINS:
        try:
            entries.append(await _generate_daily_analysis_entry(coin, day))
            logger.info("daily_analysis_coin_done coin=%s day=%s", coin, day)
        except Exception as exc:
            logger.exception("daily_analysis_coin_failed coin=%s day=%s err=%s", coin, day, exc)
    if entries:
        _persist_daily_analysis_batch(day, entries)
        _last_daily_run_day = day
        logger.info("daily_analysis_batch_saved day=%s count=%s", day, len(entries))
        _schedule_x_daily_post_after_batch(day, entries)
    else:
        logger.error("daily_analysis_batch_empty day=%s reason=%s", day, reason)


async def _maybe_catchup_daily_analyses() -> None:
    """If server starts after 7:30 AM Chicago and today's batch is missing, generate it."""
    if not DAILY_ANALYSIS_ENABLED or not GROK_API_KEY:
        return
    day = _chicago_day_key()
    store = _load_daily_analysis_store()
    existing = store.get("analyses") if store.get("day") == day else []
    if isinstance(existing, list) and len(existing) >= len(DAILY_ANALYSIS_COINS):
        return
    now = datetime.now(ZoneInfo(DAILY_ANALYSIS_TZ))
    if now.hour < DAILY_ANALYSIS_HOUR or (
        now.hour == DAILY_ANALYSIS_HOUR and now.minute < DAILY_ANALYSIS_MINUTE
    ):
        return
    await _run_daily_analysis_batch(reason="startup_catchup")


async def _daily_analysis_scheduler_loop() -> None:
    global _last_daily_run_day
    while True:
        try:
            if DAILY_ANALYSIS_ENABLED and GROK_API_KEY:
                now = datetime.now(ZoneInfo(DAILY_ANALYSIS_TZ))
                day = now.strftime("%Y-%m-%d")
                if (
                    now.hour == DAILY_ANALYSIS_HOUR
                    and now.minute == DAILY_ANALYSIS_MINUTE
                    and _last_daily_run_day != day
                ):
                    await _run_daily_analysis_batch(reason="scheduler")
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            logger.exception("daily_analysis_scheduler err=%s", exc)
        await asyncio.sleep(30)


# ---------------------------------------------------------------------------
# X (Twitter) — daily analysis thread (separate from in-app push / GET /daily_analyses)
# ---------------------------------------------------------------------------


async def _run_x_daily_post(day: str, entries: Optional[list[dict[str, Any]]] = None) -> dict[str, Any]:
    """Post today's analyses to X. Idempotent per day (see data/x_daily_posts.json)."""
    if not X_DAILY_POST_ENABLED:
        return {"skipped": True, "reason": "disabled"}
    try:
        if entries is not None:
            result = await asyncio.to_thread(
                post_daily_analyses_to_x,
                day,
                entries,
                parse_trade_levels=parse_trade_levels,
                format_usd=format_usd,
                config=_X_DAILY_CONFIG,
            )
        else:
            result = await asyncio.to_thread(
                post_today_from_store,
                load_store=_load_daily_analysis_store,
                day_key=day,
                parse_trade_levels=parse_trade_levels,
                format_usd=format_usd,
                config=_X_DAILY_CONFIG,
            )
        logger.info("x_daily_post_done day=%s result=%s", day, result)
        return result
    except Exception as exc:
        logger.exception("x_daily_post_failed day=%s err=%s", day, exc)
        return {"success": False, "day": day, "error": str(exc)}


def _schedule_x_daily_post_after_batch(day: str, entries: list[dict[str, Any]]) -> None:
    """Fire-and-forget X post when a daily batch is saved (does not block analysis)."""
    if not X_DAILY_POST_ENABLED:
        return
    asyncio.create_task(_run_x_daily_post(day, entries))


async def _x_daily_post_scheduler_loop() -> None:
    """
    Backup scheduler at the same Chicago time as daily analysis.
    Waits X_DAILY_POST_DELAY_SECONDS so Grok batch can finish, then posts from disk.
    """
    posted_days: set[str] = set()
    while True:
        try:
            if X_DAILY_POST_ENABLED:
                now = datetime.now(ZoneInfo(DAILY_ANALYSIS_TZ))
                day = _chicago_day_key(now)
                slot_key = f"{day}:{now.hour}:{now.minute}"
                if (
                    now.hour == DAILY_ANALYSIS_HOUR
                    and now.minute == DAILY_ANALYSIS_MINUTE
                    and slot_key not in posted_days
                ):
                    posted_days.add(slot_key)
                    await asyncio.sleep(max(0, X_DAILY_POST_DELAY_SECONDS))
                    await _run_x_daily_post(day)
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            logger.exception("x_daily_post_scheduler err=%s", exc)
        await asyncio.sleep(30)


def _verify_cron_secret(request: Request) -> None:
    if not X_CRON_SECRET:
        raise HTTPException(status_code=503, detail="X_CRON_SECRET not configured.")
    provided = (request.headers.get("X-Cron-Secret") or "").strip()
    if not provided or not hmac.compare_digest(provided, X_CRON_SECRET):
        raise HTTPException(status_code=403, detail="Invalid cron secret.")


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

    logger.info(
        "startup | citadel_encryption=%s blofin_passphrase_demo=%s blofin_passphrase_live=%s",
        bool(CITADEL_ENCRYPTION_KEY),
        bool(_blofin_env_passphrase(True)),
        bool(_blofin_env_passphrase(False)),
    )

    global _daily_scheduler_task, _x_daily_post_scheduler_task
    _init_daily_scheduler_state()
    if DAILY_ANALYSIS_ENABLED:
        logger.info(
            "startup | daily_analysis enabled tz=%s at=%02d:%02d coins=%s",
            DAILY_ANALYSIS_TZ,
            DAILY_ANALYSIS_HOUR,
            DAILY_ANALYSIS_MINUTE,
            ",".join(DAILY_ANALYSIS_COINS),
        )
        _daily_scheduler_task = asyncio.create_task(_daily_analysis_scheduler_loop())
        asyncio.create_task(_maybe_catchup_daily_analyses())
    else:
        logger.info("startup | daily_analysis disabled (DAILY_ANALYSIS_ENABLED=false)")

    if X_DAILY_POST_ENABLED:
        logger.info(
            "startup | x_daily_post enabled coins=%s handle=%s oauth=%s delay=%ss",
            ",".join(_X_DAILY_CONFIG.post_coins),
            _X_DAILY_CONFIG.handle,
            _X_DAILY_CONFIG.oauth_ready(),
            X_DAILY_POST_DELAY_SECONDS,
        )
        if not _X_DAILY_CONFIG.oauth_ready():
            logger.warning(
                "startup | x_daily_post missing OAuth credentials: %s",
                ", ".join(_X_DAILY_CONFIG.missing_fields()),
            )
        _x_daily_post_scheduler_task = asyncio.create_task(_x_daily_post_scheduler_loop())
    else:
        logger.info("startup | x_daily_post disabled (X_DAILY_POST_ENABLED=false)")

    yield

    if _daily_scheduler_task is not None:
        _daily_scheduler_task.cancel()
        try:
            await _daily_scheduler_task
        except asyncio.CancelledError:
            pass
    if _x_daily_post_scheduler_task is not None:
        _x_daily_post_scheduler_task.cancel()
        try:
            await _x_daily_post_scheduler_task
        except asyncio.CancelledError:
            pass
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


# ---------------------------------------------------------------------------
# Klines proxy — Trade Setup chart (Lightweight Charts in Flutter WebView)
# Binance is geo-blocked client-side in some regions; the server proxies OHLCV.
# ---------------------------------------------------------------------------

_KLINES_VALID_INTERVALS = {
    "1m", "3m", "5m", "15m", "30m", "1h", "2h", "4h", "6h", "8h", "12h", "1d", "3d", "1w",
}
_KLINES_INTERVAL_ALIASES = {"10m": "15m", "20m": "30m", "1D": "1d", "60": "1h", "240": "4h"}
_KLINES_CACHE: dict[str, tuple[float, list[list[float]]]] = {}
_KLINES_CACHE_TTL = 30.0
_KLINES_CACHE_LOCK = threading.Lock()


def fetch_binance_klines(symbol: str, interval: str, limit: int) -> Optional[list[list[float]]]:
    """OHLCV from Binance spot, futures fallback. Rows: [openTimeSec, o, h, l, c, vol]."""
    params = {"symbol": symbol, "interval": interval, "limit": limit}
    for url in (
        "https://api.binance.com/api/v3/klines",
        "https://fapi.binance.com/fapi/v1/klines",
    ):
        try:
            response = requests.get(url, params=params, timeout=REQUEST_TIMEOUT)
            if response.status_code != 200:
                continue
            raw = response.json()
            if not isinstance(raw, list) or not raw:
                continue
            return [
                [
                    float(row[0]) / 1000.0,
                    float(row[1]),
                    float(row[2]),
                    float(row[3]),
                    float(row[4]),
                    float(row[5]),
                ]
                for row in raw
            ]
        except Exception as exc:
            logger.debug("klines_miss url=%s symbol=%s err=%s", url, symbol, exc)
    return None


@app.get("/klines")
async def get_klines(coin: str, interval: str = "1h", limit: int = 300) -> dict[str, Any]:
    """OHLCV candles for the Trade Setup chart. Cached 30s per coin+interval."""
    upper = (coin or "").strip().upper()
    if not upper:
        raise HTTPException(status_code=400, detail="coin is required.")
    iv = _KLINES_INTERVAL_ALIASES.get(interval.strip(), interval.strip().lower())
    iv = _KLINES_INTERVAL_ALIASES.get(iv, iv)
    if iv not in _KLINES_VALID_INTERVALS:
        iv = "1h"
    n = max(50, min(int(limit), 500))
    cache_key = f"{upper}:{iv}:{n}"

    with _KLINES_CACHE_LOCK:
        cached = _KLINES_CACHE.get(cache_key)
        if cached and (time.time() - cached[0]) < _KLINES_CACHE_TTL:
            return {"success": True, "coin": upper, "interval": iv, "klines": cached[1], "cached": True}

    rows = await asyncio.to_thread(fetch_binance_klines, binance_usdt_symbol(upper), iv, n)
    if not rows:
        raise HTTPException(status_code=502, detail=f"Unable to fetch klines for {upper}.")

    with _KLINES_CACHE_LOCK:
        _KLINES_CACHE[cache_key] = (time.time(), rows)
        if len(_KLINES_CACHE) > 200:
            oldest = min(_KLINES_CACHE.items(), key=lambda kv: kv[1][0])[0]
            _KLINES_CACHE.pop(oldest, None)

    return {"success": True, "coin": upper, "interval": iv, "klines": rows, "cached": False}


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
        user_id = resolve_analyze_user_id(request, http_request)
        market = fetch_live_price_for_analysis(coin, user_id=user_id)

        scalp_mode = is_scalp_context(
            timeframe=request.timeframe,
            direction=request.direction,
            mode=mode,
            system_prompt=request.system_prompt or "",
        )

        derivatives = fetch_derivatives_snapshot(coin, spot_price=float(market["price"]))
        oracle_flux = extract_oracle_flux_from_request(request)

        # User's chosen leverage: request value → client prompt → Citadel record → 5x default.
        effective_leverage, leverage_is_user_set = resolve_prompt_leverage(
            user_id=user_id,
            system_prompt=request.system_prompt,
            request_leverage=request.leverage,
        )

        system_prompt = default_system_prompt(
            mode,
            scalp_mode=scalp_mode,
            leverage=effective_leverage,
            citadel_leverage=leverage_is_user_set,
        )
        user_prompt = build_analyze_user_prompt(
            coin=coin,
            timeframe=request.timeframe,
            mode=mode,
            direction=direction,
            market=market,
            scalp_mode=scalp_mode,
            derivatives=derivatives,
            vision_confluence_pct=request.vision_confluence_pct,
            oracle_flux=oracle_flux,
            user_id=user_id,
            system_prompt=request.system_prompt,
            leverage=effective_leverage,
        )

        logger.info(
            "analyze request_id=%s coin=%s mode=%s tf=%s dir=%s scalp=%s leverage=%sx price=%.6f src=%s "
            "mobula_liq=%s on_chain_vol=%s deriv=%s flux=%s",
            req_id,
            coin,
            mode,
            request.timeframe,
            direction,
            scalp_mode,
            f"{effective_leverage:.0f}",
            market["price"],
            market.get("source"),
            market.get("liquidity_usd") if market.get("source") == "mobula" else None,
            market.get("on_chain_volume_usd") if market.get("source") == "mobula" else None,
            derivatives["has_futures_data"],
            oracle_flux.oracle_score if oracle_flux else None,
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


@app.post("/internal/cron/post_daily_x")
@app.post("/internal/cron/post_daily_x/")
async def cron_post_daily_x(http_request: Request) -> dict[str, Any]:
    """
    Optional Railway cron trigger — posts today's persisted daily analyses to X.
    Header: X-Cron-Secret: <X_CRON_SECRET>
    """
    _verify_cron_secret(http_request)
    day = _chicago_day_key()
    result = await _run_x_daily_post(day)
    return {"success": result.get("success", result.get("skipped", False)), "day": day, "result": result}


@app.get("/daily_analyses")
@app.get("/daily_analyses/")
@app.get("/api/daily_analyses")
async def get_daily_analyses() -> dict[str, Any]:
    """Today's scheduled daily analyses for Home (BTC, ETH, SOL, XRP)."""
    day = _chicago_day_key()
    store = _load_daily_analysis_store()
    analyses: list[Any] = []
    if store.get("day") == day:
        raw = store.get("analyses")
        if isinstance(raw, list):
            analyses = raw
    return {
        "success": True,
        "day": day,
        "analyses": analyses,
        "count": len(analyses),
        "coins": list(DAILY_ANALYSIS_COINS),
        "timezone": DAILY_ANALYSIS_TZ,
        "scheduled_at": f"{DAILY_ANALYSIS_HOUR:02d}:{DAILY_ANALYSIS_MINUTE:02d}",
    }


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
    if previous_report.lower() in {"loading...", "loading", "no report", "no report."}:
        raise HTTPException(
            status_code=400,
            detail="previous_report is a placeholder — regenerate the original analysis first.",
        )

    # Same price chain as /analyze — Binance-only snapshot fails on Railway (WAF/geo).
    market = fetch_live_price_for_analysis(coin)
    req_id = getattr(http_request.state, "request_id", "?")
    logger.info(
        "review request_id=%s coin=%s price=%.6f src=%s",
        req_id,
        coin,
        market["price"],
        market.get("source"),
    )

    try:
        review_text = await run_grok_in_executor(
            system_prompt=build_review_system_prompt(),
            user_prompt=build_review_user_prompt(coin, previous_report, market),
            temperature=0.50,
            max_tokens=1150,
        )
    except asyncio.TimeoutError:
        logger.error("review_grok_timeout request_id=%s coin=%s", req_id, coin)
        return JSONResponse(
            status_code=502,
            content={
                "success": False,
                "detail": f"Review timed out after {ANALYZE_ROUTE_TIMEOUT}s. Try again.",
                "coin": coin,
                "request_id": req_id,
                "error": "grok_timeout",
            },
            headers={"X-Request-ID": req_id},
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
        "exchange_keys_body_keys request_id=%s keys=%s risk_percent=%s exchange=%s demo=%s has_passphrase=%s",
        req_id,
        body_keys,
        raw_body.get("risk_percent"),
        raw_body.get("exchange"),
        raw_body.get("use_demo_mode", raw_body.get("demo_mode")),
        bool((raw_body.get("exchange_passphrase") or raw_body.get("passphrase") or "").strip()),
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
        exchange_hint = (request.exchange or "").strip().lower()
        if "bitunix" in exchange_hint:
            user_msg = "Bitunix supports live trading only. Turn off Demo Mode in Citadel Setup."
        else:
            user_msg = "Demo mode is for BloFin only. Turn off Demo or set exchange to blofin."
        return JSONResponse(
            status_code=400,
            content={
                "success": False,
                "detail": "Demo/Testnet mode is only supported for BloFin.",
                "user_message": user_msg,
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

    exchange_name = (request.exchange or "blofin").strip().lower()
    is_bitunix = "bitunix" in exchange_name
    is_blofin = ("blofin" in exchange_name or not request.exchange) and not is_bitunix
    prior_record = get_citadel_user_record(user_id) or {}
    passphrase_input = (request.exchange_passphrase or "").strip()
    effective_passphrase = passphrase_input or _resolve_blofin_passphrase(
        prior_record,
        use_demo=request.use_demo_mode,
    )

    if is_blofin and not effective_passphrase:
        return JSONResponse(
            status_code=400,
            content={
                "success": False,
                "detail": "BloFin API passphrase is required for this environment.",
                "user_message": (
                    "Enter your BloFin API Passphrase in Oracle Citadel Setup "
                    "(the passphrase you chose when creating the API key)."
                ),
                "request_id": req_id,
            },
            headers={"X-Request-ID": req_id},
        )

    if is_blofin:
        verify = _blofin_verify_exchange_credentials(
            base_url=profile.get("api_base_url") or BLOFIN_LIVE_API_BASE_URL,
            api_key=exchange_api_key,
            api_secret=exchange_secret,
            passphrase=effective_passphrase,
            request_id=req_id,
        )
        if not verify.get("ok"):
            friendly = _blofin_user_friendly_error(verify.get("code"), verify.get("msg"))
            logger.warning(
                "exchange_keys_blofin_verify_failed request_id=%s user_id=%s demo=%s "
                "http=%s code=%s msg=%s",
                req_id,
                user_id,
                request.use_demo_mode,
                verify.get("http_status"),
                verify.get("code"),
                verify.get("msg"),
            )
            fail_body: dict[str, Any] = {
                "success": False,
                "detail": verify.get("msg") or "BloFin rejected these API credentials.",
                "user_message": friendly,
                "blofin_code": verify.get("code"),
                "request_id": req_id,
            }
            if _blofin_is_ip_whitelist_error(verify.get("code"), verify.get("msg")):
                egress_ip = _citadel_egress_ip_for_whitelist()
                if egress_ip:
                    fail_body["whitelist_ip"] = egress_ip
            return JSONResponse(
                status_code=400,
                content=fail_body,
                headers={"X-Request-ID": req_id},
            )

    if is_bitunix:
        verify = await asyncio.to_thread(
            bux.verify_credentials,
            api_key=exchange_api_key,
            api_secret=exchange_secret,
            request_id=req_id,
        )
        if not verify.get("ok"):
            friendly = bux.user_friendly_error(verify.get("code"), verify.get("msg"))
            logger.warning(
                "exchange_keys_bitunix_verify_failed request_id=%s user_id=%s http=%s code=%s msg=%s "
                "— saving keys anyway; execute_trade will re-validate",
                req_id,
                user_id,
                verify.get("http_status"),
                verify.get("code"),
                verify.get("msg"),
            )
            # Do not block save — Bitunix account probe can fail from WAF/IP while trade keys are valid.
        else:
            logger.info(
                "exchange_keys_bitunix_verify_ok request_id=%s user_id=%s",
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
            use_demo_mode=False if is_bitunix else request.use_demo_mode,
            exchange_passphrase=passphrase_input or None,
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
                "user_message": "Exchange keys not found on server. Re-link keys in Oracle Citadel Setup.",
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


@app.post("/app_api_key/register")
@app.post("/app_api_key/register/")
@app.post("/api/app_api_key/register")
@app.post("/api/app_api_key/register/")
async def app_api_key_register(
    request: AppApiKeyRegisterRequest,
    http_request: Request,
) -> dict[str, Any]:
    """
    Register the Flutter App API Key (secure storage) for this user_id.
    X-API-Key header may substitute for body app_api_key.
    """
    req_id = getattr(http_request.state, "request_id", "?")
    header_app_key = (
        http_request.headers.get("X-API-Key") or http_request.headers.get("x-api-key") or ""
    ).strip()
    user_id = request.user_id.strip()
    app_api_key = (request.app_api_key or header_app_key).strip()

    if not user_id or not app_api_key:
        raise HTTPException(
            status_code=400,
            detail="user_id and app_api_key are required (body or X-API-Key header).",
        )
    if header_app_key and request.app_api_key and header_app_key != request.app_api_key:
        raise HTTPException(
            status_code=403,
            detail="X-API-Key header does not match app_api_key in body.",
        )

    try:
        result = register_app_api_key(user_id, app_api_key)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc

    logger.info("app_api_key_registered request_id=%s user_id=%s", req_id, user_id)
    return {"success": True, "request_id": req_id, **result}


@app.post("/exchange_keys")
@app.post("/exchange_keys/")
@app.post("/api/exchange_keys")
@app.post("/api/exchange_keys/")
async def exchange_keys(http_request: Request) -> JSONResponse:
    return await _handle_exchange_keys(http_request)


async def _execute_bitunix_citadel_trade(
    *,
    req_id: str,
    trade_id: str,
    trade: ExecuteTradeRequest,
    user_id: str,
    exchange_api_key: str,
    exchange_secret: str,
    effective_risk: float,
    requested_risk: float,
    is_market: bool,
    order_type: str,
    environment: str,
) -> JSONResponse:
    """Oracle Citadel MARKET/LIMIT execution on Bitunix (live network)."""
    geometry_err = _validate_citadel_trade_geometry(
        direction=trade.direction,
        entry=trade.entry_price,
        sl=trade.stop_loss,
        tp1=trade.tp1,
        tp2=trade.tp2,
    )
    if geometry_err:
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

    effective_leverage = _normalize_citadel_leverage(trade.leverage)
    remember_citadel_leverage(user_id, effective_leverage)

    lev_result = await asyncio.to_thread(
        bux.set_leverage,
        api_key=exchange_api_key,
        api_secret=exchange_secret,
        coin=trade.coin,
        leverage=effective_leverage,
        request_id=req_id,
    )
    if lev_result.get("ok"):
        logger.info("bitunix_set_leverage_ok request_id=%s leverage=%sx", req_id, effective_leverage)
    else:
        logger.warning(
            "bitunix_set_leverage_failed request_id=%s leverage=%sx code=%s msg=%s",
            req_id,
            effective_leverage,
            lev_result.get("code"),
            lev_result.get("msg"),
        )

    position_mode = await asyncio.to_thread(
        bux.fetch_position_mode,
        api_key=exchange_api_key,
        api_secret=exchange_secret,
        request_id=req_id,
    )
    logger.info(
        "execute_trade_bitunix_position_mode request_id=%s mode=%s",
        req_id,
        position_mode,
    )

    if not is_market:
        limit_entry = float(trade.entry_price)
        order_size, size_meta = await asyncio.to_thread(
            bux.calculate_order_size,
            entry_price=limit_entry,
            stop_loss=trade.stop_loss,
            risk_percent=effective_risk,
            leverage=effective_leverage,
            api_key=exchange_api_key,
            api_secret=exchange_secret,
            request_id=req_id,
        )
        entry_result = await asyncio.to_thread(
            bux.place_order,
            api_key=exchange_api_key,
            api_secret=exchange_secret,
            coin=trade.coin,
            direction=trade.direction,
            order_type="limit",
            qty=order_size,
            price=str(limit_entry),
            sl=trade.stop_loss,
            client_id=trade_id[:32],
            position_mode=position_mode,
            request_id=req_id,
        )
        entry_order_id = entry_result.get("order_id")
        if not entry_result.get("ok") or not entry_order_id:
            friendly = bux.user_friendly_error(entry_result.get("code"), entry_result.get("msg"))
            fail_body: dict[str, Any] = {
                "success": False,
                "status": "failed",
                "order_type": "limit",
                "trade_id": trade_id,
                "detail": entry_result.get("msg") or "Bitunix LIMIT order rejected.",
                "user_message": friendly,
                "bitunix_code": entry_result.get("code"),
                "request_id": req_id,
            }
            _attach_bitunix_whitelist_ip_if_needed(
                fail_body,
                code=entry_result.get("code"),
                msg=entry_result.get("msg"),
                http_status=entry_result.get("http_status"),
            )
            return JSONResponse(
                status_code=502,
                content=fail_body,
                headers={"X-Request-ID": req_id},
            )

        confirm = await asyncio.to_thread(
            bux.confirm_limit_order,
            api_key=exchange_api_key,
            api_secret=exchange_secret,
            order_id=entry_order_id,
            request_id=req_id,
        )
        if not confirm.get("limit_ok"):
            return JSONResponse(
                status_code=502,
                content={
                    "success": False,
                    "status": "failed",
                    "order_type": "limit",
                    "trade_id": trade_id,
                    "order_id": entry_order_id,
                    "detail": "Bitunix accepted the LIMIT order but Citadel could not confirm it.",
                    "user_message": (
                        f"LIMIT order was submitted to Bitunix but could not be confirmed. "
                        f"Check order history on Bitunix. Order ID {entry_order_id}."
                    ),
                    "request_id": req_id,
                },
                headers={"X-Request-ID": req_id},
            )

        limit_status = confirm.get("limit_status") or "resting"
        rr = compute_rr(limit_entry, trade.tp1, trade.stop_loss)
        tp1_size: Optional[str] = None
        tp2_size: Optional[str] = None
        tp1_order_id: Optional[str] = None
        tp2_order_id: Optional[str] = None
        tp_warnings: list[str] = []

        if limit_status == "filled":
            position_size_str = str(confirm.get("filled_size") or order_size)
            tpsl_bundle = await asyncio.to_thread(
                bux.attach_dual_tpsl_after_fill,
                api_key=exchange_api_key,
                api_secret=exchange_secret,
                coin=trade.coin,
                direction=trade.direction,
                position_size_str=position_size_str,
                stop_loss=trade.stop_loss,
                tp1=trade.tp1,
                tp2=trade.tp2,
                include_sl=False,
                request_id=req_id,
            )
            tp1_order_id = tpsl_bundle.get("tp1_tpsl_id")
            tp2_order_id = tpsl_bundle.get("tp2_tpsl_id")
            tp1_size = tpsl_bundle.get("tp1_size")
            tp2_size = tpsl_bundle.get("tp2_size")
            tp_warnings = list(tpsl_bundle.get("warnings") or [])

        fill_entry = _parse_blofin_price_token(confirm.get("average_price")) or limit_entry
        if limit_status == "filled":
            user_message = (
                f"LIMIT order filled on Bitunix ({environment}). "
                f"{trade.coin} {trade.direction.upper()} · Fill {format_usd(fill_entry)} · "
                f"Order ID {entry_order_id}"
            )
            message = f"LIMIT order filled for {trade.coin} {trade.direction.upper()}."
        else:
            user_message = (
                f"Limit order resting on Bitunix ({environment}). "
                f"{trade.coin} {trade.direction.upper()} · Entry {format_usd(limit_entry)} · "
                f"Order ID {entry_order_id}. TP legs apply after fill."
            )
            message = f"LIMIT order placed for {trade.coin} {trade.direction.upper()}."

        return JSONResponse(
            status_code=200,
            content={
                "success": True,
                "status": "success",
                "order_type": "limit",
                "limit_status": limit_status,
                "trade_id": trade_id,
                "order_id": entry_order_id,
                "tp1_tpsl_id": tp1_order_id,
                "tp2_tpsl_id": tp2_order_id,
                "tp1_size": tp1_size,
                "tp2_size": tp2_size,
                "tp_warnings": tp_warnings,
                "user_id": user_id,
                "coin": trade.coin,
                "direction": trade.direction,
                "entry_price": limit_entry,
                "fill_entry_price": fill_entry if limit_status == "filled" else None,
                "stop_loss": trade.stop_loss,
                "tp1": trade.tp1,
                "tp2": trade.tp2,
                "risk_percent": effective_risk,
                "risk_percent_requested": requested_risk,
                "order_size": order_size,
                "leverage": effective_leverage,
                "rr": rr,
                "exchange": "bitunix",
                "environment": environment,
                "api_base_url": bux.BITUNIX_LIVE_API_BASE_URL,
                "message": message,
                "user_message": user_message,
                "bitunix_confirm": {
                    "status": confirm.get("status"),
                    "filled_size": confirm.get("filled_size"),
                    "average_price": confirm.get("average_price"),
                },
                "request_id": req_id,
            },
            headers={"X-Request-ID": req_id},
        )

    try:
        live = fetch_live_price_for_analysis(trade.coin)
        reference_price = float(live["price"])
    except Exception as exc:
        logger.warning(
            "execute_trade_bitunix_price_fallback request_id=%s coin=%s err=%s entry=%s",
            req_id,
            trade.coin,
            exc,
            trade.entry_price,
        )
        reference_price = float(trade.entry_price)

    order_size, size_meta = await asyncio.to_thread(
        bux.calculate_order_size,
        entry_price=reference_price,
        stop_loss=trade.stop_loss,
        risk_percent=effective_risk,
        leverage=effective_leverage,
        api_key=exchange_api_key,
        api_secret=exchange_secret,
        request_id=req_id,
    )

    market_result = await asyncio.to_thread(
        bux.place_order,
        api_key=exchange_api_key,
        api_secret=exchange_secret,
        coin=trade.coin,
        direction=trade.direction,
        order_type="market",
        qty=order_size,
        sl=None,
        client_id=trade_id[:32],
        position_mode=position_mode,
        request_id=req_id,
    )
    market_order_id = market_result.get("order_id")
    if not market_result.get("ok") or not market_order_id:
        friendly = bux.user_friendly_error(market_result.get("code"), market_result.get("msg"))
        fail_body = {
            "success": False,
            "status": "failed",
            "order_type": "market",
            "trade_id": trade_id,
            "detail": market_result.get("msg") or "Bitunix MARKET order rejected.",
            "user_message": friendly,
            "bitunix_code": market_result.get("code"),
            "request_id": req_id,
        }
        _attach_bitunix_whitelist_ip_if_needed(
            fail_body,
            code=market_result.get("code"),
            msg=market_result.get("msg"),
            http_status=market_result.get("http_status"),
        )
        return JSONResponse(
            status_code=502,
            content=fail_body,
            headers={"X-Request-ID": req_id},
        )

    confirm = await asyncio.to_thread(
        bux.confirm_order_fill,
        api_key=exchange_api_key,
        api_secret=exchange_secret,
        order_id=market_order_id,
        request_id=req_id,
    )
    if not confirm.get("ok"):
        return JSONResponse(
            status_code=502,
            content={
                "success": False,
                "status": "failed",
                "order_type": "market",
                "trade_id": trade_id,
                "order_id": market_order_id,
                "detail": "Bitunix accepted the MARKET order but no fill was confirmed.",
                "user_message": (
                    "MARKET order was submitted to Bitunix but did not fill — no position opened. "
                    f"Check margin and minimum size. Order ID {market_order_id}."
                ),
                "bitunix_confirm": confirm,
                "request_id": req_id,
            },
            headers={"X-Request-ID": req_id},
        )

    position_size_str = str(confirm.get("filled_size") or order_size)
    tpsl_bundle = await asyncio.to_thread(
        bux.attach_dual_tpsl_after_fill,
        api_key=exchange_api_key,
        api_secret=exchange_secret,
        coin=trade.coin,
        direction=trade.direction,
        position_size_str=position_size_str,
        stop_loss=trade.stop_loss,
        tp1=trade.tp1,
        tp2=trade.tp2,
        include_sl=True,
        request_id=req_id,
    )
    tp1_order_id = tpsl_bundle.get("tp1_tpsl_id")
    tp2_order_id = tpsl_bundle.get("tp2_tpsl_id")
    sl_tpsl_id = tpsl_bundle.get("sl_tpsl_id")
    tp1_size = tpsl_bundle.get("tp1_size")
    tp2_size = tpsl_bundle.get("tp2_size")
    tp_warnings: list[str] = list(tpsl_bundle.get("warnings") or [])

    fill_row = confirm.get("row") if isinstance(confirm.get("row"), dict) else {}
    fill_entry = _parse_blofin_price_token(fill_row.get("avgPrice")) or reference_price
    rr = compute_rr(fill_entry, trade.tp1, trade.stop_loss)
    user_message = (
        f"MARKET order filled on Bitunix ({environment}). "
        f"{trade.coin} {trade.direction.upper()} · Fill {format_usd(fill_entry)} · "
        f"Order ID {market_order_id}"
    )
    if not tp_warnings:
        user_message += (
            f" · SL {format_usd(trade.stop_loss)} · TP1 {format_usd(trade.tp1)} · TP2 {format_usd(trade.tp2)}"
        )

    return JSONResponse(
        status_code=200,
        content={
            "success": True,
            "status": "success",
            "order_type": "market",
            "trade_id": trade_id,
            "order_id": market_order_id,
            "sl_tpsl_id": sl_tpsl_id,
            "tp1_tpsl_id": tp1_order_id,
            "tp2_tpsl_id": tp2_order_id,
            "tp1_size": tp1_size,
            "tp2_size": tp2_size,
            "tp_warnings": tp_warnings,
            "user_id": user_id,
            "coin": trade.coin,
            "direction": trade.direction,
            "entry_price": reference_price,
            "fill_entry_price": fill_entry,
            "stop_loss": trade.stop_loss,
            "tp1": trade.tp1,
            "tp2": trade.tp2,
            "risk_percent": effective_risk,
            "risk_percent_requested": requested_risk,
            "order_size": order_size,
            "leverage": effective_leverage,
            "rr": rr,
            "exchange": "bitunix",
            "environment": environment,
            "api_base_url": bux.BITUNIX_LIVE_API_BASE_URL,
            "message": f"MARKET order filled for {trade.coin} {trade.direction.upper()}.",
            "user_message": user_message,
            "bitunix_confirm": {
                "status": confirm.get("status"),
                "filled_size": confirm.get("filled_size"),
            },
            "request_id": req_id,
        },
        headers={"X-Request-ID": req_id},
    )


async def _handle_execute_trade(http_request: Request) -> JSONResponse:
    """
    POST /execute_trade — Oracle Citadel MARKET or LIMIT execution (BloFin).

    Accepts JSON:
      user_id, coin, direction, entry_price, stop_loss, tp1, tp2, risk_percent,
      order_type=market|limit, leverage
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
                "user_message": "Exchange keys not found on server. Re-link keys in Oracle Citadel Setup (Save with API Key + Secret).",
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

    is_market = _is_market_trade_request(trade, raw_body)
    order_type = "market" if is_market else "limit"
    effective_risk, requested_risk = _resolve_effective_risk_percent(trade.risk_percent)
    exchange_profile = _resolve_execute_trade_exchange_profile(
        record,
        raw_body,
        user_id=user_id,
        req_id=req_id,
    )
    exchange = exchange_profile.get("exchange") or record.get("exchange") or "blofin"
    environment = exchange_profile.get("environment") or "live"
    api_base_url = exchange_profile.get("api_base_url") or BLOFIN_LIVE_API_BASE_URL
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

    if "bitunix" in str(exchange).lower():
        return await _execute_bitunix_citadel_trade(
            req_id=req_id,
            trade_id=trade_id,
            trade=trade,
            user_id=user_id,
            exchange_api_key=exchange_api_key,
            exchange_secret=exchange_secret,
            effective_risk=effective_risk,
            requested_risk=requested_risk,
            is_market=is_market,
            order_type=order_type,
            environment=environment,
        )

    if "blofin" not in str(exchange).lower():
        logger.warning(
            "execute_trade_unsupported_exchange request_id=%s exchange=%s",
            req_id,
            exchange,
        )
        return JSONResponse(
            status_code=400,
            content={
                "success": False,
                "detail": f"Oracle Citadel does not support exchange={exchange}.",
                "user_message": "Link BloFin or Bitunix keys in Oracle Citadel Setup to execute trades.",
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

    passphrase = _resolve_blofin_passphrase(
        record,
        use_demo=bool(exchange_profile.get("use_demo_mode")),
    )
    if not passphrase:
        env_hint = (
            "Set BLOFIN_PASSPHRASE on Railway for demo, or BLOFIN_PASSPHRASE_LIVE / "
            "Blofin_Passpharse_live for live — or enter passphrase in Citadel Setup."
        )
        logger.error(
            "execute_trade_blofin_passphrase_missing request_id=%s user_id=%s environment=%s",
            req_id,
            user_id,
            environment,
        )
        return JSONResponse(
            status_code=500,
            content={
                "success": False,
                "detail": "BloFin API passphrase is not configured on the server.",
                "user_message": f"BloFin passphrase missing ({environment}). {env_hint}",
                "request_id": req_id,
            },
            headers={"X-Request-ID": req_id},
        )

    inst_id = _blofin_inst_id(trade.coin)

    # ── LIMIT: BloFin resting entry + SL on order (TP legs deferred until fill) ──
    if not is_market:
        effective_leverage = _normalize_citadel_leverage(trade.leverage)
        # Persist for analysis prompts — future setups use this exact leverage.
        remember_citadel_leverage(user_id, effective_leverage)

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
            logger.info("Leverage set to %sx on BloFin (limit)", effective_leverage)
        else:
            logger.warning(
                "blofin_set_leverage_failed request_id=%s inst=%s leverage=%sx http=%s code=%s msg=%s "
                "— continuing with LIMIT order (exchange may use prior leverage)",
                req_id,
                inst_id,
                effective_leverage,
                lev_result.get("http_status"),
                lev_result.get("code"),
                lev_result.get("msg"),
            )

        limit_entry = float(trade.entry_price)
        order_size, size_meta = _blofin_calculate_order_size(
            coin=trade.coin,
            entry_price=limit_entry,
            stop_loss=trade.stop_loss,
            risk_percent=effective_risk,
            leverage=effective_leverage,
            base_url=api_base_url,
            api_key=exchange_api_key,
            api_secret=exchange_secret,
            passphrase=passphrase,
            request_id=req_id,
        )

        logger.info(
            "execute_trade_limit_dispatch request_id=%s trade_id=%s blofin_base=%s inst=%s "
            "limit_price=%.6f order_size=%s leverage=%sx size_meta=%s",
            req_id,
            trade_id,
            api_base_url,
            inst_id,
            limit_entry,
            order_size,
            effective_leverage,
            size_meta,
        )

        entry_result = _blofin_place_order(
            base_url=api_base_url,
            api_key=exchange_api_key,
            api_secret=exchange_secret,
            passphrase=passphrase,
            coin=trade.coin,
            direction=trade.direction,
            order_type="limit",
            size=order_size,
            price=str(limit_entry),
            tp1=None,
            sl=trade.stop_loss,
            client_order_id=trade_id[:32],
            request_id=req_id,
        )

        entry_order_id = entry_result.get("order_id")
        if not entry_result.get("ok") or not entry_order_id:
            friendly = _blofin_user_friendly_error(
                entry_result.get("code"),
                entry_result.get("msg"),
            )
            logger.warning(
                "execute_trade_limit_failure request_id=%s trade_id=%s http=%s code=%s msg=%s",
                req_id,
                trade_id,
                entry_result.get("http_status"),
                entry_result.get("code"),
                entry_result.get("msg"),
            )
            fail_body: dict[str, Any] = {
                "success": False,
                "status": "failed",
                "order_type": "limit",
                "trade_id": trade_id,
                "detail": entry_result.get("msg") or "BloFin LIMIT order rejected.",
                "user_message": friendly,
                "blofin_code": entry_result.get("code"),
                "request_id": req_id,
            }
            if _blofin_is_ip_whitelist_error(entry_result.get("code"), entry_result.get("msg")):
                egress_ip = _citadel_egress_ip_for_whitelist()
                if egress_ip:
                    fail_body["whitelist_ip"] = egress_ip
            return JSONResponse(
                status_code=502,
                content=fail_body,
                headers={"X-Request-ID": req_id},
            )

        confirm = await _blofin_confirm_limit_order(
            base_url=api_base_url,
            api_key=exchange_api_key,
            api_secret=exchange_secret,
            passphrase=passphrase,
            inst_id=inst_id,
            order_id=entry_order_id,
            placement=entry_result,
            request_id=req_id,
        )

        if not confirm.get("limit_ok"):
            logger.warning(
                "execute_trade_limit_unconfirmed request_id=%s trade_id=%s order_id=%s "
                "environment=%s base_url=%s state=%s order_size=%s",
                req_id,
                trade_id,
                entry_order_id,
                environment,
                api_base_url,
                confirm.get("state"),
                order_size,
            )
            return JSONResponse(
                status_code=502,
                content={
                    "success": False,
                    "status": "failed",
                    "order_type": "limit",
                    "trade_id": trade_id,
                    "order_id": entry_order_id,
                    "detail": (
                        "BloFin accepted the LIMIT order but Citadel could not confirm it. "
                        f"state={confirm.get('state')!s} filledSize={confirm.get('filled_size')!s}"
                    ),
                    "user_message": (
                        "LIMIT order was submitted to BloFin but could not be confirmed. "
                        f"Check order history on BloFin ({environment}). Order ID {entry_order_id}."
                    ),
                    "blofin_confirm": {
                        "state": confirm.get("state"),
                        "filled_size": confirm.get("filled_size"),
                    },
                    "api_base_url": api_base_url,
                    "request_id": req_id,
                },
                headers={"X-Request-ID": req_id},
            )

        limit_status = confirm.get("limit_status") or (
            "filled" if confirm.get("state") == "filled" else "resting"
        )
        rr = compute_rr(limit_entry, trade.tp1, trade.stop_loss)

        tp1_tpsl_id: Optional[str] = None
        tp2_tpsl_id: Optional[str] = None
        tp1_size: Optional[str] = None
        tp2_size: Optional[str] = None
        tp_warnings: list[str] = []

        # Limit filled immediately — attach dual TP legs (same as MARKET post-fill).
        if limit_status == "filled":
            spec = _blofin_fetch_instrument_spec(
                base_url=api_base_url,
                inst_id=inst_id,
                request_id=req_id,
            )
            position_size = (
                confirm.get("filled_size")
                or confirm.get("size")
                or order_size
            )
            position_size_str = str(position_size)
            tp1_size, tp2_size = _blofin_dual_tp_contract_sizes(
                position_size_str,
                lot_size=float(spec["lotSize"]),
                min_size=float(spec["minSize"]),
            )

            tp1_result = _blofin_place_tpsl_take_profit(
                base_url=api_base_url,
                api_key=exchange_api_key,
                api_secret=exchange_secret,
                passphrase=passphrase,
                coin=trade.coin,
                direction=trade.direction,
                tp_price=trade.tp1,
                size=tp1_size,
                client_order_id=f"{trade_id[:28]}l1",
                request_id=req_id,
            )
            tp1_tpsl_id = tp1_result.get("tpsl_id")
            if not tp1_result.get("ok"):
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
                client_order_id=f"{trade_id[:28]}l2",
                request_id=req_id,
            )
            tp2_tpsl_id = tp2_result.get("tpsl_id")
            if not tp2_result.get("ok"):
                tp_warnings.append(f"TP2 (60%) not placed: {tp2_result.get('msg') or 'unknown'}")

        fill_entry = _parse_blofin_price_token(confirm.get("average_price")) or limit_entry
        if limit_status == "filled":
            user_message = (
                f"LIMIT order filled on BloFin ({environment}). "
                f"{trade.coin} {trade.direction.upper()} · Fill {format_usd(fill_entry)} · "
                f"Order ID {entry_order_id}"
            )
            message = f"LIMIT order filled for {trade.coin} {trade.direction.upper()}."
        else:
            user_message = (
                f"Limit order resting on BloFin ({environment}). "
                f"{trade.coin} {trade.direction.upper()} · Entry {format_usd(limit_entry)} · "
                f"Order ID {entry_order_id}. Check Open Orders — TP legs apply after fill."
            )
            message = f"LIMIT order placed for {trade.coin} {trade.direction.upper()}."

        logger.info(
            "execute_trade_limit_outcome request_id=%s trade_id=%s order_id=%s "
            "limit_status=%s state=%s filled=%s avg=%s",
            req_id,
            trade_id,
            entry_order_id,
            limit_status,
            confirm.get("state"),
            confirm.get("filled_size"),
            confirm.get("average_price"),
        )

        return JSONResponse(
            status_code=200,
            content={
                "success": True,
                "status": "success",
                "order_type": "limit",
                "limit_status": limit_status,
                "trade_id": trade_id,
                "order_id": entry_order_id,
                "tp1_tpsl_id": tp1_tpsl_id,
                "tp2_tpsl_id": tp2_tpsl_id,
                "tp1_size": tp1_size,
                "tp2_size": tp2_size,
                "tp_warnings": tp_warnings,
                "user_id": user_id,
                "coin": trade.coin,
                "direction": trade.direction,
                "entry_price": limit_entry,
                "fill_entry_price": fill_entry if limit_status == "filled" else None,
                "stop_loss": trade.stop_loss,
                "tp1": trade.tp1,
                "tp2": trade.tp2,
                "risk_percent": effective_risk,
                "risk_percent_requested": requested_risk,
                "order_size": order_size,
                "leverage": effective_leverage,
                "rr": rr,
                "exchange": exchange,
                "environment": environment,
                "api_base_url": api_base_url,
                "message": message,
                "user_message": user_message,
                "blofin_confirm": {
                    "state": confirm.get("state"),
                    "filled_size": confirm.get("filled_size"),
                    "average_price": confirm.get("average_price"),
                    "size": confirm.get("size"),
                },
                "request_id": req_id,
            },
            headers={"X-Request-ID": req_id},
        )

    # ── MARKET: BloFin immediate entry (unchanged) ──
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

    effective_leverage = _normalize_citadel_leverage(trade.leverage)
    # Persist for analysis prompts — future setups use this exact leverage.
    remember_citadel_leverage(user_id, effective_leverage)

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

    order_size, size_meta = _blofin_calculate_order_size(
        coin=trade.coin,
        entry_price=reference_price,
        stop_loss=trade.stop_loss,
        risk_percent=effective_risk,
        leverage=effective_leverage,
        base_url=api_base_url,
        api_key=exchange_api_key,
        api_secret=exchange_secret,
        passphrase=passphrase,
        request_id=req_id,
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
        sl=None,
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
        sl_tpsl_id: Optional[str] = None
        tp_warnings: list[str] = []

        sl_result = _blofin_place_tpsl_stop_loss(
            base_url=api_base_url,
            api_key=exchange_api_key,
            api_secret=exchange_secret,
            passphrase=passphrase,
            coin=trade.coin,
            direction=trade.direction,
            sl_price=trade.stop_loss,
            size=position_size_str,
            client_order_id=f"{trade_id[:28]}sl",
            request_id=req_id,
        )
        sl_tpsl_id = sl_result.get("tpsl_id")
        if sl_result.get("ok"):
            logger.info(
                "blofin_market_sl_tpsl_ok request_id=%s trade_id=%s tpsl_id=%s size=%s sl=%s",
                req_id,
                trade_id,
                sl_tpsl_id,
                position_size_str,
                trade.stop_loss,
            )
        else:
            tp_warnings.append(
                f"Stop loss leg failed: {sl_result.get('msg') or 'unknown error'}"
            )
            logger.warning(
                "blofin_market_sl_tpsl_failed request_id=%s trade_id=%s code=%s msg=%s",
                req_id,
                trade_id,
                sl_result.get("code"),
                sl_result.get("msg"),
            )

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
                "sl_tpsl_id": sl_tpsl_id,
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

# ─── Oracle Citadel Live Positions (BloFin) ───────────────────────────────────


async def _handle_citadel_positions(http_request: Request) -> JSONResponse:
    user_id = (http_request.query_params.get("user_id") or "").strip()
    session, err = _citadel_resolve_exchange_session(http_request, user_id)
    if err is not None:
        return err
    assert session is not None
    inst_id = (http_request.query_params.get("inst_id") or "").strip() or None
    if session.get("exchange") == "bitunix":
        symbol = bux.bitunix_symbol(_citadel_coin_from_inst_id(inst_id)) if inst_id else None
        positions = await asyncio.to_thread(
            bux.fetch_positions,
            api_key=session["api_key"],
            api_secret=session["api_secret"],
            symbol=symbol,
            request_id=session["req_id"],
        )
    else:
        positions = await asyncio.to_thread(
            _blofin_fetch_positions,
            base_url=session["api_base_url"],
            api_key=session["api_key"],
            api_secret=session["api_secret"],
            passphrase=session["passphrase"],
            inst_id=inst_id,
            request_id=session["req_id"],
        )
    return JSONResponse(
        status_code=200,
        content={
            "success": True,
            "positions": positions,
            "count": len(positions),
            "request_id": session["req_id"],
        },
        headers={"X-Request-ID": session["req_id"]},
    )


async def _handle_citadel_close_position(http_request: Request, *, flash: bool = False) -> JSONResponse:
    req_id = getattr(http_request.state, "request_id", "?")
    try:
        raw = await http_request.json()
    except Exception:
        raw = {}
    if not isinstance(raw, dict):
        raw = {}
    user_id = (raw.get("user_id") or "").strip()
    session, err = _citadel_resolve_exchange_session(http_request, user_id)
    if err is not None:
        return err
    assert session is not None
    inst_id = (raw.get("inst_id") or raw.get("instId") or "").strip()
    position_id = (raw.get("position_id") or raw.get("positionId") or "").strip()
    if session.get("exchange") == "bitunix":
        close_id = position_id or inst_id
        if not close_id:
            return JSONResponse(
                status_code=400,
                content={
                    "success": False,
                    "detail": "position_id is required for Bitunix.",
                    "user_message": "Position id missing for close.",
                    "request_id": session["req_id"],
                },
                headers={"X-Request-ID": session["req_id"]},
            )
        unrealized_pnl = float(raw.get("unrealized_pnl") or raw.get("unrealizedPnl") or 0)
        result = await asyncio.to_thread(
            bux.flash_close_position,
            api_key=session["api_key"],
            api_secret=session["api_secret"],
            position_id=close_id,
            request_id=session["req_id"],
        )
        if not result.get("ok"):
            msg = bux.user_friendly_error(result.get("code"), result.get("msg"))
            fail_body = {
                "success": False,
                "detail": msg,
                "user_message": msg,
                "request_id": session["req_id"],
            }
            _attach_bitunix_whitelist_ip_if_needed(
                fail_body,
                code=result.get("code"),
                msg=result.get("msg"),
                http_status=result.get("http_status"),
            )
            return JSONResponse(
                status_code=502,
                content=fail_body,
                headers={"X-Request-ID": session["req_id"]},
            )
        coin = _citadel_coin_from_inst_id(inst_id) if inst_id else "?"
        return JSONResponse(
            status_code=200,
            content={
                "success": True,
                "flash": flash,
                "inst_id": inst_id or close_id,
                "position_id": close_id,
                "realized_pnl": unrealized_pnl,
                "coin": coin,
                "win": unrealized_pnl > 0,
                "loss": unrealized_pnl < 0,
                "request_id": session["req_id"],
            },
            headers={"X-Request-ID": session["req_id"]},
        )
    if not inst_id:
        return JSONResponse(
            status_code=400,
            content={
                "success": False,
                "detail": "inst_id is required.",
                "user_message": "Instrument id missing for close.",
                "request_id": session["req_id"],
            },
            headers={"X-Request-ID": session["req_id"]},
        )
    margin_mode = (raw.get("margin_mode") or raw.get("marginMode") or BLOFIN_MARGIN_MODE).strip()
    position_side = (raw.get("position_side") or raw.get("positionSide") or "net").strip()
    unrealized_pnl = float(raw.get("unrealized_pnl") or raw.get("unrealizedPnl") or 0)

    result = await asyncio.to_thread(
        _blofin_close_position,
        base_url=session["api_base_url"],
        api_key=session["api_key"],
        api_secret=session["api_secret"],
        passphrase=session["passphrase"],
        inst_id=inst_id,
        margin_mode=margin_mode,
        position_side=position_side,
        request_id=session["req_id"],
    )
    if not result.get("ok"):
        msg = _blofin_user_friendly_error(result.get("code"), result.get("msg"))
        return JSONResponse(
            status_code=502,
            content={
                "success": False,
                "detail": msg,
                "user_message": msg,
                "request_id": session["req_id"],
            },
            headers={"X-Request-ID": session["req_id"]},
        )
    realized = unrealized_pnl
    return JSONResponse(
        status_code=200,
        content={
            "success": True,
            "flash": flash,
            "inst_id": inst_id,
            "realized_pnl": realized,
            "coin": _citadel_coin_from_inst_id(inst_id),
            "win": realized > 0,
            "loss": realized < 0,
            "request_id": session["req_id"],
        },
        headers={"X-Request-ID": session["req_id"]},
    )


async def _handle_citadel_trailing_stop(http_request: Request) -> JSONResponse:
    try:
        raw = await http_request.json()
    except Exception:
        raw = {}
    if not isinstance(raw, dict):
        raw = {}
    user_id = (raw.get("user_id") or "").strip()
    session, err = _citadel_resolve_exchange_session(http_request, user_id)
    if err is not None:
        return err
    assert session is not None
    if session.get("exchange") == "bitunix":
        return JSONResponse(
            status_code=400,
            content={
                "success": False,
                "user_message": "Trailing stop is not supported on Bitunix. Manage stops on the exchange.",
                "request_id": session["req_id"],
            },
            headers={"X-Request-ID": session["req_id"]},
        )
    inst_id = (raw.get("inst_id") or raw.get("instId") or "").strip()
    direction = (raw.get("direction") or "long").strip().lower()
    try:
        mark_price = float(raw.get("mark_price") or raw.get("markPrice") or 0)
        callback_pct = float(raw.get("callback_pct") or raw.get("callbackPct") or 1.5)
        size = str(raw.get("size") or "1")
    except (TypeError, ValueError):
        return JSONResponse(
            status_code=400,
            content={
                "success": False,
                "user_message": "Invalid trailing stop parameters.",
                "request_id": session["req_id"],
            },
            headers={"X-Request-ID": session["req_id"]},
        )
    if not inst_id or mark_price <= 0:
        return JSONResponse(
            status_code=400,
            content={
                "success": False,
                "user_message": "inst_id and mark_price are required.",
                "request_id": session["req_id"],
            },
            headers={"X-Request-ID": session["req_id"]},
        )
    result = await asyncio.to_thread(
        _blofin_place_trailing_stop_order,
        base_url=session["api_base_url"],
        api_key=session["api_key"],
        api_secret=session["api_secret"],
        passphrase=session["passphrase"],
        inst_id=inst_id,
        direction=direction,
        mark_price=mark_price,
        callback_pct=callback_pct,
        size=size,
        request_id=session["req_id"],
    )
    if not result.get("ok"):
        msg = _blofin_user_friendly_error(result.get("code"), result.get("msg"))
        return JSONResponse(
            status_code=502,
            content={
                "success": False,
                "user_message": msg or "Trailing stop could not be placed.",
                "request_id": session["req_id"],
            },
            headers={"X-Request-ID": session["req_id"]},
        )
    return JSONResponse(
        status_code=200,
        content={
            "success": True,
            "tpsl_id": result.get("tpsl_id"),
            "sl_trigger_price": result.get("sl_trigger_price"),
            "callback_pct": result.get("callback_pct"),
            "request_id": session["req_id"],
        },
        headers={"X-Request-ID": session["req_id"]},
    )


async def _handle_citadel_tpsl_details(http_request: Request) -> JSONResponse:
    user_id = (http_request.query_params.get("user_id") or "").strip()
    session, err = _citadel_resolve_exchange_session(http_request, user_id)
    if err is not None:
        return err
    assert session is not None
    if session.get("exchange") == "bitunix":
        symbol = (http_request.query_params.get("inst_id") or http_request.query_params.get("symbol") or "").strip()
        position_id = (http_request.query_params.get("position_id") or "").strip() or None
        orders = await asyncio.to_thread(
            bux.fetch_tpsl_pending,
            api_key=session["api_key"],
            api_secret=session["api_secret"],
            symbol=symbol or None,
            position_id=position_id,
            request_id=session["req_id"],
        )
        return JSONResponse(
            status_code=200,
            content={
                "success": True,
                "orders": orders,
                "count": len(orders),
                "request_id": session["req_id"],
            },
            headers={"X-Request-ID": session["req_id"]},
        )
    inst_id = (http_request.query_params.get("inst_id") or "").strip() or None
    orders = await asyncio.to_thread(
        _blofin_fetch_tpsl_pending,
        base_url=session["api_base_url"],
        api_key=session["api_key"],
        api_secret=session["api_secret"],
        passphrase=session["passphrase"],
        inst_id=inst_id,
        request_id=session["req_id"],
    )
    return JSONResponse(
        status_code=200,
        content={
            "success": True,
            "orders": orders,
            "count": len(orders),
            "request_id": session["req_id"],
        },
        headers={"X-Request-ID": session["req_id"]},
    )


@app.post("/citadel/bitunix_probe")
@app.post("/citadel/bitunix_probe/")
@app.post("/api/citadel/bitunix_probe")
@app.post("/api/citadel/bitunix_probe/")
async def citadel_bitunix_probe(http_request: Request) -> JSONResponse:
    """Test Bitunix account API from Railway (no order placed)."""
    req_id = getattr(http_request.state, "request_id", "?")
    try:
        raw = await http_request.json()
    except Exception:
        raw = {}
    if not isinstance(raw, dict):
        raw = {}
    user_id = (raw.get("user_id") or "").strip()
    session, err = _citadel_resolve_exchange_session(http_request, user_id)
    if err is not None:
        return err
    assert session is not None
    if session.get("exchange") != "bitunix":
        return JSONResponse(
            status_code=400,
            content={
                "success": False,
                "detail": "Linked exchange is not Bitunix.",
                "user_message": "Switch Citadel to Bitunix and re-link API keys to run this probe.",
                "request_id": req_id,
            },
            headers={"X-Request-ID": req_id},
        )
    verify = await asyncio.to_thread(
        bux.verify_credentials,
        api_key=session["api_key"],
        api_secret=session["api_secret"],
        request_id=req_id,
    )
    ips = _citadel_egress_ips_for_whitelist()
    friendly = bux.user_friendly_error(verify.get("code"), verify.get("msg"))
    body: dict[str, Any] = {
        "success": bool(verify.get("ok")),
        "bitunix_code": verify.get("code"),
        "bitunix_msg": verify.get("msg"),
        "http_status": verify.get("http_status"),
        "egress_ips": ips,
        "user_message": friendly,
        "request_id": req_id,
    }
    if ips:
        body["whitelist_ip"] = ips[0]
        body["whitelist_ips"] = ips
    _attach_bitunix_whitelist_ip_if_needed(
        body,
        code=verify.get("code"),
        msg=verify.get("msg"),
        http_status=verify.get("http_status"),
    )
    logger.info(
        "citadel_bitunix_probe request_id=%s user_id=%s ok=%s code=%s http=%s ips=%s",
        req_id,
        user_id,
        verify.get("ok"),
        verify.get("code"),
        verify.get("http_status"),
        ",".join(ips),
    )
    return JSONResponse(
        status_code=200 if verify.get("ok") else 502,
        content=body,
        headers={"X-Request-ID": req_id},
    )


@app.get("/citadel/egress_ip")
@app.get("/citadel/egress_ip/")
@app.get("/api/citadel/egress_ip")
@app.get("/api/citadel/egress_ip/")
async def citadel_egress_ip(http_request: Request) -> JSONResponse:
    """Railway outbound IP(s) — whitelist in BloFin/Bitunix API key settings when IP restriction is on."""
    req_id = getattr(http_request.state, "request_id", "?")
    ips = _citadel_egress_ips_for_whitelist()
    primary = ips[0] if ips else ""
    return JSONResponse(
        status_code=200,
        content={
            "success": True,
            "egress_ip": primary,
            "whitelist_ip": primary,
            "whitelist_ips": ips,
            "message": (
                "Whitelist all listed IPs in your exchange API Management settings "
                "when Railway static outbound or IP restriction is enabled."
            ),
            "request_id": req_id,
        },
        headers={"X-Request-ID": req_id},
    )


@app.get("/citadel/positions")
@app.get("/citadel/positions/")
@app.get("/api/citadel/positions")
@app.get("/api/citadel/positions/")
async def citadel_positions(http_request: Request) -> JSONResponse:
    return await _handle_citadel_positions(http_request)


@app.post("/citadel/close_position")
@app.post("/citadel/close_position/")
@app.post("/api/citadel/close_position")
@app.post("/api/citadel/close_position/")
async def citadel_close_position(http_request: Request) -> JSONResponse:
    return await _handle_citadel_close_position(http_request, flash=False)


@app.post("/citadel/flash_close")
@app.post("/citadel/flash_close/")
@app.post("/api/citadel/flash_close")
@app.post("/api/citadel/flash_close/")
async def citadel_flash_close(http_request: Request) -> JSONResponse:
    return await _handle_citadel_close_position(http_request, flash=True)


@app.post("/citadel/trailing_stop")
@app.post("/citadel/trailing_stop/")
@app.post("/api/citadel/trailing_stop")
@app.post("/api/citadel/trailing_stop/")
async def citadel_trailing_stop(http_request: Request) -> JSONResponse:
    return await _handle_citadel_trailing_stop(http_request)


@app.get("/citadel/tpsl_details")
@app.get("/citadel/tpsl_details/")
@app.get("/api/citadel/tpsl_details")
@app.get("/api/citadel/tpsl_details/")
async def citadel_tpsl_details(http_request: Request) -> JSONResponse:
    return await _handle_citadel_tpsl_details(http_request)


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
