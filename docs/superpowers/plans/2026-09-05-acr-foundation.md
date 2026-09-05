# ACR Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up an Azure Container Registry that survives teardown, move the six app images onto it, and prove ACR Tasks rebuilds an image when its upstream base is patched — the mechanism lane 3 of the self-healing design depends on.

**Architecture:** A Basic ACR in a new resource group **outside the four the teardown deletes**, so a rebuild can pull images that already exist. App container identities get `AcrPull`; CI pushes to ACR alongside GHCR during the migration; each app image gets an ACR Task with a base-image update trigger. The 0%-traffic revision strategy belongs to **Plan 2**, because it only has meaning once there is a change window to shift traffic inside.

**Tech Stack:** Bicep (Azure Verified Modules), Azure CLI, GitHub Actions, Pester 5 (PowerShell 7), PSScriptAnalyzer.

**Spec:** [`docs/superpowers/specs/2026-09-05-operationalize-self-healing-design.md`](../specs/2026-09-05-operationalize-self-healing-design.md)

## Global Constraints

- **G2 approved:** ACR **Basic**, `centralus`, USD 0.1666/day (~USD 3.33 over the remaining window). Any SKU above Basic is a **new** G2 and must stop and ask.
- **G3 unchanged:** no tenant-level deletions. Creating a resource group is not G3; deleting one outside the demo four is not part of this plan.
- **Teardown safety:** teardown deletes `mls-rg-platform`, `mls-rg-apps`, `mls-rg-data`, `mls-rg-ops`. **The registry must not live in any of them** (spec §8, P2 — BLOCKER-E's shape).
- **Naming:** `mls-<app|role>-<env>-<type>` from `infra/bicep/naming.bicep`. Never hardcode `mls`; use `MLS_COMPANY_PREFIX` / `MLS_ENV_SEGMENT`.
- **CI targets `ubuntu-latest` (bash). Local orchestration targets PowerShell 7.** Never assume Windows PowerShell 5.1.
- **File content is written with a file tool, never a shell heredoc** (CLAUDE.md). Verify bytes, not rendering.
- **A constant naming something in another system is resolved against that system**, not written from memory.
- **PSScriptAnalyzer at Error+Warning must report 0** across `scripts`, `infra`, `verification`, `data`, `compliance`, `.github`.

---

### Task 1: Establish precondition P1 — can ACR Tasks track a Docker Hub base?

Lane 3 rests entirely on this and it is **unverified**. Nothing else in this plan should be built until it is answered. If the answer is no, stop and amend the spec.

**Files:**
- Create: `docs/findings/2026-09-05-acr-basetrigger-spike.md`

**Interfaces:**
- Consumes: nothing.
- Produces: a recorded yes/no that Task 7 depends on. No code.

- [ ] **Step 1: Register the provider (free, required before any ACR call)**

```bash
az provider register --namespace Microsoft.ContainerRegistry --wait
az provider show -n Microsoft.ContainerRegistry --query registrationState -o tsv
```

Expected: `Registered`

- [ ] **Step 2: Create a throwaway registry to probe with**

```bash
az group create -n mls-rg-spike -l centralus --tags env=demo app=spike costCenter=demo owner=platform dataClassification=public managedBy=iac
az acr create -n mlsspike$RANDOM -g mls-rg-spike --sku Basic -l centralus
```

- [ ] **Step 3: Create a task whose base is a Docker Hub image, and read back the trigger**

```bash
ACR=$(az acr list -g mls-rg-spike --query "[0].name" -o tsv)
printf 'FROM nginx:1.31-alpine\nRUN echo probe\n' > /tmp/Dockerfile.probe
az acr task create --registry "$ACR" --name basetrigger-probe \
  --context /dev/null --file /tmp/Dockerfile.probe \
  --base-image-trigger-enabled true --base-image-trigger-type All \
  --commit-trigger-enabled false
az acr task show --registry "$ACR" --name basetrigger-probe \
  --query "{baseTrigger:trigger.baseImageTrigger.baseImageTriggerType, status:trigger.baseImageTrigger.status}" -o json
```

Expected if P1 holds: `baseTrigger: All`, `status: Enabled`, and the task accepts a non-ACR base without error.

- [ ] **Step 4: Record the answer, whichever it is**

Write `docs/findings/2026-09-05-acr-basetrigger-spike.md` stating: the commands run, the exact output, and the verdict. If ACR refuses or silently ignores a Docker Hub base, say so plainly — a negative result here saves the rest of the plan.

- [ ] **Step 5: Tear the spike down**

```bash
az group delete -n mls-rg-spike --yes --no-wait
```

- [ ] **Step 6: Commit**

```bash
git add docs/findings/2026-09-05-acr-basetrigger-spike.md
git commit -m "docs(spike): whether ACR Tasks can track a Docker Hub base image"
```

**STOP HERE if the verdict is no.** Report to the sponsor and amend the spec's §2 and §8 before continuing; lane 3 falls back to a scheduled rebuild.

---

### Task 2: The registry must live outside the teardown set — assert it before building it

Write the guard first, so the resource cannot be introduced into a deleted resource group. This is BLOCKER-E's shape and it is cheap only now.

**Files:**
- Modify: `verification/tests/failure-classes.Tests.ps1`

**Interfaces:**
- Consumes: nothing.
- Produces: a repository-wide sweep later tasks must satisfy.

- [ ] **Step 1: Write the failing test**

Add to `verification/tests/failure-classes.Tests.ps1`:

```powershell
Describe 'a resource the rebuild depends on does not live where teardown deletes' {

    # BLOCKER-E: 02-fabric-capacity.ps1 defaulted the Fabric capacity into
    # <prefix>-rg-platform, which teardown deletes - so an ordinary teardown destroyed the
    # capacity and stranded the workspace. A container registry has the same shape and is
    # worse: the apps PULL from it, so a registry inside the teardown set means the rebuild
    # cannot rebuild - the estate would depend on a registry that only exists after the
    # estate exists.
    BeforeAll {
        $script:TeardownRg = @('rg-platform', 'rg-apps', 'rg-data', 'rg-ops')
    }

    It 'no bicep file places a container registry in a teardown-deleted resource group' {
        $offender = [System.Collections.Generic.List[string]]::new()
        foreach ($file in (Get-ChildItem -Path (Join-Path $script:RepoRoot 'infra/bicep') -Recurse -Filter '*.bicep' -File)) {
            $lines = Get-Content -LiteralPath $file.FullName
            for ($i = 0; $i -lt $lines.Count; $i++) {
                if ($lines[$i] -notmatch 'Microsoft\.ContainerRegistry|registries|containerRegistry') { continue }
                $from = [math]::Max(0, $i - 12)
                $block = ($lines[$from..([math]::Min($lines.Count - 1, $i + 12))]) -join "`n"
                foreach ($rg in $script:TeardownRg) {
                    if ($block -match [regex]::Escape($rg)) {
                        $offender.Add("$($file.Name):$($i + 1) near '$rg'")
                    }
                }
            }
        }
        $offender -join ', ' | Should -BeNullOrEmpty `
            -Because 'the apps pull from the registry, so a registry inside the teardown set makes the rebuild impossible (BLOCKER-E''s shape, spec P2)'
    }
}
```

- [ ] **Step 2: Run it and watch it pass vacuously, then prove it can fail**

Run:
```bash
pwsh -NoProfile -Command "Invoke-Pester -Path verification/tests/failure-classes.Tests.ps1 -Output Detailed" 
```
Expected: PASS (no registry exists yet).

Now mutation-test it. Temporarily add to any file under `infra/bicep/`:

```bicep
// mutation probe - delete after checking
resource probeAcr 'Microsoft.ContainerRegistry/registries@2023-07-01' existing = {
  name: 'probe'
  scope: resourceGroup('mls-rg-platform')
}
```

Re-run. Expected: **FAIL**, naming that file. Then delete the probe and re-run — PASS.

A sweep that has never been seen to fail is not a check.

- [ ] **Step 3: Commit**

```bash
git add verification/tests/failure-classes.Tests.ps1
git commit -m "test: a registry the rebuild depends on may not live in the teardown set"
```

---

### Task 3: Add the registry to the estate

**Files:**
- Create: `infra/bicep/registry/main.bicep`
- Create: `infra/bicep/registry/main.bicepparam`
- Modify: `infra/bicep/naming.bicep` (add the registry name)
- Test: `verification/tests/failure-classes.Tests.ps1` (already written in Task 2)

**Interfaces:**
- Consumes: `naming.bicep`'s prefix/env conventions.
- Produces: registry login server as a deployment output named `loginServer`, consumed by Tasks 5, 6 and 7. Resource group name `<prefix>-rg-registry`.

- [ ] **Step 1: Add the registry name to naming.bicep**

In `infra/bicep/naming.bicep`, beside the existing name builders:

```bicep
@description('Container registry. Alphanumeric only - ACR names forbid hyphens - so the segments are concatenated rather than joined.')
output registryName string = toLower('${companyPrefix}${envSegment}acr')

@description('The resource group the registry lives in. NOT one of the four teardown deletes: the apps pull from this registry, so destroying it would make the rebuild impossible.')
output registryResourceGroupName string = '${companyPrefix}-rg-registry'
```

- [ ] **Step 2: Write the registry module**

Create `infra/bicep/registry/main.bicep`:

```bicep
targetScope = 'subscription'

@description('Location for the registry. Defaults to the estate location.')
param location string

@description('Company prefix, from MLS_COMPANY_PREFIX. Never hardcoded (F90).')
param companyPrefix string

@description('Environment segment, from MLS_ENV_SEGMENT.')
param envSegment string

@description('Required tags, policy-enforced on every resource group.')
param tags object

// BASIC, AND THAT IS A GATE. G2 approved Basic at USD 0.1666/day. Standard is 4x and
// Premium is 10x; raising this is a NEW G2 that waits for a human.
@allowed(['Basic'])
param sku string = 'Basic'

resource registryGroup 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  // OUTSIDE THE TEARDOWN SET, DELIBERATELY. infra-down.yml deletes rg-platform, rg-apps,
  // rg-data and rg-ops. The apps PULL from this registry, so if it were destroyed with them
  // the rebuild could not proceed - the estate would depend on a registry that only exists
  // after the estate exists. This is BLOCKER-E's shape (the Fabric capacity), already paid
  // for once.
  name: '${companyPrefix}-rg-registry'
  location: location
  tags: tags
}

module registry 'br/public:avm/res/container-registry/registry:0.9.1' = {
  name: 'registry-deploy'
  scope: registryGroup
  params: {
    name: toLower('${companyPrefix}${envSegment}acr')
    location: location
    acrSku: sku
    tags: tags
    acrAdminUserEnabled: false
    publicNetworkAccess: 'Enabled'
  }
}

@description('Login server, e.g. mlsdemoacr.azurecr.io. Consumed by CI push, the app pull configuration and the base-image tasks.')
output loginServer string = registry.outputs.loginServer

@description('Resource id, for the AcrPull role assignments in the apps layer.')
output registryId string = registry.outputs.resourceId

@description('The resource group the registry lives in - named so callers cannot assume it is one of the demo four.')
output registryResourceGroupName string = registryGroup.name
```

- [ ] **Step 3: Write the parameter file**

Create `infra/bicep/registry/main.bicepparam`:

```bicep
using './main.bicep'

param location = readEnvironmentVariable('AZURE_LOCATION', 'centralus')
param companyPrefix = readEnvironmentVariable('MLS_COMPANY_PREFIX', 'mls')
param envSegment = readEnvironmentVariable('MLS_ENV_SEGMENT', 'demo')
param tags = {
  env: readEnvironmentVariable('MLS_ENV_SEGMENT', 'demo')
  app: 'registry'
  costCenter: 'demo'
  owner: 'platform'
  dataClassification: 'internal'
  managedBy: 'iac'
}
```

- [ ] **Step 4: Build it and run the guard**

Run:
```bash
az bicep build --file infra/bicep/registry/main.bicep --stdout > /dev/null && echo "bicep OK"
pwsh -NoProfile -Command "Invoke-Pester -Path verification/tests/failure-classes.Tests.ps1 -Output Detailed"
```
Expected: bicep compiles; Task 2's sweep **passes** (the registry is in `rg-registry`, not the teardown four).

- [ ] **Step 5: Deploy it**

```bash
az deployment sub create --location centralus \
  --name registry-$(date +%Y%m%d%H%M) \
  --template-file infra/bicep/registry/main.bicep \
  --parameters infra/bicep/registry/main.bicepparam
az acr list -o table
```
Expected: one Basic registry in `mls-rg-registry`.

- [ ] **Step 6: Commit**

```bash
git add infra/bicep/registry/ infra/bicep/naming.bicep
git commit -m "infra(registry): a Basic ACR outside the teardown set"
```

---

### Task 4: Grant the app identities AcrPull

Container Apps pull with their user-assigned managed identity. Without `AcrPull` the pull fails at revision creation, and the failure looks like a bad image reference.

**Files:**
- Modify: `infra/bicep/apps/main.bicep`

**Interfaces:**
- Consumes: `registryResourceGroupName` from Task 3, and the registry's **name** (the
  `loginServer` output's first label, e.g. `mlsdemoacr` from `mlsdemoacr.azurecr.io`).
- Produces: apps able to pull. `apps/main.bicep` gains exactly two parameters —
  `registryName` and `registryResourceGroupName` — which Task 6 passes. **No `registryId`
  and no `registryLoginServer`**: the module resolves the registry by name at its own
  resource group's scope, and the `*Image` parameters already carry the full registry path,
  so the login server never needs to reach bicep.

- [ ] **Step 1: Add the two parameters the grants need**

In `infra/bicep/apps/main.bicep`, beside the other image parameters:

```bicep
@description('Registry name (no suffix), e.g. mlsdemoacr. Empty means "still on a public registry" and skips the AcrPull grants.')
param registryName string = ''

@description('Resource group holding the registry. Outside the teardown set by design - see the registry module.')
param registryResourceGroupName string = ''
```

- [ ] **Step 2: Assign AcrPull to each app identity**

The role assignment is scoped to the registry, which lives in a **different resource group**,
so it goes in its own module deployed at that scope rather than inline here.

Create `infra/bicep/apps/acr-pull.bicep`:

```bicep
@description('Principal ids of the app user-assigned identities that must pull images.')
param principalIds array

@description('Name of the registry in THIS resource group, e.g. mlsdemoacr.')
param registryName string

// AcrPull, resolved not remembered. CLAUDE.md requires a constant naming something in
// another system to be verified against that system; step 3 below does exactly that.
var acrPullRoleId = '7f951dda-4ed3-4680-a7ca-43fe172d538d'

resource registry 'Microsoft.ContainerRegistry/registries@2023-07-01' existing = {
  name: registryName
}

resource acrPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for id in principalIds: {
  name: guid(registry.id, id, acrPullRoleId)
  scope: registry
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', acrPullRoleId)
    principalId: id
    principalType: 'ServicePrincipal'
  }
}]
```

Then, in `infra/bicep/apps/main.bicep`, call it at the registry's resource group scope,
using the two parameters added in step 1. The identity resources already exist in that file
— **confirm their exact symbol names with `grep -n "userAssignedIdentities"
infra/bicep/apps/main.bicep` and use what is actually there** rather than the names written
below, which are illustrative:

```bicep
module acrPullGrants 'acr-pull.bicep' = if (!empty(registryName)) {
  name: 'acr-pull-grants'
  scope: resourceGroup(registryResourceGroupName)
  params: {
    registryName: registryName
    principalIds: [
      launchOpsIdentity.outputs.principalId
      controlTowerIdentity.outputs.principalId
      mcpIdentity.outputs.principalId
      dataApiIdentity.outputs.principalId
    ]
  }
}
```

- [ ] **Step 3: Verify the role id against Azure rather than trusting the comment**

Run:
```bash
az role definition list --name AcrPull --query "[0].name" -o tsv
```
Expected: `7f951dda-4ed3-4680-a7ca-43fe172d538d`. If it differs, use what Azure returned and correct the code — this is exactly the class CLAUDE.md pins twenty-three constants for.

- [ ] **Step 4: Build**

```bash
az bicep build --file infra/bicep/apps/main.bicep --stdout > /dev/null && echo "bicep OK"
```

- [ ] **Step 5: Commit**

```bash
git add infra/bicep/apps/main.bicep
git commit -m "infra(apps): AcrPull for the app identities on the new registry"
```

---

### Task 5: CI pushes to ACR

**Files:**
- Modify: `.github/workflows/app-mcp-tools-ci.yml`, `app-data-api-ci.yml`, `app-control-tower-ci.yml`, `app-launch-ops-ci.yml`, `app-compliance-ci.yml`

**Interfaces:**
- Consumes: `loginServer` from Task 3, exposed as the `demo` environment variable `MLS_ACR_LOGIN_SERVER`.
- Produces: images at `<loginServer>/<app>:<tag>`, consumed by Task 6.

- [ ] **Step 1: Publish the login server as an environment variable**

```bash
LOGIN=$(az acr list -g mls-rg-registry --query "[0].loginServer" -o tsv)
gh variable set MLS_ACR_LOGIN_SERVER --env demo --body "$LOGIN"
gh variable get MLS_ACR_LOGIN_SERVER --env demo
```

Expected: the value echoes back. **An absent GitHub variable is the empty string, not an error** (F125) — so read it back rather than assuming the set worked.

- [ ] **Step 2: Add an ACR login step in each app CI, beside the existing GHCR login**

```yaml
      - name: Log in to ACR
        if: ${{ vars.MLS_ACR_LOGIN_SERVER != '' }}
        uses: azure/login@v3
        with:
          client-id: ${{ vars.AZURE_CLIENT_ID }}
          tenant-id: ${{ vars.AZURE_TENANT_ID }}
          subscription-id: ${{ vars.AZURE_SUBSCRIPTION_ID }}

      - name: ACR docker login
        if: ${{ vars.MLS_ACR_LOGIN_SERVER != '' }}
        run: az acr login --name "${MLS_ACR_LOGIN_SERVER%%.*}"
        env:
          MLS_ACR_LOGIN_SERVER: ${{ vars.MLS_ACR_LOGIN_SERVER }}
```

- [ ] **Step 3: Add the ACR tag to the existing build-push step**

In the `docker/build-push-action` step's `tags:`, add a second tag alongside the GHCR one:

```yaml
          tags: |
            ${{ steps.meta.outputs.registry }}/${{ env.APP_SLUG }}:${{ github.sha }}
            ${{ vars.MLS_ACR_LOGIN_SERVER != '' && format('{0}/{1}:{2}', vars.MLS_ACR_LOGIN_SERVER, env.APP_SLUG, github.sha) || '' }}
```

Pushing to **both** during the migration means a rollback to GHCR is a parameter change, not a rebuild.

- [ ] **Step 4: Lint the workflows**

```bash
docker run --rm -v "$(pwd):/repo" -w /repo rhysd/actionlint:latest -color .github/workflows/app-mcp-tools-ci.yml
```
Expected: clean. If actionlint is unavailable locally, push and read CI — do not skip it.

- [ ] **Step 5: Push and confirm an image actually lands in ACR**

```bash
az acr repository list --name "${LOGIN%%.*}" -o table
```
Expected: the app repositories appear. **Assert the effect, not the step's exit code** (F119): a publish step that "succeeded" while pushing nothing is this repository's most expensive recurring defect.

- [ ] **Step 6: Commit**

```bash
git add .github/workflows/app-*-ci.yml
git commit -m "ci: push app images to ACR alongside GHCR"
```

---

### Task 6: Apps pull from ACR

**Files:**
- Modify: `.github/workflows/layer-07-apps.yml` (pass the new parameters)

**Interfaces:**
- Consumes: `registryName` and `registryResourceGroupName` — the two parameters Task 4
  defined — plus images from Task 5. **Not** `registryId` or `registryLoginServer`; neither
  exists in `apps/main.bicep`, and passing them would fail the deployment on an unknown
  parameter.
- Produces: running revisions pulling from ACR.

- [ ] **Step 1: Pass the registry parameters into the L7 deployment**

`MLS_ACR_LOGIN_SERVER` is `<name>.azurecr.io`; the registry **name** is its first label.

```yaml
            registryName=${{ vars.MLS_ACR_LOGIN_SERVER != '' && split(vars.MLS_ACR_LOGIN_SERVER, '.')[0] || '' }}
            registryResourceGroupName=${{ vars.MLS_COMPANY_PREFIX || 'mls' }}-rg-registry
            mcpToolsImage=${{ vars.MLS_ACR_LOGIN_SERVER }}/mcp-tools:${{ github.sha }}
```

Do the same for `dataApiImage`, `launchOpsImage`, `controlTowerImage`, `complianceImage`.

- [ ] **Step 2: Deploy L7 and assert the revision is running, not merely created**

```bash
az containerapp revision list -g mls-rg-apps -n mls-mcp-demo-ca \
  --query "[?properties.active].{rev:name,image:properties.template.containers[0].image,health:properties.healthState,replicas:properties.replicas}" -o table
```

Expected: the active revision's image starts with the ACR login server, `healthState` is `Healthy`, and replicas is at least 1 after a request. **A revision that exists but cannot pull reports `Failed` here** — which is the whole reason Task 4 exists.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/layer-07-apps.yml
git commit -m "infra(L7): apps pull their images from ACR"
```

---

### Task 7: The base-image trigger — lane 3's mechanism

Only proceed if Task 1's verdict was yes.

**Files:**
- Create: `infra/registry/create-base-image-tasks.ps1`
- Test: `infra/registry/tests/create-base-image-tasks.Tests.ps1`

**Interfaces:**
- Consumes: `loginServer` from Task 3.
- Produces: one ACR Task per app image, each rebuilding when its base is patched.

- [ ] **Step 1: Write the failing test**

Create `infra/registry/tests/create-base-image-tasks.Tests.ps1`:

```powershell
BeforeAll {
    $env:MLS_SKIP_MAIN = '1'
    . (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'create-base-image-tasks.ps1')
}

Describe 'create-base-image-tasks' {
    BeforeEach {
        $script:AzCalls = [System.Collections.Generic.List[string]]::new()
        Mock Invoke-AcrCli { $script:AzCalls.Add($Argument -join ' '); return '{}' }
    }

    It 'creates one task per app with the base-image trigger enabled' {
        Invoke-Main -Registry 'mlsdemoacr' -App @('mcp-tools', 'data-api')
        @($script:AzCalls | Where-Object { $_ -like 'acr task create*' }).Count | Should -Be 2
        @($script:AzCalls | Where-Object { $_ -like '*--base-image-trigger-enabled true*' }).Count | Should -Be 2
    }

    It 'never enables the admin user, which would be a shared credential' {
        Invoke-Main -Registry 'mlsdemoacr' -App @('mcp-tools')
        @($script:AzCalls | Where-Object { $_ -like '*admin-enabled true*' }) | Should -BeNullOrEmpty
    }

    It 'is idempotent: an existing task is updated, not duplicated' {
        Mock Invoke-AcrCli {
            $script:AzCalls.Add($Argument -join ' ')
            if (($Argument -join ' ') -like 'acr task show*') { return '{"name":"mcp-tools-base"}' }
            return '{}'
        }
        Invoke-Main -Registry 'mlsdemoacr' -App @('mcp-tools')
        @($script:AzCalls | Where-Object { $_ -like 'acr task create*' }) | Should -BeNullOrEmpty
        @($script:AzCalls | Where-Object { $_ -like 'acr task update*' }).Count | Should -Be 1
    }
}
```

- [ ] **Step 2: Run it and watch it fail**

Run:
```bash
pwsh -NoProfile -Command "Invoke-Pester -Path infra/registry/tests/create-base-image-tasks.Tests.ps1 -Output Detailed"
```
Expected: FAIL — `create-base-image-tasks.ps1` does not exist.

- [ ] **Step 3: Write the script**

Create `infra/registry/create-base-image-tasks.ps1`:

```powershell
#Requires -Version 7.0
<#
.SYNOPSIS
    Creates one ACR Task per app image, each rebuilding when its upstream base is patched.
.DESCRIPTION
    Lane 3 of the self-healing design. The app Dockerfiles use floating tags
    (nginx:1.31-alpine, node:24-*), and their CVEs are OS packages INSIDE the image whose
    fix ships when upstream rebuilds the same tag. No version string we control changes, so
    Dependabot correctly opens nothing - see the design's section 2. ACR Tasks watch the
    base and rebuild, which is the first-party mechanism for exactly this.
.PARAMETER Registry
    The ACR name, without the .azurecr.io suffix.
.PARAMETER App
    App slugs to create tasks for.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$Registry,
    [string[]]$App = @('mcp-tools', 'data-api', 'control-tower', 'launch-ops', 'compliance'),
    [string]$RepositoryUrl = 'https://github.com/paulcfuqua/azure-devsecops-demo.git'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-AcrCli {
    param([Parameter(Mandatory)][string[]]$Argument)
    $out = & az @Argument 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    return ($out | Out-String).Trim()
}

function Invoke-Main {
    param(
        [Parameter(Mandatory)][string]$Registry,
        [string[]]$App,
        [string]$RepositoryUrl = 'https://github.com/paulcfuqua/azure-devsecops-demo.git'
    )
    foreach ($slug in $App) {
        $taskName = "$slug-base"
        $existing = Invoke-AcrCli -Argument @('acr', 'task', 'show', '--registry', $Registry, '--name', $taskName, '-o', 'json')
        $verb = if ([string]::IsNullOrWhiteSpace($existing)) { 'create' } else { 'update' }

        # --base-image-trigger-type All: rebuild on any base change, not only on a tag move.
        # A patched-in-place tag is precisely the case Dependabot cannot see.
        $argument = @(
            'acr', 'task', $verb,
            '--registry', $Registry,
            '--name', $taskName,
            '--image', "${slug}:{{.Run.ID}}",
            '--context', "$RepositoryUrl#main:apps/$slug",
            '--file', 'Dockerfile',
            '--base-image-trigger-enabled', 'true',
            '--base-image-trigger-type', 'All',
            '--commit-trigger-enabled', 'false',
            '-o', 'json'
        )
        if ($PSCmdlet.ShouldProcess($taskName, "acr task $verb")) {
            Invoke-AcrCli -Argument $argument | Out-Null
        }
        Write-Host "$verb task $taskName for $slug"
    }
}

if (-not $env:MLS_SKIP_MAIN) {
    Invoke-Main -Registry $Registry -App $App -RepositoryUrl $RepositoryUrl
}
```

- [ ] **Step 4: Run the tests**

Run:
```bash
pwsh -NoProfile -Command "Invoke-Pester -Path infra/registry/tests/create-base-image-tasks.Tests.ps1 -Output Detailed"
```
Expected: 3 passed.

- [ ] **Step 5: Run the analyzer**

```bash
pwsh -NoProfile -Command "Invoke-ScriptAnalyzer -Path infra/registry -Recurse -Severity Error,Warning"
```
Expected: no output.

- [ ] **Step 6: Create the tasks for real, and prove one fires**

```bash
pwsh -NoProfile -File infra/registry/create-base-image-tasks.ps1 -Registry "${LOGIN%%.*}"
az acr task list --registry "${LOGIN%%.*}" -o table
az acr task run --registry "${LOGIN%%.*}" --name mcp-tools-base
az acr task list-runs --registry "${LOGIN%%.*}" --name mcp-tools-base -o table
```
Expected: the manual run succeeds and produces an image. **The trigger firing on a real upstream patch cannot be forced** — record that it is unproven until observed, rather than claiming it works.

- [ ] **Step 7: Commit**

```bash
git add infra/registry/
git commit -m "infra(registry): ACR Tasks rebuild each app image when its base is patched"
```

---

### Task 8: Prove the registry survives a teardown and rebuild

The spec's P2 is only closed by doing this. Everything before this task is an argument; this is the evidence.

**Files:**
- Modify: `verification/layer-11-audit.ps1` (a new criterion)
- Test: `verification/tests/layer-11-audit.Tests.ps1`

**Interfaces:**
- Consumes: the registry from Task 3.
- Produces: V11.6, asserting the registry outlived a teardown.

- [ ] **Step 1: Write the failing test**

Add to `verification/tests/layer-11-audit.Tests.ps1`:

```powershell
Context 'V11.6: the registry the rebuild depends on outlived the teardown' {
    It 'passes when the registry still exists after teardown' {
        $script:RegistryExists = $true
        (Get-Row -Context (Invoke-AuditForTest -NoRetry) -Id 'V11.6').Status | Should -Be 'PASS'
    }

    It 'FAILS when teardown removed the registry, because the rebuild cannot then proceed' {
        $script:RegistryExists = $false
        $row = Get-Row -Context (Invoke-AuditForTest -NoRetry) -Id 'V11.6'
        $row.Status | Should -Be 'FAIL'
        $row.Observed | Should -BeLike '*rebuild cannot pull*'
    }
}
```

- [ ] **Step 2: Run it and watch it fail**

Run:
```bash
pwsh -NoProfile -Command "Invoke-Pester -Path verification/tests/layer-11-audit.Tests.ps1 -Output Detailed"
```
Expected: FAIL — V11.6 does not exist.

- [ ] **Step 3: Implement the criterion**

In `verification/layer-11-audit.ps1`:

```powershell
function Test-RegistrySurvivedTeardown {
    <#
    .SYNOPSIS
        V11.6 - the container registry the apps pull from still exists after a teardown.
    .DESCRIPTION
        BLOCKER-E's shape, and worse. The Fabric capacity in a teardown-deleted group merely
        stranded a workspace; a registry in one makes the REBUILD IMPOSSIBLE, because the
        apps pull from it - the estate would depend on a resource that only exists after the
        estate exists. This criterion is the evidence, not the argument.
    #>
    param([Parameter(Mandatory)][string]$RegistryResourceGroup)
    $registry = Invoke-MlsAz -AllowFailure -Argument @(
        'acr', 'list', '--resource-group', $RegistryResourceGroup, '--query', '[].name', '--output', 'json'
    )
    if ($null -eq $registry) {
        return New-MlsCheckResult -Status SKIP `
            -Observed "cannot read resource group '$RegistryResourceGroup' as this identity, so registry survival is unobservable" `
            -Detail 'Not evidence the registry is absent. Re-run with a login that can list registries (the F63/F105 rule).'
    }
    $names = @($registry)
    if ($names.Count -eq 0) {
        return New-MlsCheckResult -Passed $false -Final `
            -Observed "no registry remains in '$RegistryResourceGroup' after teardown, so the rebuild cannot pull any app image" `
            -Detail 'The registry must live outside the four resource groups infra-down.yml deletes. See the ACR foundation plan, task 3.'
    }
    return New-MlsCheckResult -Passed $true -Observed "$($names.Count) registry survived teardown in '$RegistryResourceGroup': $($names -join ', ')"
}
```

Add the parameter it reads, beside the script's other inputs in `layer-11-audit.ps1`'s
top-level `param()` block and in `Invoke-Main`'s:

```powershell
    [string]$RegistryResourceGroupName,
```

and resolve it in `Invoke-Main` the way the other inputs are resolved:

```powershell
    $registryResourceGroup = Resolve-MlsInput -Name 'RegistryResourceGroupName' `
        -Value $RegistryResourceGroupName -EnvironmentVariable @('MLS_REGISTRY_RG') `
        -DefaultValue "$($env:MLS_COMPANY_PREFIX ?? 'mls')-rg-registry" `
        -Hint 'The resource group holding the container registry - deliberately outside the four the teardown deletes.'
```

Register the criterion beside the other L11 ones:

```powershell
    Invoke-MlsCriterion -Context $context -Id 'V11.6' -Control @('3.4.1') `
        -Description 'The container registry the apps pull from outlived the teardown' `
        -Command "az acr list --resource-group $registryResourceGroup --query '[].name'" `
        -Expected 'at least one registry still present after the four demo resource groups were deleted' -NoRetry `
        -Test { Test-RegistrySurvivedTeardown -RegistryResourceGroup $registryResourceGroup } | Out-Null
```

- [ ] **Step 4: Run the tests**

Run:
```bash
pwsh -NoProfile -Command "Invoke-Pester -Path verification/tests/layer-11-audit.Tests.ps1 -Output Detailed"
```
Expected: both new tests pass, and every pre-existing L11 test still passes.

- [ ] **Step 5: Run the full suite and the analyzer**

```bash
pwsh -NoProfile -Command "Invoke-Pester -Path scripts,infra,data,verification,compliance -Output None -PassThru | Select-Object PassedCount,FailedCount"
pwsh -NoProfile -Command "Invoke-ScriptAnalyzer -Path scripts,infra,verification,data,compliance,.github -Recurse -Severity Error,Warning"
```
Expected: 0 failed, 0 analyzer findings. The full suite takes about 180 seconds.

- [ ] **Step 6: Do the real teardown and rebuild**

This is the only step that closes P2.

```bash
gh workflow run infra-down.yml && gh run watch $(gh run list --workflow infra-down.yml --limit 1 --json databaseId --jq '.[0].databaseId')
az acr list -o table   # the registry MUST still be here
gh workflow run infra-up.yml && gh run watch $(gh run list --workflow infra-up.yml --limit 1 --json databaseId --jq '.[0].databaseId')
```

Expected: the registry survives the teardown, and the rebuild's apps pull from it without a fresh image build. If the registry is gone, **stop** — the placement is wrong and Task 3 needs correcting before anything else proceeds.

- [ ] **Step 7: Commit**

```bash
git add verification/layer-11-audit.ps1 verification/tests/layer-11-audit.Tests.ps1
git commit -m "verify(V11.6): the registry the rebuild depends on outlived the teardown"
```

---

## What this plan does NOT cover

Deliberately, so the next plans have clean boundaries:

- **Plan 2 — lane automation and the change window.** The three lanes, batched adoption, the window in git, the Ops-tab display.
- **Plan 3 — the trail and the criteria.** V10.1–V10.4, the Sec-tab trail view, retiring the seeded-alert model, and the L10 playbook rewrite.

Nothing here removes the vuln-lab or changes V10.1. The plants stay until Plan 3, so the estate is never in a state where the old verification is gone and the new one has not arrived.
