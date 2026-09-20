# Pester tests for verification/layer-05-audit.ps1 - Fabric REST, the SQL analytics
# endpoint and az are all mocked; zero cloud calls.

BeforeAll {
    $env:MLS_SKIP_MAIN = '1'
    . (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'layer-05-audit.ps1')
    # No Set-StrictMode -Off: the audit scripts set -Version Latest and CI runs them
    # that way, so the harness must not relax the language mode it is testing (F49).

    $script:ReportRoot = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath "mls-l05-$([guid]::NewGuid().ToString('n'))"
    New-Item -ItemType Directory -Path $script:ReportRoot -Force | Out-Null
    $script:Table = @('launches', 'scrubs', 'vehicles', 'pads', 'telemetry_summary',
        'parts', 'suppliers', 'work_orders', 'cost_daily', 'findings_history')
    $script:ExpectedCount = [ordered]@{
        launches = 1200; scrubs = 340; vehicles = 6; pads = 5; telemetry_summary = 4800
        parts = 220; suppliers = 18; work_orders = 410; cost_daily = 365; findings_history = 96
    }
    $script:CountPath = Join-Path -Path $script:ReportRoot -ChildPath 'expected_counts.json'
    Set-Content -LiteralPath $script:CountPath -Value ($script:ExpectedCount | ConvertTo-Json) -Encoding utf8
    $script:TrialCapacityId = '99999999-9999-9999-9999-999999999999'
    $script:SavedCapacity = [Environment]::GetEnvironmentVariable('FABRIC_CAPACITY_ID')

    function Get-Row {
        param($Context, [string]$Id)
        return @($Context.Criterion | Where-Object { $_.Id -eq $Id })[0]
    }

    function Invoke-AuditForTest {
        param([switch]$NoRetry, [string]$CapacityId = $script:TrialCapacityId, [string]$ExpectedCountPath = $script:CountPath)
        Invoke-Main -FabricCapacityId $CapacityId -FabricToken 'fabric-token' -WorkspaceName 'mls-operations' `
            -LakehouseName 'mls_operations' -ExpectedTable $script:Table -ExpectedLaunchCount 1200 `
            -ExpectedCountPath $ExpectedCountPath -ReportRoot $script:ReportRoot -NoRetry:$NoRetry
    }
}

AfterAll {
    [Environment]::SetEnvironmentVariable('FABRIC_CAPACITY_ID', $script:SavedCapacity)
    Remove-Item Env:\MLS_SKIP_MAIN -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $script:ReportRoot) {
        Remove-Item -LiteralPath $script:ReportRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'layer-05-audit' {
    BeforeEach {
        Mock Write-MlsStatus {} -ModuleName 'MlsAudit'
        Mock Wait-MlsRetryInterval {} -ModuleName 'MlsAudit'

        $script:LiveTable = $script:Table
        # THE SQL CATALOG IS A SEPARATE FIXTURE FROM THE FABRIC ONE, because the two
        # routes are separate observations and V5.2 now chooses between them. Defaulting
        # both to the correct ten means a test that moves one and not the other is
        # asserting something about the route it moved.
        $script:SqlCatalogTable = $script:Table
        # 403, NOT 200, IS THE ESTATE'S REAL DEFAULT. mls-verifier holds the Fabric
        # workspace VIEWER role - read-only by contract - and Viewer confers no OneLake
        # data access. Read live on 2026-09-03: OneLake answered 403 to a caller without
        # the role while the Fabric /tables route answered 200 with an empty list, in the
        # same second. Pinning the fixture to the estate rather than to the convenient
        # case is what F114 was about.
        $script:OneLakeStatus = 403
        $script:RowCount = [ordered]@{}
        foreach ($name in $script:ExpectedCount.Keys) { $script:RowCount[$name] = $script:ExpectedCount[$name] }
        # The LIVE trial capacity reports FTL4, not the literal 'Trial'. Pinning the
        # fixture to the real value is what makes this a test of the estate rather than a
        # test of a string somebody imagined (F114).
        $script:CapacitySku = 'FTL4'
        $script:CapacityState = 'Active'
        $script:WorkspaceCapacityId = $script:TrialCapacityId

        # V5.5's fixture: defect_reports carries BOTH classes and hr_roster's restricted
        # column is populated. These are the preconditions the enforcement demo rests on.
        $script:ClassCount = [ordered]@{ INTERNAL = 747; THIRD_PARTY_PROPRIETARY = 153 }
        $script:PopulatedSalaryCount = 240

        Mock Invoke-MlsRest {
            if ($Uri -like '*/workspaces') {
                return [pscustomobject]@{ value = @([pscustomobject]@{
                            id = 'ws-1'; displayName = 'mls-operations'; capacityId = $script:WorkspaceCapacityId
                        })
                }
            }
            if ($Uri -like '*/lakehouses') {
                return [pscustomobject]@{ value = @([pscustomobject]@{
                            id          = 'lh-1'
                            displayName = 'mls_operations'
                            properties  = [pscustomobject]@{
                                # Shaped like the live item, which carries its own OneLake
                                # paths - V5.2 probes the one it is given rather than
                                # building a DFS URL out of ids and a hostname.
                                oneLakeTablesPath     = 'https://onelake.dfs.fabric.microsoft.com/ws-1/lh-1/Tables'
                                sqlEndpointProperties = [pscustomobject]@{ connectionString = 'abc.datawarehouse.fabric.microsoft.com' }
                            }
                        })
                }
            }
            if ($Uri -like '*/tables') {
                return [pscustomobject]@{ data = @($script:LiveTable | ForEach-Object { [pscustomobject]@{ name = $_ } }) }
            }
            if ($Uri -like '*/capacities') {
                return [pscustomobject]@{ value = @([pscustomobject]@{
                            id = $script:TrialCapacityId; sku = $script:CapacitySku; state = $script:CapacityState
                        })
                }
            }
            throw "unexpected Fabric REST call: $Uri"
        }

        Mock Invoke-MlsSqlQuery {
            if ($Query -like '*INFORMATION_SCHEMA*') {
                return @($script:SqlCatalogTable | ForEach-Object { [pscustomobject]@{ t = $_ } })
            }
            if ($Query -like '*classification*') {
                return @($script:ClassCount.Keys | ForEach-Object {
                        [pscustomobject]@{ c = $_; n = $script:ClassCount[$_] }
                    })
            }
            if ($Query -like '*salary_usd*') {
                return @([pscustomobject]@{ n = $script:PopulatedSalaryCount })
            }
            return @($script:RowCount.Keys | ForEach-Object {
                    [pscustomobject]@{ t = $_; n = $script:RowCount[$_] }
                })
        }

        Mock Invoke-MlsHttp {
            return [pscustomobject]@{ StatusCode = $script:OneLakeStatus; Content = ''; Headers = @{}; Error = $null }
        } -ModuleName 'MlsAudit'
        Mock Invoke-MlsHttp {
            return [pscustomobject]@{ StatusCode = $script:OneLakeStatus; Content = ''; Headers = @{}; Error = $null }
        }

        Mock Invoke-MlsAz {
            if (($Argument -join ' ') -like '*get-access-token*storage.azure.com*') {
                return [pscustomobject]@{ accessToken = 'onelake-token' }
            }
            throw "unexpected az call: $($Argument -join ' ')"
        }
    }

    Context 'all criteria pass' {
        It 'records V5.1-V5.5 as PASS on the trial capacity and exits 0' {
            $context = Invoke-AuditForTest
            # V5.5 sits BEFORE V5.4 on purpose: it reads the SQL analytics endpoint, and
            # V5.4 asserts the capacity is PAUSED. A SQL read after the pause fails.
            @($context.Criterion).Id | Should -Be @('V5.1', 'V5.2', 'V5.3', 'V5.5', 'V5.4')
            @($context.Criterion | Where-Object { $_.Status -ne 'PASS' }) | Should -BeNullOrEmpty
            Get-MlsExitCode -Context $context | Should -Be 0
        }

        It 'records the trial-capacity equivalence explicitly rather than silently' {
            $context = Invoke-AuditForTest
            $row = Get-Row -Context $context -Id 'V5.4'
            $row.Observed | Should -BeLike '*trial SKU*'
            $row.Detail | Should -BeLike '*re-arms verbatim*'
        }

        It 'reads the SQL endpoint out of the lakehouse metadata V5.1 fetched' {
            $context = Invoke-AuditForTest
            $context.Evidence['sqlEndpoint'] | Should -Be 'abc.datawarehouse.fabric.microsoft.com'
            # UNION ALL, not just COUNT(*): V5.5 also counts, and a filter that matches
            # any COUNT(*) stopped identifying V5.3's read the moment it was added.
            Should -Invoke Invoke-MlsSqlQuery -Exactly -Times 1 -ParameterFilter {
                $ServerName -eq 'abc.datawarehouse.fabric.microsoft.com' -and $Query -like '*UNION ALL*'
            }
        }
    }

    Context 'a criterion fails on a realistic wrong value' {
        It 'fails V5.3 when launches is 1,198 - a partial load, with no tolerance band' {
            $script:RowCount['launches'] = 1198
            $context = Invoke-AuditForTest
            $row = Get-Row -Context $context -Id 'V5.3'
            $row.Status | Should -Be 'FAIL'
            $row.Attempt | Should -Be 1
            $row.Observed | Should -BeLike '*launches=1198, expected exactly 1200*'
            Get-MlsExitCode -Context $context | Should -Be 1
        }

        It 'fails V5.2 on table drift - an extra table the manifest does not declare' {
            $script:SqlCatalogTable = $script:Table + 'scratch_tmp'
            $context = Invoke-AuditForTest -NoRetry
            $row = Get-Row -Context $context -Id 'V5.2'
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -Match 'extra \[scratch_tmp\]'
        }

        It 'still fails V5.4 for a PAID capacity left running' {
            # The trial branch must not become a blanket pass. F2 resumed is a real cost
            # anomaly and the reason this criterion exists; widening the SKU match to the
            # FT* family must not widen it to F*.
            $script:CapacitySku = 'F2'
            $script:CapacityState = 'Active'
            $context = Invoke-AuditForTest -NoRetry
            $row = Get-Row -Context $context -Id 'V5.4'
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -Match "paid SKU 'F2'"
        }

        It 'fails V5.1 when the workspace is bound to a different capacity (the stray-workspace case)' {
            $script:WorkspaceCapacityId = 'some-other-capacity'
            $context = Invoke-AuditForTest -NoRetry
            $row = Get-Row -Context $context -Id 'V5.1'
            $row.Status | Should -Be 'FAIL'
            $row.Detail | Should -BeLike '*must not be adopted*'
        }

        It 'fails V5.4 when a paid capacity is left resumed' {
            Mock Invoke-MlsAz {
                if (($Argument -join ' ') -like 'resource show*') { return 'Active' }
                if (($Argument -join ' ') -like '*get-access-token*storage.azure.com*') {
                    return [pscustomobject]@{ accessToken = 'onelake-token' }
                }
                throw "unexpected az call: $($Argument -join ' ')"
            }
            $armId = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Fabric/capacities/mlsf2'
            $context = Invoke-AuditForTest -CapacityId $armId -NoRetry
            $row = Get-Row -Context $context -Id 'V5.4'
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -BeLike "*'Active', expected 'Paused'*"
        }
    }

    Context 'V5.2 establishes that it could observe before reporting what it saw (F105/F171)' {
        It 'reads the table list over the SQL analytics endpoint when OneLake refuses this identity' {
            # THE ESTATE'S NORMAL CASE. mls-verifier holds Fabric workspace Viewer, which
            # confers no OneLake data access, so /lakehouses/<id>/tables answers 200 with
            # [] - indistinguishable from an empty lakehouse. The criterion must not read
            # that as a table list at all; it reads the catalog the Viewer CAN see.
            $script:OneLakeStatus = 403
            $script:LiveTable = @()
            $context = Invoke-AuditForTest -NoRetry
            $row = Get-Row -Context $context -Id 'V5.2'
            $row.Status | Should -Be 'PASS' `
                -Because 'the ten tables are there and a route this identity can read says so'
            $row.Observed | Should -Match 'HTTP 403' `
                -Because 'one line of positive evidence about what could and could not be observed (F162)'
            $row.Observed | Should -Match 'SQL analytics endpoint'
            $row.Observed | Should -Not -Match 'missing \[' `
                -Because 'an empty response from a route that may not look is never evidence the tables are missing'
        }

        It 'believes the Fabric table list once OneLake read is CONFIRMED' {
            $script:OneLakeStatus = 200
            $script:LiveTable = $script:Table
            $context = Invoke-AuditForTest -NoRetry
            $row = Get-Row -Context $context -Id 'V5.2'
            $row.Status | Should -Be 'PASS'
            $row.Observed | Should -Match 'HTTP 200'
            $row.Observed | Should -Match 'Fabric /tables'
            Should -Invoke Invoke-MlsSqlQuery -Exactly -Times 0 -ParameterFilter { $Query -like '*INFORMATION_SCHEMA*' } `
                -Because 'the SQL catalog is the FALLBACK route; a confirmed OneLake read makes it unnecessary'
        }

        It 'calls an empty lakehouse empty when OneLake read is CONFIRMED and the list is still empty' {
            # The symmetric error is the worse one: an auditor that cannot see a control
            # must not report it PRESENT either. Once the probe says this identity CAN
            # read the data plane, [] is a real finding and must fail as one.
            $script:OneLakeStatus = 200
            $script:LiveTable = @()
            $context = Invoke-AuditForTest -NoRetry
            $row = Get-Row -Context $context -Id 'V5.2'
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -Match 'missing \['
            $row.Detail | Should -Match 'CONFIRMED'
        }

        It 'reports UNOBSERVABLE, never "the tables are missing", when neither route can answer' {
            $script:OneLakeStatus = 403
            $script:LiveTable = @()
            Mock Invoke-MlsRest {
                if ($Uri -like '*/workspaces') {
                    return [pscustomobject]@{ value = @([pscustomobject]@{ id = 'ws-1'; displayName = 'mls-operations'; capacityId = $script:TrialCapacityId }) }
                }
                if ($Uri -like '*/lakehouses') {
                    # No sqlEndpointProperties at all: nothing to fall back to.
                    return [pscustomobject]@{ value = @([pscustomobject]@{ id = 'lh-1'; displayName = 'mls_operations'
                                properties = [pscustomobject]@{ oneLakeTablesPath = 'https://onelake.dfs.fabric.microsoft.com/ws-1/lh-1/Tables' }
                            })
                    }
                }
                if ($Uri -like '*/tables') { return [pscustomobject]@{ data = @() } }
                if ($Uri -like '*/capacities') {
                    return [pscustomobject]@{ value = @([pscustomobject]@{ id = $script:TrialCapacityId; sku = 'FTL4'; state = 'Active' }) }
                }
                throw "unexpected Fabric REST call: $Uri"
            }
            $context = Invoke-AuditForTest
            $row = Get-Row -Context $context -Id 'V5.2'
            $row.Status | Should -Be 'FAIL' -Because 'unobservable is never a sign-off'
            $row.Observed | Should -Match '^UNOBSERVABLE'
            $row.Observed | Should -Not -Match 'missing \['
        }

        It 'does not spend the retry window on a permission state that cannot change by waiting (F169)' {
            # V5.2 burned 03:59:25 -> 04:29:33 on the 2026-09-03 rebuild re-asking a
            # question answered on the first poll. A denial is not a propagation artifact.
            $script:OneLakeStatus = 403
            Mock Invoke-MlsRest {
                if ($Uri -like '*/workspaces') {
                    return [pscustomobject]@{ value = @([pscustomobject]@{ id = 'ws-1'; displayName = 'mls-operations'; capacityId = $script:TrialCapacityId }) }
                }
                if ($Uri -like '*/lakehouses') {
                    return [pscustomobject]@{ value = @([pscustomobject]@{ id = 'lh-1'; displayName = 'mls_operations'
                                properties = [pscustomobject]@{ oneLakeTablesPath = 'https://onelake.dfs.fabric.microsoft.com/ws-1/lh-1/Tables' }
                            })
                    }
                }
                if ($Uri -like '*/tables') { return [pscustomobject]@{ data = @() } }
                if ($Uri -like '*/capacities') {
                    return [pscustomobject]@{ value = @([pscustomobject]@{ id = $script:TrialCapacityId; sku = 'FTL4'; state = 'Active' }) }
                }
                throw "unexpected Fabric REST call: $Uri"
            }
            $context = Invoke-AuditForTest
            $row = Get-Row -Context $context -Id 'V5.2'
            $row.Attempt | Should -Be 1
            $row.SleptSeconds | Should -Be 0
        }

        It 'says it did not probe, rather than inventing a denial, when no OneLake token can be minted' {
            # A probe that never ran has established nothing. It must not be reported as
            # a denial, and it must not be reported as a grant either.
            Mock Invoke-MlsAz { throw "unexpected az call: $($Argument -join ' ')" }
            $context = Invoke-AuditForTest -NoRetry
            $row = Get-Row -Context $context -Id 'V5.2'
            $row.Observed | Should -Match 'NOT PROBED'
            $row.Status | Should -Be 'PASS' `
                -Because 'the SQL route still answered, and the report says which route did'
        }

        It 'never escalates the Verifier past the read-only Fabric role to make itself observable' {
            $onelake = Get-Content -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'layer-05-audit.ps1') -Raw
            $onelake | Should -Not -Match '(?m)^\s*[^#]*Add-FabricWorkspaceRoleAssignment' `
                -Because 'the audit reads; a criterion that grants itself the permission it is checking is not a check'
        }
    }

    Context 'retry' {
        It 'retries V5.2 while the SQL analytics endpoint is still registering tables' {
            # THE PROPAGATION THE WINDOW ACTUALLY EXISTS FOR, and now the only thing that
            # consumes it: a Delta table lands in OneLake before the SQL endpoint syncs
            # it, so the fallback route sees a short list for a few minutes.
            $script:Calls = 0
            Mock Invoke-MlsSqlQuery {
                if ($Query -like '*INFORMATION_SCHEMA*') {
                    $script:Calls++
                    if ($script:Calls -lt 2) {
                        return @($script:Table | Select-Object -First 8 | ForEach-Object { [pscustomobject]@{ t = $_ } })
                    }
                    return @($script:Table | ForEach-Object { [pscustomobject]@{ t = $_ } })
                }
                return @($script:RowCount.Keys | ForEach-Object { [pscustomobject]@{ t = $_; n = $script:RowCount[$_] } })
            }
            $context = Invoke-AuditForTest
            $row = Get-Row -Context $context -Id 'V5.2'
            $row.Status | Should -Be 'PASS'
            $row.Attempt | Should -Be 2
            # One poll interval, not the whole window - asserted against the row's own
            # cadence rather than a literal, so right-sizing the defaults (F59) cannot
            # silently turn this into a test of a constant nobody re-checked.
            $row.SleptSeconds | Should -Be $row.PollIntervalSecond
            $row.SleptSeconds | Should -BeLessThan ($row.RetryWindowMinutes * 60)
            Should -Invoke Wait-MlsRetryInterval -ModuleName 'MlsAudit' -Exactly -Times 1
        }
    }

    Context 'a check that throws' {
        It 'records V5.3 as FAIL when the SQL endpoint errors, and still evaluates V5.4' {
            Mock Invoke-MlsSqlQuery { throw 'Login failed for user: the capacity is paused.' }
            $context = Invoke-AuditForTest -NoRetry
            @($context.Criterion).Count | Should -Be 5
            (Get-Row -Context $context -Id 'V5.3').Status | Should -Be 'FAIL'
            (Get-Row -Context $context -Id 'V5.3').Observed | Should -BeLike '*capacity is paused*'
            # The same failure must make V5.5 say it could not LOOK, not that the
            # restricted rows are missing.
            (Get-Row -Context $context -Id 'V5.5').Observed | Should -BeLike '*UNOBSERVABLE*'
            (Get-Row -Context $context -Id 'V5.4').Status | Should -Be 'PASS'
        }
    }

    Context 'missing input' {
        It 'refuses to run without the Fabric capacity id' {
            [Environment]::SetEnvironmentVariable('FABRIC_CAPACITY_ID', $null)
            { Invoke-AuditForTest -CapacityId '' } | Should -Throw '*FabricCapacityId*'
            { Invoke-AuditForTest -CapacityId '' } | Should -Throw '*FABRIC_CAPACITY_ID*'
        }

        It 'records V5.3 as SKIP when the expected-counts fixture is absent, even though launches is right' {
            $context = Invoke-AuditForTest -ExpectedCountPath (Join-Path -Path $script:ReportRoot -ChildPath 'absent.json')
            $row = Get-Row -Context $context -Id 'V5.3'
            $row.Status | Should -Be 'SKIP'
            $row.Observed | Should -BeLike '*launches=1200 verified*'
            $row.Detail | Should -BeLike '*expected-counts fixture*'
        }
    }

    Context 'the -ExpectedTable DEFAULT, which is what CI actually runs' {
        # layer-05-fabric.yml passes no -ExpectedTable, so the default in the param block
        # is the live value. Every test in this file supplies its own list, so until this
        # one existed the default was covered by nothing at all - and a stale default
        # fails V5.2's set equality and V5.3's fixture comparison against a CORRECTLY
        # seeded lakehouse, which is the worst direction for a wrong answer to point.
        BeforeAll {
            $script:AuditPath = Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'layer-05-audit.ps1'
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:AuditPath, [ref]$null, [ref]$null)
            $parameter = $ast.ParamBlock.Parameters |
                Where-Object { $_.Name.VariablePath.UserPath -eq 'ExpectedTable' }
            # Walk the AST rather than regexing the source: the default carries an
            # explanatory comment, and apostrophes in prose ("V5.2's set equality") are
            # indistinguishable from string delimiters to a regex. The first version of
            # this test extracted "s set" as a table name.
            $script:DefaultTable = @(
                $parameter.DefaultValue.FindAll(
                    { param($node) $node -is [System.Management.Automation.Language.StringConstantExpressionAst] },
                    $true
                ) | ForEach-Object { $_.Value }
            )
        }

        It 'names every table the committed row-count fixture names, and no others' {
            $fixture = Get-Content -LiteralPath (
                Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath '..', 'data', 'generators', 'tests', 'expected_counts.json'
            ) -Raw | ConvertFrom-Json
            $fixtureTable = @($fixture.PSObject.Properties.Name)
            @($script:DefaultTable | Sort-Object) | Should -Be @($fixtureTable | Sort-Object) `
                -Because 'V5.3 reads that fixture and reports every table in it that the endpoint did not return'
        }

        It 'includes both mixed-sensitivity tables' {
            $script:DefaultTable | Should -Contain 'hr_roster'
            $script:DefaultTable | Should -Contain 'defect_reports'
        }
    }

    Context 'V5.5 - the sensitivity preconditions the enforcement demo rests on' {
        It 'passes when both classifications are present and salary is populated' {
            $row = Get-Row -Context (Invoke-AuditForTest) -Id 'V5.5'
            $row.Status | Should -Be 'PASS'
            $row.Observed | Should -BeLike '*THIRD_PARTY_PROPRIETARY*'
        }

        It 'FAILS when defect_reports carries only INTERNAL rows' {
            # This is the whole reason the criterion exists. An all-INTERNAL table lets
            # every downstream RLS check pass while proving nothing was ever filtered -
            # a green result over data that cannot demonstrate the control.
            $script:ClassCount = [ordered]@{ INTERNAL = 900 }
            $row = Get-Row -Context (Invoke-AuditForTest) -Id 'V5.5'
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -BeLike '*THIRD_PARTY_PROPRIETARY*'
        }

        It 'FAILS when the restricted column is entirely null' {
            # A salary column full of nulls makes the column denial indistinguishable
            # from there being nothing to deny.
            $script:PopulatedSalaryCount = 0
            $row = Get-Row -Context (Invoke-AuditForTest) -Id 'V5.5'
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -BeLike '*salary_usd*'
        }

        It 'reports UNOBSERVABLE, never "absent", when the endpoint cannot be read' {
            # F105: Fabric answers a caller without OneLake read with an empty result
            # rather than a denial, so absence is unprovable. An audit that cannot see a
            # thing says so; it never reports the thing as missing.
            Mock Invoke-MlsSqlQuery { throw 'Login failed for user: the capacity is paused.' }
            $row = Get-Row -Context (Invoke-AuditForTest) -Id 'V5.5'
            $row.Status | Should -Not -Be 'PASS'
            $row.Observed | Should -BeLike '*UNOBSERVABLE*'
        }

        It 'does not run after the capacity has been paused' {
            # V5.4 asserts the capacity is Paused. A SQL read afterwards fails, so V5.5
            # must be registered before it - ordering is correctness here, not tidiness.
            $ids = @((Invoke-AuditForTest).Criterion).Id
            $ids.IndexOf('V5.5') | Should -BeLessThan $ids.IndexOf('V5.4')
        }
    }
}
