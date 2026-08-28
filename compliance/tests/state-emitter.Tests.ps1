# compliance/tests/state-emitter.Tests.ps1
#
# Invoke-MlsCompliance.ps1 is the assembly point: the catalog, the register and every
# collector meet here and become the one artifact the board renders and the MCP tool
# answers from. Everything downstream reads this shape, so the failure modes this suite
# exists to prevent are shape failures as much as logic failures:
#
#   * a requirement silently missing from the board because nothing was said about it;
#   * an 800-53-keyed register record vanishing (Task 3 fails closed on the id mismatch)
#     or, worse, being resolved through the catalog's mappings onto an 800-171 row whose
#     status its author never asserted;
#   * collected evidence rendered as if it had driven a status it did not drive;
#   * a blended "% compliant" figure appearing anywhere;
#   * state-latest.json written as a link, which does not survive a Windows author or a
#     Linux collector round-trip.
#
# The golden fixture set is deliberately rich: it exercises all six derived statuses and
# all four provenances, an out-of-catalog record, a malformed register file, and evidence
# that participates alongside evidence that does not.

BeforeAll {
    $script:Runner = (Resolve-Path -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'Invoke-MlsCompliance.ps1')).Path
    $script:FixtureRoot = Join-Path -Path $PSScriptRoot -ChildPath 'fixtures'
    $script:CatalogPath = (Resolve-Path -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'catalog', 'nist-800-171r2.json')).Path
    $script:RealAssessmentRoot = (Resolve-Path -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'assessment')).Path
    $script:GoldenPath = Join-Path -Path $script:FixtureRoot -ChildPath 'golden-state.json'

    $script:Catalog = Get-Content -LiteralPath $script:CatalogPath -Raw | ConvertFrom-Json
    $script:CatalogId = @($script:Catalog.requirements.id)

    # The golden fixture set, in one place: every test that pins behaviour uses exactly
    # these inputs, so the golden file and the behavioural assertions can never describe
    # two different runs.
    $script:GoldenArgs = @{
        CatalogPath                = $script:CatalogPath
        AssessmentRoot             = Join-Path -Path $script:FixtureRoot -ChildPath 'state-assessment'
        RepoRoot                   = Join-Path -Path $script:FixtureRoot -ChildPath 'repo-static' -AdditionalChildPath 'compliant'
        VerificationReportRoot     = $script:FixtureRoot
        GitHubSecurityResponsePath = Join-Path -Path $script:FixtureRoot -ChildPath 'github-security-enabled.json'
        AzurePolicyResponsePath    = Join-Path -Path $script:FixtureRoot -ChildPath 'azure-policy-auditmode.json'
    }

    function script:Invoke-Runner {
        param([hashtable]$Argument = @{}, [switch]$NoPassThru)
        $splat = @{} + $Argument
        if (-not $NoPassThru) { $splat['PassThru'] = $true }
        & $script:Runner @splat -WarningAction SilentlyContinue -InformationAction SilentlyContinue
    }

    # A dated evidence stamp is the one field of the artifact that legitimately changes on
    # every run, so the golden comparison normalises it rather than pretending it is
    # stable. Everything else in the artifact is pinned byte for byte.
    function script:ConvertTo-StampFreeJson {
        param($InputObject)
        $json = $InputObject | ConvertTo-Json -Depth 12
        return ($json -replace '"collectedAt":\s*"[^"]*"', '"collectedAt": "<normalised>"')
    }

    # Every property name in the whole object graph, for the no-percentage assertion.
    function script:Get-PropertyNameDeep {
        param($InputObject, [int]$Depth = 0)
        if ($null -eq $InputObject -or $Depth -gt 16) { return }
        if ($InputObject -is [string] -or $InputObject.GetType().IsPrimitive) { return }
        if ($InputObject -is [System.Collections.IEnumerable]) {
            foreach ($item in $InputObject) { script:Get-PropertyNameDeep -InputObject $item -Depth ($Depth + 1) }
            return
        }
        foreach ($property in $InputObject.PSObject.Properties) {
            $property.Name
            script:Get-PropertyNameDeep -InputObject $property.Value -Depth ($Depth + 1)
        }
    }
}

Describe 'Invoke-MlsCompliance (state emitter)' {

    Context 'the brief''s own five tests' {
        BeforeAll {
            $script:OutDir = Join-Path -Path $TestDrive -ChildPath 'brief'
            $script:BriefState = script:Invoke-Runner -Argument ($script:GoldenArgs + @{ OutputRoot = $script:OutDir })
        }

        It 'produces one entry for every one of the 110 requirements' {
            @($script:BriefState.controls).Count | Should -Be 110
        }

        It 'stamps the commit it was collected at' {
            $script:BriefState.commit | Should -Not -BeNullOrEmpty
        }

        It 'matches the golden state for a known fixture set' {
            $golden = Get-Content -LiteralPath $script:GoldenPath -Raw | ConvertFrom-Json
            (script:ConvertTo-StampFreeJson $script:BriefState.controls) |
                Should -Be (script:ConvertTo-StampFreeJson $golden.controls)
        }

        It 'writes state-latest.json as a real file, not a link' {
            (Get-Item -LiteralPath (Join-Path -Path $script:OutDir -ChildPath 'state-latest.json')).LinkType |
                Should -BeNullOrEmpty
        }

        It 'reports counts by status AND provenance, and no blended percentage' {
            $script:BriefState.summary.byStatus | Should -Not -BeNullOrEmpty
            $script:BriefState.summary.byProvenance | Should -Not -BeNullOrEmpty
            $script:BriefState.summary.PSObject.Properties.Name | Should -Not -Contain 'percentCompliant'
        }
    }

    Context 'the artifact on disk' {
        BeforeAll {
            $script:DiskDir = Join-Path -Path $TestDrive -ChildPath 'disk'
            $script:DiskState = script:Invoke-Runner -Argument ($script:GoldenArgs + @{ OutputRoot = $script:DiskDir })
            $script:DatedName = "state-$($script:DiskState.collectedAt.Substring(0, 10)).json"
        }

        It 'writes a dated artifact named for the collection date' {
            Test-Path -LiteralPath (Join-Path -Path $script:DiskDir -ChildPath $script:DatedName) | Should -BeTrue
        }

        It 'writes state-latest.json with byte-identical content to the dated artifact' {
            $dated = Get-Content -LiteralPath (Join-Path -Path $script:DiskDir -ChildPath $script:DatedName) -Raw
            $latest = Get-Content -LiteralPath (Join-Path -Path $script:DiskDir -ChildPath 'state-latest.json') -Raw
            $latest | Should -Be $dated
        }

        It 'writes state-latest.json as a copy, so deleting the dated artifact leaves it readable' {
            Remove-Item -LiteralPath (Join-Path -Path $script:DiskDir -ChildPath $script:DatedName) -Force
            $latest = Get-Content -LiteralPath (Join-Path -Path $script:DiskDir -ChildPath 'state-latest.json') -Raw
            ($latest | ConvertFrom-Json).controls.Count | Should -Be 110
        }

        It 'creates the output directory when it does not exist' {
            $fresh = Join-Path -Path $TestDrive -ChildPath 'made-up' -AdditionalChildPath 'nested'
            script:Invoke-Runner -Argument ($script:GoldenArgs + @{ OutputRoot = $fresh }) -NoPassThru
            Test-Path -LiteralPath (Join-Path -Path $fresh -ChildPath 'state-latest.json') | Should -BeTrue
        }

        It 'writes LF-only JSON so a Windows author and a Linux collector agree byte for byte' {
            $bytes = [System.IO.File]::ReadAllBytes((Join-Path -Path $script:DiskDir -ChildPath 'state-latest.json'))
            ($bytes -contains 13) | Should -BeFalse -Because 'a CR would make every CI commit a whole-file diff'
        }

        It 'writes UTF-8 without a byte-order mark' {
            $bytes = [System.IO.File]::ReadAllBytes((Join-Path -Path $script:DiskDir -ChildPath 'state-latest.json'))
            ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should -BeFalse
        }
    }

    Context 'every one of the 110 requirements is present, whatever was said about it' {
        BeforeAll {
            $script:RealState = script:Invoke-Runner -Argument @{
                CatalogPath    = $script:CatalogPath
                AssessmentRoot = $script:RealAssessmentRoot
                OutputRoot     = (Join-Path -Path $TestDrive -ChildPath 'real')
            }
        }

        It 'emits exactly the catalog''s requirement ids, in catalog order' {
            @($script:RealState.controls.control) | Should -Be $script:CatalogId
        }

        It 'renders a requirement nothing was said about as NOT_ASSESSED / none, never as an omission' {
            # 3.2.1 (awareness training) is organizational: no finding, no criterion, no
            # collector reaches it. It must still be on the board.
            $row = $script:RealState.controls | Where-Object control -EQ '3.2.1'
            $row | Should -Not -BeNullOrEmpty
            $row.status | Should -Be 'NOT_ASSESSED'
            $row.provenance | Should -Be 'none'
            $row.observed | Should -Not -BeNullOrEmpty -Because 'a blank cell is indistinguishable from a bug'
        }

        It 'carries the catalog''s title, family and framework mappings onto every row' {
            $row = $script:RealState.controls | Where-Object control -EQ '3.5.3'
            $row.title | Should -Not -BeNullOrEmpty
            $row.family | Should -Be '3.5'
            $row.familyName | Should -Be 'Identification and Authentication'
            @($row.mappings.'cmmc-2.0') | Should -Contain 'L2-3.5.3'
        }

        It 'gives every row a status and a provenance drawn from the published vocabulary' {
            $vocabulary = & {
                Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'lib', 'MlsCompliance.psm1') -Force
                Get-MlsComplianceVocabulary
            }
            foreach ($row in $script:RealState.controls) {
                $vocabulary.Status | Should -Contain $row.status
                $vocabulary.Provenance | Should -Contain $row.provenance
            }
        }
    }

    Context 'the four 800-53-keyed register records (carried-forward decision 1)' {
        BeforeAll {
            $script:RegisterState = script:Invoke-Runner -Argument @{
                CatalogPath    = $script:CatalogPath
                AssessmentRoot = $script:RealAssessmentRoot
                OutputRoot     = (Join-Path -Path $TestDrive -ChildPath 'register')
            }
        }

        It 'renders all four as their own rows, keyed on their 800-53 ids' {
            @($script:RegisterState.outOfCatalogControls.control) |
                Should -Be @('CM-6', 'CP-9', 'IR-4', 'SI-4')
        }

        It 'labels each row with the framework it was actually assessed against' {
            foreach ($row in $script:RegisterState.outOfCatalogControls) {
                $row.framework | Should -Be 'nist-800-53r5'
                $row.inCatalog | Should -BeFalse
                $row.note | Should -Match '800-53'
                $row.note | Should -Match 'no requirement'
            }
        }

        It 'derives each one honestly rather than dropping it on the id mismatch' {
            # All four assert CLOSED. CLOSED is weaker than "the control is met", so the
            # strongest honest derivation is PARTIAL / asserted - never COMPLIANT.
            foreach ($row in $script:RegisterState.outOfCatalogControls) {
                $row.status | Should -Be 'PARTIAL'
                $row.provenance | Should -Be 'asserted'
            }
        }

        It 'does NOT resolve them through the catalog''s mappings into 800-171 rows' {
            # CP-9 maps to 3.8.9, CM-6 to 3.4.1/3.4.2, IR-4 to 3.6.1/3.6.2, SI-4 to
            # 3.14.6/3.14.7. Rendering an 800-53 record's authored CLOSED against any of
            # them would attribute a claim its author never made. That wrong-box join is
            # exactly what Task 3's control-id guard exists to catch.
            foreach ($requirementId in @('3.8.9', '3.4.1', '3.4.2', '3.6.2', '3.14.6', '3.14.7')) {
                $row = $script:RegisterState.controls | Where-Object control -EQ $requirementId
                $row.status | Should -Be 'NOT_ASSESSED' -Because "$requirementId has no assessment of its own"
                $row.provenance | Should -Be 'none'
            }
        }

        It 'counts them separately from the 110, so the framework totals stay arithmetic' {
            $script:RegisterState.summary.totalRequirements | Should -Be 110
            (@($script:RegisterState.summary.byStatus.PSObject.Properties.Value) |
                Measure-Object -Sum).Sum | Should -Be 110
            $script:RegisterState.summary.outOfCatalog.count | Should -Be 4
            $script:RegisterState.summary.outOfCatalog.byStatus.PARTIAL | Should -Be 4
        }

        It 'names, for orientation only, the requirements whose catalog mappings cite the control' {
            $cp9 = $script:RegisterState.outOfCatalogControls | Where-Object control -EQ 'CP-9'
            @($cp9.requirementsMappingToThisControl) | Should -Be @('3.8.9')
            $cp9.note | Should -Match 'not applied'
        }
    }

    Context 'collected evidence that drove nothing (carried-forward decision 2)' {
        BeforeAll {
            $script:EvidenceState = script:Invoke-Runner -Argument ($script:GoldenArgs + @{
                    OutputRoot = (Join-Path -Path $TestDrive -ChildPath 'evidence')
                })
        }

        It 'surfaces control-scoped evidence on the row rather than dropping it' {
            # 3.3.1 has repo-static evidence and no assessment at all. The evidence must
            # be visible - collecting evidence nobody renders would be its own dishonesty.
            $row = $script:EvidenceState.controls | Where-Object control -EQ '3.3.1'
            @($row.supportingEvidence).Count | Should -BeGreaterThan 0
            @($row.supportingEvidence.source) | Should -Contain 'repo-static'
        }

        It 'does not let that evidence move the status it did not drive' {
            $row = $script:EvidenceState.controls | Where-Object control -EQ '3.3.1'
            $row.status | Should -Be 'NOT_ASSESSED'
            $row.provenance | Should -Be 'none'
            @($row.statusBasis).Count | Should -Be 0
            @($row.evidence).Count | Should -Be 0
        }

        It 'marks every supporting record as not having participated' {
            foreach ($row in $script:EvidenceState.controls) {
                foreach ($record in @($row.supportingEvidence)) {
                    $record.participatedInStatus | Should -BeFalse
                }
            }
        }

        It 'keeps evidence that DID drive the status in a separate field, marked as such' {
            $row = $script:EvidenceState.controls | Where-Object control -EQ '3.5.3'
            $row.status | Should -Be 'GAP'
            $row.provenance | Should -Be 'machine-verified'
            @($row.evidence).Count | Should -Be 1
            $row.evidence[0].criterion | Should -Be 'V3.3'
            $row.evidence[0].participatedInStatus | Should -BeTrue
            @($row.supportingEvidence.criterion) | Should -Not -Contain 'V3.3'
        }

        It 'says in the artifact which is which' {
            $script:EvidenceState.notes.supportingEvidence | Should -Match 'did not'
            $script:EvidenceState.notes.supportingEvidence | Should -Match 'statusBasis'
        }

        It 'never places the same record in both fields' {
            foreach ($row in $script:EvidenceState.controls) {
                $participating = @($row.evidence | ForEach-Object { "$($_.source)|$($_.criterion)|$($_.observed)" })
                foreach ($record in @($row.supportingEvidence)) {
                    $participating | Should -Not -Contain "$($record.source)|$($record.criterion)|$($record.observed)"
                }
            }
        }

        It 'agrees with the derivation about what participated' {
            # The partition must never drift from Get-MlsControlStatus's own join: every
            # participating record has to appear as a criterion row in statusBasis, and
            # every criterion row that named a source has to have a participating record.
            foreach ($row in $script:EvidenceState.controls) {
                $basisSource = @($row.statusBasis |
                        Where-Object { $_.kind -eq 'criterion' -and $_.source } |
                        ForEach-Object { "$($_.criterion)|$($_.source)" } | Sort-Object)
                $evidenceSource = @($row.evidence | ForEach-Object { "$($_.criterion)|$($_.source)" } | Sort-Object)
                $evidenceSource | Should -Be $basisSource -Because "control $($row.control) must partition its evidence the way the derivation did"
            }
        }
    }

    Context 'a skipped criterion is machine-verified but never reads as passing (carried-forward decision 3)' {
        BeforeAll {
            $script:SkipState = script:Invoke-Runner -Argument ($script:GoldenArgs + @{
                    OutputRoot = (Join-Path -Path $TestDrive -ChildPath 'skip')
                })
            $script:SkipRow = $script:SkipState.controls | Where-Object control -EQ '3.8.4'
        }

        It 'keeps the earlier ruling: a SKIP still earns machine-verified provenance' {
            $script:SkipRow.status | Should -Be 'INCONCLUSIVE'
            $script:SkipRow.provenance | Should -Be 'machine-verified'
        }

        It 'cross-tabulates provenance against status so machine-verified cannot read as passing' {
            $script:SkipState.summary.byProvenanceAndStatus.'machine-verified'.INCONCLUSIVE |
                Should -BeGreaterThan 0
            $script:SkipState.summary.byProvenanceAndStatus.'machine-verified'.COMPLIANT |
                Should -BeGreaterThan 0
            # The two must be distinguishable: a single machine-verified total is exactly
            # the number that would blur them.
            $script:SkipState.summary.byProvenanceAndStatus.'machine-verified'.INCONCLUSIVE |
                Should -Not -Be $script:SkipState.summary.byProvenance.'machine-verified'
        }

        It 'renders every vocabulary key in every count, including the zero ones' {
            $vocabulary = & {
                Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'lib', 'MlsCompliance.psm1') -Force
                Get-MlsComplianceVocabulary
            }
            @($script:SkipState.summary.byStatus.PSObject.Properties.Name) | Should -Be $vocabulary.Status
            @($script:SkipState.summary.byProvenance.PSObject.Properties.Name) | Should -Be $vocabulary.Provenance
            foreach ($provenance in $vocabulary.Provenance) {
                @($script:SkipState.summary.byProvenanceAndStatus.$provenance.PSObject.Properties.Name) |
                    Should -Be $vocabulary.Status
            }
        }

        It 'says in the summary what machine-verified does and does not mean' {
            ($script:SkipState.summary.notes -join ' ') | Should -Match 'declined'
            ($script:SkipState.summary.notes -join ' ') | Should -Match 'COMPLIANT'
        }
    }

    Context 'no blended percentage, anywhere' {
        BeforeAll {
            $script:NoScoreState = script:Invoke-Runner -Argument ($script:GoldenArgs + @{
                    OutputRoot = (Join-Path -Path $TestDrive -ChildPath 'noscore')
                })
        }

        It 'has no percentCompliant field on the summary' {
            $script:NoScoreState.summary.PSObject.Properties.Name | Should -Not -Contain 'percentCompliant'
        }

        It 'has no property named like a percentage, ratio or score anywhere in the artifact' {
            $offender = @(script:Get-PropertyNameDeep -InputObject $script:NoScoreState |
                    Where-Object { $_ -match '(?i)percent|ratio|score|pct' } | Sort-Object -Unique)
            $offender | Should -BeNullOrEmpty -Because 'a blended figure is the number an adopter would quote to an auditor and the number that would be wrong'
        }

        It 'has no property named like a percentage in the file on disk either' {
            $raw = Get-Content -LiteralPath (Join-Path -Path $TestDrive -ChildPath 'noscore' -AdditionalChildPath 'state-latest.json') -Raw
            ($raw | ConvertFrom-Json) | Should -Not -BeNullOrEmpty
            $offender = @(script:Get-PropertyNameDeep -InputObject ($raw | ConvertFrom-Json) |
                    Where-Object { $_ -match '(?i)percent|ratio|score|pct' } | Sort-Object -Unique)
            $offender | Should -BeNullOrEmpty
        }
    }

    Context 'the normal case today: no tenant, and every collector empty' {
        BeforeAll {
            # repo-static treats a file it expected and did not find as an observable FAIL
            # (Task 6's documented decision) but returns NOTHING when -RepoRoot itself is
            # unreachable. So a genuinely empty run points it at a tree that is not there -
            # which is also the real shape of "this source could not be consulted".
            $script:EmptyRepo = Join-Path -Path $TestDrive -ChildPath 'no-such-tree'
            $script:EmptyReports = Join-Path -Path $TestDrive -ChildPath 'empty-reports'
            $script:EmptyAssessment = Join-Path -Path $TestDrive -ChildPath 'empty-assessment'
            New-Item -ItemType Directory -Path $script:EmptyReports, $script:EmptyAssessment -Force | Out-Null

            $script:EmptyState = script:Invoke-Runner -Argument @{
                CatalogPath            = $script:CatalogPath
                AssessmentRoot         = $script:EmptyAssessment
                RepoRoot               = $script:EmptyRepo
                VerificationReportRoot = $script:EmptyReports
                OutputRoot             = (Join-Path -Path $TestDrive -ChildPath 'empty')
            }
        }

        It 'still produces a complete artifact rather than failing' {
            @($script:EmptyState.controls).Count | Should -Be 110
        }

        It 'renders every requirement NOT_ASSESSED / none' {
            @($script:EmptyState.controls | Where-Object status -NE 'NOT_ASSESSED') | Should -BeNullOrEmpty
            $script:EmptyState.summary.byStatus.NOT_ASSESSED | Should -Be 110
            $script:EmptyState.summary.byProvenance.none | Should -Be 110
        }

        It 'records each collector''s own empty result rather than silently omitting it' {
            @($script:EmptyState.collectors.name) | Should -Be @(
                'verification-suite', 'repo-static', 'github-security', 'azure-policy', 'manual')
            foreach ($collector in $script:EmptyState.collectors) {
                $collector.status | Should -Be 'ok'
                $collector.recordCount | Should -Be 0
            }
        }

        It 'emits no out-of-catalog rows when the register holds none' {
            @($script:EmptyState.outOfCatalogControls).Count | Should -Be 0
            $script:EmptyState.summary.outOfCatalog.count | Should -Be 0
        }

        It 'records that the assessment root it was pointed at held nothing' {
            $script:EmptyState.assessmentProblems | Should -BeNullOrEmpty
            $script:EmptyState.commit | Should -Not -BeNullOrEmpty
        }

        It 'still completes when a source exists but is bare, and leaves the statuses alone' {
            # An EXISTING but empty working tree is a different case from an absent one:
            # repo-static reports each expected-and-missing file as a FAIL. Those records
            # must land as supporting context and move no status, because no assessment
            # claims a criterion for any of them.
            $bare = Join-Path -Path $TestDrive -ChildPath 'bare-tree'
            New-Item -ItemType Directory -Path $bare -Force | Out-Null
            $state = script:Invoke-Runner -Argument @{
                CatalogPath            = $script:CatalogPath
                AssessmentRoot         = $script:EmptyAssessment
                RepoRoot               = $bare
                VerificationReportRoot = $script:EmptyReports
                OutputRoot             = (Join-Path -Path $TestDrive -ChildPath 'bare')
            }
            @($state.controls).Count | Should -Be 110
            ($state.collectors | Where-Object name -EQ 'repo-static').recordCount | Should -BeGreaterThan 0
            $state.summary.byStatus.NOT_ASSESSED | Should -Be 110
        }
    }

    Context 'collector honesty carried into the artifact' {
        BeforeAll {
            $script:HonestyState = script:Invoke-Runner -Argument ($script:GoldenArgs + @{
                    OutputRoot = (Join-Path -Path $TestDrive -ChildPath 'honesty')
                })
        }

        It 'states azure-policy''s limitation rather than letting the evidence look stronger than it is' {
            $azure = $script:HonestyState.collectors | Where-Object name -EQ 'azure-policy'
            $azure.limitation | Should -Match 'policyDefinitionAction'
            $azure.limitation | Should -Match '(?i)audit'
            $azure.limitation | Should -Match '(?i)enforcementMode'
        }

        It 'states repo-static''s limitation: the repository declares, the estate does not run' {
            $repo = $script:HonestyState.collectors | Where-Object name -EQ 'repo-static'
            $repo.limitation | Should -Match '(?i)not.*deployed'
        }

        It 'states that manual evidence is an authored transcription' {
            $manual = $script:HonestyState.collectors | Where-Object name -EQ 'manual'
            $manual.limitation | Should -Match '(?i)authored'
        }

        It 'records a register file it could not read rather than losing it silently' {
            @($script:HonestyState.assessmentProblems.file) | Should -Contain 'Z99-malformed.json'
        }

        It 'keeps a collector failure from taking down the run, and says so' {
            # Not `$GoldenArgs + @{...}`: hashtable addition throws on a duplicate key, and
            # this case deliberately REPLACES one of the golden arguments.
            $argument = @{} + $script:GoldenArgs
            $argument['OutputRoot'] = Join-Path -Path $TestDrive -ChildPath 'failed-collector'
            $argument['AzurePolicyResponsePath'] = Join-Path -Path $TestDrive -ChildPath 'does-not-exist.json'
            $state = script:Invoke-Runner -Argument $argument
            @($state.controls).Count | Should -Be 110
            $azure = $state.collectors | Where-Object name -EQ 'azure-policy'
            $azure.status | Should -Be 'failed'
            $azure.error | Should -Not -BeNullOrEmpty
        }
    }

    Context 'provenance of the artifact itself' {
        BeforeAll {
            $script:StampState = script:Invoke-Runner -Argument ($script:GoldenArgs + @{
                    OutputRoot = (Join-Path -Path $TestDrive -ChildPath 'stamp')
                })
        }

        It 'stamps a full commit sha and its short form' {
            $script:StampState.commit | Should -Match '^[0-9a-f]{40}$'
            $script:StampState.commitShort | Should -Be $script:StampState.commit.Substring(0, 7)
        }

        It 'records whether the working tree was clean, so a dirty run is not passed off as reproducible' {
            $script:StampState.PSObject.Properties.Name | Should -Contain 'workingTreeClean'
            $script:StampState.workingTreeClean | Should -BeOfType [bool]
        }

        It 'stamps an ISO-8601 UTC collection time' {
            $script:StampState.collectedAt | Should -Match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$'
        }

        It 'names the framework the controls array is a view of' {
            $script:StampState.framework | Should -Be 'nist-800-171r2'
        }

        It 'honours an explicitly supplied commit, so CI can stamp the sha it checked out' {
            $state = script:Invoke-Runner -Argument ($script:GoldenArgs + @{
                    OutputRoot = (Join-Path -Path $TestDrive -ChildPath 'given-commit')
                    Commit     = '0123456789abcdef0123456789abcdef01234567'
                })
            $state.commit | Should -Be '0123456789abcdef0123456789abcdef01234567'
            $state.commitShort | Should -Be '0123456'
        }
    }
}
