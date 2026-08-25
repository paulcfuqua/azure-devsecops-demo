#Requires -Version 7.0
<#
.SYNOPSIS
    One entry point for the whole data plane: generate the dataset, seed Azure SQL (L6),
    seed the Fabric lakehouse (L5).

.DESCRIPTION
    Three steps, in this order, any of which may already be done:

      1. GENERATE  `python -m generators build` from data/, seed 20260822 - but only when
                   data/generated/ is missing or incomplete. The seed, not the artifacts,
                   is the source of truth; data/generated/ is gitignored and disposable.
      2. SQL       apply data/seed/sql/*.sql in filename order, then load the ten tables
                   into the Azure SQL serverless operational database.
      3. LAKEHOUSE upload the ten CSVs into OneLake and load them as Delta tables in
                   `mls_operations` over the Fabric REST API.

    -Target picks which of 2 and 3 run. Step 1 runs for either.

    IDEMPOTENT. A second run against a seeded estate issues reads and nothing else:
    the SQL half short-circuits when every table already holds its expected row count,
    the lakehouse half when every Delta table already exists. -Force overrides both
    (wipe-and-reseed, the L5 playbook's standard remediation).

    -WhatIf makes no mutating call anywhere - no generator run, no INSERT, no OneLake
    upload, no table load. Prerequisites are still checked, because they are local.

    FAILS FAST. Every prerequisite is checked before the first write, and each failure
    names the thing to fix. A half-seeded database or a lakehouse with four of ten
    tables is far more expensive than a run that refuses to start: row counts are
    contract at L5 V5.3 (launches = 1,200 +/- 0), and partial state has to be wiped
    before it can be fixed.

.PARAMETER Target
    sql | lakehouse | both (default both).

.PARAMETER SqlServerInstance
    Azure SQL logical server FQDN, e.g. mls-ops-demo-sql.database.windows.net. Comes
    from the L6 deployment outputs; never hardcoded.

.PARAMETER SqlAccessToken
    Entra access token for https://database.windows.net (OIDC-derived in CI).

.PARAMETER Token
    Bearer token for https://api.fabric.microsoft.com - the Fabric CONTROL plane.

.PARAMETER OneLakeToken
    Bearer token for https://storage.azure.com - the OneLake DATA plane. A different
    audience from -Token; see data/seed/lakehouse/README.md.

.EXAMPLE
    ./seed.ps1 -Target both -WhatIf

.EXAMPLE
    $fabric  = az account get-access-token --resource https://api.fabric.microsoft.com --query accessToken -o tsv
    $onelake = az account get-access-token --resource https://storage.azure.com --query accessToken -o tsv
    ./seed.ps1 -Target lakehouse -Token $fabric -OneLakeToken $onelake -Confirm:$false

.EXAMPLE
    $sql = az account get-access-token --resource https://database.windows.net --query accessToken -o tsv
    ./seed.ps1 -Target sql -SqlServerInstance mls-ops-demo-sql.database.windows.net `
        -SqlDatabase mls-ops-demo-db -SqlAccessToken $sql -Confirm:$false

.NOTES
    Gate: L5/L6 run only after G1 approval + layer unblock. This script changes no
    capacity state (it neither resumes nor pauses) and creates no Fabric or Azure
    resource - the workspace, the lakehouse and the SQL database must already exist.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('sql', 'lakehouse', 'both')]
    [string]$Target = 'both',

    # ---- Azure SQL (L6) -----------------------------------------------------------
    [string]$SqlServerInstance = '',
    [string]$SqlDatabase = '',
    [string]$SqlAccessToken = '',

    # ---- Fabric (L5) --------------------------------------------------------------
    [string]$Token = '',
    [string]$OneLakeToken = '',
    [string]$WorkspaceName = 'mls-operations',
    [ValidatePattern('^[A-Za-z][A-Za-z0-9_]*$')]
    [string]$LakehouseName = 'mls_operations',

    # ---- data ---------------------------------------------------------------------
    # Defaults to data/generated/, resolved from this script rather than the cwd.
    [string]$GeneratedDataPath = '',
    [string]$PythonExecutable = 'python',
    # Do not run the generators even when data/generated/ is incomplete. For an air-gapped
    # replay where the dataset was staged by another step.
    [switch]$SkipGenerate,

    # Wipe and reload even when the estate already reports the expected state.
    [switch]$Force,

    [int]$SqlBatchSize = 250,
    [int]$TimeoutSeconds = 900
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Status {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
        Justification = 'Operator-facing seeding script; console progress output is the deliverable, and a stream a caller could redirect away would hide a half-finished load.')]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Message,
        [ConsoleColor]$Color = [ConsoleColor]::Gray
    )
    Write-Host $Message -ForegroundColor $Color
}

function Invoke-GeneratorProcess {
    <#
    .SYNOPSIS
        Single choke point for the `python -m generators build` subprocess (mocked in
        tests). Returns the process exit code.
    .DESCRIPTION
        The generators are a package, so they must be invoked as `-m generators` with
        data/ as the working directory - `python generators/build.py` would fail on the
        relative imports. data/generators/ is Track A's and is never modified here.
    #>
    param(
        [Parameter(Mandatory)][string]$DataRoot,
        [Parameter(Mandatory)][string]$PythonExecutable
    )
    Push-Location -LiteralPath $DataRoot
    try {
        & $PythonExecutable -m generators build 2>&1 | ForEach-Object { Write-Status "  $_" -Color DarkGray }
        return $LASTEXITCODE
    }
    finally {
        Pop-Location
    }
}

function Invoke-GeneratorBuild {
    <#
    .SYNOPSIS
        Build the deterministic dataset when it is absent or incomplete.
    .DESCRIPTION
        "Incomplete" means any of the twenty expected files (10 tables x CSV + JSON) is
        missing. A partial data/generated/ is treated as absent rather than patched: the
        generator is deterministic, so rebuilding all of it is both cheap and the only
        way to be sure the twenty files agree with each other.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$DataRoot,
        [Parameter(Mandatory)][string]$DataPath,
        [Parameter(Mandatory)][string]$PythonExecutable,
        [Parameter(Mandatory)]$Manifest,
        [switch]$SkipGenerate
    )
    if (Test-GeneratedDataComplete -Manifest $Manifest -DataPath $DataPath) {
        Write-Status "Dataset present at $DataPath - skipping generation." -Color Green
        return $false
    }
    if ($SkipGenerate) {
        throw "The generated dataset at '$DataPath' is missing or incomplete and -SkipGenerate was set. Either drop -SkipGenerate or stage the dataset first: ``python -m generators build`` from '$DataRoot'."
    }
    if (-not (Test-Path -LiteralPath (Join-Path -Path $DataRoot -ChildPath 'generators'))) {
        throw "Cannot find the generators package at '$(Join-Path -Path $DataRoot -ChildPath 'generators')'. data/seed/seed.ps1 must run from a full checkout of the repository."
    }
    if (-not (Get-Command -Name $PythonExecutable -ErrorAction SilentlyContinue)) {
        throw "'$PythonExecutable' is not on PATH, so the dataset cannot be generated. Install Python 3.14 (the version layer-05-fabric.yml pins), pass -PythonExecutable <path>, or stage data/generated/ yourself and re-run with -SkipGenerate."
    }
    if (-not $PSCmdlet.ShouldProcess($DataPath, "Run `"$PythonExecutable -m generators build`" in $DataRoot (seed 20260822)")) {
        Write-Status "(-WhatIf) Would generate the dataset into $DataPath before seeding." -Color Yellow
        return $false
    }

    Write-Status "Generating the dataset (seed 20260822) into $DataPath ..." -Color Cyan
    $exitCode = Invoke-GeneratorProcess -DataRoot $DataRoot -PythonExecutable $PythonExecutable
    if ($exitCode -ne 0) {
        throw "``$PythonExecutable -m generators build`` failed with exit code $exitCode. Nothing was seeded."
    }
    if (-not (Test-GeneratedDataComplete -Manifest $Manifest -DataPath $DataPath)) {
        throw "The generator reported success but '$DataPath' is still missing files for one or more of the ten tables. Refusing to seed from an incomplete dataset."
    }
    Write-Status 'Dataset generated.' -Color Green
    return $true
}

function Invoke-Main {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][ValidateSet('sql', 'lakehouse', 'both')][string]$Target,
        [Parameter(Mandatory)][string]$SeedRoot,
        [AllowEmptyString()][string]$SqlServerInstance = '',
        [AllowEmptyString()][string]$SqlDatabase = '',
        [AllowEmptyString()][string]$SqlAccessToken = '',
        [AllowEmptyString()][string]$Token = '',
        [AllowEmptyString()][string]$OneLakeToken = '',
        [string]$WorkspaceName = 'mls-operations',
        [string]$LakehouseName = 'mls_operations',
        [AllowEmptyString()][string]$GeneratedDataPath = '',
        [string]$PythonExecutable = 'python',
        [switch]$SkipGenerate,
        [switch]$Force,
        [int]$SqlBatchSize = 250,
        [int]$TimeoutSeconds = 900
    )
    $dataRoot = Join-Path -Path $SeedRoot -ChildPath '..'
    $dataPath = Get-GeneratedDataPath -Path $GeneratedDataPath
    $manifest = Get-SeedManifest -Path (Get-SeedManifestPath -SeedRoot $SeedRoot)
    $tableCount = @(Get-MapValue -InputObject $manifest -Name 'load_order').Count

    Write-Status ''
    Write-Status "MLS data-plane seed - target '$Target', $tableCount tables, generator seed $(Get-MapValue -InputObject $manifest -Name 'generator_seed')." -Color Cyan

    # ---- 1. dataset -----------------------------------------------------------------
    $generated = Invoke-GeneratorBuild -DataRoot $dataRoot -DataPath $dataPath `
        -PythonExecutable $PythonExecutable -Manifest $manifest -SkipGenerate:$SkipGenerate `
        -WhatIf:$WhatIfPreference

    $result = [pscustomobject]@{
        Target    = $Target
        Generated = $generated
        Sql       = $null
        Lakehouse = $null
    }

    # ---- 2. Azure SQL (L6 operational plane) -----------------------------------------
    if ($Target -in @('sql', 'both')) {
        Write-Status ''
        Write-Status '=== Azure SQL (operational plane) ===' -Color White
        $connection = New-SqlConnectionDescriptor -ServerInstance $SqlServerInstance `
            -Database $SqlDatabase -AccessToken $SqlAccessToken
        $result.Sql = Invoke-SqlSeed -Connection $connection -Manifest $manifest -DataPath $dataPath `
            -DdlPath (Join-Path -Path $SeedRoot -ChildPath 'sql') -BatchSize $SqlBatchSize `
            -TimeoutSeconds $TimeoutSeconds -Force:$Force -WhatIf:$WhatIfPreference -Confirm:$false
    }

    # ---- 3. Fabric lakehouse (L5 analytical plane) ------------------------------------
    if ($Target -in @('lakehouse', 'both')) {
        Write-Status ''
        Write-Status '=== Fabric lakehouse (analytical plane) ===' -Color White
        $result.Lakehouse = Invoke-LakehouseSeed -Token $Token -OneLakeToken $OneLakeToken `
            -Manifest $manifest -DataPath $dataPath -WorkspaceName $WorkspaceName `
            -LakehouseName $LakehouseName -TimeoutSeconds $TimeoutSeconds -Force:$Force `
            -WhatIf:$WhatIfPreference -Confirm:$false
    }

    Write-Status ''
    if ($WhatIfPreference) {
        Write-Status '(-WhatIf) Nothing was written. Re-run without -WhatIf to seed.' -Color Yellow
    }
    else {
        Write-Status "Seed complete (target '$Target')." -Color Green
    }
    return $result
}

if (-not $env:MLS_SKIP_MAIN) {
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'seed-common.psm1') -Force
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'sql' -AdditionalChildPath 'sql-seed.psm1') -Force
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'lakehouse' -AdditionalChildPath 'lakehouse-seed.psm1') -Force

    Invoke-Main -Target $Target -SeedRoot $PSScriptRoot `
        -SqlServerInstance $SqlServerInstance -SqlDatabase $SqlDatabase -SqlAccessToken $SqlAccessToken `
        -Token $Token -OneLakeToken $OneLakeToken -WorkspaceName $WorkspaceName -LakehouseName $LakehouseName `
        -GeneratedDataPath $GeneratedDataPath -PythonExecutable $PythonExecutable `
        -SkipGenerate:$SkipGenerate -Force:$Force -SqlBatchSize $SqlBatchSize -TimeoutSeconds $TimeoutSeconds
}
