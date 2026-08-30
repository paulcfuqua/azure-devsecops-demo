#Requires -Version 7.0
<#
.SYNOPSIS
    Shared engine for the Verifier's per-layer audit scripts (verification/layer-NN-audit.ps1).

.DESCRIPTION
    Everything the eleven layer audits have in common:

      * a criterion runner (Invoke-MlsCriterion) that records, for every master-plan
        Verify criterion, its id (V<layer>.<n>), the criterion text, the command or
        query actually executed, expected vs observed, and PASS / FAIL / SKIP / PENDING;
      * bounded, interruptible retry using the per-criterion propagation window each
        playbook specifies (standard 30 minutes, polled every 5, with the plan-pinned
        exceptions: NIST 30 min, SQL auto-pause +75 min, cost export 24 h, self-heal
        24 h). A criterion that passes on the first attempt sleeps for zero seconds -
        the window is a ceiling, never a wait;
      * per-criterion exception containment: a check that throws becomes a FAIL row and
        the remaining criteria still run;
      * a report writer emitting verification/reports/L<NN>-<timestamp>.md and a
        machine-readable .json sibling, plus the exit-code rule (nonzero iff any
        criterion FAILs).

    READ-ONLY BY CONTRACT. Every audit runs as `mls-verifier` (Reader +
    Directory.Read.All + Policy.Read.All) and this module is the only place that talks
    to anything. Each transport therefore refuses to issue a mutation:

      Invoke-MlsAz     - the az verb must be in $script:AzReadOnlyVerb; `az rest`
                         additionally requires --method get.
      Invoke-MlsGh     - the gh command pair must be in $script:GhReadOnlyCommand;
                         `gh api` additionally requires GET (or no) --method.
      Invoke-MlsRest   - GET only.
      Invoke-MlsGraph  - GET only (Invoke-MgGraphRequest when the Graph SDK is present,
                         otherwise `az rest` against graph.microsoft.com).
      Invoke-MlsMcpToolCatalog - the single documented exception: MCP's JSON-RPC read
                         methods (`initialize`, `tools/list`) are POSTs at the transport
                         level. Nothing else may POST.

    Where a playbook criterion involves a write attempt - L2's untagged canary resource
    group, which policy must deny - the DEPLOY workflow performs the write and the audit
    confirms it independently from the Activity Log. That half, and only that half, is
    what layer-02-audit.ps1 implements (L02.md V2.2).

.EXAMPLE
    $ctx = New-MlsAuditContext -Layer 2 -Title 'Landing zone'
    Invoke-MlsCriterion -Context $ctx -Id 'V2.1' -Description 'sub sits under MG mls' `
        -Command 'az account management-group show --name mls' -Expected 'one child' `
        -Test { New-MlsCheckResult -Passed $true -Observed 'demo subscription' }
    Write-MlsReport -Context $ctx
    exit (Get-MlsExitCode -Context $ctx)
#>

Set-StrictMode -Version Latest

# --- constants -------------------------------------------------------------------------

# Standard bounded-retry window and poll cadence.
#
# This was "bounded retry 30 minutes, poll every 5 minutes" (master plan risk 2, repeated
# verbatim in the L01-L07 playbooks), applied as the DEFAULT to every criterion that did not
# say otherwise - 19 of the 47 criteria in this repo. That is backwards. Thirty minutes is
# the right window for the handful of checks that wait on a genuinely slow, eventually
# consistent process; it is absurd for a check whose answer is settled the moment the deploy
# step returns, and V2.1 is the second kind. It inherited the long window by default and
# spent all thirty minutes reaching a WRONG verdict (F59).
#
# The cost was never one criterion. L3 declares four criteria, none of them explicit: four
# times thirty is two hours inside a sixty-minute job. The run budget (F58) stops that from
# killing the job, but a truncated window is a half-measured answer, not a good one.
#
# So the default is now short and PATIENCE IS OPT-IN. Ordinary Azure RBAC, policy and Graph
# propagation lands well inside five minutes; the checks that genuinely need longer already
# declare it (-RetryWindowMinutes 30 on V2.3's policy scan, 24 h on the cost export and the
# self-heal criteria). A criterion that turns out to need more now fails fast and says how
# long it waited, which is the evidence for giving it an explicit window - rather than every
# criterion silently inheriting the most patient case.
#
# Twenty-second polling matters as much as the window: at 300 s a criterion that became true
# at t=10s still waited five minutes, so every propagation-lagged check cost the full poll
# interval even when it converged immediately.
$script:StandardRetryWindowMinutes = 5
$script:StandardPollIntervalSeconds = 20

# Hard ceiling on how long the WHOLE audit may spend retrying, across every criterion.
#
# The per-criterion window is bounded and the run was not, which is not the same thing:
# L2 declares three criteria at the standard 30-minute window, so its worst case was 90
# minutes inside a job whose timeout-minutes is 60. There was never any margin - V2.3
# legitimately waits out the NIST assignment's own 30-minute compliance scan, so ONE
# unexpected failure anywhere else in the layer was enough to reach the runner's limit
# and be killed mid-audit, reporting nothing (F58).
#
# A criterion that cannot be given its full window is not silently shortened: it says so
# in its Detail, because "FAIL, and the run ran out of time to keep asking" and "FAIL,
# and we waited the whole window" are different findings.
#
# 45 leaves 15 of a 60-minute job to write the report and upload it. The relationship
# between this number and the job's timeout-minutes is enforced by
# verification/tests/audit-run-budget.Tests.ps1, not by this comment.
$script:DefaultRunBudgetMinutes = 45

# Default ceiling on a SINGLE transport call. An `az` invocation had no timeout at all,
# so one hung call could consume the entire job while the retry loop above it never got
# another turn (F58).
$script:DefaultCommandTimeoutSeconds = 300

# Hard ceiling on how long ONE criterion may block a single audit run. The 24-hour
# criteria (V6.3 cost export, V10.1/V10.2 self-heal) declare a 24 h window but must not
# hang the Verifier for a day: they pass -InProcessWaitMinutes 0 -PendingWhenUnexpired,
# which records PENDING until the declared deadline actually passes.
$script:DefaultMaxWaitMinutes = 120

# Invoke-MlsCriterion's -Control parameter is validated against this set: the ids of
# Task 1's catalog (compliance/catalog/nist-800-171r2.json), loaded once on first use and
# cached here for the life of the module (spec 2026-08-26-compliance-platform-design.md
# section 4.2). $null means "not loaded yet"; an empty HashSet would be indistinguishable from
# "loaded but the catalog was empty", so the unloaded state is its own sentinel.
$script:ControlCatalogRequirementId = $null

# Sleep in slices so Ctrl+C lands promptly and the deadline is re-checked often.
$script:SleepSliceSeconds = 5

$script:AzReadOnlyVerb = @(
    'show', 'list', 'exists', 'query', 'summarize', 'get', 'view', 'download',
    'list-usages', 'list-locations', 'list-deleted', 'show-connection-string',
    'get-access-token', 'check-name'
)

# gh is a noun-verb CLI; a read-only pair list is safer than a verb denylist because
# `gh run list` and `gh workflow run` differ only in position.
$script:GhReadOnlyCommand = @(
    'api', 'run list', 'run view', 'run download', 'pr view', 'pr list', 'pr checks',
    'pr diff', 'release view', 'release download', 'workflow list', 'workflow view',
    'repo view', 'search'
)

$script:McpReadOnlyMethod = @('initialize', 'notifications/initialized', 'tools/list')

# Entra audience for the SQL data plane. Both endpoints the audit queries - the Fabric
# lakehouse SQL analytics endpoint (V5.3, V8.2) and the Entra-only Azure SQL database -
# speak TDS and accept an access token for this resource, which is exactly the audience
# .github/workflows/layer-06-platform.yml mints for the seed loader.
$script:SqlResourceUrl = 'https://database.windows.net'

# Where Invoke-MlsSqlQuery looks for a caller-supplied token before minting one.
$script:SqlAccessTokenVariable = @('MLS_SQL_ACCESS_TOKEN', 'MLS_VERIFIER_SQL_TOKEN')

# Adaptive Cards profile this repo pins (L08.md V8.4): schema 1.5 and Action.Submit only,
# so one payload renders identically in the Direct Line Web Chat embed and in Teams.
$script:AdaptiveCardElementType = @(
    'TextBlock', 'Image', 'Media', 'RichTextBlock', 'ActionSet', 'Container',
    'ColumnSet', 'Column', 'FactSet', 'Fact', 'ImageSet', 'Table', 'TableRow',
    'TableCell', 'Input.Text', 'Input.Number', 'Input.Date', 'Input.Time',
    'Input.Toggle', 'Input.ChoiceSet', 'Input.Choice'
)
$script:AdaptiveCardActionType = @('Action.Submit', 'Action.OpenUrl', 'Action.ShowCard', 'Action.ToggleVisibility')
$script:GeneratedUiPattern = '<script|<div|<span|<html|=>\s*\(|React\.|dangerouslySetInnerHTML|function\s*\('

# --- console ---------------------------------------------------------------------------

function Write-MlsStatus {
    <#
    .SYNOPSIS
        Console line for an audit run. The pass/fail table is the product (verify-g0.ps1
        convention), so this writes to the host deliberately.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
        Justification = 'Operator-facing audit output is the product, exactly as in scripts/bootstrap/verify-g0.ps1.')]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Message,
        [ConsoleColor]$Color = [ConsoleColor]::Gray
    )
    Write-Host $Message -ForegroundColor $Color
}

# --- strict-mode-safe helpers ----------------------------------------------------------

function Get-MlsProperty {
    <#
    .SYNOPSIS
        Property read from a hashtable or PSObject that is safe under Set-StrictMode.
    #>
    param(
        $InputObject,
        [Parameter(Mandatory)][string]$Name
    )
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.Contains($Name)) { return $InputObject[$Name] }
        return $null
    }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $null
}

function Get-MlsCollection {
    <#
    .SYNOPSIS
        Normalise an API collection response ({value:[...]} / {data:[...]} / bare array).
    #>
    param($Response)
    if ($null -eq $Response) { return @() }
    foreach ($key in @('value', 'data', 'jobs', 'check_runs')) {
        # Test for the KEY, not for a non-null value. PowerShell unrolls an empty
        # array on return, so `Get-MlsProperty` handed back $null for `{value: []}`
        # exactly as it does for a response with no `value` key at all - the loop
        # fell through and the function returned @($Response), the wrapper itself.
        #
        # An EMPTY collection therefore reported Count = 1, indistinguishable from a
        # one-item collection. Every caller that counts a filtered Graph or gh
        # response read an ABSENT object as PRESENT: a missing group, a missing app
        # registration, a missing federated credential, an empty group's membership.
        # That is the Verifier - the estate's sign-off gate - failing in the
        # direction of passing. Found when an empty break-glass group read as
        # holding one member.
        if (Test-MlsHasProperty -InputObject $Response -Name $key) {
            return @(Get-MlsProperty -InputObject $Response -Name $key)
        }
    }
    return @($Response)
}

function Test-MlsHasProperty {
    <#
    .SYNOPSIS
        Does this object carry this key at all, whatever its value? Distinguishes an
        absent key from one holding $null, an empty array or an empty string - which
        a plain `-ne $null` test cannot.
    #>
    param($InputObject, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $InputObject) { return $false }
    if ($InputObject -is [System.Collections.IDictionary]) {
        return (@($InputObject.Keys) -contains $Name)
    }
    return $null -ne $InputObject.PSObject.Properties[$Name]
}

function Format-MlsValue {
    <#
    .SYNOPSIS
        Render any observed value as one readable line for the report tables.
    #>
    param(
        $Value,
        [int]$MaximumLength = 600
    )
    if ($null -eq $Value) { return '(null)' }
    $text = if ($Value -is [string]) {
        $Value
    }
    elseif ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [System.Collections.IDictionary]) {
        (@($Value) | ForEach-Object { "$_" }) -join ', '
    }
    else {
        "$Value"
    }
    $text = $text -replace '\s+', ' '
    if ($text.Length -gt $MaximumLength) { return $text.Substring(0, $MaximumLength) + '...(truncated)' }
    return $text
}

function Test-MlsSetEquality {
    <#
    .SYNOPSIS
        Compare two string sets; returns Equal / Missing / Extra so a report can say which.
    #>
    param(
        [AllowEmptyCollection()][string[]]$Actual = @(),
        [AllowEmptyCollection()][string[]]$Expected = @(),
        [switch]$CaseSensitive
    )
    $comparer = if ($CaseSensitive) { [StringComparer]::Ordinal } else { [StringComparer]::OrdinalIgnoreCase }
    $actualSet = [System.Collections.Generic.HashSet[string]]::new([string[]]@($Actual | Where-Object { $null -ne $_ }), $comparer)
    $expectedSet = [System.Collections.Generic.HashSet[string]]::new([string[]]@($Expected | Where-Object { $null -ne $_ }), $comparer)
    $missing = @($expectedSet | Where-Object { -not $actualSet.Contains($_) } | Sort-Object)
    $extra = @($actualSet | Where-Object { -not $expectedSet.Contains($_) } | Sort-Object)
    return [pscustomobject]@{
        Equal   = ($missing.Count -eq 0 -and $extra.Count -eq 0)
        Missing = $missing
        Extra   = $extra
    }
}

function Get-MlsPercentile {
    <#
    .SYNOPSIS
        Nearest-rank percentile, matching L08.md V8.5's published formula exactly:
        $lat[[math]::Ceiling(0.95 * $lat.Count) - 1] over the sorted sample.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][double[]]$Value,
        [double]$Percentile = 0.95
    )
    $sorted = @($Value | Sort-Object)
    if ($sorted.Count -eq 0) { return $null }
    $index = [math]::Ceiling($Percentile * $sorted.Count) - 1
    if ($index -lt 0) { $index = 0 }
    if ($index -ge $sorted.Count) { $index = $sorted.Count - 1 }
    return $sorted[$index]
}

function Resolve-MlsInput {
    <#
    .SYNOPSIS
        Resolve one input from an explicit parameter, then environment variables, then a
        default - and fail with an actionable message rather than passing silently.
    .DESCRIPTION
        Used for script-level inputs (the ones without which nothing can run). Criterion
        level evidence - a canary PR number, an eval artifact - is handled inside the
        criterion instead, so a missing pointer becomes an explicit FAIL/SKIP row rather
        than aborting the whole audit.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [AllowEmptyString()][AllowNull()][string]$Value,
        [AllowEmptyCollection()][string[]]$EnvironmentVariable = @(),
        [AllowEmptyString()][string]$DefaultValue = '',
        [Parameter(Mandatory)][string]$Hint
    )
    if (-not [string]::IsNullOrWhiteSpace($Value)) { return $Value }
    foreach ($variable in $EnvironmentVariable) {
        $fromEnvironment = [Environment]::GetEnvironmentVariable($variable)
        if (-not [string]::IsNullOrWhiteSpace($fromEnvironment)) { return $fromEnvironment }
    }
    if (-not [string]::IsNullOrWhiteSpace($DefaultValue)) { return $DefaultValue }
    $sources = @("-$Name")
    if ($EnvironmentVariable.Count -gt 0) { $sources += ($EnvironmentVariable | ForEach-Object { "`$env:$_" }) }
    throw "Required input '$Name' was not supplied. $Hint Set one of: $($sources -join ', ')."
}

function Get-MlsJsonFile {
    <#
    .SYNOPSIS
        Read and parse a JSON file, or throw a message that names the file and its purpose.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Purpose
    )
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "File not found: '$Path' ($Purpose)."
    }
    try {
        return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json)
    }
    catch {
        throw "'$Path' ($Purpose) is not valid JSON: $($_.Exception.Message)"
    }
}

function Get-MlsControlCatalogRequirementId {
    <#
    .SYNOPSIS
        The set of valid NIST SP 800-171 Rev 2 requirement ids, for validating
        Invoke-MlsCriterion's -Control argument.
    .DESCRIPTION
        Loaded once from compliance/catalog/nist-800-171r2.json (Task 1's catalog, the
        authoritative source for which control ids exist) and cached in module scope for
        the rest of the process's life - the catalog does not change mid-run, and every
        criterion in an audit run would otherwise re-read and re-parse the same file.

        This is deliberately the ONLY validation path: a criterion that names a control id
        the catalog does not carry is a dangling evidence pointer (this plan has already
        shipped one), and catching that at authoring time - a criterion throws the moment
        it runs with a bad id - is cheaper than catching it downstream in the collector
        that later joins criterion rows to the catalog.
    #>
    param()
    if ($null -ne $script:ControlCatalogRequirementId) { return $script:ControlCatalogRequirementId }
    $path = Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'compliance', 'catalog', 'nist-800-171r2.json'
    $catalog = Get-MlsJsonFile -Path $path -Purpose 'NIST SP 800-171 Rev 2 catalog - Invoke-MlsCriterion -Control validates against this'
    $ids = @(Get-MlsProperty -InputObject $catalog -Name 'requirements' | ForEach-Object { "$(Get-MlsProperty -InputObject $_ -Name 'id')" })
    $script:ControlCatalogRequirementId = [System.Collections.Generic.HashSet[string]]::new([string[]]$ids, [StringComparer]::Ordinal)
    return $script:ControlCatalogRequirementId
}

# --- read-only guards ------------------------------------------------------------------

function Assert-MlsReadOnlyAzArgument {
    <#
    .SYNOPSIS
        Refuse any az invocation that could mutate. The Verifier holds Reader only, but a
        structural guard beats relying on RBAC to say no.
    #>
    param([Parameter(Mandatory)][string[]]$Argument)
    $positional = @($Argument | Where-Object { $_ -notlike '-*' })
    if ($positional.Count -eq 0) {
        throw "Refusing az call with no command: '$($Argument -join ' ')'."
    }
    if ($positional[0] -eq 'rest') {
        $index = [array]::IndexOf($Argument, '--method')
        $method = if ($index -ge 0 -and ($index + 1) -lt $Argument.Count) { $Argument[$index + 1] } else { 'get' }
        if ($method -notin @('get', 'GET', 'head', 'HEAD')) {
            throw "Refusing mutating az rest call (--method $method). The Verifier is read-only (CLAUDE.md)."
        }
        return
    }
    # The az verb is the last positional token before the first flag.
    $verbIndex = $Argument.Count
    for ($i = 0; $i -lt $Argument.Count; $i++) {
        if ($Argument[$i] -like '-*') { $verbIndex = $i; break }
    }
    $verb = $Argument[$verbIndex - 1]
    if ($verb -notin $script:AzReadOnlyVerb) {
        throw "Refusing az call '$($Argument -join ' ')': verb '$verb' is not read-only. The Verifier never mutates (CLAUDE.md)."
    }
}

function Assert-MlsReadOnlyGhArgument {
    <#
    .SYNOPSIS
        Refuse any gh invocation that could mutate the repository.
    #>
    param([Parameter(Mandatory)][string[]]$Argument)
    $positional = @($Argument | Where-Object { $_ -notlike '-*' })
    if ($positional.Count -eq 0) {
        throw "Refusing gh call with no command: '$($Argument -join ' ')'."
    }
    $pair = $positional[0]
    if ($positional.Count -ge 2 -and $pair -ne 'api') { $pair = "$($positional[0]) $($positional[1])" }
    if ($pair -notin $script:GhReadOnlyCommand) {
        throw "Refusing gh call '$($Argument -join ' ')': '$pair' is not in the read-only command set. The Verifier never writes to GitHub (spec F8)."
    }
    foreach ($flag in @('-X', '--method')) {
        $index = [array]::IndexOf($Argument, $flag)
        if ($index -ge 0 -and ($index + 1) -lt $Argument.Count -and $Argument[$index + 1] -notin @('GET', 'get', 'HEAD', 'head')) {
            throw "Refusing mutating gh api call ($flag $($Argument[$index + 1])). The Verifier is read-only (spec F8)."
        }
    }
}

function Assert-MlsCommand {
    <#
    .SYNOPSIS
        Fail with an actionable message when a required external tool is absent, instead
        of surfacing a CommandNotFoundException from inside a criterion.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Hint
    )
    if (-not (Get-Command -Name $Name -ErrorAction SilentlyContinue)) {
        throw "'$Name' is not available on this machine. $Hint"
    }
}

# --- transports (the only code in the repo that talks to anything) ---------------------

function Invoke-MlsBoundedNativeCommand {
    <#
    .SYNOPSIS
        Run a native command with a hard wall-clock ceiling, returning its streams.

    .DESCRIPTION
        `& az @Argument` cannot be interrupted. A call that never returns holds the audit
        forever: the retry loop above it never gets another turn, the run budget never gets
        consulted, and the job dies at the runner's timeout with the process still live -
        which is what "Terminate orphan process: pid (3399) (python3)" in L2's cancelled
        job was (F58; `az` is Python).

        stderr is CAPTURED, not discarded. The old call ended in `2>$null`, so when az did
        fail the reason was thrown away and the criterion could only report an exit code.
    #>
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$Argument,
        [Parameter(Mandatory)][int]$TimeoutSeconds
    )
    $resolved = (Get-Command -Name $FilePath -ErrorAction Stop)
    $exe = if ($resolved.CommandType -eq 'Application') { $resolved.Source } else { $FilePath }

    # ProcessStartInfo.ArgumentList, NOT Start-Process -ArgumentList. The latter joins the
    # array into one command line with no per-argument quoting, so the first az query
    # containing a space - `--query "children[?contains(id, '<sub>')].displayName"`, which
    # is V2.1 - would arrive as two arguments and the call would fail. ArgumentList escapes
    # each element on Windows and passes argv straight through on Unix.
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $exe
    foreach ($value in $Argument) { $psi.ArgumentList.Add($value) }
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    $process = [System.Diagnostics.Process]::Start($psi)
    try {
        # Drain both pipes concurrently. Reading one to the end before the other deadlocks
        # as soon as a command fills the pipe it is not being read from - and `az` output is
        # routinely larger than a pipe buffer.
        $outTask = $process.StandardOutput.ReadToEndAsync()
        $errTask = $process.StandardError.ReadToEndAsync()

        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try {
                $process.Kill($true)
            }
            catch {
                # It exited between the timeout expiring and the kill, or the OS refused.
                # Either way the wait is over and TimedOut is still the answer.
                Write-Verbose "could not kill $exe after timeout: $($_.Exception.Message)"
            }
            return [pscustomobject]@{ TimedOut = $true; ExitCode = -1; StdOut = ''; StdErr = '' }
        }
        # The overload that takes a timeout returns as soon as the process exits; the
        # parameterless one additionally waits for the redirected streams to flush.
        $process.WaitForExit()
        return [pscustomobject]@{
            TimedOut = $false
            ExitCode = $process.ExitCode
            StdOut   = ([string]$outTask.GetAwaiter().GetResult())
            StdErr   = ([string]$errTask.GetAwaiter().GetResult())
        }
    }
    finally {
        $process.Dispose()
    }
}

function Invoke-MlsAz {
    <#
    .SYNOPSIS
        Read-only az CLI call, JSON-parsed. Single choke point - mocked in every test.
    #>
    param(
        [Parameter(Mandatory)][string[]]$Argument,
        [switch]$AllowFailure,
        [switch]$Raw,
        [int]$TimeoutSeconds = 0
    )
    Assert-MlsReadOnlyAzArgument -Argument $Argument
    Assert-MlsCommand -Name 'az' -Hint 'Install the Azure CLI and sign in as mls-verifier (az login --service-principal ...).'
    if ($TimeoutSeconds -le 0) { $TimeoutSeconds = $script:DefaultCommandTimeoutSeconds }
    $run = Invoke-MlsBoundedNativeCommand -FilePath 'az' -Argument $Argument -TimeoutSeconds $TimeoutSeconds
    if ($run.TimedOut) {
        # A timeout is NOT swallowed by -AllowFailure. -AllowFailure means "this command is
        # allowed to come back empty-handed"; a hang means we never found out, and reporting
        # "not there" for "could not tell" is the mistake F57 was about.
        throw "az $($Argument -join ' ') did not return within $TimeoutSeconds s and was terminated."
    }
    if ($run.ExitCode -ne 0) {
        if ($AllowFailure) { return $null }
        $why = if ([string]::IsNullOrWhiteSpace($run.StdErr)) { '' } else { ": $($run.StdErr.Trim())" }
        throw "az $($Argument -join ' ') failed with exit code $($run.ExitCode)$why"
    }
    $output = $run.StdOut
    $text = ($output | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    if ($Raw) { return $text }
    return ($text | ConvertFrom-Json)
}

function Invoke-MlsGh {
    <#
    .SYNOPSIS
        Read-only GitHub CLI call, JSON-parsed unless -Raw. Runs under the Verifier's own
        read token (spec F8), never the deployer's context.
    #>
    param(
        [Parameter(Mandatory)][string[]]$Argument,
        [switch]$AllowFailure,
        [switch]$Raw,
        [int]$TimeoutSeconds = 0
    )
    Assert-MlsReadOnlyGhArgument -Argument $Argument
    Assert-MlsCommand -Name 'gh' -Hint 'Install the GitHub CLI and export the Verifier read token as GH_TOKEN.'
    if ($TimeoutSeconds -le 0) { $TimeoutSeconds = $script:DefaultCommandTimeoutSeconds }
    $run = Invoke-MlsBoundedNativeCommand -FilePath 'gh' -Argument $Argument -TimeoutSeconds $TimeoutSeconds
    if ($run.TimedOut) {
        throw "gh $($Argument -join ' ') did not return within $TimeoutSeconds s and was terminated."
    }
    $exitCode = $run.ExitCode
    if ($exitCode -ne 0) {
        if ($AllowFailure) { return $null }
        $why = if ([string]::IsNullOrWhiteSpace($run.StdErr)) { '' } else { ": $($run.StdErr.Trim())" }
        throw "gh $($Argument -join ' ') failed with exit code $exitCode$why"
    }
    $output = $run.StdOut
    $text = ($output | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    if ($Raw) { return $text }
    return ($text | ConvertFrom-Json)
}

function Invoke-MlsGit {
    <#
    .SYNOPSIS
        Local git read (the V1.3 grep audit). Returns exit code plus output lines: git
        grep exits 1 when it finds nothing, which is the passing case there.
    #>
    param(
        [Parameter(Mandatory)][string[]]$Argument,
        [string]$WorkingDirectory = '.'
    )
    if ($Argument[0] -notin @('grep', 'log', 'show', 'ls-files', 'rev-parse', 'status', 'diff')) {
        throw "Refusing git call '$($Argument -join ' ')': the audit only reads."
    }
    Assert-MlsCommand -Name 'git' -Hint 'Install git; V1.3 greps a fresh clone of main for committed identifiers.'
    Push-Location -LiteralPath $WorkingDirectory
    try {
        $output = & git @Argument 2>$null
        $exitCode = $LASTEXITCODE
    }
    finally {
        Pop-Location
    }
    return [pscustomobject]@{
        ExitCode = $exitCode
        Line     = @($output | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }
}

function Invoke-MlsRest {
    <#
    .SYNOPSIS
        GET-only REST call (Fabric REST, Dataverse Web API). Mocked in every test.
    #>
    param(
        [Parameter(Mandatory)][string]$Uri,
        [hashtable]$Header = @{},
        [ValidateSet('GET')][string]$Method = 'GET',
        [int]$TimeoutSec = 100
    )
    return Invoke-RestMethod -Uri $Uri -Headers $Header -Method $Method -TimeoutSec $TimeoutSec
}

function Invoke-MlsGraph {
    <#
    .SYNOPSIS
        GET-only Microsoft Graph read as mls-verifier (Directory.Read.All, Policy.Read.All).
    .DESCRIPTION
        Prefers Invoke-MgGraphRequest (the Graph PowerShell SDK the playbooks' queries are
        written in, installed at G0); falls back to `az rest` against graph.microsoft.com
        so the audit still runs on a host without the SDK. Both paths are reads.
    #>
    param(
        [Parameter(Mandatory)][string]$Uri,
        [ValidateSet('GET')][string]$Method = 'GET'
    )
    # THE CMDLET BEING INSTALLED IS NOT THE SAME AS BEING SIGNED IN.
    #
    # This preferred the SDK whenever `Invoke-MgGraphRequest` RESOLVED, and the CI runner has
    # the Graph module installed but never calls Connect-MgGraph - so every Graph criterion
    # threw "Authentication needed. Please call Connect-MgGraph." while the `az rest` fallback
    # underneath, which would have worked (the job is already OIDC-logged-in as mls-verifier),
    # was unreachable by construction (F64).
    #
    # So the test is a live CONTEXT, not a resolvable command. And an SDK call that fails on
    # authentication still falls through rather than ending the criterion: the point of having
    # two transports is that one of them working is enough.
    $sdk = Get-Command -Name 'Invoke-MgGraphRequest' -ErrorAction SilentlyContinue
    if ($sdk) {
        $context = try { Get-MgContext -ErrorAction Stop } catch { $null }
        if ($null -ne $context -and -not [string]::IsNullOrWhiteSpace("$(Get-MlsProperty -InputObject $context -Name 'ClientId')")) {
            try {
                return Invoke-MgGraphRequest -Method $Method -Uri $Uri -OutputType PSObject
            }
            catch {
                Write-MlsStatus -Message "Graph SDK call failed ($($_.Exception.Message)); falling back to az rest." -Color ([ConsoleColor]::DarkYellow)
            }
        }
    }
    return Invoke-MlsAz -Argument @('rest', '--method', 'get', '--url', $Uri, '--resource', 'https://graph.microsoft.com')
}

function Invoke-MlsHttp {
    <#
    .SYNOPSIS
        Plain HTTPS GET against a public app endpoint (V7.1 health checks, V7.3 probes).
        Returns status code, body and headers; never throws on a non-2xx status.
    #>
    param(
        [Parameter(Mandatory)][string]$Uri,
        [int]$TimeoutSec = 60
    )
    try {
        $response = Invoke-WebRequest -Uri $Uri -Method GET -TimeoutSec $TimeoutSec -SkipHttpErrorCheck
        return [pscustomobject]@{
            StatusCode = [int](Get-MlsProperty -InputObject $response -Name 'StatusCode')
            Content    = [string](Get-MlsProperty -InputObject $response -Name 'Content')
            Headers    = (Get-MlsProperty -InputObject $response -Name 'Headers')
            Error      = $null
        }
    }
    catch {
        return [pscustomobject]@{
            StatusCode = 0
            Content    = ''
            Headers    = @{}
            Error      = $_.Exception.Message
        }
    }
}

function Get-MlsSqlAccessToken {
    <#
    .SYNOPSIS
        Entra access token for the SQL data plane: explicit value, then environment, then
        minted from the current read-only login. Private - Invoke-MlsSqlQuery owns it.
    .DESCRIPTION
        The demo's SQL server enforces Entra-only authentication
        (azureADOnlyAuthentication: true in infra/bicep/platform/main.bicep) and the audits
        run on a Linux runner, where Invoke-Sqlcmd has no integrated-security fallback to
        degrade to. A token is therefore mandatory, not optional, and passing -AccessToken
        $null - which is what this module used to do - could only ever produce a login
        failure whose message says nothing about the real cause.

        Resolution order mirrors Get-VerifierFabricToken in verification/layer-05-audit.ps1:
        an explicit parameter wins, then the environment (so CI passes a token as a job-level
        `env:` rather than as a process argument, which is visible on the runner), then
        `az account get-access-token`. That last path goes through Invoke-MlsAz, so the
        read-only assertions still apply - `get-access-token` is in $script:AzReadOnlyVerb.

        Every failure names what to supply. A null token is never returned.
    #>
    param([AllowEmptyString()][AllowNull()][string]$AccessToken)

    if (-not [string]::IsNullOrWhiteSpace($AccessToken)) { return $AccessToken }
    foreach ($variable in $script:SqlAccessTokenVariable) {
        $fromEnvironment = [Environment]::GetEnvironmentVariable($variable)
        if (-not [string]::IsNullOrWhiteSpace($fromEnvironment)) { return $fromEnvironment }
    }

    $hint = "Sign in as mls-verifier (az login --service-principal ...), or supply the token with -AccessToken / `$env:$($script:SqlAccessTokenVariable -join ' / $env:'). The server enforces Entra-only authentication, so there is no password or integrated-security fallback."
    $response = $null
    try {
        $response = Invoke-MlsAz -Argument @(
            'account', 'get-access-token', '--resource', $script:SqlResourceUrl, '--output', 'json'
        )
    }
    catch {
        throw "Could not mint an Azure SQL access token: az account get-access-token --resource $($script:SqlResourceUrl) failed ($($_.Exception.Message)). $hint"
    }
    $token = Get-MlsProperty -InputObject $response -Name 'accessToken'
    if ([string]::IsNullOrWhiteSpace($token)) {
        throw "Could not mint an Azure SQL access token: az account get-access-token --resource $($script:SqlResourceUrl) returned no accessToken. $hint"
    }
    return "$token"
}

function Invoke-MlsSqlcmd {
    <#
    .SYNOPSIS
        Private passthrough to Invoke-Sqlcmd - the single place this module touches TDS,
        mirroring Invoke-MlsRest's relationship to Invoke-RestMethod.
    .DESCRIPTION
        Deliberately NOT exported: it takes any statement, and the read-only contract lives
        one level up in Invoke-MlsSqlQuery. Keeping it separate is what lets the tests prove
        which token reaches the driver without a SqlServer module installed.
    #>
    param(
        [Parameter(Mandatory)][string]$ServerName,
        [Parameter(Mandatory)][string]$DatabaseName,
        [Parameter(Mandatory)][string]$Query,
        [Parameter(Mandatory)][string]$AccessToken,
        [int]$TimeoutSec = 120
    )
    return Invoke-Sqlcmd -ServerInstance $ServerName -Database $DatabaseName -Query $Query `
        -ConnectionTimeout $TimeoutSec -AccessToken $AccessToken -ErrorAction Stop
}

function Invoke-MlsSqlQuery {
    <#
    .SYNOPSIS
        Read-only query against the lakehouse SQL analytics endpoint as mls-verifier
        (workspace Viewer, granted at L5). Rejects anything that is not a SELECT.
    .PARAMETER AccessToken
        Entra token for https://database.windows.net. Omit it and the module resolves one
        from $env:MLS_SQL_ACCESS_TOKEN / $env:MLS_VERIFIER_SQL_TOKEN, then mints one from
        the current login. There is no unauthenticated path: the statement guard runs first,
        the token is resolved second, and a resolution failure is an actionable error rather
        than a driver-level "Login failed".
    #>
    param(
        [Parameter(Mandatory)][string]$ServerName,
        [Parameter(Mandatory)][string]$DatabaseName,
        [Parameter(Mandatory)][string]$Query,
        [AllowEmptyString()][AllowNull()][string]$AccessToken,
        [int]$TimeoutSec = 120
    )
    # First, and before anything reaches a token or a network: the read-only contract.
    if ($Query -notmatch '(?is)^\s*(select|with)\b') {
        throw 'Refusing a non-SELECT statement: the Verifier only reads.'
    }
    Assert-MlsCommand -Name 'Invoke-Sqlcmd' -Hint 'Install SqlServer 22+ (Install-Module SqlServer -Scope CurrentUser -MinimumVersion 22.0.0) so the audit can query the lakehouse SQL analytics endpoint as mls-verifier; -AccessToken needs that major version.'
    $token = Get-MlsSqlAccessToken -AccessToken $AccessToken
    return Invoke-MlsSqlcmd -ServerName $ServerName -DatabaseName $DatabaseName -Query $Query `
        -AccessToken $token -TimeoutSec $TimeoutSec
}

function Connect-MlsCompliance {
    <#
    .SYNOPSIS
        Read-only Security & Compliance PowerShell session for the L4 label audit.
        mls-verifier holds Exchange.ManageAsApp with the View-Only Configuration role
        (L04.md Preconditions) - it can Get-Label and nothing else.
    #>
    param(
        [Parameter(Mandatory)][string]$Organization,
        [Parameter(Mandatory)][string]$AppId,
        [Parameter(Mandatory)][string]$CertificateThumbprint
    )
    Assert-MlsCommand -Name 'Connect-IPPSSession' -Hint 'Install ExchangeOnlineManagement (Install-Module ExchangeOnlineManagement -Scope CurrentUser); L4 reads labels through Security & Compliance PowerShell.'
    Connect-IPPSSession -AppId $AppId -Organization $Organization -CertificateThumbprint $CertificateThumbprint | Out-Null
}

function Get-MlsLabel {
    <#
    .SYNOPSIS
        Get-Label over the read-only S&C session (V4.1/V4.2).
    #>
    param()
    Assert-MlsCommand -Name 'Get-Label' -Hint 'Connect a Security & Compliance session first (Connect-MlsCompliance).'
    return @(Get-Label)
}

function Get-MlsLabelPolicy {
    <#
    .SYNOPSIS
        Get-LabelPolicy over the read-only S&C session (V4.3) - read-only, same as
        Get-Label: mls-verifier's View-Only Configuration role can read policies, not
        write them. Returns $null when the named policy does not exist, same shape as
        labels.ps1's own Get-ExistingLabelPolicy, rather than letting the cmdlet's
        not-found error surface as a thrown exception.
    #>
    param([Parameter(Mandatory)][string]$Identity)
    Assert-MlsCommand -Name 'Get-LabelPolicy' -Hint 'Connect a Security & Compliance session first (Connect-MlsCompliance).'
    try {
        return Get-LabelPolicy -Identity $Identity -ErrorAction Stop
    }
    catch {
        return $null
    }
}

function Invoke-MlsMcpToolCatalog {
    <#
    .SYNOPSIS
        MCP `tools/list` against the deployed server (V8.3's static half).
    .DESCRIPTION
        The one documented POST in this module: MCP is JSON-RPC over Streamable HTTP, so
        even its read methods are POSTs. Only the methods in $script:McpReadOnlyMethod are
        permitted, and tools/call is not one of them - the audit never invokes a tool.
    #>
    param(
        [Parameter(Mandatory)][string]$Uri,
        [hashtable]$Header = @{},
        [string]$Method = 'tools/list',
        [int]$TimeoutSec = 60
    )
    if ($Method -notin $script:McpReadOnlyMethod) {
        throw "Refusing MCP method '$Method': the audit may only call $($script:McpReadOnlyMethod -join ', ')."
    }
    $body = @{ jsonrpc = '2.0'; id = 1; method = $Method; params = @{} } | ConvertTo-Json -Depth 5
    $headers = @{ 'Content-Type' = 'application/json'; 'Accept' = 'application/json, text/event-stream' }
    foreach ($key in $Header.Keys) { $headers[$key] = $Header[$key] }
    return Invoke-RestMethod -Uri $Uri -Method POST -Headers $headers -Body $body -TimeoutSec $TimeoutSec
}

function Invoke-MlsLocalCommand {
    <#
    .SYNOPSIS
        Run a local, non-cloud tool from the audited commit (npm for the renderer's golden
        specs at V7.2, an SPDX validator at V9.3) and return its exit code and output.
    .DESCRIPTION
        Local computation only: nothing here reaches a cloud API, so the read-only contract
        is unaffected. The Verifier runs these from the audited commit, trusting the repo
        state rather than a teammate's claim (L07.md V7.2).
    #>
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [AllowEmptyCollection()][string[]]$Argument = @(),
        [string]$WorkingDirectory = '.'
    )
    Assert-MlsCommand -Name $FilePath -Hint "The audit shells out to '$FilePath' for a local check; install it or pass the criterion's evidence another way."
    Push-Location -LiteralPath $WorkingDirectory
    try {
        $output = & $FilePath @Argument 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        Pop-Location
    }
    return [pscustomobject]@{
        ExitCode = $exitCode
        Line     = @($output | ForEach-Object { "$_" })
    }
}

function Invoke-MlsChildAudit {
    <#
    .SYNOPSIS
        Run another layer audit in its own pwsh process and return its exit code (L11's
        V11.2 and V11.3 re-execute the L1-L10 audits verbatim).
    .DESCRIPTION
        A separate process on purpose: every audit script ends in `exit`, which would end
        the parent if it were dot-sourced, and the child's own report file is part of the
        evidence L11 cites.
    #>
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [AllowEmptyCollection()][string[]]$Argument = @()
    )
    if (-not (Test-Path -LiteralPath $ScriptPath)) {
        return [pscustomobject]@{ ScriptPath = $ScriptPath; ExitCode = 127; Output = @("audit script not found: $ScriptPath") }
    }
    Assert-MlsCommand -Name 'pwsh' -Hint 'PowerShell 7 runs the per-layer audits (CLAUDE.md: never assume Windows PowerShell 5.1).'
    $output = & pwsh -NoProfile -File $ScriptPath @Argument 2>&1
    return [pscustomobject]@{
        ScriptPath = $ScriptPath
        ExitCode   = $LASTEXITCODE
        Output     = @($output | ForEach-Object { "$_" })
    }
}

# --- criterion engine ------------------------------------------------------------------

function New-MlsCheckResult {
    <#
    .SYNOPSIS
        The value a criterion's -Test scriptblock returns.
    .PARAMETER Final
        Do not retry this outcome. Used where a playbook says a wrong value is not a
        propagation artifact (L03.md V3.3: "on state-visible-but-wrong fails immediately")
        and where required evidence was never supplied.
    .PARAMETER Status
        'SKIP' records a criterion that genuinely cannot run yet - a Copilot Studio agent
        that is not deployed, a Fabric data agent that needs paid F2 - with its reason, so
        the report is honest rather than green by omission. SKIP never retries and never
        fails the run, but it is never silent either.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Constructs an in-memory result row; the audit changes no state anywhere.')]
    param(
        [bool]$Passed = $false,
        [AllowEmptyString()][string]$Observed = '',
        [AllowEmptyString()][string]$Detail = '',
        [ValidateSet('PASS', 'FAIL', 'SKIP')][string]$Status = '',
        [switch]$Final
    )
    if ($Status -eq 'SKIP') { $Passed = $false }
    return [pscustomobject]@{
        Passed   = $Passed
        Observed = $Observed
        Detail   = $Detail
        Status   = $Status
        Final    = [bool]$Final
    }
}

function New-MlsAuditContext {
    <#
    .SYNOPSIS
        Create the run context every criterion records into.
    .PARAMETER MaxWaitMinutes
        Ceiling on in-process waiting for any single criterion (default 120). The declared
        propagation window can be longer - see Invoke-MlsCriterion -PendingWhenUnexpired.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates an in-memory context object; no system state is changed.')]
    param(
        [Parameter(Mandatory)][ValidateRange(1, 11)][int]$Layer,
        [Parameter(Mandatory)][string]$Title,
        [string]$ScriptName = '',
        [string]$ReportRoot = '',
        [double]$RetryWindowMinutes = -1,
        [double]$PollIntervalSeconds = -1,
        [double]$MaxWaitMinutes = -1,
        [double]$RunBudgetMinutes = -1,
        [string]$Identity = 'mls-verifier (Reader + Directory.Read.All + Policy.Read.All) - read-only by contract',
        [switch]$NoRetry
    )
    if ($RetryWindowMinutes -lt 0) { $RetryWindowMinutes = $script:StandardRetryWindowMinutes }
    if ($PollIntervalSeconds -le 0) { $PollIntervalSeconds = $script:StandardPollIntervalSeconds }
    if ($MaxWaitMinutes -lt 0) { $MaxWaitMinutes = $script:DefaultMaxWaitMinutes }
    if ($RunBudgetMinutes -lt 0) {
        # The runner knows the job's timeout; the script does not. MLS_AUDIT_RUN_BUDGET_MINUTES
        # is how the workflow tells it, so the two numbers stay related in one place
        # (CLAUDE.md: every value has one source).
        $fromEnv = $env:MLS_AUDIT_RUN_BUDGET_MINUTES
        $parsed = 0.0
        $RunBudgetMinutes = if (-not [string]::IsNullOrWhiteSpace($fromEnv) -and
            [double]::TryParse($fromEnv, [ref]$parsed) -and $parsed -gt 0) {
            $parsed
        }
        else {
            $script:DefaultRunBudgetMinutes
        }
    }
    $startedUtc = [datetime]::UtcNow
    if ([string]::IsNullOrWhiteSpace($ReportRoot)) {
        $ReportRoot = Join-Path -Path $PSScriptRoot -ChildPath 'reports'
    }
    return [pscustomobject]@{
        Layer               = $Layer
        LayerId             = ('L{0:d2}' -f $Layer)
        Title               = $Title
        ScriptName          = $ScriptName
        ReportRoot          = $ReportRoot
        RetryWindowMinutes  = $RetryWindowMinutes
        PollIntervalSeconds = $PollIntervalSeconds
        MaxWaitMinutes      = $MaxWaitMinutes
        RunBudgetMinutes    = $RunBudgetMinutes
        NoRetry             = [bool]$NoRetry
        Identity            = $Identity
        StartedUtc          = $startedUtc
        DeadlineUtc         = $startedUtc.AddMinutes($RunBudgetMinutes)
        Criterion           = [System.Collections.Generic.List[object]]::new()
        Preflight           = [System.Collections.Generic.List[object]]::new()
        Note                = [System.Collections.Generic.List[string]]::new()
        Evidence            = [ordered]@{}
    }
}

function Add-MlsPreflight {
    <#
    .SYNOPSIS
        Record a resolved input or an identity check in the report's preflight table.
        Preflight rows are context, never criteria - the criteria set is exactly the
        master plan's, and nothing else may appear in it.
    #>
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$Name,
        [AllowEmptyString()][string]$Value,
        [string]$Status = 'OK'
    )
    $Context.Preflight.Add([pscustomobject]@{ Name = $Name; Value = $Value; Status = $Status }) | Out-Null
}

function Add-MlsNote {
    <#
    .SYNOPSIS
        Record a free-text note for the report (fallback path taken, degrade accepted).
    #>
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$Message
    )
    $Context.Note.Add($Message) | Out-Null
}

function Wait-MlsRetryInterval {
    <#
    .SYNOPSIS
        Interruptible sleep between retry attempts.
    .DESCRIPTION
        Sleeps in short slices so Ctrl+C lands promptly instead of after a five-minute
        Start-Sleep, and so a caller can never be blocked longer than one slice past its
        deadline. Mocked in tests to prove the runner does not sleep a full window when a
        check passes early.
    #>
    param([Parameter(Mandatory)][double]$Seconds)
    $remaining = $Seconds
    while ($remaining -gt 0) {
        $slice = [math]::Min($script:SleepSliceSeconds, $remaining)
        Start-Sleep -Seconds $slice
        $remaining -= $slice
    }
}

function Invoke-MlsCriterion {
    <#
    .SYNOPSIS
        Run one master-plan Verify criterion, with bounded retry, and record the row.
    .PARAMETER Id
        The playbook anchor, e.g. V6.3. Must match the traceability table in
        docs/runbooks/layers/README.md exactly.
    .PARAMETER Command
        The command or query actually executed, verbatim, for the report's evidence.
    .PARAMETER RetryWindowMinutes
        The propagation window the playbook specifies. Defaults to the context's standard
        30 minutes.
    .PARAMETER InProcessWaitMinutes
        How long this run may actually wait, if that differs from the declared window.
        The 24-hour criteria pass 0: they evaluate once and report PENDING until the
        declared deadline passes.
    .PARAMETER WindowStartUtc
        When the declared window started (L6 completion, re-seed merge). With
        -PendingWhenUnexpired this turns "not yet, but still inside the window" into
        PENDING instead of FAIL.
    .PARAMETER Control
        The NIST SP 800-171 Rev 2 requirement id(s) (compliance/catalog/nist-800-171r2.json)
        this criterion is evidence for - what Task 5's verification-suite collector turns
        into machine-verified evidence (spec section 4.2). Optional, defaulting to an empty array:
        an un-migrated or third-party call site that omits -Control keeps working exactly
        as before, and a criterion that genuinely evidences no requirement (an availability
        check, a cost check) should pass -Control @() explicitly rather than omit the
        argument, so control-mapping.Tests.ps1's "every criterion declares a Control
        decision" check can tell "considered and mapped to nothing" apart from "not
        considered yet". Every entry is validated against the catalog at call time; a
        control id the catalog does not carry throws immediately, naming the offending id,
        rather than silently becoming a dangling evidence pointer.
    #>
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][ValidatePattern('^V\d{1,2}\.\d{1,2}$')][string]$Id,
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][string]$Expected,
        [Parameter(Mandatory)][scriptblock]$Test,
        [double]$RetryWindowMinutes = -1,
        [double]$PollIntervalSeconds = -1,
        [double]$InProcessWaitMinutes = -1,
        [datetime]$WindowStartUtc = [datetime]::MinValue,
        [switch]$PendingWhenUnexpired,
        [switch]$NoRetry,
        [AllowEmptyCollection()][string[]]$Control = @()
    )
    # $null -ne guard first: [string[]] binds an explicit $null, and .Count on it
    # throws under Set-StrictMode -Version Latest with a message naming neither the
    # parameter nor the criterion. Not reachable from the current tree, but a
    # variable-fed call site is one typo away from it.
    if ($null -ne $Control -and $Control.Count -gt 0) {
        $validControlId = Get-MlsControlCatalogRequirementId
        foreach ($controlId in $Control) {
            if (-not $validControlId.Contains($controlId)) {
                throw "Invoke-MlsCriterion -Control '$controlId' (criterion $Id) is not a requirement id in compliance/catalog/nist-800-171r2.json. Check for a typo, or confirm the catalog actually carries this id (Task 1 is authoritative)."
            }
        }
    }
    $window = if ($RetryWindowMinutes -ge 0) { $RetryWindowMinutes } else { $Context.RetryWindowMinutes }
    $poll = if ($PollIntervalSeconds -gt 0) { $PollIntervalSeconds } else { $Context.PollIntervalSeconds }
    $budget = if ($InProcessWaitMinutes -ge 0) { $InProcessWaitMinutes } else { [math]::Min($window, $Context.MaxWaitMinutes) }
    if ($NoRetry -or $Context.NoRetry) { $budget = 0 }

    $started = [datetime]::UtcNow
    $budgetSeconds = $budget * 60

    # Clamp this criterion's window to what is left of the WHOLE run's budget. Without
    # this each criterion got its own full window in turn and the run's worst case was
    # the sum of them, which for L2 was 90 minutes inside a 60-minute job: the runner
    # killed the audit mid-criterion and no report was ever written (F58).
    #
    # Exhausted budget does not skip the check - it still runs, once, and reports what it
    # sees. It only stops the WAITING, because waiting is the part there is no time for.
    $runBudgetExhausted = $false
    if ($Context.PSObject.Properties['DeadlineUtc'] -and $budgetSeconds -gt 0) {
        $remainingSeconds = ($Context.DeadlineUtc - [datetime]::UtcNow).TotalSeconds
        if ($remainingSeconds -lt $budgetSeconds) {
            $runBudgetExhausted = $true
            $budgetSeconds = [math]::Max(0, $remainingSeconds)
        }
    }
    $attempt = 0
    $sleptSeconds = 0.0
    $result = $null

    while ($true) {
        $attempt++
        try {
            $raw = & $Test
            $result = ConvertTo-MlsCheckResult -InputObject $raw
        }
        catch {
            # A PERMISSION FAILURE IS NEVER A PROPAGATION FAILURE, so it is -Final and the
            # loop below stops on it. Waiting cannot turn "forbidden" into "permitted"; it
            # only converts an actionable FAIL into a job timeout with no report at all.
            #
            # L2's audit ran for exactly sixty minutes and was killed by the runner. It was
            # not slow: mls-verifier had no role assignment at the mls management group, so
            # every criterion reading MG state threw AuthorizationFailed and each one waited
            # out the whole propagation window in turn (F57).
            $final = $_.Exception.Message -match 'AuthorizationFailed|Authorization_RequestDenied|InsufficientPrivileges|\bForbidden\b|\b403\b'
            $result = New-MlsCheckResult -Passed $false -Final:$final -Observed "check threw: $($_.Exception.Message)" `
                -Detail "$($_.Exception.GetType().Name) at $($_.InvocationInfo.ScriptLineNumber)$(if ($final) { ' - permission failure, not retried: the identity cannot see this, and waiting will not change that' })"
        }
        if ($result.Status -eq 'SKIP' -or $result.Passed -or $result.Final) { break }
        # Budget consumed is the greater of wall-clock elapsed and the sleep we asked for.
        # In production they agree (Wait-MlsRetryInterval really sleeps); under test, where
        # the wait is mocked, the requested-sleep tally is what bounds the loop - so a
        # mocked retry can never spin until a real deadline.
        $consumed = [math]::Max((([datetime]::UtcNow) - $started).TotalSeconds, $sleptSeconds)
        if ($consumed -ge $budgetSeconds) { break }
        Wait-MlsRetryInterval -Seconds $poll
        $sleptSeconds += $poll
    }

    $finishedUtc = [datetime]::UtcNow
    $elapsed = ($finishedUtc - $started).TotalSeconds
    $status = 'FAIL'
    $detail = $result.Detail

    # Say so when the answer is "we ran out of time to keep asking", so a reader never
    # mistakes a truncated window for a completed one.
    if ($runBudgetExhausted -and -not $result.Passed -and $result.Status -ne 'SKIP') {
        $shortfall = [math]::Round($budget - ($budgetSeconds / 60), 1)
        $detail = ("run budget exhausted: this criterion retried for {0} of its declared {1} min window ({2} min short) because the audit's overall {3} min budget ran out. Re-run it on its own to give it the full window. {4}" -f `
                [math]::Round($budgetSeconds / 60, 1), $budget, $shortfall, $Context.RunBudgetMinutes, $detail).Trim()
    }
    if ($result.Status -eq 'SKIP') {
        $status = 'SKIP'
    }
    elseif ($result.Passed) {
        $status = 'PASS'
    }
    elseif ($PendingWhenUnexpired -and -not $result.Final -and $WindowStartUtc -ne [datetime]::MinValue) {
        # A -Final failure is a real defect (a wrong value, a missing input), never a
        # "not yet": it must not be softened to PENDING just because a long window is open.
        $windowEnd = $WindowStartUtc.ToUniversalTime().AddMinutes($window)
        if ($finishedUtc -lt $windowEnd) {
            $status = 'PENDING'
            $detail = ("declared window has not elapsed: deadline {0:yyyy-MM-ddTHH:mm:ssZ}; re-run this criterion before then. {1}" -f $windowEnd, $detail).Trim()
        }
    }

    $row = [pscustomobject]@{
        Id                 = $Id
        Description        = $Description
        Command            = $Command
        Expected           = $Expected
        Observed           = $result.Observed
        Status             = $status
        Detail             = $detail
        Attempt            = $attempt
        ElapsedSeconds     = [math]::Round($elapsed, 2)
        SleptSeconds       = $sleptSeconds
        RetryWindowMinutes = $window
        PollIntervalSecond = $poll
        StartedUtc         = $started.ToString('yyyy-MM-ddTHH:mm:ssZ')
        FinishedUtc        = $finishedUtc.ToString('yyyy-MM-ddTHH:mm:ssZ')
        Control            = @($Control)
    }
    $Context.Criterion.Add($row) | Out-Null

    $colour = switch ($status) {
        'PASS' { [ConsoleColor]::Green }
        'FAIL' { [ConsoleColor]::Red }
        'PENDING' { [ConsoleColor]::Yellow }
        default { [ConsoleColor]::DarkYellow }
    }
    Write-MlsStatus -Message ("[{0,-7}] {1}  {2}" -f $status, $Id, $Description) -Color $colour
    if ($status -ne 'PASS') {
        Write-MlsStatus -Message ("           observed: {0}" -f (Format-MlsValue -Value $result.Observed)) -Color $colour
    }
    return $row
}

function ConvertTo-MlsCheckResult {
    <#
    .SYNOPSIS
        Normalise whatever a -Test scriptblock returned into a check result.
    #>
    param($InputObject)
    $candidate = $InputObject
    if ($candidate -is [System.Collections.IEnumerable] -and $candidate -isnot [string] -and $candidate -isnot [System.Collections.IDictionary]) {
        $items = @($candidate)
        if ($items.Count -eq 0) { $candidate = $null } else { $candidate = $items[-1] }
    }
    if ($null -eq $candidate) {
        return New-MlsCheckResult -Passed $false -Observed '(the check returned nothing)' `
            -Detail 'A criterion must return New-MlsCheckResult.' -Final
    }
    if ($candidate -is [bool]) {
        return New-MlsCheckResult -Passed $candidate -Observed "$candidate"
    }
    $passed = Get-MlsProperty -InputObject $candidate -Name 'Passed'
    if ($null -eq $passed) {
        return New-MlsCheckResult -Passed $false -Observed (Format-MlsValue -Value $candidate) `
            -Detail 'A criterion must return New-MlsCheckResult.' -Final
    }
    return [pscustomobject]@{
        Passed   = [bool]$passed
        Observed = [string](Get-MlsProperty -InputObject $candidate -Name 'Observed')
        Detail   = [string](Get-MlsProperty -InputObject $candidate -Name 'Detail')
        Status   = [string](Get-MlsProperty -InputObject $candidate -Name 'Status')
        Final    = [bool](Get-MlsProperty -InputObject $candidate -Name 'Final')
    }
}

function Get-MlsStatusCount {
    <#
    .SYNOPSIS
        Count criteria in one status.
    #>
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$Status
    )
    return @($Context.Criterion | Where-Object { $_.Status -eq $Status }).Count
}

function Get-MlsFailCount {
    <#
    .SYNOPSIS
        Number of FAIL rows in the run.
    #>
    param([Parameter(Mandatory)]$Context)
    return (Get-MlsStatusCount -Context $Context -Status 'FAIL')
}

function Get-MlsExitCode {
    <#
    .SYNOPSIS
        0 when no criterion FAILed, 1 otherwise. SKIP and PENDING do not fail a run - they
        are loud in the report instead (L06.md V6.3 signs off PENDING by design).
    #>
    param([Parameter(Mandatory)]$Context)
    if ((Get-MlsFailCount -Context $Context) -gt 0) { return 1 }
    return 0
}

# --- reporting -------------------------------------------------------------------------

function Format-MlsCell {
    <#
    .SYNOPSIS
        Make a value safe inside a Markdown table cell.
    #>
    param(
        $Value,
        [int]$MaximumLength = 240
    )
    $text = Format-MlsValue -Value $Value -MaximumLength $MaximumLength
    return ($text -replace '\|', '\|')
}

function Write-MlsReport {
    <#
    .SYNOPSIS
        Write verification/reports/L<NN>-<timestamp>.md and its machine-readable .json
        sibling, and return both paths plus the counts.
    #>
    param(
        [Parameter(Mandatory)]$Context,
        [string]$ReportRoot = '',
        [string]$Timestamp = ''
    )
    $root = if ([string]::IsNullOrWhiteSpace($ReportRoot)) { $Context.ReportRoot } else { $ReportRoot }
    if (-not (Test-Path -LiteralPath $root)) {
        New-Item -ItemType Directory -Path $root -Force | Out-Null
    }
    if ([string]::IsNullOrWhiteSpace($Timestamp)) {
        $Timestamp = [datetime]::UtcNow.ToString('yyyyMMdd-HHmmss') + 'Z'
    }
    $stem = "$($Context.LayerId)-$Timestamp"
    $markdownPath = Join-Path -Path $root -ChildPath "$stem.md"
    $jsonPath = Join-Path -Path $root -ChildPath "$stem.json"

    $counts = [ordered]@{
        Total   = @($Context.Criterion).Count
        Pass    = Get-MlsStatusCount -Context $Context -Status 'PASS'
        Fail    = Get-MlsStatusCount -Context $Context -Status 'FAIL'
        Skip    = Get-MlsStatusCount -Context $Context -Status 'SKIP'
        Pending = Get-MlsStatusCount -Context $Context -Status 'PENDING'
    }
    $overall = if ($counts.Fail -gt 0) { 'FAIL' } elseif ($counts.Total -eq 0) { 'EMPTY' } else { 'PASS' }
    $finishedUtc = [datetime]::UtcNow

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("# $($Context.LayerId) audit - $($Context.Title)")
    $lines.Add('')
    $lines.Add('| | |')
    $lines.Add('|---|---|')
    $lines.Add("| **Layer** | L$($Context.Layer) |")
    $lines.Add("| **Audit script** | ``$($Context.ScriptName)`` |")
    $lines.Add("| **Playbook** | ``docs/runbooks/layers/$($Context.LayerId).md`` section Validation cycle |")
    $lines.Add("| **Identity** | $($Context.Identity) |")
    $lines.Add("| **Started (UTC)** | $($Context.StartedUtc.ToString('yyyy-MM-ddTHH:mm:ssZ')) |")
    $lines.Add("| **Finished (UTC)** | $($finishedUtc.ToString('yyyy-MM-ddTHH:mm:ssZ')) |")
    $lines.Add("| **Result** | **$overall** - $($counts.Pass) PASS / $($counts.Fail) FAIL / $($counts.Skip) SKIP / $($counts.Pending) PENDING of $($counts.Total) criteria |")
    $lines.Add('')

    if (@($Context.Preflight).Count -gt 0) {
        $lines.Add('## Preflight')
        $lines.Add('')
        $lines.Add('| Input | Value | Status |')
        $lines.Add('|---|---|---|')
        foreach ($row in $Context.Preflight) {
            $lines.Add("| $(Format-MlsCell -Value $row.Name) | $(Format-MlsCell -Value $row.Value) | $($row.Status) |")
        }
        $lines.Add('')
    }

    $lines.Add('## Criteria')
    $lines.Add('')
    $lines.Add('| Id | Criterion | Status | Attempts | Elapsed (s) | Window (min) |')
    $lines.Add('|---|---|---|---|---|---|')
    foreach ($row in $Context.Criterion) {
        $lines.Add("| **$($row.Id)** | $(Format-MlsCell -Value $row.Description) | **$($row.Status)** | $($row.Attempt) | $($row.ElapsedSeconds) | $($row.RetryWindowMinutes) |")
    }
    $lines.Add('')

    $lines.Add('## Evidence')
    $lines.Add('')
    foreach ($row in $Context.Criterion) {
        $lines.Add("### $($row.Id) - $($row.Description) - **$($row.Status)**")
        $lines.Add('')
        $lines.Add('```')
        $lines.Add($row.Command)
        $lines.Add('```')
        $lines.Add('')
        $lines.Add("- **Expected:** $(Format-MlsValue -Value $row.Expected -MaximumLength 1200)")
        $lines.Add("- **Observed:** $(Format-MlsValue -Value $row.Observed -MaximumLength 1200)")
        if (-not [string]::IsNullOrWhiteSpace($row.Detail)) {
            $lines.Add("- **Note:** $(Format-MlsValue -Value $row.Detail -MaximumLength 1200)")
        }
        $controlValue = if (@($row.Control).Count -gt 0) { ($row.Control -join ', ') } else { '(none - this criterion asserts no 800-171 requirement)' }
        $lines.Add("- **Control (NIST SP 800-171 Rev 2):** $controlValue")
        $lines.Add("- **Retry:** window $($row.RetryWindowMinutes) min, poll $($row.PollIntervalSecond) s, attempts $($row.Attempt), slept $($row.SleptSeconds) s")
        $lines.Add('')
    }

    if (@($Context.Note).Count -gt 0) {
        $lines.Add('## Notes')
        $lines.Add('')
        foreach ($note in $Context.Note) { $lines.Add("- $note") }
        $lines.Add('')
    }

    $lines.Add('---')
    $lines.Add('')
    $lines.Add('Read-only audit: every call this run made was a GET-shaped read as `mls-verifier`.')
    $lines.Add('Where a criterion involves a write attempt (L2 V2.2''s untagged canary resource group),')
    $lines.Add('the deploy workflow performs the write and this audit confirms it from the Activity Log.')
    $lines.Add('')

    Set-Content -LiteralPath $markdownPath -Value ($lines -join [Environment]::NewLine) -Encoding utf8

    $document = [ordered]@{
        layer      = $Context.Layer
        layerId    = $Context.LayerId
        title      = $Context.Title
        script     = $Context.ScriptName
        identity   = $Context.Identity
        startedUtc = $Context.StartedUtc.ToString('yyyy-MM-ddTHH:mm:ssZ')
        finishedUtc = $finishedUtc.ToString('yyyy-MM-ddTHH:mm:ssZ')
        result     = $overall
        counts     = $counts
        preflight  = @($Context.Preflight)
        criteria   = @($Context.Criterion)
        notes      = @($Context.Note)
        evidence   = $Context.Evidence
    }
    Set-Content -LiteralPath $jsonPath -Value ($document | ConvertTo-Json -Depth 12) -Encoding utf8

    return [pscustomobject]@{
        MarkdownPath = $markdownPath
        JsonPath     = $jsonPath
        Result       = $overall
        Counts       = $counts
    }
}

# --- domain helpers shared by more than one layer --------------------------------------

function Test-MlsAdaptiveCard {
    <#
    .SYNOPSIS
        Validate one Adaptive Card payload against the profile L8 pins (V8.4).
    .DESCRIPTION
        The repo pins schema 1.5 with Action.Submit only so a single payload renders in
        both the Direct Line Web Chat embed and in Teams (L08.md V8.4). This validator
        checks that profile offline - type, version, element and action types, and the
        absence of Action.Execute - because the Verifier must not depend on fetching a
        schema at audit time. Returns Valid plus the list of problems.
    #>
    param(
        [Parameter(Mandatory)]$Card,
        [string]$Version = '1.5'
    )
    $problem = [System.Collections.Generic.List[string]]::new()
    $type = Get-MlsProperty -InputObject $Card -Name 'type'
    if ($type -ne 'AdaptiveCard') { $problem.Add("type is '$type', expected 'AdaptiveCard'") }
    $cardVersion = Get-MlsProperty -InputObject $Card -Name 'version'
    if ("$cardVersion" -ne $Version) { $problem.Add("version is '$cardVersion', expected '$Version'") }

    $walk = {
        param($Node, $Path)
        if ($null -eq $Node) { return }
        if ($Node -is [System.Collections.IEnumerable] -and $Node -isnot [string] -and $Node -isnot [System.Collections.IDictionary]) {
            $index = 0
            foreach ($item in $Node) {
                & $walk $item "$Path[$index]"
                $index++
            }
            return
        }
        $nodeType = Get-MlsProperty -InputObject $Node -Name 'type'
        if ($nodeType -and "$nodeType".StartsWith('Action.')) {
            if ("$nodeType" -notin $script:AdaptiveCardActionType) {
                $problem.Add("$Path uses action '$nodeType' (Action.Execute is not renderable in the Web Chat host the Ask tab embeds)")
            }
        }
        elseif ($nodeType -and "$nodeType" -ne 'AdaptiveCard') {
            if ("$nodeType" -notin $script:AdaptiveCardElementType) {
                $problem.Add("$Path uses element '$nodeType', which is not in the pinned 1.5 element set")
            }
        }
        foreach ($childName in @('body', 'actions', 'items', 'columns', 'facts', 'rows', 'cells', 'card', 'inlines', 'selectAction')) {
            $child = Get-MlsProperty -InputObject $Node -Name $childName
            if ($null -ne $child) { & $walk $child "$Path.$childName" }
        }
    }
    & $walk (Get-MlsProperty -InputObject $Card -Name 'body') 'body'
    & $walk (Get-MlsProperty -InputObject $Card -Name 'actions') 'actions'

    return [pscustomobject]@{
        Valid   = ($problem.Count -eq 0)
        Problem = @($problem)
    }
}

function Test-MlsGeneratedUi {
    <#
    .SYNOPSIS
        True when a response body contains generated UI code - the thing V8.4 forbids
        outright ("zero HTML/JS/JSX in any response").
    #>
    param([AllowEmptyString()][AllowNull()][string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    return [bool]($Text -match $script:GeneratedUiPattern)
}

function Test-MlsSpdxDocument {
    <#
    .SYNOPSIS
        Structural SPDX validation for V9.3 - document namespace, creation info, SPDX
        version and a non-empty package list.
    #>
    param([Parameter(Mandatory)]$Document)
    $problem = [System.Collections.Generic.List[string]]::new()
    foreach ($field in @('spdxVersion', 'SPDXID', 'name', 'documentNamespace', 'creationInfo')) {
        if ($null -eq (Get-MlsProperty -InputObject $Document -Name $field)) { $problem.Add("missing required field '$field'") }
    }
    $version = Get-MlsProperty -InputObject $Document -Name 'spdxVersion'
    if ($version -and "$version" -notmatch '^SPDX-\d+\.\d+$') { $problem.Add("spdxVersion '$version' is not of the form SPDX-<major>.<minor>") }
    $packages = @(Get-MlsProperty -InputObject $Document -Name 'packages')
    if ($packages.Count -eq 0) { $problem.Add('package list is empty') }
    return [pscustomobject]@{
        Valid       = ($problem.Count -eq 0)
        Problem     = @($problem)
        PackageCount = $packages.Count
    }
}

function Test-MlsMonotonicTimestamp {
    <#
    .SYNOPSIS
        True when the supplied stage timestamps are non-decreasing (V10.1/V10.2 require
        "timestamps monotonic" across the healing trail).
    #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Timestamp)
    $parsed = @()
    foreach ($value in $Timestamp) {
        if ($null -eq $value -or [string]::IsNullOrWhiteSpace("$value")) { continue }
        $slot = [datetime]::MinValue
        if (-not [datetime]::TryParse("$value", [ref]$slot)) {
            return [pscustomobject]@{ Monotonic = $false; Problem = "unparseable timestamp '$value'" }
        }
        $parsed += $slot.ToUniversalTime()
    }
    for ($i = 1; $i -lt $parsed.Count; $i++) {
        if ($parsed[$i] -lt $parsed[$i - 1]) {
            return [pscustomobject]@{ Monotonic = $false; Problem = "stage $($i + 1) ($($parsed[$i].ToString('o'))) precedes stage $i ($($parsed[$i - 1].ToString('o')))" }
        }
    }
    return [pscustomobject]@{ Monotonic = $true; Problem = '' }
}

Export-ModuleMember -Function @(
    'Write-MlsStatus',
    'Get-MlsProperty',
    'Get-MlsCollection',
    'Test-MlsHasProperty',
    'Format-MlsValue',
    'Format-MlsCell',
    'Test-MlsSetEquality',
    'Get-MlsPercentile',
    'Resolve-MlsInput',
    'Get-MlsJsonFile',
    'Get-MlsControlCatalogRequirementId',
    'Assert-MlsReadOnlyAzArgument',
    'Assert-MlsReadOnlyGhArgument',
    'Assert-MlsCommand',
    'Invoke-MlsAz',
    'Invoke-MlsGh',
    'Invoke-MlsGit',
    'Invoke-MlsRest',
    'Invoke-MlsGraph',
    'Invoke-MlsHttp',
    'Invoke-MlsSqlQuery',
    'Connect-MlsCompliance',
    'Get-MlsLabel',
    'Get-MlsLabelPolicy',
    'Invoke-MlsMcpToolCatalog',
    'Invoke-MlsLocalCommand',
    'Invoke-MlsChildAudit',
    'New-MlsCheckResult',
    'New-MlsAuditContext',
    'Add-MlsPreflight',
    'Add-MlsNote',
    'Wait-MlsRetryInterval',
    'Invoke-MlsCriterion',
    'ConvertTo-MlsCheckResult',
    'Get-MlsStatusCount',
    'Get-MlsFailCount',
    'Get-MlsExitCode',
    'Write-MlsReport',
    'Test-MlsAdaptiveCard',
    'Test-MlsGeneratedUi',
    'Test-MlsSpdxDocument',
    'Test-MlsMonotonicTimestamp'
)
