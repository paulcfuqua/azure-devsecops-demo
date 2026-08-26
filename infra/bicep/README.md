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
        └── key-vault-secrets-user-role.bicep   # referenced by main.bicep (mcpKvGrant) — see below
```

> **Copilot Studio amendment (2026-08-24).** The `copilot-svc` container app is now the
> **MCP tool server** `mls-mcp-demo-ca`; the Key Vault `anthropic-api-key` secret
> reference and the role grant that fed it are gone, because no Anthropic key exists
> anywhere in the system. Details in the L7 section below. The amendment is
> `docs/superpowers/specs/2026-08-24-amendment-copilot-studio.md`.

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
| Key Vault (RBAC mode, soft-delete on) — **currently empty** | `mls-rg-platform` | ~$0 |
| SQL server + serverless DB | `mls-rg-data` | auto-pause 60 min, 0.5–2 vCore; storage only when paused |
| Cost-export storage account | `mls-rg-ops` | Standard_LRS, pennies |
| *(empty, for L7)* | `mls-rg-apps` | — |

Nothing here bills while idle beyond SQL storage + LAW retention, which is exactly the
master plan's built-but-parked envelope (< $15/month).

**Key Vault after the amendment.** The vault is still created, and at the amendment itself
it dropped to **zero secret consumers**: `anthropic-api-key` was its only intended tenant,
and the app that read it is now an MCP server authenticating with a managed identity.
Bicep never held the value, so nothing was deleted at L6 — only the comments and the
`keyVaultUri` output description changed. That zero-consumer state did not last: Task 5
(2026-08-26, closing finding F2's infra half) gave the vault a new tenant, `mcp-auth-token`
— the MCP server's inbound auth token — read by `apps/main.bicep` via `keyVaultUrl` and the
mcp-tools UAMI (see the L7 section below). The Direct Line channel key (a G0 item) is
expected to be the vault's second occupant; destroying/recreating a soft-deleted vault name
is precisely the rebuild hazard `KEY_VAULT_CREATE_MODE=recover` exists to absorb. Whether
the Direct Line key is vaulted at all is a sponsor decision.

### L7 — apps (`apps/main.bicep`)

Three container apps, all `minReplicas: 0`:

| App | Resource name | Ingress |
|---|---|---|
| launch-ops | `mls-launch-ops-demo-ca` | external |
| control-tower | `mls-control-tower-demo-ca` | external |
| mcp-tools | `mls-mcp-demo-ca` | **external, HTTPS only, not parameterised** |

`mcp-tools` replaced `copilot-svc` at the Copilot Studio amendment. It hosts the same
five Ops/Sec/Cost tool implementations as an MCP server (Streamable HTTP); the LLM loop
moved into a Copilot Studio agent (`infra/copilot-studio/`).

**Ingress is external by requirement, not by configuration.** Copilot Studio is a SaaS
caller outside the Container Apps environment — it must resolve and reach the public
FQDN. The old `copilotExternalIngress` parameter was therefore *removed* rather than
defaulted to `true`: an internal-only MCP server is not a supported state of this design,
so it should not be expressible. `ingressAllowInsecure` stays `false`, so only the
TLS-terminated `https://` listener exists.

**No `ANTHROPIC_API_KEY` secret reference — a DIFFERENT one now exists.** The
`anthropic-api-key` Key Vault secret, the app's `ANTHROPIC_API_KEY` environment variable,
and the **Key Vault Secrets User** grant that made that reference resolvable are all
still deleted; the amendment turned "no stored secrets in CI" from a documented exception
into an absolute for that credential specifically. But mcp-tools' external ingress needed
an inbound auth token of its own (finding F2, `compliance/findings/2026-08-26-
prepublication-review.md#f2`), and Task 5 (2026-08-26) closed that finding's infra half by
adding it back as a Key Vault reference — `mcp-auth-token`, read via `keyVaultUrl` +
`identity` (not a `value`) so the token never crosses into this template, the parameter
file, ARM deployment history, or a `what-if` log. The **Key Vault Secrets User** grant is
therefore back too, scoped to this app's UAMI on the vault (module `mcpKvGrant` in
`apps/main.bicep`, using `apps/modules/key-vault-secrets-user-role.bicep` — no longer
unreferenced). CI still never sees the token: the layer-07 workflow does not read or
export it, and the container app resolves it directly at runtime.

**The user-assigned identity is kept** (`mls-mcp-demo-id`), on a new justification —
the old one ("the grant must exist before the app provisions, because the app resolves a
secret reference at creation") died with the secret:

1. `mcp-tools` is the only app that calls Azure data planes on its own behalf: the
   lakehouse SQL analytics endpoint, the **Entra-only** SQL database (no password exists
   to fall back on), Cost Management, and Defender read APIs. Something must
   authenticate, and hard rule 5 forbids a stored credential — so a managed identity is
   mandatory.
2. **User-assigned, not system-assigned,** because the grants those tools need are issued
   by *other* layers' scripts (`CREATE USER … FROM EXTERNAL PROVIDER`, a Fabric workspace
   role assignment, Cost Management Reader). A user-assigned identity has a deterministic
   name from `naming.bicep` and exports its `principalId`, so those grants can be made
   before or after the app exists. A system-assigned identity exists only once the app
   does, re-imposing an ordering dependency on every future grant.
3. Its `clientId` is injected as `AZURE_CLIENT_ID`, binding `DefaultAzureCredential`
   inside the container to this identity rather than to an ambient one.

New outputs: `mcpToolsEndpoint` (the `https://<fqdn>/mcp` URL the Copilot Studio MCP
connector consumes), `mcpToolsIdentityClientId` and `mcpToolsIdentityPrincipalId`.

> **Assumption flagged.** The `/mcp` path and Streamable HTTP transport are assumed from
> the amendment, not read from `apps/mcp-tools/` (a concurrent workstream). The path is
> the `mcpEndpointPath` parameter — reconciling it is one variable, and it provisions
> nothing.

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
   (`apps/modules/key-vault-secrets-user-role.bicep`) — **referenced again, as of Task 5
   (2026-08-26).** It originally existed solely to let the copilot app read
   `anthropic-api-key`, and went unreferenced with that app and secret at the 2026-08-24
   amendment. It is referenced again from `apps/main.bicep` (module `mcpKvGrant`), now
   granting the **mcp-tools** UAMI access to a different secret — `mcp-auth-token`, the
   MCP server's inbound auth token, closing finding F2's infra half
   (`compliance/findings/2026-08-26-prepublication-review.md#f2`). The **Direct Line
   channel key** the previous note anticipated is still a separate, undecided G0 item —
   whether it uses this same module or a dedicated grant is unresolved and does not block
   what is here now. The module's own rationale is unchanged: AVM embeds `roleAssignments`
   *inside* each resource module, which cannot work here — the vault is deployed at L6,
   long before the L7 identity exists, and `avm/ptn/authorization/role-assignment` targets
   MG/subscription/RG scope, not a single resource.
3. **`Microsoft.Insights/components` (`existing`)** (`apps/main.bicep`) — an
   `existing` reference to read the L6 App Insights connection string, not a deployment.
   AVM modules deploy resources; they cannot express an `existing` lookup.

## `[derived]` decisions

Choices made by this track that the plan/playbooks do not pin explicitly. Each is
reversible by changing one parameter or one line of `naming.bicep`.

**Registry**

- **[derived] GHCR as the container registry.** Images come from the public path
  `ghcr.io/paulcfuqua/azure-devsecops-demo/<app>:<tag>`. GHCR is **free on public repos** with
  anonymous pull, so the estate needs **no ACR resource and no registry credentials** —
  it removes a billed resource from the idle run-rate and a secret from the system. Image
  references are parameters; the placeholder default is
  `mcr.microsoft.com/azuredocs/containerapps-helloworld:latest` so L7 is deployable
  before the first app image is published.

**Naming**

- **[derived] Role segments** for shared resources, filling the `<app|role>` slot of the
  CLAUDE.md convention: `obs` (LAW + App Insights), `platform` (Container Apps
  environment), `sec` (Key Vault), `cost` (cost-export storage). `ops` (SQL) is pinned by
  CLAUDE.md's own example (`mls-ops-demo-sql`).
- **[derived] `mcp-tools` shortens to `mcp`**, giving `mls-mcp-demo-ca`. This is a
  deliberate departure from CLAUDE.md's other worked example, `mls-copilot-demo-ca`: the
  service it named no longer exists, and naming an MCP tool server "copilot" after the
  copilot moved to Copilot Studio would be actively misleading. The convention
  `mls-<app|role>-<env>-<type>` is unchanged — only the role segment is. **CLAUDE.md's
  example should be updated to match; that file is outside this change's write scope, so
  it is listed as a reconciliation item.**
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
- **[derived] `ingressAllowInsecure: false`** on all four apps (AVM defaults to `true`).
- **Not derived — required: `data-api` is provisioned here, and `DATA_API_ORIGIN` is
  injected into both frontends.** This template predates `apps/data-api`, so it shipped
  three apps while both frontends' `ApiProvider` fetched `/api/...` and their nginx
  proxied that to `${DATA_API_ORIGIN}` — a variable whose image default is a deliberately
  unreachable loopback address. Every `/api` call answered 502 and both dashboards
  rendered empty. `data-api` now provisions first (the frontends take the origin from its
  FQDN, so Bicep orders it), with its own user-assigned identity for the same reason
  `mcp-tools` has one: it reads Entra-only Azure SQL, the Fabric SQL analytics endpoint,
  Defender and Log Analytics with no stored credential.
- **[derived] `data-api` ingress is external.** Internal-only would be tighter, but it is
  the browser's data path through a same-origin proxy, `/healthz` is the first thing
  anyone checks when a dashboard is blank, and it serves read-only, allowlisted,
  row-capped synthetic data.
- **[derived] `MLS_IMAGE_DIGEST` on every app.** L7's V7.1 binds "endpoint is up" to
  "endpoint serves the audited build" by comparing the health payload's content-hash
  marker with the digest the deploy run recorded, and it refuses to pass on liveness
  alone. The frontends' nginx templates interpolate the variable into `/healthz`;
  `data-api` reads it as its `build` marker. `layer-07-apps.yml` resolves the digest from
  the registry, falling back to whatever the last per-app CI deploy stamped on the running
  app, and `'unset'` when neither answers — so the criterion says so rather than passing.
- **Not derived — required: `mcp-tools` ingress is external.** Copilot Studio reaches it
  from outside Azure. There is no parameter for this (see the L7 section).
- **[derived] A user-assigned identity for `mcp-tools`** rather than system-assigned —
  full reasoning in the L7 section. Short version: downstream grants are issued by other
  layers and need a principal that is nameable and grantable independently of the app's
  lifecycle.
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
`minCapacity: '0.5'`, SKU `GP_S_Gen5`, `minReplicas: 0` on all four apps — which is the
compile-time assertion the L6 playbook's Deferred-validation section asks Track E for.
