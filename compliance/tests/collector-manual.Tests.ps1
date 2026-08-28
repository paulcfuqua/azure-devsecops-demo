# compliance/tests/collector-manual.Tests.ps1
#
# manual turns an authored assertion in compliance/assessment/*.json (the remediation
# register) into an evidence record - the one collector whose whole job is to transcribe a
# human's claim rather than observe anything itself. The failure modes this suite exists
# to prevent: an assessment with no assertion emitting a record anyway (there is nothing
# authored to say), a manual record naming a criterion (which would let an author's claim
# masquerade as machine-verified), and one bad register file losing the rest of the
# register's evidence.
#
# compliance/tests/fixtures/manual-assessment/ mirrors the real compliance/assessment/
# schema exactly (control, applicability, criteria, assertion{status,evidence,assertedBy,
# assertedAt,rationale}) - including CM-6.json, which mirrors the real register's own
# dangling-id shape (four files keyed on 800-53 ids the 800-171 catalog does not carry).

BeforeAll {
    $script:Collector = Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'collectors', 'manual.ps1'
    $script:FixtureRoot = Join-Path -Path $PSScriptRoot -ChildPath 'fixtures' -AdditionalChildPath 'manual-assessment'

    $script:CatalogPath = Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'catalog', 'nist-800-171r2.json'
    $script:CatalogId = @((Get-Content -LiteralPath $script:CatalogPath -Raw | ConvertFrom-Json).requirements.id)
}

Describe 'manual collector' {

    It 'emits evidence only for assessments carrying an assertion' {
        $e = & $script:Collector -AssessmentRoot $script:FixtureRoot -WarningAction SilentlyContinue
        $e | Where-Object control -eq '3.5.3' | Should -BeNullOrEmpty   # criteria-driven, no assertion
        $e | Where-Object control -eq '3.6.1' | Should -Not -BeNullOrEmpty
    }

    It 'maps an authored CLOSED to pass, naming it an authored assertion, not a verified fact' {
        $e = & $script:Collector -AssessmentRoot $script:FixtureRoot -WarningAction SilentlyContinue
        $row = $e | Where-Object control -eq '3.6.1'
        $row.status | Should -Be 'pass'
        $row.observed | Should -Match 'CLOSED'
        $row.observed | Should -Match 'authored assertion'
        $row.observed | Should -Match '2 evidence reference'
    }

    It 'maps an authored GAP to fail' {
        $e = & $script:Collector -AssessmentRoot $script:FixtureRoot -WarningAction SilentlyContinue
        $row = $e | Where-Object control -eq '3.1.1'
        $row.status | Should -Be 'fail'
        $row.observed | Should -Match 'GAP'
    }

    Context 'offline behaviour - the source (the register directory) absent' {
        It 'returns an empty result, without throwing, when AssessmentRoot does not exist' {
            $missingRoot = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath "mls-manual-missing-$([guid]::NewGuid().ToString('n'))"
            $script:MissingRootResult = $null
            { $script:MissingRootResult = & $script:Collector -AssessmentRoot $missingRoot } | Should -Not -Throw
            @($script:MissingRootResult).Count | Should -Be 0
        }

        It 'returns an empty result, without throwing, when the directory exists but holds no .json files' {
            $emptyRoot = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath "mls-manual-empty-$([guid]::NewGuid().ToString('n'))"
            New-Item -ItemType Directory -Path $emptyRoot -Force | Out-Null
            try {
                $script:EmptyRootResult = $null
                { $script:EmptyRootResult = & $script:Collector -AssessmentRoot $emptyRoot } | Should -Not -Throw
                @($script:EmptyRootResult).Count | Should -Be 0
            }
            finally {
                Remove-Item -LiteralPath $emptyRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Context 'a malformed file does not lose the good ones' {
        It 'skips invalid JSON and a dangling (800-53-keyed) control id, and still returns the good evidence' {
            # Z99-malformed.json is not valid JSON at all; CM-6.json is valid JSON with an
            # assertion, but names a control id the 800-171 catalog does not carry - the
            # same shape as the real register's own CM-6/SI-4/IR-4/CP-9 files. Both must be
            # skipped with a warning, not lose 3.6.1's evidence.
            $e = & $script:Collector -AssessmentRoot $script:FixtureRoot -WarningAction SilentlyContinue
            $e | Where-Object control -eq '3.6.1' | Should -Not -BeNullOrEmpty
            $e | Where-Object control -eq 'CM-6' | Should -BeNullOrEmpty
        }

        It 'warns by name about the dangling control id rather than failing silently' {
            $warning = & $script:Collector -AssessmentRoot $script:FixtureRoot 3>&1 |
                Where-Object { $_ -is [System.Management.Automation.WarningRecord] }
            ($warning -join ' ') | Should -Match 'CM-6'
        }
    }

    Context 'contract conformance' {
        It 'emits only control ids that resolve in the catalog' {
            $e = & $script:Collector -AssessmentRoot $script:FixtureRoot -WarningAction SilentlyContinue
            @($e).Count | Should -BeGreaterThan 0
            foreach ($row in $e) { $script:CatalogId | Should -Contain $row.control }
        }

        It 'never sets a criterion - an authored assertion must never be able to satisfy a declared criterion' {
            $e = & $script:Collector -AssessmentRoot $script:FixtureRoot -WarningAction SilentlyContinue
            foreach ($row in $e) { $row.criterion | Should -BeNullOrEmpty }
        }

        It 'names every record''s source as manual' {
            $e = & $script:Collector -AssessmentRoot $script:FixtureRoot -WarningAction SilentlyContinue
            foreach ($row in $e) { $row.source | Should -Be 'manual' }
        }
    }

    Context 'a manual record can never derive COMPLIANT, end to end' {
        BeforeAll {
            Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'lib', 'MlsCompliance.psm1') -Force
        }
        AfterAll {
            Remove-Module MlsCompliance -Force -ErrorAction SilentlyContinue
        }

        It 'a pass-mapped manual record against a criteria-bearing assessment still derives INCONCLUSIVE, never COMPLIANT' {
            $e = & $script:Collector -AssessmentRoot $script:FixtureRoot -WarningAction SilentlyContinue
            $record = $e | Where-Object control -eq '3.6.1'

            $result = Get-MlsControlStatus -Requirement @{ id = '3.6.1' } `
                -Assessment @{ applicability = 'applicable'; criteria = @('V99.1') } `
                -Evidence @($record)

            $result.Status | Should -Not -Be 'COMPLIANT'
            $result.Provenance | Should -Not -Be 'machine-verified'
        }
    }
}
