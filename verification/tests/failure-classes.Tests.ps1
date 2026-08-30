# Preventive checks for the failure CLASSES this estate has already paid for.
#
# Every finding below was discovered by deploying, failing, and reading a log - the most
# expensive way there is. Each run buys one defect, because a layer stops at its first error,
# so a class of defect present in four places costs four deploys to find. These tests turn
# each class into something a laptop finds in a second.
#
# The classes, and where they were learned:
#
#   F70  A fix at the call site protects one call; a fix at the CHOKE POINT protects the
#        class. L3's replication retry was added to the failing POST, and the next run died
#        on the GET one line above it. Every transport wrapper needs the retry, not every
#        call site.
#   F69  A predicate matching Graph error text against $_.Exception.Message never fires:
#        Invoke-MgGraphRequest puts the terse status there and the error CODE in
#        $_.ErrorDetails.Message. A correct retry keyed on a field that never carries the
#        value is indistinguishable from no retry at all.
#
# These are deliberately INVENTORY-BASED, like verification/guid-allowlist.txt. A new
# transport that nobody thought about does not silently inherit an exemption: it fails this
# suite until someone declares what it is and whether it retries.
#
# WHAT THIS DOES NOT COVER, stated so nobody mistakes a green run for full coverage:
# only HTTP transports. L4 reaches Purview through Security & Compliance PowerShell cmdlets
# and L8 reaches Power Platform through the `pac` CLI - neither is an Invoke-* HTTP call, so
# neither is visible here. Those are a real gap, not an exemption; they need their own check
# once their failure shapes are known from a run rather than assumed from a reading.

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path

    # Raw transports: the calls that actually leave the machine.
    $script:TransportPattern = 'Invoke-MgGraphRequest|Invoke-RestMethod|Invoke-WebRequest'

    # Tokens that indicate a bounded retry rather than a single attempt.
    $script:RetryPattern = 'deadline|Start-Sleep|PropagationDelay|Retry-After|retry|attempt'

    # THE INVENTORY. Every non-test PowerShell file under infra/ or scripts/ that makes a raw
    # transport call must appear here, with an explicit verdict on retry.
    #
    # RetryRequired = $true  -> the file's transport must show bounded-retry machinery.
    # RetryRequired = $false -> deliberately none, with the reason stated. Read-only or
    #                           single-shot paths where a retry would hide a real answer.
    $script:TransportInventory = @(
        @{ Path = 'infra/entra/apply-entra.ps1'; RetryRequired = $true
            Why = 'Invoke-GraphApi is the choke point; every create is followed by reads and writes against an object that may not have replicated (F70).'
        }
        @{ Path = 'infra/entra/teardown.ps1'; RetryRequired = $false
            Why = 'Deletes. A 404 means the object is already gone, which is the desired end state - retrying it would wait out a budget to confirm success.'
        }
        @{ Path = 'infra/fabric/fabric-api.psm1'; RetryRequired = $true
            Why = 'Long-running operations are polled to a deadline honouring Retry-After. NOTE the transport itself does not retry a transient 429/503 - whether it needs to is unknown until L5 runs against a live capacity, and guessing is how three wrong theories about L3 got shipped.'
        }
    )
}

Describe 'every transport choke point is accounted for' {

    It 'finds transports at all' {
        # A discovery step that silently matches nothing would make every assertion vacuous.
        $files = @(Get-ChildItem -Path $script:RepoRoot -Recurse -Include '*.ps1', '*.psm1' -File |
                Where-Object { $_.FullName -notmatch '[\\/](tests|node_modules|\.git)[\\/]' } |
                Where-Object { $_.FullName -match '[\\/](infra|scripts)[\\/]' } |
                Where-Object { (Get-Content -LiteralPath $_.FullName -Raw) -match $script:TransportPattern })
        $files.Count | Should -BeGreaterThan 0
    }

    It 'every file making a raw transport call is declared in the inventory' {
        # The point of the inventory: a NEW transport cannot inherit an exemption by being
        # forgotten. Adding one means saying what it is and whether it retries.
        $declared = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($entry in $script:TransportInventory) { $null = $declared.Add($entry.Path) }

        $undeclared = [System.Collections.Generic.List[string]]::new()
        foreach ($file in (Get-ChildItem -Path $script:RepoRoot -Recurse -Include '*.ps1', '*.psm1' -File)) {
            if ($file.FullName -match '[\\/](tests|node_modules|\.git)[\\/]') { continue }
            if ($file.FullName -notmatch '[\\/](infra|scripts)[\\/]') { continue }
            if ((Get-Content -LiteralPath $file.FullName -Raw) -notmatch $script:TransportPattern) { continue }
            $relative = $file.FullName.Substring($script:RepoRoot.Length).TrimStart('\', '/').Replace('\', '/')
            if (-not $declared.Contains($relative)) { $undeclared.Add($relative) }
        }
        $undeclared -join ', ' | Should -BeNullOrEmpty `
            -Because 'a transport nobody declared is a transport nobody decided about (F70)'
    }

    It 'every inventory entry that claims to retry actually does' {
        $offender = [System.Collections.Generic.List[string]]::new()
        foreach ($entry in $script:TransportInventory) {
            if (-not $entry.RetryRequired) { continue }
            $full = Join-Path $script:RepoRoot $entry.Path
            if (-not (Test-Path -LiteralPath $full)) { $offender.Add("$($entry.Path) (missing)"); continue }
            # CODE only. `fabric-api.psm1` passed this check on the strength of a COMMENT
            # mentioning Retry-After while containing no retry whatsoever - a check satisfied
            # by prose about the thing it is checking for is the same defect it exists to
            # catch, one level up.
            $code = (Get-Content -LiteralPath $full) |
                ForEach-Object { ($_ -replace '(?<!`)#.*$', '') } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
            if (($code -join "`n") -notmatch $script:RetryPattern) { $offender.Add($entry.Path) }
        }
        $offender -join ', ' | Should -BeNullOrEmpty `
            -Because 'a transport that does not retry fails the first time its API is slow, and finds that out in a deploy'
    }

    It 'every inventory entry states why' {
        $missing = @($script:TransportInventory |
                Where-Object { [string]::IsNullOrWhiteSpace($_.Why) } |
                ForEach-Object { $_.Path })
        $missing -join ', ' | Should -BeNullOrEmpty -Because 'an exemption without a reason is an oversight with a checkbox'
    }
}

Describe 'error predicates read the field that carries the value' {

    It 'no catch matches Graph or HTTP error codes against Exception.Message alone' {
        # F69: Invoke-MgGraphRequest puts the terse status in Exception.Message and the JSON
        # body carrying the error CODE in ErrorDetails.Message. A predicate reading only the
        # former is a retry that never fires - it passed every unit test and did nothing in
        # production, because the mocks threw the shape the author expected.
        $codePattern = 'Request_ResourceNotFound|ResourceNotFound|Authorization_RequestDenied|InsufficientPrivileges'
        $offender = [System.Collections.Generic.List[string]]::new()

        foreach ($file in (Get-ChildItem -Path $script:RepoRoot -Recurse -Include '*.ps1', '*.psm1' -File)) {
            if ($file.FullName -match '[\\/](node_modules|\.git)[\\/]') { continue }
            $lines = Get-Content -LiteralPath $file.FullName
            for ($i = 0; $i -lt $lines.Count; $i++) {
                $line = $lines[$i]
                if ($line -notmatch '\$_\.Exception\.Message' -or $line -notmatch '-match') { continue }
                if ($line -notmatch $codePattern) { continue }
                # The value may be composed a line or two earlier or later; look at the block.
                $from = [math]::Max(0, $i - 4)
                $to = [math]::Min($lines.Count - 1, $i + 2)
                $block = ($lines[$from..$to]) -join "`n"
                if ($block -notmatch 'ErrorDetails') {
                    $relative = $file.FullName.Substring($script:RepoRoot.Length).TrimStart('\', '/').Replace('\', '/')
                    $offender.Add("${relative}:$($i + 1)")
                }
            }
        }
        $offender -join ', ' | Should -BeNullOrEmpty `
            -Because 'the Graph error code lives in ErrorDetails.Message; a predicate reading only Exception.Message never fires (F69)'
    }
}
