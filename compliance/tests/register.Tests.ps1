# compliance/tests/register.Tests.ps1
BeforeAll {
    $script:Root = Join-Path $PSScriptRoot '..' 'assessment'
    $script:Findings = Join-Path $PSScriptRoot '..' 'findings' '2026-08-26-prepublication-review.md'
}

Describe 'remediation register' {
    It 'has an assessment file for every control named in the findings table' {
        $expected = @('3.1.1','3.1.2','3.1.3','3.1.5','3.1.6','3.1.7',
                      '3.3.1','3.3.2','3.3.5','3.5.1','3.12.1','3.12.3',
                      '3.13.1','3.13.16','3.14.1',
                      'CM-6','SI-4','IR-4','CP-9')
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

    It 'the narrative findings record covers every finding it claims to, with no gaps' {
        # Derived from the file, never hardcoded. A literal count went stale at 18
        # while the register reached 23, leaving F19-F23 with no structural guard -
        # including F23, whose #f23 anchor compliance/assessment/CM-6.json cites as
        # evidence. Deleting that section would have kept this suite green and left
        # a dangling evidence pointer.
        Test-Path $script:Findings | Should -BeTrue
        $body = Get-Content $script:Findings -Raw

        $numbers = @([regex]::Matches($body, '(?m)^#+\s*F(\d+)\b') |
            ForEach-Object { [int]$_.Groups[1].Value } |
            Sort-Object -Unique)
        $numbers.Count | Should -BeGreaterThan 0 -Because 'the register must contain findings'

        # Contiguous from F1: a missing number means a section was removed or
        # renumbered without the register noticing.
        $missing = @(1..($numbers[-1]) | Where-Object { $_ -notin $numbers })
        $missing | Should -BeNullOrEmpty -Because 'finding numbers must run contiguously from F1'
    }

    It 'every assessment record asserts a permitted status - GAP or CLOSED, never COMPLIANT' {
        # The absence of this assertion is why compliance/README.md drifted into
        # claiming every record was GAP long after 16 were CLOSED. CLOSED means "no
        # known open finding", deliberately weaker than "the control is met";
        # COMPLIANT is a claim this register never makes, because an authored
        # assertion cannot carry machine-verified provenance (spec 3.4).
        $records = @(Get-ChildItem $script:Root -Filter *.json)
        $records.Count | Should -BeGreaterThan 0

        foreach ($file in $records) {
            $record = Get-Content $file.FullName -Raw | ConvertFrom-Json
            $record.assertion.status |
                Should -BeIn @('GAP', 'CLOSED') -Because "$($file.Name) must assert a permitted status"
        }
    }
}
