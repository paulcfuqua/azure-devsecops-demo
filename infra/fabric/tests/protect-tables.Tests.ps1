# Pester tests for infra/fabric/protect-tables.ps1 - TDS mocked; zero cloud calls.
#
# What this script applies was PROVEN against the live lakehouse SQL analytics endpoint
# on 2026-09-20 before any of it was written (spike probes A / A2 / A3, recorded in
# docs/superpowers/specs/2026-09-20-tiered-data-access-demo-design.md section 2):
#
#   DENY SELECT ON dbo.<table>(<column>) TO <role>   works  -> column-level security
#   CREATE VIEW ... WITH SCHEMABINDING                works
#   CREATE FUNCTION ... RETURNS TABLE WITH SCHEMABINDING  works
#   CREATE SECURITY POLICY ... WITH (STATE = ON)      works  -> row-level security
#
# Two spike attempts failed on defects in the PROBE, not in Fabric: a policy cannot bind
# to a view that is not SCHEMABINDING, and a column name written from memory does not
# exist. Both errors named the policy, which was fine. The tests below pin the two
# things those failures would have produced.

BeforeAll {
    $env:MLS_SKIP_MAIN = '1'
    . (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'protect-tables.ps1') `
        -SqlEndpoint 'endpoint.invalid' -AccessToken 'tok-dummy'
    # No Set-StrictMode -Off: the script under test sets -Version Latest and CI runs it
    # that way, so the harness must not relax the language mode it is testing (F49).

    $script:Prefix = 'acme'
    function Get-Sql {
        param([Parameter(Mandatory)][string]$Key)
        $statement = Get-ProtectionStatement -Prefix $script:Prefix | Where-Object Key -eq $Key
        if (-not $statement) { throw "No protection statement with key '$Key'." }
        return $statement.Sql
    }
}

Describe 'Get-ProtectionStatement' {
    Context 'naming' {
        It 'prefixes every role it creates' {
            $sql = (Get-ProtectionStatement -Prefix $script:Prefix | ForEach-Object Sql) -join "`n"
            $sql | Should -Match 'acme_data_standard'
            $sql | Should -Match 'acme_data_privileged'
        }

        It 'hardcodes no company prefix anywhere' {
            # F90: a hardcoded mls is the half of a rebrand nobody sees. Entra names and
            # the Fabric workspace were left behind by exactly this.
            $sql = (Get-ProtectionStatement -Prefix $script:Prefix | ForEach-Object Sql) -join "`n"
            $sql | Should -Not -Match '\bmls_data_'
        }
    }

    Context 'column-level security on hr_roster' {
        It 'denies exactly the three restricted columns' {
            $deny = Get-Sql -Key 'cls_hr_roster'
            foreach ($column in 'salary_usd', 'bonus_target_pct', 'performance_band') {
                $deny | Should -Match ([regex]::Escape($column))
            }
        }

        It 'never denies an open column' {
            # start_date and department are the whole point: a standard caller reads them
            # from the same row whose salary the database refuses.
            $deny = Get-Sql -Key 'cls_hr_roster'
            foreach ($open in 'start_date', 'department', 'display_name', 'job_family', 'tenure_years') {
                $deny | Should -Not -Match ([regex]::Escape($open))
            }
        }

        It 'denies to the standard role and never to the privileged one' {
            $deny = Get-Sql -Key 'cls_hr_roster'
            $deny | Should -Match 'acme_data_standard'
            $deny | Should -Not -Match 'acme_data_privileged'
        }
    }

    Context 'row-level security on defect_reports' {
        It 'creates the secure view WITH SCHEMABINDING' {
            # Spike attempt 1 failed exactly here: a security policy cannot bind to a view
            # that is not schema-bound, and Fabric reported it as a problem with the policy.
            Get-Sql -Key 'rls_view' | Should -Match 'WITH\s+SCHEMABINDING'
        }

        It 'creates the predicate WITH SCHEMABINDING and as an inline table-valued function' {
            $predicate = Get-Sql -Key 'rls_predicate'
            $predicate | Should -Match 'RETURNS\s+TABLE'
            $predicate | Should -Match 'WITH\s+SCHEMABINDING'
        }

        It 'filters on the classification column and lets the privileged role through' {
            # Quote-agnostic on purpose: CREATE FUNCTION cannot sit inside an IF, so the
            # guarded form wraps it in EXEC('...') and every inner quote is doubled.
            # Pinning the quoting here would test the escaping, not the meaning.
            $predicate = Get-Sql -Key 'rls_predicate'
            $predicate | Should -Match 'THIRD_PARTY_PROPRIETARY'
            $predicate | Should -Match 'IS_ROLEMEMBER'
            $predicate | Should -Match 'acme_data_privileged'
        }

        It 'enables the security policy' {
            # A policy created with STATE = OFF exists, reports healthy in sys catalogs,
            # and filters nothing. That is F119's class: present but not enabled.
            Get-Sql -Key 'rls_policy' | Should -Match 'STATE\s*=\s*ON'
        }

        It 'denies the base table so the view is the only door' {
            $deny = Get-Sql -Key 'deny_base'
            $deny | Should -Match 'defect_reports'
            $deny | Should -Match 'acme_data_standard'
        }
    }

    Context 'ordering and replay' {
        It 'creates each dependency before its dependent' {
            $keys = @((Get-ProtectionStatement -Prefix $script:Prefix).Key)
            $keys.IndexOf('rls_view') | Should -BeLessThan $keys.IndexOf('rls_policy')
            $keys.IndexOf('rls_predicate') | Should -BeLessThan $keys.IndexOf('rls_policy')
            $keys.IndexOf('role_standard') | Should -BeLessThan $keys.IndexOf('cls_hr_roster')
            $keys.IndexOf('role_privileged') | Should -BeLessThan $keys.IndexOf('rls_predicate')
        }

        It 'marks every statement idempotent' {
            # Replay is the standard remediation on this estate; a second run must not throw.
            foreach ($statement in Get-ProtectionStatement -Prefix $script:Prefix) {
                $statement.Idempotent | Should -BeTrue -Because "statement '$($statement.Key)' must be safe to replay"
            }
        }

        It 'uses no T-SQL the lakehouse SQL analytics endpoint rejects' {
            # A lakehouse SQL analytics endpoint is NOT a Warehouse and not a SQL database,
            # and the unsupported surface is discovered rather than documented.
            #
            # DATABASE_PRINCIPAL_ID() fails here with Msg 15871, verified live 2026-09-20.
            # The cost of that one function was total and silent: the role guard threw, the
            # role was never created, and every GRANT and DENY after it failed with
            # "Principal could not be found" - while all nineteen tests in this file passed,
            # because they read the SQL text and not what the endpoint does with it.
            #
            # A class paid for once becomes a check (CLAUDE.md).
            $sql = (Get-ProtectionStatement -Prefix $script:Prefix | ForEach-Object Sql) -join "`n"
            $sql | Should -Not -Match 'DATABASE_PRINCIPAL_ID' `
                -Because 'unsupported on this endpoint (Msg 15871); use sys.database_principals'
        }

        It 'guards role creation through sys.database_principals' {
            foreach ($key in 'role_standard', 'role_privileged') {
                Get-Sql -Key $key | Should -Match 'sys\.database_principals'
            }
        }

        It 'guards every CREATE with an existence check' {
            foreach ($statement in Get-ProtectionStatement -Prefix $script:Prefix) {
                if ($statement.Sql -match 'CREATE\s+(ROLE|VIEW|FUNCTION|SECURITY\s+POLICY)') {
                    $statement.Sql | Should -Match "IF\s+NOT\s+EXISTS|IS\s+NULL" `
                        -Because "statement '$($statement.Key)' creates an object and must not throw on replay"
                }
            }
        }
    }
}

Describe 'Assert-ExpectedColumn' {
    # The spike failed twice on column names written from memory. The deploy path resolves
    # the real schema from INFORMATION_SCHEMA and refuses to proceed when it disagrees,
    # so a renamed column fails in seconds with a clear message instead of inside a policy
    # that silently protects nothing.

    It 'passes when the endpoint reports exactly the expected columns' {
        { Assert-ExpectedColumn -Table 'hr_roster' -Expected @('a', 'b') -Actual @('b', 'a') } |
            Should -Not -Throw
    }

    It 'throws, naming the table and the difference, when a column is missing' {
        { Assert-ExpectedColumn -Table 'hr_roster' -Expected @('a', 'b') -Actual @('a') } |
            Should -Throw -ExpectedMessage '*hr_roster*b*'
    }

    It 'throws when the endpoint has a column the script does not know about' {
        # A new column is not harmless: an unlisted column on hr_roster is one the CLS
        # DENY does not cover, so it would be readable by the standard role.
        { Assert-ExpectedColumn -Table 'hr_roster' -Expected @('a') -Actual @('a', 'secret') } |
            Should -Throw -ExpectedMessage '*secret*'
    }
}

Describe 'Invoke-TableProtection' {
    BeforeEach {
        $script:Applied = [System.Collections.Generic.List[string]]::new()
        Mock Write-Status {}
        Mock Invoke-ProtectionSql { $script:Applied.Add($Key) }
        Mock Get-EndpointColumn {
            param($Table)
            switch ($Table) {
                'hr_roster' { @('employee_id', 'display_name', 'department', 'job_family', 'location', 'start_date', 'tenure_years', 'manager_id', 'employment_type', 'salary_usd', 'bonus_target_pct', 'performance_band') }
                'defect_reports' { @('defect_id', 'vehicle_id', 'supplier_id', 'reported_date', 'severity', 'subsystem', 'status', 'summary', 'root_cause', 'classification') }
                default { @() }
            }
        }
    }

    It 'applies every statement, in declared order' {
        Invoke-TableProtection -Prefix $script:Prefix | Out-Null
        $expected = @((Get-ProtectionStatement -Prefix $script:Prefix).Key)
        @($script:Applied) | Should -Be $expected
    }

    It 'reports on every statement and fails at the end, not at the first error' {
        # CLAUDE.md: a run is an expensive observation and returns everything it saw.
        # Stopping at the first failure makes the discovery rate equal to the deploy rate.
        Mock Invoke-ProtectionSql {
            $script:Applied.Add($Key)
            if ($Key -eq 'cls_hr_roster') { throw 'simulated failure' }
        }
        $result = Invoke-TableProtection -Prefix $script:Prefix -ErrorAction SilentlyContinue
        $total = @((Get-ProtectionStatement -Prefix $script:Prefix).Key).Count
        @($script:Applied).Count | Should -Be $total -Because 'every statement is attempted even after one fails'
        @($result | Where-Object Status -eq 'Failed').Count | Should -Be 1
    }

    It 'refuses to run when the endpoint schema disagrees with the script' {
        Mock Get-EndpointColumn { @('employee_id') }
        { Invoke-TableProtection -Prefix $script:Prefix } | Should -Throw
        @($script:Applied).Count | Should -Be 0 -Because 'nothing is applied against a schema it does not recognise'
    }
}
