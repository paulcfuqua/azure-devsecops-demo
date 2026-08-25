# Pester tests for verification/layer-03-audit.ps1 - every Graph call mocked; zero cloud
# calls. The expected values come from the real infra/entra/manifest.json, exactly as the
# audit reads them, so a manifest change is felt here too.

BeforeAll {
    $env:MLS_SKIP_MAIN = '1'
    . (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'layer-03-audit.ps1')
    Set-StrictMode -Off

    $script:ReportRoot = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath "mls-l03-$([guid]::NewGuid().ToString('n'))"
    $script:Domain = 'meridianlaunch.onmicrosoft.com'
    $script:ManifestPath = Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath '..', 'infra', 'entra', 'manifest.json'
    $script:Manifest = Get-Content -LiteralPath $script:ManifestPath -Raw | ConvertFrom-Json
    $script:SkuId = '99999999-9999-9999-9999-999999999999'
    $script:DomainVariable = @('MLS_TENANT_DOMAIN', 'TENANT_DOMAIN')
    $script:SavedEnvironment = @{}
    foreach ($name in $script:DomainVariable) { $script:SavedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name) }

    function Get-Row {
        param($Context, [string]$Id)
        return @($Context.Criterion | Where-Object { $_.Id -eq $Id })[0]
    }

    function Invoke-AuditForTest {
        param([switch]$NoRetry, [string]$Domain = $script:Domain)
        Invoke-Main -Domain $Domain -ReportRoot $script:ReportRoot -NoRetry:$NoRetry
    }

    function Get-GroupByName {
        param([string]$Name)
        return @($script:Manifest.groups | Where-Object { $_.displayName -eq $Name })[0]
    }
}

AfterAll {
    foreach ($name in $script:DomainVariable) { [Environment]::SetEnvironmentVariable($name, $script:SavedEnvironment[$name]) }
    Remove-Item Env:\MLS_SKIP_MAIN -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $script:ReportRoot) {
        Remove-Item -LiteralPath $script:ReportRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'layer-03-audit' {
    BeforeEach {
        Mock Write-MlsStatus {} -ModuleName 'MlsAudit'
        Mock Wait-MlsRetryInterval {} -ModuleName 'MlsAudit'

        $script:CaState = 'enabledForReportingButNotEnforced'
        $script:LicenseState = 'Active'
        $script:LicenseError = 'None'
        $script:MissingMember = ''
        $script:ExtraGroupName = ''

        Mock Invoke-MlsGraph {
            if ($Uri -like '*subscribedSkus*') {
                return [pscustomobject]@{ value = @([pscustomobject]@{ skuPartNumber = 'EMSPREMIUM'; skuId = $script:SkuId }) }
            }
            if ($Uri -like '*conditionalAccess/policies*') {
                return [pscustomobject]@{ value = @($script:Manifest.conditionalAccessPolicies | ForEach-Object {
                            [pscustomobject]@{ displayName = $_.displayName; state = $script:CaState }
                        })
                }
            }
            if ($Uri -match '/groups/(?<id>[^/]+)/members') {
                $groupName = $Matches['id'] -replace '^id-', ''
                $group = Get-GroupByName -Name $groupName
                $member = @($group.members | Where-Object { $_ -ne $script:MissingMember } | ForEach-Object {
                        [pscustomobject]@{ userPrincipalName = "$_@$($script:Domain)" }
                    })
                return [pscustomobject]@{ value = $member }
            }
            if ($Uri -like '*/groups?*startswith*') {
                $names = @($script:Manifest.groups | ForEach-Object { $_.displayName })
                if ($script:ExtraGroupName) { $names += $script:ExtraGroupName }
                return [pscustomobject]@{ value = @($names | ForEach-Object { [pscustomobject]@{ id = "id-$_"; displayName = $_ } }) }
            }
            if ($Uri -match "/groups\?.*displayName eq '(?<name>[^']+)'") {
                $name = $Matches['name']
                return [pscustomobject]@{ value = @([pscustomobject]@{ id = "id-$name"; displayName = $name }) }
            }
            if ($Uri -like '*/applications?*startswith*') {
                return [pscustomobject]@{ value = @($script:Manifest.appRegistrations | ForEach-Object {
                            [pscustomobject]@{ id = "id-$($_.displayName)"; displayName = $_.displayName }
                        })
                }
            }
            if ($Uri -match "/applications\?.*displayName eq '(?<name>[^']+)'") {
                return [pscustomobject]@{ value = @([pscustomobject]@{ id = "id-$($Matches['name'])"; displayName = $Matches['name'] }) }
            }
            if ($Uri -like '*/users/*licenseAssignmentStates*') {
                return [pscustomobject]@{
                    licenseAssignmentStates = @([pscustomobject]@{ skuId = $script:SkuId; state = $script:LicenseState; error = $script:LicenseError })
                }
            }
            if ($Uri -like '*/users/*') {
                return [pscustomobject]@{ id = 'user-object-id'; userPrincipalName = ($Uri -split '/')[-1] }
            }
            throw "unexpected Graph call: $Uri"
        }
    }

    Context 'all criteria pass' {
        It 'records V3.1-V3.4 as PASS and exits 0' {
            $context = Invoke-AuditForTest
            @($context.Criterion).Id | Should -Be @('V3.1', 'V3.2', 'V3.3', 'V3.4')
            @($context.Criterion | Where-Object { $_.Status -ne 'PASS' }) | Should -BeNullOrEmpty
            Get-MlsExitCode -Context $context | Should -Be 0
        }

        It 'expects exactly the manifest counts' {
            $context = Invoke-AuditForTest
            (Get-Row -Context $context -Id 'V3.1').Expected | Should -BeLike '*5 users*'
            (Get-Row -Context $context -Id 'V3.1').Expected | Should -BeLike '*4 groups*'
            (Get-Row -Context $context -Id 'V3.1').Expected | Should -BeLike '*3 app registrations*'
        }
    }

    Context 'a criterion fails on a realistic wrong value' {
        It 'fails V3.3 immediately when a CA policy is enforced, and flags the safety risk' {
            $script:CaState = 'enabled'
            $context = Invoke-AuditForTest
            $row = Get-Row -Context $context -Id 'V3.3'
            $row.Status | Should -Be 'FAIL'
            $row.Attempt | Should -Be 1
            $row.Detail | Should -BeLike '*SAFETY FLAG*'
            Should -Invoke Wait-MlsRetryInterval -ModuleName 'MlsAudit' -Exactly -Times 0
        }

        It 'fails V3.4 when group licensing reports CountViolation' {
            $script:LicenseState = 'Error'
            $script:LicenseError = 'CountViolation'
            $context = Invoke-AuditForTest -NoRetry
            $row = Get-Row -Context $context -Id 'V3.4'
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -BeLike '*CountViolation*'
        }

        It 'fails V3.2 when a manifest member is missing from its group' {
            $script:MissingMember = 'marcus.webb'
            $context = Invoke-AuditForTest -NoRetry
            $row = Get-Row -Context $context -Id 'V3.2'
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -BeLike '*missing*marcus.webb*'
        }

        It 'fails V3.1 on drift - an mls-prefixed group the manifest does not declare' {
            $script:ExtraGroupName = 'mls-shadow-admins'
            $context = Invoke-AuditForTest -NoRetry
            $row = Get-Row -Context $context -Id 'V3.1'
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -BeLike '*mls-shadow-admins*'
        }
    }

    Context 'retry' {
        It 'retries V3.1 through propagation lag and passes without sleeping the whole window' {
            $script:Calls = 0
            Mock Invoke-MlsGraph {
                if ($Uri -like '*/users/*licenseAssignmentStates*') {
                    return [pscustomobject]@{ licenseAssignmentStates = @([pscustomobject]@{ skuId = $script:SkuId; state = 'Active'; error = 'None' }) }
                }
                if ($Uri -like '*/users/*') {
                    $script:Calls++
                    # First pass: the last user has not replicated yet.
                    if ($script:Calls -eq 5) { return $null }
                    return [pscustomobject]@{ id = 'user-object-id' }
                }
                if ($Uri -like '*subscribedSkus*') {
                    return [pscustomobject]@{ value = @([pscustomobject]@{ skuPartNumber = 'EMSPREMIUM'; skuId = $script:SkuId }) }
                }
                if ($Uri -like '*conditionalAccess/policies*') {
                    return [pscustomobject]@{ value = @($script:Manifest.conditionalAccessPolicies | ForEach-Object {
                                [pscustomobject]@{ displayName = $_.displayName; state = 'enabledForReportingButNotEnforced' } })
                    }
                }
                if ($Uri -match '/groups/(?<id>[^/]+)/members') {
                    $group = Get-GroupByName -Name ($Matches['id'] -replace '^id-', '')
                    return [pscustomobject]@{ value = @($group.members | ForEach-Object { [pscustomobject]@{ userPrincipalName = "$_@$($script:Domain)" } }) }
                }
                if ($Uri -like '*/groups?*startswith*') {
                    return [pscustomobject]@{ value = @($script:Manifest.groups | ForEach-Object { [pscustomobject]@{ id = "id-$($_.displayName)"; displayName = $_.displayName } }) }
                }
                if ($Uri -match "/groups\?.*displayName eq '(?<name>[^']+)'") {
                    return [pscustomobject]@{ value = @([pscustomobject]@{ id = "id-$($Matches['name'])"; displayName = $Matches['name'] }) }
                }
                if ($Uri -like '*/applications?*startswith*') {
                    return [pscustomobject]@{ value = @($script:Manifest.appRegistrations | ForEach-Object { [pscustomobject]@{ id = "id-$($_.displayName)"; displayName = $_.displayName } }) }
                }
                if ($Uri -match "/applications\?.*displayName eq '(?<name>[^']+)'") {
                    return [pscustomobject]@{ value = @([pscustomobject]@{ id = "id-x"; displayName = $Matches['name'] }) }
                }
                throw "unexpected Graph call: $Uri"
            }
            $context = Invoke-AuditForTest
            $row = Get-Row -Context $context -Id 'V3.1'
            $row.Status | Should -Be 'PASS'
            $row.Attempt | Should -Be 2
            $row.SleptSeconds | Should -Be 300
            $row.SleptSeconds | Should -BeLessThan (30 * 60)
            Should -Invoke Wait-MlsRetryInterval -ModuleName 'MlsAudit' -Exactly -Times 1
        }
    }

    Context 'a check that throws' {
        It 'records V3.3 as FAIL and still evaluates the other criteria' {
            Mock Invoke-MlsGraph {
                if ($Uri -like '*conditionalAccess/policies*') { throw 'Authorization_RequestDenied: Policy.Read.All is not consented on mls-verifier.' }
                if ($Uri -like '*subscribedSkus*') { return [pscustomobject]@{ value = @([pscustomobject]@{ skuPartNumber = 'EMSPREMIUM'; skuId = $script:SkuId }) } }
                if ($Uri -like '*/users/*licenseAssignmentStates*') { return [pscustomobject]@{ licenseAssignmentStates = @([pscustomobject]@{ skuId = $script:SkuId; state = 'Active'; error = 'None' }) } }
                if ($Uri -like '*/users/*') { return [pscustomobject]@{ id = 'u' } }
                if ($Uri -match '/groups/(?<id>[^/]+)/members') {
                    $group = Get-GroupByName -Name ($Matches['id'] -replace '^id-', '')
                    return [pscustomobject]@{ value = @($group.members | ForEach-Object { [pscustomobject]@{ userPrincipalName = "$_@$($script:Domain)" } }) }
                }
                if ($Uri -like '*/groups?*startswith*') { return [pscustomobject]@{ value = @($script:Manifest.groups | ForEach-Object { [pscustomobject]@{ id = "id-$($_.displayName)"; displayName = $_.displayName } }) } }
                if ($Uri -match "/groups\?.*displayName eq '(?<name>[^']+)'") { return [pscustomobject]@{ value = @([pscustomobject]@{ id = "id-$($Matches['name'])"; displayName = $Matches['name'] }) } }
                if ($Uri -like '*/applications?*startswith*') { return [pscustomobject]@{ value = @($script:Manifest.appRegistrations | ForEach-Object { [pscustomobject]@{ id = 'a'; displayName = $_.displayName } }) } }
                if ($Uri -match "/applications\?.*displayName eq '(?<name>[^']+)'") { return [pscustomobject]@{ value = @([pscustomobject]@{ id = 'a'; displayName = $Matches['name'] }) } }
                throw "unexpected Graph call: $Uri"
            }
            $context = Invoke-AuditForTest -NoRetry
            @($context.Criterion).Count | Should -Be 4
            (Get-Row -Context $context -Id 'V3.3').Status | Should -Be 'FAIL'
            (Get-Row -Context $context -Id 'V3.3').Observed | Should -BeLike '*Authorization_RequestDenied*'
            (Get-Row -Context $context -Id 'V3.4').Status | Should -Be 'PASS'
        }
    }

    Context 'missing input' {
        It 'refuses to run without the tenant domain, because UPNs cannot be composed without it' {
            foreach ($name in $script:DomainVariable) { [Environment]::SetEnvironmentVariable($name, $null) }
            { Invoke-AuditForTest -Domain '' } | Should -Throw '*Domain*'
            { Invoke-AuditForTest -Domain '' } | Should -Throw '*MLS_TENANT_DOMAIN*'
        }

        It 'refuses to run when the manifest is absent' {
            { Invoke-Main -Domain $script:Domain -ManifestPath (Join-Path -Path $script:ReportRoot -ChildPath 'no-manifest.json') -ReportRoot $script:ReportRoot } |
                Should -Throw '*not found*'
        }
    }
}
