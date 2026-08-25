"""The committed row-count fixture must never drift from the generators.

`expected_counts.json` is not documentation: `verification/layer-05-audit.ps1`
reads it for V5.3 and, when it is absent, records the criterion SKIP with
"launches = 1,200 verified; other nine tables unverified". So the file is the
only thing standing between "ten tables asserted exactly" and "one table
asserted, nine taken on trust".

Because it is committed, it can go stale silently the moment anyone changes a
constant in `generators/config.py` or a loop in `generators/build.py`. These
tests re-derive every number from a fresh deterministic build and compare, so
the drift becomes a red test in `python -m pytest` rather than a false PASS in
an audit report at tenant time.
"""

import json
from pathlib import Path

from generators import config as C

FIXTURE = Path(__file__).resolve().parent / "expected_counts.json"


def load_fixture():
    return json.loads(FIXTURE.read_text(encoding="utf-8"))


def test_fixture_exists_and_is_a_flat_table_to_count_map():
    # layer-05-audit.ps1 walks the parsed object's properties and casts each
    # value with [int], so any extra key (a "seed" or "generatedAt" field)
    # would be read as an eleventh table name and fail the comparison.
    fixture = load_fixture()
    assert isinstance(fixture, dict)
    for name, count in fixture.items():
        assert isinstance(name, str)
        assert isinstance(count, int) and not isinstance(count, bool)
        assert count > 0


def test_fixture_covers_exactly_the_ten_tables_in_order():
    fixture = load_fixture()
    assert list(fixture.keys()) == C.TABLE_ORDER


def test_fixture_matches_a_fresh_deterministic_build(tables):
    fixture = load_fixture()
    built = {name: len(rows) for name, rows in tables.items()}
    assert fixture == built, (
        "data/generators/tests/expected_counts.json has drifted from the "
        "generators. Regenerate it with:\n"
        "  python -c \"import json,sys; sys.path.insert(0,'.'); "
        "from generators.build import build_tables; "
        "print(json.dumps({k: len(v) for k, v in build_tables().items()}, indent=2))\"\n"
        f"committed={fixture}\nbuilt={built}"
    )


def test_fixture_agrees_with_the_declared_constants(tables):
    # The nine fixed-size tables come from config.EXPECTED_COUNTS; scrubs is
    # derived from launches.scrub_count and has no constant to compare against,
    # so it is checked against the build directly.
    fixture = load_fixture()
    for name, expected in C.EXPECTED_COUNTS.items():
        assert fixture[name] == expected
    assert fixture["scrubs"] == sum(r["scrub_count"] for r in tables["launches"])


def test_launches_count_matches_the_plan_pinned_value():
    # V5.3 pins launches = 1,200 exactly, with no tolerance band, independently
    # of this fixture. If the two ever disagree the audit fails on the pinned
    # value, so keep them in step here.
    assert load_fixture()["launches"] == 1200
