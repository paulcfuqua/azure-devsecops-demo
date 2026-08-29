#Requires -Version 7.0
<#
.SYNOPSIS
    G0 bootstrap step 1 - root OIDC identities (human-run, under your own `az login`).

.DESCRIPTION
    Creates/updates the GitHub OIDC deployer identity and the read-only verifier identity:

      * App registration `mls-github-deployer` with a federated identity credential for
        the repo you pass as -Repository (subject: the `demo` environment only). There is
        deliberately no branch-ref credential here (2026-08-26 finding F7): a `repo:<r>:
        ref:refs/heads/main` subject is mintable by any job with `id-token: write` that
        runs on main, deploy or not, which would let it reach this identity's Owner grant
        while bypassing the `demo` environment's protection rules entirely. The
        environment subject is sufficient for every deploy job, which already declares
        `environment: demo`. Also: its service principal, Owner on the target
        subscription, and Microsoft Graph *application* permissions (User.ReadWrite.All,
        Group.ReadWrite.All, Application.ReadWrite.OwnedBy, Policy.ReadWrite.ConditionalAccess,
        Directory.Read.All).
      * App registration `mls-verifier` with its OWN federated identity credential on a
        subject DISTINCT from the deployer's - `environment:verify`, never `environment:
        demo` (2026-08-26 findings F6/F7: reusing the deployer's subject would let anything
        executing in a verify job mint a token that exchanges for the Owner-capable
        deployer instead of this Reader-scoped identity). Also: its service principal,
        Reader on the target subscription, and READ-ONLY Graph application permissions
        Directory.Read.All + Policy.Read.All (CA policy state audits). Its S&C PowerShell
        access for Get-Label audits (View-Only Configuration + Exchange.ManageAsApp) is a
        manual step printed at the end - EXO role assignment is not cleanly scriptable here.

    The script NEVER grants admin consent itself - it prints the admin-consent URL for
    each app and you click it (G0 runbook, docs/runbooks/g0-bootstrap.md, step C3).

    Idempotent: re-running updates existing objects instead of duplicating them.

.NOTES
    Gate: G0 bootstrap. Runs under an interactive `az login` session held by the tenant
    Global Administrator. AGENTS MAY RUN THIS (sponsor amendment 2026-08-29: agent-created
    and agent-managed infrastructure is the demo, not something the demo describes). This
    line previously read "Agents author this file; they never execute it."

    What did NOT change, and is the reason the amendment is safe to make: G2 still gates
    every spend increase, and G3 still gates tenant-level deletion -- the three teardown
    scripts under infra/ refuse to run unattended in CI without -AllowAutomation, and no
    workflow passes it. See CLAUDE.md rule 1.

.EXAMPLE
    ./01-root-oidc.ps1 -SubscriptionId 00000000-0000-0000-0000-000000000000 -Repository <owner>/<repo> -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$SubscriptionId,

    # GitHub repository the federated credentials trust (owner/name).
    #
    # NO DEFAULT, deliberately. This value decides which repo is trusted to deploy into
    # your subscription. A default would mean anyone who clones this public repo and runs
    # the script without reading it federates their Azure identity to SOMEONE ELSE'S
    # repository - a silent, and serious, misconfiguration. Falls back to the
    # MLS_GITHUB_REPO / MLS_REPOSITORY environment variables, then fails with instructions.
    [ValidatePattern('^$|^[\w.-]+/[\w.-]+$')]
    [string]$Repository = '',

    # GitHub environment name used by deploy jobs.
    [string]$EnvironmentName = 'demo',

    # GitHub environment name used by verify jobs. Deliberately DISTINCT from
    # -EnvironmentName (2026-08-26 findings F6/F7): the OIDC subject is derived from the
    # job's declared `environment:`, not from the client-id passed to azure/login, so
    # reusing 'demo' here would let any verify job mint the Owner-capable deployer's
    # subject instead of this Reader-scoped identity's.
    [string]$VerifierEnvironmentName = 'verify',

    [string]$DeployerAppName = 'mls-github-deployer',

    [string]$VerifierAppName = 'mls-verifier'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- constants -------------------------------------------------------------------------

$script:GraphResourceAppId = '00000003-0000-0000-c000-000000000000' # Microsoft Graph
$script:GithubOidcIssuer = 'https://token.actions.githubusercontent.com'
$script:OidcAudience = 'api://AzureADTokenExchange'

# Microsoft Graph *application* (appRole) permission ids.
#
# Application.ReadWrite.OwnedBy (not .All, 2026-08-26 finding F8): apply-entra.ps1 only
# ever creates/updates the three apps in infra/entra/manifest.json, all owned by this
# deployer, so OwnedBy is a drop-in. .All would let the holder add a credential to ANY
# app or SP in the tenant - including one holding Global Administrator - which is a
# strictly larger blast radius than the Owner role this identity also holds.
#
# Policy.ReadWrite.ConditionalAccess is RETAINED deliberately, not an oversight: L3
# authors Conditional Access policies and needs it. It can also disable CA tenant-wide -
# a real, accepted risk recorded in the findings record's "Deferred" section
# (compliance/findings/2026-08-26-prepublication-review.md, bottom) rather than left
# unremarked in a code comment only.
$script:DeployerGraphRoles = [ordered]@{
    'User.ReadWrite.All'                  = '741f803b-c850-494e-b5df-cde7c675a1ca'
    'Group.ReadWrite.All'                 = '62a82d76-70ea-41e2-9197-370581804d09'
    'Application.ReadWrite.OwnedBy'       = '18a4783c-866b-4cc7-a460-3d5e5662c884'
    'Policy.ReadWrite.ConditionalAccess'  = '01c0a623-fc9b-48e9-b794-0756f8e8f067'
    'Directory.Read.All'                  = '7ab1d382-f21e-4acd-a863-ba3e13f7da61'
}
$script:VerifierGraphRoles = [ordered]@{
    'Directory.Read.All' = '7ab1d382-f21e-4acd-a863-ba3e13f7da61'
    'Policy.Read.All'    = '246dd0d5-5bd0-4def-940b-0421030a5b68' # audit CA policy state read-only
}

# --- plumbing --------------------------------------------------------------------------

function Write-Status {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
        Justification = 'Interactive bootstrap script; console output is the product.')]
    param(
        [Parameter(Mandatory)][string]$Message,
        [ConsoleColor]$Color = [ConsoleColor]::Gray
    )
    Write-Host $Message -ForegroundColor $Color
}

function Invoke-AzCli {
    <# Single choke point for every Azure CLI invocation (mocked in tests). #>
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [switch]$AllowFailure
    )
    $raw = & az @Arguments 2>$null
    if ($LASTEXITCODE -ne 0) {
        if ($AllowFailure) { return $null }
        throw "az $($Arguments -join ' ') failed with exit code $LASTEXITCODE"
    }
    $text = ($raw | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    return $text | ConvertFrom-Json
}

function Invoke-AzMutation {
    <# Every mutating az call flows through here so -WhatIf gates all writes. #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][string]$Action,
        [Parameter(Mandatory)][string[]]$Arguments
    )
    if ($PSCmdlet.ShouldProcess($Target, $Action)) {
        return Invoke-AzCli -Arguments $Arguments
    }
    return $null
}

function New-TempJsonFile {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)]$InputObject)
    $path = Join-Path ([IO.Path]::GetTempPath()) ("mls-{0}.json" -f ([guid]::NewGuid().ToString('N')))
    if ($PSCmdlet.ShouldProcess($path, 'Write temporary JSON payload')) {
        # -InputObject (not pipeline) so single-element arrays stay JSON arrays.
        ConvertTo-Json -InputObject $InputObject -Depth 10 | Set-Content -LiteralPath $path -Encoding utf8
    }
    return $path
}

# --- building blocks -------------------------------------------------------------------

function Assert-AzContext {
    param([Parameter(Mandatory)][string]$SubscriptionId)
    $account = Invoke-AzCli -Arguments @('account', 'show', '--output', 'json') -AllowFailure
    if (-not $account) {
        throw 'Azure CLI is not logged in. Run `az login` (as the tenant Global Administrator) and retry.'
    }
    if ($account.id -ne $SubscriptionId) {
        Invoke-AzCli -Arguments @('account', 'set', '--subscription', $SubscriptionId) | Out-Null
        $account = Invoke-AzCli -Arguments @('account', 'show', '--output', 'json')
    }
    return $account
}

function Get-AdApp {
    param([Parameter(Mandatory)][string]$DisplayName)
    $apps = Invoke-AzCli -Arguments @('ad', 'app', 'list', '--display-name', $DisplayName, '--output', 'json')
    $found = @($apps | Where-Object { $_ -and $_.displayName -eq $DisplayName })
    if ($found.Count -gt 1) {
        Write-Warning "Multiple app registrations named '$DisplayName' found; using the first (appId $($found[0].appId))."
    }
    if ($found.Count -ge 1) { return $found[0] }
    return $null
}

function Initialize-AdApp {
    <# Create-if-absent app registration; returns the app object (null under -WhatIf when absent). #>
    param([Parameter(Mandatory)][string]$DisplayName)
    $app = Get-AdApp -DisplayName $DisplayName
    if ($app) {
        Write-Status "App registration '$DisplayName' already exists (appId $($app.appId)) - reusing." -Color Green
        return $app
    }
    $app = Invoke-AzMutation -Target $DisplayName -Action 'Create app registration' -Arguments @(
        'ad', 'app', 'create',
        '--display-name', $DisplayName,
        '--sign-in-audience', 'AzureADMyOrg',
        '--output', 'json'
    )
    if ($app) { Write-Status "Created app registration '$DisplayName' (appId $($app.appId))." -Color Green }
    return $app
}

function Initialize-FederatedCredential {
    <# Create-if-absent / update-if-drifted federated identity credential, matched by subject. #>
    param(
        [Parameter(Mandatory)][string]$AppObjectId,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Subject
    )
    $desired = [ordered]@{
        name        = $Name
        issuer      = $script:GithubOidcIssuer
        subject     = $Subject
        description = "GitHub Actions OIDC ($Subject)"
        audiences   = @($script:OidcAudience)
    }
    $existing = Invoke-AzCli -Arguments @('ad', 'app', 'federated-credential', 'list', '--id', $AppObjectId, '--output', 'json')
    $current = @($existing | Where-Object { $_ -and $_.subject -eq $Subject })
    if ($current.Count -ge 1) {
        $cred = $current[0]
        $audienceOk = (@($cred.audiences) -contains $script:OidcAudience)
        if ($cred.issuer -eq $script:GithubOidcIssuer -and $audienceOk) {
            Write-Status "Federated credential for subject '$Subject' already correct - skipping." -Color Green
            return $cred
        }
        $payload = New-TempJsonFile -InputObject $desired -WhatIf:$false -Confirm:$false
        try {
            return Invoke-AzMutation -Target $Subject -Action 'Update federated identity credential' -Arguments @(
                'ad', 'app', 'federated-credential', 'update',
                '--id', $AppObjectId,
                '--federated-credential-id', $cred.id,
                '--parameters', "@$payload",
                '--output', 'json'
            )
        }
        finally { Remove-Item -LiteralPath $payload -ErrorAction SilentlyContinue -WhatIf:$false -Confirm:$false }
    }
    $payload = New-TempJsonFile -InputObject $desired -WhatIf:$false -Confirm:$false
    try {
        $created = Invoke-AzMutation -Target $Subject -Action 'Create federated identity credential' -Arguments @(
            'ad', 'app', 'federated-credential', 'create',
            '--id', $AppObjectId,
            '--parameters', "@$payload",
            '--output', 'json'
        )
        if ($created) { Write-Status "Created federated credential '$Name' for subject '$Subject'." -Color Green }
        return $created
    }
    finally { Remove-Item -LiteralPath $payload -ErrorAction SilentlyContinue -WhatIf:$false -Confirm:$false }
}

function Initialize-ServicePrincipal {
    <# Create-if-absent service principal for an app registration. #>
    param([Parameter(Mandatory)][string]$AppId)
    $sps = Invoke-AzCli -Arguments @('ad', 'sp', 'list', '--filter', "appId eq '$AppId'", '--output', 'json')
    $sp = @($sps | Where-Object { $_ })
    if ($sp.Count -ge 1) {
        Write-Status "Service principal for appId $AppId already exists - reusing." -Color Green
        return $sp[0]
    }
    $created = Invoke-AzMutation -Target $AppId -Action 'Create service principal' -Arguments @(
        'ad', 'sp', 'create', '--id', $AppId, '--output', 'json'
    )
    if ($created) { Write-Status "Created service principal for appId $AppId." -Color Green }
    return $created
}

function Initialize-RoleAssignment {
    <# Create-if-absent RBAC role assignment for a service principal at a scope. #>
    param(
        [Parameter(Mandatory)][string]$PrincipalObjectId,
        [Parameter(Mandatory)][string]$Role,
        [Parameter(Mandatory)][string]$Scope
    )
    $existing = Invoke-AzCli -Arguments @(
        'role', 'assignment', 'list',
        '--assignee', $PrincipalObjectId,
        '--role', $Role,
        '--scope', $Scope,
        '--output', 'json'
    )
    if (@($existing | Where-Object { $_ }).Count -ge 1) {
        Write-Status "Role '$Role' already assigned at $Scope - skipping." -Color Green
        return $existing[0]
    }
    $created = Invoke-AzMutation -Target "$Role @ $Scope" -Action 'Create role assignment' -Arguments @(
        'role', 'assignment', 'create',
        '--assignee-object-id', $PrincipalObjectId,
        '--assignee-principal-type', 'ServicePrincipal',
        '--role', $Role,
        '--scope', $Scope,
        '--output', 'json'
    )
    if ($created) { Write-Status "Assigned role '$Role' at $Scope." -Color Green }
    return $created
}

function Grant-GraphApplicationPermission {
    <#
        Ensure the app's requiredResourceAccess includes the given Microsoft Graph
        application roles (union with whatever is already declared - re-running never
        duplicates). Declaring permissions does NOT consent them; consent is a human
        click on the printed URL.
    #>
    param(
        [Parameter(Mandatory)][string]$AppObjectId,
        [Parameter(Mandatory)][hashtable]$Roles
    )
    $app = Invoke-AzCli -Arguments @('ad', 'app', 'show', '--id', $AppObjectId, '--output', 'json')
    $resourceAccess = @()
    $otherResources = @()
    if ($app.PSObject.Properties.Name -contains 'requiredResourceAccess' -and $app.requiredResourceAccess) {
        foreach ($rra in @($app.requiredResourceAccess)) {
            if ($rra.resourceAppId -eq $script:GraphResourceAppId) {
                $resourceAccess = @($rra.resourceAccess)
            }
            else {
                $otherResources += $rra
            }
        }
    }
    $existingIds = @($resourceAccess | ForEach-Object { $_.id })
    $missing = @($Roles.Keys | Where-Object { $existingIds -notcontains $Roles[$_] })
    if ($missing.Count -eq 0) {
        Write-Status 'All required Graph application permissions already declared - skipping.' -Color Green
        return $false
    }
    foreach ($name in $missing) {
        $resourceAccess += [pscustomobject]@{ id = $Roles[$name]; type = 'Role' }
    }
    $desired = @($otherResources) + @([pscustomobject]@{
            resourceAppId  = $script:GraphResourceAppId
            resourceAccess = @($resourceAccess)
        })
    $payload = New-TempJsonFile -InputObject $desired -WhatIf:$false -Confirm:$false
    try {
        Invoke-AzMutation -Target $AppObjectId -Action "Declare Graph application permissions: $($missing -join ', ')" -Arguments @(
            'ad', 'app', 'update',
            '--id', $AppObjectId,
            '--required-resource-accesses', "@$payload"
        ) | Out-Null
    }
    finally { Remove-Item -LiteralPath $payload -ErrorAction SilentlyContinue -WhatIf:$false -Confirm:$false }
    if (-not $WhatIfPreference) {
        Write-Status "Declared Graph application permissions: $($missing -join ', ')." -Color Green
    }
    return $true
}

function Get-GitHubSubClaimPrefix {
    <#
        WHAT SUBJECT WILL GITHUB ACTUALLY PRESENT? Ask it, do not construct it.

        This script used to register exactly one subject per app, built by hand as
        "repo:<owner>/<repo>:environment:<env>". On 2026-08-29 the first real OIDC
        login failed against a live tenant with:

          AADSTS700213: No matching federated identity record found for presented
          assertion subject
          'repo:paulcfuqua@51541817/azure-devsecops-demo@1347346268:environment:demo'

        GitHub now embeds IMMUTABLE ACTOR IDENTIFIERS -- the numeric owner id and
        repository id -- in the subject claim, so that renaming an org or repo cannot
        silently redirect a federated trust to someone else. The hand-built string is
        the old shape and no longer matches.

        GitHub reports the prefix it will use at
        GET /repos/{owner}/{repo}/actions/oidc/customization/sub, in `sub_claim_prefix`.
        Note that the tenant this was found on returned `use_immutable_subject: false`
        while still presenting the immutable form -- so DO NOT branch on that flag.
        Read the prefix and trust it.

        Returns $null when the field is absent or gh is unavailable; the caller then
        registers only the classic subject, which is the pre-2026-08-29 behaviour.
    #>
    param([Parameter(Mandatory)][string]$Repository)

    $raw = & gh api "repos/$Repository/actions/oidc/customization/sub" 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($raw)) {
        Write-Status "  (could not read GitHub's sub_claim_prefix for $Repository; registering the classic subject only)" -Color Yellow
        return $null
    }
    try { $parsed = $raw | ConvertFrom-Json } catch { return $null }
    $prefix = $parsed.sub_claim_prefix
    if ([string]::IsNullOrWhiteSpace($prefix)) { return $null }
    if ($prefix -eq "repo:$Repository") { return $null }   # same as the classic form
    return [string]$prefix
}

function Get-AdminConsentUrl {
    param(
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$AppId
    )
    return "https://login.microsoftonline.com/$TenantId/adminconsent?client_id=$AppId"
}

# --- main ------------------------------------------------------------------------------

function Invoke-Main {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$EnvironmentName,
        [string]$VerifierEnvironmentName = 'verify',
        [Parameter(Mandatory)][string]$DeployerAppName,
        [Parameter(Mandatory)][string]$VerifierAppName
    )
    $account = Assert-AzContext -SubscriptionId $SubscriptionId
    $tenantId = $account.tenantId
    $scope = "/subscriptions/$SubscriptionId"
    $consentUrls = [ordered]@{}

    Write-Status "Tenant $tenantId / subscription $SubscriptionId" -Color Cyan
    $script:ImmutableSubjectPrefix = Get-GitHubSubClaimPrefix -Repository $Repository
    if ($script:ImmutableSubjectPrefix) {
        Write-Status "GitHub presents immutable subjects: $($script:ImmutableSubjectPrefix) - registering both forms." -Color Gray
    }

    # ---- deployer -----------------------------------------------------------------
    Write-Status "`n== $DeployerAppName ==" -Color Cyan
    $deployer = Initialize-AdApp -DisplayName $DeployerAppName
    if ($deployer) {
        # Deliberately ONE credential, not two (2026-08-26 finding F7): a branch-ref
        # subject here would let any id-token:write job on main mint this identity's
        # Owner-capable subject while bypassing the demo environment's protection rules.
        Initialize-FederatedCredential -AppObjectId $deployer.id -Name "github-env-$EnvironmentName" `
            -Subject "repo:${Repository}:environment:$EnvironmentName" | Out-Null
        # ... and the immutable-identifier form, when GitHub says it will present one.
        # Both are registered rather than one replacing the other: GitHub is evidently
        # mid-transition (it reported use_immutable_subject=false while presenting the
        # immutable subject), and an app that accepts only the form GitHub happens to
        # send today breaks silently when that changes. Neither subject widens the
        # trust -- both name the same repository and the same `demo` environment, which
        # is the property F7 cares about.
        if ($script:ImmutableSubjectPrefix) {
            Initialize-FederatedCredential -AppObjectId $deployer.id -Name "github-env-$EnvironmentName-immutable" `
                -Subject "$($script:ImmutableSubjectPrefix):environment:$EnvironmentName" | Out-Null
        }
        $deployerSp = Initialize-ServicePrincipal -AppId $deployer.appId
        if ($deployerSp) {
            Initialize-RoleAssignment -PrincipalObjectId $deployerSp.id -Role 'Owner' -Scope $scope | Out-Null
        }
        else {
            Write-Status '(-WhatIf) Would assign Owner to the new service principal.' -Color Yellow
        }
        Grant-GraphApplicationPermission -AppObjectId $deployer.id -Roles ([hashtable]$script:DeployerGraphRoles) | Out-Null
        $consentUrls[$DeployerAppName] = Get-AdminConsentUrl -TenantId $tenantId -AppId $deployer.appId
    }
    else {
        Write-Status "(-WhatIf) Would then create a federated credential ($EnvironmentName), service principal, Owner assignment, and declare Graph permissions for '$DeployerAppName'." -Color Yellow
    }

    # ---- verifier -----------------------------------------------------------------
    Write-Status "`n== $VerifierAppName ==" -Color Cyan
    $verifier = Initialize-AdApp -DisplayName $VerifierAppName
    if ($verifier) {
        # Its OWN credential on its OWN environment (2026-08-26 findings F6/F7) - never
        # $EnvironmentName. Reusing the deployer's subject here is exactly what would let
        # a verify job mint a token that authenticates as the Owner-capable deployer
        # instead of this Reader-scoped identity.
        Initialize-FederatedCredential -AppObjectId $verifier.id -Name "github-env-$VerifierEnvironmentName" `
            -Subject "repo:${Repository}:environment:$VerifierEnvironmentName" | Out-Null
        if ($script:ImmutableSubjectPrefix) {
            Initialize-FederatedCredential -AppObjectId $verifier.id -Name "github-env-$VerifierEnvironmentName-immutable" `
                -Subject "$($script:ImmutableSubjectPrefix):environment:$VerifierEnvironmentName" | Out-Null
        }
        $verifierSp = Initialize-ServicePrincipal -AppId $verifier.appId
        if ($verifierSp) {
            Initialize-RoleAssignment -PrincipalObjectId $verifierSp.id -Role 'Reader' -Scope $scope | Out-Null
        }
        else {
            Write-Status '(-WhatIf) Would assign Reader to the new service principal.' -Color Yellow
        }
        Grant-GraphApplicationPermission -AppObjectId $verifier.id -Roles ([hashtable]$script:VerifierGraphRoles) | Out-Null
        $consentUrls[$VerifierAppName] = Get-AdminConsentUrl -TenantId $tenantId -AppId $verifier.appId
    }
    else {
        Write-Status "(-WhatIf) Would then create a federated credential ($VerifierEnvironmentName), service principal, Reader assignment, and declare Directory.Read.All + Policy.Read.All for '$VerifierAppName'." -Color Yellow
    }

    # ---- consent instructions (NEVER automated) ------------------------------------
    #
    # THE BROWSER URL BELOW FAILS ON A FRESH APP, and this script used to print only
    # that (finding F46). The /adminconsent endpoint redirects back to a reply address
    # after you approve, and neither app registration has one -- nor should it, since
    # both are daemon identities that never sign a user in. The result is:
    #
    #   AADSTS500113: No reply address is registered for the application.
    #
    # `az ad app permission admin-consent` grants the same consent through Graph with
    # no redirect involved, so it is printed FIRST as the path that works. The URL is
    # kept because it is what the Azure portal shows and someone will look for it, but
    # it now carries the warning it needed.
    Write-Status "`n== ACTION REQUIRED: admin consent (this script never consents for you) ==" -Color Yellow
    if ($consentUrls.Count -eq 0) {
        Write-Status '(-WhatIf) Consent commands will be printed on a real run once the apps exist.' -Color Yellow
    }
    if ($consentUrls.Count -gt 0) {
        Write-Status '  Run these (works without a redirect URI):' -Color Yellow
        foreach ($name in $consentUrls.Keys) {
            $appId = ($consentUrls[$name] -split 'client_id=')[-1]
            Write-Status "    az ad app permission admin-consent --id $appId   # $name" -Color Yellow
        }
        Write-Status "`n  The portal consent URLs, for reference. These return AADSTS500113 (`"no reply" -Color DarkGray
        Write-Status '  address is registered") unless you add a redirect URI these daemon apps do' -Color DarkGray
        Write-Status '  not otherwise need -- prefer the commands above:' -Color DarkGray
    }
    foreach ($name in $consentUrls.Keys) {
        Write-Status "    ${name}: $($consentUrls[$name])" -Color DarkGray
    }
    Write-Status "`nManual step for $VerifierAppName (Get-Label audits, L4/L11 - not scripted here):" -Color Yellow
    Write-Status @"
  In the Microsoft Purview / Security & Compliance portal, grant '$VerifierAppName'
  app-only access to Security & Compliance PowerShell: assign the Office 365
  Exchange Online 'Exchange.ManageAsApp' application permission to the app, then add
  its service principal to the 'View-Only Configuration' S&C role group. This keeps
  the verifier strictly read-only while allowing Connect-IPPSSession -CertificateThumbprint
  audits of the label taxonomy.
"@
    Write-Status "`nNext: record the deployer appId as GitHub environment variable AZURE_CLIENT_ID (see docs/runbooks/g0-bootstrap.md)." -Color Cyan

    return [pscustomobject]@{
        TenantId       = $tenantId
        SubscriptionId = $SubscriptionId
        DeployerApp    = $deployer
        VerifierApp    = $verifier
        ConsentUrls    = $consentUrls
    }
}

function Resolve-RepositoryInput {
    <# -Repository, then MLS_GITHUB_REPO / MLS_REPOSITORY, then a hard stop. Never a
       built-in default: see the -Repository parameter comment for why guessing here is
       a security problem rather than a convenience. #>
    param([AllowEmptyString()][string]$Value)
    if (-not [string]::IsNullOrWhiteSpace($Value)) { return $Value }
    foreach ($name in @('MLS_GITHUB_REPO', 'MLS_REPOSITORY')) {
        $fromEnvironment = [Environment]::GetEnvironmentVariable($name)
        if (-not [string]::IsNullOrWhiteSpace($fromEnvironment)) { return $fromEnvironment }
    }
    throw @'
No GitHub repository was supplied, and this script will not guess one.

The federated credentials it creates decide WHICH REPOSITORY IS TRUSTED to deploy into
your Azure subscription. Defaulting that to the upstream repo would silently grant a
repository you do not control the ability to authenticate as your deployer identity.

Pass your own fork/repo explicitly:

    ./01-root-oidc.ps1 -SubscriptionId <sub> -Repository <owner>/<repo>

or set $env:MLS_GITHUB_REPO first.
'@
}

if (-not $env:MLS_SKIP_MAIN) {
    $resolvedRepository = Resolve-RepositoryInput -Value $Repository
    Invoke-Main -SubscriptionId $SubscriptionId -Repository $resolvedRepository -EnvironmentName $EnvironmentName `
        -VerifierEnvironmentName $VerifierEnvironmentName -DeployerAppName $DeployerAppName -VerifierAppName $VerifierAppName
}
