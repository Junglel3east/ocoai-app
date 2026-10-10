"""Billing entitlement, track-record grading, and Citadel sizing — run: python test_safety_features.py"""

from __future__ import annotations

import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import bitunix_service as bux
import play_billing as pb
import track_record as trk

HOUR = 3600.0
NOW_MS = 1_800_000_000_000


# ─── Billing ─────────────────────────────────────────────────────────────────


def _sub(state: str, expiry_iso: str, product: str = "oracle_pro_monthly") -> dict:
    return {"subscriptionState": state, "lineItems": [{"productId": product, "expiryTime": expiry_iso}]}


def test_entitlement_states() -> None:
    future = "2027-03-15T10:00:00.123456789Z"  # nanosecond precision, as Google sends
    past = "2020-01-01T00:00:00Z"
    active = pb.entitlement_from_subscription(_sub("SUBSCRIPTION_STATE_ACTIVE", future), now_ms=NOW_MS)
    assert active["active"] and active["plan"] == "Expert"
    canceled = pb.entitlement_from_subscription(_sub("SUBSCRIPTION_STATE_CANCELED", future), now_ms=NOW_MS)
    assert canceled["active"], "auto-renew off keeps access until expiry"
    expired = pb.entitlement_from_subscription(_sub("SUBSCRIPTION_STATE_EXPIRED", past), now_ms=NOW_MS)
    assert not expired["active"] and expired["plan"] is None
    on_hold = pb.entitlement_from_subscription(_sub("SUBSCRIPTION_STATE_ON_HOLD", future), now_ms=NOW_MS)
    assert not on_hold["active"], "payment failed → no access"
    legacy = pb.entitlement_from_subscription(
        _sub("SUBSCRIPTION_STATE_ACTIVE", future, "premium_monthly"), now_ms=NOW_MS
    )
    assert legacy["plan"] == "Premium"
    unknown = pb.entitlement_from_subscription(_sub("SUBSCRIPTION_STATE_ACTIVE", future, "other"), now_ms=NOW_MS)
    assert not unknown["active"]


def test_token_rebinds_to_one_user() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        store = pb.EntitlementStore(Path(tmp) / "b.json")
        ent = {"active": True, "plan": "Expert", "product_id": "oracle_pro_monthly",
               "expires_at_ms": int(time.time() * 1000) + 86_400_000, "state": "SUBSCRIPTION_STATE_ACTIVE"}
        store.put("usr_a", "tok1", ent)
        assert pb.public_view(store.get("usr_a"))["active"]
        store.put("usr_b", "tok1", ent)
        assert store.get("usr_a") is None, "sharing a token moves access instead of duplicating it"
        assert store.owner_of("tok1") == "usr_b"
        expired = dict(ent, expires_at_ms=int(time.time() * 1000) - 1)
        store.put("usr_b", "tok1", expired)
        assert not pb.public_view(store.get("usr_b"))["active"]


# ─── Track record ────────────────────────────────────────────────────────────


def _long_setup(created: float = 0.0) -> dict:
    s = trk.build_setup(setup_id="d_BTC", coin="BTC", day="d", entry=100.0, tp1=110.0, tp2=120.0,
                        sl=95.0, created_at=created)
    assert s is not None
    return s


def _c(hour: int, high: float, low: float, close: float | None = None) -> list[float]:
    return [hour * HOUR, low, high, low, close if close is not None else (high + low) / 2, 0.0]


def test_rejects_bad_geometry() -> None:
    assert trk.build_setup(setup_id="x", coin="BTC", day="d", entry=100, tp1=90, tp2=120, sl=95,
                           created_at=0) is None


def test_long_stopped_before_tp1() -> None:
    out = trk.evaluate_setup(_long_setup(), [_c(0, 103, 99), _c(1, 101, 94)], now=10 * HOUR)
    assert out["outcome"] == "stopped" and out["r_multiple"] == -1.0


def test_long_tp1_then_stop_counts_partial() -> None:
    out = trk.evaluate_setup(_long_setup(), [_c(0, 101, 99), _c(1, 111, 104), _c(2, 105, 94)], now=10 * HOUR)
    # R1 = 2, R2 = 4 → 0.4·2 − 0.6 = 0.2
    assert out["outcome"] == "tp1_then_stop" and abs(out["r_multiple"] - 0.2) < 1e-9


def test_long_full_tp2() -> None:
    out = trk.evaluate_setup(_long_setup(), [_c(0, 101, 99), _c(1, 111, 104), _c(2, 121, 108)], now=10 * HOUR)
    assert out["outcome"] == "tp2" and abs(out["r_multiple"] - 3.2) < 1e-9


def test_fill_candle_never_counts_targets() -> None:
    out = trk.evaluate_setup(_long_setup(), [_c(0, 121, 99)], now=2 * HOUR)
    assert out["status"] == "open" and not out["tp1_hit"]


def test_same_candle_stop_and_target_counts_stop() -> None:
    out = trk.evaluate_setup(_long_setup(), [_c(0, 101, 99), _c(1, 112, 94)], now=10 * HOUR)
    assert out["outcome"] == "stopped"


def test_no_fill_after_72h() -> None:
    candles = [_c(h, 130, 105) for h in range(0, 80)]
    out = trk.evaluate_setup(_long_setup(), candles, now=80 * HOUR)
    assert out["status"] == "no_fill"


def test_short_tp2() -> None:
    s = trk.build_setup(setup_id="d_ETH", coin="ETH", day="d", entry=100.0, tp1=90.0, tp2=80.0,
                        sl=105.0, created_at=0)
    assert s is not None and s["direction"] == "short"
    out = trk.evaluate_setup(s, [_c(0, 101, 99), _c(1, 96, 89), _c(2, 92, 79)], now=10 * HOUR)
    assert out["outcome"] == "tp2"


def test_summary() -> None:
    a = trk.evaluate_setup(_long_setup(), [_c(0, 101, 99), _c(1, 101, 94)], now=10 * HOUR)
    b = trk.evaluate_setup(dict(_long_setup(), id="b"), [_c(0, 101, 99), _c(1, 111, 104), _c(2, 121, 108)],
                           now=10 * HOUR)
    summary = trk.summarize([a, b])
    assert summary["closed"] == 2 and summary["wins"] == 1 and summary["win_rate"] == 0.5
    assert abs(summary["total_r"] - 2.2) < 1e-9


# ─── Bitunix sizing (no network) ─────────────────────────────────────────────


def _rules(decimals: int = 3, min_qty: float = 0.003) -> bux.SymbolRules:
    return bux.SymbolRules(symbol="ETHUSDT", qty_decimals=decimals, price_decimals=2, min_qty=min_qty,
                           max_market_qty=None, max_leverage=100, api_supported=True, source="test")


def _with_balance(value):
    original = bux.fetch_available_usdt
    bux.fetch_available_usdt = lambda **_: value
    return original


def test_sizing_rounds_down_to_precision() -> None:
    original = _with_balance(1000.0)
    try:
        qty, meta = bux.calculate_order_size(entry_price=3000.0, stop_loss=2900.0, risk_percent=10,
                                             leverage=5, api_key="k", api_secret="s", rules=_rules())
    finally:
        bux.fetch_available_usdt = original
    # margin 100 × 5x = 500 notional / 3000 = 0.16666 → 0.166 (never rounded up)
    assert qty == "0.166" and "error" not in meta


def test_sizing_below_minimum_unaffordable_errors() -> None:
    original = _with_balance(0.5)
    try:
        qty, meta = bux.calculate_order_size(entry_price=3000.0, stop_loss=2900.0, risk_percent=10,
                                             leverage=5, api_key="k", api_secret="s", rules=_rules())
    finally:
        bux.fetch_available_usdt = original
    assert qty == "0" and "minimum" in meta["error"]


def test_sizing_bumps_to_minimum_when_affordable() -> None:
    original = _with_balance(50.0)
    try:
        qty, meta = bux.calculate_order_size(entry_price=3000.0, stop_loss=2900.0, risk_percent=1,
                                             leverage=5, api_key="k", api_secret="s", rules=_rules())
    finally:
        bux.fetch_available_usdt = original
    assert qty == "0.003" and meta.get("bumped_to_min_qty")


def test_dual_tp_split() -> None:
    assert bux.dual_tp_sizes("0.15", _rules(2, 0.1)) == ("0.15", None)
    tp1, tp2 = bux.dual_tp_sizes("1.000", _rules())
    assert float(tp1) + float(tp2) == 1.0 and tp2 is not None


# ─── Weekly X recap ──────────────────────────────────────────────────────────


def _x_weight(text: str) -> int:
    """X counts URLs as 23 and characters outside basic ranges (emoji) as 2."""
    import re

    without_urls = re.sub(r"https?://\S+", "", text)
    urls = len(re.findall(r"https?://\S+", text))
    return urls * 23 + sum(2 if ord(ch) > 0x2FFF else 1 for ch in without_urls)


def test_weekly_recap_skips_empty_week() -> None:
    import x_daily_poster as xp

    assert xp.format_weekly_recap({"week": {"closed": 0}}, "Oct 4–10") is None


def test_weekly_recap_fits_x_limit() -> None:
    import x_daily_poster as xp

    with tempfile.TemporaryDirectory() as tmp:
        store = trk.TrackRecordStore(Path(tmp) / "t.json")
        now = 100 * 86400.0
        closed = [
            dict(_long_setup(), id=f"s{i}", coin=c, status="closed", outcome=o, r_multiple=r,
                 tp1_hit=o != "stopped", closed_at=now - 86400)
            for i, (c, o, r) in enumerate([("BTC", "tp2", 3.2), ("ETH", "stopped", -1.0), ("SOL", "tp1_then_stop", 0.2)])
        ]
        old = dict(_long_setup(), id="old", status="closed", outcome="tp2", r_multiple=2.0, closed_at=now - 30 * 86400)
        store.replace_many(closed + [old])
        stats = trk.weekly_recap_stats(store, now=now)
        assert stats["week"]["closed"] == 3 and stats["all_time"]["closed"] == 4
        assert stats["best"]["coin"] == "BTC"
        text = xp.format_weekly_recap(stats, "Sep 28–Oct 4")
        assert text and "2W / 1L" in text and "+2.4R" in text and "All-time: 4 closed" in text
        assert _x_weight(text) <= 280, _x_weight(text)
        assert text.count("$") == 0, "no cashtags"


def test_week_label() -> None:
    from datetime import datetime

    import x_daily_poster as xp

    assert xp.format_week_label(datetime(2026, 10, 5), datetime(2026, 10, 11)) == "Oct 5–11"
    assert xp.format_week_label(datetime(2026, 9, 28), datetime(2026, 10, 4)) == "Sep 28–Oct 4"


if __name__ == "__main__":
    tests = [(name, fn) for name, fn in sorted(globals().items()) if name.startswith("test_") and callable(fn)]
    failed = 0
    for name, fn in tests:
        try:
            fn()
            print(f"  ok   {name}")
        except AssertionError as exc:
            failed += 1
            print(f"  FAIL {name}: {exc}")
    print(f"{len(tests) - failed}/{len(tests)} passed")
    sys.exit(1 if failed else 0)
