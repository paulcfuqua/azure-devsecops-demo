"""Same seed => byte-identical output, in memory and on disk."""

import hashlib

from generators.build import build_tables
from generators.config import TABLE_ORDER
from generators.writers import build_and_write


def test_build_twice_identical_in_memory():
    a = build_tables()
    b = build_tables()
    assert list(a.keys()) == list(b.keys())
    for name in a:
        assert a[name] == b[name], f"table {name} differs between two builds"


def test_written_files_byte_identical(tmp_path):
    dir_a = tmp_path / "a"
    dir_b = tmp_path / "b"
    build_and_write(dir_a)
    build_and_write(dir_b)
    for name in TABLE_ORDER:
        for ext in ("csv", "json"):
            fa = dir_a / f"{name}.{ext}"
            fb = dir_b / f"{name}.{ext}"
            assert fa.is_file() and fb.is_file()
            ha = hashlib.sha256(fa.read_bytes()).hexdigest()
            hb = hashlib.sha256(fb.read_bytes()).hexdigest()
            assert ha == hb, f"{name}.{ext} not byte-identical across builds"


def test_no_time_of_run_in_generation_source():
    """Guard: generation modules must not import or call wall-clock time."""
    from pathlib import Path

    pkg = Path(__file__).resolve().parents[1]
    banned = ("datetime.now", "date.today", "time.time(", "utcnow", "perf_counter")
    for mod in ("config.py", "pools.py", "build.py", "writers.py", "__main__.py"):
        text = (pkg / mod).read_text(encoding="utf-8")
        for token in banned:
            assert token not in text, f"{mod} contains banned time-of-run token {token!r}"
