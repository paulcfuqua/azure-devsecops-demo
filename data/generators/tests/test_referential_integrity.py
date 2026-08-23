"""Every foreign key in every table must resolve to an existing primary key."""


def ids(tables, name, key):
    return {r[key] for r in tables[name]}


def test_launches_fks(tables):
    vehicle_ids = ids(tables, "vehicles", "vehicle_id")
    pad_ids = ids(tables, "pads", "pad_id")
    for r in tables["launches"]:
        assert r["vehicle_id"] in vehicle_ids, r["launch_id"]
        assert r["pad_id"] in pad_ids, r["launch_id"]


def test_scrubs_fk(tables):
    launch_ids = ids(tables, "launches", "launch_id")
    for r in tables["scrubs"]:
        assert r["launch_id"] in launch_ids, r["scrub_id"]


def test_telemetry_fk(tables):
    launch_ids = ids(tables, "launches", "launch_id")
    for r in tables["telemetry_summary"]:
        assert r["launch_id"] in launch_ids, r["telemetry_id"]


def test_parts_fk(tables):
    supplier_ids = ids(tables, "suppliers", "supplier_id")
    for r in tables["parts"]:
        assert r["supplier_id"] in supplier_ids, r["part_id"]


def test_work_orders_fks(tables):
    part_ids = ids(tables, "parts", "part_id")
    vehicle_ids = ids(tables, "vehicles", "vehicle_id")
    launch_ids = ids(tables, "launches", "launch_id")
    for r in tables["work_orders"]:
        assert r["part_id"] in part_ids, r["work_order_id"]
        assert r["vehicle_id"] in vehicle_ids, r["work_order_id"]
        if r["launch_id"] is not None:  # nullable FK
            assert r["launch_id"] in launch_ids, r["work_order_id"]


def test_primary_keys_unique(tables):
    pk = {
        "launches": "launch_id",
        "scrubs": "scrub_id",
        "vehicles": "vehicle_id",
        "pads": "pad_id",
        "telemetry_summary": "telemetry_id",
        "parts": "part_id",
        "suppliers": "supplier_id",
        "work_orders": "work_order_id",
        "cost_daily": "cost_id",
        "findings_history": "finding_id",
    }
    for name, key in pk.items():
        values = [r[key] for r in tables[name]]
        assert len(values) == len(set(values)), f"duplicate {key} in {name}"
