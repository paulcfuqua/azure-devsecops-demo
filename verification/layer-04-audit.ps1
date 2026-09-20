#Requires -Version 7.0
<#
.SYNOPSIS
    L4 Verifier audit - Purview sensitivity labels. READ-ONLY.

.DESCRIPTION
    Implements the two master-plan Verify criteria owned by
    docs/runbooks/layers/L04.md section Validation cycle, and nothing else:

      V4.1  Get-Label returns the 6 labels with expected GUIDs recorded to
            verification/reports/.
      V4.2  Labels survive a kill/rebuild cycle (checked again at L11).
      V4.4  Table protection ARTEFACTS - the column DENYs exist and the row-level
            security policy is ENABLED.
      V4.5  Table protection ENFORCEMENT - the standard tier is actually refused. This
            one reports SKIP and says why: EXECUTE AS is not supported on a Fabric
            lakehouse SQL analytics endpoint (Msg 15868), so the refusal cannot be
            provoked from a read-only audit by ANY caller. V4.4 does not stand in for
            it - a criterion that cannot look must never report the control present.

    V4.2 is a checkpoint comparison, not a second query: L04 owns the criterion, L11 owns
    the re-execution schedule, so layer-11-audit.ps1 runs this same script with
    -Checkpoint 'post-down' and again with -Checkpoint 'post-up'. Any GUID delta after
    down.ps1 means the teardown path touched tenant objects - stop-the-line.

    V4.3 is a supplementary criterion, NOT in the master plan's 43-row list (same
    convention as V6.5 / CP-9): the label policy that scopes the taxonomy to the demo
    groups exists and is scoped as L04.md:53 describes. Added closing F18 - a label
    with no published policy cannot be applied to anything and enforces nothing, and
    V4.1/V4.2 only ever checked label existence, so that gap was invisible to this
    audit until now. L04.md's own Failure mode 5 already anticipated this exact
    supplementary check (`Get-LabelPolicy | Select -Expand ExchangeLocation`).

    The S&C session is READ-ONLY BY DESIGN, and as of 2026-09-03 it does not open at all:
    mls-verifier is MEANT to hold Exchange.ManageAsApp with a read-only compliance role,
    but G0 never granted either and the tenant refuses the session with UnAuthorized
    (F177). That is a human grant, not a code defect - g0-bootstrap.md step 11d - and this
    audit fails rather than skipping, because a green job that audited nothing is what hid
    the problem for the life of the project (F175).

.EXAMPLE
    ./layer-04-audit.ps1 -Organization contoso.onmicrosoft.com
#>
[CmdletBinding()]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'CertificatePassword',
    Justification = 'A Security and Compliance certificate password arrives from a GitHub Actions secret as an environment variable, which is a plain string before this code ever sees it. SecureString would not protect it: on .NET for Linux - and CI is ubuntu-latest - SecureString is not encrypted at all, and the -CertificatePassword parameter takes it back to plain text to open the PFX regardless. The value is never logged, and the PFX is deleted by the cleanup step in the job that staged it.')]
param(
    [string]$Organization,
    [string]$VerifierAppId,
    # Windows only - Connect-IPPSSession gates -CertificateThumbprint on $IsWindows (F176).
    [string]$CertificateThumbprint,
    # The path CI uses: accepted on every platform.
    [string]$CertificateFilePath,
    [string]$CertificatePassword,
    # Empty resolves to the prefixed taxonomy read from infra/bicep/naming.bicep
    # (F32): the labels are named <prefix>-public/-internal/-confidential/
    # -export-controlled, never the bare words, so this audit can never be pointed at
    # an adopter's own 'Confidential'.
    [string[]]$ExpectedLabel = @(),
    [string]$LabelGuidPath,
    [ValidateSet('layer', 'post-down', 'post-up')][string]$Checkpoint = 'layer',
    [string]$ReportRoot,
    [switch]$NoRetry,
    # Empty resolves to '<prefix>-demo-label-policy'.
    [string]$ExpectedLabelPolicy = '',
    # 'All', NOT FOUR GROUP NAMES (F121). The policy used to be published to four demo
    # groups and never could be: `-ExchangeLocation` takes a RECIPIENT, and L3 creates
    # pure security groups - mailEnabled=False, no mail address - which Security &
    # Compliance cannot resolve however correct the name is. The first real L4 run failed
    # with `The specified recipient "mls-flight-operations" couldn't be found`, and this
    # expectation would then have failed the criterion on its own fix. See
    # Get-LabelPolicyScope in infra/purview/labels.ps1 for why All was chosen over making
    # the groups mail-enabled.
    [string[]]$ExpectedLabelPolicyScope = @('All'),
    # Run only these criteria (e.g. -OnlyCriterion V4.2). Everything else reports SKIP
    # naming the reason, and the run exits 3 - a DIAGNOSTIC, never a sign-off (P-10).
    [string[]]$OnlyCriterion = @(),

    # V4.4 reads the lakehouse SQL analytics endpoint for the table-protection artefacts.
    # RESOLVED by the caller from the Fabric API, never stored: it regenerates on every
    # rebuild (F129's class). Absent means V4.4 reports UNOBSERVABLE, never a pass.
    [string]$SqlEndpoint,
    [string]$SqlAccessToken,
    [string]$LakehouseName = 'mls_operations',
    # Empty resolves the same way every other reader in this estate resolves it.
    [string]$ProtectionPrefix = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'MlsAudit.psm1') -Force

function Get-CompanyPrefix {
    <#
    .SYNOPSIS
        Reads `defaultCompanyPrefix` out of infra/bicep/naming.bicep - the same helper,
        parsed the same way, as infra/purview/labels.ps1's and scripts/down.ps1's.
    .DESCRIPTION
        F32's own defect. The taxonomy this audit checks used to be the bare words
        'Public', 'Internal', 'Confidential', 'Export-Controlled'; labels.ps1 now
        creates <prefix>-prefixed names, and an audit that still looked for the bare
        words would match an ADOPTER'S OWN labels and report a healthy demo built out
        of somebody else's taxonomy. Reader-only script, so it refuses rather than
        guessing.
    #>
    param([string]$Path = (Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath 'infra' -AdditionalChildPath 'bicep', 'naming.bicep'))
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Cannot resolve the label-name prefix: '$Path' does not exist. Names come from infra/bicep/naming.bicep and nowhere else (CLAUDE.md). Run this audit from a clone of the repository, or pass -ExpectedLabel explicitly."
    }
    # MLS_COMPANY_PREFIX FIRST, naming.bicep SECOND. naming.bicep holds the DEFAULT;
    # estate.env (locally) and the `demo` GitHub environment (in CI) override it. A
    # resolver that reads only the file disagrees with every one that honours the
    # override, and the estate splits down the middle - Azure named acme-*, these
    # names still mls-* (F91).
    if (-not [string]::IsNullOrWhiteSpace($env:MLS_COMPANY_PREFIX)) {
        return $env:MLS_COMPANY_PREFIX
    }

    $content = Get-Content -LiteralPath $Path -Raw
    $match = [regex]::Match($content, "var\s+defaultCompanyPrefix\s*=\s*'([^']+)'")
    if (-not $match.Success) {
        throw "Could not parse 'defaultCompanyPrefix' out of '$Path'."
    }
    return $match.Groups[1].Value
}

function Get-ExpectedLabelName {
    <# The prefixed six-label taxonomy infra/purview/labels.ps1 creates, in the same
       lowest-to-highest order. Kept as a literal list here, mirroring that script's
       own Get-LabelTaxonomy, for the reason it gives: a read-only audit importing
       another layer's apply script is a bigger coupling than one six-item list. #>
    param([Parameter(Mandatory)][string]$Prefix)
    return @(
        "$Prefix-public", "$Prefix-internal", "$Prefix-confidential", "$Prefix-export-controlled",
        # The two tiered-access labels. They CLASSIFY the mixed-sensitivity tables;
        # they do not gate access to them - that is CLS/RLS at the data layer, and
        # no criterion here may assert otherwise (F18).
        "$Prefix-hr-sensitive", "$Prefix-3ppi"
    )
}

function Get-LabelSnapshot {
    <# One read of the six labels, normalised to name -> guid. #>
    param([Parameter(Mandatory)][string[]]$ExpectedLabel)
    $labels = @(Get-MlsLabel)
    $relevant = @($labels | Where-Object { (Get-MlsProperty -InputObject $_ -Name 'DisplayName') -in $ExpectedLabel })
    $map = [ordered]@{}
    foreach ($label in ($relevant | Sort-Object { Get-MlsProperty -InputObject $_ -Name 'DisplayName' })) {
        $map["$(Get-MlsProperty -InputObject $label -Name 'DisplayName')"] = "$(Get-MlsProperty -InputObject $label -Name 'Guid')"
    }
    return $map
}

function Get-RecordedLabelGuid {
    <# The baseline recorded at first L4 run (labels.ps1 commits it via PR). #>
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $document = Get-MlsJsonFile -Path $Path -Purpose 'recorded label GUID baseline'
    $map = [ordered]@{}
    foreach ($property in $document.PSObject.Properties) { $map["$($property.Name)"] = "$($property.Value)" }
    return $map
}

function Test-LabelTaxonomy {
    <# V4.1 - exactly the six labels; GUIDs equal to the recorded baseline when one exists. #>
    param(
        [Parameter(Mandatory)][string[]]$ExpectedLabel,
        [AllowNull()]$Baseline,
        [Parameter(Mandatory)]$Context
    )
    $snapshot = Get-LabelSnapshot -ExpectedLabel $ExpectedLabel
    $Context.Evidence['labelGuids'] = $snapshot
    $comparison = Test-MlsSetEquality -Actual @($snapshot.Keys) -Expected $ExpectedLabel
    $describe = (@($snapshot.Keys) | ForEach-Object { "$_=$($snapshot[$_])" }) -join '; '
    if (-not $comparison.Equal) {
        return New-MlsCheckResult -Passed $false `
            -Observed "labels present: [$describe]; missing [$($comparison.Missing -join ', ')]; extra [$($comparison.Extra -join ', ')]" `
            -Detail 'Label replication across S&C endpoints can lag; the standard 30-minute window applies (L04.md V4.1).'
    }
    if ($null -eq $Baseline) {
        return New-MlsCheckResult -Passed $true -Observed $describe `
            -Detail 'No recorded baseline yet: these GUIDs are this run''s first-run record (the "recorded to verification/reports/" half of the criterion). They are in this report''s JSON sibling under evidence.labelGuids - commit them to verification/reports/label-guids.json so every later run compares.'
    }
    $mismatch = @($snapshot.Keys | Where-Object { $Baseline.Contains($_) -and $Baseline[$_] -ne $snapshot[$_] })
    $absent = @($snapshot.Keys | Where-Object { -not $Baseline.Contains($_) })
    if ($mismatch.Count -gt 0) {
        return New-MlsCheckResult -Passed $false `
            -Observed ("GUID drift: " + (($mismatch | ForEach-Object { "$_ recorded=$($Baseline[$_]) observed=$($snapshot[$_])" }) -join '; ')) `
            -Detail 'A changed GUID means a label was deleted and recreated, which only a G3 action could legitimately do. Do NOT re-baseline the JSON - escalate with Search-UnifiedAuditLog -Operations DeleteLabel (L04.md Rollback).' -Final
    }
    $detail = ''
    if ($absent.Count -gt 0) { $detail = "labels not present in the baseline file: $($absent -join ', ')" }
    return New-MlsCheckResult -Passed $true -Observed $describe -Detail $detail
}

function Test-LabelPersistence {
    <# V4.2 - the same read, compared at a named checkpoint against the recorded GUIDs.
       Persistence is binary, so there is nothing to wait for. #>
    param(
        [Parameter(Mandatory)][string[]]$ExpectedLabel,
        [AllowNull()]$Baseline,
        [Parameter(Mandatory)][string]$Checkpoint
    )
    if ($null -eq $Baseline) {
        return New-MlsCheckResult -Status 'SKIP' `
            -Observed "no recorded baseline at the '$Checkpoint' checkpoint" `
            -Detail 'V4.2 compares label GUIDs across checkpoints and needs verification/reports/label-guids.json, written on the first L4 run. Without it survival cannot be asserted, only label presence (V4.1).'
    }
    $snapshot = Get-LabelSnapshot -ExpectedLabel $ExpectedLabel
    $comparison = Test-MlsSetEquality -Actual @($snapshot.Keys) -Expected $ExpectedLabel
    $drift = @($snapshot.Keys | Where-Object { $Baseline.Contains($_) -and $Baseline[$_] -ne $snapshot[$_] })
    if ($comparison.Equal -and $drift.Count -eq 0) {
        return New-MlsCheckResult -Passed $true `
            -Observed "checkpoint '$Checkpoint': same 6 labels, same GUIDs as the recorded baseline" `
            -Detail 'L11 re-executes this criterion immediately after down.ps1 and again after up.ps1 (V11.2 invokes it by reference).'
    }
    return New-MlsCheckResult -Passed $false `
        -Observed "checkpoint '$Checkpoint': missing [$($comparison.Missing -join ', ')] extra [$($comparison.Extra -join ', ')] guid-drift [$($drift -join ', ')]" `
        -Detail 'Any delta post-down.ps1 means the teardown path touched tenant objects - a critical defect in down.ps1, stop-the-line (L04.md V4.2).' -Final
}

function Test-LabelPolicyScope {
    <#
        V4.3 - supplementary, not a master-plan criterion (L04.md's Validation cycle
        section and README.md's traceability-table header both say so explicitly - same
        convention CP-9's V6.5 uses). The policy named by $PolicyName exists and
        publishes exactly $ExpectedLabel, scoped to exactly $ExpectedScope. This is the
        check L04.md's own Failure mode 5 already promised
        (`Get-LabelPolicy | Select -Expand ExchangeLocation`) and is what makes F18's
        fix auditable: V4.1 only ever proved the labels exist, never that anyone could
        apply them.
    #>
    param(
        [Parameter(Mandatory)][string]$PolicyName,
        [Parameter(Mandatory)][string[]]$ExpectedLabel,
        [Parameter(Mandatory)][string[]]$ExpectedScope
    )
    $policy = Get-MlsLabelPolicy -Identity $PolicyName
    if ($null -eq $policy) {
        return New-MlsCheckResult -Passed $false `
            -Observed "label policy '$PolicyName' not found" `
            -Detail 'A published policy is what actually lets anyone apply a label - without it the six labels are directory objects with no protection action (L04.md Deploy procedure step 1; F18).'
    }
    $actualLabel = @(Get-MlsProperty -InputObject $policy -Name 'Labels')
    $actualScope = @(Get-MlsProperty -InputObject $policy -Name 'ExchangeLocation')
    $labelComparison = Test-MlsSetEquality -Actual $actualLabel -Expected $ExpectedLabel
    $scopeComparison = Test-MlsSetEquality -Actual $actualScope -Expected $ExpectedScope
    $describe = "Labels=[$($actualLabel -join ', ')] ExchangeLocation=[$($actualScope -join ', ')]"
    if (-not $labelComparison.Equal -or -not $scopeComparison.Equal) {
        return New-MlsCheckResult -Passed $false -Observed $describe `
            -Detail ("label policy scoping error (L04.md Failure mode 5): labels missing [$($labelComparison.Missing -join ', ')] extra [$($labelComparison.Extra -join ', ')]; " +
                "scope missing [$($scopeComparison.Missing -join ', ')] extra [$($scopeComparison.Extra -join ', ')]")
    }
    return New-MlsCheckResult -Passed $true -Observed $describe
}

function Test-TableProtectionArtefact {
    <#
    .SYNOPSIS
        V4.4 - the CLS and RLS objects exist, and the policy is ENABLED.
    .DESCRIPTION
        This is the ARTEFACT half and it says so. It proves the objects are there; it does
        not prove anyone is actually refused - see Test-TableProtectionEnforcement for why
        that cannot be observed from here, and why this criterion does not quietly stand in
        for it.

        `is_enabled` is the part that earns its place. A security policy created with
        STATE = OFF exists, appears in sys.security_policies, reads as healthy to anything
        counting rows in that view, and filters nothing at all - F119's class, a thing
        present but not switched on.
    #>
    param(
        [AllowEmptyString()][string]$SqlEndpoint,
        [AllowEmptyString()][AllowNull()][string]$SqlAccessToken,
        [Parameter(Mandatory)][string]$LakehouseName,
        [Parameter(Mandatory)][string]$Prefix,
        [Parameter(Mandatory)][string[]]$RestrictedColumn
    )
    if ([string]::IsNullOrWhiteSpace($SqlEndpoint)) {
        return New-MlsCheckResult -Passed $false `
            -Observed 'UNOBSERVABLE: no SQL analytics endpoint was supplied' `
            -Detail 'Pass -SqlEndpoint (resolved from the Fabric API, never stored). Without it this criterion cannot look, and it reports that rather than reporting the protection absent (F105).' -Final
    }

    $standard = "${Prefix}_data_standard"
    try {
        # ESTABLISH THAT WE CAN SEE BEFORE READING ANYTHING INTO WHAT WE SAW.
        # sys.database_permissions returns an EMPTY SET, not an error, to a caller that
        # may not read other principals' permissions - and mls-verifier holds workspace
        # Viewer, which is exactly the kind of identity that might not. Empty would then
        # mean "no DENY exists" and this criterion would FAIL a correctly protected
        # estate with a confident, specific, wrong answer. That is F105's shape.
        #
        # Every database has built-in roles (public, db_owner, ...), so a caller that can
        # see principals at all sees several. Zero means we are blind, not that the estate
        # is unprotected.
        $visibleRole = @(Invoke-MlsSqlQuery -ServerName $SqlEndpoint -DatabaseName $LakehouseName `
                -AccessToken $SqlAccessToken `
                -Query "SELECT COUNT(*) AS n FROM sys.database_principals WHERE type = 'R'")
        $roleCount = 0
        if ($visibleRole.Count -gt 0) { $roleCount = [int](Get-MlsProperty -InputObject $visibleRole[0] -Name 'n') }
        if ($roleCount -le 0) {
            return New-MlsCheckResult -Passed $false `
                -Observed 'UNOBSERVABLE: this identity cannot enumerate database principals, so an empty permission set cannot be distinguished from an unprotected table' `
                -Detail 'sys.database_permissions answers a caller without visibility with an empty set rather than a denial (F105''s shape). Every database has built-in roles, so seeing none means this identity is blind here - grant it visibility, or run V4.4 as the deployer. It reports that it could not look, never that the protection is missing.' -Final
        }

        $permissions = @(Invoke-MlsSqlQuery -ServerName $SqlEndpoint -DatabaseName $LakehouseName `
                -AccessToken $SqlAccessToken -Query @"
SELECT dp.name AS principal, pm.permission_name AS permission, pm.state_desc AS state,
       OBJECT_NAME(pm.major_id) AS object_name, c.name AS column_name
FROM sys.database_permissions pm
JOIN sys.database_principals dp ON dp.principal_id = pm.grantee_principal_id
LEFT JOIN sys.columns c ON c.object_id = pm.major_id AND c.column_id = pm.minor_id
WHERE dp.name = '$standard' AND pm.state_desc = 'DENY'
"@)
        $policies = @(Invoke-MlsSqlQuery -ServerName $SqlEndpoint -DatabaseName $LakehouseName `
                -AccessToken $SqlAccessToken `
                -Query "SELECT name, is_enabled FROM sys.security_policies WHERE name = 'sp_defect_tier'")
    } catch {
        return New-MlsCheckResult -Passed $false `
            -Observed "UNOBSERVABLE: the SQL analytics endpoint could not be read - $($_.Exception.Message)" `
            -Detail 'The endpoint refused or failed, so this criterion cannot distinguish "the protection is missing" from "could not look". It reports that it could not look (F105).' -Final
    }

    $deniedColumn = @($permissions |
            Where-Object { "$(Get-MlsProperty -InputObject $_ -Name 'object_name')" -eq 'hr_roster' } |
            ForEach-Object { "$(Get-MlsProperty -InputObject $_ -Name 'column_name')" })
    $deniedObject = @($permissions |
            Where-Object { [string]::IsNullOrEmpty("$(Get-MlsProperty -InputObject $_ -Name 'column_name')") } |
            ForEach-Object { "$(Get-MlsProperty -InputObject $_ -Name 'object_name')" })

    $problems = [System.Collections.Generic.List[string]]::new()
    foreach ($column in $RestrictedColumn) {
        if ($column -notin $deniedColumn) { $problems.Add("hr_roster.$column carries no DENY for $standard") }
    }
    if ('defect_reports' -notin $deniedObject) {
        $problems.Add("the unfiltered base table defect_reports carries no DENY for $standard, so the filtered view is not the only door")
    }
    if ($policies.Count -eq 0) {
        $problems.Add('the security policy sp_defect_tier does not exist')
    }
    else {
        $enabled = Get-MlsProperty -InputObject $policies[0] -Name 'is_enabled'
        if (-not [bool]$enabled) {
            $problems.Add('the security policy sp_defect_tier exists but is NOT enabled, so it filters nothing')
        }
    }

    $describe = "DENY columns on hr_roster: [$($deniedColumn -join ', ')]; DENY objects: [$($deniedObject -join ', ')]; sp_defect_tier: $(if ($policies.Count) { "enabled=$(Get-MlsProperty -InputObject $policies[0] -Name 'is_enabled')" } else { 'absent' })"
    if ($problems.Count -gt 0) {
        return New-MlsCheckResult -Passed $false -Observed "$($problems -join '; ') -- $describe" `
            -Detail 'Re-run layer-04-purview.yml''s protect job, which applies infra/fabric/protect-tables.ps1. Every statement is guarded and safe to replay.' -Final
    }
    return New-MlsCheckResult -Passed $true -Observed $describe
}

function Test-TableProtectionEnforcement {
    <#
    .SYNOPSIS
        V4.5 - does the standard tier ACTUALLY get refused? Not observable here, and this
        records that rather than passing on the artefact.
    .DESCRIPTION
        THE CRITERION THIS ESTATE WOULD MOST LIKE TO HAVE, AND CANNOT. Asserting the
        capability rather than the artefact is the rule this repository keeps re-learning -
        break-glass readiness meant "an account is in the group" and passed on one holding
        no role; V3.3 meant "an enabled CA policy exists" and failed on a tenant whose MFA
        came from Security Defaults. So V4.4 checking that a DENY row exists is exactly the
        kind of proxy that is right until the day it matters.

        The direct check is `EXECUTE AS USER = <a member of the standard role>`, then read
        `salary_usd` and require a permission error. **A Fabric lakehouse SQL analytics
        endpoint does not support EXECUTE AS at all** - Msg 15868, verified live
        2026-09-20, and it is a feature-level refusal rather than a permission one, so no
        credential makes it work. There is also nothing to impersonate: the endpoint's only
        database users are dbo, guest, sys and INFORMATION_SCHEMA, and a database ROLE is
        not a user.

        The remaining route is to CONNECT as a principal that is a member of the standard
        role and be refused. mls-verifier cannot be that principal: V5.3 asserts
        defect_reports holds exactly 900 rows, and a verifier inside the standard tier
        would see the filtered subset and fail a correct estate.

        So this reports SKIP, names the blocker, and names where the capability IS
        observable: the two-tier agent path, where the standard tier's own identity asks
        for salary through the tool chain and is refused by the database. That belongs to
        the agent-tiering work, not here. SKIP rather than PASS, because a criterion that
        cannot look must never report the control present (F102/F103/F105).
    #>
    param([Parameter(Mandatory)][string]$Prefix)
    return New-MlsCheckResult -Status 'SKIP' `
        -Observed 'UNOBSERVABLE from a read-only audit: EXECUTE AS is not supported on a Fabric lakehouse SQL analytics endpoint (Msg 15868, verified 2026-09-20)' `
        -Detail "The refusal cannot be provoked from here for ANY caller - Msg 15868 is a feature-level refusal, not a permission error - and the endpoint exposes no impersonable user (dbo, guest, sys, INFORMATION_SCHEMA only; a database role is not a user). mls-verifier cannot join ${Prefix}_data_standard to test it either, because V5.3 requires it to see all 900 defect_reports rows and a member of the standard tier sees the filtered subset. The capability is observable end to end on the two-tier agent path, where the standard tier's identity is refused by the database; that criterion belongs with the agent tiering. V4.4 covers the artefact and does not stand in for this."
}

function Invoke-Main {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
        Justification = 'Every parameter is consumed inside the criterion scriptblocks; PSSA cannot see through scriptblock closures.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'CertificatePassword',
        Justification = 'A Security and Compliance certificate password arrives from a GitHub Actions secret as an environment variable, which is a plain string before this code ever sees it. SecureString would not protect it: on .NET for Linux - and CI is ubuntu-latest - SecureString is not encrypted at all, and the -CertificatePassword parameter takes it back to plain text to open the PFX regardless. The value is never logged, and the PFX is deleted by the cleanup step in the job that staged it.')]
    param(
        [string]$Organization,
        [string]$VerifierAppId,
        [string]$CertificateThumbprint,
        [string]$CertificateFilePath,
        [string]$CertificatePassword,
        [string[]]$ExpectedLabel = @(),
        [string]$LabelGuidPath,
        [string]$Checkpoint = 'layer',
        [string]$ReportRoot,
        [switch]$NoRetry,
        [switch]$SkipConnect,
        [string]$ExpectedLabelPolicy = '',
        [string[]]$ExpectedLabelPolicyScope = @('All'),
        [string[]]$OnlyCriterion = @(),
        [string]$SqlEndpoint = '',
        [string]$SqlAccessToken = '',
        [string]$LakehouseName = 'mls_operations',
        [string]$ProtectionPrefix = ''
    )
    $repoRoot = Split-Path -Path $PSScriptRoot -Parent
    # Resolved here rather than as a parameter default so naming.bicep is read once,
    # at run time, and an explicit -ExpectedLabel / -ExpectedLabelPolicy still wins
    # (F32). Both names are prefixed; neither is ever the bare word.
    if (@($ExpectedLabel).Count -eq 0 -or [string]::IsNullOrWhiteSpace($ExpectedLabelPolicy)) {
        $companyPrefix = Get-CompanyPrefix
        if (@($ExpectedLabel).Count -eq 0) { $ExpectedLabel = Get-ExpectedLabelName -Prefix $companyPrefix }
        if ([string]::IsNullOrWhiteSpace($ExpectedLabelPolicy)) { $ExpectedLabelPolicy = "$companyPrefix-demo-label-policy" }
    }
    $organizationName = Resolve-MlsInput -Name 'Organization' -Value $Organization `
        -EnvironmentVariable @('TENANT_DOMAIN', 'MLS_TENANT_DOMAIN') `
        -Hint 'Connect-IPPSSession needs the tenant domain; the S&C endpoint has no other way to find the tenant.'
    $appId = Resolve-MlsInput -Name 'VerifierAppId' -Value $VerifierAppId -EnvironmentVariable @('MLS_VERIFIER_APP_ID') `
        -Hint 'App-only S&C auth for mls-verifier (Exchange.ManageAsApp + View-Only Configuration, granted at G0).'
    # EITHER credential form, but at least one - and the FILE is the one CI uses, because
    # -CertificateThumbprint is a Windows-only dynamic parameter of Connect-IPPSSession and
    # every runner here is ubuntu-latest (F176; see Connect-MlsCompliance).
    #
    # Read DIRECTLY, not through Resolve-MlsInput: that helper THROWS when it resolves to
    # nothing, and an empty -DefaultValue does not make it optional (it treats empty as "no
    # default supplied"). These three are optional INDIVIDUALLY and required as a SET, so
    # the check that matters is the one below - which can then name both ways to satisfy it
    # instead of failing on whichever happened to be resolved first.
    $certificateFile = if (-not [string]::IsNullOrWhiteSpace($CertificateFilePath)) { $CertificateFilePath } else { "$env:MLS_VERIFIER_CERT_PATH" }
    $certificatePassword = if (-not [string]::IsNullOrWhiteSpace($CertificatePassword)) { $CertificatePassword } else { "$env:MLS_VERIFIER_CERT_PASSWORD" }
    $thumbprint = if (-not [string]::IsNullOrWhiteSpace($CertificateThumbprint)) { $CertificateThumbprint } else { "$env:MLS_VERIFIER_CERT" }
    if (-not $SkipConnect -and [string]::IsNullOrWhiteSpace($certificateFile) -and [string]::IsNullOrWhiteSpace($thumbprint)) {
        throw "Required input 'CertificateFilePath' was not supplied. L4 opens its own read-only Security & Compliance session as mls-verifier and S&C PowerShell has no federated path, so it needs a certificate. Set -CertificateFilePath / `$env:MLS_VERIFIER_CERT_PATH to the PFX (preferred - it is the only form that works on Linux, and CI is ubuntu-latest), or -CertificateThumbprint / `$env:MLS_VERIFIER_CERT on Windows."
    }
    $baselinePath = Resolve-MlsInput -Name 'LabelGuidPath' -Value $LabelGuidPath -EnvironmentVariable @('MLS_LABEL_GUID_PATH') `
        -DefaultValue (Join-Path -Path $repoRoot -ChildPath 'verification' -AdditionalChildPath 'reports', 'label-guids.json') `
        -Hint 'Recorded label GUID baseline.'

    $context = New-MlsAuditContext -Layer 4 -Title 'Purview sensitivity labels' `
        -ScriptName 'verification/layer-04-audit.ps1' -ReportRoot $ReportRoot -NoRetry:$NoRetry `
        -OnlyCriterion $OnlyCriterion
    Add-MlsPreflight -Context $context -Name 'Organization' -Value $organizationName
    Add-MlsPreflight -Context $context -Name 'Checkpoint' -Value $Checkpoint
    Add-MlsPreflight -Context $context -Name 'Baseline file' -Value $baselinePath `
        -Status $(if (Test-Path -LiteralPath $baselinePath) { 'OK' } else { 'ABSENT' })

    if (-not $SkipConnect) {
        Connect-MlsCompliance -Organization $organizationName -AppId $appId `
            -CertificateThumbprint $thumbprint -CertificateFilePath $certificateFile `
            -CertificatePassword $certificatePassword
    }
    $baseline = Get-RecordedLabelGuid -Path $baselinePath

    # L04: label replication across S&C endpoints can lag
    Invoke-MlsCriterion -Context $context -Id 'V4.1' -Control @('3.8.4') `
        -Description 'Get-Label returns the 6 labels with expected GUIDs recorded to verification/reports/' `
        -Command "Connect-IPPSSession -AppId <mls-verifier> -Organization $organizationName -CertificateThumbprint <thumbprint>`nGet-Label | Select-Object DisplayName, Guid | Where-Object DisplayName -in '$($ExpectedLabel -join "','")'" `
        -Expected "exactly 6 labels ($($ExpectedLabel -join ', ')); GUIDs equal to the recorded baseline when one exists" `
        -RetryWindowMinutes 30 `
        -Test { Test-LabelTaxonomy -ExpectedLabel $ExpectedLabel -Baseline $baseline -Context $context } | Out-Null

    Invoke-MlsCriterion -Context $context -Id 'V4.2' -Control @('3.8.4') `
        -Description 'Labels survive a kill/rebuild cycle (checked again at L11)' `
        -Command "Get-Label  # re-read at checkpoint '$Checkpoint', compared against $baselinePath" `
        -Expected 'same 6 labels, same GUIDs as label-guids.json, at every checkpoint' -NoRetry `
        -Test { Test-LabelPersistence -ExpectedLabel $ExpectedLabel -Baseline $baseline -Checkpoint $Checkpoint } | Out-Null

    # L04: reads the replication V4.1 has already waited out
    Invoke-MlsCriterion -Context $context -Id 'V4.3' -Control @('3.8.4') `
        -Description "Label policy exists, publishing the taxonomy to the demo groups (supplementary - L04.md Failure mode 5, F18)" `
        -Command "Connect-IPPSSession -AppId <mls-verifier> -Organization $organizationName -CertificateThumbprint <thumbprint>`nGet-LabelPolicy -Identity '$ExpectedLabelPolicy' | Select-Object Labels, ExchangeLocation" `
        -Expected "policy '$ExpectedLabelPolicy' exists; Labels == [$($ExpectedLabel -join ', ')]; ExchangeLocation == [$($ExpectedLabelPolicyScope -join ', ')]" `
        -RetryWindowMinutes 10 `
        -Test { Test-LabelPolicyScope -PolicyName $ExpectedLabelPolicy -ExpectedLabel $ExpectedLabel -ExpectedScope $ExpectedLabelPolicyScope } | Out-Null

    # V4.4 / V4.5 - the data-layer protection. NOT the labels: a sensitivity label
    # classifies and does not gate a read, and no criterion here may assert otherwise
    # (F18). There is deliberately no separate "the two new labels exist" criterion -
    # V4.1 already asserts the taxonomy is EXACTLY the six names, so a third check of the
    # same fact would be two ways to learn one thing.
    if ([string]::IsNullOrWhiteSpace($ProtectionPrefix)) { $ProtectionPrefix = Get-CompanyPrefix }
    $restrictedColumn = @('salary_usd', 'bonus_target_pct', 'performance_band')

    Invoke-MlsCriterion -Context $context -Id 'V4.4' -Control @('3.1.1', '3.1.5') `
        -Description 'Table protection ARTEFACTS: the column DENYs exist and the row-level security policy is ENABLED' `
        -Command "SELECT dp.name, pm.permission_name, pm.state_desc, OBJECT_NAME(pm.major_id), c.name FROM sys.database_permissions pm ... WHERE dp.name = '${ProtectionPrefix}_data_standard' AND pm.state_desc = 'DENY'`nSELECT name, is_enabled FROM sys.security_policies WHERE name = 'sp_defect_tier'" `
        -Expected "DENY on hr_roster($($restrictedColumn -join ', ')) and on defect_reports for ${ProtectionPrefix}_data_standard; sp_defect_tier present with is_enabled = 1" `
        -RetryWindowMinutes 5 `
        -Test {
        Test-TableProtectionArtefact -SqlEndpoint $SqlEndpoint -SqlAccessToken $SqlAccessToken `
            -LakehouseName $LakehouseName -Prefix $ProtectionPrefix -RestrictedColumn $restrictedColumn
    } | Out-Null

    Invoke-MlsCriterion -Context $context -Id 'V4.5' -Control @('3.1.1', '3.1.5') `
        -Description 'Table protection ENFORCEMENT: the standard tier is actually refused (capability, not artefact)' `
        -Command "EXECUTE AS USER = '<member of ${ProtectionPrefix}_data_standard>'; SELECT TOP 1 salary_usd FROM dbo.hr_roster; REVERT;   -- Msg 15868: EXECUTE AS is not supported on this endpoint" `
        -Expected 'a permission error naming salary_usd, and a filtered row count on v_defect_reports' `
        -NoRetry `
        -Test { Test-TableProtectionEnforcement -Prefix $ProtectionPrefix } | Out-Null

    return $context
}

if (-not $env:MLS_SKIP_MAIN) {
    try {
        $auditContext = Invoke-Main -Organization $Organization -VerifierAppId $VerifierAppId `
            -CertificateThumbprint $CertificateThumbprint -CertificateFilePath $CertificateFilePath `
            -CertificatePassword $CertificatePassword -ExpectedLabel $ExpectedLabel `
            -LabelGuidPath $LabelGuidPath -Checkpoint $Checkpoint -ReportRoot $ReportRoot -NoRetry:$NoRetry `
            -OnlyCriterion $OnlyCriterion `
            -ExpectedLabelPolicy $ExpectedLabelPolicy -ExpectedLabelPolicyScope $ExpectedLabelPolicyScope `
            -SqlEndpoint $SqlEndpoint -SqlAccessToken $SqlAccessToken `
            -LakehouseName $LakehouseName -ProtectionPrefix $ProtectionPrefix
    }
    catch {
        Write-MlsStatus -Message "layer-04-audit could not start: $($_.Exception.Message)" -Color Red
        exit 2
    }
    $reportFile = Write-MlsReport -Context $auditContext
    Write-MlsStatus -Message "report: $($reportFile.MarkdownPath)"
    exit (Get-MlsExitCode -Context $auditContext)
}
