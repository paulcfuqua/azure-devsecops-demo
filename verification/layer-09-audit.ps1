#Requires -Version 7.0
<#
.SYNOPSIS
    L9 Verifier audit - the DevSecOps chain. READ-ONLY.

.DESCRIPTION
    Implements the five master-plan Verify criteria owned by
    docs/runbooks/layers/L09.md section Validation cycle, and nothing else:

      V9.1  GitHub API shows all GHAS features enabled.
      V9.2  A seeded CRITICAL image fails CI (negative test) then passes after pin.
      V9.3  SBOM artifact present + SPDX-valid.
      V9.4  ZAP report artifact exists with 0 High.
      V9.5  Defender plan toggles on -> off leaving state Off.

    GitHub is read with the Verifier's own read token (spec F8); Defender state is read
    with Reader. The Defender enable/disable round-trip itself is the deploy workflow's
    G2-gated action - this audit only observes its Activity Log trail, which is what
    proves the toggle was exercised rather than merely never-enabled.

.EXAMPLE
    ./layer-09-audit.ps1 -SubscriptionId <sub> -LayerRunId 123 -ReleaseTag v0.9.0 -ZapRunId 124
#>
[CmdletBinding()]
param(
    [string]$Repository,
    [string]$SubscriptionId,
    [string]$LayerRunId,
    [string]$ReleaseTag,
    [string]$ZapRunId,
    [string]$ZapArtifactName = 'zap-baseline-report',
    [string[]]$CodeQlLanguage = @('javascript-typescript', 'python'),
    [string]$DefenderPlanName = 'Containers',
    [string]$ActivityLogOffset = '6h',
    [string]$DownloadRoot,
    [string]$ReportRoot,
    [switch]$NoRetry,
    # Run only these criteria (e.g. -OnlyCriterion V9.2). Everything else reports SKIP
    # naming the reason, and the run exits 3 - a DIAGNOSTIC, never a sign-off (P-10).
    [string[]]$OnlyCriterion = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'MlsAudit.psm1') -Force

function Test-GhasFeature {
    <# V9.1 - secret scanning + push protection enabled, Dependabot alerts on (204 from
       the vulnerability-alerts endpoint), and a completed CodeQL analysis per language.

       "OFF" AND "I CANNOT SEE IT" ARE DIFFERENT ANSWERS, AND THIS CHECK USED TO CONFLATE
       THEM. `security_and_analysis` is returned only to a caller with ADMIN permission on
       the repository, and `GET /repos/{owner}/{repo}/vulnerability-alerts` needs admin
       too. The Verifier holds a deliberately read-only token, so both come back absent -
       and reading absent as disabled made V9.1 report

           secret_scanning='' push_protection='' | Dependabot alerts are off

       on a repository where all three were verifiably ENABLED (F103).

       A security audit announcing that a control is missing, when what happened is that it
       lacked the permission to look, is the worst answer this repository can produce. It
       is CLAUDE.md's capability-versus-artefact rule inverted: the check read a field's
       value without ever establishing it could observe the field at all. The same shape
       passing silently would be worse still - an auditor that cannot see a control must
       never be able to report it as present either.

       So an unobservable control is UNOBSERVABLE. It is reported, it is loud, and it does
       not pass: the criterion still fails, because "nobody checked" is not a sign-off.
       What changes is that the report says which of the two happened, and how to fix it -
       grant the Verifier's token repository admin, or accept the gap in writing. #>
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string[]]$CodeQlLanguage
    )
    $problem = [System.Collections.Generic.List[string]]::new()
    $observed = [System.Collections.Generic.List[string]]::new()
    $blind = [System.Collections.Generic.List[string]]::new()

    # NB: not $repository - PowerShell variable names are case-insensitive, so assigning to
    # it would overwrite the [string]$Repository parameter with a stringified response and
    # corrupt every later URL.
    $repositoryState = Invoke-MlsGh -Argument @('api', "repos/$Repository")
    $analysis = Get-MlsProperty -InputObject $repositoryState -Name 'security_and_analysis'
    if ($null -eq $analysis) {
        # The BLOCK is missing, not a field inside it. GitHub omits the whole object for a
        # non-admin caller; a genuinely disabled feature is present with status 'disabled'.
        # That distinction is the entire finding, and it is readable straight off the API.
        $blind.Add('security_and_analysis is absent from the repository response, so secret scanning and push protection could not be observed (the field is admin-only)')
        $observed.Add('secret_scanning=<not visible> push_protection=<not visible>')
    }
    else {
        $secretScanning = "$(Get-MlsProperty -InputObject (Get-MlsProperty -InputObject $analysis -Name 'secret_scanning') -Name 'status')"
        $pushProtection = "$(Get-MlsProperty -InputObject (Get-MlsProperty -InputObject $analysis -Name 'secret_scanning_push_protection') -Name 'status')"
        $observed.Add("secret_scanning=$secretScanning push_protection=$pushProtection")
        if ($secretScanning -ne 'enabled') { $problem.Add("secret_scanning.status='$secretScanning'") }
        if ($pushProtection -ne 'enabled') { $problem.Add("secret_scanning_push_protection.status='$pushProtection'") }
    }

    $alerts = Invoke-MlsGh -Raw -AllowFailure -Argument @('api', "repos/$Repository/vulnerability-alerts", '-i')
    $status = if ("$alerts" -match '(?m)^HTTP/[\d.]+\s+(\d{3})') { $Matches[1] } else { '' }
    # 204 = on. 404 = OFF, and GitHub documents that. 403 (and an empty response, which is
    # what a refused call leaves behind) mean the caller may not ask - not that it is off.
    if ($status -eq '204') {
        $observed.Add('vulnerability-alerts=204')
    }
    elseif ($status -eq '404') {
        $observed.Add('vulnerability-alerts=404')
        $problem.Add('the vulnerability-alerts endpoint answered 404 - Dependabot alerts are off')
    }
    else {
        $observed.Add("vulnerability-alerts=$(if ($status) { $status } else { '<no response>' })")
        $blind.Add("the vulnerability-alerts endpoint answered $(if ($status) { $status } else { 'nothing' }) rather than 204 or 404, so Dependabot alert state could not be observed (the endpoint is admin-only)")
    }

    $analyses = @(Invoke-MlsGh -AllowFailure -Argument @('api', "repos/$Repository/code-scanning/analyses"))
    $codeql = @($analyses | Where-Object {
            "$(Get-MlsProperty -InputObject (Get-MlsProperty -InputObject $_ -Name 'tool') -Name 'name')" -eq 'CodeQL'
        })
    $observed.Add("codeql analyses=$($codeql.Count)")
    foreach ($language in $CodeQlLanguage) {
        $forLanguage = @($codeql | Where-Object {
                "$(Get-MlsProperty -InputObject $_ -Name 'category')$(Get-MlsProperty -InputObject $_ -Name 'environment')" -like "*$language*"
            })
        if ($forLanguage.Count -eq 0) { $problem.Add("no completed CodeQL analysis for '$language'") }
    }

    if ($problem.Count -eq 0 -and $blind.Count -eq 0) {
        return New-MlsCheckResult -Passed $true -Observed ($observed -join '; ')
    }
    # Unobservable does not pass, and it does not masquerade as disabled either. Both lists
    # are reported; the detail names whichever fix the run actually needs.
    $detail = 'The first CodeQL analysis needs one workflow runtime (~10-20 min) inside the standard 30-minute window. A default-setup conflict blocks the advanced workflow entirely (L09 failure mode 1).'
    if ($blind.Count -gt 0) {
        $detail = "V9.1 could not OBSERVE part of the GHAS state - this is not the same as the state being off, and the report must never let the two read alike (F103). security_and_analysis and /vulnerability-alerts are both ADMIN-only, and the Verifier's token is read-only by contract. Either grant MLS_VERIFIER_GH_TOKEN repository admin (it remains read-only in effect - both are GET) or record the gap in writing and stop claiming V9.1 covers it. Confirm the real state out of band with: gh api repos/$Repository -q .security_and_analysis. $detail"
    }
    $reported = @($problem) + @($blind | ForEach-Object { "UNOBSERVABLE: $_" })
    return New-MlsCheckResult -Passed $false -Observed (($observed -join '; ') + ' | ' + ($reported -join ' | ')) `
        -Detail $detail
}

function Test-TrivyNegativeTest {
    <# V9.2 - both halves must be present: a gate that never fails is untested. #>
    param(
        [Parameter(Mandatory)][string]$Repository,
        [AllowEmptyString()][string]$RunId
    )
    if ([string]::IsNullOrWhiteSpace($RunId)) {
        return New-MlsCheckResult -Passed $false -Observed 'no layer-09 run id supplied' -Final `
            -Detail 'The DevSecOps lead posts the layer-09-devsecops.yml run id; pass -LayerRunId / $env:MLS_L9_RUN_ID. Without it the negative test cannot be located, and the audit will not assume it ran.'
    }
    $jobs = @(Get-MlsCollection -Response (Invoke-MlsGh -Argument @('api', "repos/$Repository/actions/runs/$RunId/jobs")))
    $negative = @($jobs | Where-Object { "$(Get-MlsProperty -InputObject $_ -Name 'name')" -like 'trivy-negative*' })
    $describe = @($negative | ForEach-Object { "$(Get-MlsProperty -InputObject $_ -Name 'name')=$(Get-MlsProperty -InputObject $_ -Name 'conclusion')" })
    $failHalf = @($negative | Where-Object { "$(Get-MlsProperty -InputObject $_ -Name 'name')" -like '*fail*' })
    $passHalf = @($negative | Where-Object { "$(Get-MlsProperty -InputObject $_ -Name 'name')" -like '*pass*' })
    $problem = [System.Collections.Generic.List[string]]::new()
    if ($failHalf.Count -eq 0) { $problem.Add('the trivy-negative-fail job (seeded CRITICAL asserted to fail the scan) is absent') }
    elseif ("$(Get-MlsProperty -InputObject $failHalf[0] -Name 'conclusion')" -ne 'success') { $problem.Add("trivy-negative-fail concluded '$(Get-MlsProperty -InputObject $failHalf[0] -Name 'conclusion')'") }
    if ($passHalf.Count -eq 0) { $problem.Add('the trivy-negative-pass job (pinned rebuild asserted to pass) is absent') }
    elseif ("$(Get-MlsProperty -InputObject $passHalf[0] -Name 'conclusion')" -ne 'success') { $problem.Add("trivy-negative-pass concluded '$(Get-MlsProperty -InputObject $passHalf[0] -Name 'conclusion')'") }
    if ($problem.Count -eq 0) {
        return New-MlsCheckResult -Passed $true -Observed ($describe -join '; ')
    }
    return New-MlsCheckResult -Passed $false -Observed (($describe -join '; ') + ' | ' + ($problem -join ' | ')) -Final `
        -Detail 'Both halves present is the criterion: the gate must be shown failing on the seeded CRITICAL and passing after the pin.'
}

function Test-SbomArtifact {
    <# V9.3 - one *.spdx.json per app on the release, and each one SPDX-valid. Uses the
       pinned validator when it is installed, otherwise structural validation in-process
       (the Verifier must not depend on fetching tooling at audit time). #>
    param(
        [Parameter(Mandatory)][string]$Repository,
        [AllowEmptyString()][string]$Tag,
        [Parameter(Mandatory)][string]$DownloadRoot
    )
    if ([string]::IsNullOrWhiteSpace($Tag)) {
        return New-MlsCheckResult -Passed $false -Observed 'no release tag supplied' -Final `
            -Detail 'SBOMs attach to the release created on tagged builds; pass -ReleaseTag / $env:MLS_L9_RELEASE_TAG.'
    }
    $release = Invoke-MlsGh -AllowFailure -Argument @('release', 'view', $Tag, '--repo', $Repository, '--json', 'assets')
    $assets = @(Get-MlsProperty -InputObject $release -Name 'assets' | ForEach-Object { "$(Get-MlsProperty -InputObject $_ -Name 'name')" })
    $spdxAssets = @($assets | Where-Object { $_ -like '*.spdx.json' })
    if ($spdxAssets.Count -eq 0) {
        return New-MlsCheckResult -Passed $false -Observed "release '$Tag' carries no *.spdx.json asset (assets: $($assets -join ', '))" -Final
    }
    $target = Join-Path -Path $DownloadRoot -ChildPath "sbom-$Tag"
    if (-not (Test-Path -LiteralPath $target)) { New-Item -ItemType Directory -Path $target -Force | Out-Null }
    Invoke-MlsGh -AllowFailure -Raw -Argument @('release', 'download', $Tag, '--repo', $Repository, '-p', '*.spdx.json', '-D', $target, '--clobber') | Out-Null
    $files = @(Get-ChildItem -Path $target -Filter '*.spdx.json' -File -ErrorAction SilentlyContinue)
    if ($files.Count -eq 0) {
        return New-MlsCheckResult -Passed $false -Observed "release '$Tag' lists $($spdxAssets.Count) SPDX asset(s) but none downloaded to $target"
    }
    $problem = [System.Collections.Generic.List[string]]::new()
    $observed = [System.Collections.Generic.List[string]]::new()
    $usedPinnedValidator = $false
    foreach ($file in $files) {
        if (Get-Command -Name 'pyspdxtools' -ErrorAction SilentlyContinue) {
            $usedPinnedValidator = $true
            $result = Invoke-MlsLocalCommand -FilePath 'pyspdxtools' -Argument @('-i', $file.FullName)
            $observed.Add("$($file.Name): pyspdxtools exit $($result.ExitCode)")
            if ($result.ExitCode -ne 0) { $problem.Add("$($file.Name) failed pyspdxtools: $(($result.Line | Select-Object -Last 2) -join ' / ')") }
            continue
        }
        $document = Get-MlsJsonFile -Path $file.FullName -Purpose 'SPDX SBOM attached to the release'
        $validation = Test-MlsSpdxDocument -Document $document
        $observed.Add("$($file.Name): $($validation.PackageCount) package(s)")
        if (-not $validation.Valid) { $problem.Add("$($file.Name): $($validation.Problem -join '; ')") }
    }
    $detail = if ($usedPinnedValidator) { 'Validated with the pinned SPDX tooling from the sbom workflow.' }
    else { 'pyspdxtools is not installed on this host, so the audit validated SPDX structure in-process (document namespace, creation info, SPDX version, non-empty package list) rather than skipping the check.' }
    if ($problem.Count -eq 0) {
        return New-MlsCheckResult -Passed $true -Observed ($observed -join '; ') -Detail $detail
    }
    return New-MlsCheckResult -Passed $false -Observed ($problem -join ' | ') -Final -Detail $detail
}

function Test-ZapReport {
    <# V9.4 - report artifact present for the staging URL and zero High alerts. An
       unreachable target produces an empty report, which is a FAIL, not a pass. #>
    param(
        [Parameter(Mandatory)][string]$Repository,
        [AllowEmptyString()][string]$RunId,
        [Parameter(Mandatory)][string]$ArtifactName,
        [Parameter(Mandatory)][string]$DownloadRoot
    )
    if ([string]::IsNullOrWhiteSpace($RunId)) {
        return New-MlsCheckResult -Passed $false -Observed 'no ZAP run id supplied' -Final `
            -Detail 'Pass -ZapRunId / $env:MLS_L9_ZAP_RUN_ID (the zap.yml run whose artifact carries the baseline report).'
    }
    $target = Join-Path -Path $DownloadRoot -ChildPath "zap-$RunId"
    if (-not (Test-Path -LiteralPath $target)) { New-Item -ItemType Directory -Path $target -Force | Out-Null }
    Invoke-MlsGh -AllowFailure -Raw -Argument @('run', 'download', $RunId, '--repo', $Repository, '-n', $ArtifactName, '-D', $target) | Out-Null
    $files = @(Get-ChildItem -Path $target -Filter '*.json' -Recurse -File -ErrorAction SilentlyContinue)
    if ($files.Count -eq 0) {
        return New-MlsCheckResult -Passed $false -Observed "artifact '$ArtifactName' from run $RunId produced no JSON report in $target" -Final `
            -Detail 'An unreachable staging target produces an empty report - that is a FAIL, not a pass (L09.md V9.4).'
    }
    $report = Get-MlsJsonFile -Path $files[0].FullName -Purpose 'ZAP baseline JSON report'
    $sites = @(Get-MlsProperty -InputObject $report -Name 'site')
    $alerts = @($sites | ForEach-Object { Get-MlsProperty -InputObject $_ -Name 'alerts' } | Where-Object { $null -ne $_ })
    $high = @($alerts | Where-Object { "$(Get-MlsProperty -InputObject $_ -Name 'riskdesc')" -like 'High*' })
    if ($sites.Count -eq 0) {
        return New-MlsCheckResult -Passed $false -Observed 'the report contains no site entry - ZAP could not reach the staging URL' -Final
    }
    if ($high.Count -eq 0) {
        return New-MlsCheckResult -Passed $true -Observed "$($files[0].Name): $($alerts.Count) alert(s), 0 at risk level High" `
            -Detail 'Medium/Low/Informational findings are recorded and triaged as normal backlog; only High fails the criterion.'
    }
    return New-MlsCheckResult -Passed $false `
        -Observed "$($high.Count) High alert(s): $(@($high | ForEach-Object { Get-MlsProperty -InputObject $_ -Name 'alert' }) -join ', ')" -Final `
        -Detail 'Fix the finding in the app or its config via the normal PR path; only rule-tune via a committed zap.conf with justification - never by editing the report (L09 failure mode 3).'
}

function Test-DefenderPlanState {
    <# V9.5 - current tier Free (the ARM representation of Off) AND the paired
       Standard-then-Free writes in the Activity Log, proving the toggle was exercised. #>
    param(
        [Parameter(Mandatory)][string]$PlanName,
        [Parameter(Mandatory)][string]$ActivityLogOffset
    )
    $pricing = Invoke-MlsAz -AllowFailure -Argument @(
        'security', 'pricing', 'show', '--name', $PlanName, '--query', '{tier:pricingTier}', '--output', 'json'
    )
    $tier = "$(Get-MlsProperty -InputObject $pricing -Name 'tier')"
    $events = @(Invoke-MlsAz -AllowFailure -Argument @(
            'monitor', 'activity-log', 'list', '--offset', $ActivityLogOffset,
            '--query', "[?contains(operationName.value,'Microsoft.Security/pricings')].{op:operationName.value, status:status.value, time:eventTimestamp}",
            '--output', 'json'
        ))
    $writes = @($events | Where-Object { "$(Get-MlsProperty -InputObject $_ -Name 'op')" -like '*write*' })
    if ($tier -ne 'Free') {
        return New-MlsCheckResult -Passed $false -Observed "pricingTier = '$tier', expected 'Free'" -Final `
            -Detail 'Defender left on is a cost leak: disable immediately with scripts/defender/toggle-containers-plan.ps1 -Disable (a spend decrease needs no gate), then root-cause why the layer''s disable step failed (L09.md Rollback).'
    }
    if ($writes.Count -lt 2) {
        return New-MlsCheckResult -Passed $false `
            -Observed "pricingTier = Free, but only $($writes.Count) Microsoft.Security/pricings write event(s) in the last $ActivityLogOffset" `
            -Detail 'The paired Standard-then-Free writes prove the toggle was exercised rather than merely never-enabled. Foundational CSPM stays on (free, spec F10) and is out of scope for this check.'
    }
    return New-MlsCheckResult -Passed $true `
        -Observed "pricingTier = Free with $($writes.Count) pricings write event(s) in the layer window (toggle exercised)"
}

function Invoke-Main {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
        Justification = 'Every parameter is consumed inside the criterion scriptblocks; PSSA cannot see through scriptblock closures.')]
    param(
        [string]$Repository,
        [string]$SubscriptionId,
        [string]$LayerRunId,
        [string]$ReleaseTag,
        [string]$ZapRunId,
        [string]$ZapArtifactName = 'zap-baseline-report',
        [string[]]$CodeQlLanguage = @(),
        [string]$DefenderPlanName = 'Containers',
        [string]$ActivityLogOffset = '6h',
        [string]$DownloadRoot,
        [string]$ReportRoot,
        [switch]$NoRetry,
        [string[]]$OnlyCriterion = @()
    )
    $repositoryName = Resolve-MlsInput -Name 'Repository' -Value $Repository -EnvironmentVariable @('MLS_GITHUB_REPO', 'MLS_REPOSITORY') `
        -Hint 'The repo whose GHAS state and CI artifacts this audit reads.'
    Resolve-MlsInput -Name 'GitHubToken' -Value '' -EnvironmentVariable @('MLS_VERIFIER_GH_TOKEN', 'GH_TOKEN', 'GITHUB_TOKEN') `
        -Hint "The Verifier's own GitHub read token (spec F8) - four of five criteria here are GitHub reads." | Out-Null
    $subscription = Resolve-MlsInput -Name 'SubscriptionId' -Value $SubscriptionId -EnvironmentVariable @('AZURE_SUBSCRIPTION_ID') `
        -Hint 'V9.5 reads the subscription-scoped Defender plan state and its Activity Log trail.'
    $downloads = $DownloadRoot
    if ([string]::IsNullOrWhiteSpace($downloads)) { $downloads = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath 'mls-l9-audit' }

    $runId = $LayerRunId
    if ([string]::IsNullOrWhiteSpace($runId)) { $runId = [Environment]::GetEnvironmentVariable('MLS_L9_RUN_ID') }
    $tag = $ReleaseTag
    if ([string]::IsNullOrWhiteSpace($tag)) { $tag = [Environment]::GetEnvironmentVariable('MLS_L9_RELEASE_TAG') }
    $zapRun = $ZapRunId
    if ([string]::IsNullOrWhiteSpace($zapRun)) { $zapRun = [Environment]::GetEnvironmentVariable('MLS_L9_ZAP_RUN_ID') }

    $context = New-MlsAuditContext -Layer 9 -Title 'DevSecOps chain' `
        -ScriptName 'verification/layer-09-audit.ps1' -ReportRoot $ReportRoot -NoRetry:$NoRetry `
        -OnlyCriterion $OnlyCriterion
    Add-MlsPreflight -Context $context -Name 'Repository' -Value $repositoryName
    Add-MlsPreflight -Context $context -Name 'SubscriptionId' -Value $subscription
    Add-MlsPreflight -Context $context -Name 'layer-09 run id' -Value "$runId" -Status $(if ($runId) { 'OK' } else { 'ABSENT' })
    Add-MlsPreflight -Context $context -Name 'Release tag' -Value "$tag" -Status $(if ($tag) { 'OK' } else { 'ABSENT' })
    Add-MlsPreflight -Context $context -Name 'ZAP run id' -Value "$zapRun" -Status $(if ($zapRun) { 'OK' } else { 'ABSENT' })
    Add-MlsPreflight -Context $context -Name 'Download root' -Value $downloads

    # L09: the first CodeQL analysis has to finish
    Invoke-MlsCriterion -Context $context -Id 'V9.1' -Control @('3.11.2') `
        -Description 'GitHub API shows all GHAS features enabled' `
        -Command "gh api repos/$repositoryName --jq '.security_and_analysis'`ngh api repos/$repositoryName/vulnerability-alerts -i   # expect 204`ngh api repos/$repositoryName/code-scanning/analyses --jq '.[0].tool.name'" `
        -Expected "secret scanning + push protection enabled; vulnerability-alerts 204; a completed CodeQL analysis for each of $($CodeQlLanguage -join ', ')" `
        -RetryWindowMinutes 20 `
        -Test { Test-GhasFeature -Repository $repositoryName -CodeQlLanguage $CodeQlLanguage } | Out-Null

    Invoke-MlsCriterion -Context $context -Id 'V9.2' -Control @('3.11.2', '3.14.1') `
        -Description 'A seeded CRITICAL image fails CI (negative test) then passes after pin' `
        -Command "gh api repos/$repositoryName/actions/runs/<layer09-runId>/jobs --jq '.jobs[] | select(.name | startswith(`"trivy-negative`")) | {name, conclusion}'" `
        -Expected 'trivy-negative-fail concludes success (its inner Trivy step exited non-zero on the seeded CRITICAL) and trivy-negative-pass concludes success' -NoRetry `
        -Test { Test-TrivyNegativeTest -Repository $repositoryName -RunId $runId } | Out-Null

    Invoke-MlsCriterion -Context $context -Id 'V9.3' -Control @('3.4.1') `
        -Description 'SBOM artifact present + SPDX-valid' `
        -Command "gh release view <tag> --json assets --jq '.assets[].name'`ngh release download <tag> -p '*.spdx.json' -D <tmp>`npyspdxtools -i <file>.spdx.json   # or in-process SPDX structural validation" `
        -Expected 'one *.spdx.json per app attached to the release; validator exits 0 (well-formed SPDX, non-empty package list)' -NoRetry `
        -Test { Test-SbomArtifact -Repository $repositoryName -Tag $tag -DownloadRoot $downloads } | Out-Null

    Invoke-MlsCriterion -Context $context -Id 'V9.4' -Control @('3.11.2') `
        -Description 'ZAP report artifact exists with 0 High' `
        -Command "gh run download <zap-runId> -n $ZapArtifactName -D <tmp>`n(Get-Content report.json | ConvertFrom-Json).site.alerts | Where-Object riskdesc -like 'High*'" `
        -Expected 'report artifact present for the staging URL; zero alerts at risk level High' -NoRetry `
        -Test { Test-ZapReport -Repository $repositoryName -RunId $zapRun -ArtifactName $ZapArtifactName -DownloadRoot $downloads } | Out-Null

    # -Control @(): this asserts Defender for Containers ends the demo OFF (a cost-control
    # toggle, exercised then disabled) - the opposite of a protection being in place, so
    # mapping it to a scanning/detection requirement would misrepresent what it proves.
    Invoke-MlsCriterion -Context $context -Id 'V9.5' -Control @() `
        -Description 'Defender plan toggles on -> off leaving state Off' `
        -Command "az security pricing show --name $DefenderPlanName --query `"{tier:pricingTier}`"`naz monitor activity-log list --offset $ActivityLogOffset --query `"[?contains(operationName.value,'Microsoft.Security/pricings')].{op:operationName.value, status:status.value, time:eventTimestamp}`"" `
        -Expected 'pricingTier == "Free" AND the paired Standard-then-Free write events inside the layer window' `
        -RetryWindowMinutes 5 `
        -Test { Test-DefenderPlanState -PlanName $DefenderPlanName -ActivityLogOffset $ActivityLogOffset } | Out-Null

    return $context
}

if (-not $env:MLS_SKIP_MAIN) {
    try {
        $auditContext = Invoke-Main -Repository $Repository -SubscriptionId $SubscriptionId -LayerRunId $LayerRunId `
            -ReleaseTag $ReleaseTag -ZapRunId $ZapRunId -ZapArtifactName $ZapArtifactName `
            -CodeQlLanguage $CodeQlLanguage -DefenderPlanName $DefenderPlanName `
            -ActivityLogOffset $ActivityLogOffset -DownloadRoot $DownloadRoot -ReportRoot $ReportRoot -NoRetry:$NoRetry `
            -OnlyCriterion $OnlyCriterion
    }
    catch {
        Write-MlsStatus -Message "layer-09-audit could not start: $($_.Exception.Message)" -Color Red
        exit 2
    }
    $reportFile = Write-MlsReport -Context $auditContext
    Write-MlsStatus -Message "report: $($reportFile.MarkdownPath)"
    exit (Get-MlsExitCode -Context $auditContext)
}
