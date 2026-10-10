"""Public track record — every published daily setup, graded against real 1h candles.

Grading rules (deliberately conservative so the numbers can't be accused of flattering):
  • A setup only counts once price touches Entry. No touch within NO_FILL_HOURS → "no_fill"
    (excluded from win-rate, shown separately).
  • After fill, if a candle reaches both the stop and a target, the stop is assumed first.
  • Stop is never moved to breakeven: TP1 then stop = +0.4·R1 − 0.6R.
  • TP1 then TP2 = 0.4·R1 + 0.6·R2. Stop before TP1 = −1R.
  • Still open after MAX_OPEN_HOURS → closed at the last candle's close (mark-to-market).
"""

from __future__ import annotations

import json
import logging
import threading
import time
from pathlib import Path
from typing import Any, Callable, Optional

logger = logging.getLogger("oco.track_record")

NO_FILL_HOURS = 72
MAX_OPEN_HOURS = 14 * 24
TP1_WEIGHT = 0.4
TP2_WEIGHT = 0.6

FINAL_STATUSES = {"closed", "no_fill"}

# Candle rows: [open_time_sec, open, high, low, close, volume]
Candle = list[float]


def direction_for(entry: float, sl: float) -> Optional[str]:
    if sl < entry:
        return "long"
    if sl > entry:
        return "short"
    return None


def build_setup(
    *,
    setup_id: str,
    coin: str,
    day: str,
    entry: float,
    tp1: float,
    tp2: float,
    sl: float,
    created_at: float,
    source: str = "daily",
) -> Optional[dict[str, Any]]:
    direction = direction_for(entry, sl)
    if direction is None:
        return None
    # Targets must sit on the profit side of entry, beyond each other.
    if direction == "long" and not (sl < entry < tp1 <= tp2):
        return None
    if direction == "short" and not (sl > entry > tp1 >= tp2):
        return None
    return {
        "id": setup_id,
        "coin": coin.upper(),
        "day": day,
        "source": source,
        "direction": direction,
        "entry": entry,
        "tp1": tp1,
        "tp2": tp2,
        "sl": sl,
        "created_at": created_at,
        "status": "pending",
        "outcome": None,
        "r_multiple": None,
        "tp1_hit": False,
        "filled_at": None,
        "closed_at": None,
    }


def _r_values(setup: dict[str, Any]) -> tuple[float, float, float]:
    entry, sl = setup["entry"], setup["sl"]
    risk = abs(entry - sl)
    r1 = abs(setup["tp1"] - entry) / risk
    r2 = abs(setup["tp2"] - entry) / risk
    return risk, r1, r2


def _close(setup: dict[str, Any], outcome: str, r: float, at: float) -> dict[str, Any]:
    setup.update({"status": "closed", "outcome": outcome, "r_multiple": round(r, 3), "closed_at": at})
    return setup


def evaluate_setup(setup: dict[str, Any], candles: list[Candle], *, now: Optional[float] = None) -> dict[str, Any]:
    """Advance a setup through its candles. Pure: returns an updated copy."""
    s = dict(setup)
    if s.get("status") in FINAL_STATUSES:
        return s
    now = now if now is not None else time.time()
    long = s["direction"] == "long"
    entry, tp1, tp2, sl = s["entry"], s["tp1"], s["tp2"], s["sl"]
    _risk, r1, r2 = _r_values(s)
    last_close: Optional[float] = None
    last_time: Optional[float] = None

    for row in sorted(candles, key=lambda c: c[0]):
        t, _o, high, low, close = row[0], row[1], row[2], row[3], row[4]
        if t < s["created_at"]:
            continue
        last_close, last_time = close, t + 3600

        just_filled = False
        if s["status"] == "pending":
            if t >= s["created_at"] + NO_FILL_HOURS * 3600:
                s.update({"status": "no_fill", "outcome": "no_fill", "closed_at": t})
                return s
            if not (low <= entry <= high):
                continue
            s.update({"status": "open", "filled_at": t})
            just_filled = True

        # On the fill candle the order of wicks is unknown: count the stop, never the targets.
        stop_hit = low <= sl if long else high >= sl
        tp1_reached = not just_filled and (high >= tp1 if long else low <= tp1)
        tp2_reached = not just_filled and (high >= tp2 if long else low <= tp2)

        if stop_hit:
            if s["tp1_hit"]:
                return _close(s, "tp1_then_stop", TP1_WEIGHT * r1 - TP2_WEIGHT, t)
            return _close(s, "stopped", -1.0, t)
        if tp1_reached and not s["tp1_hit"]:
            s["tp1_hit"] = True
        if s["tp1_hit"] and tp2_reached:
            return _close(s, "tp2", TP1_WEIGHT * r1 + TP2_WEIGHT * r2, t)

        if s["filled_at"] is not None and t >= s["filled_at"] + MAX_OPEN_HOURS * 3600:
            break

    if s["status"] == "pending":
        if now >= s["created_at"] + NO_FILL_HOURS * 3600:
            s.update({"status": "no_fill", "outcome": "no_fill", "closed_at": now})
        return s

    if (
        s["filled_at"] is not None
        and last_close is not None
        and last_time is not None
        and last_time >= s["filled_at"] + MAX_OPEN_HOURS * 3600
    ):
        risk = abs(entry - sl)
        mtm = ((last_close - entry) if long else (entry - last_close)) / risk
        r = TP1_WEIGHT * r1 + TP2_WEIGHT * mtm if s["tp1_hit"] else mtm
        return _close(s, "expired", r, last_time)
    return s


def summarize(setups: list[dict[str, Any]], *, since: Optional[float] = None) -> dict[str, Any]:
    rows = [s for s in setups if since is None or s.get("created_at", 0) >= since]
    closed = [s for s in rows if s.get("status") == "closed"]
    wins = [s for s in closed if (s.get("r_multiple") or 0) > 0]
    tp1_hits = [s for s in closed if s.get("tp1_hit")]
    tp2_hits = [s for s in closed if s.get("outcome") == "tp2"]
    total_r = sum(float(s.get("r_multiple") or 0) for s in closed)
    n = len(closed)
    return {
        "closed": n,
        "open": sum(1 for s in rows if s.get("status") in {"open"}),
        "pending": sum(1 for s in rows if s.get("status") == "pending"),
        "no_fill": sum(1 for s in rows if s.get("status") == "no_fill"),
        "wins": len(wins),
        "losses": n - len(wins),
        "win_rate": round(len(wins) / n, 4) if n else None,
        "tp1_hit_rate": round(len(tp1_hits) / n, 4) if n else None,
        "tp2_hit_rate": round(len(tp2_hits) / n, 4) if n else None,
        "total_r": round(total_r, 2),
        "avg_r": round(total_r / n, 3) if n else None,
    }


class TrackRecordStore:
    def __init__(self, path: Path) -> None:
        self.path = path
        self._lock = threading.Lock()

    def _load(self) -> dict[str, Any]:
        if not self.path.is_file():
            return {"setups": {}}
        try:
            raw = json.loads(self.path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            logger.error("track_record_read_failed path=%s err=%s", self.path, exc)
            return {"setups": {}}
        if not isinstance(raw, dict) or not isinstance(raw.get("setups"), dict):
            return {"setups": {}}
        return raw

    def _save(self, data: dict[str, Any]) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        tmp = self.path.with_suffix(".json.tmp")
        tmp.write_text(json.dumps(data, indent=2), encoding="utf-8")
        tmp.replace(self.path)

    def all(self) -> list[dict[str, Any]]:
        with self._lock:
            return list(self._load()["setups"].values())

    def upsert_new(self, setup: dict[str, Any]) -> bool:
        """Insert, or replace levels only while the existing setup is still unfilled."""
        with self._lock:
            data = self._load()
            existing = data["setups"].get(setup["id"])
            if existing and existing.get("status") != "pending":
                return False
            if existing:
                setup = {**setup, "created_at": existing.get("created_at", setup["created_at"])}
            data["setups"][setup["id"]] = setup
            self._save(data)
            return True

    def replace_many(self, updated: list[dict[str, Any]]) -> None:
        if not updated:
            return
        with self._lock:
            data = self._load()
            for s in updated:
                data["setups"][s["id"]] = s
            self._save(data)


def record_daily_entries(
    store: TrackRecordStore,
    day: str,
    entries: list[dict[str, Any]],
    parse_trade_levels: Callable[[str], dict[str, Optional[float]]],
) -> int:
    added = 0
    now = time.time()
    for entry in entries:
        if not isinstance(entry, dict):
            continue
        coin = str(entry.get("coin") or "").upper()
        levels = parse_trade_levels(str(entry.get("report") or ""))
        values = [levels.get(k) for k in ("entry", "tp1", "tp2", "sl")]
        if not coin or any(v is None for v in values):
            continue
        setup = build_setup(
            setup_id=f"{day}_{coin}",
            coin=coin,
            day=day,
            entry=float(values[0]),
            tp1=float(values[1]),
            tp2=float(values[2]),
            sl=float(values[3]),
            created_at=now,
        )
        if setup is None:
            logger.warning("track_record_skipped_geometry day=%s coin=%s levels=%s", day, coin, levels)
            continue
        if store.upsert_new(setup):
            added += 1
    return added


def evaluate_open_setups(
    store: TrackRecordStore,
    fetch_hourly: Callable[[str, int], Optional[list[Candle]]],
) -> int:
    """Grade every non-final setup. fetch_hourly(coin, limit) → 1h candles (newest last)."""
    now = time.time()
    updated: list[dict[str, Any]] = []
    for setup in store.all():
        if setup.get("status") in FINAL_STATUSES:
            continue
        hours = int((now - float(setup["created_at"])) / 3600) + 3
        candles = fetch_hourly(setup["coin"], max(10, min(hours, 1000)))
        if not candles:
            continue
        # Drop the still-forming candle so a wick that later retraces isn't double-counted.
        complete = [c for c in candles if c[0] + 3600 <= now]
        result = evaluate_setup(setup, complete, now=now)
        if result != setup:
            updated.append(result)
    store.replace_many(updated)
    return len(updated)


def user_payload(store: TrackRecordStore, user_id: str, *, recent: int = 50) -> dict[str, Any]:
    """One user's paper trades, graded with the same rules as the public record."""
    setups = [s for s in store.all() if s.get("user_id") == user_id]
    setups.sort(key=lambda s: s.get("created_at", 0), reverse=True)
    fields = (
        "id", "coin", "direction", "order_type", "entry", "tp1", "tp2", "sl",
        "status", "outcome", "r_multiple", "tp1_hit", "created_at", "filled_at", "closed_at",
    )
    return {
        "summary": summarize(setups),
        "trades": [{k: s.get(k) for k in fields} for s in setups[:recent]],
    }


def public_payload(store: TrackRecordStore, *, recent: int = 30) -> dict[str, Any]:
    setups = store.all()
    setups.sort(key=lambda s: s.get("created_at", 0), reverse=True)
    now = time.time()
    fields = (
        "id", "coin", "day", "direction", "entry", "tp1", "tp2", "sl",
        "status", "outcome", "r_multiple", "tp1_hit", "filled_at", "closed_at",
    )
    return {
        "all_time": summarize(setups),
        "last_30d": summarize(setups, since=now - 30 * 86400),
        "last_7d": summarize(setups, since=now - 7 * 86400),
        "recent": [{k: s.get(k) for k in fields} for s in setups[:recent]],
        "methodology": (
            "Every daily setup is graded on Binance 1h candles. It counts only after price touches Entry. "
            "If a candle hits both stop and target, the stop counts first. Stops are never moved to "
            "breakeven: TP1 then stop = +0.4×R1 − 0.6R; TP2 = 0.4×R1 + 0.6×R2; stop = −1R. "
            "No fill within 72h is excluded from win rate. Open after 14 days closes at market."
        ),
        "updated_at": int(now),
    }
