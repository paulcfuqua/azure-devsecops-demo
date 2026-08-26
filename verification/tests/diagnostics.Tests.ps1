# =============================================================================
# F9 (compliance/findings/2026-08-26-prepublication-review.md#f9, Task 13): a
# grep for diagnosticSettings|auditingSettings|az monitor diagnostic across
# every Bicep, YAML and PowerShell file in the repo returned ZERO matches.
# Nothing routed Key Vault AuditEvent (the estate's only real credentials —
# the Direct Line secret, and mcp-auth-token since Task 5), SQL audit, storage
# blob data-plane logs, or Container Apps environment diagnostics anywhere.
# SQL auditing was also nominally "Enabled" (the AVM default) with neither
# storageAccountResourceId nor isAzureMonitorTargetEnabled set, i.e. auditing
# that writes nowhere.
#
# This guards the platform/main.bicep half of the fix: diagnosticSettings on
# Key Vault, the cost-export storage account, the SQL database (the AVM
# sql/server module has no top-level diagnosticSettings param — server is not
# a diagnostic-log-emitting resource type; Microsoft.Sql/servers/databases is,
# so the setting lives on the databases[] item, verified against the cached
# avm/res/sql/server@0.22.0 module schema) and the Container Apps environment,
# all routed to the L6 Log Analytics workspace, plus a real SQL audit
# destination (isAzureMonitorTargetEnabled) and retention raised 30 -> 90.
#
# The subscription Activity Log and Entra SignInLogs/AuditLogs are NOT in this
# file — both need a Log Analytics workspace that does not exist yet at the
# point in infra-up.yml's layer graph the brief named (L2/L3 precede L6 on a
# same-pass run), so both are wired in layer-06-platform.yml's deploy job
# instead, right after the LAW becomes a real deployed resource. The second
# Describe block below guards that half, added after a review round corrected
# an initial deferral of the Entra item (see task-13-report.md's fix-round
# section for why "needs a live tenant to verify" was not, in the end, true of
# the Entra resource shape or the role it needs — both are publicly
# documented).
# =============================================================================

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath '..')).Path
    $script:MainBicepPath = Join-Path -Path $script:RepoRoot -ChildPath 'infra' -AdditionalChildPath 'bicep', 'platform', 'main.bicep'
    $script:MainBicep = Get-Content -LiteralPath $script:MainBicepPath -Raw
    $script:Layer06Path = Join-Path -Path $script:RepoRoot -ChildPath '.github' -AdditionalChildPath 'workflows', 'layer-06-platform.yml'
    $script:Layer06 = Get-Content -LiteralPath $script:Layer06Path -Raw
}

Describe 'platform diagnostics route to Log Analytics (F9)' {
    It 'routes diagnostics for every resource that can emit them' {
        ($script:MainBicep | Select-String 'diagnosticSettings' -AllMatches).Matches.Count |
            Should -BeGreaterOrEqual 4 -Because 'Key Vault, storage, SQL (database) and the CAE all emit'
    }

    It 'sends SQL audit events somewhere' {
        $script:MainBicep | Should -Match 'isAzureMonitorTargetEnabled'
    }

    It 'every diagnosticSettings entry points at the Log Analytics workspace' {
        $matches = [regex]::Matches($script:MainBicep, 'diagnosticSettings:\s*\[[^\]]*\]')
        $matches.Count | Should -BeGreaterOrEqual 4
        foreach ($m in $matches) {
            $m.Value | Should -Match 'logAnalytics\.outputs\.resourceId'
        }
    }

    It 'enables SQL auditing with an actual destination, not the writes-nowhere AVM default' {
        $script:MainBicep | Should -Match 'auditSettings:\s*\{[^}]*state:\s*''Enabled''[^}]*isAzureMonitorTargetEnabled:\s*true'
    }

    It 'raises Log Analytics retention from 30 to the 90-day AU-11/DFARS convention' {
        $script:MainBicep | Should -Match "param\s+lawDataRetentionDays\s+int\s*=\s*90"
        $script:MainBicep | Should -Not -Match "param\s+lawDataRetentionDays\s+int\s*=\s*30"
    }
}

Describe 'subscription and tenant diagnostics route to Log Analytics from L6 (F9)' {
    It 'wires the subscription Activity Log to the LAW' {
        $script:Layer06 | Should -Match 'az monitor diagnostic-settings subscription create'
        $script:Layer06 | Should -Match 'logAnalyticsWorkspaceResourceId'
    }

    It 'wires Entra ID SignInLogs and AuditLogs to the LAW' {
        $script:Layer06 | Should -Match 'microsoft\.aadiam'
        $script:Layer06 | Should -Match 'SignInLogs'
        $script:Layer06 | Should -Match 'AuditLogs'
    }

    It 'does not overclaim the L2/L3-before-L6 ordering as a universal invariant' {
        # infra-up.yml supports a skip-tolerant selective replay (`layers: l6`
        # alone, skipping L2/L3 entirely), so the ordering guarantee only holds
        # when both run in the same pass. A review round caught this file
        # overclaiming it as "every invocation" / "a certainty" — guard against
        # that regressing.
        $script:Layer06 | Should -Not -Match 'a certainty'
        $script:Layer06 | Should -Not -Match 'every\s+(single\s+)?invocation'
    }
}
