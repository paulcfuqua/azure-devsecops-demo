"""hr_roster: the column-sensitivity table. Salary is restricted; start_date is not.

The demo this table exists for shows a standard caller reading `start_date` and
`department` from the same row whose `salary_usd` the database refuses. That only
works if the sensitive and non-sensitive columns genuinely live together, which is
what these tests pin.
"""

from generators import config as C
from generators.build import gen_hr_roster

OPEN_COLUMNS = {
    "employee_id",
    "display_name",
    "department",
    "job_family",
    "location",
    "start_date",
    "tenure_years",
    "manager_id",
    "employment_type",
}
RESTRICTED_COLUMNS = {"salary_usd", "bonus_target_pct", "performance_band"}


def test_row_count_is_exact():
    assert len(gen_hr_roster()) == C.N_HR_ROSTER


def test_every_row_carries_both_open_and_restricted_columns():
    # The whole point of this table is that ONE ROW mixes both. A table whose
    # sensitive columns lived in a separate table would demonstrate nothing:
    # column-level security would have nothing to discriminate within.
    for row in gen_hr_roster():
        assert OPEN_COLUMNS <= set(row), f"missing open columns: {OPEN_COLUMNS - set(row)}"
        assert RESTRICTED_COLUMNS <= set(row), (
            f"missing restricted columns: {RESTRICTED_COLUMNS - set(row)}"
        )


def test_salary_is_populated_and_plausible():
    # A restricted column full of nulls makes the CLS demo vacuous - the denial
    # would be indistinguishable from there being nothing to deny.
    salaries = [r["salary_usd"] for r in gen_hr_roster()]
    assert all(s is not None for s in salaries)
    assert min(salaries) >= 45000
    assert max(salaries) <= 400000


def test_performance_band_uses_only_declared_values():
    bands = {r["performance_band"] for r in gen_hr_roster()}
    assert bands <= {v for v, _ in C.HR_PERFORMANCE_BANDS}


def test_is_deterministic():
    assert gen_hr_roster() == gen_hr_roster()


def test_managers_reference_real_employees_or_none():
    rows = gen_hr_roster()
    ids = {r["employee_id"] for r in rows}
    for r in rows:
        assert r["manager_id"] is None or r["manager_id"] in ids


def test_employee_ids_are_unique():
    rows = gen_hr_roster()
    assert len({r["employee_id"] for r in rows}) == len(rows)
