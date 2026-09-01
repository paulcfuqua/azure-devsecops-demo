# Every tracked package-lock.json agrees with the package.json beside it.
#
# WHY THIS EXISTS
#
# Four of this repository's five lockfiles belong to the root npm workspace and
# are kept honest for free: `npm ci` at the root refuses to run when the root
# lockfile and any workspace manifest disagree, and lint-ci runs `npm ci` on
# every pull request. Two do not. `apps/mcp-tools` and `apps/shared/spec-renderer`
# each carry a STANDALONE package-lock.json, and nothing at the root reads them.
#
# So a dependency bump applied to those two package.json files leaves their own
# lockfiles behind, silently, and `npm install` at the root reports success. The
# 2026-08-29 dependency sweep did exactly that: it moved vitest, @types/node and
# typescript in `apps/mcp-tools/package.json` while its lockfile stayed on
# vitest ^3.2.4 and @types/node ^24.13.3.
#
# One of the two was caught, and only by accident of packaging: mcp-tools' image
# does `COPY apps/mcp-tools/package.json apps/mcp-tools/package-lock.json ./`
# followed by `npm ci`, so the container build failed and -- because F39 had just
# made the image jobs required status checks -- blocked the merge. spec-renderer
# has no Dockerfile, so its nine drifted entries were caught by nothing at all
# and would have shipped.
#
# THE TRAP THAT CAUSED IT, recorded because it is not obvious: running
# `npm install --package-lock-only` inside `apps/mcp-tools` does NOT regenerate
# that directory's lockfile. npm walks up, finds the root manifest listing the
# directory in `workspaces`, and updates the ROOT lockfile instead, reporting
# success either way. `--no-workspaces` is what pins it to the local package.
#
# This test needs no npm and no network: it compares declared ranges to what the
# lockfile's own root entry records, which is the exact comparison `npm ci` makes
# before it refuses to install.

BeforeDiscovery {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path

    # git ls-files, so a lockfile that is present locally but not committed --
    # or one added later in a directory nobody thought to list here -- is
    # covered without this file needing to change.
    Push-Location $script:RepoRoot
    try {
        $tracked = @(& git ls-files '*package-lock.json')
    } finally {
        Pop-Location
    }

    $script:LockCases = foreach ($rel in $tracked) {
        $dir = Split-Path -Parent $rel
        if ([string]::IsNullOrEmpty($dir)) { $dir = '.' }
        @{
            Name     = $dir
            LockPath = Join-Path $script:RepoRoot $rel
            PkgPath  = Join-Path $script:RepoRoot (Join-Path $dir 'package.json')
        }
    }
}

Describe 'every tracked lockfile matches its package.json' {
    It 'found lockfiles to check' -TestCases @(@{ Count = @($script:LockCases).Count }) {
        # Guards the whole suite: a `git ls-files` that returned nothing would
        # otherwise make this file pass by checking zero lockfiles.
        $Count | Should -BeGreaterThan 0
    }

    Context '<Name>' -ForEach $script:LockCases {
        It 'has a package.json beside it' {
            Test-Path -LiteralPath $PkgPath | Should -BeTrue
        }

        It 'records the same dependency ranges the manifest declares' {
            # -AsHashtable is required, not stylistic: a lockfile's `packages`
            # map is keyed by path and the ROOT entry's key is the empty string,
            # which ConvertFrom-Json refuses to turn into a PSObject property.
            $pkg = Get-Content -LiteralPath $PkgPath -Raw | ConvertFrom-Json -AsHashtable
            $lock = Get-Content -LiteralPath $LockPath -Raw | ConvertFrom-Json -AsHashtable

            $lockRoot = $lock['packages']['']
            $lockRoot | Should -Not -BeNullOrEmpty -Because 'a lockfile must carry a root package entry'

            $declared = @{}
            $locked = @{}
            # A package with no devDependencies (or none at all - the workspace
            # root declares only `workspaces`) leaves the section null, and
            # indexing .Keys on null throws rather than yielding nothing.
            foreach ($section in 'dependencies', 'devDependencies') {
                if ($null -ne $pkg[$section]) {
                    foreach ($name in @($pkg[$section].Keys)) { $declared[$name] = $pkg[$section][$name] }
                }
                if ($null -ne $lockRoot[$section]) {
                    foreach ($name in @($lockRoot[$section].Keys)) { $locked[$name] = $lockRoot[$section][$name] }
                }
            }

            $drift = foreach ($name in $declared.Keys | Sort-Object) {
                if ($locked[$name] -ne $declared[$name]) {
                    $lockValue = if ($locked.ContainsKey($name)) { $locked[$name] } else { '<absent>' }
                    "$name (package.json=$($declared[$name]), lock=$lockValue)"
                }
            }

            @($drift) -join '; ' | Should -BeNullOrEmpty -Because (
                "$Name's lockfile is stale; regenerate it with " +
                "``npm install --package-lock-only --no-workspaces`` from that directory " +
                '(the --no-workspaces is required, or npm updates the ROOT lockfile instead)')
        }
    }
}

# A LOCKFILE INSIDE A ROOT WORKSPACE MEMBER CANNOT BE MAINTAINED, BY ANYONE.
#
# The check above says a lockfile must agree with its manifest. This one says
# which directories are allowed to have a lockfile at all, and it exists because
# the agreement above is not something the tooling can keep for these two.
#
# npm resolves a workspace member's install against the ROOT lockfile - that is
# what a workspace is - so `npm install` in the member updates the root lockfile
# and leaves the member's own file untouched. Dependabot does exactly the same
# thing, being npm. So a bump to a workspace member's package.json ships with a
# stale sibling lockfile every single time, and no amount of care prevents it:
#
#   PR #102 bumped @testing-library/react to ^16.3.3 in four package.json files
#   and regenerated exactly one lockfile - the root. spec-renderer's standalone
#   lockfile stayed on ^16.3.0, the check above failed, and lint-ci went red.
#   That was the nineteenth such failure.
#
# The fix for spec-renderer was deletion, not regeneration: nothing read it.
# There is no Dockerfile in that directory, no workflow installs from it, and
# the package is built through the root workspace like every other member. It
# could only ever drift and never be consulted - a file whose sole observable
# behaviour was turning dependency bumps red.
#
# apps/mcp-tools is the real exception and stays. Its Dockerfile does
#
#     COPY apps/mcp-tools/package.json apps/mcp-tools/package-lock.json ./
#     RUN npm ci
#
# installing in isolation with no repo root in the build context, so it needs a
# lockfile of its own. It pays for that with the drift the check above catches -
# loudly and in two places, since the image build fails too - and regenerating
# it needs the `--no-workspaces` documented at the top of this file.
#
# So the rule is not "no lockfiles in workspace members", it is "each one is
# declared here with the reason it must exist". A new undeclared one is almost
# certainly the accident this test was written about.
Describe 'no unowned lockfile inside a root workspace member' {
    BeforeAll {
        $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path

        # Directories that legitimately carry their own lockfile despite being
        # workspace members. Keep the reason with the entry - an allowlist whose
        # entries carry no justification becomes a place to silence this test.
        $script:Allowed = @{
            'apps/mcp-tools' = 'its Dockerfile installs in isolation (COPY package.json package-lock.json; npm ci) with no repo root in the build context'
        }
    }

    It 'every tracked lockfile is either outside the workspaces or explicitly allowed' {
        Push-Location $script:Root
        try {
            $tracked = @(& git ls-files '*package-lock.json')
            $rootPkg = Get-Content -LiteralPath (Join-Path $script:Root 'package.json') -Raw | ConvertFrom-Json -AsHashtable
            $patterns = @($rootPkg['workspaces'])
        } finally {
            Pop-Location
        }

        $patterns.Count | Should -BeGreaterThan 0 -Because 'the root manifest must declare workspaces, or this test checks nothing'

        $offenders = foreach ($rel in $tracked) {
            # .Replace, not -replace: the argument is a literal separator, not a
            # regex, and a lone backslash is not a valid pattern. git ls-files emits
            # forward slashes; Split-Path hands back backslashes on Windows.
            $dir = (Split-Path -Parent $rel).Replace([char]92, [char]47)
            if ([string]::IsNullOrEmpty($dir)) { continue }  # the root lockfile itself
            if ($script:Allowed.ContainsKey($dir)) { continue }

            # `apps/shared/*` must match apps/shared/spec-renderer, so the
            # workspace globs are compared as globs rather than as literals.
            $isMember = $false
            foreach ($pattern in $patterns) {
                if ($dir -like $pattern) { $isMember = $true; break }
            }
            if ($isMember) { $dir }
        }

        @($offenders) -join '; ' | Should -BeNullOrEmpty -Because (
            'a lockfile in a root workspace member is updated by nothing - npm and Dependabot both ' +
            'resolve the member against the ROOT lockfile - so it can only drift and turn every ' +
            'dependency bump red. Delete it if nothing reads it, or add it to $script:Allowed with ' +
            'the reason it must exist (as apps/mcp-tools does).')
    }
}
