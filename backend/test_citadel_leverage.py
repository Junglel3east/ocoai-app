"""Lightweight Citadel leverage helpers — run: python test_citadel_leverage.py"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from api import BLOFIN_DEFAULT_LEVERAGE, _normalize_citadel_leverage


def test_normalize_citadel_leverage_defaults_and_clamps() -> None:
    assert _normalize_citadel_leverage(None) == BLOFIN_DEFAULT_LEVERAGE
    assert _normalize_citadel_leverage("bad") == BLOFIN_DEFAULT_LEVERAGE
    assert _normalize_citadel_leverage(5) == 5
    assert _normalize_citadel_leverage(5.9) == 5
    assert _normalize_citadel_leverage(1) == 1
    assert _normalize_citadel_leverage(100) == 100
    assert _normalize_citadel_leverage(0) == 1
    assert _normalize_citadel_leverage(150) == 100


if __name__ == "__main__":
    test_normalize_citadel_leverage_defaults_and_clamps()
    print("test_citadel_leverage: ok")
