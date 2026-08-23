"""Distribution assertions: Saturday is the busiest launch weekday (argmax)."""

from datetime import date

SATURDAY = 5  # Python weekday(): Monday=0 .. Sunday=6


def weekday_counts(rows, column):
    counts = [0] * 7
    for r in rows:
        value = r[column]
        if value is None:
            continue
        counts[date.fromisoformat(value).weekday()] += 1
    return counts


def test_saturday_argmax_actual_date(tables):
    counts = weekday_counts(tables["launches"], "actual_date")
    assert counts.index(max(counts)) == SATURDAY, f"weekday counts (Mon..Sun): {counts}"


def test_saturday_margin_actual_date(tables):
    """Saturday must clearly lead so downstream copilot evals are unambiguous."""
    counts = weekday_counts(tables["launches"], "actual_date")
    runner_up = max(c for i, c in enumerate(counts) if i != SATURDAY)
    assert counts[SATURDAY] >= 1.15 * runner_up, f"weekday counts (Mon..Sun): {counts}"


def test_saturday_argmax_planned_date(tables):
    counts = weekday_counts(tables["launches"], "planned_date")
    assert counts.index(max(counts)) == SATURDAY, f"weekday counts (Mon..Sun): {counts}"


def test_every_weekday_represented(tables):
    counts = weekday_counts(tables["launches"], "actual_date")
    assert all(c > 0 for c in counts), f"weekday counts (Mon..Sun): {counts}"
