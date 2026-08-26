# Security Remediation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the 15 findings from the 2026-08-26 pre-publication security review, capturing each one first as durable data so nothing survives only in conversation. Task 2 scrubs for 800-53/CMMC gaps the 800-171 pass didn't cover and found three more (F16-F18), bringing the total to 18.

**Architecture:** Task 1 authors every finding into `compliance/assessment/*.json` in the schema defined by the compliance-platform spec — this is simultaneously the durable record, the remediation tracker, and the seed data Plan 2's platform renders. Task 2 runs the additional 800-53/CMMC scrubs so newly-found gaps are closed in the same pass rather than a later one. Tasks 3+ close gaps in dependency order: the dead CI leg first (nothing else can be trusted green until CI actually runs), then the unauthenticated internet endpoints (the only findings an outsider can exploit today), then privilege reduction, then observability, then the app-layer bugs.

**Tech Stack:** PowerShell 7 + Pester 6 (collectors, audits, bootstrap), TypeScript + vitest (apps), Bicep + AVM (infra), GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-08-26-compliance-platform-design.md` (schema only — §3.2 defines the assessment record this plan authors). The findings themselves are recorded in Task 1 of this plan, which is their system of record.

## Global Constraints

- **No Azure/Entra/Fabric/GitHub-org writes.** Nothing is deployed. Every task is authoring + local test only. `CLAUDE.md` hard rule 1.
- **No secrets in the repo and none in CI.** The only stored runtime secrets are Key Vault entries (`directline-secret`, `mcp-auth-token`). `CLAUDE.md` hard rule 5.
- **Synthetic data only.** No real PII. Demo personas stay fictional; real presenters are portal-only, never in `manifest.json`.
- **Conventional commits:** `feat:`, `fix:`, `infra:`, `docs:`, `verify:`. Layer work references its layer, e.g. `infra(L6): …`.
- **CI targets `ubuntu-latest` (bash); local orchestration targets `pwsh` 7.** Never assume Windows PowerShell 5.1.
- **Gate every change on the full local suite:** Pester (currently 605), PSScriptAnalyzer 0 at Error/Warning, `npm test` exit 0 across 7 workspaces, pytest 30, and `az bicep build` on all 3 `.bicep` + 3 `.bicepparam` files.
- **Naming:** `mls-<app|role>-<env>-<type>`. Prefix set once in `infra/bicep/naming.bicep`; never hardcode `mls` elsewhere.
- **Every finding's assessment file is updated in the same commit as its fix** — the register must never claim a gap is closed before it is.

---

## Task 1: Author the remediation register

Durable capture. Until this lands, all 15 findings exist only in a chat transcript.

**Files:**
- Create: `compliance/assessment/*.json` (one per affected control)
- Create: `compliance/findings/2026-08-26-prepublication-review.md` (narrative record with attack paths and file:line)
- Create: `compliance/README.md`
- Test: `compliance/tests/register.Tests.ps1`

**Interfaces:**
- Consumes: nothing.
- Produces: the assessment-record schema instances every later task updates; `compliance/findings/2026-08-26-prepublication-review.md` as the finding→control index.

**Schema** (from spec §3.2 — reproduced here because the executor may read tasks out of order):

```json
{
  "control": "3.1.1",
  "applicability": "applicable",
  "criteria": [],
  "assertion": {
    "status": "GAP",
    "evidence": ["compliance/findings/2026-08-26-prepublication-review.md#f2"],
    "assertedBy": "paulcfuqua",
    "assertedAt": "2026-08-26",
    "rationale": "data-api has ingressExternal:true and no inbound authentication."
  },
  "recommendation": "Add an inbound auth gate, or set ingressExternal:false and reach it over the Container Apps internal network.",
  "gapSeverity": "critical",
  "references": ["apps/data-api/src/app.ts:56", "infra/bicep/apps/main.bicep:334"]
}
```

**The 15 findings and their control mappings:**

| # | Finding | Controls | Severity | Closed by |
|---|---|---|---|---|
| F1 | `data-api` external ingress, no auth | 3.1.1, 3.1.2, 3.13.1 | critical | Task 6 |
| F2 | MCP auth gate inert (`MLS_TOOL_BACKENDS` unset; token never plumbed) | 3.1.1, 3.5.1, 3.13.1 | critical | Tasks 4, 5 |
| F3 | Direct Line token endpoint fails open twice | 3.1.1, 3.5.1 | high | Task 7 |
| F4 | App Insights connection string + subscription inventory in public job summary | 3.1.3, 3.13.16 | high | Task 8 |
| F5 | `lint-ci` node leg dead — `npm test` never runs in CI | 3.12.3, 3.14.1 | high | Task 3 |
| F6 | `mls-verifier` has no federated credential | 3.12.1, 3.12.3 | high | Task 9 |
| F7 | `environment: demo` mints an Owner-capable OIDC subject | 3.1.5, 3.1.6, 3.1.7 | high | Task 9 |
| F8 | `Application.ReadWrite.All` on the deployer | 3.1.5 | high | Task 10 |
| F9 | Zero `diagnosticSettings` in the estate | 3.3.1, 3.3.2, 3.3.5 | high | Task 13 |
| F10 | NIST policy identity holds standing Contributor | 3.1.5 | medium | Task 11 |
| F11 | `javascript:` href accepted in Adaptive Cards; no CSP | 3.14.1 | high | Task 14 |
| F12 | SQL gate: unterminated comment/quote swallows the tail | 3.14.1 | medium | Task 15 |
| F13 | Zero workload RBAC expressed in IaC | 3.1.1, 3.1.2, 3.1.5 | high | Task 12 |
| F14 | `self-heal` branch-squatting kill switch + missing `ref` filter | — (availability) | medium | Task 16 |
| F15 | Cost export non-functional (container mismatch + missing grant) | — (cost control) | medium | Task 17 |
| F16 | Azure SQL backup posture never decided or verified | CP-9 | medium | Task 18 |
| F17 | Zero alert rules or action groups anywhere in the estate | SI-4, IR-4 | high | Task 19 |
| F18 | Sensitivity labels published nowhere — a taxonomy, not a control | CM-6 | medium | Task 20 |
| F19 | cost-ingest documented as deployed; deploys nowhere | — (availability/completeness) | medium | *unassigned* |
| F20 | data-api's contained-user grant is expressed but never applies | — (availability) | medium | *unassigned* |
| F21 | `mls-verifier`'s documented Fabric workspace Viewer grant does not exist | — (availability — breaks the Verifier sign-off gate) | high | *unassigned* |

F14 and F15 map to no 800-171 control. They are recorded in `compliance/findings/` and tracked here so they do not fall through the gap between the security and compliance framings. F16–F18 (Task 2's 800-53/CMMC scrub) map to NIST SP 800-53 Rev 5 controls that 800-171 tailors *out* — CP-9, SI-4, IR-4, CM-6 — rather than to a 3.x 800-171 control. F19–F21 were surfaced building Task 12 (F13's closing task): same shape again — a document asserting something the code never does — but none is a CUI-protection gap, so none maps to an 800-171 control either. No task in this plan owns closing them; they need one.

- [ ] **Step 1: Write the failing test**

```powershell
# compliance/tests/register.Tests.ps1
BeforeAll {
    $script:Root = Join-Path $PSScriptRoot '..' 'assessment'
    $script:Findings = Join-Path $PSScriptRoot '..' 'findings' '2026-08-26-prepublication-review.md'
}

Describe 'remediation register' {
    It 'has an assessment file for every control named in the findings table' {
        $expected = @('3.1.1','3.1.2','3.1.3','3.1.5','3.1.6','3.1.7',
                      '3.3.1','3.3.2','3.3.5','3.5.1','3.12.1','3.12.3',
                      '3.13.1','3.13.16','3.14.1')
        foreach ($c in $expected) {
            Test-Path (Join-Path $script:Root "$c.json") | Should -BeTrue -Because "$c is cited by a finding"
        }
    }

    It 'produces valid JSON with the required fields' {
        foreach ($f in Get-ChildItem $script:Root -Filter *.json) {
            $r = Get-Content $f.FullName -Raw | ConvertFrom-Json
            $r.control       | Should -Not -BeNullOrEmpty
            $r.applicability | Should -BeIn @('applicable','not-applicable')
            $r.recommendation| Should -Not -BeNullOrEmpty
        }
    }

    It 'never marks not-applicable without a justification' {
        foreach ($f in Get-ChildItem $script:Root -Filter *.json) {
            $r = Get-Content $f.FullName -Raw | ConvertFrom-Json
            if ($r.applicability -eq 'not-applicable') {
                $r.naJustification | Should -Not -BeNullOrEmpty
            }
        }
    }

    It 'every assertion cites at least one piece of evidence' {
        foreach ($f in Get-ChildItem $script:Root -Filter *.json) {
            $r = Get-Content $f.FullName -Raw | ConvertFrom-Json
            if ($null -ne $r.assertion) {
                @($r.assertion.evidence).Count | Should -BeGreaterThan 0
            }
        }
    }

    It 'the narrative findings record exists and covers all 15' {
        Test-Path $script:Findings | Should -BeTrue
        $body = Get-Content $script:Findings -Raw
        1..15 | ForEach-Object { $body | Should -Match "(?m)^#+\s*F$_\b" }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -c "Invoke-Pester compliance/tests/register.Tests.ps1"`
Expected: FAIL — `compliance/assessment` does not exist.

- [ ] **Step 3: Write the register**

Create `compliance/findings/2026-08-26-prepublication-review.md` with one `## F<n>` section per finding, each carrying: severity, confidence (CONFIRMED/SUSPECTED), `file:line`, the concrete attack path, impact including cost, and the fix. Copy the detail from the four auditor reports — do not summarise it away; the attack paths are why the fixes are shaped as they are.

Then create one `compliance/assessment/<control>.json` per control in the mapping table, using the schema above. Where several findings hit one control (3.1.1 is cited by F1, F2, F3, F13), the `rationale` names each and `evidence` lists each anchor.

- [ ] **Step 4: Run tests to verify they pass**

Run: `pwsh -c "Invoke-Pester compliance/tests/register.Tests.ps1"`
Expected: PASS, 5 tests.

- [ ] **Step 5: Commit**

```bash
git add compliance/
git commit -m "docs(compliance): remediation register for the 2026-08-26 review

Fifteen findings authored as assessment records in the schema from
2026-08-26-compliance-platform-design.md §3.2, so they are durable data
rather than conversation, and double as seed data for the platform.

F14 and F15 map to no 800-171 control (availability and cost); they are
tracked in compliance/findings/ so they do not fall between framings."
```

---

## Task 2: Additional 800-53 and CMMC scrubs

Sponsor asked for these *before* remediation so newly-found gaps close in the same pass.

**Files:**
- Modify: `compliance/findings/2026-08-26-prepublication-review.md` (append F16+)
- Modify/Create: `compliance/assessment/*.json`

**Interfaces:**
- Consumes: Task 1's register and schema.
- Produces: any additional findings, in the same shape, folded into the task list below.

- [ ] **Step 1: Run the scrub**

Review the estate against the 800-53 Rev 5 moderate baseline families that 800-171 tailors *out* but CMMC assessors still probe — principally CM-6 (configuration settings), SI-4 (system monitoring), CP-9 (backup), and IR-4 (incident handling) — plus CMMC L1's 15 FAR safeguards. Record only gaps not already covered by F1–F15.

Known candidates from the 800-171 pass, to confirm or dismiss: no backup/PITR configuration on Azure SQL (`infra/bicep/platform/main.bicep`), `Standard_LRS` with no geo-redundancy, no alert rules or action groups anywhere, and sensitivity labels created without a publishing policy (`infra/purview/labels.ps1`) so they enforce nothing.

- [ ] **Step 2: Append findings to the register**

Same schema. Number them F16 onward.

- [ ] **Step 3: Update this plan**

Add a task per new finding, placed by dependency, and update the Task 1 mapping table.

- [ ] **Step 4: Run the register tests**

Run: `pwsh -c "Invoke-Pester compliance/tests/register.Tests.ps1"`
Expected: PASS (update the expected-controls list first if new controls appeared).

- [ ] **Step 5: Commit**

```bash
git add compliance/ docs/superpowers/plans/2026-08-26-security-remediation.md
git commit -m "docs(compliance): 800-53 and CMMC scrub findings appended to the register"
```

---

## Task 3: Fix the dead CI leg (F5)

First, because until CI actually runs the JS tests, no later task's green is trustworthy.

**Files:**
- Modify: `.github/workflows/lint-ci.yml:194-202`
- Test: manual reproduction (shell behaviour, not unit-testable)

**Interfaces:**
- Consumes: nothing.
- Produces: a `node` job that reaches `npm test`, making `vitest (npm workspace)` selectable as a required status check.

- [ ] **Step 1: Reproduce the failure**

```bash
mkdir -p /tmp/cicheck && cd /tmp/cicheck
bash -c 'set -euo pipefail
for script in .github/scripts/*.mjs; do node --check "${script}"; done
echo "LOOP COMPLETED"'; echo "exit: $?"
```

Expected: `MODULE_NOT_FOUND`, exit 1, `LOOP COMPLETED` never printed. That is the step failing on the literal unexpanded glob, killing the job before `npm ci`.

- [ ] **Step 2: Remove the step**

`.github/scripts/` was deleted by the 2026-08-24 amendment (`.github/README.md:135`). The step guards files that no longer exist, so delete it entirely — lines 196-202, the whole `Syntax-check the committed CI scripts` block. Do not "fix" it with `shopt -s nullglob`: a step that silently checks nothing is worse than no step.

- [ ] **Step 3: Verify the job now reaches the tests**

Run: `pwsh -c "npm test"` from the repo root.
Expected: exit 0 across 7 workspaces — this is what CI will now execute.

- [ ] **Step 4: Verify actionlint is still clean**

Run: `actionlint .github/workflows/lint-ci.yml`
Expected: no output.

- [ ] **Step 5: Update the register and commit**

Set `compliance/assessment/3.12.3.json` and `3.14.1.json` assertion status for F5 to `CLOSED` with the commit SHA as evidence.

```bash
git add .github/workflows/lint-ci.yml compliance/assessment/
git commit -m "fix(ci): remove dead .mjs syntax-check that killed the node job

The step globbed .github/scripts/*.mjs, deleted by the 2026-08-24
amendment. With set -euo pipefail and no nullglob, bash passed the
literal glob, node --check exited 1, and the job died at its first
step — so npm ci, build, typecheck, npm test across 7 workspaces and
the vuln-lab CVE-seed check never ran in CI. Closes F5."
```

---

## Task 4: Make the MCP auth gate enforce by default (F2, part 1)

**Files:**
- Modify: `apps/mcp-tools/src/auth-gate.ts:123-147`
- Modify: `apps/mcp-tools/src/app.ts:50` (move the gate above the body parser — L3 from the appsec review)
- Test: `apps/mcp-tools/tests/auth-gate.test.ts`

**Interfaces:**
- Consumes: nothing.
- Produces: `loadInboundAuth(env, backendMode)` whose enforcement no longer depends on `backendMode`.

**Why:** enforcement was conditional on `backendMode === "cloud"`, and `MLS_TOOL_BACKENDS` is set nowhere in Bicep or CI, so the shipped server runs `local` → gate off → `enforced: false`, with external ingress. The risk is the ingress, not the backend mode.

- [ ] **Step 1: Write the failing tests**

```typescript
it("enforces by default even in local mode when nothing opts out", () => {
  // The deployed container sets no MLS_TOOL_BACKENDS, so local mode is the
  // configuration that actually ships — it must not be the unguarded one.
  expect(() => loadInboundAuth({} as NodeJS.ProcessEnv, "local")).toThrow(/MCP_AUTH_TOKEN/);
});

it("allows an open endpoint only when explicitly chosen, in either mode", () => {
  for (const mode of ["local", "cloud"] as const) {
    const auth = loadInboundAuth(
      { MCP_ALLOW_UNAUTHENTICATED: "true" } as NodeJS.ProcessEnv, mode);
    expect(auth.deliberatelyOpen).toBe(true);
    expect(describeInboundAuth(auth)).toMatch(/DISABLED/);
  }
});

it("parses the body only after the gate has run", async () => {
  // A 1MB JSON parse must not be reachable without a credential.
  const { server, url } = await start(enforced);
  const res = await fetch(`${url}${MCP_PATH}`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ padding: "x".repeat(900_000) }),
  });
  expect(res.status).toBe(401);
  await stop(server);
});
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd apps/mcp-tools && npx vitest run tests/auth-gate.test.ts`
Expected: FAIL — the first test does not throw; the third returns non-401.

- [ ] **Step 3: Implement**

In `auth-gate.ts`, drop `backendMode` from the throw condition:

```typescript
if (token === undefined && !allowOpen) {
  throw new Error(
    "MCP_AUTH_TOKEN is required.\n" +
      "  This server runs with external ingress in every deployed configuration, so\n" +
      "  without it the five tools are callable by anyone who finds the URL, and every\n" +
      "  call bills the subscription.\n" +
      "  Set MCP_AUTH_TOKEN (the platform injects it from Key Vault), or set\n" +
      "  MCP_ALLOW_UNAUTHENTICATED=true if an open endpoint is genuinely what you intend.",
  );
}
return { token, enforced: token !== undefined, deliberatelyOpen: token === undefined && allowOpen };
```

`backendMode` stays a parameter (the message differs for local development) but no longer gates enforcement. In `app.ts`, move `app.use(MCP_PATH, gate)` above `app.use(express.json(...))`.

Local development sets `MCP_ALLOW_UNAUTHENTICATED=true` in `apps/mcp-tools/package.json`'s `dev` script so the laptop path stays frictionless while the deployed path fails closed.

- [ ] **Step 4: Run the full workspace suite**

Run: `cd apps/mcp-tools && npm test`
Expected: PASS. Existing tests that construct a bare local config will need `MCP_ALLOW_UNAUTHENTICATED` or a token — update them; that churn is the point.

- [ ] **Step 5: Commit**

```bash
git add apps/mcp-tools/ compliance/assessment/
git commit -m "fix(mcp-tools): enforce inbound auth by default, not by backend mode

Enforcement was conditional on backendMode === 'cloud', but
MLS_TOOL_BACKENDS is set nowhere in Bicep or CI, so the shipped
container ran local mode with the gate off and external ingress. The
risk is the ingress, not the backend. Also moves the gate above the
1MB JSON body parser. Closes F2 (app half)."
```

---

## Task 5: Plumb `mcp-auth-token` from Key Vault (F2, part 2)

**Files:**
- Modify: `infra/bicep/apps/main.bicep` (Key Vault reference + `MLS_TOOL_BACKENDS`)
- Modify: `infra/bicep/apps/demo.bicepparam` (remove `mcpAuthToken`)
- Modify: `infra/bicep/apps/modules/key-vault-secrets-user-role.bicep` (repurpose from the deleted `copilot-svc`)
- Test: `az bicep build`

**Interfaces:**
- Consumes: Task 4's env-var contract (`MCP_AUTH_TOKEN`, `MCP_ALLOW_UNAUTHENTICATED`).
- Produces: a container app whose secret comes from Key Vault via its own UAMI — no secure param, no deployment history exposure, no CI secret.

**Why the Key Vault reference and not the secure param:** the current `@secure()` param crosses a module boundary into a nested deployment declared as a plain `array`, so the token may land in ARM deployment history readable by anything with Reader — which is what `mls-verifier` holds. It is also rendered by `az deployment group what-if` into a **public** repo's workflow log. The `keyVaultUrl` form removes all three exposures and needs no data-plane role on the deployer.

- [ ] **Step 1: Write the failing check**

```bash
az bicep build --file infra/bicep/apps/main.bicep --stdout \
  | jq -e '.resources[] | select(.name | test("mcp-tools")) | .properties.template.resources[]?
           | .properties.configuration.secrets[]? | select(.keyVaultUrl)' > /dev/null
```
Expected: FAIL (exit 1) — no `keyVaultUrl` secret exists yet.

- [ ] **Step 2: Implement**

Repurpose the existing unreferenced module (its header still cites `copilot-svc` and `ANTHROPIC_API_KEY`, both deleted in August — update it), grant the mcp-tools UAMI `Key Vault Secrets User` on the platform vault, and switch the container app to a vault reference:

```bicep
resource platformKv 'Microsoft.KeyVault/vaults@2024-11-01' existing = {
  scope: az.resourceGroup(platformRgName)
  name: naming.keyVaultName(companyPrefix, env)
}

module mcpKvGrant 'modules/key-vault-secrets-user-role.bicep' = {
  scope: az.resourceGroup(platformRgName)
  params: { keyVaultName: platformKv.name, principalId: mcpToolsIdentity.outputs.principalId }
}

// in mcpToolsApp:
secrets: [{
  name: 'mcp-auth-token'
  keyVaultUrl: '${platformKv.properties.vaultUri}secrets/mcp-auth-token'
  identity: mcpToolsIdentity.outputs.resourceId
}]
env: concat([ /* existing three */ ], [
  { name: 'MCP_AUTH_TOKEN', secretRef: 'mcp-auth-token' }
  { name: 'MLS_TOOL_BACKENDS', value: mcpToolsBackendMode }
])
```

Delete `param mcpAuthToken` from `main.bicep` and `demo.bicepparam`. Add `param mcpToolsBackendMode string = 'local'` so the mode is a deployment decision rather than an omission.

- [ ] **Step 3: Verify the build and the check**

Run: `az bicep build --file infra/bicep/apps/main.bicep --stdout > /dev/null && echo OK`
Then re-run Step 1's `jq` check.
Expected: both pass.

- [ ] **Step 4: Confirm no secure param remains**

Run: `grep -n "mcpAuthToken\|@secure" infra/bicep/apps/main.bicep infra/bicep/apps/demo.bicepparam`
Expected: no `mcpAuthToken` hits.

- [ ] **Step 5: Update the runbook, register and commit**

Amend `docs/runbooks/g0-bootstrap.md` item C11: the workflow no longer exports the token; the container app resolves it from Key Vault directly. Correct the `infra/copilot-studio/agent-definition.md:248` note that still records connector auth as an open decision.

```bash
git add infra/bicep/ docs/runbooks/g0-bootstrap.md infra/copilot-studio/ compliance/assessment/
git commit -m "infra(L7): resolve mcp-auth-token from Key Vault, not a secure param

Closes F2 (infra half). The secure param crossed a module boundary into
a nested deployment declared as a plain array, risking exposure in ARM
deployment history readable by Reader, and was rendered into a public
what-if log. The keyVaultUrl + UAMI form removes all three and needs no
data-plane role on the deployer. Also sets MLS_TOOL_BACKENDS explicitly."
```

---

## Task 6: Authenticate `data-api` (F1)

The worst cost path in the estate: one unauthenticated request every 59 minutes holds `GP_S_Gen5` serverless SQL open at roughly $188/month, against a $200 credit.

**Files:**
- Modify: `infra/bicep/apps/main.bicep:327-376`
- Modify: `apps/control-tower/nginx.conf.template`, `apps/launch-ops/nginx.conf.template`
- Test: `apps/data-api/tests/ingress.test.ts` (new)

**Interfaces:**
- Consumes: nothing.
- Produces: a `data-api` unreachable from the public internet.

**Approach — internal ingress, not a token.** Both frontends already proxy `/api/*` server-side through nginx, so the only legitimate callers live inside the Container Apps environment. Setting `ingressExternal: false` is strictly better than a shared secret: nothing to distribute, nothing to rotate, nothing to leak from a static bundle. The `/healthz` convenience the header comment cites is met with `az containerapp exec`.

- [ ] **Step 1: Write the failing test**

```typescript
// apps/data-api/tests/ingress.test.ts
import { readFileSync } from "node:fs";
it("data-api is not exposed to the public internet", () => {
  const bicep = readFileSync("../../infra/bicep/apps/main.bicep", "utf8");
  const block = bicep.slice(bicep.indexOf("module dataApiApp"), bicep.indexOf("module launchOpsApp"));
  expect(block).toMatch(/ingressExternal:\s*false/);
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd apps/data-api && npx vitest run tests/ingress.test.ts`
Expected: FAIL — currently `ingressExternal: true`.

- [ ] **Step 3: Implement**

Set `ingressExternal: false` on `dataApiApp`. Confirm both nginx templates proxy `/api/` to the internal FQDN (`DATA_API_ORIGIN`) — `control-tower` already does at lines 45-56; add the equivalent to `launch-ops` if absent. Update the header comment at `main.bicep:41-46` to record why.

- [ ] **Step 4: Verify**

Run: `cd apps/data-api && npm test` and `az bicep build --file infra/bicep/apps/main.bicep --stdout > /dev/null`
Expected: PASS and exit 0.

- [ ] **Step 5: Commit**

```bash
git add infra/bicep/apps/main.bicep apps/ compliance/assessment/
git commit -m "infra(L7): make data-api internal-only

Closes F1. data-api had external ingress and, by its own comment, no
Authorization at all, while holding a managed identity reading SQL,
the lakehouse, Log Analytics, Defender and GitHub Security. One
unauthenticated request an hour keeps serverless SQL from auto-pausing
— about \$188/month against a \$200 credit. Both frontends proxy it
server-side, so internal ingress costs nothing and beats a shared
secret."
```

---

## Task 7: Close the Direct Line token faucet (F3)

**Files:**
- Modify: `apps/directline-token/src/functions/directline-token.mjs:60-67`
- Test: `apps/directline-token/tests/origin-guard.test.mjs`

**Interfaces:**
- Consumes: nothing.
- Produces: a token endpoint that refuses unconfigured and origin-less callers.

**Why:** `if (allowed.length > 0 && origin && !allowed.includes(origin))` fails open twice — a caller sending no `Origin` header skips the check entirely (browsers always send it; `curl` never has to), and an unset `DIRECTLINE_ALLOWED_ORIGINS` skips it *and* drops the minted token's origin binding. This path also holds the MCP credential, so it bypasses Task 4's gate entirely.

- [ ] **Step 1: Write the failing tests**

```javascript
it("refuses a request with no Origin header", async () => {
  const res = await handler(makeRequest({ headers: {} }), ctx);
  expect(res.status).toBe(403);
});

it("refuses to mint when no allow-list is configured", async () => {
  delete process.env.DIRECTLINE_ALLOWED_ORIGINS;
  const res = await handler(makeRequest({ headers: { origin: "https://anything" } }), ctx);
  expect(res.status).toBe(500);
  expect(res.jsonBody.error).toMatch(/not configured/i);
});

it("still mints for a configured origin", async () => {
  process.env.DIRECTLINE_ALLOWED_ORIGINS = "https://ct.example";
  const res = await handler(makeRequest({ headers: { origin: "https://ct.example" } }), ctx);
  expect(res.status).toBe(200);
});
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd apps/directline-token && npm test`
Expected: first two FAIL with 200.

- [ ] **Step 3: Implement**

```javascript
if (allowed.length === 0) {
  context.error("DIRECTLINE_ALLOWED_ORIGINS is unset; refusing to mint an unbound token.");
  return { status: 500, headers, jsonBody: { error: "Token endpoint is not configured." } };
}
if (!origin || !allowed.includes(origin)) {
  return { status: 403, headers, jsonBody: { error: "Origin not allowed." } };
}
```

- [ ] **Step 4: Verify**

Run: `cd apps/directline-token && npm test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/directline-token/ compliance/assessment/
git commit -m "fix(directline-token): fail closed on missing Origin and unset allow-list

Closes F3. Both conditions previously skipped the guard and minted a
valid conversation token to any caller, and an unset allow-list also
dropped the token's own origin binding. This path holds the MCP
credential, so it bypassed the MCP gate entirely."
```

---

## Task 8: Stop publishing the App Insights key and subscription inventory (F4)

**Amendment (2026-08-26, post-implementation).** The original Step 3 below — "set
`disableLocalAuth: true` and grant the two UAMIs `Monitoring Metrics Publisher`" — is
necessary but was not sufficient as written, and shipping it alone would have silently
broken telemetry rather than fixing F4. `@azure/monitor-opentelemetry-exporter`'s HTTP
sender only attaches a Microsoft Entra ID bearer token `if (this.appInsightsClientOptions.
credential)` — the RBAC grant has no effect unless the exporter is also given a
`credential`, and neither apps/mcp-tools/src/telemetry.ts nor apps/data-api/src/telemetry/
otel.ts passed one. Verified against Microsoft's own docs (learn.microsoft.com/azure/
azure-monitor/app/azure-ad-authentication): `Monitoring Metrics Publisher` is confirmed
correct — "Although the ... role says 'metrics,' it publishes all telemetry" — and the
Node.js sample there is exactly `useAzureMonitor({ azureMonitorExporterOptions: {
connectionString, credential } })`. The actual Step 3 (below) adds that credential wiring
to both apps, gated on `AZURE_CLIENT_ID` being set (the deployed container sets it; a
laptop with no managed identity does not, and must not fall through to an ambient `az
login` session for telemetry). It also places the RBAC grant where it has to live —
infra/bicep/apps/main.bicep, alongside the UAMIs it targets, not platform/main.bicep,
which deploys before those identities exist — so the Files list below is corrected too.
The regression test's two `Select-String` patterns are also corrected (below) for two
real false positives/negatives the brief's literal versions had. None of this changes the
finding, the fix's intent, or the commit's scope — only what Step 3 has to include for the
grant to actually do anything.

**Files:**
- Modify: `infra/bicep/platform/main.bicep:175-185` (`disableLocalAuth`), `:343-344` (delete the output)
- New: `infra/bicep/apps/modules/monitoring-metrics-publisher-role.bicep`
- Modify: `infra/bicep/apps/main.bicep` (two grant modules, one per UAMI)
- Modify: `apps/mcp-tools/src/telemetry.ts`, `apps/mcp-tools/tests/telemetry.test.ts`
- Modify: `apps/data-api/src/config.ts`, `apps/data-api/src/telemetry/otel.ts`, `apps/data-api/tests/telemetry.test.ts`
- Modify: `.github/workflows/layer-06-platform.yml:192-197`, `:299-304`
- Modify: `.github/workflows/layer-07-apps.yml` (same pattern, plus one redundant debug `cat` of an already-non-sensitive manifest)
- Test: `verification/tests/no-secret-outputs.Tests.ps1` (new)

**Interfaces:**
- Consumes: nothing.
- Produces: manifests that carry no ingestion credential and no subscription ID; telemetry
  ingestion authenticated by Microsoft Entra ID instead of the deleted key.

- [ ] **Step 1: Write the failing test**

```powershell
Describe 'deployment manifests leak nothing' {
    It 'no Bicep output name suggests a connection string, key, or secret' {
        # NOT the brief's original `Select-String -Path 'infra/bicep/**/*.bicep'`: in
        # PowerShell's wildcard provider `**` is a literal two-segment wildcard, not a
        # bash-style recursive globstar, so that glob matches only files exactly two path
        # segments below infra/bicep/ — missing infra/bicep/naming.bicep (one segment) and
        # infra/bicep/apps/modules/*.bicep (three), backwards for a check whose whole job
        # is "no .bicep file anywhere leaks a secret". Get-ChildItem -Recurse instead.
        $bicepFiles = Get-ChildItem -Path 'infra' -Recurse -Filter '*.bicep'
        # NOT the brief's original `(ConnectionString|Key|Secret)`: Select-String is
        # case-insensitive by default, so bare `Key` matches the "Key" inside the two
        # legitimate, non-secret `keyVaultUri` / `keyVaultResourceId` outputs (both are a
        # resource locator for the Key Vault *product*, never a secret value).
        # `Key(?!Vault)` keeps ConnectionString/ApiKey/...Secret... caught everywhere else.
        $hits = $bicepFiles | Select-String -Pattern '^output\s+\w*(ConnectionString|Key(?!Vault)|Secret)\w*\s'
        $hits | Should -BeNullOrEmpty
    }
    It 'no workflow cats a manifest into the job summary' {
        $hits = Select-String -Path '.github/workflows/*.yml' -Pattern 'cat .*manifest\.json'
        $hits | Should -BeNullOrEmpty
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `pwsh -c "Invoke-Pester verification/tests/no-secret-outputs.Tests.ps1"`
Expected: FAIL on both, against the unfixed repo.

- [ ] **Step 3: Implement**

Delete `output appInsightsConnectionString` — nothing consumes it (`apps/main.bicep`
reads the component as `existing`). Set `disableLocalAuth: true` on the AVM component.
Add `infra/bicep/apps/modules/monitoring-metrics-publisher-role.bicep` (same raw-resource
shape as its sibling `key-vault-secrets-user-role.bicep`, scoped to the App Insights
component) and call it twice from `apps/main.bicep` — once per UAMI (mcp-tools,
data-api) — granting each `Monitoring Metrics Publisher` on the platform App Insights
component. In both apps' telemetry modules, build a credential ONLY when `AZURE_CLIENT_ID`
is set (reusing each app's existing `DefaultAzureCredential`-with-`managedIdentityClientId`
helper — `tools/auth.ts`'s `createDefaultCredential` for mcp-tools, `backends/azureAuth.ts`'s
`createCredential` for data-api — never inventing a new one) and pass it as the exporter's
`credential` option. Replace each `cat <manifest>.json` with an explicit `jq`-built summary
of non-sensitive keys (resource group/account/container-app names, image digests, the
externally-ingress FQDNs — never a resource ID, the Key Vault URI, the SQL FQDN, or
data-api's internal-only FQDN), and drop the artifact upload of the raw manifest.

- [ ] **Step 4: Verify**

Run: `pwsh -c "Invoke-Pester verification/tests/no-secret-outputs.Tests.ps1"`, then
`az bicep build --file infra/bicep/platform/main.bicep --stdout > /dev/null` and the same
for `infra/bicep/apps/main.bicep`, then `actionlint .github/workflows/*.yml`, then
`npm run typecheck --workspace apps/mcp-tools --workspace apps/data-api` and
`npm run test --workspace apps/mcp-tools --workspace apps/data-api`.
Expected: all pass; the two workspaces' test counts move by the number of new
credential-wiring assertions added (data-api +2, mcp-tools +1 — extended existing test
files in place rather than adding new ones where the assertion fit naturally).

- [ ] **Step 5: Commit**

```bash
git add infra/bicep/platform/main.bicep infra/bicep/apps/main.bicep \
  infra/bicep/apps/modules/monitoring-metrics-publisher-role.bicep \
  apps/mcp-tools/src/telemetry.ts apps/mcp-tools/tests/telemetry.test.ts \
  apps/data-api/src/config.ts apps/data-api/src/telemetry/otel.ts apps/data-api/tests/telemetry.test.ts \
  .github/workflows/ verification/tests/ compliance/assessment/
git commit -m "infra(L6): stop publishing the App Insights key and subscription inventory

Closes F4. layer-06 cat'd l6-manifest.json into GITHUB_STEP_SUMMARY,
which is unauthenticated-readable on a public repo. It carried
InstrumentationKey= (and disableLocalAuth defaulted false, so that key
alone authorises ingestion from anywhere) plus the subscription ID,
Key Vault URI and SQL FQDN. The output had no consumer.

disableLocalAuth:true now refuses that key outright; mcp-tools and
data-api authenticate ingestion with a Microsoft Entra ID token via
their UAMIs' Monitoring Metrics Publisher grant instead."
```

---

## Task 9: Verifier federated credential and environment split (F6, F7)

**Amendment (2026-08-26, post-implementation).** The file list below names
`layer-02`…`layer-09` by layer number but omits where L11's verify job actually lives:
there is no `layer-11-*.yml` file — L11's down-state verify job ("verify down-state
(mls-verifier)") is the `verify` job inside `infra-down.yml` (line 317 pre-fix). Found by
grepping every workflow for `AZURE_VERIFIER_CLIENT_ID`, which turned up exactly the set
named here plus `infra-down.yml` — not, e.g., any of the `app-*-ci.yml` workflows, whose
`environment: demo` jobs never reference the verifier at all and were correctly left
alone. `infra-down.yml:317` is included in the actual edit.

Two further consequential changes, not named in the steps below but required for the fix
to be self-consistent: (1) `verify-g0.ps1`'s `Test-Federation` expected BOTH the
`ref:refs/heads/main` and `environment:demo` subjects on the deployer; deleting the
branch-ref credential per Step 3 without updating this check would make G0 fail forever
on a correctly-fixed deployer, so `Test-Federation` now expects only the environment
subject. (2) Every GitHub environment variable the Verifier's `azure/login` reads
(`AZURE_VERIFIER_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`, plus L4's
`MLS_TENANT_DOMAIN`/`MLS_VERIFIER_APP_ID`) must now exist on **both** `demo` (read by the
unchanged `preflight` gate) and `verify` (read by the now-moved `verify` job) — GitHub
environment variables and secrets do not cascade between sibling environments. Documented
in `docs/runbooks/g0-bootstrap.md` C9/C9b rather than scripted, since environment creation
is a human G0 action.

**Files:**
- Modify: `scripts/bootstrap/01-root-oidc.ps1:352-386`
- Modify: `scripts/bootstrap/verify-g0.ps1` (`Test-VerifierApp`)
- Modify: every `verify` job — `verify-l1.yml:69`, `self-heal.yml:683`, `layer-02`…`layer-09`, `layer-11`
- Modify: `docs/runbooks/g0-bootstrap.md` (add the `verify` environment to C9)
- Test: `scripts/bootstrap/tests/01-root-oidc.Tests.ps1`, `verify-g0.Tests.ps1`

**Interfaces:**
- Consumes: nothing.
- Produces: `mls-verifier` federated on `repo:<owner>/<repo>:environment:verify`; verify jobs that cannot mint the deployer's subject.

**Why both in one task:** they are the same bug seen twice. The verifier has no credential at all (so the audit control is unimplementable), and the obvious fix — giving it the `environment:demo` subject — is exactly what makes the escalation structural. Fixing one without the other produces a worse system than either.

- [ ] **Step 1: Write the failing tests**

```powershell
It 'creates a federated credential for the VERIFIER, not just the deployer' {
    $script:CapturedFedApps | Where-Object { $_ -eq 'ver-obj' } | Should -Not -BeNullOrEmpty
}

It 'gives the verifier a subject distinct from the deployer' {
    $verifierSubjects = $script:CapturedFedSubjects | Where-Object { $_ -match 'environment:verify' }
    $verifierSubjects | Should -Not -BeNullOrEmpty
    $verifierSubjects | Should -Not -Contain 'repo:paulcfuqua/azure-devsecops-demo:environment:demo'
}

It 'verify-g0 fails when the verifier has no federated credential' {
    $script:VerifierFedCreds = @()
    $results = Invoke-MainForTest
    ($results | Where-Object Name -match 'verifier federation').Status | Should -Be 'FAIL'
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `pwsh -c "Invoke-Pester scripts/bootstrap/tests/"`
Expected: FAIL — no verifier FIC is created; `verify-g0` has no such check.

- [ ] **Step 3: Implement**

In `01-root-oidc.ps1`, after the verifier SP is created:

```powershell
Initialize-FederatedCredential -AppObjectId $verifier.id -Name 'github-env-verify' `
    -Subject "repo:${Repository}:environment:verify" | Out-Null
```

Delete the deployer's `github-main` branch-ref credential (`:352-353`) — nothing needs it, and it lets any future `id-token: write` job on `main` reach Owner while skipping the environment's protection rules.

Extend `Test-VerifierApp` in `verify-g0.ps1` to assert the credential exists *and* that its subject differs from the deployer's. Change `environment: demo` to `environment: verify` in every `verify` job.

- [ ] **Step 4: Verify**

Run: `pwsh -c "Invoke-Pester scripts/bootstrap/ verification/"` and `actionlint .github/workflows/*.yml`
Expected: PASS, actionlint silent.

- [ ] **Step 5: Commit**

```bash
git add scripts/bootstrap/ .github/workflows/ docs/runbooks/g0-bootstrap.md compliance/assessment/
git commit -m "fix(G0): give mls-verifier its own federated credential and environment

Closes F6 and F7. Initialize-FederatedCredential was called twice, both
for the deployer, so the verifier could never authenticate and every
verify job would fail AADSTS70021 — while verify-g0 reported green
because it only checked the app existed. Separately, the OIDC subject
derives from the job's environment, not the client-id, so a verify job
declaring environment: demo could mint the Owner-holding deployer's
subject. Verify jobs now use a distinct environment. Also drops the
deployer's unused branch-ref credential."
```

---

## Task 10: Narrow the deployer's Graph permissions (F8)

**Amendment (2026-08-26, post-implementation).** The file list below does not name
`verify-g0.ps1`, but its `$script:GraphConsentedRoles` hashtable independently declares
the SAME permission set (for `Test-GraphConsent`'s admin-consent check) with the same
`Application.ReadWrite.All` GUID. Leaving it unchanged after the deployer stops
requesting/consenting that role would mean `Test-GraphConsent` checks for consent of a
permission that no longer exists in the deployer's `requiredResourceAccess` at all — G0
would report `GraphConsent: FAIL` forever on a correctly-fixed deployer, the same failure
mode Task 9's amendment describes for `Test-Federation`. Swapped the same GUID there too,
and in its test fixture's `$script:RoleIds`.

**Files:**
- Modify: `scripts/bootstrap/01-root-oidc.ps1:66-72`
- Modify: `docs/runbooks/g0-bootstrap.md` item C3
- Test: `scripts/bootstrap/tests/01-root-oidc.Tests.ps1`

- [ ] **Step 1: Write the failing test**

```powershell
It 'does not request tenant-wide application write' {
    $script:DeployerGraphRoles.Keys | Should -Not -Contain 'Application.ReadWrite.All'
    $script:DeployerGraphRoles.Keys | Should -Contain 'Application.ReadWrite.OwnedBy'
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `pwsh -c "Invoke-Pester scripts/bootstrap/tests/01-root-oidc.Tests.ps1"`
Expected: FAIL.

- [ ] **Step 3: Implement**

Replace `'Application.ReadWrite.All' = '1bfefb4e-e0b5-418b-a88f-73c46d2cc8e9'` with
`'Application.ReadWrite.OwnedBy' = '18a4783c-866b-4cc7-a460-3d5e5662c884'`.

`Application.ReadWrite.All` permits adding a credential to *any* application in the tenant, including one holding Global Administrator — a strictly larger blast radius than subscription Owner. `apply-entra.ps1:415` only ever touches the three apps in `manifest.json`, which the deployer owns, so `OwnedBy` is a drop-in.

Add a comment recording that `Policy.ReadWrite.ConditionalAccess` can disable CA tenant-wide and is retained deliberately because L3 needs it.

- [ ] **Step 4: Verify**

Run: `pwsh -c "Invoke-Pester scripts/bootstrap/"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/bootstrap/ docs/runbooks/g0-bootstrap.md compliance/assessment/
git commit -m "fix(G0): Application.ReadWrite.All -> Application.ReadWrite.OwnedBy

Closes F8. The broad role lets the holder add credentials to any app in
the tenant, including one holding Global Administrator — a larger blast
radius than subscription Owner. The demo only ever writes its own three
apps."
```

---

## Task 11: Drop the NIST policy identity's standing Contributor (F10)

**Files:**
- Modify: `infra/bicep/landing-zone/main.bicep:228`
- Test: `az bicep build` + grep assertion

- [ ] **Step 1: Write the failing check**

```bash
grep -n "roleDefinitionIds: \[contributorRoleId\]" infra/bicep/landing-zone/main.bicep
```
Expected: one hit (the defect).

- [ ] **Step 2: Implement**

Set `roleDefinitionIds: []`. ARM requires an *identity* when an initiative contains `deployIfNotExists`/`modify` members; it does not require a role assignment. With `enforcementMode: 'DoNotEnforce'` no remediation ever runs, so the Contributor grant is a permanent unowned principal over the whole subscription that nothing uses — and it survives RG-scoped teardown, since the assignment lives at subscription scope.

Record in the comment that enabling enforcement later means granting the specific roles the DINE members declare, never Contributor.

- [ ] **Step 3: Verify**

Run: `az bicep build --file infra/bicep/landing-zone/main.bicep --stdout > /dev/null && echo OK`
Expected: exit 0. Re-run Step 1's grep: no hits.

- [ ] **Step 4: Run the full suite**

Run: `pwsh -c "Invoke-Pester scripts/ infra/ data/ verification/"`
Expected: 605+ pass.

- [ ] **Step 5: Commit**

```bash
git add infra/bicep/landing-zone/main.bicep compliance/assessment/
git commit -m "infra(L2): remove standing Contributor from the NIST policy identity

Closes F10. The assignment is a permanent subscription-scoped
Contributor principal that nothing uses — the initiative is in
DoNotEnforce, so no remediation ever runs — and it outlives RG teardown."
```

---

## Task 12: Express workload RBAC in IaC (F13)

**Files:**
- Create: `infra/bicep/apps/modules/workload-role-assignments.bicep` (subscription-scoped grants)
- Create: `infra/bicep/apps/modules/log-analytics-reader-role.bicep` (resource-scoped grant — added beyond the original file list: Bicep's BCP139 forbids one file mixing a subscription-scope and a resourceGroup-scope resource, so the LAW-scoped grant needed its own module rather than a parameter on the first)
- Create: `data/seed/sql/900-contained-users.sql`
- Modify: `infra/bicep/apps/main.bicep`
- Modify: `infra/fabric/fabric-api.psm1` (new `Add-FabricWorkspaceRoleAssignment`/`Get-FabricWorkspaceRoleAssignment` — no role-assignment wrapper existed before this task, contrary to the original brief's premise; see F21)
- Modify: `infra/fabric/provision-workspace.ps1` (workspace Viewer role; also corrects a false docstring — see F21)
- Test: `verification/tests/workload-rbac.Tests.ps1`

**Why:** the repo contains **zero** role assignments for its workload identities. The only `Microsoft.Authorization/roleAssignments` resource is `key-vault-secrets-user-role.bicep`, documented as unreferenced and written for a component deleted in August. Seven grants are described in prose and implemented nowhere. This is not only a compliance gap: `main.bicep:263` resolves `dataApiMode` to `cloud` as soon as `fabricSqlEndpoint` is non-empty — which C9 has you set after L5 — at which point `data-api` 403s on every backend call.

**Outcome: five of the seven grants, not seven.** Two are excluded, each with a different owner, and F13 stays OPEN because of them:

| Principal | Role | Scope | Status |
|---|---|---|---|
| data-api UAMI | Log Analytics Reader | LAW | DONE — Task 12 |
| data-api UAMI | Security Reader | subscription | DONE — Task 12 |
| data-api UAMI | SQL contained-database user | database | DONE — Task 12 (expressed; does not yet apply in a single `infra-up.yml` pass — see F20) |
| data-api UAMI | Fabric workspace Viewer | workspace | DONE — Task 12 |
| mcp-tools UAMI | Log Analytics Reader | LAW | DONE — Task 12 |
| mcp-tools UAMI | Security Reader | subscription | DONE — Task 12 |
| mcp-tools UAMI | Cost Management Reader | subscription | DONE — Task 12 |
| Cost Management service | Storage Blob Data Contributor | export container | **EXCLUDED — owned by Task 17 (F15).** Its own plan section names this exact grant and lists `layer-06-platform.yml` among its files; the export's identity is created there, not by Bicep, so Task 12 has no `principalId` to grant. |
| cost-ingest | Storage Blob Data Reader | storage account | **EXCLUDED — blocked by F19.** cost-ingest has no Function App, and therefore no identity, anywhere in this repo's IaC, despite `infra-up.yml:31` claiming it deploys inside `layer-06-platform.yml`. There is nothing to grant a role to. |

Building this task also surfaced two more findings, recorded but not fixed here: **F20** (the SQL grant above is expressed but nothing re-invokes `seed.ps1 -Target sql` after L7 creates the identity, so it never applies in a single `infra-up.yml` pass) and **F21** (mls-verifier's own documented Fabric workspace Viewer grant does not exist either — a different principal, breaking the L5 Verifier audit independent of F13).

**The test asserts only the five**, by design — asserting a role NAME for the two excluded grants would pass on a comment alone, which is precisely the failure mode the GUID-with-comment ruling below exists to prevent.

**Original seven-grant framing (superseded):**

| Principal | Role | Scope |
|---|---|---|
| data-api UAMI | Log Analytics Reader | LAW |
| data-api UAMI | Security Reader | subscription |
| data-api UAMI | SQL contained-database user | database |
| data-api UAMI | Fabric workspace Viewer | workspace |
| mcp-tools UAMI | Log Analytics Reader | LAW |
| mcp-tools UAMI | Security Reader | subscription |
| mcp-tools UAMI | Cost Management Reader | subscription |
| Cost Management service | Storage Blob Data Contributor | export container |

- [ ] **Step 1: Write the failing test**

```powershell
Describe 'workload identities have their grants expressed in code' {
    It 'declares a role assignment for every documented grant' {
        $bicep = Get-Content 'infra/bicep/apps/main.bicep' -Raw
        foreach ($role in 'Log Analytics Reader','Security Reader','Cost Management Reader') {
            $bicep | Should -Match ([regex]::Escape($role))
        }
    }
    It 'creates the SQL contained-database users in the seed' {
        Test-Path 'data/seed/sql/900-contained-users.sql' | Should -BeTrue
        Get-Content 'data/seed/sql/900-contained-users.sql' -Raw | Should -Match 'FROM EXTERNAL PROVIDER'
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `pwsh -c "Invoke-Pester verification/tests/workload-rbac.Tests.ps1"`
Expected: FAIL on both.

- [ ] **Step 3: Implement**

Add a `workload-role-assignments.bicep` module taking a principal ID and role definition ID, invoked once per grant at the correct scope. Add the SQL script:

```sql
CREATE USER [mls-data-api-demo-id] FROM EXTERNAL PROVIDER;
ALTER ROLE db_datareader ADD MEMBER [mls-data-api-demo-id];
```

Add the Fabric workspace Viewer assignment via the existing `infra/fabric/fabric-api.psm1` REST path.

- [ ] **Step 4: Verify**

Run: `pwsh -c "Invoke-Pester verification/ data/"` and `az bicep build --file infra/bicep/apps/main.bicep --stdout > /dev/null`
Expected: PASS, exit 0.

- [ ] **Step 5: Commit**

```bash
git add infra/ data/seed/sql/ verification/tests/ compliance/assessment/
git commit -m "infra(L7): express the seven workload role assignments in IaC

Closes F13. The repo contained zero role assignments for workload
identities — the only one present is documented as unreferenced and
serves a component deleted in August. Beyond the compliance gap this is
a live failure: main.bicep:263 flips data-api to cloud mode as soon as
fabricSqlEndpoint is set, and it would then 403 on every backend call."
```

---

## Task 13: Diagnostic settings and SQL auditing (F9)

One missing pattern collapses three NIST families (3.3 Audit, 3.6 IR detection, 3.14 monitoring).

**Files:**
- Modify: `infra/bicep/platform/main.bicep` (Key Vault, storage, SQL server, Container Apps environment)
- Modify: `.github/workflows/layer-02-landing-zone.yml` (subscription Activity Log)
- Modify: `.github/workflows/layer-03-entra.yml` (Entra `SignInLogs` + `AuditLogs`)
- Test: `verification/tests/diagnostics.Tests.ps1`

**Outcome: the Bicep half landed as planned; both workflow items moved, and F9 is now fully closed — after a review round that corrected two mistakes.**

`infra/bicep/platform/main.bicep` now routes `diagnosticSettings` for Key Vault, the
cost-export storage account (account-level metrics *and* blob-service-level data-plane
logs — those are two different resource types in the AVM schema), the SQL **database**
(not the server — `avm/res/sql/server@0.22.0` has no top-level `diagnosticSettings`
param; verified against the cached module schema, not assumed) and the Container Apps
environment, all to the L6 Log Analytics workspace. SQL `auditSettings` now sets
`isAzureMonitorTargetEnabled: true`. `lawDataRetentionDays` is 90.

The subscription Activity Log did **not** land in `layer-02-landing-zone.yml`. On a full
`infra-up.yml` pass, `layer-06 needs: [..., layer-04]`, which needs `[..., layer-02]`, so
L2 always precedes L6, and teardown deletes `mls-rg-platform` (and the LAW inside it)
every cycle, so a full pass never reaches L2 with the LAW already present — a diagnostic
setting there would be pointed at a workspace that doesn't exist yet, and
`az monitor diagnostic-settings subscription create --workspace` validates its target at
request time. (This is a same-pass invariant, not a universal one: `infra-up.yml` also
supports a skip-tolerant selective replay, e.g. `layers: l6` alone, which skips L2
entirely — an earlier draft of this note overstated the claim as "every invocation,"
caught on review.) Moved to `layer-06-platform.yml`'s deploy job instead, right after the
LAW becomes a real deployed resource. `layer-02-landing-zone.yml` itself gained only an
explanatory comment, not a step.

Entra `SignInLogs` + `AuditLogs` went through three rounds, not two. First **deferred**
(unverifiable without a live tenant, in that session — the `Microsoft.aadiam`
tenant-scoped resource shape and the Entra role required were both unconfirmed). Then
**implemented** as an automated call in `layer-06-platform.yml`, alongside the Activity
Log step, after a review round found both facts are in fact publicly documented
(Microsoft Learn, "How to configure Microsoft Entra diagnostic settings" — Security
Administrator is the named role) and pointed out that "cannot verify without a live
tenant" is true of every line in a repo where nothing is deployed, so accepting it as a
reason to defer would excuse deferring everything. Then **removed again**, on a second
review round, once it was flagged (by this session, in the first implementation's own
concerns section) that nothing in this repo's IaC grants `mls-github-deployer` the
Security Administrator role the automated call needed — and the ruling was not "grant it"
but "this SP must not hold it": Task 10 narrowed this exact SP from
`Application.ReadWrite.All` to `.ReadWrite.OwnedBy` specifically to shrink its tenant
blast radius (finding F8), and adding Security Administrator now would re-inflate
precisely what that narrowing closed, to automate a setting that is configured once and
never replayed by the kill/rebuild loop. The remedy that landed is a new G0 human
checklist item — `docs/runbooks/g0-bootstrap.md` § C, item 12 — carrying the exact
command, the role requirement, and the after-L6 ordering, in the same style as item 4
(the Fabric SP API toggle) and item 11 (the MCP auth secret). A documented human step
with an exact command is treated as a real remedy here, the same standard item 4 already
meets — not a weaker stand-in for automation.

Register consequence, corrected three times across the two review rounds. First, the
initial pass downgraded `gapSeverity` on `3.3.1`/`3.3.2`/`3.3.5` from `high` to `medium`
because most of F9's action items had landed — called Critical on review and reverted,
citing Task 12's own precedent (`3.1.5.json` keeps `gapSeverity: "high"` while F13, its
sole contributor, had five of seven grants landed — severity is a property of the
finding, not a progress meter). Second, once Entra was implemented as an automated step,
the controls moved to **CLOSED, `gapSeverity: "none"`**. Third, once that automated step
was removed in favor of the G0 item, the rationale text in all three files was rewritten
again — not the status (closing via a documented human step is still closing, per the
explicit ruling above) — to describe the real remedy: IaC for everything but the Entra
piece, a G0 runbook item for that piece. See `task-13-report.md` for the full sequence
and every fix round's evidence.

- [ ] **Step 1: Write the failing test**

```powershell
It 'routes diagnostics for every resource that can emit them' {
    $bicep = Get-Content 'infra/bicep/platform/main.bicep' -Raw
    ($bicep | Select-String 'diagnosticSettings' -AllMatches).Matches.Count |
        Should -BeGreaterOrEqual 4 -Because 'Key Vault, storage, SQL and the CAE all emit'
}
It 'sends SQL audit events somewhere' {
    Get-Content 'infra/bicep/platform/main.bicep' -Raw | Should -Match 'isAzureMonitorTargetEnabled'
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `pwsh -c "Invoke-Pester verification/tests/diagnostics.Tests.ps1"`
Expected: FAIL — zero `diagnosticSettings` in the repo.

- [ ] **Step 3: Implement**

Add `diagnosticSettings: [{ workspaceResourceId: logAnalytics.outputs.resourceId }]` to the Key Vault, storage account, SQL server and Container Apps environment AVM modules. Set `auditSettings: { state: 'Enabled', isAzureMonitorTargetEnabled: true }` on the SQL server — AVM defaults `state: 'Enabled'` with no destination, which is auditing that writes nowhere and may hard-fail the deployment.

Raise `lawDataRetentionDays` from 30 to 90. The existing `dailyQuotaGb: '1'` cap bounds the cost.

- [ ] **Step 4: Verify**

Run: `pwsh -c "Invoke-Pester verification/"`, `az bicep build --file infra/bicep/platform/main.bicep --stdout > /dev/null`
Expected: PASS, exit 0.

- [ ] **Step 5: Commit**

```bash
git add infra/bicep/ .github/workflows/ verification/tests/ compliance/assessment/
git commit -m "infra(L6): route diagnostics and SQL audit to Log Analytics

Closes F9. The repo contained zero diagnosticSettings — no Activity
Log, no Entra sign-in or audit logs, no SQL auditing, no Key Vault
audit events. Key Vault holds the only real credentials in the system
and access to them was entirely unlogged. Retention raised 30 -> 90
days; the existing 1GB/day cap bounds the cost."
```

---

## Task 14: Block `javascript:` URLs and add CSP (F11)

**Files:**
- Modify: `apps/control-tower/src/AdaptiveCardView.tsx:123-127`, `:194-202`
- Modify: `apps/control-tower/nginx.conf.template`, `apps/launch-ops/nginx.conf.template`
- Modify: `apps/control-tower/Dockerfile`, `apps/launch-ops/Dockerfile` (add `USER nginx`)
- Test: `apps/control-tower/tests/adaptive-card-url.test.tsx`

**Why:** `str()` checks only for a non-empty string; Fluent's `Link` passes `href` through unsanitised; React 18 renders `javascript:` with only a dev warning; and neither nginx template emits a CSP that would neutralise it. Card content arrives from the agent over Direct Line and is cast to `AdaptiveCard` with no validation, so a prompt injection reaches an operator's click. The sibling renderer already gets this right — `apps/shared/spec-renderer/src/markdown.tsx:14` constrains hrefs to `https?://`.

**Outcome: landed as planned, with the brief's CSP snippet corrected after verifying it in a real browser rather than shipped as suggested.** `AdaptiveCardView.tsx` gained a `safeUrl()` allowlist (`/^https?:\/\//i`, trimmed) on both `Action.OpenUrl.url` and `Image.url`, rendering `UnsupportedElement` on rejection; `tests/adaptive-card-url.test.tsx` covers the brief's five cases plus case-varied, whitespace/control-character, and embedded-control-character bypass attempts (21 tests). The brief's suggested `connect-src` would have broken the Ask tab's very first network call — it never lists the `directline-token` Function's own host, only Direct Line's — and the brief's CSP overall has no `style-src`, which (verified by building the app and loading the bundle under that exact policy in a real browser) leaves Fluent UI's Griffel CSS-in-JS entirely blocked and the app unstyled. The shipped CSP adds `style-src 'self' 'unsafe-inline'`, widens `connect-src` to the directline-token Function's host, the Application Insights Web SDK's config/ingestion hosts (both frontends load it when a connection string is configured — not mentioned in the brief at all), and wildcards the Direct Line host for `wss://` and the regional `*.directline.botframework.com` variants `VITE_DIRECTLINE_DOMAIN` can select. `USER nginx` alone does not work on this base image either (verified against the actual nginx.org Alpine package contents): the pid path is `/run/nginx.pid`, not `/var/run`; `/etc/nginx/conf.d` has to stay writable or the entrypoint's envsubst pass silently skips rendering (serving nginx's stock page instead of this app — not a crash); and `/var/cache/nginx` does not exist in the image at all. Both Dockerfiles carry the fix for all three. Register: F11 closed (3.14.1's only other contributor, F12, is Task 15's); `gapSeverity` on 3.14.1 moves `high -> medium`.

- [ ] **Step 1: Write the failing tests**

```tsx
it.each([
  "javascript:alert(1)",
  "JaVaScRiPt:alert(1)",
  "javascript:alert(1)",
  "data:text/html,<script>alert(1)</script>",
  "vbscript:msgbox(1)",
])("refuses to render an unsafe Action.OpenUrl url: %s", (url) => {
  render(<AdaptiveCardView card={{ type: "AdaptiveCard", actions: [
    { type: "Action.OpenUrl", title: "View report", url }] }} />);
  expect(screen.queryByRole("link")).toBeNull();
  expect(screen.getByText(/unsupported/i)).toBeInTheDocument();
});

it("still renders an https link", () => {
  render(<AdaptiveCardView card={{ type: "AdaptiveCard", actions: [
    { type: "Action.OpenUrl", title: "ok", url: "https://example.test/r" }] }} />);
  expect(screen.getByRole("link")).toHaveAttribute("href", "https://example.test/r");
});
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd apps/control-tower && npx vitest run tests/adaptive-card-url.test.tsx`
Expected: FAIL — a link renders for every unsafe URL.

- [ ] **Step 3: Implement**

```tsx
const SAFE_URL = /^https?:\/\//i;
const safeUrl = (v: unknown): string | undefined => {
  const s = str(v);
  return s && SAFE_URL.test(s.trim()) ? s.trim() : undefined;
};
```

Use it for both `Action.OpenUrl.url` and `Image.url`; render `<UnsupportedElement>` otherwise. Add to both nginx templates:

```
add_header Content-Security-Policy "default-src 'self'; script-src 'self'; img-src 'self' data: https:; connect-src 'self' https://directline.botframework.com; frame-ancestors 'none'; base-uri 'none'" always;
add_header X-Content-Type-Options nosniff always;
add_header Referrer-Policy no-referrer always;
```

Add `USER nginx` to both frontend Dockerfiles — `data-api` and `mcp-tools` already drop to `USER node`; the frontends run as root.

- [ ] **Step 4: Verify**

Run: `cd apps/control-tower && npm test`, then `npm test` from the root.
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/control-tower/ apps/launch-ops/ compliance/assessment/
git commit -m "fix(control-tower): reject javascript: URLs in Adaptive Cards, add CSP

Closes F11. Action.OpenUrl and Image accepted any non-empty string as
an href; Fluent's Link does not sanitise schemes and React 18 renders
javascript: with only a dev warning. Card content comes from the agent
over Direct Line unvalidated, so a prompt injection reached an
operator's click in an origin holding the live Direct Line token. The
spec-renderer sibling already constrained hrefs; this brings the
Adaptive Card path in line. Also drops both frontends off root."
```

---

## Task 15: Reject unterminated comments and quotes in the SQL gate (F12)

**Files:**
- Modify: `apps/mcp-tools/src/tools/sql-dialect.ts:154-166`, `:224-267`
- Test: `apps/mcp-tools/tests/sql-dialect.test.ts`

**Why:** `scrubSql` nests block comments, but SQLite does not — so `/* a /* b */` is a *closed* comment to SQLite and an *unclosed* one to the scrubber, which then eats the rest of the statement. Both the `;`-scan and the forbidden-verb scan run on the scrubbed text and are blind to everything after the fake opener; the raw text is what reaches the engine. Verified: `SELECT 1 /* a /* b */ ; DELETE FROM launches` passes the gate. Only `db.prepare()`'s single-statement compilation prevents execution today — an incidental property, and `lakehouse.ts` already uses `db.exec` three lines away, where both statements *do* run.

**Outcome: landed as planned, with one test-case correction after re-deriving the brief's own reproduction against real engine semantics.** `scrubSql` now returns `{ text, terminated }`; `assertReadOnlySingleStatement` rejects with an "unterminated comment or quoted section" message before the single-statement, forbidden-verb or SELECT/WITH checks run, so a partial scrub is never trusted downstream. Block-comment nesting is dialect-aware: depth is tracked only for `dialect === "tsql"`; for `sqlite` the first `*/` closes, matching the real engine. The brief's Step-1 test asserts `/unterminated/i` for all five rows, including `SELECT 1 /* a /* b */ ; DELETE FROM launches` against **sqlite** — but to real SQLite (no nesting, first `*/` wins) that comment is genuinely *closed*, not unterminated; it is F12's own narrative that says so. What it exposes is `; DELETE FROM launches` as a live second statement, which the *pre-existing* single-statement check now catches correctly because it is no longer hidden by over-scrubbing. Asserting `/unterminated/i` there would assert the wrong defect for the one dialect the fix is supposed to stop over-scrubbing; the shipped test instead asserts `/single SQL statement/i` for that row and keeps `/unterminated/i` for the other four (the `tsql` variant of the same string, plus the unterminated backtick, quote and bracket cases) and for the genuinely-unterminated cases the message is exactly as specified. The "legitimate nested-looking comment" case (`/* note: a/b ratio */`) passes in both dialects, unchanged. `apps/mcp-tools` moved 277 -> 287 tests (10 added); root `npm test` moved 858 -> 868, exit 0; all 27 pre-existing bypass probes and the schema-column/string-literal false-positive guards still pass. Register: F12 closed; 3.14.1 had no other open contributor (F5 and F11 were already closed), so it moves `gapSeverity: medium -> none`, `status: GAP -> CLOSED`.

- [ ] **Step 1: Write the failing tests**

```typescript
it.each([
  ["SELECT 1 /* a /* b */ ; DELETE FROM launches", "sqlite"],
  ["SELECT 1 /* a /* b */ ; DELETE FROM launches", "tsql"],
  ["SELECT 1 ` ; DROP TABLE launches", "sqlite"],
  ["SELECT 1 ' ; DROP TABLE launches", "sqlite"],
  ["SELECT 1 [ ; DROP TABLE launches", "sqlite"],
] as const)("rejects an unterminated comment or quote: %s", (sql, dialect) => {
  expect(() => assertReadOnlySingleStatement(sql, dialect)).toThrow(/unterminated/i);
});

it("still accepts a legitimate nested-looking comment", () => {
  expect(() => assertReadOnlySingleStatement(
    "SELECT 1 /* note: a/b ratio */", "sqlite")).not.toThrow();
});
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd apps/mcp-tools && npx vitest run tests/sql-dialect.test.ts`
Expected: the five reject cases FAIL (they currently pass the gate).

- [ ] **Step 3: Implement**

Have `scrubSql` return `{ text, terminated }`, setting `terminated: false` if it reaches the end inside a comment, quote, backtick or bracket. In `assertReadOnlySingleStatement`, reject before any other check:

```typescript
const { text, terminated } = scrubSql(raw, dialect);
if (!terminated) {
  throw new SqlRejected(
    "The statement has an unterminated comment or quoted section. Send one complete " +
    "SELECT (or WITH … SELECT) with all comments and quotes closed.");
}
```

Make nesting dialect-aware: track depth only for `tsql`; for `sqlite` the first `*/` closes.

- [ ] **Step 4: Verify**

Run: `cd apps/mcp-tools && npm test`
Expected: PASS, including the 27 existing bypass probes.

- [ ] **Step 5: Commit**

```bash
git add apps/mcp-tools/ compliance/assessment/
git commit -m "fix(mcp-tools): reject unterminated comments and quotes in the SQL gate

Closes F12. scrubSql nested block comments, which T-SQL does and SQLite
does not, so a fake nested opener made the scrubber swallow the tail —
and both the semicolon scan and the forbidden-verb scan ran on the
scrubbed text while the raw text reached the engine. Not exploitable
today only because db.prepare compiles one statement; that is
incidental, and db.exec sits three lines away."
```

---

## Task 16: Harden the self-heal selection (F14)

**Files:**
- Modify: `.github/workflows/self-heal.yml:242`, `:252`
- Test: `actionlint` + review

- [ ] **Step 1: Understand the failure**

`gh pr list --state open --json headRefName` enumerates **all** open PRs including forks, and the attacker controls their own head-branch name. Once public, anyone opens throwaway fork PRs named `self-heal/dependabot-1-x` … `-50-x`; every alert then looks already-handled, the run reports "Nothing to heal" and concludes **green**. Alert numbers are small sequential integers, so no reconnaissance is needed. Separately, `:242` lists code-scanning alerts with no `ref` filter, so alerts raised on fork-PR analyses are in scope.

- [ ] **Step 2: Implement**

```bash
# :242 — only the default branch's alerts
endpoint="repos/${REPO}/code-scanning/alerts?state=open&ref=refs/heads/main&per_page=100"

# :252 — only branches in the base repository
gh pr list --state open --json headRefName,headRepositoryOwner \
  --jq ".[] | select(.headRepositoryOwner.login == \"${REPO%%/*}\") | .headRefName" > open-branches.txt || true
```

Also add, after the alert is selected, an assertion that `.most_recent_instance.ref == "refs/heads/main"`.

- [ ] **Step 3: Verify**

Run: `actionlint .github/workflows/self-heal.yml`
Expected: no output.

- [ ] **Step 4: Run the full suite**

Run: `pwsh -c "Invoke-Pester scripts/ verification/"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/self-heal.yml compliance/findings/
git commit -m "fix(L10): scope self-heal selection to the base repo and default branch

Closes F14. The open-PR branch list included fork PRs whose head-branch
names an attacker controls, so squatting self-heal/<kind>-<n>-* names
made every alert look handled and the run report 'Nothing to heal' —
green. Code-scanning alerts were also listed with no ref filter, so
fork-PR analyses were in scope."
```

---

## Task 17: Repair the cost export (F15)

The detective control behind every denial-of-wallet path in this plan.

**Files:**
- Modify: `.github/workflows/layer-06-platform.yml:232`
- Modify: `scripts/bootstrap/03-budget.ps1` (forecast thresholds)
- Test: `scripts/bootstrap/tests/03-budget.Tests.ps1`

- [ ] **Step 1: Write the failing test**

```powershell
It 'alerts on forecast as well as actual spend' {
    $body = Get-DesiredBudgetBody -Amount 75 -Email 'x@y.z'
    ($body.properties.notifications.Values | Where-Object thresholdType -eq 'Forecasted') |
        Should -Not -BeNullOrEmpty
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `pwsh -c "Invoke-Pester scripts/bootstrap/tests/03-budget.Tests.ps1"`
Expected: FAIL — every notification is `Actual`.

- [ ] **Step 3: Implement**

Fix the container name at `layer-06:232`: `--storage-container cost-exports` (Bicep creates `cost-exports`; the workflow wrote to `costexports`). Add the missing `Storage Blob Data Contributor` grant for the Cost Management service identity — `allowSharedKeyAccess: false` forces the RBAC path and no grant exists, so the export cannot write. Add `Forecasted` notifications at 50% and 80% alongside the actual ones: actual-cost data lags 8-24 hours, which is longer than it takes to burn the credit.

- [ ] **Step 4: Verify**

Run: `pwsh -c "Invoke-Pester scripts/bootstrap/"` and `actionlint .github/workflows/layer-06-platform.yml`
Expected: PASS, silent.

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/ scripts/bootstrap/ compliance/findings/
git commit -m "fix(L6): repair the cost export and add forecast alerts

Closes F15. Bicep created 'cost-exports' and the workflow wrote to
'costexports'; the Storage Blob Data Contributor grant the RBAC-only
storage account requires did not exist at all. Adds forecast-based
notifications, since actual-cost data lags 8-24 hours — longer than it
takes to exhaust a \$200 credit."
```

---

## Task 18: Pin Azure SQL backup posture (F16)

**Files:**
- Modify: `infra/bicep/platform/main.bicep:264-282` (`databases` array)
- Modify: `verification/layer-06-audit.ps1` (new V6.5 criterion)
- Test: `az bicep build`

**Why:** no `shortTermRetentionPolicy` or `requestedBackupStorageRedundancy` is set on the database, so both resolve to whatever the platform default is on a given deployment day — never decided, never audited. CP-9 (backup) is tailored out of 800-171 but is exactly what a CMMC assessor probes next.

- [ ] **Step 1: Write the failing check**

```bash
grep -n "shortTermRetentionPolicy\|requestedBackupStorageRedundancy" infra/bicep/platform/main.bicep
```
Expected: no hits (the defect).

- [ ] **Step 2: Implement**

Add to the `databases` array entry in `main.bicep`:

```bicep
shortTermRetentionPolicy: {
  retentionDays: 7 // [derived] platform default made explicit; raise if the sponsor wants more
}
requestedBackupStorageRedundancy: 'Local' // [derived] matches the single-region design; document if changed
```

Add a V6.5 criterion to `verification/layer-06-audit.ps1` asserting `az sql db show` reports the same values, so drift from a future template change is caught rather than silently inherited.

- [ ] **Step 3: Verify**

Run: `az bicep build --file infra/bicep/platform/main.bicep --stdout > /dev/null && echo OK`
Expected: exit 0. Re-run Step 1's grep: two hits.

- [ ] **Step 4: Run the full suite**

Run: `pwsh -c "Invoke-Pester infra/ verification/"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add infra/bicep/platform/main.bicep verification/layer-06-audit.ps1 compliance/assessment/
git commit -m "infra(L6): pin Azure SQL backup retention and storage redundancy

Closes F16. Neither shortTermRetentionPolicy nor
requestedBackupStorageRedundancy was set, so both resolved to whatever
the platform default was on a given deployment day rather than a
decision the template made or the L6 audit verified."
```

---

## Task 19: Alert on what F9 starts collecting (F17)

**Depends on:** Task 13 (F9) — alerts need the diagnostic data F9 routes to the Log Analytics workspace to exist before a query against it means anything.

**Files:**
- Modify: `infra/bicep/platform/main.bicep` (`actionGroups`, `scheduledQueryRules`)
- Modify: `scripts/bootstrap/03-budget.ps1` (share the action group, once Task 17 adds one)
- Test: `az bicep build`

**Why:** zero `metricAlerts`, `scheduledQueryRules` or `actionGroups` exist anywhere in the estate. Even after F9 lands, nobody would notice a Key Vault access-denied spike, a SQL failed-login spike, or a Container Apps restart loop — the estate has no way to alert on what it monitors.

- [ ] **Step 1: Write the failing check**

```bash
grep -rn "Microsoft.Insights/actionGroups\|scheduledQueryRules\|metricAlerts" infra/
```
Expected: no hits (the defect).

- [ ] **Step 2: Implement**

Add one `Microsoft.Insights/actionGroups` resource (email receiver, reusing the sponsor address `03-budget.ps1` already notifies) and `scheduledQueryRules` against: Key Vault `AuditEvent` with a denied result, SQL `sql-server-logs` failed-login spikes, and Container Apps environment restart counts — all reading from the LAW F9 wires up.

- [ ] **Step 3: Verify**

Run: `az bicep build --file infra/bicep/platform/main.bicep --stdout > /dev/null && echo OK`
Expected: exit 0.

- [ ] **Step 4: Run the full suite**

Run: `pwsh -c "Invoke-Pester infra/ scripts/bootstrap/"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add infra/bicep/platform/main.bicep scripts/bootstrap/03-budget.ps1 compliance/assessment/
git commit -m "infra(L6): add alerting on the signals F9 collects

Closes F17. Zero metricAlerts, scheduledQueryRules or actionGroups
existed anywhere in the estate, so even fully-logged data (F9) had no
automated trigger for anyone to notice — the alerting half of SI-4 and
the detection phase of IR-4 were both absent."
```

---

## Task 20: Publish the Purview label policy (F18)

**Files:**
- Modify: `infra/purview/labels.ps1` (add `New-LabelPolicy`/`Set-LabelPolicy`)
- Modify: `verification/layer-04-audit.ps1` (new V4.3 criterion)
- Create: `infra/purview/auto-label-design.md` (or remove the `L04.md` reference to it)
- Test: `infra/purview/tests/labels.Tests.ps1`

**Why:** `labels.ps1` creates the four-label taxonomy but never publishes a policy scoping it to any user or group, despite `L04.md:53` documenting that step as part of the deploy. A label nobody can apply and that triggers no protection action is a taxonomy, not a control — and the Verifier's own V4.1/V4.2 checks only label existence, so this gap is invisible to the audit that is supposed to catch it.

- [ ] **Step 1: Write the failing test**

```powershell
It 'publishes a label policy, not just the labels' {
    $script = Get-Content 'infra/purview/labels.ps1' -Raw
    $script | Should -Match 'New-LabelPolicy|Set-LabelPolicy'
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `pwsh -c "Invoke-Pester infra/purview/tests/labels.Tests.ps1"`
Expected: FAIL.

- [ ] **Step 3: Implement**

Add a publish step to `Invoke-Main` calling `New-LabelPolicy`/`Set-LabelPolicy`, scoped to the demo users' groups `L04.md` already names, idempotent (update-in-place on drift, same shape as `Initialize-SensitivityLabel`). Add a V4.3 criterion to `verification/layer-04-audit.ps1` asserting the policy exists and is scoped as expected. Either author `infra/purview/auto-label-design.md` (referenced by `L04.md` but never created) or remove the reference.

- [ ] **Step 4: Verify**

Run: `pwsh -c "Invoke-Pester infra/purview/ verification/"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add infra/purview/ verification/layer-04-audit.ps1 compliance/assessment/
git commit -m "infra(L4): publish the Purview label policy, not just the labels

Closes F18. labels.ps1 created the four-label taxonomy but never
published a policy scoping it to any user or group, though L04.md
documented that step as part of the deploy. A label nobody can apply
enforces nothing, and V4.1/V4.2 checked only label existence — the
Verifier's own audit could not have caught this."
```

---

## Task 21: Grant mls-verifier the Fabric workspace Viewer role (F21)

**Files:** Modify `infra/fabric/provision-workspace.ps1`, `.github/workflows/layer-05-fabric.yml`; Test `infra/fabric/tests/provision-workspace.Tests.ps1`

**Why this one matters disproportionately.** `verification/layer-05-audit.ps1:57` builds its Fabric bearer header assuming `mls-verifier` holds workspace Viewer. It does not — nothing grants it. So the L5 Verifier audit 403s the first time it runs against a real tenant, and CLAUDE.md makes the Verifier's sign-off the authoritative test for whether a layer is done. A broken audit gate is worse than a missing feature: it fails in the direction of looking unverified rather than looking fine, but it blocks the layer either way.

Task 12 added `Set-FabricWorkspaceRoleAssignment` to `infra/fabric/fabric-api.psm1` for data-api's grant. Use it. The verifier needs **Viewer** — read-only — matching its Reader-everywhere posture; anything broader is itself a finding.

Steps: write the failing test asserting the L5 deploy path grants the verifier Viewer; run it and watch it fail; implement; re-run; update `compliance/assessment/` for F21's controls and close F21; commit `fix(L5): grant mls-verifier the Fabric workspace Viewer role it audits with`.

---

## Task 22: Apply the SQL contained-database user after L7 (F20)

**Files:** Modify `.github/workflows/layer-07-apps.yml` (or `infra-up.yml`); Test `scripts/tests/up.Tests.ps1`

Task 12 expressed the grant in `data/seed/sql/`, guarded so it cannot abort the L6 seed when the identity does not yet exist. But nothing re-invokes `seed.ps1 -Target sql` after L7 creates the data-api UAMI, so the grant never actually lands in a single `infra-up.yml` pass — `data-api` 403s on every SQL route until someone re-runs the seed by hand.

Add a post-L7 invocation. Keep it idempotent: it must be safe on a tenant where the user already exists, since `up.ps1` replays.

Steps: write the failing test asserting a post-L7 SQL seed invocation exists; run it and watch it fail; implement; re-run; update the register and close F20; commit `fix(L7): apply the SQL contained-database user after the identity exists`.

---

## Task 24: Smoke-test the container images in CI (F22)

**Files:** Modify `.github/workflows/app-{control-tower,launch-ops,data-api,mcp-tools}-ci.yml`

App CI runs `docker build` and Trivy-scans the result, but **never starts the container**. Nothing curls `/healthz` before merge; the only runtime check is `verification/layer-07-audit.ps1`, which runs post-deployment against live Azure.

That matters because Task 14 hardened both frontend images to run as `USER nginx`, and the failure mode is silent rather than loud: a non-writable `/etc/nginx/conf.d` makes the entrypoint skip templating and serve the **stock nginx welcome page**, which answers 200 to a naive health check while serving none of the app. Same class as F5 — a CI gap that means something is never actually exercised.

Add a step after the image build: `docker run -d` the built image, poll `/healthz` until ready or timeout, assert the response is the app's own payload (not the stock nginx page — check for a field only the app emits), then stop the container. Keep it in the job that already holds the image, and do **not** put it in a job holding `id-token: write` or `packages: write` (the split established in earlier tasks).

Steps: write the failing assertion first (a workflow-shape test in `verification/tests/`, since the runtime check cannot execute locally); implement; run `actionlint`; update the register and close F22; commit `ci: smoke-test container images before merge`.

---

## Task 23: Full-suite verification and register reconciliation

**Files:**
- Modify: `compliance/assessment/*.json`
- Modify: `docs/runbooks/g0-bootstrap.md`

- [ ] **Step 1: Run every gate**

```bash
pwsh -c "Invoke-Pester scripts/,infra/,data/,verification/,compliance/"
pwsh -c "Get-ChildItem -Path scripts,infra,verification,data,.github -Recurse -Include *.ps1,*.psm1 |
         ForEach-Object { Invoke-ScriptAnalyzer -Path \$_.FullName -Severity Error,Warning }"
npm test
cd data/generators && python -m pytest -q && cd ../..
for f in infra/bicep/*/main.bicep; do az bicep build --file "$f" --stdout > /dev/null || echo "FAIL $f"; done
for f in infra/bicep/*/demo.bicepparam; do az bicep build-params --file "$f" --stdout > /dev/null || echo "FAIL $f"; done
actionlint .github/workflows/*.yml
```

Expected: Pester all green, PSSA 0, npm exit 0, pytest 30, every Bicep artifact exit 0, actionlint silent.

- [ ] **Step 1b: Add a verify-g0 check for the Entra diagnostic setting**

G0 item 12 (Entra `SignInLogs`/`AuditLogs`) is a human step, deliberately un-automated so the deployer never holds a standing Security Administrator role. But unlike C4 (whose Fabric-capacity check implicitly proves the SP toggle) and item 10 (covered by V3.4), it has no verification at all — making F9's closure the only one in the register that rests on a human remembering an unaudited command.

Add a read-only check to `scripts/bootstrap/verify-g0.ps1` asserting the tenant diagnostic setting exists and routes `SignInLogs` + `AuditLogs` to the LAW:

```powershell
az monitor diagnostic-settings list --resource "/providers/microsoft.aadiam"
```

Report it informational rather than gate-failing, matching how items C6/C7/C10 are treated — the point is that a missing setting becomes visible, not that G0 blocks on it.

- [ ] **Step 1c: Disambiguate the findings narrative's status fields**

`compliance/findings/2026-08-26-prepublication-review.md` still shows `Status: GAP` inline for findings the per-control JSON now records as `CLOSED`. The doc header says the JSON is the living register, so this is defensible — but two separate reviewers have had to reason it out from first principles, which means it is not labelled clearly enough.

On a branch whose recurring defect shape is *a document asserting something the code contradicts* (F2, F13, F18, F19, F21, and the `Policy.ReadWrite.ConditionalAccess` comment), leaving a record that reads as stale is the wrong thing to ship.

Either sync each finding's `Status:` to its current state, or mark the field explicitly point-in-time (e.g. `Status at discovery: GAP — current state: see compliance/assessment/<control>.json`). Pick one and apply it uniformly.

- [ ] **Step 2: Reconcile the register**

Every finding closed in Tasks 3-20 has its assessment record updated with status and the closing commit SHA as evidence. Any finding *not* closed keeps its `GAP` status and gains a note saying why — the register must never overstate.

- [ ] **Step 3: Verify the register agrees with reality**

Run: `pwsh -c "Invoke-Pester compliance/tests/register.Tests.ps1"`
Expected: PASS.

- [ ] **Step 4: Update the runbook**

Record in `docs/runbooks/g0-bootstrap.md` the new C-items this plan created (the `verify` environment, the `mcp-auth-token` secret) and remove any step the Key Vault reference made obsolete.

- [ ] **Step 5: Commit**

```bash
git add compliance/ docs/runbooks/
git commit -m "verify: full-suite green after the 2026-08-26 remediation

All gates replayed: Pester, PSScriptAnalyzer 0, npm across 7
workspaces, pytest, all six Bicep artifacts, actionlint. Register
reconciled — closed findings carry their commit SHA as evidence; open
ones keep GAP status with a stated reason."
```

---

## Self-Review

**Spec coverage.** This plan implements no section of the compliance-platform spec — deliberately. It consumes only §3.2's assessment schema, in Task 1. The platform itself is Plan 2. The one place they touch is the register, which Task 1 produces and Plan 2 renders.

**Findings coverage.** F1→T6, F2→T4+T5, F3→T7, F4→T8, F5→T3, F6→T9, F7→T9, F8→T10, F9→T13, F10→T11, F11→T14, F12→T15, F13→T12 (partial — 5/7 grants; the other two are owned by T17 and blocked by F19), F14→T16, F15→T17, F16→T18, F17→T19, F18→T20. All original 18 have a closing task. F19, F20 and F21 (surfaced building T12) do not — each needs a new task.

**Sequencing rationale.** T3 first — until CI runs the JS tests, no later green is trustworthy. Then the internet-facing endpoints (T4-T7), the only findings an outsider can exploit. Then leakage (T8), identity (T9-T12), observability (T13), and finally the app-layer bugs (T14-T15), which are real but need a click or a prompt injection to reach. T16-T17 harden the pipeline's own integrity and cost backstop. T18-T20 (the 800-53/CMMC scrub, Task 2) are placed last among the per-finding tasks: T19 explicitly depends on T13's diagnostic settings landing first (an alert on a signal that does not yet exist is not an alert), and T18/T20 are independent of every other task, so ordering them after the exploitable and identity-layer fixes costs nothing. T21 closes the plan.

**Known deferral.** The Azure SQL `0.0.0.0-0.0.0.0` firewall rule is *not* in this plan. It needs a VNet-integrated workload profile to fix properly, which is a G2 spend decision that needs pricing against the $200 credit. Task 13's SQL auditing makes unauthorised connection attempts visible in the meantime, which is the honest interim. This omission is deliberate and recorded in the register rather than silently dropped.
