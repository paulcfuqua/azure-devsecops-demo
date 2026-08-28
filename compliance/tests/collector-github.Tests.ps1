# compliance/tests/collector-github.Tests.ps1
#
# github-security reports real GHAS posture from GitHub's `security_and_analysis` API
# shape - genuine external state, unlike repo-static's repository-declares-it checks. It
# never calls the network: -Response takes an already-deserialised fixture so every test
# runs offline. The failure mode this suite exists to prevent: a missing or partial
# response rendering as a silent pass, and one bad field costing the other control its
# otherwise-good record.

BeforeAll {
    $script:Collector = Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'collectors', 'github-security.ps1'
    $script:FixtureRoot = Join-Path -Path $PSScriptRoot -ChildPath 'fixtures'

    function Get-MlsGithubFixture {
        param([string]$Name)
        Get-Content -LiteralPath (Join-Path -Path $script:FixtureRoot -ChildPath $Name) -Raw | ConvertFrom-Json
    }

    $script:CatalogPath = Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'catalog', 'nist-800-171r2.json'
    $script:CatalogId = @((Get-Content -LiteralPath $script:CatalogPath -Raw | ConvertFrom-Json).requirements.id)
}

Describe 'github-security collector' {

    It 'reports secret scanning and push protection state' {
        $fixture = Get-MlsGithubFixture 'github-security-enabled.json'
        $e = & $script:Collector -Response $fixture
        ($e | Where-Object control -eq '3.13.16').status | Should -Be 'pass'
    }

    It 'reports a gap when Dependabot security updates are disabled' {
        $fixture = Get-MlsGithubFixture 'github-security-dependabot-disabled.json'
        $e = & $script:Collector -Response $fixture
        ($e | Where-Object control -eq '3.14.1').status | Should -Be 'fail'
    }

    It 'reports a gap when secret scanning and push protection are disabled' {
        $fixture = Get-MlsGithubFixture 'github-security-secret-scanning-disabled.json'
        $e = & $script:Collector -Response $fixture
        ($e | Where-Object control -eq '3.13.16').status | Should -Be 'fail'
    }

    It 'reports compliant Dependabot security updates when enabled' {
        $fixture = Get-MlsGithubFixture 'github-security-enabled.json'
        $e = & $script:Collector -Response $fixture
        ($e | Where-Object control -eq '3.14.1').status | Should -Be 'pass'
    }

    Context 'offline behaviour - the source (GitHub API) absent' {
        It 'returns an empty result, without throwing, when no response was supplied' {
            $script:Result = $null
            { $script:Result = & $script:Collector } | Should -Not -Throw
            @($script:Result).Count | Should -Be 0
        }

        It 'returns an empty result when the response carries no security_and_analysis block at all' {
            $e = & $script:Collector -Response ([pscustomobject]@{ full_name = 'x/y' })
            @($e).Count | Should -Be 0
        }
    }

    Context 'a malformed / partial response does not lose the good record' {
        It 'reports 3.13.16 inconclusive when push protection is absent, while 3.14.1 still reports its own good record' {
            $fixture = Get-MlsGithubFixture 'github-security-partial.json'
            $e = & $script:Collector -Response $fixture -WarningAction SilentlyContinue
            ($e | Where-Object control -eq '3.13.16').status | Should -Be 'inconclusive'
            ($e | Where-Object control -eq '3.14.1').status | Should -Be 'pass'
        }
    }

    Context 'contract conformance' {
        It 'emits only control ids that resolve in the catalog' {
            $fixture = Get-MlsGithubFixture 'github-security-enabled.json'
            $e = & $script:Collector -Response $fixture
            @($e).Count | Should -BeGreaterThan 0
            foreach ($row in $e) { $script:CatalogId | Should -Contain $row.control }
        }

        It 'never sets a criterion - github-security observes a control directly' {
            $fixture = Get-MlsGithubFixture 'github-security-enabled.json'
            $e = & $script:Collector -Response $fixture
            foreach ($row in $e) { $row.criterion | Should -BeNullOrEmpty }
        }

        It 'names every record''s source as github-security' {
            $fixture = Get-MlsGithubFixture 'github-security-enabled.json'
            $e = & $script:Collector -Response $fixture
            foreach ($row in $e) { $row.source | Should -Be 'github-security' }
        }
    }
}
