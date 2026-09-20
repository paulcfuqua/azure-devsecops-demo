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
      V4.4  RETIRED 2026-09-20. It asserted that the column DENYs exist and the RLS
            policy is enabled - both ARTEFACTS. V4.5 proves the policy actually FILTERS,
            which strictly implies it exists and is enabled, so nothing was lost by
            removing it. Two things made keeping it worse than useless: the column DENYs
            target a role that can never have members on this endpoint (F218), so they
            enforce nothing; and mls-verifier cannot read sys.database_permissions at
            all (F224), so the criterion could never reach a verdict. A check that can
            neither see its subject nor find a working control if it could is noise
            wearing the costume of diligence. Restore it if the sensitive tables ever
            move to a Fabric Warehouse, where database principals exist and the DENYs
            would bind.
      V4.5  Row-level security ENFORCES - a non-privileged caller sees exactly the
            unrestricted rows. A REAL VERDICT: the predicate keys on the PRIVILEGED role,
            so it filters every caller outside it, this auditor included.
      V4.6  Column-level denial ENFORCES - not observable read-only, and reports SKIP
            saying why. A DENY binds only members of the role it targets, and EXECUTE AS
            is unsupported here (Msg 15868), and per F218 no principal can exist to be
            denied in the first place.

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

    # V4.5 reads the lakehouse SQL analytics endpoint to prove the row filter filters.
    # RESOLVED by the caller from the Fabric API, never stored: it regenerates on every
    # rebuild (F129's class). Absent means V4.5 reports UNOBSERVABLE, never a pass.
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

function Test-RowFilterEnforcement {
    <#
    .SYNOPSIS
        V4.5 - the row-level security policy ACTUALLY FILTERS. The capability, not the
        artefact, and it is observable read-only.
    .DESCRIPTION
        THIS WAS ORIGINALLY A BLANKET SKIP AND THAT WAS WRONG. The first design reasoned
        that proving enforcement needed a caller inside the standard role, which is
        impossible here - a DENY bites only members of the role it targets, and EXECUTE AS
        is unsupported on this endpoint (Msg 15868). True for the COLUMN denial; false for
        the row filter.

        The predicate is: classification <> the restricted value, OR the caller is a member
        of <prefix>_data_privileged. It keys on the PRIVILEGED role, so every caller
        OUTSIDE that role is filtered - including mls-verifier. Confirmed on the live
        estate 2026-09-20: one caller in neither role read 900 rows from defect_reports and
        761 from v_defect_reports in the same second, with 139 rows classified restricted.
        900 - 139 = 761.

        So the check is: read both counts as myself, and require the shortfall to equal the
        restricted count exactly. That is the control doing its job, observed - not an
        object existing.

        Vacuity is guarded in both directions. A PRIVILEGED caller sees everything and would
        make the comparison meaningless, so that reports SKIP rather than failing a correct
        estate. And a table with no restricted rows would make a filter that removed nothing
        look identical to one that worked, so zero restricted rows is a FAIL pointing at V5.5.

        THIS CRITERION SUBSUMES THE RETIRED V4.4. A policy that filters necessarily exists
        and is necessarily enabled - a disabled policy returns every row and fails here. So
        the artefact check added nothing this does not already prove, and unlike it, this
        one is observable by the verifier.
    #>
    param(
        [AllowEmptyString()][string]$SqlEndpoint,
        [AllowEmptyString()][AllowNull()][string]$SqlAccessToken,
        [Parameter(Mandatory)][string]$LakehouseName,
        [Parameter(Mandatory)][string]$Prefix,
        [Parameter(Mandatory)][string]$RestrictedClassification
    )
    if ([string]::IsNullOrWhiteSpace($SqlEndpoint)) {
        return New-MlsCheckResult -Passed $false `
            -Observed 'UNOBSERVABLE: no SQL analytics endpoint was supplied' `
            -Detail 'Pass -SqlEndpoint, resolved from the Fabric API. Without it this criterion cannot look, and it says so rather than reporting the filter broken.' -Final
    }

    $privileged = "${Prefix}_data_privileged"
    $query = @"
SELECT
    (SELECT COUNT(*) FROM dbo.defect_reports) AS base_rows,
    (SELECT COUNT(*) FROM dbo.v_defect_reports) AS view_rows,
    (SELECT COUNT(*) FROM dbo.defect_reports WHERE classification = '$RestrictedClassification') AS restricted_rows,
    ISNULL(IS_ROLEMEMBER('$privileged'), -1) AS is_privileged
"@
    try {
        $rows = @(Invoke-MlsSqlQuery -ServerName $SqlEndpoint -DatabaseName $LakehouseName `
                -AccessToken $SqlAccessToken -Query $query)
    }
    catch {
        return New-MlsCheckResult -Passed $false `
            -Observed "UNOBSERVABLE: could not read both the base table and the filtered view - $($_.Exception.Message)" `
            -Detail 'The comparison needs both reads from the same caller. It reports that it could not look, never that the filter is broken (F105).' -Final
    }
    if ($rows.Count -eq 0) {
        return New-MlsCheckResult -Passed $false `
            -Observed 'UNOBSERVABLE: the endpoint returned no row for the comparison' -Final
    }

    $base = [int](Get-MlsProperty -InputObject $rows[0] -Name 'base_rows')
    $view = [int](Get-MlsProperty -InputObject $rows[0] -Name 'view_rows')
    $restricted = [int](Get-MlsProperty -InputObject $rows[0] -Name 'restricted_rows')
    $isPrivileged = [int](Get-MlsProperty -InputObject $rows[0] -Name 'is_privileged')
    $describe = "base=$base, through the view=$view, restricted=$restricted, this caller privileged=$isPrivileged"

    if ($isPrivileged -eq -1) {
        return New-MlsCheckResult -Passed $false `
            -Observed "UNOBSERVABLE: role '$privileged' does not exist, so nothing follows about filtering -- $describe" `
            -Detail 'The protection has not been applied. Re-run layer-04-purview.yml, whose protect job applies infra/fabric/protect-tables.ps1; every statement is guarded and safe to replay. This criterion cannot distinguish "no filter" from "no role to filter against", so it reports neither.' -Final
    }
    if ($isPrivileged -eq 1) {
        return New-MlsCheckResult -Status 'SKIP' `
            -Observed "UNOBSERVABLE: this auditor IS a member of '$privileged', which by design bypasses the filter -- $describe" `
            -Detail "A privileged caller sees every row, so equal counts would prove nothing either way. Run the audit as an identity outside $privileged - mls-verifier is outside it by default, and putting it inside would silently make this criterion vacuous."
    }
    if ($restricted -le 0) {
        return New-MlsCheckResult -Passed $false `
            -Observed "no rows carry the restricted classification, so a filter that removed nothing would look identical to one that worked -- $describe" `
            -Detail 'Reseed (L5). V5.5 asserts this precondition directly; without restricted rows this criterion can demonstrate nothing.' -Final
    }
    if (($base - $view) -ne $restricted) {
        return New-MlsCheckResult -Passed $false `
            -Observed "the filter removed $($base - $view) row(s) but $restricted are classified restricted -- $describe" `
            -Detail 'A non-privileged caller must see exactly the unrestricted rows through v_defect_reports. Equal counts mean the policy is not filtering: check that sp_defect_tier exists with is_enabled = 1 in sys.security_policies and that its predicate is bound to v_defect_reports.' -Final
    }
    return New-MlsCheckResult -Passed $true `
        -Observed "a non-privileged caller sees $view of $base rows; exactly the $restricted restricted row(s) were filtered out, silently -- $describe"
}

function Test-ColumnDenialEnforcement {
    <#
    .SYNOPSIS
        V4.6 - does the standard tier actually get REFUSED the restricted columns? Not
        observable from here, and this records that rather than passing on the artefact.
    .DESCRIPTION
        The column half of enforcement, and the half a read-only auditor genuinely cannot
        demonstrate on this endpoint.

        Contrast with V4.5. The row predicate keys on the PRIVILEGED role, so it filters
        every caller outside it - this auditor included, which is what makes V4.5 a real
        verdict. A DENY is the other way round: it binds only members of the role it
        TARGETS. mls-verifier is not in <prefix>_data_standard, so it reads salary_usd
        perfectly well, and that proves nothing about the standard tier.

        The direct check would be EXECUTE AS a member of that role. A Fabric lakehouse SQL
        analytics endpoint DOES NOT SUPPORT EXECUTE AS - Msg 15868, verified live
        2026-09-20 - and that is a feature-level refusal, not a permission error, so no
        credential makes it work. The endpoint's only database users are dbo, guest, sys and
        INFORMATION_SCHEMA; a database role is not a user.

        Joining mls-verifier to the standard role to test it would break other criteria:
        V5.3 needs it to see all 900 defect_reports rows, and a member of the standard tier
        is DENIED that table outright.

        So: SKIP, naming the blocker, and naming where the capability IS observable - the
        two-tier agent path, where the standard tier's own identity asks for salary through
        the tool chain and is refused by the database. The retired V4.4 covered the artefact
        and never stood in for this.
    #>
    param([Parameter(Mandatory)][string]$Prefix)
    return New-MlsCheckResult -Status 'SKIP' `
        -Observed 'UNOBSERVABLE from a read-only audit: a DENY binds only members of the role it targets, and EXECUTE AS is not supported on this endpoint (Msg 15868, verified 2026-09-20)' `
        -Detail "This auditor is not in ${Prefix}_data_standard, so its own ability to read salary_usd says nothing about the standard tier. The refusal cannot be provoked from here for ANY caller - Msg 15868 is a feature-level refusal - and the endpoint exposes no impersonable user. Joining the auditor to ${Prefix}_data_standard would break V5.3, which needs it to read all 900 defect_reports rows. The capability is observable end to end on the two-tier agent path; that criterion belongs with the agent tiering. V4.4 used to cover the artefact and was retired (F218, F224): the DENY rows it checked can never bind anyone on this endpoint, and the verifier cannot see them anyway. Contrast V4.5, which IS a real verdict because the row predicate keys on the PRIVILEGED role and so filters every caller outside it."
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

    # V4.5 / V4.6 - the data-layer protection. NOT the labels: a sensitivity label
    # classifies and does not gate a read, and no criterion here may assert otherwise
    # (F18). There is deliberately no separate "the two new labels exist" criterion -
    # V4.1 already asserts the taxonomy is EXACTLY the six names, so a third check of the
    # same fact would be two ways to learn one thing.
    if ([string]::IsNullOrWhiteSpace($ProtectionPrefix)) { $ProtectionPrefix = Get-CompanyPrefix }
    # The restricted COLUMN list went with V4.4: it was that criterion's input, and per
    # F218 those DENYs bind nobody on this endpoint anyway. V4.6 names the columns in its
    # own text for the human reading a SKIP.
    #
    # The value the RLS predicate filters on. Mirrors
    # infra/fabric/protect-tables.ps1's $script:RestrictedClassification.
    $restrictedClassification = 'THIRD_PARTY_PROPRIETARY'

    # V4.5 IS A REAL VERDICT, not a SKIP. The row predicate keys on the PRIVILEGED role,
    # so it filters every caller outside it - this auditor included. Reading the base table
    # and the filtered view as myself and requiring the shortfall to equal the restricted
    # count IS the capability check. Proven on the live estate 2026-09-20: 900 base, 761
    # through the view, 139 restricted.
    Invoke-MlsCriterion -Context $context -Id 'V4.5' -Control @('3.1.1', '3.1.5') `
        -Description 'Row-level security ENFORCES: a non-privileged caller sees exactly the unrestricted rows (capability, not artefact)' `
        -Command "SELECT (SELECT COUNT(*) FROM dbo.defect_reports) AS base_rows, (SELECT COUNT(*) FROM dbo.v_defect_reports) AS view_rows, (SELECT COUNT(*) FROM dbo.defect_reports WHERE classification = '$restrictedClassification') AS restricted_rows, IS_ROLEMEMBER('${ProtectionPrefix}_data_privileged') AS is_privileged" `
        -Expected "base_rows - view_rows == restricted_rows, read by a caller outside ${ProtectionPrefix}_data_privileged" `
        -RetryWindowMinutes 5 `
        -Test {
        Test-RowFilterEnforcement -SqlEndpoint $SqlEndpoint -SqlAccessToken $SqlAccessToken `
            -LakehouseName $LakehouseName -Prefix $ProtectionPrefix `
            -RestrictedClassification $restrictedClassification
    } | Out-Null

    # V4.6 is the half that genuinely cannot be observed here, kept SEPARATE so V4.5's
    # pass never implies it. A DENY binds only members of the role it targets, and
    # EXECUTE AS is unsupported on this endpoint (Msg 15868).
    Invoke-MlsCriterion -Context $context -Id 'V4.6' -Control @('3.1.1', '3.1.5') `
        -Description 'Column-level denial ENFORCES: the standard tier is refused salary_usd (not observable read-only)' `
        -Command "EXECUTE AS USER = '<member of ${ProtectionPrefix}_data_standard>'; SELECT TOP 1 salary_usd FROM dbo.hr_roster; REVERT;   -- Msg 15868: EXECUTE AS is not supported on this endpoint" `
        -Expected 'a permission error naming salary_usd' `
        -NoRetry `
        -Test { Test-ColumnDenialEnforcement -Prefix $ProtectionPrefix } | Out-Null

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
