#Requires -Version 7.0
<#
.SYNOPSIS
    L10 Verifier audit - the self-healing pipeline on GitHub Copilot Autofix. READ-ONLY.

.DESCRIPTION
    Implements the two master-plan Verify criteria owned by
    docs/runbooks/layers/L10.md section Validation cycle, and nothing else:

      V10.1  For the seeded CodeQL alert, the full Autofix trail holds - alert created ->
             autofix status success -> PR whose head commit is the Autofix commit and whose
             body carries Autofix's explanation -> gauntlet checks all green -> merged by
             automation (no human merger) -> new ACA revision -> alert state fixed,
             timestamps monotonic.
      V10.2  For at least 2 of the 3 seeded dependency pins, the Dependabot trail holds.

    Each stage is read independently from an API. Stage 3 checks the head commit came from
    the Autofix API and stage 5 checks the merger identity, so a hand-assisted chain reads
    as a failed chain - which is the point: never hand-close alerts, hand-write a fix, or
    hand-merge PRs to "complete" a run (L10.md Rollback).

    Both criteria carry a 24 h window measured from the re-seed merge. This audit does not
    block for a day: it evaluates the trail now and records PENDING while that declared
    window is still open, FAIL once it has passed.

.EXAMPLE
    ./layer-10-audit.ps1 -CodeQlAlertNumber 7 -AutofixPrNumber 31 -DependabotAlertNumber 3,4,5
#>
[CmdletBinding()]
param(
    [string]$Repository,
    [string]$CodeQlAlertNumber,
    [string]$AutofixPrNumber,
    [string[]]$DependabotAlertNumber = @(),
    [string]$VulnLabAppName = 'mls-vuln-lab-demo-ca',
    [string]$ResourceGroupName = 'mls-rg-apps',
    [string]$AutomationLogin = 'github-actions[bot]',
    [string]$ReseedMergedUtc,
    [double]$ChainWindowHours = 24,
    [int]$DependencyPassBar = 2,
    [string]$ReportRoot,
    [switch]$NoRetry
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'MlsAudit.psm1') -Force

function Get-PullRequestDetail {
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$Number
    )
    return Invoke-MlsGh -AllowFailure -Argument @(
        'pr', 'view', $Number, '--repo', $Repository,
        '--json', 'number,headRefOid,body,commits,mergedAt,mergedBy,autoMergeRequest,state,title'
    )
}

function Get-CheckConclusion {
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$HeadSha
    )
    $runs = @(Get-MlsCollection -Response (Invoke-MlsGh -AllowFailure -Argument @('api', "repos/$Repository/commits/$HeadSha/check-runs")))
    return @($runs | ForEach-Object { "$(Get-MlsProperty -InputObject $_ -Name 'name')=$(Get-MlsProperty -InputObject $_ -Name 'conclusion')" })
}

function Get-RevisionAfter {
    <# Stage 6 for both tracks: a new ACA revision timestamped after the merge. #>
    param(
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string]$AppName,
        [AllowNull()][datetime]$MergedUtc
    )
    $revisions = @(Invoke-MlsAz -AllowFailure -Argument @(
            'containerapp', 'revision', 'list', '--resource-group', $ResourceGroupName, '--name', $AppName,
            '--query', '[].{name:name, created:properties.createdTime}', '--output', 'json'
        ))
    if ($null -eq $MergedUtc) { return @() }
    return @($revisions | Where-Object {
            $created = "$(Get-MlsProperty -InputObject $_ -Name 'created')"
            $slot = [datetime]::MinValue
            [datetime]::TryParse($created, [ref]$slot) -and $slot.ToUniversalTime() -ge $MergedUtc
        })
}

function Test-AutofixTrail {
    <# V10.1 - seven stages, each read independently. #>
    param(
        [Parameter(Mandatory)][string]$Repository,
        [AllowEmptyString()][string]$AlertNumber,
        [AllowEmptyString()][string]$PullRequestNumber,
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string]$AppName,
        [Parameter(Mandatory)][string]$AutomationLogin
    )
    if ([string]::IsNullOrWhiteSpace($AlertNumber) -or [string]::IsNullOrWhiteSpace($PullRequestNumber)) {
        return New-MlsCheckResult -Passed $false -Observed 'no seeded CodeQL alert number and/or heal PR number supplied' -Final `
            -Detail 'L10 deploy step 4: the DevSecOps lead posts the alert numbers and PR numbers to the Verifier as they appear. Pass -CodeQlAlertNumber / $env:MLS_L10_CODEQL_ALERT and -AutofixPrNumber / $env:MLS_L10_AUTOFIX_PR.'
    }
    $stage = [System.Collections.Generic.List[string]]::new()
    $problem = [System.Collections.Generic.List[string]]::new()
    $timestamp = [System.Collections.Generic.List[object]]::new()

    # 1. alert created
    $alert = Invoke-MlsGh -AllowFailure -Argument @('api', "repos/$Repository/code-scanning/alerts/$AlertNumber")
    if ($null -eq $alert) {
        return New-MlsCheckResult -Passed $false -Observed "code-scanning alert #$AlertNumber could not be read"
    }
    $createdAt = "$(Get-MlsProperty -InputObject $alert -Name 'created_at')"
    $rule = "$(Get-MlsProperty -InputObject (Get-MlsProperty -InputObject $alert -Name 'rule') -Name 'id')"
    $stage.Add("1 alert #$AlertNumber rule=$rule created=$createdAt")
    $timestamp.Add($createdAt)

    # 2. autofix generated by GitHub, not by us
    $autofix = Invoke-MlsGh -AllowFailure -Argument @('api', "repos/$Repository/code-scanning/alerts/$AlertNumber/autofix")
    $autofixStatus = "$(Get-MlsProperty -InputObject $autofix -Name 'status')"
    $description = "$(Get-MlsProperty -InputObject $autofix -Name 'description')"
    $startedAt = "$(Get-MlsProperty -InputObject $autofix -Name 'started_at')"
    $stage.Add("2 autofix status=$autofixStatus")
    if ($startedAt) { $timestamp.Add($startedAt) }
    if ($autofixStatus -ne 'success') { $problem.Add("autofix status '$autofixStatus' (expected success)") }
    if ([string]::IsNullOrWhiteSpace($description)) { $problem.Add('autofix returned no description - there is no GitHub-authored explanation to carry into the PR') }

    # 3. PR head commit is the autofix commit and the body carries Autofix's explanation
    $pullRequest = Get-PullRequestDetail -Repository $Repository -Number $PullRequestNumber
    if ($null -eq $pullRequest) {
        return New-MlsCheckResult -Passed $false -Observed (($stage -join ' | ') + " | heal PR #$PullRequestNumber could not be read")
    }
    $headSha = "$(Get-MlsProperty -InputObject $pullRequest -Name 'headRefOid')"
    $body = "$(Get-MlsProperty -InputObject $pullRequest -Name 'body')"
    $commits = @(Get-MlsProperty -InputObject $pullRequest -Name 'commits')
    $stage.Add("3 PR #$PullRequestNumber head=$($headSha.Substring(0, [math]::Min(7, $headSha.Length))) commits=$($commits.Count)")
    if ($description -and $body -notlike "*$($description.Substring(0, [math]::Min(40, $description.Length)))*") {
        $problem.Add("the PR body does not carry Autofix's own explanation - the check that the narrative is GitHub's, not text the workflow wrote")
    }
    $headCommit = @($commits | Where-Object { "$(Get-MlsProperty -InputObject $_ -Name 'oid')" -eq $headSha })
    if ($commits.Count -gt 0 -and $headCommit.Count -eq 0) {
        $problem.Add("the PR's head commit $headSha is not among its own commits - the branch was not created from the autofix/commits call")
    }

    # 4. gauntlet green
    $conclusion = Get-CheckConclusion -Repository $Repository -HeadSha $headSha
    $notGreen = @($conclusion | Where-Object { $_ -notlike '*=success' })
    $stage.Add("4 checks=$($conclusion.Count)")
    if ($conclusion.Count -eq 0) { $problem.Add('no check runs on the heal PR head commit') }
    if ($notGreen.Count -gt 0) { $problem.Add("gauntlet not green: $($notGreen -join ', ')") }

    # 5. merged by automation, no human merger
    $mergedAt = "$(Get-MlsProperty -InputObject $pullRequest -Name 'mergedAt')"
    $mergedBy = "$(Get-MlsProperty -InputObject (Get-MlsProperty -InputObject $pullRequest -Name 'mergedBy') -Name 'login')"
    $autoMerge = Get-MlsProperty -InputObject $pullRequest -Name 'autoMergeRequest'
    $stage.Add("5 mergedBy=$mergedBy auto=$($null -ne $autoMerge)")
    if ($mergedAt) { $timestamp.Add($mergedAt) }
    if ([string]::IsNullOrWhiteSpace($mergedAt)) { $problem.Add('the heal PR is not merged') }
    if ($mergedBy -ne $AutomationLogin) { $problem.Add("mergedBy='$mergedBy', expected the automation identity '$AutomationLogin' (no human merger anywhere in the trail)") }
    if ($null -eq $autoMerge) { $problem.Add('no auto-merge request on the PR') }

    # 6. new ACA revision after the merge
    $mergedUtc = $null
    if ($mergedAt) {
        $slot = [datetime]::MinValue
        if ([datetime]::TryParse($mergedAt, [ref]$slot)) { $mergedUtc = $slot.ToUniversalTime() }
    }
    $revision = Get-RevisionAfter -ResourceGroupName $ResourceGroupName -AppName $AppName -MergedUtc $mergedUtc
    $stage.Add("6 revisions after merge=$($revision.Count)")
    if ($revision.Count -lt 1) { $problem.Add('no new container app revision timestamped after the merge') }
    elseif ($revision.Count -ge 1) { $timestamp.Add("$(Get-MlsProperty -InputObject $revision[0] -Name 'created')") }

    # 7. alert closed
    $final = Invoke-MlsGh -AllowFailure -Argument @('api', "repos/$Repository/code-scanning/alerts/$AlertNumber")
    $finalState = "$(Get-MlsProperty -InputObject $final -Name 'state')"
    $stage.Add("7 alert state=$finalState")
    if ($finalState -ne 'fixed') { $problem.Add("alert state '$finalState', expected 'fixed'") }

    $monotonic = Test-MlsMonotonicTimestamp -Timestamp @($timestamp)
    if (-not $monotonic.Monotonic) { $problem.Add("timestamps not monotonic: $($monotonic.Problem)") }

    if ($problem.Count -eq 0) {
        return New-MlsCheckResult -Passed $true -Observed ($stage -join ' | ')
    }
    return New-MlsCheckResult -Passed $false -Observed (($stage -join ' | ') + ' || ' + ($problem -join ' | ')) `
        -Detail 'A status of error is not retried away by the audit: one re-run of the chain is permitted and recorded; a second failure is a genuine defect in the seeded flaw''s suitability (L10 failure mode 3).'
}

function Test-DependabotTrailForAlert {
    <# Six stages for one seeded pin. #>
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$AlertNumber,
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string]$AppName,
        [Parameter(Mandatory)][string]$AutomationLogin
    )
    $problem = [System.Collections.Generic.List[string]]::new()
    $timestamp = [System.Collections.Generic.List[object]]::new()
    $alert = Invoke-MlsGh -AllowFailure -Argument @('api', "repos/$Repository/dependabot/alerts/$AlertNumber")
    if ($null -eq $alert) {
        return [pscustomobject]@{ Passed = $false; Summary = "alert #$AlertNumber unreadable" }
    }
    $package = "$(Get-MlsProperty -InputObject (Get-MlsProperty -InputObject (Get-MlsProperty -InputObject $alert -Name 'dependency') -Name 'package') -Name 'name')"
    $timestamp.Add("$(Get-MlsProperty -InputObject $alert -Name 'created_at')")

    $pullRequests = @(Invoke-MlsGh -AllowFailure -Argument @(
            'pr', 'list', '--repo', $Repository, '--author', 'app/dependabot', '--state', 'all',
            '--json', 'number,title,headRefName'
        ))
    $candidate = @($pullRequests | Where-Object {
            "$(Get-MlsProperty -InputObject $_ -Name 'title')$(Get-MlsProperty -InputObject $_ -Name 'headRefName')" -like "*$package*"
        })
    if ($candidate.Count -eq 0) {
        return [pscustomobject]@{ Passed = $false; Summary = "#$AlertNumber ($package): no Dependabot PR targeting the package" }
    }
    $number = "$(Get-MlsProperty -InputObject $candidate[0] -Name 'number')"
    $pullRequest = Get-PullRequestDetail -Repository $Repository -Number $number
    $headSha = "$(Get-MlsProperty -InputObject $pullRequest -Name 'headRefOid')"
    $conclusion = Get-CheckConclusion -Repository $Repository -HeadSha $headSha
    $notGreen = @($conclusion | Where-Object { $_ -notlike '*=success' })
    if ($conclusion.Count -eq 0) { $problem.Add('no check runs') }
    if ($notGreen.Count -gt 0) { $problem.Add("gauntlet not green: $($notGreen -join ', ')") }

    $mergedAt = "$(Get-MlsProperty -InputObject $pullRequest -Name 'mergedAt')"
    $mergedBy = "$(Get-MlsProperty -InputObject (Get-MlsProperty -InputObject $pullRequest -Name 'mergedBy') -Name 'login')"
    $autoMerge = Get-MlsProperty -InputObject $pullRequest -Name 'autoMergeRequest'
    if ($mergedAt) { $timestamp.Add($mergedAt) }
    if ([string]::IsNullOrWhiteSpace($mergedAt)) { $problem.Add('PR not merged') }
    if ($mergedBy -ne $AutomationLogin) { $problem.Add("mergedBy='$mergedBy'") }
    if ($null -eq $autoMerge) { $problem.Add('no auto-merge request (Dependabot PRs must be explicitly flagged - L10 failure mode 5)') }

    $mergedUtc = $null
    if ($mergedAt) {
        $slot = [datetime]::MinValue
        if ([datetime]::TryParse($mergedAt, [ref]$slot)) { $mergedUtc = $slot.ToUniversalTime() }
    }
    $revision = Get-RevisionAfter -ResourceGroupName $ResourceGroupName -AppName $AppName -MergedUtc $mergedUtc
    if ($revision.Count -lt 1) { $problem.Add('no new container app revision after the merge') }
    else { $timestamp.Add("$(Get-MlsProperty -InputObject $revision[0] -Name 'created')") }

    $final = Invoke-MlsGh -AllowFailure -Argument @('api', "repos/$Repository/dependabot/alerts/$AlertNumber")
    $finalState = "$(Get-MlsProperty -InputObject $final -Name 'state')"
    if ($finalState -ne 'fixed') { $problem.Add("alert state '$finalState', expected 'fixed'") }

    $monotonic = Test-MlsMonotonicTimestamp -Timestamp @($timestamp)
    if (-not $monotonic.Monotonic) { $problem.Add("timestamps not monotonic: $($monotonic.Problem)") }

    if ($problem.Count -eq 0) {
        return [pscustomobject]@{ Passed = $true; Summary = "#$AlertNumber ($package) PR #$($number): all six stages hold" }
    }
    return [pscustomobject]@{ Passed = $false; Summary = "#$AlertNumber ($package) PR #$($number): $($problem -join ', ')" }
}

function Test-DependabotTrail {
    <# V10.2 - at least 2 of the 3 seeded pins; the third's outcome is recorded either way. #>
    param(
        [Parameter(Mandatory)][string]$Repository,
        [AllowEmptyCollection()][string[]]$AlertNumber,
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string]$AppName,
        [Parameter(Mandatory)][string]$AutomationLogin,
        [Parameter(Mandatory)][int]$PassBar
    )
    $numbers = @($AlertNumber | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($numbers.Count -eq 0) {
        return New-MlsCheckResult -Passed $false -Observed 'no seeded Dependabot alert numbers supplied' -Final `
            -Detail 'Pass -DependabotAlertNumber / $env:MLS_L10_DEPENDABOT_ALERTS (comma-separated) with the three seeded pins'' alert numbers. L9 failure mode 5 - a valid but silent Dependabot config - is exactly what this criterion would otherwise hide.'
    }
    $result = @($numbers | ForEach-Object {
            Test-DependabotTrailForAlert -Repository $Repository -AlertNumber $_ `
                -ResourceGroupName $ResourceGroupName -AppName $AppName -AutomationLogin $AutomationLogin
        })
    $passing = @($result | Where-Object { $_.Passed })
    $observed = "$($passing.Count) of $($numbers.Count) trails complete: " + (@($result | ForEach-Object { $_.Summary }) -join ' | ')
    if ($passing.Count -ge $PassBar) {
        return New-MlsCheckResult -Passed $true -Observed $observed `
            -Detail '3/3 is the target, 2/3 is the pass line; the third pin''s outcome is recorded either way (L10.md V10.2).'
    }
    return New-MlsCheckResult -Passed $false -Observed $observed `
        -Detail 'Partial credit does not accumulate across runs - a pass requires the trails to complete within one armed cycle (L10 failure mode 7).'
}

function Invoke-Main {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
        Justification = 'Every parameter is consumed inside the criterion scriptblocks; PSSA cannot see through scriptblock closures.')]
    param(
        [string]$Repository,
        [string]$CodeQlAlertNumber,
        [string]$AutofixPrNumber,
        [string[]]$DependabotAlertNumber = @(),
        [string]$VulnLabAppName = 'mls-vuln-lab-demo-ca',
        [string]$ResourceGroupName = 'mls-rg-apps',
        [string]$AutomationLogin = 'github-actions[bot]',
        [string]$ReseedMergedUtc,
        [double]$ChainWindowHours = 24,
        [int]$DependencyPassBar = 2,
        [string]$ReportRoot,
        [switch]$NoRetry
    )
    $repositoryName = Resolve-MlsInput -Name 'Repository' -Value $Repository -EnvironmentVariable @('MLS_REPOSITORY') `
        -DefaultValue 'paulcfuqua/azure-devsecops' -Hint 'The public repo the healing trail lives on.'
    Resolve-MlsInput -Name 'GitHubToken' -Value '' -EnvironmentVariable @('MLS_VERIFIER_GH_TOKEN', 'GH_TOKEN', 'GITHUB_TOKEN') `
        -Hint "The Verifier's own GitHub read token (spec F8); both criteria are mostly GitHub reads." | Out-Null

    $codeqlAlert = $CodeQlAlertNumber
    if ([string]::IsNullOrWhiteSpace($codeqlAlert)) { $codeqlAlert = [Environment]::GetEnvironmentVariable('MLS_L10_CODEQL_ALERT') }
    $healPr = $AutofixPrNumber
    if ([string]::IsNullOrWhiteSpace($healPr)) { $healPr = [Environment]::GetEnvironmentVariable('MLS_L10_AUTOFIX_PR') }
    $dependabotAlert = @($DependabotAlertNumber | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($dependabotAlert.Count -eq 0) {
        $fromEnvironment = [Environment]::GetEnvironmentVariable('MLS_L10_DEPENDABOT_ALERTS')
        if (-not [string]::IsNullOrWhiteSpace($fromEnvironment)) {
            $dependabotAlert = @($fromEnvironment -split '[,;\s]+' | Where-Object { $_ })
        }
    }
    $windowStart = [datetime]::MinValue
    $reseed = $ReseedMergedUtc
    if ([string]::IsNullOrWhiteSpace($reseed)) { $reseed = [Environment]::GetEnvironmentVariable('MLS_L10_RESEED_MERGED_AT') }
    if (-not [string]::IsNullOrWhiteSpace($reseed)) { $windowStart = [datetime]::Parse($reseed).ToUniversalTime() }

    $context = New-MlsAuditContext -Layer 10 -Title 'Self-healing pipeline on GitHub Copilot Autofix' `
        -ScriptName 'verification/layer-10-audit.ps1' -ReportRoot $ReportRoot -NoRetry:$NoRetry
    Add-MlsPreflight -Context $context -Name 'Repository' -Value $repositoryName
    Add-MlsPreflight -Context $context -Name 'CodeQL alert / heal PR' -Value "$codeqlAlert / $healPr" `
        -Status $(if ($codeqlAlert -and $healPr) { 'OK' } else { 'ABSENT' })
    Add-MlsPreflight -Context $context -Name 'Dependabot alerts' -Value ($dependabotAlert -join ', ') `
        -Status $(if ($dependabotAlert.Count -ge 3) { 'OK' } elseif ($dependabotAlert.Count -gt 0) { 'PARTIAL' } else { 'ABSENT' })
    Add-MlsPreflight -Context $context -Name 'Re-seed merged (UTC)' -Value "$reseed" `
        -Status $(if ($windowStart -ne [datetime]::MinValue) { 'OK' } else { 'ABSENT' })
    if ($windowStart -eq [datetime]::MinValue) {
        Add-MlsNote -Context $context -Message 'No re-seed merge timestamp supplied (-ReseedMergedUtc / $env:MLS_L10_RESEED_MERGED_AT), so the 24 h chain deadline could not be computed and an incomplete trail is recorded FAIL rather than PENDING.'
    }
    $windowMinutes = $ChainWindowHours * 60
    $pendingAllowed = ($windowStart -ne [datetime]::MinValue)

    Invoke-MlsCriterion -Context $context -Id 'V10.1' `
        -Description 'For the seeded CodeQL alert, the full Autofix trail holds (alert -> autofix success -> PR with Autofix commit and explanation -> gauntlet green -> merged by automation -> new ACA revision -> alert fixed, timestamps monotonic)' `
        -Command "gh api repos/$repositoryName/code-scanning/alerts/<n> --jq '{state, created_at, rule:.rule.id}'`ngh api repos/$repositoryName/code-scanning/alerts/<n>/autofix --jq '{status, description, started_at}'`ngh pr view <pr> --json headRefOid,body,commits`ngh api repos/$repositoryName/commits/<head-sha>/check-runs`ngh pr view <pr> --json mergedBy,autoMergeRequest`naz containerapp revision list -g $ResourceGroupName -n $VulnLabAppName`ngh api repos/$repositoryName/code-scanning/alerts/<n> --jq '.state'" `
        -Expected "seven stages hold: autofix status success with a non-empty description carried in the PR body; head commit from autofix/commits; all check-run conclusions success; mergedBy == $AutomationLogin with an auto-merge request; a revision after the merge; alert state fixed; timestamps monotonic" `
        -RetryWindowMinutes $windowMinutes -InProcessWaitMinutes 0 -WindowStartUtc $windowStart -PendingWhenUnexpired:$pendingAllowed `
        -Test {
        Test-AutofixTrail -Repository $repositoryName -AlertNumber $codeqlAlert -PullRequestNumber $healPr `
            -ResourceGroupName $ResourceGroupName -AppName $VulnLabAppName -AutomationLogin $AutomationLogin
    } | Out-Null

    Invoke-MlsCriterion -Context $context -Id 'V10.2' `
        -Description 'For at least 2 of the 3 seeded dependency pins, the Dependabot trail holds (alert -> patch PR -> gauntlet green -> merged by automation -> new ACA revision -> alert fixed)' `
        -Command "gh api repos/$repositoryName/dependabot/alerts/<n> --jq '{state, created_at, dep:.dependency.package.name}'`ngh pr list --author `"app/dependabot`" --json number,title,headRefName`ngh api repos/$repositoryName/commits/<head-sha>/check-runs`ngh pr view <pr> --json mergedBy,autoMergeRequest`naz containerapp revision list -g $ResourceGroupName -n $VulnLabAppName`ngh api repos/$repositoryName/dependabot/alerts/<n> --jq '.state'" `
        -Expected "all six stages hold for at least $DependencyPassBar of the seeded pins (3/3 is the target, $DependencyPassBar/3 is the pass line)" `
        -RetryWindowMinutes $windowMinutes -InProcessWaitMinutes 0 -WindowStartUtc $windowStart -PendingWhenUnexpired:$pendingAllowed `
        -Test {
        Test-DependabotTrail -Repository $repositoryName -AlertNumber $dependabotAlert `
            -ResourceGroupName $ResourceGroupName -AppName $VulnLabAppName -AutomationLogin $AutomationLogin -PassBar $DependencyPassBar
    } | Out-Null

    return $context
}

if (-not $env:MLS_SKIP_MAIN) {
    try {
        $auditContext = Invoke-Main -Repository $Repository -CodeQlAlertNumber $CodeQlAlertNumber `
            -AutofixPrNumber $AutofixPrNumber -DependabotAlertNumber $DependabotAlertNumber `
            -VulnLabAppName $VulnLabAppName -ResourceGroupName $ResourceGroupName -AutomationLogin $AutomationLogin `
            -ReseedMergedUtc $ReseedMergedUtc -ChainWindowHours $ChainWindowHours `
            -DependencyPassBar $DependencyPassBar -ReportRoot $ReportRoot -NoRetry:$NoRetry
    }
    catch {
        Write-MlsStatus -Message "layer-10-audit could not start: $($_.Exception.Message)" -Color Red
        exit 2
    }
    $reportFile = Write-MlsReport -Context $auditContext
    Write-MlsStatus -Message "report: $($reportFile.MarkdownPath)"
    exit (Get-MlsExitCode -Context $auditContext)
}
