#Requires -Version 7.0
<#
.SYNOPSIS
    L3 Entra layer - G3 full-tenant teardown (F23). Deletes manifest-listed CA
    policies, app registrations, groups and users, in that reverse-dependency order.

.DESCRIPTION
    The teardown half of infra/entra/apply-entra.ps1's triplet (CLAUDE.md: "Every
    layer ships a deploy path, a teardown script, a verification audit script. A
    layer without all three is not done."). docs/runbooks/kill-rebuild.md section 7
    step 2 names this exact path for tenant handback; before this file existed an
    operator following that numbered procedure hit file-not-found (spec F23).

    Reuses apply-entra.ps1's own access pattern rather than inventing a new one:
    every Graph call still funnels through Invoke-GraphApi / Invoke-GraphMutation
    (not the Remove-Mg* cmdlets), so -WhatIf gating and -AllowNotFound idempotency
    come from the same choke points the apply script already proved. Deletes ONLY
    what infra/entra/manifest.json lists - never a wildcard sweep of the tenant.

    The caller must already be connected:

        Connect-MgGraph -Scopes 'User.ReadWrite.All','Group.ReadWrite.All',
                                'Application.ReadWrite.All','Policy.ReadWrite.ConditionalAccess'

.NOTES
    *** GATE G3 *** Full-tenant teardown: per-occurrence human approval with stated
    scope (docs/runbooks/kill-rebuild.md section 7). Deleting these objects
    invalidates every recorded object ID and restarts license-propagation clocks -
    a rebuild afterwards carries the honest 2-3 hour SLA, not the standard cycle's
    <60 minutes. The standard kill/rebuild cycle (scripts/down.ps1) never calls this
    script; that separation is structural, not a runtime flag.

    Never callable from CI: refuses to run when $env:GITHUB_ACTIONS -eq 'true'
    unless -AllowAutomation is passed explicitly. No workflow in this repo passes it.

    Authoring this script is permitted under CLAUDE.md hard rule 1 ("Authoring code
    is always allowed; executing deployments is not"). It has never been run against
    a live tenant - verified only by the mocked Pester suite in
    infra/entra/tests/teardown.Tests.ps1, zero cloud calls.

.EXAMPLE
    ./teardown.ps1 -WhatIf
    # Enumerates every manifest-listed object that would be deleted; deletes nothing.

.EXAMPLE
    ./teardown.ps1 -Confirm:$false
    # G3 approval already on record: deletes CA policies, app registrations, groups,
    # then users.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [string]$ManifestPath = (Join-Path $PSScriptRoot 'manifest.json'),

    # Verified tenant domain for UPNs; empty = use the manifest's domain value.
    [string]$Domain = '',

    # Opt-out of the CI refusal below. No workflow in this repo ever passes this.
    [switch]$AllowAutomation
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- plumbing (same contract as apply-entra.ps1) ----------------------------------------

function Write-Status {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
        Justification = 'Interactive teardown script; console output is the product.')]
    param(
        # AllowEmptyString: the G3 banner prints blank spacer lines via
        # Write-Status '', which a bare Mandatory string parameter rejects.
        [Parameter(Mandatory)][AllowEmptyString()][string]$Message,
        [ConsoleColor]$Color = [ConsoleColor]::Gray
    )
    Write-Host $Message -ForegroundColor $Color
}

function Assert-NotAutomated {
    <# G3 teardown must never run unattended in CI; -AllowAutomation is the only opt-out. #>
    param([switch]$AllowAutomation)
    if ($env:GITHUB_ACTIONS -eq 'true' -and -not $AllowAutomation) {
        throw 'Refusing to run: $env:GITHUB_ACTIONS is ''true'' and -AllowAutomation was not passed. This is a G3 full-tenant teardown script (docs/runbooks/kill-rebuild.md section 7) and must never execute unattended in CI - no workflow in this repo passes -AllowAutomation.'
    }
}

function Write-G3Banner {
    <# Printed before any destructive call: the gate, the exact scope, the irreversible consequence. #>
    param(
        [Parameter(Mandatory)][string]$Scope,
        [Parameter(Mandatory)][string]$Consequence
    )
    Write-Status ''
    Write-Status '================ GATE G3: full-tenant Entra teardown ================' -Color Red
    Write-Status 'Per-occurrence human approval, stated scope (docs/runbooks/kill-rebuild.md section 7).' -Color Red
    Write-Status "Scope: $Scope" -Color Red
    Write-Status "Irreversible consequence: $Consequence" -Color Red
    Write-Status '=======================================================================' -Color Red
    Write-Status ''
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
    <#
        Every mutating Graph call flows through here so -WhatIf gates all writes.
        ConfirmImpact is 'High' HERE (the function that actually calls
        ShouldProcess), not on Invoke-Main: ConfirmImpact does not propagate from
        caller to callee, so declaring it only on Invoke-Main (as the original draft
        did) meant the default $ConfirmPreference of 'High' never triggered a prompt
        anywhere in the call chain (F23 review, Critical 1).

        Returns @{ Confirmed; Response }, not just the raw Graph response. A
        successful DELETE and a declined ShouldProcess both hand the caller no
        response body to tell them apart by - returning the boolean ShouldProcess
        itself produced is the only way a caller can distinguish "the human said
        no" from "it deleted cleanly" (F23 review, Critical 1 - the fix for the
        finding's own namesake defect: reporting a declined delete as done).
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][string]$Action,
        [Parameter(Mandatory)][ValidateSet('POST', 'PATCH', 'DELETE')][string]$Method,
        [Parameter(Mandatory)][string]$Path,
        $Body = $null
    )
    $confirmed = $PSCmdlet.ShouldProcess($Target, $Action)
    $response = $null
    if ($confirmed) {
        $response = Invoke-GraphApi -Method $Method -Path $Path -Body $Body -AllowNotFound
    }
    return @{ Confirmed = $confirmed; Response = $response }
}

# --- safe accessors (Graph returns hashtables; the manifest is PSCustomObject) ---------

function Get-Field {
    <# Value of a field, or $null. #>
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

function ConvertTo-ODataLiteral {
    param([Parameter(Mandatory)][string]$Value)
    return $Value.Replace("'", "''")
}

# --- lookups (same queries apply-entra.ps1 uses) ----------------------------------------

function Get-EntraUser {
    param([Parameter(Mandatory)][string]$Upn)
    return Invoke-GraphApi -Method GET -Path "users/$Upn`?`$select=id,displayName,userPrincipalName" -AllowNotFound
}

function Get-EntraGroup {
    <#
        Refuses on an ambiguous match (Count -gt 1) rather than deleting whichever
        object Graph happens to return first. apply-entra.ps1's identical
        first-match-wins read is safe there because it only ever decides
        "don''t recreate" - reversed into a delete, first-match-wins would delete an
        arbitrary real-tenant object sharing a manifest display name, with no
        warning (F23 review, Important 5).
    #>
    param([Parameter(Mandatory)][string]$DisplayName)
    $literal = ConvertTo-ODataLiteral -Value $DisplayName
    $response = Invoke-GraphApi -Method GET -Path "groups?`$filter=displayName eq '$literal'&`$select=id,displayName"
    $found = @(Get-ResponseValue -Response $response)
    if ($found.Count -gt 1) {
        throw "Ambiguous group display name '$DisplayName': $($found.Count) tenant objects share it. Refusing to delete an arbitrary match - resolve the duplicate by object ID before re-running this teardown."
    }
    if ($found.Count -ge 1) { return $found[0] }
    return $null
}

function Get-EntraApplication {
    <# Refuses on an ambiguous match - see Get-EntraGroup's note (F23 review,
       Important 5). #>
    param([Parameter(Mandatory)][string]$DisplayName)
    $literal = ConvertTo-ODataLiteral -Value $DisplayName
    $response = Invoke-GraphApi -Method GET -Path "applications?`$filter=displayName eq '$literal'&`$select=id,appId,displayName"
    $found = @(Get-ResponseValue -Response $response)
    if ($found.Count -gt 1) {
        throw "Ambiguous app registration display name '$DisplayName': $($found.Count) tenant objects share it. Refusing to delete an arbitrary match - resolve the duplicate by object ID before re-running this teardown."
    }
    if ($found.Count -ge 1) { return $found[0] }
    return $null
}

function Get-CaPolicy {
    <# Refuses on an ambiguous match - see Get-EntraGroup's note (F23 review,
       Important 5). #>
    param([Parameter(Mandatory)][string]$DisplayName)
    $response = Invoke-GraphApi -Method GET -Path 'identity/conditionalAccess/policies'
    $found = @(Get-ResponseValue -Response $response | Where-Object { (Get-Field -Object $_ -Name 'displayName') -eq $DisplayName })
    if ($found.Count -gt 1) {
        throw "Ambiguous CA policy display name '$DisplayName': $($found.Count) tenant objects share it. Refusing to delete an arbitrary match - resolve the duplicate by object ID before re-running this teardown."
    }
    if ($found.Count -ge 1) { return $found[0] }
    return $null
}

# --- pre-flight resolution (refuse before touching the tenant, not partway through) ----

function Resolve-ManifestForTeardown {
    <#
    .SYNOPSIS
        Resolves every manifest-listed CA policy, app registration, group and user
        BEFORE any deletion begins.
    .DESCRIPTION
        Get-CaPolicy / Get-EntraApplication / Get-EntraGroup already throw on an
        ambiguous (Count -gt 1) match against a live tenant object sharing a
        manifest display name. Before this pre-flight pass existed, that check ran
        per-lookup, INSIDE the same reverse-dependency loop that deletes: a
        duplicate display name on, say, the third group correctly refused the run,
        but only after the 2 CA policies and 3 app registrations ahead of it in
        manifest order had already been deleted for real - an ambiguity the script
        itself detected stopped it one category too late (F23 review, Minor 6).
        Calling every lookup here, once, before Invoke-Main's deletion loops run at
        all, means an ambiguous manifest refuses the ENTIRE run with zero deletes of
        any kind, CA policies included, rather than whichever categories happened to
        sort earlier than the duplicate.

        Users are resolved here too even though Get-EntraUser has no ambiguity case
        (a UPN lookup is unique by construction, not a displayName filter that can
        match more than one tenant object) - the manifest is validated as a whole
        up front, not piecemeal by category.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Policies,
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Apps,
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Groups,
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Users,
        [Parameter(Mandatory)][string]$Domain
    )
    foreach ($policy in $Policies) {
        Get-CaPolicy -DisplayName (Get-Field -Object $policy -Name 'displayName') | Out-Null
    }
    foreach ($app in $Apps) {
        Get-EntraApplication -DisplayName (Get-Field -Object $app -Name 'displayName') | Out-Null
    }
    foreach ($group in $Groups) {
        Get-EntraGroup -DisplayName (Get-Field -Object $group -Name 'displayName') | Out-Null
    }
    foreach ($user in $Users) {
        $upn = "$(Get-Field -Object $user -Name 'userPrincipalNamePrefix')@$Domain"
        Get-EntraUser -Upn $upn | Out-Null
    }
}

# --- delete-if-present (mirror of apply-entra.ps1's create-if-absent shape, reversed) ---

function Remove-CaPolicy {
    <#
    .SYNOPSIS
        Delete one manifest CA policy if it exists. Returns @{ DisplayName; Existed;
        Confirmed }.
    .DESCRIPTION
        Existed tells the caller whether a delete was attempted at all; Confirmed -
        taken directly from Invoke-GraphMutation's own ShouldProcess return value -
        tells the caller whether that attempt actually proceeded or was declined at
        the confirmation prompt. A successful DELETE and a ShouldProcess decline
        both hand back no Graph response body to tell them apart (there is no
        object body the way a POST's created-resource response has), so Confirmed
        is the only signal; reading $WhatIfPreference at the Invoke-Main call site
        instead - as an earlier revision did - conflated "declined" with "deleted",
        since both leave $WhatIfPreference $false (F23 review, Critical 1).

        This wrapper declares SupportsShouldProcess (satisfying PSScriptAnalyzer's
        PSUseShouldProcessForStateChangingFunctions on a "Remove" verb) but does NOT
        call $PSCmdlet.ShouldProcess itself - Invoke-GraphMutation is the single,
        sole place that gate is evaluated. A prior revision called ShouldProcess
        here too, "to satisfy the analyzer rule"; that justification was wrong
        (infra/policy/teardown.ps1's Remove-PolicyAssignment already proved the
        declare-but-never-call shape alone satisfies the rule) and the redundant
        second gate made every -WhatIf mutation test in this file pass even when
        EITHER layer alone was neutered - a false sense of coverage, not a safety
        feature (F23 review, Important 6).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)]$Policy)
    $displayName = Get-Field -Object $Policy -Name 'displayName'
    $existing = Get-CaPolicy -DisplayName $displayName
    if (-not $existing) {
        Write-Status "CA policy '$displayName' already absent - nothing to delete." -Color DarkGray
        return @{ DisplayName = $displayName; Existed = $false; Confirmed = $false }
    }
    $id = Get-Field -Object $existing -Name 'id'
    $mutation = Invoke-GraphMutation -Target $displayName -Action 'Delete CA policy' `
        -Method DELETE -Path "identity/conditionalAccess/policies/$id"
    return @{ DisplayName = $displayName; Existed = $true; Confirmed = $mutation.Confirmed }
}

function Remove-EntraApplication {
    <# Delete one manifest app registration if it exists. Returns @{ DisplayName;
       Existed; Confirmed } - see Remove-CaPolicy's note on why Confirmed comes
       from Invoke-GraphMutation's own ShouldProcess return, not $WhatIfPreference
       (F23 review, Critical 1). SupportsShouldProcess is declared for
       PSScriptAnalyzer only; Invoke-GraphMutation is the sole ShouldProcess call
       site. #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)]$App)
    $displayName = Get-Field -Object $App -Name 'displayName'
    $existing = Get-EntraApplication -DisplayName $displayName
    if (-not $existing) {
        Write-Status "App registration '$displayName' already absent - nothing to delete." -Color DarkGray
        return @{ DisplayName = $displayName; Existed = $false; Confirmed = $false }
    }
    $id = Get-Field -Object $existing -Name 'id'
    $mutation = Invoke-GraphMutation -Target $displayName -Action 'Delete app registration' `
        -Method DELETE -Path "applications/$id"
    return @{ DisplayName = $displayName; Existed = $true; Confirmed = $mutation.Confirmed }
}

function Remove-EntraGroup {
    <# Delete one manifest group if it exists. Returns @{ DisplayName; Existed;
       Confirmed } - see Remove-CaPolicy's note on why Confirmed comes from
       Invoke-GraphMutation's own ShouldProcess return, not $WhatIfPreference (F23
       review, Critical 1). SupportsShouldProcess is declared for PSScriptAnalyzer
       only; Invoke-GraphMutation is the sole ShouldProcess call site. #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)]$Group)
    $displayName = Get-Field -Object $Group -Name 'displayName'
    $existing = Get-EntraGroup -DisplayName $displayName
    if (-not $existing) {
        Write-Status "Group '$displayName' already absent - nothing to delete." -Color DarkGray
        return @{ DisplayName = $displayName; Existed = $false; Confirmed = $false }
    }
    $id = Get-Field -Object $existing -Name 'id'
    $mutation = Invoke-GraphMutation -Target $displayName -Action 'Delete group' `
        -Method DELETE -Path "groups/$id"
    return @{ DisplayName = $displayName; Existed = $true; Confirmed = $mutation.Confirmed }
}

function Remove-EntraUser {
    <# Delete one manifest user if it exists. Returns @{ Upn; Existed; Confirmed } -
       see Remove-CaPolicy's note on why Confirmed comes from Invoke-GraphMutation's
       own ShouldProcess return, not $WhatIfPreference (F23 review, Critical 1).
       SupportsShouldProcess is declared for PSScriptAnalyzer only;
       Invoke-GraphMutation is the sole ShouldProcess call site. #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]$User,
        [Parameter(Mandatory)][string]$Domain
    )
    $upn = "$(Get-Field -Object $User -Name 'userPrincipalNamePrefix')@$Domain"
    $existing = Get-EntraUser -Upn $upn
    if (-not $existing) {
        Write-Status "User '$upn' already absent - nothing to delete." -Color DarkGray
        return @{ Upn = $upn; Existed = $false; Confirmed = $false }
    }
    $id = Get-Field -Object $existing -Name 'id'
    $mutation = Invoke-GraphMutation -Target $upn -Action 'Delete user' -Method DELETE -Path "users/$id"
    return @{ Upn = $upn; Existed = $true; Confirmed = $mutation.Confirmed }
}

# --- main --------------------------------------------------------------------------------

function Invoke-Main {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [string]$ManifestPath = (Join-Path $PSScriptRoot 'manifest.json'),
        [AllowEmptyString()][string]$Domain = '',
        [switch]$AllowAutomation
    )
    Assert-NotAutomated -AllowAutomation:$AllowAutomation

    $manifest = Get-Manifest -Path $ManifestPath
    Test-GraphConnection | Out-Null

    $effectiveDomain = $Domain
    if ([string]::IsNullOrWhiteSpace($effectiveDomain)) {
        $effectiveDomain = Get-Field -Object $manifest -Name 'domain'
    }

    $users = @(Get-Field -Object $manifest -Name 'users')
    $groups = @(Get-Field -Object $manifest -Name 'groups')
    $apps = @(Get-Field -Object $manifest -Name 'appRegistrations')
    $policies = @(Get-Field -Object $manifest -Name 'conditionalAccessPolicies')

    # Refuse on an ambiguous manifest BEFORE any deletion runs, not partway through
    # the reverse-dependency loop below (F23 review, Minor 6).
    Resolve-ManifestForTeardown -Policies $policies -Apps $apps -Groups $groups -Users $users -Domain $effectiveDomain

    Write-G3Banner `
        -Scope "infra/entra/manifest.json (domain '$effectiveDomain'): $($policies.Count) CA polic(y/ies), $($apps.Count) app registration(s), $($groups.Count) group(s), $($users.Count) user(s)." `
        -Consequence 'Every deleted object''s Entra ID is invalidated permanently and license-propagation clocks restart. A rebuild after this teardown carries the honest 2-3 hour SLA (docs/runbooks/kill-rebuild.md section 7), not the standard cycle''s under-60-minute claim.'

    $summary = [ordered]@{
        CaDeleted = 0; CaDeclined = 0; CaNotFound = 0
        AppsDeleted = 0; AppsDeclined = 0; AppsNotFound = 0
        GroupsDeleted = 0; GroupsDeclined = 0; GroupsNotFound = 0
        UsersDeleted = 0; UsersDeclined = 0; UsersNotFound = 0
        SkippedInWhatIf = 0
    }

    # ---- reverse-dependency order: CA policies -> app registrations -> groups -> users ----
    # Existed means "found in the tenant"; Confirmed means "ShouldProcess actually
    # let the delete through" - a declined prompt leaves Existed true but Confirmed
    # false, and must be counted as Declined, never as Deleted (F23 review,
    # Critical 1). $WhatIfPreference is checked first so a -WhatIf run still reports
    # SkippedInWhatIf rather than Declined - both leave Confirmed false, but only
    # one of them is a dry run.

    foreach ($policy in $policies) {
        $result = Remove-CaPolicy -Policy $policy
        if (-not $result.Existed) { $summary.CaNotFound++ }
        elseif ($WhatIfPreference) { $summary.SkippedInWhatIf++ }
        elseif (-not $result.Confirmed) { $summary.CaDeclined++; Write-Status "Declined: CA policy '$($result.DisplayName)' was NOT deleted." -Color Yellow }
        else { $summary.CaDeleted++; Write-Status "Deleted CA policy '$($result.DisplayName)'." -Color Green }
    }

    foreach ($app in $apps) {
        $result = Remove-EntraApplication -App $app
        if (-not $result.Existed) { $summary.AppsNotFound++ }
        elseif ($WhatIfPreference) { $summary.SkippedInWhatIf++ }
        elseif (-not $result.Confirmed) { $summary.AppsDeclined++; Write-Status "Declined: app registration '$($result.DisplayName)' was NOT deleted." -Color Yellow }
        else { $summary.AppsDeleted++; Write-Status "Deleted app registration '$($result.DisplayName)'." -Color Green }
    }

    foreach ($group in $groups) {
        $result = Remove-EntraGroup -Group $group
        if (-not $result.Existed) { $summary.GroupsNotFound++ }
        elseif ($WhatIfPreference) { $summary.SkippedInWhatIf++ }
        elseif (-not $result.Confirmed) { $summary.GroupsDeclined++; Write-Status "Declined: group '$($result.DisplayName)' was NOT deleted." -Color Yellow }
        else { $summary.GroupsDeleted++; Write-Status "Deleted group '$($result.DisplayName)'." -Color Green }
    }

    foreach ($user in $users) {
        $result = Remove-EntraUser -User $user -Domain $effectiveDomain
        if (-not $result.Existed) { $summary.UsersNotFound++ }
        elseif ($WhatIfPreference) { $summary.SkippedInWhatIf++ }
        elseif (-not $result.Confirmed) { $summary.UsersDeclined++; Write-Status "Declined: user '$($result.Upn)' was NOT deleted." -Color Yellow }
        else { $summary.UsersDeleted++; Write-Status "Deleted user '$($result.Upn)'." -Color Green }
    }

    $summaryObject = [pscustomobject]$summary
    Write-Status ("Done: " + (($summary.Keys | ForEach-Object { "$_=$($summary[$_])" }) -join ' ')) -Color Cyan
    return $summaryObject
}

if (-not $env:MLS_SKIP_MAIN) {
    Invoke-Main -ManifestPath $ManifestPath -Domain $Domain -AllowAutomation:$AllowAutomation
}
