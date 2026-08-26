# compliance/

Durable records for the self-auditing multi-framework compliance platform described in
[docs/superpowers/specs/2026-08-26-compliance-platform-design.md](../docs/superpowers/specs/2026-08-26-compliance-platform-design.md).
That spec defines the full system (catalog, collectors, state, the `apps/compliance`
board, the `query_compliance` MCP tool); this directory is populated incrementally as the
follow-on implementation plan proceeds.

## What exists today

- **`assessment/`** — one `<control-id>.json` per NIST SP 800-171 control that the
  2026-08-26 pre-publication security review found a gap against, in the schema from
  spec §3.2. Every file here currently asserts `status: "GAP"` — nothing in the estate
  has been remediated yet. This is the **remediation register**: the first
  implementation task against the compliance-platform spec (§8, item 1), not part of the
  spec itself.
- **`findings/2026-08-26-prepublication-review.md`** — the narrative record of the
  15 findings behind that register: severity, confidence, `file:line`, the concrete
  attack path, impact (including cost where relevant), and the fix. Each
  `compliance/assessment/*.json` file's `assertion.evidence` cites one or more anchors
  into this document. Two findings (F14, F15 — availability and cost) map to no
  800-171 control and are recorded here only, not as assessment files, so they don't
  fall through the gap between the security and compliance framings.
- **`tests/register.Tests.ps1`** — Pester 6 tests asserting the register's structural
  integrity: an assessment file exists for every control the findings table cites, every
  file is valid JSON with the required fields, no `not-applicable` control lacks a
  justification, and every assertion cites at least one piece of evidence.

## What does not exist yet

- **`catalog/`** — the full 110-requirement NIST SP 800-171 Rev 2 catalog with framework
  mappings (800-53 Rev 5, CMMC 2.0, FAR 52.204-21). Building this is Task 1 of the
  compliance-platform implementation plan; until it lands, the control IDs in
  `assessment/` are used verbatim from the review and are not yet validated against a
  catalog.
- **`state/`** — collector-emitted, CI-committed snapshots joining the catalog and
  assessment records against live evidence (`verification/` reports, repo statics, GHAS
  posture, policy compliance state). Nothing here is machine-verified yet; every record
  in `assessment/` is an authored assertion, which is why every status renders as `GAP`
  rather than `COMPLIANT` — an authored assertion can never claim machine-verified
  provenance (spec §3.4).

## Why the schema looks the way it does

These assessment records double as seed data for the compliance platform once it's
built. The schema in each `assessment/*.json` file — `control`, `applicability`,
`criteria`, `assertion`, `recommendation`, `gapSeverity`, `references` — is fixed by
spec §3.2 and is not this task's to redesign. A later derivation function reads these
files directly.
