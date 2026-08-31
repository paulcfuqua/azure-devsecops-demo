# Pester tests for infra/entra/apply-entra.ps1 - every Graph call mocked; zero cloud calls.

BeforeAll {
    $env:MLS_SKIP_MAIN = '1'
    $script:ManifestPath = Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'manifest.json'
    . (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'apply-entra.ps1')
    # No Set-StrictMode -Off: the script under test sets -Version Latest and CI runs it
    # that way, so the harness must not relax the language mode it is testing (F49).

    function Get-FreshManifest {
        # Get-Manifest, not raw ConvertFrom-Json: the manifest is tokenised (${prefix},
        # ${env}) and the script under test resolves those before it sees a single name.
        # A test that read the raw file would assert against '${prefix}-break-glass' while
        # the script created 'mls-break-glass' - a harness testing a different string than
        # the code produces, which is the mirror this suite exists to avoid (F90).
        return Get-Manifest -Path $script:ManifestPath
    }

    function Invoke-ApplyForTest {
        # -AsWhatIf, not -WhatIf: a parameter literally named WhatIf on a function that
        # never calls ShouldProcess trips PSUseSupportsShouldProcess, and lint-ci fails
        # on any warning. It is still forwarded to Invoke-Main as -WhatIf.
        param([switch]$AsWhatIf, [string]$Path = $script:ManifestPath)
        Invoke-Main -ManifestPath $Path -Domain 'mls.example' `
            -PropagationTimeoutSeconds 30 -PropagationIntervalSeconds 1 -WhatIf:$AsWhatIf
    }

    # Expected totals straight from the manifest, so tests fail loudly if it changes.
    $manifest = Get-FreshManifest
    $script:UserCount = @($manifest.users).Count
    $script:GroupCount = @($manifest.groups).Count
    $script:AppCount = @($manifest.appRegistrations).Count
    # Every registration gets a service principal; only the Easy Auth dashboards get the
    # Verifier's probe role. Derived from the manifest so adding either is felt here (F89).
    # Get-Field, not $_.verifierProbeRole: Set-StrictMode -Version Latest is ON in this
    # harness by design (F49), and a bare property access throws on the one registration
    # that does not declare the field.
    $script:ProbeRoleCount = @($manifest.appRegistrations |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string](Get-Field -Object $_ -Name 'verifierProbeRole')) }).Count
    $script:CaCount = @($manifest.conditionalAccessPolicies).Count
    $script:MembershipCount = (@($manifest.groups) | ForEach-Object { @($_.members).Count } | Measure-Object -Sum).Sum

    # The CA policies split by declared state: the two broad All-users/All-applications
    # policies stay report-only, the dashboard MFA policy is enforced. Derived, never
    # counted by hand, so adding a policy to the manifest is felt here.
    $script:ReportOnlyCaCount = @($manifest.conditionalAccessPolicies | Where-Object { $_.state -eq 'enabledForReportingButNotEnforced' }).Count
    $script:EnforcedPolicy = @($manifest.conditionalAccessPolicies | Where-Object { $_.state -eq 'enabled' })
    $script:EnforcedCaCount = $script:EnforcedPolicy.Count
    # Found by FLAG, exactly as apply-entra.ps1 finds it: naming the group here would
    # hard-code the company prefix and would let a rename disarm the guard silently.
    # Get-Field, not $_.breakGlass: only one of the five manifest groups carries the key,
    # and a bare property read on the other four is a terminating error under the
    # Set-StrictMode -Version Latest apply-entra.ps1 sets. This is how the script itself
    # finds them (apply-entra.ps1:228), which is the point of the flag-not-name rule (F49).
    $script:BreakGlassGroupName = @(@($manifest.groups |
                Where-Object { [bool](Get-Field -Object $_ -Name 'breakGlass') }).displayName)
}

AfterAll {
    Remove-Item Env:\MLS_SKIP_MAIN -ErrorAction SilentlyContinue
}

Describe 'apply-entra manifest schema validation' {
    It 'accepts the shipped manifest' {
        { Assert-ManifestSchema -Manifest (Get-FreshManifest) } | Should -Not -Throw
    }

    It 'names the exact user and field when a required user field is missing' {
        $manifest = Get-FreshManifest
        $manifest.users[0].PSObject.Properties.Remove('mailNickname')
        { Assert-ManifestSchema -Manifest $manifest } |
            Should -Throw "*missing required field 'mailNickname'*"
    }

    It 'reports a missing top-level key' {
        $manifest = Get-FreshManifest
        $manifest.PSObject.Properties.Remove('groups')
        { Assert-ManifestSchema -Manifest $manifest } |
            Should -Throw "*missing required key 'groups'*"
    }

    It 'rejects an invalid Conditional Access state' {
        $manifest = Get-FreshManifest
        $manifest.conditionalAccessPolicies[0].state = 'superEnabled'
        { Assert-ManifestSchema -Manifest $manifest } |
            Should -Throw "*invalid state 'superEnabled'*"
    }

    It 'rejects a group member that matches no user' {
        $manifest = Get-FreshManifest
        $manifest.groups[0].members += 'ghost.user'
        { Assert-ManifestSchema -Manifest $manifest } |
            Should -Throw "*'ghost.user' does not match any users*"
    }

    It 'rejects a CA policy without grantControls' {
        $manifest = Get-FreshManifest
        $manifest.conditionalAccessPolicies[1].PSObject.Properties.Remove('grantControls')
        { Assert-ManifestSchema -Manifest $manifest } |
            Should -Throw "*missing required field 'grantControls'*"
    }

    It 'rejects an enforced policy that excludes no break-glass group' {
        # The single most important rule in this file. Microsoft's own guidance is that
        # every enforced CA policy excludes an emergency-access account; without one, a
        # misconfiguration locks the tenant owner out of their own tenant.
        $manifest = Get-FreshManifest
        $policy = @($manifest.conditionalAccessPolicies | Where-Object { $_.state -eq 'enabled' })[0]
        $policy.conditions.users.PSObject.Properties.Remove('excludeGroupsByDisplayName')
        { Assert-ManifestSchema -Manifest $manifest } |
            Should -Throw "*excludes no break-glass group*"
    }

    It 'rejects an enforced policy whose exclusion names a group that is not flagged breakGlass' {
        $manifest = Get-FreshManifest
        $policy = @($manifest.conditionalAccessPolicies | Where-Object { $_.state -eq 'enabled' })[0]
        # A real group, correctly spelled, just not an emergency-access group.
        $policy.conditions.users.excludeGroupsByDisplayName = @($manifest.groups[0].displayName)
        { Assert-ManifestSchema -Manifest $manifest } |
            Should -Throw "*excludes no break-glass group*"
    }

    It 'rejects an enforced policy that targets every application' {
        $manifest = Get-FreshManifest
        $policy = @($manifest.conditionalAccessPolicies | Where-Object { $_.state -eq 'enabled' })[0]
        $policy.conditions.applications.includeApplicationsByDisplayName = @('All')
        { Assert-ManifestSchema -Manifest $manifest } |
            Should -Throw "*targets every application*"
    }

    It 'rejects an enforced policy that names no application at all' {
        $manifest = Get-FreshManifest
        $policy = @($manifest.conditionalAccessPolicies | Where-Object { $_.state -eq 'enabled' })[0]
        $policy.conditions.applications.includeApplicationsByDisplayName = @()
        { Assert-ManifestSchema -Manifest $manifest } |
            Should -Throw "*names no applications*"
    }

    It 'rejects an application reference that matches no app registration' {
        # A typo here would otherwise resolve to nothing and post a policy scoped WIDER
        # than authored, which is the failure this check exists for.
        $manifest = Get-FreshManifest
        $policy = @($manifest.conditionalAccessPolicies | Where-Object { $_.state -eq 'enabled' })[0]
        $policy.conditions.applications.includeApplicationsByDisplayName = @('no-such-app')
        { Assert-ManifestSchema -Manifest $manifest } |
            Should -Throw "*'no-such-app' does not match any appRegistrations*"
    }

    It 'rejects a group exclusion that matches no group' {
        $manifest = Get-FreshManifest
        $policy = @($manifest.conditionalAccessPolicies | Where-Object { $_.state -eq 'enabled' })[0]
        $policy.conditions.users.excludeGroupsByDisplayName = @('no-such-group')
        { Assert-ManifestSchema -Manifest $manifest } |
            Should -Throw "*'no-such-group' does not match any groups*"
    }

    It 'fails clearly when the manifest file does not exist' {
        { Get-Manifest -Path (Join-Path $TestDrive 'nope.json') } | Should -Throw '*not found*'
    }

    It 'fails clearly on malformed JSON' {
        $bad = Join-Path $TestDrive 'bad.json'
        Set-Content -LiteralPath $bad -Value '{ "users": [' -Encoding utf8
        { Get-Manifest -Path $bad } | Should -Throw '*not valid JSON*'
    }
}

Describe 'one run reports every failure, and still fails' {
    # L3 stopped at its first failing item on three consecutive runs, so each ~40-minute
    # attempt bought exactly one finding. A layer that halts on first error makes the
    # DISCOVERY rate equal to the deploy rate. Items are independent by construction, so
    # continuing past one costs nothing and shows everything (F72).
    #
    # The gate is unchanged, and that is the property these tests exist to hold: collected
    # failures are still failures, the run still throws, and L4-L8 still skip.

    BeforeEach {
        Mock Test-GraphConnection { [pscustomobject]@{ TenantId = 'mock-tenant' } }
        Mock Invoke-PropagationDelay {}
    }

    It 'continues past a failing group and reports all of them together' {
        Mock Invoke-GraphApi {
            $joined = "$Method $Path"
            if ($joined -like 'GET users*') { return @{ value = @() } }
            if ($joined -like 'POST users*') { return @{ id = "u-$([guid]::NewGuid())" } }
            if ($joined -like 'GET groups*') { return @{ value = @() } }
            if ($joined -like 'POST groups*') { throw 'Request_ResourceNotFound: simulated group failure' }
            return @{ value = @() }
        }
        Mock Wait-EntraPropagation { @{ id = 'x' } }

        $err = $null
        try { Invoke-ApplyForTest } catch { $err = $_ }

        $err | Should -Not -BeNullOrEmpty -Because 'a layer with failed items must still fail'
        # Every group, not just the first: the whole point.
        $err.Exception.Message | Should -Match "$($script:GroupCount) manifest item\(s\) failed"
    }

    It 'exits clean when nothing fails' {
        # The counterpart: fail-slow must not turn a healthy run into a reported failure.
        Mock Invoke-GraphApi {
            if ($Method -eq 'GET') { return @{ value = @() } }
            return @{ id = "x-$([guid]::NewGuid())" }
        }
        Mock Wait-EntraPropagation { @{ id = 'x' } }
        { Invoke-ApplyForTest } | Should -Not -Throw
    }
}

Describe 'L3 licenses the users its manifest declares licensed' {
    # g0-bootstrap item C10 asked a human to assign licences after L3 created the users, and
    # V3.4 asserted the result - so the audit checked a state nothing in the deploy path
    # produced. On an estate claiming agent-managed infrastructure, a manifest field nothing
    # acts on is a gap rather than a design (F79).

    BeforeEach { Mock Write-Status {} }

    It 'picks a SKU by capability, not by bundle name' {
        # The tenant runs Microsoft 365 E5, which provides everything EMS Premium does and
        # is named nothing like it (F73).
        Mock Invoke-GraphApi {
            @{ value = @(
                    @{ skuId = 'e5'; skuPartNumber = 'SPE_E5'
                        prepaidUnits = @{ enabled = 25 }; consumedUnits = 2
                        servicePlans = @(
                            @{ servicePlanName = 'AAD_PREMIUM'; provisioningStatus = 'Success' }
                            @{ servicePlanName = 'MFA_PREMIUM'; provisioningStatus = 'Success' }
                        ) }
                ) }
        }
        $sku = Get-CapableLicenseSku
        $sku.PartNumber | Should -Be 'SPE_E5'
        $sku.SeatsFree | Should -Be 23
    }

    It 'refuses a SKU with no free seat rather than failing mid-assignment' {
        Mock Invoke-GraphApi {
            @{ value = @(
                    @{ skuId = 'e5'; skuPartNumber = 'SPE_E5'
                        prepaidUnits = @{ enabled = 2 }; consumedUnits = 2
                        servicePlans = @(
                            @{ servicePlanName = 'AAD_PREMIUM'; provisioningStatus = 'Success' }
                            @{ servicePlanName = 'MFA_PREMIUM'; provisioningStatus = 'Success' }
                        ) }
                ) }
        }
        Get-CapableLicenseSku | Should -BeNullOrEmpty -Because 'buying seats is a spend decision, never an implicit one'
    }

    It 'ignores a SKU missing a required plan' {
        Mock Invoke-GraphApi {
            @{ value = @(
                    @{ skuId = 'b'; skuPartNumber = 'O365_BUSINESS'
                        prepaidUnits = @{ enabled = 50 }; consumedUnits = 0
                        servicePlans = @(@{ servicePlanName = 'EXCHANGE_S_STANDARD'; provisioningStatus = 'Success' }) }
                ) }
        }
        Get-CapableLicenseSku | Should -BeNullOrEmpty
    }

    It 'assigns a licence the user does not have' {
        Mock Invoke-GraphApi { @{ assignedLicenses = @() } }
        Mock Invoke-GraphMutation { @{} }
        Initialize-UserLicense -UserId 'u-1' -Upn 'dana@x' -Sku @{ SkuId = 'e5'; PartNumber = 'SPE_E5' } |
            Should -Be 'Assigned'
    }

    It 'is idempotent when the licence is already there' {
        Mock Invoke-GraphApi { @{ assignedLicenses = @(@{ skuId = 'e5' }) } }
        Mock Invoke-GraphMutation { throw 'must not re-assign a licence the user already holds' }
        Initialize-UserLicense -UserId 'u-1' -Upn 'dana@x' -Sku @{ SkuId = 'e5'; PartNumber = 'SPE_E5' } |
            Should -Be 'Unchanged'
    }
}

Describe 'break-glass readiness is capability, not membership' {
    # The check used to verify that SOME cloud-only non-persona account sat in the group and
    # call that ready. It passed on an account holding no directory role whatsoever - one
    # that satisfies every condition for being in the group and can recover nothing. The
    # enforced MFA policy would have deployed on a safety net nobody had tested (F77).

    BeforeEach {
        Mock Write-Status {}
        # Defined here, not in the Describe body: a variable set at discovery time is not in
        # scope when an It block actually runs.
        $script:ActiveGa = @{
            '@odata.type'  = '#microsoft.graph.directoryRole'
            roleTemplateId = '62e90394-69f5-4237-9190-012177145e10'
            displayName    = 'Global Administrator'
        }
    }

    It 'is ready when the account holds an ACTIVE Global Administrator role' {
        Mock Invoke-GraphApi -ParameterFilter { $Path -like 'groups/*/members*' } -MockWith { @{ value = @(@{ id = 'bg-1' }) } }
        Mock Invoke-GraphApi -ParameterFilter { $Path -like 'users/bg-1?*' } -MockWith { @{ id = 'bg-1'; userPrincipalName = 'bg@x.onmicrosoft.com'; onPremisesSyncEnabled = $false } }
        Mock Invoke-GraphApi -ParameterFilter { $Path -like '*transitiveMemberOf*' } -MockWith { @{ value = @($script:ActiveGa) } }

        $result = Test-BreakGlassReady -GroupName @('mls-break-glass') -GroupIdByDisplayName @{ 'mls-break-glass' = 'g-1' }
        $result.Ready | Should -BeTrue
        $result.Reason | Should -BeLike '*active Global Administrator*'
    }

    It 'is NOT ready when the account holds no role at all' {
        # Exactly the account this session created before the role was assigned.
        Mock Invoke-GraphApi -ParameterFilter { $Path -like 'groups/*/members*' } -MockWith { @{ value = @(@{ id = 'bg-1' }) } }
        Mock Invoke-GraphApi -ParameterFilter { $Path -like 'users/bg-1?*' } -MockWith { @{ id = 'bg-1'; userPrincipalName = 'bg@x.onmicrosoft.com'; onPremisesSyncEnabled = $false } }
        Mock Invoke-GraphApi -ParameterFilter { $Path -like '*transitiveMemberOf*' } -MockWith { @{ value = @() } }

        (Test-BreakGlassReady -GroupName @('mls-break-glass') -GroupIdByDisplayName @{ 'mls-break-glass' = 'g-1' }).Ready |
            Should -BeFalse -Because 'an account that cannot administer the tenant cannot recover it'
    }

    It 'is NOT ready on a PIM-eligible-only assignment, and says why' {
        # An eligible role does not appear in transitiveMemberOf: it is not held until it is
        # activated, and activation needs a sign-in, a healthy PIM service and usually MFA -
        # the controls an emergency account exists to bypass.
        Mock Invoke-GraphApi -ParameterFilter { $Path -like 'groups/*/members*' } -MockWith { @{ value = @(@{ id = 'bg-1' }) } }
        Mock Invoke-GraphApi -ParameterFilter { $Path -like 'users/bg-1?*' } -MockWith { @{ id = 'bg-1'; userPrincipalName = 'bg@x.onmicrosoft.com'; onPremisesSyncEnabled = $false } }
        Mock Invoke-GraphApi -ParameterFilter { $Path -like '*transitiveMemberOf*' } -MockWith { @{ value = @(@{ '@odata.type' = '#microsoft.graph.group'; displayName = 'mls-break-glass' }) } }

        (Test-BreakGlassReady -GroupName @('mls-break-glass') -GroupIdByDisplayName @{ 'mls-break-glass' = 'g-1' }).Ready | Should -BeFalse
        Should -Invoke Write-Status -ParameterFilter { $Message -like '*PIM-ELIGIBLE*' } -Times 1 -Scope It
    }

    It 'still rejects an on-premises synced account even with the role' {
        # An emergency path that depends on the sync source is not an emergency path.
        Mock Invoke-GraphApi -ParameterFilter { $Path -like 'groups/*/members*' } -MockWith { @{ value = @(@{ id = 'bg-1' }) } }
        Mock Invoke-GraphApi -ParameterFilter { $Path -like 'users/bg-1?*' } -MockWith { @{ id = 'bg-1'; userPrincipalName = 'bg@x'; onPremisesSyncEnabled = $true } }
        Mock Invoke-GraphApi -ParameterFilter { $Path -like '*transitiveMemberOf*' } -MockWith { @{ value = @($script:ActiveGa) } }

        (Test-BreakGlassReady -GroupName @('mls-break-glass') -GroupIdByDisplayName @{ 'mls-break-glass' = 'g-1' }).Ready | Should -BeFalse
    }
}

Describe 'Security Defaults and an enforced CA policy cannot coexist' {
    # Graph refuses an ENABLED Conditional Access policy while Security Defaults are on, and
    # accepts report-only ones - which is why two of this manifest's three applied cleanly
    # and the third came back 400. The way out is a posture decision, not a switch to flip
    # on the operator's behalf: this manifest enforces only the dashboard policy, so turning
    # Security Defaults off would take baseline MFA from every user and give back one
    # enforced policy (F75).

    BeforeEach {
        Mock Invoke-PropagationDelay {}
        Mock Write-Status {}
    }

    It 'refuses an enforced policy while Security Defaults are enabled' {
        Mock Invoke-GraphApi {
            if ($Path -like 'policies/identitySecurityDefaultsEnforcementPolicy*') { return @{ isEnabled = $true } }
            if ($Path -like '*conditionalAccess/policies*') { return @{ value = @() } }
            return @{ value = @() }
        }
        $outcome = Initialize-CaPolicy -Policy ([pscustomobject]@{ displayName = 'mls-ca-require-mfa-dashboards'; state = 'enabled' }) `
            -BreakGlassGroupName @('mls-break-glass') -GroupIdByDisplayName @{ 'mls-break-glass' = 'g-1' }
        $outcome | Should -Be 'Blocked' -Because 'the fail-safe direction is no policy, not a weakened tenant'
    }

    It 'allows a report-only policy while Security Defaults are enabled' {
        # These are accepted by Graph, and they are most of the manifest.
        Mock Invoke-GraphApi {
            if ($Path -like 'policies/identitySecurityDefaultsEnforcementPolicy*') { return @{ isEnabled = $true } }
            if ($Path -like '*conditionalAccess/policies*' -and $Method -eq 'GET') { return @{ value = @() } }
            return @{ id = 'ca-1' }
        }
        $outcome = Initialize-CaPolicy -Policy ([pscustomobject]@{ displayName = 'mls-ca-require-mfa-admins'; state = 'enabledForReportingButNotEnforced' }) `
            -BreakGlassGroupName @('mls-break-glass') -GroupIdByDisplayName @{ 'mls-break-glass' = 'g-1' }
        $outcome | Should -Not -Be 'Blocked'
    }

    It 'treats an unreadable Security Defaults policy as not enabled' {
        # The tenants that cannot read this are the ones missing Policy.Read.All. Refusing to
        # deploy on a permissions gap would be a worse failure than letting Graph answer.
        Mock Invoke-GraphApi {
            if ($Path -like 'policies/identitySecurityDefaultsEnforcementPolicy*') { return $null }
            if ($Path -like '*conditionalAccess/policies*' -and $Method -eq 'GET') { return @{ value = @() } }
            if ($Path -like 'groups/*/members*') { return @{ value = @(@{ id = 'bg-1' }) } }
            if ($Path -like 'users/*') { return @{ id = 'bg-1'; onPremisesSyncEnabled = $false } }
            return @{ id = 'ca-1' }
        }
        $outcome = Initialize-CaPolicy -Policy ([pscustomobject]@{ displayName = 'mls-ca-require-mfa-dashboards'; state = 'enabled' }) `
            -BreakGlassGroupName @('mls-break-glass') -GroupIdByDisplayName @{ 'mls-break-glass' = 'g-1' }
        $outcome | Should -Not -Be 'Blocked'
    }
}

Describe 'Graph calls survive directory replication' {
    # These mock Invoke-MgGraphRequest, NOT Invoke-GraphApi. The retry lives in
    # Invoke-GraphApi now, so a test that mocks it bypasses the very thing under test -
    # which is what the previous version of these tests did once the retry moved (F70).

    BeforeAll {
        function global:Invoke-MgGraphRequest {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
                Justification = 'Stub for the Graph SDK cmdlet; the Pester mock supplies the behaviour.')]
            param($Method, $Uri, $Body, $ContentType)
        }

        # The shape Invoke-MgGraphRequest actually throws: terse Message, JSON in ErrorDetails.
        # Deliberately carries NEITHER '404' NOR 'Not Found' in the exception message, so a
        # predicate reading only Exception.Message cannot pass this by accident (F69).
        function global:Get-GraphNotFoundRecord {
            $exception = [System.Net.Http.HttpRequestException]::new('The remote server returned an error.')
            $record = [System.Management.Automation.ErrorRecord]::new(
                $exception, 'GraphHttpError', [System.Management.Automation.ErrorCategory]::InvalidResult, $null)
            $record.ErrorDetails = [System.Management.Automation.ErrorDetails]::new(
                '{"error":{"code":"Request_ResourceNotFound","message":"Resource does not exist or one of its queried reference-property objects are not present."}}')
            return $record
        }
    }
    AfterAll {
        Remove-Item -LiteralPath 'function:global:Invoke-MgGraphRequest' -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath 'function:global:Get-GraphNotFoundRecord' -ErrorAction SilentlyContinue
    }

    BeforeEach {
        Mock Invoke-PropagationDelay {}
        $script:PropagationTimeoutSeconds = 60
        $script:PropagationIntervalSeconds = 1
    }

    It 'retries a GET that 404s on a freshly created object' {
        # The exact call that failed after the POST was fixed and the GET beside it was not.
        $script:Calls = 0
        Mock Invoke-MgGraphRequest {
            $script:Calls++
            if ($script:Calls -lt 3) { throw (Get-GraphNotFoundRecord) }
            return @{ value = @() }
        }
        $result = Invoke-GraphApi -Method GET -Path 'groups/g-1/members?$select=id'
        $result.value | Should -BeNullOrEmpty
        $script:Calls | Should -Be 3
        Should -Invoke Invoke-PropagationDelay -Exactly -Times 2
    }

    It 'retries a POST the same way' {
        $script:Calls = 0
        Mock Invoke-MgGraphRequest {
            $script:Calls++
            if ($script:Calls -lt 2) { throw (Get-GraphNotFoundRecord) }
            return @{}
        }
        $null = Invoke-GraphApi -Method POST -Path 'groups/g-1/members/$ref' -Body @{ 'x' = 1 }
        $script:Calls | Should -Be 2
    }

    It 'does NOT retry when the caller said -AllowNotFound' {
        # "Does this exist?" wants the answer no, immediately. Making a lookup wait out a
        # propagation budget would turn every create-if-absent into a three-minute stall.
        Mock Invoke-MgGraphRequest { throw (Get-GraphNotFoundRecord) }
        Invoke-GraphApi -Method GET -Path 'groups/g-1' -AllowNotFound | Should -BeNullOrEmpty
        Should -Invoke Invoke-PropagationDelay -Exactly -Times 0
    }

    It 'raises a non-404 immediately, without waiting' {
        Mock Invoke-MgGraphRequest { throw 'Authorization_RequestDenied: Insufficient privileges.' }
        { Invoke-GraphApi -Method POST -Path 'groups/g-1/members/$ref' -Body @{ 'x' = 1 } } |
            Should -Throw '*Authorization_RequestDenied*'
        Should -Invoke Invoke-PropagationDelay -Exactly -Times 0
    }

    It 'gives up with an error naming replication, not a missing object' {
        $script:PropagationTimeoutSeconds = 0
        Mock Invoke-MgGraphRequest { throw (Get-GraphNotFoundRecord) }
        { Invoke-GraphApi -Method GET -Path 'groups/g-1/members' } |
            Should -Throw '*directory replication rather than a missing object*'
    }
}

Describe 'group membership' {
    BeforeEach { Mock Invoke-PropagationDelay {} }

    It 'does not re-add a member the group already has' {
        Mock Invoke-GraphApi {
            if ($Method -eq 'GET') { return @{ value = @(@{ id = 'u-1' }) } }
            throw 'the POST must not be attempted for a member already present'
        }
        Initialize-GroupMembership -GroupId 'g-1' -GroupName 'mls-launch-ops' -MemberIds @('u-1') | Should -Be 0
    }

    It 'adds a member the group does not have' {
        Mock Invoke-GraphApi {
            if ($Method -eq 'GET') { return @{ value = @() } }
            return @{}
        }
        Initialize-GroupMembership -GroupId 'g-1' -GroupName 'mls-launch-ops' -MemberIds @('u-1') | Should -Be 1
    }
}

Describe 'apply-entra propagation polling' {
    BeforeEach {
        Mock Invoke-PropagationDelay {}
    }

    It 'polls (does not blind-sleep) until the object is visible' {
        $script:ProbeCalls = 0
        $probe = {
            $script:ProbeCalls++
            if ($script:ProbeCalls -ge 3) { return @{ id = 'x' } }
            return $null
        }
        $result = Wait-EntraPropagation -Probe $probe -TimeoutSeconds 60 -IntervalSeconds 1 -Description 'test object'
        $result.id | Should -Be 'x'
        $script:ProbeCalls | Should -Be 3
        Should -Invoke Invoke-PropagationDelay -Exactly -Times 2
    }

    It 'throws a clear timeout error when the object never appears' {
        { Wait-EntraPropagation -Probe { $null } -TimeoutSeconds 0 -IntervalSeconds 1 -Description 'ghost' } |
            Should -Throw '*Timed out*ghost*'
    }
}

Describe 'apply-entra idempotency + WhatIf' {
    BeforeEach {
        Mock Write-Status {}
        Mock Test-GraphConnection { [pscustomobject]@{ TenantId = 'mock-tenant' } }
        Mock Invoke-PropagationDelay {}

        # Present-scenario lookup tables, built from the manifest itself.
        $manifest = Get-FreshManifest
        $domain = 'mls.example'
        $script:ExistingUsers = @{}
        foreach ($user in $manifest.users) {
            $script:ExistingUsers["users/$($user.userPrincipalNamePrefix)@$domain"] = @{
                id          = "uid-$($user.userPrincipalNamePrefix)"
                displayName = $user.displayName
                jobTitle    = $user.jobTitle
                department  = $user.department
            }
        }
        $script:ExistingGroups = @{}
        $script:ExistingMembers = @{}
        foreach ($group in $manifest.groups) {
            $script:ExistingGroups[$group.displayName] = @{ id = "gid-$($group.displayName)"; displayName = $group.displayName }
            $script:ExistingMembers["gid-$($group.displayName)"] = @($group.members | ForEach-Object { @{ id = "uid-$_" } })
        }
        $script:ExistingApps = @{}
        $script:ExistingServicePrincipals = @{}
        $script:ExistingAppRoleAssignments = [System.Collections.Generic.List[object]]::new()
        foreach ($app in $manifest.appRegistrations) {
            # A POPULATED TENANT NOW INCLUDES THE PRINCIPAL AND THE ROLE. It did not, and
            # the replay test caught the change honestly: an application object without its
            # service principal is a half-created object, so "fully populated" had to grow
            # to mean both (F89). The role id is computed the same way the script computes
            # it, never pasted, so a change to that derivation fails here instead of
            # silently re-PATCHing every app on every replay.
            $roles = @()
            $probeRole = [string](Get-Field -Object $app -Name 'verifierProbeRole')
            if (-not [string]::IsNullOrWhiteSpace($probeRole)) {
                $roleId = Get-DeterministicGuid -Text "$($app.displayName)/$probeRole"
                $roles = @(@{
                        id                 = $roleId
                        value              = $probeRole
                        allowedMemberTypes = @('Application')
                        isEnabled          = $true
                    })
                $script:ExistingAppRoleAssignments.Add(@{
                        resourceId = "spid-$($app.displayName)"
                        appRoleId  = $roleId
                    })
            }
            $script:ExistingApps[$app.displayName] = @{
                id = "aid-$($app.displayName)"; appId = "client-$($app.displayName)"
                displayName = $app.displayName; signInAudience = $app.signInAudience
                appRoles = $roles
            }
            $script:ExistingServicePrincipals["client-$($app.displayName)"] = @{
                id = "spid-$($app.displayName)"; appId = "client-$($app.displayName)"
                displayName = $app.displayName
            }
        }
        $script:ExistingCaPolicies = @($manifest.conditionalAccessPolicies | ForEach-Object {
                @{ id = "cid-$($_.displayName)"; displayName = $_.displayName; state = $_.state }
            })

        # Break-glass membership is deliberately NOT in the manifest (the account is a real
        # human credential, never a fictional persona), so tests seed it here. Empty by
        # default, which is the true state of a first-ever apply.
        $script:BreakGlassMember = @()
        # Active Global Administrator, which is what makes an emergency account one. A test
        # models "no role" or "PIM-eligible only" by setting this to @().
        $script:BreakGlassRoles = @(@{
                '@odata.type'  = '#microsoft.graph.directoryRole'
                roleTemplateId = '62e90394-69f5-4237-9190-012177145e10'
                displayName    = 'Global Administrator'
            })
        $script:BreakGlassUser = @{}
        $script:PostOrder = [System.Collections.Generic.List[string]]::new()
        # The exact bodies that would reach Graph, asserted on directly: a ParameterFilter
        # cannot express set equality over a nested array legibly.
        $script:PostedPolicy = [System.Collections.Generic.List[object]]::new()

        # $script:TenantEmpty toggles between the two idempotency branches.
        $script:TenantEmpty = $true
        Mock Invoke-GraphApi {
            $cleanPath = $Path.Split('?')[0]
            if ($Method -eq 'GET') {
                if ($cleanPath -like 'users/*/transitiveMemberOf') {
                    # Membership is not capability: Test-BreakGlassReady now requires an
                    # ACTIVE Global Administrator role, because the check used to pass on an
                    # account holding none at all (F77). $BreakGlassRoles lets a test model
                    # the no-role and PIM-eligible-only cases, which both read as no active
                    # role here.
                    return @{ value = $script:BreakGlassRoles }
                }
                if ($cleanPath -like 'users/uid-*') {
                    return @{ id = ($cleanPath -split '/')[1] } # propagation probe
                }
                if ($cleanPath -like 'users/*') {
                    # Break-glass members are looked up for onPremisesSyncEnabled: a
                    # break-glass account must be cloud-only.
                    if ($script:BreakGlassUser.ContainsKey($cleanPath)) { return $script:BreakGlassUser[$cleanPath] }
                    if ($script:TenantEmpty) { return $null }
                    return $script:ExistingUsers[$cleanPath]
                }
                if ($cleanPath -like 'groups/*/members') {
                    $gid = ($cleanPath -split '/')[1]
                    # The break-glass group's members are seeded by the test whether or not
                    # the rest of the tenant exists: a human puts them there out of band.
                    if ($gid -in @($script:BreakGlassGroupName | ForEach-Object { "gid-$_" })) {
                        return @{ value = $script:BreakGlassMember }
                    }
                    if ($script:TenantEmpty) { return @{ value = @() } }
                    return @{ value = $script:ExistingMembers[$gid] }
                }
                if ($cleanPath -like 'groups/gid-*') {
                    return @{ id = ($cleanPath -split '/')[1] } # propagation probe
                }
                if ($cleanPath -eq 'groups') {
                    if ($script:TenantEmpty) { return @{ value = @() } }
                    if ($Path -match "eq '([^']+)'") { return @{ value = @($script:ExistingGroups[$Matches[1]]) } }
                    return @{ value = @() }
                }
                if ($cleanPath -eq 'applications') {
                    if ($script:TenantEmpty) { return @{ value = @() } }
                    if ($Path -match "eq '([^']+)'") { return @{ value = @($script:ExistingApps[$Matches[1]]) } }
                    return @{ value = @() }
                }
                if ($cleanPath -eq 'identity/conditionalAccess/policies') {
                    if ($script:TenantEmpty) { return @{ value = @() } }
                    return @{ value = $script:ExistingCaPolicies }
                }
                if ($cleanPath -like 'servicePrincipals/*/appRoleAssignments') {
                    if ($script:TenantEmpty) { return @{ value = @() } }
                    return @{ value = $script:ExistingAppRoleAssignments.ToArray() }
                }
                if ($cleanPath -eq 'servicePrincipals') {
                    # mls-verifier's principal is created OUT OF BAND by
                    # scripts/bootstrap/01-root-oidc.ps1, so it exists in both branches -
                    # the same treatment the break-glass members get above, and for the
                    # same reason: this script never creates it.
                    if ($Path -match "displayName eq '([^']+)'") {
                        if ($Matches[1] -eq 'mls-verifier') {
                            return @{ value = @(@{ id = 'spid-mls-verifier'; displayName = 'mls-verifier' }) }
                        }
                        return @{ value = @() }
                    }
                    if ($script:TenantEmpty) { return @{ value = @() } }
                    if ($Path -match "appId eq '([^']+)'") {
                        return @{ value = @($script:ExistingServicePrincipals[$Matches[1]]) }
                    }
                    return @{ value = @() }
                }
                return $null
            }
            if ($Method -eq 'POST') {
                $script:PostOrder.Add($cleanPath)
                if ($cleanPath -eq 'identity/conditionalAccess/policies') { $script:PostedPolicy.Add($Body) }
                if ($cleanPath -eq 'users') { return @{ id = "uid-$($Body['mailNickname'])" } }
                if ($cleanPath -eq 'groups') { return @{ id = "gid-$($Body['displayName'])" } }
                if ($cleanPath -like 'groups/*/members/*') { return @{} }
                # appId as well as id, because that is what Graph returns and what a CA
                # policy addresses an application by. Without it the dashboard MFA policy
                # could not be scoped to named applications at all.
                if ($cleanPath -eq 'applications') { return @{ id = "aid-$($Body['displayName'])"; appId = "client-$($Body['displayName'])" } }
                if ($cleanPath -eq 'identity/conditionalAccess/policies') { return @{ id = "cid-$($Body['displayName'])" } }
                # Same id shape as the populated fixture above (spid-<displayName>), so a
                # test cannot pass in one idempotency branch and fail in the other purely
                # because the mock invented two different naming schemes.
                if ($cleanPath -eq 'servicePrincipals') {
                    return @{ id = "spid-$($Body['appId'] -replace '^client-', '')"; appId = $Body['appId'] }
                }
                if ($cleanPath -like 'servicePrincipals/*/appRoleAssignments') { return @{ id = 'ara-1' } }
            }
            return @{}
        }
    }

    Context 'empty tenant - everything is created' {
        It 'creates every user, group, membership, app registration and every CA policy it is allowed to' {
            # CaCreated is the REPORT-ONLY count here, not the manifest count. On a
            # first-ever pass the break-glass group has just been created empty, so the
            # enforced dashboard MFA policy is refused rather than created: no emergency
            # account exists to fall back on yet. That is the guard working. The context
            # below covers the pass where the account exists and the policy lands.
            $summary = Invoke-ApplyForTest
            $summary.UsersCreated | Should -Be $script:UserCount
            $summary.GroupsCreated | Should -Be $script:GroupCount
            $summary.MembershipsAdded | Should -Be $script:MembershipCount
            $summary.AppsCreated | Should -Be $script:AppCount
            $summary.CaCreated | Should -Be $script:ReportOnlyCaCount
            $summary.CaBlocked | Should -Be $script:EnforcedCaCount
            Should -Invoke Invoke-GraphApi -Exactly -Times $script:UserCount -ParameterFilter { $Method -eq 'POST' -and $Path -eq 'users' }
            Should -Invoke Invoke-GraphApi -Exactly -Times $script:GroupCount -ParameterFilter { $Method -eq 'POST' -and $Path -eq 'groups' }
            Should -Invoke Invoke-GraphApi -Exactly -Times $script:MembershipCount -ParameterFilter { $Method -eq 'POST' -and $Path -like 'groups/*/members/*' }
            Should -Invoke Invoke-GraphApi -Exactly -Times $script:AppCount -ParameterFilter { $Method -eq 'POST' -and $Path -eq 'applications' }
            Should -Invoke Invoke-GraphApi -Exactly -Times $script:ReportOnlyCaCount -ParameterFilter { $Method -eq 'POST' -and $Path -eq 'identity/conditionalAccess/policies' }
        }

        It 'creates a service principal for EVERY app registration, not just the ones with a probe role' {
            # An application object is a definition; the service principal is the tenant
            # identity that app role assignments, permission grants, enterprise-app
            # visibility and sign-in logs all address. Registering applications without
            # them left four half-objects in a live tenant (F89), and nothing failed
            # visibly - interactive sign-in still works, because Entra creates the
            # principal on first consent. Only client-credentials issuance broke, which
            # is why it survived until V7.3 needed a token.
            $summary = Invoke-ApplyForTest
            $summary.ServicePrincipalsCreated | Should -Be $script:AppCount
            Should -Invoke Invoke-GraphApi -Exactly -Times $script:AppCount -ParameterFilter {
                $Method -eq 'POST' -and $Path -eq 'servicePrincipals'
            }
        }

        It 'assigns the probe role to the Verifier for the dashboards only' {
            $summary = Invoke-ApplyForTest
            $summary.ProbeRolesAssigned | Should -Be $script:ProbeRoleCount
            $script:ProbeRoleCount | Should -BeLessThan $script:AppCount `
                -Because 'the probe role belongs on the Easy Auth dashboards, not on every registration - mcp-tools authenticates with a shared bearer token and needs no audience'
            Should -Invoke Invoke-GraphApi -Exactly -Times $script:ProbeRoleCount -ParameterFilter {
                $Method -eq 'POST' -and $Path -like 'servicePrincipals/*/appRoleAssignments'
            }
        }

        It 'assigns the role on the Verifier principal, naming the dashboard as the resource' {
            Invoke-ApplyForTest | Out-Null
            # principalId is the VERIFIER (the grantee) and resourceId is the DASHBOARD
            # (the grantor). Swapping them is a silent no-op that grants nothing, so the
            # direction is asserted rather than assumed.
            Should -Invoke Invoke-GraphApi -Exactly -Times $script:ProbeRoleCount -ParameterFilter {
                $Method -eq 'POST' -and $Path -eq 'servicePrincipals/spid-mls-verifier/appRoleAssignments' -and
                $Body['principalId'] -eq 'spid-mls-verifier' -and
                $Body['resourceId'] -like 'spid-mls-*-demo-app'
            }
        }

        It 'declares the probe role for Application members only, so no user can hold it' {
            Invoke-ApplyForTest | Out-Null
            Should -Invoke Invoke-GraphApi -Exactly -Times $script:ProbeRoleCount -ParameterFilter {
                $Method -eq 'PATCH' -and $Path -like 'applications/*' -and
                $null -ne $Body['appRoles'] -and
                @($Body['appRoles'] | Where-Object {
                        $_['allowedMemberTypes'] -contains 'Application' -and
                        $_['allowedMemberTypes'] -notcontains 'User'
                    }).Count -ge 1
            }
        }

        It 'uses a stable role id, so a replay does not revoke the grant it just made' {
            # An assignment references its role BY id. A fresh GUID per run would make every
            # deploy dangle the previous run's assignment while reporting success.
            $first = Get-DeterministicGuid -Text 'mls-launch-ops-demo-app/Telemetry.Probe'
            $second = Get-DeterministicGuid -Text 'mls-launch-ops-demo-app/Telemetry.Probe'
            $first | Should -Be $second
            $first | Should -Not -Be (Get-DeterministicGuid -Text 'mls-control-tower-demo-app/Telemetry.Probe')
        }

        It 'creates the broad CA policies in report-only mode exactly as the manifest declares' {
            Invoke-ApplyForTest | Out-Null
            Should -Invoke Invoke-GraphApi -Exactly -Times $script:ReportOnlyCaCount -ParameterFilter {
                $Method -eq 'POST' -and $Path -eq 'identity/conditionalAccess/policies' -and
                $Body['state'] -eq 'enabledForReportingButNotEnforced'
            }
        }

        It 'never posts an enforced policy while the break-glass group is empty' {
            Invoke-ApplyForTest | Out-Null
            Should -Invoke Invoke-GraphApi -Exactly -Times 0 -ParameterFilter {
                $Method -eq 'POST' -and $Path -eq 'identity/conditionalAccess/policies' -and
                $Body['state'] -eq 'enabled'
            }
        }

        It 'polls for propagation after creating directory objects' {
            Invoke-ApplyForTest | Out-Null
            Should -Invoke Invoke-GraphApi -Exactly -Times $script:UserCount -ParameterFilter {
                $Method -eq 'GET' -and $Path -like 'users/uid-*'
            }
        }
    }

    Context 'an enforced CA policy lands only once a break-glass account exists' {
        BeforeEach {
            # A real emergency-access account: cloud-only, and not one of the fictional
            # demo personas. The human adds it out of band (g0-bootstrap.md item 13),
            # which is why the manifest declares the group with no members.
            $script:BreakGlassMember = @(@{ id = 'bg-emergency-access' })
        }

        It 'creates the enforced dashboard MFA policy once the account is there' {
            $summary = Invoke-ApplyForTest
            $summary.CaCreated | Should -Be $script:CaCount
            $summary.CaBlocked | Should -Be 0
            Should -Invoke Invoke-GraphApi -Exactly -Times $script:EnforcedCaCount -ParameterFilter {
                $Method -eq 'POST' -and $Path -eq 'identity/conditionalAccess/policies' -and
                $Body['state'] -eq 'enabled'
            }
        }

        It 'grants mfa, scoped to exactly the three dashboard apps and never to All, excluding break-glass' {
            # The whole point of the policy, asserted on the bytes that would go to Graph.
            $expectedAppId = @($script:EnforcedPolicy[0].conditions.applications.includeApplicationsByDisplayName |
                    ForEach-Object { "client-$_" })
            $expectedGroupId = @($script:BreakGlassGroupName | ForEach-Object { "gid-$_" })
            $expectedAppId.Count | Should -Be 3 -Because 'the estate has exactly three human-facing dashboards'

            Invoke-ApplyForTest | Out-Null
            $posted = @($script:PostedPolicy | Where-Object { $_.state -eq 'enabled' })
            $posted.Count | Should -Be 1
            $body = $posted[0]
            $body.grantControls.builtInControls | Should -Contain 'mfa'
            $body.conditions.users.includeUsers | Should -Contain 'All'
            $body.conditions.clientAppTypes | Should -Contain 'all'

            $includeApplication = @($body.conditions.applications.includeApplications)
            $includeApplication | Should -Not -Contain 'All' -Because 'an enforced grant scoped to every application is a tenant-wide lockout risk'
            Compare-Object $includeApplication $expectedAppId | Should -BeNullOrEmpty

            $excludeGroup = @($body.conditions.users.excludeGroups)
            Compare-Object $excludeGroup $expectedGroupId | Should -BeNullOrEmpty -Because 'the break-glass exclusion is the only recovery path from a wrong policy'
        }

        It 'sends Graph object ids, never the manifest display-name keys' {
            Invoke-ApplyForTest | Out-Null
            foreach ($body in $script:PostedPolicy) {
                $body.conditions.applications.ContainsKey('includeApplicationsByDisplayName') | Should -BeFalse
                $body.conditions.users.ContainsKey('excludeGroupsByDisplayName') | Should -BeFalse
            }
        }

        It 'creates the app registrations BEFORE the CA policy that names them' {
            # Ordering is what makes the display-name resolution possible at all: an
            # application has no client id to be scoped by until its registration exists.
            Invoke-ApplyForTest | Out-Null
            $lastApp = $script:PostOrder.LastIndexOf('applications')
            $firstPolicy = $script:PostOrder.IndexOf('identity/conditionalAccess/policies')
            $lastApp | Should -BeGreaterThan -1
            $firstPolicy | Should -BeGreaterThan $lastApp
        }

        It 'refuses when the only break-glass member is one of the fictional demo personas' {
            # A persona is not an emergency-access account: no human holds its credential,
            # and the manifest says out loud that they are all fictional.
            $script:BreakGlassMember = @(@{ id = "uid-$((Get-FreshManifest).users[0].userPrincipalNamePrefix)" })
            $summary = Invoke-ApplyForTest
            $summary.CaBlocked | Should -Be $script:EnforcedCaCount
            Should -Invoke Invoke-GraphApi -Exactly -Times 0 -ParameterFilter {
                $Method -eq 'POST' -and $Path -eq 'identity/conditionalAccess/policies' -and $Body['state'] -eq 'enabled'
            }
        }

        It 'refuses when the only break-glass member is synced from on-premises' {
            $script:BreakGlassMember = @(@{ id = 'bg-synced' })
            $script:BreakGlassUser['users/bg-synced'] = @{ id = 'bg-synced'; onPremisesSyncEnabled = $true }
            $summary = Invoke-ApplyForTest
            $summary.CaBlocked | Should -Be $script:EnforcedCaCount
        }

        It 'refuses to enable a drifted policy that someone turned off, when the account is gone' {
            $script:TenantEmpty = $false
            $script:BreakGlassMember = @()
            $enforcedName = $script:EnforcedPolicy[0].displayName
            @($script:ExistingCaPolicies | Where-Object { $_.displayName -eq $enforcedName })[0].state = 'disabled'
            $summary = Invoke-ApplyForTest
            $summary.CaBlocked | Should -Be 1
            $summary.CaUpdated | Should -Be 0
            Should -Invoke Invoke-GraphApi -Exactly -Times 0 -ParameterFilter { $Method -eq 'PATCH' }
        }

        It 'converges a drifted enforced policy back to enabled when the account is there' {
            $script:TenantEmpty = $false
            $enforcedName = $script:EnforcedPolicy[0].displayName
            @($script:ExistingCaPolicies | Where-Object { $_.displayName -eq $enforcedName })[0].state = 'disabled'
            $summary = Invoke-ApplyForTest
            $summary.CaUpdated | Should -Be 1
            $summary.CaBlocked | Should -Be 0
            Should -Invoke Invoke-GraphApi -Exactly -Times 1 -ParameterFilter {
                $Method -eq 'PATCH' -and $Path -like 'identity/conditionalAccess/policies/cid-*' -and
                $Body['state'] -eq 'enabled'
            }
        }
    }

    Context 'fully-populated tenant - replay no-ops' {
        BeforeEach { $script:TenantEmpty = $false }

        It 'issues zero mutating calls' {
            $summary = Invoke-ApplyForTest
            Should -Invoke Invoke-GraphApi -Exactly -Times 0 -ParameterFilter { $Method -in @('POST', 'PATCH', 'DELETE') }
            $summary.UsersUnchanged | Should -Be $script:UserCount
            $summary.GroupsUnchanged | Should -Be $script:GroupCount
            $summary.MembershipsAdded | Should -Be 0
            $summary.AppsUnchanged | Should -Be $script:AppCount
            $summary.CaUnchanged | Should -Be $script:CaCount
        }

        It 'PATCHes a drifted user in place instead of recreating it' {
            $firstKey = @($script:ExistingUsers.Keys)[0]
            $script:ExistingUsers[$firstKey].jobTitle = 'Former Title'
            $summary = Invoke-ApplyForTest
            $summary.UsersUpdated | Should -Be 1
            $summary.UsersCreated | Should -Be 0
            Should -Invoke Invoke-GraphApi -Exactly -Times 1 -ParameterFilter {
                $Method -eq 'PATCH' -and $Path -like 'users/uid-*' -and $Body['jobTitle']
            }
        }

        It 'PATCHes a drifted CA policy state back to report-only' {
            $script:ExistingCaPolicies[0].state = 'disabled'
            $summary = Invoke-ApplyForTest
            $summary.CaUpdated | Should -Be 1
            Should -Invoke Invoke-GraphApi -Exactly -Times 1 -ParameterFilter {
                $Method -eq 'PATCH' -and $Path -like 'identity/conditionalAccess/policies/cid-*' -and
                $Body['state'] -eq 'enabledForReportingButNotEnforced'
            }
        }

        It 'adds only the missing member when one membership is absent' {
            $gid = "gid-$((Get-FreshManifest).groups[0].displayName)"
            $script:ExistingMembers[$gid] = @($script:ExistingMembers[$gid] | Select-Object -Skip 1)
            $summary = Invoke-ApplyForTest
            $summary.MembershipsAdded | Should -Be 1
            Should -Invoke Invoke-GraphApi -Exactly -Times 1 -ParameterFilter {
                $Method -eq 'POST' -and $Path -like 'groups/*/members/*'
            }
        }
    }

    Context '-WhatIf makes no mutating calls' {
        It 'on an empty tenant performs reads only and reports the skips' {
            $summary = Invoke-ApplyForTest -AsWhatIf
            Should -Invoke Invoke-GraphApi -Exactly -Times 0 -ParameterFilter { $Method -in @('POST', 'PATCH', 'DELETE') }
            $summary.SkippedInWhatIf | Should -Be ($script:UserCount + $script:GroupCount + $script:AppCount + $script:CaCount)
        }

        It 'on a populated tenant with drift still performs reads only' {
            $script:TenantEmpty = $false
            $script:ExistingCaPolicies[0].state = 'disabled'
            Invoke-ApplyForTest -AsWhatIf | Out-Null
            Should -Invoke Invoke-GraphApi -Exactly -Times 0 -ParameterFilter { $Method -in @('POST', 'PATCH', 'DELETE') }
        }
    }

    Context 'validation failures stop everything before any Graph call' {
        It 'invalid manifest -> clear error, zero Graph traffic' {
            $badPath = Join-Path $TestDrive 'broken-manifest.json'
            $manifest = Get-FreshManifest
            $manifest.users[0].PSObject.Properties.Remove('userPrincipalNamePrefix')
            $manifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $badPath -Encoding utf8
            { Invoke-ApplyForTest -Path $badPath } | Should -Throw '*Manifest validation failed*'
            Should -Invoke Invoke-GraphApi -Exactly -Times 0
        }
    }
}
