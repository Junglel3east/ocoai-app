"""
CoinGecko Pro service — On-Chain Oracle AI.

A small, self-contained, reusable wrapper around the CoinGecko API tuned for a
**paid Pro plan**. It is imported by api.py; it never imports from api.py, so it
can be reused/tested in isolation.

Design goals (paid-plan optimization):
  * Always authenticate Pro calls with the `x-cg-pro-api-key` header and hit the
    Pro host (`pro-api.coingecko.com`). Falls back to the public host only when
    no Pro key is configured.
  * Spend credits efficiently: prefer ONE rich `/coins/markets` call (which
    returns multi-timeframe momentum, volume, market cap, 24h hi/lo for up to
    250 coins) over many `/simple/price` calls, and reuse those rows via a very
    short in-memory cache.
  * Maximize freshness for trade-critical data: live price lookups use a tiny
    TTL (paid plan supports high request frequency) and an explicit `no_cache`
    path for the pre-AI aggressive pull.
  * Resilience: a shared `requests.Session` with automatic retry/back-off on
    429 (rate limit) and 5xx, honoring `Retry-After`.
  * Observability: structured logging plus lightweight per-endpoint usage
    counters so we can see credit consumption.

Environment variables:
  COINGECKO_PRO_API_KEY        Pro key. When empty, public endpoints are used.
  COINGECKO_TIMEOUT            Per-request timeout seconds (default 20).
  COINGECKO_MAX_RETRIES        Retry attempts for 429/5xx (default 3).
  COINGECKO_LIVE_CACHE_TTL     Live-price cache TTL seconds (default 8).
  COINGECKO_MARKETS_CACHE_TTL  Bulk markets cache TTL seconds (default 30).
"""

from __future__ import annotations

import logging
import os
import threading
import time
from typing import Any, Iterable, Optional, Union

import requests
from requests.adapters import HTTPAdapter

try:  # urllib3 is bundled with requests; import defensively across versions.
    from urllib3.util.retry import Retry
except Exception:  # pragma: no cover
    from requests.packages.urllib3.util.retry import Retry  # type: ignore

logger = logging.getLogger("oracle.coingecko")

# ---------------------------------------------------------------------------
# Config (read lazily where import-order matters, e.g. before load_dotenv)
# ---------------------------------------------------------------------------

PUBLIC_API_BASE = "https://api.coingecko.com/api/v3"
PRO_API_BASE = "https://pro-api.coingecko.com/api/v3"

# Multi-timeframe momentum we always request from /coins/markets for richer AI context.
DEFAULT_PRICE_CHANGE = "1h,24h,7d,30d"

REQUEST_TIMEOUT = float(os.getenv("COINGECKO_TIMEOUT", "20"))
MAX_RETRIES = int(os.getenv("COINGECKO_MAX_RETRIES", "3"))
# Paid plan supports high frequency — keep the live cache very small so
# trade-critical price/volume stays fresh while still de-duping burst polling.
LIVE_CACHE_TTL = float(os.getenv("COINGECKO_LIVE_CACHE_TTL", "8"))
MARKETS_CACHE_TTL = float(os.getenv("COINGECKO_MARKETS_CACHE_TTL", "30"))

_PRO_API_KEY_CACHE: Optional[str] = None


def pro_api_key() -> str:
    """Resolved lazily so it works even if imported before load_dotenv()."""
    global _PRO_API_KEY_CACHE
    if _PRO_API_KEY_CACHE is None:
        _PRO_API_KEY_CACHE = (os.getenv("COINGECKO_PRO_API_KEY") or "").strip()
    return _PRO_API_KEY_CACHE


def is_pro() -> bool:
    return bool(pro_api_key())


def api_base() -> str:
    return PRO_API_BASE if is_pro() else PUBLIC_API_BASE


def source_label() -> str:
    """Canonical `source` tag used across the app's market dicts."""
    return "coingecko_pro" if is_pro() else "coingecko"


def build_headers(*, no_cache: bool = False) -> dict[str, str]:
    headers: dict[str, str] = {"Accept": "application/json"}
    key = pro_api_key()
    if key:
        headers["x-cg-pro-api-key"] = key
    if no_cache:
        headers.update(
            {
                "Cache-Control": "no-cache, no-store, must-revalidate",
                "Pragma": "no-cache",
                "Expires": "0",
            }
        )
    return headers


# ---------------------------------------------------------------------------
# Session with retry/back-off (429 + 5xx, honors Retry-After)
# ---------------------------------------------------------------------------


def _build_session() -> requests.Session:
    session = requests.Session()
    retry = Retry(
        total=MAX_RETRIES,
        connect=MAX_RETRIES,
        read=MAX_RETRIES,
        status=MAX_RETRIES,
        backoff_factor=0.6,  # 0.6s, 1.2s, 2.4s ...
        status_forcelist=(429, 500, 502, 503, 504),
        allowed_methods=frozenset({"GET"}),
        respect_retry_after_header=True,
        raise_on_status=False,
    )
    adapter = HTTPAdapter(max_retries=retry, pool_connections=10, pool_maxsize=20)
    session.mount("https://", adapter)
    session.mount("http://", adapter)
    return session


_SESSION = _build_session()


# ---------------------------------------------------------------------------
# Lightweight usage accounting (credit visibility)
# ---------------------------------------------------------------------------

_usage_lock = threading.Lock()
_usage: dict[str, Any] = {"calls": 0, "ok": 0, "errors": 0, "by_endpoint": {}}


def _record(endpoint: str, ok: bool) -> None:
    with _usage_lock:
        _usage["calls"] += 1
        _usage["ok" if ok else "errors"] += 1
        bucket = _usage["by_endpoint"].setdefault(endpoint, {"calls": 0, "errors": 0})
        bucket["calls"] += 1
        if not ok:
            bucket["errors"] += 1


def usage_stats() -> dict[str, Any]:
    """Snapshot of CoinGecko call counts (for /health or periodic logging)."""
    with _usage_lock:
        return {
            "pro": is_pro(),
            "calls": _usage["calls"],
            "ok": _usage["ok"],
            "errors": _usage["errors"],
            "by_endpoint": {k: dict(v) for k, v in _usage["by_endpoint"].items()},
        }


# ---------------------------------------------------------------------------
# Core request
# ---------------------------------------------------------------------------


def _get(
    path: str,
    params: Optional[dict[str, Any]] = None,
    *,
    no_cache: bool = False,
) -> Optional[requests.Response]:
    """GET {api_base}{path}. Returns the Response on HTTP 200, else None."""
    url = f"{api_base()}{path}"
    started = time.time()
    try:
        resp = _SESSION.get(
            url,
            params=params,
            headers=build_headers(no_cache=no_cache),
            timeout=REQUEST_TIMEOUT,
        )
    except Exception as exc:
        _record(path, False)
        logger.warning("coingecko_request_error path=%s err=%s", path, exc)
        return None

    ok = resp.status_code == 200
    _record(path, ok)
    elapsed_ms = (time.time() - started) * 1000
    if not ok:
        logger.warning(
            "coingecko_http_error path=%s status=%s elapsed_ms=%.0f body=%.180s",
            path,
            resp.status_code,
            elapsed_ms,
            (resp.text or "").replace("\n", " "),
        )
        return None
    logger.debug("coingecko_ok path=%s elapsed_ms=%.0f", path, elapsed_ms)
    return resp


def _f(value: Any) -> Optional[float]:
    try:
        if value is None:
            return None
        return float(value)
    except (TypeError, ValueError):
        return None


# ---------------------------------------------------------------------------
# Normalization
# ---------------------------------------------------------------------------


def normalize_market_row(row: dict[str, Any]) -> dict[str, Any]:
    """Convert a /coins/markets row into the app's standard market dict.

    Preserves the legacy keys (price, change_24h_pct, volume_24h_usd, source,
    coin_id) and adds richer multi-timeframe context for the AI prompt.
    """
    price = _f(row.get("current_price")) or 0.0
    change_24h = row.get("price_change_percentage_24h_in_currency")
    if change_24h is None:
        change_24h = row.get("price_change_percentage_24h")
    return {
        "price": price,
        "change_24h_pct": _f(change_24h) or 0.0,
        "change_1h_pct": _f(row.get("price_change_percentage_1h_in_currency")),
        "change_7d_pct": _f(row.get("price_change_percentage_7d_in_currency")),
        "change_30d_pct": _f(row.get("price_change_percentage_30d_in_currency")),
        "volume_24h_usd": _f(row.get("total_volume")) or 0.0,
        "market_cap_usd": _f(row.get("market_cap")),
        "high_24h": _f(row.get("high_24h")),
        "low_24h": _f(row.get("low_24h")),
        "coin_id": row.get("id"),
        "symbol": str(row.get("symbol") or "").upper(),
        "source": source_label(),
    }


# ---------------------------------------------------------------------------
# Short-TTL live-price cache (keyed by coin id), fed by /coins/markets rows
# ---------------------------------------------------------------------------

_price_cache: dict[str, tuple[float, dict[str, Any]]] = {}
_price_lock = threading.Lock()


def prime_price_cache(rows: Iterable[dict[str, Any]]) -> int:
    """Warm the live-price cache from bulk /coins/markets rows (zero extra calls).

    Lets top-market lookups serve fresh multi-timeframe data without spending
    another credit per coin. Returns the number of rows cached.
    """
    now = time.time()
    count = 0
    with _price_lock:
        for row in rows:
            coin_id = row.get("id") or row.get("coin_id")
            if not coin_id:
                continue
            norm = normalize_market_row(row) if "current_price" in row else dict(row)
            if (norm.get("price") or 0) <= 0:
                continue
            _price_cache[str(coin_id)] = (now, norm)
            count += 1
    return count


def _cache_get(coin_id: str) -> Optional[dict[str, Any]]:
    with _price_lock:
        hit = _price_cache.get(coin_id)
        if hit and (time.time() - hit[0]) < LIVE_CACHE_TTL:
            return dict(hit[1])
    return None


def _cache_put(coin_id: str, market: dict[str, Any]) -> None:
    with _price_lock:
        _price_cache[coin_id] = (time.time(), dict(market))


# ---------------------------------------------------------------------------
# Public fetchers (clean + reusable)
# ---------------------------------------------------------------------------


def fetch_market_data(
    *,
    ids: Optional[Union[str, Iterable[str]]] = None,
    page: int = 1,
    per_page: int = 250,
    vs_currency: str = "usd",
    order: str = "market_cap_desc",
    price_change: str = DEFAULT_PRICE_CHANGE,
    sparkline: bool = False,
    no_cache: bool = False,
) -> list[dict[str, Any]]:
    """`/coins/markets` — the workhorse. One call returns price, 1h/24h/7d/30d
    momentum, volume, market cap and 24h hi/lo for up to 250 coins.

    Returns the raw CoinGecko rows (list). Use `normalize_market_row` to map a
    row into the app's standard market dict.
    """
    params: dict[str, Any] = {
        "vs_currency": vs_currency,
        "order": order,
        "per_page": max(1, min(int(per_page), 250)),
        "page": max(1, int(page)),
        "sparkline": "true" if sparkline else "false",
        "price_change_percentage": price_change,
    }
    if ids:
        params["ids"] = ids if isinstance(ids, str) else ",".join(ids)
    resp = _get("/coins/markets", params, no_cache=no_cache)
    if resp is None:
        return []
    data = resp.json()
    return data if isinstance(data, list) else []


def _fetch_simple_price(coin_id: str, *, no_cache: bool = False) -> Optional[dict[str, Any]]:
    """Minimal `/simple/price` fallback (only when /coins/markets returns nothing)."""
    params: dict[str, Any] = {
        "ids": coin_id,
        "vs_currencies": "usd",
        "include_24hr_change": "true",
        "include_24hr_vol": "true",
    }
    if no_cache:
        params["_"] = str(int(time.time() * 1000))
    resp = _get("/simple/price", params, no_cache=no_cache)
    if resp is None:
        return None
    payload = resp.json().get(coin_id, {})
    price = _f(payload.get("usd")) or 0.0
    if price <= 0:
        return None
    return {
        "price": price,
        "change_24h_pct": _f(payload.get("usd_24h_change")) or 0.0,
        "volume_24h_usd": _f(payload.get("usd_24h_vol")) or 0.0,
        "coin_id": coin_id,
        "source": source_label(),
    }


def fetch_price(coin_id: str, *, no_cache: bool = False) -> Optional[dict[str, Any]]:
    """Fresh single-coin market dict (price + multi-timeframe momentum + volume).

    Uses the short-TTL cache unless `no_cache=True` (used for the pre-AI pull).
    Prefers the rich /coins/markets row; falls back to /simple/price.
    """
    coin_id = (coin_id or "").strip()
    if not coin_id:
        return None

    if not no_cache:
        cached = _cache_get(coin_id)
        if cached is not None:
            return cached

    rows = fetch_market_data(ids=coin_id, per_page=1, no_cache=no_cache)
    if rows:
        norm = normalize_market_row(rows[0])
        if (norm.get("price") or 0) > 0:
            _cache_put(coin_id, norm)
            return norm

    fallback = _fetch_simple_price(coin_id, no_cache=no_cache)
    if fallback is not None:
        _cache_put(coin_id, fallback)
    return fallback


def fetch_price_aggressive(coin_id: str, attempts: int = 2) -> Optional[dict[str, Any]]:
    """Back-to-back cache-busted pulls; returns the latest successful tick.

    Used immediately before AI analysis / trade setup so the price is never a
    stale cached value.
    """
    last: Optional[dict[str, Any]] = None
    for _ in range(max(1, attempts)):
        snap = fetch_price(coin_id, no_cache=True)
        if snap:
            last = snap
    return last


def fetch_ohlc(
    coin_id: str,
    *,
    days: Union[int, str] = 1,
    vs_currency: str = "usd",
) -> list[list[float]]:
    """`/coins/{id}/ohlc` — OHLC candles. Cheaper/cleaner than market_chart when
    only candles are needed. Returns [[ts_ms, o, h, l, c], ...]."""
    coin_id = (coin_id or "").strip()
    if not coin_id:
        return []
    resp = _get(
        f"/coins/{coin_id}/ohlc",
        {"vs_currency": vs_currency, "days": str(days)},
    )
    if resp is None:
        return []
    data = resp.json()
    return data if isinstance(data, list) else []


def fetch_market_chart_range(
    coin_id: str,
    *,
    frm: Union[int, float],
    to: Union[int, float],
    vs_currency: str = "usd",
) -> Optional[dict[str, Any]]:
    """`/coins/{id}/market_chart/range` — historical prices/volumes for a window.

    `frm`/`to` are UNIX seconds. Returns {prices, market_caps, total_volumes}.
    """
    coin_id = (coin_id or "").strip()
    if not coin_id:
        return None
    resp = _get(
        f"/coins/{coin_id}/market_chart/range",
        {"vs_currency": vs_currency, "from": int(frm), "to": int(to)},
    )
    if resp is None:
        return None
    data = resp.json()
    return data if isinstance(data, dict) else None


def fetch_coin_details(
    coin_id: str,
    *,
    market_data: bool = True,
    tickers: bool = False,
) -> Optional[dict[str, Any]]:
    """`/coins/{id}` — full coin metadata (categories, ATH, supply, market data).

    Heavy fields (localization/community/developer/sparkline) are disabled to
    keep the payload small and credit-cheap.
    """
    coin_id = (coin_id or "").strip()
    if not coin_id:
        return None
    resp = _get(
        f"/coins/{coin_id}",
        {
            "localization": "false",
            "tickers": "true" if tickers else "false",
            "market_data": "true" if market_data else "false",
            "community_data": "false",
            "developer_data": "false",
            "sparkline": "false",
        },
    )
    if resp is None:
        return None
    data = resp.json()
    return data if isinstance(data, dict) else None


def search(query: str) -> list[dict[str, Any]]:
    """`/search` — resolve a symbol/name to coin ids."""
    query = (query or "").strip()
    if not query:
        return []
    resp = _get("/search", {"query": query})
    if resp is None:
        return []
    coins = resp.json().get("coins", [])
    return coins if isinstance(coins, list) else []
