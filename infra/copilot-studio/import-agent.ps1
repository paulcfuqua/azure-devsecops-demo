#Requires -Version 7.0
<#
.SYNOPSIS
    L8 - pack the committed Meridian Launch Copilot solution source and import it into
    the DEMO Power Platform environment.

.DESCRIPTION
    The tenant-ward half of the round trip (see README section 5). Reads the reviewed,
    committed source under infra/copilot-studio/solution/, packs it, and imports it into
    the demo environment. This is the only sanctioned way anything reaches that
    environment: a human editing the demo agent directly is drift, and the next run of
    this script overwrites it.

    Wraps the Power Platform CLI (`pac`). It never authenticates by itself: an auth
    profile must already exist, created by `pac auth create` (in CI, after
    azure/login@v2, with --managedIdentity).

    IDEMPOTENT. Before importing, the online solution version is compared with the
    version in the committed source. If they already match, the import is skipped with a
    notice - re-running is a cheap no-op rather than a needless tenant write. -Force
    imports regardless. When the online version cannot be determined the script imports
    anyway, because `pac solution import --force-overwrite --stage-and-upgrade` is
    itself convergent.

    FAILS BEFORE IT ACTS. pac present, an auth profile, a resolvable environment, and a
    solution source tree that actually contains Other/Solution.xml are all verified up
    front. Nothing mutating runs until every check passes, so a missing prerequisite can
    never leave the demo environment half-imported.

    PACKAGE TYPE MATCHES THE SOURCE, AND IS ASSERTED (F132). Microsoft's ALM guidance is
    "export and deploy solutions as managed, unless setting up a development environment" -
    and that guidance assumes a separate authoring environment. This demo has ONE Power
    Platform environment, which is both the maker environment and the deployment target, so
    the committed source is unmanaged and so is the import. Callers may still ask for
    managed, but a request that the source cannot satisfy now fails in PREFLIGHT with the
    reason, rather than inside `pac solution pack` with "Solution package type did not match
    requested type" - which is where it failed for a week while the workflow's own default
    asked for a package the repo has never contained.

.NOTES
    `--publish-changes` publishes solution CUSTOMIZATIONS. That is NOT the same thing as
    publishing the agent in Copilot Studio. Microsoft: "You must publish your imported
    agent before it can be shared." That step, and everything else in the post-import
    checklist this script prints, is manual because those settings are documented as not
    solution-aware.

    Authored only - this has never been run against a real environment.

.EXAMPLE
    ./import-agent.ps1 -WhatIf
    # Prints every pac command it would run. Contacts nothing.

.EXAMPLE
    ./import-agent.ps1 -EnvironmentUrl https://contoso-demo.crm.dynamics.com -Force
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    # Demo environment URL. Defaults to the POWERPLATFORM_ENVIRONMENT_URL variable from
    # the GitHub `demo` environment; never committed (CLAUDE.md hard rule 5).
    [string]$EnvironmentUrl = $env:POWERPLATFORM_ENVIRONMENT_URL,

    # Solution unique name, per agent-definition.md section 1.
    [string]$SolutionName = 'MeridianLaunchCopilot',

    # Root of the committed unpacked source.
    [string]$SolutionRoot = (Join-Path $PSScriptRoot 'solution'),

    # Where the packed .zip is written. Never under solution/ - it is a build artifact.
    [string]$ArtifactPath = (Join-Path ([IO.Path]::GetTempPath()) 'mls-copilot-studio'),

    # Optional deployment-settings file for environment variables / connection
    # references. Ignored (with a notice) when the path does not exist.
    [string]$SettingsFile,

    # THE MCP SERVER'S LIVE HOSTNAME, and F129 is why this parameter exists. The connector
    # definition in the committed solution is TOKENISED (`${mcpHost}`) because a Container
    # Apps FQDN embeds the ENVIRONMENT's randomly-assigned domain - `happymeadow-9e15a087`
    # today, `thankfulisland-7f9b1aba` before the last rebuild. Azure picks a new one every
    # time the environment is recreated, so a literal host in a committed artifact is
    # guaranteed to be wrong after the very teardown/rebuild this demo exists to show.
    #
    # Resolved from MLS_MCP_HOST, or from Azure when the CLI is available. NEVER defaulted
    # to a literal: importing a connector that points at a dead host produces "Connector
    # request failed" three layers away in Copilot Studio, with nothing naming the cause.
    [string]$McpHost = $env:MLS_MCP_HOST,

    # Pack and import unmanaged instead of managed. Troubleshooting only.
    [switch]$Unmanaged,

    # Import even when the online version already matches the committed source.
    [switch]$Force,

    # Minutes pac waits on the asynchronous import before giving up.
    [ValidateRange(1, 240)]
    [int]$MaxAsyncWaitMinutes = 60
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Where the MCP server lives, for the -McpHost fallback lookup. Defaults only; a rebranded
# estate passes -McpHost outright rather than relying on these.
$script:McpAppName = if ($env:MLS_MCP_APP_NAME) { $env:MLS_MCP_APP_NAME } else { 'mls-mcp-demo-ca' }
$script:McpResourceGroup = if ($env:MLS_MCP_RESOURCE_GROUP) { $env:MLS_MCP_RESOURCE_GROUP } else { 'mls-rg-apps' }

function Write-Status {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
        Justification = 'Interactive operations script; console output is the product.')]
    param(
        # AllowEmptyString: the banners print blank spacer lines via Write-Status '',
        # which a bare Mandatory string parameter rejects.
        [Parameter(Mandatory)][AllowEmptyString()][string]$Message,        [ConsoleColor]$Color = [ConsoleColor]::Gray
    )
    Write-Host $Message -ForegroundColor $Color
}

function Assert-PacCli {
    <#
    .SYNOPSIS
        Fail fast, and actionably, when the Power Platform CLI is missing.
    #>
    if (Get-Command 'pac' -CommandType Application -ErrorAction SilentlyContinue) { return }
    throw @'
The Power Platform CLI (`pac`) is not on PATH, so nothing can be imported.

Install one of these, then re-run:
  * GitHub Actions : add a step `uses: microsoft/powerplatform-actions/actions-install@v1`
                     before this script (it puts pac on PATH for the job).
  * .NET tool      : dotnet tool install --global Microsoft.PowerApps.CLI.Tool
  * Windows        : winget install Microsoft.PowerAppsCLI
  * VS Code        : the Power Platform Tools extension ships pac.

The demo environment was NOT contacted and nothing was changed.
'@
}

function Assert-PacAuthProfile {
    <#
    .SYNOPSIS
        Fail fast when no pac authentication profile exists. This script never signs in
        on its own - creating credentials is the caller's job, by design.
    #>
    $profiles = & pac auth list 2>&1
    $exitCode = $LASTEXITCODE
    $text = ($profiles | Out-String)

    if ($exitCode -eq 0 -and $text -match '\S' -and $text -notmatch '(?i)no profiles|no auth') {
        Write-Status 'pac authentication profile: present.' -Color Green
        return
    }

    throw @"
No Power Platform authentication profile is configured, so there is no environment to
import into. `pac auth list` said:

$($text.Trim())

Create one first:
  * GitHub Actions (no secret) : run azure/login@v2 with OIDC, then
        pac auth create --environment "<url>" --name mls-l8 --managedIdentity
  * Service principal          : pac auth create --applicationId <id> --clientSecret <secret> --tenant <tenant>
  * Interactive                : pac auth create --environment "<url>"

The demo environment was NOT contacted and nothing was changed.
"@
}

function Resolve-EnvironmentUrl {
    <#
    .SYNOPSIS
        Resolve the demo environment URL, or fail with the exact variable to set.
    #>
    param([string]$Candidate)
    if (-not [string]::IsNullOrWhiteSpace($Candidate)) { return $Candidate.Trim() }
    throw @'
No target environment was supplied, so this script does not know where to import.

Set one of:
  * -EnvironmentUrl https://<org>.crm.dynamics.com
  * the POWERPLATFORM_ENVIRONMENT_URL environment variable (GitHub `demo` environment
    variable; see infra/copilot-studio/README.md section 2).

`pac env list` shows the environments the current profile can reach.
Nothing was imported and no environment was contacted.
'@
}

function Assert-SolutionSource {
    <#
    .SYNOPSIS
        Refuse to pack a source tree that is missing or empty. Packing nothing and
        importing it would wipe the agent in the demo environment.
    #>
    param(
        [Parameter(Mandatory)][string]$SolutionFolder,
        [Parameter(Mandatory)][string]$SolutionName
    )
    $solutionXml = Join-Path -Path $SolutionFolder -ChildPath 'Other' -AdditionalChildPath 'Solution.xml'
    if (Test-Path -LiteralPath $solutionXml) {
        Write-Status "Solution source: $SolutionFolder" -Color Green
        return $solutionXml
    }
    throw @"
No solution source to import: '$solutionXml' does not exist.

This means the export pipeline has never run, or its output was not committed. The repo
is the source of truth for what reaches the demo environment, so this script will not
invent a solution or fall back to whatever is already deployed.

Fix by exporting first:
    ./export-agent.ps1 -EnvironmentUrl <authoring env url>
then commit the resulting tree under infra/copilot-studio/solution/$SolutionName/.

The demo environment was NOT contacted and nothing was changed.
"@
}

function Assert-PackageTypeMatchesSource {
    <#
    .SYNOPSIS
        Refuse a package type the committed source cannot produce (F132).
    .DESCRIPTION
        `pac solution pack --packagetype Managed` over a tree whose Solution.xml says
        <Managed>0</Managed> fails with "Solution package type did not match requested
        type" - a message that names the symptom and not the cause. The workflow default
        asked for Managed against unmanaged source, so every L8 import either skipped or
        failed, and the failure looked like a `pac` problem rather than a configuration
        one. This asserts the constant against the system that owns it, before any write.
    #>
    param(
        [Parameter(Mandatory)][string]$SolutionXmlPath,
        [Parameter(Mandatory)][ValidateSet('Managed', 'Unmanaged')][string]$PackageType
    )

    # An unreadable flag is not a failure: pack will produce the real error, and refusing
    # to import over a parse problem in our own precondition would be worse than the bug.
    $sourceIsManaged = $null
    try {
        $node = ([xml](Get-Content -LiteralPath $SolutionXmlPath -Raw)).SelectSingleNode('//Managed')
        if ($node) { $sourceIsManaged = ($node.InnerText.Trim() -eq '1') }
    } catch {
        Write-Status "Could not read the source's Managed flag: $($_.Exception.Message)" -Color Yellow
        return
    }
    if ($null -eq $sourceIsManaged) { return }

    $sourceType = if ($sourceIsManaged) { 'Managed' } else { 'Unmanaged' }
    if ($sourceType -eq $PackageType) {
        Write-Status "Package type $PackageType matches the committed source." -Color Green
        return
    }

    throw @"
Cannot pack '$PackageType' from $sourceType source.

$SolutionXmlPath says <Managed>$(if ($sourceIsManaged) { '1' } else { '0' })</Managed>, and
pac will refuse the pack with "Solution package type did not match requested type".

$(if ($PackageType -eq 'Managed') {
@'
This demo has ONE Power Platform environment - it is both the maker environment and the
deployment target - so the source is committed unmanaged on purpose. Re-run with
-Unmanaged (the workflow's deploy_as_managed=false, which is now its default). Deploying
managed needs a managed export from a separate authoring environment first; that is a
decision about the ALM topology, not a flag.
'@
} else {
@'
The source has been exported managed. Import it managed (drop -Unmanaged), or export
unmanaged source if this environment is meant to be the authoring one.
'@
})

The demo environment was NOT contacted and nothing was changed.
"@
}

function Resolve-McpHost {
    <#
        The live MCP FQDN, or a hard failure naming what to do. Never a stale literal.
    #>
    param([string]$Candidate)
    if (-not [string]::IsNullOrWhiteSpace($Candidate)) { return $Candidate.Trim() }
    $resolved = ''
    if (Get-Command -Name az -CommandType Application -ErrorAction SilentlyContinue) {
        try {
            $resolved = (& az containerapp show --name $script:McpAppName --resource-group $script:McpResourceGroup `
                    --query 'properties.configuration.ingress.fqdn' --output tsv 2>$null | Out-String).Trim()
        }
        catch { $resolved = '' }
    }
    if ([string]::IsNullOrWhiteSpace($resolved)) {
        throw @"
Cannot resolve the MCP server's hostname, and this import will not guess one (F129).

The connector definition is tokenised with `${mcpHost}` on purpose: a Container Apps FQDN
carries the environment's randomly-assigned domain, which changes on every rebuild. Importing
a stale host produces "Connector request failed" inside Copilot Studio, three layers from the
cause and naming none of it.

Supply it either way:
  -McpHost mls-mcp-demo-ca.<env-domain>.<region>.azurecontainerapps.io
  `$env:MLS_MCP_HOST = '<same>'
or sign in to Azure so this can read it:
  az containerapp show -n $script:McpAppName -g $script:McpResourceGroup --query properties.configuration.ingress.fqdn -o tsv
"@
    }
    return $resolved
}

function Get-TokenisedSolutionSource {
    <#
        Copy the committed source to a staging folder and resolve its tokens, so `pac
        solution pack` packs a tree with real values while the REPOSITORY keeps the tokens.
        The same shape as infra/entra/manifest.json's ${prefix}/${env} (F90): one estate-
        specific value, one place that resolves it, and nothing environment-shaped committed.
    #>
    param(
        [Parameter(Mandatory)][string]$SolutionFolder,
        [Parameter(Mandatory)][string]$StagingRoot,
        [Parameter(Mandatory)][hashtable]$Token
    )
    if (Test-Path -LiteralPath $StagingRoot) { Remove-Item -LiteralPath $StagingRoot -Recurse -Force }
    New-Item -ItemType Directory -Path $StagingRoot -Force | Out-Null
    Copy-Item -LiteralPath $SolutionFolder -Destination $StagingRoot -Recurse -Force
    $staged = Join-Path $StagingRoot (Split-Path -Leaf $SolutionFolder)

    $replaced = 0
    foreach ($file in (Get-ChildItem -LiteralPath $staged -Recurse -File)) {
        $text = Get-Content -LiteralPath $file.FullName -Raw
        $original = $text
        foreach ($key in $Token.Keys) { $text = $text.Replace($key, [string]$Token[$key]) }
        if ($text -ne $original) {
            Set-Content -LiteralPath $file.FullName -Value $text -NoNewline
            $replaced++
        }
    }
    return [pscustomobject]@{ Path = $staged; FilesChanged = $replaced }
}

function Invoke-PacCommand {
    <#
    .SYNOPSIS
        Run one pac command. Mutating calls are gated by ShouldProcess so -WhatIf prints
        the exact command line and runs nothing.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$Intent,
        [switch]$ReadOnly,
        [switch]$AllowFailure
    )
    $display = "pac $($Arguments -join ' ')"

    if (-not $ReadOnly -and -not $PSCmdlet.ShouldProcess($display, $Intent)) {
        return $null
    }

    Write-Status "  > $display" -Color DarkGray
    $output = & pac @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        if ($AllowFailure) {
            Write-Status "    ($Intent did not succeed; continuing.)" -Color Yellow
            return $null
        }
        $output | ForEach-Object { Write-Status "    $_" -Color Red }
        throw "$Intent failed: '$display' exited with code $LASTEXITCODE."
    }
    return $output
}

function Get-SolutionVersion {
    <# Read the four-part version out of an unpacked Other/Solution.xml, or $null. #>
    param([Parameter(Mandatory)][string]$SolutionXmlPath)
    try {
        return ([xml](Get-Content -LiteralPath $SolutionXmlPath -Raw)).ImportExportXml.SolutionManifest.Version
    }
    catch {
        Write-Status "  Could not parse a version out of $SolutionXmlPath ($($_.Exception.Message))." -Color Yellow
        return $null
    }
}

function Get-OnlineSolutionVersion {
    <#
    .SYNOPSIS
        Best-effort read of the solution version already installed in the target.
    .DESCRIPTION
        `pac solution online-version` returns human-readable text whose exact shape is
        not documented, so this scrapes a four-part version out of it and returns $null
        when it cannot. $null means "unknown", and the caller imports anyway - never the
        other way round. An absent solution is a normal first-run condition, not an
        error, hence -AllowFailure.
    #>
    param(
        [Parameter(Mandatory)][string]$SolutionName,
        [Parameter(Mandatory)][string]$EnvironmentUrl
    )
    $output = Invoke-PacCommand -ReadOnly -Intent "Read the online version of '$SolutionName'" -AllowFailure -Arguments @(
        'solution', 'online-version',
        '--environment', $EnvironmentUrl,
        '--solution-name', $SolutionName
    )
    if ($null -eq $output) { return $null }
    $match = [regex]::Match(($output | Out-String), '\b\d+\.\d+\.\d+\.\d+\b')
    if ($match.Success) { return $match.Value }
    return $null
}

function Write-PostImportChecklist {
    <#
    .SYNOPSIS
        The manual steps. None of these travel in a solution - all verified, not guessed.
    #>
    Write-Status ''
    Write-Status 'POST-IMPORT CHECKLIST (manual - none of this is solution-aware):' -Color Cyan
    Write-Status '  1. PUBLISH the agent in Copilot Studio. Nothing works until you do.'
    Write-Status '     (--publish-changes above published solution customizations, not the agent.)'
    Write-Status '  2. Reconfigure authentication: Settings -> Security -> Authentication ->'
    Write-Status '     Authenticate manually -> Microsoft Entra ID V2. Then publish again.'
    Write-Status '  3. Re-create the Fabric connection and re-attach the data agent under Agents.'
    Write-Status '  4. Create the MCP connection; confirm the tool list populates from the server.'
    Write-Status '  5. Re-enable generative orchestration (Settings -> Orchestration).'
    Write-Status '     Both the Fabric binding and MCP require it.'
    Write-Status '  6. Configure the Custom website channel + Web channel security; capture the'
    Write-Status '     Token Endpoint into COPILOT_TOKEN_ENDPOINT. Channel details import empty.'
    Write-Status '  7. Re-apply sharing, and grant demo users read on the Fabric data agent'
    Write-Status '     and lakehouse (the agent uses user authentication).'
    Write-Status '  8. Re-set the icon if it matters (propagation can take 24 h).'
    Write-Status ''
    Write-Status '  Full detail: infra/copilot-studio/README.md section 6.' -Color Cyan
}

function Invoke-Main {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$EnvironmentUrl,
        [Parameter(Mandatory)][string]$SolutionName,
        [Parameter(Mandatory)][string]$SolutionRoot,
        [Parameter(Mandatory)][string]$ArtifactPath,
        [string]$SettingsFile,
        [switch]$Unmanaged,
        [switch]$Force,
        [int]$MaxAsyncWaitMinutes = 60,
        [string]$McpHost
    )

    # ---- preflight: everything that can fail, fails here, before any write ----------
    $packageType = if ($Unmanaged) { 'Unmanaged' } else { 'Managed' }
    Write-Status "Importing solution '$SolutionName' ($packageType) into the demo environment." -Color Cyan
    Assert-PacCli
    Assert-PacAuthProfile
    $targetUrl = Resolve-EnvironmentUrl -Candidate $EnvironmentUrl
    Write-Status "Demo environment: $targetUrl" -Color Green

    $solutionFolder = Join-Path $SolutionRoot $SolutionName
    $solutionXml = Assert-SolutionSource -SolutionFolder $solutionFolder -SolutionName $SolutionName
    $localVersion = Get-SolutionVersion -SolutionXmlPath $solutionXml
    Write-Status "Committed source version: $(if ($localVersion) { $localVersion } else { '(unreadable)' })" -Color Green
    Assert-PackageTypeMatchesSource -SolutionXmlPath $solutionXml -PackageType $packageType

    $zipPath = Join-Path $ArtifactPath "$SolutionName`_$packageType.zip"

    # Settings file is optional; a missing one is a notice, never a failure.
    $resolvedSettings = $null
    if (-not [string]::IsNullOrWhiteSpace($SettingsFile)) {
        if (Test-Path -LiteralPath $SettingsFile) {
            $resolvedSettings = (Resolve-Path -LiteralPath $SettingsFile).Path
            Write-Status "Deployment settings: $resolvedSettings" -Color Green
        }
        else {
            Write-Status "Deployment settings file '$SettingsFile' does not exist - importing without one." -Color Yellow
        }
    }

    # ---- idempotency: skip a no-op import --------------------------------------------
    $onlineVersion = Get-OnlineSolutionVersion -SolutionName $SolutionName -EnvironmentUrl $targetUrl
    if ($onlineVersion) {
        Write-Status "Online version: $onlineVersion" -Color Green
        if ($localVersion -and $onlineVersion -eq $localVersion -and -not $Force) {
            Write-Status ''
            Write-Status "'$SolutionName' $onlineVersion is already installed - nothing to import." -Color Yellow
            Write-Status 'Use -Force to import anyway (for example after a portal edit you want overwritten).' -Color Yellow
            Write-PostImportChecklist
            return [pscustomobject]@{
                SolutionName  = $SolutionName
                Imported      = $false
                Reason        = 'already-current'
                LocalVersion  = $localVersion
                OnlineVersion = $onlineVersion
                PackageType   = $packageType
                WhatIfOnly    = [bool]$WhatIfPreference
            }
        }
    }
    else {
        Write-Status 'Online version unknown (first import, or unparseable output) - importing.' -Color Yellow
    }

    if ($WhatIfPreference) {
        Write-Status "(-WhatIf) The artifact directory $ArtifactPath would be created as needed." -Color Yellow
    }
    elseif (-not (Test-Path -LiteralPath $ArtifactPath)) {
        New-Item -ItemType Directory -Path $ArtifactPath -Force | Out-Null
    }

    # ---- resolve tokens into a staging copy (F129) ---------------------------------------
    # The repository keeps `${mcpHost}`; the PACKAGE gets the live FQDN. Resolved here, in
    # preflight, so a missing host fails before anything is written rather than importing a
    # connector that points at a hostname Azure retired on the last rebuild.
    $resolvedMcpHost = Resolve-McpHost -Candidate $McpHost
    Write-Status "MCP host for the connector: $resolvedMcpHost" -Color Green
    $staging = Get-TokenisedSolutionSource -SolutionFolder $solutionFolder `
        -StagingRoot (Join-Path $ArtifactPath 'staged-source') `
        -Token @{ '${mcpHost}' = $resolvedMcpHost }
    Write-Status "Resolved tokens in $($staging.FilesChanged) file(s); packing from the staging copy." -Color Green

    # ---- pack -------------------------------------------------------------------------
    Invoke-PacCommand -Intent "Pack '$SolutionName' as $packageType" -Arguments @(
        'solution', 'pack',
        '--zipfile', $zipPath,
        '--folder', $staging.Path,
        '--packagetype', $packageType
    ) | Out-Null

    # ---- import -----------------------------------------------------------------------
    # --force-overwrite + --stage-and-upgrade make the import convergent: an existing
    # solution is upgraded in place rather than colliding, and portal drift is overwritten.
    $importArgs = @(
        'solution', 'import',
        '--environment', $targetUrl,
        '--path', $zipPath,
        '--force-overwrite',
        '--publish-changes',
        '--stage-and-upgrade',
        '--async',
        '--max-async-wait-time', "$MaxAsyncWaitMinutes"
    )
    if ($resolvedSettings) { $importArgs += @('--settings-file', $resolvedSettings) }

    Invoke-PacCommand -Intent "Import '$SolutionName' into $targetUrl" -Arguments $importArgs | Out-Null

    # ---- report -----------------------------------------------------------------------
    Write-Status ''
    if ($WhatIfPreference) {
        Write-Status '(-WhatIf) Nothing ran. The demo environment was not contacted and no file changed.' -Color Yellow
    }
    else {
        Write-Status "Imported '$SolutionName' $(if ($localVersion) { $localVersion }) ($packageType) into $targetUrl." -Color Green
    }
    Write-PostImportChecklist

    return [pscustomobject]@{
        SolutionName  = $SolutionName
        Imported      = -not $WhatIfPreference
        Reason        = 'imported'
        LocalVersion  = $localVersion
        OnlineVersion = $onlineVersion
        PackageType   = $packageType
        ZipPath       = $zipPath
        SettingsFile  = $resolvedSettings
        WhatIfOnly    = [bool]$WhatIfPreference
    }
}

if (-not $env:MLS_SKIP_MAIN) {
    Invoke-Main -EnvironmentUrl $EnvironmentUrl -SolutionName $SolutionName `
        -SolutionRoot $SolutionRoot -ArtifactPath $ArtifactPath -SettingsFile $SettingsFile `
        -Unmanaged:$Unmanaged -Force:$Force -MaxAsyncWaitMinutes $MaxAsyncWaitMinutes `
        -McpHost $McpHost
}
