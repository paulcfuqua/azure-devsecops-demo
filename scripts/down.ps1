#Requires -Version 7.0
<#
.SYNOPSIS
    Kill the estate: dispatch .github/workflows/infra-down.yml and watch it to the end.

.DESCRIPTION
    The local entry point for the standard kill cycle. A THIN wrapper over the
    workflow - the teardown semantics live there and in
    docs/runbooks/kill-rebuild.md section 2.

    GATE-FREE, AND FRICTIONLESS ON PURPOSE. CLAUDE.md hard rule 2: "RG-scoped
    teardown of demo resources is gate-free by design." kill-rebuild.md section 2:
    "Idempotent, order-safe, no confirmation prompt." The demo's central trick is
    being able to destroy the estate on a whim, so a confirmation prompt here would
    break the showpiece rather than protect it.

    FRICTIONLESS IS NOT THE SAME AS SILENT. Before it dispatches anything this script
    prints the exact manifest - the four resource groups by resolved name, the Fabric
    workspace items, the cost-export definition - AND the list of everything the
    cycle deliberately leaves alone. Nobody should ever be surprised by what came
    back and what did not.

    THE LINE THIS SCRIPT CANNOT CROSS. There is no code path here that reaches an
    Entra object, a Purview label, the Fabric workspace shell, the capacity, the
    management group, the budget, the OIDC federation or the Copilot Studio
    environment. That separation is structural - those live in G3-gated scripts
    (infra/*/teardown.ps1) - not a runtime flag on this one.

    Names are resolved from infra/bicep/naming.bicep, never hardcoded (CLAUDE.md:
    "Company name and prefix are set once in infra/bicep/naming.bicep").

.PARAMETER Repository
    owner/name. Defaults to whatever `gh` resolves for the current directory.

.PARAMETER SkipFabric
    Pass through to the workflow: RG deletes only, no Fabric item delete or capacity
    pause. Useful when the capacity is already known-paused.

.PARAMETER NoWatch
    Dispatch and return immediately.

.PARAMETER TimeoutMinutes
    How long to watch before giving up on the run (the run itself keeps going).

.EXAMPLE
    pwsh scripts/down.ps1
    # Prints the manifest, dispatches, watches, reports each stage.

.EXAMPLE
    pwsh scripts/down.ps1 -WhatIf
    # Prints exactly what would be deleted and dispatches nothing.

.NOTES
    Runbook: docs/runbooks/kill-rebuild.md section 2 (semantics) and 3 (verifying
    the down state). Rebuild counterpart: scripts/up.ps1.
    Expected wall time 10-20 minutes for the deletes to drain; not on any rebuild
    clock. Safe to re-run at any time, from any state.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidatePattern('^[\w.-]+/[\w.-]+$')]
    [string]$Repository,

    [switch]$SkipFabric,

    [switch]$NoWatch,

    [ValidateRange(1, 240)]
    [int]$TimeoutMinutes = 60,

    [ValidateRange(2, 120)]
    [int]$PollSeconds = 15,

    # Overridable only so the tests can point at a fixture; nobody passes this.
    [string]$NamingFile = (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'infra/bicep/naming.bicep')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:WorkflowFile = 'infra-down.yml'

# infra-down.yml's guard needs only the three identity variables; unlike infra-up it
# does not read FABRIC_CAPACITY_ID at preflight (the fabric job reads it directly).
$script:RequiredDemoVariables = @(
    'AZURE_CLIENT_ID'
    'AZURE_TENANT_ID'
    'AZURE_SUBSCRIPTION_ID'
)

# The four demo RG purposes, per naming.bicep's `rgPurposes` and CLAUDE.md.
$script:RgPurposes = @('platform', 'apps', 'data', 'ops')

$script:StageOrder = @('preflight', 'Fabric', 'remove the cost-export', 'delete the four', 'run summary')

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
    <# Resolve owner/name from the parameter, or from the directory gh is run in. #>
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
  * pass it explicitly:  pwsh scripts/down.ps1 -Repository owner/name

Nothing was dispatched and no estate was touched.
'@
}

function Get-DemoEnvironmentVariable {
    <# Names of the variables on the repository's `demo` environment, or $null. #>
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
        Refuse to dispatch a teardown that the pre-G0 guard would turn into a green
        no-op.
    .DESCRIPTION
        Same trap as infra-up, and worse here: an operator who believes the estate is
        dead when it is not keeps paying for it. So the guard's condition is checked
        locally first and named exactly.
    #>
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string[]]$Required
    )

    $present = Get-DemoEnvironmentVariable -Repository $Repository
    if ($null -eq $present) {
        throw @"
The repository $Repository has no ``demo`` GitHub environment, so infra-down would
skip every stage and still report success - and you would believe the estate was
torn down when nothing had been deleted.

If G0/L1 have not run yet there is genuinely nothing to tear down. Otherwise create
the environment and set its variables:

    gh api -X PUT repos/$Repository/environments/demo
$(($Required | ForEach-Object { "    gh variable set $_ --env demo --repo $Repository" }) -join "`n")

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

infra-down.yml's pre-G0 guard would report configured=false, SKIP every stage and
finish GREEN. A teardown that looks like a success and deletes nothing is the most
expensive possible failure here, so this is a refusal rather than a warning.

Set them, then re-run:
$(($missing | ForEach-Object { "    gh variable set $_ --env demo --repo $Repository" }) -join "`n")

Nothing was dispatched and no estate was touched.
"@
}

# --- the manifest ----------------------------------------------------------------

function Get-CompanyPrefix {
    <#
    .SYNOPSIS
        Reads `defaultCompanyPrefix` out of naming.bicep.
    .DESCRIPTION
        The same single source of truth the .github/actions/naming composite action
        parses, for the same reason: CLAUDE.md forbids hardcoding the prefix anywhere
        but naming.bicep. If this file cannot be read the script refuses rather than
        printing a manifest it guessed at - a teardown manifest naming the wrong
        resource groups is worse than no manifest.
    #>
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw @"
Cannot resolve the estate's resource-group names: '$Path' does not exist.

Names come from infra/bicep/naming.bicep and nowhere else (CLAUDE.md, "Naming and
tagging"). Run this script from a clone of the repository.

Nothing was dispatched and no estate was touched.
"@
    }

    $content = Get-Content -LiteralPath $Path -Raw
    $match = [regex]::Match($content, "var\s+defaultCompanyPrefix\s*=\s*'([^']+)'")
    if (-not $match.Success) {
        throw @"
Could not parse ``defaultCompanyPrefix`` out of '$Path'.

The teardown manifest is built from that value, and printing resource-group names
this script is not sure about would be worse than stopping.

Nothing was dispatched and no estate was touched.
"@
    }
    return $match.Groups[1].Value
}

function Get-TeardownManifest {
    <#
    .SYNOPSIS
        Exactly what infra-down.yml deletes, and exactly what it leaves.
    .DESCRIPTION
        Mirrors kill-rebuild.md section 1's two columns and section 2's ordered
        stages. Built locally from naming.bicep so it can be printed BEFORE the
        dispatch - the whole point being that the operator sees the blast radius
        before the run starts, not in the run summary afterwards.
    #>
    param(
        [Parameter(Mandatory)][string]$Prefix,
        [switch]$SkipFabric
    )

    $resourceGroups = @($script:RgPurposes | ForEach-Object { "$Prefix-rg-$_" })

    $deletes = [System.Collections.Generic.List[object]]::new()
    if (-not $SkipFabric) {
        $deletes.Add([pscustomobject]@{
                Stage  = 1
                What   = "Fabric workspace ITEMS in '$Prefix-operations'"
                Detail = 'lakehouse + its Delta tables + the data agent; the workspace shell and its role grants survive'
            })
        $deletes.Add([pscustomobject]@{
                Stage  = 2
                What   = 'Fabric capacity pause'
                Detail = 'paid F2: ARM suspend. Trial: no-op. $0 either way after this step'
            })
    }
    $deletes.Add([pscustomobject]@{
            Stage  = 3
            What   = "Cost-export definition '$Prefix-cost-daily'"
            Detail = 'subscription scope; removed so it never points at deleted storage'
        })
    foreach ($rg in $resourceGroups) {
        $deletes.Add([pscustomobject]@{
                Stage  = 4
                What   = "Resource group $rg"
                Detail = 'and everything in it; deleted in parallel, then waited on'
            })
    }

    $survives = @(
        'Entra users (5), groups (4), CA policies (report-only), app registrations (3)'
        'Purview labels (Public/Internal/Confidential/Export-Controlled) and their GUIDs'
        "Fabric workspace SHELL '$Prefix-operations' + role assignments; the capacity itself"
        "Management group '$Prefix', policy + NIST assignments, the `$75 budget"
        'OIDC federation on the deployer, mls-verifier, and this repository'
        'The Power Platform environment, its pay-as-you-go plan, and the Copilot Studio agent'
    )

    return [pscustomobject]@{
        Prefix         = $Prefix
        ResourceGroups = $resourceGroups
        Deletes        = @($deletes)
        Survives       = $survives
    }
}

function Write-TeardownManifest {
    <# The "never surprising" half of "frictionless but never surprising". #>
    param([Parameter(Mandatory)][object]$Manifest)

    Write-Status ''
    Write-Status 'THIS WILL DELETE' -Color Red
    Write-Status '----------------' -Color Red
    foreach ($item in $Manifest.Deletes) {
        Write-Status ("  [{0}] {1}" -f $item.Stage, $item.What) -Color Red
        Write-Status ("        {0}" -f $item.Detail) -Color DarkGray
    }

    Write-Status ''
    Write-Status 'THIS SURVIVES (G3 to touch; no code path here can reach it)' -Color Green
    Write-Status '-----------------------------------------------------------' -Color Green
    foreach ($item in $Manifest.Survives) {
        Write-Status "  * $item" -Color Green
    }

    Write-Status ''
    Write-Status 'Gate-free by design (CLAUDE.md hard rule 2) - there is no confirmation prompt.' -Color Yellow
    Write-Status 'Idempotent and order-safe: re-running from any state is always allowed.' -Color Yellow
    Write-Status ''
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
    <# `gh workflow run` does not return a run id, so watch for a new one. #>
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

The dispatch itself succeeded, so the teardown is probably running. Find it with:
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

function Get-StageSortKey {
    <# Orders the result table like kill-rebuild.md section 2, unknown stages last. #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$JobName)
    for ($i = 0; $i -lt $script:StageOrder.Count; $i++) {
        if ($JobName -like "$($script:StageOrder[$i])*") { return $i }
    }
    return $script:StageOrder.Count
}

function Format-RunResult {
    <# The per-stage table, in the workflow's own order. #>
    param([Parameter(Mandatory)][object]$Snapshot)

    return @($Snapshot.Jobs |
            Sort-Object -Property @{ Expression = { Get-StageSortKey -JobName $_.Name } }, Name |
            ForEach-Object {
                $result = if ($_.Conclusion) { $_.Conclusion } else { $_.Status }
                [pscustomobject]@{ Stage = $_.Name; Result = $result }
            })
}

function Wait-WorkflowRun {
    <# Poll a run to completion, printing each stage as it settles. #>
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][int64]$RunId,
        [int]$TimeoutMinutes = 60,
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

function Format-Duration {
    <# `14m 02s`. Teardown is not on the rebuild clock, but the number still helps. #>
    param([Parameter(Mandatory)][timespan]$Duration)
    if ($Duration.TotalHours -ge 1) {
        return ('{0}h {1:00}m {2:00}s' -f [int]$Duration.TotalHours, $Duration.Minutes, $Duration.Seconds)
    }
    return ('{0}m {1:00}s' -f [int]$Duration.TotalMinutes, $Duration.Seconds)
}

# --- main ------------------------------------------------------------------------

function Invoke-Main {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$Repository,
        [Parameter(Mandatory)][string]$NamingFile,
        [switch]$SkipFabric,
        [switch]$NoWatch,
        [int]$TimeoutMinutes = 60,
        [int]$PollSeconds = 15
    )

    $startedAt = Get-Date

    Write-Status ''
    Write-Status 'Meridian Launch Systems - tear the demo estate down' -Color Cyan
    Write-Status '===================================================' -Color Cyan

    # ---- preflight: everything that can fail, fails before the dispatch ----------
    Assert-GhCli
    Assert-GhAuthenticated
    $repo = Resolve-Repository -Candidate $Repository
    Write-Status "Repository: $repo" -Color Green
    Assert-DemoEnvironment -Repository $repo -Required $script:RequiredDemoVariables

    # ---- the manifest, printed BEFORE anything is dispatched ---------------------
    $prefix = Get-CompanyPrefix -Path $NamingFile
    $manifest = Get-TeardownManifest -Prefix $prefix -SkipFabric:$SkipFabric
    Write-TeardownManifest -Manifest $manifest

    $ghArgs = @(
        'workflow', 'run', $script:WorkflowFile,
        '--repo', $repo,
        '-f', "skip_fabric=$($SkipFabric.IsPresent.ToString().ToLowerInvariant())"
    )
    Write-Status "  command   gh $($ghArgs -join ' ')" -Color DarkGray
    Write-Status ''

    if (-not $PSCmdlet.ShouldProcess(
            "$repo (RGs: $($manifest.ResourceGroups -join ', '))",
            'Dispatch the estate teardown workflow')) {
        Write-Status '(-WhatIf) Nothing was dispatched. The estate above is untouched.' -Color Yellow
        return [pscustomobject]@{
            Repository     = $repo
            RunId          = $null
            Conclusion     = 'whatif'
            Stages         = @()
            ResourceGroups = $manifest.ResourceGroups
            Elapsed        = (Get-Date) - $startedAt
            WhatIfOnly     = $true
        }
    }

    $previousRunId = Get-LatestRunId -Repository $repo -WorkflowFile $script:WorkflowFile
    Invoke-Gh -Arguments $ghArgs | Out-Null
    Write-Status 'Dispatched.' -Color Green

    if ($NoWatch) {
        Write-Status "Not watching (-NoWatch). Follow it with: gh run watch --repo $repo" -Color Yellow
        return [pscustomobject]@{
            Repository     = $repo
            RunId          = $null
            Conclusion     = 'dispatched'
            Stages         = @()
            ResourceGroups = $manifest.ResourceGroups
            Elapsed        = (Get-Date) - $startedAt
            WhatIfOnly     = $false
        }
    }

    $runId = Wait-NewRunId -Repository $repo -WorkflowFile $script:WorkflowFile -PreviousRunId $previousRunId
    Write-Status ''
    Write-Status "Watching run $runId" -Color Cyan

    $snapshot = Wait-WorkflowRun -Repository $repo -RunId $runId `
        -TimeoutMinutes $TimeoutMinutes -PollSeconds $PollSeconds

    $stages = @()
    if ($snapshot) { $stages = Format-RunResult -Snapshot $snapshot }
    $elapsed = (Get-Date) - $startedAt

    Write-Status ''
    Write-Status 'Teardown stages' -Color Cyan
    if ($stages.Count -gt 0) {
        $stages | Format-Table -AutoSize | Out-Host
    }
    else {
        Write-Status '  (no job information available)' -Color Yellow
    }
    Write-Status "Elapsed: $(Format-Duration -Duration $elapsed) (teardown is not on the rebuild clock)"

    $conclusion = if ($snapshot) { $snapshot.Conclusion } else { '' }
    Write-Status ''
    if ($conclusion -eq 'success') {
        Write-Status "Estate torn down. Run: $($snapshot.Url)" -Color Green
        Write-Status 'Verify it is really dead (read-only, kill-rebuild.md section 3):'
        Write-Status "  az group list --query `"[?starts_with(name,'$prefix-rg-')].name`"   # expect []" -Color DarkGray
        Write-Status '  pwsh verification/layer-11-audit.ps1     # down-state half' -Color DarkGray
        Write-Status '  pwsh verification/layer-03-audit.ps1 ; pwsh verification/layer-04-audit.ps1' -Color DarkGray
        Write-Status '  A tenant-object regression there is stop-the-line (G4): the teardown crossed the line.' -Color Yellow
    }
    elseif ($conclusion) {
        Write-Status "infra-down finished '$conclusion'. Run: $($snapshot.Url)" -Color Red
        Write-Status 'Re-running down.ps1 is safe and idempotent; a stuck RG is usually a lock,' -Color Yellow
        Write-Status 'a Key Vault soft-delete conflict, or a resource in Failed state.' -Color Yellow
    }
    else {
        Write-Status 'infra-down did not complete inside the watch window.' -Color Yellow
    }

    return [pscustomobject]@{
        Repository     = $repo
        RunId          = $runId
        Conclusion     = $conclusion
        Stages         = $stages
        ResourceGroups = $manifest.ResourceGroups
        Elapsed        = $elapsed
        WhatIfOnly     = $false
    }
}

if (-not $env:MLS_SKIP_MAIN) {
    $outcome = Invoke-Main -Repository $Repository -NamingFile $NamingFile `
        -SkipFabric:$SkipFabric -NoWatch:$NoWatch `
        -TimeoutMinutes $TimeoutMinutes -PollSeconds $PollSeconds
    if ($outcome.Conclusion -notin @('success', 'whatif', 'dispatched')) { exit 1 }
    exit 0
}
