# compliance/

Durable records for the self-auditing multi-framework compliance platform described in
[docs/superpowers/specs/2026-08-26-compliance-platform-design.md](../docs/superpowers/specs/2026-08-26-compliance-platform-design.md).
That spec defines the full system (catalog, collectors, state, the `apps/compliance`
board, the `query_compliance` MCP tool). **All of it now exists**: the follow-on
implementation plan completed on 2026-08-28, and its layer playbook is
[`docs/runbooks/layers/L12.md`](../docs/runbooks/layers/L12.md) — which also states, in
its Teardown section, the one leg of the layer's triplet that is still missing (there is
no `verification/layer-12-audit.ps1`).

This directory holds the collection half. The rendering half is `apps/compliance` (a
static board behind Container Apps Easy Auth) and the query half is `query_compliance`,
the sixth tool on `apps/mcp-tools` — both read the artifact emitted here, and neither
holds a second copy of the logic.

**What the board says on this estate, today: 0 COMPLIANT, 15 PARTIAL, 1 GAP, 0
INCONCLUSIVE, 0 NOT_APPLICABLE, 94 NOT_ASSESSED of 110**, plus the 4 out-of-catalog rows
described below. Nothing here has ever been deployed, so nothing could have been
observed; a green board at this point would mean the platform had invented a claim.

The three rows that moved from GAP to PARTIAL on 2026-08-28 are 3.1.1, 3.1.2 and 3.1.5,
and **PARTIAL is the ceiling an authored assertion can reach** — see **Derived
vocabulary** below. Their last open contributor was F13's seventh workload RBAC grant,
which had no principal to be written against until F19 provisioned `apps/cost-ingest` as
a real Function App.

**The one GAP is 3.5.3 (multifactor authentication), added 2026-08-28, and it is a row
that moved from NOT_ASSESSED to GAP by being assessed rather than by regressing.** The
estate now *declares* an enforced Conditional Access policy requiring MFA for every user
signing in to the three human-facing dashboards, with a break-glass exclusion the apply
script refuses to proceed without — but 3.5.3 also requires MFA for privileged accounts,
and the policy that would cover those is deliberately left report-only. One prong
declared, one prong knowingly not enforced, and nothing deployed either way: `CLOSED`
would have claimed no known open shortfall stands, while the record's own rationale names
one. See `assessment/3.5.3.json`, which is explicit about what it does *not* claim. 3.5.4
(replay-resistant mechanisms) has no record and stays NOT_ASSESSED on purpose: what makes
an Entra sign-in replay-resistant is the OIDC flow the platform implements, which this
repository neither configures nor verifies.

## What exists today

- **`assessment/`** — one `<control-id>.json` per control this repository has actually
  said something about, in the schema from
  spec §3.2. Each file asserts a `status` (see **Register vocabulary** below). Nineteen
  of them exist because the 2026-08-26 pre-publication security review found a gap
  against that control; **3.5.3 is the first that does not** — no finding raised it, it
  was assessed because the sponsor asked for enforced MFA and the answer had to be
  recorded honestly. As of
  2026-08-29, **19 assert `CLOSED` and one (3.5.3) asserts `GAP`** — `CLOSED` saying only
  that no known open finding
  stands against those controls, never that they are met. This is the **remediation register**: the first
  implementation task against the compliance-platform spec (§8, item 1), not part of the
  spec itself.
- **`findings/2026-08-26-prepublication-review.md`** — the narrative record of the
  36 findings behind that register (F1-F36): severity, confidence, `file:line`, the concrete
  attack path, impact (including cost where relevant), and the fix. Each
  `compliance/assessment/*.json` file's `assertion.evidence` cites one or more anchors
  into this document. Eight findings (F14, F15, F19, F20, F21, F22, F29, F36) map to no
  800-171 control and are recorded here only, not as assessment files, so they don't fall
  through the gap between the security and compliance framings. (This paragraph said
  "24 findings (F1-F24)" until 2026-08-28; the 2026-08-28 addendum added F25-F36 and the
  count was never updated with it.)
- **`catalog/`** — the full 110-requirement NIST SP 800-171 Rev 2 catalog with its mappings
  to 800-53 Rev 5, CMMC 2.0 and FAR 52.204-21, in the schema from spec §3.1. This is
  **authored reference data**: it carries no status field and asserts nothing about this
  estate. See [`catalog/README.md`](catalog/README.md) for its sources and for the four
  places its content is an editorial decision rather than a straight transcription. The
  control ids used in `assessment/` are still not validated against it: four records
  (`CM-6`, `SI-4`, `IR-4`, `CP-9`) key on 800-53 ids the 800-171 catalog has no
  requirement for, so the catalog-to-register join is not an identity mapping. The state
  emitter renders those four on their own rows (`outOfCatalogControls`) rather than
  dropping them or forcing them through the mappings — see **What the state artifact
  says** below.
- **`lib/MlsCompliance.psm1`** — the status derivation, spec §3.4. `Get-MlsControlStatus`
  is a pure function over (requirement, assessment, evidence) returning `Status`,
  `Provenance` and `Observed`; `Get-MlsComplianceVocabulary` publishes the two
  vocabularies below as data so counting code never invents its own list. It reads no
  file, no clock and no environment, and keeps no state between calls — which is what
  makes the honesty rules mechanical rather than a matter of review discipline.
- **`tests/register.Tests.ps1`** — Pester 6 tests asserting the register's structural
  integrity: an assessment file exists for every control the findings table cites, every
  file is valid JSON with the required fields, no `not-applicable` control lacks a
  justification, and every assertion cites at least one piece of evidence.
- **`tests/catalog.Tests.ps1`** — Pester 6 tests asserting the catalog's counts, numbering
  and mapping shape, so a partial transcription cannot pass for a complete framework.
- **`tests/derivation.Tests.ps1`** — Pester 6 tests over every row of §3.4's table, both
  halves of the honesty invariant as property tests, purity, and the degenerate and
  malformed inputs each branch must fail closed on.
- **`Invoke-MlsCompliance.ps1`** — the state emitter, spec §3.3. Loads the catalog and
  the register, runs all five collectors, calls `Get-MlsControlStatus` once per
  requirement, and writes `state/state-<ISO-date>.json` plus `state-latest.json` (a real
  file copy, never a symlink: authored on Windows, collected on Linux). Read-only,
  offline, and needs no tenant. See the file header for the three decisions it takes —
  how the four 800-53-keyed records are rendered, how collected evidence that drove
  nothing is surfaced without looking as though it drove something, and how a skipped
  criterion is counted so `machine-verified` cannot be read as verified-and-passing.
- **`state/`** — the emitted snapshots themselves, committed on every run of
  `.github/workflows/compliance.yml` (push to `main`, nightly, dispatch) so
  `git log compliance/state/` is the record of when the estate became compliant and when
  it regressed. Never hand-edited.
- **`tests/state-emitter.Tests.ps1`** and **`tests/fixtures/golden-state.json`** — the
  emitter's suite and the golden file pinning the whole artifact for a fixture set that
  exercises all six derived statuses, all four provenances, an out-of-catalog record and
  a malformed register file. The golden's `commit` and `collectedAt` are placeholders: it
  pins a shape, not a collection that happened.

## What the state artifact says, and what it refuses to say

- One entry for **every one of the 110 requirements**. A requirement nothing was said
  about is `NOT_ASSESSED` / `none`, never an omission.
- Each control row separates three different things: `statusBasis` (the working the
  derivation itself returned — nothing outside it moved the status), `evidence` (the
  collected records that participated in it) and `supportingEvidence` (everything else
  collected for that control, each marked `participatedInStatus: false`). Since every
  register record declares `criteria: []` today, no collected evidence participates
  anywhere; it is rendered as context, and labelled as context.
- The four `800-53`-keyed records (`CM-6`, `CP-9`, `IR-4`, `SI-4`) get their own rows in
  `outOfCatalogControls`, keyed on their own ids and counted separately. They are
  deliberately **not** resolved through the catalog's `mappings.nist-800-53r5` onto
  800-171 rows — CP-9 maps to 3.8.9, and rendering CP-9's authored `CLOSED` against
  3.8.9 would attribute a claim its author never made.
- `summary` carries `byStatus`, `byProvenance` and the cross-tabulation
  `byProvenanceAndStatus`. The cross-tab is load-bearing: a criterion a machine
  explicitly declined to run renders `INCONCLUSIVE` / `machine-verified`, so a bare
  `machine-verified` total must never be read as verified-and-passing. `COMPLIANT` is
  the only status that means that.
- **No blended percentage, ever** — no `percentCompliant`, no score, no ratio. Counts
  only. Enforced by the emitter's tests, which walk the whole object graph, and again by
  the workflow, which greps the emitted bytes.

Nothing in the register is machine-verified: every record in `assessment/` is an
authored assertion, which is why no status derived from one ever renders as `COMPLIANT`
(spec §3.4, and **Derived vocabulary** below).

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
  see it in `assessment/`, that is a defect. It is a legitimate *derived* status — see
  **Derived vocabulary** below — and the two are not the same word used twice.

`compliance/tests/register.Tests.ps1` enforces that every record's status is one of the
two permitted values.

## Derived vocabulary

What a human asserted and what the platform can justify saying are different things, and
`Get-MlsControlStatus` **maps** between them rather than passing `assertion.status`
through — passing it through would put `CLOSED`, a word that belongs to no rendered enum,
straight onto the board. The derived statuses are:

`COMPLIANT` · `PARTIAL` · `GAP` · `INCONCLUSIVE` · `NOT_APPLICABLE` · `NOT_ASSESSED`

each carrying a provenance of `machine-verified`, `asserted`, `declared` or `none`. The
mapping from the register:

| Assessment | Derived status | Provenance |
|---|---|---|
| `not-applicable` **with** an `naJustification` | `NOT_APPLICABLE` | `declared` |
| `not-applicable` **without** one | `NOT_ASSESSED` | `none` |
| `criteria`, all collected and passing | `COMPLIANT` | `machine-verified` |
| `criteria`, any failing | `GAP` | `machine-verified` |
| `criteria`, any inconclusive, skipped or never collected | `INCONCLUSIVE` | `machine-verified` |
| no criteria, an authored `CLOSED` citing evidence | `PARTIAL` | `asserted` |
| no criteria, an authored `GAP` citing evidence | `GAP` | `asserted` |
| no criteria, an authored status outside the register's two | `INCONCLUSIVE` | `asserted` |
| no criteria, an assertion citing nothing, or no assertion, or no file | `NOT_ASSESSED` | `none` |

**`COMPLIANT` is reachable from the criteria branch only.** An authored assertion can
never produce it, whatever its status: `CLOSED` means "no known open finding", which is
weaker than "the control is met", so deriving `COMPLIANT` from it would launder the
weaker claim into the stronger one on the board. `Provenance` is likewise set by which
branch fired and never read from an input field, so no record can ask to be called
machine-verified. Both halves are property-tested over a generated space of assertion
shapes in `tests/derivation.Tests.ps1`, so neither can be broken without a test going
red.

Every record in `assessment/` carries `criteria: []` today, so every one takes an
authored path and the board is `PARTIAL` and `GAP`, never green. The machine-verified
path is what the collectors populate.

3.5.3 is the clearest illustration of why the mapping is a decision rather than a
formality: `verification/layer-03-audit.ps1`'s V3.3 now asserts, against a live tenant,
that the dashboard MFA policy is enforced, grants `mfa`, is scoped to exactly three named
applications and excludes a populated break-glass group — and it is still mapped to **no**
control, because the same criterion asserts as a pass condition that the *admin* MFA
policy is report-only. Claiming a criterion for a control it only half demonstrates is
the one thing the criteria branch cannot be allowed to do, since it is the only path to
`COMPLIANT`.

There is deliberately **no "% compliant" figure** anywhere: counts by status and by
provenance only. A percentage that blends verified and asserted controls is the exact
number an adopter would quote and should not (spec §3.4).

## Why the schema looks the way it does

These assessment records double as seed data for the compliance platform once it's
built. The schema in each `assessment/*.json` file — `control`, `applicability`,
`criteria`, `assertion`, `recommendation`, `gapSeverity`, `references` — is fixed by
spec §3.2 and is not this task's to redesign. `lib/MlsCompliance.psm1` reads these
records directly, as either a hashtable or a `ConvertFrom-Json` object, and treats a
partial or malformed record as ordinary input to fail closed on rather than as an error.
