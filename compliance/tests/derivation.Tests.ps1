# compliance/tests/derivation.Tests.ps1
#
# Get-MlsControlStatus is the one place a control's rendered status and its
# provenance are decided, so this suite is heavier than the code volume suggests.
# The failure mode it exists to prevent is a wrong green box: an authored claim
# rendered as if a machine had checked it.

BeforeAll {
    $script:ModulePath = Join-Path $PSScriptRoot '..' 'lib' 'MlsCompliance.psm1'
    Import-Module $script:ModulePath -Force
    $script:AssessmentRoot = Join-Path $PSScriptRoot '..' 'assessment'

    # Every derivation here is for one requirement; the id is incidental to the
    # decision and is factored out so the cases read as behaviour.
    function script:Invoke-Derivation {
        param($Assessment, $Evidence = @(), $RequirementId = '3.5.3')
        Get-MlsControlStatus -Requirement @{ id = $RequirementId } `
            -Assessment $Assessment -Evidence $Evidence
    }
}

AfterAll {
    Remove-Module MlsCompliance -Force -ErrorAction SilentlyContinue
}

Describe 'Get-MlsControlStatus' {

    # Spec section 3.4's table, as amended by the plan-owner rulings of 2026-08-28.
    #
    # Ruling A: the derived Status enum is COMPLIANT | PARTIAL | GAP | INCONCLUSIVE |
    #   NOT_APPLICABLE | NOT_ASSESSED.
    # Ruling B: the REGISTER vocabulary (GAP | CLOSED, per compliance/README.md) and the
    #   DERIVED vocabulary are different things. The derivation MAPS between them, never
    #   passes assertion.status through, and may derive COMPLIANT only from machine
    #   evidence.
    $derivationCases = @(
        @{ Name = 'not-applicable with a justification'
           Assessment = @{ applicability = 'not-applicable'; naJustification = 'no on-prem component' }
           Evidence = @(); Status = 'NOT_APPLICABLE'; Provenance = 'declared' }

        @{ Name = 'not-applicable without a justification'
           Assessment = @{ applicability = 'not-applicable' }
           Evidence = @(); Status = 'NOT_ASSESSED'; Provenance = 'none' }

        @{ Name = 'criteria, all present and passing'
           Assessment = @{ applicability = 'applicable'; criteria = @('V3.3') }
           Evidence = @(@{ criterion = 'V3.3'; status = 'pass' })
           Status = 'COMPLIANT'; Provenance = 'machine-verified' }

        @{ Name = 'criteria, any failing'
           Assessment = @{ applicability = 'applicable'; criteria = @('V3.3', 'V3.4') }
           Evidence = @(@{ criterion = 'V3.3'; status = 'pass' }, @{ criterion = 'V3.4'; status = 'fail' })
           Status = 'GAP'; Provenance = 'machine-verified' }

        @{ Name = 'criteria, any inconclusive'
           Assessment = @{ applicability = 'applicable'; criteria = @('V3.3') }
           Evidence = @(@{ criterion = 'V3.3'; status = 'inconclusive' })
           Status = 'INCONCLUSIVE'; Provenance = 'machine-verified' }

        @{ Name = 'criteria, any skipped'
           Assessment = @{ applicability = 'applicable'; criteria = @('V3.3', 'V3.4') }
           Evidence = @(@{ criterion = 'V3.3'; status = 'pass' }, @{ criterion = 'V3.4'; status = 'skip' })
           Status = 'INCONCLUSIVE'; Provenance = 'machine-verified' }

        @{ Name = 'criteria, any missing entirely'
           Assessment = @{ applicability = 'applicable'; criteria = @('V3.3', 'V3.4') }
           Evidence = @(@{ criterion = 'V3.3'; status = 'pass' })
           Status = 'INCONCLUSIVE'; Provenance = 'machine-verified' }

        @{ Name = 'criteria, a failure outranks a missing criterion'
           Assessment = @{ applicability = 'applicable'; criteria = @('V3.3', 'V3.4') }
           Evidence = @(@{ criterion = 'V3.4'; status = 'fail' })
           Status = 'GAP'; Provenance = 'machine-verified' }

        @{ Name = 'no criteria, an authored CLOSED citing evidence'
           Assessment = @{ applicability = 'applicable'; criteria = @()
                           assertion = @{ status = 'CLOSED'; evidence = @('SECURITY.md') } }
           Evidence = @(); Status = 'PARTIAL'; Provenance = 'asserted' }

        @{ Name = 'no criteria, an authored GAP citing evidence'
           Assessment = @{ applicability = 'applicable'; criteria = @()
                           assertion = @{ status = 'GAP'; evidence = @('SECURITY.md', 'commit abc1234') } }
           Evidence = @(); Status = 'GAP'; Provenance = 'asserted' }

        @{ Name = 'no criteria, an authored CLOSED citing nothing'
           Assessment = @{ applicability = 'applicable'; criteria = @()
                           assertion = @{ status = 'CLOSED'; evidence = @() } }
           Evidence = @(); Status = 'NOT_ASSESSED'; Provenance = 'none' }

        @{ Name = 'no criteria, an assertion citing nothing'
           Assessment = @{ applicability = 'applicable'; criteria = @()
                           assertion = @{ status = 'COMPLIANT'; evidence = @() } }
           Evidence = @(); Status = 'NOT_ASSESSED'; Provenance = 'none' }

        @{ Name = 'no criteria and no assertion'
           Assessment = @{ applicability = 'applicable'; criteria = @() }
           Evidence = @(); Status = 'NOT_ASSESSED'; Provenance = 'none' }

        @{ Name = 'nothing at all'
           Assessment = $null
           Evidence = @(); Status = 'NOT_ASSESSED'; Provenance = 'none' }
    )

    It 'derives <Name> correctly' -ForEach $derivationCases {
        $r = Get-MlsControlStatus -Requirement @{ id = '3.5.3' } -Assessment $Assessment -Evidence $Evidence
        $r.Status     | Should -Be $Status
        $r.Provenance | Should -Be $Provenance
    }

    It 'fails closed when a not-applicable has no justification' {
        $r = Get-MlsControlStatus -Requirement @{ id = '3.10.1' } `
            -Assessment @{ applicability = 'not-applicable' } -Evidence @()
        $r.Status | Should -Be 'NOT_ASSESSED'
        $r.Status | Should -Not -Be 'NOT_APPLICABLE'
    }

    It 'fails closed when a not-applicable justification is <Label>' -ForEach @(
        @{ Label = 'empty';      Justification = '' }
        @{ Label = 'whitespace'; Justification = '   ' }
        @{ Label = 'null';       Justification = $null }
    ) {
        $r = Invoke-Derivation -Assessment @{ applicability = 'not-applicable'; naJustification = $Justification }
        $r.Status     | Should -Be 'NOT_ASSESSED' -Because "a $Label justification justifies nothing"
        $r.Provenance | Should -Be 'none'
    }

    It 'ignores evidence for criteria the assessment does not claim' {
        # Stray evidence must not silently upgrade a control.
        $r = Get-MlsControlStatus -Requirement @{ id = '3.5.3' } `
            -Assessment @{ applicability = 'applicable'; criteria = @() } `
            -Evidence @(@{ criterion = 'V3.3'; status = 'pass' })
        $r.Status     | Should -Be 'NOT_ASSESSED'
        $r.Provenance | Should -Be 'none'
        @($r.Observed).Count | Should -Be 0 -Because 'unclaimed evidence is discarded, not shown as working'
    }

    It 'ignores stray passing evidence alongside claimed criteria' {
        $r = Invoke-Derivation `
            -Assessment @{ applicability = 'applicable'; criteria = @('V3.3') } `
            -Evidence @(@{ criterion = 'V9.9'; status = 'pass' })
        $r.Status | Should -Be 'INCONCLUSIVE' -Because 'V3.3 was never collected and V9.9 is not claimed'
        @($r.Observed).Criterion | Should -Not -Contain 'V9.9'
    }
}

Describe 'the honesty invariant' {

    # The generated space: every assessment shape carrying NO criteria, crossed with every
    # assertion status - the two real ones, the three the plan's prose assumed, and
    # nonsense the register could never legitimately hold - crossed with several evidence
    # sets and several applicability values. Both halves must hold for every combination.
    BeforeAll {
        $script:AssertionStatuses = @(
            'CLOSED', 'GAP',                          # the register's real vocabulary
            'COMPLIANT', 'PARTIAL', 'NOT_ASSESSED',   # derived-vocabulary words, wrongly authored
            'closed', 'Gap',                          # case variants
            'ACCEPTED_RISK', 'true', '', '   ',       # nonsense
            $null, 1, @('CLOSED'), @{ status = 'CLOSED' }
        )
        $script:EvidenceSets = @(
            @(),
            @('SECURITY.md'),
            @('SECURITY.md', 'commit abc1234'),
            @('compliance/findings/2026-08-26-prepublication-review.md#f1'),
            $null
        )
        # Three distinct ways an assessment can carry no criteria.
        $script:NoCriteriaShapes = @(
            @{ Label = 'criteria absent'; Build = { param($a) @{ applicability = $a } } }
            @{ Label = 'criteria empty';  Build = { param($a) @{ applicability = $a; criteria = @() } } }
            @{ Label = 'criteria null';   Build = { param($a) @{ applicability = $a; criteria = $null } } }
        )
        $script:Applicabilities = @('applicable', 'not-applicable', 'APPLICABLE', 'bogus', '')

        function script:Get-GeneratedAssertionSpace {
            foreach ($shape in $script:NoCriteriaShapes) {
                foreach ($applicability in $script:Applicabilities) {
                    foreach ($status in $script:AssertionStatuses) {
                        foreach ($evidence in $script:EvidenceSets) {
                            $assessment = & $shape.Build $applicability
                            $assessment['assertion'] = @{ status = $status; evidence = $evidence }
                            [pscustomobject]@{
                                Label      = ("$($shape.Label), applicability='$applicability', " +
                                              "status='$status', $(@($evidence).Count) evidence")
                                Assessment = $assessment
                            }
                        }
                    }
                }
            }
        }
    }

    It 'covers a space of at least 200 generated assessments' {
        # If the generator silently collapses, the two invariants below would pass
        # vacuously. Pin the size so that failure is loud.
        @(Get-GeneratedAssertionSpace).Count | Should -BeGreaterThan 200
    }

    It 'INVARIANT 1: an authored assertion is never machine-verified' {
        foreach ($case in Get-GeneratedAssertionSpace) {
            $r = Get-MlsControlStatus -Requirement @{ id = '3.6.1' } `
                -Assessment $case.Assessment -Evidence @()
            $r.Provenance | Should -Not -Be 'machine-verified' `
                -Because "an authored assertion ($($case.Label)) must never claim machine verification"
        }
    }

    It 'INVARIANT 2: an authored assertion never derives COMPLIANT' {
        foreach ($case in Get-GeneratedAssertionSpace) {
            $r = Get-MlsControlStatus -Requirement @{ id = '3.6.1' } `
                -Assessment $case.Assessment -Evidence @()
            $r.Status | Should -Not -Be 'COMPLIANT' -Because (
                "the register's CLOSED means 'no known open finding', which is weaker than " +
                "'the control is met'; deriving COMPLIANT from an authored status ($($case.Label)) " +
                'would launder the weaker claim into the stronger one')
        }
    }

    It 'INVARIANT 3: every derived status and provenance sits inside the published vocabulary' {
        $vocabulary = Get-MlsComplianceVocabulary
        foreach ($case in Get-GeneratedAssertionSpace) {
            $r = Get-MlsControlStatus -Requirement @{ id = '3.6.1' } `
                -Assessment $case.Assessment -Evidence @()
            $r.Status     | Should -BeIn $vocabulary.Status -Because $case.Label
            $r.Provenance | Should -BeIn $vocabulary.Provenance -Because $case.Label
        }
    }

    It 'never emits a register word as a derived status' {
        # CLOSED belongs to neither enum. Passing assertion.status through would emit it.
        foreach ($status in @('CLOSED', 'closed', 'GAP')) {
            $r = Get-MlsControlStatus -Requirement @{ id = '3.6.1' } `
                -Assessment @{ applicability = 'applicable'; criteria = @()
                               assertion = @{ status = $status; evidence = @('SECURITY.md') } } `
                -Evidence @()
            $r.Status | Should -Not -Be 'CLOSED'
        }
    }

    It 'derives COMPLIANT only when every claimed criterion was collected and passed' {
        # The positive half of invariant 2: the one branch that may produce COMPLIANT.
        $passing = Get-MlsControlStatus -Requirement @{ id = '3.5.3' } `
            -Assessment @{ applicability = 'applicable'; criteria = @('V3.3', 'V3.4') } `
            -Evidence @(@{ criterion = 'V3.3'; status = 'pass' }, @{ criterion = 'V3.4'; status = 'pass' })
        $passing.Status     | Should -Be 'COMPLIANT'
        $passing.Provenance | Should -Be 'machine-verified'

        foreach ($degraded in @(
                @(@{ criterion = 'V3.3'; status = 'pass' }),
                @(@{ criterion = 'V3.3'; status = 'pass' }, @{ criterion = 'V3.4'; status = 'skip' }),
                @(@{ criterion = 'V3.3'; status = 'pass' }, @{ criterion = 'V3.4'; status = 'fail' }),
                @())) {
            $r = Get-MlsControlStatus -Requirement @{ id = '3.5.3' } `
                -Assessment @{ applicability = 'applicable'; criteria = @('V3.3', 'V3.4') } `
                -Evidence $degraded
            $r.Status | Should -Not -Be 'COMPLIANT' -Because 'one claimed criterion was not collected and passing'
        }
    }
}

Describe 'the published vocabulary' {
    It 'declares exactly the six derived statuses' {
        (Get-MlsComplianceVocabulary).Status |
            Should -Be @('COMPLIANT', 'PARTIAL', 'GAP', 'INCONCLUSIVE', 'NOT_APPLICABLE', 'NOT_ASSESSED')
    }

    It 'declares exactly the four provenances' {
        (Get-MlsComplianceVocabulary).Provenance |
            Should -Be @('machine-verified', 'asserted', 'declared', 'none')
    }

    It 'keeps the register vocabulary separate and admits COMPLIANT to neither side wrongly' {
        $vocabulary = Get-MlsComplianceVocabulary
        $vocabulary.RegisterStatus | Should -Be @('GAP', 'CLOSED')
        $vocabulary.RegisterStatus | Should -Not -Contain 'COMPLIANT'
        $vocabulary.Status         | Should -Not -Contain 'CLOSED'
    }

    It 'returns exactly the three declared fields and no blended percentage' {
        $r = Get-MlsControlStatus -Requirement @{ id = '3.5.3' } `
            -Assessment @{ applicability = 'applicable'; criteria = @('V3.3') } `
            -Evidence @(@{ criterion = 'V3.3'; status = 'pass' })
        $r.PSObject.Properties.Name | Should -Be @('Status', 'Provenance', 'Observed')
        foreach ($name in $r.PSObject.Properties.Name) {
            $name | Should -Not -Match 'percent|score|ratio|rate'
        }
    }
}

Describe 'purity' {
    It 'returns an identical result when called twice with the same inputs' {
        $assessment = @{ applicability = 'applicable'; criteria = @('V3.3', 'V3.4')
                         assertion = @{ status = 'CLOSED'; evidence = @('SECURITY.md') } }
        $evidence = @(
            @{ criterion = 'V3.3'; status = 'pass'; observed = 'policy enforced'; source = 'verification-suite' },
            @{ criterion = 'V3.4'; status = 'fail'; observed = 'policy absent';   source = 'verification-suite' }
        )
        $first  = Invoke-Derivation -Assessment $assessment -Evidence $evidence
        $second = Invoke-Derivation -Assessment $assessment -Evidence $evidence
        ($first | ConvertTo-Json -Depth 10) | Should -Be ($second | ConvertTo-Json -Depth 10)
    }

    It 'keeps no state across calls: interleaved unrelated calls do not change the answer' {
        $assessment = @{ applicability = 'applicable'; criteria = @('V3.3') }
        $evidence = @(@{ criterion = 'V3.3'; status = 'pass' })
        $before = Invoke-Derivation -Assessment $assessment -Evidence $evidence
        $null = Invoke-Derivation -Assessment @{ applicability = 'not-applicable'; naJustification = 'x' }
        $null = Invoke-Derivation -Assessment $null
        $null = Invoke-Derivation -Assessment @{ applicability = 'applicable'; criteria = @('V9.9') }
        $after = Invoke-Derivation -Assessment $assessment -Evidence $evidence
        ($after | ConvertTo-Json -Depth 10) | Should -Be ($before | ConvertTo-Json -Depth 10)
    }

    It 'does not mutate the assessment or the evidence it was given' {
        $assessment = @{ applicability = 'applicable'; criteria = @('V3.3', 'V3.4')
                         assertion = @{ status = 'CLOSED'; evidence = @('SECURITY.md') } }
        $evidence = @(@{ criterion = 'V3.3'; status = 'pass'; observed = 'ok' })
        $assessmentBefore = $assessment | ConvertTo-Json -Depth 10
        $evidenceBefore   = $evidence   | ConvertTo-Json -Depth 10
        $null = Invoke-Derivation -Assessment $assessment -Evidence $evidence
        ($assessment | ConvertTo-Json -Depth 10) | Should -Be $assessmentBefore
        ($evidence   | ConvertTo-Json -Depth 10) | Should -Be $evidenceBefore
    }

    It 'reads nothing outside its arguments: no file, network, clock or environment call' {
        # A pure function is what makes the honesty rules mechanical rather than a matter
        # of review discipline, so the ban is asserted against the source, not assumed.
        $source = Get-Content $script:ModulePath -Raw
        # Strip block and line comments so the module's own documentation of what it does
        # not do cannot trip the check.
        $code = [regex]::Replace($source, '(?s)<#.*?#>', '')
        $code = [regex]::Replace($code, '(?m)#.*$', '')
        $code.Trim() | Should -Not -BeNullOrEmpty -Because 'the comment strip must not eat the whole module'
        foreach ($forbidden in @(
                'Get-Content', 'Set-Content', 'Out-File', 'Import-Csv', 'Test-Path',
                'Get-ChildItem', 'Invoke-RestMethod', 'Invoke-WebRequest', 'Invoke-Expression',
                'Get-Date', 'Start-Sleep', 'Get-Random', 'Read-Host',
                '\$env:', '\$script:', '\$global:')) {
            $code | Should -Not -Match $forbidden `
                -Because "a pure derivation must not reach for $forbidden"
        }
    }
}

Describe 'failing closed on unrecognised input' {

    It 'fails closed on an unknown applicability even when every criterion passes' {
        $r = Invoke-Derivation `
            -Assessment @{ applicability = 'maybe'; criteria = @('V3.3') } `
            -Evidence @(@{ criterion = 'V3.3'; status = 'pass' })
        $r.Status     | Should -Be 'NOT_ASSESSED'
        $r.Provenance | Should -Be 'none'
    }

    It 'fails closed when applicability is missing entirely' {
        $r = Invoke-Derivation -Assessment @{ criteria = @('V3.3') } `
            -Evidence @(@{ criterion = 'V3.3'; status = 'pass' })
        $r.Status | Should -Be 'NOT_ASSESSED'
    }

    It 'treats an unrecognised register status (<Label>) citing evidence as INCONCLUSIVE' -ForEach @(
        @{ Label = 'COMPLIANT';     Authored = 'COMPLIANT' }
        @{ Label = 'PARTIAL';       Authored = 'PARTIAL' }
        @{ Label = 'ACCEPTED_RISK'; Authored = 'ACCEPTED_RISK' }
        @{ Label = 'empty string';  Authored = '' }
        @{ Label = 'null';          Authored = $null }
        @{ Label = 'a number';      Authored = 42 }
    ) {
        $r = Invoke-Derivation -Assessment @{
            applicability = 'applicable'; criteria = @()
            assertion = @{ status = $Authored; evidence = @('SECURITY.md') } }
        $r.Status     | Should -Be 'INCONCLUSIVE'
        $r.Provenance | Should -Be 'asserted'
    }

    It 'reads an outcome of <Label> as <Expected>' -ForEach @(
        @{ Label = 'pass';         Raw = 'pass';    Expected = 'COMPLIANT' }
        @{ Label = 'PASS';         Raw = 'PASS';    Expected = 'COMPLIANT' }
        @{ Label = 'padded pass';  Raw = ' pass ';  Expected = 'COMPLIANT' }
        @{ Label = 'fail';         Raw = 'fail';    Expected = 'GAP' }
        @{ Label = 'FAIL';         Raw = 'FAIL';    Expected = 'GAP' }
        @{ Label = 'passed';       Raw = 'passed';  Expected = 'INCONCLUSIVE' }
        @{ Label = 'ok';           Raw = 'ok';      Expected = 'INCONCLUSIVE' }
        @{ Label = 'true';         Raw = 'true';    Expected = 'INCONCLUSIVE' }
        @{ Label = 'PENDING';      Raw = 'PENDING'; Expected = 'INCONCLUSIVE' }
        @{ Label = 'empty string'; Raw = '';        Expected = 'INCONCLUSIVE' }
        @{ Label = 'null';         Raw = $null;     Expected = 'INCONCLUSIVE' }
        @{ Label = 'a boolean';    Raw = $true;     Expected = 'INCONCLUSIVE' }
    ) {
        $r = Invoke-Derivation -Assessment @{ applicability = 'applicable'; criteria = @('V3.3') } `
            -Evidence @(@{ criterion = 'V3.3'; status = $Raw })
        $r.Status | Should -Be $Expected
    }

    It 'survives malformed evidence (<Label>) without throwing and without upgrading' -ForEach @(
        @{ Label = 'a null record';          Record = $null }
        @{ Label = 'a bare string';          Record = 'V3.3 passed' }
        @{ Label = 'a number';               Record = 7 }
        @{ Label = 'no criterion key';       Record = @{ status = 'pass' } }
        @{ Label = 'no status key';          Record = @{ criterion = 'V3.3' } }
        @{ Label = 'a null criterion';       Record = @{ criterion = $null; status = 'pass' } }
        @{ Label = 'a non-string criterion'; Record = @{ criterion = 3.3; status = 'pass' } }
        @{ Label = 'an empty hashtable';     Record = @{} }
    ) {
        $r = Invoke-Derivation -Assessment @{ applicability = 'applicable'; criteria = @('V3.3') } `
            -Evidence @($Record)
        $r.Status     | Should -Be 'INCONCLUSIVE' -Because "$Label evidences nothing about V3.3"
        $r.Provenance | Should -Not -Be 'asserted'
    }

    It 'survives a malformed criteria declaration (<Label>)' -ForEach @(
        @{ Label = 'a null entry';    Criteria = @($null) }
        @{ Label = 'an empty string'; Criteria = @('') }
        @{ Label = 'whitespace';      Criteria = @('   ') }
        @{ Label = 'a nested array';  Criteria = @(, @('V3.3')) }
    ) {
        $r = Invoke-Derivation -Assessment @{ applicability = 'applicable'; criteria = $Criteria } `
            -Evidence @(@{ criterion = 'V3.3'; status = 'pass' })
        $r.Status | Should -Be 'INCONCLUSIVE' -Because "$Label declares no criterion that can be matched"
    }

    It 'survives a malformed assertion block (<Label>)' -ForEach @(
        @{ Label = 'a bare string'; Assertion = 'CLOSED' }
        @{ Label = 'a number';      Assertion = 3 }
        @{ Label = 'an array';      Assertion = @('CLOSED') }
        @{ Label = 'empty';         Assertion = @{} }
    ) {
        $r = Invoke-Derivation -Assessment @{ applicability = 'applicable'; criteria = @(); assertion = $Assertion }
        $r.Status     | Should -Not -Be 'COMPLIANT'
        $r.Provenance | Should -Not -Be 'machine-verified'
    }

    It 'does not mistake an assertion citing only blanks for one carrying evidence: <Label>' -ForEach @(
        @{ Label = 'one null';        Citations = @($null) }
        @{ Label = 'nulls and blanks'; Citations = @($null, '', '   ') }
        @{ Label = 'a lone blank';    Citations = @('  ') }
    ) {
        $r = Invoke-Derivation -Assessment @{
            applicability = 'applicable'; criteria = @()
            assertion = @{ status = 'CLOSED'; evidence = $Citations } }
        $r.Status     | Should -Be 'NOT_ASSESSED' -Because "$Label cites nothing"
        $r.Provenance | Should -Be 'none'
    }

    It 'counts only the usable citations when some are blank' {
        $r = Invoke-Derivation -Assessment @{
            applicability = 'applicable'; criteria = @()
            assertion = @{ status = 'CLOSED'; evidence = @('SECURITY.md', '', $null) } }
        $r.Status             | Should -Be 'PARTIAL'
        $r.Observed[0].Detail | Should -Match 'citing 1 evidence'
    }

    It 'sees a single-element criteria list as a claimed criterion, not as a scalar' {
        # PowerShell unrolls a collection on output, so a field reader that returns one
        # without comma-wrapping turns @($null) into $null and a nested array into its
        # contents - both of which silently change the branch that fires.
        $r = Invoke-Derivation -Assessment @{ applicability = 'applicable'; criteria = @('V3.3') } `
            -Evidence @(@{ criterion = 'V3.3'; status = 'pass' })
        $r.Status | Should -Be 'COMPLIANT'
        @($r.Observed).Count | Should -Be 1
    }

    It 'survives an assessment object with no properties at all' {
        $r = Invoke-Derivation -Assessment @{}
        $r.Status     | Should -Be 'NOT_ASSESSED'
        $r.Provenance | Should -Be 'none'
    }

    It 'survives a null evidence collection and an omitted -Evidence argument' {
        $assessment = @{ applicability = 'applicable'; criteria = @('V3.3') }
        (Invoke-Derivation -Assessment $assessment -Evidence $null).Status | Should -Be 'INCONCLUSIVE'
        (Get-MlsControlStatus -Requirement @{ id = '3.5.3' } -Assessment $assessment).Status |
            Should -Be 'INCONCLUSIVE'
    }

    It 'fails closed when the assessment was authored against a different control' {
        # Deriving control X's status from control Y's assessment is a wrong box even when
        # the assessment itself is well formed.
        $r = Get-MlsControlStatus -Requirement @{ id = '3.8.9' } `
            -Assessment @{ control = 'CP-9'; applicability = 'applicable'; criteria = @()
                           assertion = @{ status = 'CLOSED'; evidence = @('SECURITY.md') } } `
            -Evidence @()
        $r.Status     | Should -Be 'NOT_ASSESSED'
        $r.Provenance | Should -Be 'none'
        @($r.Observed).Kind | Should -Contain 'mismatch'
    }

    It 'accepts an assessment whose control matches the requirement' {
        $r = Get-MlsControlStatus -Requirement @{ id = 'CP-9' } `
            -Assessment @{ control = 'CP-9'; applicability = 'applicable'; criteria = @()
                           assertion = @{ status = 'CLOSED'; evidence = @('SECURITY.md') } } `
            -Evidence @()
        $r.Status | Should -Be 'PARTIAL'
    }
}

Describe 'Observed, the working the decision rested on' {

    It 'carries one row per declared criterion, in declared order' {
        $r = Invoke-Derivation `
            -Assessment @{ applicability = 'applicable'; criteria = @('V3.3', 'V3.4') } `
            -Evidence @(
                @{ criterion = 'V3.4'; status = 'fail'; observed = 'policy absent'
                   source = 'verification-suite'; artifact = 'verification/reports/L03.md'
                   collectedAt = '2026-08-26T14:20:02Z' },
                @{ criterion = 'V3.3'; status = 'pass'; observed = 'policy enforced'
                   source = 'verification-suite' })
        @($r.Observed).Count     | Should -Be 2
        @($r.Observed).Criterion | Should -Be @('V3.3', 'V3.4')
        $r.Observed[0].Kind        | Should -Be 'criterion'
        $r.Observed[0].Outcome     | Should -Be 'pass'
        $r.Observed[0].Detail      | Should -Be 'policy enforced'
        $r.Observed[1].Outcome     | Should -Be 'fail'
        $r.Observed[1].Artifact    | Should -Be 'verification/reports/L03.md'
        $r.Observed[1].CollectedAt | Should -Be '2026-08-26T14:20:02Z'
    }

    It 'shows a missing criterion as missing rather than omitting it' {
        $r = Invoke-Derivation `
            -Assessment @{ applicability = 'applicable'; criteria = @('V3.3', 'V3.4') } `
            -Evidence @(@{ criterion = 'V3.3'; status = 'pass' })
        @($r.Observed).Count     | Should -Be 2
        $r.Observed[1].Criterion | Should -Be 'V3.4'
        $r.Observed[1].Outcome   | Should -Be 'missing'
    }

    It 'shows every record when a criterion was collected twice, worst outcome winning' {
        $r = Invoke-Derivation `
            -Assessment @{ applicability = 'applicable'; criteria = @('V3.3') } `
            -Evidence @(@{ criterion = 'V3.3'; status = 'pass' }, @{ criterion = 'V3.3'; status = 'fail' })
        $r.Status | Should -Be 'GAP' -Because 'corroboration cannot erase a failure'
        @($r.Observed).Count | Should -Be 2
    }

    It 'names the authored status on the asserted path without adopting it' {
        $r = Invoke-Derivation -Assessment @{
            applicability = 'applicable'; criteria = @()
            assertion = @{ status = 'CLOSED'; evidence = @('SECURITY.md', 'commit abc1234') } }
        @($r.Observed).Count  | Should -Be 1
        $r.Observed[0].Kind   | Should -Be 'assertion'
        $r.Observed[0].Source | Should -Be 'assessment-register'
        $r.Observed[0].Detail | Should -Match 'CLOSED'
        $r.Observed[0].Detail | Should -Match '2'
        $r.Status             | Should -Be 'PARTIAL'
    }

    It 'carries the justification on the declared path' {
        $r = Invoke-Derivation -Assessment @{
            applicability = 'not-applicable'; naJustification = 'the estate has no on-prem component' }
        @($r.Observed).Count  | Should -Be 1
        $r.Observed[0].Kind   | Should -Be 'justification'
        $r.Observed[0].Detail | Should -Be 'the estate has no on-prem component'
    }

    It 'is an empty collection when nothing was assessed' {
        @((Invoke-Derivation -Assessment $null).Observed).Count | Should -Be 0
        @((Invoke-Derivation -Assessment @{ applicability = 'applicable'; criteria = @() }).Observed).Count |
            Should -Be 0
    }

    It 'gives every row on the <Label> branch the same shape' -ForEach @(
        @{ Label = 'criterion'
           Assessment = @{ applicability = 'applicable'; criteria = @('V3.3') }
           Evidence = @(@{ criterion = 'V3.3'; status = 'pass' }) }
        @{ Label = 'assertion'
           Assessment = @{ applicability = 'applicable'; criteria = @()
                           assertion = @{ status = 'GAP'; evidence = @('SECURITY.md') } }
           Evidence = @() }
        @{ Label = 'justification'
           Assessment = @{ applicability = 'not-applicable'; naJustification = 'out of scope' }
           Evidence = @() }
    ) {
        $r = Invoke-Derivation -Assessment $Assessment -Evidence $Evidence
        @($r.Observed).Count | Should -BeGreaterThan 0
        foreach ($row in @($r.Observed)) {
            $row.PSObject.Properties.Name |
                Should -Be @('Kind', 'Criterion', 'Outcome', 'Detail', 'Source', 'Artifact', 'CollectedAt')
        }
    }
}

Describe 'the real remediation register' {

    It 'derives a status inside the vocabulary for every committed record, without throwing' {
        $files = @(Get-ChildItem $script:AssessmentRoot -Filter *.json)
        $files.Count | Should -BeGreaterThan 0
        $vocabulary = Get-MlsComplianceVocabulary
        foreach ($file in $files) {
            $assessment = Get-Content $file.FullName -Raw | ConvertFrom-Json
            $r = Get-MlsControlStatus -Requirement @{ id = $assessment.control } `
                -Assessment $assessment -Evidence @()
            $r.Status     | Should -BeIn $vocabulary.Status -Because $file.Name
            $r.Provenance | Should -BeIn $vocabulary.Provenance -Because $file.Name
        }
    }

    It 'renders nothing in the register as COMPLIANT or machine-verified' {
        # Every committed record carries criteria:[] today, so every one takes an authored
        # path. Task 5's collector is what starts populating the other one.
        foreach ($file in @(Get-ChildItem $script:AssessmentRoot -Filter *.json)) {
            $assessment = Get-Content $file.FullName -Raw | ConvertFrom-Json
            $r = Get-MlsControlStatus -Requirement @{ id = $assessment.control } `
                -Assessment $assessment -Evidence @()
            $r.Status     | Should -Not -Be 'COMPLIANT' -Because "$($file.Name) is an authored assertion"
            $r.Provenance | Should -Not -Be 'machine-verified' -Because "$($file.Name) is an authored assertion"
        }
    }

    It 'maps every authored CLOSED to PARTIAL and every authored GAP to GAP' {
        # Counts derived from the files, never hardcoded, so this cannot go stale as the
        # register changes.
        #
        # `$expectedGap | Should -BeGreaterThan 0` used to sit alongside the partial
        # guard below, and it went red the day the register's last GAP closed (F19,
        # 2026-08-28 - the seventh workload RBAC grant, which was F13's last open
        # contributor against 3.1.1/3.1.2/3.1.5). That assertion was checking the
        # register's COMPOSITION, not this function's MAPPING: it encoded "some finding
        # is always open", which is not a property the derivation has or should have.
        # The non-vacuity it was there to provide is now supplied by a synthetic GAP
        # record below, which exercises the same branch without requiring the estate to
        # stay broken for the test to pass.
        $expectedPartial = 0
        $expectedGap = 0
        $actualPartial = 0
        $actualGap = 0
        foreach ($file in @(Get-ChildItem $script:AssessmentRoot -Filter *.json)) {
            $assessment = Get-Content $file.FullName -Raw | ConvertFrom-Json
            switch ($assessment.assertion.status) {
                'CLOSED' { $expectedPartial++ }
                'GAP'    { $expectedGap++ }
            }
            $r = Get-MlsControlStatus -Requirement @{ id = $assessment.control } `
                -Assessment $assessment -Evidence @()
            $r.Provenance | Should -Be 'asserted' -Because "$($file.Name) cites evidence but declares no criteria"
            switch ($r.Status) {
                'PARTIAL' { $actualPartial++ }
                'GAP'     { $actualGap++ }
            }
        }
        $expectedPartial | Should -BeGreaterThan 0
        $actualPartial   | Should -Be $expectedPartial
        $actualGap       | Should -Be $expectedGap

        # The GAP branch, exercised on a record shaped exactly like a real one. This is
        # what keeps the mapping honest once every committed record reads CLOSED.
        $syntheticGap = @{
            control       = '3.1.1'
            applicability = 'applicable'
            criteria      = @()
            assertion     = @{
                status   = 'GAP'
                evidence = @('compliance/findings/2026-08-26-prepublication-review.md#f13')
            }
        }
        $gapResult = Get-MlsControlStatus -Requirement @{ id = '3.1.1' } `
            -Assessment $syntheticGap -Evidence @()
        $gapResult.Status     | Should -Be 'GAP'
        $gapResult.Provenance | Should -Be 'asserted'
    }
}

Describe 'provenance answers how we know, not how we intended to know' {
    BeforeAll { Import-Module (Join-Path $PSScriptRoot '..' 'lib' 'MlsCompliance.psm1') -Force }

    It 'claims machine-verified only when at least one claimed criterion matched a record' {
        # A control declaring criteria that no collector produced anything for used to
        # derive INCONCLUSIVE / machine-verified. Nothing was machine-verified. Left as
        # it was, a collector outage that emitted zero records would still have counted
        # every such control as machine-verified in the board's provenance totals.
        $result = Get-MlsControlStatus -Requirement @{ id = '3.5.3' } `
            -Assessment @{ applicability = 'applicable'; criteria = @('V3.3') } -Evidence @()

        $result.Status | Should -Be 'INCONCLUSIVE'
        $result.Provenance | Should -Be 'none' -Because 'no record was collected, so no machine verified anything'
    }

    It 'still claims machine-verified when only some claimed criteria were collected' {
        # Partial collection is genuine machine evidence; the gap is already visible as a
        # 'missing' row in Observed, so the provenance need not be downgraded.
        $result = Get-MlsControlStatus -Requirement @{ id = '3.5.3' } `
            -Assessment @{ applicability = 'applicable'; criteria = @('V3.3', 'V3.4') } `
            -Evidence @(@{ criterion = 'V3.3'; status = 'pass' })

        $result.Status | Should -Be 'INCONCLUSIVE'
        $result.Provenance | Should -Be 'machine-verified'
        @($result.Observed | Where-Object { $_.Outcome -eq 'missing' }).Count |
            Should -Be 1 -Because 'the uncollected criterion stays visible'
    }

    It 'a fully collected passing set is still COMPLIANT / machine-verified' {
        $result = Get-MlsControlStatus -Requirement @{ id = '3.5.3' } `
            -Assessment @{ applicability = 'applicable'; criteria = @('V3.3') } `
            -Evidence @(@{ criterion = 'V3.3'; status = 'pass' })

        $result.Status | Should -Be 'COMPLIANT'
        $result.Provenance | Should -Be 'machine-verified'
    }
}
