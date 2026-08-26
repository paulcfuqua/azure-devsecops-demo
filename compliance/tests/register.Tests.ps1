# compliance/tests/register.Tests.ps1
BeforeAll {
    $script:Root = Join-Path $PSScriptRoot '..' 'assessment'
    $script:Findings = Join-Path $PSScriptRoot '..' 'findings' '2026-08-26-prepublication-review.md'
}

Describe 'remediation register' {
    It 'has an assessment file for every control named in the findings table' {
        $expected = @('3.1.1','3.1.2','3.1.3','3.1.5','3.1.6','3.1.7',
                      '3.3.1','3.3.2','3.3.5','3.5.1','3.12.1','3.12.3',
                      '3.13.1','3.13.16','3.14.1')
        foreach ($c in $expected) {
            Test-Path (Join-Path $script:Root "$c.json") | Should -BeTrue -Because "$c is cited by a finding"
        }
    }

    It 'produces valid JSON with the required fields' {
        foreach ($f in Get-ChildItem $script:Root -Filter *.json) {
            $r = Get-Content $f.FullName -Raw | ConvertFrom-Json
            $r.control       | Should -Not -BeNullOrEmpty
            $r.applicability | Should -BeIn @('applicable','not-applicable')
            $r.recommendation| Should -Not -BeNullOrEmpty
        }
    }

    It 'never marks not-applicable without a justification' {
        foreach ($f in Get-ChildItem $script:Root -Filter *.json) {
            $r = Get-Content $f.FullName -Raw | ConvertFrom-Json
            if ($r.applicability -eq 'not-applicable') {
                $r.naJustification | Should -Not -BeNullOrEmpty
            }
        }
    }

    It 'every assertion cites at least one piece of evidence' {
        foreach ($f in Get-ChildItem $script:Root -Filter *.json) {
            $r = Get-Content $f.FullName -Raw | ConvertFrom-Json
            if ($null -ne $r.assertion) {
                @($r.assertion.evidence).Count | Should -BeGreaterThan 0
            }
        }
    }

    It 'the narrative findings record exists and covers all 15' {
        Test-Path $script:Findings | Should -BeTrue
        $body = Get-Content $script:Findings -Raw
        1..15 | ForEach-Object { $body | Should -Match "(?m)^#+\s*F$_\b" }
    }
}
