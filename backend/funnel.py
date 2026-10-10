"""
Paywall funnel events — append-only JSONL plus a summary for the owner.

Events come from the app (paywall_view → purchase_start → purchase_success, and the
one-time Pro preview). Only an anonymous install id and a few small properties are stored.
"""

from __future__ import annotations

import json
import re
import threading
import time
from collections import defaultdict
from pathlib import Path
from typing import Any, Optional

EVENTS = frozenset(
    {
        "paywall_view",
        "purchase_start",
        "purchase_success",
        "purchase_cancel",
        "purchase_error",
        "pro_preview_offer",
        "pro_preview_start",
    }
)
_INSTALL_ID_RE = re.compile(r"^[a-f0-9]{8,64}$")
_MAX_PROPS = 6
_MAX_PROP_LEN = 64
_RATE_LIMIT_PER_MIN = 30


def clean_event(raw: Any) -> Optional[dict[str, Any]]:
    """Validate an incoming event. Returns None when it should be dropped."""
    if not isinstance(raw, dict):
        return None
    event = str(raw.get("event") or "")
    install_id = str(raw.get("install_id") or "").lower()
    if event not in EVENTS or not _INSTALL_ID_RE.match(install_id):
        return None
    props: dict[str, Any] = {}
    raw_props = raw.get("props")
    if isinstance(raw_props, dict):
        for key, value in list(raw_props.items())[:_MAX_PROPS]:
            if not isinstance(key, str) or len(key) > 32:
                continue
            if isinstance(value, (int, float, bool)) or value is None:
                props[key] = value
            else:
                props[key] = str(value)[:_MAX_PROP_LEN]
    return {"event": event, "install_id": install_id, "props": props}


class FunnelStore:
    def __init__(self, path: Path) -> None:
        self.path = path
        self._lock = threading.Lock()
        self._recent: dict[str, list[float]] = defaultdict(list)

    def allow(self, install_id: str, now: Optional[float] = None) -> bool:
        now = now if now is not None else time.time()
        with self._lock:
            hits = [t for t in self._recent[install_id] if now - t < 60]
            if len(hits) >= _RATE_LIMIT_PER_MIN:
                self._recent[install_id] = hits
                return False
            hits.append(now)
            self._recent[install_id] = hits
            return True

    def append(self, event: dict[str, Any], *, user_id: Optional[str], now: Optional[float] = None) -> None:
        row = {**event, "ts": now if now is not None else time.time()}
        if user_id:
            row["user_id"] = user_id
        with self._lock:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            with self.path.open("a", encoding="utf-8") as fh:
                fh.write(json.dumps(row, separators=(",", ":")) + "\n")

    def read_since(self, since: float) -> list[dict[str, Any]]:
        if not self.path.is_file():
            return []
        rows: list[dict[str, Any]] = []
        with self._lock, self.path.open(encoding="utf-8") as fh:
            for line in fh:
                try:
                    row = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if isinstance(row, dict) and float(row.get("ts") or 0) >= since:
                    rows.append(row)
        return rows


def _rate(numerator: int, denominator: int) -> Optional[float]:
    return round(numerator / denominator, 4) if denominator else None


def summarize(rows: list[dict[str, Any]]) -> dict[str, Any]:
    """Unique installs per step, overall and by paywall source."""
    installs: dict[str, set[str]] = defaultdict(set)
    by_source: dict[str, dict[str, set[str]]] = defaultdict(lambda: defaultdict(set))
    for row in rows:
        event, install = row.get("event"), row.get("install_id")
        if not event or not install:
            continue
        installs[event].add(install)
        source = (row.get("props") or {}).get("source")
        if source:
            by_source[str(source)][event].add(install)

    def steps(sets: dict[str, set[str]]) -> dict[str, Any]:
        views = len(sets.get("paywall_view", ()))
        starts = len(sets.get("purchase_start", ()))
        buys = len(sets.get("purchase_success", ()))
        return {
            "paywall_views": views,
            "purchase_starts": starts,
            "purchases": buys,
            "view_to_start": _rate(starts, views),
            "start_to_purchase": _rate(buys, starts),
            "view_to_purchase": _rate(buys, views),
        }

    overall = steps(installs)
    overall.update(
        {
            "cancels": len(installs.get("purchase_cancel", ())),
            "errors": len(installs.get("purchase_error", ())),
            "pro_preview_offers": len(installs.get("pro_preview_offer", ())),
            "pro_preview_starts": len(installs.get("pro_preview_start", ())),
        }
    )
    return {
        "overall": overall,
        "by_source": {source: steps(sets) for source, sets in sorted(by_source.items())},
        "events": len(rows),
    }
