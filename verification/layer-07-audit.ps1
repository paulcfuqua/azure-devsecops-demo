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
    [switch]$NoRetry
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

function Test-OtelSpan {
    <# V7.3 - one tagged synthetic request per app (a read, permitted to the Verifier),
       then look for it in App Insights via KQL. #>
    param(
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string[]]$AppName,
        [Parameter(Mandatory)][string]$HealthPath,
        [AllowEmptyString()][string]$WorkspaceId,
        [Parameter(Mandatory)][string]$ProbeId
    )
    if ([string]::IsNullOrWhiteSpace($WorkspaceId)) {
        return New-MlsCheckResult -Passed $false -Observed 'no Log Analytics workspace (customer) id available' -Final `
            -Detail 'Pass -LogAnalyticsWorkspaceId / $env:MLS_LAW_CUSTOMER_ID (the L6 deployment output).'
    }
    $problem = [System.Collections.Generic.List[string]]::new()
    $observed = [System.Collections.Generic.List[string]]::new()
    foreach ($name in $AppName) {
        $fqdn = Get-AppFqdn -ResourceGroupName $ResourceGroupName -Name $name
        if ([string]::IsNullOrWhiteSpace($fqdn)) {
            $problem.Add("$name has no ingress FQDN")
            continue
        }
        Invoke-MlsHttp -Uri "https://$fqdn$HealthPath`?probe=$ProbeId" -TimeoutSec 60 | Out-Null
    }
    $query = "AppRequests | where Url has 'probe=$ProbeId' | project TimeGenerated, AppRoleName, OperationId"
    $rows = @(Invoke-MlsAz -AllowFailure -Argument @(
            'monitor', 'log-analytics', 'query', '--workspace', $WorkspaceId,
            '--analytics-query', $query, '--timespan', 'PT1H', '--output', 'json'
        ))
    foreach ($name in $AppName) {
        $roleName = ($name -replace '^mls-', '') -replace '-demo-ca$', ''
        $matched = @($rows | Where-Object { "$(Get-MlsProperty -InputObject $_ -Name 'AppRoleName')" -like "*$roleName*" })
        $observed.Add("$roleName rows=$($matched.Count)")
        if ($matched.Count -lt 1) { $problem.Add("no AppRequests row carrying probe=$ProbeId for AppRoleName ~ '$roleName'") }
    }
    if ($problem.Count -eq 0) {
        return New-MlsCheckResult -Passed $true -Observed ($observed -join '; ')
    }
    return New-MlsCheckResult -Passed $false -Observed (($observed -join '; ') + ' | ' + ($problem -join ' | ')) `
        -Detail 'App Insights ingestion latency is typically 2-10 minutes; the standard 30-minute window covers it. Persistent emptiness means the connection string is not injected or sampling is 0 (L07 failure mode 3).'
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
    $notSuccess = @($checkRuns | Where-Object { "$(Get-MlsProperty -InputObject $_ -Name 'conclusion')" -ne 'success' } |
            ForEach-Object { "$(Get-MlsProperty -InputObject $_ -Name 'name')=$(Get-MlsProperty -InputObject $_ -Name 'conclusion')" })
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
        -Observed "$($conclusion.Count) check run(s) on #$PullRequestNumber all success; paths touched: $($path -join ', ')"
}

function Test-ReplicaScaling {
    <# V7.5 - three phases per app: 0 before load, >= 1 under load, back to 0 after the
       idle window. Phase 3 waits 15 minutes before the first read; a nonzero count at
       +30 minutes is a FAIL (idle-cost model broken). #>
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
        $phaseOne = [int](Invoke-MlsAz -AllowFailure -Raw -Argument @(
                'containerapp', 'replica', 'list', '--resource-group', $ResourceGroupName, '--name', $name,
                '--query', 'length(@)', '--output', 'tsv'
            ))
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
        $observed.Add("$name 0->N->0 observed as $phaseOne->$phaseTwo->$phaseThree (phase 3 at +$waited min)")
        if ($phaseOne -ne 0) { $problem.Add("$name had $phaseOne replica(s) before load, expected 0") }
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
        [string]$DeployManifestPath,
        [string]$LogAnalyticsWorkspaceId,
        [string]$Repository,
        [string]$CanaryPrNumber,
        [string]$HealthPath = '/healthz',
        [int]$LoadRequestCount = 20,
        [double]$ScaleInWaitMinutes = 15,
        [double]$ScaleInDeadlineMinutes = 30,
        [string]$ReportRoot,
        [switch]$NoRetry
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
        -ScriptName 'verification/layer-07-audit.ps1' -ReportRoot $ReportRoot -NoRetry:$NoRetry
    Add-MlsPreflight -Context $context -Name 'Resource group' -Value $ResourceGroupName
    Add-MlsPreflight -Context $context -Name 'Apps' -Value ($AppName -join ', ')
    Add-MlsPreflight -Context $context -Name 'Deploy manifest' -Value "$manifestPath" -Status $(if ($manifest) { 'OK' } else { 'ABSENT' })
    Add-MlsPreflight -Context $context -Name 'LAW customer id' -Value "$workspaceId" -Status $(if ($workspaceId) { 'OK' } else { 'ABSENT' })
    Add-MlsPreflight -Context $context -Name 'Canary PR' -Value "$canary" -Status $(if ($canary) { 'OK' } else { 'ABSENT' })
    Add-MlsPreflight -Context $context -Name 'Probe marker' -Value $probeId
    Add-MlsNote -Context $context -Message 'The control tower''s Ask tab ships dark at L7 and is deliberately not part of any L7 criterion, so a dark tab cannot fail this layer (L07.md Purpose).'

    Invoke-MlsCriterion -Context $context -Id 'V7.1' `
        -Description 'Public endpoints return 200 with correct content hash markers' `
        -Command "az containerapp show -g $ResourceGroupName -n <app> --query properties.configuration.ingress.fqdn -o tsv`nGET https://<fqdn>$HealthPath" `
        -Expected 'HTTP 200 from both apps; health payload content-hash marker equals the image digest recorded in the deploy run' `
        -PollIntervalSeconds 60 `
        -Test { Test-PublicEndpoint -ResourceGroupName $ResourceGroupName -AppName $AppName -HealthPath $HealthPath -Manifest $manifest } | Out-Null

    Invoke-MlsCriterion -Context $context -Id 'V7.2' `
        -Description 'Renderer schema validation passes on golden specs' `
        -Command 'npm --prefix apps/shared/spec-renderer run validate:golden' `
        -Expected 'exit 0; every golden spec valid against the component-spec JSON Schema' -NoRetry `
        -Test { Test-GoldenSpec -RepoRoot $repoRoot } | Out-Null

    Invoke-MlsCriterion -Context $context -Id 'V7.3' `
        -Description 'OTel spans from a synthetic request visible in App Insights via KQL' `
        -Command "GET https://<fqdn>$HealthPath`?probe=$probeId   # one per app`naz monitor log-analytics query --workspace <lawCustomerId> --analytics-query `"AppRequests | where Url has 'probe=$probeId' | project TimeGenerated, AppRoleName, OperationId`" --timespan PT1H" `
        -Expected '>= 1 AppRequests row per app carrying the probe marker, with AppRoleName matching the app name from naming.bicep' `
        -Test {
        Test-OtelSpan -ResourceGroupName $ResourceGroupName -AppName $AppName -HealthPath $HealthPath `
            -WorkspaceId $workspaceId -ProbeId $probeId
    } | Out-Null

    Invoke-MlsCriterion -Context $context -Id 'V7.4' `
        -Description 'Per-app CI green on a canary PR' `
        -Command "gh pr view <canary-pr> --json number,headRefOid,files,state`ngh api repos/$repositoryName/commits/<canary-sha>/check-runs" `
        -Expected 'every required check concludes success; path filters fire for the touched app(s) only' `
        -Test { Test-CanaryPipeline -Repository $repositoryName -PullRequestNumber $canary } | Out-Null

    Invoke-MlsCriterion -Context $context -Id 'V7.5' `
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
            -ScaleInDeadlineMinutes $ScaleInDeadlineMinutes -ReportRoot $ReportRoot -NoRetry:$NoRetry
    }
    catch {
        Write-MlsStatus -Message "layer-07-audit could not start: $($_.Exception.Message)" -Color Red
        exit 2
    }
    $reportFile = Write-MlsReport -Context $auditContext
    Write-MlsStatus -Message "report: $($reportFile.MarkdownPath)"
    exit (Get-MlsExitCode -Context $auditContext)
}
