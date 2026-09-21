"""defect_reports: the row-sensitivity table.

Rows classified THIRD_PARTY_PROPRIETARY are filtered by row-level security at L4,
so a standard caller sees fewer rows and is told nothing about the rest. These
tests pin the preconditions that make that demonstrable: both classes must exist,
the restricted slice must be a meaningful minority, and every restricted row must
name the third party it belongs to.
"""

from generators import config as C
from generators.build import gen_defect_reports, gen_suppliers, gen_vehicles

RESTRICTED = "THIRD_PARTY_PROPRIETARY"


def _rows():
    return gen_defect_reports(gen_vehicles(), gen_suppliers())


def test_row_count_is_exact():
    assert len(_rows()) == C.N_DEFECT_REPORTS


def test_both_classifications_are_present():
    # An RLS demo needs rows on BOTH sides of the predicate. A table that is
    # entirely restricted, or entirely open, lets a filtered query pass while
    # proving nothing was filtered.
    assert {r["classification"] for r in _rows()} == {"INTERNAL", RESTRICTED}


def test_restricted_rows_are_a_meaningful_minority():
    rows = _rows()
    n = sum(1 for r in rows if r["classification"] == RESTRICTED)
    fraction = n / len(rows)
    assert 0.10 <= fraction <= 0.25, f"restricted fraction {fraction}"


def test_referential_integrity_to_vehicles_and_suppliers():
    vehicles, suppliers = gen_vehicles(), gen_suppliers()
    vids = {v["vehicle_id"] for v in vehicles}
    sids = {s["supplier_id"] for s in suppliers}
    for r in gen_defect_reports(vehicles, suppliers):
        assert r["vehicle_id"] in vids
        assert r["supplier_id"] is None or r["supplier_id"] in sids


def test_every_restricted_row_names_a_supplier():
    # Third-party proprietary information with no third party would be
    # incoherent, and the demo narrative depends on that link being real.
    for r in _rows():
        if r["classification"] == RESTRICTED:
            assert r["supplier_id"] is not None


def test_severity_and_status_use_only_declared_values():
    rows = _rows()
    assert {r["severity"] for r in rows} <= {v for v, _ in C.DEFECT_SEVERITIES}
    assert {r["status"] for r in rows} <= {v for v, _ in C.DEFECT_STATUSES}


def test_defect_ids_are_unique():
    rows = _rows()
    assert len({r["defect_id"] for r in rows}) == len(rows)


def test_is_deterministic():
    assert _rows() == _rows()
