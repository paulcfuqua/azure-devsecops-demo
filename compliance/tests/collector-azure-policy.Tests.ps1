# compliance/tests/collector-azure-policy.Tests.ps1
#
# azure-policy joins Azure Policy compliance state back to the 800-171 catalog through the
# built-in NIST SP 800-53 Rev. 5 initiative's policyDefinitionGroupNames (which, for that
# specific initiative, ARE the 800-53 control ids Task 1's catalog already maps). Nothing
# in this estate has been deployed, so today this collector collects nothing - a clean
# empty result, never an error. The other failure mode this suite exists to prevent: an
# audit-mode (DoNotEnforce) initiative's "Compliant" rows rendering as a machine-verified
# pass, when they are a scorecard nothing is actually enforcing.

BeforeAll {
    $script:Collector = Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'collectors', 'azure-policy.ps1'
    $script:FixtureRoot = Join-Path -Path $PSScriptRoot -ChildPath 'fixtures'

    function Get-MlsAzurePolicyFixture {
        param([string]$Name)
        Get-Content -LiteralPath (Join-Path -Path $script:FixtureRoot -ChildPath $Name) -Raw | ConvertFrom-Json
    }

    $script:CatalogPath = Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'catalog', 'nist-800-171r2.json'
    $script:CatalogId = @((Get-Content -LiteralPath $script:CatalogPath -Raw | ConvertFrom-Json).requirements.id)
}

Describe 'azure-policy collector' {

    It 'maps a non-compliant policy assignment to its control' {
        $fixture = Get-MlsAzurePolicyFixture 'azure-policy-noncompliant.json'
        $e = & $script:Collector -Response $fixture
        ($e | Where-Object control -eq '3.13.1').status | Should -Be 'fail'
    }

    It 'also fans the same policy state row out to a second mapped control (3.13.2, same SC-7 group)' {
        $fixture = Get-MlsAzurePolicyFixture 'azure-policy-noncompliant.json'
        $e = & $script:Collector -Response $fixture
        ($e | Where-Object control -eq '3.13.2').status | Should -Be 'fail'
    }

    It 'reports pass for a genuinely compliant, enforced row' {
        $fixture = Get-MlsAzurePolicyFixture 'azure-policy-noncompliant.json'
        $e = & $script:Collector -Response $fixture
        # AU-6 in this fixture is Compliant under an enforced (Default) assignment.
        ($e | Where-Object control -eq '3.3.2').status | Should -Be 'pass'
    }

    It 'reports inconclusive when the initiative is in DoNotEnforce' {
        # An audit-mode initiative produces a scorecard, not a control. Rendering
        # its "compliant" rows as machine-verified compliance would be false.
        $fixture = Get-MlsAzurePolicyFixture 'azure-policy-auditmode.json'
        $e = & $script:Collector -Response $fixture
        ($e | Where-Object control -eq '3.13.1').status | Should -Be 'inconclusive'
    }

    It 'never reports pass for a DoNotEnforce row even though complianceState says Compliant' {
        $fixture = Get-MlsAzurePolicyFixture 'azure-policy-auditmode.json'
        $e = & $script:Collector -Response $fixture
        $e | Where-Object { $_.status -eq 'pass' } | Should -BeNullOrEmpty
    }

    Context 'offline behaviour - the source (a live tenant) absent' {
        It 'returns an empty result, without throwing, when no response was supplied - nothing has been deployed yet' {
            $script:Result = $null
            { $script:Result = & $script:Collector } | Should -Not -Throw
            @($script:Result).Count | Should -Be 0
        }

        It 'returns an empty result when the response carries no policyStates at all' {
            $e = & $script:Collector -Response ([pscustomobject]@{ assignment = @{ enforcementMode = 'Default' } })
            @($e).Count | Should -Be 0
        }
    }

    Context 'a malformed row does not lose the good one' {
        It 'skips a row with no policyDefinitionGroupNames and still returns the good row''s evidence' {
            $fixture = Get-MlsAzurePolicyFixture 'azure-policy-mixed-malformed.json'
            $e = & $script:Collector -Response $fixture -WarningAction SilentlyContinue
            ($e | Where-Object control -eq '3.13.1').status | Should -Be 'fail'
        }
    }

    Context 'contract conformance' {
        It 'emits only control ids that resolve in the catalog' {
            $fixture = Get-MlsAzurePolicyFixture 'azure-policy-noncompliant.json'
            $e = & $script:Collector -Response $fixture
            @($e).Count | Should -BeGreaterThan 0
            foreach ($row in $e) { $script:CatalogId | Should -Contain $row.control }
        }

        It 'never sets a criterion - azure-policy observes a control directly' {
            $fixture = Get-MlsAzurePolicyFixture 'azure-policy-noncompliant.json'
            $e = & $script:Collector -Response $fixture
            foreach ($row in $e) { $row.criterion | Should -BeNullOrEmpty }
        }

        It 'names every record''s source as azure-policy' {
            $fixture = Get-MlsAzurePolicyFixture 'azure-policy-noncompliant.json'
            $e = & $script:Collector -Response $fixture
            foreach ($row in $e) { $row.source | Should -Be 'azure-policy' }
        }
    }
}
