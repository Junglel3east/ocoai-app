"""Optional background price watcher — free Binance ticks + FCM if FCM_SERVER_KEY is set."""

from __future__ import annotations

import json
import logging
import os
import time
from pathlib import Path
from typing import Any

import requests

logger = logging.getLogger("oco.alerts")

_STORE = Path(os.getenv("ALERT_WATCH_FILE", "/tmp/oco_alert_watch.json"))
_FCM_KEY = (os.getenv("FCM_SERVER_KEY") or "").strip()
_BINANCE = "https://api.binance.com/api/v3/ticker/price"


def _load() -> dict[str, Any]:
    try:
        if _STORE.exists():
            return json.loads(_STORE.read_text(encoding="utf-8"))
    except Exception as exc:
        logger.warning("alert_store_read_failed err=%s", exc)
    return {"users": {}}


def _save(store: dict[str, Any]) -> None:
    try:
        _STORE.write_text(json.dumps(store), encoding="utf-8")
    except Exception as exc:
        logger.warning("alert_store_write_failed err=%s", exc)


def upsert_watch(token: str, levels: list[dict[str, Any]], mute_all: bool) -> None:
    if not token or mute_all:
        return
    store = _load()
    users = store.setdefault("users", {})
    existing = users.get(token, {})
    fired = set(existing.get("fired") or [])
    users[token] = {
        "levels": levels,
        "fired": list(fired),
        "updated_at": int(time.time()),
    }
    _save(store)


def _binance_prices(coins: set[str]) -> dict[str, float]:
    if not coins:
        return {}
    try:
        res = requests.get(_BINANCE, timeout=12)
        res.raise_for_status()
        rows = res.json()
    except Exception as exc:
        logger.warning("alert_binance_fail err=%s", exc)
        return {}
    want = {f"{c}USDT": c for c in coins}
    out: dict[str, float] = {}
    if not isinstance(rows, list):
        return out
    for row in rows:
        if not isinstance(row, dict):
            continue
        coin = want.get(str(row.get("symbol") or ""))
        if not coin:
            continue
        try:
            price = float(row.get("price") or 0)
        except (TypeError, ValueError):
            continue
        if price > 0:
            out[coin] = price
    return out


def _send_fcm(token: str, title: str, body: str, data: dict[str, str]) -> None:
    if not _FCM_KEY:
        logger.info("alert_hit_no_fcm title=%s (set FCM_SERVER_KEY for push when app is closed)", title)
        return
    payload = {
        "to": token,
        "priority": "high",
        "notification": {"title": title, "body": body},
        "data": data,
    }
    try:
        res = requests.post(
            "https://fcm.googleapis.com/fcm/send",
            headers={"Authorization": f"key={_FCM_KEY}", "Content-Type": "application/json"},
            json=payload,
            timeout=10,
        )
        if res.status_code >= 300:
            logger.warning("alert_fcm_http status=%s body=%s", res.status_code, res.text[:200])
    except Exception as exc:
        logger.warning("alert_fcm_fail err=%s", exc)


def evaluate_once() -> int:
    store = _load()
    users = store.get("users") or {}
    if not users:
        return 0
    coins: set[str] = set()
    for row in users.values():
        for level in row.get("levels") or []:
            coin = str(level.get("coin") or "").upper()
            if coin:
                coins.add(coin)
    prices = _binance_prices(coins)
    if not prices:
        return 0
    hits = 0
    now = int(time.time())
    stale_before = now - 86400 * 3
    for token, row in list(users.items()):
        if int(row.get("updated_at") or 0) < stale_before:
            users.pop(token, None)
            continue
        fired = set(row.get("fired") or [])
        for level in row.get("levels") or []:
            lid = str(level.get("id") or "")
            coin = str(level.get("coin") or "").upper()
            op = str(level.get("op") or "above")
            try:
                target = float(level.get("price") or 0)
            except (TypeError, ValueError):
                continue
            price = prices.get(coin)
            if not lid or not coin or target <= 0 or price is None:
                continue
            if lid in fired:
                continue
            hit = False
            if op == "above":
                hit = price >= target
            elif op == "below":
                hit = price <= target
            elif op == "touch":
                hit = abs(price - target) / target <= 0.0015
            if not hit:
                continue
            fired.add(lid)
            hits += 1
            _send_fcm(
                token,
                f"{coin} alert",
                f"{coin} {op} {target:g} (now {price:g})",
                {"type": "alertHit", "coin": coin, "open": "alerts", "level": lid},
            )
        row["fired"] = list(fired)
    _save(store)
    return hits


async def watcher_loop() -> None:
    logger.info("alert_watcher started fcm=%s", bool(_FCM_KEY))
    while True:
        try:
            evaluate_once()
        except Exception as exc:
            logger.exception("alert_watcher_tick err=%s", exc)
        await __import__("asyncio").sleep(20)
