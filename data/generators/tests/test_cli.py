"""End-to-end CLI checks: `python -m generators build` and `... summary`."""

import subprocess
import sys
from pathlib import Path

from generators.config import TABLE_ORDER

DATA_DIR = Path(__file__).resolve().parents[2]  # .../data


def run_cli(*args, timeout=120):
    return subprocess.run(
        [sys.executable, "-m", "generators", *args],
        cwd=DATA_DIR,
        capture_output=True,
        text=True,
        timeout=timeout,
    )


def test_cli_build_writes_all_tables(tmp_path):
    result = run_cli("build", "--out", str(tmp_path))
    assert result.returncode == 0, result.stderr
    for name in TABLE_ORDER:
        assert (tmp_path / f"{name}.csv").is_file(), f"missing {name}.csv"
        assert (tmp_path / f"{name}.json").is_file(), f"missing {name}.json"
    with open(tmp_path / "launches.csv", newline="", encoding="utf-8") as f:
        line_count = sum(1 for _ in f)
    assert line_count == 1201  # header + 1200 rows


def test_cli_summary_reports_saturday(tmp_path):
    result = run_cli("summary")
    assert result.returncode == 0, result.stderr
    assert "launches" in result.stdout
    assert "Saturday" in result.stdout
    # The argmax marker must sit on the Saturday line.
    saturday_line = next(
        line for line in result.stdout.splitlines() if "Saturday" in line
    )
    assert "max" in saturday_line
