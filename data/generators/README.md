# generators — synthetic data for Meridian Launch Systems

Deterministic synthetic launch-industry dataset for the MLS demo (Phase P,
Track A; seeds the L5 lakehouse tables). Pure Python stdlib — no runtime
dependencies. Real vehicle names and launch sites are public facts; every
company, customer, supplier, and person is fictional.

## Usage

From the `data/` directory:

```
python -m generators build            # CSV + JSON per table -> data/generated/ (gitignored)
python -m generators build --out DIR  # write elsewhere
python -m generators summary          # row counts + launches-by-weekday
```

Tests (pytest is the only dependency, see `requirements.txt`):

```
python -m pytest generators/tests
```

## Determinism

- Master seed `20260822` is hardcoded in `config.py` (fixed by the Phase P plan).
- Each table draws from its own child RNG (`random.Random(f"{SEED}:{table}")`),
  so tables are independent of each other's draw counts.
- No time-of-run anywhere: all calendar windows are fixed constants
  (launch window 2021-01-04 .. 2026-06-21). A test greps the source for
  wall-clock calls.
- Output is byte-stable: UTF-8, LF newlines, fixed column order. Building twice
  produces sha256-identical files (asserted in tests).

## Tables

Null handling: CSV renders null as an empty string; JSON uses native `null`.
Booleans: `True`/`False` in CSV, native in JSON. Dates are ISO `YYYY-MM-DD`.

### launches (exactly 1,200 rows)
| column | type | notes |
|---|---|---|
| launch_id | str PK | `LNH-0001`.. |
| mission_name | str | `<customer code>-<seq>`, e.g. `AUR-014` |
| vehicle_id | str FK -> vehicles | only vehicles active in that year |
| pad_id | str FK -> pads | vehicle/pad compatibility enforced |
| customer | str, dirty | fictional customer (16-name pool) |
| orbit | str | LEO / SSO / GTO / MEO / HEO / ISS / TLI, by vehicle class |
| planned_date | date | `actual_date` minus slip (0–14 days) |
| actual_date | date | weekday-biased: **Saturday is the argmax** |
| outcome | str | success 93% / partial_failure 3% / failure 4% |
| payload_mass_kg | float | 18–92% of vehicle capacity for the orbit |
| weather_delay_min | int, nullable | same-day hold; 0 for 60% of launches |
| scrub_count | int | 0–3; equals this launch's rows in `scrubs` |
| booster_recovery | str | droneship / RTLS / expended |
| insurance_value_musd | float, nullable | 20–420 |

### scrubs (derived; 475 rows at the default seed)
scrub_id PK, launch_id FK, scrub_date, category (weather/technical/range/payload),
reason, called_at_t_minus_s (hold point in seconds), recycle_hours (nullable).
Multi-scrub launches are weather cascades with probability 0.65: consecutive-day
scrubs starting at the planned date (weather stand-down behavior).

### vehicles (12 rows, static)
vehicle_id PK, name (real vehicles: Falcon 9 Block 5, Electron, Vulcan Centaur,
…), vehicle_class (small/medium/heavy), fleet_group, stages, reusable,
leo_capacity_kg, gto_capacity_kg (null for smalls), height_m, first_flight_year,
last_flight_year (null if active), status.

### pads (11 rows, static)
pad_id PK, name (real pads: SLC-40, LC-39A, LC-1A, ELA-4, LA-Y2, …), site,
country, latitude, longitude, first_used_year, status.

### telemetry_summary (one row per launch: 1,200)
telemetry_id PK, launch_id FK, max_q_kpa, max_accel_g, meco_time_s,
peak_thrust_kn, max_altitude_km (orbit-dependent apogee), anomaly_count
(elevated on failures), telemetry_coverage_pct (degraded on failures),
data_dropout_s (nullable).

### parts (300 rows)
part_id PK, part_number, name, category (Propulsion/Structures/Avionics/GNC/
Pressurization/Recovery/Ground Support), supplier_id FK, unit_cost_usd
(lognormal around a category base), lead_time_days (**outliers**: see knobs),
qty_on_hand, min_stock, criticality (1–3), material (nullable, dirty).

### suppliers (24 rows)
supplier_id PK, name (fictional), country, certification, avg_lead_time_days
(10–45 base), on_time_pct, quality_rating, active.

### work_orders (800 rows)
work_order_id PK, part_id FK, vehicle_id FK, launch_id (nullable FK, ~60% set),
opened_date, closed_date (null while open/in_progress), status
(closed 75% / in_progress 15% / open 10%), disposition (closed only:
repair/replace/use-as-is/scrap), priority (P1–P4), labor_hours, technician
(fictional, dirty).

### cost_daily (5 centers x 903 days = 4,515 rows; 2024-01-01 .. 2026-06-21)
cost_id PK, date, cost_center (Propulsion / Avionics / Range Operations /
Facilities / Cloud & IT), amount_usd (seasonal sine + lognormal noise; Range
Operations spikes ~$4–9k per launch that day), budget_usd, currency.

### findings_history (420 rows; opened 2025-01-01 .. 2026-06-01)
finding_id PK, source (CodeQL/Dependabot/Trivy/ZAP/Defender for Cloud),
severity (critical/high/medium/low), title, component (repo path), cve_id
(nullable; Dependabot/Trivy only), opened_date, closed_date (nullable), status
(resolved/open/risk_accepted), assignee (fictional), sla_days (by severity).

## Messiness knobs (`config.py`; bounds asserted in `tests/test_messiness.py`)

| knob | default | effect |
|---|---|---|
| `WEEKDAY_WEIGHTS` | `[10,11,12,12,14,26,15]` (Mon..Sun) | launch weekday bias; Saturday (index 5) must stay the strict argmax — pytest and the copilot golden-question eval both assert it |
| `NULL_RATE` | 0.03 | fraction of `NULLABLE_COLUMNS` values set to null (tested within 0.005–0.08) |
| `DIRTY_RATE` | 0.06 | fraction of `DIRTY_COLUMNS` values given casing/whitespace damage: UPPER, lower, leading/trailing space, doubled inner space (tested within 0.02–0.12) |
| `LEAD_TIME_OUTLIER_RATE` | 0.07 | fraction of parts whose lead time is multiplied 4–9x (supply-chain outliers; tested within 0.02–0.15, max > 200 d, median < 60 d) |
| `DELAY_PROB` | 0.30 | probability a launch slips >= 1 day past its planned date |
| `CASCADE_PROB` | 0.65 | probability a multi-scrub launch is a consecutive-day weather cascade (tested: >= 25 consecutive-day weather scrub pairs) |

`NULLABLE_COLUMNS`: launches.weather_delay_min, launches.insurance_value_musd,
scrubs.recycle_hours, telemetry_summary.data_dropout_s, parts.material.
`DIRTY_COLUMNS`: launches.customer, parts.material, work_orders.technician.

Changing any knob (or anything in `config.py`/`pools.py`) changes the generated
bytes — treat edits as schema changes and re-run the test suite.
