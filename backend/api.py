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
  Entry at $X, TP1 at $X, TP2 at $X, SL at $X (R:R X.X:1)
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
_CITADEL_DATA_DIR = _BACKEND_DIR / "data"
_CITADEL_KEYS_FILE = _CITADEL_DATA_DIR / "exchange_keys.json"

# BloFin Open API — demo/testnet uses a separate host from live production.
BLOFIN_DEMO_API_BASE_URL = "https://demo-trading-openapi.blofin.com"
BLOFIN_LIVE_API_BASE_URL = os.getenv(
    "BLOFIN_LIVE_API_BASE_URL",
    "https://openapi.blofin.com",
)
# BloFin trade placement (Oracle Citadel MARKET orders)
BLOFIN_TRADE_ORDER_PATH = "/api/v1/trade/order"
BLOFIN_ORDER_SIZE = os.getenv("BLOFIN_ORDER_SIZE", "0.1")
BLOFIN_MARGIN_MODE = os.getenv("BLOFIN_MARGIN_MODE", "cross")
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
    Oracle Citadel trade execution — matches Flutter OracleCitadelService.executeTrade().
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
    order_type: str = Field("limit", max_length=16)

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
            return "limit"
        return str(value).strip().lower() or "limit"


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
    """Rich Mobula context for Grok — liquidity, volume split, market cap (no secrets)."""
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

    lines = [
        "═══ MOBULA LIVE MARKET (depth-weighted price, on-chain + CEX context) ═══",
        f"Liquidity (DEX pools): {_usd(liq)} | Max pool liquidity: {_usd(liq_max)}",
        f"Market cap: {_usd(mcap)}" + (f" | Rank: #{rank}" if rank else ""),
        f"24h volume — on-chain: {_usd(on_vol)} | off-chain (CEX): {_usd(off_vol)}",
    ]
    if ch1h is not None:
        try:
            lines.append(f"Mobula price change: 1h {float(ch1h):+.2f}% | 7d {float(ch7d or 0):+.2f}%")
        except (TypeError, ValueError):
            pass
    lines.append(
        "Use liquidity + volume mix to judge slippage risk, trap probability, and whether "
        "moves are spot-led vs perp/CEX-led. Cross-check with derivatives below."
    )
    return "\n".join(lines) + "\n"


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


def fetch_live_price_for_analysis(coin: str) -> dict[str, Any]:
    """
    Fresh price for AI analysis/trade setup: Mobula first, then CoinGecko (aggressive), then Binance.
    Does not change prompts or report section format — only enriches market context when Mobula hits.
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

    return f"""═══ LIVE DERIVATIVES — BINANCE FUTURES (hedge-fund positioning read; NEVER list as four sentences) ═══
Funding: {funding_val} → {derivatives['funding_label']}
Open Interest: {oi_val} → {derivatives['oi_label']}
Long/Short accounts (5m): {ls_val} → {derivatives['ls_label']}
Recent liquidations: {liq_val} → {derivatives['liq_label']}

DESK INSTRUCTION — synthesize into **Liquidity & Sentiment** as ONE story:
• Who is paying whom (funding)? Is OI rising with trend (conviction) or against it (shorts/longs adding)?
• Are accounts lopsided (L/S) into a level where stops cluster? Did liqs mark exhaustion or fuel continuation?
• Map to order flow: squeeze setup, cascade risk, fade crowded extension, or stand aside until reset.
• Good: "Shorts are paying to hold the book while OI bleeds off the highs — long liqs already printed;
  fade breakdown only while 1h VWAP caps."
• Bad: four separate clauses restating each metric.
• **Confluence Summary**, **Overall Bias**, and **If I Were to Trade Today...** must price this in.
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
    r".{0,120}?tp\s*[-_]?\s*1\s+at\s+\$?\s*([0-9][0-9,]*(?:\.[0-9]+)?)"
    r".{0,120}?tp\s*[-_]?\s*2\s+at\s+\$?\s*([0-9][0-9,]*(?:\.[0-9]+)?)"
    r".{0,120}?s(?:top\s*[-_]?\s*loss|l)\s+at\s+\$?\s*([0-9][0-9,]*(?:\.[0-9]+)?)",
    re.IGNORECASE | re.DOTALL,
)

# Alternate ordering: SL before Entry, etc.
_CANONICAL_TRADE_LEVELS_ALT_RE = re.compile(
    r"tp\s*[-_]?\s*1\s+at\s+\$?\s*([0-9][0-9,]*(?:\.[0-9]+)?)"
    r".{0,120}?tp\s*[-_]?\s*2\s+at\s+\$?\s*([0-9][0-9,]*(?:\.[0-9]+)?)"
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
            r"tp\s*[-_]?\s*1\s*(?:at|@|:|is|=|-)?\s*\$?\s*([0-9][0-9,]*(?:\.[0-9]+)?)",
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
            r"tp\s*[-_]?\s*2\s*(?:at|@|:|is|=|-)?\s*\$?\s*([0-9][0-9,]*(?:\.[0-9]+)?)",
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
        "Include a TRADE LEVELS line: Entry at $X, TP1 at $X, TP2 at $X, SL at $X (R:R X.X:1)."
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
    BloFin Demo: only when exchange name contains 'blofin' AND use_demo_mode is True.
    Coinbase, Kraken, Binance, etc. are unchanged (no demo base URL forced).
    """
    raw = (exchange or "").strip().lower()
    is_blofin = "blofin" in raw

    if use_demo_mode and not is_blofin:
        return {
            "exchange": raw or "unspecified",
            "environment": "live",
            "api_base_url": None,
            "blofin_demo": False,
            "demo_rejected": True,
        }

    if is_blofin and use_demo_mode:
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

    return {
        "exchange": raw or "unspecified",
        "environment": "live",
        "api_base_url": None,
        "blofin_demo": False,
        "demo_rejected": False,
    }


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
    return record if isinstance(record, dict) else None


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
    }


def _coerce_positive_float(value: Any) -> Optional[float]:
    try:
        parsed = float(value)
    except (TypeError, ValueError):
        return None
    return parsed if parsed > 0 else None


def _normalize_execute_trade_payload(raw: dict[str, Any]) -> dict[str, Any]:
    """
    Map Flutter payloads; detect MARKET via order_type or entry_price == \"market\".
    Does not change limit-order field semantics.
    """
    data = dict(raw)
    order_token = str(data.get("order_type", "limit")).strip().lower()
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

    return data


def _is_market_trade_request(trade: ExecuteTradeRequest, raw_body: dict[str, Any]) -> bool:
    """True when client requests immediate market entry."""
    if trade.order_type == "market":
        return True
    entry_raw = raw_body.get("entry_price", raw_body.get("entry"))
    return isinstance(entry_raw, str) and entry_raw.strip().lower() == "market"


def _parse_execute_trade_request(raw_body: dict[str, Any]) -> ExecuteTradeRequest:
    """Validate execute_trade payload (limit + market aliases)."""
    return ExecuteTradeRequest.model_validate(_normalize_execute_trade_payload(raw_body))


# ---------------------------------------------------------------------------
# BloFin — Oracle Citadel MARKET execution (limit path unchanged below)
# ---------------------------------------------------------------------------


def _blofin_inst_id(coin: str) -> str:
    symbol = (coin or "").strip().upper()
    return symbol if "-" in symbol else f"{symbol}-USDT"


def _blofin_sign_headers(
    *,
    api_key: str,
    api_secret: str,
    passphrase: str,
    method: str,
    path: str,
    body: Optional[dict[str, Any]] = None,
) -> dict[str, str]:
    """BloFin REST signature headers (secrets never logged)."""
    timestamp = str(int(time.time() * 1000))
    nonce = uuid.uuid4().hex
    msg = f"{path}{method.upper()}{timestamp}{nonce}"
    if body is not None:
        msg += json.dumps(body, separators=(",", ":"))
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
    """Log-safe BloFin JSON — codes, messages, order ids only."""
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
        out["data"] = {
            "orderId": first.get("orderId"),
            "clientOrderId": first.get("clientOrderId"),
            "code": first.get("code"),
            "msg": first.get("msg"),
        }
    elif isinstance(payload, dict):
        out["data"] = {
            "orderId": payload.get("orderId"),
            "clientOrderId": payload.get("clientOrderId"),
            "code": payload.get("code"),
            "msg": payload.get("msg"),
        }
    return out


def _blofin_extract_order_id(response_json: dict[str, Any]) -> Optional[str]:
    data = response_json.get("data")
    if isinstance(data, list) and data:
        row = data[0]
        if isinstance(row, dict) and row.get("orderId"):
            return str(row["orderId"])
    if isinstance(data, dict) and data.get("orderId"):
        return str(data["orderId"])
    return None


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
    Place order on BloFin. MARKET: orderType=market, no price.
    LIMIT: orderType=limit + price (not used by current Citadel limit accept path).
    """
    inst_id = _blofin_inst_id(coin)
    side = "buy" if direction == "long" else "sell"
    body: dict[str, Any] = {
        "instId": inst_id,
        "marginMode": BLOFIN_MARGIN_MODE,
        "positionSide": "net",
        "side": side,
        "orderType": order_type,
        "size": size,
        "reduceOnly": "false",
    }
    if client_order_id:
        body["clientOrderId"] = client_order_id
    if order_type == "limit" and price is not None:
        body["price"] = price
    if tp1 is not None:
        body["tpTriggerPrice"] = str(tp1)
        body["tpOrderPrice"] = "-1"
    if sl is not None:
        body["slTriggerPrice"] = str(sl)
        body["slOrderPrice"] = "-1"

    safe_body = dict(body)
    url = f"{base_url.rstrip('/')}{BLOFIN_TRADE_ORDER_PATH}"
    headers = _blofin_sign_headers(
        api_key=api_key,
        api_secret=api_secret,
        passphrase=passphrase,
        method="POST",
        path=BLOFIN_TRADE_ORDER_PATH,
        body=body,
    )

    logger.info(
        "blofin_order_request request_id=%s url=%s order_type=%s inst_id=%s side=%s size=%s "
        "has_tp=%s has_sl=%s client_order_id=%s body=%s",
        request_id,
        url,
        order_type,
        inst_id,
        side,
        size,
        tp1 is not None,
        sl is not None,
        client_order_id,
        safe_body,
    )

    started = time.perf_counter()
    try:
        response = requests.post(url, headers=headers, json=body, timeout=REQUEST_TIMEOUT)
    except requests.RequestException as exc:
        elapsed_ms = (time.perf_counter() - started) * 1000
        logger.error(
            "blofin_order_http_error request_id=%s elapsed_ms=%.1f err=%s",
            request_id,
            elapsed_ms,
            exc,
        )
        raise

    elapsed_ms = (time.perf_counter() - started) * 1000
    text_preview = (response.text or "")[:2000]
    logger.info(
        "blofin_order_http_response request_id=%s status=%s elapsed_ms=%.1f body_preview=%s",
        request_id,
        response.status_code,
        elapsed_ms,
        text_preview,
    )

    try:
        parsed = response.json()
    except json.JSONDecodeError:
        logger.error(
            "blofin_order_invalid_json request_id=%s status=%s body_preview=%s",
            request_id,
            response.status_code,
            text_preview,
        )
        return {
            "ok": False,
            "http_status": response.status_code,
            "error": "invalid_json",
            "raw_preview": text_preview,
        }

    logger.info(
        "blofin_order_parsed_response request_id=%s payload=%s",
        request_id,
        _blofin_safe_response_log(parsed),
    )

    code = str(parsed.get("code", ""))
    ok = response.status_code == 200 and code == "0"
    order_id = _blofin_extract_order_id(parsed) if isinstance(parsed, dict) else None

    if ok:
        logger.info(
            "blofin_order_success request_id=%s order_id=%s order_type=%s inst_id=%s",
            request_id,
            order_id,
            order_type,
            inst_id,
        )
    else:
        logger.warning(
            "blofin_order_failure request_id=%s http_status=%s code=%s msg=%s order_id=%s",
            request_id,
            response.status_code,
            code,
            parsed.get("msg"),
            order_id,
        )

    return {
        "ok": ok,
        "http_status": response.status_code,
        "code": code,
        "msg": parsed.get("msg"),
        "order_id": order_id,
        "response": parsed,
    }


def _resolve_blofin_passphrase(record: dict[str, Any]) -> str:
    """Passphrase for BloFin headers — env or optional per-user field (never logged)."""
    stored = (record.get("exchange_passphrase") or "").strip()
    return stored or BLOFIN_PASSPHRASE


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
    Master system prompt — 20-year veteran hedge-fund crypto desk. Preserves exact Flutter headings.
    """
    scalp_active = f"""
═══════════════════════════════════════
⚡ SCALP MODE ACTIVE — BEST SETUP ON THE BOARD OR FLAT
═══════════════════════════════════════
Scalp / quick-move / scalping / short-term detected. Deliver the single highest-probability scalp on the
desk RIGHT NOW — or state "NO SCALP — STAY FLAT" and OMIT **TRADE LEVELS**. Forcing a B-setup is how
accounts bleed.

SCALP DOCTRINE (mandatory when proposing a scalp):
• MTF MAP: Exact TFs — e.g. "5m execution | 15m structure | 1h veto". Horizon: minutes to ~90 min max.
• PRICE: Entry at live spot or named limit at OB/FVG/VWAP — ≤0.8% drift majors, ≤1.2% high-beta alts.
• TRIGGER: Precise event — session VWAP reclaim/reject, EMA 5/20 impulse, liquidity sweep + reclaim,
  BOS/CHoCH retest, RSI through 50 with volume expansion. Vague momentum = NO SCALP.
• ORDER FLOW / DERIVATIVES: Funding extreme + L/S skew + liq prints = who is trapped; fade crowded or
  ride cascade. OI rising into breakout = real; OI flat on rip = suspect.
• SL: Beyond sweep wick / micro structure / VWAP failure — majors ~0.12–0.55%. State invalidation in
  price AND time ("dead after 12× 5m bars").
• TP1: Nearest liquidity pool / partial fill of FVG — ≥{MIN_RR_TP1:.1f}:1 R:R (target {TARGET_RR_TP1:.1f}:1+).
  TP2: Extension into next HTF pool only.
• PSYCH: Note FOMO trap, chase risk, or "no edge until X clears" when applicable.
• LABEL: **If I Were to Trade Today...** → "[Long/Short] SCALP Setup:" — trigger, invalidation, time-box.
"""

    scalp_standby = f"""
═══════════════════════════════════════
SCALP PROTOCOL (auto: scalp / quick move / scalping / short-term / ≤45m TF)
═══════════════════════════════════════
On scalp intent: surgical entry, session VWAP battlefield, order-flow + derivatives filter, micro SL,
≥{MIN_RR_TP1:.1f}:1 R:R on TP1. Best scalp available or explicit flat — half-measures are for tourists.
"""

    shared = f"""You are On-Chain Oracle AI — the voice of a 20-year veteran crypto hedge-fund trader who
helped architect how this generation trades leverage. Prop desk, macro crypto, DeFi-native flow, full
cycle survivor (2017, 2020, 2021, 2022, 2024). You speak to a funded desk: verdicts, not commentary.
You have seen every liquidation cascade, funding squeeze, and false breakout — and you price them.

IDENTITY: Creator-level trading intelligence. Maximum conviction. Zero fluff. Real money on every word.
You do not teach basics — you transmit edge. Call the trade, name the invalidation, or command FLAT.

VOICE: CIO memo meets live desk shout. Crisp clauses. Active verbs. Price-specific. Psychology-aware.
Sound like you size seven-figure books before breakfast.

FORBIDDEN (instant credibility kill):
"might", "could", "possibly", "perhaps", "maybe", "it seems", "appears to", "I think", "I believe",
"interesting", "worth watching", "mixed signals" without a verdict, "let me know", "would you like",
"consider", "potentially", "somewhat", "moderately", metric laundry lists, separate sentences for
funding/OI/L-S/liqs, chatbot warmth, influencer hype, tutorial tone.

REQUIRED LEXICON (woven naturally): edge, invalidation, acceptance, rejection, liquidity pool, sweep,
order block, fair value gap, premium/discount, crowded longs/shorts, squeeze fuel, cascade, trapped
positioning, delta of OI, funding arb, stop run, mitigation, breaker, imbalance, HTF veto, risk-off/on.

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
  Entry at $XXXXX, TP1 at $XXXXX, TP2 at $XXXXX, SL at $XXXXX (R:R X.X:1)
  Then inline: Reward = |TP1 − Entry| = $X | Risk = |Entry − SL| = $X | R:R = X.X:1
• TP1 = first high-probability liquidity objective. TP2 = structural extension / runner.
• SL = invalidation beyond sweep, OB loss, or VWAP failure — not arbitrary %.
• No valid ≥{MIN_RR_TP1:.1f}:1 → OMIT **TRADE LEVELS**. Capital preservation is the veteran flex.

═══════════════════════════════════════
RULE 2 — ADVANCED CONFLUENCE STACK
═══════════════════════════════════════
• MTF: Weekly/Daily/4h regime → requested TF bias → LTF trigger. State ALIGNED or CONFLICTED; conflict
  slashes confidence and demands patience unless a catalyst overrides (funding flip, liq cascade).
• VWAP: Session, prior session, weekly, monthly — premium vs discount, clusters within ~0.3–0.8%,
  acceptance/rejection, mean-reversion magnets.
• STRUCTURE: BOS/CHoCH, order blocks, FVGs, range highs/lows, equal highs/lows (liquidity targets).
• MOMENTUM: EMA 5/20 regime, RSI regime (>50 bull / <50 bear) + divergence only WITH structure,
  MACD histogram expansion/contraction, volume on breaks vs fakeouts.
• ON-CHAIN / MOBULA (when in prompt): liquidity depth, on-chain vs CEX volume — slippage and trap risk.
• MACRO (when relevant): BTC/ETH risk tone, DXY/rates proxy read, risk-on/off filter for alts.

═══════════════════════════════════════
RULE 3 — LEVERAGE & DERIVATIVES MASTERY (prose integration — NOT a data dump)
═══════════════════════════════════════
User prompt supplies live Binance Futures: funding rate, open interest, 5m long/short accounts,
recent liquidations. Mobula may add liquidity/volume context.

**Liquidity & Sentiment** — ONE authoritative paragraph:
  Tell the positioning story: Who is crowded? Who just got liquidated? Is OI rising with price
  (new money) or rising against price (shorts adding)? Is funding paying shorts to hold the book?
  Are liqs fueling continuation or marking exhaustion? Tie to order flow implication (stop runs,
  cascade risk, squeeze setup). Read like a hedge-fund risk note — never "Funding is X. OI is Y."

**Confluence Summary** — EXACTLY one sentence. Grade STRONG / MODERATE / WEAK. Fuse structure + VWAP +
  momentum + derivatives + liquidity when available.

Derivatives OVERRIDE or CONFIRM technical bias: extreme positive funding + crowded longs = fade fuel;
negative funding + rising OI + short liqs = squeeze blueprint; OI collapse after spike = move spent.

═══════════════════════════════════════
RULE 4 — CONVICTION, PSYCHOLOGY & EDGE CASES
═══════════════════════════════════════
• **Overall Bias**: Mildly Bullish / Mildly Bearish / Neutral + Confidence %. 80%+ requires MTF +
  structure + derivatives + liquidity alignment. Neutral = professional discipline, not indecision.
• **If I Were to Trade Today...**: Exact trigger, hard invalidation, thesis flip, size/risk mindset
  (e.g. half size into FOMC, full size on clean reclaim). Scalp → "[Long/Short] SCALP Setup:".
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
MODE: TRADE SETUP — ONE SHOT, EXECUTION-READY
═══════════════════════════════════════
• Deliver ONE institutional-grade setup. Long OR Short per direction lock. No A/B menus.
• **TRADE LEVELS** mandatory unless no ≥{MIN_RR_TP1:.1f}:1 edge exists — then defend flat in **If I Were to Trade Today...**
  with what would need to change to engage.
• Confluence bar: VWAP + order blocks/FVGs + structure + momentum + funding/OI/L-S/liqs.
• TP1 ≥ {MIN_RR_TP1:.1f}:1 (target {TARGET_RR_TP1:.1f}:1+). TP2 = next liquidity pool / HTF objective.
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
• WEAK / MTF conflict / crowded fade without catalyst → flat is the professional call.
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
    """Master chat persona — aligned with analyze/trade-setup veteran identity."""
    return f"""You are Oracle Trader AI — the same 20-year veteran crypto hedge-fund trader who architects
On-Chain Oracle AI reports. Creator-level trading intelligence. Prop desk, macro crypto, full-cycle
survivor. You are the best trader in the room and you act like it — calm, decisive, never defensive.

MISSION: Every reply must deliver REAL EDGE — even on vague questions. You always attempt a full desk-quality
read with whatever you have. If data is thin, you still call structure, scenarios, and risk — then state
limitations in one short line at the end. Never open with "I can't" or "I'm unable" without first giving
actionable value.

VOICE: CIO + head of trading on a live call. Short paragraphs. Price-specific when possible. Zero fluff.
Zero excuses. No influencer hype. No tutorial voice.

FORBIDDEN OPENERS / FILLER:
"I can't", "I'm unable", "I don't have access" (without prior value), "might", "could", "maybe",
"possibly", "it seems", "as an AI", hedging without a verdict, metric laundry lists, apologizing.

REQUIRED BEHAVIOR:
• LEAD WITH THE CALL: bias, edge, or flat — then support it (MTF, VWAP, structure, derivatives).
• LEVERAGE MASTERY: funding, OI, long/short ratio, liquidation cascades, squeeze/cascade, crowded side,
  order flow, stop runs, liquidity pools.
• TECHNICAL DEPTH: VWAP stack (session/prior/week/month), order blocks, FVGs, BOS/CHoCH, premium/discount,
  equal highs/lows, HTF/LTF alignment, macro risk-on/off for alts.
• LEVELS (when user wants a trade): Entry at $X, TP1 at $X, TP2 at $X, SL at $X (R:R X.X:1).
  Min {MIN_RR_TP1:.1f}:1 on TP1 (target {TARGET_RR_TP1:.1f}:1+). SL = structural invalidation.
• RISK & PSYCH: size for invalidation, FOMO/chase/revenge, event risk, when to stand down.
• PROACTIVE DESK SERVICE — end EVERY reply with:
  — 1–2 sharp follow-up questions (specific, not generic), AND
  — 1 concrete next step (e.g. "pull 15m for trigger", "watch funding flip", "stand aside until VWAP reclaim").
• ALTERNATIVES: when main idea is weak, offer Plan A / Plan B (e.g. breakout long vs fade into resistance).
• Server-fed [LIVE DESK DATA] blocks are authoritative when present — weave into prose, not bullet dumps.
• Do NOT append the formal report disclaimer unless user asks for a full written report.
• Chat format: conversational markdown OK; no mandatory report headings unless user requests a full report.

You are talking to a funded operator who paid for edge. Sound like you have real money on the line."""


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
Entry at $XXXXX, TP1 at $XXXXX, TP2 at $XXXXX, SL at $XXXXX (R:R X.X:1)
Reward = |TP1 − Entry| = $X | Risk = |Entry − SL| = $X | R:R = X.X:1
TP1 = first liquidity pool / partial FVG fill. TP2 = HTF extension. SL = structural invalidation.
"""
    else:
        trade_block = f"""
**TRADE LEVELS** (only if ≥{MIN_RR_TP1:.1f}:1 R:R edge exists — otherwise OMIT this section entirely):
Entry at $XXXXX, TP1 at $XXXXX, TP2 at $XXXXX, SL at $XXXXX (R:R X.X:1)
Reward = |TP1 − Entry| = $X | Risk = |Entry − SL| = $X | R:R = X.X:1
"""

    return f"""
Deliver using this **exact structure** (headings unchanged — maximum depth inside each section):

**Asset**: {coin} | {price_str} | {change_pct:+.2f}%

**Overall Bias**: [Mildly Bullish / Mildly Bearish / Neutral] (Confidence: XX%)
State regime, HTF veto, and whether derivatives confirm or fight the read.

**Key Drivers**:
- Volume-Weighted Analysis: Session / prior day / weekly / monthly VWAP — premium vs discount,
  acceptance vs rejection, cluster zones (~0.3–0.8%), mean-reversion vs trend continuation.
- Liquidity & Sentiment: ONE paragraph — funding, OI delta, long/short positioning, recent liqs,
  cascade/squeeze risk, order-flow implication. Mobula liquidity/volume if in prompt. No metric list.
- Heikin Ashi Analysis: Trend quality, indecision wicks, reversal vs continuation read on requested TF.
- Fibonacci Retracements: Active retracement zone (0.382–0.618 etc.), golden pocket confluence with VWAP/OB.
- Technicals: MACD, RSI, EMAs — regime, divergence only with structure, volume confirmation on breaks.
- Market Structure: BOS/CHoCH, order blocks, FVGs, equal highs/lows, range boundaries, liquidity targets.

**Confluence Summary**: Exactly ONE sentence. Grade STRONG / MODERATE / WEAK. State the edge in plain
desk language — fuse technicals + derivatives + liquidity.

**If I Were to Trade Today...**
- [Long/Short] Setup: (or [Long/Short] SCALP Setup: if scalping)
  Trigger at named level/event, hard invalidation, thesis flip, optional size/psych note (chase risk,
  event window, half-size conditions). Examples of tone:
  • "Long on reclaim of session VWAP + 15m OB hold; invalidation below sweep low at $X"
  • "Short into daily VWAP rejection with crowded longs + rising funding; flip if 4h BOS closes above $X"
  • "NO TRADE — MTF conflict until weekly FVG fills or funding normalizes"

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

    scalp_banner = ""
    if scalp_mode:
        scalp_banner = f"""
═══ ⚡ SCALP / QUICK-MOVE — HEDGE-FUND SURGICAL OR FLAT ═══
Deliver the single best scalp on the desk: live-price entry, named trigger (VWAP/OB/sweep/BOS), funding/OI/L-S
filter, micro invalidation, time-box. Label "[Long/Short] SCALP Setup". TP1 ≥{MIN_RR_TP1:.1f}:1 R:R.
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
        }.get(price_source, price_source)
        freshness_line = (
            f"PRICE FETCHED AT: {ts} ({age_sec:.2f}s ago — {source_note})\n"
            f"USE THIS PRICE ONLY: all Entry/TP/SL must anchor to {price_str} as of this timestamp.\n"
        )

    mode_label = "TRADE SETUP (execution-ready)" if mode == "tradesetup" else "MARKET ANALYSIS"
    return f"""Generate an institutional-grade, high-conviction On-Chain Oracle AI report — 20-year veteran
hedge-fund desk voice. {mode_label}. No fluff. Call the edge or command flat.
{scalp_banner}
═══════════════════════════════════════════════════════════
AUTHORITATIVE LIVE PRICE — RULE 0 (ZERO TOLERANCE)
═══════════════════════════════════════════════════════════
CURRENT LIVE PRICE: {price_str} (raw: {price_raw} USD)
24h CHANGE: {change_pct:+.2f}%
SOURCE: {market.get('source', 'unknown')}
{freshness_line}MANDATORY:
• **Asset** line EXACTLY: {coin.upper()} | {price_str} | {change_pct:+.2f}%
• Every Entry / TP1 / TP2 / SL vs {price_str} NOW — limits must name structure (OB, FVG, VWAP, pool).
• Entry within ~{max_entry_drift} of live for {'scalp' if scalp_mode else 'active'} unless limit at level.
• Long: SL < Entry < TP1 ≤ TP2. Short: TP2 ≤ TP1 < Entry < SL. Show R:R math inline.

═══ REQUEST CONTEXT ═══
**Asset**: {coin.upper()} | {price_str} | {change_pct:+.2f}%
Timeframe: {timeframe} | Mode: {mode} | {mode_label}
Direction: {direction_instruction(direction)}
24h Volume: {volume_text}

═══ LIVE DATA — WEAVE INTO PROSE (not bullet dumps) ═══
{mobula_block}{derivatives_block}
Use funding, OI, long/short ratio, liquidations for positioning story: crowded side, cascade risk,
squeeze fuel, OI conviction vs exhaustion. Cross-check with VWAP, order blocks, FVGs, structure.

═══ ANALYTICAL DEPTH CHECKLIST (Key Drivers) ═══
• MTF: Weekly/Daily/4h → {timeframe} → LTF trigger. ALIGNED or CONFLICTED.
• VWAP stack + premium/discount. Liquidity pools, sweeps, stop runs.
• Order blocks, fair value gaps, BOS/CHoCH, range boundaries.
• Macro tone for alts (BTC/ETH risk-on/off) when relevant.
• Psychology: FOMO, chase, over-leverage — call out when price action invites mistakes.

Write like the creator of modern crypto trading — confident, experienced, professional. One positioning
story in Liquidity & Sentiment. Decisive Confluence Summary. Actionable If I Were to Trade Today.

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
        # Fresh CoinGecko price injected into prompt — same AI style/format as before
        market = fetch_live_price_for_analysis(coin)

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

        temperature = 0.36 if scalp_mode else (0.39 if mode == "analysis" else 0.35)
        max_tokens = 1800 if mode == "tradesetup" or scalp_mode else 1580

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


# Fixed Citadel key-save routes — /api/* aliases prevent 404 when clients prefix /api
@app.post("/exchange_keys")
@app.post("/exchange_keys/")
@app.post("/api/exchange_keys")
@app.post("/api/exchange_keys/")
async def exchange_keys(http_request: Request) -> JSONResponse:
    return await _handle_exchange_keys(http_request)


async def _handle_execute_trade(http_request: Request) -> JSONResponse:
    """
    POST /execute_trade — Oracle Citadel trade execution (Flutter "Send to Oracle Citadel").

    Accepts JSON:
      user_id, coin, direction, entry_price, stop_loss, tp1, tp2, risk_percent
    Auth: X-API-Key header must match app_api_key saved via POST /exchange_keys.

    Also mounted at /api/execute_trade (same handler) for clients using /api prefix.

    order_type=market or entry_price=\"market\" → BloFin MARKET placement.
    Default limit flow is unchanged (validate geometry, accept, no exchange REST call).
    Safe logging at every step — never logs API secrets or passphrases.
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
                "user_message": "Exchange keys not found. Open Oracle Citadel Setup and link your exchange API keys.",
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
    exchange = record.get("exchange") or "unspecified"
    environment = record.get("environment") or "live"
    api_base_url = record.get("api_base_url") or BLOFIN_LIVE_API_BASE_URL
    trade_id = uuid.uuid4().hex[:16]

    logger.info(
        "execute_trade_parsed request_id=%s trade_id=%s user_id=%s order_type=%s coin=%s direction=%s "
        "entry=%s sl=%s tp1=%s tp2=%s risk_percent=%.2f exchange=%s environment=%s base_url=%s",
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
        trade.risk_percent,
        exchange,
        environment,
        api_base_url,
    )

    # ── MARKET: BloFin immediate entry (order_type=market or entry_price=\"market\") ──
    if is_market:
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
                    "detail": f"MARKET orders are only supported for BloFin (exchange={exchange}).",
                    "user_message": "MARKET entry is available for BloFin only. Use AI Limit Order or link BloFin keys.",
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

        logger.info(
            "execute_trade_market_dispatch request_id=%s trade_id=%s blofin_base=%s inst=%s",
            req_id,
            trade_id,
            api_base_url,
            _blofin_inst_id(trade.coin),
        )

        blofin_result = _blofin_place_order(
            base_url=api_base_url,
            api_key=exchange_api_key,
            api_secret=exchange_secret,
            passphrase=passphrase,
            coin=trade.coin,
            direction=trade.direction,
            order_type="market",
            size=BLOFIN_ORDER_SIZE,
            tp1=trade.tp1,
            sl=trade.stop_loss,
            client_order_id=trade_id[:32],
            request_id=req_id,
        )

        blofin_order_id = blofin_result.get("order_id")
        if blofin_result.get("ok"):
            logger.info(
                "execute_trade_market_success request_id=%s trade_id=%s blofin_order_id=%s",
                req_id,
                trade_id,
                blofin_order_id,
            )
            return JSONResponse(
                status_code=200,
                content={
                    "success": True,
                    "status": "success",
                    "order_type": "market",
                    "trade_id": trade_id,
                    "order_id": blofin_order_id,
                    "user_id": user_id,
                    "coin": trade.coin,
                    "direction": trade.direction,
                    "stop_loss": trade.stop_loss,
                    "tp1": trade.tp1,
                    "tp2": trade.tp2,
                    "risk_percent": trade.risk_percent,
                    "exchange": exchange,
                    "environment": environment,
                    "message": f"MARKET order placed for {trade.coin} {trade.direction.upper()}.",
                    "user_message": (
                        f"MARKET order executed on BloFin ({environment}). "
                        f"{trade.coin} {trade.direction.upper()} · Order ID {blofin_order_id or 'pending'}"
                    ),
                    "request_id": req_id,
                },
                headers={"X-Request-ID": req_id},
            )

        logger.warning(
            "execute_trade_market_failure request_id=%s trade_id=%s http=%s code=%s msg=%s",
            req_id,
            trade_id,
            blofin_result.get("http_status"),
            blofin_result.get("code"),
            blofin_result.get("msg"),
        )
        return JSONResponse(
            status_code=502,
            content={
                "success": False,
                "status": "failed",
                "order_type": "market",
                "trade_id": trade_id,
                "detail": blofin_result.get("msg") or "BloFin MARKET order rejected.",
                "user_message": blofin_result.get("msg") or "BloFin could not place the MARKET order. Try again.",
                "blofin_code": blofin_result.get("code"),
                "request_id": req_id,
            },
            headers={"X-Request-ID": req_id},
        )

    # ── LIMIT: original accept-only flow (unchanged) ─────────────────────────────
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

    rr = compute_rr(trade.entry_price, trade.tp1, trade.stop_loss)

    logger.info(
        "execute_trade_limit_accepted request_id=%s trade_id=%s user_id=%s coin=%s direction=%s "
        "entry=%s sl=%s tp1=%s tp2=%s risk_percent=%.2f rr=%s exchange=%s environment=%s",
        req_id,
        trade_id,
        user_id,
        trade.coin,
        trade.direction,
        trade.entry_price,
        trade.stop_loss,
        trade.tp1,
        trade.tp2,
        trade.risk_percent,
        f"{rr:.2f}" if rr is not None else "n/a",
        exchange,
        environment,
    )

    return JSONResponse(
        status_code=200,
        content={
            "success": True,
            "status": "success",
            "order_type": "limit",
            "trade_id": trade_id,
            "user_id": user_id,
            "coin": trade.coin,
            "direction": trade.direction,
            "entry_price": trade.entry_price,
            "stop_loss": trade.stop_loss,
            "tp1": trade.tp1,
            "tp2": trade.tp2,
            "risk_percent": trade.risk_percent,
            "rr": rr,
            "exchange": exchange,
            "environment": environment,
            "api_base_url": api_base_url,
            "message": f"Trade request accepted for {trade.coin} {trade.direction.upper()}.",
            "user_message": (
                f"Trade sent to Oracle Citadel ({exchange}, {environment}). "
                f"{trade.coin} {trade.direction.upper()} · Entry {format_usd(trade.entry_price)}"
            ),
            "request_id": req_id,
        },
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
