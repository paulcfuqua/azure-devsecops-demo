# Tiered Data Access — Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Seed two mixed-sensitivity lakehouse tables and enforce column- and row-level access on them at the data layer, with criteria that prove a standard principal genuinely cannot read restricted data.

**Architecture:** Two new tables join the existing ten through `data/generators` (deterministic, seed 20260822) and the `data/seed/seed.ps1` lakehouse path. A new idempotent script creates two database roles, a column DENY (CLS) and a security policy over a schema-bound view (RLS) on the Fabric SQL analytics endpoint. L4 applies the protection; L5 seeds the data. Verification executes a real query as the restricted role and requires it to fail.

**Tech Stack:** Python 3 (generators, pytest), PowerShell 7 (seed, protection, Pester), T-SQL on Fabric SQL analytics endpoint, GitHub Actions.

**Spec:** [`docs/superpowers/specs/2026-09-20-tiered-data-access-demo-design.md`](../specs/2026-09-20-tiered-data-access-demo-design.md)

## Global Constraints

- **Synthetic data only.** No real person's PII; demo people are fictional (CLAUDE.md hard rule 4).
- **Determinism.** `data/generators` must be a pure function of `config.SEED = 20260822`. No time-of-run, no env vars, no filesystem state. Changing any value in `config.py` is a schema change.
- **No hardcoded `mls`.** Role and label names use `<prefix>` / `<env>` resolved from `MLS_COMPANY_PREFIX` / `MLS_ENV_SEGMENT`. (F90)
- **Scope: lakehouse only.** These two tables are NOT seeded to Azure SQL. `findings_history` is the existing precedent — it has no file in `data/seed/sql/`.
- **Every layer ships a triplet:** deploy path, teardown, `verification/` audit script.
- **Idempotent on replay.** Protection objects are create-if-absent; a second run issues no destructive statement.
- **File content is written with a file tool, never a shell heredoc.** (CLAUDE.md)
- **Resolve schema from the endpoint; never write a column name from memory.** Both spike probe failures were this.
- **A criterion asserts the capability, not the artefact.** V4.5 runs a query and requires a denial.
- **CI is `ubuntu-latest` (bash); local orchestration is `pwsh`.** Never assume Windows PowerShell 5.1.

### Table declaration sites — all five must agree

Adding a table touches every one of these. `data/seed/tests/schema-parity.Tests.ps1` is the guard that catches a miss:

1. `data/generators/config.py` → `TABLE_ORDER`
2. `data/generators/tests/expected_counts.json`
3. `data/seed/schema-manifest.json` → `load_order` + `tables`
4. `data/seed/sql/*.sql` → **not applicable here** (lakehouse-only, as `findings_history`)
5. Prose saying "ten tables" in `data/generators/build.py`, `data/seed/seed.ps1`, `data/seed/README.md`, `data/seed/sql/sql-seed.psm1`, `data/seed/tests/schema-parity.Tests.ps1`, `verification/tests/layer-05-audit.Tests.ps1`

---

### Task 1: `hr_roster` generator — mixed sensitivity by column

**Files:**
- Modify: `data/generators/config.py`
- Modify: `data/generators/build.py`
- Test: `data/generators/tests/test_hr_roster.py` (create)

**Interfaces:**
- Consumes: `config.SEED`, `build._rng`, `build._rand_date`, `build._weighted`, `build._maybe_null`
- Produces: `build.gen_hr_roster() -> list[dict]` with keys `employee_id, display_name, department, job_family, location, start_date, tenure_years, manager_id, employment_type, salary_usd, bonus_target_pct, performance_band`

- [ ] **Step 1: Write the failing test**

Create `data/generators/tests/test_hr_roster.py`:

```python
"""hr_roster: the column-sensitivity table. Salary is restricted; start_date is not."""
from generators import config as C
from generators.build import gen_hr_roster

OPEN_COLUMNS = {
    "employee_id", "display_name", "department", "job_family", "location",
    "start_date", "tenure_years", "manager_id", "employment_type",
}
RESTRICTED_COLUMNS = {"salary_usd", "bonus_target_pct", "performance_band"}


def test_row_count_is_exact():
    assert len(gen_hr_roster()) == C.N_HR_ROSTER


def test_every_row_carries_both_open_and_restricted_columns():
    # The whole point of this table is that one row mixes both. A table whose
    # sensitive columns lived in a separate table would demonstrate nothing.
    for row in gen_hr_roster():
        assert OPEN_COLUMNS <= set(row), f"missing open columns: {OPEN_COLUMNS - set(row)}"
        assert RESTRICTED_COLUMNS <= set(row), f"missing restricted: {RESTRICTED_COLUMNS - set(row)}"


def test_salary_is_populated_and_plausible():
    # A restricted column full of nulls makes the CLS demo vacuous.
    salaries = [r["salary_usd"] for r in gen_hr_roster()]
    assert all(s is not None for s in salaries)
    assert min(salaries) >= 45000
    assert max(salaries) <= 400000


def test_is_deterministic():
    assert gen_hr_roster() == gen_hr_roster()


def test_managers_reference_real_employees_or_none():
    rows = gen_hr_roster()
    ids = {r["employee_id"] for r in rows}
    for r in rows:
        assert r["manager_id"] is None or r["manager_id"] in ids
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd data && python -m pytest generators/tests/test_hr_roster.py -v`
Expected: FAIL — `ImportError: cannot import name 'gen_hr_roster'`

- [ ] **Step 3: Add the constants**

In `data/generators/config.py`, after `N_FINDINGS = 420`:

```python
N_HR_ROSTER = 240
N_DEFECT_REPORTS = 900

# hr_roster / defect_reports fixed windows.
HR_START = date(2015, 1, 5)
HR_END = date(2026, 5, 29)
DEFECT_START = date(2024, 1, 2)
DEFECT_END = date(2026, 6, 1)

# Fictional name pools. Hard rule 4: no real person's PII. These are composed,
# not sampled from any real roster.
HR_FIRST_NAMES = [
    "Aurelia", "Bertram", "Caspian", "Delphine", "Emeric", "Fenella", "Gideon",
    "Halcyon", "Isolde", "Jarrah", "Kestrel", "Lisandra", "Montague", "Nerissa",
    "Oberon", "Persephone", "Quillon", "Rosalind", "Silas", "Thessaly",
]
HR_LAST_NAMES = [
    "Ashgrove", "Blackwood", "Castellan", "Drummond", "Everhart", "Fairweather",
    "Glasspool", "Hartigan", "Ironside", "Jessamy", "Kingsleigh", "Lockhart",
    "Marchetti", "Northcott", "Ollivander", "Pemberton", "Quarrington",
    "Ravensworth", "Stronghold", "Thorncastle",
]
HR_DEPARTMENTS = [
    "Propulsion", "Avionics", "Structures", "Launch Operations",
    "Mission Assurance", "Supply Chain", "Finance", "People",
]
HR_JOB_FAMILIES = ["Engineering", "Operations", "Corporate", "Technician"]
HR_LOCATIONS = ["Canaveral", "Vandenberg", "Wallops", "Remote"]
HR_EMPLOYMENT_TYPES = [("Full-time", 82), ("Contract", 13), ("Intern", 5)]
HR_PERFORMANCE_BANDS = [("Exceeds", 22), ("Meets", 62), ("Developing", 16)]
```

Add to `TABLE_ORDER`, after `"findings_history"`:

```python
    "hr_roster",
    "defect_reports",
```

- [ ] **Step 4: Implement the generator**

In `data/generators/build.py`, after `gen_findings()`:

```python
def gen_hr_roster():
    """Fictional employee roster. Mixed sensitivity IN ONE ROW: start_date and
    department are open; salary_usd, bonus_target_pct and performance_band are
    restricted by column-level security at L4. The mix is the point - a table
    whose sensitive columns lived elsewhere would demonstrate nothing."""
    rng = _rng("hr_roster")
    rows = []
    for i in range(C.N_HR_ROSTER):
        first = C.HR_FIRST_NAMES[rng.randrange(len(C.HR_FIRST_NAMES))]
        last = C.HR_LAST_NAMES[rng.randrange(len(C.HR_LAST_NAMES))]
        start = _rand_date(rng, C.HR_START, C.HR_END)
        family = C.HR_JOB_FAMILIES[rng.randrange(len(C.HR_JOB_FAMILIES))]
        base = {"Engineering": 118000, "Operations": 92000,
                "Corporate": 104000, "Technician": 71000}[family]
        rows.append({
            "employee_id": f"EMP-{1000 + i}",
            "display_name": f"{first} {last}",
            "department": C.HR_DEPARTMENTS[rng.randrange(len(C.HR_DEPARTMENTS))],
            "job_family": family,
            "location": C.HR_LOCATIONS[rng.randrange(len(C.HR_LOCATIONS))],
            "start_date": start.isoformat(),
            "tenure_years": round((C.HR_END - start).days / 365.25, 1),
            "manager_id": None,
            "employment_type": _weighted(rng, C.HR_EMPLOYMENT_TYPES),
            "salary_usd": base + rng.randrange(-18000, 92000, 500),
            "bonus_target_pct": rng.randrange(0, 26),
            "performance_band": _weighted(rng, C.HR_PERFORMANCE_BANDS),
        })

    # Managers: the first 24 rows are managers; everyone else reports to one of
    # them. Assigned after the fact so manager_id always resolves (tested).
    manager_ids = [r["employee_id"] for r in rows[:24]]
    for r in rows[24:]:
        r["manager_id"] = manager_ids[rng.randrange(len(manager_ids))]
    return rows
```

- [ ] **Step 5: Run test to verify it passes**

Run: `cd data && python -m pytest generators/tests/test_hr_roster.py -v`
Expected: PASS, 5 tests

- [ ] **Step 6: Commit**

```bash
git add data/generators/config.py data/generators/build.py data/generators/tests/test_hr_roster.py
git commit -m "feat(data): hr_roster, mixed sensitivity within a single row"
```

---

### Task 2: `defect_reports` generator — mixed sensitivity by row

**Files:**
- Modify: `data/generators/config.py`
- Modify: `data/generators/build.py`
- Test: `data/generators/tests/test_defect_reports.py` (create)

**Interfaces:**
- Consumes: `build.gen_vehicles()`, `build.gen_suppliers()` (for referential integrity), `config.N_DEFECT_REPORTS`
- Produces: `build.gen_defect_reports(vehicles, suppliers) -> list[dict]` with keys `defect_id, vehicle_id, supplier_id, reported_date, severity, subsystem, status, summary, root_cause, classification`

- [ ] **Step 1: Write the failing test**

Create `data/generators/tests/test_defect_reports.py`:

```python
"""defect_reports: the row-sensitivity table. Some rows are third-party
proprietary and are filtered by row-level security at L4."""
from generators import config as C
from generators.build import gen_defect_reports, gen_suppliers, gen_vehicles

RESTRICTED = "THIRD_PARTY_PROPRIETARY"


def _rows():
    return gen_defect_reports(gen_vehicles(), gen_suppliers())


def test_row_count_is_exact():
    assert len(_rows()) == C.N_DEFECT_REPORTS


def test_both_classifications_are_present():
    # An RLS demo needs rows on BOTH sides of the predicate. A table that is
    # entirely restricted, or entirely open, proves nothing when filtered.
    classes = {r["classification"] for r in _rows()}
    assert classes == {"INTERNAL", RESTRICTED}


def test_restricted_rows_are_a_meaningful_minority():
    rows = _rows()
    n = sum(1 for r in rows if r["classification"] == RESTRICTED)
    assert 0.10 <= n / len(rows) <= 0.25, f"restricted fraction {n / len(rows)}"


def test_referential_integrity_to_vehicles_and_suppliers():
    vehicles, suppliers = gen_vehicles(), gen_suppliers()
    vids = {v["vehicle_id"] for v in vehicles}
    sids = {s["supplier_id"] for s in suppliers}
    for r in gen_defect_reports(vehicles, suppliers):
        assert r["vehicle_id"] in vids
        assert r["supplier_id"] is None or r["supplier_id"] in sids


def test_every_restricted_row_names_a_supplier():
    # 3PPI means third-party material, so a restricted row with no third party
    # would be incoherent - and the demo narrative depends on that link.
    for r in _rows():
        if r["classification"] == RESTRICTED:
            assert r["supplier_id"] is not None


def test_is_deterministic():
    assert _rows() == _rows()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd data && python -m pytest generators/tests/test_defect_reports.py -v`
Expected: FAIL — `ImportError: cannot import name 'gen_defect_reports'`

- [ ] **Step 3: Add the constants**

In `data/generators/config.py`, after the HR block from Task 1:

```python
DEFECT_SEVERITIES = [("Critical", 6), ("Major", 24), ("Minor", 70)]
DEFECT_SUBSYSTEMS = [
    "Propulsion", "Avionics", "Structures", "Thermal", "Guidance",
    "Ground Support", "Payload Fairing",
]
DEFECT_STATUSES = [("Closed", 63), ("In Analysis", 22), ("Open", 15)]
DEFECT_RESTRICTED_RATE = 0.17
DEFECT_SUMMARIES = [
    "Anomalous vibration signature during static fire",
    "Telemetry dropout on stage separation",
    "Out-of-spec weld porosity on interstage",
    "Valve actuation latency above tolerance",
    "Thermal blanket delamination observed post-flight",
    "Guidance IMU drift beyond allowance",
    "Fairing separation shock above predicted",
]
DEFECT_ROOT_CAUSES = [
    "Supplier process deviation",
    "Design margin insufficient",
    "Assembly workmanship",
    "Environmental exposure",
    "Undetermined - monitoring",
]
```

- [ ] **Step 4: Implement the generator**

In `data/generators/build.py`, after `gen_hr_roster()`:

```python
def gen_defect_reports(vehicles, suppliers):
    """Defect records. Mixed sensitivity BY ROW: rows classified
    THIRD_PARTY_PROPRIETARY are filtered by row-level security at L4, so a
    standard caller sees fewer rows and is told nothing about the rest.
    Restricted rows always name a supplier - 3PPI without a third party would
    be incoherent."""
    rng = _rng("defect_reports")
    vehicle_ids = [v["vehicle_id"] for v in vehicles]
    supplier_ids = [s["supplier_id"] for s in suppliers]
    rows = []
    for i in range(C.N_DEFECT_REPORTS):
        restricted = rng.random() < C.DEFECT_RESTRICTED_RATE
        supplier = supplier_ids[rng.randrange(len(supplier_ids))]
        rows.append({
            "defect_id": f"DEF-{10000 + i}",
            "vehicle_id": vehicle_ids[rng.randrange(len(vehicle_ids))],
            "supplier_id": supplier if restricted or rng.random() < 0.6 else None,
            "reported_date": _rand_date(rng, C.DEFECT_START, C.DEFECT_END).isoformat(),
            "severity": _weighted(rng, C.DEFECT_SEVERITIES),
            "subsystem": C.DEFECT_SUBSYSTEMS[rng.randrange(len(C.DEFECT_SUBSYSTEMS))],
            "status": _weighted(rng, C.DEFECT_STATUSES),
            "summary": C.DEFECT_SUMMARIES[rng.randrange(len(C.DEFECT_SUMMARIES))],
            "root_cause": C.DEFECT_ROOT_CAUSES[rng.randrange(len(C.DEFECT_ROOT_CAUSES))],
            "classification": "THIRD_PARTY_PROPRIETARY" if restricted else "INTERNAL",
        })
    return rows
```

- [ ] **Step 5: Run test to verify it passes**

Run: `cd data && python -m pytest generators/tests/test_defect_reports.py -v`
Expected: PASS, 6 tests

- [ ] **Step 6: Commit**

```bash
git add data/generators/config.py data/generators/build.py data/generators/tests/test_defect_reports.py
git commit -m "feat(data): defect_reports, mixed sensitivity by row (3PPI)"
```

---

### Task 3: Wire both tables through every declaration site

**Files:**
- Modify: `data/generators/build.py` (`build_tables`, docstring)
- Modify: `data/generators/tests/expected_counts.json`
- Modify: `data/seed/schema-manifest.json`
- Modify: `data/seed/README.md`, `data/seed/seed.ps1`, `data/seed/sql/sql-seed.psm1` (prose only)
- Test: `data/seed/tests/schema-parity.Tests.ps1` (existing — must pass unchanged)

**Interfaces:**
- Consumes: `gen_hr_roster()`, `gen_defect_reports(vehicles, suppliers)` from Tasks 1–2
- Produces: `build_tables()` returns twelve tables keyed by `config.TABLE_ORDER`

- [ ] **Step 1: Run the parity test to see it fail**

Run: `pwsh -NoProfile -Command "Invoke-Pester data/seed/tests/schema-parity.Tests.ps1 -Output Detailed"`
Expected: FAIL — `TABLE_ORDER` now names `hr_roster` / `defect_reports` but `schema-manifest.json` does not.

This test is the F145 guard: the table list feeds several readers, and this is what catches a half-widened list.

- [ ] **Step 2: Update `build_tables()`**

In `data/generators/build.py`, change the docstring `"""Build all ten tables."""` to `"""Build all twelve tables."""`, then inside:

```python
    hr_roster = gen_hr_roster()
    defect_reports = gen_defect_reports(vehicles, suppliers)
```

and add to the `generated` dict:

```python
        "hr_roster": hr_roster,
        "defect_reports": defect_reports,
```

- [ ] **Step 3: Update `expected_counts.json`**

Add two entries to `data/generators/tests/expected_counts.json`:

```json
  "hr_roster": 240,
  "defect_reports": 900
```

- [ ] **Step 4: Update `schema-manifest.json`**

Add `"hr_roster"` and `"defect_reports"` to `load_order`, and add table entries under `tables` matching the existing shape. Read one existing entry first and copy its structure exactly — do not invent fields.

Mark both as lakehouse-only, the way `findings_history` is (it has no file in `data/seed/sql/`).

- [ ] **Step 5: Update the "ten tables" prose**

Replace "ten tables" / "ten CSVs" with "twelve" in: `data/seed/README.md`, `data/seed/seed.ps1`, `data/seed/sql/sql-seed.psm1`, `data/generators/build.py`.

Note `data/seed/sql/sql-seed.psm1` describes the **Azure SQL** half, which still loads ten — check each occurrence and only change the ones describing the full set. Read the surrounding sentence before editing.

- [ ] **Step 6: Run all data tests**

Run: `cd data && python -m pytest generators/tests -v`
Run: `pwsh -NoProfile -Command "Invoke-Pester data/seed/tests -Output Detailed"`
Expected: PASS, including `schema-parity.Tests.ps1`

- [ ] **Step 7: Commit**

```bash
git add data/
git commit -m "feat(data): wire hr_roster and defect_reports through every declaration site"
```

---

### Task 4: The two Purview labels

**Files:**
- Modify: `infra/purview/labels.ps1`
- Test: `infra/purview/tests/labels.Tests.ps1`

**Interfaces:**
- Consumes: `Get-LabelDefinition -Prefix <string>`
- Produces: six label definitions, adding `$Prefix-hr-sensitive` and `$Prefix-3ppi`

- [ ] **Step 1: Write the failing test**

Add to `infra/purview/tests/labels.Tests.ps1`:

```powershell
Describe 'Get-LabelDefinition - the two tiered-access labels' {
    It 'defines a distinct label for HR-sensitive and third-party proprietary data' {
        $labels = Get-LabelDefinition -Prefix 'acme'
        $names = $labels.Name
        $names | Should -Contain 'acme-hr-sensitive'
        $names | Should -Contain 'acme-3ppi'
    }

    It 'gives every label a Name equal to its DisplayName' {
        # Both Get-Label -Identity (Name) and layer-04-audit.ps1 (DisplayName)
        # must address the same objects.
        foreach ($label in Get-LabelDefinition -Prefix 'acme') {
            $label.Name | Should -BeExactly $label.DisplayName
        }
    }

    It 'gives every label a non-empty tooltip' {
        foreach ($label in Get-LabelDefinition -Prefix 'acme') {
            $label.Tooltip | Should -Not -BeNullOrEmpty
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -Command "Invoke-Pester infra/purview/tests/labels.Tests.ps1 -Output Detailed"`
Expected: FAIL — `acme-hr-sensitive` not found

- [ ] **Step 3: Add the definitions**

In `infra/purview/labels.ps1`, inside `Get-LabelDefinition`'s returned array, after the `export-controlled` entry:

```powershell
        [pscustomobject]@{
            Name        = "$Prefix-hr-sensitive"
            DisplayName = "$Prefix-hr-sensitive"
            Tooltip     = 'Workforce data with restricted attributes: compensation, bonus target, performance band. Classification only - access is enforced by column-level security at the data layer.'
        }
        [pscustomobject]@{
            Name        = "$Prefix-3ppi"
            DisplayName = "$Prefix-3ppi"
            Tooltip     = 'Third-party proprietary information received under agreement. Classification only - access is enforced by row-level security at the data layer.'
        }
```

Both tooltips state what the label does NOT do. A label does not gate a read; believing it did is finding F18.

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoProfile -Command "Invoke-Pester infra/purview/tests/labels.Tests.ps1 -Output Detailed"`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add infra/purview/
git commit -m "feat(L4): hr-sensitive and 3ppi labels, with tooltips that say what a label does not do"
```

---

### Task 5: `protect-tables.ps1` — roles, CLS and RLS

**Files:**
- Create: `infra/fabric/protect-tables.ps1`
- Create: `infra/fabric/tests/protect-tables.Tests.ps1`

**Interfaces:**
- Consumes: `$SqlEndpoint`, `$Database`, `$AccessToken`, `$Prefix`, `$StandardPrincipal`, `$PrivilegedPrincipal`
- Produces: `Get-ProtectionStatement -Prefix <string>` returning an ordered list of `[pscustomobject]@{ Key; Sql; Idempotent }`; `Invoke-TableProtection` applying them

**Design notes (proven by the 2026-09-20 spike, not assumed):**
- RLS binds to a **schema-bound view**, not the base table. `CREATE VIEW … WITH SCHEMABINDING` over a Delta table works; the predicate must be an inline TVF `WITH SCHEMABINDING`; the predicate parameter type must match the bound column's type.
- CLS is `DENY SELECT ON dbo.<table>(<column>) TO <role>` and works directly on the base table.
- Both are visible in `sys.security_policies` / `sys.database_permissions`, which is what Task 8 verifies.

- [ ] **Step 1: Write the failing test**

Create `infra/fabric/tests/protect-tables.Tests.ps1`:

```powershell
BeforeAll {
    . "$PSScriptRoot/../protect-tables.ps1" -DotSourceOnly
}

Describe 'Get-ProtectionStatement' {
    It 'prefixes every role it creates' {
        $sql = (Get-ProtectionStatement -Prefix 'acme' | ForEach-Object Sql) -join "`n"
        $sql | Should -Match 'acme_data_standard'
        $sql | Should -Match 'acme_data_privileged'
        # F90: a hardcoded mls here is the half of a rebrand nobody sees.
        $sql | Should -Not -Match '\bmls_data_'
    }

    It 'denies exactly the three restricted hr_roster columns' {
        $deny = Get-ProtectionStatement -Prefix 'acme' | Where-Object Key -eq 'cls_hr_roster'
        $deny.Sql | Should -Match 'salary_usd'
        $deny.Sql | Should -Match 'bonus_target_pct'
        $deny.Sql | Should -Match 'performance_band'
    }

    It 'never denies an open column' {
        $deny = Get-ProtectionStatement -Prefix 'acme' | Where-Object Key -eq 'cls_hr_roster'
        foreach ($open in 'start_date', 'department', 'display_name', 'job_family') {
            $deny.Sql | Should -Not -Match $open
        }
    }

    It 'creates the RLS predicate WITH SCHEMABINDING' {
        # The spike proved a policy cannot bind to a non-schema-bound object.
        $pred = Get-ProtectionStatement -Prefix 'acme' | Where-Object Key -eq 'rls_predicate'
        $pred.Sql | Should -Match 'WITH SCHEMABINDING'
    }

    It 'creates the secure view WITH SCHEMABINDING' {
        $view = Get-ProtectionStatement -Prefix 'acme' | Where-Object Key -eq 'rls_view'
        $view.Sql | Should -Match 'WITH SCHEMABINDING'
    }

    It 'enables the security policy' {
        $pol = Get-ProtectionStatement -Prefix 'acme' | Where-Object Key -eq 'rls_policy'
        $pol.Sql | Should -Match 'STATE\s*=\s*ON'
    }

    It 'orders statements so each dependency exists before its dependent' {
        $keys = (Get-ProtectionStatement -Prefix 'acme').Key
        $keys.IndexOf('rls_view')      | Should -BeLessThan $keys.IndexOf('rls_policy')
        $keys.IndexOf('rls_predicate') | Should -BeLessThan $keys.IndexOf('rls_policy')
        $keys.IndexOf('role_standard') | Should -BeLessThan $keys.IndexOf('cls_hr_roster')
    }

    It 'marks every statement idempotent' {
        # Replay is the standard remediation; a second run must not throw.
        foreach ($s in Get-ProtectionStatement -Prefix 'acme') {
            $s.Idempotent | Should -BeTrue
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -Command "Invoke-Pester infra/fabric/tests/protect-tables.Tests.ps1 -Output Detailed"`
Expected: FAIL — `protect-tables.ps1` does not exist

- [ ] **Step 3: Write `infra/fabric/protect-tables.ps1`**

Write the file with the Write tool (never a heredoc). It must:

1. Accept `-DotSourceOnly` so the Pester file can load the functions without executing anything.
2. Define `Get-ProtectionStatement -Prefix` returning, in this order, with `Key` / `Sql` / `Idempotent = $true`:
   - `role_standard` — `IF DATABASE_PRINCIPAL_ID('<p>_data_standard') IS NULL CREATE ROLE [<p>_data_standard]`
   - `role_privileged` — same shape for `<p>_data_privileged`
   - `grant_hr_open` — `GRANT SELECT ON dbo.hr_roster TO [<p>_data_standard]`
   - `cls_hr_roster` — `DENY SELECT ON dbo.hr_roster(salary_usd, bonus_target_pct, performance_band) TO [<p>_data_standard]`
   - `rls_predicate` — `CREATE FUNCTION dbo.fn_defect_tier(@classification varchar(64)) RETURNS TABLE WITH SCHEMABINDING AS RETURN SELECT 1 AS ok WHERE @classification <> 'THIRD_PARTY_PROPRIETARY' OR IS_ROLEMEMBER('<p>_data_privileged') = 1`, wrapped in an existence guard
   - `rls_view` — `CREATE VIEW dbo.v_defect_reports WITH SCHEMABINDING AS SELECT defect_id, vehicle_id, supplier_id, reported_date, severity, subsystem, status, summary, root_cause, classification FROM dbo.defect_reports`, guarded
   - `rls_policy` — `CREATE SECURITY POLICY dbo.sp_defect_tier ADD FILTER PREDICATE dbo.fn_defect_tier(classification) ON dbo.v_defect_reports WITH (STATE = ON)`, guarded
   - `grant_view` — `GRANT SELECT ON dbo.v_defect_reports TO [<p>_data_standard]`
   - `deny_base` — `DENY SELECT ON dbo.defect_reports TO [<p>_data_standard]` (the view is the only door)
   - `members` — add `$StandardPrincipal` / `$PrivilegedPrincipal` to their roles, guarded by `IS_ROLEMEMBER`
3. Define `Invoke-TableProtection` which runs them in order via `Invoke-Sqlcmd -AccessToken`, reports **every** statement's outcome and fails at the end rather than at the first error (CLAUDE.md: a run returns everything it saw).
4. Resolve the column list for `rls_view` from `INFORMATION_SCHEMA.COLUMNS` at runtime and fail loudly if it disagrees with the hardcoded list — the spike failed twice on a column name written from memory.

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoProfile -Command "Invoke-Pester infra/fabric/tests/protect-tables.Tests.ps1 -Output Detailed"`
Expected: PASS, 8 tests

- [ ] **Step 5: Commit**

```bash
git add infra/fabric/protect-tables.ps1 infra/fabric/tests/protect-tables.Tests.ps1
git commit -m "feat(L4): CLS and RLS over the two mixed-sensitivity tables"
```

---

### Task 6: Teardown for the protection objects

**Files:**
- Create: `infra/fabric/teardown-protection.ps1`
- Create: `infra/fabric/tests/teardown-protection.Tests.ps1`

**Interfaces:**
- Consumes: `Get-ProtectionStatement` key list from Task 5
- Produces: `Get-TeardownStatement -Prefix <string>` returning drops in reverse dependency order

A layer without all three of deploy, teardown and audit is not done (CLAUDE.md).

- [ ] **Step 1: Write the failing test**

Create `infra/fabric/tests/teardown-protection.Tests.ps1`:

```powershell
BeforeAll {
    . "$PSScriptRoot/../teardown-protection.ps1" -DotSourceOnly
    . "$PSScriptRoot/../protect-tables.ps1" -DotSourceOnly
}

Describe 'Get-TeardownStatement' {
    It 'drops the policy before the objects it binds to' {
        $keys = (Get-TeardownStatement -Prefix 'acme').Key
        $keys.IndexOf('rls_policy') | Should -BeLessThan $keys.IndexOf('rls_view')
        $keys.IndexOf('rls_policy') | Should -BeLessThan $keys.IndexOf('rls_predicate')
    }

    It 'is the exact inverse of the protection statement set' {
        $made = (Get-ProtectionStatement -Prefix 'acme').Key | Sort-Object -Unique
        $dropped = (Get-TeardownStatement -Prefix 'acme').Key | Sort-Object -Unique
        # Every object created must have a drop. A teardown that misses one
        # leaves an object a rebuild then collides with.
        foreach ($k in 'rls_policy', 'rls_view', 'rls_predicate', 'role_standard', 'role_privileged') {
            $dropped | Should -Contain $k
        }
    }

    It 'never drops a base table' {
        # Teardown removes PROTECTION, not DATA. L5 owns the tables.
        $sql = (Get-TeardownStatement -Prefix 'acme' | ForEach-Object Sql) -join "`n"
        $sql | Should -Not -Match 'DROP TABLE'
        $sql | Should -Not -Match 'hr_roster\s*$'
    }

    It 'uses IF EXISTS everywhere so replay is safe' {
        foreach ($s in Get-TeardownStatement -Prefix 'acme') {
            $s.Sql | Should -Match 'IF EXISTS'
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -Command "Invoke-Pester infra/fabric/tests/teardown-protection.Tests.ps1 -Output Detailed"`
Expected: FAIL — `teardown-protection.ps1` does not exist

- [ ] **Step 3: Write `infra/fabric/teardown-protection.ps1`**

Same shape as Task 5. Drop order: `rls_policy`, `rls_view`, `rls_predicate`, `cls_hr_roster` (revoke), `role_standard`, `role_privileged`. Every statement uses `DROP … IF EXISTS`.

This is **not** a G3 action: these are database objects inside the lakehouse, not tenant-level objects, and RG-scoped teardown of demo resources is gate-free by design.

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoProfile -Command "Invoke-Pester infra/fabric/tests/teardown-protection.Tests.ps1 -Output Detailed"`
Expected: PASS, 4 tests

- [ ] **Step 5: Commit**

```bash
git add infra/fabric/teardown-protection.ps1 infra/fabric/tests/teardown-protection.Tests.ps1
git commit -m "infra(L4): teardown for the protection objects, data untouched"
```

---

### Task 7: Wire protection into the L4 workflow

**Files:**
- Modify: `.github/workflows/layer-04-purview.yml`

**Interfaces:**
- Consumes: `infra/fabric/protect-tables.ps1` from Task 5
- Produces: an L4 run that applies protection to the live lakehouse

- [ ] **Step 1: Read the existing workflow**

Read `.github/workflows/layer-04-purview.yml` in full before editing. Match its existing auth pattern, its step naming, and how it acquires tokens.

- [ ] **Step 2: Add the protection step**

After the label step, add a step that:
- resolves the SQL endpoint **from the Fabric API** (never a stored FQDN — F129; the ACA-style stored-name failure is the same class)
- mints a token for `https://database.windows.net/.default`
- runs `infra/fabric/protect-tables.ps1` with `-Prefix ${{ vars.MLS_COMPANY_PREFIX }}`

Do **not** add `continue-on-error`. A step allowed to fail is a step nobody is watching (F119) — and if it is ever added, something must assert the state it was supposed to produce.

- [ ] **Step 3: Lint the workflow**

Run: `pwsh -NoProfile -Command "actionlint .github/workflows/layer-04-purview.yml"` (or the repo's existing actionlint invocation — check `lint-ci.yml` for the exact command)
Expected: no findings

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/layer-04-purview.yml
git commit -m "infra(L4): apply table protection in the deploy path, so a rebuild reproduces it"
```

---

### Task 8: V5.5 and V5.6 — the tables exist and carry both sensitivity classes

**Files:**
- Modify: `verification/layer-05-audit.ps1`
- Modify: `verification/tests/layer-05-audit.Tests.ps1`

**Interfaces:**
- Consumes: `Invoke-MlsSqlQuery` from `verification/MlsAudit.psm1`
- Produces: criteria `V5.5`, `V5.6`

L5 currently ends at V5.4 (confirmed 2026-09-20).

- [ ] **Step 1: Write the failing test**

Add to `verification/tests/layer-05-audit.Tests.ps1`:

```powershell
Describe 'V5.5 / V5.6 registration' {
    It 'registers both new criteria' {
        $ids = Get-MlsCriterionId -Layer 5
        $ids | Should -Contain 'V5.5'
        $ids | Should -Contain 'V5.6'
    }

    It 'V5.5 asserts row counts rather than a status code' {
        # The V7.6 lesson: a layer that verifies plumbing without verifying
        # water is how an empty estate signed off 5/5 for two days.
        $text = Get-Content "$PSScriptRoot/../layer-05-audit.ps1" -Raw
        $text | Should -Match 'hr_roster'
        $text | Should -Match 'defect_reports'
    }
}
```

Adjust `Get-MlsCriterionId` to whatever the existing tests use to enumerate criteria — read the file first and follow its established pattern rather than inventing a helper.

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -Command "Invoke-Pester verification/tests/layer-05-audit.Tests.ps1 -Output Detailed"`
Expected: FAIL — V5.5 not registered

- [ ] **Step 3: Implement the criteria**

In `verification/layer-05-audit.ps1`, following the existing criterion shape:

- **V5.5** — `SELECT COUNT(*) FROM dbo.hr_roster` and `FROM dbo.defect_reports`. PASS requires 240 and 900 exactly. A zero row count is FAIL, not PASS.
- **V5.6** — `SELECT classification, COUNT(*) FROM dbo.defect_reports GROUP BY classification`. PASS requires **both** `INTERNAL` and `THIRD_PARTY_PROPRIETARY` present with non-zero counts.

If the query cannot run at all, report **UNOBSERVABLE**, never "the table is empty". Fabric answers a caller without OneLake read using an empty result rather than a denial (F105), so absence here is unprovable without establishing that you could observe.

Declare an explicit wait window and say what it waits on. Do not inherit a default (the nineteen-criteria lesson).

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoProfile -Command "Invoke-Pester verification/tests/layer-05-audit.Tests.ps1 -Output Detailed"`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add verification/layer-05-audit.ps1 verification/tests/layer-05-audit.Tests.ps1
git commit -m "verify(L5): V5.5 rows exist, V5.6 both sensitivity classes present"
```

---

### Task 9: V4.4–V4.6 — and V4.5 proves enforcement by being refused

**Files:**
- Modify: `verification/layer-04-audit.ps1`
- Modify: `verification/tests/layer-04-audit.Tests.ps1`

**Interfaces:**
- Consumes: `Invoke-MlsSqlQuery`; the role names from Task 5
- Produces: criteria `V4.4`, `V4.5`, `V4.6`

L4 currently ends at V4.3 (confirmed 2026-09-20).

- [ ] **Step 1: Write the failing test**

Add to `verification/tests/layer-04-audit.Tests.ps1`:

```powershell
Describe 'V4.4 / V4.5 / V4.6 registration' {
    It 'registers all three new criteria' {
        $ids = Get-MlsCriterionId -Layer 4
        foreach ($id in 'V4.4', 'V4.5', 'V4.6') { $ids | Should -Contain $id }
    }

    It 'V4.5 asserts a REFUSAL, not the presence of a policy object' {
        # Break-glass readiness meant "an account is in the group" and passed on
        # one holding no role. V3.3 meant "an enabled CA policy exists" and failed
        # on a tenant whose MFA came from Security Defaults. Assert the capability.
        $text = Get-Content "$PSScriptRoot/../layer-04-audit.ps1" -Raw
        $text | Should -Match 'EXECUTE AS'
        $text | Should -Match 'salary_usd'
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -Command "Invoke-Pester verification/tests/layer-04-audit.Tests.ps1 -Output Detailed"`
Expected: FAIL — V4.4 not registered

- [ ] **Step 3: Implement the criteria**

- **V4.4 — the objects exist.** `SELECT name, is_enabled FROM sys.security_policies WHERE name = 'sp_defect_tier'` must return `is_enabled = 1`; `sys.database_permissions` must show the three column DENYs against the standard role. This is the artefact check and it is the weaker one.
- **V4.5 — the control actually controls.** `EXECUTE AS USER = '<prefix>_data_standard'`, then:
  - `SELECT salary_usd FROM dbo.hr_roster` — **must fail** with a permission error. If it succeeds, V4.5 FAILS.
  - `SELECT COUNT(*) FROM dbo.v_defect_reports` — must return **fewer** rows than the same query under the privileged role.
  - `REVERT`.

  A PASS requires the denial to have actually happened. **A query that errors for any other reason is UNOBSERVABLE, not PASS** — check the error is a permission error specifically, or the criterion reports a wrong verdict confidently, which is the defect family this repository spends its budget preventing.
- **V4.6 — the labels exist.** Both `<prefix>-hr-sensitive` and `<prefix>-3ppi` present, matched on DisplayName exactly as V4.1 does.

**No criterion may assert that a label enforces access.** It does not.

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoProfile -Command "Invoke-Pester verification/tests/layer-04-audit.Tests.ps1 -Output Detailed"`
Expected: PASS

- [ ] **Step 5: Run the full local gauntlet**

Run: `pwsh -NoProfile -Command "Invoke-Pester verification/tests -Output Detailed"`
Run: `cd data && python -m pytest generators/tests -v`
Expected: PASS, no regressions

- [ ] **Step 6: Commit**

```bash
git add verification/
git commit -m "verify(L4): V4.4 objects, V4.5 the standard role is genuinely refused, V4.6 labels"
```

---

## Self-Review

**Spec coverage:**

| Spec section | Task |
|---|---|
| § 4.1 `hr_roster` | Task 1 |
| § 4.2 `defect_reports` | Task 2 |
| § 4.3 two failure modes | Tasks 5 (RLS silent / CLS loud), 9 (V4.5 asserts both) |
| § 5.1 database objects | Task 5 |
| § 5.4 naming | Task 5 test "prefixes every role" |
| § 8 classification labels | Task 4 |
| § 11 V5.5, V5.6 | Task 8 |
| § 11 V4.4, V4.5, V4.6 | Task 9 |
| Triplet: deploy / teardown / audit | Tasks 7 / 6 / 8–9 |

**Deferred to later plans, by design** (§ 5.2 second identity, § 5.3 MCP tiering, § 6 Ask box, § 7 audit legs, § 10 Copilot Studio). Each is independently shippable and none is required for this plan's deliverable to be demonstrable at the SQL layer.

**Known gaps carried deliberately:**

1. **§ 5.2's privileged identity does not exist yet.** Task 5 takes principals as parameters, so this plan is complete without it; role *membership* is only meaningful once the second identity lands in the next plan. V4.5 works regardless because `EXECUTE AS USER` needs no real principal.
2. **§ 12 Q1 (can a low-privileged principal read `queryinsights`?) is unresolved** and belongs to the audit plan, not this one.
3. **§ 12 Q2 is now RESOLVED and it is a finding:** `groupMembershipClaims` is `null` on `mls-control-tower-demo-app` (verified 2026-09-20). Group claims do **not** reach `/.auth/me` today. The one-box design needs a tokenised change to `infra/entra/manifest.json` — that is a task in the control-tower plan, and it must be verified *live* before the Ask box is wired, per F135.

**Type consistency:** `Get-ProtectionStatement` / `Get-TeardownStatement` both return `Key` / `Sql` / `Idempotent`, used consistently in Tasks 5, 6 and 9. Role names `<prefix>_data_standard` / `<prefix>_data_privileged` are identical across Tasks 5, 6, 9. Table and column names match Tasks 1–2 exactly.

**Placeholder scan:** no TBD/TODO. Tasks 3, 5, 6, 7 and 8 contain instructions to *read an existing file and follow its pattern* rather than inline code — deliberate, because inventing a shape that contradicts the existing one is worse than reading it, and the spike proved twice over that writing another system's names from memory is this repo's most reliable way to waste an hour.
