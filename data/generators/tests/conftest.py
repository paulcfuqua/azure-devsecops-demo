"""Shared fixtures. Adds data/ to sys.path so `import generators` works from any cwd."""

import sys
from pathlib import Path

DATA_DIR = Path(__file__).resolve().parents[2]  # .../data
if str(DATA_DIR) not in sys.path:
    sys.path.insert(0, str(DATA_DIR))

import pytest  # noqa: E402

from generators.build import build_tables  # noqa: E402


@pytest.fixture(scope="session")
def tables():
    """One deterministic build shared by the whole test session."""
    return build_tables()
