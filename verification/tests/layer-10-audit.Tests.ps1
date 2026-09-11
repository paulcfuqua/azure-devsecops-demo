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

    # SupportsShouldProcess on both fixture builders: the names carry a state-changing verb
    # and they write files. PSScriptAnalyzer runs at Error+Warning over the whole
    # repository, and a test helper is not exempt from the rules the audits are held to -
    # the same treatment Set-Mode carries in layer-01-audit.Tests.ps1.
    function New-PolicyFile {
        [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
        param(
            [int]$CriticalDays = 7,
            [int]$MediumDays = 30,
            [int]$Lookback = 30,
            [string[]]$ExcludedManifest = @('apps/vuln-lab/package-lock.json'),
            [string[]]$ExcludedPrefix = @('apps/vuln-lab/'),
            [string]$DeferLane = '',
            [string]$DeferExpires = ''
        )
        $path = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath "mls-policy-$([guid]::NewGuid().ToString('n')).json"
        if (-not $PSCmdlet.ShouldProcess($path, 'write policy fixture')) { return $path }
        @{
            slo                 = @{ days = @{ critical = $CriticalDays; high = $CriticalDays; medium = $MediumDays; low = $MediumDays } }
            closureLookbackDays = @{ value = $Lookback }
            excludedPaths       = @{ manifests = $ExcludedManifest; sourcePrefixes = $ExcludedPrefix }
            laneDeferral        = $(if ($DeferLane) {
                    @{ $DeferLane = @{ reason = 'mechanism not built'; expires = $DeferExpires } }
                } else { @{} })
        } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $path -Encoding utf8
        return $path
    }

    function New-NamingFile {
        # Only the appKeys block matters, and the map is deliberately NOT the identity
        # function - mcp-tools keys to `mcp`, which is exactly the trap Get-AppKeyMap
        # exists to avoid.
        [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
        param()
        $path = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath "mls-naming-$([guid]::NewGuid().ToString('n')).bicep"
        if (-not $PSCmdlet.ShouldProcess($path, 'write naming fixture')) { return $path }
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

        # Ancestry of the RUNNING image relative to the heal's merge commit. The default
        # is 'diverged' - an unrelated image that does not contain the heal - so a fixture
        # that changes RevisionImage away from the merge tag still means "this heal never
        # shipped" unless it says otherwise.
        $script:CompareStatus = 'diverged'
        $script:CompareReadable = $true

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
            if ($joined -like '*compare/*') {
                if (-not $script:CompareReadable) { return $null }
                return [pscustomobject]@{ status = $script:CompareStatus }
            }
            return $null
        }

        Mock Invoke-MlsAz {
            # $null, NOT @(). This mock used to hand back an empty array, which is not what
            # `Invoke-MlsAz -AllowFailure` does when the app is absent - it returns $null,
            # and `@($null)` is a ONE-element array in PowerShell. The friendlier fixture
            # was supplying the answer the test was checking, and it hid a real defect:
            # a container app that does not exist read as existing with an unreadable
            # revision, for every app in the estate, for as long as this suite has run.
            if (-not $script:AppExists) { return $null }
            return @([pscustomobject]@{
                    name = 'rev-1'; created = $script:RevisionCreated
                    image = $script:RevisionImage; active = $true
                })
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

    Context 'lane 3 closes by rebuild, and its deferral expires' {
        BeforeEach {
            # A Trivy container-image finding: closed by a rescan, with no PR behind it -
            # and never any prospect of one, because lane 3 changes no file in the repo.
            $script:CodeAlert = @(
                [pscustomobject]@{
                    number = 400; state = 'fixed'
                    created_at = ([datetime]::UtcNow.AddDays(-5)).ToString('o')
                    fixed_at = ([datetime]::UtcNow.AddDays(-1)).ToString('o')
                    rule = [pscustomobject]@{ id = 'CVE-2026-82562'; security_severity_level = 'high'; severity = 'error' }
                    tool = [pscustomobject]@{ name = 'Trivy' }
                    most_recent_instance = [pscustomobject]@{ location = [pscustomobject]@{ path = 'paulcfuqua/azure-devsecops-demo/launch-ops' } }
                })
        }

        It 'does NOT demand a heal pull request for a container-image closure' {
            # V10.2 shipped demanding one and reported 397 of 400 closures unexplained on
            # its first real run - asking lane 3 for evidence that cannot exist.
            $row = Get-Row -Context (Invoke-AuditForTest -NoRetry) -Id 'V10.2'
            $row.Status | Should -Be 'PASS'
            $row.Observed | Should -BeLike '*closed by image rebuild (lane 3): 1*'
        }

        It 'still COUNTS the rebuild closures rather than dropping them silently' {
            # A closure this criterion does not trail is still a closure the report must
            # account for; a silent skip is indistinguishable from a lane nobody watches.
            (Get-Row -Context (Invoke-AuditForTest -NoRetry) -Id 'V10.2').Observed |
                Should -BeLike '*2 closure(s)*'
        }

        It 'defers an OPEN lane-3 finding while the deferral is live, and says how long is left' {
            $script:CodeAlert[0].state = 'open'
            $script:CodeAlert[0].fixed_at = ''
            $script:CodeAlert[0].created_at = ([datetime]::UtcNow.AddDays(-90)).ToString('o')
            $policy = New-PolicyFile -DeferLane 'container-image' -DeferExpires ([datetime]::UtcNow.AddDays(20).ToString('yyyy-MM-dd'))
            $row = Get-Row -Context (Invoke-AuditForTest -NoRetry -PolicyPath $policy) -Id 'V10.1'
            $row.Status | Should -Be 'PASS'
            $row.Observed | Should -BeLike "*lane 'container-image' deferred: 1 finding(s)*"
            $row.Observed | Should -BeLike '*d left*'
            Remove-Item -LiteralPath $policy -Force -ErrorAction SilentlyContinue
        }

        It 'FAILS once the deferral has expired - a deadline, not an amnesty' {
            # The whole justification for deferring rather than excluding. If this did not
            # hold, laneDeferral would be the dumping ground V10.4 exists to prevent.
            $script:CodeAlert[0].state = 'open'
            $script:CodeAlert[0].fixed_at = ''
            $script:CodeAlert[0].created_at = ([datetime]::UtcNow.AddDays(-90)).ToString('o')
            $policy = New-PolicyFile -DeferLane 'container-image' -DeferExpires ([datetime]::UtcNow.AddDays(-1).ToString('yyyy-MM-dd'))
            $row = Get-Row -Context (Invoke-AuditForTest -NoRetry -PolicyPath $policy) -Id 'V10.1'
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -BeLike '*DEFERRAL EXPIRED*'
            $row.Observed | Should -BeLike '*PAST SLO*'
            Remove-Item -LiteralPath $policy -Force -ErrorAction SilentlyContinue
        }
    }

    Context 'a pull request that TALKS about an alert did not heal it' {
        # THE REAL FALSE POSITIVE, USED AS THE FIXTURE. V10.2 matched code-scanning alert
        # #9 (closed 2026-09-04) to PR #254, which merged 2026-09-07 and mentioned
        # "alert #9" only because its description discussed this very defect. A write-up
        # was credited with the heal, three days after the fact, and the criterion went
        # GREEN on it - which is worse than the red it replaced.
        BeforeEach {
            $script:CodeAlert = @(
                [pscustomobject]@{
                    number = 9; state = 'fixed'
                    created_at = ([datetime]::UtcNow.AddDays(-10)).ToString('o')
                    fixed_at = ([datetime]::UtcNow.AddDays(-3)).ToString('o')
                    rule = [pscustomobject]@{ id = 'js/trivial-conditional'; security_severity_level = 'medium'; severity = 'warning' }
                    tool = [pscustomobject]@{ name = 'CodeQL' }
                    most_recent_instance = [pscustomobject]@{ location = [pscustomobject]@{ path = 'apps/mcp-tools/src/thing.ts' } }
                })
            $script:DependabotAlert = @()
        }

        It 'does NOT credit a pull request that merged AFTER the alert closed' {
            # The cheap half of the fix: one comparison, no extra API call, and it alone
            # rules out the #254 case.
            $script:PrBody = 'Alert **#9**: fixed but no auto-merge request on the PR.'
            $script:MergedAt = ([datetime]::UtcNow).ToString('o')   # merged today; alert closed 3d ago
            $script:PrFiles = @('apps/mcp-tools/src/thing.ts')
            (Get-Row -Context (Invoke-AuditForTest -NoRetry) -Id 'V10.2').Observed |
                Should -BeLike '*no merged pull request in the window explains it*'
        }

        It 'does NOT credit a pull request that never touched the file the alert is in' {
            # The other half: a heal edits the flawed code; a write-up does not.
            $script:PrBody = 'Alert **#9** is discussed at length here.'
            $script:MergedAt = ([datetime]::UtcNow.AddDays(-4)).ToString('o')
            $script:ArmedAt = ([datetime]::UtcNow.AddDays(-4).AddMinutes(-5)).ToString('o')
            $script:PrFiles = @('docs/runbooks/layers/L10.md')
            (Get-Row -Context (Invoke-AuditForTest -NoRetry) -Id 'V10.2').Observed |
                Should -BeLike '*no merged pull request in the window explains it*'
        }

        It 'DOES credit a pull request that changed the file, before the alert closed' {
            # The fix must not make every real heal unexplainable.
            $script:PrBody = 'Fixes code scanning alert #9.'
            $script:MergedAt = ([datetime]::UtcNow.AddDays(-4)).ToString('o')
            # Armed BEFORE the merge, or the provenance stage correctly objects - the
            # fixture has to move both clocks together, not just one.
            $script:ArmedAt = ([datetime]::UtcNow.AddDays(-4).AddMinutes(-5)).ToString('o')
            $script:RevisionCreated = ([datetime]::UtcNow.AddDays(-4).AddMinutes(10)).ToString('o')
            $script:PrFiles = @('apps/mcp-tools/src/thing.ts')
            $row = Get-Row -Context (Invoke-AuditForTest -NoRetry) -Id 'V10.2'
            $row.Status | Should -Be 'PASS'
            $row.Observed | Should -BeLike '*healed:PR #247*'
        }
    }

    Context 'a heal that fixed the code without naming the alert' {
        # THE REAL FALSE NEGATIVE, USED AS THE FIXTURE. Code-scanning alert #1
        # (js/polynomial-redos, apps/mcp-tools/src/auth-gate.ts) closed 2026-08-29T04:44:09Z.
        # PR #45 changed that exact file and merged at 04:42:58Z - SEVENTY-ONE SECONDS
        # earlier - and V10.2 reported "no merged pull request in the window explains it"
        # on every scheduled run for a fortnight.
        #
        # The cause was that prose was the PRIMARY matcher: a code-scanning candidate had
        # to name the alert number in its body before the file test was ever reached. An
        # Autofix heal does name it; a hand-written fix that closes the same alert does
        # not, and nothing required it to. The criterion was measuring how a pull request
        # was WORDED, then reporting the answer as whether the estate could explain a
        # closure.
        BeforeEach {
            $script:CodeAlert = @(
                [pscustomobject]@{
                    number = 1; state = 'fixed'
                    created_at = ([datetime]::UtcNow.AddDays(-10)).ToString('o')
                    fixed_at = ([datetime]::UtcNow.AddDays(-4)).ToString('o')
                    rule = [pscustomobject]@{ id = 'js/polynomial-redos'; security_severity_level = 'high'; severity = 'error' }
                    tool = [pscustomobject]@{ name = 'CodeQL' }
                    most_recent_instance = [pscustomobject]@{ location = [pscustomobject]@{ path = 'apps/mcp-tools/src/auth-gate.ts' } }
                })
            $script:DependabotAlert = @()
            $script:PrTitle = 'chore: resolve the Dependabot backlog, close a ReDoS'
            $script:PrBody = 'Bumps a batch of dependencies and closes the ReDoS in the inbound Authorization parse.'
            $script:PrFiles = @('apps/mcp-tools/src/auth-gate.ts', 'apps/mcp-tools/tests/auth-gate.test.ts')
            $script:MergedAt = ([datetime]::UtcNow.AddDays(-4).AddMinutes(-2)).ToString('o')
            $script:ArmedAt = ([datetime]::UtcNow.AddDays(-4).AddMinutes(-7)).ToString('o')
            $script:RevisionCreated = ([datetime]::UtcNow.AddDays(-4).AddMinutes(10)).ToString('o')
        }

        It 'credits a pull request that changed the alert file before it closed, though it never named the alert' {
            $row = Get-Row -Context (Invoke-AuditForTest -NoRetry) -Id 'V10.2'
            $row.Status | Should -Be 'PASS'
            $row.Observed | Should -BeLike '*healed:PR #247*'
        }

        It 'still refuses a pull request that merged AFTER the alert closed, prose or no prose' {
            # Causality is what replaced prose, so it has to hold on the new path too -
            # otherwise this fix has only traded a false negative for the false positive
            # the #254 case already cost.
            $script:MergedAt = ([datetime]::UtcNow).ToString('o')
            (Get-Row -Context (Invoke-AuditForTest -NoRetry) -Id 'V10.2').Observed |
                Should -BeLike '*no merged pull request in the window explains it*'
        }

        It 'still refuses a pull request that never touched the alert file' {
            $script:PrFiles = @('docs/runbooks/layers/L10.md')
            (Get-Row -Context (Invoke-AuditForTest -NoRetry) -Id 'V10.2').Observed |
                Should -BeLike '*no merged pull request in the window explains it*'
        }
    }

    Context 'a heal whose revision Azure has already discarded' {
        # THE SECOND HALF OF THE SAME DAILY RED. Stage 4 demanded a container app revision
        # whose image tag is the heal's merge commit. Every container app in this estate
        # runs activeRevisionsMode=Single with maxInactiveRevisions=0, so Azure DESTROYS
        # the previous revision the moment a new one activates: the evidence this stage
        # requires has a lifetime of "until the next deploy of that app".
        #
        # Alert #9's heal (PR #225, merge 7eb75ce) deployed successfully on 2026-09-04 -
        # the CI deploy job is green on that commit - and by 2026-09-10 the only revision
        # left carried sha-b8dca97. The audit read one revision, did not find the tag, and
        # announced that the app "never ran this heal". It had; the record was gone.
        #
        # So the fallback asserts the CAPABILITY - the healed code is what is running -
        # rather than the artefact that used to accompany it.
        BeforeEach {
            $script:CodeAlert = @(
                [pscustomobject]@{
                    number = 9; state = 'fixed'
                    created_at = ([datetime]::UtcNow.AddDays(-10)).ToString('o')
                    fixed_at = ([datetime]::UtcNow.AddDays(-4)).ToString('o')
                    rule = [pscustomobject]@{ id = 'js/trivial-conditional'; security_severity_level = 'medium'; severity = 'warning' }
                    tool = [pscustomobject]@{ name = 'CodeQL' }
                    most_recent_instance = [pscustomobject]@{ location = [pscustomobject]@{ path = 'apps/mcp-tools/src/data/lakehouse.ts' } }
                })
            $script:DependabotAlert = @()
            $script:PrBody = 'Applies Copilot Autofix for code scanning alert #9.'
            $script:PrFiles = @('apps/mcp-tools/src/data/lakehouse.ts')
            $script:MergedAt = ([datetime]::UtcNow.AddDays(-4)).ToString('o')
            $script:ArmedAt = ([datetime]::UtcNow.AddDays(-4).AddMinutes(-5)).ToString('o')
            # The heal's own revision is gone; a LATER image is what runs now.
            $script:RevisionImage = 'ghcr.io/paulcfuqua/azure-devsecops-demo/mcp-tools:sha-b8dca97'
            $script:RevisionCreated = ([datetime]::UtcNow.AddDays(-1)).ToString('o')
        }

        It 'PASSES when the running image was built from a commit that contains the heal' {
            $script:CompareStatus = 'ahead'
            $row = Get-Row -Context (Invoke-AuditForTest -NoRetry) -Id 'V10.2'
            $row.Status | Should -Be 'PASS'
            $row.Observed | Should -BeLike '*sha-b8dca97*'
        }

        It 'PASSES when the running image is the heal commit itself' {
            $script:CompareStatus = 'identical'
            (Get-Row -Context (Invoke-AuditForTest -NoRetry) -Id 'V10.2').Status | Should -Be 'PASS'
        }

        It 'FAILS when the running image does not contain the heal' {
            # The state the stage exists to catch survives: a heal that merged and never
            # reached the app still reads as never having run.
            $script:CompareStatus = 'behind'
            $row = Get-Row -Context (Invoke-AuditForTest -NoRetry) -Id 'V10.2'
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -BeLike '*never ran this heal*'
        }

        It 'reports UNOBSERVABLE rather than claiming the heal never ran, when ancestry cannot be read' {
            # F102/F103/F105, one level down: an audit that could not look must never
            # report what it did not see. Still red - never green - but it says which.
            $script:CompareReadable = $false
            $row = Get-Row -Context (Invoke-AuditForTest -NoRetry) -Id 'V10.2'
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -BeLike '*could not establish*'
            $row.Observed | Should -Not -BeLike '*never ran this heal*'
        }

        It 'reports UNOBSERVABLE when the running image carries no sha- tag to resolve' {
            $script:RevisionImage = 'ghcr.io/paulcfuqua/azure-devsecops-demo/mcp-tools:latest'
            $row = Get-Row -Context (Invoke-AuditForTest -NoRetry) -Id 'V10.2'
            $row.Observed | Should -BeLike '*could not establish*'
            $row.Observed | Should -Not -BeLike '*never ran this heal*'
        }
    }

    Context 'the candidate window bounds the fetch, and truncation is unobservable' {
        It 'reports SKIP rather than FAIL when the candidate page was truncated' {
            # THE DEFECT THIS GUARDS. The fetch asked for --limit 100 and then filtered by
            # date - the wrong way round. 189 pull requests merged inside the declared
            # 30-day window, so 89 were invisible and V10.2 called alert #1 unexplained
            # when its fixing pull request had simply fallen off the page. A confident
            # wrong answer from an audit that could not see what it was judging.
            #
            # The fetch is now bounded by the window (--search merged:>=<date>), and if a
            # page ever does come back at the ceiling the criterion says so instead of
            # judging on a partial view - the F63/F105 rule applied to pagination.
            $script:PrTitle = 'chore: nothing that mentions the package'
            Mock Invoke-MlsGh {
                $joined = $Argument -join ' '
                if ($joined -like '*dependabot/alerts?state=all*') { return $script:DependabotAlert }
                if ($joined -like '*code-scanning/alerts?state=all*') { return @() }
                if ($joined -like 'pr list*') {
                    return @(1..1000 | ForEach-Object {
                            [pscustomobject]@{
                                number = $_; title = 'chore: unrelated'; body = ''
                                mergedAt = ([datetime]::UtcNow.AddDays(-1)).ToString('o')
                                headRefOid = 'h'; mergeCommit = [pscustomobject]@{ oid = 'x' }
                                mergedBy = [pscustomobject]@{ login = 'x' }; autoMergeRequest = $null
                                author = [pscustomobject]@{ login = 'x' }
                            }
                        })
                }
                return $null
            }
            $row = Get-Row -Context (Invoke-AuditForTest -NoRetry) -Id 'V10.2'
            $row.Status | Should -Be 'SKIP'
            $row.Observed | Should -BeLike '*TRUNCATED*'
        }

        It 'asks the API for the window rather than a page size' {
            # Asserts the call SHAPE, because the bug was invisible in any single result:
            # a date-bounded search cannot silently drop the older half of the window.
            $captured = ''
            Mock Invoke-MlsGh {
                $joined = $Argument -join ' '
                if ($joined -like 'pr list*') { $script:Captured = $joined; return @() }
                if ($joined -like '*dependabot/alerts?state=all*') { return $script:DependabotAlert }
                if ($joined -like '*code-scanning/alerts?state=all*') { return @() }
                return $null
            }
            Invoke-AuditForTest -NoRetry | Out-Null
            $captured = $script:Captured
            $captured | Should -BeLike '*--search*merged:>=*'
        }
    }

    Context 'the audit does not depend on state only the harness provides' {
        It 'uses no $script: state at all, in code' {
            # V10.2 shipped with `if (-not $script:HealCandidate) { $script:HealCandidate = ... }`
            # as a lazy cache. Under Set-StrictMode -Version Latest the READ throws before
            # the assignment can run, and production recorded
            # "check threw: The variable '$script:HealCandidate' cannot be retrieved".
            # The suite passed anyway, because BeforeEach set it to $null - the fixture
            # created the precondition production lacked, which CLAUDE.md names as a test
            # supplying its own answer rather than a test.
            #
            # THE FIRST VERSION OF THIS GUARD WAS FALSE COMFORT and is recorded because it
            # is the more instructive mistake: it asserted "every $script: variable read is
            # also assigned", and the lazy-cache pattern does BOTH, so it would have passed
            # over the very defect it was written for. Checked by hand against the original
            # line rather than assumed.
            #
            # This asserts the shape that actually holds: the audit is a script with no
            # script-scoped mutable state, so values are parameters or closures and the
            # ordering trap cannot recur. Comments are stripped first - this file documents
            # the defect it scans for.
            $source = Get-Content -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'layer-10-audit.ps1')
            $code = @($source | Where-Object { $_ -notmatch '^\s*#' })
            @($code | Where-Object { $_ -match '\$script:' }) -join ' | ' |
                Should -BeNullOrEmpty -Because 'script-scoped state in an audit is read before assignment sooner or later, and under Set-StrictMode -Version Latest that throws where a harness that pre-set it would show green'
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
