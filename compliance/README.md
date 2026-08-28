# compliance/

Durable records for the self-auditing multi-framework compliance platform described in
[docs/superpowers/specs/2026-08-26-compliance-platform-design.md](../docs/superpowers/specs/2026-08-26-compliance-platform-design.md).
That spec defines the full system (catalog, collectors, state, the `apps/compliance`
board, the `query_compliance` MCP tool); this directory is populated incrementally as the
follow-on implementation plan proceeds.

## What exists today

- **`assessment/`** — one `<control-id>.json` per NIST SP 800-171 control that the
  2026-08-26 pre-publication security review found a gap against, in the schema from
  spec §3.2. Each file asserts a `status` (see **Register vocabulary** below). As of the
  2026-08-26 remediation branch, 16 of 19 assert `CLOSED` and the rest remain `GAP`. This is the **remediation register**: the first
  implementation task against the compliance-platform spec (§8, item 1), not part of the
  spec itself.
- **`findings/2026-08-26-prepublication-review.md`** — the narrative record of the
  24 findings behind that register (F1-F24): severity, confidence, `file:line`, the concrete
  attack path, impact (including cost where relevant), and the fix. Each
  `compliance/assessment/*.json` file's `assertion.evidence` cites one or more anchors
  into this document. Six findings (F14, F15, F19, F20, F21, F22) map to no 800-171 control
  and are recorded here only, not as assessment files, so they don't fall through the
  gap between the security and compliance framings.
- **`catalog/`** — the full 110-requirement NIST SP 800-171 Rev 2 catalog with its mappings
  to 800-53 Rev 5, CMMC 2.0 and FAR 52.204-21, in the schema from spec §3.1. This is
  **authored reference data**: it carries no status field and asserts nothing about this
  estate. See [`catalog/README.md`](catalog/README.md) for its sources and for the four
  places its content is an editorial decision rather than a straight transcription. The
  control ids used in `assessment/` are not yet validated against it; that join arrives
  with the derivation function.
- **`tests/register.Tests.ps1`** — Pester 6 tests asserting the register's structural
  integrity: an assessment file exists for every control the findings table cites, every
  file is valid JSON with the required fields, no `not-applicable` control lacks a
  justification, and every assertion cites at least one piece of evidence.
- **`tests/catalog.Tests.ps1`** — Pester 6 tests asserting the catalog's counts, numbering
  and mapping shape, so a partial transcription cannot pass for a complete framework.

## What does not exist yet

- **`state/`** — collector-emitted, CI-committed snapshots joining the catalog and
  assessment records against live evidence (`verification/` reports, repo statics, GHAS
  posture, policy compliance state). Nothing here is machine-verified yet; every record
  in `assessment/` is an authored assertion, which is why no status ever renders as
  `COMPLIANT` — an authored assertion can never claim machine-verified provenance
  (spec §3.4).

## Register vocabulary

The `assertion.status` field takes exactly two values, and the distinction is
load-bearing:

- **`GAP`** — a known open finding stands against this control.
- **`CLOSED`** — **no known open finding** stands against it. This is deliberately
  weaker than "the control is met", and must never be read as such. It says only that
  every finding this review raised against the control has been addressed; it does not
  assert that the control is satisfied, that the estate was assessed exhaustively, or
  that anything was verified against a live tenant.
- **`COMPLIANT`** — a status this register never asserts, for the reason above. If you
  see it anywhere in `compliance/`, that is a defect.

`compliance/tests/register.Tests.ps1` enforces that every record's status is one of the
two permitted values.

## Why the schema looks the way it does

These assessment records double as seed data for the compliance platform once it's
built. The schema in each `assessment/*.json` file — `control`, `applicability`,
`criteria`, `assertion`, `recommendation`, `gapSeverity`, `references` — is fixed by
spec §3.2 and is not this task's to redesign. A later derivation function reads these
files directly.
