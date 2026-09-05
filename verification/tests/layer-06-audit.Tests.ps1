# Pester tests for verification/layer-06-audit.ps1 - every az call mocked; zero cloud calls.

BeforeAll {
    $env:MLS_SKIP_MAIN = '1'
    . (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'layer-06-audit.ps1')
    # No Set-StrictMode -Off: the audit scripts set -Version Latest and CI runs them
    # that way, so the harness must not relax the language mode it is testing (F49).

    $script:ReportRoot = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath "mls-l06-$([guid]::NewGuid().ToString('n'))"
    $script:Subscription = '22222222-2222-2222-2222-222222222222'
    $script:EnvironmentVariable = @('AZURE_SUBSCRIPTION_ID', 'MLS_SQL_DB_ID', 'MLS_ACA_ENV_ID', 'MLS_LAW_CUSTOMER_ID',
        'MLS_COST_EXPORT_ACCOUNT', 'MLS_L6_COMPLETED_AT')
    $script:SavedEnvironment = @{}
    foreach ($name in $script:EnvironmentVariable) { $script:SavedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name) }

    function Get-Row {
        param($Context, [string]$Id)
        return @($Context.Criterion | Where-Object { $_.Id -eq $Id })[0]
    }

    function Invoke-AuditForTest {
        param(
            [switch]$NoRetry,
            [string]$SubscriptionId = $script:Subscription,
            [string]$LayerCompletedUtc = '',
            [string]$SqlLastTouchedUtc = '',
            [double]$SqlPauseWaitMinutes = -1
        )
        Invoke-Main -SubscriptionId $SubscriptionId -DeploymentName 'layer-06' -LayerCompletedUtc $LayerCompletedUtc `
            -SqlLastTouchedUtc $SqlLastTouchedUtc -SqlPauseWaitMinutes $SqlPauseWaitMinutes `
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

Describe 'layer-06-audit' {
    BeforeEach {
        foreach ($name in $script:EnvironmentVariable) { [Environment]::SetEnvironmentVariable($name, $null) }
        Mock Write-MlsStatus {} -ModuleName 'MlsAudit'
        Mock Wait-MlsRetryInterval {} -ModuleName 'MlsAudit'

        $script:AutoPauseDelay = 60
        $script:MinCapacity = 0.5
        $script:SqlSku = 'GP_S_Gen5_1'
        $script:SqlStatus = 'Paused'
        $script:AcaState = 'Succeeded'
        $script:LawRows = @([pscustomobject]@{ TimeGenerated = '2026-08-24T09:00:00Z' })
        # V6.2's precondition probe: whether a Log Analytics token can be minted at the
        # moment of the query, and how many times the criterion asked.
        $script:LawTokenAvailable = $true
        $script:LawTokenProbes = 0
        $script:Blobs = @([pscustomobject]@{ name = '20260824/mls-cost-export.csv'; len = 20480 })
        $script:BackupRedundancy = 'Local'
        $script:BackupRetentionDays = 7
        # Two functions deployed, which is the healthy state. F119 was the
        # opposite - both apps empty because every publish 403'd - and L6
        # reported success anyway, which is why V6.7 exists.
        $script:FunctionsPayload = '{"value":[{"properties":{"name":"cost-ingest"}},{"properties":{"name":"directline-token"}}]}'
        # V6.8's subject. The healthy state: the reference resolves, so the secret
        # actually reaches the app. F122 was `MSINotEnabled` here while every other
        # view of the same setting - the app settings list, the role assignment, the
        # deploy, V6.1-V6.7 - looked correct.
        $script:ConfigReferencesPayload = '{"value":[{"name":"DIRECTLINE_SECRET","properties":{"status":"Resolved"}}]}'

        Mock Invoke-MlsAz {
            $joined = $Argument -join ' '
            if ($joined -like 'deployment sub show*') {
                return [pscustomobject]@{
                    sqlDatabaseId             = [pscustomobject]@{ value = '/subscriptions/s/resourceGroups/mls-rg-platform/providers/Microsoft.Sql/servers/mls-ops-demo-sql/databases/ops' }
                    containerAppEnvironmentId = [pscustomobject]@{ value = '/subscriptions/s/resourceGroups/mls-rg-platform/providers/Microsoft.App/managedEnvironments/mls-demo-cae' }
                    lawCustomerId             = [pscustomobject]@{ value = 'law-customer-guid' }
                    costExportAccountName     = [pscustomobject]@{ value = 'mlscostexportsa' }
                }
            }
            if ($joined -like 'sql db show*' -and $joined -like '*currentSku*') {
                return [pscustomobject]@{ sku = $script:SqlSku; autoPause = $script:AutoPauseDelay; minCap = $script:MinCapacity; status = $script:SqlStatus }
            }
            if ($joined -like 'sql db show*' -and $joined -like '*requestedBackupStorageRedundancy*') { return $script:BackupRedundancy }
            if ($joined -like 'sql db show*' -and $joined -like '*status*') { return $script:SqlStatus }
            if ($joined -like 'containerapp env show*') { return $script:AcaState }
            if ($joined -like 'monitor log-analytics query*') { return $script:LawRows }
            if ($joined -like 'account get-access-token*loganalytics*') {
                $script:LawTokenProbes++
                if (-not $script:LawTokenAvailable) { return $null }
                return [pscustomobject]@{ accessToken = 'law-token'; expiresOn = '2026-08-24T10:00:00Z' }
            }
            if ($joined -like 'storage blob list*') { return $script:Blobs }
            if ($joined -like 'resource show*backupShortTermRetentionPolicies/default*') {
                return [pscustomobject]@{ retentionDays = $script:BackupRetentionDays }
            }
            if ($joined -like '*Microsoft.Web/sites*functions*') {
                # V6.7's subject. A JSON STRING, not an object: the criterion asks
                # for -Raw so it can tell "the endpoint said nothing" (which reads
                # the same as a denial) from "the endpoint said []" - and a mock
                # returning a live object would hide exactly that distinction.
                return $script:FunctionsPayload
            }
            if ($joined -like '*configreferences*') { return $script:ConfigReferencesPayload }
            throw "unexpected az call: $joined"
        }
    }

    Context 'all criteria pass' {
        It 'records V6.1-V6.8 as PASS and exits 0' {
            $context = Invoke-AuditForTest
            @($context.Criterion).Id | Should -Be @('V6.1', 'V6.2', 'V6.3', 'V6.4', 'V6.5', 'V6.7', 'V6.8')
            @($context.Criterion | Where-Object { $_.Status -ne 'PASS' }) | Should -BeNullOrEmpty
            Get-MlsExitCode -Context $context | Should -Be 0
        }

        It 'resolves expected values from the layer-06 deployment outputs, not from a message' {
            $context = Invoke-AuditForTest
            @($context.Preflight | Where-Object { $_.Name -eq 'SQL database id' })[0].Value | Should -BeLike '*mls-ops-demo-sql*'
            Should -Invoke Invoke-MlsAz -Exactly -Times 1 -ParameterFilter { ($Argument -join ' ') -like 'deployment sub show*' }
        }

        It 'carries the plan-pinned SQL values into the expectation text' {
            $context = Invoke-AuditForTest
            (Get-Row -Context $context -Id 'V6.1').Expected | Should -BeLike '*autoPauseDelay == 60*'
            (Get-Row -Context $context -Id 'V6.1').Expected | Should -BeLike '*minCapacity == 0.5*'
        }
    }

    Context 'a criterion fails on a realistic wrong value' {
        It 'fails V6.1 when auto-pause was widened to 120 minutes (an un-gated spend increase)' {
            $script:AutoPauseDelay = 120
            $context = Invoke-AuditForTest -NoRetry
            $row = Get-Row -Context $context -Id 'V6.1'
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -BeLike '*autoPauseDelay=120, expected 60*'
            $row.Detail | Should -BeLike '*un-gated spend-profile change*'
            Get-MlsExitCode -Context $context | Should -Be 1
        }

        It 'fails V6.1 on a provisioned (non-serverless) SQL SKU' {
            $script:SqlSku = 'GP_Gen5_2'
            $context = Invoke-AuditForTest -NoRetry
            (Get-Row -Context $context -Id 'V6.1').Observed | Should -BeLike '*not serverless*'
        }

        It 'fails V6.4 when the database is still Online past the idle window' {
            $script:SqlStatus = 'Online'
            $context = Invoke-AuditForTest -NoRetry
            $row = Get-Row -Context $context -Id 'V6.4'
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -BeLike "*status = 'Online'*"
            $row.RetryWindowMinutes | Should -Be 75
        }
    }

    Context 'the async cost-export criterion' {
        It 'records V6.3 as PENDING while the declared 24 h window is still open' {
            $script:Blobs = @()
            $context = Invoke-AuditForTest -LayerCompletedUtc ([datetime]::UtcNow.AddHours(-2).ToString('o'))
            $row = Get-Row -Context $context -Id 'V6.3'
            $row.Status | Should -Be 'PENDING'
            $row.RetryWindowMinutes | Should -Be 1440
            $row.SleptSeconds | Should -Be 0
            Get-MlsExitCode -Context $context | Should -Be 0
        }

        It 'records V6.3 as FAIL once the 24 h window has elapsed' {
            $script:Blobs = @()
            $context = Invoke-AuditForTest -LayerCompletedUtc ([datetime]::UtcNow.AddHours(-30).ToString('o'))
            (Get-Row -Context $context -Id 'V6.3').Status | Should -Be 'FAIL'
        }
    }

    Context 'the async SQL auto-pause criterion' {
        # L06.md schedules V6.4 "75 minutes after the last deployment touch of the DB", and
        # kill-rebuild.md section 5 excludes it from the <60-minute rebuild clock. The layer
        # workflow therefore runs the audit inline with the seed timestamp and a zero wait
        # budget, and closes the criterion on a later re-check run.
        It 'records V6.4 as PENDING, without sleeping, while the 75-minute window is still open' {
            $script:SqlStatus = 'Online'
            $context = Invoke-AuditForTest -SqlLastTouchedUtc ([datetime]::UtcNow.AddMinutes(-3).ToString('o')) -SqlPauseWaitMinutes 0
            $row = Get-Row -Context $context -Id 'V6.4'
            $row.Status | Should -Be 'PENDING'
            $row.SleptSeconds | Should -Be 0
            $row.Attempt | Should -Be 1
            $row.Detail | Should -BeLike '*declared window has not elapsed*'
            Get-MlsExitCode -Context $context | Should -Be 0
            Should -Invoke Wait-MlsRetryInterval -ModuleName 'MlsAudit' -Exactly -Times 0
        }

        It 'records V6.4 as FAIL once the 75-minute window has elapsed, even with a last-touched time' {
            $script:SqlStatus = 'Online'
            $context = Invoke-AuditForTest -SqlLastTouchedUtc ([datetime]::UtcNow.AddHours(-3).ToString('o')) -SqlPauseWaitMinutes 0
            $row = Get-Row -Context $context -Id 'V6.4'
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -BeLike "*status = 'Online'*"
            Get-MlsExitCode -Context $context | Should -Be 1
        }

        It 'still PASSes V6.4 inside the window when the database is already Paused' {
            $context = Invoke-AuditForTest -SqlLastTouchedUtc ([datetime]::UtcNow.AddMinutes(-3).ToString('o')) -SqlPauseWaitMinutes 0
            (Get-Row -Context $context -Id 'V6.4').Status | Should -Be 'PASS'
        }

        It 'notes that a missing last-touched time is why an Online database FAILs rather than PENDs' {
            $script:SqlStatus = 'Online'
            $context = Invoke-AuditForTest -NoRetry
            (Get-Row -Context $context -Id 'V6.4').Status | Should -Be 'FAIL'
            ($context.Note -join ' ') | Should -BeLike '*V6.4: no last-touched timestamp supplied*'
        }
    }

    Context 'the SQL backup posture criterion (F16, Task 18 — CP-9)' {
        It 'fails V6.5 when requestedBackupStorageRedundancy drifts from the pinned tier' {
            $script:BackupRedundancy = 'Geo'
            $context = Invoke-AuditForTest -NoRetry
            $row = Get-Row -Context $context -Id 'V6.5'
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -BeLike "*requestedBackupStorageRedundancy='Geo'*"
            $row.Observed | Should -BeLike "*expected 'Local'*"
        }

        It 'fails V6.5 when the short-term retention window drifts from 7 days' {
            $script:BackupRetentionDays = 35
            $context = Invoke-AuditForTest -NoRetry
            $row = Get-Row -Context $context -Id 'V6.5'
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -BeLike '*retentionDays=35, expected 7*'
        }

        It 'fails V6.5 with an actionable message when the retention policy resource returns nothing' {
            Mock Invoke-MlsAz {
                $joined = $Argument -join ' '
                if ($joined -like 'deployment sub show*') {
                    return [pscustomobject]@{
                        sqlDatabaseId             = [pscustomobject]@{ value = 'db-id' }
                        containerAppEnvironmentId = [pscustomobject]@{ value = 'env-id' }
                        lawCustomerId             = [pscustomobject]@{ value = 'law' }
                        costExportAccountName     = [pscustomobject]@{ value = 'sa' }
                    }
                }
                if ($joined -like 'sql db show*' -and $joined -like '*currentSku*') {
                    return [pscustomobject]@{ sku = 'GP_S_Gen5_1'; autoPause = 60; minCap = 0.5; status = 'Paused' }
                }
                if ($joined -like 'sql db show*' -and $joined -like '*requestedBackupStorageRedundancy*') { return 'Local' }
                if ($joined -like 'sql db show*') { return 'Paused' }
                if ($joined -like 'containerapp env show*') { return 'Succeeded' }
                if ($joined -like 'monitor log-analytics query*') { return @([pscustomobject]@{ x = 1 }) }
                if ($joined -like 'storage blob list*') { return @([pscustomobject]@{ name = 'x.csv'; len = 10 }) }
                if ($joined -like 'resource show*backupShortTermRetentionPolicies/default*') { return $null }
                if ($joined -like '*Microsoft.Web/sites*functions*') {
                # V6.7's subject. A JSON STRING, not an object: the criterion asks
                # for -Raw so it can tell "the endpoint said nothing" (which reads
                # the same as a denial) from "the endpoint said []" - and a mock
                # returning a live object would hide exactly that distinction.
                return $script:FunctionsPayload
            }
            if ($joined -like '*configreferences*') { return $script:ConfigReferencesPayload }
            throw "unexpected az call: $joined"
            }
            $context = Invoke-AuditForTest -NoRetry
            $row = Get-Row -Context $context -Id 'V6.5'
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -BeLike '*returned nothing*'
        }

        It 'fails V6.5 with an actionable message when no SQL database resource id is available' {
            Mock Invoke-MlsAz {
                $joined = $Argument -join ' '
                if ($joined -like 'deployment sub show*') { return $null }
                if ($joined -like 'monitor log-analytics query*') { return @() }
                if ($joined -like 'storage blob list*') { return @() }
                if ($joined -like '*Microsoft.Web/sites*functions*') {
                # V6.7's subject. A JSON STRING, not an object: the criterion asks
                # for -Raw so it can tell "the endpoint said nothing" (which reads
                # the same as a denial) from "the endpoint said []" - and a mock
                # returning a live object would hide exactly that distinction.
                return $script:FunctionsPayload
            }
            if ($joined -like '*configreferences*') { return $script:ConfigReferencesPayload }
            throw "unexpected az call: $joined"
            }
            $context = Invoke-AuditForTest -NoRetry
            $row = Get-Row -Context $context -Id 'V6.5'
            $row.Status | Should -Be 'FAIL'
            $row.Detail | Should -BeLike '*MLS_SQL_DB_ID*'
        }
    }

    Context 'retry' {
        It 'retries V6.2 through workspace RBAC propagation without sleeping the whole window' {
            $script:Calls = 0
            Mock Invoke-MlsAz {
                $joined = $Argument -join ' '
                if ($joined -like 'deployment sub show*') {
                    return [pscustomobject]@{
                        sqlDatabaseId             = [pscustomobject]@{ value = 'db-id' }
                        containerAppEnvironmentId = [pscustomobject]@{ value = 'env-id' }
                        lawCustomerId             = [pscustomobject]@{ value = 'law-customer-guid' }
                        costExportAccountName     = [pscustomobject]@{ value = 'mlscostexportsa' }
                    }
                }
                if ($joined -like 'sql db show*' -and $joined -like '*currentSku*') {
                    return [pscustomobject]@{ sku = 'GP_S_Gen5_1'; autoPause = 60; minCap = 0.5; status = 'Paused' }
                }
                if ($joined -like 'sql db show*' -and $joined -like '*requestedBackupStorageRedundancy*') { return 'Local' }
                if ($joined -like 'sql db show*') { return 'Paused' }
                if ($joined -like 'containerapp env show*') { return 'Succeeded' }
                if ($joined -like 'monitor log-analytics query*') {
                    $script:Calls++
                    if ($script:Calls -lt 2) { return $null }
                    return @([pscustomobject]@{ TimeGenerated = '2026-08-24T09:00:00Z' })
                }
                if ($joined -like 'storage blob list*') { return @([pscustomobject]@{ name = 'x.csv'; len = 10 }) }
                if ($joined -like 'resource show*backupShortTermRetentionPolicies/default*') {
                    return [pscustomobject]@{ retentionDays = 7 }
                }
                if ($joined -like '*Microsoft.Web/sites*functions*') {
                # V6.7's subject. A JSON STRING, not an object: the criterion asks
                # for -Raw so it can tell "the endpoint said nothing" (which reads
                # the same as a denial) from "the endpoint said []" - and a mock
                # returning a live object would hide exactly that distinction.
                return $script:FunctionsPayload
            }
            if ($joined -like '*configreferences*') { return $script:ConfigReferencesPayload }
            throw "unexpected az call: $joined"
            }
            $context = Invoke-AuditForTest
            $row = Get-Row -Context $context -Id 'V6.2'
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
        It 'records V6.1 as FAIL and still evaluates the rest' {
            Mock Invoke-MlsAz {
                $joined = $Argument -join ' '
                if ($joined -like 'deployment sub show*') {
                    return [pscustomobject]@{
                        sqlDatabaseId             = [pscustomobject]@{ value = 'db-id' }
                        containerAppEnvironmentId = [pscustomobject]@{ value = 'env-id' }
                        lawCustomerId             = [pscustomobject]@{ value = 'law' }
                        costExportAccountName     = [pscustomobject]@{ value = 'sa' }
                    }
                }
                if ($joined -like 'sql db show*' -and $joined -like '*currentSku*') { throw 'az sql db show failed with exit code 3.' }
                if ($joined -like 'sql db show*' -and $joined -like '*requestedBackupStorageRedundancy*') { return 'Local' }
                if ($joined -like 'sql db show*') { return 'Paused' }
                if ($joined -like 'containerapp env show*') { return 'Succeeded' }
                if ($joined -like 'monitor log-analytics query*') { return @([pscustomobject]@{ x = 1 }) }
                if ($joined -like 'storage blob list*') { return @([pscustomobject]@{ name = 'x.csv'; len = 10 }) }
                if ($joined -like 'resource show*backupShortTermRetentionPolicies/default*') {
                    return [pscustomobject]@{ retentionDays = 7 }
                }
                if ($joined -like '*Microsoft.Web/sites*functions*') {
                # V6.7's subject. A JSON STRING, not an object: the criterion asks
                # for -Raw so it can tell "the endpoint said nothing" (which reads
                # the same as a denial) from "the endpoint said []" - and a mock
                # returning a live object would hide exactly that distinction.
                return $script:FunctionsPayload
            }
            if ($joined -like '*configreferences*') { return $script:ConfigReferencesPayload }
            throw "unexpected az call: $joined"
            }
            $context = Invoke-AuditForTest -NoRetry
            # Seven since V6.8 joined the layer. The number is asserted rather than
            # the ids because this test is about a THROWING check not aborting the
            # run - every criterion after V6.1 must still be evaluated.
            @($context.Criterion).Count | Should -Be 7
            (Get-Row -Context $context -Id 'V6.1').Status | Should -Be 'FAIL'
            (Get-Row -Context $context -Id 'V6.1').Observed | Should -BeLike '*exit code 3*'
            (Get-Row -Context $context -Id 'V6.2').Status | Should -Be 'PASS'
        }
    }

    Context 'missing input' {
        It 'refuses to run without a subscription id' {
            { Invoke-AuditForTest -SubscriptionId '' } | Should -Throw '*SubscriptionId*'
        }

        It 'fails V6.1 with an actionable message when the deployment outputs carry no resource ids' {
            Mock Invoke-MlsAz {
                $joined = $Argument -join ' '
                if ($joined -like 'deployment sub show*') { return $null }
                if ($joined -like 'monitor log-analytics query*') { return @() }
                if ($joined -like 'storage blob list*') { return @() }
                if ($joined -like '*Microsoft.Web/sites*functions*') {
                # V6.7's subject. A JSON STRING, not an object: the criterion asks
                # for -Raw so it can tell "the endpoint said nothing" (which reads
                # the same as a denial) from "the endpoint said []" - and a mock
                # returning a live object would hide exactly that distinction.
                return $script:FunctionsPayload
            }
            if ($joined -like '*configreferences*') { return $script:ConfigReferencesPayload }
            throw "unexpected az call: $joined"
            }
            $context = Invoke-AuditForTest -NoRetry
            $row = Get-Row -Context $context -Id 'V6.1'
            $row.Status | Should -Be 'FAIL'
            $row.Detail | Should -BeLike '*layer manifest artifact*'
            (Get-Row -Context $context -Id 'V6.2').Detail | Should -BeLike '*MLS_LAW_CUSTOMER_ID*'
        }
    }

    Context 'V6.2 says whether it could look, before saying what it saw (F182)' {
        # V6.2 failed twice on the rebuilt estate with:
        #   "the query returned no result (HTTP error, or the Reader identity cannot
        #    query this workspace)"
        # which offers two readings in one breath and commits to neither - the exact
        # F102/F103/F105 disease, in the component built to catch it. A reader cannot act
        # on it: one reading is a broken credential, the other a missing role assignment.
        #
        # The register's leading hypothesis was an expired federated assertion. That is
        # ruled out by the code: Invoke-MlsAz THROWS on AADSTS700024 even under
        # -AllowFailure, so an expired assertion arrives as "check threw", never as "no
        # result". Whatever this is, it is not that.
        #
        # So establish the precondition. If a Log Analytics token cannot be obtained AT
        # THE MOMENT OF THE QUERY, reachability is unobservable and the criterion must
        # not pretend to a verdict. If a token IS obtainable, the identity authenticates
        # fine and a failing query is a real finding about workspace RBAC.
        It 'reports UNOBSERVABLE when no Log Analytics token can be obtained' {
            $script:LawRows = $null
            $script:LawTokenAvailable = $false
            $row = Get-Row -Context (Invoke-AuditForTest -NoRetry) -Id 'V6.2'
            $row.Status | Should -Be 'SKIP'
            $row.Observed | Should -BeLike '*unobservable*'
            # Never the other reading: this must not read as "the role is missing".
            $row.Observed | Should -Not -BeLike '*cannot query this workspace*'
        }

        It 'FAILS when a token was obtainable and the query still returned nothing' {
            $script:LawRows = $null
            $script:LawTokenAvailable = $true
            $row = Get-Row -Context (Invoke-AuditForTest -NoRetry) -Id 'V6.2'
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -BeLike '*token*obtained*'
            $row.Detail | Should -BeLike '*RBAC*'
        }

        It 'does not probe for a token when the query succeeded' {
            # The probe is diagnosis, not part of the happy path: an extra token call on
            # every pass would spend the very assertion lifetime this is reasoning about.
            $script:LawRows = @([pscustomobject]@{ TimeGenerated = '2026-08-24T09:00:00Z' })
            (Get-Row -Context (Invoke-AuditForTest -NoRetry) -Id 'V6.2').Status | Should -Be 'PASS'
            $script:LawTokenProbes | Should -Be 0
        }
    }

    # -----------------------------------------------------------------------
    # V6.7 - F119. Every zip publish in this estate failed 403 against the
    # deployment storage firewall and L6 reported SUCCESS every time, because
    # both publish steps carry continue-on-error by design. That flag stays -
    # it exists so a non-critical publish cannot starve the verify job. This
    # criterion is what makes the failure visible instead, so these cases are
    # the reason it exists rather than decoration on it.
    # -----------------------------------------------------------------------
    Context 'V6.7: a Function App with no functions is a layer that did not deliver' {
        It 'FAILS when a Function App reports an empty function list' {
            $script:FunctionsPayload = '{"value":[]}'
            $context = Invoke-AuditForTest -NoRetry
            $row = Get-Row -Context $context -Id 'V6.7'
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -Match 'NO functions deployed'
            # It names the finding because the cause is two layers from the
            # symptom: a firewall on a storage account nobody was looking at.
            $row.Observed | Should -Match 'F119'
        }

        It 'reports UNOBSERVABLE, not "no functions", when the endpoint says nothing' {
            # THE DISTINCTION THIS CRITERION EXISTS TO PRESERVE. The ARM functions
            # endpoint answers a caller who may not read it and an app with
            # nothing deployed in ways that are easy to conflate. Reporting "no
            # functions" for a permissions problem is the absence-vs-denial class
            # that has cost this repository six findings: it must never say the
            # control is missing when it could not look.
            $script:FunctionsPayload = ''
            $context = Invoke-AuditForTest -NoRetry
            $row = Get-Row -Context $context -Id 'V6.7'
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -Match 'not reported as empty'
            $row.Observed | Should -Not -Match 'NO functions deployed'
        }

        It 'PASSES when the apps hold functions, so the guard is not a blanket fail' {
            $script:FunctionsPayload = '{"value":[{"properties":{"name":"cost-ingest"}}]}'
            $context = Invoke-AuditForTest -NoRetry
            (Get-Row -Context $context -Id 'V6.7').Status | Should -Be 'PASS'
        }
    }

    Context 'V6.8: a Key Vault reference that resolves to nothing (F122)' {
        It 'FAILS on the exact status the estate actually reported' {
            # Not a synthetic value. This is verbatim what
            # /config/configreferences/appsettings returned for the directline
            # Function while L6 signed off green: the site had only a user-assigned
            # identity, so the platform looked for a system-assigned one to resolve
            # the reference with, found none, and handed the app an empty string.
            $script:ConfigReferencesPayload = '{"value":[{"name":"DIRECTLINE_SECRET","properties":{"status":"MSINotEnabled","details":"Reference was not able to be resolved because site Managed Identity not enabled."}}]}'
            $context = Invoke-AuditForTest -NoRetry
            $row = Get-Row -Context $context -Id 'V6.8'
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -Match 'MSINotEnabled'
            # The remedy is one template property with a name nobody guesses, so the
            # criterion carries it rather than leaving a reader to search for it.
            $row.Detail | Should -Match 'keyVaultAccessIdentityResourceId'
        }

        It 'FAILS when the identity cannot read the secret, which is a different cause' {
            $script:ConfigReferencesPayload = '{"value":[{"name":"DIRECTLINE_SECRET","properties":{"status":"Forbidden","details":"Access denied to the key vault."}}]}'
            $context = Invoke-AuditForTest -NoRetry
            $row = Get-Row -Context $context -Id 'V6.8'
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -Match 'Forbidden'
        }

        It 'reports UNOBSERVABLE, not "no references", when the endpoint says nothing' {
            # Same distinction V6.7 keeps, for the same reason. An empty body from a
            # caller who may not read this endpoint must never be recorded as "this
            # site has no Key Vault references and is therefore fine".
            $script:ConfigReferencesPayload = ''
            $context = Invoke-AuditForTest -NoRetry
            $row = Get-Row -Context $context -Id 'V6.8'
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -Match 'may not look'
        }

        It 'PASSES when every reference resolves, so the guard is not a blanket fail' {
            $context = Invoke-AuditForTest -NoRetry
            (Get-Row -Context $context -Id 'V6.8').Status | Should -Be 'PASS'
        }
    }

}
