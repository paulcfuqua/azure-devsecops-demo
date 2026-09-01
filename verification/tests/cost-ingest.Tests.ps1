# =============================================================================
# F19 (compliance/findings/2026-08-26-prepublication-review.md#f19) — and with it
# F13's seventh and last workload RBAC grant.
#
# `apps/cost-ingest` was a complete, tested Azure Functions app that appeared in
# no Bicep anywhere: no Function App, no identity, and therefore no principal for
# `cost-ingest -> Storage Blob Data Reader` to be granted to. This file guards
# the shape of what was added, in three parts:
#
#   * the Bicep — the Function App exists, carries a user-assigned identity, runs
#     on a plan that costs nothing while idle, and stores no credential;
#   * the GRANT — by role definition GUID and by SCOPE, never by role name;
#   * the workflow wiring — the code publish and the Event Grid subscription that
#     make the trigger fire at all, and the fact that neither can cost L6 its
#     Verifier sign-off.
#
# ASSERT GUIDS AND VALUES, NEVER COMMENTS (F27). Every string this file matches
# against a Bicep template is matched against a COMMENT-STRIPPED copy, the same
# treatment verification/tests/workload-rbac.Tests.ps1 applies for the same
# reason: a reviewer proved that comment-matching kept that suite green when a
# grant was changed to Owner. The role name "Storage Blob Data Reader" appears in
# this template only inside comments; the executable Bicep carries
# 2a2b9908-6ea1-4ae2-8e65-a410df84e7d1, and that is what is asserted here.
#
# Nothing in this file contacts Azure. It reads the repository.
# =============================================================================

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath '..')).Path

    $script:PlatformBicepPath = Join-Path -Path $script:RepoRoot -ChildPath 'infra' -AdditionalChildPath 'bicep', 'platform', 'main.bicep'
    $script:ContainerRoleModulePath = Join-Path -Path $script:RepoRoot -ChildPath 'infra' -AdditionalChildPath 'bicep', 'platform', 'modules', 'blob-container-role.bicep'
    $script:AccountRoleModulePath = Join-Path -Path $script:RepoRoot -ChildPath 'infra' -AdditionalChildPath 'bicep', 'platform', 'modules', 'storage-account-role.bicep'
    $script:NamingBicepPath = Join-Path -Path $script:RepoRoot -ChildPath 'infra' -AdditionalChildPath 'bicep', 'naming.bicep'
    $script:TriggerPath = Join-Path -Path $script:RepoRoot -ChildPath 'apps' -AdditionalChildPath 'cost-ingest', 'src', 'functions', 'cost-ingest.ts'
    $script:Layer06Path = Join-Path -Path $script:RepoRoot -ChildPath '.github' -AdditionalChildPath 'workflows', 'layer-06-platform.yml'
    $script:Layer07Path = Join-Path -Path $script:RepoRoot -ChildPath '.github' -AdditionalChildPath 'workflows', 'layer-07-apps.yml'
    $script:InfraUpPath = Join-Path -Path $script:RepoRoot -ChildPath '.github' -AdditionalChildPath 'workflows', 'infra-up.yml'
    $script:ProvisionWorkspacePath = Join-Path -Path $script:RepoRoot -ChildPath 'infra' -AdditionalChildPath 'fabric', 'provision-workspace.ps1'

    $script:Layer06 = Get-Content -LiteralPath $script:Layer06Path -Raw
    $script:Layer07 = Get-Content -LiteralPath $script:Layer07Path -Raw
    $script:Trigger = Get-Content -LiteralPath $script:TriggerPath -Raw

    # Comment-stripped copies (F27). `//` inside a quoted string would also be
    # stripped, which is why nothing below asserts on a URL.
    $script:Stripped = @{}
    foreach ($entry in @(
            @{ Key = 'platform'; Path = $script:PlatformBicepPath },
            @{ Key = 'containerRole'; Path = $script:ContainerRoleModulePath },
            @{ Key = 'accountRole'; Path = $script:AccountRoleModulePath })) {
        $raw = Get-Content -LiteralPath $entry.Path -Raw
        $script:Stripped[$entry.Key] = (
            ($raw -split "`n") |
                Where-Object { $_ -notmatch '^\s*@description\(' } |
                ForEach-Object { $_ -replace '//.*$', '' }
        ) -join "`n"
    }

    # Azure-wide constants (learn.microsoft.com/azure/role-based-access-control/
    # built-in-roles/storage). A wrong GUID is a different role.
    $script:RoleGuid = [ordered]@{
        'Storage Blob Data Reader'       = '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1'
        'Storage Blob Data Owner'        = 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'
        'Storage Queue Data Contributor' = '974c5e8b-45b9-4653-ba55-5f855dd0fb88'
        'Storage Table Data Contributor' = '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3'
    }
    # Roles that would make the "least privilege" claim false while every
    # surrounding comment still read correctly. Storage Blob Data Contributor is
    # in this list on purpose: it is one character-class away from the Reader this
    # grant is supposed to be, and it would let the Function delete the export it
    # was only ever meant to read.
    $script:ForbiddenRoleGuid = [ordered]@{
        'Owner'                       = '8e3af657-a8ff-443c-a75c-2fe8c4bcb635'
        'Contributor'                 = 'b24988ac-6180-42a0-ab88-20f7382dd24c'
        'User Access Administrator'   = '18d7d88d-d35e-4fb5-a5c3-7773c20a72d9'
        'Storage Account Contributor' = '17d1049b-9a84-46fb-8f53-869881c3d3ab'
    }

    function Get-JobBody {
        param([string]$JobName, [string]$Source)
        if ($Source -notmatch "(?ms)^  $JobName`:\r?\n(.*?)(?=^  \w\S*:\r?\n|\z)") {
            throw "Could not isolate job '$JobName'."
        }
        return $Matches[1]
    }
    function Get-StepBody {
        param([string]$StepName, [string]$JobBody)
        $escaped = [regex]::Escape($StepName)
        if ($JobBody -notmatch "(?ms)^\s{6}- name: $escaped\r?\n(.*?)(?=^\s{6}- name:|\z)") {
            throw "Could not isolate step '$StepName'."
        }
        return $Matches[1]
    }
}

Describe 'F19: cost-ingest is provisioned as a real Function App' {
    It 'declares a Function App, its plan and its user-assigned identity in L6''s template' {
        $script:Stripped['platform'] | Should -Match "module costIngestFunctionApp 'br/public:avm/res/web/site:"
        $script:Stripped['platform'] | Should -Match "module costIngestPlan 'br/public:avm/res/web/serverfarm:"
        $script:Stripped['platform'] | Should -Match "module costIngestIdentity 'br/public:avm/res/managed-identity/user-assigned-identity:"
    }

    It 'pins an exact version on every AVM module it introduces, as the rest of the tree does' {
        foreach ($module in @('web/site', 'web/serverfarm', 'event-grid/system-topic')) {
            $pattern = "br/public:avm/res/$([regex]::Escape($module)):\d+\.\d+\.\d+'"
            $script:Stripped['platform'] | Should -Match $pattern -Because "avm/res/$module must be pinned to an exact version"
        }
    }

    It 'binds the Function App to the user-assigned identity, not a system-assigned one' {
        # userAssignedResourceIds carrying THIS identity is the assertion; a
        # systemAssigned:true would leave the container-scoped grant below
        # attached to a principal the app does not use.
        #
        # SCOPED TO THE FUNCTION APP MODULE, NOT THE WHOLE TEMPLATE. The second assertion
        # used to search the entire file, which made it a claim about every resource in
        # L6 rather than about cost-ingest. It broke the moment the SQL server was given
        # a system-assigned identity - which it NEEDS, because CREATE USER ... FROM
        # EXTERNAL PROVIDER resolves principals through the server's own identity (F112).
        # A correct change to one resource must not fail a test about another.
        $functionApp = [regex]::Match(
            $script:Stripped['platform'],
            "(?s)module costIngestFunctionApp\s+'br/public:avm/res/web/site:.*?
\}")
        $functionApp.Success | Should -BeTrue -Because 'the sweep must find the Function App module it claims to describe'
        $functionApp.Value | Should -Match 'userAssignedResourceIds:\s*\[costIngestIdentity\.outputs\.resourceId\]'
        $functionApp.Value | Should -Not -Match 'systemAssigned:\s*true'
    }

    It 'runs on Flex Consumption (FC1) — the plan that is $0 idle AND supports managed-identity host storage' {
        $script:Stripped['platform'] | Should -Match "skuName:\s*'FC1'"
    }

    It 'configures no always-ready instances, which is the only thing that would bill while idle' {
        $script:Stripped['platform'] | Should -Not -Match 'alwaysReady'
    }

    It 'authenticates host storage by managed identity, with no connection string and no key' {
        $script:Stripped['platform'] | Should -Match 'storageAccountUseIdentityAuthentication:\s*true'
        $script:Stripped['platform'] | Should -Match "AzureWebJobsStorage__credential:\s*'managedidentity'"
        $script:Stripped['platform'] | Should -Match 'AzureWebJobsStorage__clientId:\s*costIngestIdentity\.outputs\.clientId'
        # The bare setting name is the connection-string form. Its presence would
        # mean a key had been introduced.
        $script:Stripped['platform'] | Should -Not -Match '(?m)AzureWebJobsStorage:\s'
        $script:Stripped['platform'] | Should -Not -Match 'WEBSITE_AZUREFILESCONNECTIONSTRING'
    }

    It 'authenticates the blob trigger''s own connection by managed identity too' {
        $script:Stripped['platform'] | Should -Match "CostExports__credential:\s*'managedidentity'"
        $script:Stripped['platform'] | Should -Match 'CostExports__clientId:\s*costIngestIdentity\.outputs\.clientId'
    }

    It 'reads the deployment package with the app''s own identity, not a shared key or SAS' {
        $script:Stripped['platform'] | Should -Match "type:\s*'UserAssignedIdentity'"
        $script:Stripped['platform'] | Should -Match 'userAssignedIdentityResourceId:\s*costIngestIdentity\.outputs\.resourceId'
    }

    It 'keeps shared-key access off on both storage accounts the Function touches' {
        ([regex]::Matches($script:Stripped['platform'], 'allowSharedKeyAccess:\s*false').Count) |
            Should -BeGreaterOrEqual 2
        $script:Stripped['platform'] | Should -Not -Match 'allowSharedKeyAccess:\s*true'
    }

    It 'never enables FTP/FTPS publishing on the Function App' {
        $script:Stripped['platform'] | Should -Match "ftpsState:\s*'Disabled'"
        $script:Stripped['platform'] | Should -Not -Match "ftpsState:\s*'AllAllowed'"
    }

    It 'names everything through naming.bicep and hardcodes the company prefix nowhere' {
        $script:Stripped['platform'] | Should -Match 'naming\.functionAppName\(companyPrefix'
        $script:Stripped['platform'] | Should -Match 'naming\.appServicePlanName\(companyPrefix'
        $script:Stripped['platform'] | Should -Match 'naming\.userAssignedIdentityName\(companyPrefix, naming\.appKeys\.costIngest'
        $naming = Get-Content -LiteralPath $script:NamingBicepPath -Raw
        $naming | Should -Match "costIngest:\s*'cost-ingest'"
    }

    It 'publishes the Function App name and its resource group as deployment outputs the workflow can resolve' {
        $script:Stripped['platform'] | Should -Match '(?m)^output costIngestFunctionAppName string'
        $script:Stripped['platform'] | Should -Match '(?m)^output costIngestResourceGroupName string'
        $script:Stripped['platform'] | Should -Match '(?m)^output costExportSystemTopicName string'
    }
}

Describe 'F19 / F13 seventh grant: Storage Blob Data Reader, scoped to the container' {
    It 'grants the Storage Blob Data Reader GUID — in executable Bicep, not a comment' {
        $script:Stripped['platform'] | Should -Match ([regex]::Escape($script:RoleGuid['Storage Blob Data Reader']))
    }

    It 'makes that grant through the CONTAINER-scoped module, never the account-scoped one' {
        # The two modules exist precisely so the scope is legible from the call
        # site. Reading which module the export grant invokes is the assertion.
        if ($script:Stripped['platform'] -notmatch "(?ms)module costIngestExportReaderGrant\s+'([^']+)'\s*=\s*\{(.*?)\n\}") {
            throw 'Could not isolate the costIngestExportReaderGrant module invocation.'
        }
        $modulePath = $Matches[1]
        $invocation = $Matches[2]

        $modulePath | Should -Be 'modules/blob-container-role.bicep'
        $invocation | Should -Match ([regex]::Escape($script:RoleGuid['Storage Blob Data Reader']))
        $invocation | Should -Match 'containerName:\s*costExportContainerName'
        $invocation | Should -Match 'storageAccountName:\s*costExportStorage\.outputs\.name'
        $invocation | Should -Match 'principalId:\s*costIngestIdentity\.outputs\.principalId'
    }

    It 'scopes the container module''s role assignment to the container resource, not the account' {
        # The module is where the scope is actually expressed. `scope:` must
        # resolve through blobServices/containers, and the account resource must
        # not be the scope of any assignment in this file.
        $script:Stripped['containerRole'] | Should -Match 'scope:\s*storageAccount::blobService::container'
        $script:Stripped['containerRole'] | Should -Not -Match '(?m)^\s*scope:\s*storageAccount\s*$'
        $script:Stripped['containerRole'] | Should -Match "resource container 'containers' existing"
    }

    It 'passes the identity''s principalId, never its clientId' {
        # The Authorization API accepts any GUID; a clientId produces an
        # assignment that belongs to nothing and fails open-looking.
        $script:Stripped['platform'] | Should -Not -Match 'principalId:\s*costIngestIdentity\.outputs\.clientId'
    }

    It 'grants the Functions host''s account-wide roles ONLY on the runtime storage account' {
        if ($script:Stripped['platform'] -notmatch "(?ms)module costIngestRuntimeStorageGrant\s+'([^']+)'\s*=\s*\[(.*?)\n\]") {
            throw 'Could not isolate the costIngestRuntimeStorageGrant module invocation.'
        }
        $modulePath = $Matches[1]
        $invocation = $Matches[2]

        $modulePath | Should -Be 'modules/storage-account-role.bicep'
        # THE point of the second storage account: the account-wide grants name
        # functionRuntimeStorage and never costExportStorage.
        $invocation | Should -Match 'storageAccountName:\s*functionRuntimeStorage\.outputs\.name'
        $invocation | Should -Not -Match 'costExportStorage'
    }

    It 'grants exactly the three documented host roles on that account, and no others' {
        if ($script:Stripped['platform'] -notmatch '(?ms)var costIngestRuntimeStorageGrants = \[(.*?)\n\]') {
            throw 'Could not isolate the costIngestRuntimeStorageGrants table.'
        }
        $table = $Matches[1]
        $observed = @([regex]::Matches($table, "'([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})'") |
                ForEach-Object { $_.Groups[1].Value.ToLowerInvariant() } | Sort-Object -Unique)
        $expected = @(
            $script:RoleGuid['Storage Blob Data Owner'],
            $script:RoleGuid['Storage Queue Data Contributor'],
            $script:RoleGuid['Storage Table Data Contributor']
        ) | ForEach-Object { $_.ToLowerInvariant() } | Sort-Object -Unique

        $observed | Should -Be $expected
    }

    It 'grants no role outside the four this leg documents' {
        # Every role definition GUID literal in the L6 template and both grant
        # modules must be one of the four. A fifth is either an undocumented grant
        # or a privilege escalation.
        $guidPattern = "'([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})'"
        $observed = @()
        foreach ($key in @('platform', 'containerRole', 'accountRole')) {
            $observed += @([regex]::Matches($script:Stripped[$key], $guidPattern) |
                    ForEach-Object { $_.Groups[1].Value.ToLowerInvariant() })
        }
        $allowed = @($script:RoleGuid.Values | ForEach-Object { $_.ToLowerInvariant() })
        foreach ($guid in ($observed | Sort-Object -Unique)) {
            $guid | Should -BeIn $allowed -Because 'every role definition GUID at L6 must be one of the four documented storage roles'
        }
    }

    It 'never grants Owner, Contributor, User Access Administrator or Storage Blob Data Contributor' {
        foreach ($name in $script:ForbiddenRoleGuid.Keys) {
            foreach ($key in @('platform', 'containerRole', 'accountRole')) {
                $script:Stripped[$key] | Should -Not -Match ([regex]::Escape($script:ForbiddenRoleGuid[$name])) `
                    -Because "$name must never be granted to the cost-ingest identity"
            }
        }
    }
}

Describe 'F19: the trigger can actually fire' {
    It 'declares the Event Grid source the Flex Consumption plan requires' {
        # Flex Consumption supports only the event-based blob trigger. Without
        # this the app deploys, the subscription delivers, and nothing ever runs.
        $script:Trigger | Should -Match 'source:\s*"EventGrid"'
    }

    It 'falls back to the container that actually exists, hyphenated' {
        # `costexports` is a container nothing in this estate creates. The same
        # one-hyphen mismatch was already found once on the export side (F15).
        $script:Trigger | Should -Match 'COST_EXPORT_CONTAINER \|\| "cost-exports"'
        $script:Trigger | Should -Not -Match '\|\| "costexports"'
    }

    It 'declares an Event Grid system topic on the cost-export account in L6''s template' {
        $script:Stripped['platform'] | Should -Match "module costExportSystemTopic 'br/public:avm/res/event-grid/system-topic:"
        $script:Stripped['platform'] | Should -Match "topicType:\s*'Microsoft.Storage.StorageAccounts'"
        $script:Stripped['platform'] | Should -Match 'source:\s*costExportStorage\.outputs\.resourceId'
    }
}

Describe 'F19: the L6 workflow publishes the code and subscribes the trigger' {
    BeforeAll {
        $script:L6Deploy = Get-JobBody -JobName 'deploy' -Source $script:Layer06
        $script:L6Verify = Get-JobBody -JobName 'verify' -Source $script:Layer06
        $script:PublishStep = Get-StepBody -StepName 'Publish the cost-ingest Function package (F19)' -JobBody $script:L6Deploy
        $script:EventStep = Get-StepBody -StepName 'Subscribe the cost-ingest Function to blob-created events (F19)' -JobBody $script:L6Deploy
    }

    It 'lives in the deploy job (mls-github-deployer, which can write), not the Reader-only verify job' {
        $script:L6Deploy | Should -Match ([regex]::Escape('Publish the cost-ingest Function package (F19)'))
        $script:L6Verify | Should -Not -Match ([regex]::Escape('(F19)'))
    }

    It 'runs after the platform deployment that creates the Function App' {
        $deployIndex = $script:L6Deploy.IndexOf('- name: Deploy the platform')
        $publishIndex = $script:L6Deploy.IndexOf('Publish the cost-ingest Function package (F19)')
        $eventIndex = $script:L6Deploy.IndexOf('Subscribe the cost-ingest Function to blob-created events (F19)')
        $deployIndex | Should -BeGreaterThan -1
        $publishIndex | Should -BeGreaterThan $deployIndex
        $eventIndex | Should -BeGreaterThan $publishIndex
    }

    It 'runs after the V6.4 window start is recorded, so neither step can skip it' {
        # "Record when the database was last touched" carries always(), but the
        # ordering is asserted anyway: the V6.4 deadline must be stamped by the
        # deployment's own timeline, not after a ten-minute package publish.
        $seededIndex = $script:L6Deploy.IndexOf('- name: Record when the database was last touched')
        $publishIndex = $script:L6Deploy.IndexOf('Publish the cost-ingest Function package (F19)')
        $seededIndex | Should -BeGreaterThan -1
        $publishIndex | Should -BeGreaterThan $seededIndex
    }

    It 'carries continue-on-error on both steps, so a failed publish cannot starve the verify job' {
        # `verify` is needs: [preflight, deploy] and requires deploy to SUCCEED.
        # cost-ingest is not on the critical path; L6's sign-off must not hang on it.
        $script:PublishStep | Should -Match '(?m)^\s*continue-on-error:\s*true\s*$'
        $script:EventStep | Should -Match '(?m)^\s*continue-on-error:\s*true\s*$'
    }

    It 'is skipped on a dry run, like every other writing step in this job' {
        $script:PublishStep | Should -Match '(?m)^\s*if:\s*\$\{\{\s*!inputs\.dry_run\s*\}\}\s*$'
        $script:EventStep | Should -Match '(?m)^\s*if:\s*\$\{\{\s*!inputs\.dry_run\s*\}\}\s*$'
    }

    It 'resolves the Function App from the deployment manifest, not from a hardcoded name' {
        $script:PublishStep | Should -Match 'costIngestFunctionAppName'
        $script:PublishStep | Should -Match 'l6-manifest\.json'
        $script:EventStep | Should -Match 'costExportSystemTopicName'
    }

    It 'masks the blobs_extension system key before it is used, and never writes it anywhere' {
        # The key is why this subscription is not in Bicep at all. It must not
        # reach the log, an output, the job summary or an artifact.
        $script:EventStep | Should -Match '::add-mask::\$\{blob_key\}'
        $script:EventStep | Should -Not -Match 'GITHUB_OUTPUT'
        $script:EventStep | Should -Not -Match 'GITHUB_ENV'
        $script:EventStep | Should -Not -Match 'GITHUB_STEP_SUMMARY'
    }

    It 'filters the subscription to BlobCreated events under the cost-exports container only' {
        $script:EventStep | Should -Match '--included-event-types Microsoft\.Storage\.BlobCreated'
        $script:EventStep | Should -Match '--subject-begins-with "/blobServices/default/containers/\$\{container\}/"'
    }

    It 'is create-if-absent rather than a blind create, since an event subscription''s endpoint is immutable' {
        $script:EventStep | Should -Match 'az eventgrid system-topic event-subscription show'
    }

    It 'ships only production dependencies in the package' {
        $script:PublishStep | Should -Match 'npm install --omit=dev'
    }

    It 'surfaces a failed pass in the run summary, since continue-on-error keeps the job green' {
        $reportStep = Get-StepBody -StepName 'Report a failed cost-ingest pass (F19)' -JobBody $script:L6Deploy
        $reportStep | Should -Match "steps\.cost_ingest_publish\.outcome == 'failure'"
        $reportStep | Should -Match "steps\.cost_ingest_events\.outcome == 'failure'"
        $reportStep | Should -Match 'GITHUB_STEP_SUMMARY'
    }
}

Describe 'F19: the Fabric write grant is wired, not merely available' {
    BeforeAll {
        $script:L7Deploy = Get-JobBody -JobName 'deploy' -Source $script:Layer07
        $script:F19Step = Get-StepBody -StepName 'Grant cost-ingest the Fabric workspace Contributor role now that the identity exists (F19)' -JobBody $script:L7Deploy
    }

    It 'actually passes -CostIngestPrincipalId — the defect F24 recorded was a parameter with no caller' {
        $script:F19Step | Should -Match '-CostIngestPrincipalId\s+\$principalId'
        $provision = Get-Content -LiteralPath $script:ProvisionWorkspacePath -Raw
        $provision | Should -Match 'CostIngestPrincipalId'
    }

    It 'grants Contributor — the least Fabric role that can write — and never Admin or Member' {
        $provision = Get-Content -LiteralPath $script:ProvisionWorkspacePath -Raw
        # Asserted on the grant TABLE's role value, which is what is passed to the
        # API, not on the prose that explains it.
        $provision | Should -Match "Label = 'cost-ingest identity';\s*PrincipalId = \`$CostIngestPrincipalId;\s*Role = 'Contributor'"
        $provision | Should -Not -Match "Role = 'Admin'"
        $provision | Should -Not -Match "Role = 'Member'"
    }

    It 'leaves the two READ principals on Viewer' {
        $provision = Get-Content -LiteralPath $script:ProvisionWorkspacePath -Raw
        $provision | Should -Match "Label = 'data-api identity';\s*PrincipalId = \`$DataApiPrincipalId;\s*Role = 'Viewer'"
        $provision | Should -Match "Label = 'mls-verifier';\s*PrincipalId = \`$VerifierPrincipalId;\s*Role = 'Viewer'"
    }

    It 'resolves the identity''s principal (object) id from mls-rg-ops, where L6 creates it' {
        $script:F19Step | Should -Match '\$env:RG_OPS'
        $script:F19Step | Should -Match 'principalId:principalId'
        $script:F19Step | Should -Not -Match 'principalId:\s*clientId'
    }

    It 'refuses when more than one cost-ingest identity matches, rather than granting write to an arbitrary one' {
        $script:F19Step | Should -Match '(?m)::error.*Ambiguous cost-ingest identity'
    }

    It 'distinguishes an Azure CLI failure from "L6 has not deployed yet"' {
        $script:F19Step | Should -Match '\$LASTEXITCODE'
        $script:F19Step | Should -Match '(?m)::error.*Azure CLI call failed'
    }

    It 'runs after the V7.1 manifest is written AND uploaded, and carries continue-on-error' {
        $writeIndex = $script:L7Deploy.IndexOf('- name: Write the V7.1 deploy manifest for the Verifier')
        $uploadIndex = $script:L7Deploy.IndexOf('- name: Upload the V7.1 deploy manifest')
        $grantIndex = $script:L7Deploy.IndexOf('Grant cost-ingest the Fabric workspace Contributor role now that the identity exists (F19)')

        $writeIndex | Should -BeGreaterThan -1
        $uploadIndex | Should -BeGreaterThan $writeIndex
        $grantIndex | Should -BeGreaterThan $uploadIndex
        $script:F19Step | Should -Match '(?m)^\s*continue-on-error:\s*true\s*$'
    }

    It 'surfaces a failed grant in the run summary' {
        $reportStep = Get-StepBody -StepName 'Report a failed F19 grant pass' -JobBody $script:L7Deploy
        $reportStep | Should -Match "steps\.f19_grant\.outcome == 'failure'"
        $reportStep | Should -Match 'GITHUB_STEP_SUMMARY'
    }
}

Describe 'F19: infra-up.yml no longer claims a deploy that does not exist' {
    It 'still says the FinOps leg deploys inside layer-06-platform.yml — and that is now true' {
        $infraUp = Get-Content -LiteralPath $script:InfraUpPath -Raw
        $infraUp | Should -Match 'deploys inside\s*\r?\n?#?\s*layer-06-platform\.yml'
        # The claim is only true because these two steps exist. Assert the link
        # rather than the prose.
        $script:Layer06 | Should -Match ([regex]::Escape('Publish the cost-ingest Function package (F19)'))
        $script:Layer06 | Should -Match ([regex]::Escape('Subscribe the cost-ingest Function to blob-created events (F19)'))
    }
}
