# Layer Playbooks — Index and Verify-Criterion Traceability

One playbook per master-plan layer, `L01.md` … `L11.md` (master-plan L0 is local
toolchain work covered by `docs/runbooks/g0-bootstrap.md` § A and Phase P Track H —
it has no cloud state and no layer playbook), plus **`L12.md`**, which is *not* a
master-plan layer: it covers the compliance platform added by the 2026-08-26
compliance-platform design and is numbered after L11 rather than folded into L7. Every
playbook carries the same eight sections: Purpose, Preconditions, Deploy procedure,
Validation cycle, Teardown, Rollback, Failure modes, Deferred validation.

> **`L12.md` owns none of the 43 master-plan criteria below and adds none to them.** Its
> criteria are `V12.1`–`V12.6`, drawn from
> `../../superpowers/specs/2026-08-26-compliance-platform-design.md`, and they appear in
> the supplementary table further down. The traceability rule below is about the master
> plan and is unaffected either way.
>
> **Superseded 2026-09-01.** This note used to add that the playbook "states plainly that
> no `verification/layer-12-audit.ps1` exists to execute them — five are enforced by CI
> gates instead and one cannot be checked until the tenant exists." **The script exists**,
> the Entra app registration exists, and `compliance.yml`'s `verify` job runs the audit as
> `mls-verifier` on every collection: 4 PASS + 2 by-design SKIP. See `L12.md` § Validation
> cycle for which criterion is checked where and why.

**Traceability rule (Phase P Track D):** every Verify criterion in the master plan's
L1–L11 sections appears in **exactly one** playbook's Validation cycle, as a numbered
item `V<layer>.<n>` quoting the criterion verbatim before expanding it into the exact
Verifier query, expected values, and retry window. The first table below is the full
mapping — **43 criteria, 43 validation-cycle items, no criterion unmapped, none
duplicated.** (Cross-references exist — V11.2 *re-executes* the L3/L4 audits, V6.3
*closes* during the L7 window — but each criterion is owned by exactly one section.)

> **Re-checked 2026-08-24** after the Copilot Studio amendment. The count moved from 40
> to 43: L8's three criteria became five (the agent is now a deployed Power Platform
> solution, so provenance and card validity are separately checkable), and L10's single
> criterion became two (Copilot Autofix heals CodeQL alerts; Dependabot heals dependency
> alerts — two mechanisms, two trails, so one criterion could not honestly cover both).
> L1–L7, L9 and L11 are untouched.
>
> **Re-checked against the audit scripts 2026-09-22, and the number a reader wants is
> 65, not 43.** The master-plan count is still 43 and the traceability rule still holds
> over exactly those. What grew is the supplementary set: 22 criteria that no master plan
> ever named, each added because something shipped green while being wrong. They are
> indexed in their own table below rather than folded into the first, because a
> supplementary criterion has no master-plan wording to quote verbatim and pretending
> otherwise is how the quote stops meaning anything. Per layer, as the audit scripts
> declare them: **L1 5, L2 3, L3 4, L4 3, L5 7, L6 7, L7 7, L8 8, L9 6, L10 4, L11 5,
> L12 6 = 65.**

Naming note: workflow file names of the form `layer-<nn>-<name>.yml` instantiate the
master plan's `layer-<nn>-*.yml` pattern and are marked [derived] at first use in
each playbook.

## Master-plan criteria (43)

| # | Layer | Master-plan Verify criterion | Playbook section |
|---|---|---|---|
| 1 | L1 | Actions run using OIDC succeeds (`az account show` inside the runner matches the demo sub) | `L01.md` § Validation cycle **V1.1** |
| 2 | L1 | `gh api repos/{repo}` shows secret scanning + push protection enabled | `L01.md` § Validation cycle **V1.2** |
| 3 | L1 | No committed IDs (grep audit) | `L01.md` § Validation cycle **V1.3** |
| 4 | L1 | Federated credential subject matches `repo:<owner>/<repo>` | `L01.md` § Validation cycle **V1.4** |
| 5 | L2 | `az account management-group show mls` shows the sub | `L02.md` § Validation cycle **V2.1** |
| 6 | L2 | Creating an untagged canary RG **fails** with policy denial (then cleaned up) | `L02.md` § Validation cycle **V2.2** |
| 7 | L2 | `az policy state summarize` returns NIST compliance data within 30 min of assignment | `L02.md` § Validation cycle **V2.3** |
| 8 | L3 | Graph queries confirm object counts | `L03.md` § Validation cycle **V3.1** |
| 9 | L3 | Graph queries confirm group memberships | `L03.md` § Validation cycle **V3.2** |
| 10 | L3 | CA policy state == `enabledForReportingButNotEnforced` *(see note c)* | `L03.md` § Validation cycle **V3.3** |
| 11 | L3 | License assignment state == success for all 5 | `L03.md` § Validation cycle **V3.4** |
| 12 | L4 | `Get-Label` returns the 4 labels with expected GUIDs recorded to `verification/reports/` *(see note b)* | `L04.md` § Validation cycle **V4.1** |
| 13 | L4 | Labels survive a kill/rebuild cycle (checked again at L11) | `L04.md` § Validation cycle **V4.2** |
| 14 | L5 | Fabric REST: workspace + lakehouse exist | `L05.md` § Validation cycle **V5.1** |
| 15 | L5 | Table list matches manifest | `L05.md` § Validation cycle **V5.2** |
| 16 | L5 | SQL analytics endpoint returns expected row counts (`launches` = 1,200 ± 0) | `L05.md` § Validation cycle **V5.3** |
| 17 | L5 | Capacity state == `Paused` after layer completes | `L05.md` § Validation cycle **V5.4** |
| 18 | L6 | ARM GET on each resource: SKU/serverless/auto-pause/minReplicas values match manifest exactly | `L06.md` § Validation cycle **V6.1** |
| 19 | L6 | KQL query against LAW succeeds as verifier | `L06.md` § Validation cycle **V6.2** |
| 20 | L6 | First cost export file lands within 24 h (async check L7 window) | `L06.md` § Validation cycle **V6.3** |
| 21 | L6 | SQL auto-pauses (checked after 75 min idle) | `L06.md` § Validation cycle **V6.4** |
| 22 | L7 | Public endpoints return 200 with correct content hash markers | `L07.md` § Validation cycle **V7.1** |
| 23 | L7 | Renderer schema validation passes on golden specs | `L07.md` § Validation cycle **V7.2** |
| 24 | L7 | OTel spans from a synthetic request visible in App Insights via KQL | `L07.md` § Validation cycle **V7.3** |
| 25 | L7 | Per-app CI green on a canary PR | `L07.md` § Validation cycle **V7.4** |
| 26 | L7 | Replicas scale 0→N→0 | `L07.md` § Validation cycle **V7.5** |
| 27 | L8 | Deployed agent's solution unique name + version + component list match the committed solution exactly, and its published state is current | `L08.md` § Validation cycle **V8.1** |
| 28 | L8 | Eval suite passes ≥ 9/10 against the deployed agent, with each answer's number independently re-derived by the Verifier from the lakehouse | `L08.md` § Validation cycle **V8.2** |
| 29 | L8 | No tool invoked outside the five-tool allowlist and the agent declares exactly those five *(see note a)* | `L08.md` § Validation cycle **V8.3** |
| 30 | L8 | Every visual answer is an Adaptive Card payload that validates against the pinned Adaptive Cards schema; zero HTML/JS/JSX in any response | `L08.md` § Validation cycle **V8.4** |
| 31 | L8 | p95 latency < 20 s | `L08.md` § Validation cycle **V8.5** |
| 32 | L9 | GitHub API shows all GHAS features enabled | `L09.md` § Validation cycle **V9.1** |
| 33 | L9 | A seeded CRITICAL image fails CI (negative test) then passes after pin | `L09.md` § Validation cycle **V9.2** |
| 34 | L9 | SBOM artifact present + SPDX-valid | `L09.md` § Validation cycle **V9.3** |
| 35 | L9 | ZAP report artifact exists with 0 High | `L09.md` § Validation cycle **V9.4** |
| 36 | L9 | Defender plan toggles on→off leaving state `Off` *(see note d)* | `L09.md` § Validation cycle **V9.5** |
| 37 | L10 | For the seeded CodeQL alert, the full Autofix trail holds — alert created → autofix status `success` → PR whose head commit is the Autofix commit and whose body carries Autofix's explanation → gauntlet checks all green → merged by automation (no human merger) → new ACA revision → alert state `fixed`, timestamps monotonic *(see note e)* | `L10.md` § Validation cycle **V10.1** |
| 38 | L10 | For at least 2 of the 3 seeded dependency pins, the Dependabot trail holds — alert created → Dependabot patch PR → gauntlet green → merged by automation → new ACA revision → alert state `fixed` *(see note e)* | `L10.md` § Validation cycle **V10.2** |
| 39 | L11 | All RGs absent post-down | `L11.md` § Validation cycle **V11.1** |
| 40 | L11 | Tenant objects intact (L3/L4 audits still pass) | `L11.md` § Validation cycle **V11.2** |
| 41 | L11 | Post-up: all layer audits green | `L11.md` § Validation cycle **V11.3** |
| 42 | L11 | Wall-clock < 180 min *(see note f)* | `L11.md` § Validation cycle **V11.4** |
| 43 | L11 | Run-rate returns to idle profile | `L11.md` § Validation cycle **V11.5** |

## Supplementary criteria (22) — no master-plan wording to quote

Each of these was added after something shipped green while being wrong; the playbook
section names the finding. They are **not** part of the 43-row traceability rule above,
and `verification/layer-NN-audit.ps1` is the source for every wording here.

| Layer | Criterion (as the audit script declares it) | Playbook section |
|---|---|---|
| L1 | The declared governance mode is the one `main` enforces | `L01.md` § Validation cycle **V1.5** |
| L4 | Label policy exists, publishing the taxonomy to its declared scope (`ExchangeLocation` == `All`, F18/F121) | `L04.md` § Validation cycle **V4.3** |
| L5 | The mixed-sensitivity tables carry mixed sensitivity: both classifications present, restricted column populated | `L05.md` § Validation cycle **V5.5** |
| L5 | Row-level security ENFORCES: a non-privileged caller sees exactly the unrestricted rows (capability, not artefact) | `L05.md` § Validation cycle **V5.6** |
| L5 | Column-level denial ENFORCES: the standard tier is refused `salary_usd` (not observable read-only) | `L05.md` § Validation cycle **V5.7** |
| L6 | SQL backup posture (short-term retention + backup storage redundancy) matches the template-pinned values | `L06.md` § Validation cycle **V6.5** |
| L6 | Every Function App the layer deploys actually has functions deployed to it | `L06.md` § Validation cycle **V6.7** |
| L6 | Every Key Vault reference in every Function App actually resolves — the secret arrives, rather than the setting merely being present | `L06.md` § Validation cycle **V6.8** |
| L7 | The data API answers with rows, not merely with a status code | `L07.md` § Validation cycle **V7.6** |
| L7 | A human can complete an interactive sign-in | `L07.md` § Validation cycle **V7.7** |
| L8 | The AWS Athena lakehouse answers through the deployed tool with ROWS, not merely with a status code | `L08.md` § Validation cycle **V8.6** |
| L8 | A denial from the AWS lakehouse is never reported as an empty dataset: observability is established before anything is reported | `L08.md` § Validation cycle **V8.7** |
| L8 | The deployed tool REFUSES the restricted objects and still serves the governed views | `L08.md` § Validation cycle **V8.8** |
| L9 | Defender for Cloud actually produces posture for this subscription | `L09.md` § Validation cycle **V9.6** |
| L10 | The self-heal chain could actually READ the alert surface — a denial is never recorded as "no alerts to heal" | `L10.md` § Validation cycle **V10.3** |
| L10 | `pending-solution` is not a dumping ground: for every finding held there, no upstream fix actually exists | `L10.md` § Validation cycle **V10.4** |
| L12 | The artifact carries one entry for every catalog requirement, and no score anywhere | `L12.md` § Validation cycle **V12.1** |
| L12 | The honesty invariant holds in the shipped artifact: COMPLIANT is unreachable from an authored assertion | `L12.md` § Validation cycle **V12.2** |
| L12 | The board renders the emitted artifact, unaltered | `L12.md` § Validation cycle **V12.3** |
| L12 | Easy Auth refuses an unauthenticated request, and the platform (not the app) is what enforces it | `L12.md` § Validation cycle **V12.4** |
| L12 | `query_compliance` answers from the same artifact, and only from it | `L12.md` § Validation cycle **V12.5** |
| L12 | The collection history is a git history, and `state-latest.json` is what the newest collection wrote | `L12.md` § Validation cycle **V12.6** |

**Numbering gap, so nobody hunts for it:** there is no `V6.6` anywhere in this
repository — `verification/layer-06-audit.ps1` runs V6.1–V6.5, V6.7 and V6.8. L6's seven
criteria are those seven.

**Retired, and recorded rather than deleted:** `V4.4` (2026-09-20) asserted that the
column `DENY`s exist and the row-level policy is enabled — both **artefacts**. V5.6 proves
the policy actually FILTERS, which strictly implies it exists and is enabled, so nothing
was lost. Two things made keeping it worse than useless: the column `DENY`s target a role
that can never have members on this endpoint (F218), and `mls-verifier` cannot read
`sys.database_permissions` at all (F224), so the criterion could never reach a verdict.

## Notes on criteria whose wording is quoted but whose substance has moved

The quotes above are deliberately **not** rewritten: silently editing a criterion to match
a later change is how traceability stops meaning anything. Each note says what moved.

> **(a) Criterion 29 (V8.3), 2026-08-28, updated 2026-09-22.** "The five-tool allowlist"
> was accurate when the master plan was written on 2026-08-22. The MCP server carries
> **seven** tools: `query_compliance` was added 2026-08-26 by the compliance-platform
> design, and `query_aws_lakehouse_sql` 2026-09-16 by the AWS lakehouse link.
> `apps/mcp-tools/src/tools/index.ts`'s `ALLOWED_TOOL_NAMES` is the source of truth,
> `verification/layer-08-audit.ps1`'s `-AllowedTool` default carries all seven, and
> `verification/tests/layer-08-audit.Tests.ps1` asserts that default stays in step — so a
> future eighth tool fails a test rather than silently going unaudited. The criterion's
> substance — nothing runs outside the *declared* allowlist, and the agent declares exactly
> what is on it — is unchanged; only the count moved, and `L08.md` § V8.3 says so in full.

> **(b) Criterion 12 (V4.1), 2026-09-22.** The taxonomy is **six** labels, not four:
> `<prefix>-public`, `-internal`, `-confidential`, `-export-controlled`, plus the two
> tiered-access labels `-hr-sensitive` and `-3ppi`, which classify the mixed-sensitivity
> lakehouse tables. `infra/purview/labels.ps1` creates all six and
> `verification/layer-04-audit.ps1` expects all six. L4's third criterion, V4.3, is
> supplementary and is in the table above.

> **(c) Criterion 10 (V3.3), 2026-09-22.** The quoted wording covers one policy state.
> `verification/layer-03-audit.ps1` now asserts that **each** CA policy is live in the
> state `infra/entra/manifest.json` declares — the two broad All-users/All-applications
> policies report-only, `mls-ca-require-mfa-dashboards` **enforced** — and that the
> enforced one really does require MFA, on exactly the three dashboard applications, with
> a populated break-glass exclusion behind it. The earlier form meant "an enabled CA policy
> exists" and failed on a tenant whose MFA was enforced by Security Defaults: assert the
> capability, not the artefact that usually accompanies it.

> **(d) Criterion 36 (V9.5), 2026-09-22.** The quoted wording is a cost-control toggle
> ending `Off`. `verification/layer-09-audit.ps1` now expects `pricingTier == "Standard"`
> — the estate deliberately runs Defender for Containers (F165) — and reports the Activity
> Log `pricings` writes beside the verdict rather than requiring them, because a quiet day
> with no writes is the normal case. **`layer-09-devsecops.yml`'s `defender` job still ends
> its round-trip with `-Disable`, so the deploy path and the audit disagree about the
> intended end state.** `L09.md` § Teardown records the conflict; it is a decision, not a
> documentation fix.

> **(e) Criteria 37 and 38 (V10.1, V10.2), 2026-09-22.** Both quoted wordings verify one
> **seeded** alert's trail against `apps/vuln-lab`. `verification/layer-10-audit.ps1` no
> longer works that way: V10.1 is "the backlog drains — no healable finding remains open
> past the SLO its severity declares, reported per lane and per severity", and V10.2 is
> "every closure is traceable". The seeding apparatus required re-arming, and a pull
> request that reintroduces a critical alert cannot merge past code scanning protection
> without an administrator override (F190). The stages survived in `Get-HealTrail` and
> apply per healed finding. `L10.md` § Validation cycle carries the full account.

> **(f) Criterion 42 (V11.4), 2026-09-22.** The master plan wrote `< 60 min`. Raised to
> **180** by sponsor decision after two measured cycles missed it: 87 min (2026-09-03) and
> 152.2 min (2026-09-21) — the measurement plus ~18% headroom. `L11.md`, `scripts/up.ps1`'s
> printed verdict and `verification/layer-11-audit.ps1`'s `-WallClockBudgetMinutes` default
> all carry 180; a figure declared in one place and enforced in another is the defect V1.5
> exists to catch.

Companion runbooks: `../demo-script.md` (stage flow),
`../kill-rebuild.md` (standard cycle + G3 variant), `../g0-bootstrap.md` (bootstrap;
agent-run since the 2026-08-29 sponsor amendment). Master plan:
`../../superpowers/plans/2026-08-22-g1-master-plan.md`.
