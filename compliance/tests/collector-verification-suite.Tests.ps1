# compliance/tests/collector-verification-suite.Tests.ps1
#
# verification-suite is the machine-verified path: the only collector whose evidence can
# derive COMPLIANT (compliance/lib/MlsCompliance.psm1's Get-MlsControlStatus). It reads
# committed layer-audit JSON reports (verification/MlsAudit.psm1's Write-MlsReport shape)
# and turns each criterion row into one evidence record per mapped control. The failure
# modes this suite exists to prevent: a SKIPPED or PENDING criterion rendering as a silent
# pass, evidence invented for a criterion Task 2 deliberately left unmapped, and one bad
# report file taking the whole run down with it.
#
# compliance/tests/fixtures/L03-report.json is built to the real Write-MlsReport shape:
# top-level fields camelCase, criteria rows PascalCase with a Control string array - not an
# invented shape, because a fixture that disagrees with the producer tests nothing.
# compliance/tests/fixtures/L99-malformed.json (invalid JSON) and L98-not-a-report.json
# (valid JSON, no criteria array) sit alongside it deliberately, so every "good" test below
# also proves the collector tolerates a dirty directory rather than needing a synthetic one.

BeforeAll {
    $script:Collector = Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'collectors', 'verification-suite.ps1'
    $script:FixtureRoot = Join-Path -Path $PSScriptRoot -ChildPath 'fixtures'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'lib', 'MlsCompliance.psm1') -Force
}

AfterAll {
    Remove-Module MlsCompliance -Force -ErrorAction SilentlyContinue
}

Describe 'verification-suite collector' {

    It 'turns a PASS criterion into pass evidence for each mapped control' {
        # Brief's own test, verbatim: the fixture's V3.3 is FAIL, not PASS, so the
        # assertion below is on 'fail' - the title describes the general shape being
        # proven (one control, one record, carrying the right status/observed/artifact).
        $evidence = & $script:Collector -ReportRoot $script:FixtureRoot -WarningAction SilentlyContinue
        $row = $evidence | Where-Object { $_.control -eq '3.5.3' -and $_.criterion -eq 'V3.3' }
        $row.status | Should -Be 'fail'          # fixture has V3.3 FAIL
        $row.observed | Should -Match 'report-only'
        $row.artifact | Should -Match 'L03'
    }

    It 'emits nothing for criteria that map to no control' {
        $evidence = & $script:Collector -ReportRoot $script:FixtureRoot -WarningAction SilentlyContinue
        $evidence | Where-Object { $_.criterion -eq 'V11.4' } | Should -BeNullOrEmpty
    }

    It 'emits inconclusive for SKIP, never pass' {
        $evidence = & $script:Collector -ReportRoot $script:FixtureRoot -WarningAction SilentlyContinue
        $row = $evidence | Where-Object { $_.criterion -eq 'V4.1' }
        $row.status | Should -Be 'inconclusive'
    }

    It 'emits inconclusive for PENDING, never pass' {
        $evidence = & $script:Collector -ReportRoot $script:FixtureRoot -WarningAction SilentlyContinue
        $row = $evidence | Where-Object { $_.criterion -eq 'V6.3' }
        $row.status | Should -Be 'inconclusive'
    }

    It 'emits one evidence record per mapped control when a criterion declares more than one' {
        $evidence = & $script:Collector -ReportRoot $script:FixtureRoot -WarningAction SilentlyContinue
        $rows = @($evidence | Where-Object { $_.criterion -eq 'V3.1' })
        $rows.Count | Should -Be 2
        @($rows.control | Sort-Object) | Should -Be @('3.5.1', '3.5.2')
        foreach ($row in $rows) {
            $row.criterion | Should -Be 'V3.1'
            $row.status | Should -Be 'pass'
        }
    }

    It 'names the source report as the artifact' {
        $evidence = & $script:Collector -ReportRoot $script:FixtureRoot -WarningAction SilentlyContinue
        $row = $evidence | Where-Object { $_.criterion -eq 'V3.3' }
        $row.artifact | Should -Match 'L03-report\.json$'
    }

    It 'returns every record already carrying source verification-suite' {
        $evidence = & $script:Collector -ReportRoot $script:FixtureRoot -WarningAction SilentlyContinue
        @($evidence).Count | Should -BeGreaterThan 0
        foreach ($row in $evidence) { $row.source | Should -Be 'verification-suite' }
    }

    It 'returns an empty result, without throwing, when no reports are present' {
        # verification/reports/ carries no .json reports today - this is the normal
        # pre-tenant state, not an error.
        $emptyRoot = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath "mls-vs-empty-$([guid]::NewGuid().ToString('n'))"
        New-Item -ItemType Directory -Path $emptyRoot -Force | Out-Null
        try {
            # $script: here, not a bare local - the assertion scriptblock below runs in
            # its own child scope, and a bare `$result = ...` inside it would assign a
            # local that vanishes once the scriptblock returns, leaving the outer $result
            # untouched (still $null, so @($result).Count would read 1, not 0).
            $script:EmptyRootResult = $null
            { $script:EmptyRootResult = & $script:Collector -ReportRoot $emptyRoot } | Should -Not -Throw
            @($script:EmptyRootResult).Count | Should -Be 0
        }
        finally {
            Remove-Item -LiteralPath $emptyRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'returns an empty result, without throwing, when the report root does not exist at all' {
        $missingRoot = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath "mls-vs-missing-$([guid]::NewGuid().ToString('n'))"
        $script:MissingRootResult = $null
        { $script:MissingRootResult = & $script:Collector -ReportRoot $missingRoot } | Should -Not -Throw
        @($script:MissingRootResult).Count | Should -Be 0
    }

    It 'skips an unparsable report and still returns evidence from the good ones' {
        # L99-malformed.json (invalid JSON) lives in the same fixture directory as
        # L03-report.json for every test above; this one asserts the good report's
        # evidence survives its presence explicitly.
        $evidence = & $script:Collector -ReportRoot $script:FixtureRoot -WarningAction SilentlyContinue
        $evidence | Where-Object { $_.criterion -eq 'V3.3' } | Should -Not -BeNullOrEmpty
    }

    It 'skips a well-formed JSON file with no criteria array and still returns the good evidence' {
        # L98-not-a-report.json is valid JSON but not a layer-audit report shape.
        $evidence = & $script:Collector -ReportRoot $script:FixtureRoot -WarningAction SilentlyContinue
        $evidence | Where-Object { $_.criterion -eq 'V3.1' } | Should -Not -BeNullOrEmpty
    }

    It 'a record produced here satisfies a declared criterion in Get-MlsControlStatus end to end' {
        # The join that matters: Task 3's derivation reaches COMPLIANT only through a
        # criterion-scoped record whose `criterion` matches a declared criteria entry.
        $evidence = & $script:Collector -ReportRoot $script:FixtureRoot -WarningAction SilentlyContinue

        $result = Get-MlsControlStatus -Requirement @{ id = '3.5.1' } `
            -Assessment @{ applicability = 'applicable'; criteria = @('V3.1') } `
            -Evidence $evidence

        $result.Status | Should -Be 'COMPLIANT'
        $result.Provenance | Should -Be 'machine-verified'
    }

    It 'a FAIL record produced here derives GAP end to end, never COMPLIANT' {
        $evidence = & $script:Collector -ReportRoot $script:FixtureRoot -WarningAction SilentlyContinue

        $result = Get-MlsControlStatus -Requirement @{ id = '3.5.3' } `
            -Assessment @{ applicability = 'applicable'; criteria = @('V3.3') } `
            -Evidence $evidence

        $result.Status | Should -Be 'GAP'
        $result.Provenance | Should -Be 'machine-verified'
    }
}
