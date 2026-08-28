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
# The subscription Activity Log IS wired automatically, in
# layer-06-platform.yml's deploy job, right after the LAW becomes a real
# deployed resource (it needs a workspace that doesn't exist yet at the point
# in infra-up.yml's layer graph the brief originally named).
#
# Entra ID SignInLogs/AuditLogs are deliberately NOT wired automatically
# anywhere. History, briefly: first deferred (unverifiable without a live
# tenant, in that session); then implemented in layer-06-platform.yml after a
# review round found the resource shape and required role are both publicly
# documented; then REMOVED from that workflow on a second review round, because
# the role required — Security Administrator — is materially more tenant
# privilege than mls-github-deployer should hold standing (Task 10 narrowed
# this exact SP's Graph permission specifically to shrink its blast radius,
# finding F8; adding Security Administrator now would re-inflate that). It is
# a documented G0 human step instead (docs/runbooks/g0-bootstrap.md § C, item
# 12) — the same treatment item 4 (Fabric's SP API toggle) already gets for a
# different one-time, tenant-level, no-pipeline-identity setting. The second
# Describe block below guards that: the exact command is in the runbook, and
# — regression guard — the automated call does NOT reappear in the workflow.
# =============================================================================

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath '..')).Path
    $script:MainBicepPath = Join-Path -Path $script:RepoRoot -ChildPath 'infra' -AdditionalChildPath 'bicep', 'platform', 'main.bicep'
    $script:MainBicep = Get-Content -LiteralPath $script:MainBicepPath -Raw
    $script:Layer06Path = Join-Path -Path $script:RepoRoot -ChildPath '.github' -AdditionalChildPath 'workflows', 'layer-06-platform.yml'
    $script:Layer06 = Get-Content -LiteralPath $script:Layer06Path -Raw
    $script:G0Path = Join-Path -Path $script:RepoRoot -ChildPath 'docs' -AdditionalChildPath 'runbooks', 'g0-bootstrap.md'
    $script:G0 = Get-Content -LiteralPath $script:G0Path -Raw
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
        $settingMatches = [regex]::Matches($script:MainBicep, 'diagnosticSettings:\s*\[[^\]]*\]')
        $settingMatches.Count | Should -BeGreaterOrEqual 4
        foreach ($m in $settingMatches) {
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

Describe 'subscription Activity Log is automated; Entra diagnostics are a documented G0 step (F9)' {
    It 'wires the subscription Activity Log to the LAW in layer-06-platform.yml' {
        $script:Layer06 | Should -Match 'az monitor diagnostic-settings subscription create'
        $script:Layer06 | Should -Match 'logAnalyticsWorkspaceResourceId'
    }

    It 'does NOT wire Entra diagnostics as an automated pipeline call' {
        # Regression guard in the other direction from most tests here: this
        # asserts an ABSENCE on purpose. mls-github-deployer must not hold
        # Security Administrator (see the header comment), so no workflow may
        # call `az monitor diagnostic-settings create --resource
        # "/providers/microsoft.aadiam"` — if this starts failing, someone
        # re-added the automated call this task deliberately removed.
        $script:Layer06 | Should -Not -Match 'providers/microsoft\.aadiam'
    }

    It 'documents the Entra diagnostic setting as a G0 human step with the exact command' {
        $script:G0 | Should -Match 'az monitor diagnostic-settings create'
        $script:G0 | Should -Match 'providers/microsoft\.aadiam'
        $script:G0 | Should -Match 'SignInLogs'
        $script:G0 | Should -Match 'AuditLogs'
        $script:G0 | Should -Match 'Security Administrator'
    }

    It 'states the G0 step runs after L6 and requires a role mls-github-deployer does not hold' {
        $script:G0 | Should -Match '(?i)after\s+(the\s+first\s+successful\s+)?L6'
        $script:G0 | Should -Match 'mls-github-deployer'
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
