"""
Oracle Citadel — Bitunix futures REST adapter (live network).

Auth: double SHA256 per https://www.bitunix.com/api-docs/futures/common/sign.html
"""
from __future__ import annotations

import hashlib
import json
import logging
import os
import secrets
import time
import urllib.parse
from typing import Any, Optional

import requests
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry

try:
    from curl_cffi import requests as curl_requests

    _HAS_CURL_CFFI = True
except ImportError:
    curl_requests = None  # type: ignore[assignment,misc]
    _HAS_CURL_CFFI = False

logger = logging.getLogger(__name__)

BITUNIX_LIVE_API_BASE_URL = "https://fapi.bitunix.com"
BITUNIX_DEFAULT_LEVERAGE = 5
BITUNIX_MARGIN_COIN = "USDT"
BITUNIX_DEFAULT_QTY = "0.001"
BITUNIX_MIN_QTY = 0.001
BITUNIX_QTY_STEP = 0.001

BITUNIX_ACCOUNT_PATH = "/api/v1/futures/account"
BITUNIX_CHANGE_LEVERAGE_PATH = "/api/v1/futures/account/change_leverage"
BITUNIX_PLACE_ORDER_PATH = "/api/v1/futures/trade/place_order"
BITUNIX_ORDER_DETAIL_PATH = "/api/v1/futures/trade/get_order_detail"
BITUNIX_POSITIONS_PATH = "/api/v1/futures/position/get_pending_positions"
BITUNIX_FLASH_CLOSE_PATH = "/api/v1/futures/trade/flash_close_position"

BITUNIX_POST_ORDER_CONFIRM_DELAY_SEC = 1.5
BITUNIX_FILL_CONFIRM_MAX_POLLS = 6
BITUNIX_FILL_CONFIRM_POLL_SEC = 0.6

_BITUNIX_USER_AGENT = (
    os.getenv("BITUNIX_USER_AGENT")
    or "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
)
_BITUNIX_CURL_IMPERSONATE = (os.getenv("BITUNIX_CURL_IMPERSONATE") or "chrome124").strip()


def _bitunix_session() -> requests.Session:
    session = requests.Session()
    retry = Retry(
        total=2,
        connect=2,
        read=2,
        backoff_factor=0.4,
        status_forcelist=(429, 500, 502, 503, 504),
        allowed_methods=frozenset({"GET", "POST"}),
    )
    adapter = HTTPAdapter(max_retries=retry)
    session.mount("https://", adapter)
    session.headers.update(
        {
            "Accept": "application/json",
            "Accept-Language": "en-US,en;q=0.9",
            "User-Agent": _BITUNIX_USER_AGENT,
        }
    )
    return session


_BITUNIX_HTTP = _bitunix_session()


def bitunix_symbol(coin: str) -> str:
    c = (coin or "BTC").strip().upper().replace("-", "").replace("/", "")
    if c.endswith("USDT"):
        return c
    return f"{c}USDT"


def _canonical_json(body: dict[str, Any]) -> str:
    # Bitunix signature requires sorted keys and no spaces (official docs + community libs).
    return json.dumps(body, separators=(",", ":"), ensure_ascii=False, sort_keys=True)


def is_waf_or_ip_block(code: Any, msg: Optional[str], http_status: Optional[int] = None) -> bool:
    text = (msg or "").lower()
    raw = msg or ""
    if "1010" in raw or "cloudflare" in text or "waf" in text or "firewall" in text:
        return True
    if str(code or "") == "10004" or ("ip" in text and "whitelist" in text):
        return True
    if http_status in {403, 503} and ("blocked" in text or "denied" in text or "access denied" in text):
        return True
    if str(code or "") == "invalid_json" and ("cloudflare" in text or "firewall" in text or "1010" in raw):
        return True
    return False


def _format_api_error(raw: str, http_status: int) -> str:
    text = (raw or "").strip()
    if not text:
        return f"Bitunix API returned an empty response (HTTP {http_status})."
    if text.startswith("{"):
        try:
            parsed = json.loads(text)
            if isinstance(parsed, dict):
                return user_friendly_error(parsed.get("code"), parsed.get("msg") or parsed.get("message"))
        except json.JSONDecodeError:
            pass
    lower = text.lower()
    if "1010" in text or "cloudflare" in lower:
        return (
            "Bitunix Cloudflare blocked this server (error 1010). "
            "Remove ALL IPs from your Bitunix API key (IP binding is broken on Bitunix for cloud servers). "
            "If it still fails, email Bitunix support to allowlist Oracle Citadel / Railway server traffic."
        )
    if http_status == 403:
        return "Bitunix denied the request (HTTP 403). Check Trade permission and IP whitelist on your API key."
    if http_status == 401:
        return "Bitunix rejected API credentials (HTTP 401). Check API Key and Secret."
    return f"Bitunix error (HTTP {http_status}): {text[:240]}"


def _query_params_string(params: dict[str, Any]) -> str:
    if not params:
        return ""
    items = sorted((str(k), str(v)) for k, v in params.items())
    return "".join(f"{k}{v}" for k, v in items)


def _sign_headers(
    *,
    api_key: str,
    api_secret: str,
    method: str,
    query_params: str,
    body_str: str,
) -> dict[str, str]:
    nonce = secrets.token_hex(16)
    timestamp = str(int(time.time() * 1000))
    digest_input = f"{nonce}{timestamp}{api_key}{query_params}{body_str}"
    digest = hashlib.sha256(digest_input.encode("utf-8")).hexdigest()
    sign = hashlib.sha256((digest + api_secret).encode("utf-8")).hexdigest()
    return {
        "api-key": api_key,
        "nonce": nonce,
        "timestamp": timestamp,
        "sign": sign,
        "Content-Type": "application/json",
        "language": "en-US",
    }


def _private_request(
    *,
    base_url: str,
    api_key: str,
    api_secret: str,
    method: str,
    path: str,
    query: Optional[dict[str, Any]] = None,
    body: Optional[dict[str, Any]] = None,
    request_id: str = "?",
    log_tag: str = "bitunix",
) -> tuple[int, str, Optional[dict[str, Any]]]:
    query = query or {}
    body_str = _canonical_json(body) if body else ""
    query_str = _query_params_string(query)
    headers = _sign_headers(
        api_key=api_key,
        api_secret=api_secret,
        method=method.upper(),
        query_params=query_str,
        body_str=body_str,
    )
    url = f"{base_url.rstrip('/')}{path}"
    if query:
        url = f"{url}?{urllib.parse.urlencode(query)}"

    try:
        browser_headers = {
            "Accept": "application/json, text/plain, */*",
            "Accept-Language": "en-US,en;q=0.9",
            "Origin": "https://www.bitunix.com",
            "Referer": "https://www.bitunix.com/",
            "User-Agent": _BITUNIX_USER_AGENT,
        }
        merged_headers = {**browser_headers, **headers}
        payload = body_str.encode("utf-8") if body_str else None

        if _HAS_CURL_CFFI and curl_requests is not None:
            response = curl_requests.request(
                method.upper(),
                url,
                headers=merged_headers,
                data=payload,
                timeout=30,
                impersonate=_BITUNIX_CURL_IMPERSONATE,
            )
        else:
            response = _BITUNIX_HTTP.request(
                method.upper(),
                url,
                headers=merged_headers,
                data=payload,
                timeout=30,
            )
        raw = response.text or ""
        parsed: Optional[dict[str, Any]] = None
        if raw:
            try:
                loaded = json.loads(raw)
                if isinstance(loaded, dict):
                    parsed = loaded
            except json.JSONDecodeError:
                parsed = None
        if response.status_code >= 400 or (
            isinstance(parsed, dict)
            and parsed.get("code") is not None
            and str(parsed.get("code")) != "0"
        ):
            logger.warning(
                "%s_http request_id=%s status=%s path=%s code=%s body=%s",
                log_tag,
                request_id,
                response.status_code,
                path,
                parsed.get("code") if isinstance(parsed, dict) else None,
                (raw or "")[:500],
            )
        return response.status_code, raw, parsed
    except requests.RequestException as exc:
        logger.warning("%s_request_failed request_id=%s path=%s err=%s", log_tag, request_id, path, exc)
        return 0, str(exc), None


def user_friendly_error(code: Any, msg: Optional[str]) -> str:
    text = (msg or "").strip()
    if text.lower().startswith("bitunix"):
        return text
    code_s = str(code) if code is not None else ""
    lower = text.lower()
    if is_waf_or_ip_block(code, msg):
        return (
            "Bitunix Cloudflare blocked this server (error 1010). "
            "Remove ALL IPs from your Bitunix API key — IP binding breaks cloud/server API access. "
            "Re-save keys in Citadel Setup after clearing IP binding."
        )
    if code_s == "10004" or "current ip is not in" in lower:
        return (
            "Bitunix rejected this server IP (code 10004). "
            "Add all Railway static outbound IPs to your Bitunix API key whitelist."
        )
    if code_s == "10007" or "signature" in lower:
        return "Bitunix rejected the API signature. Check API Key and Secret."
    if "permission" in text.lower() or code_s == "10003":
        return "Bitunix API key lacks Trade permission. Enable Trading API on your key."
    if text:
        return f"Bitunix: {text}"
    return "Bitunix API request failed. Check keys and try again."


def fetch_position_mode(
    *,
    api_key: str,
    api_secret: str,
    request_id: str = "?",
) -> str:
    http_status, raw, parsed = _private_request(
        base_url=BITUNIX_LIVE_API_BASE_URL,
        api_key=api_key,
        api_secret=api_secret,
        method="GET",
        path=BITUNIX_ACCOUNT_PATH,
        query={"marginCoin": BITUNIX_MARGIN_COIN},
        request_id=request_id,
        log_tag="bitunix_position_mode",
    )
    if not isinstance(parsed, dict) or http_status != 200 or str(parsed.get("code")) != "0":
        return "HEDGE"
    data = parsed.get("data")
    rows = data if isinstance(data, list) else [data] if isinstance(data, dict) else []
    for row in rows:
        if isinstance(row, dict):
            mode = str(row.get("positionMode") or "").upper()
            if mode in {"ONE_WAY", "HEDGE"}:
                return mode
    return "HEDGE"


def verify_credentials(
    *,
    api_key: str,
    api_secret: str,
    request_id: str = "?",
) -> dict[str, Any]:
    http_status, raw, parsed = _private_request(
        base_url=BITUNIX_LIVE_API_BASE_URL,
        api_key=api_key,
        api_secret=api_secret,
        method="GET",
        path=BITUNIX_ACCOUNT_PATH,
        query={"marginCoin": BITUNIX_MARGIN_COIN},
        request_id=request_id,
        log_tag="bitunix_verify",
    )
    if not isinstance(parsed, dict):
        return {
            "ok": False,
            "http_status": http_status,
            "code": None,
            "msg": _format_api_error(raw or "", http_status),
        }
    code = parsed.get("code")
    ok = http_status == 200 and str(code) == "0"
    return {
        "ok": ok,
        "http_status": http_status,
        "code": code,
        "msg": parsed.get("msg") if isinstance(parsed, dict) else "Invalid response",
    }


def fetch_available_usdt(
    *,
    api_key: str,
    api_secret: str,
    request_id: str = "?",
) -> Optional[float]:
    http_status, _raw, parsed = _private_request(
        base_url=BITUNIX_LIVE_API_BASE_URL,
        api_key=api_key,
        api_secret=api_secret,
        method="GET",
        path=BITUNIX_ACCOUNT_PATH,
        query={"marginCoin": BITUNIX_MARGIN_COIN},
        request_id=request_id,
        log_tag="bitunix_balance",
    )
    if not isinstance(parsed, dict) or http_status != 200 or str(parsed.get("code")) != "0":
        return None
    data = parsed.get("data")
    rows = data if isinstance(data, list) else [data] if isinstance(data, dict) else []
    for row in rows:
        if not isinstance(row, dict):
            continue
        try:
            return float(row.get("available") or 0)
        except (TypeError, ValueError):
            continue
    return None


def _format_qty(qty: float) -> str:
    steps = max(1, int(qty / BITUNIX_QTY_STEP))
    val = steps * BITUNIX_QTY_STEP
    return f"{val:.3f}".rstrip("0").rstrip(".") or BITUNIX_DEFAULT_QTY


def calculate_order_size(
    *,
    entry_price: float,
    stop_loss: float,
    risk_percent: float,
    leverage: float,
    api_key: str,
    api_secret: str,
    request_id: str = "?",
) -> tuple[str, dict[str, Any]]:
    available = fetch_available_usdt(api_key=api_key, api_secret=api_secret, request_id=request_id)
    risk_frac = max(0.1, min(float(risk_percent), 100.0)) / 100.0
    lev = max(1.0, float(leverage))
    entry = max(float(entry_price), 1e-9)
    stop_dist = abs(entry - float(stop_loss))
    if stop_dist <= 0:
        stop_dist = entry * 0.01
    if available and available > 0:
        risk_usd = available * risk_frac
        notional = risk_usd * lev / (stop_dist / entry)
        qty = notional / entry
        qty = max(BITUNIX_MIN_QTY, qty)
        meta = {"source": "balance", "available_usdt": available, "risk_usd": risk_usd}
        return _format_qty(qty), meta
    return BITUNIX_DEFAULT_QTY, {"source": "fallback", "available_usdt": available}


def dual_tp_sizes(total_qty: str) -> tuple[str, str]:
    try:
        total = float(total_qty)
    except (TypeError, ValueError):
        total = BITUNIX_MIN_QTY
    if total < BITUNIX_MIN_QTY * 2:
        half = max(BITUNIX_MIN_QTY, total / 2.0)
        return _format_qty(half), _format_qty(max(BITUNIX_MIN_QTY, total - half))
    tp1 = total * 0.4
    tp2 = max(BITUNIX_MIN_QTY, total - tp1)
    return _format_qty(tp1), _format_qty(tp2)


def set_leverage(
    *,
    api_key: str,
    api_secret: str,
    coin: str,
    leverage: float,
    request_id: str = "?",
) -> dict[str, Any]:
    symbol = bitunix_symbol(coin)
    body = {
        "symbol": symbol,
        "marginCoin": BITUNIX_MARGIN_COIN,
        "leverage": int(max(1, min(leverage, 125))),
    }
    http_status, _raw, parsed = _private_request(
        base_url=BITUNIX_LIVE_API_BASE_URL,
        api_key=api_key,
        api_secret=api_secret,
        method="POST",
        path=BITUNIX_CHANGE_LEVERAGE_PATH,
        body=body,
        request_id=request_id,
        log_tag="bitunix_set_leverage",
    )
    ok = http_status == 200 and isinstance(parsed, dict) and str(parsed.get("code")) == "0"
    return {
        "ok": ok,
        "http_status": http_status,
        "code": parsed.get("code") if isinstance(parsed, dict) else None,
        "msg": parsed.get("msg") if isinstance(parsed, dict) else None,
        "symbol": symbol,
    }


def _open_side(direction: str) -> tuple[str, str]:
    d = direction.strip().lower()
    if d == "short":
        return "SELL", "OPEN"
    return "BUY", "OPEN"


def _close_side(direction: str) -> tuple[str, str]:
    d = direction.strip().lower()
    if d == "short":
        return "BUY", "CLOSE"
    return "SELL", "CLOSE"


def place_order(
    *,
    api_key: str,
    api_secret: str,
    coin: str,
    direction: str,
    order_type: str,
    qty: str,
    price: Optional[str] = None,
    sl: Optional[float] = None,
    client_id: Optional[str] = None,
    reduce_only: bool = False,
    trade_side: Optional[str] = None,
    position_mode: Optional[str] = None,
    request_id: str = "?",
) -> dict[str, Any]:
    symbol = bitunix_symbol(coin)
    mode = (position_mode or "HEDGE").upper()
    if trade_side:
        side = "BUY" if direction.lower() == "long" and trade_side == "OPEN" else (
            "SELL" if direction.lower() == "short" and trade_side == "OPEN" else _close_side(direction)[0]
        )
        ts = trade_side
    elif reduce_only:
        side, ts = _close_side(direction)
    else:
        side, ts = _open_side(direction)

    body: dict[str, Any] = {
        "symbol": symbol,
        "qty": str(qty),
        "side": side,
        "orderType": "MARKET" if order_type.lower() == "market" else "LIMIT",
    }
    if mode == "HEDGE":
        body["tradeSide"] = ts
    if reduce_only:
        body["reduceOnly"] = True
    if client_id:
        body["clientId"] = client_id[:32]
    if body["orderType"] == "LIMIT" and price is not None:
        body["price"] = str(price)
        body["effect"] = "GTC"
    if sl is not None and not reduce_only:
        body["slPrice"] = str(sl)
        body["slStopType"] = "MARK_PRICE"
        body["slOrderType"] = "MARKET"

    http_status, raw, parsed = _private_request(
        base_url=BITUNIX_LIVE_API_BASE_URL,
        api_key=api_key,
        api_secret=api_secret,
        method="POST",
        path=BITUNIX_PLACE_ORDER_PATH,
        body=body,
        request_id=request_id,
        log_tag="bitunix_place_order",
    )
    if not isinstance(parsed, dict):
        return {
            "ok": False,
            "http_status": http_status,
            "code": "invalid_json",
            "msg": _format_api_error(raw or "", http_status),
            "order_id": None,
            "raw_preview": (raw or "")[:500],
        }
    data = parsed.get("data") if isinstance(parsed.get("data"), dict) else {}
    order_id = data.get("orderId")
    ok = http_status == 200 and str(parsed.get("code")) == "0" and bool(order_id)
    return {
        "ok": ok,
        "http_status": http_status,
        "code": parsed.get("code"),
        "msg": parsed.get("msg"),
        "order_id": str(order_id) if order_id else None,
        "response": parsed,
        "body": body,
    }


def fetch_order_detail(
    *,
    api_key: str,
    api_secret: str,
    order_id: str,
    request_id: str = "?",
) -> dict[str, Any]:
    http_status, _raw, parsed = _private_request(
        base_url=BITUNIX_LIVE_API_BASE_URL,
        api_key=api_key,
        api_secret=api_secret,
        method="GET",
        path=BITUNIX_ORDER_DETAIL_PATH,
        query={"orderId": order_id},
        request_id=request_id,
        log_tag="bitunix_order_detail",
    )
    if not isinstance(parsed, dict) or http_status != 200 or str(parsed.get("code")) != "0":
        return {}
    data = parsed.get("data")
    return data if isinstance(data, dict) else {}


def confirm_order_fill(
    *,
    api_key: str,
    api_secret: str,
    order_id: str,
    request_id: str = "?",
) -> dict[str, Any]:
    time.sleep(BITUNIX_POST_ORDER_CONFIRM_DELAY_SEC)
    for attempt in range(1, BITUNIX_FILL_CONFIRM_MAX_POLLS + 1):
        row = fetch_order_detail(
            api_key=api_key,
            api_secret=api_secret,
            order_id=order_id,
            request_id=request_id,
        )
        status = str(row.get("status") or "").upper()
        try:
            trade_qty = float(row.get("tradeQty") or 0)
        except (TypeError, ValueError):
            trade_qty = 0.0
        if status == "FILLED" or trade_qty > 0:
            return {
                "ok": True,
                "filled_size": str(trade_qty or row.get("qty") or ""),
                "status": status,
                "row": row,
            }
        if attempt < BITUNIX_FILL_CONFIRM_MAX_POLLS:
            time.sleep(BITUNIX_FILL_CONFIRM_POLL_SEC)
    return {"ok": False, "filled_size": "0", "status": "timeout", "row": {}}


def confirm_limit_order(
    *,
    api_key: str,
    api_secret: str,
    order_id: str,
    request_id: str = "?",
) -> dict[str, Any]:
    time.sleep(BITUNIX_POST_ORDER_CONFIRM_DELAY_SEC)
    row = fetch_order_detail(
        api_key=api_key,
        api_secret=api_secret,
        order_id=order_id,
        request_id=request_id,
    )
    status = str(row.get("status") or "").upper()
    try:
        trade_qty = float(row.get("tradeQty") or 0)
    except (TypeError, ValueError):
        trade_qty = 0.0
    avg_price = row.get("avgPrice") or row.get("price")
    resting_states = {"NEW", "PENDING", "INIT", "PARTIAL_FILLED", "PART_FILLED"}
    if status == "FILLED" or trade_qty > 0:
        return {
            "limit_ok": True,
            "limit_status": "filled",
            "filled_size": str(trade_qty or row.get("qty") or ""),
            "average_price": avg_price,
            "status": status,
            "row": row,
        }
    if status in resting_states or row:
        return {
            "limit_ok": True,
            "limit_status": "resting",
            "filled_size": "0",
            "average_price": avg_price,
            "status": status,
            "row": row,
        }
    return {"limit_ok": False, "limit_status": "unknown", "filled_size": "0", "status": status, "row": row}


def place_tp_close_order(
    *,
    api_key: str,
    api_secret: str,
    coin: str,
    direction: str,
    qty: str,
    tp_price: float,
    client_id: Optional[str] = None,
    position_mode: Optional[str] = None,
    request_id: str = "?",
) -> dict[str, Any]:
    side, trade_side = _close_side(direction)
    mode = (position_mode or "HEDGE").upper()
    body: dict[str, Any] = {
        "symbol": bitunix_symbol(coin),
        "qty": str(qty),
        "side": side,
        "orderType": "LIMIT",
        "price": str(tp_price),
        "effect": "GTC",
        "reduceOnly": True,
    }
    if mode == "HEDGE":
        body["tradeSide"] = trade_side
    if client_id:
        body["clientId"] = client_id[:32]
    http_status, raw, parsed = _private_request(
        base_url=BITUNIX_LIVE_API_BASE_URL,
        api_key=api_key,
        api_secret=api_secret,
        method="POST",
        path=BITUNIX_PLACE_ORDER_PATH,
        body=body,
        request_id=request_id,
        log_tag="bitunix_tp_close",
    )
    if not isinstance(parsed, dict):
        return {
            "ok": False,
            "http_status": http_status,
            "code": "invalid_json",
            "msg": _format_api_error(raw or "", http_status),
            "order_id": None,
        }
    ok = http_status == 200 and str(parsed.get("code")) == "0"
    data = parsed.get("data") if isinstance(parsed.get("data"), dict) else {}
    return {
        "ok": ok,
        "http_status": http_status,
        "code": parsed.get("code"),
        "msg": parsed.get("msg"),
        "order_id": data.get("orderId"),
    }


def fetch_positions(
    *,
    api_key: str,
    api_secret: str,
    symbol: Optional[str] = None,
    request_id: str = "?",
) -> list[dict[str, Any]]:
    query: dict[str, Any] = {}
    if symbol:
        query["symbol"] = symbol
    http_status, _raw, parsed = _private_request(
        base_url=BITUNIX_LIVE_API_BASE_URL,
        api_key=api_key,
        api_secret=api_secret,
        method="GET",
        path=BITUNIX_POSITIONS_PATH,
        query=query or None,
        request_id=request_id,
        log_tag="bitunix_positions",
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
            qty = float(row.get("qty") or 0)
        except (TypeError, ValueError):
            qty = 0.0
        if abs(qty) <= 0:
            continue
        sym = str(row.get("symbol") or "")
        side = str(row.get("side") or "LONG").upper()
        direction = "long" if side == "LONG" else "short"
        coin = sym.replace("USDT", "") if sym.endswith("USDT") else sym
        try:
            entry = float(row.get("avgOpenPrice") or row.get("entryValue") or 0)
            upnl = float(row.get("unrealizedPNL") or 0)
            liq = float(row.get("liqPrice") or 0)
            lev = float(row.get("leverage") or 1)
        except (TypeError, ValueError):
            continue
        out.append(
            {
                "positionId": str(row.get("positionId") or ""),
                "instId": sym,
                "coin": coin,
                "direction": direction,
                "entryPrice": entry,
                "markPrice": entry,
                "size": abs(qty),
                "leverage": lev,
                "unrealizedPnl": upnl,
                "unrealizedPnlPct": 0.0,
                "liquidationPrice": liq,
                "marginMode": str(row.get("marginMode") or "CROSS").lower(),
                "positionSide": side.lower(),
            }
        )
    return out


def flash_close_position(
    *,
    api_key: str,
    api_secret: str,
    position_id: str,
    request_id: str = "?",
) -> dict[str, Any]:
    body = {"positionId": str(position_id)}
    http_status, _raw, parsed = _private_request(
        base_url=BITUNIX_LIVE_API_BASE_URL,
        api_key=api_key,
        api_secret=api_secret,
        method="POST",
        path=BITUNIX_FLASH_CLOSE_PATH,
        body=body,
        request_id=request_id,
        log_tag="bitunix_flash_close",
    )
    ok = http_status == 200 and isinstance(parsed, dict) and str(parsed.get("code")) == "0"
    return {
        "ok": ok,
        "http_status": http_status,
        "code": parsed.get("code") if isinstance(parsed, dict) else None,
        "msg": parsed.get("msg") if isinstance(parsed, dict) else None,
    }
