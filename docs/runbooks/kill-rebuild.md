# Kill/Rebuild Runbook — Standard Cycle and G3 Variant

Operational runbook for the demo's central trick: destroy the environment on demand,
rebuild it in under an hour, spend almost nothing in between. The standard cycle is
**gate-free by design** (CLAUDE.md hard rule 2); the full-tenant variant at the end
is **G3-gated** with an honest 2–3 hour rebuild SLA (spec F6). L11's playbook
(`docs/runbooks/layers/L11.md`) is the formal *proof* procedure; this runbook is the
day-to-day operation.

---

## 1. The line the cycle never crosses

| Dies every cycle (gate-free) | Persists every cycle (G3 to touch) |
|---|---|
| RGs `mls-rg-platform`, `mls-rg-apps`, `mls-rg-data`, `mls-rg-ops` — and everything in them (ACA env + apps, SQL, LAW/App Insights, storage, Key Vault, registry/images) | Entra users (5), groups (4), CA policies (report-only), app registrations (3) |
| Fabric workspace **items** in `mls-operations` (lakehouse `mls_operations` + its 10 Delta tables) — **and, since 2026-08-24, the Fabric data agent, which is a workspace item too** | Purview labels (Public/Internal/Confidential/Export-Controlled) + their GUIDs |
| Subscription-scope cost-export definition [derived — removed so it doesn't point at deleted storage] | Fabric workspace shell `mls-operations` + role assignments; the capacity itself |
| | OIDC federation on `mls-github-deployer`; `mls-verifier`; MG `mls` + policy/NIST assignments; the $75 budget; the GitHub repo and all its config |
| | **The Power Platform environment, its pay-as-you-go billing plan, and the Copilot Studio agent + its solution** (2026-08-24) — not RG-scoped, and re-import + republish + Direct Line reconfiguration does not fit inside the hour |

Why the line sits here: tenant-level objects propagate in 15–45 minutes — churning
them makes a <60-minute rebuild impossible (spec F6). Money is disposable; identity
is not.

## 2. `down.ps1` — semantics

```
pwsh scripts/down.ps1
```

Local wrapper over `.github/workflows/infra-down.yml` (dispatches it and tails the
run). What the workflow does, in order:

1. **Fabric item delete** — `infra/fabric/teardown-items.ps1` [derived name, per
   L05 playbook] deletes every item inside workspace `mls-operations`. The
   workspace shell and its role grants (including `mls-verifier` Viewer) survive.
2. **Capacity pause** — paid F2: ARM suspend; Fabric trial: no-op recorded ($0
   either way after this step).
3. **Cost-export definition delete** at subscription scope [derived, § 1].
4. **Four RG deletes, parallel** — `az group delete --yes --no-wait` on all four,
   then a wait-loop until all report gone. Empty or missing RGs no-op harmlessly:
   `down.ps1` is safe to re-run at any time, from any state.
5. **What it never touches:** anything in the right-hand column of § 1. There is no
   code path in `down.ps1` that can reach a tenant object — that separation is
   structural (different scripts, G3-gated), not a runtime flag.

Idempotent, order-safe, no confirmation prompt. Expected wall time: 10–20 minutes
for the deletes to fully drain (not on any rebuild clock).

## 3. Verifying the down state

Before declaring the environment dead (and always before a demo cold open), the
Verifier — or any operator, read-only — runs the down-state half of
`verification/layer-11-audit.ps1`:

| Check | Query | Pass |
|---|---|---|
| RGs gone | `az group list --query "[?starts_with(name,'mls-rg-')].name"` | `[]` |
| Workspace emptied | Fabric REST: list items in `mls-operations` | zero items; workspace shell present |
| Capacity | ARM state (paid F2) / trial equivalent | `Paused` / `Active (trial, $0)` |
| Tenant objects intact | re-run `verification/layer-03-audit.ps1` + `layer-04-audit.ps1` | both PASS, label GUIDs unchanged |
| No orphan spend | `az resource list --query "[?starts_with(name,'mls')]"` at subscription scope | only the plumbing set (OneLake storage, LAW-linked retained artifacts, budget) |
| Copilot Studio idle | Cost analysis → the Power Platform account resource (a *hidden type* — tick "View hidden types" in the portal) | $0 accruing; the agent survives the cycle but consumes nothing when nobody talks to it |
| Idle run-rate | Cost analysis, next-day data | < $5/month pro-rated (≈ $0.17/day) |

A tenant-object regression here is stop-the-line: `down.ps1` crossed the § 1
boundary — G4, and do not rebuild until root-caused.

## 4. `up.ps1` — replay order

```
pwsh scripts/up.ps1
```

Local wrapper over `.github/workflows/infra-up.yml` (layer-ordered full
instantiation, `workflow_dispatch`). Replay sequence and what each leg actually does
on a *standard* rebuild (tenant objects present):

| Leg | Replays | On standard rebuild | Time [derived] |
|---|---|---|---|
| 1 | L2 landing zone | idempotent no-op (MG, assignments exist) | ~1–2 min |
| 2 | L3 Entra (`apply-entra.ps1`) | create-if-absent no-ops in seconds | ~1–2 min |
| 3 | L4 labels (`labels.ps1`) | create-if-absent no-op; GUIDs untouched | ~1 min |
| 4a | L5 Fabric + seed | **real work**: resume capacity (G2 stated per resume; trial $0), recreate lakehouse `mls_operations`, `python -m generators build` (seed `20260822`), load 10 tables, re-pause | ~20–25 min |
| 4b | L6 platform Bicep | **real work**: full redeploy into `mls-rg-platform` (+ data/ops RG contents per the Bicep tree); Key Vault recovers from soft-delete; cost export recreated | ~12–18 min |
| 5 | L7 apps | `layer-07-apps.yml` redeploys the whole `infra/bicep/apps` template into `mls-rg-apps` **by image digest** — five serving container apps (`launch-ops`, `control-tower`, `data-api`, `mcp-tools`, `compliance`) plus the L10 witness. No image is rebuilt: `infra-up.yml` deliberately does not call the per-app CI workflows, because GHCR does not die with the resource groups | ~10–15 min |
| 6 | L8 MCP tools CI + agent repoint + eval | **real work**: rebuild/deploy `apps/mcp-tools` to ACA; **repoint the surviving Copilot Studio agent at the new MCP FQDN** (the ACA environment's domain suffix changes when the RG is recreated) and, on the paid-F2 path, recreate + republish the Fabric data agent and reattach it; then the golden-question eval over Direct Line (needs capacity resumed — scheduled inside leg 4a's window or its own stated resume) | ~10–14 min |
| 7 | L9 chain re-verify | config-as-code already in repo; re-assert states (Defender `Free`) | ~2–3 min |
| — | L10 re-arm | **not in the timed path** — `apps/vuln-lab/reseed.ps1` is demo-prep, run from the pre-demo checklist [derived, per L11 playbook] | — |
| 8 | Verifier audits L1–L10 | full independent re-audit | ~8–10 min |

[derived] Scheduling: legs 4a and 4b have no mutual dependency and run as parallel
workflow jobs; legs 5–6 need 4b (ACA env), and leg 6's eval needs 4a (lakehouse). Leg 5
brings the compliance board back with everything else — its state artifact was never in
Azure to lose, so it needs no reseed of any kind (L12).
The master plan mandates the replay set ("L2–L10 pipelines + seed") and the <60 min
outcome; the parallelization is the conservative schedule that achieves it.

## 5. The <60-minute clock

**Clock starts:** `up.ps1` invocation. **Clock stops:** last synchronous layer
audit green. Recorded from two independent sources (script timestamps + GitHub run
timestamps) into `verification/reports/rebuild-proof.md` (L11).

**Critical path** (the thing to watch when the clock runs hot):

```
up.ps1 → [L2–L4 no-ops ~4m] → L6 platform ~15m → L7 apps ~12m → L8 mcp+repoint+eval ~12m → audits ~9m
                             ↘ L5 fabric+seed ~22m (parallel; must finish before L8's eval)
≈ 52 minutes nominal, ~8 minutes of margin
```

What eats the margin, in observed-likelihood order:

1. **Fabric SQL-endpoint sync lag** after lakehouse recreation (L5 audit's V5.3
   wait) — the single most variable leg.
2. **Uncached container builds** (registry died with the RGs; every image rebuilds
   from scratch — keep Dockerfiles lean, use build cache actions).
3. **Key Vault soft-delete recovery** hiccups in L6 (recover-mode template handles
   it; a purge-protection conflict does not).
4. **The agent-repoint step in leg 6** (new, 2026-08-24). The Copilot Studio agent
   outlives the RGs, so every rebuild leaves it pointing at an MCP server that no longer
   exists, and — on the paid-F2 path — at a deleted Fabric data agent. Both are scripted;
   both are new failure surface that did not exist when the copilot was just another
   container in `mls-rg-apps`. If the agent answers but every tool call fails after a
   rebuild, this is why (L08 failure mode 5).
5. **Serialized legs that should be parallel** (a workflow-dependency regression —
   compare the Actions graph against the table above).

**Excluded from the clock** (async by definition, tracked to closure in the proof
report): V6.3 first cost-export file (≤ 24 h), V6.4 SQL auto-pause (+75 min), V11.5
idle run-rate (next-day consumption data).

If the clock exceeds 60 minutes: that is a failed V11.4 on a proof run — remediate
the named bottleneck and re-run the full cycle clean (L11 Rollback; two consecutive
failures → G4). On a non-proof operational rebuild, log the overage and the cause in
the run notes — the SLA claim always cites the latest committed proof, never an
unmeasured assertion.

## 6. Cost of a cycle

~$1–2 per cycle (master plan): the Fabric resume window on paid F2 (~$0.36/hr ×
~2 h; $0 during the 60-day trial) + SQL serverless activity during seed/eval + CI
minutes ($0, public repo). Every capacity resume carries its G2 statement — during
the trial that statement reads "$0 delta", and it is still filed (the discipline is
the point; the paid-F2 switch changes the number, not the process).

## 7. G3 variant — full-tenant teardown (and its honest SLA)

For end-of-life, tenant handback, or a deliberate from-absolute-zero rehearsal.
**Every step below is G3: per-occurrence human approval with stated scope. None of
this is ever run by the standard cycle.**

Teardown order (reverse-dependency):

1. `infra/purview/teardown.ps1` — label policy, then the 4
   labels. Consequence: recreated labels get **new GUIDs**;
   `verification/reports/label-guids.json` must be re-baselined in the PR that
   records the G3 approval.
2. `infra/entra/teardown.ps1` — CA policies, app registrations, groups, users (5/4/3
   per manifest). Consequence: all recorded object IDs invalidated; licenses return
   to the pool.
3. Fabric workspace shell `mls-operations` delete (REST) — and, if fully exiting,
   the capacity itself.
3b. **Copilot Studio: delete the agent's solution, then the environment, then unlink or
   delete the pay-as-you-go billing plan** (2026-08-24). Consequence: the Direct Line
   secret and token endpoint are invalidated, so the Key Vault entries must be re-seeded
   by a human on rebuild (G0 item C7); the environment ID recorded in the deploy workflow
   is invalidated too. Note that deleting the billing plan does not delete its Power
   Platform account resource in Azure — remove that separately or it lingers, untagged,
   in the resource group.
4. `infra/policy/teardown.ps1` — NIST + policy assignments removed, subscription
   moved to tenant root, MG `mls` deleted.
5. OIDC federation + `mls-github-deployer` / `mls-verifier` app registrations
   removed (the last step — it cuts off the automation's own hands; after this,
   only the human's login can act).

Rebuild from absolute zero = G0 (human, `docs/runbooks/g0-bootstrap.md`) + L1–L11
with **live tenant-object creation**: Entra propagation, CA policy replication, and
label replication each lag 15–45 minutes, serialized across L2→L3→L4 with
Verifier-gated audits between. **Honest SLA: 2–3 hours** (spec F6) — plus human
time for G0's portal-only steps (trials, Fabric SP toggle). The <60-minute claim
never applies to this path, and the demo script never depends on it: the standard
cycle exists precisely so the show can promise the hour.

## 8. Quick reference

```
# kill (gate-free, idempotent, run from repo root)
pwsh scripts/down.ps1

# verify dead (read-only)
az group list --query "[?starts_with(name,'mls-rg-')].name"    # expect []

# rebuild (G2 statement for the capacity resume rides with the run)
pwsh scripts/up.ps1

# verify alive (Verifier)
foreach ($n in 1..10) { pwsh verification/layer-$('{0:d2}' -f $n)-audit.ps1 }

# the proof of record
verification/reports/rebuild-proof.md
```
