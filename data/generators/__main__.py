"""CLI: `python -m generators build|summary` (run from the data/ directory)."""

import argparse
import sys

from .build import build_tables, launches_by_weekday
from .config import WEEKDAY_NAMES
from .writers import GENERATED_DIR, build_and_write


def cmd_build(args):
    out, written = build_and_write(args.out)
    print(f"Wrote CSV + JSON for {len(written)} tables to {out}")
    for name, count in written.items():
        print(f"  {name:<20} {count:>6} rows")
    return 0


def cmd_summary(_args):
    tables = build_tables()
    print("Row counts:")
    for name, rows in tables.items():
        print(f"  {name:<20} {len(rows):>6}")
    counts = launches_by_weekday(tables["launches"], "actual_date")
    argmax = counts.index(max(counts))
    print("\nLaunches by weekday (actual_date):")
    for i, (day, count) in enumerate(zip(WEEKDAY_NAMES, counts)):
        marker = "  <= max" if i == argmax else ""
        print(f"  {day:<10} {count:>5}{marker}")
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(
        prog="generators",
        description="Deterministic synthetic data for Meridian Launch Systems.",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    p_build = sub.add_parser("build", help="write CSV + JSON for every table")
    p_build.add_argument(
        "--out",
        default=None,
        help=f"output directory (default: {GENERATED_DIR})",
    )
    p_build.set_defaults(func=cmd_build)

    p_summary = sub.add_parser(
        "summary", help="print row counts and launches-by-weekday distribution"
    )
    p_summary.set_defaults(func=cmd_summary)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
