# compliance/tests/collector-repo-static.Tests.ps1
#
# repo-static is the only collector that works with no tenant - nothing in this estate
# has ever been deployed, so it is what makes the board demonstrable today. The failure
# mode this suite exists to prevent above all others: a record built from a Bicep file or
# workflow YAML rendering, anywhere on a board, as evidence something is actually running.
# Every fixture tree below lives under compliance/tests/fixtures/repo-static/ and mirrors
# the real repository's own layout (infra/bicep/platform/main.bicep, .github/workflows/
# codeql.yml, .github/dependabot.yml, apps/*/Dockerfile, ...) rather than an invented shape.

BeforeAll {
    $script:Collector = Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'collectors', 'repo-static.ps1'
    $script:FixtureRoot = Join-Path -Path $PSScriptRoot -ChildPath 'fixtures' -AdditionalChildPath 'repo-static'
    $script:FixtureRepoWith = Join-Path -Path $script:FixtureRoot -ChildPath 'compliant'
    $script:FixtureRepoWithout = Join-Path -Path $script:FixtureRoot -ChildPath 'gaps'
    $script:FixtureRepoRootUser = Join-Path -Path $script:FixtureRoot -ChildPath 'root-user'
    $script:FixtureRepoMalformed = Join-Path -Path $script:FixtureRoot -ChildPath 'malformed'

    $script:CatalogPath = Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'catalog', 'nist-800-171r2.json'
    $script:CatalogId = @((Get-Content -LiteralPath $script:CatalogPath -Raw | ConvertFrom-Json).requirements.id)
}

Describe 'repo-static collector' {

    Context 'the brief''s own three tests' {
        It 'reports a gap when the estate has no diagnostic settings' {
            $evidence = & $script:Collector -RepoRoot $script:FixtureRepoWithout -WarningAction SilentlyContinue
            ($evidence | Where-Object control -eq '3.3.1').status | Should -Be 'fail'
        }

        It 'reports compliant once diagnostics are wired' {
            $evidence = & $script:Collector -RepoRoot $script:FixtureRepoWith -WarningAction SilentlyContinue
            ($evidence | Where-Object control -eq '3.3.1').status | Should -Be 'pass'
        }

        It 'flags a frontend Dockerfile with no USER directive' {
            $evidence = & $script:Collector -RepoRoot $script:FixtureRepoRootUser -WarningAction SilentlyContinue
            ($evidence | Where-Object control -eq '3.13.1').status | Should -Be 'fail'
        }
    }

    Context 'the other seven checks, both directions' {
        It 'reports a gap when no SQL audit destination is configured (3.3.2)' {
            $evidence = & $script:Collector -RepoRoot $script:FixtureRepoWithout -WarningAction SilentlyContinue
            ($evidence | Where-Object control -eq '3.3.2').status | Should -Be 'fail'
        }

        It 'reports compliant once isAzureMonitorTargetEnabled is wired (3.3.2)' {
            $evidence = & $script:Collector -RepoRoot $script:FixtureRepoWith -WarningAction SilentlyContinue
            ($evidence | Where-Object control -eq '3.3.2').status | Should -Be 'pass'
        }

        It 'reports a gap when codeql.yml does not exist (3.11.2)' {
            $evidence = & $script:Collector -RepoRoot $script:FixtureRepoWithout -WarningAction SilentlyContinue
            ($evidence | Where-Object control -eq '3.11.2').status | Should -Be 'fail'
        }

        It 'reports compliant once codeql.yml is scheduled (3.11.2)' {
            $evidence = & $script:Collector -RepoRoot $script:FixtureRepoWith -WarningAction SilentlyContinue
            ($evidence | Where-Object control -eq '3.11.2').status | Should -Be 'pass'
        }

        It 'reports a gap when dependabot.yml does not exist (3.14.1)' {
            $evidence = & $script:Collector -RepoRoot $script:FixtureRepoWithout -WarningAction SilentlyContinue
            ($evidence | Where-Object control -eq '3.14.1').status | Should -Be 'fail'
        }

        It 'reports compliant once dependabot.yml covers at least one ecosystem (3.14.1)' {
            $evidence = & $script:Collector -RepoRoot $script:FixtureRepoWith -WarningAction SilentlyContinue
            $row = $evidence | Where-Object control -eq '3.14.1'
            $row.status | Should -Be 'pass'
            $row.observed | Should -Match 'npm'
        }

        It 'reports a gap when gitleaks.yml does not exist (3.13.16)' {
            $evidence = & $script:Collector -RepoRoot $script:FixtureRepoWithout -WarningAction SilentlyContinue
            ($evidence | Where-Object { $_.control -eq '3.13.16' -and $_.observed -match 'gitleaks' }).status | Should -Be 'fail'
        }

        It 'reports compliant once gitleaks.yml scans full history (3.13.16)' {
            $evidence = & $script:Collector -RepoRoot $script:FixtureRepoWith -WarningAction SilentlyContinue
            ($evidence | Where-Object { $_.control -eq '3.13.16' -and $_.observed -match 'gitleaks' }).status | Should -Be 'pass'
        }

        It 'reports a gap when a Bicep output is secret-shaped (3.13.16)' {
            $evidence = & $script:Collector -RepoRoot $script:FixtureRepoWithout -WarningAction SilentlyContinue
            $row = $evidence | Where-Object { $_.control -eq '3.13.16' -and $_.observed -match 'output name' }
            $row.status | Should -Be 'fail'
            $row.observed | Should -Match 'sqlAdminSecret'
        }

        It 'reports compliant when no Bicep output is secret-shaped, and does not false-positive on keyVaultUri (3.13.16)' {
            $evidence = & $script:Collector -RepoRoot $script:FixtureRepoWith -WarningAction SilentlyContinue
            $row = $evidence | Where-Object { $_.control -eq '3.13.16' -and $_.observed -match 'output name' }
            $row.status | Should -Be 'pass'
        }

        It 'reports a gap when .github/rulesets/ has no committed ruleset (3.4.5)' {
            $evidence = & $script:Collector -RepoRoot $script:FixtureRepoWithout -WarningAction SilentlyContinue
            ($evidence | Where-Object control -eq '3.4.5').status | Should -Be 'fail'
        }

        It 'reports compliant once a ruleset config is committed (3.4.5)' {
            $evidence = & $script:Collector -RepoRoot $script:FixtureRepoWith -WarningAction SilentlyContinue
            ($evidence | Where-Object control -eq '3.4.5').status | Should -Be 'pass'
        }
    }

    Context 'offline behaviour - the source (working tree) absent' {
        It 'returns an empty result, without throwing, when RepoRoot does not exist at all' {
            $missingRoot = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath "mls-rs-missing-$([guid]::NewGuid().ToString('n'))"
            $script:MissingRootResult = $null
            { $script:MissingRootResult = & $script:Collector -RepoRoot $missingRoot } | Should -Not -Throw
            @($script:MissingRootResult).Count | Should -Be 0
        }
    }

    Context 'a malformed input does not lose the good records' {
        It 'reports 3.14.1 inconclusive (not fail, not pass) for an unparsable dependabot.yml, while every other check still returns evidence' {
            $evidence = & $script:Collector -RepoRoot $script:FixtureRepoMalformed -WarningAction SilentlyContinue
            ($evidence | Where-Object control -eq '3.14.1').status | Should -Be 'inconclusive'

            # The rest of the malformed fixture is deliberately built like the compliant
            # one - these must still be present and correct despite the broken dependabot.yml.
            ($evidence | Where-Object control -eq '3.3.1').status | Should -Be 'pass'
            ($evidence | Where-Object control -eq '3.11.2').status | Should -Be 'pass'
            @($evidence).Count | Should -BeGreaterThan 5
        }
    }

    Context 'contract conformance' {
        It 'emits only control ids that resolve in the catalog' {
            $evidence = & $script:Collector -RepoRoot $script:FixtureRepoWith -WarningAction SilentlyContinue
            @($evidence).Count | Should -BeGreaterThan 0
            foreach ($row in $evidence) {
                $script:CatalogId | Should -Contain $row.control
            }
        }

        It 'never sets a criterion - repo-static observes a control directly, not a Verifier criterion' {
            $evidence = & $script:Collector -RepoRoot $script:FixtureRepoWith -WarningAction SilentlyContinue
            foreach ($row in $evidence) {
                $row.criterion | Should -BeNullOrEmpty
            }
        }

        It 'names every record''s source as repo-static' {
            $evidence = & $script:Collector -RepoRoot $script:FixtureRepoWith -WarningAction SilentlyContinue
            foreach ($row in $evidence) {
                $row.source | Should -Be 'repo-static'
            }
        }
    }

    Context 'observed text distinguishes declared-in-IaC from deployed' {
        It 'every record says what the repository declares and explicitly denies deployment, on both the pass and the gap fixtures' {
            $evidence = @() + (& $script:Collector -RepoRoot $script:FixtureRepoWith -WarningAction SilentlyContinue) +
                (& $script:Collector -RepoRoot $script:FixtureRepoWithout -WarningAction SilentlyContinue)
            @($evidence).Count | Should -BeGreaterThan 0
            foreach ($row in $evidence) {
                $row.observed | Should -Match 'declares' -Because "a repo-static record must say what the REPOSITORY declares: $($row.control)/$($row.status)"
                $row.observed | Should -Match 'not.*deployed' -Because "a repo-static record must explicitly deny this is deployed evidence: $($row.control)/$($row.status)"
            }
        }

        It 'never asserts deployment as a bare positive claim (only ever inside the "not what is deployed" denial)' {
            $evidence = & $script:Collector -RepoRoot $script:FixtureRepoWith -WarningAction SilentlyContinue
            foreach ($row in $evidence) {
                # The only permitted appearance of "is deployed" is inside the honesty
                # clause itself ("not what is deployed ... has been deployed"), which
                # always pairs it with an explicit negation nearby. Strip that clause out
                # and confirm nothing claiming deployment survives.
                $withoutHonestyClause = $row.observed -replace [regex]::Escape(
                    'This describes what the repository declares, not what is deployed ' +
                    '- nothing in this estate has been deployed, so it is not evidence anything runs.'
                ), ''
                $withoutHonestyClause | Should -Not -Match 'deploy' -Because 'a repo-static finding must never claim deployment outside the fixed honesty clause'
            }
        }
    }
}
