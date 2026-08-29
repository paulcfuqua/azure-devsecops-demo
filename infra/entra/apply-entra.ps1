#Requires -Version 7.0
<#
.SYNOPSIS
    L3 Entra layer - manifest-driven users, groups, app registrations and CA policies.

.DESCRIPTION
    Applies infra/entra/manifest.json to the tenant via Microsoft Graph
    (Invoke-MgGraphRequest). The caller must already be connected:

        Connect-MgGraph -Scopes 'User.ReadWrite.All','Group.ReadWrite.All',
                                'Application.ReadWrite.All','Policy.ReadWrite.ConditionalAccess'

    Idempotent create-if-absent / update-on-drift; replaying after a kill/rebuild
    no-ops in seconds (spec F6). Conditional Access policies are created in exactly
    the state the manifest declares - which is report-only
    (enabledForReportingButNotEnforced) for the two broad All-users/All-applications
    policies and `enabled` for mls-ca-require-mfa-dashboards, the narrow policy that
    requires MFA on the three human-facing dashboards. Propagation is handled by
    POLLING Graph until the new object is readable - never by blind sleeps.

    BREAK GLASS IS A PRECONDITION, NOT A README LINE
    ------------------------------------------------
    An `enabled` policy is refused - loudly, and on its own, without stopping the rest
    of the layer - until a group the manifest flags "breakGlass": true actually holds
    an emergency-access account: a member that is NOT one of the manifest's fictional
    demo personas and is not synced from on-premises. That is the whole failure mode a
    CA policy has: a misconfiguration with no excluded account locks the tenant's owner
    out of their own tenant with no recovery path. The group is created empty by this
    script, so the first pass necessarily skips the policy; a human adds the account
    (docs/runbooks/g0-bootstrap.md item 13) and the next replay creates it.

    The manifest addresses applications and groups by DISPLAY NAME
    (includeApplicationsByDisplayName / excludeGroupsByDisplayName) because Graph wants
    object ids that do not exist until this script has run. App registrations and groups
    are therefore created BEFORE conditional access policies, and their ids are carried
    forward into the policy body - see Invoke-Main.

    UPNs are <userPrincipalNamePrefix>@<domain>; -Domain overrides the manifest's
    placeholder domain (mls.example) with the tenant's real verified domain.

.NOTES
    Gate: L3 runs only after G1 approval + layer unblock (CLAUDE.md hard rule 1).
    Teardown lives in infra/entra/teardown.ps1 (G3-gated), not here.

.EXAMPLE
    ./apply-entra.ps1 -Domain contoso.onmicrosoft.com -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ManifestPath = (Join-Path $PSScriptRoot 'manifest.json'),

    # Verified tenant domain for UPNs; empty = use the manifest's domain value.
    [string]$Domain = '',

    [ValidateRange(0, 3600)]
    [int]$PropagationTimeoutSeconds = 180,

    [ValidateRange(0, 60)]
    [int]$PropagationIntervalSeconds = 5
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:AllowedCaStates = @('enabled', 'disabled', 'enabledForReportingButNotEnforced')

# --- plumbing --------------------------------------------------------------------------

function Write-Status {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
        Justification = 'Interactive apply script; console output is the product.')]
    param(
        [Parameter(Mandatory)][string]$Message,
        [ConsoleColor]$Color = [ConsoleColor]::Gray
    )
    Write-Host $Message -ForegroundColor $Color
}

function Test-GraphConnection {
    <# Throws unless an authenticated Microsoft Graph session exists. #>
    $cmd = Get-Command -Name Get-MgContext -ErrorAction SilentlyContinue
    if (-not $cmd) {
        throw 'Microsoft.Graph.Authentication module not found. Install-Module Microsoft.Graph.Authentication -Scope CurrentUser, then Connect-MgGraph.'
    }
    $ctx = Get-MgContext
    if (-not $ctx) {
        throw 'Not connected to Microsoft Graph. Run Connect-MgGraph with the scopes listed in this script''s help, then retry.'
    }
    return $ctx
}

function Invoke-GraphApi {
    <# Single choke point for every Microsoft Graph call (mocked in tests). #>
    param(
        [ValidateSet('GET', 'POST', 'PATCH', 'DELETE')]
        [string]$Method = 'GET',
        [Parameter(Mandatory)][string]$Path,
        $Body = $null,
        [switch]$AllowNotFound
    )
    $uri = "https://graph.microsoft.com/v1.0/$Path"
    try {
        if ($null -ne $Body) {
            return Invoke-MgGraphRequest -Method $Method -Uri $uri -Body ($Body | ConvertTo-Json -Depth 10) -ContentType 'application/json'
        }
        return Invoke-MgGraphRequest -Method $Method -Uri $uri
    }
    catch {
        if ($AllowNotFound -and $_.Exception.Message -match '(?i)404|Not ?Found|Request_ResourceNotFound|does not exist') {
            return $null
        }
        throw
    }
}

function Invoke-GraphMutation {
    <# Every mutating Graph call flows through here so -WhatIf gates all writes. #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][string]$Action,
        [Parameter(Mandatory)][ValidateSet('POST', 'PATCH', 'DELETE')][string]$Method,
        [Parameter(Mandatory)][string]$Path,
        $Body = $null
    )
    if ($PSCmdlet.ShouldProcess($Target, $Action)) {
        return Invoke-GraphApi -Method $Method -Path $Path -Body $Body
    }
    return $null
}

function Invoke-PropagationDelay {
    <# Isolated so tests can mock the wait away. #>
    param([Parameter(Mandatory)][int]$Seconds)
    Start-Sleep -Seconds $Seconds
}

function Wait-EntraPropagation {
    <#
        Poll a probe scriptblock until it returns a value (object visible in Graph) or
        the timeout elapses. Replaces blind Start-Sleep after creates.
    #>
    param(
        [Parameter(Mandatory)][scriptblock]$Probe,
        [string]$Description = 'object',
        [int]$TimeoutSeconds = 180,
        [int]$IntervalSeconds = 5
    )
    $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ($true) {
        $result = & $Probe
        if ($result) { return $result }
        if ([datetime]::UtcNow -ge $deadline) {
            throw "Timed out after ${TimeoutSeconds}s waiting for $Description to propagate in Microsoft Graph."
        }
        Invoke-PropagationDelay -Seconds $IntervalSeconds
    }
}

# --- safe accessors (Graph returns hashtables; the manifest is PSCustomObject) ---------

function Get-Field {
    <# Value of a field, or $null. NOTE: an empty-array value also comes back empty
       (PowerShell unrolls it) - use Test-Field when presence itself is the question. #>
    param($Object, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $null
    }
    $prop = $Object.PSObject.Properties[$Name]
    if ($prop) { return $prop.Value }
    return $null
}

function Test-Field {
    <# True when the key/property exists at all, regardless of its value. #>
    param($Object, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Object) { return $false }
    if ($Object -is [System.Collections.IDictionary]) { return $Object.Contains($Name) }
    return $null -ne $Object.PSObject.Properties[$Name]
}

function Get-FieldArray {
    <# A field that is meant to be a list, as an array - and an ABSENT field as an EMPTY
       array. `@(Get-Field ...)` cannot do this: @($null) is a one-element array holding
       $null, so a missing key would read as a list of one nothing. #>
    param($Object, [Parameter(Mandatory)][string]$Name)
    $value = Get-Field -Object $Object -Name $Name
    if ($null -eq $value) { return @() }
    return @($value)
}

function Get-ResponseValue {
    <# Normalize a Graph collection response to an array; an empty `value` stays empty. #>
    param($Response)
    if ($null -eq $Response) { return @() }
    if ($Response -is [System.Collections.IDictionary]) {
        if ($Response.Contains('value')) { return @($Response['value']) }
        return @($Response)
    }
    $prop = $Response.PSObject.Properties['value']
    if ($prop) { return @($prop.Value) }
    return @($Response)
}

# --- manifest --------------------------------------------------------------------------

function Get-Manifest {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Manifest not found at '$Path'."
    }
    try {
        return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    }
    catch {
        throw "Manifest at '$Path' is not valid JSON: $($_.Exception.Message)"
    }
}

function Get-BreakGlassGroupName {
    <# Display names of every group the manifest flags "breakGlass": true. Found by FLAG,
       never by name: renaming the group must not be able to silently disarm the guard,
       and hard-coding the name here would also hard-code the company prefix (CLAUDE.md). #>
    param([Parameter(Mandatory)]$Manifest)
    return @(Get-FieldArray -Object $Manifest -Name 'groups' |
            Where-Object { [bool](Get-Field -Object $_ -Name 'breakGlass') } |
            ForEach-Object { Get-Field -Object $_ -Name 'displayName' })
}

function Assert-ManifestSchema {
    <# Fail fast with a precise, human-actionable message before any Graph call. #>
    param([Parameter(Mandatory)]$Manifest)
    $problems = [System.Collections.Generic.List[string]]::new()

    foreach ($key in @('domain', 'users', 'groups', 'appRegistrations', 'conditionalAccessPolicies')) {
        if (-not (Test-Field -Object $Manifest -Name $key)) {
            $problems.Add("manifest missing required key '$key'")
        }
    }

    $userPrefixes = @()
    $index = 0
    foreach ($user in @(Get-Field -Object $Manifest -Name 'users')) {
        foreach ($field in @('displayName', 'mailNickname', 'userPrincipalNamePrefix', 'jobTitle', 'department')) {
            if ([string]::IsNullOrWhiteSpace([string](Get-Field -Object $user -Name $field))) {
                $problems.Add("users[$index] missing required field '$field'")
            }
        }
        $prefix = Get-Field -Object $user -Name 'userPrincipalNamePrefix'
        if ($prefix) { $userPrefixes += $prefix }
        $index++
    }

    $index = 0
    foreach ($group in @(Get-Field -Object $Manifest -Name 'groups')) {
        foreach ($field in @('displayName', 'mailNickname')) {
            if ([string]::IsNullOrWhiteSpace([string](Get-Field -Object $group -Name $field))) {
                $problems.Add("groups[$index] missing required field '$field'")
            }
        }
        if (-not (Test-Field -Object $group -Name 'members')) {
            $problems.Add("groups[$index] missing required field 'members'")
        }
        else {
            foreach ($member in @(Get-Field -Object $group -Name 'members')) {
                if ($userPrefixes -notcontains $member) {
                    $problems.Add("groups[$index] member '$member' does not match any users[].userPrincipalNamePrefix")
                }
            }
        }
        $index++
    }

    $index = 0
    foreach ($app in @(Get-Field -Object $Manifest -Name 'appRegistrations')) {
        if ([string]::IsNullOrWhiteSpace([string](Get-Field -Object $app -Name 'displayName'))) {
            $problems.Add("appRegistrations[$index] missing required field 'displayName'")
        }
        $index++
    }

    $applicationName = @(Get-FieldArray -Object $Manifest -Name 'appRegistrations' |
            ForEach-Object { Get-Field -Object $_ -Name 'displayName' })
    $groupName = @(Get-FieldArray -Object $Manifest -Name 'groups' |
            ForEach-Object { Get-Field -Object $_ -Name 'displayName' })
    $breakGlassName = Get-BreakGlassGroupName -Manifest $Manifest

    $index = 0
    foreach ($policy in @(Get-Field -Object $Manifest -Name 'conditionalAccessPolicies')) {
        foreach ($field in @('displayName', 'state', 'conditions', 'grantControls')) {
            if (-not (Test-Field -Object $policy -Name $field)) {
                $problems.Add("conditionalAccessPolicies[$index] missing required field '$field'")
            }
        }
        $state = Get-Field -Object $policy -Name 'state'
        if ($state -and $script:AllowedCaStates -notcontains $state) {
            $problems.Add("conditionalAccessPolicies[$index] has invalid state '$state' (allowed: $($script:AllowedCaStates -join ', '))")
        }

        # Every *ByDisplayName reference has to name something this manifest declares -
        # apply time is far too late to discover a typo, because the resolver would then
        # silently drop the entry and post a policy with a WIDER scope than authored.
        $conditions = Get-Field -Object $policy -Name 'conditions'
        $applications = Get-Field -Object $conditions -Name 'applications'
        $users = Get-Field -Object $conditions -Name 'users'
        $includeByName = Get-FieldArray -Object $applications -Name 'includeApplicationsByDisplayName'
        foreach ($name in $includeByName) {
            if ($applicationName -notcontains $name) {
                $problems.Add("conditionalAccessPolicies[$index] includeApplicationsByDisplayName '$name' does not match any appRegistrations[].displayName")
            }
        }
        $excludeByName = Get-FieldArray -Object $users -Name 'excludeGroupsByDisplayName'
        foreach ($name in $excludeByName) {
            if ($groupName -notcontains $name) {
                $problems.Add("conditionalAccessPolicies[$index] excludeGroupsByDisplayName '$name' does not match any groups[].displayName")
            }
        }

        # ENFORCED POLICIES CARRY THREE EXTRA RULES, checked here so an unsafe policy is
        # unrepresentable rather than merely undeployed. Microsoft's own guidance is that
        # every enforced CA policy excludes at least one emergency-access account; the
        # other two rules keep an enforced grant from quietly becoming tenant-wide.
        if ($state -eq 'enabled') {
            if (-not @($excludeByName | Where-Object { $breakGlassName -contains $_ })) {
                $problems.Add("conditionalAccessPolicies[$index] has state 'enabled' but excludes no break-glass group - an enforced policy must exclude a group flagged 'breakGlass': true or a misconfiguration locks the tenant owner out with no recovery path")
            }
            $include = Get-FieldArray -Object $applications -Name 'includeApplications'
            if ($include -contains 'All' -or $includeByName -contains 'All') {
                $problems.Add("conditionalAccessPolicies[$index] has state 'enabled' and targets every application ('All') - an enforced policy must name the applications it covers")
            }
            elseif ($includeByName.Count -eq 0) {
                $problems.Add("conditionalAccessPolicies[$index] has state 'enabled' but names no applications in includeApplicationsByDisplayName")
            }
        }
        $index++
    }

    if ($problems.Count -gt 0) {
        throw "Manifest validation failed:`n  - " + ($problems -join "`n  - ")
    }
    return $true
}

# --- lookups ---------------------------------------------------------------------------

function ConvertTo-ODataLiteral {
    param([Parameter(Mandatory)][string]$Value)
    return $Value.Replace("'", "''")
}

function Get-EntraUser {
    param([Parameter(Mandatory)][string]$Upn)
    return Invoke-GraphApi -Method GET -Path "users/$Upn`?`$select=id,displayName,jobTitle,department,userPrincipalName" -AllowNotFound
}

function Get-EntraGroup {
    param([Parameter(Mandatory)][string]$DisplayName)
    $literal = ConvertTo-ODataLiteral -Value $DisplayName
    $response = Invoke-GraphApi -Method GET -Path "groups?`$filter=displayName eq '$literal'&`$select=id,displayName,description"
    $found = @(Get-ResponseValue -Response $response)
    if ($found.Count -ge 1) { return $found[0] }
    return $null
}

function Get-EntraApplication {
    param([Parameter(Mandatory)][string]$DisplayName)
    $literal = ConvertTo-ODataLiteral -Value $DisplayName
    $response = Invoke-GraphApi -Method GET -Path "applications?`$filter=displayName eq '$literal'&`$select=id,appId,displayName,signInAudience"
    $found = @(Get-ResponseValue -Response $response)
    if ($found.Count -ge 1) { return $found[0] }
    return $null
}

function Get-CaPolicy {
    param([Parameter(Mandatory)][string]$DisplayName)
    $response = Invoke-GraphApi -Method GET -Path 'identity/conditionalAccess/policies'
    $found = @(Get-ResponseValue -Response $response | Where-Object { (Get-Field -Object $_ -Name 'displayName') -eq $DisplayName })
    if ($found.Count -ge 1) { return $found[0] }
    return $null
}

function Get-NewUserSecret {
    <# One-time initial password; user must change at first sign-in. Never logged. #>
    $bytes = [byte[]]::new(24)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    return 'Mls!' + [Convert]::ToBase64String($bytes)
}

# --- ensure functions ------------------------------------------------------------------

function Initialize-EntraUser {
    <# Create-if-absent / update-on-drift. Returns @{ Id; Outcome } (Id null under -WhatIf create). #>
    param(
        [Parameter(Mandatory)]$User,
        [Parameter(Mandatory)][string]$Domain,
        [int]$TimeoutSeconds = 180,
        [int]$IntervalSeconds = 5
    )
    $upn = "$(Get-Field -Object $User -Name 'userPrincipalNamePrefix')@$Domain"
    $existing = Get-EntraUser -Upn $upn
    if ($existing) {
        $patch = @{}
        foreach ($field in @('displayName', 'jobTitle', 'department')) {
            $desired = Get-Field -Object $User -Name $field
            if ($desired -and (Get-Field -Object $existing -Name $field) -ne $desired) {
                $patch[$field] = $desired
            }
        }
        if ($patch.Count -gt 0) {
            Invoke-GraphMutation -Target $upn -Action "Update user ($($patch.Keys -join ', '))" `
                -Method PATCH -Path "users/$(Get-Field -Object $existing -Name 'id')" -Body $patch | Out-Null
            return @{ Id = (Get-Field -Object $existing -Name 'id'); Outcome = 'Updated' }
        }
        return @{ Id = (Get-Field -Object $existing -Name 'id'); Outcome = 'Unchanged' }
    }

    $body = [ordered]@{
        accountEnabled    = $true
        displayName       = Get-Field -Object $User -Name 'displayName'
        mailNickname      = Get-Field -Object $User -Name 'mailNickname'
        userPrincipalName = $upn
        jobTitle          = Get-Field -Object $User -Name 'jobTitle'
        department        = Get-Field -Object $User -Name 'department'
        passwordProfile   = @{
            forceChangePasswordNextSignIn = $true
            password                      = Get-NewUserSecret
        }
    }
    foreach ($optional in @('givenName', 'surname', 'usageLocation')) {
        $value = Get-Field -Object $User -Name $optional
        if ($value) { $body[$optional] = $value }
    }
    $created = Invoke-GraphMutation -Target $upn -Action 'Create user' -Method POST -Path 'users' -Body $body
    if (-not $created) {
        return @{ Id = $null; Outcome = 'WhatIf' }
    }
    $id = Get-Field -Object $created -Name 'id'
    Wait-EntraPropagation -Description "user $upn" -TimeoutSeconds $TimeoutSeconds -IntervalSeconds $IntervalSeconds -Probe {
        Invoke-GraphApi -Method GET -Path "users/$id`?`$select=id" -AllowNotFound
    } | Out-Null
    return @{ Id = $id; Outcome = 'Created' }
}

function Initialize-EntraGroup {
    <# Create-if-absent security group; returns @{ Id; Outcome }. #>
    param(
        [Parameter(Mandatory)]$Group,
        [int]$TimeoutSeconds = 180,
        [int]$IntervalSeconds = 5
    )
    $displayName = Get-Field -Object $Group -Name 'displayName'
    $existing = Get-EntraGroup -DisplayName $displayName
    if ($existing) {
        return @{ Id = (Get-Field -Object $existing -Name 'id'); Outcome = 'Unchanged' }
    }
    $body = [ordered]@{
        displayName     = $displayName
        mailNickname    = Get-Field -Object $Group -Name 'mailNickname'
        description     = Get-Field -Object $Group -Name 'description'
        securityEnabled = $true
        mailEnabled     = $false
    }
    $created = Invoke-GraphMutation -Target $displayName -Action 'Create security group' -Method POST -Path 'groups' -Body $body
    if (-not $created) {
        return @{ Id = $null; Outcome = 'WhatIf' }
    }
    $id = Get-Field -Object $created -Name 'id'
    Wait-EntraPropagation -Description "group $displayName" -TimeoutSeconds $TimeoutSeconds -IntervalSeconds $IntervalSeconds -Probe {
        Invoke-GraphApi -Method GET -Path "groups/$id`?`$select=id" -AllowNotFound
    } | Out-Null
    return @{ Id = $id; Outcome = 'Created' }
}

function Initialize-GroupMembership {
    <# Add missing members only; returns the number of members added. #>
    param(
        [Parameter(Mandatory)][string]$GroupId,
        [Parameter(Mandatory)][string]$GroupName,
        [AllowEmptyCollection()][string[]]$MemberIds = @()
    )
    $response = Invoke-GraphApi -Method GET -Path "groups/$GroupId/members?`$select=id"
    $currentIds = @(Get-ResponseValue -Response $response | ForEach-Object { Get-Field -Object $_ -Name 'id' })
    $added = 0
    foreach ($memberId in $MemberIds) {
        if ($currentIds -contains $memberId) { continue }
        $body = @{ '@odata.id' = "https://graph.microsoft.com/v1.0/directoryObjects/$memberId" }
        Invoke-GraphMutation -Target $GroupName -Action "Add member $memberId" `
            -Method POST -Path "groups/$GroupId/members/`$ref" -Body $body | Out-Null
        $added++
    }
    return $added
}

function Initialize-EntraApplication {
    <# Create-if-absent / update-on-drift app registration. Returns @{ AppId; Outcome }.

       AppId is the application (client) id, NOT the directory object id: it is what
       Conditional Access `includeApplications` addresses an application by, and carrying
       it out of here is what lets the CA loop below scope a policy to named applications
       instead of 'All'. It is $null only under -WhatIf, where nothing was created. #>
    param([Parameter(Mandatory)]$App)
    $displayName = Get-Field -Object $App -Name 'displayName'
    $audience = Get-Field -Object $App -Name 'signInAudience'
    if (-not $audience) { $audience = 'AzureADMyOrg' }
    $existing = Get-EntraApplication -DisplayName $displayName
    if ($existing) {
        $appId = Get-Field -Object $existing -Name 'appId'
        if ((Get-Field -Object $existing -Name 'signInAudience') -ne $audience) {
            Invoke-GraphMutation -Target $displayName -Action "Update signInAudience -> $audience" `
                -Method PATCH -Path "applications/$(Get-Field -Object $existing -Name 'id')" `
                -Body @{ signInAudience = $audience } | Out-Null
            return @{ AppId = $appId; Outcome = 'Updated' }
        }
        return @{ AppId = $appId; Outcome = 'Unchanged' }
    }
    $body = [ordered]@{
        displayName    = $displayName
        signInAudience = $audience
    }
    $notes = Get-Field -Object $App -Name 'notes'
    if ($notes) { $body['notes'] = $notes }
    $created = Invoke-GraphMutation -Target $displayName -Action 'Create app registration' -Method POST -Path 'applications' -Body $body
    if ($created) {
        return @{ AppId = (Get-Field -Object $created -Name 'appId'); Outcome = 'Created' }
    }
    return @{ AppId = $null; Outcome = 'WhatIf' }
}

function Resolve-CaPolicyCondition {
    <#
        Turn the manifest's display-name references into the object ids Graph requires.

        `includeApplicationsByDisplayName` -> `includeApplications` (application/client ids)
        `excludeGroupsByDisplayName`       -> `excludeGroups`       (group object ids)

        Neither *ByDisplayName key is a Graph field; both exist because the ids do not
        exist until this run has created the objects. Returns
        @{ Conditions; Unresolved } - Unresolved naming every reference with no id yet,
        which under -WhatIf is every one of them (nothing was created).
    #>
    param(
        [Parameter(Mandatory)]$Policy,
        [Parameter(Mandatory)][hashtable]$AppIdByDisplayName,
        [Parameter(Mandatory)][hashtable]$GroupIdByDisplayName
    )
    $unresolved = [System.Collections.Generic.List[string]]::new()
    # Round-trip through JSON for a deep, mutable copy: the manifest is PSCustomObject all
    # the way down and must not be edited in place (it is read again on the next replay).
    $conditions = Get-Field -Object $Policy -Name 'conditions' | ConvertTo-Json -Depth 20 | ConvertFrom-Json -AsHashtable
    if ($null -eq $conditions) { return @{ Conditions = $null; Unresolved = @('conditions') } }

    $resolve = {
        param($Container, [string]$FromKey, [string]$ToKey, [hashtable]$Map, [string]$Kind)
        if ($null -eq $Container -or -not $Container.ContainsKey($FromKey)) { return }
        $names = @($Container[$FromKey])
        $Container.Remove($FromKey)
        $ids = @()
        if ($Container.ContainsKey($ToKey)) { $ids = @($Container[$ToKey]) }
        foreach ($name in $names) {
            if ($Map.ContainsKey($name) -and $Map[$name]) { $ids += $Map[$name]; continue }
            $unresolved.Add("$Kind '$name'")
        }
        $Container[$ToKey] = @($ids)
    }

    & $resolve $conditions['applications'] 'includeApplicationsByDisplayName' 'includeApplications' $AppIdByDisplayName 'application'
    & $resolve $conditions['users'] 'excludeGroupsByDisplayName' 'excludeGroups' $GroupIdByDisplayName 'group'

    return @{ Conditions = $conditions; Unresolved = @($unresolved) }
}

function Test-BreakGlassReady {
    <#
        Is there an emergency-access account to fall back on if this policy is wrong?

        Ready means: some break-glass group holds at least one member that is NOT one of
        this manifest's fictional demo personas (a persona is not an emergency account - no
        human holds its credential) and is not synced from on-premises (a break-glass
        account must be cloud-only, or an outage in the sync source takes the recovery path
        down with it). Returns @{ Ready; Reason }.
    #>
    param(
        [AllowEmptyCollection()][string[]]$GroupName = @(),
        [Parameter(Mandatory)][hashtable]$GroupIdByDisplayName,
        [AllowEmptyCollection()][string[]]$DemoUserId = @()
    )
    foreach ($name in $GroupName) {
        if (-not $GroupIdByDisplayName.ContainsKey($name) -or -not $GroupIdByDisplayName[$name]) { continue }
        $groupId = $GroupIdByDisplayName[$name]
        $response = Invoke-GraphApi -Method GET -Path "groups/$groupId/members?`$select=id"
        foreach ($member in @(Get-ResponseValue -Response $response)) {
            $memberId = Get-Field -Object $member -Name 'id'
            if (-not $memberId) { continue }
            if ($DemoUserId -contains $memberId) { continue }
            $user = Invoke-GraphApi -Method GET -Path "users/$memberId`?`$select=id,userPrincipalName,onPremisesSyncEnabled" -AllowNotFound
            if ($user -and (Get-Field -Object $user -Name 'onPremisesSyncEnabled') -eq $true) { continue }
            return @{ Ready = $true; Reason = "break-glass group '$name' holds an emergency-access account" }
        }
    }
    return @{
        Ready  = $false
        Reason = "no break-glass group ($($GroupName -join ', ')) holds a cloud-only emergency-access account that is not one of the manifest's demo personas"
    }
}

function Initialize-CaPolicy {
    <#
        Create-if-absent CA policy from the manifest (the state comes straight from the
        manifest - report-only for the two broad policies, `enabled` for the dashboard MFA
        policy); on drift only `state` is re-asserted - condition edits are a deliberate
        manual/G3 concern.

        An `enabled` policy is REFUSED (outcome 'Blocked') unless a break-glass group holds
        an emergency-access account. The refusal is per policy: everything else in the
        layer still applies, the operator is told exactly what to do, and the fail-safe
        direction is the safe one - no policy means no lockout.
    #>
    param(
        [Parameter(Mandatory)]$Policy,
        [hashtable]$AppIdByDisplayName = @{},
        [hashtable]$GroupIdByDisplayName = @{},
        [AllowEmptyCollection()][string[]]$BreakGlassGroupName = @(),
        [AllowEmptyCollection()][string[]]$DemoUserId = @()
    )
    $displayName = Get-Field -Object $Policy -Name 'displayName'
    $desiredState = Get-Field -Object $Policy -Name 'state'
    $enforced = $desiredState -eq 'enabled'

    # Test-BreakGlassReady reads the tenant, so it is called only on the branches that are
    # about to enforce something - never on the -WhatIf plan path below, where the group it
    # would look at has not been created yet and the answer would be meaningless.
    $breakGlass = @{ Ready = $true; Reason = 'not an enforced policy' }

    $existing = Get-CaPolicy -DisplayName $displayName
    if ($existing) {
        if ($enforced) {
            $breakGlass = Test-BreakGlassReady -GroupName $BreakGlassGroupName `
                -GroupIdByDisplayName $GroupIdByDisplayName -DemoUserId $DemoUserId
        }
        if ((Get-Field -Object $existing -Name 'state') -eq $desiredState) {
            if (-not $breakGlass.Ready) {
                Write-Warning "CA policy '$displayName' is ENFORCED but $($breakGlass.Reason). Restore an emergency-access account before you need one."
            }
            return 'Unchanged'
        }
        if (-not $breakGlass.Ready) {
            Write-Status "REFUSING to enable CA policy '$displayName': $($breakGlass.Reason). See docs/runbooks/g0-bootstrap.md item 13." -Color Red
            return 'Blocked'
        }
        Invoke-GraphMutation -Target $displayName -Action "Update CA policy state -> $desiredState" `
            -Method PATCH -Path "identity/conditionalAccess/policies/$(Get-Field -Object $existing -Name 'id')" `
            -Body @{ state = $desiredState } | Out-Null
        return 'Updated'
    }

    $resolved = Resolve-CaPolicyCondition -Policy $Policy `
        -AppIdByDisplayName $AppIdByDisplayName -GroupIdByDisplayName $GroupIdByDisplayName
    if ($resolved.Unresolved.Count -gt 0) {
        # Only reachable under -WhatIf: the apps and groups a policy names are created
        # earlier in the same run, so on a real pass every id is already in hand.
        Write-Status "(-WhatIf) Would create CA policy '$displayName' (state: $desiredState) once these exist: $($resolved.Unresolved -join ', ')" -Color Yellow
        return 'WhatIf'
    }

    if ($enforced) {
        $breakGlass = Test-BreakGlassReady -GroupName $BreakGlassGroupName `
            -GroupIdByDisplayName $GroupIdByDisplayName -DemoUserId $DemoUserId
    }
    if (-not $breakGlass.Ready) {
        Write-Status "REFUSING to create ENFORCED CA policy '$displayName': $($breakGlass.Reason). See docs/runbooks/g0-bootstrap.md item 13, then re-run this layer." -Color Red
        return 'Blocked'
    }

    $body = [ordered]@{
        displayName   = $displayName
        state         = $desiredState
        conditions    = $resolved.Conditions
        grantControls = Get-Field -Object $Policy -Name 'grantControls'
    }
    $created = Invoke-GraphMutation -Target $displayName -Action "Create CA policy (state: $desiredState)" `
        -Method POST -Path 'identity/conditionalAccess/policies' -Body $body
    if ($created) { return 'Created' }
    return 'WhatIf'
}

# --- main ------------------------------------------------------------------------------

function Invoke-Main {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$ManifestPath,
        [AllowEmptyString()][string]$Domain = '',
        [int]$PropagationTimeoutSeconds = 180,
        [int]$PropagationIntervalSeconds = 5
    )
    $manifest = Get-Manifest -Path $ManifestPath
    Assert-ManifestSchema -Manifest $manifest | Out-Null
    Test-GraphConnection | Out-Null

    $effectiveDomain = $Domain
    if ([string]::IsNullOrWhiteSpace($effectiveDomain)) {
        $effectiveDomain = Get-Field -Object $manifest -Name 'domain'
    }
    if ($effectiveDomain -eq 'mls.example') {
        Write-Warning "Using placeholder domain 'mls.example' - pass -Domain <verified tenant domain> for a real tenant."
    }
    Write-Status "Applying Entra manifest '$ManifestPath' (domain: $effectiveDomain)" -Color Cyan

    $summary = [ordered]@{
        UsersCreated = 0; UsersUpdated = 0; UsersUnchanged = 0
        GroupsCreated = 0; GroupsUnchanged = 0; MembershipsAdded = 0
        AppsCreated = 0; AppsUpdated = 0; AppsUnchanged = 0
        CaCreated = 0; CaUpdated = 0; CaUnchanged = 0; CaBlocked = 0
        SkippedInWhatIf = 0
    }

    # ---- users ---------------------------------------------------------------------
    $userIdByPrefix = @{}
    foreach ($user in @(Get-Field -Object $manifest -Name 'users')) {
        $result = Initialize-EntraUser -User $user -Domain $effectiveDomain `
            -TimeoutSeconds $PropagationTimeoutSeconds -IntervalSeconds $PropagationIntervalSeconds
        $prefix = Get-Field -Object $user -Name 'userPrincipalNamePrefix'
        switch ($result.Outcome) {
            'Created' { $summary.UsersCreated++ }
            'Updated' { $summary.UsersUpdated++ }
            'Unchanged' { $summary.UsersUnchanged++ }
            'WhatIf' { $summary.SkippedInWhatIf++ }
        }
        if ($result.Id) { $userIdByPrefix[$prefix] = $result.Id }
    }

    # ---- groups + memberships ------------------------------------------------------
    # Group ids are kept for the CA loop below: an enforced policy excludes the
    # break-glass group by object id, and the group has to exist before it can be named.
    $groupIdByDisplayName = @{}
    foreach ($group in @(Get-Field -Object $manifest -Name 'groups')) {
        $groupName = Get-Field -Object $group -Name 'displayName'
        $result = Initialize-EntraGroup -Group $group `
            -TimeoutSeconds $PropagationTimeoutSeconds -IntervalSeconds $PropagationIntervalSeconds
        switch ($result.Outcome) {
            'Created' { $summary.GroupsCreated++ }
            'Unchanged' { $summary.GroupsUnchanged++ }
            'WhatIf' { $summary.SkippedInWhatIf++ }
        }
        if (-not $result.Id) {
            Write-Status "(-WhatIf) Would then add members to '$groupName': $((Get-Field -Object $group -Name 'members') -join ', ')" -Color Yellow
            continue
        }
        $groupIdByDisplayName[$groupName] = $result.Id
        $memberIds = @()
        foreach ($member in @(Get-Field -Object $group -Name 'members')) {
            if ($userIdByPrefix.ContainsKey($member)) {
                $memberIds += $userIdByPrefix[$member]
            }
            else {
                Write-Status "(-WhatIf) Member '$member' has no resolvable id yet (user not created) - skipping." -Color Yellow
            }
        }
        $summary.MembershipsAdded += Initialize-GroupMembership -GroupId $result.Id -GroupName $groupName -MemberIds $memberIds
    }

    # ---- app registrations ---------------------------------------------------------
    # ORDERING IS LOAD-BEARING, not incidental: mls-ca-require-mfa-dashboards scopes
    # itself to three named applications, and Conditional Access addresses an application
    # by its application (client) id - which does not exist until the registration does.
    # So app registrations are created here, their ids are collected, and only then does
    # the CA loop below run. A policy whose applications are not yet resolvable is skipped
    # with a message naming them rather than posted with an empty (= tenant-wide) scope.
    $appIdByDisplayName = @{}
    foreach ($app in @(Get-Field -Object $manifest -Name 'appRegistrations')) {
        $result = Initialize-EntraApplication -App $app
        switch ($result.Outcome) {
            'Created' { $summary.AppsCreated++ }
            'Updated' { $summary.AppsUpdated++ }
            'Unchanged' { $summary.AppsUnchanged++ }
            'WhatIf' { $summary.SkippedInWhatIf++ }
        }
        if ($result.AppId) { $appIdByDisplayName[(Get-Field -Object $app -Name 'displayName')] = $result.AppId }
    }

    # ---- conditional access policies ----------------------------------------------
    $breakGlassGroupName = Get-BreakGlassGroupName -Manifest $manifest
    $demoUserId = @($userIdByPrefix.Values)
    foreach ($policy in @(Get-Field -Object $manifest -Name 'conditionalAccessPolicies')) {
        $outcome = Initialize-CaPolicy -Policy $policy `
            -AppIdByDisplayName $appIdByDisplayName -GroupIdByDisplayName $groupIdByDisplayName `
            -BreakGlassGroupName $breakGlassGroupName -DemoUserId $demoUserId
        switch ($outcome) {
            'Created' { $summary.CaCreated++ }
            'Updated' { $summary.CaUpdated++ }
            'Unchanged' { $summary.CaUnchanged++ }
            'Blocked' { $summary.CaBlocked++ }
            'WhatIf' { $summary.SkippedInWhatIf++ }
        }
    }
    if ($summary.CaBlocked -gt 0) {
        Write-Status "$($summary.CaBlocked) enforced CA polic(y/ies) NOT created: no break-glass account exists yet. MFA is NOT being enforced. Add an emergency-access account to the break-glass group ($($breakGlassGroupName -join ', ')) per docs/runbooks/g0-bootstrap.md item 13 and re-run this layer; V3.3 fails until you do." -Color Red
    }

    $summaryObject = [pscustomobject]$summary
    Write-Status ("Done: " + (($summary.Keys | ForEach-Object { "$_=$($summary[$_])" }) -join ' ')) -Color Cyan
    return $summaryObject
}

if (-not $env:MLS_SKIP_MAIN) {
    Invoke-Main -ManifestPath $ManifestPath -Domain $Domain `
        -PropagationTimeoutSeconds $PropagationTimeoutSeconds -PropagationIntervalSeconds $PropagationIntervalSeconds
}
