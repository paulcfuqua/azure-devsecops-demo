"""Exact row counts per the Phase P / L5 plan (launches = 1,200 exactly)."""

from generators import config as C


def test_launches_exactly_1200(tables):
    assert len(tables["launches"]) == 1200


def test_expected_counts(tables):
    for name, expected in C.EXPECTED_COUNTS.items():
        assert len(tables[name]) == expected, (
            f"{name}: expected {expected} rows, got {len(tables[name])}"
        )


def test_all_ten_tables_present(tables):
    assert list(tables.keys()) == C.TABLE_ORDER
    assert len(C.TABLE_ORDER) == 10
    for name in C.TABLE_ORDER:
        assert len(tables[name]) > 0, f"{name} is empty"


def test_scrub_rows_match_scrub_counts(tables):
    total_declared = sum(r["scrub_count"] for r in tables["launches"])
    assert len(tables["scrubs"]) == total_declared


def test_telemetry_one_row_per_launch(tables):
    assert len(tables["telemetry_summary"]) == len(tables["launches"])
