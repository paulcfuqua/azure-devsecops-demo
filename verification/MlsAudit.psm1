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

# Standard bounded-retry window and poll cadence: "bounded retry 30 minutes, poll every
# 5 minutes" (master plan risk 2; repeated verbatim in L01-L07 playbooks).
$script:StandardRetryWindowMinutes = 30
$script:StandardPollIntervalSeconds = 300

# Hard ceiling on how long ONE criterion may block a single audit run. The 24-hour
# criteria (V6.3 cost export, V10.1/V10.2 self-heal) declare a 24 h window but must not
# hang the Verifier for a day: they pass -InProcessWaitMinutes 0 -PendingWhenUnexpired,
# which records PENDING until the declared deadline actually passes.
$script:DefaultMaxWaitMinutes = 120

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
        $found = Get-MlsProperty -InputObject $Response -Name $key
        if ($null -ne $found) { return @($found) }
    }
    return @($Response)
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

function Invoke-MlsAz {
    <#
    .SYNOPSIS
        Read-only az CLI call, JSON-parsed. Single choke point - mocked in every test.
    #>
    param(
        [Parameter(Mandatory)][string[]]$Argument,
        [switch]$AllowFailure,
        [switch]$Raw
    )
    Assert-MlsReadOnlyAzArgument -Argument $Argument
    Assert-MlsCommand -Name 'az' -Hint 'Install the Azure CLI and sign in as mls-verifier (az login --service-principal ...).'
    $output = & az @Argument 2>$null
    if ($LASTEXITCODE -ne 0) {
        if ($AllowFailure) { return $null }
        throw "az $($Argument -join ' ') failed with exit code $LASTEXITCODE."
    }
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
        [switch]$Raw
    )
    Assert-MlsReadOnlyGhArgument -Argument $Argument
    Assert-MlsCommand -Name 'gh' -Hint 'Install the GitHub CLI and export the Verifier read token as GH_TOKEN.'
    $output = & gh @Argument 2>$null
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        if ($AllowFailure) { return $null }
        throw "gh $($Argument -join ' ') failed with exit code $exitCode."
    }
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
    if (Get-Command -Name 'Invoke-MgGraphRequest' -ErrorAction SilentlyContinue) {
        return Invoke-MgGraphRequest -Method $Method -Uri $Uri -OutputType PSObject
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

function Invoke-MlsSqlQuery {
    <#
    .SYNOPSIS
        Read-only query against the lakehouse SQL analytics endpoint as mls-verifier
        (workspace Viewer, granted at L5). Rejects anything that is not a SELECT.
    #>
    param(
        [Parameter(Mandatory)][string]$ServerName,
        [Parameter(Mandatory)][string]$DatabaseName,
        [Parameter(Mandatory)][string]$Query,
        [int]$TimeoutSec = 120
    )
    if ($Query -notmatch '(?is)^\s*(select|with)\b') {
        throw 'Refusing a non-SELECT statement: the Verifier only reads.'
    }
    Assert-MlsCommand -Name 'Invoke-Sqlcmd' -Hint 'Install SqlServer (Install-Module SqlServer -Scope CurrentUser) so the audit can query the lakehouse SQL analytics endpoint as mls-verifier.'
    return Invoke-Sqlcmd -ServerInstance $ServerName -Database $DatabaseName -Query $Query `
        -ConnectionTimeout $TimeoutSec -AccessToken $null -ErrorAction Stop
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
        [string]$Identity = 'mls-verifier (Reader + Directory.Read.All + Policy.Read.All) - read-only by contract',
        [switch]$NoRetry
    )
    if ($RetryWindowMinutes -lt 0) { $RetryWindowMinutes = $script:StandardRetryWindowMinutes }
    if ($PollIntervalSeconds -le 0) { $PollIntervalSeconds = $script:StandardPollIntervalSeconds }
    if ($MaxWaitMinutes -lt 0) { $MaxWaitMinutes = $script:DefaultMaxWaitMinutes }
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
        NoRetry             = [bool]$NoRetry
        Identity            = $Identity
        StartedUtc          = [datetime]::UtcNow
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
        [switch]$NoRetry
    )
    $window = if ($RetryWindowMinutes -ge 0) { $RetryWindowMinutes } else { $Context.RetryWindowMinutes }
    $poll = if ($PollIntervalSeconds -gt 0) { $PollIntervalSeconds } else { $Context.PollIntervalSeconds }
    $budget = if ($InProcessWaitMinutes -ge 0) { $InProcessWaitMinutes } else { [math]::Min($window, $Context.MaxWaitMinutes) }
    if ($NoRetry -or $Context.NoRetry) { $budget = 0 }

    $started = [datetime]::UtcNow
    $budgetSeconds = $budget * 60
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
            $result = New-MlsCheckResult -Passed $false -Observed "check threw: $($_.Exception.Message)" `
                -Detail "$($_.Exception.GetType().Name) at $($_.InvocationInfo.ScriptLineNumber)"
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
    'Format-MlsValue',
    'Format-MlsCell',
    'Test-MlsSetEquality',
    'Get-MlsPercentile',
    'Resolve-MlsInput',
    'Get-MlsJsonFile',
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
