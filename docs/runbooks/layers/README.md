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
mapping — **40 criteria, 40 validation-cycle items, no criterion unmapped, none
duplicated.** (Cross-references exist — V11.2 *re-executes* the L3/L4 audits, V6.3
*closes* during the L7 window — but each criterion is owned by exactly one section.)

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
| 27 | L8 | Eval suite passes ≥ 9/10 with valid schema output and SQL that the Verifier re-executes against the lakehouse to confirm the numbers | `L08.md` § Validation cycle **V8.1** |
| 28 | L8 | No tool call outside the allowlist | `L08.md` § Validation cycle **V8.2** |
| 29 | L8 | p95 latency < 20 s | `L08.md` § Validation cycle **V8.3** |
| 30 | L9 | GitHub API shows all GHAS features enabled | `L09.md` § Validation cycle **V9.1** |
| 31 | L9 | A seeded CRITICAL image fails CI (negative test) then passes after pin | `L09.md` § Validation cycle **V9.2** |
| 32 | L9 | SBOM artifact present + SPDX-valid | `L09.md` § Validation cycle **V9.3** |
| 33 | L9 | ZAP report artifact exists with 0 High | `L09.md` § Validation cycle **V9.4** |
| 34 | L9 | Defender plan toggles on→off leaving state `Off` | `L09.md` § Validation cycle **V9.5** |
| 35 | L10 | Full chain observed via API trail for at least 2 of 3 seeded vulns: alert created → PR with triage comment → checks green → merged by automation → new ACA revision → alert state `fixed` (human sees the PR trail only) | `L10.md` § Validation cycle **V10.1** |
| 36 | L11 | All RGs absent post-down | `L11.md` § Validation cycle **V11.1** |
| 37 | L11 | Tenant objects intact (L3/L4 audits still pass) | `L11.md` § Validation cycle **V11.2** |
| 38 | L11 | Post-up: all layer audits green | `L11.md` § Validation cycle **V11.3** |
| 39 | L11 | Wall-clock < 60 min | `L11.md` § Validation cycle **V11.4** |
| 40 | L11 | Run-rate returns to idle profile | `L11.md` § Validation cycle **V11.5** |

Companion runbooks: `../demo-script.md` (stage flow),
`../kill-rebuild.md` (standard cycle + G3 variant), `../g0-bootstrap.md` (human-only
bootstrap). Master plan: `../../superpowers/plans/2026-08-22-g1-master-plan.md`.
