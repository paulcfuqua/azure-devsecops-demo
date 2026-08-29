#Requires -Version 7.0
<#
.SYNOPSIS
    Light the fuse: dispatch .github/workflows/infra-up.yml and watch it to the end.

.DESCRIPTION
    The local entry point for a full instantiation of the demo estate. It is a THIN
    wrapper: every deployment decision lives in the workflow and the per-layer
    workflows it calls (docs/runbooks/kill-rebuild.md section 4). This script's job is
    to make the tenant activation feel like turning a key rather than starting a
    project, which means three things:

      1. FAIL BEFORE IT DISPATCHES. gh present, gh authenticated, a repository it can
         resolve, and the four `demo` environment variables the workflow's pre-G0
         guard requires. Without that last check the run would dispatch, the guard
         would report configured=false, every layer would skip, and the run would go
         GREEN - which is correct behaviour for CI and a terrible experience for an
         operator who just asked for an estate. So the check happens here, and the
         message names the exact variables and the exact command that sets them.

      2. WATCH IT, DO NOT JUST LAUNCH IT. The run is polled to completion and the
         per-leg result table is printed - the same legs as the workflow's own
         summary, so the console and the Actions page agree.

      3. REPORT THE WALL CLOCK, AND HAND IT OVER. L11's proof is "<60 minutes" and it
         is measured on exactly this path (kill-rebuild.md section 5: clock starts at
         up.ps1 invocation, stops at the last synchronous layer audit green). The
         elapsed time is reported from TWO independent sources - this script's own
         timestamps and GitHub's run timestamps - because that is what the proof
         record requires.

         Printing it is not enough. verification/layer-11-audit.ps1's V11.4 needs
         those two instants as -UpStartUtc / -UpCompletedUtc (or MLS_L11_UP_START /
         MLS_L11_UP_COMPLETED) and, given neither, records a FAIL rather than
         inventing a start time - which is the right refusal and a broken handoff.
         So the clock is written DURABLY to verification/reports/up-clock.json, and
         to $GITHUB_ENV when this runs inside Actions, and the exact re-run command
         is printed with the timestamps already substituted.

    Never writes to Azure itself and never calls the Azure APIs. The only credential
    involved is the operator's own `gh` login; the deployment authenticates by OIDC
    inside the runner (CLAUDE.md hard rule 5).

.PARAMETER Repository
    owner/name. Defaults to whatever `gh` resolves for the current directory.

.PARAMETER Mode
    full = layer-ordered instantiation; oidc-smoke = the login job only (L1 V1.1).

.PARAMETER Layers
    Selective replay: 'all', 'none', or a comma list such as 'l5,l6'.

.PARAMETER Location
    Azure region passed to every layer.

.PARAMETER ImageTag
    GHCR tag for the L7/L8 app deployments. Empty keeps the placeholder image.

.PARAMETER DryRun
    Runs the workflow in plan-only mode (what-if / -WhatIf inside every layer).
    This is a REMOTE dry run and still dispatches a run - not the same thing as
    -WhatIf, which dispatches nothing at all.

.PARAMETER NoWatch
    Dispatch and return immediately. Skips the result table and the wall clock.

.PARAMETER TimeoutMinutes
    How long to watch before giving up on the run (the run itself keeps going).

.PARAMETER ReportRoot
    Where the clock record is written. Defaults to verification/reports/ - the
    directory the Verifier's own reports live in, so the wall-clock evidence sits
    next to the audit that cites it.

.EXAMPLE
    pwsh scripts/up.ps1
    # The standard rebuild. Prints the plan, dispatches, watches, reports the clock.

.EXAMPLE
    pwsh scripts/up.ps1 -WhatIf
    # Prints the exact `gh workflow run` command and dispatches nothing.

.EXAMPLE
    pwsh scripts/up.ps1 -Layers l5,l6
    # Selective replay of just the Fabric and platform legs.

.NOTES
    Runbook: docs/runbooks/kill-rebuild.md sections 4 and 5.
    Teardown counterpart: scripts/down.ps1.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidatePattern('^[\w.-]+/[\w.-]+$')]
    [string]$Repository,

    [ValidateSet('full', 'oidc-smoke')]
    [string]$Mode = 'full',

    [string]$Layers = 'all',

    # EMPTY BY DEFAULT, and deliberately so. This used to read 'eastus', which is a
    # region the estate cannot deploy into on a trial subscription (F52) - and because
    # this value is passed as a workflow INPUT it silently overrode
    # vars.AZURE_LOCATION, so setting the demo environment variable appeared to do
    # nothing. Empty means "use the demo environment's AZURE_LOCATION", which is the
    # single source of truth; pass -Location only to override it for one run (F53).
    [string]$Location = '',

    [string]$ImageTag = '',

    [switch]$DryRun,

    [switch]$NoWatch,

    [ValidateRange(1, 240)]
    [int]$TimeoutMinutes = 90,

    [ValidateRange(2, 120)]
    [int]$PollSeconds = 15,

    [string]$ReportRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:WorkflowFile = 'infra-up.yml'

# The variables infra-up.yml's `demo-env-guard` requires. If any is absent the run
# dispatches, skips every layer and reports success - so this list is the single
# most load-bearing thing in the script.
$script:RequiredDemoVariables = @(
    'AZURE_CLIENT_ID'
    'AZURE_TENANT_ID'
    'AZURE_SUBSCRIPTION_ID'
    'FABRIC_CAPACITY_ID'
)

# The legs the workflow reports, in dependency order. Used to sort the result table
# so the console reads like the replay graph in kill-rebuild.md section 4.
$script:LegOrder = @(
    'preflight', 'plan', 'oidc-login',
    'L2', 'L3', 'L4', 'L5', 'L6', 'L7', 'L8',
    'summary'
)

# --- console ---------------------------------------------------------------------

function Write-Status {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
        Justification = 'Interactive operations script; the console output IS the product.')]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Message,
        [ConsoleColor]$Color = [ConsoleColor]::Gray
    )
    Write-Host $Message -ForegroundColor $Color
}

# --- gh plumbing -----------------------------------------------------------------

function Invoke-Gh {
    <#
    .SYNOPSIS
        Runs one `gh` command. The single seam every test mocks, so no test can reach
        the network by accident.
    #>
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [switch]$AllowFailure
    )
    $output = & gh @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0 -and -not $AllowFailure) {
        $text = ($output | Out-String).Trim()
        throw "gh $($Arguments -join ' ') failed with exit code ${exitCode}: $text"
    }
    return [pscustomobject]@{
        ExitCode = $exitCode
        Output   = @($output | ForEach-Object { [string]$_ })
    }
}

function Invoke-GhJson {
    <# Runs a `gh` command that emits JSON and returns the parsed object, or $null. #>
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [switch]$AllowFailure
    )
    $result = Invoke-Gh -Arguments $Arguments -AllowFailure:$AllowFailure
    if ($result.ExitCode -ne 0) { return $null }
    $text = ($result.Output -join "`n").Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    return $text | ConvertFrom-Json
}

# --- preflight -------------------------------------------------------------------

function Assert-GhCli {
    <# Fail fast, and actionably, when the GitHub CLI is missing. #>
    if (Get-Command 'gh' -CommandType Application -ErrorAction SilentlyContinue) { return }
    throw @'
The GitHub CLI (`gh`) is not on PATH, so there is no way to dispatch the workflow.

Install one, then re-run:
  * Windows : winget install GitHub.cli
  * macOS   : brew install gh
  * Linux   : https://github.com/cli/cli/blob/trunk/docs/install_linux.md

Nothing was dispatched and no estate was touched.
'@
}

function Assert-GhAuthenticated {
    <# `gh auth status` is the only honest test: a token can exist and be expired. #>
    $result = Invoke-Gh -Arguments @('auth', 'status') -AllowFailure
    if ($result.ExitCode -eq 0) { return }
    $detail = ($result.Output -join "`n").Trim()
    throw @"
The GitHub CLI is installed but not authenticated, so the workflow cannot be
dispatched. ``gh auth status`` said:

$detail

Sign in first:
    gh auth login

Nothing was dispatched and no estate was touched.
"@
}

function Resolve-Repository {
    <#
    .SYNOPSIS
        Resolve owner/name from the parameter, or from the directory gh is run in.
    #>
    param([string]$Candidate)
    if (-not [string]::IsNullOrWhiteSpace($Candidate)) { return $Candidate.Trim() }

    $view = Invoke-GhJson -Arguments @('repo', 'view', '--json', 'nameWithOwner') -AllowFailure
    if ($view -and $view.PSObject.Properties.Name -contains 'nameWithOwner' -and $view.nameWithOwner) {
        return [string]$view.nameWithOwner
    }
    throw @'
Could not work out which repository to dispatch against.

`gh repo view` found nothing, which usually means this is not a clone of the demo
repo (or the remote is not a GitHub remote). Fix it either way:
  * run from inside the repository, or
  * pass it explicitly:  pwsh scripts/up.ps1 -Repository owner/name

Nothing was dispatched and no estate was touched.
'@
}

function Get-DemoEnvironmentVariable {
    <#
    .SYNOPSIS
        Names of the variables defined on the repository's `demo` environment.
    .DESCRIPTION
        Returns $null when the environment itself does not exist - a different
        failure from "exists but is empty", and worth a different message.
    #>
    param([Parameter(Mandatory)][string]$Repository)

    $response = Invoke-GhJson -AllowFailure -Arguments @(
        'api', "repos/$Repository/environments/demo/variables", '--paginate'
    )
    if ($null -eq $response) { return $null }
    if ($response.PSObject.Properties.Name -notcontains 'variables') { return @() }
    return @($response.variables | ForEach-Object { [string]$_.name })
}

function Assert-DemoEnvironment {
    <#
    .SYNOPSIS
        Refuse to dispatch a run that the pre-G0 guard would turn into a green no-op.
    .DESCRIPTION
        infra-up.yml's `preflight` job reads the `demo` environment. When a variable
        is missing it reports configured=false, every layer job is skipped, and the
        run SUCCEEDS. That is right for CI - the repo must be green before the tenant
        exists - and useless for an operator who asked for an estate. So the same
        condition is checked here, before anything is dispatched, and named precisely.
    #>
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string[]]$Required
    )

    $present = Get-DemoEnvironmentVariable -Repository $Repository
    if ($null -eq $present) {
        throw @"
The repository $Repository has no ``demo`` GitHub environment, so infra-up would
skip every layer and still report success.

The ``demo`` environment is created during L1 and holds the tenant/subscription
identifiers as VARIABLES (never secrets - CLAUDE.md hard rule 5). Create it, then
set the variables:

    gh api -X PUT repos/$Repository/environments/demo
$(($Required | ForEach-Object { "    gh variable set $_ --env demo --repo $Repository" }) -join "`n")

See docs/runbooks/g0-bootstrap.md and docs/runbooks/layers/L01.md.
Nothing was dispatched and no estate was touched.
"@
    }

    $missing = @($Required | Where-Object { $present -notcontains $_ })
    if ($missing.Count -eq 0) {
        Write-Status "demo environment: $($present.Count) variable(s), all $($Required.Count) required present." -Color Green
        return
    }

    throw @"
The ``demo`` environment is missing $($missing.Count) required variable(s):
$(($missing | ForEach-Object { "  * $_" }) -join "`n")

infra-up.yml's pre-G0 guard would report configured=false, SKIP every layer, and
finish GREEN - a run that looks like a success and builds nothing. Refusing to
dispatch it.

Set them, then re-run:
$(($missing | ForEach-Object { "    gh variable set $_ --env demo --repo $Repository" }) -join "`n")

FABRIC_CAPACITY_ID is the trial capacity id or the paid F2's ARM resource id
(G0 item C4). The rest come from G0's app registrations.
Nothing was dispatched and no estate was touched.
"@
}

# --- dispatch and watch ----------------------------------------------------------

function Get-LatestRunId {
    <# Newest run id for the workflow, or $null when it has never run. #>
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$WorkflowFile
    )
    $runs = Invoke-GhJson -AllowFailure -Arguments @(
        'run', 'list',
        '--repo', $Repository,
        '--workflow', $WorkflowFile,
        '--limit', '1',
        '--json', 'databaseId'
    )
    $list = @($runs)
    if ($list.Count -ge 1 -and $list[0]) { return [int64]$list[0].databaseId }
    return $null
}

function Wait-NewRunId {
    <#
    .SYNOPSIS
        `gh workflow run` does not return a run id, so watch for a new one to appear.
    #>
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$WorkflowFile,
        [int64]$PreviousRunId,
        [int]$TimeoutSeconds = 120,
        [int]$IntervalSeconds = 3
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $candidate = Get-LatestRunId -Repository $Repository -WorkflowFile $WorkflowFile
        if ($null -ne $candidate -and $candidate -ne $PreviousRunId) { return $candidate }
        Start-Sleep -Seconds $IntervalSeconds
    }
    throw @"
Dispatched $WorkflowFile but no new run appeared within $TimeoutSeconds seconds.

The dispatch itself succeeded, so the run has probably just not been indexed yet.
Find it with:
    gh run list --repo $Repository --workflow $WorkflowFile
"@
}

function Get-RunSnapshot {
    <# One poll: overall status plus every job's name and conclusion. #>
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][int64]$RunId
    )
    $run = Invoke-GhJson -AllowFailure -Arguments @(
        'run', 'view', "$RunId",
        '--repo', $Repository,
        '--json', 'status,conclusion,createdAt,updatedAt,url,jobs'
    )
    if ($null -eq $run) { return $null }

    $jobs = @()
    if ($run.PSObject.Properties.Name -contains 'jobs' -and $run.jobs) {
        $jobs = @($run.jobs | ForEach-Object {
                [pscustomobject]@{
                    Name       = [string]$_.name
                    Status     = [string]$_.status
                    Conclusion = if ($_.conclusion) { [string]$_.conclusion } else { '' }
                }
            })
    }

    return [pscustomobject]@{
        Status     = [string]$run.status
        Conclusion = if ($run.conclusion) { [string]$run.conclusion } else { '' }
        CreatedAt  = $run.createdAt
        UpdatedAt  = $run.updatedAt
        Url        = [string]$run.url
        Jobs       = $jobs
    }
}

function Get-LegSortKey {
    <# Orders the result table like the replay graph, unknown legs last. #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$JobName)
    for ($i = 0; $i -lt $script:LegOrder.Count; $i++) {
        if ($JobName -like "$($script:LegOrder[$i])*") { return $i }
    }
    return $script:LegOrder.Count
}

function Format-RunResult {
    <#
    .SYNOPSIS
        The per-leg table. Deliberately the same legs the workflow's own summary
        prints, so the console and the Actions page never disagree.
    #>
    param([Parameter(Mandatory)][object]$Snapshot)

    $rows = @($Snapshot.Jobs |
            Sort-Object -Property @{ Expression = { Get-LegSortKey -JobName $_.Name } }, Name |
            ForEach-Object {
                $result = if ($_.Conclusion) { $_.Conclusion } else { $_.Status }
                [pscustomobject]@{ Leg = $_.Name; Result = $result }
            })
    return $rows
}

function Wait-WorkflowRun {
    <#
    .SYNOPSIS
        Poll a run to completion, printing each leg as it settles.
    .DESCRIPTION
        Polling rather than `gh run watch` on purpose: the incremental output is
        legible in a transcript, every call goes through the one mocked seam, and a
        watch that dies mid-run does not take the script with it.
    #>
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][int64]$RunId,
        [int]$TimeoutMinutes = 90,
        [int]$PollSeconds = 15
    )

    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    $announced = @{}
    $snapshot = $null

    while ($true) {
        $snapshot = Get-RunSnapshot -Repository $Repository -RunId $RunId
        if ($null -eq $snapshot) {
            Write-Status '  (run not readable yet; retrying)' -Color DarkGray
        }
        else {
            foreach ($job in $snapshot.Jobs) {
                if ($job.Conclusion -and -not $announced.ContainsKey($job.Name)) {
                    $announced[$job.Name] = $true
                    $color = switch ($job.Conclusion) {
                        'success' { [ConsoleColor]::Green }
                        'skipped' { [ConsoleColor]::DarkGray }
                        default { [ConsoleColor]::Red }
                    }
                    Write-Status ("  {0,-46} {1}" -f $job.Name, $job.Conclusion) -Color $color
                }
            }
            if ($snapshot.Status -eq 'completed') { return $snapshot }
        }

        if ((Get-Date) -ge $deadline) {
            Write-Warning "Stopped watching after $TimeoutMinutes minutes. The run is still going: $($snapshot.Url)"
            return $snapshot
        }
        Start-Sleep -Seconds $PollSeconds
    }
}

# --- wall clock ------------------------------------------------------------------

function Format-Duration {
    <# `52m 14s`, the unit the <60-minute claim is argued in. #>
    param([Parameter(Mandatory)][timespan]$Duration)
    if ($Duration.TotalHours -ge 1) {
        return ('{0}h {1:00}m {2:00}s' -f [int]$Duration.TotalHours, $Duration.Minutes, $Duration.Seconds)
    }
    return ('{0}m {1:00}s' -f [int]$Duration.TotalMinutes, $Duration.Seconds)
}

function Format-UtcStamp {
    <#
    .SYNOPSIS
        Normalise any timestamp-shaped value to yyyy-MM-ddTHH:mm:ssZ, or $null.
    .DESCRIPTION
        gh's JSON timestamps come back from ConvertFrom-Json as [datetime] objects,
        which stringify in the host's culture ("08/24/2026 10:00:00"). The clock
        record is read by a PowerShell audit and by humans in two time zones, so
        every instant in it is written in one unambiguous UTC format.
    #>
    param([AllowNull()][object]$Value)
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace("$Value")) { return $null }
    $slot = [datetime]::MinValue
    $styles = [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal
    if ([datetime]::TryParse("$Value", [cultureinfo]::InvariantCulture, $styles, [ref]$slot)) {
        return $slot.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    }
    return "$Value"
}

function Get-DefaultReportRoot {
    <# verification/reports/ - the Verifier's own report directory. #>
    return (Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath 'verification' -AdditionalChildPath 'reports')
}

function Write-UpClock {
    <#
    .SYNOPSIS
        Persist the two instants V11.4 measures, and hand them to whatever runs next.
    .DESCRIPTION
        kill-rebuild.md section 5 defines the clock as "starts at up.ps1 invocation,
        stops at the last synchronous layer audit green", and the layer workflows now
        run their audits inline - so the run finishing IS that second instant. The two
        explicitly-async criteria (V6.3 cost export, V6.4 SQL auto-pause) are recorded
        PENDING by the L6 audit rather than waited out, which is what keeps them out of
        this number, exactly as section 5 says they must be.

        Three sinks, because there are three consumers:
          * verification/reports/up-clock.json - the durable record the rebuild proof
            cites, and what a Verifier reads on a workstation an hour later;
          * $GITHUB_ENV - so a later step in the same Actions run inherits
            MLS_L11_UP_START / MLS_L11_UP_COMPLETED with no copy-paste;
          * the console - the ready-to-paste layer-11-audit.ps1 command.

        Returns the JSON path, or $null when nothing could be written. A clock that
        cannot be recorded must not take the rebuild down with it, so every failure
        here is a warning.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Writes the run''s own evidence record under verification/reports/; it touches no estate, and gating it behind ShouldProcess would mean a -WhatIf rehearsal silently produced no proof file.')]
    param(
        [Parameter(Mandatory)][datetime]$StartedAt,
        [AllowNull()][Nullable[datetime]]$CompletedAt,
        [Parameter(Mandatory)][string]$Repository,
        [AllowNull()][object]$RunId,
        [AllowEmptyString()][string]$Conclusion = '',
        [AllowNull()][object]$RunCreatedAt,
        [AllowNull()][object]$RunUpdatedAt,
        [AllowEmptyString()][string]$ReportRoot = '',
        [double]$BudgetMinutes = 60
    )

    $root = if ([string]::IsNullOrWhiteSpace($ReportRoot)) { Get-DefaultReportRoot } else { $ReportRoot }

    $startUtc = $StartedAt.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $completedUtc = $null
    $elapsedMinutes = $null
    if ($null -ne $CompletedAt) {
        $completedUtc = ([datetime]$CompletedAt).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        $elapsedMinutes = [math]::Round((([datetime]$CompletedAt) - $StartedAt).TotalMinutes, 2)
    }

    $document = [ordered]@{
        # These two key names are the contract: they are exactly the environment
        # variables verification/layer-11-audit.ps1 falls back to.
        MLS_L11_UP_START     = $startUtc
        MLS_L11_UP_COMPLETED = $completedUtc
        repository           = $Repository
        runId                = $RunId
        runUrl               = if ($RunId) { "https://github.com/$Repository/actions/runs/$RunId" } else { $null }
        conclusion           = $Conclusion
        elapsedMinutes       = $elapsedMinutes
        budgetMinutes        = $BudgetMinutes
        withinBudget         = if ($null -eq $elapsedMinutes) { $null } else { [bool]($elapsedMinutes -lt $BudgetMinutes) }
        githubRunCreatedAt   = Format-UtcStamp -Value $RunCreatedAt
        githubRunUpdatedAt   = Format-UtcStamp -Value $RunUpdatedAt
        clockDefinition      = 'kill-rebuild.md section 5: starts at up.ps1 invocation, stops at the last synchronous layer audit green. Excluded by definition and closed on their own clocks: V6.3 first cost export (<= 24 h), V6.4 SQL auto-pause (+75 min), V11.5 idle run-rate (next-day consumption).'
        recordedBy           = 'scripts/up.ps1'
    }

    $jsonPath = $null
    try {
        if (-not (Test-Path -LiteralPath $root)) {
            New-Item -ItemType Directory -Path $root -Force | Out-Null
        }
        $jsonPath = Join-Path -Path $root -ChildPath 'up-clock.json'
        Set-Content -LiteralPath $jsonPath -Value ($document | ConvertTo-Json -Depth 5) -Encoding utf8
    }
    catch {
        Write-Warning "Could not write the up-clock record to '$root': $($_.Exception.Message)"
        $jsonPath = $null
    }

    if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_ENV)) {
        try {
            Add-Content -LiteralPath $env:GITHUB_ENV -Value "MLS_L11_UP_START=$startUtc"
            if ($completedUtc) {
                Add-Content -LiteralPath $env:GITHUB_ENV -Value "MLS_L11_UP_COMPLETED=$completedUtc"
            }
        }
        catch {
            Write-Warning "Could not append the up-clock to `$GITHUB_ENV: $($_.Exception.Message)"
        }
    }

    return $jsonPath
}

function Get-RunDuration {
    <#
    .SYNOPSIS
        GitHub's own view of how long the run took - the SECOND independent source
        kill-rebuild.md section 5 requires for the proof record. Returns $null when
        the timestamps are unusable rather than inventing a number.
    #>
    param([Parameter(Mandatory)][object]$Snapshot)
    if ($Snapshot.PSObject.Properties.Name -notcontains 'CreatedAt') { return $null }
    try {
        $created = [datetime]::Parse([string]$Snapshot.CreatedAt, [cultureinfo]::InvariantCulture)
        $updated = [datetime]::Parse([string]$Snapshot.UpdatedAt, [cultureinfo]::InvariantCulture)
    }
    catch {
        return $null
    }
    if ($updated -lt $created) { return $null }
    return $updated - $created
}

# --- main ------------------------------------------------------------------------

function Invoke-Main {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$Repository,
        [Parameter(Mandatory)][string]$Mode,
        [Parameter(Mandatory)][string]$Layers,
        [Parameter(Mandatory)][string]$Location,
        [AllowEmptyString()][string]$ImageTag = '',
        [switch]$DryRun,
        [switch]$NoWatch,
        [int]$TimeoutMinutes = 90,
        [int]$PollSeconds = 15,
        [AllowEmptyString()][string]$ReportRoot = ''
    )

    $startedAt = Get-Date

    Write-Status ''
    Write-Status 'Meridian Launch Systems - instantiate the demo estate' -Color Cyan
    Write-Status '=====================================================' -Color Cyan

    # ---- preflight: everything that can fail, fails before the dispatch ----------
    Assert-GhCli
    Assert-GhAuthenticated
    $repo = Resolve-Repository -Candidate $Repository
    Write-Status "Repository: $repo" -Color Green
    Assert-DemoEnvironment -Repository $repo -Required $script:RequiredDemoVariables

    $ghArgs = @(
        'workflow', 'run', $script:WorkflowFile,
        '--repo', $repo,
        '-f', "mode=$Mode",
        '-f', "layers=$Layers",
        '-f', "location=$Location",
        '-f', "dry_run=$($DryRun.IsPresent.ToString().ToLowerInvariant())",
        '-f', "image_tag=$ImageTag"
    )

    Write-Status ''
    Write-Status 'Plan:' -Color Cyan
    Write-Status "  workflow  $($script:WorkflowFile)"
    Write-Status "  mode      $Mode"
    Write-Status "  layers    $Layers"
    Write-Status "  location  $(if ($Location) { "$Location (explicit override)" } else { "(from the demo environment's AZURE_LOCATION)" })"
    Write-Status "  dry_run   $($DryRun.IsPresent)"
    Write-Status "  image_tag $(if ($ImageTag) { $ImageTag } else { '(placeholder image)' })"
    Write-Status "  command   gh $($ghArgs -join ' ')" -Color DarkGray
    if ($DryRun) {
        Write-Status '  NOTE: -DryRun is a REMOTE plan-only run. It still dispatches.' -Color Yellow
    }
    Write-Status ''

    if (-not $PSCmdlet.ShouldProcess("$repo ($($script:WorkflowFile))", 'Dispatch the estate instantiation workflow')) {
        Write-Status '(-WhatIf) Nothing was dispatched. GitHub was not contacted beyond the read-only preflight.' -Color Yellow
        return [pscustomobject]@{
            Repository = $repo
            RunId      = $null
            Conclusion = 'whatif'
            Legs       = @()
            Elapsed    = (Get-Date) - $startedAt
            RunElapsed = $null
            ClockPath  = $null
            WhatIfOnly = $true
        }
    }

    $previousRunId = Get-LatestRunId -Repository $repo -WorkflowFile $script:WorkflowFile
    Invoke-Gh -Arguments $ghArgs | Out-Null
    Write-Status 'Dispatched.' -Color Green

    if ($NoWatch) {
        # The clock still STARTED, and V11.4 needs that instant whoever stops it.
        # Recorded with no completion time rather than not at all.
        $clockPath = Write-UpClock -StartedAt $startedAt -CompletedAt $null -Repository $repo `
            -RunId $null -Conclusion 'dispatched' -RunCreatedAt $null -RunUpdatedAt $null -ReportRoot $ReportRoot
        Write-Status "Not watching (-NoWatch). Follow it with: gh run watch --repo $repo" -Color Yellow
        if ($clockPath) {
            Write-Status "Clock start recorded in $clockPath (MLS_L11_UP_START only - nothing stopped the clock)." -Color Yellow
        }
        return [pscustomobject]@{
            Repository = $repo
            RunId      = $null
            Conclusion = 'dispatched'
            Legs       = @()
            Elapsed    = (Get-Date) - $startedAt
            RunElapsed = $null
            ClockPath  = $clockPath
            WhatIfOnly = $false
        }
    }

    $runId = Wait-NewRunId -Repository $repo -WorkflowFile $script:WorkflowFile -PreviousRunId $previousRunId
    Write-Status ''
    Write-Status "Watching run $runId" -Color Cyan

    $snapshot = Wait-WorkflowRun -Repository $repo -RunId $runId `
        -TimeoutMinutes $TimeoutMinutes -PollSeconds $PollSeconds

    $legs = @()
    if ($snapshot) { $legs = Format-RunResult -Snapshot $snapshot }

    $completedAt = Get-Date
    $elapsed = $completedAt - $startedAt
    $runElapsed = if ($snapshot) { Get-RunDuration -Snapshot $snapshot } else { $null }

    $clockPath = Write-UpClock -StartedAt $startedAt -CompletedAt $completedAt -Repository $repo `
        -RunId $runId -Conclusion $(if ($snapshot) { $snapshot.Conclusion } else { '' }) `
        -RunCreatedAt $(if ($snapshot) { $snapshot.CreatedAt } else { $null }) `
        -RunUpdatedAt $(if ($snapshot) { $snapshot.UpdatedAt } else { $null }) `
        -ReportRoot $ReportRoot

    Write-Status ''
    Write-Status 'Layer results' -Color Cyan
    if ($legs.Count -gt 0) {
        $legs | Format-Table -AutoSize | Out-Host
    }
    else {
        Write-Status '  (no job information available)' -Color Yellow
    }

    # ---- the <60-minute clock (kill-rebuild.md section 5) ------------------------
    Write-Status 'Wall clock' -Color Cyan
    Write-Status "  up.ps1 (clock starts at invocation) : $(Format-Duration -Duration $elapsed)"
    if ($runElapsed) {
        Write-Status "  GitHub run timestamps               : $(Format-Duration -Duration $runElapsed)"
    }
    else {
        Write-Status '  GitHub run timestamps               : unavailable' -Color Yellow
    }
    if ($elapsed.TotalMinutes -lt 60) {
        Write-Status "  L11 budget (<60 min)                : MET, $([int](60 - $elapsed.TotalMinutes)) min of margin" -Color Green
    }
    else {
        Write-Status '  L11 budget (<60 min)                : EXCEEDED' -Color Red
        Write-Status '  On a proof run that is a failed V11.4 - remediate the named bottleneck and' -Color Yellow
        Write-Status '  re-run clean. On an operational rebuild, log the overage and the cause.' -Color Yellow
        Write-Status '  Usual suspects, in observed-likelihood order: kill-rebuild.md section 5.' -Color Yellow
    }

    # ---- hand the clock over (kill-rebuild.md section 5 / L11 V11.4) -------------
    $startUtc = $startedAt.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $completedUtc = $completedAt.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    Write-Status ''
    Write-Status 'Handover to V11.4' -Color Cyan
    if ($clockPath) {
        Write-Status "  recorded: $clockPath"
    }
    else {
        Write-Status '  recorded: (could not be written - copy the values below)' -Color Yellow
    }
    Write-Status "  MLS_L11_UP_START     $startUtc"
    Write-Status "  MLS_L11_UP_COMPLETED $completedUtc"
    Write-Status '  Verifier closes the cycle with:' -Color DarkGray
    Write-Status "    pwsh verification/layer-11-audit.ps1 -Phase Up -UpStartUtc $startUtc -UpCompletedUtc $completedUtc" -Color DarkGray
    Write-Status '  Then close the two async criteria the clock excludes:' -Color DarkGray
    Write-Status '    gh workflow run layer-06-platform.yml -f verify_only=true   # V6.3 cost export, V6.4 SQL auto-pause' -Color DarkGray

    $conclusion = if ($snapshot) { $snapshot.Conclusion } else { '' }
    Write-Status ''
    if ($conclusion -eq 'success') {
        Write-Status "Estate instantiated. Run: $($snapshot.Url)" -Color Green
        Write-Status 'Next: the Verifier re-runs every layer audit (verification/layer-NN-audit.ps1).'
    }
    elseif ($conclusion) {
        Write-Status "infra-up finished '$conclusion'. Run: $($snapshot.Url)" -Color Red
    }
    else {
        Write-Status 'infra-up did not complete inside the watch window.' -Color Yellow
    }

    return [pscustomobject]@{
        Repository = $repo
        RunId      = $runId
        Conclusion = $conclusion
        Legs       = $legs
        Elapsed    = $elapsed
        RunElapsed = $runElapsed
        ClockPath  = $clockPath
        WhatIfOnly = $false
    }
}

if (-not $env:MLS_SKIP_MAIN) {
    $outcome = Invoke-Main -Repository $Repository -Mode $Mode -Layers $Layers `
        -Location $Location -ImageTag $ImageTag -DryRun:$DryRun -NoWatch:$NoWatch `
        -TimeoutMinutes $TimeoutMinutes -PollSeconds $PollSeconds -ReportRoot $ReportRoot
    if ($outcome.Conclusion -notin @('success', 'whatif', 'dispatched')) { exit 1 }
    exit 0
}
