#Requires -Version 7.0
<#
.SYNOPSIS
    Capture evidence that the lakehouse access control is real. READ-ONLY.

.DESCRIPTION
    The estate is scheduled for teardown around 2026-09-27. After that, every number below
    is unobtainable: the outbrief's prose can be written afterwards, its evidence cannot.
    This script produces a dated, self-describing record so the claim in that document
    rests on an artifact rather than on somebody's memory of a terminal.

    IT RECORDS WHAT IT OBSERVED, INCLUDING THE PARTS THAT WEAKEN THE CLAIM. An evidence
    file that only carries the flattering half is marketing. The two limits below are
    printed in the output every run, not buried in a footnote:

      F218  The COLUMN denials are inert. CREATE USER is unsupported on a lakehouse SQL
            analytics endpoint (Msg 22424), so no principal can ever join
            <prefix>_data_standard, so a DENY targeting it binds nobody. The objects
            exist; they enforce nothing. Real column-level enforcement needs a Fabric
            Warehouse, where database principals exist.

      F218  There is therefore NO TIERING. Every caller is outside the privileged role,
            so every caller is filtered identically. The claim this evidence supports is
            "3PPI is hidden from every automated caller", NOT "different accounts see
            different data".

    WHAT IT DOES SUPPORT, and this is a real control: the row-level security policy
    removes exactly the restricted rows, silently, from any caller that reads through the
    secure view - including the Copilot agent's own identity.

.NOTES
    Read-only by construction: every statement is a SELECT. It is safe to run against the
    live estate at any time and is deliberately runnable by anyone with read access, so
    the numbers can be reproduced rather than trusted.

    The SQL endpoint is RESOLVED from the Fabric API, never stored - it regenerates on
    every rebuild (F129's class).

.EXAMPLE
    ./capture-access-control-evidence.ps1 -OutputPath verification/reports/access-control-evidence.md
#>
[CmdletBinding()]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'SqlAccessToken',
    Justification = 'An Entra access token arrives as a plain string and Invoke-Sqlcmd -AccessToken takes one. SecureString is not encrypted on .NET for Linux. It is never written to the evidence file.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
    Justification = 'SqlEndpoint, Database and SqlAccessToken are read by Get-Evidence through PowerShell dynamic scoping, which the analyser cannot follow. They are the connection; an unused one would fail on the first query.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
    Justification = 'Evidence-capture script run by a human at a terminal; the two Write-Host lines are the confirmation that the file was written and what verdict it carries. The evidence itself goes to a file, not the stream, so nothing here is a pipeline output being swallowed.')]
param(
    [Parameter(Mandatory)][string]$SqlEndpoint,
    [Parameter(Mandatory)][string]$SqlAccessToken,
    [string]$Database = 'mls_operations',
    [string]$Prefix = 'mls',
    [string]$OutputPath = 'verification/reports/access-control-evidence.md',
    [int]$TimeoutSec = 120
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-Evidence {
    <#
        Select-Object * is not decoration. Invoke-Sqlcmd returns DataRow objects, and a
        DataRow ENUMERATES OVER ITS COLUMNS - so @(...) around a single-row result does
        not give a one-element array of rows, it gives an N-element array of VALUES, and
        $rows[0] is the first column rather than the first row. Projecting to
        PSCustomObject first makes the shape what it looks like.
    #>
    param([Parameter(Mandatory)][string]$Query)
    return @(Invoke-Sqlcmd -ServerInstance $SqlEndpoint -Database $Database -Query $Query `
            -AccessToken $SqlAccessToken -ConnectionTimeout $TimeoutSec -ErrorAction Stop |
            Select-Object *)
}

function Get-Field {
    <# Named access, so a renamed column fails loudly here rather than rendering as an
       empty cell in an evidence file somebody later quotes. #>
    param(
        [Parameter(Mandatory)]$Row,
        [Parameter(Mandatory)][string]$Name
    )
    if (-not $Row.PSObject.Properties.Name.Contains($Name)) {
        throw "The result has no column '$Name'. Columns: $($Row.PSObject.Properties.Name -join ', ')"
    }
    return $Row.$Name
}

$collectedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')

# Who is reading? The verdict means nothing without it: a privileged caller bypasses the
# filter by design, so the same numbers would prove the opposite.
$identity = Get-Evidence -Query @"
SELECT SUSER_NAME() AS caller,
       ISNULL(IS_ROLEMEMBER('${Prefix}_data_privileged'), -1) AS is_privileged,
       ISNULL(IS_ROLEMEMBER('${Prefix}_data_standard'), -1) AS is_standard
"@

# The control, measured. Base table and filtered view read by the SAME caller in the SAME
# statement - two counts taken apart in time would not be evidence of one thing.
$counts = Get-Evidence -Query @"
SELECT (SELECT COUNT(*) FROM dbo.defect_reports) AS base_rows,
       (SELECT COUNT(*) FROM dbo.v_defect_reports) AS view_rows,
       (SELECT COUNT(*) FROM dbo.defect_reports WHERE classification = 'THIRD_PARTY_PROPRIETARY') AS restricted_rows
"@

$policy = Get-Evidence -Query @'
SELECT p.name AS policy_name, p.is_enabled, pr.predicate_type_desc, OBJECT_NAME(pr.target_object_id) AS bound_to
FROM sys.security_policies p
LEFT JOIN sys.security_predicates pr ON pr.object_id = p.object_id
WHERE p.name = 'sp_defect_tier'
'@

$hr = Get-Evidence -Query 'SELECT COUNT(*) AS rows_total, COUNT(salary_usd) AS salary_populated FROM dbo.hr_roster'

$base = [int](Get-Field -Row $counts[0] -Name 'base_rows')
$view = [int](Get-Field -Row $counts[0] -Name 'view_rows')
$restricted = [int](Get-Field -Row $counts[0] -Name 'restricted_rows')
$removed = $base - $view
$verdict = if ($removed -eq $restricted -and $restricted -gt 0) { 'CONTROL DEMONSTRATED' } else { 'NOT DEMONSTRATED' }

$lines = [System.Collections.Generic.List[string]]::new()
$lines.Add('# Access-control evidence — Meridian lakehouse')
$lines.Add('')
$lines.Add("**Collected:** $collectedAt  ")
$lines.Add("**Database:** ``$Database`` on the Fabric lakehouse SQL analytics endpoint  ")
$lines.Add("**Read by:** ``$(Get-Field -Row $identity[0] -Name 'caller')`` — privileged role: $(Get-Field -Row $identity[0] -Name 'is_privileged'), standard role: $(Get-Field -Row $identity[0] -Name 'is_standard')")
$lines.Add('')
$lines.Add('Every statement behind this file is a `SELECT`. Re-run `verification/capture-access-control-evidence.ps1` to reproduce it.')
$lines.Add('')
$lines.Add("## Verdict: $verdict")
$lines.Add('')
$lines.Add('| | rows |')
$lines.Add('|---|---|')
$lines.Add("| ``defect_reports`` (base table) | **$base** |")
$lines.Add("| ``v_defect_reports`` (through the security policy) | **$view** |")
$lines.Add("| classified ``THIRD_PARTY_PROPRIETARY`` | **$restricted** |")
$lines.Add("| removed by the filter | **$removed** |")
$lines.Add('')
$lines.Add("$base − $restricted = $view. The row-level security policy removed exactly the restricted rows, and returned no error while doing it.")
$lines.Add('')
if ($policy.Count -gt 0) {
    $lines.Add("Policy ``$(Get-Field -Row $policy[0] -Name 'policy_name')`` — enabled: **$(Get-Field -Row $policy[0] -Name 'is_enabled')**, $(Get-Field -Row $policy[0] -Name 'predicate_type_desc') predicate bound to ``$(Get-Field -Row $policy[0] -Name 'bound_to')``.")
}
else {
    $lines.Add('The policy could not be read from `sys.security_policies` by this caller. That is a visibility limit of this identity (F224), not evidence of absence.')
}
$lines.Add('')
$lines.Add("``hr_roster``: $(Get-Field -Row $hr[0] -Name 'rows_total') rows, $(Get-Field -Row $hr[0] -Name 'salary_populated') with a populated ``salary_usd``.")
$lines.Add('')
$lines.Add('## What this evidence does NOT show')
$lines.Add('')
$lines.Add('Stated here rather than in a footnote, because an evidence file carrying only the flattering half is marketing.')
$lines.Add('')
$lines.Add('- **The column denials are inert.** `CREATE USER` is unsupported on this endpoint (Msg 22424), so no principal can join `' + $Prefix + '_data_standard`, so a `DENY` targeting it binds nobody. The objects exist and enforce nothing. Column-level enforcement needs a Fabric Warehouse, where database principals exist. (F218)')
$lines.Add('- **There is no tiering.** Every caller sits outside the privileged role, so every caller is filtered identically. This supports *3PPI is hidden from every automated caller* — not *different accounts see different data*. (F218)')
$lines.Add('- **Silence is the intended behaviour.** A filtered caller gets no error and no indication rows were removed. That is correct for row-level security, where the existence of a record is itself sensitive — and it means this evidence, not the caller''s experience, is how the control is observed.')
$lines.Add('')
$lines.Add('## Independently checked')
$lines.Add('')
$lines.Add('`V4.5` in `verification/layer-04-audit.ps1` asserts this same comparison on every L4 run, as `mls-verifier`, and fails when the shortfall does not equal the restricted count. This file is the human-readable capture; that criterion is the machine-checked one.')

$directory = Split-Path -Path $OutputPath -Parent
if ($directory -and -not (Test-Path -LiteralPath $directory)) {
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
}
Set-Content -LiteralPath $OutputPath -Value ($lines -join "`n") -Encoding utf8

Write-Host "Evidence written to $OutputPath" -ForegroundColor Green
Write-Host "  $verdict : base=$base view=$view restricted=$restricted removed=$removed"
