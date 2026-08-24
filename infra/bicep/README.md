# `infra/bicep` — Bicep infrastructure tree (Track E, Phase P)

Authored and **compile-validated only**. Nothing in this tree has been deployed:
Phase P makes zero cloud writes (`docs/superpowers/plans/2026-08-22-phase-p-pre-tenant-scaffold.md`).
Live deployment happens at L2 / L6 / L7 after G1b + G0, per the layer playbooks in
`docs/runbooks/layers/`.

## Layout

```
infra/bicep/
├── bicepconfig.json                 # linter config for the whole tree
├── naming.bicep                     # single source of naming + tags (no other file says 'mls')
├── landing-zone/                    # L2 — tenant-root MG scope
│   ├── main.bicep
│   └── demo.bicepparam
├── platform/                        # L6 — subscription scope
│   ├── main.bicep
│   └── demo.bicepparam
└── apps/                            # L7 — resource group scope (mls-rg-apps)
    ├── main.bicep
    ├── demo.bicepparam
    └── modules/
        └── key-vault-secrets-user-role.bicep
```

## What deploys at which layer

| Layer | Template | Deployment scope | Command (run by the layer workflow, never locally) |
|---|---|---|---|
| **L2** | `landing-zone/main.bicep` | Tenant root management group | `az deployment mg create --management-group-id <tenantRoot> --location $AZURE_LOCATION` |
| **L6** | `platform/main.bicep` | Subscription | `az deployment sub create --location $AZURE_LOCATION` |
| **L7** | `apps/main.bicep` | Resource group `mls-rg-apps` | `az deployment group create --resource-group mls-rg-apps` |

### L2 — landing zone (`landing-zone/main.bicep`)

- Management group `mls` under the tenant root; demo subscription placed beneath it.
- **Tag deny on RGs:** five `Require a tag on resource groups` assignments (`env`, `app`,
  `costCenter`, `owner`, `dataClassification`) plus one
  `Require a tag and its value on resource groups` pinning `managedBy=iac`.
- **Tag inherit (modify):** six `Inherit a tag from the resource group if missing`
  assignments, one per required tag, each with a system-assigned identity holding
  **Tag Contributor**.
- **Allowed locations:** guardrails for both resources and resource groups.
- **NIST SP 800-53 Rev. 5** built-in initiative at **subscription** scope with
  `enforcementMode: DoNotEnforce` (= audit mode, per the master plan).

Built-in definition IDs are stable GUIDs, each commented in-file with its display name:

| GUID | Display name | Kind |
|---|---|---|
| `96670d01-0a4d-4649-9c89-2d3abc0a5025` | Require a tag on resource groups | policyDefinition |
| `8ce3da23-7156-49e4-b145-24f95f9dcb46` | Require a tag and its value on resource groups | policyDefinition |
| `ea3f2387-9b95-492a-a190-fcdc54f7b070` | Inherit a tag from the resource group if missing | policyDefinition |
| `e56962a6-4747-49cd-b67b-5fbf209ee700` | Allowed locations | policyDefinition |
| `e765b5de-1225-4ba3-bd56-1ac6695af988` | Allowed locations for resource groups | policyDefinition |
| `179d1daa-458f-4e47-8086-2a68d0d6c38f` | NIST SP 800-53 Rev. 5 | policy**Set**Definition |
| `4a9ae827-6dc8-4573-8ac7-8239d42aa03f` | Tag Contributor | roleDefinition |
| `b24988ac-6180-42a0-ab88-20f7382dd24c` | Contributor | roleDefinition |
| `4633458b-17de-408a-b874-0445c86b69e6` | Key Vault Secrets User | roleDefinition |

> L2 playbook failure mode 3 anticipates initiative-ID drift. If a deploy ever fails with
> `PolicyDefinitionNotFound`, `infra/policy/` resolves the initiative by display name and
> the new ID is pinned here via PR — never hand-edited in the portal.

### L6 — platform (`platform/main.bicep`)

Creates **all four demo resource groups** (this template is the single owner of RG
creation), then:

| Resource | RG | Cost posture |
|---|---|---|
| Log Analytics workspace | `mls-rg-platform` | PerGB2018, 30-day retention, 1 GB/day cap |
| Application Insights (workspace-based) | `mls-rg-platform` | bills only via LAW ingestion |
| Container Apps environment (wired to LAW) | `mls-rg-platform` | consumption-only; env itself bills $0 |
| Key Vault (RBAC mode, soft-delete on) | `mls-rg-platform` | ~$0 at demo secret volume |
| SQL server + serverless DB | `mls-rg-data` | auto-pause 60 min, 0.5–2 vCore; storage only when paused |
| Cost-export storage account | `mls-rg-ops` | Standard_LRS, pennies |
| *(empty, for L7)* | `mls-rg-apps` | — |

Nothing here bills while idle beyond SQL storage + LAW retention, which is exactly the
master plan's built-but-parked envelope (< $15/month).

### L7 — apps (`apps/main.bicep`)

Three container apps, all `minReplicas: 0`:

| App | Resource name | Ingress |
|---|---|---|
| launch-ops | `mls-launch-ops-demo-ca` | external |
| control-tower | `mls-control-tower-demo-ca` | external |
| copilot-svc | `mls-copilot-demo-ca` | **internal**, flipped by `copilotExternalIngress` |

`copilot-svc` gets a user-assigned identity granted **Key Vault Secrets User** on the L6
vault, and an `ANTHROPIC_API_KEY` environment variable backed by a Key Vault secret
reference. **This template wires the reference only** — the secret *value* arrives at G0
(human bootstrap, item C5) and is written into the vault by the layer-06 workflow from
the GitHub secret. No secret value exists in this repo (CLAUDE.md hard rule 5).

## AVM modules used

Every resource that has an AVM module uses one, pinned to an explicit version.

| Purpose | AVM module | Version |
|---|---|---|
| Management group | `avm/res/management/management-group` | 0.2.0 |
| Policy assignments (all 15) | `avm/ptn/authorization/policy-assignment` | 0.5.3 |
| Resource groups (all 4) | `avm/res/resources/resource-group` | 0.4.4 |
| Log Analytics workspace | `avm/res/operational-insights/workspace` | 0.16.1 |
| Application Insights | `avm/res/insights/component` | 0.8.0 |
| Container Apps environment | `avm/res/app/managed-environment` | 0.15.0 |
| Container apps (all 3) | `avm/res/app/container-app` | 0.23.0 |
| SQL server + database | `avm/res/sql/server` | 0.22.0 |
| Storage account | `avm/res/storage/storage-account` | 0.33.0 |
| Key Vault | `avm/res/key-vault/vault` | 0.14.0 |
| User-assigned identity | `avm/res/managed-identity/user-assigned-identity` | 0.6.0 |

## Raw resources — and why each one is raw

Only three, each because **no AVM module covers the case**:

1. **`Microsoft.Management/managementGroups/subscriptions`**
   (`landing-zone/main.bicep`) — placing the demo subscription under MG `mls`. The
   management-group AVM module creates the group but does not move subscriptions into
   it, and no separate AVM module exists for the association.
2. **`Microsoft.Authorization/roleAssignments` scoped to an existing Key Vault**
   (`apps/modules/key-vault-secrets-user-role.bicep`) — AVM embeds `roleAssignments`
   *inside* each resource module, which cannot work here: the vault is deployed at L6,
   long before the copilot identity exists at L7. `avm/ptn/authorization/role-assignment`
   targets MG/subscription/RG scope, not a single resource. A thin local module is the
   correct shape.
3. **`Microsoft.Insights/components` (`existing`)** (`apps/main.bicep`) — an
   `existing` reference to read the L6 App Insights connection string, not a deployment.
   AVM modules deploy resources; they cannot express an `existing` lookup.

## `[derived]` decisions

Choices made by this track that the plan/playbooks do not pin explicitly. Each is
reversible by changing one parameter or one line of `naming.bicep`.

**Registry**

- **[derived] GHCR as the container registry.** Images come from the public path
  `ghcr.io/paulcfuqua/azure-devsecops/<app>:<tag>`. GHCR is **free on public repos** with
  anonymous pull, so the estate needs **no ACR resource and no registry credentials** —
  it removes a billed resource from the idle run-rate and a secret from the system. Image
  references are parameters; the placeholder default is
  `mcr.microsoft.com/azuredocs/containerapps-helloworld:latest` so L7 is deployable
  before the first app image is published.

**Naming**

- **[derived] Role segments** for shared resources, filling the `<app|role>` slot of the
  CLAUDE.md convention: `obs` (LAW + App Insights), `platform` (Container Apps
  environment), `sec` (Key Vault), `cost` (cost-export storage). `ops` (SQL) and
  `copilot` are pinned by CLAUDE.md's own examples (`mls-ops-demo-sql`,
  `mls-copilot-demo-ca`).
- **[derived] `copilot-svc` shortens to `copilot`** in resource names, so the container
  app is `mls-copilot-demo-ca` exactly as CLAUDE.md specifies.
- **[derived] Storage account names strip hyphens** (`mlscostdemost`) — storage requires
  3–24 lowercase alphanumerics, so the hyphenated convention cannot apply.
- **[derived] `mls-rg-apps` is created by the L6 template**, not the L7 one, so a single
  template owns all four RGs and L7 stays a pure RG-scoped app deployment.

**Tags**

- **[derived] Tag defaults:** `costCenter=demo`, `owner=paulcfuqua`,
  `dataClassification=internal` (synthetic data only, CLAUDE.md rule 4). `managedBy` is
  hardcoded to `iac` inside the tag builder — it is the only permitted value.
- **[derived] The `app` tag value follows the role segment** of each resource's name, so
  tags and names stay consistent under the tag-inherit modify policy.

**Cost posture**

- **[derived] LAW retention 30 days + 1 GB/day ingestion cap.** Retention beyond 31 days
  bills; the cap is a runaway-ingest guard protecting the idle-cost model. Raising either
  is a spend-profile change (G2).
- **[derived] SQL max capacity 2 vCores, 32 GiB, no zone redundancy**; auto-pause 60 min
  and min 0.5 vCore are pinned by the master plan, not derived.
- **[derived] Container sizing 0.25 vCPU / 0.5 GiB, maxReplicas 2** — the smallest
  consumption slice, ample for demo traffic, and a low ceiling on active spend.
- **[derived] Key Vault SKU `standard`** (AVM defaults to `premium`); no HSM-backed keys
  are needed.
- **[derived] Purge protection OFF, `createMode` parameterized.** The G3 full-teardown
  path must be able to purge the vault, and the standard kill/rebuild cycle recovers a
  soft-deleted vault by setting `KEY_VAULT_CREATE_MODE=recover` — this is the mechanism
  the L6 playbook's rollback note calls for. Soft-delete itself stays **on** with 90-day
  retention.

**Security / connectivity**

- **[derived] SQL uses Entra-only authentication** (`azureADOnlyAuthentication: true`), so
  no SQL password exists anywhere in the system. The admin login/object ID arrive as
  environment variables at deploy time.
- **[derived] SQL firewall allows Azure services** (`0.0.0.0`–`0.0.0.0`, the ARM idiom).
  The design is consumption-only with no VNet, so Container Apps reach SQL over the
  public endpoint.
- **[derived] Cost-export storage disables shared-key access** — Cost Management writes
  with its service identity via Storage Blob Data Contributor (granted by the layer-06
  workflow), so keys are unnecessary.
- **[derived] Container Apps environment `publicNetworkAccess: Enabled`** — AVM defaults
  it to `Disabled`, which would break the two external frontends by design.
- **[derived] `zoneRedundant: false`** on the Container Apps environment: zone redundancy
  requires an infrastructure subnet (a VNet), which this consumption-only design does not
  have.
- **[derived] `ingressAllowInsecure: false`** on all three apps (AVM defaults to `true`).
- **[derived] A user-assigned identity for copilot-svc** rather than system-assigned: the
  Key Vault role grant must exist *before* the app provisions, because the app resolves
  the secret reference at creation. A system-assigned identity would require the app to
  exist first — a deadlock.
- **[derived] NIST initiative assignment carries a system-assigned identity with
  Contributor.** The built-in initiative contains `deployIfNotExists`/`modify` members,
  and ARM rejects the assignment without an identity even in `DoNotEnforce` mode.

**Parameters**

- **[derived] No IDs are committed.** `*.bicepparam` files read
  `AZURE_SUBSCRIPTION_ID`, `AZURE_LOCATION`, the SQL admin identity, and image
  references via `readEnvironmentVariable(...)` with safe defaults, satisfying CLAUDE.md
  hard rule 5 and spec F5 while keeping local builds green with nothing set.
- **[derived] Single-region guardrail:** `allowedLocations` defaults to just
  `AZURE_LOCATION` (fallback `eastus2`).
- **[derived] Empty `demoSubscriptionId` compiles but skips** subscription placement and
  the NIST assignment, so the landing zone builds locally with no tenant.

## Validation

Run from the repo root (Bicep CLI 0.46.1). **No Azure contact** — `build` and `lint` are
local; module restore pulls from `mcr.microsoft.com` (the public AVM registry).

```powershell
bicep build infra/bicep/landing-zone/main.bicep --stdout
bicep build infra/bicep/platform/main.bicep     --stdout
bicep build infra/bicep/apps/main.bicep         --stdout

bicep build-params infra/bicep/landing-zone/demo.bicepparam --stdout
bicep build-params infra/bicep/platform/demo.bicepparam     --stdout
bicep build-params infra/bicep/apps/demo.bicepparam         --stdout

Get-ChildItem infra/bicep -Recurse -Include *.bicep,*.bicepparam |
  ForEach-Object { bicep lint $_.FullName }
```

**Current status: zero errors and zero warnings** across all 8 files.

> Note on exit codes: `bicep lint` returns 0 even when it emits warnings, so the real
> pass condition is **no diagnostic lines**, not the exit code. The linter was
> sanity-checked against a deliberately unused parameter/variable to confirm it is active
> and would have reported.

### Deferred validation

`what-if` and real deployment are deferred to L2 / L6 / L7 and covered by
`verification/layer-{02,06,07}-audit.ps1`. Locally proven now: templates compile, names
resolve exclusively through `naming.bicep` (no file outside it contains the literal
`mls`), and the pinned spend-profile values reach the compiled ARM — `autoPauseDelay: 60`,
`minCapacity: '0.5'`, SKU `GP_S_Gen5`, `minReplicas: 0` on all three apps — which is the
compile-time assertion the L6 playbook's Deferred-validation section asks Track E for.
