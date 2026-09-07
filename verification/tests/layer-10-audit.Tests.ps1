# Pester tests for verification/layer-10-audit.ps1 - every gh and az call mocked;
# zero cloud calls.
#
# REWRITTEN 2026-09-07 for the operations model. The previous suite tested a seeded
# alert's seven-stage trail against apps/vuln-lab: it asserted things like "the witness
# was never stamped" and "2 of 3 pins is the pass line", none of which exist any more.
# The stages it protected are still tested - they moved into Get-HealTrail and are
# exercised per healed finding below.

BeforeAll {
    $env:MLS_SKIP_MAIN = '1'
    . (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'layer-10-audit.ps1')
    # No Set-StrictMode -Off: the audit scripts set -Version Latest and CI runs them
    # that way, so the harness must not relax the language mode it is testing (F49).

    $script:ReportRoot = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath "mls-l10-$([guid]::NewGuid().ToString('n'))"
    $script:Repository = 'paulcfuqua/azure-devsecops-demo'
    $script:Automation = 'mls-automation'
    $script:EnvironmentVariable = @('MLS_VERIFIER_GH_TOKEN', 'GH_TOKEN', 'GITHUB_TOKEN')
    $script:SavedEnvironment = @{}
    foreach ($name in $script:EnvironmentVariable) { $script:SavedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name) }

    function Get-Row {
        param($Context, [string]$Id)
        return @($Context.Criterion | Where-Object { $_.Id -eq $Id })[0]
    }

    function New-PolicyFile {
        param(
            [int]$CriticalDays = 7,
            [int]$MediumDays = 30,
            [int]$Lookback = 30,
            [string[]]$ExcludedManifest = @('apps/vuln-lab/package-lock.json'),
            [string[]]$ExcludedPrefix = @('apps/vuln-lab/')
        )
        $path = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath "mls-policy-$([guid]::NewGuid().ToString('n')).json"
        @{
            slo                 = @{ days = @{ critical = $CriticalDays; high = $CriticalDays; medium = $MediumDays; low = $MediumDays } }
            closureLookbackDays = @{ value = $Lookback }
            excludedPaths       = @{ manifests = $ExcludedManifest; sourcePrefixes = $ExcludedPrefix }
        } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $path -Encoding utf8
        return $path
    }

    function New-NamingFile {
        # Only the appKeys block matters, and the map is deliberately NOT the identity
        # function - mcp-tools keys to `mcp`, which is exactly the trap Get-AppKeyMap
        # exists to avoid.
        $path = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath "mls-naming-$([guid]::NewGuid().ToString('n')).bicep"
        @(
            'var appKeys = {'
            "  launchOps: 'launch-ops'"
            "  controlTower: 'control-tower'"
            "  mcpTools: 'mcp'"
            "  dataApi: 'data-api'"
            '}'
        ) | Set-Content -LiteralPath $path -Encoding utf8
        return $path
    }

    function Invoke-AuditForTest {
        param(
            [switch]$NoRetry,
            [string]$AlertSurfaceReadable = 'true',
            [string]$PolicyPath = '',
            [string]$NamingBicepPath = ''
        )
        Invoke-Main -Repository $script:Repository -ResourceGroupName 'mls-rg-apps' `
            -Prefix 'mls' -EnvironmentSegment 'demo' `
            -PolicyPath $(if ($PolicyPath) { $PolicyPath } else { $script:PolicyPath }) `
            -NamingBicepPath $(if ($NamingBicepPath) { $NamingBicepPath } else { $script:NamingPath }) `
            -AlertSurfaceReadable $AlertSurfaceReadable `
            -ReportRoot $script:ReportRoot -NoRetry:$NoRetry
    }
}

AfterAll {
    foreach ($name in $script:EnvironmentVariable) { [Environment]::SetEnvironmentVariable($name, $script:SavedEnvironment[$name]) }
    Remove-Item Env:\MLS_SKIP_MAIN -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $script:ReportRoot) {
        Remove-Item -LiteralPath $script:ReportRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'layer-10-audit' {
    BeforeEach {
        foreach ($name in $script:EnvironmentVariable) { [Environment]::SetEnvironmentVariable($name, $null) }
        $env:GH_TOKEN = 'ghp-verifier-read-only'
        Mock Write-MlsStatus {} -ModuleName 'MlsAudit'
        Mock Wait-MlsRetryInterval {} -ModuleName 'MlsAudit'

        $script:PolicyPath = New-PolicyFile
        $script:NamingPath = New-NamingFile
        $script:HealCandidate = $null

        $now = [datetime]::UtcNow
        # The steady state this model expects: nothing open, one closure fully explained.
        $script:DependabotAlert = @(
            [pscustomobject]@{
                number = 91; state = 'fixed'
                created_at = $now.AddDays(-3).ToString('o'); fixed_at = $now.AddDays(-2).ToString('o')
                security_advisory = [pscustomobject]@{ severity = 'high' }
                security_vulnerability = [pscustomobject]@{ first_patched_version = [pscustomobject]@{ identifier = '6.16.0' } }
                dependency = [pscustomobject]@{ package = [pscustomobject]@{ name = 'qs' }; manifest_path = 'package-lock.json' }
            }
        )
        $script:CodeAlert = @()
        $script:DependabotReadable = $true
        $script:CodeReadable = $true

        $script:MergedAt = $now.AddDays(-2).ToString('o')
        $script:ArmedAt = $now.AddDays(-2).AddMinutes(-5).ToString('o')
        $script:ArmedBy = $script:Automation
        $script:MergedBy = $script:Automation
        $script:MergeCommit = 'abcdef1234567890abcdef1234567890abcdef12'
        $script:PrTitle = 'fix(deps): Bump qs from 6.15.3 to 6.16.0'
        $script:PrBody = 'Bumps qs.'
        $script:PrFiles = @('apps/mcp-tools/package-lock.json')
        $script:Checks = @('vitest (npm workspace)=success', 'PSScriptAnalyzer + Pester=success', 'deploy to Container Apps=skipped')
        $script:RevisionImage = 'ghcr.io/paulcfuqua/azure-devsecops-demo/mcp-tools:sha-abcdef1'
        $script:RevisionCreated = $now.AddDays(-2).AddMinutes(10).ToString('o')
        $script:AppExists = $true

        Mock Invoke-MlsGh {
            $joined = $Argument -join ' '
            if ($joined -like '*dependabot/alerts?state=all*') {
                if (-not $script:DependabotReadable) { throw 'HTTP 403: Resource not accessible by integration' }
                return $script:DependabotAlert
            }
            if ($joined -like '*code-scanning/alerts?state=all*') {
                if (-not $script:CodeReadable) { throw 'HTTP 403: Resource not accessible by integration' }
                return $script:CodeAlert
            }
            if ($joined -match 'dependabot/alerts/(\d+)$') {
                $number = [int]$Matches[1]
                return @($script:DependabotAlert | Where-Object { $_.number -eq $number })[0]
            }
            if ($joined -like 'pr list*') {
                return @([pscustomobject]@{
                        number = 247; title = $script:PrTitle; body = $script:PrBody
                        mergedAt = $script:MergedAt; headRefOid = 'head1234'
                        mergeCommit = [pscustomobject]@{ oid = $script:MergeCommit }
                        mergedBy = [pscustomobject]@{ login = $script:MergedBy }
                        autoMergeRequest = $(if ($script:ArmedBy) {
                                [pscustomobject]@{ enabledBy = [pscustomobject]@{ login = $script:ArmedBy }; enabledAt = $script:ArmedAt }
                            } else { $null })
                        author = [pscustomobject]@{ login = 'app/dependabot' }
                    })
            }
            if ($joined -like '*/pulls/*/files*') {
                return @($script:PrFiles | ForEach-Object { [pscustomobject]@{ filename = $_ } })
            }
            if ($joined -like '*check-runs*') {
                return @($script:Checks | ForEach-Object {
                        $part = $_ -split '='
                        [pscustomobject]@{ name = $part[0]; conclusion = $part[1] }
                    })
            }
            return $null
        }

        Mock Invoke-MlsAz {
            if (-not $script:AppExists) { return @() }
            return @([pscustomobject]@{ name = 'rev-1'; created = $script:RevisionCreated; image = $script:RevisionImage })
        }
    }

    AfterEach {
        Remove-Item -LiteralPath $script:PolicyPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $script:NamingPath -Force -ErrorAction SilentlyContinue
    }

    Context 'the steady state: a drained backlog and one explained closure' {
        It 'records V10.1-V10.4 as PASS and exits 0' {
            $context = Invoke-AuditForTest -NoRetry
            @($context.Criterion).Id | Should -Be @('V10.1', 'V10.2', 'V10.3', 'V10.4')
            @($context.Criterion | Where-Object { $_.Status -ne 'PASS' }) | Should -BeNullOrEmpty
            Get-MlsExitCode -Context $context | Should -Be 0
        }

        It 'reports the backlog per lane and per severity rather than as one number' {
            # A blended figure hides the slice that is not moving, which is the whole
            # reason the design says never to average them.
            $script:DependabotAlert += [pscustomobject]@{
                number = 92; state = 'open'
                created_at = ([datetime]::UtcNow.AddDays(-1)).ToString('o'); fixed_at = ''
                security_advisory = [pscustomobject]@{ severity = 'medium' }
                security_vulnerability = [pscustomobject]@{ first_patched_version = [pscustomobject]@{ identifier = '1.2.3' } }
                dependency = [pscustomobject]@{ package = [pscustomobject]@{ name = 'left-pad' }; manifest_path = 'package-lock.json' }
            }
            $observed = (Get-Row -Context (Invoke-AuditForTest -NoRetry) -Id 'V10.1').Observed
            $observed | Should -BeLike '*dependabot=1*'
            $observed | Should -BeLike '*medium=1*'
        }

        It 'binds the deploy stage to the merge commit through the image tag' {
            # The tag is `sha-<first 7>`, which every app CI already computes. Nothing
            # about this needs the applications to cooperate.
            (Get-Row -Context (Invoke-AuditForTest -NoRetry) -Id 'V10.2').Observed | Should -BeLike '*healed:PR #247*'
        }
    }

    Context 'V10.1 - the backlog drains' {
        It 'FAILS a healable finding that has outlived its declared SLO' {
            $script:DependabotAlert += [pscustomobject]@{
                number = 93; state = 'open'
                created_at = ([datetime]::UtcNow.AddDays(-40)).ToString('o'); fixed_at = ''
                security_advisory = [pscustomobject]@{ severity = 'critical' }
                security_vulnerability = [pscustomobject]@{ first_patched_version = [pscustomobject]@{ identifier = '2.0.0' } }
                dependency = [pscustomobject]@{ package = [pscustomobject]@{ name = 'minimist' }; manifest_path = 'package-lock.json' }
            }
            $row = Get-Row -Context (Invoke-AuditForTest -NoRetry) -Id 'V10.1'
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -BeLike '*PAST SLO*#93*minimist*'
            Get-MlsExitCode -Context (Invoke-AuditForTest -NoRetry) | Should -Be 1
        }

        It 'does NOT age a finding that has no upstream fix - that is pending-solution' {
            $script:DependabotAlert += [pscustomobject]@{
                number = 94; state = 'open'
                created_at = ([datetime]::UtcNow.AddDays(-90)).ToString('o'); fixed_at = ''
                security_advisory = [pscustomobject]@{ severity = 'high' }
                security_vulnerability = [pscustomobject]@{ first_patched_version = $null }
                dependency = [pscustomobject]@{ package = [pscustomobject]@{ name = 'nofix' }; manifest_path = 'package-lock.json' }
            }
            $row = Get-Row -Context (Invoke-AuditForTest -NoRetry) -Id 'V10.1'
            $row.Status | Should -Be 'PASS'
            $row.Observed | Should -BeLike '*pending-solution: 1*'
        }

        It 'excludes the vuln-lab by policy, and SAYS how many it excluded' {
            # The lab is a manual demonstration generator now. Excluding it must never be
            # silent, or an empty backlog could be manufactured by editing the policy.
            $script:DependabotAlert += [pscustomobject]@{
                number = 95; state = 'open'
                created_at = ([datetime]::UtcNow.AddDays(-90)).ToString('o'); fixed_at = ''
                security_advisory = [pscustomobject]@{ severity = 'critical' }
                security_vulnerability = [pscustomobject]@{ first_patched_version = [pscustomobject]@{ identifier = '1.2.8' } }
                dependency = [pscustomobject]@{ package = [pscustomobject]@{ name = 'minimist' }; manifest_path = 'apps/vuln-lab/package-lock.json' }
            }
            $row = Get-Row -Context (Invoke-AuditForTest -NoRetry) -Id 'V10.1'
            $row.Status | Should -Be 'PASS'
            $row.Observed | Should -BeLike '*excluded by policy: 1*'
        }

        It 'SKIPs rather than reporting a drained backlog when the surface cannot be read' {
            # F103/F105: an identity that cannot look must never say the queue is empty.
            $script:DependabotReadable = $false
            $row = Get-Row -Context (Invoke-AuditForTest -NoRetry) -Id 'V10.1'
            $row.Status | Should -Be 'SKIP'
            $row.Observed | Should -BeLike '*not fully readable*'
            $row.Observed | Should -Not -BeLike '*drained*'
        }

        It 'SKIPs rather than inventing an SLO when no policy is declared' {
            $row = Get-Row -Context (Invoke-AuditForTest -NoRetry -PolicyPath (Join-Path ([IO.Path]::GetTempPath()) 'no-such-policy.json')) -Id 'V10.1'
            $row.Status | Should -Be 'SKIP'
            $row.Observed | Should -BeLike '*no declared self-heal policy*'
        }
    }

    Context 'V10.2 - every closure is traceable' {
        It 'FAILS a closure with no merged pull request behind it' {
            $script:PrTitle = 'chore: something unrelated'
            $row = Get-Row -Context (Invoke-AuditForTest -NoRetry) -Id 'V10.2'
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -BeLike '*no merged pull request in the window explains it*'
        }

        It 'FAILS a heal a human merged at their own discretion' {
            # F191's question: WHEN was the decision made, not who is credited with it.
            $script:ArmedBy = ''
            $row = Get-Row -Context (Invoke-AuditForTest -NoRetry) -Id 'V10.2'
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -BeLike '*discretionary act*'
        }

        It 'FAILS when a third identity completed what the chain armed' {
            $script:MergedBy = 'someone-else'
            (Get-Row -Context (Invoke-AuditForTest -NoRetry) -Id 'V10.2').Observed |
                Should -BeLike '*third identity*'
        }

        It 'FAILS when the gauntlet was not green' {
            $script:Checks = @('vitest (npm workspace)=failure', 'PSScriptAnalyzer + Pester=success')
            (Get-Row -Context (Invoke-AuditForTest -NoRetry) -Id 'V10.2').Observed |
                Should -BeLike '*gauntlet not green*'
        }

        It 'FAILS when the changed application never ran this heal' {
            $script:RevisionImage = 'ghcr.io/paulcfuqua/azure-devsecops-demo/mcp-tools:sha-0000000'
            $row = Get-Row -Context (Invoke-AuditForTest -NoRetry) -Id 'V10.2'
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -BeLike '*mls-mcp-demo-ca never ran this heal*'
        }

        It 'resolves the container app through naming.bicep, not the directory name' {
            # apps/mcp-tools keys to `mcp`. Assuming the directory would look up
            # mls-mcp-tools-demo-ca, which does not exist, and report a good heal as
            # undeployed.
            $script:RevisionImage = 'ghcr.io/x/y:sha-0000000'
            (Get-Row -Context (Invoke-AuditForTest -NoRetry) -Id 'V10.2').Observed |
                Should -BeLike '*mls-mcp-demo-ca*'
        }

        It 'REPORTS rather than fails a heal that touched no deployed application' {
            $script:PrFiles = @('verification/layer-10-audit.ps1', 'docs/runbooks/layers/L10.md')
            $row = Get-Row -Context (Invoke-AuditForTest -NoRetry) -Id 'V10.2'
            $row.Status | Should -Be 'PASS'
            $row.Observed | Should -BeLike '*no deployed application on its changed paths*'
        }

        It 'REPORTS rather than fails when the application is not deployed at all' {
            # Absence of the app is a different fact from absence of the revision.
            $script:AppExists = $false
            $row = Get-Row -Context (Invoke-AuditForTest -NoRetry) -Id 'V10.2'
            $row.Status | Should -Be 'PASS'
            $row.Observed | Should -BeLike '*not deployed - no deploy assertion*'
        }

        It 'accepts a dismissal that carries a recorded reason' {
            $script:DependabotAlert[0].state = 'dismissed'
            $script:DependabotAlert[0] | Add-Member -NotePropertyName dismissed_at -NotePropertyValue ([datetime]::UtcNow.AddDays(-1).ToString('o')) -Force
            $script:DependabotAlert[0] | Add-Member -NotePropertyName dismissed_reason -NotePropertyValue 'not_used' -Force
            $row = Get-Row -Context (Invoke-AuditForTest -NoRetry) -Id 'V10.2'
            $row.Status | Should -Be 'PASS'
            $row.Observed | Should -BeLike '*dismissed:not_used*'
        }

        It 'FAILS a dismissal with no reason recorded' {
            $script:DependabotAlert[0].state = 'dismissed'
            $script:DependabotAlert[0] | Add-Member -NotePropertyName dismissed_at -NotePropertyValue ([datetime]::UtcNow.AddDays(-1).ToString('o')) -Force
            $script:DependabotAlert[0] | Add-Member -NotePropertyName dismissed_reason -NotePropertyValue '' -Force
            (Get-Row -Context (Invoke-AuditForTest -NoRetry) -Id 'V10.2').Observed |
                Should -BeLike '*NO recorded reason*'
        }

        It 'passes when nothing closed in the window, and says so' {
            $script:DependabotAlert = @()
            $row = Get-Row -Context (Invoke-AuditForTest -NoRetry) -Id 'V10.2'
            $row.Status | Should -Be 'PASS'
            $row.Observed | Should -BeLike '*nothing to explain*'
        }
    }

    Context 'V10.3 - the alert surface was readable' {
        It 'passes when the chain reported readable=true' {
            (Get-Row -Context (Invoke-AuditForTest -NoRetry) -Id 'V10.3').Status | Should -Be 'PASS'
        }

        It 'FAILS a denial, and never calls it "nothing to heal"' {
            $row = Get-Row -Context (Invoke-AuditForTest -NoRetry -AlertSurfaceReadable 'false') -Id 'V10.3'
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -BeLike '*could NOT read*'
            $row.Observed | Should -Not -BeLike '*nothing to heal*'
        }

        It 'FAILS when the chain did not say either way' {
            # An absent value is UNOBSERVABLE, and unobservable is not healthy. With the
            # plant gone, "no findings" is the expected steady state - so a denial that
            # read as an empty queue would look exactly like success, forever.
            $row = Get-Row -Context (Invoke-AuditForTest -NoRetry -AlertSurfaceReadable '') -Id 'V10.3'
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -BeLike '*did not report whether*'
        }
    }

    Context 'V10.4 - pending-solution is not a dumping ground' {
        It 'passes when nothing is being held' {
            (Get-Row -Context (Invoke-AuditForTest -NoRetry) -Id 'V10.4').Observed |
                Should -BeLike '*no finding is being held*'
        }

        It 'FAILS a finding held as unfixable while the advisory names a patched version' {
            # The list projection says there is no fix; the re-read says there is. The
            # re-read wins, because that is the claim the whole state rests on.
            $held = [pscustomobject]@{
                number = 96; state = 'open'
                created_at = ([datetime]::UtcNow.AddDays(-2)).ToString('o'); fixed_at = ''
                security_advisory = [pscustomobject]@{ severity = 'high' }
                security_vulnerability = [pscustomobject]@{ first_patched_version = $null }
                dependency = [pscustomobject]@{ package = [pscustomobject]@{ name = 'held' }; manifest_path = 'package-lock.json' }
            }
            $script:DependabotAlert += $held
            Mock Invoke-MlsGh {
                $joined = $Argument -join ' '
                if ($joined -like '*dependabot/alerts?state=all*') { return $script:DependabotAlert }
                if ($joined -like '*code-scanning/alerts?state=all*') { return @() }
                if ($joined -match 'dependabot/alerts/96$') {
                    return [pscustomobject]@{
                        security_vulnerability = [pscustomobject]@{ first_patched_version = [pscustomobject]@{ identifier = '9.9.9' } }
                    }
                }
                if ($joined -like 'pr list*') { return @() }
                return $null
            }
            $row = Get-Row -Context (Invoke-AuditForTest -NoRetry) -Id 'V10.4'
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -BeLike '*the advisory names a patched version: 9.9.9*'
        }
    }

    Context 'Get-AppKeyMap reads naming.bicep rather than restating it' {
        It 'maps the directory to the appKey, including where they differ' {
            $map = Get-AppKeyMap -NamingBicepPath $script:NamingPath
            $map['mcp-tools'] | Should -Be 'mcp'
            $map['launch-ops'] | Should -Be 'launch-ops'
            $map['control-tower'] | Should -Be 'control-tower'
        }

        It 'returns an empty map when naming.bicep cannot be read, so callers can say so' {
            (Get-AppKeyMap -NamingBicepPath (Join-Path ([IO.Path]::GetTempPath()) 'no-such.bicep')).Count |
                Should -Be 0
        }
    }
}
