# Pester tests for verification/layer-05-audit.ps1 - Fabric REST, the SQL analytics
# endpoint and az are all mocked; zero cloud calls.

BeforeAll {
    $env:MLS_SKIP_MAIN = '1'
    . (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'layer-05-audit.ps1')
    Set-StrictMode -Off

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
        $script:RowCount = [ordered]@{}
        foreach ($name in $script:ExpectedCount.Keys) { $script:RowCount[$name] = $script:ExpectedCount[$name] }
        $script:CapacitySku = 'Trial'
        $script:CapacityState = 'Active'
        $script:WorkspaceCapacityId = $script:TrialCapacityId

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
            return @($script:RowCount.Keys | ForEach-Object {
                    [pscustomobject]@{ t = $_; n = $script:RowCount[$_] }
                })
        }

        Mock Invoke-MlsAz { throw "unexpected az call: $($Argument -join ' ')" }
    }

    Context 'all criteria pass' {
        It 'records V5.1-V5.4 as PASS on the trial capacity and exits 0' {
            $context = Invoke-AuditForTest
            @($context.Criterion).Id | Should -Be @('V5.1', 'V5.2', 'V5.3', 'V5.4')
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
            Should -Invoke Invoke-MlsSqlQuery -Exactly -Times 1 -ParameterFilter {
                $ServerName -eq 'abc.datawarehouse.fabric.microsoft.com' -and $Query -like 'SELECT*'
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
            $script:LiveTable = $script:Table + 'scratch_tmp'
            $context = Invoke-AuditForTest -NoRetry
            $row = Get-Row -Context $context -Id 'V5.2'
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -Match 'extra \[scratch_tmp\]'
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
                throw "unexpected az call: $($Argument -join ' ')"
            }
            $armId = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Fabric/capacities/mlsf2'
            $context = Invoke-AuditForTest -CapacityId $armId -NoRetry
            $row = Get-Row -Context $context -Id 'V5.4'
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -BeLike "*'Active', expected 'Paused'*"
        }
    }

    Context 'retry' {
        It 'retries V5.2 while the SQL endpoint is still registering tables' {
            $script:Calls = 0
            Mock Invoke-MlsRest {
                if ($Uri -like '*/workspaces') {
                    return [pscustomobject]@{ value = @([pscustomobject]@{ id = 'ws-1'; displayName = 'mls-operations'; capacityId = $script:TrialCapacityId }) }
                }
                if ($Uri -like '*/lakehouses') {
                    return [pscustomobject]@{ value = @([pscustomobject]@{ id = 'lh-1'; displayName = 'mls_operations'
                                properties = [pscustomobject]@{ sqlEndpointProperties = [pscustomobject]@{ connectionString = 'abc.datawarehouse.fabric.microsoft.com' } }
                            })
                    }
                }
                if ($Uri -like '*/tables') {
                    $script:Calls++
                    if ($script:Calls -lt 2) {
                        return [pscustomobject]@{ data = @($script:Table | Select-Object -First 8 | ForEach-Object { [pscustomobject]@{ name = $_ } }) }
                    }
                    return [pscustomobject]@{ data = @($script:Table | ForEach-Object { [pscustomobject]@{ name = $_ } }) }
                }
                if ($Uri -like '*/capacities') {
                    return [pscustomobject]@{ value = @([pscustomobject]@{ id = $script:TrialCapacityId; sku = 'Trial'; state = 'Active' }) }
                }
                throw "unexpected Fabric REST call: $Uri"
            }
            $context = Invoke-AuditForTest
            $row = Get-Row -Context $context -Id 'V5.2'
            $row.Status | Should -Be 'PASS'
            $row.Attempt | Should -Be 2
            $row.SleptSeconds | Should -Be 300
            $row.SleptSeconds | Should -BeLessThan (30 * 60)
            Should -Invoke Wait-MlsRetryInterval -ModuleName 'MlsAudit' -Exactly -Times 1
        }
    }

    Context 'a check that throws' {
        It 'records V5.3 as FAIL when the SQL endpoint errors, and still evaluates V5.4' {
            Mock Invoke-MlsSqlQuery { throw 'Login failed for user: the capacity is paused.' }
            $context = Invoke-AuditForTest -NoRetry
            @($context.Criterion).Count | Should -Be 4
            (Get-Row -Context $context -Id 'V5.3').Status | Should -Be 'FAIL'
            (Get-Row -Context $context -Id 'V5.3').Observed | Should -BeLike '*capacity is paused*'
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
}
