# Pester tests for verification/layer-12-audit.ps1 - every az, http and git call mocked;
# zero cloud calls. The artifact and catalog are real files written per-test into a temp
# directory, because V12.1/V12.2/V12.6 read files and mocking the filesystem would test the
# mock rather than the criterion.

BeforeAll {
    $env:MLS_SKIP_MAIN = '1'
    . (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'layer-12-audit.ps1')
    # No Set-StrictMode -Off: the audit scripts set -Version Latest and CI runs them
    # that way, so the harness must not relax the language mode it is testing (F49).

    $script:ReportRoot = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath "mls-l12-$([guid]::NewGuid().ToString('n'))"
    $script:Workspace = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath "mls-l12ws-$([guid]::NewGuid().ToString('n'))"
    $script:Subscription = '00000000-0000-0000-0000-000000000000'

    function Get-Row {
        param($Context, [string]$Id)
        return @($Context.Criterion | Where-Object { $_.Id -eq $Id })[0]
    }

    function Get-ArtifactBody {
        <# A minimal but SHAPE-ACCURATE artifact: the same keys the emitter writes, so a
           criterion that reads a field the real file does not have fails here too. #>
        param(
            [string[]]$ControlId,
            [hashtable]$StatusOverride = @{},
            [hashtable]$ProvenanceOverride = @{},
            [switch]$WithScoreKey,
            [hashtable]$SummaryOverride
        )
        $controls = @()
        $tally = @{}
        foreach ($id in $ControlId) {
            $status = if ($StatusOverride.ContainsKey($id)) { $StatusOverride[$id] } else { 'NOT_ASSESSED' }
            $provenance = if ($ProvenanceOverride.ContainsKey($id)) { $ProvenanceOverride[$id] } else { 'none' }
            $controls += [ordered]@{ control = $id; status = $status; provenance = $provenance }
            if (-not $tally.ContainsKey($provenance)) { $tally[$provenance] = @{} }
            if (-not $tally[$provenance].ContainsKey($status)) { $tally[$provenance][$status] = 0 }
            $tally[$provenance][$status]++
        }
        $byProvenanceAndStatus = [ordered]@{}
        foreach ($provenance in @('machine-verified', 'asserted', 'declared', 'none')) {
            $inner = [ordered]@{}
            foreach ($status in @('COMPLIANT', 'PARTIAL', 'GAP', 'INCONCLUSIVE', 'NOT_APPLICABLE', 'NOT_ASSESSED')) {
                $value = 0
                if ($tally.ContainsKey($provenance) -and $tally[$provenance].ContainsKey($status)) { $value = $tally[$provenance][$status] }
                $inner[$status] = $value
            }
            $byProvenanceAndStatus[$provenance] = $inner
        }
        if ($SummaryOverride) { $byProvenanceAndStatus = $SummaryOverride }
        $artifact = [ordered]@{
            schemaVersion        = 1
            framework            = 'nist-800-171r2'
            collectedAt          = '2026-08-29T05:58:32Z'
            summary              = [ordered]@{
                totalRequirements     = $ControlId.Count
                byProvenanceAndStatus = $byProvenanceAndStatus
            }
            controls             = $controls
            outOfCatalogControls = @()
        }
        if ($WithScoreKey) { $artifact['compliancePercent'] = 42 }
        return ($artifact | ConvertTo-Json -Depth 8)
    }

    function Get-StateDirectoryWith {
        <# Writes a state directory. Dated snapshot names are supplied, and state-latest.json
           is byte-identical to the newest unless -LatestBody says otherwise. #>
        param(
            [string[]]$DatedName = @('state-2026-08-28.json', 'state-2026-08-29.json'),
            [string]$Body,
            [string]$LatestBody
        )
        if (Test-Path -LiteralPath $script:Workspace) { Remove-Item -LiteralPath $script:Workspace -Recurse -Force }
        $stateDirectory = Join-Path -Path $script:Workspace -ChildPath 'compliance/state'
        New-Item -ItemType Directory -Path $stateDirectory -Force | Out-Null
        foreach ($name in $DatedName) {
            Set-Content -LiteralPath (Join-Path $stateDirectory $name) -Value $Body -NoNewline
        }
        $latest = if ($PSBoundParameters.ContainsKey('LatestBody')) { $LatestBody } else { $Body }
        Set-Content -LiteralPath (Join-Path $stateDirectory 'state-latest.json') -Value $latest -NoNewline
        return $stateDirectory
    }

    function Invoke-AuditForTest {
        param(
            [switch]$NoRetry,
            [string]$StateDirectory,
            [string]$CatalogPath
        )
        Invoke-Main -SubscriptionId $script:Subscription -Repository 'paulcfuqua/azure-devsecops-demo' `
            -ResourceGroupName 'mls-rg-apps' -ComplianceAppName 'mls-compliance-demo-ca' `
            -StateDirectory $StateDirectory -CatalogPath $CatalogPath `
            -ReportRoot $script:ReportRoot -NoRetry:$NoRetry
    }
}

AfterAll {
    Remove-Item Env:\MLS_SKIP_MAIN -ErrorAction SilentlyContinue
    foreach ($path in @($script:ReportRoot, $script:Workspace)) {
        if ($path -and (Test-Path -LiteralPath $path)) {
            Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'layer-12-audit' {
    BeforeEach {
        Mock Write-MlsStatus {} -ModuleName 'MlsAudit'
        Mock Wait-MlsRetryInterval {} -ModuleName 'MlsAudit'

        $script:CatalogId = @('3.1.1', '3.1.2', '3.3.1')
        New-Item -ItemType Directory -Path $script:ReportRoot -Force | Out-Null
        $script:CatalogPath = Join-Path -Path $script:ReportRoot -ChildPath 'catalog.json'
        Set-Content -LiteralPath $script:CatalogPath -NoNewline -Value (
            @{ requirements = @($script:CatalogId | ForEach-Object { @{ id = $_ } }) } | ConvertTo-Json -Depth 5)

        # The healthy estate, for every criterion at once.
        $script:Fqdn = 'mls-compliance-demo-ca.example.azurecontainerapps.io'
        $script:AuthPayload = [pscustomobject]@{
            globalValidation  = [pscustomobject]@{ unauthenticatedClientAction = 'RedirectToLoginPage' }
            identityProviders = [pscustomobject]@{
                azureActiveDirectory = [pscustomobject]@{
                    enabled      = $true
                    registration = [pscustomobject]@{ clientSecretSettingName = $null }
                }
            }
        }
        $script:HttpStatus = 302
        $script:HttpError = $null
        $script:GitSubject = 'verify(compliance): state at 87bfd91d9b4acad06ae9493e5a0c7b7578423257'

        Mock Invoke-MlsAz {
            $joined = $Argument -join ' '
            if ($joined -like '*containerapp show*') { return $script:Fqdn }
            if ($joined -like '*containerapp auth show*') { return $script:AuthPayload }
            throw "unexpected az call: $joined"
        }

        Mock Invoke-MlsHttp {
            return [pscustomobject]@{
                StatusCode = $script:HttpStatus
                Content    = ''
                Headers    = @{}
                Error      = $script:HttpError
            }
        }

        Mock Invoke-MlsGit {
            return [pscustomobject]@{ ExitCode = 0; Line = @($script:GitSubject) }
        }

        $script:Body = Get-ArtifactBody -ControlId $script:CatalogId
        $script:StateDirectory = Get-StateDirectoryWith -Body $script:Body
    }

    Context 'all criteria pass' {
        It 'records V12.1-V12.6, four PASS and two SKIP, and exits 0' {
            $context = Invoke-AuditForTest -NoRetry -StateDirectory $script:StateDirectory -CatalogPath $script:CatalogPath
            @($context.Criterion).Id | Should -Be @('V12.1', 'V12.2', 'V12.3', 'V12.4', 'V12.5', 'V12.6')
            @($context.Criterion | Where-Object { $_.Status -eq 'PASS' }).Count | Should -Be 4
            @($context.Criterion | Where-Object { $_.Status -eq 'SKIP' }).Count | Should -Be 2
            @($context.Criterion | Where-Object { $_.Status -eq 'FAIL' }) | Should -BeNullOrEmpty
            Get-MlsExitCode -Context $context | Should -Be 0
        }

        It 'names the OWNER of each skipped criterion rather than only skipping it' {
            # A SKIP that says "not checked" is an omission with a label. These two say
            # where the check actually lives, which is the difference between a gap and a
            # boundary.
            $context = Invoke-AuditForTest -NoRetry -StateDirectory $script:StateDirectory -CatalogPath $script:CatalogPath
            (Get-Row -Context $context -Id 'V12.3').Detail | Should -Match 'CI gate'
            (Get-Row -Context $context -Id 'V12.5').Detail | Should -Match 'V8\.3'
        }
    }

    Context 'V12.1: the artifact is complete, and carries no score' {
        It 'FAILS when a catalog requirement has no row - an omission, not a NOT_ASSESSED' {
            $partial = Get-ArtifactBody -ControlId @('3.1.1', '3.1.2')
            $directory = Get-StateDirectoryWith -Body $partial
            $context = Invoke-AuditForTest -NoRetry -StateDirectory $directory -CatalogPath $script:CatalogPath
            $row = Get-Row -Context $context -Id 'V12.1'
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -Match 'MISSING 1'
            $row.Observed | Should -Match '3\.3\.1'
        }

        It 'FAILS on a score-shaped key, which the design forbids anywhere in the artifact' {
            $scored = Get-ArtifactBody -ControlId $script:CatalogId -WithScoreKey
            $directory = Get-StateDirectoryWith -Body $scored
            $context = Invoke-AuditForTest -NoRetry -StateDirectory $directory -CatalogPath $script:CatalogPath
            $row = Get-Row -Context $context -Id 'V12.1'
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -Match 'SCORE-SHAPED KEYS'
        }

        It 'FAILS on a duplicated row, which a bare count comparison would not see' {
            # The reason this criterion compares SETS rather than counts: 3 rows against a
            # 3-requirement catalog is the right NUMBER and the wrong CONTENT.
            $duplicated = Get-ArtifactBody -ControlId @('3.1.1', '3.1.2', '3.1.2')
            $directory = Get-StateDirectoryWith -Body $duplicated
            $context = Invoke-AuditForTest -NoRetry -StateDirectory $directory -CatalogPath $script:CatalogPath
            $row = Get-Row -Context $context -Id 'V12.1'
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -Match 'DUPLICATED'
        }

        It 'reports UNOBSERVABLE, not complete, when the catalog yields nothing' {
            $emptyCatalog = Join-Path -Path $script:ReportRoot -ChildPath 'empty-catalog.json'
            Set-Content -LiteralPath $emptyCatalog -NoNewline -Value (@{ requirements = @() } | ConvertTo-Json)
            $context = Invoke-AuditForTest -NoRetry -StateDirectory $script:StateDirectory -CatalogPath $emptyCatalog
            $row = Get-Row -Context $context -Id 'V12.1'
            $row.Status | Should -Be 'FAIL'
            $row.Detail | Should -Match 'UNOBSERVABLE'
        }
    }

    Context 'V12.2: COMPLIANT is unreachable from an authored assertion' {
        It 'FAILS when an asserted row reached COMPLIANT' {
            # The invariant the whole platform rests on. A human may argue a control to
            # PARTIAL or GAP; only the criteria branch may produce COMPLIANT.
            $body = Get-ArtifactBody -ControlId $script:CatalogId `
                -StatusOverride @{ '3.1.1' = 'COMPLIANT' } -ProvenanceOverride @{ '3.1.1' = 'asserted' }
            $directory = Get-StateDirectoryWith -Body $body
            $context = Invoke-AuditForTest -NoRetry -StateDirectory $directory -CatalogPath $script:CatalogPath
            $row = Get-Row -Context $context -Id 'V12.2'
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -Match "3\.1\.1 is COMPLIANT with provenance 'asserted'"
        }

        It 'PASSES a COMPLIANT row whose provenance IS machine-verified, so it is not a blanket ban' {
            $body = Get-ArtifactBody -ControlId $script:CatalogId `
                -StatusOverride @{ '3.1.1' = 'COMPLIANT' } -ProvenanceOverride @{ '3.1.1' = 'machine-verified' }
            $directory = Get-StateDirectoryWith -Body $body
            $context = Invoke-AuditForTest -NoRetry -StateDirectory $directory -CatalogPath $script:CatalogPath
            (Get-Row -Context $context -Id 'V12.2').Status | Should -Be 'PASS'
        }

        It 'FAILS on a provenance value outside the emitter vocabulary' {
            # How a record would smuggle itself past the invariant: not by claiming
            # machine-verified, but by claiming something the check does not recognise and
            # therefore does not judge.
            $body = Get-ArtifactBody -ControlId $script:CatalogId -ProvenanceOverride @{ '3.1.2' = 'self-attested' }
            $directory = Get-StateDirectoryWith -Body $body
            $context = Invoke-AuditForTest -NoRetry -StateDirectory $directory -CatalogPath $script:CatalogPath
            $row = Get-Row -Context $context -Id 'V12.2'
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -Match 'UNKNOWN PROVENANCE'
        }

        It 'FAILS when the published summary disagrees with the rows beneath it' {
            $drifted = @{ 'none' = @{ 'NOT_ASSESSED' = 99 } }
            $body = Get-ArtifactBody -ControlId $script:CatalogId -SummaryOverride $drifted
            $directory = Get-StateDirectoryWith -Body $body
            $context = Invoke-AuditForTest -NoRetry -StateDirectory $directory -CatalogPath $script:CatalogPath
            $row = Get-Row -Context $context -Id 'V12.2'
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -Match 'summary says 99, rows say 3'
        }
    }

    Context 'V12.4: Easy Auth refuses an unauthenticated request' {
        It 'FAILS when the board SERVES an anonymous request' {
            $script:HttpStatus = 200
            $context = Invoke-AuditForTest -NoRetry -StateDirectory $script:StateDirectory -CatalogPath $script:CatalogPath
            $row = Get-Row -Context $context -Id 'V12.4'
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -Match 'SERVED an anonymous request'
        }

        It 'PASSES on 401 as well as 302, because both are refusals' {
            # NOT a widening for convenience. The deployed board answers 302 to PowerShell
            # and 401 to curl - the same control, a different refusal shape per client. A
            # criterion pinned to 302 would fail a working control on the User-Agent of
            # whoever ran it.
            $script:HttpStatus = 401
            $context = Invoke-AuditForTest -NoRetry -StateDirectory $script:StateDirectory -CatalogPath $script:CatalogPath
            (Get-Row -Context $context -Id 'V12.4').Status | Should -Be 'PASS'
        }

        It 'FAILS when the platform is not configured to intercept, even though the app refused' {
            # The app answering 401 today does not mean Easy Auth is doing it; the
            # configuration is read as an independent second fact.
            $script:AuthPayload.globalValidation.unauthenticatedClientAction = 'AllowAnonymous'
            $context = Invoke-AuditForTest -NoRetry -StateDirectory $script:StateDirectory -CatalogPath $script:CatalogPath
            $row = Get-Row -Context $context -Id 'V12.4'
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -Match "unauthenticatedClientAction is 'AllowAnonymous'"
        }

        It 'FAILS when a client secret is configured on an app registered without one' {
            $script:AuthPayload.identityProviders.azureActiveDirectory.registration.clientSecretSettingName = 'a-secret'
            $context = Invoke-AuditForTest -NoRetry -StateDirectory $script:StateDirectory -CatalogPath $script:CatalogPath
            $row = Get-Row -Context $context -Id 'V12.4'
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -Match 'a client secret is configured'
        }

        It 'reports UNOBSERVABLE, not "refused", when the request produced no status at all' {
            $script:HttpStatus = 0
            $script:HttpError = 'No such host is known'
            $context = Invoke-AuditForTest -NoRetry -StateDirectory $script:StateDirectory -CatalogPath $script:CatalogPath
            $row = Get-Row -Context $context -Id 'V12.4'
            $row.Status | Should -Be 'FAIL'
            $row.Detail | Should -Match 'UNOBSERVABLE'
        }

        It 'reports UNOBSERVABLE, not "no app", when the FQDN cannot be read' {
            $script:Fqdn = ''
            $context = Invoke-AuditForTest -NoRetry -StateDirectory $script:StateDirectory -CatalogPath $script:CatalogPath
            $row = Get-Row -Context $context -Id 'V12.4'
            $row.Status | Should -Be 'FAIL'
            $row.Detail | Should -Match 'UNOBSERVABLE, not "no app"'
        }
    }

    Context 'V12.6: the collection history is a git history' {
        It 'FAILS when state-latest.json matches no dated snapshot' {
            $other = Get-ArtifactBody -ControlId @('3.1.1')
            $directory = Get-StateDirectoryWith -Body $script:Body -LatestBody $other
            $context = Invoke-AuditForTest -NoRetry -StateDirectory $directory -CatalogPath $script:CatalogPath
            $row = Get-Row -Context $context -Id 'V12.6'
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -Match 'does not match the newest dated snapshot'
        }

        It 'FAILS when a snapshot was introduced by a commit the emitter did not write' {
            $script:GitSubject = 'chore: tweak the compliance numbers'
            $context = Invoke-AuditForTest -NoRetry -StateDirectory $script:StateDirectory -CatalogPath $script:CatalogPath
            $row = Get-Row -Context $context -Id 'V12.6'
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -Match 'not introduced by the emitter'
        }

        It 'PASSES the bootstrap message, which is not the per-run format but is the emitter' {
            # The first version of this criterion demanded 'state at <sha>' and failed the
            # real repository on 'verify(compliance): first collected state artifact' - a
            # legitimate bootstrap commit. The namespace is the honest boundary.
            $script:GitSubject = 'verify(compliance): first collected state artifact'
            $context = Invoke-AuditForTest -NoRetry -StateDirectory $script:StateDirectory -CatalogPath $script:CatalogPath
            (Get-Row -Context $context -Id 'V12.6').Status | Should -Be 'PASS'
        }

        It 'reports UNOBSERVABLE, not "clean", when git returns nothing for a snapshot' {
            Mock Invoke-MlsGit { return [pscustomobject]@{ ExitCode = 128; Line = @() } }
            $context = Invoke-AuditForTest -NoRetry -StateDirectory $script:StateDirectory -CatalogPath $script:CatalogPath
            $row = Get-Row -Context $context -Id 'V12.6'
            $row.Status | Should -Be 'FAIL'
            # When NO snapshot has an introducing commit, the honest reading is "the
            # history could not be read", not "every snapshot was hand-edited" - one git
            # failure must not be reported as evidence against the artifacts.
            $row.Observed | Should -Match 'UNOBSERVABLE, not empty'
            $row.Observed | Should -Not -Match 'not introduced by the emitter'
        }

        It 'FAILS when there are no dated snapshots at all' {
            $directory = Get-StateDirectoryWith -Body $script:Body -DatedName @()
            $context = Invoke-AuditForTest -NoRetry -StateDirectory $directory -CatalogPath $script:CatalogPath
            $row = Get-Row -Context $context -Id 'V12.6'
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -Match 'no dated snapshots'
        }
    }
}
