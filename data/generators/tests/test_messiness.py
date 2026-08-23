"""Reproducible messiness stays inside declared bounds: nulls, dirty strings,
supplier lead-time outliers, and weather scrub cascades."""

from datetime import date

from generators import config as C
from generators import pools as P

NULL_LO, NULL_HI = 0.005, 0.08
DIRTY_LO, DIRTY_HI = 0.02, 0.12
OUTLIER_LO, OUTLIER_HI = 0.02, 0.15

# Canonical (undamaged) value sets per dirty column: a value is dirty iff it
# is not exactly one of its pool's canonical strings.
CANONICAL = {
    ("launches", "customer"): {name for name, _, _ in P.CUSTOMERS},
    ("parts", "material"): set(P.MATERIALS),
    ("work_orders", "technician"): set(P.TECHNICIANS),
}


def test_null_fractions_within_bounds(tables):
    for table_name, columns in C.NULLABLE_COLUMNS.items():
        rows = tables[table_name]
        for col in columns:
            nulls = sum(1 for r in rows if r[col] is None)
            frac = nulls / len(rows)
            assert NULL_LO <= frac <= NULL_HI, (
                f"{table_name}.{col}: null fraction {frac:.4f} outside "
                f"[{NULL_LO}, {NULL_HI}] ({nulls}/{len(rows)})"
            )


def test_dirty_string_fractions_within_bounds(tables):
    for table_name, columns in C.DIRTY_COLUMNS.items():
        rows = tables[table_name]
        for col in columns:
            canonical = CANONICAL[(table_name, col)]
            values = [r[col] for r in rows if r[col] is not None]
            dirty = sum(1 for v in values if v not in canonical)
            frac = dirty / len(values)
            assert DIRTY_LO <= frac <= DIRTY_HI, (
                f"{table_name}.{col}: dirty fraction {frac:.4f} outside "
                f"[{DIRTY_LO}, {DIRTY_HI}] ({dirty}/{len(values)})"
            )


def test_lead_time_outliers(tables):
    """Parts lead times have a long tail: a bounded fraction of clear outliers."""
    lead_times = sorted(r["lead_time_days"] for r in tables["parts"])
    n = len(lead_times)
    outliers = sum(1 for v in lead_times if v > 120)
    frac = outliers / n
    assert OUTLIER_LO <= frac <= OUTLIER_HI, f"outlier fraction {frac:.4f}"
    assert max(lead_times) > 200, "expected at least one extreme lead-time outlier"
    median = lead_times[n // 2]
    assert median < 60, f"median lead time {median} should stay realistic"


def test_weather_scrub_cascades(tables):
    """Weather stand-downs produce runs of consecutive-day scrubs per launch."""
    by_launch = {}
    for r in tables["scrubs"]:
        if r["category"] == "weather":
            by_launch.setdefault(r["launch_id"], []).append(
                date.fromisoformat(r["scrub_date"])
            )
    consecutive_pairs = 0
    for dates in by_launch.values():
        dates.sort()
        for a, b in zip(dates, dates[1:]):
            if (b - a).days == 1:
                consecutive_pairs += 1
    assert consecutive_pairs >= 25, (
        f"only {consecutive_pairs} consecutive-day weather scrub pairs; "
        "cascades are not clustering"
    )


def test_launches_have_scrub_variety(tables):
    """Some launches fly on time; some slip; scrub counts stay plausible."""
    scrub_counts = [r["scrub_count"] for r in tables["launches"]]
    assert scrub_counts.count(0) > len(scrub_counts) * 0.5
    assert max(scrub_counts) <= 3
    assert sum(1 for c in scrub_counts if c > 0) > len(scrub_counts) * 0.15
