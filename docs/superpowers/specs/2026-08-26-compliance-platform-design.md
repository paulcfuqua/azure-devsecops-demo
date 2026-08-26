# Design: a self-auditing multi-framework compliance platform

**Date:** 2026-08-26 · **Status:** sponsor-approved design, pending implementation plan
**Affects:** a new `apps/compliance`; `verification/MlsAudit.psm1` and all 11 layer audits
(a new `-Control` parameter); `apps/mcp-tools` (a new `query_compliance` tool); L7
(one more container app)
**Does not supersede anything.** The self-healing pipeline (showpiece #3) is unaffected.

## 1. Purpose

The demo currently proves it can *fix* a vulnerability. This proves it can *govern an
estate against a standard* — which is the question the target audience actually has to
answer to their own auditors.

The platform renders, for NIST SP 800-171 and the frameworks that map onto it, which
requirements the estate meets, which it does not, what the evidence is in each case, and
what specifically would close each gap. Crucially it distinguishes what has been
**machine-verified** from what has merely been **asserted** — because a compliance tool
that blurs those two is worse than no tool at all. It launders a gap into a green box.

### Why this is worth building over more self-healing polish

The `verification/` suite is already the strongest asset in the repo: 55 criteria, each
declaring the command it ran, the value it expected and the value it observed, executed
by an identity that is structurally incapable of mutation. It is, in all but name, a
control-assessment engine. It is missing exactly one field — which control each criterion
evidences — and a surface to render the result.

This design adds that field and that surface. Most of the value is already paid for.

## 2. Decisions taken (sponsor, 2026-08-26)

| # | Decision | Rejected alternatives |
|---|---|---|
| D1 | **Hybrid truth model with explicit provenance.** All 110 requirements present; each carries `machine-verified`, `asserted`, `declared` (N/A), or `none` | Machine-derived only (covers ~a third of the standard, organizational families never appear); curated register (status is a human claim throughout, which the audience discounts) |
| D2 | **Pluggable collectors** producing typed evidence records | Bare evidence links (no extensibility story) |
| D3 | **Standalone `apps/compliance`**, not a control-tower tab | A fifth tab in control-tower — rejected by sponsor for separation and future reusability |
| D4 | **Read-only app; evidence authored in-repo via PR.** Git is the evidence chain | A write path in the UI — needs storage, per-user identity, and its own audit trail, and puts evidence somewhere harder to trust than git |
| D5 | **Authored recommendations + an MCP `query_compliance` tool** | Authored only (leaves the agent tie-in unused); agent-generated (confident wrong compliance advice is the worst failure mode available) |
| D6 | **Multi-framework: 800-171 Rev 2, 800-53 Rev 5, CMMC 2.0 L1/L2**, schema structured for L3 later | 800-171 only; or L3 now (pulls in 800-172's enhanced requirements, most of which this estate has no honest claim to) |
| D7 | **CI-collected, artifact-served** (approach A) | App-collected live — needs the seven RBAC grants that do not exist, bills the subscription per page view, cannot run pre-tenant |
| D8 | **`compliance` uses Container Apps Easy Auth; `mcp-tools` keeps its own gate.** No shared auth module | A shared auth gate — does not work: a static SPA has nowhere to keep a secret |

### A correction to the record on D6

Multi-framework was initially costed as "materially the largest build." That was wrong,
and the estimate assumed the mappings would be invented. They are published:

- **CMMC 2.0 Level 2 is exactly the 110 requirements of 800-171 Rev 2** — an identity
  mapping, not a crosswalk.
- **800-171 → 800-53 Rev 5** ships as Appendix D of 800-171 itself.
- **CMMC Level 1** is the 15 basic safeguards of FAR 52.204-21.

The work is transcription and verification, not judgment. With mappings held on the
catalog rather than on each assessment, a framework view is a filter and a relabel over
one set of assessment records.

## 3. Data model

Three artifacts, joined on control ID. The separation matters: reference data changes
rarely, assessments change per PR, state changes per collector run.

### 3.1 Catalog — reference data

`compliance/catalog/nist-800-171r2.json`. The requirement text and every framework
mapping. Reviewed rarely; effectively static.

```json
{
  "framework": "NIST SP 800-171 Rev 2",
  "requirements": [
    {
      "id": "3.5.3",
      "family": "3.5",
      "familyName": "Identification and Authentication",
      "title": "Use multifactor authentication for local and network access to privileged accounts and for network access to non-privileged accounts.",
      "mappings": {
        "nist-800-53r5": ["IA-2(1)", "IA-2(2)"],
        "cmmc-2.0": ["L2-3.5.3"],
        "far-52.204-21": []
      }
    }
  ]
}
```

### 3.2 Assessment — authored, PR-reviewed

`compliance/assessment/<control-id>.json`. One file per control keeps PR diffs legible
and blame meaningful. This is what the remediation register populates.

**Assessment files are optional.** A control with no file is `NOT_ASSESSED` — which is
the correct starting state for all 110 and the reason the initial board is mostly grey
rather than mostly green. Files appear as controls are actually assessed.

```json
{
  "control": "3.5.3",
  "applicability": "applicable",
  "criteria": ["V3.3"],
  "assertion": null,
  "recommendation": "Parameterize the CA policy state; default to enabled with a break-glass exclusion group. Invert V3.3 so enforcement passes and report-only is a declared exception.",
  "gapSeverity": "high",
  "references": ["docs/runbooks/layers/L03.md#v33"]
}
```

`assertion`, when present, is `{ status, evidence[], assertedBy, assertedAt, rationale }`.
`assertedBy` is informational — git blame is the authoritative record of who claimed what,
and when.

For a requirement genuinely out of scope, `applicability: "not-applicable"` **requires** a
`naJustification`. An N/A without one fails validation. Unjustified N/A is the most common
way real assessments inflate a score.

### 3.3 State — emitted, committed, never hand-edited

`compliance/state/state-<ISO-date>.json` plus `state-latest.json`, which is a **copy** rather than a symlink — the repo is
authored on Windows and collected on Linux. Each run
commits a dated artifact, so `git log compliance/state/` becomes a defensible record of
when the estate became compliant and when it regressed — a question most GRC tooling
cannot answer at all.

```json
{
  "collectedAt": "2026-08-26T14:22:10Z",
  "commit": "1376573",
  "controls": [
    {
      "control": "3.5.3",
      "status": "GAP",
      "provenance": "machine-verified",
      "observed": "CA state = enabledForReportingButNotEnforced",
      "evidence": [
        { "source": "verification-suite", "criterion": "V3.3",
          "artifact": "verification/reports/L03-2026-08-26.md",
          "collectedAt": "2026-08-26T14:20:02Z" }
      ]
    }
  ]
}
```

### 3.4 Status derivation

A pure function over catalog + assessment + evidence. Testable in isolation, and the
place every honesty rule is enforced mechanically rather than by review discipline.

| Input | Status | Provenance |
|---|---|---|
| `not-applicable` + justification | `NOT_APPLICABLE` | `declared` |
| has criteria, all pass | `COMPLIANT` | `machine-verified` |
| has criteria, any fail | `GAP` | `machine-verified` |
| has criteria, any skip/pending | `INCONCLUSIVE` | `machine-verified` |
| no criteria, assertion with evidence | assertion's status | `asserted` |
| no criteria, assertion without evidence | `NOT_ASSESSED` | `none` |
| no criteria, no assertion | `NOT_ASSESSED` | `none` |

**The load-bearing rule:** an authored assertion can never render as `machine-verified`.
Section 6 makes this a property test.

**Scoring.** The board reports counts by status and provenance, never a single
"% compliant" figure. A percentage that blends verified and asserted controls is the
exact number an adopter would quote and should not.

## 4. Collectors

A collector maps a source to evidence records. Nothing else.

```
EvidenceRecord {
  control:     "3.5.3"
  source:      "verification-suite"
  status:      pass | fail | inconclusive
  observed:    "CA state = enabledForReportingButNotEnforced"
  artifact?:   "verification/reports/L03-2026-08-26.md"
  collectedAt: ISO-8601
}
```

| Collector | Source | Primary families |
|---|---|---|
| `verification-suite` | committed layer-audit reports | 3.1, 3.4, 3.5, 3.12 |
| `repo-static` | the working tree; no tenant required | 3.4, 3.11, 3.14 |
| `github-security` | GHAS posture, ruleset, Dependabot | 3.11, 3.14, 3.4 |
| `azure-policy` | policy compliance state | 3.13, 3.4 |
| `manual` | assessment files carrying an `assertion` block | 3.2, 3.6, 3.9 |

### 4.1 Language: PowerShell

Collectors are CI tooling, not application code — under D7 the app only reads JSON. They
live beside `verification/` and reuse `MlsAudit.psm1`, which means they inherit its
**read-only transport guards**: a collector built on that module is structurally
incapable of mutating the estate it assesses. That is the correct property for an
assessment tool, and it is free.

### 4.2 The criterion → control mapping

`Invoke-MlsCriterion` gains a `-Control` parameter, so each criterion declares the
requirement it evidences inline:

```powershell
Invoke-MlsCriterion -Context $context -Id 'V3.3' -Control @('3.5.3') `
    -Description 'CA policy state == enabledForReportingButNotEnforced'
```

The alternative — a standalone mapping file — touches no existing code but can silently
drift from the criteria it maps. In a compliance tool, drift is the failure mode that
matters most. Inline keeps the mapping adjacent to the assertion it describes.

Cost: one parameter in `MlsAudit.psm1`, a mechanical edit across 11 audit scripts, and a
few Pester assertions. This is the only place the design reaches into existing code.

### 4.3 Behaviour before the tenant exists

`repo-static` and `manual` run against the working tree and need nothing. `verification-suite`
reads committed reports; pre-G0 there are none, so those controls render `NOT_ASSESSED` —
visibly distinct from `GAP`, and honest. The board is therefore demonstrable **today**, and
the pre-tenant board is what makes the post-deployment board mean something.

## 5. The application

### 5.1 Shape: a static SPA with state baked at build time

React and Fluent UI behind nginx, matching `control-tower` and `launch-ops`. No backend,
no API, no managed identity, no RBAC grants, no per-view Azure cost. CI runs the
collectors, commits the state, builds the image, deploys.

The build bakes three things: the **catalog** (titles and framework mappings), the
**latest state**, and the **preceding state artifacts** the trend view needs. Assessment
files are not shipped — their content is already resolved into the state artifact by the
collectors, and shipping both would create a second source of truth in the browser.

This inherits the digest-binding property V7.1 already applies to apps: **the image digest
binds to the exact compliance state it renders**, so any deployment can prove which
assessment it is showing.

### 5.2 Authentication: Container Apps Easy Auth

The board is a list of the estate's own security gaps. Even with synthetic demo data it is
not a public page.

`compliance` uses **Container Apps built-in authentication with Entra** — Bicep
configuration, no application code, real per-user identity, no secret to distribute or
rotate. A static SPA cannot hold a bearer secret, so an application-level gate is not
merely unnecessary here; it does not work.

`mcp-tools` keeps its own gate, because its caller is a Copilot Studio connector and a
header credential is the right shape there. Nothing is shared between them: one uses
platform auth via configuration, the other an in-process check. An abstraction over those
two would be an abstraction over two different things.

Easy Auth also injects the caller's identity, so "viewed by" is real rather than
decorative — and it puts a working Entra authentication story on stage beside the board
that reports on 3.5.

### 5.3 The MCP tool

`query_compliance` on the existing server, reading the same committed artifact:

```
query_compliance(control?, family?, framework?, status?)
  → [{ control, title, status, provenance, observed,
        recommendation, evidence[], frameworks{} }]
```

Four argument shapes cover the questions people ask: one control, one family, everything
failing, or a framework view. The Ask tab then answers *"what is blocking 3.5.3?"* against
the same evidence the board renders — one source of truth, and the agent can only return
authored recommendations, never invent them.

## 6. Testing

Heavier than the code volume suggests, because the failure mode is a wrong green box.

- **Status derivation:** table-driven over every row of §3.4, plus degenerate inputs —
  empty criteria array, assertion without evidence, N/A without justification. Each must
  fail closed.
- **The honesty invariant, as a property test:** `provenance == "machine-verified"` implies
  the record came from a collector reading an executed criterion. This is the single test
  separating this tool from compliance theatre.
- **Referential integrity, both directions:** every `criteria` reference resolves to a
  criterion that exists (rename `V3.3` and the build fails loudly instead of the control
  degrading silently to `NOT_ASSESSED`); and every criterion maps to ≥1 control or is
  explicitly marked as mapping to none, preventing silent under-coverage.
- **Catalog completeness:** 110 requirements, no duplicate IDs, 14 families, well-formed
  mapping targets.
- **Collector contracts:** fixture-driven, no cloud calls, plus an explicit assertion that
  no collector issues a mutating `az`/`gh` call — the pattern the layer audits already use.
- **Golden-file state:** a known fixture set produces a known artifact, so derivation
  changes surface as a diff.
- **Tool/board parity:** `query_compliance` and the board return the same status for the
  same control.

### 6.1 A limit stated plainly

Whether `V3.3` genuinely evidences `3.5.3` is a human judgment; no test confirms it. The
mitigation is transparency rather than a claim to correctness: the board renders each
criterion's actual command and observed value beside the control, so a reader can judge
the mapping. This is why `observed` is required on every evidence record.

## 7. Out of scope

- **Procedural and business-process controls** (3.2 Awareness & Training, 3.9 Personnel
  Security, most of 3.6 Incident Response). These are represented in the catalog and
  rendered honestly as gaps or assertions, but the demo does not attempt to satisfy them.
  Sponsor decision, 2026-08-26.
- **A write path in the UI** (D4).
- **CMMC Level 3 / 800-172** — schema accommodates it; content deferred (D6).
- **Live collection from the app** (D7).
- **A single "% compliant" headline figure** (§3.4).

## 8. Follow-on work, not part of this spec

1. **The remediation register** — the 15 findings from the 2026-08-26 pre-publication
   review, authored in §3.2 shape. This is the first implementation task against this
   spec, not part of it: the spec describes the system, the register describes the estate,
   and keeping them separate is what stops them drifting.
2. **Additional scrubs** for gaps that an 800-53 or CMMC lens surfaces and the 800-171 pass
   did not, appended to the same register before remediation begins.
3. **Closing the IaC gaps themselves**, tracked against the register.
