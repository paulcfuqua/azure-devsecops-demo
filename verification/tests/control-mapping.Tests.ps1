# Pester tests for Invoke-MlsCriterion's -Control parameter: the referential-integrity
# contract (every mapped id must exist in Task 1's catalog) and the coverage contract
# (every criterion in every layer audit must declare a Control decision, even an empty
# one). See docs/superpowers/specs/2026-08-26-compliance-platform-design.md section 4.2 and
# .superpowers/sdd/2026-08-26-compliance-platform/task-2-brief.md.

BeforeAll {
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'MlsAudit.psm1') -Force
    Set-StrictMode -Off

    $script:ReportRoot = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath "mls-control-mapping-tests-$([guid]::NewGuid().ToString('n'))"
    $script:RepoRoot = Split-Path -Path $PSScriptRoot -Parent | Split-Path -Parent
    $script:CatalogPath = Join-Path -Path $script:RepoRoot -ChildPath 'compliance' -AdditionalChildPath 'catalog', 'nist-800-171r2.json'
    $script:Catalog = Get-Content -LiteralPath $script:CatalogPath -Raw | ConvertFrom-Json
    $script:ValidId = [System.Collections.Generic.HashSet[string]]::new(
        [string[]]@($script:Catalog.requirements.id), [StringComparer]::Ordinal
    )

    function New-TestContext {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Pure builder: returns an in-memory audit context and changes no state anywhere.')]
        param([int]$Layer = 1)
        return New-MlsAuditContext -Layer $Layer -Title 'unit test' -ScriptName 'test.ps1' -ReportRoot $script:ReportRoot
    }
}

AfterAll {
    if (Test-Path -LiteralPath $script:ReportRoot) {
        Remove-Item -LiteralPath $script:ReportRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    Remove-Module 'MlsAudit' -Force -ErrorAction SilentlyContinue
}

Describe 'criterion to control mapping' {
    BeforeEach {
        Mock Write-MlsStatus {} -ModuleName 'MlsAudit'
        Mock Wait-MlsRetryInterval {} -ModuleName 'MlsAudit'
    }

    It 'records the Control field on the criterion row' {
        $context = New-TestContext
        Invoke-MlsCriterion -Context $context -Id 'V1.1' -Control @('3.5.3') `
            -Description 'd' -Command 'c' -Expected 'e' `
            -Test { New-MlsCheckResult -Passed $true -Observed 'o' } | Out-Null
        (@($context.Criterion)[0]).Control | Should -Be @('3.5.3')
    }

    It 'accepts more than one control id' {
        $context = New-TestContext
        Invoke-MlsCriterion -Context $context -Id 'V1.1' -Control @('3.5.1', '3.5.2') `
            -Description 'd' -Command 'c' -Expected 'e' `
            -Test { New-MlsCheckResult -Passed $true -Observed 'o' } | Out-Null
        (@($context.Criterion)[0]).Control | Should -Be @('3.5.1', '3.5.2')
    }

    It 'defaults to an empty array when -Control is omitted (the parameter is genuinely optional)' {
        $context = New-TestContext
        $row = Invoke-MlsCriterion -Context $context -Id 'V1.2' -Description 'd' -Command 'c' -Expected 'e' `
            -Test { New-MlsCheckResult -Passed $true -Observed 'o' }
        @($row.Control).Count | Should -Be 0
        $row.Status | Should -Be 'PASS'
        $row.Id | Should -Be 'V1.2'
    }

    It 'accepts an explicit empty array as a deliberate zero-mapping decision' {
        $context = New-TestContext
        $row = Invoke-MlsCriterion -Context $context -Id 'V1.3' -Control @() -Description 'd' -Command 'c' -Expected 'e' `
            -Test { New-MlsCheckResult -Passed $true -Observed 'o' }
        @($row.Control).Count | Should -Be 0
    }

    It 'rejects a control id that is not in the catalog' {
        # Referential integrity in the authoring direction: a typo must fail loudly rather
        # than silently evidencing nothing.
        $context = New-TestContext
        { Invoke-MlsCriterion -Context $context -Id 'V1.4' -Control @('3.99.99') `
                -Description 'd' -Command 'c' -Expected 'e' `
                -Test { New-MlsCheckResult -Passed $true -Observed 'o' } } | Should -Throw '*3.99.99*'
    }

    It 'rejects a bad id even when it is mixed in with valid ones' {
        $context = New-TestContext
        { Invoke-MlsCriterion -Context $context -Id 'V1.1' -Control @('3.5.1', 'not-a-real-id') `
                -Description 'd' -Command 'c' -Expected 'e' `
                -Test { New-MlsCheckResult -Passed $true -Observed 'o' } } | Should -Throw '*not-a-real-id*'
    }

    It 'does not add the rejected row to the context (validation happens before the row is recorded)' {
        $context = New-TestContext
        { Invoke-MlsCriterion -Context $context -Id 'V1.1' -Control @('3.99.99') `
                -Description 'd' -Command 'c' -Expected 'e' `
                -Test { New-MlsCheckResult -Passed $true -Observed 'o' } } | Should -Throw
        @($context.Criterion).Count | Should -Be 0
    }

    It 'every -Control value resolves to a real requirement id in the NIST SP 800-171 catalog' {
        # Cross-check every id actually used across all 11 layer audits, not just the ids
        # exercised by the two happy-path tests above.
        $sources = Get-ChildItem (Join-Path $PSScriptRoot '..') -Filter 'layer-*-audit.ps1'
        $used = [System.Collections.Generic.List[string]]::new()
        foreach ($file in $sources) {
            $body = Get-Content $file.FullName -Raw
            foreach ($match in [regex]::Matches($body, "-Control\s+@\(([^)]*)\)")) {
                foreach ($idMatch in [regex]::Matches($match.Groups[1].Value, "'([^']+)'")) {
                    $used.Add($idMatch.Groups[1].Value)
                }
            }
        }
        $used.Count | Should -BeGreaterThan 0
        $bad = @($used | Where-Object { -not $script:ValidId.Contains($_) })
        $bad | Should -BeNullOrEmpty -Because "the following -Control ids do not appear in $($script:CatalogPath): $($bad -join ', ')"
    }

    It 'every criterion in every layer audit declares a Control decision' {
        # Either it maps to >=1 control, or it explicitly maps to none via -Control @().
        # Silence (omitting -Control entirely) is not allowed on a real call site - that is
        # how coverage quietly rots. (Invoke-MlsCriterion itself still treats a genuinely
        # omitted -Control as the same safe empty default, for third-party/future callers -
        # this test enforces the stronger house rule that every call site in THIS repo's
        # audits makes the decision explicit.)
        $sources = Get-ChildItem (Join-Path $PSScriptRoot '..') -Filter 'layer-*-audit.ps1'
        foreach ($file in $sources) {
            $body = Get-Content $file.FullName -Raw
            $calls = [regex]::Matches($body, "Invoke-MlsCriterion[^`n]*(`n[^`n]*)*?-Test")
            $calls.Count | Should -BeGreaterThan 0 -Because "$($file.Name) should contain at least one Invoke-MlsCriterion call"
            foreach ($call in $calls) {
                $call.Value | Should -Match '-Control' -Because "$($file.Name) has a criterion with no Control decision: $($call.Value.Substring(0, [Math]::Min(80, $call.Value.Length)))"
            }
        }
    }

    It 'the emitted row carries Control as a string array, the shape the verification-suite collector reads' {
        $context = New-TestContext
        $row = Invoke-MlsCriterion -Context $context -Id 'V1.1' -Control @('3.5.1', '3.5.2') `
            -Description 'd' -Command 'c' -Expected 'e' `
            -Test { New-MlsCheckResult -Passed $true -Observed 'o' }
        $row.Control -is [array] | Should -BeTrue
        $row.Control | Should -BeOfType [string]
    }

    It 'round-trips the Control mapping through Write-MlsReport''s JSON sibling' {
        $context = New-TestContext
        Invoke-MlsCriterion -Context $context -Id 'V1.1' -Control @('3.5.2') `
            -Description 'd' -Command 'c' -Expected 'e' `
            -Test { New-MlsCheckResult -Passed $true -Observed 'o' } | Out-Null
        Invoke-MlsCriterion -Context $context -Id 'V1.3' -Control @() `
            -Description 'd' -Command 'c' -Expected 'e' `
            -Test { New-MlsCheckResult -Passed $true -Observed 'o' } | Out-Null
        $report = Write-MlsReport -Context $context -Timestamp '20260827-000000Z'
        $document = Get-Content -LiteralPath $report.JsonPath -Raw | ConvertFrom-Json
        $mapped = @($document.criteria | Where-Object { $_.Id -eq 'V1.1' })[0]
        $unmapped = @($document.criteria | Where-Object { $_.Id -eq 'V1.3' })[0]
        @($mapped.Control) | Should -Be @('3.5.2')
        @($unmapped.Control).Count | Should -Be 0
    }
}
