#Requires -Version 7.0
<#
.SYNOPSIS
    Thin Microsoft Fabric REST API wrappers (L5 data platform).

.DESCRIPTION
    Service-principal-first wrappers over https://api.fabric.microsoft.com/v1.
    Every function takes an explicit bearer -Token (from GitHub OIDC ->
    `az account get-access-token --resource https://api.fabric.microsoft.com` in CI, or
    the human's token locally); the module never authenticates by itself and never
    stores credentials. Requires the tenant toggle "Service principals can use Fabric
    APIs" for SP tokens (spec F2 - portal-only, see 02-fabric-capacity.ps1).

    Capacity IDs are always parameters - never hardcoded (trial capacity today, paid
    F2 later is one variable change + gate G2).

    2026-08-24 (Copilot Studio amendment): data agent wrappers added for L8. The
    Fabric *data agent* item is generally available; its *configuration management*
    APIs (including staging/publish) and its Copilot Studio consumption are in
    PREVIEW. See infra/fabric/create-data-agent.ps1 for the documented fallback.
#>

Set-StrictMode -Version Latest

$script:FabricApiBaseUrl = 'https://api.fabric.microsoft.com/v1'

function Invoke-FabricApi {
    <#
    .SYNOPSIS
        Single choke point for every Fabric REST call (mocked in tests).
    .PARAMETER Token
        Bearer access token for https://api.fabric.microsoft.com.
    .PARAMETER Path
        Path relative to /v1, e.g. 'workspaces' or 'workspaces/<id>/lakehouses'.
    .PARAMETER IncludeResponse
        Return an envelope { Content; Headers; StatusCode } instead of the bare body.
        Needed only by callers that must inspect a 202 Accepted long-running-operation
        response (Location / x-ms-operation-id / Retry-After headers).
        Ref: https://learn.microsoft.com/en-us/rest/api/fabric/articles/long-running-operation
    #>
    param(
        [Parameter(Mandatory)][string]$Token,
        [ValidateSet('GET', 'POST', 'PATCH', 'DELETE')]
        [string]$Method = 'GET',
        [Parameter(Mandatory)][string]$Path,
        $Body = $null,
        [switch]$IncludeResponse
    )
    $uri = "$($script:FabricApiBaseUrl)/$Path"
    $headers = @{ Authorization = "Bearer $Token" }
    $restArgs = @{
        Method  = $Method
        Uri     = $uri
        Headers = $headers
    }
    if ($null -ne $Body) {
        $restArgs['Body'] = ($Body | ConvertTo-Json -Depth 10)
        $restArgs['ContentType'] = 'application/json'
    }
    if (-not $IncludeResponse) {
        return Invoke-RestMethod @restArgs
    }
    # Pre-initialised so Set-StrictMode is satisfied when the transport is mocked
    # and never assigns them.
    $responseHeaders = $null
    $statusCode = $null
    $content = Invoke-RestMethod @restArgs `
        -ResponseHeadersVariable responseHeaders -StatusCodeVariable statusCode
    return [pscustomobject]@{
        Content    = $content
        Headers    = $responseHeaders
        StatusCode = $statusCode
    }
}

function Get-PropertyValue {
    <# Strict-mode-safe property read from either a hashtable or a PSObject. #>
    param($InputObject, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.Contains($Name)) { return $InputObject[$Name] }
        return $null
    }
    $prop = $InputObject.PSObject.Properties[$Name]
    if ($prop) { return $prop.Value }
    return $null
}

function Get-FabricHeaderValue {
    <#
    .SYNOPSIS
        First value of a response header. Invoke-RestMethod returns headers as
        string[] per key, and header names are case-insensitive on the wire.
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

function Get-CollectionValue {
    <# Normalize a Fabric collection response ({value:[...]} or {data:[...]}) to an array. #>
    param($Response)
    if ($null -eq $Response) { return @() }
    if ($Response -is [System.Collections.IDictionary]) {
        foreach ($key in @('value', 'data')) {
            if ($Response.Contains($key)) { return @($Response[$key]) }
        }
        return @($Response)
    }
    foreach ($key in @('value', 'data')) {
        $prop = $Response.PSObject.Properties[$key]
        if ($prop) { return @($prop.Value) }
    }
    return @($Response)
}

function Get-FabricWorkspace {
    <#
    .SYNOPSIS
        Workspace by display name, or $null when absent.
    #>
    param(
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$Name
    )
    $response = Invoke-FabricApi -Token $Token -Method GET -Path 'workspaces'
    $found = @(Get-CollectionValue -Response $response | Where-Object { $_ -and $_.displayName -eq $Name })
    if ($found.Count -ge 1) { return $found[0] }
    return $null
}

function New-FabricWorkspace {
    <#
    .SYNOPSIS
        Create a workspace on the given capacity. CapacityId is a required parameter by
        design - it always comes from configuration, never a hardcoded value.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$CapacityId,
        [string]$Description = ''
    )
    if ($PSCmdlet.ShouldProcess($Name, "Create Fabric workspace on capacity $CapacityId")) {
        $body = [ordered]@{
            displayName = $Name
            capacityId  = $CapacityId
        }
        if ($Description) { $body['description'] = $Description }
        return Invoke-FabricApi -Token $Token -Method POST -Path 'workspaces' -Body $body
    }
    return $null
}

function Get-FabricLakehouse {
    <#
    .SYNOPSIS
        Lakehouse by display name within a workspace, or $null when absent.
    #>
    param(
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$WorkspaceId,
        [Parameter(Mandatory)][string]$Name
    )
    $response = Invoke-FabricApi -Token $Token -Method GET -Path "workspaces/$WorkspaceId/lakehouses"
    $found = @(Get-CollectionValue -Response $response | Where-Object { $_ -and $_.displayName -eq $Name })
    if ($found.Count -ge 1) { return $found[0] }
    return $null
}

function New-FabricLakehouse {
    <#
    .SYNOPSIS
        Create a lakehouse in a workspace.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$WorkspaceId,
        [Parameter(Mandatory)][string]$Name,
        [string]$Description = ''
    )
    if ($PSCmdlet.ShouldProcess($Name, "Create lakehouse in workspace $WorkspaceId")) {
        $body = [ordered]@{ displayName = $Name }
        if ($Description) { $body['description'] = $Description }
        return Invoke-FabricApi -Token $Token -Method POST -Path "workspaces/$WorkspaceId/lakehouses" -Body $body
    }
    return $null
}

function Get-FabricTable {
    <#
    .SYNOPSIS
        List the Delta tables of a lakehouse (the L5 audit compares this to the manifest).
    #>
    param(
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$WorkspaceId,
        [Parameter(Mandatory)][string]$LakehouseId
    )
    $response = Invoke-FabricApi -Token $Token -Method GET -Path "workspaces/$WorkspaceId/lakehouses/$LakehouseId/tables"
    return @(Get-CollectionValue -Response $response)
}

function Get-FabricWorkspaceRoleAssignment {
    <#
    .SYNOPSIS
        Role assignments for a workspace, or $null for a given principal when absent.
        GET /v1/workspaces/{workspaceId}/roleAssignments
    .DESCRIPTION
        F13 (compliance/findings/2026-08-26-prepublication-review.md#f13, Task 12):
        used to make Add-FabricWorkspaceRoleAssignment idempotent — check before
        granting rather than relying on the API to reject a duplicate.
        Ref: https://learn.microsoft.com/en-us/rest/api/fabric/core/workspaces/list-workspace-role-assignments
        Pagination (continuationToken/continuationUri) is not followed: every known
        caller (a handful of workload identities, never users) fits in one page, and
        the repo's other Fabric list wrappers (Get-FabricWorkspace, Get-FabricLakehouse)
        make the same simplifying assumption.
    .PARAMETER PrincipalId
        When supplied, returns only the one assignment for that principal (or $null).
        Omit to return every assignment in the workspace.
    #>
    param(
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$WorkspaceId,
        [string]$PrincipalId = ''
    )
    $response = Invoke-FabricApi -Token $Token -Method GET -Path "workspaces/$WorkspaceId/roleAssignments"
    $assignments = @(Get-CollectionValue -Response $response)
    if ([string]::IsNullOrWhiteSpace($PrincipalId)) { return $assignments }
    $found = @($assignments | Where-Object { $_ -and (Get-PropertyValue -InputObject $_.principal -Name 'id') -eq $PrincipalId })
    if ($found.Count -ge 1) { return $found[0] }
    return $null
}

function Add-FabricWorkspaceRoleAssignment {
    <#
    .SYNOPSIS
        Grant a principal a workspace role.
        POST /v1/workspaces/{workspaceId}/roleAssignments
    .DESCRIPTION
        F13 (compliance/findings/2026-08-26-prepublication-review.md#f13, Task 12):
        the REST path apps/main.bicep's grant modules cannot reach — a Fabric
        workspace role assignment is not an ARM resource, so it cannot be a Bicep
        `Microsoft.Authorization/roleAssignments` the way the subscription- and
        resource-scoped grants in infra/bicep/apps/modules/ are. This is the
        function provision-workspace.ps1 calls for data-api's workspace Viewer
        grant; the caller is responsible for idempotency (check
        Get-FabricWorkspaceRoleAssignment first) — this function always POSTs.
        Ref: https://learn.microsoft.com/en-us/rest/api/fabric/core/workspaces/add-workspace-role-assignment
    .PARAMETER PrincipalType
        One of the Fabric API's documented PrincipalType values (User,
        ServicePrincipal, Group, ServicePrincipalProfile, EntireTenant). A
        user-assigned managed identity authenticates as a service principal, so a
        UAMI's principalId is passed with type 'ServicePrincipal' — Fabric's REST
        API has no separate "managed identity" principal type (see this API's
        "Microsoft Entra supported identities" table: Service principal and
        Managed identities share the same row).
    .PARAMETER Role
        One of the Fabric API's documented WorkspaceRole values (Admin, Member,
        Contributor, Viewer).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$WorkspaceId,
        [Parameter(Mandatory)][string]$PrincipalId,
        [ValidateSet('User', 'ServicePrincipal', 'Group', 'ServicePrincipalProfile', 'EntireTenant')]
        [string]$PrincipalType = 'ServicePrincipal',
        [ValidateSet('Admin', 'Member', 'Contributor', 'Viewer')]
        [Parameter(Mandatory)][string]$Role
    )
    if (-not $PSCmdlet.ShouldProcess($PrincipalId, "Grant Fabric workspace role '$Role' in workspace $WorkspaceId")) {
        return $null
    }
    $body = [ordered]@{
        principal = [ordered]@{
            id   = $PrincipalId
            type = $PrincipalType
        }
        role      = $Role
    }
    return Invoke-FabricApi -Token $Token -Method POST -Path "workspaces/$WorkspaceId/roleAssignments" -Body $body
}

function Get-FabricCapacity {
    <#
    .SYNOPSIS
        Capacity by id from GET /v1/capacities, or $null when it is not visible to the
        caller.
    .DESCRIPTION
        The interesting field is `sku`. Fabric TRIAL capacities do not support AI
        experiences - the data agent among them - so L8 has to be able to tell a trial
        capacity from a paid F2+ one before it tries to create anything.
        Ref: https://learn.microsoft.com/en-us/fabric/fundamentals/fabric-trial
    #>
    param(
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$CapacityId
    )
    $response = Invoke-FabricApi -Token $Token -Method GET -Path 'capacities'
    $found = @(Get-CollectionValue -Response $response | Where-Object { $_ -and $_.id -eq $CapacityId })
    if ($found.Count -ge 1) { return $found[0] }
    return $null
}

function Wait-FabricOperation {
    <#
    .SYNOPSIS
        Poll a Fabric long-running operation to completion and return its result.
    .DESCRIPTION
        Fabric answers a write that cannot complete inline with 202 Accepted, an empty
        body, and the headers Location / x-ms-operation-id / Retry-After. The caller
        polls GET /v1/operations/{id} until status is Succeeded or Failed, then reads
        GET /v1/operations/{id}/result.
        Ref: https://learn.microsoft.com/en-us/rest/api/fabric/articles/long-running-operation
    #>
    param(
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$OperationId,
        [int]$PollIntervalSeconds = 5,
        [int]$TimeoutSeconds = 600
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ($true) {
        $operation = Invoke-FabricApi -Token $Token -Method GET -Path "operations/$OperationId"
        $status = Get-PropertyValue -InputObject $operation -Name 'status'
        if ($status -eq 'Succeeded') {
            return Invoke-FabricApi -Token $Token -Method GET -Path "operations/$OperationId/result"
        }
        if ($status -eq 'Failed') {
            $failure = Get-PropertyValue -InputObject $operation -Name 'error'
            $detail = if ($null -ne $failure) { ($failure | ConvertTo-Json -Depth 5 -Compress) } else { '(no error detail returned)' }
            throw "Fabric operation $OperationId failed: $detail"
        }
        if ((Get-Date) -gt $deadline) {
            throw "Fabric operation $OperationId did not complete within $TimeoutSeconds seconds (last status: '$status')."
        }
        Start-Sleep -Seconds $PollIntervalSeconds
    }
}

function New-FabricDataAgentDefinition {
    <#
    .SYNOPSIS
        Build the InlineBase64 `definition.parts` payload that binds a data agent to a
        lakehouse. Pure function - no REST, no side effects, fully unit-testable.
    .DESCRIPTION
        Part layout and JSON schemas per
        https://learn.microsoft.com/en-us/rest/api/fabric/articles/item-management/definitions/data-agent-definition

            Files/Config/data_agent.json                                  { "$schema": "2.1.0" }
            Files/Config/draft/stage_config.json                          { "$schema": "1.0.0", aiInstructions }
            Files/Config/draft/lakehouse-<name>/datasource.json           the binding below

        datasource.json `type` is taken from the documented enum
        (unknown | lakehouse_tables | lakehouse | data_warehouse | kusto |
         semantic_model | graph | mirrored_database | mirrored_azure_databricks).
        `lakehouse_tables` is correct here: the agent reads Delta TABLES through the
        SQL analytics endpoint. Lakehouse *files* are not supported by data agents.
    .PARAMETER SchemaName
        Wrap the selected tables in a `lakehouse_tables.schema` element of this name.
        Microsoft's published example uses that nesting (shown for a warehouse:
        `warehouse_tables.schema` with table children). Pass an empty string to emit a
        flat list of `lakehouse_tables.table` elements instead - kept as an escape
        hatch because the lakehouse-shaped example is not published verbatim.
    #>
    # NOTE: this attribute must stay BELOW the comment-help block. Placed above it,
    # PSScriptAnalyzer stops recognising the help and raises PSProvideCommentHelp.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pure builder: returns an in-memory object and changes no state anywhere.')]
    param(
        [Parameter(Mandatory)][string]$WorkspaceId,
        [Parameter(Mandatory)][string]$LakehouseId,
        [Parameter(Mandatory)][string]$LakehouseName,
        [string[]]$TableName = @(),
        [string]$AiInstructions = '',
        [string]$DataSourceInstructions = '',
        [string]$UserDescription = '',
        [string]$SchemaName = 'dbo'
    )
    $tableElements = @(
        foreach ($table in $TableName) {
            [ordered]@{
                display_name = $table
                type         = 'lakehouse_tables.table'
                is_selected  = $true
            }
        }
    )

    if ([string]::IsNullOrWhiteSpace($SchemaName)) {
        $elements = $tableElements
    }
    else {
        $elements = @(
            [ordered]@{
                display_name = $SchemaName
                type         = 'lakehouse_tables.schema'
                is_selected  = $true
                children     = $tableElements
            }
        )
    }

    $dataSource = [ordered]@{
        '$schema'              = '1.0.0'
        artifactId             = $LakehouseId
        workspaceId            = $WorkspaceId
        displayName            = $LakehouseName
        type                   = 'lakehouse_tables'
        userDescription        = $UserDescription
        dataSourceInstructions = $DataSourceInstructions
        elements               = $elements
    }

    $parts = @(
        (New-FabricDefinitionPart -Path 'Files/Config/data_agent.json' -Object ([ordered]@{ '$schema' = '2.1.0' }))
        (New-FabricDefinitionPart -Path 'Files/Config/draft/stage_config.json' -Object ([ordered]@{
                    '$schema'      = '1.0.0'
                    aiInstructions = $AiInstructions
                }))
        (New-FabricDefinitionPart -Path "Files/Config/draft/lakehouse-$LakehouseName/datasource.json" -Object $dataSource)
    )

    return [ordered]@{ parts = $parts }
}

function New-FabricDefinitionPart {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pure builder: returns an in-memory object and changes no state anywhere.')]
    <# Encode one definition part as InlineBase64 (UTF-8, no BOM). #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Object
    )
    $json = $Object | ConvertTo-Json -Depth 20
    return [ordered]@{
        path        = $Path
        payload     = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
        payloadType = 'InlineBase64'
    }
}

function Get-FabricDataAgent {
    <#
    .SYNOPSIS
        Data agent by display name within a workspace, or $null when absent.
        GET /v1/workspaces/{workspaceId}/dataAgents
    #>
    param(
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$WorkspaceId,
        [Parameter(Mandatory)][string]$Name
    )
    $response = Invoke-FabricApi -Token $Token -Method GET -Path "workspaces/$WorkspaceId/dataAgents"
    $found = @(Get-CollectionValue -Response $response | Where-Object { $_ -and $_.displayName -eq $Name })
    if ($found.Count -ge 1) { return $found[0] }
    return $null
}

function New-FabricDataAgent {
    <#
    .SYNOPSIS
        Create a data agent in a workspace.
        POST /v1/workspaces/{workspaceId}/dataAgents
    .DESCRIPTION
        Caller needs the workspace CONTRIBUTOR role and the Item.ReadWrite.All scope;
        service principals and managed identities are supported for this operation.
        Creating with a definition can answer 202 Accepted, so the response is
        inspected and any long-running operation is awaited here rather than by the
        caller. Ref: https://learn.microsoft.com/en-us/rest/api/fabric/dataagent/items
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$WorkspaceId,
        [Parameter(Mandatory)][string]$Name,
        [string]$Description = '',
        $Definition = $null,
        [int]$TimeoutSeconds = 600
    )
    if (-not $PSCmdlet.ShouldProcess($Name, "Create Fabric data agent in workspace $WorkspaceId")) {
        return $null
    }

    $body = [ordered]@{ displayName = $Name }
    if ($Description) { $body['description'] = $Description }
    if ($null -ne $Definition) { $body['definition'] = $Definition }

    $response = Invoke-FabricApi -Token $Token -Method POST `
        -Path "workspaces/$WorkspaceId/dataAgents" -Body $body -IncludeResponse

    $content = Get-PropertyValue -InputObject $response -Name 'Content'
    if ($null -ne (Get-PropertyValue -InputObject $content -Name 'id')) {
        return $content
    }

    # 202 Accepted: no body, poll the operation named in the response headers.
    $headers = Get-PropertyValue -InputObject $response -Name 'Headers'
    $operationId = Get-FabricHeaderValue -Headers $headers -Name 'x-ms-operation-id'
    if ([string]::IsNullOrWhiteSpace($operationId)) {
        throw "Fabric accepted the data agent create for '$Name' but returned neither an item id nor an x-ms-operation-id header."
    }

    $retryAfter = Get-FabricHeaderValue -Headers $headers -Name 'Retry-After'
    $pollInterval = 5
    if ($retryAfter -and ([int]::TryParse("$retryAfter", [ref]$null))) { $pollInterval = [int]$retryAfter }

    return Wait-FabricOperation -Token $Token -OperationId $operationId `
        -PollIntervalSeconds $pollInterval -TimeoutSeconds $TimeoutSeconds
}

function Publish-FabricDataAgent {
    <#
    .SYNOPSIS
        Promote a data agent's draft (staging) configuration to published.
        POST /v1/workspaces/{workspaceId}/dataAgents/{dataAgentId}/staging/publish
    .DESCRIPTION
        PREVIEW: "Data Agent configuration management is currently in Preview."
        Returns 200 with { publishedDescription } - this is NOT a long-running
        operation. Publishing is mandatory: an unpublished data agent cannot be
        consumed by Copilot Studio or by the Fabric data agent MCP endpoint, and the
        published description becomes the tool description the orchestrator reads.
        Scope: Item.ReadWrite.All or DataAgent.ReadWrite.All.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$WorkspaceId,
        [Parameter(Mandatory)][string]$DataAgentId,
        [string]$Description = ''
    )
    if (-not $PSCmdlet.ShouldProcess($DataAgentId, "Publish staging configuration of data agent in workspace $WorkspaceId")) {
        return $null
    }
    $body = [ordered]@{}
    if ($Description) { $body['description'] = $Description }
    return Invoke-FabricApi -Token $Token -Method POST `
        -Path "workspaces/$WorkspaceId/dataAgents/$DataAgentId/staging/publish" -Body $body
}

Export-ModuleMember -Function @(
    'Invoke-FabricApi',
    'Get-FabricWorkspace',
    'New-FabricWorkspace',
    'Get-FabricLakehouse',
    'New-FabricLakehouse',
    'Get-FabricTable',
    'Get-FabricWorkspaceRoleAssignment',
    'Add-FabricWorkspaceRoleAssignment',
    'Get-FabricCapacity',
    'Wait-FabricOperation',
    'New-FabricDataAgentDefinition',
    'Get-FabricDataAgent',
    'New-FabricDataAgent',
    'Publish-FabricDataAgent'
)
