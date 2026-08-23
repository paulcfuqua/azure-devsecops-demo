"""Deterministic synthetic launch-industry data for Meridian Launch Systems.

Usage (from the data/ directory):
    python -m generators build      # write CSV + JSON under data/generated/
    python -m generators summary    # row counts + launches-by-weekday

Same seed (config.SEED = 20260822) => byte-identical output, always.
"""

from .build import build_tables, launches_by_weekday
from .config import SEED, TABLE_ORDER
from .writers import build_and_write

__all__ = [
    "SEED",
    "TABLE_ORDER",
    "build_tables",
    "build_and_write",
    "launches_by_weekday",
]
