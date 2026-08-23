"""Deterministic table generators for the Meridian Launch Systems demo dataset.

All randomness derives from config.SEED via per-table child RNGs
(`random.Random(f"{SEED}:{table}")`), so each table's stream is stable even if
another table's logic changes. Nothing here may read the clock, the
environment, or the filesystem.
"""

import math
import random
from datetime import date, timedelta

from . import config as C
from . import pools as P


def _rng(table_name):
    # Seeding with a string is deterministic (SHA-512 based) and independent
    # of PYTHONHASHSEED.
    return random.Random(f"{C.SEED}:{table_name}")


def _maybe_null(rng, value):
    return None if rng.random() < C.NULL_RATE else value


def _dirty(rng, value):
    """Reproducibly damage a string's casing/whitespace at DIRTY_RATE."""
    if rng.random() >= C.DIRTY_RATE:
        return value
    style = rng.choice(["upper", "lower", "lead_ws", "trail_ws", "double_space"])
    if style == "upper":
        return value.upper()
    if style == "lower":
        return value.lower()
    if style == "lead_ws":
        return "  " + value
    if style == "trail_ws":
        return value + " "
    return value.replace(" ", "  ", 1)


def _weighted(rng, pairs):
    values = [v for v, _ in pairs]
    weights = [w for _, w in pairs]
    return rng.choices(values, weights=weights, k=1)[0]


def _rand_date(rng, start, end):
    return start + timedelta(days=rng.randrange((end - start).days + 1))


# ---------------------------------------------------------------------------
# Static reference tables
# ---------------------------------------------------------------------------

def gen_vehicles():
    rows = []
    for v in P.VEHICLES:
        rows.append({
            "vehicle_id": v["vehicle_id"],
            "name": v["name"],
            "vehicle_class": v["vehicle_class"],
            "fleet_group": P.FLEET_GROUPS[v["vehicle_class"]],
            "stages": v["stages"],
            "reusable": v["reusable"],
            "leo_capacity_kg": v["leo_capacity_kg"],
            "gto_capacity_kg": v["gto_capacity_kg"],
            "height_m": v["height_m"],
            "first_flight_year": v["first_flight_year"],
            "last_flight_year": v["last_flight_year"],
            "status": "retired" if v["last_flight_year"] is not None else "active",
        })
    return rows


def gen_pads():
    return [dict(p) for p in P.PADS]


# ---------------------------------------------------------------------------
# Suppliers and parts
# ---------------------------------------------------------------------------

def gen_suppliers():
    rng = _rng("suppliers")
    rows = []
    for i, name in enumerate(P.SUPPLIER_NAMES, start=1):
        rows.append({
            "supplier_id": f"SUP-{i:03d}",
            "name": name,
            "country": rng.choice(P.SUPPLIER_COUNTRIES),
            "certification": rng.choice(P.SUPPLIER_CERTS),
            "avg_lead_time_days": rng.randint(10, 45),
            "on_time_pct": round(rng.uniform(82.0, 99.5), 1),
            "quality_rating": round(rng.uniform(2.8, 5.0), 1),
            "active": rng.random() < 0.9,
        })
    return rows


def gen_parts(suppliers):
    rng = _rng("parts")
    categories = list(P.PART_CATALOG.keys())
    rows = []
    for i in range(1, C.N_PARTS + 1):
        supplier = rng.choice(suppliers)
        category = rng.choice(categories)
        code, names = P.PART_CATALOG[category]
        base_cost = P.PART_COST_BASE[category]

        lead = supplier["avg_lead_time_days"] * rng.lognormvariate(0.0, 0.30)
        if rng.random() < C.LEAD_TIME_OUTLIER_RATE:
            lead *= rng.uniform(4.0, 9.0)  # supply-chain outlier
        material = _maybe_null(rng, rng.choice(P.MATERIALS))
        if material is not None:
            material = _dirty(rng, material)
        rows.append({
            "part_id": f"PRT-{i:04d}",
            "part_number": f"{code}-{rng.randint(1000, 9999)}-{rng.choice('ABCDEF')}",
            "name": rng.choice(names),
            "category": category,
            "supplier_id": supplier["supplier_id"],
            "unit_cost_usd": round(base_cost * rng.lognormvariate(0.0, 0.5), 2),
            "lead_time_days": max(3, int(round(lead))),
            "qty_on_hand": rng.randint(0, 40),
            "min_stock": rng.randint(1, 10),
            "criticality": _weighted(rng, [(1, 20), (2, 50), (3, 30)]),
            "material": material,
        })
    return rows


# ---------------------------------------------------------------------------
# Launches
# ---------------------------------------------------------------------------

def gen_launches(vehicles):
    rng = _rng("launches")
    weekdays = list(range(7))
    mission_counters = {}
    rows = []
    meta = []  # (launch_id, planned: date, delay_days, scrub_count)

    for i in range(1, C.N_LAUNCHES + 1):
        # Date: uniform week + weighted weekday => exact Saturday bias.
        week = rng.randrange(C.N_WEEKS)
        weekday = rng.choices(weekdays, weights=C.WEEKDAY_WEIGHTS, k=1)[0]
        actual = C.START_MONDAY + timedelta(weeks=week, days=weekday)

        # Vehicle: only those flying in that year, by fleet weight.
        year = actual.year
        candidates = [
            v for v in vehicles
            if v["first_flight_year"] <= year
            and (v["last_flight_year"] is None or year <= v["last_flight_year"])
        ]
        weights = [P.VEHICLE_WEIGHTS[v["vehicle_id"]] for v in candidates]
        vehicle = rng.choices(candidates, weights=weights, k=1)[0]
        pad_id = rng.choice(P.PAD_COMPAT[vehicle["vehicle_id"]])
        orbit = _weighted(rng, P.ORBITS_BY_CLASS[vehicle["vehicle_class"]])

        # Customer + mission name.
        customer, code, _ = rng.choices(
            P.CUSTOMERS, weights=[w for _, _, w in P.CUSTOMERS], k=1
        )[0]
        mission_counters[code] = mission_counters.get(code, 0) + 1
        mission_name = f"{code}-{mission_counters[code]:03d}"

        # Schedule slip: most launches fly on the planned day.
        if rng.random() < C.DELAY_PROB:
            delay_days = 1 + min(13, int(rng.expovariate(1 / 3.0)))
        else:
            delay_days = 0
        planned = actual - timedelta(days=delay_days)
        if delay_days == 0:
            scrub_count = 0
        else:
            scrub_count = min(delay_days, _weighted(rng, [(1, 60), (2, 30), (3, 10)]))

        outcome = _weighted(
            rng, [("success", 93), ("partial_failure", 3), ("failure", 4)]
        )

        capacity = vehicle["leo_capacity_kg"]
        if orbit == "GTO" and vehicle["gto_capacity_kg"] is not None:
            capacity = vehicle["gto_capacity_kg"]
        payload_mass_kg = round(capacity * rng.uniform(0.18, 0.92), 1)

        weather_delay_min = 0 if rng.random() < 0.6 else rng.randrange(5, 181, 5)
        if vehicle["reusable"]:
            booster_recovery = _weighted(
                rng, [("droneship", 55), ("RTLS", 25), ("expended", 20)]
            )
        else:
            booster_recovery = "expended"

        rows.append({
            "launch_id": f"LNH-{i:04d}",
            "mission_name": mission_name,
            "vehicle_id": vehicle["vehicle_id"],
            "pad_id": pad_id,
            "customer": _dirty(rng, customer),
            "orbit": orbit,
            "planned_date": planned.isoformat(),
            "actual_date": actual.isoformat(),
            "outcome": outcome,
            "payload_mass_kg": payload_mass_kg,
            "weather_delay_min": _maybe_null(rng, weather_delay_min),
            "scrub_count": scrub_count,
            "booster_recovery": booster_recovery,
            "insurance_value_musd": _maybe_null(rng, round(rng.uniform(20.0, 420.0), 1)),
        })
        meta.append((f"LNH-{i:04d}", planned, delay_days, scrub_count))

    return rows, meta


# ---------------------------------------------------------------------------
# Scrubs (weather cascades cluster on consecutive days)
# ---------------------------------------------------------------------------

def gen_scrubs(launch_meta):
    rng = _rng("scrubs")
    rows = []
    scrub_no = 0
    for launch_id, planned, delay_days, scrub_count in launch_meta:
        if scrub_count == 0:
            continue
        cascade = scrub_count >= 2 and rng.random() < C.CASCADE_PROB
        if cascade:
            # Weather stand-down: consecutive days starting at the planned date.
            offsets = list(range(scrub_count))
            categories = ["weather"] * scrub_count
        else:
            offsets = sorted(rng.sample(range(delay_days), scrub_count))
            categories = [
                _weighted(rng, P.SCRUB_CATEGORY_WEIGHTS) for _ in range(scrub_count)
            ]
        for offset, category in zip(offsets, categories):
            scrub_no += 1
            rows.append({
                "scrub_id": f"SCR-{scrub_no:04d}",
                "launch_id": launch_id,
                "scrub_date": (planned + timedelta(days=offset)).isoformat(),
                "category": category,
                "reason": rng.choice(P.SCRUB_REASONS[category]),
                "called_at_t_minus_s": rng.choice(P.SCRUB_HOLD_POINTS_S),
                "recycle_hours": _maybe_null(rng, round(rng.uniform(24.0, 96.0), 1)),
            })
    return rows


# ---------------------------------------------------------------------------
# Telemetry summaries (one per launch)
# ---------------------------------------------------------------------------

_TLM_BASE = {
    #  class     max_q_kpa  max_g   meco_s  thrust_kn
    "small": (26.0, 6.2, 152.0, 240.0),
    "medium": (33.0, 3.9, 162.0, 7600.0),
    "heavy": (36.0, 4.2, 187.0, 22000.0),
}
_APOGEE_KM = {
    "LEO": (400, 650), "SSO": (500, 800), "ISS": (410, 430),
    "GTO": (33000, 37000), "MEO": (19000, 24000), "HEO": (35000, 40000),
    "TLI": (350000, 400000),
}


def gen_telemetry(launches, vehicles):
    rng = _rng("telemetry_summary")
    vclass = {v["vehicle_id"]: v["vehicle_class"] for v in vehicles}
    rows = []
    for i, launch in enumerate(launches, start=1):
        cls = vclass[launch["vehicle_id"]]
        max_q, max_g, meco, thrust = _TLM_BASE[cls]
        lo, hi = _APOGEE_KM[launch["orbit"]]
        anomalies = _weighted(rng, [(0, 70), (1, 20), (2, 7), (3, 3)])
        coverage = round(rng.uniform(97.0, 100.0), 2)
        if launch["outcome"] == "failure":
            anomalies += rng.randint(3, 8)
            coverage = round(rng.uniform(35.0, 90.0), 2)
        elif launch["outcome"] == "partial_failure":
            anomalies += rng.randint(1, 4)
        rows.append({
            "telemetry_id": f"TLM-{i:04d}",
            "launch_id": launch["launch_id"],
            "max_q_kpa": round(max_q * rng.uniform(0.92, 1.08), 1),
            "max_accel_g": round(max_g * rng.uniform(0.9, 1.1), 2),
            "meco_time_s": round(meco * rng.uniform(0.95, 1.05), 1),
            "peak_thrust_kn": round(thrust * rng.uniform(0.97, 1.03), 1),
            "max_altitude_km": round(rng.uniform(lo, hi), 1),
            "anomaly_count": anomalies,
            "telemetry_coverage_pct": coverage,
            "data_dropout_s": _maybe_null(rng, round(rng.uniform(0.0, 45.0), 1)),
        })
    return rows


# ---------------------------------------------------------------------------
# Work orders
# ---------------------------------------------------------------------------

def gen_work_orders(parts, vehicles, launches):
    rng = _rng("work_orders")
    rows = []
    for i in range(1, C.N_WORK_ORDERS + 1):
        part = rng.choice(parts)
        vehicle = rng.choice(vehicles)
        launch_id = rng.choice(launches)["launch_id"] if rng.random() < 0.6 else None
        opened = _rand_date(rng, C.WO_START, C.WO_END)
        status = _weighted(rng, [("closed", 75), ("in_progress", 15), ("open", 10)])
        if status == "closed":
            closed = min(opened + timedelta(days=rng.randint(1, 60)), C.COST_END)
            closed_date = closed.isoformat()
            disposition = _weighted(rng, P.WO_DISPOSITIONS)
        else:
            closed_date = None
            disposition = None
        rows.append({
            "work_order_id": f"WO-{i:05d}",
            "part_id": part["part_id"],
            "vehicle_id": vehicle["vehicle_id"],
            "launch_id": launch_id,
            "opened_date": opened.isoformat(),
            "closed_date": closed_date,
            "status": status,
            "disposition": disposition,
            "priority": _weighted(rng, P.WO_PRIORITIES),
            "labor_hours": round(rng.uniform(1.0, 120.0), 1),
            "technician": _dirty(rng, rng.choice(P.TECHNICIANS)),
        })
    return rows


# ---------------------------------------------------------------------------
# Daily costs (one row per cost center per day; launch days spike Range Ops)
# ---------------------------------------------------------------------------

def gen_cost_daily(launches):
    rng = _rng("cost_daily")
    launches_on = {}
    for r in launches:
        launches_on[r["actual_date"]] = launches_on.get(r["actual_date"], 0) + 1

    rows = []
    cost_no = 0
    n_days = (C.COST_END - C.COST_START).days + 1
    for d in range(n_days):
        day = C.COST_START + timedelta(days=d)
        day_iso = day.isoformat()
        season = 1.0 + 0.08 * math.sin(2 * math.pi * day.timetuple().tm_yday / 365.0)
        for center, base in P.COST_CENTERS:
            cost_no += 1
            amount = base * season * rng.lognormvariate(0.0, 0.10)
            if center == "Range Operations":
                amount += launches_on.get(day_iso, 0) * rng.uniform(4000.0, 9000.0)
            rows.append({
                "cost_id": f"CST-{cost_no:05d}",
                "date": day_iso,
                "cost_center": center,
                "amount_usd": round(amount, 2),
                "budget_usd": round(base * 1.05, 2),
                "currency": "USD",
            })
    return rows


# ---------------------------------------------------------------------------
# Security findings history
# ---------------------------------------------------------------------------

def gen_findings():
    rng = _rng("findings_history")
    rows = []
    for i in range(1, C.N_FINDINGS + 1):
        source = _weighted(rng, P.FINDING_SOURCES)
        severity = _weighted(rng, P.FINDING_SEVERITIES)
        opened = _rand_date(rng, C.FINDINGS_START, C.FINDINGS_END)
        status = _weighted(rng, [("resolved", 60), ("open", 30), ("risk_accepted", 10)])
        if status == "resolved":
            closed_date = (opened + timedelta(days=rng.randint(1, 45))).isoformat()
        else:
            closed_date = None
        if source in ("Dependabot", "Trivy") and rng.random() < 0.7:
            cve_id = f"CVE-{opened.year}-{rng.randint(10000, 49999)}"
        else:
            cve_id = None
        rows.append({
            "finding_id": f"FND-{i:04d}",
            "source": source,
            "severity": severity,
            "title": rng.choice(P.FINDING_TITLES),
            "component": rng.choice(P.FINDING_COMPONENTS),
            "cve_id": cve_id,
            "opened_date": opened.isoformat(),
            "closed_date": closed_date,
            "status": status,
            "assignee": rng.choice(P.ASSIGNEES),
            "sla_days": P.FINDING_SLA_DAYS[severity],
        })
    return rows


# ---------------------------------------------------------------------------
# Assembly
# ---------------------------------------------------------------------------

def build_tables():
    """Build all ten tables. Pure function of config.SEED."""
    vehicles = gen_vehicles()
    pads = gen_pads()
    suppliers = gen_suppliers()
    parts = gen_parts(suppliers)
    launches, launch_meta = gen_launches(vehicles)
    scrubs = gen_scrubs(launch_meta)
    telemetry = gen_telemetry(launches, vehicles)
    work_orders = gen_work_orders(parts, vehicles, launches)
    cost_daily = gen_cost_daily(launches)
    findings = gen_findings()

    generated = {
        "launches": launches,
        "scrubs": scrubs,
        "vehicles": vehicles,
        "pads": pads,
        "telemetry_summary": telemetry,
        "parts": parts,
        "suppliers": suppliers,
        "work_orders": work_orders,
        "cost_daily": cost_daily,
        "findings_history": findings,
    }
    return {name: generated[name] for name in C.TABLE_ORDER}


def launches_by_weekday(launch_rows, column="actual_date"):
    """Counts per weekday (Monday=0..Sunday=6) for the given date column."""
    counts = [0] * 7
    for r in launch_rows:
        value = r[column]
        if value is None:
            continue
        counts[date.fromisoformat(value).weekday()] += 1
    return counts
