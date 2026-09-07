#Requires -Version 7.0
<#
.SYNOPSIS
    L10 Verifier audit - the self-healing pipeline on GitHub Copilot Autofix. READ-ONLY.

.DESCRIPTION
    The OPERATIONS CYCLE, not a demonstration. Four criteria:

      V10.1  The backlog drains. No HEALABLE finding remains open past the SLO its
             severity declares. Reported per lane and per severity, never averaged - a
             blended figure hides the slice that is not moving.
      V10.2  Every closure is traceable. Each finding closed inside the declared window
             carries a complete heal trail, or an explicit record of being closed some
             other way. An unexplained closure fails.
      V10.3  The alert surface was READABLE. A denial is never recorded as "nothing to
             heal" (F123).
      V10.4  pending-solution is not a dumping ground. Every finding held there is checked
             against the advisory for an upstream fix that does exist.

    WHAT THIS REPLACED, AND WHY. V10.1 and V10.2 used to verify one SEEDED alert's
    seven-stage trail against apps/vuln-lab. That framing required the lab to always hold
    something to heal, which required re-arming, which is F190 - a pull request that
    reintroduces a critical alert cannot merge past code scanning protection without an
    administrator override. The entire apparatus existed to feed one hard-coded path
    filter, and it made the verification weaker rather than stronger: PR #225 was a correct
    Autofix heal of a REAL alert in apps/mcp-tools, and it could never complete a trail,
    because the wrong application deployed. L10.md conceded as much in its own words -
    nothing can prove healed code runs when the package is deliberately never deployed.

    THE STAGES SURVIVED. They live in Get-HealTrail and apply per healed finding: a merged
    pull request that explains the closure, a green gauntlet (skipped and neutral are not
    failures, and a run where nothing executed is not a pass), a merge PRE-AUTHORISED by
    auto-merge rather than chosen once the result was visible (F191 - the question is WHEN
    the decision was made, not who is credited with it), and the healed code actually
    running.

    THE DEPLOY STAGE IS WHERE THE MODEL CHANGED SHAPE. Old: did the vuln-lab witness roll?
    New: did the application this heal actually CHANGED receive a revision carrying the
    merge commit? The binding needs no cooperation from the applications, because every app
    CI already computes `tag="sha-${GITHUB_SHA:0:7}"` and GITHUB_SHA on a push to main IS
    the merge commit - so a revision whose image ends `:sha-<first 7>` is the estate's own
    record that this heal shipped. Two cases are REPORTED rather than failed: a heal
    touching no deployed application, and an application that is not deployed at all.

    THE SERVICE LEVEL IS DECLARED, NEVER DEFAULTED. .github/self-heal-policy.json carries
    it, and a missing or malformed policy makes the criteria SKIP rather than invent a pass
    line - this repository has twice been bitten by a criterion silently adopting a timeout
    nobody chose.

    apps/vuln-lab still exists and is no longer load-bearing for anything here. It is a
    manual demonstration generator: a deliberate way to arm a finding when the queue is
    empty or the chain needs exercising in front of an audience. Its manifests are listed
    under excludedPaths in the policy, so its knowingly-vulnerable pins do not age against
    an SLO the estate never intended to meet - and the audit reports how many findings were
    excluded, so an empty backlog cannot be manufactured by adding a path there unnoticed.

.EXAMPLE
    ./layer-10-audit.ps1 -Repository owner/repo -AlertSurfaceReadable true
#>
[CmdletBinding()]
param(
    [string]$Repository,
    [string]$ResourceGroupName = 'mls-rg-apps',
    # The estate's naming inputs, so a rebranded estate resolves its own container apps
    # rather than looking up names that no longer exist (F90).
    [string]$Prefix = 'mls',
    [string]$EnvironmentSegment = 'demo',
    # Both default to the repository's own copies; parameters exist so the tests can
    # supply fixtures without writing into .github/.
    [string]$PolicyPath = '',
    [string]$NamingBicepPath = '',
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

function Test-GauntletConclusion {
    <#
    .SYNOPSIS
        The gauntlet stage's verdict: nothing FAILED, and something actually ran.
    .DESCRIPTION
        This was `$_ -notlike '*=success'`, which counted SKIPPED as a failure. Every heal
        pull request carries five skipped `deploy to Container Apps` jobs - they only run
        on main - so the predicate marked the gauntlet not-green on every correct run.
        Verified on #174, #226 and #232: all three are exactly 5 skipped / 24 success. Run
        33934487531 failed V10.2 with "gauntlet not green: deploy to Container
        Apps=skipped" five times over, on a chain that had worked.

        Same shape as F191: a criterion asserting something that cannot be true when the
        system behaves correctly.

        Accepting `skipped` on its own would be the opposite trap - a pull request where
        NOTHING ran would sail through - so this asserts the capability rather than the
        artefact: no check failed, AND at least one check actually concluded successfully.
        `neutral` joins `skipped` as not-a-failure; CodeQL reports it on a pull request it
        has nothing to say about (observed on #225).
    .OUTPUTS
        A list of problems, empty when the gauntlet is green.
    #>
    param([AllowNull()][string[]]$Conclusion)
    $problem = [System.Collections.Generic.List[string]]::new()
    $entries = @($Conclusion | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($entries.Count -eq 0) {
        $problem.Add('no check runs on the heal PR head commit')
        return $problem
    }
    # A conclusion that is absent or empty means the check has not finished, which is not
    # a pass - it joins the failures rather than the benign set.
    $benign = @('success', 'skipped', 'neutral')
    $failed = @($entries | Where-Object {
            $value = ($_ -split '=', 2)[1]
            $benign -notcontains $value
        })
    $succeeded = @($entries | Where-Object { $_ -like '*=success' })
    if ($failed.Count -gt 0) { $problem.Add("gauntlet not green: $($failed -join ', ')") }
    elseif ($succeeded.Count -eq 0) {
        $problem.Add("no check run actually concluded successfully ($($entries.Count) reported, all skipped or neutral) - a gauntlet nothing ran is not a gauntlet that passed")
    }
    return $problem
}

function Get-SelfHealPolicy {
    <#
    .SYNOPSIS
        The DECLARED service levels. Never a default.
    .DESCRIPTION
        The design is explicit that the window is declared in configuration rather than
        inherited: "this repository has twice been bitten by criteria silently adopting a
        timeout nobody chose". So a missing or malformed policy is UNOBSERVABLE, not
        "assume 7 days" - a criterion that invents its own pass line measures nothing.
    .OUTPUTS
        The parsed policy, or $null when it cannot be read.
    #>
    param([AllowEmptyString()][string]$PolicyPath = '')
    if ([string]::IsNullOrWhiteSpace($PolicyPath) -or -not (Test-Path -LiteralPath $PolicyPath)) { return $null }
    try { return Get-Content -LiteralPath $PolicyPath -Raw | ConvertFrom-Json }
    catch { return $null }
}

function Get-AppKeyMap {
    <#
    .SYNOPSIS
        apps/<directory> -> the appKey infra/bicep/naming.bicep gives it.
    .DESCRIPTION
        Read from naming.bicep rather than restated here, because CLAUDE.md is explicit
        that a constant naming something in another system is resolved against that
        system. The map is NOT the identity function: apps/mcp-tools is keyed `mcp` and
        apps/directline-token is keyed `directline`, so assuming the directory name would
        look up container apps that do not exist and report a heal as undeployed.
    .OUTPUTS
        A hashtable of directory name -> appKey. Empty when naming.bicep cannot be read,
        which callers must treat as unobservable rather than as "no apps".
    #>
    param([Parameter(Mandatory)][string]$NamingBicepPath)
    $map = @{}
    if (-not (Test-Path -LiteralPath $NamingBicepPath)) { return $map }

    $inBlock = $false
    foreach ($raw in @(Get-Content -LiteralPath $NamingBicepPath)) {
        $line = "$raw".Trim()
        if ($line -match '^var\s+appKeys\s*=\s*\{') { $inBlock = $true; continue }
        if (-not $inBlock) { continue }
        if ($line -eq '}') { break }
        if ($line.StartsWith('//') -or $line.Length -eq 0) { continue }
        if ($line -match "^([A-Za-z0-9_]+)\s*:\s*'([^']+)'") {
            # camelCase identifier -> the kebab directory it corresponds to, plus the
            # explicit value. Both are recorded: the VALUE is the appKey, and the
            # directory is derived by kebab-casing the identifier.
            $identifier = $Matches[1]
            $key = $Matches[2]
            $directory = ($identifier -creplace '([a-z0-9])([A-Z])', '$1-$2').ToLowerInvariant()
            $map[$directory] = $key
        }
    }
    return $map
}

function Resolve-AffectedApp {
    <#
    .SYNOPSIS
        Which deployed applications a heal actually changed.
    .DESCRIPTION
        Replaces the seeded model's single hard-coded witness. The old deploy stage read
        revisions of mls-vuln-lab-demo-ca no matter what the heal touched, so PR #225 -
        a correct Autofix heal of a REAL alert in apps/mcp-tools - could never complete a
        trail, because the wrong application deployed. L10.md conceded the limitation in
        its own words: nothing can prove healed code runs when the package is deliberately
        never deployed.

        The path is the evidence: changed files -> apps/<dir>/** -> naming.bicep appKey ->
        <prefix>-<key>-<env>-ca.

        Two outcomes are REPORTED rather than failed, per the design:
          * a heal touching no application path (verification/, docs/, .github/) - no
            deploy assertion is possible, and saying so is honest where failing is not;
          * a heal touching several applications - all of them must roll.
    .OUTPUTS
        Directory, AppKey and ContainerApp for each application path the heal touched.
    #>
    param(
        [AllowNull()][string[]]$ChangedPath,
        [Parameter(Mandatory)][hashtable]$AppKeyMap,
        [Parameter(Mandatory)][string]$Prefix,
        [Parameter(Mandatory)][string]$EnvironmentSegment
    )
    $seen = [System.Collections.Generic.List[string]]::new()
    foreach ($path in @($ChangedPath | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
        if ("$path" -notmatch '^apps/([^/]+)/') { continue }
        $directory = $Matches[1]
        if (-not $AppKeyMap.ContainsKey($directory)) { continue }
        if (-not $seen.Contains($directory)) { $seen.Add($directory) }
    }
    return @($seen | ForEach-Object {
            [pscustomobject]@{
                Directory    = $_
                AppKey       = $AppKeyMap[$_]
                ContainerApp = "$Prefix-$($AppKeyMap[$_])-$EnvironmentSegment-ca"
            }
        })
}

function Get-RevisionCarryingCommit {
    <#
    .SYNOPSIS
        A revision of one container app that is running THIS merge commit's image.
    .DESCRIPTION
        The binding is the image tag, and it needs no cooperation from the applications.
        Every app CI computes `tag="sha-${GITHUB_SHA:0:7}"`, and on a push to main
        GITHUB_SHA is the merge commit - so a revision whose image ends `:sha-<first 7 of
        the merge commit>` is the estate's own record, read with Reader, that this heal
        shipped to this app.

        That is why it is not "some revision appeared after the merge", which any
        unrelated redeploy satisfies. It is also why the old MLS_HEAL_COMMIT stamp is not
        needed outside the witness: the tag already carries the commit.

        Absence of the app is distinguished from absence of the revision. `az` returning
        nothing for an app that does not exist is NOT evidence the heal failed to deploy -
        it is a different fact, and the caller reports it as one (the F63/F105 rule).
    .OUTPUTS
        AppExists, After, Matched, Tag - enough for the caller to phrase every case.
    #>
    param(
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string]$AppName,
        [AllowNull()][nullable[datetime]]$MergedUtc,
        [AllowEmptyString()][AllowNull()][string]$MergeCommit
    )
    $revisions = @(Invoke-MlsAz -AllowFailure -Argument @(
            'containerapp', 'revision', 'list', '--resource-group', $ResourceGroupName, '--name', $AppName,
            '--query', '[].{name:name, created:properties.createdTime, image:properties.template.containers[0].image}',
            '--output', 'json'
        ))
    $appExists = ($null -ne $revisions -and @($revisions).Count -gt 0)
    $result = [pscustomobject]@{ AppExists = $appExists; After = @(); Matched = @(); Tag = @() }
    if (-not $appExists -or $null -eq $MergedUtc) { return $result }

    $after = @($revisions | Where-Object {
            $slot = [datetime]::MinValue
            [datetime]::TryParse("$(Get-MlsProperty -InputObject $_ -Name 'created')", [ref]$slot) -and
            $slot.ToUniversalTime() -ge $MergedUtc
        })
    $result.After = $after
    $result.Tag = @($after | ForEach-Object { "$(Get-MlsProperty -InputObject $_ -Name 'image')" })
    if (-not [string]::IsNullOrWhiteSpace($MergeCommit)) {
        # The tag is the SHORT sha the app CI computes. Comparing the full oid would never
        # match, and comparing a prefix of the tag would match too much.
        $short = "$MergeCommit".Substring(0, [Math]::Min(7, "$MergeCommit".Length))
        $result.Matched = @($after | Where-Object {
                "$(Get-MlsProperty -InputObject $_ -Name 'image')" -like "*:sha-$short"
            })
    }
    return $result
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

function Select-ClosedAt {
    <#
    .SYNOPSIS
        When an alert closed: whichever stamp it actually carries, never both glued together.
    .DESCRIPTION
        GitHub can report fixed_at AND dismissed_at on the same alert - a fixed alert that
        someone later dismissed keeps both. Concatenating them yields a string no parser
        accepts, which drops the closure out of the audit window entirely and lets V10.2
        report "nothing to explain" over a closure that plainly happened. The most recent
        stamp is the one that describes the state the alert is in now.
    #>
    param([Parameter(Mandatory)]$Alert)
    $candidate = @(
        "$(Get-MlsProperty -InputObject $Alert -Name 'fixed_at')",
        "$(Get-MlsProperty -InputObject $Alert -Name 'dismissed_at')",
        "$(Get-MlsProperty -InputObject $Alert -Name 'auto_dismissed_at')"
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

    $latest = ''
    $latestSlot = [datetime]::MinValue
    foreach ($value in $candidate) {
        $slot = [datetime]::MinValue
        if ([datetime]::TryParse($value, [ref]$slot) -and $slot -ge $latestSlot) {
            $latestSlot = $slot
            $latest = $value
        }
    }
    return $latest
}

function Get-PullRequestFile {
    <# The paths a pull request changed - the input to the rewritten deploy stage. #>
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$Number
    )
    $response = Invoke-MlsGh -AllowFailure -Argument @('api', '--paginate', "repos/$Repository/pulls/$Number/files?per_page=100")
    return @(Get-MlsCollection -Response $response | ForEach-Object { "$(Get-MlsProperty -InputObject $_ -Name 'filename')" })
}

function Get-MergedHealPullRequest {
    <#
    .SYNOPSIS
        Merged pull requests in the window, as trail candidates.
    .DESCRIPTION
        Fetched once and reused for every closure rather than searched per finding: this
        audit runs against a rate-limited API, and a per-finding search turns one
        observation into dozens.
    #>
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][int]$LookbackDays
    )
    $response = Invoke-MlsGh -AllowFailure -Argument @(
        'pr', 'list', '--repo', $Repository, '--state', 'merged', '--limit', '100',
        '--json', 'number,title,body,mergedAt,headRefOid,mergeCommit,mergedBy,autoMergeRequest,author')
    if ($null -eq $response) { return @() }
    $since = [datetime]::UtcNow.AddDays(-$LookbackDays)
    return @(Get-MlsCollection -Response $response | Where-Object {
            $slot = [datetime]::MinValue
            [datetime]::TryParse("$(Get-MlsProperty -InputObject $_ -Name 'mergedAt')", [ref]$slot) -and
            $slot.ToUniversalTime() -ge $since
        })
}

function Get-HealTrail {
    <#
    .SYNOPSIS
        The seven stages, applied to ONE closed finding.
    .DESCRIPTION
        This is where the seeded model's stages survive. They are unchanged in substance -
        a pull request that explains the closure, a green gauntlet, a merge pre-authorised
        rather than chosen once the result was visible, and the healed code actually
        running - but they now attach to whatever was healed instead of to three pins
        somebody planted.

        The deploy stage is the part that changes shape. Old: did the vuln-lab witness
        roll? New: did the application this heal actually CHANGED receive a revision
        carrying the merge commit? A heal touching no deployed application is reported as
        exactly that rather than failed, because no deploy assertion is possible - and
        saying so is the honest answer where failing would be a lie about what was
        observed.
    .OUTPUTS
        Problem[] and Reference.
    #>
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)]$Finding,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Candidate,
        [Parameter(Mandatory)][hashtable]$AppKeyMap,
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string]$Prefix,
        [Parameter(Mandatory)][string]$EnvironmentSegment
    )
    $problem = [System.Collections.Generic.List[string]]::new()

    # Stage 1 - a pull request that plausibly explains this closure. Dependabot names the
    # package in its title; a code-scanning heal names the alert number in its body.
    $match = @($Candidate | Where-Object {
            $title = "$(Get-MlsProperty -InputObject $_ -Name 'title')"
            $body = "$(Get-MlsProperty -InputObject $_ -Name 'body')"
            if ($Finding.Lane -eq 'dependabot') {
                -not [string]::IsNullOrWhiteSpace($Finding.Package) -and $title -like "*$($Finding.Package)*"
            }
            else {
                $body -match "alert[^0-9]{0,12}$([regex]::Escape($Finding.Number))\b"
            }
        })
    if ($match.Count -eq 0) {
        $problem.Add('no merged pull request in the window explains it')
        return [pscustomobject]@{ Problem = $problem; Reference = '' }
    }
    $pullRequest = $match[0]
    $number = "$(Get-MlsProperty -InputObject $pullRequest -Name 'number')"
    $reference = "PR #$number"

    # Stage 2 - the gauntlet. Reused verbatim: SKIPPED and neutral are not failures, and a
    # pull request where nothing ran is not a pass (F-gauntlet).
    $headSha = "$(Get-MlsProperty -InputObject $pullRequest -Name 'headRefOid')"
    foreach ($entry in @(Test-GauntletConclusion -Conclusion (Get-CheckConclusion -Repository $Repository -HeadSha $headSha))) {
        $problem.Add($entry)
    }

    # Stage 3 - provenance. WHEN the decision was made, not who typed it (F191).
    $mergedAt = "$(Get-MlsProperty -InputObject $pullRequest -Name 'mergedAt')"
    foreach ($entry in @((Test-MergeProvenance -PullRequest $pullRequest -MergedAt $mergedAt).Problem)) {
        $problem.Add($entry)
    }

    # Stage 4 - the healed code is running.
    $mergeCommit = Get-MergeCommitSha -PullRequest $pullRequest
    $mergedUtc = $null
    $slot = [datetime]::MinValue
    if ([datetime]::TryParse($mergedAt, [ref]$slot)) { $mergedUtc = $slot.ToUniversalTime() }

    $affected = @(Resolve-AffectedApp -ChangedPath (Get-PullRequestFile -Repository $Repository -Number $number) `
            -AppKeyMap $AppKeyMap -Prefix $Prefix -EnvironmentSegment $EnvironmentSegment)
    if ($affected.Count -eq 0) {
        # REPORTED, not failed. The design names this case explicitly.
        return [pscustomobject]@{
            Problem   = $problem
            Reference = "$reference (no deployed application on its changed paths, so no deploy assertion is possible)"
        }
    }
    foreach ($app in $affected) {
        $revision = Get-RevisionCarryingCommit -ResourceGroupName $ResourceGroupName -AppName $app.ContainerApp `
            -MergedUtc $mergedUtc -MergeCommit $mergeCommit
        if (-not $revision.AppExists) {
            # Not a failure of the heal: the app is not deployed, or Reader cannot see it.
            $reference += " ($($app.ContainerApp) not deployed - no deploy assertion)"
            continue
        }
        if ($revision.Matched.Count -lt 1) {
            $short = if ($mergeCommit) { "$mergeCommit".Substring(0, [Math]::Min(7, "$mergeCommit".Length)) } else { '(none)' }
            $seen = if ($revision.Tag.Count -gt 0) { $revision.Tag -join ', ' } else { '(no revision after the merge)' }
            $problem.Add("$($app.ContainerApp) never ran this heal: no revision after the merge carries image tag sha-$short (saw: $seen)")
        }
    }
    return [pscustomobject]@{ Problem = $problem; Reference = $reference }
}

function Get-Finding {
    <#
    .SYNOPSIS
        Every Dependabot and code-scanning alert, normalised to one shape.
    .DESCRIPTION
        The seeded model asked about three pre-named alert numbers. The operations model
        asks about the whole surface, so the surface is what this reads.

        READABILITY IS ESTABLISHED BEFORE CONTENT. `gh api` returning nothing is
        indistinguishable from "no alerts" at the call site, and this repository has paid
        for that confusion three times in one night (F102/F103/F105). So each source
        reports Readable separately, and a caller that could not look must never report an
        empty backlog as a drained one.
    .OUTPUTS
        Finding[] plus DependabotReadable / CodeScanningReadable.
    #>
    param(
        [Parameter(Mandatory)][string]$Repository,
        [AllowNull()]$Policy
    )
    $excludedManifest = @()
    $excludedPrefix = @()
    if ($null -ne $Policy) {
        $excluded = Get-MlsProperty -InputObject $Policy -Name 'excludedPaths'
        $excludedManifest = @(Get-MlsProperty -InputObject $excluded -Name 'manifests')
        $excludedPrefix = @(Get-MlsProperty -InputObject $excluded -Name 'sourcePrefixes')
    }

    $finding = [System.Collections.Generic.List[object]]::new()

    # READABILITY COMES FROM WHETHER THE CALL SUCCEEDED, NEVER FROM WHETHER IT RETURNED
    # ANYTHING. `-AllowFailure` yields $null on a denial - and an empty JSON array yields
    # $null too, because PowerShell collapses an empty collection on return. Testing
    # `$null -ne $raw` therefore reports a healthy, genuinely empty alert surface as
    # UNREADABLE, and (far worse in the other direction) would let a denial masquerade as
    # emptiness the day the collapse behaviour differed. That is F102/F103/F105 exactly,
    # and under the operations model an empty queue is the EXPECTED steady state, so the
    # two states have to be told apart by construction rather than by luck.
    #
    # A throw is a denial; a successful call that returned nothing is an empty surface.
    $dependabotRaw = $null
    $dependabotReadable = $true
    try { $dependabotRaw = Invoke-MlsGh -Argument @(
            'api', '--paginate', "repos/$Repository/dependabot/alerts?state=all&per_page=100") }
    catch { $dependabotReadable = $false }
    foreach ($alert in @(Get-MlsCollection -Response $dependabotRaw)) {
        $dependency = Get-MlsProperty -InputObject $alert -Name 'dependency'
        $manifest = "$(Get-MlsProperty -InputObject $dependency -Name 'manifest_path')"
        $advisory = Get-MlsProperty -InputObject $alert -Name 'security_advisory'
        $vulnerability = Get-MlsProperty -InputObject $alert -Name 'security_vulnerability'
        $patched = "$(Get-MlsProperty -InputObject (Get-MlsProperty -InputObject $vulnerability -Name 'first_patched_version') -Name 'identifier')"
        $finding.Add([pscustomobject]@{
                Lane      = 'dependabot'
                Number    = "$(Get-MlsProperty -InputObject $alert -Name 'number')"
                State     = "$(Get-MlsProperty -InputObject $alert -Name 'state')"
                Severity  = "$(Get-MlsProperty -InputObject $advisory -Name 'severity')".ToLowerInvariant()
                Package   = "$(Get-MlsProperty -InputObject (Get-MlsProperty -InputObject $dependency -Name 'package') -Name 'name')"
                Path      = $manifest
                CreatedAt = "$(Get-MlsProperty -InputObject $alert -Name 'created_at')"
                # Chosen, not concatenated. An alert can carry BOTH stamps - GitHub keeps
                # fixed_at after a later dismissal - and gluing them together produced an
                # unparseable string, so the closure silently fell out of the window and
                # V10.2 reported "nothing to explain" over a real closure.
                ClosedAt  = (Select-ClosedAt -Alert $alert)
                Reason    = "$(Get-MlsProperty -InputObject $alert -Name 'dismissed_reason')"
                FixExists = (-not [string]::IsNullOrWhiteSpace($patched))
                FixVersion = $patched
                Excluded  = ($excludedManifest -contains $manifest)
            })
    }

    $codeRaw = $null
    $codeReadable = $true
    try { $codeRaw = Invoke-MlsGh -Argument @(
            'api', '--paginate', "repos/$Repository/code-scanning/alerts?state=all&per_page=100") }
    catch { $codeReadable = $false }
    foreach ($alert in @(Get-MlsCollection -Response $codeRaw)) {
        $rule = Get-MlsProperty -InputObject $alert -Name 'rule'
        $path = "$(Get-MlsProperty -InputObject (Get-MlsProperty -InputObject (Get-MlsProperty -InputObject $alert -Name 'most_recent_instance') -Name 'location') -Name 'path')"
        # security_severity_level is the CVSS-aligned band and is absent on non-security
        # rules; `severity` (note/warning/error) is the fallback so nothing lands with a
        # blank band and silently misses every SLO comparison.
        $severity = "$(Get-MlsProperty -InputObject $rule -Name 'security_severity_level')"
        if ([string]::IsNullOrWhiteSpace($severity)) { $severity = "$(Get-MlsProperty -InputObject $rule -Name 'severity')" }
        $excludedBySource = $false
        foreach ($prefix in $excludedPrefix) {
            if (-not [string]::IsNullOrWhiteSpace($prefix) -and $path.StartsWith($prefix)) { $excludedBySource = $true; break }
        }
        # THE CODE-SCANNING SURFACE CARRIES TWO OF THE THREE LANES, AND THEY ARE NOT THE
        # SAME SHAPE. The design's section 2 is explicit: lanes 1 and 2 produce COMMITS,
        # lane 3 produces AN ARTIFACT - "there is nothing to merge, because nothing in the
        # repository changes".
        #
        # Trivy uploads container-image findings as SARIF, and they close when a rebuilt
        # image no longer contains them. No pull request is involved, ever. V10.2 shipped
        # demanding a merged heal trail for every closure and reported 397 of 400 as
        # unexplained on its first real run - asking lane 3 for evidence that structurally
        # cannot exist. The lane is read from the tool that reported the finding rather
        # than guessed from the path, because a container finding's path is an image
        # reference, not a file in this repository.
        $tool = "$(Get-MlsProperty -InputObject (Get-MlsProperty -InputObject $alert -Name 'tool') -Name 'name')"
        $lane = if ($tool -eq 'Trivy') { 'container-image' } else { 'code-scanning' }
        $finding.Add([pscustomobject]@{
                Lane      = $lane
                Number    = "$(Get-MlsProperty -InputObject $alert -Name 'number')"
                State     = "$(Get-MlsProperty -InputObject $alert -Name 'state')"
                Severity  = "$severity".ToLowerInvariant()
                Package   = "$(Get-MlsProperty -InputObject $rule -Name 'id')"
                Path      = $path
                CreatedAt = "$(Get-MlsProperty -InputObject $alert -Name 'created_at')"
                ClosedAt  = (Select-ClosedAt -Alert $alert)
                Reason    = "$(Get-MlsProperty -InputObject $alert -Name 'dismissed_reason')"
                # Autofix covers CodeQL alerts as a class; there is no per-alert "a fix
                # exists" field to read without asking Autofix to generate one, which an
                # audit must never do. Dependency findings carry first_patched_version and
                # are where V10.4's question can be answered definitively.
                FixExists = $true
                FixVersion = ''
                Excluded  = $excludedBySource
            })
    }

    return [pscustomobject]@{
        Finding             = @($finding)
        DependabotReadable  = $dependabotReadable
        CodeScanningReadable = $codeReadable
    }
}

function Get-SloDay {
    <# The declared SLO for a severity band, or 0 when the policy does not name it. #>
    param([AllowNull()]$Policy, [AllowEmptyString()][string]$Severity)
    $days = Get-MlsProperty -InputObject (Get-MlsProperty -InputObject $Policy -Name 'slo') -Name 'days'
    if ($null -eq $days) { return 0 }
    $value = Get-MlsProperty -InputObject $days -Name "$Severity"
    if ($null -eq $value) { return 0 }
    return [int]$value
}

function Test-BacklogDrain {
    <#
    .SYNOPSIS
        V10.1 - no HEALABLE finding remains open past its declared SLO.
    .DESCRIPTION
        Replaces "the seeded CodeQL alert's seven-stage trail". The stages did not vanish;
        they moved to V10.2, where they apply per healed finding instead of to a pre-named
        one. What this asserts now is the thing an operations cycle actually promises: the
        queue drains.

        Reported per lane and per severity, NEVER averaged - a blended figure hides the
        slice that is not moving, which is the failure the compliance platform exists to
        avoid.

        A finding with no upstream fix does not consume its SLO. It is pending-solution,
        which holds and ages legitimately, and V10.4 is what stops that becoming a place
        where a backlog goes to die quietly.
    #>
    param(
        [Parameter(Mandatory)]$Surface,
        [AllowNull()]$Policy,
        [Parameter(Mandatory)][datetime]$NowUtc
    )
    if ($null -eq $Policy) {
        return New-MlsCheckResult -Status SKIP -Observed 'no declared self-heal policy: .github/self-heal-policy.json was not found or is malformed' `
            -Detail 'The design requires the SLO to be DECLARED rather than inherited from a default, so this criterion refuses to invent one. Create the file with an slo.days map per severity.'
    }
    if (-not $Surface.DependabotReadable -or -not $Surface.CodeScanningReadable) {
        return New-MlsCheckResult -Status SKIP `
            -Observed "alert surface not fully readable (dependabot=$($Surface.DependabotReadable) code-scanning=$($Surface.CodeScanningReadable))" `
            -Detail 'UNOBSERVABLE, never "the backlog is empty". An identity that cannot read an alert surface must not be able to report it drained (F103/F105).'
    }

    $open = @($Surface.Finding | Where-Object { $_.State -eq 'open' })
    $excluded = @($open | Where-Object { $_.Excluded })
    $counted = @($open | Where-Object { -not $_.Excluded })
    $pending = @($counted | Where-Object { -not $_.FixExists })
    $healable = @($counted | Where-Object { $_.FixExists })

    # A LANE WHOSE MECHANISM DOES NOT EXIST YET, DEFERRED WITH AN EXPIRY DATE.
    #
    # Lane 3 is entitlement-blocked - ACR Tasks returns TasksOperationsNotAllowed on this
    # subscription - and its scheduled-rebuild fallback is not built. Its findings are a
    # real backlog with no automation reaching them, so counting them against a heal SLO
    # states something true and useless: it fails every run for a reason nobody can act on
    # from here.
    #
    # THE EXPIRY IS THE WHOLE POINT. An exclusion that cannot expire is precisely the
    # dumping ground V10.4 exists to prevent, one level up - so this one stops applying by
    # itself on a date declared in git, and the criterion goes red again if the lane still
    # has no mechanism. It is a deadline, not an amnesty, and the observed line carries the
    # count and the days remaining on every run so it can never be quietly forgotten.
    $deferralNote = ''
    $deferred = @()
    $deferralConfig = Get-MlsProperty -InputObject $Policy -Name 'laneDeferral'
    if ($null -ne $deferralConfig) {
        foreach ($lane in @($healable | Select-Object -ExpandProperty Lane -Unique)) {
            $entry = Get-MlsProperty -InputObject $deferralConfig -Name $lane
            if ($null -eq $entry) { continue }
            $expiry = [datetime]::MinValue
            if (-not [datetime]::TryParse("$(Get-MlsProperty -InputObject $entry -Name 'expires')", [ref]$expiry)) { continue }
            if ($NowUtc -ge $expiry.ToUniversalTime()) {
                $deferralNote += " | DEFERRAL EXPIRED for lane '$lane' on $($expiry.ToString('yyyy-MM-dd')): its findings now count"
                continue
            }
            $inLane = @($healable | Where-Object { $_.Lane -eq $lane })
            $deferred += $inLane
            $left = [math]::Ceiling(($expiry.ToUniversalTime() - $NowUtc).TotalDays)
            $deferralNote += " | lane '$lane' deferred: $($inLane.Count) finding(s), expires $($expiry.ToString('yyyy-MM-dd')) ($left d left) - $(Get-MlsProperty -InputObject $entry -Name 'reason')"
        }
        if ($deferred.Count -gt 0) {
            $healable = @($healable | Where-Object { $deferred -notcontains $_ })
        }
    }

    $breach = [System.Collections.Generic.List[string]]::new()
    foreach ($item in $healable) {
        $slo = Get-SloDay -Policy $Policy -Severity $item.Severity
        if ($slo -le 0) {
            $breach.Add("#$($item.Number) $($item.Lane)/$($item.Severity) $($item.Package) - the policy declares no SLO for severity '$($item.Severity)', so this finding is not measurable")
            continue
        }
        $created = [datetime]::MinValue
        if (-not [datetime]::TryParse($item.CreatedAt, [ref]$created)) { continue }
        $age = ($NowUtc - $created.ToUniversalTime()).TotalDays
        if ($age -gt $slo) {
            $breach.Add("#$($item.Number) $($item.Lane)/$($item.Severity) $($item.Package) open $([math]::Floor($age))d, SLO ${slo}d ($($item.Path))")
        }
    }

    $byLane = @($healable | Group-Object Lane | ForEach-Object { "$($_.Name)=$($_.Count)" })
    $bySeverity = @($healable | Group-Object Severity | ForEach-Object { "$($_.Name)=$($_.Count)" })
    $observed = "healable open: $(if ($byLane) { $byLane -join ' ' } else { 'none' }) | by severity: $(if ($bySeverity) { $bySeverity -join ' ' } else { 'none' }) | pending-solution: $($pending.Count) | excluded by policy: $($excluded.Count)$deferralNote"

    if ($breach.Count -gt 0) {
        return New-MlsCheckResult -Passed $false `
            -Observed "$observed | PAST SLO: $($breach -join '; ')" `
            -Detail 'Each of these has an upstream fix and has outlived its declared service level. Either the chain is not reaching them or the fix generator produced nothing to adopt - the per-lane counts above say which.'
    }
    return New-MlsCheckResult -Passed $true -Observed $observed
}

function Test-ClosureTraceable {
    <#
    .SYNOPSIS
        V10.2 - every closure inside the declared window is explained.
    .DESCRIPTION
        The seven stages live here now, applied per healed finding rather than to three
        pre-named pins. For each alert closed in the window, either a self-heal pull
        request explains it with a complete trail, or the closure is explicitly recorded
        as having happened another way.

        "Explicitly recorded" is GitHub's own dismissal record, not a file this repository
        invents: a dismissed alert carries who dismissed it and why. A FIXED alert with no
        heal pull request behind it is the case that fails - something closed it and the
        estate cannot say what, which is precisely the property an auditor is buying.
    #>
    param(
        [Parameter(Mandatory)]$Surface,
        [AllowNull()]$Policy,
        [Parameter(Mandatory)][datetime]$NowUtc,
        [Parameter(Mandatory)][scriptblock]$TrailFor
    )
    if ($null -eq $Policy) {
        return New-MlsCheckResult -Status SKIP -Observed 'no declared self-heal policy, so the closure window is undefined' `
            -Detail 'Declare closureLookbackDays in .github/self-heal-policy.json.'
    }
    if (-not $Surface.DependabotReadable -or -not $Surface.CodeScanningReadable) {
        return New-MlsCheckResult -Status SKIP `
            -Observed "alert surface not fully readable (dependabot=$($Surface.DependabotReadable) code-scanning=$($Surface.CodeScanningReadable))" `
            -Detail 'UNOBSERVABLE. A surface that cannot be read cannot be reported as having no unexplained closures.'
    }

    $lookback = [int]"$(Get-MlsProperty -InputObject (Get-MlsProperty -InputObject $Policy -Name 'closureLookbackDays') -Name 'value')"
    if ($lookback -le 0) {
        return New-MlsCheckResult -Status SKIP -Observed 'the policy declares no closureLookbackDays, so there is no window to audit' `
            -Detail 'Declare closureLookbackDays.value in .github/self-heal-policy.json rather than letting this criterion choose one.'
    }
    $since = $NowUtc.AddDays(-$lookback)

    $closed = @($Surface.Finding | Where-Object {
            $_.State -ne 'open' -and -not $_.Excluded -and (& {
                $slot = [datetime]::MinValue
                [datetime]::TryParse($_.ClosedAt, [ref]$slot) -and $slot.ToUniversalTime() -ge $since
            })
        })

    if ($closed.Count -eq 0) {
        return New-MlsCheckResult -Passed $true -Observed "no finding closed in the last ${lookback}d, so there is nothing to explain"
    }

    $explained = [System.Collections.Generic.List[string]]::new()
    $unexplained = [System.Collections.Generic.List[string]]::new()
    $rebuilt = 0
    foreach ($item in $closed) {
        # LANE 3 CLOSES BY REBUILD, NOT BY MERGE. The design's section 2 says lane 3
        # produces an artifact and nothing in the repository changes, so a container-image
        # finding that stopped appearing in a rescan has no pull request behind it and
        # never could. Demanding one reported 397 of 400 closures as unexplained on the
        # first real run - a category error, not a finding about the estate.
        #
        # It is COUNTED AND NAMED rather than dropped: a closure this criterion does not
        # trail is still a closure the report has to account for, and a silent skip would
        # be indistinguishable from a lane nobody is watching.
        if ($item.Lane -eq 'container-image') { $rebuilt++; continue }
        if ($item.State -like '*dismissed*') {
            $reason = if ([string]::IsNullOrWhiteSpace($item.Reason)) { '(no reason recorded)' } else { $item.Reason }
            if ([string]::IsNullOrWhiteSpace($item.Reason)) {
                $unexplained.Add("#$($item.Number) $($item.Lane) $($item.Package) dismissed with NO recorded reason")
            }
            else {
                $explained.Add("#$($item.Number) dismissed:$reason")
            }
            continue
        }
        $trail = & $TrailFor $item
        if ($trail.Problem.Count -eq 0) { $explained.Add("#$($item.Number) healed:$($trail.Reference)") }
        else { $unexplained.Add("#$($item.Number) $($item.Lane) $($item.Package) fixed but $($trail.Problem -join '; ')") }
    }

    $observed = "$($closed.Count) closure(s) in ${lookback}d - explained: $($explained.Count), closed by image rebuild (lane 3): $rebuilt, unexplained: $($unexplained.Count)"
    if ($unexplained.Count -gt 0) {
        return New-MlsCheckResult -Passed $false -Observed "$observed | $($unexplained -join ' | ')" `
            -Detail 'A closure the estate cannot account for is the failure this criterion exists to catch: either automation closed it and the trail is broken, or a human did and nothing recorded that.'
    }
    return New-MlsCheckResult -Passed $true -Observed "$observed | $($explained -join ' ')"
}

function Test-PendingSolution {
    <#
    .SYNOPSIS
        V10.4 - pending-solution is not a dumping ground.
    .DESCRIPTION
        pending-solution legitimately does not count as failure, which makes it the
        obvious place for a backlog to go and die quietly. So every finding excused from
        V10.1 on the grounds that no upstream fix exists has that claim CHECKED against
        the advisory rather than believed.

        This is the artefact-instead-of-capability trap the repository keeps paying for,
        one level up: an unverified "no fix available" is exactly the kind of comfortable
        answer nothing was asserting.
    #>
    param(
        [Parameter(Mandatory)]$Surface,
        [Parameter(Mandatory)][string]$Repository
    )
    if (-not $Surface.DependabotReadable) {
        return New-MlsCheckResult -Status SKIP -Observed 'the Dependabot alert surface was not readable' `
            -Detail 'UNOBSERVABLE. Never report an empty pending-solution set from a surface that could not be read.'
    }

    $pending = @($Surface.Finding | Where-Object { $_.State -eq 'open' -and -not $_.Excluded -and -not $_.FixExists })
    if ($pending.Count -eq 0) {
        return New-MlsCheckResult -Passed $true -Observed 'no finding is being held as pending-solution'
    }

    $wrong = [System.Collections.Generic.List[string]]::new()
    foreach ($item in $pending) {
        if ($item.Lane -ne 'dependabot') { continue }
        # Re-read the alert on its own rather than trusting the list projection: this is
        # the claim the whole state rests on, and it is one call per held finding.
        $fresh = Invoke-MlsGh -AllowFailure -Argument @('api', "repos/$Repository/dependabot/alerts/$($item.Number)")
        if ($null -eq $fresh) {
            $wrong.Add("#$($item.Number) could not be re-read, so 'no fix exists' is unverified")
            continue
        }
        $patched = "$(Get-MlsProperty -InputObject (Get-MlsProperty -InputObject (Get-MlsProperty -InputObject $fresh -Name 'security_vulnerability') -Name 'first_patched_version') -Name 'identifier')"
        if (-not [string]::IsNullOrWhiteSpace($patched)) {
            $wrong.Add("#$($item.Number) $($item.Package) is held as pending-solution but the advisory names a patched version: $patched")
        }
    }

    $observed = "$($pending.Count) finding(s) held as pending-solution; $($wrong.Count) with a fix that does exist"
    if ($wrong.Count -gt 0) {
        return New-MlsCheckResult -Passed $false -Observed "$observed | $($wrong -join ' | ')" `
            -Detail 'A finding parked as unfixable while an upstream fix exists is a backlog hiding inside a state that never fails. Bump it or record why the named version is not adoptable.'
    }
    return New-MlsCheckResult -Passed $true -Observed $observed
}

function Invoke-Main {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
        Justification = 'Every parameter is consumed inside the criterion scriptblocks; PSSA cannot see through scriptblock closures.')]
    param(
        [string]$Repository,
        [string]$ResourceGroupName = 'mls-rg-apps',
        [string]$Prefix = 'mls',
        [string]$EnvironmentSegment = 'demo',
        [string]$PolicyPath = '',
        [string]$NamingBicepPath = '',
        [string]$AlertSurfaceReadable = '',
        [string]$ReportRoot,
        [switch]$NoRetry,
        [string[]]$OnlyCriterion = @()
    )
    $repositoryName = Resolve-MlsInput -Name 'Repository' -Value $Repository -EnvironmentVariable @('MLS_GITHUB_REPO', 'MLS_REPOSITORY') `
        -Hint 'The public repo the healing trail lives on.'
    Resolve-MlsInput -Name 'GitHubToken' -Value '' -EnvironmentVariable @('MLS_VERIFIER_GH_TOKEN', 'GH_TOKEN', 'GITHUB_TOKEN') `
        -Hint "The Verifier's own GitHub read token (spec F8); these criteria are mostly GitHub reads." | Out-Null

    $repoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath '..')).Path
    $policyPath = $PolicyPath
    if ([string]::IsNullOrWhiteSpace($policyPath)) {
        $policyPath = Join-Path -Path $repoRoot -ChildPath '.github' -AdditionalChildPath 'self-heal-policy.json'
    }
    $namingPath = $NamingBicepPath
    if ([string]::IsNullOrWhiteSpace($namingPath)) {
        $namingPath = Join-Path -Path $repoRoot -ChildPath 'infra' -AdditionalChildPath 'bicep', 'naming.bicep'
    }

    $policy = Get-SelfHealPolicy -PolicyPath $policyPath
    $appKeyMap = Get-AppKeyMap -NamingBicepPath $namingPath
    $surface = Get-Finding -Repository $repositoryName -Policy $policy
    $now = [datetime]::UtcNow

    # Fetched once, here, and closed over by V10.2's trail lookup. One page of merged
    # pull requests answers every closure; a per-finding search would turn a single
    # observation into dozens against a rate-limited API.
    $healCandidate = @()
    if ($null -ne $policy) {
        $healCandidate = @(Get-MergedHealPullRequest -Repository $repositoryName `
                -LookbackDays ([int]"$(Get-MlsProperty -InputObject (Get-MlsProperty -InputObject $policy -Name 'closureLookbackDays') -Name 'value')"))
    }

    $context = New-MlsAuditContext -Layer 10 -Title 'Self-healing pipeline - operations cycle' `
        -ScriptName 'verification/layer-10-audit.ps1' -ReportRoot $ReportRoot -NoRetry:$NoRetry `
        -OnlyCriterion $OnlyCriterion
    Add-MlsPreflight -Context $context -Name 'Repository' -Value $repositoryName
    Add-MlsPreflight -Context $context -Name 'Declared policy' -Value $policyPath `
        -Status $(if ($null -ne $policy) { 'OK' } else { 'ABSENT' })
    Add-MlsPreflight -Context $context -Name 'Alert surface readable' `
        -Value "dependabot=$($surface.DependabotReadable) code-scanning=$($surface.CodeScanningReadable)" `
        -Status $(if ($surface.DependabotReadable -and $surface.CodeScanningReadable) { 'OK' } else { 'ABSENT' })
    Add-MlsPreflight -Context $context -Name 'Application key map' -Value "$($appKeyMap.Count) app(s) from naming.bicep" `
        -Status $(if ($appKeyMap.Count -gt 0) { 'OK' } else { 'ABSENT' })

    if ($null -eq $policy) {
        Add-MlsNote -Context $context -Message "No declared self-heal policy at $policyPath. The service level must be DECLARED, not inherited from a default, so the criteria that depend on it report SKIP rather than inventing a pass line."
    }

    # THE SEEDED MODEL IS GONE, AND WITH IT THE ONLY REASON THIS LAYER NEEDED A PLANT.
    #
    # V10.1 and V10.2 used to verify ONE seeded alert's seven-stage trail against
    # apps/vuln-lab. That framing required the lab to always contain something to heal,
    # which required re-arming, which is F190: a pull request that reintroduces a critical
    # alert cannot merge past code scanning protection without an administrator override.
    # The whole apparatus existed to feed one hard-coded path filter, and PR #225 proved
    # what it cost - a correct Autofix heal of a REAL alert could not complete a trail,
    # because the wrong application deployed.
    #
    # The stages did not die; they moved to V10.2 and apply per healed finding. What the
    # criteria assert now is what an operations cycle actually promises: no findings; one
    # arrives; it is healed; back to no findings.

    Invoke-MlsCriterion -Context $context -Id 'V10.1' -Control @('3.4.3', '3.14.1') `
        -Description 'The backlog drains: no healable finding remains open past its declared SLO, reported per lane and per severity' `
        -Command "gh api repos/$repositoryName/dependabot/alerts?state=all`ngh api repos/$repositoryName/code-scanning/alerts?state=all`ncat .github/self-heal-policy.json" `
        -Expected 'every open finding with an upstream fix is inside the SLO its severity declares' `
        -RetryWindowMinutes 0 `
        -Test { Test-BacklogDrain -Surface $surface -Policy $policy -NowUtc $now } | Out-Null

    # 3.4.3 for the reason V10.1 used to carry it: a full merge trail through a
    # pre-authorised auto-merge with every check green is change-control evidence, not only
    # flaw-remediation evidence. It is stronger here than in the seeded model, because it
    # now attaches to whatever the estate actually healed rather than to a planted example.
    Invoke-MlsCriterion -Context $context -Id 'V10.2' -Control @('3.4.3', '3.14.1') `
        -Description 'Every closure is traceable: each finding closed in the declared window carries a complete heal trail, or an explicit record of being closed another way' `
        -Command "gh api repos/$repositoryName/dependabot/alerts?state=all`ngh pr list --repo $repositoryName --state merged --json number,mergedAt,mergeCommit,autoMergeRequest`ngh api repos/$repositoryName/commits/<head>/check-runs`naz containerapp revision list -g $ResourceGroupName -n <app> --query `"[].{created:properties.createdTime, image:properties.template.containers[0].image}`"" `
        -Expected 'for every closure: a merged heal PR whose gauntlet was green, whose merge was pre-authorised by auto-merge, and whose changed applications each ran a revision tagged with the merge commit - or a dismissal carrying a recorded reason' `
        -RetryWindowMinutes 0 `
        -Test {
        Test-ClosureTraceable -Surface $surface -Policy $policy -NowUtc $now -TrailFor {
            param($Finding)
            # $healCandidate is resolved ONCE, above, and closed over. It used to be a
            # lazy `if (-not $script:HealCandidate)` cache, which threw on the first call
            # under Set-StrictMode -Version Latest - reading a variable that has never
            # been assigned is an error, not $null, and the criterion recorded
            # "check threw: The variable '$script:HealCandidate' cannot be retrieved".
            #
            # The unit tests did not catch it because the harness set
            # $script:HealCandidate = $null in BeforeEach. That is a test SUPPLYING the
            # answer it is checking, which CLAUDE.md names as not a test at all - the
            # fixture created the very precondition production lacked.
            Get-HealTrail -Repository $repositoryName -Finding $Finding -Candidate $healCandidate `
                -AppKeyMap $appKeyMap -ResourceGroupName $ResourceGroupName `
                -Prefix $Prefix -EnvironmentSegment $EnvironmentSegment
        }
    } | Out-Null

    # V10.3 - F123. THE CHAIN COULD NOT LOOK, AND SAID "NOTHING TO HEAL".
    #
    # Unchanged by the operations model, and more load-bearing under it than before: with
    # no planted alert guaranteeing the queue is non-empty, "no findings" is the EXPECTED
    # steady state. A denial that reads as an empty queue would therefore look exactly like
    # success, every time, forever.
    #
    # NO RETRY WINDOW. A 403 is settled the instant it is returned.
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

    # V10.4 - THE STATE THAT NEVER FAILS IS THE ONE TO WATCH.
    #
    # pending-solution legitimately does not count as a breach, which makes it the obvious
    # place for a backlog to go and die quietly. Every finding excused from V10.1 on the
    # grounds that no upstream fix exists has that claim checked against the advisory, one
    # call per held finding, rather than believed.
    Invoke-MlsCriterion -Context $context -Id 'V10.4' -Control @('3.4.3', '3.14.1') `
        -Description 'pending-solution is not a dumping ground: for every finding held there, no upstream fix actually exists' `
        -Command "gh api repos/$repositoryName/dependabot/alerts/<n> --jq '.security_vulnerability.first_patched_version.identifier'" `
        -Expected 'every finding held as pending-solution has no first_patched_version in its advisory' `
        -RetryWindowMinutes 0 `
        -Test { Test-PendingSolution -Surface $surface -Repository $repositoryName } | Out-Null

    return $context
}

if (-not $env:MLS_SKIP_MAIN) {
    try {
        $auditContext = Invoke-Main -Repository $Repository -ResourceGroupName $ResourceGroupName `
            -Prefix $Prefix -EnvironmentSegment $EnvironmentSegment `
            -PolicyPath $PolicyPath -NamingBicepPath $NamingBicepPath `
            -AlertSurfaceReadable $AlertSurfaceReadable `
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
