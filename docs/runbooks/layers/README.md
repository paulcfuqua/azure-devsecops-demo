# Layer Playbooks — Index and Verify-Criterion Traceability

One playbook per master-plan layer, `L01.md` … `L11.md` (master-plan L0 is local
toolchain work covered by `docs/runbooks/g0-bootstrap.md` § A and Phase P Track H —
it has no cloud state and no layer playbook). Every playbook carries the same eight
sections: Purpose, Preconditions, Deploy procedure, Validation cycle, Teardown,
Rollback, Failure modes, Deferred validation.

**Traceability rule (Phase P Track D):** every Verify criterion in the master plan's
L1–L11 sections appears in **exactly one** playbook's Validation cycle, as a numbered
item `V<layer>.<n>` quoting the criterion verbatim before expanding it into the exact
Verifier query, expected values, and retry window. The table below is the full
mapping — **43 criteria, 43 validation-cycle items, no criterion unmapped, none
duplicated.** (Cross-references exist — V11.2 *re-executes* the L3/L4 audits, V6.3
*closes* during the L7 window — but each criterion is owned by exactly one section.)

> **Re-checked 2026-08-24** after the Copilot Studio amendment. The count moved from 40
> to 43: L8's three criteria became five (the agent is now a deployed Power Platform
> solution, so provenance and card validity are separately checkable), and L10's single
> criterion became two (Copilot Autofix heals CodeQL alerts; Dependabot heals dependency
> alerts — two mechanisms, two trails, so one criterion could not honestly cover both).
> L1–L7, L9 and L11 are untouched.

Naming note: workflow file names of the form `layer-<nn>-<name>.yml` instantiate the
master plan's `layer-<nn>-*.yml` pattern and are marked [derived] at first use in
each playbook.

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
| 10 | L3 | CA policy state == `enabledForReportingButNotEnforced` | `L03.md` § Validation cycle **V3.3** |
| 11 | L3 | License assignment state == success for all 5 | `L03.md` § Validation cycle **V3.4** |
| 12 | L4 | `Get-Label` returns the 4 labels with expected GUIDs recorded to `verification/reports/` | `L04.md` § Validation cycle **V4.1** |
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
| 29 | L8 | No tool invoked outside the five-tool allowlist and the agent declares exactly those five | `L08.md` § Validation cycle **V8.3** |
| 30 | L8 | Every visual answer is an Adaptive Card payload that validates against the pinned Adaptive Cards schema; zero HTML/JS/JSX in any response | `L08.md` § Validation cycle **V8.4** |
| 31 | L8 | p95 latency < 20 s | `L08.md` § Validation cycle **V8.5** |
| 32 | L9 | GitHub API shows all GHAS features enabled | `L09.md` § Validation cycle **V9.1** |
| 33 | L9 | A seeded CRITICAL image fails CI (negative test) then passes after pin | `L09.md` § Validation cycle **V9.2** |
| 34 | L9 | SBOM artifact present + SPDX-valid | `L09.md` § Validation cycle **V9.3** |
| 35 | L9 | ZAP report artifact exists with 0 High | `L09.md` § Validation cycle **V9.4** |
| 36 | L9 | Defender plan toggles on→off leaving state `Off` | `L09.md` § Validation cycle **V9.5** |
| 37 | L10 | For the seeded CodeQL alert, the full Autofix trail holds — alert created → autofix status `success` → PR whose head commit is the Autofix commit and whose body carries Autofix's explanation → gauntlet checks all green → merged by automation (no human merger) → new ACA revision → alert state `fixed`, timestamps monotonic | `L10.md` § Validation cycle **V10.1** |
| 38 | L10 | For at least 2 of the 3 seeded dependency pins, the Dependabot trail holds — alert created → Dependabot patch PR → gauntlet green → merged by automation → new ACA revision → alert state `fixed` | `L10.md` § Validation cycle **V10.2** |
| 39 | L11 | All RGs absent post-down | `L11.md` § Validation cycle **V11.1** |
| 40 | L11 | Tenant objects intact (L3/L4 audits still pass) | `L11.md` § Validation cycle **V11.2** |
| 41 | L11 | Post-up: all layer audits green | `L11.md` § Validation cycle **V11.3** |
| 42 | L11 | Wall-clock < 60 min | `L11.md` § Validation cycle **V11.4** |
| 43 | L11 | Run-rate returns to idle profile | `L11.md` § Validation cycle **V11.5** |

Companion runbooks: `../demo-script.md` (stage flow),
`../kill-rebuild.md` (standard cycle + G3 variant), `../g0-bootstrap.md` (human-only
bootstrap). Master plan: `../../superpowers/plans/2026-08-22-g1-master-plan.md`.
