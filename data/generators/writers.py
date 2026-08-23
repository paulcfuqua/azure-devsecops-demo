"""CSV/JSON writers. Output is byte-stable: LF newlines, UTF-8, fixed key order.

CSV conventions: null -> empty string; booleans -> True/False.
JSON conventions: native null/true/false; one pretty-printed array per table.
"""

import csv
import json
from pathlib import Path

from .build import build_tables
from .config import TABLE_ORDER

# data/generated/ — resolved relative to this package, not the cwd.
GENERATED_DIR = Path(__file__).resolve().parent.parent / "generated"


def write_csv(rows, path):
    fieldnames = list(rows[0].keys())
    with open(path, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames, lineterminator="\n")
        writer.writeheader()
        for row in rows:
            writer.writerow({k: ("" if v is None else v) for k, v in row.items()})


def write_json(rows, path):
    with open(path, "w", newline="", encoding="utf-8") as f:
        json.dump(rows, f, ensure_ascii=False, indent=2)
        f.write("\n")


def build_and_write(out_dir=None):
    """Generate every table and write <table>.csv + <table>.json.

    Returns (output_dir, {table_name: row_count}).
    """
    tables = build_tables()
    out = Path(out_dir) if out_dir is not None else GENERATED_DIR
    out.mkdir(parents=True, exist_ok=True)
    written = {}
    for name in TABLE_ORDER:
        rows = tables[name]
        write_csv(rows, out / f"{name}.csv")
        write_json(rows, out / f"{name}.json")
        written[name] = len(rows)
    return out, written
