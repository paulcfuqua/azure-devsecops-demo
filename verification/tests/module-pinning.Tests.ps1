# No CI job installs a PowerShell module whose version is chosen by the gallery on the
# morning of the run.
#
# WHY THIS EXISTS
#
# Three jobs installed ExchangeOnlineManagement, and all three did it identically and
# completely unpinned:
#
#     Install-Module ExchangeOnlineManagement -Force -Scope CurrentUser -AllowClobber
#
# That is a dependency of the VERIFIER - the component whose independence is the product -
# resolving to whatever PSGallery served that morning. There is no lockfile for PowerShell
# modules, so `-RequiredVersion` IS the lockfile, and without one the same commit can be
# rebuilt twice and legitimately produce two different verdicts, with nothing in git to
# explain the second. lockfile-sync.Tests.ps1 makes this argument for npm; the npm half at
# least fails loudly when it drifts, because `npm ci` refuses to install. A PowerShell
# module resolves silently and succeeds.
#
# For this module the risk is not hypothetical. F172 was `Connect-IPPSSession
# -CertificateThumbprint` being a WINDOWS-ONLY DYNAMIC parameter - the module adds it only
# inside `if ($IsWindows)` - so on ubuntu-latest the L4 audit died at parameter binding
# having never opened a connection, and exited 2 for the life of the project. A module
# whose PARAMETER SET differs by platform is a module whose parameter set can also differ
# by version, between two runs of one commit, with no diff to point at.
#
# The fix was .github/actions/install-exo: one pinned version, installed once, with the
# LOADED version asserted afterwards rather than inferred from the exit code (F119's class -
# a step whose effect nobody asserts is a step nobody is watching). A single action helps
# nobody if the next job writes its own install step, so this file pins the class instead
# of today's instance.
#
# SCOPE RULE, stated up front because the false positives are the majority of the matches.
#
#   IN SCOPE: `.github/workflows/*.yml` and `.github/actions/**/action.yml` - the only
#   files that describe what CI actually executes - and within them only lines whose FIRST
#   non-whitespace token is `Install-Module`. That token test is the entire discriminator,
#   and it is enough:
#
#     * a YAML or PowerShell comment starts with `#`. compliance.yml, lint-ci.yml and the
#       install-exo action all discuss Install-Module in prose, at length.
#     * a human-facing hint starts with `throw` or `Write-Host`.
#
#   A statement is then read across its backtick continuations before its parameters are
#   judged, because the install-exo action splits exactly that way and reading one line
#   would score a correctly pinned install as unpinned.
#
#   OUT OF SCOPE: every `.ps1` and `.psm1` in the repository. `infra/purview/labels.ps1`,
#   `infra/entra/apply-entra.ps1`, `verification/MlsAudit.psm1` and
#   `data/seed/sql/sql-seed.psm1` each name `Install-Module` inside a `throw` or an
#   `Assert-MlsCommand -Hint`. Those are instructions to a HUMAN whose local shell is
#   missing a module: they install nothing, they run in no job, and a version pinned in
#   that sentence would be advice rather than a constraint. Flagging them would teach the
#   next reader to add exclusions to this test, which is how a sweep stops being read.
#   The check named 'ignores Install-Module inside comments and human-facing hints' below
#   holds that boundary from the other side, so the scope rule is asserted and not merely
#   described.

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $script:GithubDir = Join-Path $script:RepoRoot '.github'
    $script:ActionPath = Join-Path $script:GithubDir (Join-Path 'actions' (Join-Path 'install-exo' 'action.yml'))

    # First non-whitespace token only. See the SCOPE RULE at the top of this file.
    $script:InstallPattern = '^\s*Install-Module\s+(?<module>[A-Za-z0-9_.-]+)'

    # A job that runs Security & Compliance PowerShell needs the module at RUNTIME,
    # whether or not it is the step that installed it. That is the capability this
    # depends on; `Install-Module` is only the artefact that usually accompanies it.
    $script:ScUsagePattern = '^\s*(Connect-IPPSSession\b|Import-Module\s+ExchangeOnlineManagement\b)'

    $script:UsesAction = 'uses:\s*\./\.github/actions/install-exo'

    function Get-MlsRelativePath {
        param([Parameter(Mandatory)][string]$Path)
        # Forward slashes, always. workload-rbac and control-characters both record that a
        # path comparison written with backslashes matches nothing on ubuntu-latest, so the
        # check behaves differently in the one place that gates a merge.
        $Path.Substring($script:RepoRoot.Length + 1).Replace([char]92, [char]47)
    }

    function Get-MlsModuleInstall {
        param([Parameter(Mandatory)][string]$Path)

        $backtick = [char]96
        $lines = @(Get-Content -LiteralPath $Path)
        $found = [System.Collections.Generic.List[object]]::new()

        for ($i = 0; $i -lt $lines.Count; $i++) {
            $match = [regex]::Match($lines[$i], $script:InstallPattern)
            if (-not $match.Success) { continue }

            # Follow the continuations before judging the parameters.
            $statement = $lines[$i]
            $j = $i
            while ($statement.TrimEnd().EndsWith($backtick) -and ($j + 1) -lt $lines.Count) {
                $j++
                $statement = $statement.TrimEnd().TrimEnd($backtick) + ' ' + $lines[$j].Trim()
            }

            $found.Add([pscustomobject]@{
                    File      = Get-MlsRelativePath -Path $Path
                    Line      = $i + 1
                    Module    = $match.Groups['module'].Value
                    Exact     = [bool]($statement -match '-RequiredVersion')
                    Floor     = [bool]($statement -match '-MinimumVersion')
                    Statement = $statement.Trim()
                })
        }

        # NO leading comma. `, $found.ToArray()` wraps the result in an outer array, and a
        # caller collecting with @() then holds one ARRAY per file rather than one record
        # per install - which reads as 28 findings with no properties on them instead of 10
        # with all of them, and passes the emptiness checks below for the wrong reason.
        $found.ToArray()
    }

    $script:CiFiles = @(
        @(Get-ChildItem -Path (Join-Path $script:GithubDir 'workflows') -Filter '*.yml' -File) +
        @(Get-ChildItem -Path (Join-Path $script:GithubDir 'actions') -Filter 'action.yml' -File -Recurse)
    )
    $script:CiInstalls = @(foreach ($file in $script:CiFiles) { Get-MlsModuleInstall -Path $file.FullName })

    # The four scripts that mention Install-Module in guidance a human reads. Named, not
    # globbed: the point of this list is that these exact sentences must survive the sweep.
    $script:GuidancePaths = @(
        (Join-Path $script:RepoRoot (Join-Path 'infra' (Join-Path 'purview' 'labels.ps1')))
        (Join-Path $script:RepoRoot (Join-Path 'infra' (Join-Path 'entra' 'apply-entra.ps1')))
        (Join-Path $script:RepoRoot (Join-Path 'verification' 'MlsAudit.psm1'))
        (Join-Path $script:RepoRoot (Join-Path 'data' (Join-Path 'seed' (Join-Path 'sql' 'sql-seed.psm1'))))
    )

    $script:PinnedVersion = ([regex]::Match(
        (Get-Content -LiteralPath $script:ActionPath -Raw),
            "(?m)^\s*default:\s*'(?<v>[0-9]+(\.[0-9]+)+)'\s*$")).Groups['v'].Value
}

Describe 'no CI job installs a PowerShell module unpinned' {

    It 'found Install-Module in CI at all' {
        # NON-VACUITY, and it is the whole reason this It exists. A sweep that matches
        # nothing reports a clean repository in exactly the voice of a working one - the
        # class behind F102, F103 and F105, where three subsystems answered "absent" to a
        # question they had never been able to observe. If the workflow layout moves, or
        # the token test stops matching, this fails instead of quietly passing.
        @($script:CiInstalls).Count | Should -BeGreaterThan 0 `
            -Because 'a sweep that finds no installs would pass this whole file while checking nothing'
        @($script:CiInstalls | Select-Object -ExpandProperty File -Unique).Count | Should -BeGreaterThan 1 `
            -Because 'the installs are spread over several workflows; matching only one means the enumeration is broken, not that the repo improved'
    }

    It 'ignores Install-Module inside comments and human-facing hints' {
        # THE FALSE-POSITIVE HALF OF THE SCOPE RULE, asserted rather than described.
        # infra/purview/labels.ps1 and verification/MlsAudit.psm1 tell a human with a bare
        # shell what to install; flagging them would make this test wrong in the direction
        # that gets tests silenced. Both directions are checked: the sentences must still
        # exist (or this proves nothing), and none may be read as a CI install.
        $mentions = 0
        $commands = @()
        foreach ($path in $script:GuidancePaths) {
            Test-Path -LiteralPath $path | Should -BeTrue `
                -Because "$path is one of the guidance strings this exclusion is written about; if it moved, the exclusion is now describing nothing"
            $mentions += @(Select-String -LiteralPath $path -Pattern 'Install-Module' -SimpleMatch).Count
            $commands += @(Get-MlsModuleInstall -Path $path)
        }

        $mentions | Should -BeGreaterThan 0 `
            -Because 'the human-facing hints must still be there, or this check passes by having nothing to misread'
        @($commands | ForEach-Object { "$($_.File):$($_.Line)" }) -join ', ' | Should -BeNullOrEmpty `
            -Because 'a throw or a hint string is advice to a person, not a step CI runs; reading one as an unpinned install trains the next reader to add exclusions here'
    }

    It 'every module CI installs declares at least a version floor' {
        # THE RATCHET. Two installs in this repository still name no version at all, and
        # they are recorded here as DEBT, not as permission - each entry states what has to
        # happen for it to be deleted. The comparison is set equality in BOTH directions:
        # a new unpinned install fails, and so does a fixed one whose entry was left
        # behind, so the list cannot rot into an allowlist that quietly grows.
        #
        # -MinimumVersion counts as a floor and not as a pin. It is a deliberate, documented
        # choice in the five SqlServer installs (22+ for `Invoke-Sqlcmd -AccessToken`) and in
        # Pester (5.5+ for New-PesterConfiguration), and weakening those to a floor is a
        # narrower failure than having no constraint: the version can still move under CI,
        # but not backwards past the capability the job depends on.
        $debt = @{
            '.github/workflows/layer-03-entra.yml|Microsoft.Graph.Authentication' = @{
                Occurrences = 2
                Why         = 'L3 plan and L3 apply each install Graph unpinned. Both belong to the L3 branch in flight; pinning them needs a version resolved against PSGallery, not written from memory. Delete this entry when they carry -RequiredVersion.'
            }
            '.github/workflows/lint-ci.yml|PSScriptAnalyzer' = @{
                Occurrences = 1
                Why         = 'The analyser gates every pull request, so a gallery-chosen version can turn the repo red on a morning nobody changed anything - and can just as easily stop reporting a rule. Delete this entry when it carries -RequiredVersion.'
            }
        }

        $observed = @{}
        foreach ($install in ($script:CiInstalls | Where-Object { -not $_.Exact -and -not $_.Floor })) {
            $key = "$($install.File)|$($install.Module)"
            if (-not $observed.ContainsKey($key)) { $observed[$key] = 0 }
            $observed[$key]++
        }

        $drift = foreach ($key in (@($observed.Keys) + @($debt.Keys) | Sort-Object -Unique)) {
            $have = if ($observed.ContainsKey($key)) { $observed[$key] } else { 0 }
            $want = if ($debt.ContainsKey($key)) { $debt[$key].Occurrences } else { 0 }
            if ($have -ne $want) { "$key (declared $want, found $have)" }
        }

        @($drift) -join '; ' | Should -BeNullOrEmpty -Because (
            'an install with no version constraint lets PSGallery decide what CI runs, so the same ' +
            'commit can behave differently on two mornings with no diff to explain it. Pin it with ' +
            '-RequiredVersion; if it genuinely cannot be pinned yet, add it to $debt above with what ' +
            'has to happen for the entry to go away. An entry that no longer matches reality is also ' +
            'a failure - a fixed install must have its debt entry deleted, or this becomes an ' +
            'allowlist that only grows')
    }

    It 'pins ExchangeOnlineManagement to an exact version wherever it is installed' {
        # No floor, no debt entry, no exception. This is the Verifier's dependency and the
        # one module in the estate whose PARAMETER SET is known to differ between platforms
        # (F172), so "some version at or above X" is not a constraint that would have caught
        # anything: -CertificateThumbprint appears and disappears without the version moving
        # backwards at all.
        $exo = @($script:CiInstalls | Where-Object { $_.Module -eq 'ExchangeOnlineManagement' })
        @($exo).Count | Should -BeGreaterThan 0 `
            -Because 'L4 and infra-down both need this module; finding no install means the enumeration broke, not that the need went away'
        @($exo | Where-Object { -not $_.Exact } | ForEach-Object { "$($_.File):$($_.Line)" }) -join ', ' |
            Should -BeNullOrEmpty `
            -Because 'the audit that signs off L4 must not be able to change behaviour without a commit; -MinimumVersion still lets the version move under CI'
    }
}

Describe 'the pinned ExchangeOnlineManagement version has exactly one source' {

    It 'is declared as the install-exo action input default' {
        # CLAUDE.md: every value has one source. Three call sites sharing a constant they
        # each spell out is three constants that drift, and the drift is invisible because
        # every one of them still looks correct on its own.
        $script:PinnedVersion | Should -Match '^\d+\.\d+\.\d+$' `
            -Because 'the rest of this file searches for this literal; if it cannot be parsed out of the action, every check below is looking for an empty string and finds it everywhere'
    }

    It 'appears nowhere else under .github/' {
        # Bounded so 3.9.2 does not match inside 13.9.20 - a version literal that matches a
        # longer number would report a violation nobody can find, which is the fastest way
        # to get a sweep deleted.
        $pattern = "(?<![0-9.])$([regex]::Escape($script:PinnedVersion))(?![0-9.])"

        $offenders = foreach ($file in (Get-ChildItem -Path $script:GithubDir -Recurse -File)) {
            if ($file.FullName -eq $script:ActionPath) { continue }
            $number = 0
            foreach ($line in (Get-Content -LiteralPath $file.FullName)) {
                $number++
                if ($line -match $pattern) { "$(Get-MlsRelativePath -Path $file.FullName):$number" }
            }
        }

        @($offenders) -join ', ' | Should -BeNullOrEmpty -Because (
            "the version is an input default on .github/actions/install-exo with a documented reason; " +
            'a second copy in a workflow is a value that outranks it silently, exactly as an input ' +
            'default outranked vars.AZURE_LOCATION in F52/F53. Override the version input on the ' +
            'action if a single job genuinely needs a different one')
    }
}

Describe 'every ExchangeOnlineManagement consumer goes through the pinned action' {

    It 'installs the module in exactly one place, the action itself' {
        $exo = @($script:CiInstalls | Where-Object { $_.Module -eq 'ExchangeOnlineManagement' })
        $inline = @($exo | Where-Object { $_.File -ne (Get-MlsRelativePath -Path $script:ActionPath) })

        @($exo).Count | Should -Be 1 `
            -Because 'one install means one version; a second install step is a second version whether or not it is pinned today'
        @($inline | ForEach-Object { "$($_.File):$($_.Line)" }) -join ', ' | Should -BeNullOrEmpty `
            -Because 'an inline install bypasses both the pin and the loaded-version assertion, and it does so while looking like a perfectly ordinary step'
    }

    It 'is referenced by every workflow that runs Security & Compliance PowerShell' {
        # ASSERT THE CAPABILITY, NOT THE ARTEFACT. The question is not "did a job call
        # Install-Module" but "can the job that calls Connect-IPPSSession see the module at
        # all" - the invisible-value class (F122-F125), where the value exists, is spelled
        # correctly, and is not visible to the thing that reads it.
        $consumers = @()
        foreach ($file in (Get-ChildItem -Path (Join-Path $script:GithubDir 'workflows') -Filter '*.yml' -File)) {
            $content = Get-Content -LiteralPath $file.FullName
            if (@($content | Where-Object { $_ -match $script:ScUsagePattern }).Count -gt 0) {
                $consumers += [pscustomobject]@{
                    Name  = $file.Name
                    Wired = [bool](@($content | Where-Object { $_ -match $script:UsesAction }).Count -gt 0)
                }
            }
        }

        @($consumers).Count | Should -BeGreaterThan 0 `
            -Because 'L4 runs Connect-IPPSSession; finding no consumer means this check stopped recognising them and would pass over a job that installs nothing'
        @($consumers | Where-Object { -not $_.Wired } | Select-Object -ExpandProperty Name) -join ', ' |
            Should -BeNullOrEmpty `
            -Because 'a job that calls Connect-IPPSSession without the pinned install either fails at command resolution or picks up whatever a previous step left behind'
    }

    It 'asserts the version it actually loaded, rather than trusting the install' {
        # F119's class, applied to the one step this whole file routes through. Install-Module
        # can succeed and leave the wrong version importable - a side-by-side install, a
        # -Scope that the next step does not read - and every check above would still pass,
        # because they all read the repository rather than the runner.
        $action = Get-Content -LiteralPath $script:ActionPath -Raw
        $action | Should -Match 'Import-Module\s+ExchangeOnlineManagement\s+-RequiredVersion' `
            -Because 'importing the version by name is what makes the next assertion able to fail'
        $action | Should -Match 'Get-Module\s+ExchangeOnlineManagement' `
            -Because 'the loaded version has to be read back from the runner; the exit code of Install-Module is not evidence of what is importable'
        $action | Should -Match '(?s)Get-Module\s+ExchangeOnlineManagement.*throw' `
            -Because 'reading the version and not comparing it produces a log line instead of a gate, and a step allowed to pass quietly is a step nobody is watching'
    }
}
