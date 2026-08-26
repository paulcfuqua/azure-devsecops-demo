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
# NOT covered here: subscription Activity Log and Entra SignInLogs/AuditLogs.
# See task-13-report.md for why — both were found to need a Log Analytics
# workspace that does not exist yet at the point in infra-up.yml's layer graph
# the brief named (L2/L3 run strictly before L6 creates it).
# =============================================================================

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath '..')).Path
    $script:MainBicepPath = Join-Path -Path $script:RepoRoot -ChildPath 'infra' -AdditionalChildPath 'bicep', 'platform', 'main.bicep'
    $script:MainBicep = Get-Content -LiteralPath $script:MainBicepPath -Raw
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
