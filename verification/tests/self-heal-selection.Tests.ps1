# =============================================================================
# Regression guard for F14 (compliance/findings/2026-08-26-prepublication-review.md#f14,
# Task 16): the self-heal selection step must never again decide "already
# handled" by asking `gh pr list` for open-PR branch names, and the
# code-scanning alert listing must never again go unscoped to a ref.
#
# Why this shape matters: `gh pr list --json headRefName` enumerates ALL open
# PRs including forks, and the attacker controls their own head-branch name —
# squatting `self-heal/<kind>-<n>-*` names on throwaway fork PRs made every
# alert look already-healed and the run report "Nothing to heal" green, a
# silent kill switch for the self-healing showpiece (L10). The fix roots the
# branch check at `git/matching-refs`, which is scoped to the base repository
# itself: a fork's branch lives in the fork's own ref namespace and can never
# appear there, so forks are sidestepped rather than filtered for. Separately,
# the code-scanning alert listing gained a `ref=` filter so alerts raised on a
# fork PR's own CodeQL analysis (codeql.yml runs on pull_request) are out of
# scope for healing from the start.
#
# This is a workflow-shape assertion, not an execution test — self-heal.yml's
# logic has no unit-test harness (it runs as GitHub Actions bash), so this is
# the available mechanism per CLAUDE.md's shell-change testing note. Pattern
# match against raw file content only, same approach as
# no-secret-outputs.Tests.ps1; a test that would pass against the pre-fix
# shape as readily as the post-fix one is worse than no test, so each
# assertion here is chosen to FAIL against the original self-heal.yml.
# =============================================================================

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath '..')).Path
    $script:WorkflowPath = Join-Path -Path $script:RepoRoot -ChildPath '.github/workflows/self-heal.yml'
}

Describe 'self-heal alert selection is not spoofable by a fork PR (F14)' {
    It 'the workflow file exists' {
        Test-Path $script:WorkflowPath | Should -BeTrue
    }

    It 'never asks gh pr list for open-PR branch names to decide "already healed"' {
        # This is the exact vulnerable invocation F14 reported: it enumerates
        # every open PR (forks included) and trusts the attacker-controlled
        # head-branch name. The dependency job's own `gh pr list --author
        # app/dependabot ...` call is a different, non-forgeable filter
        # (GitHub verifies that author identity server-side) and is not
        # matched by this pattern.
        $hits = Select-String -Path $script:WorkflowPath -Pattern "gh pr list --state open --json headRefName"
        $hits | Should -BeNullOrEmpty
    }

    It 'roots the open-self-heal-branch check at this repository''s own git refs' {
        # git/matching-refs is scoped to ${REPO} (the base repo) -- a fork's
        # branch lives in the fork's own ref namespace and can never appear
        # in this listing, which is why the fix sidesteps the fork question
        # instead of trying to filter PRs for it.
        $hits = Select-String -Path $script:WorkflowPath -Pattern 'git/matching-refs/heads/self-heal/'
        $hits | Should -Not -BeNullOrEmpty
    }

    It 'scopes the code-scanning alert listing to a ref (not just "open")' {
        # Without a ref= filter, an alert whose most recent instance is a
        # fork PR's own CodeQL analysis (codeql.yml runs on pull_request) is
        # "open" and in scope for healing -- the second half of F14.
        $hits = Select-String -Path $script:WorkflowPath -Pattern 'code-scanning/alerts\?state=open&ref='
        $hits | Should -Not -BeNullOrEmpty
    }

    It 'asserts most_recent_instance.ref before the alert can drive Autofix' {
        # Defense in depth, independent of the listing's own ref= filter:
        # once in the select job (so a filtered listing is trusted a second
        # time, not just once) and again in the autofix job (so an alert
        # number arriving via workflow_dispatch/repository_dispatch -- which
        # bypasses the select job's listing and its ref filter entirely --
        # is still checked before any autofix call is made).
        $hits = Select-String -Path $script:WorkflowPath -Pattern 'most_recent_instance\.ref'
        $hits.Count | Should -BeGreaterOrEqual 2
    }
}
