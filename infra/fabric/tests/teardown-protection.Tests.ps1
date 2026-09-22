# Pester tests for infra/fabric/teardown-protection.ps1 - TDS mocked; zero cloud calls.
#
# The interesting assertions here are NEGATIVE. This teardown removes PROTECTION, never
# DATA: hr_roster and defect_reports belong to L5, and a teardown that dropped them would
# turn "remove the access controls" into "destroy the demo dataset".

BeforeAll {
    $env:MLS_SKIP_MAIN = '1'
    . (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'teardown-protection.ps1') `
        -SqlEndpoint 'endpoint.invalid' -AccessToken 'tok-dummy'
    . (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'protect-tables.ps1') `
        -SqlEndpoint 'endpoint.invalid' -AccessToken 'tok-dummy'
    # No Set-StrictMode -Off (F49).
    $script:Prefix = 'acme'
}

Describe 'Get-TeardownStatement' {
    Context 'order' {
        It 'drops the security policy before the objects it binds to' {
            # A view bound by a live security policy cannot be dropped, and a predicate
            # in use by one cannot either. Order here is not cosmetic.
            $keys = @((Get-TeardownStatement -Prefix $script:Prefix).Key)
            $keys.IndexOf('rls_policy') | Should -BeLessThan $keys.IndexOf('rls_view')
            $keys.IndexOf('rls_policy') | Should -BeLessThan $keys.IndexOf('rls_predicate')
        }

        It 'revokes permissions before dropping the roles that hold them' {
            $keys = @((Get-TeardownStatement -Prefix $script:Prefix).Key)
            $keys.IndexOf('revoke_standard') | Should -BeLessThan $keys.IndexOf('role_standard')
            $keys.IndexOf('revoke_privileged') | Should -BeLessThan $keys.IndexOf('role_privileged')
        }
    }

    Context 'completeness - every object protect-tables creates has a drop' {
        It 'removes both roles, the policy, the view and the predicate' {
            $dropped = @((Get-TeardownStatement -Prefix $script:Prefix).Key)
            foreach ($key in 'rls_policy', 'rls_view', 'rls_predicate', 'role_standard', 'role_privileged') {
                $dropped | Should -Contain $key `
                    -Because 'an object created by the deploy and missed by the teardown survives as an orphan the next rebuild collides with'
            }
        }

        It 'names every object protect-tables.ps1 creates' {
            # The two scripts are deliberate duplicates rather than one importing the
            # other, so nothing but a test keeps them in step - the same reasoning, and
            # the same hazard, as the Purview taxonomy duplicated across labels.ps1,
            # teardown.ps1 and layer-04-audit.ps1.
            $teardownSql = (Get-TeardownStatement -Prefix $script:Prefix | ForEach-Object Sql) -join "`n"
            foreach ($object in 'sp_defect_tier', 'v_defect_reports', 'fn_defect_tier',
                'acme_data_standard', 'acme_data_privileged') {
                $teardownSql | Should -Match ([regex]::Escape($object))
            }
        }
    }

    Context 'it removes protection, never data' {
        It 'issues no DROP TABLE at all' {
            $sql = (Get-TeardownStatement -Prefix $script:Prefix | ForEach-Object Sql) -join "`n"
            $sql | Should -Not -Match 'DROP\s+TABLE'
        }

        It 'never drops or truncates either seeded table' {
            $sql = (Get-TeardownStatement -Prefix $script:Prefix | ForEach-Object Sql) -join "`n"
            $sql | Should -Not -Match 'DROP\s+.*\bhr_roster\b'
            $sql | Should -Not -Match 'DROP\s+.*\bdefect_reports\b'
            $sql | Should -Not -Match 'TRUNCATE'
            $sql | Should -Not -Match 'DELETE\s+FROM'
        }

        It 'drops only the view this estate created, never the base table of the same subject' {
            $view = Get-TeardownStatement -Prefix $script:Prefix | Where-Object Key -eq 'rls_view'
            $view.Sql | Should -Match 'v_defect_reports'
            # dbo.defect_reports and dbo.v_defect_reports differ by four characters.
            $view.Sql | Should -Not -Match 'DROP\s+VIEW[^;]*\bdbo\.defect_reports\b'
        }
    }

    Context 'replay' {
        It 'guards every statement so a second run is a no-op' {
            foreach ($statement in Get-TeardownStatement -Prefix $script:Prefix) {
                $statement.Sql | Should -Match 'IF\s+EXISTS' `
                    -Because "statement '$($statement.Key)' must tolerate the object already being gone"
            }
        }

        It 'uses no T-SQL the lakehouse SQL analytics endpoint rejects' {
            # Msg 15871, the defect that cost protect-tables.ps1 a silent total failure.
            $sql = (Get-TeardownStatement -Prefix $script:Prefix | ForEach-Object Sql) -join "`n"
            $sql | Should -Not -Match 'DATABASE_PRINCIPAL_ID'
        }
    }

    Context 'naming' {
        It 'hardcodes no company prefix' {
            $sql = (Get-TeardownStatement -Prefix $script:Prefix | ForEach-Object Sql) -join "`n"
            $sql | Should -Not -Match '\bmls_data_'
        }
    }
}

Describe 'Invoke-ProtectionTeardown' {
    BeforeEach {
        $script:Applied = [System.Collections.Generic.List[string]]::new()
        Mock Write-Status {}
        Mock Invoke-TeardownSql { $script:Applied.Add($Key) }
    }

    It 'applies every statement in declared order' {
        Invoke-ProtectionTeardown -Prefix $script:Prefix | Out-Null
        @($script:Applied) | Should -Be @((Get-TeardownStatement -Prefix $script:Prefix).Key)
    }

    It 'continues past a failure and reports every statement' {
        Mock Invoke-TeardownSql {
            $script:Applied.Add($Key)
            if ($Key -eq 'rls_view') { throw 'simulated failure' }
        }
        $result = Invoke-ProtectionTeardown -Prefix $script:Prefix -ErrorAction SilentlyContinue
        $total = @((Get-TeardownStatement -Prefix $script:Prefix).Key).Count
        @($script:Applied).Count | Should -Be $total `
            -Because 'a teardown that stops at the first error leaves a half-removed estate'
        @($result | Where-Object Status -eq 'Failed').Count | Should -Be 1
    }
}
