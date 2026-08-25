#Requires -Version 7.0
<#
.SYNOPSIS
    L8 - export the Meridian Launch Copilot from the AUTHORING Power Platform
    environment and unpack it into infra/copilot-studio/solution/ as reviewable source.

.DESCRIPTION
    The repo-ward half of the round trip (see README section 5). A human authors in the
    Copilot Studio portal; this script captures that state so it can be reviewed in a
    pull request and replayed into the demo environment by
    .github/workflows/layer-08-copilot-studio.yml.

    Wraps the Power Platform CLI (`pac`). It never authenticates by itself: an auth
    profile must already exist, created by `pac auth create` (in CI, after
    azure/login@v2, with --managedIdentity; locally, however you normally sign in).

    IDEMPOTENT. Re-running converges: the zip is re-exported with --overwrite and the
    source folder is re-unpacked with --clobber --allowDelete --allowWrite, so
    solution/ always reflects exactly what the authoring environment currently holds.
    Components deleted in the portal disappear from the tree instead of lingering.

    FAILS BEFORE IT ACTS. Every precondition - pac present, an auth profile, a
    resolvable environment - is checked up front, and each failure prints what to do
    about it. Nothing mutating runs until all of them pass, so the script cannot leave
    a half-exported tree behind.

.NOTES
    ALWAYS DO THIS FIRST, IN THE PORTAL:
        agent -> ... -> Advanced -> Add required objects

    Microsoft: "The imported solution reflects the agent's state only at the time that
    you originally exported it." Topics, tools, connectors, child agents and MCP servers
    added since the first export do NOT flow to the target unless dependencies are
    pulled into the solution first. Skipping this yields a green pipeline that deploys a
    silently incomplete agent. The script reprints this reminder on every run.

    Authored only - this has never been run against a real environment.

.EXAMPLE
    ./export-agent.ps1 -WhatIf
    # Prints every pac command it would run. Contacts nothing.

.EXAMPLE
    ./export-agent.ps1 -EnvironmentUrl https://contoso-authoring.crm.dynamics.com
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    # Authoring environment URL. Defaults to the POWERPLATFORM_AUTHORING_URL variable
    # from the GitHub `demo` environment; never committed (CLAUDE.md hard rule 5).
    [string]$EnvironmentUrl = $env:POWERPLATFORM_AUTHORING_URL,

    # Solution unique name, per agent-definition.md section 1.
    [string]$SolutionName = 'MeridianLaunchCopilot',

    # Where the unpacked source tree is written.
    [string]$SolutionRoot = (Join-Path $PSScriptRoot 'solution'),

    # Where the intermediate .zip is written. Deliberately NOT under solution/ - the zip
    # is a build artifact and is never committed (README section 4).
    [string]$ArtifactPath = (Join-Path ([IO.Path]::GetTempPath()) 'mls-copilot-studio'),

    # Emit the deployment-settings template alongside the source.
    [switch]$SkipSettingsTemplate,

    # Minutes pac waits on the asynchronous export before giving up.
    [ValidateRange(1, 240)]
    [int]$MaxAsyncWaitMinutes = 60
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Status {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
        Justification = 'Interactive operations script; console output is the product.')]
    param(
        [Parameter(Mandatory)][string]$Message,
        [ConsoleColor]$Color = [ConsoleColor]::Gray
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
The Power Platform CLI (`pac`) is not on PATH, so nothing can be exported.

Install one of these, then re-run:
  * GitHub Actions : add a step `uses: microsoft/powerplatform-actions/actions-install@v1`
                     before this script (it puts pac on PATH for the job).
  * .NET tool      : dotnet tool install --global Microsoft.PowerApps.CLI.Tool
  * Windows        : winget install Microsoft.PowerAppsCLI
  * VS Code        : the Power Platform Tools extension ships pac.

Nothing was exported and no files were touched.
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
export from. `pac auth list` said:

$($text.Trim())

Create one first:
  * GitHub Actions (no secret) : run azure/login@v2 with OIDC, then
        pac auth create --environment "<url>" --name mls-l8 --managedIdentity
  * Service principal          : pac auth create --applicationId <id> --clientSecret <secret> --tenant <tenant>
  * Interactive                : pac auth create --environment "<url>"

Nothing was exported and no files were touched.
"@
}

function Resolve-EnvironmentUrl {
    <#
    .SYNOPSIS
        Resolve the authoring environment URL, or fail with the exact variable to set.
    #>
    param([string]$Candidate)
    if (-not [string]::IsNullOrWhiteSpace($Candidate)) { return $Candidate.Trim() }
    throw @'
No authoring environment was supplied, so this script does not know what to export.

Set one of:
  * -EnvironmentUrl https://<org>.crm.dynamics.com
  * the POWERPLATFORM_AUTHORING_URL environment variable (GitHub `demo` environment
    variable; see infra/copilot-studio/README.md section 2).

`pac env list` shows the environments the current profile can reach.
Nothing was exported and no files were touched.
'@
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
        [switch]$ReadOnly
    )
    $display = "pac $($Arguments -join ' ')"

    if (-not $ReadOnly -and -not $PSCmdlet.ShouldProcess($display, $Intent)) {
        return $null
    }

    Write-Status "  > $display" -Color DarkGray
    $output = & pac @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        $output | ForEach-Object { Write-Status "    $_" -Color Red }
        throw "$Intent failed: '$display' exited with code $LASTEXITCODE."
    }
    return $output
}

function Get-SolutionVersion {
    <# Read the four-part version out of an unpacked Other/Solution.xml, or $null. #>
    param([Parameter(Mandatory)][string]$SolutionXmlPath)
    if (-not (Test-Path -LiteralPath $SolutionXmlPath)) { return $null }
    try {
        return ([xml](Get-Content -LiteralPath $SolutionXmlPath -Raw)).ImportExportXml.SolutionManifest.Version
    }
    catch {
        Write-Status "  Could not parse a version out of $SolutionXmlPath ($($_.Exception.Message))." -Color Yellow
        return $null
    }
}

function Write-AddRequiredObjectsReminder {
    Write-Status ''
    Write-Status '  !! BEFORE EXPORTING, in the authoring portal:' -Color Yellow
    Write-Status '     agent -> ... -> Advanced -> Add required objects' -Color Yellow
    Write-Status '     Components added since the last export do NOT travel without it,' -Color Yellow
    Write-Status '     and the pipeline will stay green while deploying an incomplete agent.' -Color Yellow
    Write-Status ''
}

function Invoke-Main {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$EnvironmentUrl,
        [Parameter(Mandatory)][string]$SolutionName,
        [Parameter(Mandatory)][string]$SolutionRoot,
        [Parameter(Mandatory)][string]$ArtifactPath,
        [switch]$SkipSettingsTemplate,
        [int]$MaxAsyncWaitMinutes = 60
    )

    # ---- preflight: everything that can fail, fails here, before any write ----------
    Write-Status "Exporting solution '$SolutionName' from the authoring environment." -Color Cyan
    Assert-PacCli
    Assert-PacAuthProfile
    $targetUrl = Resolve-EnvironmentUrl -Candidate $EnvironmentUrl
    Write-Status "Authoring environment: $targetUrl" -Color Green

    Write-AddRequiredObjectsReminder

    $solutionFolder = Join-Path $SolutionRoot $SolutionName
    $zipPath = Join-Path $ArtifactPath "$SolutionName.zip"
    $settingsPath = Join-Path $SolutionRoot "$SolutionName.settings.json"
    $solutionXml = Join-Path $solutionFolder 'Other' 'Solution.xml'
    $versionBefore = Get-SolutionVersion -SolutionXmlPath $solutionXml

    if ($WhatIfPreference) {
        Write-Status '(-WhatIf) Directories would be created as needed:' -Color Yellow
        Write-Status "    zip    : $zipPath" -Color Yellow
        Write-Status "    source : $solutionFolder" -Color Yellow
    }
    else {
        foreach ($directory in @($ArtifactPath, $SolutionRoot)) {
            if (-not (Test-Path -LiteralPath $directory)) {
                New-Item -ItemType Directory -Path $directory -Force | Out-Null
            }
        }
    }

    # ---- export ---------------------------------------------------------------------
    # Unmanaged: a managed solution cannot be exported, so the repo holds the unmanaged
    # source and the import job packs a managed build from it (README section 4).
    Invoke-PacCommand -Intent "Export '$SolutionName' from $targetUrl" -Arguments @(
        'solution', 'export',
        '--environment', $targetUrl,
        '--name', $SolutionName,
        '--path', $zipPath,
        '--overwrite',
        '--async',
        '--max-async-wait-time', "$MaxAsyncWaitMinutes"
    ) | Out-Null

    # ---- unpack ---------------------------------------------------------------------
    # --clobber --allowDelete --allowWrite is what makes this converge rather than
    # accumulate: portal deletions become deletions in the tree.
    Invoke-PacCommand -Intent "Unpack '$SolutionName' into $solutionFolder" -Arguments @(
        'solution', 'unpack',
        '--zipfile', $zipPath,
        '--folder', $solutionFolder,
        '--packagetype', 'Unmanaged',
        '--allowDelete',
        '--allowWrite',
        '--clobber'
    ) | Out-Null

    # ---- deployment-settings template ------------------------------------------------
    if ($SkipSettingsTemplate) {
        Write-Status 'Skipping the deployment-settings template (-SkipSettingsTemplate).' -Color Yellow
    }
    else {
        Invoke-PacCommand -Intent "Generate the deployment-settings template for '$SolutionName'" -Arguments @(
            'solution', 'create-settings',
            '--solution-zip', $zipPath,
            '--settings-file', $settingsPath
        ) | Out-Null
    }

    # ---- report ----------------------------------------------------------------------
    $versionAfter = Get-SolutionVersion -SolutionXmlPath $solutionXml
    Write-Status ''
    if ($WhatIfPreference) {
        Write-Status '(-WhatIf) Nothing ran. No environment was contacted and no file changed.' -Color Yellow
    }
    else {
        Write-Status "Exported '$SolutionName' to $solutionFolder." -Color Green
        if ($versionBefore -and $versionAfter -and $versionBefore -eq $versionAfter) {
            Write-Status "  Solution version unchanged at $versionAfter - re-exporting the same build." -Color Yellow
        }
        elseif ($versionAfter) {
            Write-Status "  Solution version: $versionAfter$(if ($versionBefore) { " (was $versionBefore)" })." -Color Green
        }
    }
    Write-Status ''
    Write-Status 'Next:' -Color Cyan
    Write-Status '  1. Review the diff under solution/. It should contain only what you changed'
    Write-Status '     in agent-definition.md. Anything else is drift - investigate it.'
    Write-Status '  2. Update agent-definition.md if the specification itself moved.'
    Write-Status '  3. Open a PR. Merging to main is what deploys, via layer-08-copilot-studio.yml.'
    Write-Status "  4. The .zip at $zipPath is a build artifact - do not commit it."

    return [pscustomobject]@{
        SolutionName    = $SolutionName
        EnvironmentUrl  = $targetUrl
        SolutionFolder  = $solutionFolder
        ZipPath         = $zipPath
        SettingsPath    = if ($SkipSettingsTemplate) { $null } else { $settingsPath }
        VersionBefore   = $versionBefore
        VersionAfter    = $versionAfter
        WhatIfOnly      = [bool]$WhatIfPreference
    }
}

if (-not $env:MLS_SKIP_MAIN) {
    Invoke-Main -EnvironmentUrl $EnvironmentUrl -SolutionName $SolutionName `
        -SolutionRoot $SolutionRoot -ArtifactPath $ArtifactPath `
        -SkipSettingsTemplate:$SkipSettingsTemplate -MaxAsyncWaitMinutes $MaxAsyncWaitMinutes
}
