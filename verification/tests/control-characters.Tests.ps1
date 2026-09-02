Describe 'no source file carries a stray control character' {
    # THE DAMAGE IS INVISIBLE IN REVIEW, WHICH IS WHY THIS IS A TEST AND NOT A HABIT.
    #
    # Content written through a shell heredoc crosses two escaping layers - the shell,
    # then the Python or PowerShell string literal inside it - and backslash sequences
    # are silently transformed on the way. In one session that produced:
    #
    #   * a throttle check written as /\b429\b/ that reached the file as
    #     /<0x08>429<0x08>/ - a literal BACKSPACE, matching nothing. The cooldown it
    #     guarded never opened, and the feed kept hammering an upstream that was
    #     throttling it. Only a behavioural test caught it; a test asserting "the
    #     regex is correct" would have read the same corrupted bytes.
    #   * the same corruption inside a comment in MlsAudit.Tests.ps1, where it was
    #     harmless and passed every suite - which is exactly why it survived.
    #
    # A diff renders 0x08 as nothing, or as a space, or not at all. The file looks
    # right, the code compiles, the tests pass. This sweep is a second and cheaper
    # instance of the rule CLAUDE.md states: a class paid for once becomes a check.
    #
    # WHAT IS ALLOWED. Tab (0x09), line feed (0x0A) and carriage return (0x0D) are
    # ordinary text. Everything else below 0x20 is a mistake in a source file - and
    # this deliberately does NOT scan binaries, lockfiles or anything generated.

    BeforeAll {
        $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    }

    It 'contains no control characters other than tab, CR and LF' {
        $extensions = @('*.ts', '*.tsx', '*.mjs', '*.js', '*.ps1', '*.psm1', '*.bicep',
            '*.bicepparam', '*.yml', '*.yaml', '*.md', '*.json')
        $files = @(Get-ChildItem -Path $script:Root -Include $extensions -Recurse -File |
                Where-Object {
                    # NORMALISED TO FORWARD SLASHES FIRST. The exclusions below were
                    # written with backslashes and matched nothing on ubuntu-latest,
                    # so a path this test deliberately ignores failed CI while passing
                    # on the dev host - a check that behaved differently in the place
                    # that actually gates a merge.
                    $path = $_.FullName.Replace([char]92, [char]47)
                    $path -notlike '*node_modules*' -and
                    $path -notlike '*/.git/*' -and
                    $path -notlike '*/dist/*' -and
                    $path -notlike '*package-lock.json' -and
                    # Superpowers plan and brief archives: a historical record of how
                    # work was executed, not maintained source. One of them carries a
                    # deliberate 0x01 inside an XSS test fixture, and rewriting an
                    # archive to satisfy a sweep would falsify the record it exists to
                    # keep. Excluded by path rather than by an allowlist of bytes, so
                    # the rule stays absolute everywhere it applies.
                    $path -notlike '*/docs/superpowers/*' -and
                    $path -notlike '*/.superpowers/*'
                })

        $offender = [System.Collections.Generic.List[string]]::new()
        foreach ($file in $files) {
            $text = Get-Content -LiteralPath $file.FullName -Raw
            if ([string]::IsNullOrEmpty($text)) { continue }
            foreach ($match in [regex]::Matches($text, '[\x00-\x08\x0B\x0C\x0E-\x1F]')) {
                $code = [int][char]$match.Value[0]
                $relative = $file.FullName.Substring($script:Root.Length + 1)
                # The line number is what makes this actionable: the character is
                # invisible, so "somewhere in this file" would send a reader hunting.
                $line = ($text.Substring(0, $match.Index) -split "`n").Count
                $offender.Add("$relative line $line : 0x$('{0:X2}' -f $code)")
                break
            }
        }

        $files.Count | Should -BeGreaterThan 100 `
            -Because 'if the sweep reads almost nothing its globs are wrong and it asserts nothing'
        $offender -join ' | ' | Should -BeNullOrEmpty `
            -Because 'a control character in source is heredoc escaping damage: it renders as nothing in a diff, compiles, and passes tests - a regex carrying one matches nothing and a comment carrying one hides it (CLAUDE.md: file content is written with a file tool, never through a shell heredoc)'
    }
}
