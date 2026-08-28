# compliance/tests/collector-contract.Tests.ps1
#
# CollectorContract.psm1 is the shape of every evidence record this platform will ever
# produce (New-MlsEvidence), and the runner every collector in Tasks 5-7 goes through
# (Invoke-MlsCollector). The failure mode this suite exists to prevent: a collector that
# mutates the estate it is supposed to be read-only about, or an evidence record that
# stands in for something nobody actually observed.

BeforeAll {
    $script:ModulePath = Join-Path $PSScriptRoot '..' 'collectors' 'CollectorContract.psm1'
    Import-Module $script:ModulePath -Force

    # A real collector (Tasks 5-7) imports MlsAudit.psm1 itself to call the guarded
    # transports directly, the same way every verification/layer-NN-audit.ps1 does; one
    # test below exercises that pattern, so the module needs to be available here too -
    # importing it inside CollectorContract.psm1 does not also make it available in this
    # file's own session state.
    Import-Module (Join-Path $PSScriptRoot '..' '..' 'verification' 'MlsAudit.psm1') -Force
}

AfterAll {
    Remove-Module CollectorContract -Force -ErrorAction SilentlyContinue
    Remove-Module MlsAudit -Force -ErrorAction SilentlyContinue
}

Describe 'evidence records' {

    It 'stamps collectedAt and carries every required field' {
        $e = New-MlsEvidence -Control '3.5.3' -Source 'verification-suite' -Status 'fail' -Observed 'CA report-only'
        $e.control | Should -Be '3.5.3'
        $e.source | Should -Be 'verification-suite'
        $e.status | Should -Be 'fail'
        $e.observed | Should -Not -BeNullOrEmpty
        $e.collectedAt | Should -Match '^\d{4}-\d{2}-\d{2}T'
    }

    It 'carries an artifact when one is supplied' {
        $e = New-MlsEvidence -Control '3.5.3' -Source 's' -Status 'pass' -Observed 'o' `
            -Artifact 'verification/reports/L03-2026-08-26.md'
        $e.artifact | Should -Be 'verification/reports/L03-2026-08-26.md'
    }

    It 'leaves artifact null when none is supplied, rather than omitting the field' {
        $e = New-MlsEvidence -Control '3.5.3' -Source 's' -Status 'pass' -Observed 'o'
        $e.PSObject.Properties.Name | Should -Contain 'artifact'
        $e.artifact | Should -BeNullOrEmpty
    }

    It 'rejects a status outside the contract' {
        { New-MlsEvidence -Control '3.5.3' -Source 's' -Status 'green' -Observed 'o' } | Should -Throw
    }

    It 'requires observed - the field that lets a reader judge the mapping' {
        { New-MlsEvidence -Control '3.5.3' -Source 's' -Status 'pass' -Observed '' } | Should -Throw
    }

    It 'rejects an observed value that is whitespace only' {
        { New-MlsEvidence -Control '3.5.3' -Source 's' -Status 'pass' -Observed '   ' } | Should -Throw
    }

    # Task 2's finding, carried forward by Task 3's report: an assessment's `criteria`
    # only ever claims what genuinely ran. A collector must therefore gate emission on a
    # real PASS/FAIL and never manufacture evidence for a criterion that was SKIPPED or
    # left PENDING - so those words are not in the contract at all.
    It 'rejects skip - a skipped criterion is not evidence of anything' {
        { New-MlsEvidence -Control '3.5.3' -Source 's' -Status 'skip' -Observed 'o' } | Should -Throw
    }

    It 'rejects pending - a criterion that has not resolved yet is not evidence either' {
        { New-MlsEvidence -Control '3.5.3' -Source 's' -Status 'pending' -Observed 'o' } | Should -Throw
    }

    It 'accepts inconclusive - the honest word for a criterion that ran but proved nothing' {
        { New-MlsEvidence -Control '3.5.3' -Source 's' -Status 'inconclusive' -Observed 'o' } | Should -Not -Throw
    }

    # Referential integrity against Task 1's catalog - carried forward explicitly: "a
    # dangling control id has already shipped once on this branch."
    It 'rejects a control id the catalog does not carry' {
        { New-MlsEvidence -Control '99.99.99' -Source 's' -Status 'pass' -Observed 'o' } |
            Should -Throw '*99.99.99*'
    }

    It 'rejects an 800-53 id even though the register keys four assessment files on one' {
        # compliance/README.md: CM-6, SI-4, IR-4, CP-9 key the register on 800-53 ids the
        # 800-171 catalog has no requirement for. Evidence is keyed on the 800-171 id, not
        # on whatever the register happens to use, so these must fail the same as any
        # other unknown id - proven concretely rather than merely asserted.
        { New-MlsEvidence -Control 'CM-6' -Source 's' -Status 'pass' -Observed 'o' } | Should -Throw
    }

    It 'accepts every id actually in the catalog' {
        $catalogPath = Join-Path $PSScriptRoot '..' 'catalog' 'nist-800-171r2.json'
        $catalog = Get-Content -LiteralPath $catalogPath -Raw | ConvertFrom-Json
        foreach ($requirement in $catalog.requirements) {
            { New-MlsEvidence -Control $requirement.id -Source 's' -Status 'pass' -Observed 'o' } |
                Should -Not -Throw -Because "'$($requirement.id)' is a real catalog id"
        }
    }
}

Describe 'collector isolation' {

    It 'fails a collector that issues a mutating call' {
        # Collectors assess; they must not change what they assess. This is the literal
        # shape a careless collector author reaches for first - bare `az`, not
        # Invoke-MlsAz - which is exactly why it has to be the one that is tested.
        { Invoke-MlsCollector -Name 'bad' -ScriptBlock { az group create -n x -l y } } |
            Should -Throw '*read-only*'
    }

    It 'fails a mutating call made via the call operator' {
        # `& az ...` resolves through the same command lookup as a bare `az ...`; proven
        # separately because it is the second-most obvious way to shell out.
        { Invoke-MlsCollector -Name 'bad' -ScriptBlock { & az group create -n x -l y } } |
            Should -Throw '*read-only*'
    }

    It 'fails a collector that issues a mutating gh call' {
        { Invoke-MlsCollector -Name 'bad' -ScriptBlock { gh repo delete octocat/hello } } |
            Should -Throw '*'
    }

    It 'fails a collector that issues a mutating git call' {
        { Invoke-MlsCollector -Name 'bad' -ScriptBlock { git push origin main } } |
            Should -Throw '*'
    }

    It 'leaves az, gh and git resolving to the real executables once the collector returns' {
        # The shadow must not leak past the one call it guards.
        { Invoke-MlsCollector -Name 'bad' -ScriptBlock { az group create -n x -l y } } |
            Should -Throw
        (Get-Command az -ErrorAction SilentlyContinue).CommandType | Should -Be 'Application'
        (Get-Command gh -ErrorAction SilentlyContinue).CommandType | Should -Be 'Application'
        (Get-Command git -ErrorAction SilentlyContinue).CommandType | Should -Be 'Application'
    }

    It 'validates every emitted record, not only the first' {
        # The first record here is a genuinely valid one; only the second is broken. A
        # runner that checked index 0 and stopped would let this through.
        {
            Invoke-MlsCollector -Name 'multi' -ScriptBlock {
                New-MlsEvidence -Control '3.5.3' -Source 's' -Status 'pass' -Observed 'first, valid'
                [pscustomobject]@{
                    control = '3.1.1'; source = 's'; status = 'not-a-real-status'
                    observed = 'second, broken'; collectedAt = '2026-08-28T00:00:00Z'
                }
            }
        } | Should -Throw "*not-a-real-status*"
    }

    It 'rejects a hand-built record with no observed, even when it did not go through New-MlsEvidence' {
        # A collector is free to build a hashtable by hand instead of calling
        # New-MlsEvidence; the contract still applies.
        {
            Invoke-MlsCollector -Name 'handbuilt' -ScriptBlock {
                [pscustomobject]@{
                    control = '3.5.3'; source = 's'; status = 'pass'
                    observed = ''; collectedAt = '2026-08-28T00:00:00Z'
                }
            }
        } | Should -Throw '*observed*'
    }

    It 'rejects a record that never carried a control id at all' {
        # Strict-mode safety: a scalar/malformed "record" must fail closed with a named
        # reason, not crash on a missing property.
        { Invoke-MlsCollector -Name 'scalar' -ScriptBlock { 'not-a-record' } } |
            Should -Throw '*control*'
    }

    It 'rejects a literal null emitted as a record' {
        # $null in the output stream is not "nothing was collected" - Invoke-MlsCollector
        # cannot tell that apart from a caller trying to assert an absence as evidence, so
        # it must fail closed rather than silently drop it.
        { Invoke-MlsCollector -Name 'nullrecord' -ScriptBlock { $null } } | Should -Throw
    }

    It 'returns zero records, without throwing, for a collector that genuinely finds nothing to emit' {
        # Distinct from the case above: no output at all is a legitimate "nothing here",
        # not an evidence record standing in for an absence.
        $result = Invoke-MlsCollector -Name 'quiet' -ScriptBlock { $null = 1 + 1 }
        @($result).Count | Should -Be 0
    }

    It 'surfaces an error the collector throws mid-run rather than a partial set' {
        # The scriptblock builds one good record, then blows up before building a second.
        # A runner that swallowed the error and returned what it had so far would still
        # pass a test that only checked the message; asserting the CALL ITSELF throws is
        # what rules that out - there is no way for a caller to receive the partial
        # one-record set, because a thrown call never produces a return value at all.
        {
            Invoke-MlsCollector -Name 'boom' -ScriptBlock {
                New-MlsEvidence -Control '3.5.3' -Source 's' -Status 'pass' -Observed 'before the throw'
                throw "the collector's own logic exploded"
            }
        } | Should -Throw "*the collector's own logic exploded*"
    }

    It 'returns every valid record a well-behaved collector emits' {
        $result = Invoke-MlsCollector -Name 'good' -ScriptBlock {
            New-MlsEvidence -Control '3.5.3' -Source 'verification-suite' -Status 'pass' -Observed 'first'
            New-MlsEvidence -Control '3.1.1' -Source 'verification-suite' -Status 'fail' -Observed 'second'
        }
        @($result).Count | Should -Be 2
        ($result | Where-Object control -eq '3.5.3').status | Should -Be 'pass'
        ($result | Where-Object control -eq '3.1.1').status | Should -Be 'fail'
    }

    It 'still lets a collector make a legitimate read-only call through the guarded transport directly' {
        # Isolation guards the bare-native path; it must not make the module unusable for
        # a collector that imports MlsAudit.psm1 itself (as Tasks 5-7 do) and calls the
        # guarded transport the way it is meant to be called.
        Mock Invoke-MlsGit {
            return [pscustomobject]@{ ExitCode = 1; Line = @() }
        }
        $result = Invoke-MlsCollector -Name 'legit' -ScriptBlock {
            $grep = Invoke-MlsGit -Argument @('grep', '-n', 'TODO')
            New-MlsEvidence -Control '3.5.3' -Source 'repo-static' -Status 'pass' `
                -Observed "git grep exit code $($grep.ExitCode)"
        }
        @($result).Count | Should -Be 1
        Should -Invoke Invoke-MlsGit -Exactly -Times 1
    }
}

Describe 'evidence carries the criterion id Task 3 joins on' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..' 'collectors' 'CollectorContract.psm1') -Force
        Import-Module (Join-Path $PSScriptRoot '..' 'lib' 'MlsCompliance.psm1') -Force
    }

    It 'carries a criterion when the record came from a Verifier criterion' {
        $record = New-MlsEvidence -Control '3.5.3' -Source 'verification-suite' `
            -Status 'fail' -Observed 'CA policies are report-only' -Criterion 'V3.3'
        $record.criterion | Should -Be 'V3.3'
    }

    It 'leaves criterion null for control-scoped evidence that has no criterion' {
        # repo-static, github-security, azure-policy and manual observe a control
        # directly. Inventing a criterion id for them would be a false join key.
        $record = New-MlsEvidence -Control '3.5.3' -Source 'repo-static' `
            -Status 'pass' -Observed 'SECURITY.md documents the reporting path'
        $record.criterion | Should -BeNullOrEmpty
    }

    It 'a criterion-scoped record actually satisfies a declared criterion in the derivation' {
        # The join this field exists for, tested end to end rather than assumed. Before
        # -Criterion existed, a collector record could never match a declared criterion,
        # so every machine-verified path was unreachable no matter what the collectors
        # emitted.
        $record = New-MlsEvidence -Control '3.5.3' -Source 'verification-suite' `
            -Status 'pass' -Observed 'both policies enforced' -Criterion 'V3.3'

        $result = Get-MlsControlStatus -Requirement @{ id = '3.5.3' } `
            -Assessment @{ applicability = 'applicable'; criteria = @('V3.3') } `
            -Evidence @($record)

        $result.Status | Should -Be 'COMPLIANT'
        $result.Provenance | Should -Be 'machine-verified'
    }

    It 'a control-scoped record cannot satisfy a declared criterion' {
        # Matching on control alone would let repo-static evidence silently satisfy a
        # criterion it never ran.
        $record = New-MlsEvidence -Control '3.5.3' -Source 'repo-static' `
            -Status 'pass' -Observed 'documented in the runbook'

        $result = Get-MlsControlStatus -Requirement @{ id = '3.5.3' } `
            -Assessment @{ applicability = 'applicable'; criteria = @('V3.3') } `
            -Evidence @($record)

        $result.Status | Should -Be 'INCONCLUSIVE'
        $result.Provenance | Should -Be 'none' -Because 'nothing matched the declared criterion'
    }
}
