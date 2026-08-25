#Requires -Version 7.0
<#
.SYNOPSIS
    Fabric half of the L5 seed: create and load the ten Delta tables in the
    `mls_operations` lakehouse over REST, as a service principal, with no portal step.

.DESCRIPTION
    MECHANISM (researched against learn.microsoft.com, not assumed - full citations and
    the rejected alternatives are in data/seed/lakehouse/README.md):

      1. Upload  each generated <table>.csv into the lakehouse's OneLake Files area with
                 the ADLS Gen2 (DFS) API:
                   PUT   https://onelake.dfs.fabric.microsoft.com/{ws}/{lh}/Files/{path}?resource=file
                   PATCH .../Files/{path}?action=append&position=0&flush=true
                 https://learn.microsoft.com/en-us/fabric/onelake/onelake-access-api
                 https://learn.microsoft.com/en-us/rest/api/storageservices/datalakestoragegen2/path/create
                 https://learn.microsoft.com/en-us/rest/api/storageservices/datalakestoragegen2/path/update

      2. Load    each uploaded file into a Delta table with the Fabric Load Table API:
                   POST /v1/workspaces/{ws}/lakehouses/{lh}/tables/{table}/load
                   { relativePath, pathType: File, mode: Overwrite, recursive: false,
                     formatOptions: { format: Csv, header: true, delimiter: "," } }
                 https://learn.microsoft.com/en-us/rest/api/fabric/lakehouse/tables/load-table
                 Answers 202 + Location / x-ms-operation-id / Retry-After; polled per
                 https://learn.microsoft.com/en-us/rest/api/fabric/articles/long-running-operation

    There is deliberately NO separate "create table" step: no Fabric REST operation
    writes a Delta table directly, and Load Table in Overwrite mode creates the table
    when it is absent. Creation and load are the same call.

    TWO TOKENS, TWO AUDIENCES. This is the detail that breaks a first attempt:
      * Fabric control plane -> https://api.fabric.microsoft.com/.default
      * OneLake DFS          -> https://storage.azure.com/.default
        "Use the OneLake resource scope https://storage.azure.com/.default when
         requesting the token."
        https://learn.microsoft.com/en-us/fabric/onelake/security/onelake-security-integrations-external-engines
    Passing the Fabric token to OneLake returns 401 with a bearer challenge, not a
    helpful error, so the token is checked before the first upload.

    ROW-COUNT FIDELITY (L5 V5.3, launches = 1,200 +/- 0):
      * header:true is set explicitly - with header:false Fabric names the columns _c0,
        _c1, ... and the header row becomes a data row (+1 per table);
      * mode Overwrite, never Append - Append has no merge or de-duplicate semantics, so
        a re-run would double every table;
      * pathType File with recursive:false against a per-table folder - a folder load
        would pick up anything else that ever lands beside it;
      * the table list is read back after the load and compared to the manifest.

    Every REST call goes through one of two choke points - Invoke-FabricApi (from
    infra/fabric/fabric-api.psm1, the repo's existing Fabric convention) for the control
    plane, and Invoke-SeedWebRequest for raw absolute URLs (OneLake, and the LRO
    Location the load returns). Both are mocked wholesale in the Pester suite; there is
    no third path to the network.

.NOTES
    PREVIEW: "This API is part of a Preview release and is provided for evaluation and
    development purposes only." - Load Table, at the URL above. Accepted with eyes open;
    the notebook fallback is documented in the README for the day it changes.

    PERMISSIONS the script cannot bootstrap for itself: the SP needs the workspace
    CONTRIBUTOR role and the tenant toggle "Service principals can use Fabric APIs"
    (G0 item C4). Both are asserted by scripts/bootstrap/verify-g0.ps1.
#>

Set-StrictMode -Version Latest

# No -Force on either dependency import. -Force removes and re-imports the module, and
# the re-import lands in THIS module's scope - so a caller that had already imported
# seed-common or fabric-api for itself silently loses every command it exported.
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'seed-common.psm1')
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath '..', '..', 'infra', 'fabric', 'fabric-api.psm1')

$script:OneLakeDfsEndpoint = 'https://onelake.dfs.fabric.microsoft.com'
# ADLS Gen2 returns a bearer challenge instead of data when x-ms-version is older than
# 2017-11-09; pinned rather than floating so a service-side default change is visible.
$script:OneLakeApiVersion = '2023-08-03'
# Load Table's own constraint, quoted from the REST reference.
$script:LakehouseTableNamePattern = '^(?=[0-9]*[a-zA-Z_])[a-zA-Z0-9_]{1,256}$'

function Get-SeedHeaderValue {
    <#
    .SYNOPSIS
        First value of a response header, case-insensitively.
    .DESCRIPTION
        Invoke-WebRequest returns headers as string[] per key, and header names are
        case-insensitive on the wire - so neither the casing nor the arity can be assumed.
    #>
    param($Headers, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Headers) { return $null }
    foreach ($key in $Headers.Keys) {
        if ($key -ieq $Name) {
            $value = $Headers[$key]
            if ($value -is [array]) { return $value[0] }
            return $value
        }
    }
    return $null
}

function Invoke-SeedWebRequest {
    <#
    .SYNOPSIS
        Single choke point for raw absolute-URL HTTP (OneLake DFS + LRO polling).
    .DESCRIPTION
        Kept separate from Invoke-FabricApi on purpose: that wrapper is bound to
        https://api.fabric.microsoft.com/v1 and to the Fabric token, and neither applies
        to OneLake (different host, different audience) or to a Location header that must
        be followed verbatim rather than reconstructed.
    #>
    param(
        [Parameter(Mandatory)][ValidateSet('GET', 'PUT', 'PATCH', 'POST', 'DELETE')][string]$Method,
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$Token,
        [hashtable]$Header = @{},
        [string]$InFile = '',
        [string]$ContentType = ''
    )
    $headers = @{ Authorization = "Bearer $Token" }
    foreach ($key in $Header.Keys) { $headers[$key] = $Header[$key] }

    $arguments = @{
        Method      = $Method
        Uri         = $Uri
        Headers     = $headers
        ErrorAction = 'Stop'
    }
    if (-not [string]::IsNullOrWhiteSpace($InFile)) { $arguments['InFile'] = $InFile }
    if (-not [string]::IsNullOrWhiteSpace($ContentType)) { $arguments['ContentType'] = $ContentType }

    $response = Invoke-WebRequest @arguments
    $content = $null
    $raw = Get-MapValue -InputObject $response -Name 'Content'
    if ($raw -is [byte[]]) { $raw = [Text.Encoding]::UTF8.GetString($raw) }
    if (-not [string]::IsNullOrWhiteSpace("$raw")) {
        try { $content = "$raw" | ConvertFrom-Json } catch { $content = "$raw" }
    }
    return [pscustomobject]@{
        StatusCode = (Get-MapValue -InputObject $response -Name 'StatusCode')
        Headers    = (Get-MapValue -InputObject $response -Name 'Headers')
        Content    = $content
    }
}

function Get-OneLakeFileUri {
    <#
    .SYNOPSIS
        Absolute OneLake DFS URI for a path under a lakehouse's Files area. Pure.
    .DESCRIPTION
        GUID form (workspaceId/lakehouseId) rather than
        <workspace name>/<lakehouse>.Lakehouse: both are documented, and the GUID form
        needs no name escaping and no item-type suffix, so a workspace rename cannot
        break a running seed.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pure builder: returns a URI string and changes no state anywhere.')]
    param(
        [Parameter(Mandatory)][string]$WorkspaceId,
        [Parameter(Mandatory)][string]$LakehouseId,
        [Parameter(Mandatory)][string]$RelativePath
    )
    $trimmed = $RelativePath.Trim('/')
    if (-not $trimmed.StartsWith('Files/')) {
        throw "OneLake seed paths must live under 'Files/' (got '$RelativePath'). The Load Table API also requires relativePath to start with Files."
    }
    return "$($script:OneLakeDfsEndpoint)/$WorkspaceId/$LakehouseId/$trimmed"
}

function Get-SeedStagingPath {
    <#
    .SYNOPSIS
        Per-table staging path under Files/ - one file per folder.
    .DESCRIPTION
        The one-file-per-folder layout is what makes a folder-scoped load unable to sweep
        up anything that lands beside the seed. See the module header.
    .OUTPUTS
        System.String
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pure builder: returns a relative path string and changes no state anywhere.')]
    param(
        [Parameter(Mandatory)][string]$TableName,
        [string]$Root = 'Files/seed'
    )
    return "$Root/$TableName/$TableName.csv"
}

function Assert-LakehouseTableName {
    <#
    .SYNOPSIS
        Load Table's documented name pattern, checked before the call rather than after.
    .DESCRIPTION
        The REST reference pins tableName to ^(?=[0-9]*[a-zA-Z_])[a-zA-Z0-9_]{1,256}$.
        Checking locally turns a server-side 400 halfway through the seed into an
        immediate, named failure.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Name)
    if ($Name -notmatch $script:LakehouseTableNamePattern) {
        throw "'$Name' is not a valid Fabric lakehouse table name. The Load Table API requires $($script:LakehouseTableNamePattern)."
    }
    return $Name
}

function Send-OneLakeFile {
    <#
    .SYNOPSIS
        Upload one local file into the lakehouse's OneLake Files area.
    .DESCRIPTION
        ADLS Gen2 create + append, with flush folded into the append rather than sent as
        a third call: "flush ... allows the caller to flush during an append call.
        Default value is 'false', if 'true' the data will be flushed with the append
        call."
        https://learn.microsoft.com/en-us/rest/api/storageservices/datalakestoragegen2/path/update
        That page also lists six x-ms-content-* headers as unsupported alongside
        flush=true; none of them is sent here, and the ordinary Content-Type that
        -InFile implies is not one of them.

        The create call carries no body on purpose - Path/Create answers
        400 ContentLengthMustBeZero otherwise, so `?resource=file` is how an empty file
        is made before anything is appended to it.

        The seed's largest file is well under a megabyte, so a single append is enough
        and no chunking is needed; if that ever changes this is the function that grows
        a position loop.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$OneLakeToken,
        [Parameter(Mandatory)][string]$WorkspaceId,
        [Parameter(Mandatory)][string]$LakehouseId,
        [Parameter(Mandatory)][string]$RelativePath,
        [Parameter(Mandatory)][string]$LocalPath
    )
    if (-not (Test-Path -LiteralPath $LocalPath)) {
        throw "Cannot upload '$LocalPath' to OneLake: the file does not exist. Run ``python -m generators build`` from the repo's data/ directory."
    }
    $uri = Get-OneLakeFileUri -WorkspaceId $WorkspaceId -LakehouseId $LakehouseId -RelativePath $RelativePath
    $length = (Get-Item -LiteralPath $LocalPath).Length
    if (-not $PSCmdlet.ShouldProcess($RelativePath, "Upload $length byte(s) to OneLake")) { return $null }

    $version = @{ 'x-ms-version' = $script:OneLakeApiVersion }
    Invoke-SeedWebRequest -Method PUT -Uri "$($uri)?resource=file" -Token $OneLakeToken -Header $version | Out-Null
    Invoke-SeedWebRequest -Method PATCH -Uri "$($uri)?action=append&position=0&flush=true" `
        -Token $OneLakeToken -Header $version -InFile $LocalPath -ContentType 'application/octet-stream' | Out-Null

    return [pscustomobject]@{ RelativePath = $RelativePath; Bytes = $length }
}

function ConvertTo-OperationStatus {
    <#
    .SYNOPSIS
        Normalise the two documented status shapes to one string.
    .DESCRIPTION
        The generic LRO reference returns a string status (NotStarted / Running /
        Succeeded / Failed); the lakehouse-scoped operations endpoint documents a numeric
        Status (1 not started, 2 running, 3 success, 4 failed). Load Table's own Location
        header can point at either, so both are handled rather than guessed at.
    #>
    param($Operation)
    if ($null -eq $Operation) { return 'Unknown' }
    foreach ($name in @('status', 'Status')) {
        $value = Get-MapValue -InputObject $Operation -Name $name
        if ($null -eq $value) { continue }
        if ($value -is [string]) { return $value }
        switch ([int]$value) {
            1 { return 'NotStarted' }
            2 { return 'Running' }
            3 { return 'Succeeded' }
            4 { return 'Failed' }
            default { return "Unknown($value)" }
        }
    }
    return 'Unknown'
}

function Wait-LakehouseLoadOperation {
    <#
    .SYNOPSIS
        Poll a load's long-running operation to completion.
    .DESCRIPTION
        Follows the Location header verbatim. The REST reference and the lakehouse
        how-to document different polling URLs for this same operation, so constructing
        one from the operation id would be a coin flip; the header is authoritative.
    #>
    param(
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$OperationUri,
        [int]$PollIntervalSeconds = 5,
        [int]$TimeoutSeconds = 900
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ($true) {
        $response = Invoke-SeedWebRequest -Method GET -Uri $OperationUri -Token $Token
        $operation = Get-MapValue -InputObject $response -Name 'Content'
        $status = ConvertTo-OperationStatus -Operation $operation
        if ($status -eq 'Succeeded') { return $operation }
        if ($status -eq 'Failed') {
            $failure = Get-MapValue -InputObject $operation -Name 'error'
            $detail = if ($null -ne $failure) { ($failure | ConvertTo-Json -Depth 5 -Compress) } else { '(no error detail returned)' }
            throw "Fabric table load failed: $detail"
        }
        if ((Get-Date) -gt $deadline) {
            throw "Fabric table load did not complete within $TimeoutSeconds seconds (last status: '$status', operation $OperationUri)."
        }
        Start-Sleep -Seconds $PollIntervalSeconds
    }
}

function Import-LakehouseTable {
    <#
    .SYNOPSIS
        Turn one staged CSV into a Delta table (creating it if absent).
    .DESCRIPTION
        Overwrite mode, header:true, explicit comma delimiter, pathType File - the four
        settings that make a re-run land exactly the source rows and no more. See the
        module header for what each one prevents.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$WorkspaceId,
        [Parameter(Mandatory)][string]$LakehouseId,
        [Parameter(Mandatory)][string]$TableName,
        [Parameter(Mandatory)][string]$RelativePath,
        [int]$TimeoutSeconds = 900
    )
    Assert-LakehouseTableName -Name $TableName | Out-Null
    if (-not $PSCmdlet.ShouldProcess($TableName, "Load Delta table from $RelativePath (mode Overwrite)")) {
        return $null
    }

    $body = [ordered]@{
        relativePath  = $RelativePath
        pathType      = 'File'
        mode          = 'Overwrite'
        recursive     = $false
        formatOptions = [ordered]@{
            format    = 'Csv'
            header    = $true
            delimiter = ','
        }
    }
    $response = Invoke-FabricApi -Token $Token -Method POST `
        -Path "workspaces/$WorkspaceId/lakehouses/$LakehouseId/tables/$TableName/load" `
        -Body $body -IncludeResponse

    $headers = Get-MapValue -InputObject $response -Name 'Headers'
    $location = Get-SeedHeaderValue -Headers $headers -Name 'Location'
    if ([string]::IsNullOrWhiteSpace($location)) {
        # Documented as a 202-only operation, but a synchronous 200 is not an error.
        return [pscustomobject]@{ Table = $TableName; Operation = $null; Awaited = $false }
    }

    $retryAfter = Get-SeedHeaderValue -Headers $headers -Name 'Retry-After'
    $pollInterval = 5
    if ($retryAfter -and ([int]::TryParse("$retryAfter", [ref]$null))) { $pollInterval = [int]$retryAfter }

    $operation = Wait-LakehouseLoadOperation -Token $Token -OperationUri $location `
        -PollIntervalSeconds $pollInterval -TimeoutSeconds $TimeoutSeconds
    return [pscustomobject]@{ Table = $TableName; Operation = $operation; Awaited = $true }
}

function Assert-LakehouseSeedPrerequisite {
    <#
    .SYNOPSIS
        Fail before the first upload, with a message that says what to do.
    .DESCRIPTION
        Local checks only, so this behaves identically under -WhatIf. The two-token
        check is here because a Fabric token sent to OneLake fails with an opaque 401
        bearer challenge halfway through the first table.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Token,
        [Parameter(Mandatory)][AllowEmptyString()][string]$OneLakeToken,
        [Parameter(Mandatory)][string]$DataPath,
        [Parameter(Mandatory)]$Manifest
    )
    if ([string]::IsNullOrWhiteSpace($Token)) {
        throw 'No Fabric API token was supplied. Pass -Token (az account get-access-token --resource https://api.fabric.microsoft.com --query accessToken -o tsv), or run with -Target sql.'
    }
    if ([string]::IsNullOrWhiteSpace($OneLakeToken)) {
        throw 'No OneLake token was supplied. OneLake is a STORAGE audience, not the Fabric one: pass -OneLakeToken from `az account get-access-token --resource https://storage.azure.com --query accessToken -o tsv`. Reusing the Fabric token here fails with an opaque 401 bearer challenge. https://learn.microsoft.com/en-us/fabric/onelake/onelake-access-api'
    }
    if (-not (Test-GeneratedDataComplete -Manifest $Manifest -DataPath $DataPath)) {
        throw "Generated dataset is missing or incomplete at '$DataPath'. Run ``python -m generators build`` from the repo's data/ directory (seed 20260822), or let data/seed/seed.ps1 run it for you."
    }
}

function Invoke-LakehouseSeed {
    <#
    .SYNOPSIS
        Create and load the ten Delta tables in the `mls_operations` lakehouse.
    .DESCRIPTION
        Idempotent: when every manifest table is already registered in the lakehouse the
        run uploads nothing and loads nothing. -Force re-uploads and re-loads in
        Overwrite mode, which is exactly-once by construction and is the L5 playbook's
        wipe-and-reseed remediation.

        The workspace and the lakehouse must already exist - infra/fabric/
        provision-workspace.ps1 owns creating them, and this refuses rather than
        quietly creating a second one under a name nobody expects.

        -WhatIf issues GETs only: workspace lookup, lakehouse lookup, table list. No PUT,
        PATCH or POST is reachable.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Token,
        [Parameter(Mandatory)][AllowEmptyString()][string]$OneLakeToken,
        [Parameter(Mandatory)]$Manifest,
        [Parameter(Mandatory)][string]$DataPath,
        [string]$WorkspaceName = 'mls-operations',
        [string]$LakehouseName = 'mls_operations',
        [string]$StagingRoot = 'Files/seed',
        [int]$TimeoutSeconds = 900,
        [switch]$Force
    )
    Assert-LakehouseSeedPrerequisite -Token $Token -OneLakeToken $OneLakeToken -DataPath $DataPath -Manifest $Manifest

    $tableNames = @(Get-MapValue -InputObject $Manifest -Name 'load_order')

    $workspace = Get-FabricWorkspace -Token $Token -Name $WorkspaceName
    if (-not $workspace) {
        throw "Fabric workspace '$WorkspaceName' does not exist. L5 provisions it (infra/fabric/provision-workspace.ps1); the seed will not create it."
    }
    $lakehouse = Get-FabricLakehouse -Token $Token -WorkspaceId $workspace.id -Name $LakehouseName
    if (-not $lakehouse) {
        throw "Lakehouse '$LakehouseName' does not exist in workspace '$WorkspaceName'. Run infra/fabric/provision-workspace.ps1 first."
    }
    Write-SeedStatus "Fabric: workspace '$WorkspaceName' ($($workspace.id)) / lakehouse '$LakehouseName' ($($lakehouse.id))" -Color Cyan

    $existing = @(@(Get-FabricTable -Token $Token -WorkspaceId $workspace.id -LakehouseId $lakehouse.id) |
            ForEach-Object { Get-MapValue -InputObject $_ -Name 'name' })
    $missing = @($tableNames | Where-Object { $_ -notin $existing })
    if ($missing.Count -eq 0 -and -not $Force) {
        Write-SeedStatus "All $($tableNames.Count) Delta tables already exist - nothing to load." -Color Green
        return [pscustomobject]@{
            Workspace            = $workspace
            Lakehouse            = $lakehouse
            Uploaded             = @()
            Loaded               = @()
            SkippedAlreadySeeded = $true
            Tables               = $existing
        }
    }

    if ($WhatIfPreference) {
        Write-SeedStatus "(-WhatIf) Would upload $($tableNames.Count) CSV file(s) to OneLake under $StagingRoot/ and load them as Delta tables (mode Overwrite): $($tableNames -join ', ')." -Color Yellow
    }

    $uploaded = @()
    $loaded = @()
    foreach ($name in $tableNames) {
        $localPath = Join-Path -Path $DataPath -ChildPath "$name.csv"
        $relativePath = Get-SeedStagingPath -TableName $name -Root $StagingRoot

        $upload = Send-OneLakeFile -OneLakeToken $OneLakeToken -WorkspaceId $workspace.id `
            -LakehouseId $lakehouse.id -RelativePath $relativePath -LocalPath $localPath `
            -WhatIf:$WhatIfPreference
        if ($null -eq $upload) { continue }
        $uploaded += $upload

        $load = Import-LakehouseTable -Token $Token -WorkspaceId $workspace.id `
            -LakehouseId $lakehouse.id -TableName $name -RelativePath $relativePath `
            -TimeoutSeconds $TimeoutSeconds -WhatIf:$WhatIfPreference
        if ($null -eq $load) { continue }
        $loaded += $load
        Write-SeedStatus "  loaded $name ($($upload.Bytes) bytes)" -Color Gray
    }

    if ($WhatIfPreference) {
        return [pscustomobject]@{
            Workspace            = $workspace
            Lakehouse            = $lakehouse
            Uploaded             = @()
            Loaded               = @()
            SkippedAlreadySeeded = $false
            Tables               = $existing
        }
    }

    # ---- read the table list back (L5 V5.2 is set equality, so drift matters both ways)
    $final = @(@(Get-FabricTable -Token $Token -WorkspaceId $workspace.id -LakehouseId $lakehouse.id) |
            ForEach-Object { Get-MapValue -InputObject $_ -Name 'name' })
    $stillMissing = @($tableNames | Where-Object { $_ -notin $final })
    if ($stillMissing.Count -gt 0) {
        throw "Loaded $($loaded.Count) table(s) but the lakehouse does not report $($stillMissing -join ', '). Table registration can lag a Delta write by minutes (L5 failure mode 4); re-run the seed, and if it persists check capacity health rather than widening this check."
    }
    Write-SeedStatus "Lakehouse seeded: $($loaded.Count) Delta table(s) loaded, $($final.Count) reported by Fabric." -Color Green

    return [pscustomobject]@{
        Workspace            = $workspace
        Lakehouse            = $lakehouse
        Uploaded             = @($uploaded)
        Loaded               = @($loaded)
        SkippedAlreadySeeded = $false
        Tables               = $final
    }
}

Export-ModuleMember -Function @(
    'Get-SeedHeaderValue',
    'Invoke-SeedWebRequest',
    'Get-OneLakeFileUri',
    'Get-SeedStagingPath',
    'Assert-LakehouseTableName',
    'Send-OneLakeFile',
    'ConvertTo-OperationStatus',
    'Wait-LakehouseLoadOperation',
    'Import-LakehouseTable',
    'Assert-LakehouseSeedPrerequisite',
    'Invoke-LakehouseSeed'
)
