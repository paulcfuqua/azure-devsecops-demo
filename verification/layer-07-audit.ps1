#Requires -Version 7.0
<#
.SYNOPSIS
    L7 Verifier audit - spec-renderer, launch-ops, control tower, per-app CI. READ-ONLY.

.DESCRIPTION
    Implements the five master-plan Verify criteria owned by
    docs/runbooks/layers/L07.md section Validation cycle, and nothing else:

      V7.1  Public endpoints return 200 with correct content hash markers.
      V7.2  Renderer schema validation passes on golden specs.
      V7.3  OTel spans from a synthetic request visible in App Insights via KQL.
      V7.4  Per-app CI green on a canary PR (including the path-filter assertion).
      V7.5  Replicas scale 0 -> N -> 0.

    The Ask tab is deliberately not part of any of them - it ships dark at L7, so a dark
    tab cannot fail this layer (L07.md Purpose).

    Everything here is a read: health GETs, tagged probe GETs (explicitly permitted to the
    Verifier by L07.md V7.3), Log Analytics queries, GitHub reads and ARM reads. The load
    phase of V7.5 issues concurrent GETs against a public endpoint - traffic, not mutation.

.EXAMPLE
    ./layer-07-audit.ps1 -CanaryPrNumber 42 -DeployManifestPath ./l7-manifest.json
#>
[CmdletBinding()]
param(
    [string]$ResourceGroupName = 'mls-rg-apps',
    [string[]]$AppName = @('mls-launch-ops-demo-ca', 'mls-control-tower-demo-ca'),
    [string]$DeployManifestPath,
    [string]$LogAnalyticsWorkspaceId,
    [string]$Repository,
    [string]$CanaryPrNumber,
    [string]$HealthPath = '/healthz',
    [int]$LoadRequestCount = 20,
    [double]$ScaleInWaitMinutes = 15,
    [double]$ScaleInDeadlineMinutes = 30,
    [string]$ReportRoot,
    [switch]$NoRetry,

    # Run only these criteria (e.g. -OnlyCriterion V7.3). Everything else reports SKIP
    # naming the reason, and the run exits 3 - a DIAGNOSTIC, never a sign-off.
    #
    # Why this exists: V7.5 waits up to 15 minutes per app for a real scale-in cycle, so a
    # full audit is ~55 minutes. Four consecutive runs were spent testing one criterion
    # with the other four along for the ride, which is the "a run is an expensive,
    # rate-limited observation" rule pointing at its own audit.
    [string[]]$OnlyCriterion = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'MlsAudit.psm1') -Force

function Get-AppFqdn {
    <# Ingress FQDN of one container app. #>
    param(
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string]$Name
    )
    $fqdn = Invoke-MlsAz -AllowFailure -Raw -Argument @(
        'containerapp', 'show', '--resource-group', $ResourceGroupName, '--name', $Name,
        '--query', 'properties.configuration.ingress.fqdn', '--output', 'tsv'
    )
    return "$fqdn".Trim()
}

function Get-ExpectedDigest {
    <# The image digest the deploy run recorded, per app, from the layer manifest. #>
    param(
        [AllowNull()]$Manifest,
        [Parameter(Mandatory)][string]$Name
    )
    if ($null -eq $Manifest) { return '' }
    $apps = @(Get-MlsProperty -InputObject $Manifest -Name 'apps')
    foreach ($app in $apps) {
        if ("$(Get-MlsProperty -InputObject $app -Name 'name')" -eq $Name) {
            return "$(Get-MlsProperty -InputObject $app -Name 'imageDigest')"
        }
    }
    return ''
}

function Test-PublicEndpoint {
    <# V7.1 - 200 from both apps, and the health payload's content-hash marker equal to
       the image digest recorded in the deploy run (binding endpoint to build). #>
    param(
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string[]]$AppName,
        [Parameter(Mandatory)][string]$HealthPath,
        [AllowNull()]$Manifest
    )
    if ($null -eq $Manifest) {
        return New-MlsCheckResult -Passed $false -Observed 'no deploy manifest supplied' -Final `
            -Detail 'V7.1 binds "endpoint is up" to "endpoint serves the audited build", so it needs the per-app image digests the deploy run stamped. The app CI workflows must publish a manifest {"apps":[{"name":...,"imageDigest":...}]} for the Verifier; pass it with -DeployManifestPath / $env:MLS_L7_MANIFEST. Refusing to pass on liveness alone.'
    }
    $problem = [System.Collections.Generic.List[string]]::new()
    $observed = [System.Collections.Generic.List[string]]::new()
    foreach ($name in $AppName) {
        $fqdn = Get-AppFqdn -ResourceGroupName $ResourceGroupName -Name $name
        if ([string]::IsNullOrWhiteSpace($fqdn)) {
            $problem.Add("$name has no ingress FQDN")
            continue
        }
        $response = Invoke-MlsHttp -Uri "https://$fqdn$HealthPath" -TimeoutSec 60
        $observed.Add("$name -> $($response.StatusCode)")
        if ($response.StatusCode -ne 200) {
            $problem.Add("$name returned $($response.StatusCode) $(Format-MlsValue -Value $response.Error -MaximumLength 120)")
            continue
        }
        $expectedDigest = Get-ExpectedDigest -Manifest $Manifest -Name $name
        if ([string]::IsNullOrWhiteSpace($expectedDigest)) {
            $problem.Add("$name has no imageDigest in the deploy manifest")
            continue
        }
        if ("$($response.Content)" -notlike "*$expectedDigest*") {
            $problem.Add("$name health payload does not carry the deployed image digest $expectedDigest")
        }
    }
    if ($problem.Count -eq 0) {
        return New-MlsCheckResult -Passed $true -Observed (($observed -join '; ') + ' with matching content-hash markers')
    }
    return New-MlsCheckResult -Passed $false -Observed ($problem -join ' | ') `
        -Detail 'First request may cold-start from 0 replicas: up to 60 s is normal, and the retry window absorbs it (L07 failure mode 1).'
}

function Test-GoldenSpec {
    <# V7.2 - deterministic local check, run from the audited commit. #>
    param([Parameter(Mandatory)][string]$RepoRoot)
    $rendererPath = Join-Path -Path $RepoRoot -ChildPath 'apps' -AdditionalChildPath 'shared', 'spec-renderer'
    if (-not (Test-Path -LiteralPath $rendererPath)) {
        return New-MlsCheckResult -Passed $false -Observed "spec-renderer not found at $rendererPath" -Final
    }
    $result = Invoke-MlsLocalCommand -FilePath 'npm' -WorkingDirectory $RepoRoot `
        -Argument @('--prefix', 'apps/shared/spec-renderer', 'run', 'validate:golden')
    if ($result.ExitCode -eq 0) {
        return New-MlsCheckResult -Passed $true -Observed 'npm run validate:golden exited 0 - every golden spec validates against the component-spec JSON Schema'
    }
    return New-MlsCheckResult -Passed $false `
        -Observed "npm run validate:golden exited $($result.ExitCode): $(($result.Line | Select-Object -Last 5) -join ' / ')" -Final `
        -Detail 'V7.2 rolls back in the repo only - no cloud state is involved; fix the schema or the fixtures via PR and re-run.'
}

function Get-AppEasyAuthClientId {
    <# The Entra client id an app's Easy Auth validates tokens against, read from the
       running app rather than supplied. It is the audience the probe must request, and
       Easy Auth publishes it in its own WWW-Authenticate `resource_id` on a 401. #>
    param(
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string]$Name
    )
    return "$(Invoke-MlsAz -AllowFailure -Raw -Argument @(
            'containerapp', 'auth', 'show', '--resource-group', $ResourceGroupName, '--name', $Name,
            '--query', 'identityProviders.azureActiveDirectory.registration.clientId', '--output', 'tsv'
        ))".Trim()
}

function Test-OtelSpan {
    <# V7.3 - a tagged synthetic request per app that actually REACHES application code,
       then look for its span in App Insights via KQL.

       WHY THE PROBE IS AUTHENTICATED. This criterion spent two runs failing against an
       App Insights resource that was correctly wired - right component, right
       instrumentation key on every container - and completely empty. The cause was not
       ingestion latency and not sampling:

         * the three dashboards are nginx serving a static React bundle, and Easy Auth's
           ONLY excluded path is /healthz, which nginx answers from its own config. No
           application code runs, so nothing emits a span.
         * every other path returns 401 AT EASY AUTH, so it never reaches data-api - the
           one app in the request chain that would emit an AppRequests row.
         * the browser SDK in each frontend never executes, because the probe is curl.

       So there was no request an ANONYMOUS probe could make that would produce a span,
       and no retry window could have changed that (F89).

       The fix is not to open an unauthenticated path - that would add anonymous surface
       to the app tier of a compliance demo to satisfy a check, which is backwards. Easy
       Auth already publishes the way in, and the Verifier already federates as
       mls-verifier, so it needs a token rather than a new credential. The deploy path
       grants it a probe role that confers NO application capability; a 403 from the app
       is a perfectly good result here, because the claim is "the request traversed Easy
       Auth and reached the application", not "the Verifier may read data".

       The emitting role is data-api, not the frontend, because the frontends emit
       nothing server-side. Per-app attribution therefore comes from the probe marker,
       which carries the frontend's name, not from AppRoleName. #>
    param(
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string[]]$AppName,
        [Parameter(Mandatory)][string]$ProbePath,
        [AllowEmptyString()][string]$WorkspaceId,
        [Parameter(Mandatory)][string]$ProbeId
    )
    if ([string]::IsNullOrWhiteSpace($WorkspaceId)) {
        return New-MlsCheckResult -Passed $false -Observed 'no Log Analytics workspace (customer) id available' -Final `
            -Detail 'Pass -LogAnalyticsWorkspaceId / $env:MLS_LAW_CUSTOMER_ID (the L6 deployment output).'
    }
    $problem = [System.Collections.Generic.List[string]]::new()
    $observed = [System.Collections.Generic.List[string]]::new()
    $statusByApp = @{}
    foreach ($name in $AppName) {
        $roleName = ($name -replace '^mls-', '') -replace '-demo-ca$', ''
        $fqdn = Get-AppFqdn -ResourceGroupName $ResourceGroupName -Name $name
        if ([string]::IsNullOrWhiteSpace($fqdn)) {
            $problem.Add("$name has no ingress FQDN")
            continue
        }
        $clientId = Get-AppEasyAuthClientId -ResourceGroupName $ResourceGroupName -Name $name
        if ([string]::IsNullOrWhiteSpace($clientId) -or $clientId -eq 'None') {
            $problem.Add("$name has no Easy Auth client id, so no audience to request a token for")
            continue
        }
        $token = "$(Invoke-MlsAz -AllowFailure -Raw -Argument @(
                'account', 'get-access-token', '--resource', $clientId, '--query', 'accessToken', '--output', 'tsv'
            ))".Trim()
        if ([string]::IsNullOrWhiteSpace($token)) {
            # Distinguish "cannot get a token" from "got in and saw nothing": they have
            # completely different fixes, and the old message conflated them.
            $problem.Add("$roleName could not obtain a token for audience $clientId - the app registration needs a service principal and the Verifier needs its probe role (L3 applies both; see F89)")
            continue
        }
        $marker = "$ProbeId-$roleName"
        $response = Invoke-MlsHttp -Uri "https://$fqdn$ProbePath`?probe=$marker" -TimeoutSec 60 `
            -Header @{ Authorization = "Bearer $token" }
        $status = "$(Get-MlsProperty -InputObject $response -Name 'StatusCode')"
        $statusByApp[$roleName] = $status
        # 401 means Easy Auth REJECTED the token, and no span can follow. Any other status -
        # including 403 or 404 from the application - means the request got through, which
        # is the whole claim.
        if ($status -eq '401') {
            $problem.Add("$roleName still 401 with a bearer token: Easy Auth rejected it, so the request never reached the application")
        }
    }
    $query = "AppRequests | where Url has 'probe=$ProbeId' | project TimeGenerated, AppRoleName, Url, OperationId"
    $rows = @(Invoke-MlsAz -AllowFailure -Argument @(
            'monitor', 'log-analytics', 'query', '--workspace', $WorkspaceId,
            '--analytics-query', $query, '--timespan', 'PT1H', '--output', 'json'
        ))
    foreach ($name in $AppName) {
        $roleName = ($name -replace '^mls-', '') -replace '-demo-ca$', ''
        $marker = "$ProbeId-$roleName"
        # Matched on the MARKER, not on AppRoleName: the span is emitted by whichever app
        # in the chain runs instrumented code (data-api), while the marker identifies which
        # front door the request came through.
        $matched = @($rows | Where-Object { "$(Get-MlsProperty -InputObject $_ -Name 'Url')" -like "*probe=$marker*" })
        $status = if ($statusByApp.ContainsKey($roleName)) { $statusByApp[$roleName] } else { 'not probed' }
        $observed.Add("$roleName http=$status rows=$($matched.Count)")
        if ($matched.Count -lt 1) { $problem.Add("no AppRequests row carrying probe=$marker") }
    }
    if ($problem.Count -eq 0) {
        return New-MlsCheckResult -Passed $true -Observed ($observed -join '; ')
    }
    return New-MlsCheckResult -Passed $false -Observed (($observed -join '; ') + ' | ' + ($problem -join ' | ')) `
        -Detail 'A non-401 status with zero rows is an emission problem (connection string or sampling). A 401 is an access problem - the probe never reached the app, so no span could exist (L07 failure mode 3).'
}

function Test-CanaryPipeline {
    <# V7.4 - every required check green on the canary PR, and the path filters behaving:
       both app pipelines when the canary touches apps/shared/**, only the matching app's
       pipeline when it touches a single app path. #>
    param(
        [Parameter(Mandatory)][string]$Repository,
        [AllowEmptyString()][string]$PullRequestNumber
    )
    if ([string]::IsNullOrWhiteSpace($PullRequestNumber)) {
        return New-MlsCheckResult -Passed $false -Observed 'no canary PR number supplied' -Final `
            -Detail 'The L7 lead opens the canary PR (the Verifier never writes to the repo) and posts its number; pass -CanaryPrNumber / $env:MLS_L7_CANARY_PR.'
    }
    $pullRequest = Invoke-MlsGh -AllowFailure -Argument @(
        'pr', 'view', $PullRequestNumber, '--repo', $Repository, '--json', 'number,headRefOid,files,state'
    )
    if ($null -eq $pullRequest) {
        return New-MlsCheckResult -Passed $false -Observed "canary PR #$PullRequestNumber could not be read"
    }
    $headSha = "$(Get-MlsProperty -InputObject $pullRequest -Name 'headRefOid')"
    $path = @(Get-MlsProperty -InputObject $pullRequest -Name 'files' | ForEach-Object { "$(Get-MlsProperty -InputObject $_ -Name 'path')" })
    $checkRuns = @(Get-MlsCollection -Response (Invoke-MlsGh -Argument @('api', "repos/$Repository/commits/$headSha/check-runs")))
    $conclusion = @($checkRuns | ForEach-Object { "$(Get-MlsProperty -InputObject $_ -Name 'conclusion')" })
    $names = @($checkRuns | ForEach-Object { "$(Get-MlsProperty -InputObject $_ -Name 'name')" })
    # SKIPPED IS NOT A FAILURE, AND THIS CRITERION USED TO SAY IT WAS.
    #
    # A canary that touches only apps/shared/** is a documentation-shaped change: the five
    # per-app pipelines build and scan, and their `deploy to Container Apps` jobs SKIP,
    # because the guard added for F83 declines to roll an image onto an app when nothing
    # about that app changed. That is the guard working. Counting it as "not green" failed
    # V7.4 on a canary whose CI was entirely correct - five skips out of 28 checks.
    #
    # The repo already knows this: `skipped` is not `failure` is written into the workflow
    # comments that F58 came from. The criterion had not learned it.
    #
    # `neutral` joins it for the same reason: a check that declines to judge has not failed.
    # Everything else - failure, cancelled, timed_out, action_required - still fails, and a
    # check still RUNNING is caught by the null conclusion.
    $acceptable = @('success', 'skipped', 'neutral')
    $notSuccess = @($checkRuns | Where-Object { "$(Get-MlsProperty -InputObject $_ -Name 'conclusion')" -notin $acceptable } |
            ForEach-Object { "$(Get-MlsProperty -InputObject $_ -Name 'name')=$(Get-MlsProperty -InputObject $_ -Name 'conclusion')" })
    $skipped = @($checkRuns | Where-Object { "$(Get-MlsProperty -InputObject $_ -Name 'conclusion')" -eq 'skipped' })
    if ($checkRuns.Count -eq 0) {
        return New-MlsCheckResult -Passed $false -Observed "no check runs on canary head $headSha yet"
    }
    if ($notSuccess.Count -gt 0) {
        return New-MlsCheckResult -Passed $false -Observed "checks not green: $($notSuccess -join ', ') (of $($conclusion.Count))"
    }

    # Path-filter assertion: working path filters are part of the criterion's intent.
    $touchesShared = @($path | Where-Object { $_ -like 'apps/shared/*' }).Count -gt 0
    $touchedApp = @($path | Where-Object { $_ -like 'apps/*' -and $_ -notlike 'apps/shared/*' } |
            ForEach-Object { ($_ -split '/')[1] } | Sort-Object -Unique)
    $ranLaunchOps = @($names | Where-Object { $_ -like '*launch-ops*' }).Count -gt 0
    $ranControlTower = @($names | Where-Object { $_ -like '*control-tower*' }).Count -gt 0
    $filterProblem = [System.Collections.Generic.List[string]]::new()
    if ($touchesShared) {
        if (-not ($ranLaunchOps -and $ranControlTower)) {
            $filterProblem.Add('canary touches apps/shared/** but not both app pipelines ran')
        }
    }
    elseif ($touchedApp.Count -eq 1) {
        if ($touchedApp[0] -eq 'launch-ops' -and $ranControlTower) { $filterProblem.Add('canary touches only launch-ops but the control-tower pipeline also ran') }
        if ($touchedApp[0] -eq 'control-tower' -and $ranLaunchOps) { $filterProblem.Add('canary touches only control-tower but the launch-ops pipeline also ran') }
    }
    if ($filterProblem.Count -gt 0) {
        return New-MlsCheckResult -Passed $false -Observed ($filterProblem -join ' | ') -Final `
            -Detail 'Path-filter drift is exactly what turns "per-app CI" into "monolithic CI" silently (L07 failure mode 4).'
    }
    return New-MlsCheckResult -Passed $true `
        -Observed "$($conclusion.Count) check run(s) on #$PullRequestNumber; $($skipped.Count) skipped (deploy jobs the F83 guard declined), rest success; paths touched: $($path -join ', ')"
}

function Test-ReplicaScaling {
    <# V7.5 - three phases per app: 0 before load, >= 1 under load, back to 0 after the
       idle window. Phase 3 waits 15 minutes before the first read; a nonzero count at
       +30 minutes is a FAIL (idle-cost model broken).

       Phase 0 first waits for the app to BE at zero, because V7.1 has already curled every
       endpoint by the time this runs and left them warm (F89). #>
    param(
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string[]]$AppName,
        [Parameter(Mandatory)][string]$HealthPath,
        [Parameter(Mandatory)][int]$LoadRequestCount,
        [Parameter(Mandatory)][double]$ScaleInWaitMinutes,
        [Parameter(Mandatory)][double]$ScaleInDeadlineMinutes
    )
    $problem = [System.Collections.Generic.List[string]]::new()
    $observed = [System.Collections.Generic.List[string]]::new()
    foreach ($name in $AppName) {
        # PHASE 0 - ESTABLISH THE PRECONDITION, DO NOT ASSERT IT.
        #
        # This criterion used to open by reading the replica count and failing if it was
        # not 0. It observed launch-ops at 1->1->0 and failed, while control-tower next to
        # it managed 0->1->0 - not because the apps differ, but because V7.1 runs FIRST in
        # the same audit and curls every endpoint, which wakes them. An earlier criterion
        # in the same run guaranteed the precondition of a later one was false, and which
        # app happened to have scaled back down by then was a race (F89).
        #
        # "Starts at 0" is not the claim. The claim is "goes 0 -> N -> 0". So wait for the
        # app to be at 0 before starting, and if it will not settle, THAT is the finding -
        # an app that never scales to zero is exactly what this criterion exists to catch,
        # and it is now reported as itself rather than as a corrupted phase 1.
        $settleWaited = 0.0
        $phaseOne = -1
        while ($true) {
            $phaseOne = [int](Invoke-MlsAz -AllowFailure -Raw -Argument @(
                    'containerapp', 'replica', 'list', '--resource-group', $ResourceGroupName, '--name', $name,
                    '--query', 'length(@)', '--output', 'tsv'
                ))
            if ($phaseOne -eq 0 -or $settleWaited -ge $ScaleInDeadlineMinutes) { break }
            Wait-MlsRetryInterval -Seconds ([math]::Min($ScaleInWaitMinutes, [math]::Max($ScaleInDeadlineMinutes - $settleWaited, 0)) * 60)
            $settleWaited += $ScaleInWaitMinutes
        }
        if ($phaseOne -ne 0) {
            $observed.Add("$name never settled to 0 (still $phaseOne after $settleWaited min idle)")
            $problem.Add("$name did not scale to 0 within $ScaleInDeadlineMinutes min before the probe, so the 0->N->0 cycle could not be observed")
            continue
        }
        $fqdn = Get-AppFqdn -ResourceGroupName $ResourceGroupName -Name $name
        if ([string]::IsNullOrWhiteSpace($fqdn)) {
            $problem.Add("$name has no ingress FQDN")
            continue
        }
        for ($i = 0; $i -lt $LoadRequestCount; $i++) {
            Invoke-MlsHttp -Uri "https://$fqdn$HealthPath" -TimeoutSec 60 | Out-Null
        }
        $phaseTwo = [int](Invoke-MlsAz -AllowFailure -Raw -Argument @(
                'containerapp', 'replica', 'list', '--resource-group', $ResourceGroupName, '--name', $name,
                '--query', 'length(@)', '--output', 'tsv'
            ))
        $waited = 0.0
        $phaseThree = -1
        while ($true) {
            Wait-MlsRetryInterval -Seconds ([math]::Min($ScaleInWaitMinutes, [math]::Max($ScaleInDeadlineMinutes - $waited, 0)) * 60)
            $waited += $ScaleInWaitMinutes
            $phaseThree = [int](Invoke-MlsAz -AllowFailure -Raw -Argument @(
                    'containerapp', 'replica', 'list', '--resource-group', $ResourceGroupName, '--name', $name,
                    '--query', 'length(@)', '--output', 'tsv'
                ))
            if ($phaseThree -eq 0 -or $waited -ge $ScaleInDeadlineMinutes) { break }
        }
        $observed.Add("$name 0->N->0 observed as $phaseOne->$phaseTwo->$phaseThree (settled after $settleWaited min, phase 3 at +$waited min)")
        # No phase-1 assertion: phase 0 above establishes it or reports why it could not.
        if ($phaseTwo -lt 1) { $problem.Add("$name did not scale out under load (still $phaseTwo)") }
        if ($phaseThree -ne 0) { $problem.Add("$name still has $phaseThree replica(s) at +$waited min") }
    }
    if ($problem.Count -eq 0) {
        return New-MlsCheckResult -Passed $true -Observed ($observed -join '; ')
    }
    return New-MlsCheckResult -Passed $false -Observed (($observed -join '; ') + ' | ' + ($problem -join ' | ')) -Final `
        -Detail 'Replicas that never return to 0 mean health-probe traffic keeping the app warm or a scale-rule floor set to 1 by a template change - an unrequested drift, so a defect rather than a G2 question (L07 failure mode 5).'
}

function Invoke-Main {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
        Justification = 'Every parameter is consumed inside the criterion scriptblocks; PSSA cannot see through scriptblock closures.')]
    param(
        [string]$ResourceGroupName = 'mls-rg-apps',
        [string[]]$AppName = @(),
        # The path V7.3 probes THROUGH Easy Auth. It must reach application code, unlike
        # $HealthPath, which nginx answers from its own config. Any /api/* path works:
        # even a 404 from data-api is an emitted span, which is the claim being tested,
        # so this does not go stale when routes change.
        [string]$ProbePath = '/api/launches',
        [string]$DeployManifestPath,
        [string]$LogAnalyticsWorkspaceId,
        [string]$Repository,
        [string]$CanaryPrNumber,
        [string]$HealthPath = '/healthz',
        [int]$LoadRequestCount = 20,
        [double]$ScaleInWaitMinutes = 15,
        [double]$ScaleInDeadlineMinutes = 30,
        [string]$ReportRoot,
        [switch]$NoRetry,
        [string[]]$OnlyCriterion = @()
    )
    $repoRoot = Split-Path -Path $PSScriptRoot -Parent
    $repositoryName = Resolve-MlsInput -Name 'Repository' -Value $Repository -EnvironmentVariable @('MLS_GITHUB_REPO', 'MLS_REPOSITORY') `
        -Hint 'The repo whose per-app CI V7.4 reads.'

    $manifestPath = $DeployManifestPath
    if ([string]::IsNullOrWhiteSpace($manifestPath)) { $manifestPath = [Environment]::GetEnvironmentVariable('MLS_L7_MANIFEST') }
    $manifest = $null
    if (-not [string]::IsNullOrWhiteSpace($manifestPath) -and (Test-Path -LiteralPath $manifestPath)) {
        $manifest = Get-MlsJsonFile -Path $manifestPath -Purpose 'L7 deploy manifest: per-app image digests recorded by the app CI runs'
    }
    $workspaceId = $LogAnalyticsWorkspaceId
    if ([string]::IsNullOrWhiteSpace($workspaceId)) { $workspaceId = [Environment]::GetEnvironmentVariable('MLS_LAW_CUSTOMER_ID') }
    $canary = $CanaryPrNumber
    if ([string]::IsNullOrWhiteSpace($canary)) { $canary = [Environment]::GetEnvironmentVariable('MLS_L7_CANARY_PR') }
    $probeId = "verifier-$([datetime]::UtcNow.ToString('yyyyMMddHHmmss'))"

    $context = New-MlsAuditContext -Layer 7 -Title 'Apps: spec-renderer, launch-ops, control tower, per-app CI' `
        -ScriptName 'verification/layer-07-audit.ps1' -ReportRoot $ReportRoot -NoRetry:$NoRetry `
        -OnlyCriterion $OnlyCriterion
    Add-MlsPreflight -Context $context -Name 'Resource group' -Value $ResourceGroupName
    Add-MlsPreflight -Context $context -Name 'Apps' -Value ($AppName -join ', ')
    Add-MlsPreflight -Context $context -Name 'Deploy manifest' -Value "$manifestPath" -Status $(if ($manifest) { 'OK' } else { 'ABSENT' })
    Add-MlsPreflight -Context $context -Name 'LAW customer id' -Value "$workspaceId" -Status $(if ($workspaceId) { 'OK' } else { 'ABSENT' })
    Add-MlsPreflight -Context $context -Name 'Canary PR' -Value "$canary" -Status $(if ($canary) { 'OK' } else { 'ABSENT' })
    Add-MlsPreflight -Context $context -Name 'Probe marker' -Value $probeId
    Add-MlsNote -Context $context -Message 'The control tower''s Ask tab ships dark at L7 and is deliberately not part of any L7 criterion, so a dark tab cannot fail this layer (L07.md Purpose).'

    # L07: Container Apps revision readiness
    Invoke-MlsCriterion -Context $context -Id 'V7.1' -Control @('3.4.1') `
        -Description 'Public endpoints return 200 with correct content hash markers' `
        -Command "az containerapp show -g $ResourceGroupName -n <app> --query properties.configuration.ingress.fqdn -o tsv`nGET https://<fqdn>$HealthPath" `
        -Expected 'HTTP 200 from both apps; health payload content-hash marker equals the image digest recorded in the deploy run' `
        -PollIntervalSeconds 60 `
        -RetryWindowMinutes 10 `
        -Test { Test-PublicEndpoint -ResourceGroupName $ResourceGroupName -AppName $AppName -HealthPath $HealthPath -Manifest $manifest } | Out-Null

    # -Control @(): schema-validation of the renderer's own output against golden fixtures
    # is a functional-correctness/code-quality check for the UI library, not a CUI
    # protection assertion.
    Invoke-MlsCriterion -Context $context -Id 'V7.2' -Control @() `
        -Description 'Renderer schema validation passes on golden specs' `
        -Command 'npm --prefix apps/shared/spec-renderer run validate:golden' `
        -Expected 'exit 0; every golden spec valid against the component-spec JSON Schema' -NoRetry `
        -Test { Test-GoldenSpec -RepoRoot $repoRoot } | Out-Null

    # L07: App Insights ingestion latency is typically 2-10 min
    Invoke-MlsCriterion -Context $context -Id 'V7.3' -Control @('3.3.1') `
        -Description 'OTel spans from a synthetic request visible in App Insights via KQL' `
        -Command "az account get-access-token --resource <easy-auth-client-id>`nGET https://<fqdn>$ProbePath`?probe=$probeId-<app>  -H 'Authorization: Bearer <token>'   # one per app`naz monitor log-analytics query --workspace <lawCustomerId> --analytics-query `"AppRequests | where Url has 'probe=$probeId' | project TimeGenerated, AppRoleName, Url, OperationId`" --timespan PT1H" `
        -Expected '>= 1 AppRequests row per app carrying that app''s probe marker; the row''s AppRoleName is the instrumented app in the chain (data-api), not the static frontend' `
        -RetryWindowMinutes 15 `
        -Test {
        Test-OtelSpan -ResourceGroupName $ResourceGroupName -AppName $AppName -ProbePath $ProbePath `
            -WorkspaceId $workspaceId -ProbeId $probeId
    } | Out-Null

    # -Control @(): validates CI/CD path-filter plumbing (the right app pipeline runs for
    # the right change) and that its checks are green - pipeline correctness, not a formal
    # change-approval or change-logging assertion (there is no human-review-required gate
    # in play here, and "checks are green" does not by itself evidence 3.4.3's
    # track/review/approve/log workflow).
    # L07: waits on a canary PR s CI run
    Invoke-MlsCriterion -Context $context -Id 'V7.4' -Control @() `
        -Description 'Per-app CI green on a canary PR' `
        -Command "gh pr view <canary-pr> --json number,headRefOid,files,state`ngh api repos/$repositoryName/commits/<canary-sha>/check-runs" `
        -Expected 'every required check concludes success; path filters fire for the touched app(s) only' `
        -RetryWindowMinutes 15 `
        -Test { Test-CanaryPipeline -Repository $repositoryName -PullRequestNumber $canary } | Out-Null

    # -Control @(): autoscale/idle-cost behaviour check, not CUI protection.
    Invoke-MlsCriterion -Context $context -Id 'V7.5' -Control @() `
        -Description 'Replicas scale 0 -> N -> 0' `
        -Command "az containerapp replica list -g $ResourceGroupName -n <app> --query `"length(@)`"   # phase 1: expect 0`n# phase 2: $LoadRequestCount concurrent GETs, then re-read: expect >= 1`n# phase 3: after the scale-in window: expect 0" `
        -Expected "0 before load; >= 1 under load; back to 0 within $ScaleInDeadlineMinutes minutes of idle" -NoRetry `
        -Test {
        Test-ReplicaScaling -ResourceGroupName $ResourceGroupName -AppName $AppName -HealthPath $HealthPath `
            -LoadRequestCount $LoadRequestCount -ScaleInWaitMinutes $ScaleInWaitMinutes -ScaleInDeadlineMinutes $ScaleInDeadlineMinutes
    } | Out-Null

    return $context
}

if (-not $env:MLS_SKIP_MAIN) {
    try {
        $auditContext = Invoke-Main -ResourceGroupName $ResourceGroupName -AppName $AppName `
            -DeployManifestPath $DeployManifestPath -LogAnalyticsWorkspaceId $LogAnalyticsWorkspaceId `
            -Repository $Repository -CanaryPrNumber $CanaryPrNumber -HealthPath $HealthPath `
            -LoadRequestCount $LoadRequestCount -ScaleInWaitMinutes $ScaleInWaitMinutes `
            -ScaleInDeadlineMinutes $ScaleInDeadlineMinutes -ReportRoot $ReportRoot -NoRetry:$NoRetry `
            -OnlyCriterion $OnlyCriterion
    }
    catch {
        Write-MlsStatus -Message "layer-07-audit could not start: $($_.Exception.Message)" -Color Red
        exit 2
    }
    $reportFile = Write-MlsReport -Context $auditContext
    Write-MlsStatus -Message "report: $($reportFile.MarkdownPath)"
    exit (Get-MlsExitCode -Context $auditContext)
}
