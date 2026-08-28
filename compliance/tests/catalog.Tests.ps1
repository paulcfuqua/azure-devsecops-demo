# compliance/tests/catalog.Tests.ps1
BeforeAll {
    $script:CatalogPath = Join-Path $PSScriptRoot '..' 'catalog' 'nist-800-171r2.json'
    $script:Catalog = if (Test-Path $script:CatalogPath) {
        Get-Content $script:CatalogPath -Raw | ConvertFrom-Json
    }
    $script:ExpectedCounts = @{
        '3.1' = 22; '3.2' = 3;  '3.3' = 9;  '3.4' = 9;  '3.5' = 11
        '3.6' = 3;  '3.7' = 6;  '3.8' = 9;  '3.9' = 2;  '3.10' = 6
        '3.11' = 3; '3.12' = 4; '3.13' = 16; '3.14' = 7
    }
}

Describe 'the 800-171 catalog' {
    It 'declares the framework identifier the mapping keys are stated against' {
        $script:Catalog.framework | Should -Be 'nist-800-171r2'
    }

    It 'contains exactly 110 requirements' {
        @($script:Catalog.requirements).Count | Should -Be 110
    }

    It 'has the right count in every family' {
        foreach ($family in $script:ExpectedCounts.Keys) {
            $actual = @($script:Catalog.requirements | Where-Object { $_.family -eq $family }).Count
            $actual | Should -Be $script:ExpectedCounts[$family] -Because "family $family"
        }
    }

    It 'has no duplicate requirement ids' {
        $ids = @($script:Catalog.requirements.id)
        ($ids | Sort-Object -Unique).Count | Should -Be $ids.Count
    }

    It 'numbers every family contiguously from 1' {
        # A family whose ids run 1,2,3,5 has the right shape and the wrong content:
        # 3.1.4 is missing and some later id was invented to keep the count. The
        # per-family count alone cannot see that, so assert the sequence itself.
        foreach ($family in $script:ExpectedCounts.Keys) {
            $ordinals = @($script:Catalog.requirements |
                Where-Object { $_.family -eq $family } |
                ForEach-Object { [int]($_.id -replace '^3\.\d+\.', '') } |
                Sort-Object)
            $expected = @(1..$script:ExpectedCounts[$family])
            ($ordinals -join ',') | Should -Be ($expected -join ',') -Because "family $family must run 1..$($script:ExpectedCounts[$family]) with no gaps"
        }
    }

    It 'derives every requirement id from its own family' {
        foreach ($r in $script:Catalog.requirements) {
            $r.id | Should -BeLike "$($r.family).*" -Because "requirement $($r.id) claims family $($r.family)"
        }
    }

    It 'gives every requirement a non-empty title' {
        foreach ($r in $script:Catalog.requirements) {
            $r.title | Should -Not -BeNullOrEmpty -Because "requirement $($r.id)"
        }
    }

    It 'names each family identically on every requirement in it' {
        # familyName is denormalised onto each requirement so the board can render
        # a row without a second lookup. Denormalised data drifts; two spellings of
        # "Access Control" would split one family into two columns.
        foreach ($family in $script:ExpectedCounts.Keys) {
            $names = @($script:Catalog.requirements |
                Where-Object { $_.family -eq $family } |
                ForEach-Object { $_.familyName } |
                Sort-Object -Unique)
            $names.Count | Should -Be 1 -Because "family $family must carry one familyName, found: $($names -join ' | ')"
            $names[0] | Should -Not -BeNullOrEmpty -Because "family $family"
        }
    }

    It 'uses only the agreed framework keys in mappings' {
        $allowed = @('nist-800-53r5', 'cmmc-2.0', 'far-52.204-21')
        foreach ($r in $script:Catalog.requirements) {
            foreach ($key in $r.mappings.PSObject.Properties.Name) {
                $key | Should -BeIn $allowed -Because "requirement $($r.id)"
            }
        }
    }

    It 'maps every requirement to its identical CMMC 2.0 Level 2 practice' {
        # CMMC 2.0 L2 IS the 110 requirements of 800-171 Rev 2 - an identity
        # mapping. Any requirement missing one is a transcription error.
        foreach ($r in $script:Catalog.requirements) {
            @($r.mappings.'cmmc-2.0') | Should -Contain "L2-$($r.id)" -Because "requirement $($r.id)"
        }
    }

    It 'maps every requirement to at least one 800-53 control' {
        # 800-171 derives from the 800-53 moderate baseline; Appendix D maps
        # each requirement to its parents. An empty mapping means unfinished
        # transcription, not an absent relationship.
        foreach ($r in $script:Catalog.requirements) {
            @($r.mappings.'nist-800-53r5').Count | Should -BeGreaterThan 0 -Because "requirement $($r.id)"
        }
    }

    It 'cites exactly the 15 FAR 52.204-21 basic safeguarding requirements' {
        # FAR 52.204-21(b)(1) has fifteen items. Counting distinct clause
        # references - not requirements - is what "the 15 basic safeguards"
        # means; see the requirement-count assertion below for why the two
        # numbers differ.
        $clauses = @($script:Catalog.requirements |
            ForEach-Object { $_.mappings.'far-52.204-21' } |
            Where-Object { $_ } |
            Sort-Object -Unique)
        $clauses.Count | Should -Be 15
    }

    It 'marks the 17 requirements that carry a CMMC Level 1 practice' {
        # CMMC 2.0 Level 1 is 17 practices, not 15: FAR 52.204-21(b)(1)(ix)
        # ("escort visitors and monitor visitor activity; maintain audit logs of
        # physical access; and control and manage physical access devices") is one
        # clause covering three 800-171 requirements - 3.10.3, 3.10.4 and 3.10.5.
        # Trimming this to 15 to match the clause count would silently drop two
        # real Level 1 practices.
        $l1 = @($script:Catalog.requirements | Where-Object { @($_.mappings.'far-52.204-21').Count -gt 0 })
        $l1.Count | Should -Be 17
    }

    It 'gives every FAR-mapped requirement its CMMC Level 1 practice, and no other requirement one' {
        foreach ($r in $script:Catalog.requirements) {
            $hasFar = @($r.mappings.'far-52.204-21').Count -gt 0
            $hasL1 = @($r.mappings.'cmmc-2.0') -contains "L1-$($r.id)"
            $hasL1 | Should -Be $hasFar -Because "requirement $($r.id): CMMC L1 and FAR 52.204-21 coverage are the same set"
        }
    }
}
