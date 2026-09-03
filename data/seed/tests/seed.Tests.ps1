# Pester tests for data/seed/seed.ps1 - the single entry point.
#
# ZERO CLOUD CALLS, ZERO SUBPROCESSES. The two seeding halves (Invoke-SqlSeed,
# Invoke-LakehouseSeed) and the generator subprocess (Invoke-GeneratorProcess) are all
# mocked; what is under test here is orchestration - target selection, when the
# generator runs, and which prerequisite failure the operator is shown.

BeforeAll {
    $env:MLS_SKIP_MAIN = '1'
    $script:SeedSource = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath '..')).Path

    Import-Module (Join-Path -Path $script:SeedSource -ChildPath 'seed-common.psm1') -Force
    Import-Module (Join-Path -Path $script:SeedSource -ChildPath 'sql' -AdditionalChildPath 'sql-seed.psm1') -Force
    Import-Module (Join-Path -Path $script:SeedSource -ChildPath 'lakehouse' -AdditionalChildPath 'lakehouse-seed.psm1') -Force
    . (Join-Path -Path $script:SeedSource -ChildPath 'seed.ps1')
    Set-StrictMode -Off

    # A fake checkout: <root>/data/seed is the SeedRoot, <root>/data/generators is what
    # Invoke-GeneratorBuild insists on finding before it tries to run python.
    $script:FakeSeedRoot = (Join-Path -Path $TestDrive -ChildPath 'repo' -AdditionalChildPath 'data','seed')
    New-Item -ItemType Directory -Path $script:FakeSeedRoot -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path -Path $TestDrive -ChildPath 'repo' -AdditionalChildPath 'data','generators') -Force | Out-Null

    $script:TestManifest = @{
        generator_seed = 20260822
        load_order     = @('vehicles', 'launches')
        tables         = @{
            vehicles = @{ expected_rows = 12; columns = @(@{ name = 'vehicle_id'; sql_type = 'NVARCHAR(16)'; nullable = $false }) }
            launches = @{ expected_rows = 1200; columns = @(@{ name = 'launch_id'; sql_type = 'NVARCHAR(16)'; nullable = $false }) }
        }
    }

    # -AsWhatIf, never -WhatIf: a helper parameter literally named WhatIf on a function
    # that does not call ShouldProcess trips PSUseSupportsShouldProcess.
    function Invoke-SeedForTest {
        param(
            [string]$Target = 'both',
            [switch]$AsWhatIf,
            [switch]$AsSkipGenerate,
            [switch]$AsSchemaOnly,
            [string]$WorkloadUserName = '',
            [string]$WorkloadUserClientId = ''
        )
        Invoke-Main -Target $Target -SchemaOnly:$AsSchemaOnly -SeedRoot $script:FakeSeedRoot `
            -SqlServerInstance 'srv' -SqlDatabase 'db' -SqlAccessToken 'tok-sql' `
            -SqlWorkloadUserName $WorkloadUserName -SqlWorkloadUserClientId $WorkloadUserClientId `
            -Token 'tok-fabric' -OneLakeToken 'tok-onelake' `
            -SkipGenerate:$AsSkipGenerate -WhatIf:$AsWhatIf
    }
}

AfterAll {
    Remove-Item Env:\MLS_SKIP_MAIN -ErrorAction SilentlyContinue
    Remove-Module 'lakehouse-seed' -Force -ErrorAction SilentlyContinue
    Remove-Module 'sql-seed' -Force -ErrorAction SilentlyContinue
    Remove-Module 'seed-common' -Force -ErrorAction SilentlyContinue
}

Describe 'seed.ps1' {
    BeforeEach {
        Mock Write-Status {}
        Mock Get-SeedManifest { $script:TestManifest }
        Mock Get-GeneratedDataPath { (Join-Path -Path $TestDrive -ChildPath 'repo' -AdditionalChildPath 'data','generated') }
        Mock Test-GeneratedDataComplete { $true }
        Mock Invoke-GeneratorProcess { throw 'the generator subprocess must not run in this scenario' }
        Mock Invoke-SqlSeed { [pscustomobject]@{ SkippedAlreadySeeded = $false; Loaded = @() } }
        Mock Invoke-LakehouseSeed { [pscustomobject]@{ SkippedAlreadySeeded = $false; Loaded = @() } }
    }

    Context '-Target selection' {
        It 'seeds only Azure SQL for -Target sql' {
            $result = Invoke-SeedForTest -Target 'sql'
            Should -Invoke Invoke-SqlSeed -Exactly -Times 1
            Should -Invoke Invoke-LakehouseSeed -Exactly -Times 0
            $result.Lakehouse | Should -BeNullOrEmpty
        }

        It 'seeds only the lakehouse for -Target lakehouse' {
            $result = Invoke-SeedForTest -Target 'lakehouse'
            Should -Invoke Invoke-LakehouseSeed -Exactly -Times 1
            Should -Invoke Invoke-SqlSeed -Exactly -Times 0
            $result.Sql | Should -BeNullOrEmpty
        }

        It 'seeds both planes for -Target both, SQL first' {
            $result = Invoke-SeedForTest -Target 'both'
            Should -Invoke Invoke-SqlSeed -Exactly -Times 1
            Should -Invoke Invoke-LakehouseSeed -Exactly -Times 1
            $result.Sql | Should -Not -BeNullOrEmpty
            $result.Lakehouse | Should -Not -BeNullOrEmpty
        }

        It 'rejects a target that is not one of the three' {
            { Invoke-Main -Target 'warehouse' -SeedRoot $script:FakeSeedRoot } | Should -Throw
        }

        It 'passes the SQL DDL directory that ships with the repo' {
            Invoke-SeedForTest -Target 'sql' | Out-Null
            Should -Invoke Invoke-SqlSeed -Exactly -Times 1 -ParameterFilter {
                $DdlPath -like '*seed*sql'
            }
        }
    }

    Context 'dataset generation' {
        It 'does not run the generators when the dataset is already complete' {
            $result = Invoke-SeedForTest -Target 'sql'
            $result.Generated | Should -BeFalse
            Should -Invoke Invoke-GeneratorProcess -Exactly -Times 0
        }

        It 'runs `python -m generators build` when the dataset is missing' {
            $script:Complete = $false
            Mock Test-GeneratedDataComplete { $script:Complete }
            Mock Invoke-GeneratorProcess { $script:Complete = $true; return 0 }
            $result = Invoke-SeedForTest -Target 'sql'
            $result.Generated | Should -BeTrue
            Should -Invoke Invoke-GeneratorProcess -Exactly -Times 1
        }

        It 'runs the generators from data/, not from data/seed/' {
            $script:Complete = $false
            Mock Test-GeneratedDataComplete { $script:Complete }
            Mock Invoke-GeneratorProcess { $script:Complete = $true; return 0 }
            Invoke-SeedForTest -Target 'sql' | Out-Null
            Should -Invoke Invoke-GeneratorProcess -Exactly -Times 1 -ParameterFilter {
                $DataRoot -like '*seed*..'
            }
        }

        It 'fails, seeding nothing, when the generator exits non-zero' {
            Mock Test-GeneratedDataComplete { $false }
            Mock Invoke-GeneratorProcess { 1 }
            { Invoke-SeedForTest -Target 'sql' } | Should -Throw '*exit code 1*'
            Should -Invoke Invoke-SqlSeed -Exactly -Times 0
        }

        It 'fails when the generator claims success but the dataset is still incomplete' {
            Mock Test-GeneratedDataComplete { $false }
            Mock Invoke-GeneratorProcess { 0 }
            { Invoke-SeedForTest -Target 'sql' } | Should -Throw '*incomplete dataset*'
            Should -Invoke Invoke-SqlSeed -Exactly -Times 0
        }
    }

    Context 'missing prerequisites fail fast, before anything is written' {
        It 'names python when it is not on PATH' {
            Mock Test-GeneratedDataComplete { $false }
            Mock Get-Command { $null } -ParameterFilter { $Name -eq 'python' }
            { Invoke-SeedForTest -Target 'sql' } | Should -Throw '*is not on PATH*'
            Should -Invoke Invoke-SqlSeed -Exactly -Times 0
            Should -Invoke Invoke-GeneratorProcess -Exactly -Times 0
        }

        It 'explains the -SkipGenerate contradiction rather than seeding half a dataset' {
            Mock Test-GeneratedDataComplete { $false }
            { Invoke-SeedForTest -Target 'sql' -AsSkipGenerate } | Should -Throw '*-SkipGenerate*'
            Should -Invoke Invoke-SqlSeed -Exactly -Times 0
        }

        It 'refuses to run outside a full checkout' {
            Mock Test-GeneratedDataComplete { $false }
            { Invoke-Main -Target 'sql' -SeedRoot (Join-Path -Path $TestDrive -ChildPath 'not-a-checkout' -AdditionalChildPath 'seed') } |
                Should -Throw '*full checkout*'
        }

        It 'surfaces a seeding-half failure instead of continuing to the other plane' {
            Mock Invoke-SqlSeed { throw 'server unreachable' }
            { Invoke-SeedForTest -Target 'both' } | Should -Throw '*server unreachable*'
            Should -Invoke Invoke-LakehouseSeed -Exactly -Times 0
        }
    }

    Context '-WhatIf' {
        It 'runs no generator subprocess' {
            Mock Test-GeneratedDataComplete { $false }
            Invoke-SeedForTest -Target 'both' -AsWhatIf | Out-Null
            Should -Invoke Invoke-GeneratorProcess -Exactly -Times 0
        }

        It 'still reaches both halves, each of them gated' {
            Invoke-SeedForTest -Target 'both' -AsWhatIf | Out-Null
            Should -Invoke Invoke-SqlSeed -Exactly -Times 1 -ParameterFilter { $WhatIf -eq $true }
            Should -Invoke Invoke-LakehouseSeed -Exactly -Times 1 -ParameterFilter { $WhatIf -eq $true }
        }
    }

    Context '-SchemaOnly (F20: post-L7 grant pass needs no dataset)' {
        It 'skips dataset generation entirely, even when the dataset is missing' {
            Mock Test-GeneratedDataComplete { $false }
            $result = Invoke-SeedForTest -Target 'sql' -AsSchemaOnly
            $result.Generated | Should -BeFalse
            Should -Invoke Test-GeneratedDataComplete -Exactly -Times 0
            Should -Invoke Invoke-GeneratorProcess -Exactly -Times 0
        }

        It 'needs no -SkipGenerate - -SchemaOnly alone skips the dataset, dataset or not' {
            Mock Test-GeneratedDataComplete { $false }
            { Invoke-SeedForTest -Target 'sql' -AsSchemaOnly } | Should -Not -Throw
        }

        It 'forwards -SchemaOnly to Invoke-SqlSeed' {
            Invoke-SeedForTest -Target 'sql' -AsSchemaOnly | Out-Null
            Should -Invoke Invoke-SqlSeed -Exactly -Times 1 -ParameterFilter { $SchemaOnly -eq $true }
        }

        It 'forwards the workload identity L7 supplies, so the contained-user grant can be applied (F172)' {
            # THE PARAMETERS HAVE TO REACH Invoke-Main, NOT MERELY THE SCRIPT'S param BLOCK.
            # The first version read $SqlWorkloadUserName out of the enclosing script scope,
            # which works when seed.ps1 is RUN and is unreachable when it is TESTED - this
            # suite sets MLS_SKIP_MAIN and calls Invoke-Main directly, so the grant would
            # have been exercised with the empty string on every single run of this file.
            Invoke-SeedForTest -Target 'sql' -AsSchemaOnly `
                -WorkloadUserName 'mls-data-api-demo-id' `
                -WorkloadUserClientId 'c1c1c1c1-0000-4000-8000-00000000c1d1' | Out-Null
            Should -Invoke Invoke-SqlSeed -Exactly -Times 1 -ParameterFilter {
                $WorkloadUserName -eq 'mls-data-api-demo-id' -and
                $WorkloadUserClientId -eq 'c1c1c1c1-0000-4000-8000-00000000c1d1'
            }
        }

        It 'forwards nothing when no identity was supplied - the L6 case, where there is none yet' {
            Invoke-SeedForTest -Target 'sql' -AsSchemaOnly | Out-Null
            Should -Invoke Invoke-SqlSeed -Exactly -Times 1 -ParameterFilter {
                [string]::IsNullOrEmpty($WorkloadUserName) -and [string]::IsNullOrEmpty($WorkloadUserClientId)
            }
        }

        It 'does not forward -SchemaOnly when it was not requested' {
            Invoke-SeedForTest -Target 'sql' | Out-Null
            Should -Invoke Invoke-SqlSeed -Exactly -Times 1 -ParameterFilter { $SchemaOnly -eq $false }
        }

        It 'rejects -Target lakehouse - there is no lakehouse DDL step' {
            { Invoke-SeedForTest -Target 'lakehouse' -AsSchemaOnly } | Should -Throw '*-SchemaOnly*'
            Should -Invoke Invoke-LakehouseSeed -Exactly -Times 0
            Should -Invoke Invoke-SqlSeed -Exactly -Times 0
        }

        It 'rejects -Target both - the lakehouse half has no schema-only mode' {
            { Invoke-SeedForTest -Target 'both' -AsSchemaOnly } | Should -Throw '*-SchemaOnly*'
        }
    }
}
