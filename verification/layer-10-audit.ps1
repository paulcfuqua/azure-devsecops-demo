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

    THE DEPLOY STAGE (V10.1 stage 6, V10.2 stage 5) reads revisions of
    mls-vuln-lab-demo-ca, the L10 deployment witness provisioned by
    infra/bicep/apps/main.bicep. apps/vuln-lab itself is never containerised - its pins are
    CRITICAL and would fail the very Trivy gate the heal PR has to pass, and its seeds are
    unstarted server factories whose safety rests on nothing ever running them - so the
    witness carries a pinned public placeholder image plus the heal's identity as
    configuration. The criterion is therefore not "some revision appeared", which any
    unrelated redeploy satisfies, but "the revision after the merge carries
    MLS_HEAL_COMMIT == this PR's merge commit", which nothing satisfies by accident.
    .github/workflows/vuln-lab-witness.yml is what stamps it.

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
    # V10.3's subject. 'true' / 'false' as reported by the self-heal select job; an
    # empty value means the chain did not say, which is itself unobservable and is
    # NOT treated as healthy. See F123.
    [string]$AlertSurfaceReadable = '',
    [string]$ReportRoot,
    [switch]$NoRetry,
    # Run only these criteria (e.g. -OnlyCriterion V10.2). Everything else reports SKIP
    # naming the reason, and the run exits 3 - a DIAGNOSTIC, never a sign-off (P-10).
    [string[]]$OnlyCriterion = @()
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
        # mergeCommit is what binds the estate half of the trail to this PR: the deploy
        # stage requires the witness revision to be stamped with THIS merge's commit, not
        # merely to exist after it.
        '--json', 'number,headRefOid,body,commits,mergedAt,mergedBy,autoMergeRequest,mergeCommit,state,title'
    )
}

function Get-MergeCommitSha {
    <# The oid gh reports for a merged PR's merge commit, or '' when it is not merged. #>
    param([AllowNull()]$PullRequest)
    return "$(Get-MlsProperty -InputObject (Get-MlsProperty -InputObject $PullRequest -Name 'mergeCommit') -Name 'oid')"
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
    <#
    .SYNOPSIS
        The deploy stage for both tracks (V10.1 stage 6, V10.2 stage 5): a new revision of
        the L10 deployment witness, timestamped after the merge AND stamped with that
        merge's commit.
    .DESCRIPTION
        The app is mls-vuln-lab-demo-ca, provisioned by infra/bicep/apps/main.bicep. It is a
        witness, not a fifth serving app: apps/vuln-lab is never containerised (its pins are
        CRITICAL and would fail the very Trivy gate the heal PR has to pass, and its seeds
        are unstarted server factories whose safety argument is that nothing ever runs
        them), so the container carries a pinned public placeholder image and the heal's
        identity as configuration. .github/workflows/vuln-lab-witness.yml re-stamps
        MLS_HEAL_COMMIT on every push to main touching apps/vuln-lab/**.

        The commit match is the point. "Some revision appeared after the merge" is satisfied
        by any unrelated redeploy and proves nothing; "the revision after the merge carries
        this heal's merge commit" cannot be satisfied by accident, and it is the estate's own
        record - read from ARM with Reader - that the merged fix reached Azure.
    .OUTPUTS
        After   - revisions created at or after the merge
        Matched - of those, the ones stamped with this merge commit
        Stamp   - the MLS_HEAL_COMMIT values seen on After, for the report's observed line
    #>
    param(
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string]$AppName,
        # [nullable[datetime]], not [datetime]. [AllowNull()] waives the null VALIDATION but
        # not the type COERCION, and $null does not convert to a value type - so with a plain
        # [datetime] the binder threw before the `if ($null -eq $MergedUtc)` guard below could
        # ever run, and that guard was dead code from the day it was written. An unmerged PR
        # is the chain's normal state, not an error: it must reach the guard and return $empty
        # so the caller reports "PR not merged" instead of a PowerShell type error (F187).
        [AllowNull()][nullable[datetime]]$MergedUtc,
        [AllowEmptyString()][AllowNull()][string]$MergeCommit
    )
    $revisions = @(Invoke-MlsAz -AllowFailure -Argument @(
            'containerapp', 'revision', 'list', '--resource-group', $ResourceGroupName, '--name', $AppName,
            '--query', "[].{name:name, created:properties.createdTime, healCommit:properties.template.containers[0].env[?name=='MLS_HEAL_COMMIT']|[0].value}",
            '--output', 'json'
        ))
    $empty = [pscustomobject]@{ After = @(); Matched = @(); Stamp = @() }
    if ($null -eq $MergedUtc) { return $empty }
    $after = @($revisions | Where-Object {
            $created = "$(Get-MlsProperty -InputObject $_ -Name 'created')"
            $slot = [datetime]::MinValue
            [datetime]::TryParse($created, [ref]$slot) -and $slot.ToUniversalTime() -ge $MergedUtc
        })
    $stamp = @($after | ForEach-Object { "$(Get-MlsProperty -InputObject $_ -Name 'healCommit')" })
    $matched = @()
    if (-not [string]::IsNullOrWhiteSpace($MergeCommit)) {
        $matched = @($after | Where-Object {
                "$(Get-MlsProperty -InputObject $_ -Name 'healCommit')" -eq $MergeCommit
            })
    }
    return [pscustomobject]@{ After = $after; Matched = $matched; Stamp = $stamp }
}

function Test-MergeProvenance {
    <#
    .SYNOPSIS
        Stage 5's verdict: the merge was PRE-AUTHORISED by the chain, not decided by a
        human after seeing the result.
    .DESCRIPTION
        This asserted `mergedBy.login -eq 'github-actions[bot]'` until F191. The chain arms
        auto-merge with SELF_HEAL_TOKEN, a PAT owned by a person, so GitHub attributes the
        merge to THAT PERSON - and the criterion whose entire job is "no human merged this"
        reported a human on every correct run. PR #232, healed and merged with no human
        involved anywhere, failed it.

        Allowing the PAT owner's login would have made it pass and asserted NOTHING: a
        genuine hand-merge produces an identical `mergedBy`, so the check would no longer
        distinguish the two states it exists to tell apart - and V10.1 is what makes
        auto-merge-on-green defensible in the first place.

        The question is not WHO merged, it is WHEN the decision was made. Auto-merge stamps
        `enabledAt` before the gauntlet finishes and the platform merges on green; a
        discretionary click happens after the result is known and leaves no
        autoMergeRequest at all. `autoMergeRequest` survives the merge, so this is
        readable after the fact.

        The literal-login assertion becomes honest again the day the chain runs as a
        GitHub App - an installation token merges as `<app>[bot]`. That is the durable
        fix; this is the faithful check until then.
    .OUTPUTS
        Problem - failures, empty when the provenance holds
        Note    - the stage fragment naming who merged and when it was armed
    #>
    param(
        [AllowNull()]$PullRequest,
        [AllowEmptyString()][AllowNull()][string]$MergedAt
    )
    $problem = [System.Collections.Generic.List[string]]::new()
    $mergedBy = "$(Get-MlsProperty -InputObject (Get-MlsProperty -InputObject $PullRequest -Name 'mergedBy') -Name 'login')"
    $autoMerge = Get-MlsProperty -InputObject $PullRequest -Name 'autoMergeRequest'
    $armedBy = "$(Get-MlsProperty -InputObject (Get-MlsProperty -InputObject $autoMerge -Name 'enabledBy') -Name 'login')"
    $armedAt = "$(Get-MlsProperty -InputObject $autoMerge -Name 'enabledAt')"
    $note = "5 mergedBy=$mergedBy armed=$(if ($armedBy) { "$armedBy@$armedAt" } else { 'none' })"

    if ($null -eq $autoMerge) {
        $problem.Add("no auto-merge request on the PR, so the merge was a discretionary act taken after the result was known (merged by '$mergedBy')")
        return [pscustomobject]@{ Problem = $problem; Note = $note }
    }

    # Provenance is only meaningful once something has actually merged. An armed but
    # unmerged PR is the chain's ordinary in-flight state, and its own problem is
    # recorded by the caller - not a bogus identity mismatch against an absent merger.
    if ([string]::IsNullOrWhiteSpace($MergedAt)) { return [pscustomobject]@{ Problem = $problem; Note = $note } }

    if ($armedBy -ne $mergedBy) {
        $problem.Add("auto-merge was armed by '$armedBy' but the merge is attributed to '$mergedBy' - a third identity completed what the chain started")
    }
    $armedSlot = [datetime]::MinValue
    $mergedSlot = [datetime]::MinValue
    if ([datetime]::TryParse($armedAt, [ref]$armedSlot) -and [datetime]::TryParse($MergedAt, [ref]$mergedSlot)) {
        if ($armedSlot.ToUniversalTime() -ge $mergedSlot.ToUniversalTime()) {
            $problem.Add("auto-merge was armed at $armedAt, which is not before the merge at $MergedAt - an arming stamped after the merge cannot have caused it")
        }
    }
    return [pscustomobject]@{ Problem = $problem; Note = $note }
}

function Test-DeployStage {
    <#
    .SYNOPSIS
        Shared verdict for the deploy stage: returns the matched revision (or $null) plus the
        problem text, so both trails phrase the same failure the same way.
    #>
    param(
        [Parameter(Mandatory)]$Deploy,
        [AllowEmptyString()][AllowNull()][string]$MergeCommit
    )
    if ($Deploy.After.Count -lt 1) {
        return [pscustomobject]@{
            Revision = $null
            Problem  = 'no new container app revision timestamped after the merge (the vuln-lab deployment witness was not rolled - check .github/workflows/vuln-lab-witness.yml ran for the merge commit)'
        }
    }
    if ([string]::IsNullOrWhiteSpace($MergeCommit)) {
        return [pscustomobject]@{
            Revision = $null
            Problem  = 'the PR reports no merge commit, so the revision after the merge could not be bound to this heal'
        }
    }
    if ($Deploy.Matched.Count -lt 1) {
        $seen = @($Deploy.Stamp | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
        $describe = if ($seen.Count -gt 0) { $seen -join ', ' } else { '(none stamped)' }
        return [pscustomobject]@{
            Revision = $null
            Problem  = "$($Deploy.After.Count) revision(s) exist after the merge but none carries MLS_HEAL_COMMIT=$MergeCommit (stamps seen: $describe) - a revision that is not this heal's does not prove this heal shipped"
        }
    }
    return [pscustomobject]@{ Revision = $Deploy.Matched[0]; Problem = '' }
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

    # 5. the merge was pre-authorised by the chain, not decided by a human (F191)
    $mergedAt = "$(Get-MlsProperty -InputObject $pullRequest -Name 'mergedAt')"
    $provenance = Test-MergeProvenance -PullRequest $pullRequest -MergedAt $mergedAt
    $stage.Add($provenance.Note)
    if ($mergedAt) { $timestamp.Add($mergedAt) }
    if ([string]::IsNullOrWhiteSpace($mergedAt)) { $problem.Add('the heal PR is not merged') }
    foreach ($entry in $provenance.Problem) { $problem.Add($entry) }

    # 6. new witness revision after the merge, stamped with this merge's commit
    $mergedUtc = $null
    if ($mergedAt) {
        $slot = [datetime]::MinValue
        if ([datetime]::TryParse($mergedAt, [ref]$slot)) { $mergedUtc = $slot.ToUniversalTime() }
    }
    $mergeCommit = Get-MergeCommitSha -PullRequest $pullRequest
    $deploy = Get-RevisionAfter -ResourceGroupName $ResourceGroupName -AppName $AppName `
        -MergedUtc $mergedUtc -MergeCommit $mergeCommit
    $verdict = Test-DeployStage -Deploy $deploy -MergeCommit $mergeCommit
    $stage.Add("6 revisions after merge=$($deploy.After.Count) stamped with $($mergeCommit.Substring(0, [math]::Min(7, $mergeCommit.Length)))=$($deploy.Matched.Count)")
    if ($verdict.Problem) { $problem.Add($verdict.Problem) }
    else { $timestamp.Add("$(Get-MlsProperty -InputObject $verdict.Revision -Name 'created')") }

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

    # Same provenance rule as the Autofix trail (F191): the merge must have been
    # pre-authorised by the chain, not chosen by a human once the result was visible.
    $mergedAt = "$(Get-MlsProperty -InputObject $pullRequest -Name 'mergedAt')"
    if ($mergedAt) { $timestamp.Add($mergedAt) }
    if ([string]::IsNullOrWhiteSpace($mergedAt)) { $problem.Add('PR not merged') }
    $provenance = Test-MergeProvenance -PullRequest $pullRequest -MergedAt $mergedAt
    foreach ($entry in $provenance.Problem) { $problem.Add($entry) }

    $mergedUtc = $null
    if ($mergedAt) {
        $slot = [datetime]::MinValue
        if ([datetime]::TryParse($mergedAt, [ref]$slot)) { $mergedUtc = $slot.ToUniversalTime() }
    }
    $mergeCommit = Get-MergeCommitSha -PullRequest $pullRequest
    $deploy = Get-RevisionAfter -ResourceGroupName $ResourceGroupName -AppName $AppName `
        -MergedUtc $mergedUtc -MergeCommit $mergeCommit
    $verdict = Test-DeployStage -Deploy $deploy -MergeCommit $mergeCommit
    if ($verdict.Problem) { $problem.Add($verdict.Problem) }
    else { $timestamp.Add("$(Get-MlsProperty -InputObject $verdict.Revision -Name 'created')") }

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
        [string]$AlertSurfaceReadable = '',
        [string]$ReportRoot,
        [switch]$NoRetry,
        [string[]]$OnlyCriterion = @()
    )
    $repositoryName = Resolve-MlsInput -Name 'Repository' -Value $Repository -EnvironmentVariable @('MLS_GITHUB_REPO', 'MLS_REPOSITORY') `
        -Hint 'The public repo the healing trail lives on.'
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

    # F192: DERIVE THE WINDOW WHEN NOBODY SUPPLIED ONE.
    #
    # The self-heal workflow runs this audit in the same run that arms auto-merge, so it
    # reads the trail minutes before the gauntlet finishes - run 33905789865 verified at
    # 18:26:07 a merge that landed at 18:29:02. An in-flight chain is exactly what the
    # PENDING window exists for, and it was recorded FAIL instead, because the window
    # depended on a human having set MLS_L10_RESEED_MERGED_AT and nobody had. A window
    # that only works when someone remembers to set a variable is a window that is
    # usually absent, and 'absent' silently meant 'every in-flight trail is a failure'.
    #
    # The moment the chain committed to THIS heal is on the pull request itself:
    # autoMergeRequest.enabledAt, which survives the merge. It is a narrower clock than
    # the re-seed merge - it times the chain's own attempt rather than the whole demo
    # cycle - so the supplied value still wins when there is one, and the report names
    # which clock it used.
    $windowSource = 're-seed merge'
    if ($windowStart -eq [datetime]::MinValue -and -not [string]::IsNullOrWhiteSpace($healPr)) {
        $armedAt = "$(Get-MlsProperty -InputObject (Get-MlsProperty -InputObject (
                    Get-PullRequestDetail -Repository $repositoryName -Number $healPr
                ) -Name 'autoMergeRequest') -Name 'enabledAt')"
        $slot = [datetime]::MinValue
        if (-not [string]::IsNullOrWhiteSpace($armedAt) -and [datetime]::TryParse($armedAt, [ref]$slot)) {
            $windowStart = $slot.ToUniversalTime()
            $windowSource = "heal PR #$healPr auto-merge armed"
            $reseed = $armedAt
        }
    }

    $context = New-MlsAuditContext -Layer 10 -Title 'Self-healing pipeline on GitHub Copilot Autofix' `
        -ScriptName 'verification/layer-10-audit.ps1' -ReportRoot $ReportRoot -NoRetry:$NoRetry `
        -OnlyCriterion $OnlyCriterion
    Add-MlsPreflight -Context $context -Name 'Repository' -Value $repositoryName
    Add-MlsPreflight -Context $context -Name 'CodeQL alert / heal PR' -Value "$codeqlAlert / $healPr" `
        -Status $(if ($codeqlAlert -and $healPr) { 'OK' } else { 'ABSENT' })
    Add-MlsPreflight -Context $context -Name 'Dependabot alerts' -Value ($dependabotAlert -join ', ') `
        -Status $(if ($dependabotAlert.Count -ge 3) { 'OK' } elseif ($dependabotAlert.Count -gt 0) { 'PARTIAL' } else { 'ABSENT' })
    Add-MlsPreflight -Context $context -Name "Chain window start (UTC, from $windowSource)" -Value "$reseed" `
        -Status $(if ($windowStart -ne [datetime]::MinValue) { 'OK' } else { 'ABSENT' })
    if ($windowStart -eq [datetime]::MinValue) {
        Add-MlsNote -Context $context -Message 'No chain window could be computed: no re-seed timestamp (-ReseedMergedUtc / $env:MLS_L10_RESEED_MERGED_AT) and no heal PR carrying an auto-merge arming time, so an incomplete trail is recorded FAIL rather than PENDING.'
    }
    elseif ($windowSource -ne 're-seed merge') {
        Add-MlsNote -Context $context -Message "Chain window derived from $windowSource, not from a supplied re-seed timestamp (F192). It times this heal's own attempt rather than the whole demo cycle; set MLS_L10_RESEED_MERGED_AT to measure from the re-seed instead."
    }
    $windowMinutes = $ChainWindowHours * 60
    $pendingAllowed = ($windowStart -ne [datetime]::MinValue)

    # 3.4.3 alongside 3.14.1: this is the estate's strongest change-control
    # evidence. It asserts a complete, ordered trail - PR opened, the autofix
    # explanation carried in the body, every required check green, merged by the
    # automation identity under an auto-merge request, a witness revision stamped
    # with the merge commit, timestamps monotonic. That is a positive demonstration
    # of "track, review, approve or disapprove, and log changes", stronger than
    # V8.1's negative evidence (no component carries an unmanaged layer), which
    # already carries 3.4.3.
    Invoke-MlsCriterion -Context $context -Id 'V10.1' -Control @('3.4.3', '3.14.1') `
        -Description 'For the seeded CodeQL alert, the full Autofix trail holds (alert -> autofix success -> PR with Autofix commit and explanation -> gauntlet green -> merged by automation -> new ACA revision -> alert fixed, timestamps monotonic)' `
        -Command "gh api repos/$repositoryName/code-scanning/alerts/<n> --jq '{state, created_at, rule:.rule.id}'`ngh api repos/$repositoryName/code-scanning/alerts/<n>/autofix --jq '{status, description, started_at}'`ngh pr view <pr> --json headRefOid,body,commits`ngh api repos/$repositoryName/commits/<head-sha>/check-runs`ngh pr view <pr> --json mergedBy,autoMergeRequest,mergeCommit`naz containerapp revision list -g $ResourceGroupName -n $VulnLabAppName --query `"[].{name:name, created:properties.createdTime, healCommit:properties.template.containers[0].env[?name=='MLS_HEAL_COMMIT']|[0].value}`"`ngh api repos/$repositoryName/code-scanning/alerts/<n> --jq '.state'" `
        -Expected "seven stages hold: autofix status success with a non-empty description carried in the PR body; head commit from autofix/commits; all check-run conclusions success; mergedBy == $AutomationLogin with an auto-merge request; a witness revision after the merge carrying MLS_HEAL_COMMIT == the PR's merge commit; alert state fixed; timestamps monotonic" `
        -RetryWindowMinutes $windowMinutes -InProcessWaitMinutes 0 -WindowStartUtc $windowStart -PendingWhenUnexpired:$pendingAllowed `
        -Test {
        Test-AutofixTrail -Repository $repositoryName -AlertNumber $codeqlAlert -PullRequestNumber $healPr `
            -ResourceGroupName $ResourceGroupName -AppName $VulnLabAppName -AutomationLogin $AutomationLogin
    } | Out-Null

    # 3.4.3 for the same reason as V10.1: a full merge trail through the
    # automation identity with every check green is change-control evidence, not
    # only flaw-remediation evidence.
    Invoke-MlsCriterion -Context $context -Id 'V10.2' -Control @('3.4.3', '3.14.1') `
        -Description 'For at least 2 of the 3 seeded dependency pins, the Dependabot trail holds (alert -> patch PR -> gauntlet green -> merged by automation -> new ACA revision -> alert fixed)' `
        -Command "gh api repos/$repositoryName/dependabot/alerts/<n> --jq '{state, created_at, dep:.dependency.package.name}'`ngh pr list --author `"app/dependabot`" --json number,title,headRefName`ngh api repos/$repositoryName/commits/<head-sha>/check-runs`ngh pr view <pr> --json mergedBy,autoMergeRequest,mergeCommit`naz containerapp revision list -g $ResourceGroupName -n $VulnLabAppName --query `"[].{name:name, created:properties.createdTime, healCommit:properties.template.containers[0].env[?name=='MLS_HEAL_COMMIT']|[0].value}`"`ngh api repos/$repositoryName/dependabot/alerts/<n> --jq '.state'" `
        -Expected "all six stages hold for at least $DependencyPassBar of the seeded pins (3/3 is the target, $DependencyPassBar/3 is the pass line)" `
        -RetryWindowMinutes $windowMinutes -InProcessWaitMinutes 0 -WindowStartUtc $windowStart -PendingWhenUnexpired:$pendingAllowed `
        -Test {
        Test-DependabotTrail -Repository $repositoryName -AlertNumber $dependabotAlert `
            -ResourceGroupName $ResourceGroupName -AppName $VulnLabAppName -AutomationLogin $AutomationLogin -PassBar $DependencyPassBar
    } | Out-Null

    # V10.3 - F123. THE CHAIN COULD NOT LOOK, AND SAID "NOTHING TO HEAL".
    #
    # The select job's alert read returned HTTP 403 on every run since the workflow
    # was written, and set `found=false` - the same output it sets when the
    # repository genuinely has no open alerts. Every lane skipped, the run reported
    # success, and BLOCKER-4 was recorded as "self-healing has nothing to heal"
    # while four Dependabot alerts sat open, one of them critical.
    #
    # The cause was a credential scope, not a permission grant: SELF_HEAL_TOKEN was
    # created as a `demo` ENVIRONMENT secret, and every job that consumes it -
    # here, in compliance.yml, in gitleaks.yml, in layer-09 - declares no
    # environment, so `secrets.SELF_HEAL_TOKEN` was empty and the `|| GITHUB_TOKEN`
    # fallback took over. GITHUB_TOKEN cannot read /dependabot/alerts. The rotation
    # table in gitleaks.yml, which CLAUDE.md designates as the source of truth,
    # says plainly that this one is a REPOSITORY secret.
    #
    # NO RETRY WINDOW. A 403 is settled the instant it is returned; there is no
    # propagation to wait on, and waiting would only make a permissions answer
    # arrive slower.
    Invoke-MlsCriterion -Context $context -Id 'V10.3' -Control @('3.4.3', '3.14.1') `
        -Description 'The self-heal chain could actually READ the alert surface - a denial is never recorded as "no alerts to heal"' `
        -Command "gh api repos/$repositoryName/dependabot/alerts?state=open (in the self-heal select job; its readable output is passed here)" `
        -Expected 'the select job reported readable=true' `
        -RetryWindowMinutes 0 `
        -Test {
            if ($AlertSurfaceReadable -eq 'true') {
                return New-MlsCheckResult -Passed $true -Observed 'the self-heal select job read the alert surface successfully'
            }
            if ($AlertSurfaceReadable -eq 'false') {
                return New-MlsCheckResult -Passed $false -Observed 'the self-heal select job could NOT read the alert surface (readable=false)' `
                    -Detail 'This is a DENIAL, not an empty alert list, and the chain must never report it as "nothing to heal" (F123). SELF_HEAL_TOKEN is a REPOSITORY secret per the rotation table in gitleaks.yml; if it was created as an environment secret it is invisible to every job that uses it, because none of them declares an environment, and the GITHUB_TOKEN fallback cannot read /dependabot/alerts.'
            }
            return New-MlsCheckResult -Passed $false -Observed "the self-heal chain did not report whether the alert surface was readable (value: '$AlertSurfaceReadable')" `
                -Detail 'UNOBSERVABLE, not healthy. The select job emits a readable output for exactly this criterion; an absent value means the audit was invoked without it, so nothing here can say whether the chain can see its own work.'
        } | Out-Null

    return $context
}

if (-not $env:MLS_SKIP_MAIN) {
    try {
        $auditContext = Invoke-Main -Repository $Repository -CodeQlAlertNumber $CodeQlAlertNumber `
            -AutofixPrNumber $AutofixPrNumber -DependabotAlertNumber $DependabotAlertNumber `
            -VulnLabAppName $VulnLabAppName -ResourceGroupName $ResourceGroupName -AutomationLogin $AutomationLogin `
            -ReseedMergedUtc $ReseedMergedUtc -ChainWindowHours $ChainWindowHours `
            -DependencyPassBar $DependencyPassBar -AlertSurfaceReadable $AlertSurfaceReadable `
            -ReportRoot $ReportRoot -NoRetry:$NoRetry `
            -OnlyCriterion $OnlyCriterion
    }
    catch {
        Write-MlsStatus -Message "layer-10-audit could not start: $($_.Exception.Message)" -Color Red
        exit 2
    }
    $reportFile = Write-MlsReport -Context $auditContext
    Write-MlsStatus -Message "report: $($reportFile.MarkdownPath)"
    exit (Get-MlsExitCode -Context $auditContext)
}
