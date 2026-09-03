# Compliance Platform Implementation Plan

> **HISTORY — this plan was executed. It is kept as the record of what was done and why,
> not as a description of current state or of work still to do.**
>
> For what is true now, read [docs/DEMO-READINESS.md](../../DEMO-READINESS.md). For how
> each thing came to be true — including the diagnoses that turned out to be wrong — read
> [docs/findings/2026-09-03-finding-register.md](../../findings/2026-09-03-finding-register.md).
>
> Checkboxes below are left in the state they were in. An unticked box here does **not**
> mean outstanding work; it means the plan moved on. Nothing is deleted, because a plan
> that edits its own premises after the fact stops being evidence of anything.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A self-auditing compliance platform that renders all 110 NIST SP 800-171 Rev 2 requirements — with 800-53 Rev 5 and CMMC 2.0 L1/L2 views over the same records — showing status, evidence, provenance, and what would close each gap.

**Architecture:** PowerShell collectors run in CI, read five sources, and emit typed evidence records. A pure derivation function turns catalog + assessment + evidence into a dated state artifact, committed to git so compliance drift becomes `git log`. A static React SPA bakes the catalog and state at build time and renders them behind Container Apps Easy Auth. An MCP `query_compliance` tool reads the same artifact so the Ask tab answers from one source of truth.

**Tech Stack:** PowerShell 7 + Pester 6 (collectors, derivation), TypeScript + React 18 + Fluent UI v9 + vite/vitest (app, matching `control-tower`), Bicep + AVM (container app, Easy Auth), GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-08-26-compliance-platform-design.md`

**Depends on:** `docs/superpowers/plans/2026-08-26-security-remediation.md` Task 1, which authors the initial `compliance/assessment/*.json` records this plan renders. Tasks 1-3 here can proceed in parallel with remediation; Task 6 onward wants the register populated.

## Global Constraints

- **No Azure/Entra/Fabric/GitHub-org writes.** Collectors are read-only by construction (see Task 4); the app deploys but is not deployed by this plan.
- **No secrets in the repo and none in CI.** The app holds none — Easy Auth is platform configuration, not application code.
- **An authored assertion may never render as `machine-verified`.** Enforced as a property test in Task 3, not by review discipline. This is the single rule the platform exists to keep.
- **No single "% compliant" headline figure.** Counts by status *and* provenance only. A blended percentage is the number an adopter would quote to their auditor and the number that would be wrong.
- **Conventional commits:** `feat:`, `fix:`, `infra:`, `docs:`, `verify:`.
- **Gate every change on:** Pester (**848 at this plan's start** — raise it, never lower it), PSScriptAnalyzer 0 at Error/Warning, `npm test` exit 0 (868), pytest 30, `az bicep build` on all Bicep artifacts, `actionlint` clean **run bare, the way `lint-ci.yml` runs it** — verifying with `-shellcheck=` disables the check that most recently went red.
- **Naming:** `mls-<app|role>-<env>-<type>` — the app is `mls-compliance-demo-ca`. Prefix comes from `infra/bicep/naming.bicep`; never hardcode `mls`.
- **Framework identifiers**, used verbatim as JSON keys everywhere: `nist-800-171r2`, `nist-800-53r5`, `cmmc-2.0`, `far-52.204-21`.

---

## Task 1: The control catalog

**Files:**
- Create: `compliance/catalog/nist-800-171r2.json`
- Create: `compliance/catalog/README.md`
- Test: `compliance/tests/catalog.Tests.ps1`

**Interfaces:**
- Consumes: nothing.
- Produces: the catalog every later task keys off. Shape per spec §3.1: `{ framework, requirements: [{ id, family, familyName, title, mappings }] }`.

The 14 families and their requirement counts (Rev 2), which the test asserts:

| Family | Name | Count |
|---|---|---|
| 3.1 | Access Control | 22 |
| 3.2 | Awareness and Training | 3 |
| 3.3 | Audit and Accountability | 9 |
| 3.4 | Configuration Management | 9 |
| 3.5 | Identification and Authentication | 11 |
| 3.6 | Incident Response | 3 |
| 3.7 | Maintenance | 6 |
| 3.8 | Media Protection | 9 |
| 3.9 | Personnel Security | 2 |
| 3.10 | Physical Protection | 6 |
| 3.11 | Risk Assessment | 3 |
| 3.12 | Security Assessment | 4 |
| 3.13 | System and Communications Protection | 16 |
| 3.14 | System and Information Integrity | 7 |
| | **Total** | **110** |

- [ ] **Step 1: Write the failing test**

```powershell
# compliance/tests/catalog.Tests.ps1
BeforeAll {
    $script:CatalogPath = Join-Path $PSScriptRoot '..' 'catalog' 'nist-800-171r2.json'
    $script:Catalog = if (Test-Path $script:CatalogPath) {
        Get-Content $script:CatalogPath -Raw | ConvertFrom-Json
    }
    $script:ExpectedCounts = @{
        '3.1' = 22; '3.2' = 3;  '3.3' = 9;  '3.4' = 9;  '3.5' = 11
        '3.6' = 3;  '3.7' = 6;  '3.8' = 9;  '3.9' = 2;  '3.10' = 6
        '3.11' = 3; '3.12' = 4; '3.13' = 16; '3.14' = 7
    }
}

Describe 'the 800-171 catalog' {
    It 'contains exactly 110 requirements' {
        @($script:Catalog.requirements).Count | Should -Be 110
    }

    It 'has the right count in every family' {
        foreach ($family in $script:ExpectedCounts.Keys) {
            $actual = @($script:Catalog.requirements | Where-Object { $_.family -eq $family }).Count
            $actual | Should -Be $script:ExpectedCounts[$family] -Because "family $family"
        }
    }

    It 'has no duplicate requirement ids' {
        $ids = @($script:Catalog.requirements.id)
        ($ids | Sort-Object -Unique).Count | Should -Be $ids.Count
    }

    It 'gives every requirement a non-empty title' {
        foreach ($r in $script:Catalog.requirements) {
            $r.title | Should -Not -BeNullOrEmpty -Because "requirement $($r.id)"
        }
    }

    It 'uses only the agreed framework keys in mappings' {
        $allowed = @('nist-800-53r5', 'cmmc-2.0', 'far-52.204-21')
        foreach ($r in $script:Catalog.requirements) {
            foreach ($key in $r.mappings.PSObject.Properties.Name) {
                $key | Should -BeIn $allowed -Because "requirement $($r.id)"
            }
        }
    }

    It 'maps every requirement to its identical CMMC 2.0 Level 2 practice' {
        # CMMC 2.0 L2 IS the 110 requirements of 800-171 Rev 2 — an identity
        # mapping. Any requirement missing one is a transcription error.
        foreach ($r in $script:Catalog.requirements) {
            @($r.mappings.'cmmc-2.0') | Should -Contain "L2-$($r.id)" -Because "requirement $($r.id)"
        }
    }

    It 'maps every requirement to at least one 800-53 control' {
        # 800-171 derives from the 800-53 moderate baseline; Appendix D maps
        # each requirement to its parents. An empty mapping means unfinished
        # transcription, not an absent relationship.
        foreach ($r in $script:Catalog.requirements) {
            @($r.mappings.'nist-800-53r5').Count | Should -BeGreaterThan 0 -Because "requirement $($r.id)"
        }
    }

    It 'marks exactly the 17 CMMC Level 1 requirements, against 15 FAR clauses' {
        $l1 = @($script:Catalog.requirements | Where-Object { @($_.mappings.'far-52.204-21').Count -gt 0 })
        $l1.Count | Should -Be 15
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `pwsh -c "Invoke-Pester compliance/tests/catalog.Tests.ps1"`
Expected: FAIL — the catalog file does not exist.

- [ ] **Step 3: Author the catalog**

Transcribe all 110 requirements from NIST SP 800-171 Rev 2, with the Appendix D mappings to 800-53 Rev 5. CMMC L2 is mechanical (`L2-<id>` for each). CMMC L1 is FAR 52.204-21(b)(1)(i)-(xv) — fifteen clauses, but clause (ix) covers 3.10.3, 3.10.4 and 3.10.5, so **seventeen requirements** carry a Level 1 practice. Mark those seventeen with their `far-52.204-21` clause reference.

Write `compliance/catalog/README.md` recording the source documents and revision, so a reader knows what the transcription is *of* and can re-verify it.

- [ ] **Step 4: Run to verify it passes**

Run: `pwsh -c "Invoke-Pester compliance/tests/catalog.Tests.ps1"`
Expected: PASS, 8 tests.

- [ ] **Step 5: Commit**

```bash
git add compliance/catalog/ compliance/tests/catalog.Tests.ps1
git commit -m "feat(compliance): NIST 800-171 Rev 2 catalog with 800-53 and CMMC mappings

All 110 requirements across 14 families, each carrying its Appendix D
mapping to 800-53 Rev 5 and its identical CMMC 2.0 L2 practice, with the
17 requirements marked for CMMC L1, against 15 FAR 52.204-21 clauses. Tests assert the
per-family counts so a partial transcription cannot render as a high
compliance score."
```

---

## Task 2: `-Control` on `Invoke-MlsCriterion`

The one place this plan reaches into existing code. Per spec §4.2, the mapping lives beside the assertion it describes, because a separate mapping file drifts and drift is this tool's worst failure mode.

**Files:**
- Modify: `verification/MlsAudit.psm1` (`Invoke-MlsCriterion`, `New-MlsAuditContext` row shape)
- Modify: `verification/layer-01-audit.ps1` … `layer-11-audit.ps1` (all 55 call sites)
- Test: `verification/tests/MlsAudit.Tests.ps1`, `verification/tests/control-mapping.Tests.ps1`

**Interfaces:**
- Consumes: Task 1's catalog (for validating that mapped IDs exist).
- Produces: every criterion row carries `Control` — a `string[]`, possibly empty. This is what the `verification-suite` collector (Task 6) reads.

- [ ] **Step 1: Write the failing tests**

```powershell
# verification/tests/control-mapping.Tests.ps1
BeforeAll {
    $script:Catalog = Get-Content (Join-Path $PSScriptRoot '..' '..' 'compliance' 'catalog' 'nist-800-171r2.json') -Raw | ConvertFrom-Json
    $script:ValidIds = @($script:Catalog.requirements.id)
}

Describe 'criterion to control mapping' {
    It 'records the Control field on the criterion row' {
        $context = New-MlsAuditContext -Layer 99 -Title 't' -ScriptName 's' -ReportRoot $TestDrive
        Invoke-MlsCriterion -Context $context -Id 'V99.1' -Control @('3.5.3') `
            -Description 'd' -Command 'c' -Expected 'e' `
            -Test { New-MlsCheckResult -Passed $true -Observed 'o' } | Out-Null
        (@($context.Criterion)[0]).Control | Should -Be @('3.5.3')
    }

    It 'defaults to an empty array when a criterion maps to nothing' {
        $context = New-MlsAuditContext -Layer 99 -Title 't' -ScriptName 's' -ReportRoot $TestDrive
        Invoke-MlsCriterion -Context $context -Id 'V99.2' -Description 'd' -Command 'c' -Expected 'e' `
            -Test { New-MlsCheckResult -Passed $true -Observed 'o' } | Out-Null
        @((@($context.Criterion)[0]).Control).Count | Should -Be 0
    }

    It 'rejects a control id that is not in the catalog' {
        # Referential integrity in the authoring direction: a typo must fail
        # loudly rather than silently evidencing nothing.
        $context = New-MlsAuditContext -Layer 99 -Title 't' -ScriptName 's' -ReportRoot $TestDrive
        { Invoke-MlsCriterion -Context $context -Id 'V99.3' -Control @('3.99.99') `
            -Description 'd' -Command 'c' -Expected 'e' `
            -Test { New-MlsCheckResult -Passed $true -Observed 'o' } } | Should -Throw '*3.99.99*'
    }

    It 'every criterion in every layer audit declares a Control decision' {
        # Either it maps to >=1 control, or it explicitly maps to none. Silence
        # is not allowed — that is how coverage quietly rots.
        $sources = Get-ChildItem (Join-Path $PSScriptRoot '..') -Filter 'layer-*-audit.ps1'
        foreach ($file in $sources) {
            $body = Get-Content $file.FullName -Raw
            $calls = [regex]::Matches($body, "Invoke-MlsCriterion[^`n]*(`n[^`n]*)*?-Test")
            foreach ($call in $calls) {
                $call.Value | Should -Match '-Control' -Because "$($file.Name) has a criterion with no Control decision"
            }
        }
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `pwsh -c "Invoke-Pester verification/tests/control-mapping.Tests.ps1"`
Expected: FAIL — `Invoke-MlsCriterion` has no `-Control` parameter.

- [ ] **Step 3: Implement**

Add to `Invoke-MlsCriterion`:

```powershell
[Parameter()][AllowEmptyCollection()][string[]]$Control = @(),
```

Validate each entry against the catalog at call time (load once, cache in a module-scope variable), throwing with the offending ID. Add `Control = $Control` to the criterion row object.

Then annotate all 55 call sites. Suggested mappings for the highest-value ones — the rest follow the same reasoning:

| Criterion | Control | Why |
|---|---|---|
| V1.2 | `3.4.1` | repo baseline configuration |
| V1.4 | `3.5.1`, `3.5.2` | OIDC subject identification |
| V3.1 | `3.1.1`, `3.5.1` | account inventory |
| V3.2 | `3.1.1`, `3.1.2` | group membership = access enforcement |
| V3.3 | `3.5.3` | MFA policy state |
| V3.4 | `3.5.1` | licence state gates identity features |
| V4.1 | `3.8.4` | sensitivity labelling |
| V6.x | `3.13.1`, `3.13.8` | boundary and transmission protection |
| V9.1-9.4 | `3.11.2`, `3.14.1` | vulnerability scanning and flaw remediation |
| V10.1-10.2 | `3.14.1` | timely flaw remediation |
| V11.2 | `3.4.1`, `3.12.3` | configuration integrity across rebuild |

Criteria that genuinely evidence no 800-171 requirement — V11.4's wall clock, for instance — take `-Control @()` with a comment saying why.

- [ ] **Step 4: Run the full verification suite**

Run: `pwsh -c "Invoke-Pester verification/"`
Expected: PASS. Existing tests asserting on criterion rows may need the new field; update them.

- [ ] **Step 5: Commit**

```bash
git add verification/ compliance/tests/
git commit -m "feat(verify): criteria declare the 800-171 control they evidence

Adds -Control to Invoke-MlsCriterion and annotates all 55 criteria. The
mapping lives beside the assertion rather than in a separate file, because
a detached mapping drifts and drift is a compliance tool's worst failure.
Unmapped criteria must say so explicitly; silence fails the test."
```

---

## Task 3: Status derivation and the honesty invariant

The heart of the system. A pure function, so every honesty rule is mechanical.

**Files:**
- Create: `compliance/lib/MlsCompliance.psm1`
- Test: `compliance/tests/derivation.Tests.ps1`

**Interfaces:**
- Consumes: Task 1's catalog.
- Produces: `Get-MlsControlStatus -Requirement <obj> -Assessment <obj> -Evidence <obj[]>` returning
  `@{ Status; Provenance; Observed }` where `Status` ∈ `COMPLIANT|GAP|INCONCLUSIVE|NOT_APPLICABLE|NOT_ASSESSED`
  and `Provenance` ∈ `machine-verified|asserted|declared|none`.

- [ ] **Step 1: Write the failing tests**

```powershell
# compliance/tests/derivation.Tests.ps1
Describe 'Get-MlsControlStatus' {
    BeforeAll { Import-Module (Join-Path $PSScriptRoot '..' 'lib' 'MlsCompliance.psm1') -Force }

    $cases = @(
        @{ Name='N/A with justification'; Assessment=@{applicability='not-applicable'; naJustification='no on-prem component'}; Evidence=@(); Status='NOT_APPLICABLE'; Provenance='declared' }
        @{ Name='criteria all pass';      Assessment=@{applicability='applicable'; criteria=@('V3.3')}; Evidence=@(@{criterion='V3.3'; status='pass'}); Status='COMPLIANT'; Provenance='machine-verified' }
        @{ Name='criteria any fail';      Assessment=@{applicability='applicable'; criteria=@('V3.3','V3.4')}; Evidence=@(@{criterion='V3.3'; status='pass'},@{criterion='V3.4'; status='fail'}); Status='GAP'; Provenance='machine-verified' }
        @{ Name='criteria any skip';      Assessment=@{applicability='applicable'; criteria=@('V3.3')}; Evidence=@(@{criterion='V3.3'; status='inconclusive'}); Status='INCONCLUSIVE'; Provenance='machine-verified' }
        @{ Name='assertion with evidence';Assessment=@{applicability='applicable'; criteria=@(); assertion=@{status='PARTIAL'; evidence=@('SECURITY.md')}}; Evidence=@(); Status='PARTIAL'; Provenance='asserted' }
        @{ Name='assertion, no evidence'; Assessment=@{applicability='applicable'; criteria=@(); assertion=@{status='COMPLIANT'; evidence=@()}}; Evidence=@(); Status='NOT_ASSESSED'; Provenance='none' }
        @{ Name='nothing at all';         Assessment=$null; Evidence=@(); Status='NOT_ASSESSED'; Provenance='none' }
    )

    It 'derives <Name> correctly' -ForEach $cases {
        $r = Get-MlsControlStatus -Requirement @{ id='3.5.3' } -Assessment $Assessment -Evidence $Evidence
        $r.Status     | Should -Be $Status
        $r.Provenance | Should -Be $Provenance
    }

    It 'fails closed when a not-applicable has no justification' {
        $r = Get-MlsControlStatus -Requirement @{ id='3.10.1' } `
            -Assessment @{ applicability='not-applicable' } -Evidence @()
        $r.Status | Should -Be 'NOT_ASSESSED'
        $r.Status | Should -Not -Be 'NOT_APPLICABLE'
    }

    It 'THE HONESTY INVARIANT: an assertion can never be machine-verified' {
        # The single rule this platform exists to keep. Property test over a
        # generated space of assessments carrying no criteria.
        $statuses = @('COMPLIANT','PARTIAL','GAP')
        $evidenceSets = @(@(), @('a'), @('a','b'))
        foreach ($s in $statuses) {
            foreach ($e in $evidenceSets) {
                $r = Get-MlsControlStatus -Requirement @{ id='3.6.1' } `
                    -Assessment @{ applicability='applicable'; criteria=@(); assertion=@{ status=$s; evidence=$e } } `
                    -Evidence @()
                $r.Provenance | Should -Not -Be 'machine-verified' `
                    -Because "an authored assertion (status=$s, evidence=$($e.Count)) must never claim machine verification"
            }
        }
    }

    It 'ignores evidence for criteria the assessment does not claim' {
        # Stray evidence must not silently upgrade a control.
        $r = Get-MlsControlStatus -Requirement @{ id='3.5.3' } `
            -Assessment @{ applicability='applicable'; criteria=@() } `
            -Evidence @(@{ criterion='V3.3'; status='pass' })
        $r.Status | Should -Be 'NOT_ASSESSED'
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `pwsh -c "Invoke-Pester compliance/tests/derivation.Tests.ps1"`
Expected: FAIL — module does not exist.

- [ ] **Step 3: Implement**

`Get-MlsControlStatus` applies spec §3.4's table in order: N/A first (requiring justification), then criteria-driven, then assertion-driven, then `NOT_ASSESSED`. Evidence is matched to the assessment's declared criteria only; unclaimed evidence is discarded. `Provenance` is set from *which branch fired*, never from any input field — that is what makes the invariant structural rather than defensive.

- [ ] **Step 4: Run to verify they pass**

Run: `pwsh -c "Invoke-Pester compliance/tests/derivation.Tests.ps1"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add compliance/lib/ compliance/tests/derivation.Tests.ps1
git commit -m "feat(compliance): status derivation with the honesty invariant

Pure function over catalog + assessment + evidence. Provenance is set by
which derivation branch fires, never from an input field, so an authored
assertion is structurally incapable of rendering as machine-verified — a
property test covers the generated space of assertion shapes. N/A without
a justification and evidence for unclaimed criteria both fail closed."
```

---

## Task 4: Collector framework

**Files:**
- Create: `compliance/collectors/CollectorContract.psm1`
- Test: `compliance/tests/collector-contract.Tests.ps1`

**Interfaces:**
- Consumes: nothing.
- Produces: `New-MlsEvidence -Control <string> -Source <string> -Status <pass|fail|inconclusive> -Observed <string> [-Artifact <string>]` returning a validated record; `Invoke-MlsCollector -Name <string> -ScriptBlock <sb>` which runs a collector and validates every record it emits.

- [ ] **Step 1: Write the failing tests**

```powershell
Describe 'evidence records' {
    It 'stamps collectedAt and carries every required field' {
        $e = New-MlsEvidence -Control '3.5.3' -Source 'verification-suite' -Status 'fail' -Observed 'CA report-only'
        $e.control | Should -Be '3.5.3'
        $e.source | Should -Be 'verification-suite'
        $e.status | Should -Be 'fail'
        $e.observed | Should -Not -BeNullOrEmpty
        $e.collectedAt | Should -Match '^\d{4}-\d{2}-\d{2}T'
    }

    It 'rejects a status outside the contract' {
        { New-MlsEvidence -Control '3.5.3' -Source 's' -Status 'green' -Observed 'o' } | Should -Throw
    }

    It 'requires observed — the field that lets a reader judge the mapping' {
        { New-MlsEvidence -Control '3.5.3' -Source 's' -Status 'pass' -Observed '' } | Should -Throw
    }
}

Describe 'collector isolation' {
    It 'fails a collector that issues a mutating call' {
        # Collectors assess; they must not change what they assess.
        { Invoke-MlsCollector -Name 'bad' -ScriptBlock { az group create -n x -l y } } |
            Should -Throw '*read-only*'
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `pwsh -c "Invoke-Pester compliance/tests/collector-contract.Tests.ps1"`
Expected: FAIL.

- [ ] **Step 3: Implement**

`New-MlsEvidence` validates and stamps. `Invoke-MlsCollector` wraps execution in `MlsAudit.psm1`'s read-only transport guards — reuse them rather than reimplementing, so a collector inherits the same structural inability to mutate that the layer audits have.

- [ ] **Step 4: Verify**

Run: `pwsh -c "Invoke-Pester compliance/tests/"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add compliance/collectors/CollectorContract.psm1 compliance/tests/
git commit -m "feat(compliance): collector contract with read-only enforcement

Evidence records are validated and timestamped at construction, and
collectors run inside MlsAudit's read-only transport guards so a
collector is structurally incapable of mutating the estate it assesses."
```

---

## Task 5: `verification-suite` collector

**Files:**
- Create: `compliance/collectors/verification-suite.ps1`
- Test: `compliance/tests/collector-verification-suite.Tests.ps1`
- Fixture: `compliance/tests/fixtures/L03-report.json`

**Interfaces:**
- Consumes: Task 2's `Control` field, Task 4's contract.
- Produces: evidence records from committed layer-audit reports.

- [ ] **Step 1: Write the failing test**

```powershell
It 'turns a PASS criterion into pass evidence for each mapped control' {
    $evidence = & $collector -ReportRoot $fixtureRoot
    $row = $evidence | Where-Object { $_.control -eq '3.5.3' -and $_.criterion -eq 'V3.3' }
    $row.status | Should -Be 'fail'          # fixture has V3.3 FAIL
    $row.observed | Should -Match 'report-only'
    $row.artifact | Should -Match 'L03'
}

It 'emits nothing for criteria that map to no control' {
    $evidence = & $collector -ReportRoot $fixtureRoot
    $evidence | Where-Object { $_.criterion -eq 'V11.4' } | Should -BeNullOrEmpty
}

It 'emits inconclusive for SKIP and PENDING, never pass' {
    $evidence = & $collector -ReportRoot $fixtureRoot
    ($evidence | Where-Object { $_.criterion -eq 'V4.1' }).status | Should -Be 'inconclusive'
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `pwsh -c "Invoke-Pester compliance/tests/collector-verification-suite.Tests.ps1"`
Expected: FAIL.

- [ ] **Step 3: Implement**

Read each committed report under `verification/reports/`, map criterion status (`PASS`→`pass`, `FAIL`→`fail`, `SKIP`/`PENDING`→`inconclusive`), and emit one record per `(criterion, control)` pair with the report path as `artifact`.

**A SKIP is never a pass.** A skipped audit is an unverified control, and rendering it green is precisely the laundering this platform exists to prevent.

- [ ] **Step 4: Verify**

Run: `pwsh -c "Invoke-Pester compliance/tests/"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add compliance/collectors/verification-suite.ps1 compliance/tests/
git commit -m "feat(compliance): verification-suite collector

Turns committed layer-audit reports into evidence. SKIP and PENDING map
to inconclusive, never pass — a skipped audit is an unverified control."
```

---

## Task 6: `repo-static` collector

The one that works with no tenant, and therefore the one that makes the board demonstrable today.

**Files:**
- Create: `compliance/collectors/repo-static.ps1`
- Test: `compliance/tests/collector-repo-static.Tests.ps1`

**Interfaces:**
- Consumes: Task 4's contract.
- Produces: evidence from the working tree.

**Checks it performs**, each mapping to a control:

| Check | Control | Passes when |
|---|---|---|
| `diagnosticSettings` present in platform Bicep | `3.3.1` | ≥4 occurrences |
| SQL audit destination configured | `3.3.2` | `isAzureMonitorTargetEnabled` present |
| CodeQL workflow present and scheduled | `3.11.2` | `codeql.yml` has `schedule` |
| Dependabot config covers all ecosystems | `3.14.1` | `dependabot.yml` parses, ≥1 entry |
| Secret scanning workflow present | `3.13.16` | `gitleaks.yml` exists, full history |
| No secret-shaped Bicep outputs | `3.13.16` | no `output *ConnectionString\|Key\|Secret` |
| Containers run as non-root | `3.13.1` | every app Dockerfile has `USER` |
| Branch protection documented | `3.4.5` | ruleset config committed |

- [ ] **Step 1: Write the failing test**

```powershell
It 'reports a gap when the estate has no diagnostic settings' {
    $evidence = & $collector -RepoRoot $fixtureRepoWithout
    ($evidence | Where-Object control -eq '3.3.1').status | Should -Be 'fail'
}
It 'reports compliant once diagnostics are wired' {
    $evidence = & $collector -RepoRoot $fixtureRepoWith
    ($evidence | Where-Object control -eq '3.3.1').status | Should -Be 'pass'
}
It 'flags a frontend Dockerfile with no USER directive' {
    ($( & $collector -RepoRoot $fixtureRepoRootUser ) | Where-Object control -eq '3.13.1').status |
        Should -Be 'fail'
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `pwsh -c "Invoke-Pester compliance/tests/collector-repo-static.Tests.ps1"`
Expected: FAIL.

- [ ] **Step 3: Implement**

Each check is a small function returning one evidence record, with `observed` stating what was actually found ("0 diagnosticSettings across 3 Bicep templates") rather than a bare verdict.

- [ ] **Step 4: Verify**

Run: `pwsh -c "Invoke-Pester compliance/tests/"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add compliance/collectors/repo-static.ps1 compliance/tests/
git commit -m "feat(compliance): repo-static collector

Assesses what is checkable from the working tree with no tenant, which
is what makes the board demonstrable before G0 — and makes the
pre-deployment picture the baseline the post-deployment one improves on."
```

---

## Task 7: `github-security`, `azure-policy` and `manual` collectors

Grouped: same contract, same test shape, and a reviewer would accept or reject them together.

**Files:**
- Create: `compliance/collectors/github-security.ps1`, `azure-policy.ps1`, `manual.ps1`
- Test: `compliance/tests/collector-github.Tests.ps1`, `collector-azure-policy.Tests.ps1`, `collector-manual.Tests.ps1`
- Fixtures: mocked API responses under `compliance/tests/fixtures/`

**Interfaces:**
- Consumes: Task 4's contract.
- Produces: evidence from GHAS posture, Azure Policy compliance state, and authored assertions.

- [ ] **Step 1: Write the failing tests**

```powershell
# github-security
It 'reports secret scanning and push protection state' {
    $e = & $collector -Response $fixture
    ($e | Where-Object control -eq '3.13.16').status | Should -Be 'pass'
}
It 'reports a gap when Dependabot security updates are disabled' {
    $e = & $collector -Response $fixtureDisabled
    ($e | Where-Object control -eq '3.14.1').status | Should -Be 'fail'
}

# azure-policy
It 'maps a non-compliant policy assignment to its control' {
    ($( & $collector -Response $fixture ) | Where-Object control -eq '3.13.1').status | Should -Be 'fail'
}
It 'reports inconclusive when the initiative is in DoNotEnforce' {
    # An audit-mode initiative produces a scorecard, not a control. Rendering
    # its "compliant" rows as machine-verified compliance would be false.
    ($( & $collector -Response $fixtureAuditMode ) | Where-Object control -eq '3.13.1').status |
        Should -Be 'inconclusive'
}

# manual
It 'emits evidence only for assessments carrying an assertion' {
    $e = & $collector -AssessmentRoot $fixtureRoot
    $e | Where-Object control -eq '3.5.3' | Should -BeNullOrEmpty   # criteria-driven, no assertion
    $e | Where-Object control -eq '3.6.1' | Should -Not -BeNullOrEmpty
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `pwsh -c "Invoke-Pester compliance/tests/collector-*.Tests.ps1"`
Expected: FAIL.

- [ ] **Step 3: Implement**

All three take an injectable response/root parameter so tests never touch the network. The `azure-policy` collector's `DoNotEnforce` handling is the subtle one — an audit-mode initiative reports compliance it does not enforce, so its rows are `inconclusive`, never `pass`.

- [ ] **Step 4: Verify**

Run: `pwsh -c "Invoke-Pester compliance/tests/"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add compliance/collectors/ compliance/tests/
git commit -m "feat(compliance): github-security, azure-policy and manual collectors

All three take injectable inputs so tests never touch the network. An
Azure Policy initiative in DoNotEnforce yields inconclusive rather than
pass — an audit-mode scorecard is not an enforced control."
```

---

## Task 8: State emitter and the CI workflow

**Files:**
- Create: `compliance/Invoke-MlsCompliance.ps1` (runner)
- Create: `.github/workflows/compliance.yml`
- Test: `compliance/tests/state-emitter.Tests.ps1`, golden file `compliance/tests/fixtures/golden-state.json`

**Interfaces:**
- Consumes: Tasks 1, 3, 4-7.
- Produces: `compliance/state/state-<ISO-date>.json` and `state-latest.json` (a **copy**, not a symlink — authored on Windows, collected on Linux).

- [ ] **Step 1: Write the failing tests**

```powershell
It 'produces one entry for every one of the 110 requirements' {
    $state = & $runner -CatalogPath $catalog -AssessmentRoot $fx -OutputRoot $TestDrive -PassThru
    @($state.controls).Count | Should -Be 110
}
It 'stamps the commit it was collected at' {
    (& $runner @args -PassThru).commit | Should -Not -BeNullOrEmpty
}
It 'matches the golden state for a known fixture set' {
    $actual = & $runner -CatalogPath $catalog -AssessmentRoot $fx -OutputRoot $TestDrive -PassThru
    $golden = Get-Content $goldenPath -Raw | ConvertFrom-Json
    ($actual.controls | ConvertTo-Json -Depth 10) | Should -Be ($golden.controls | ConvertTo-Json -Depth 10)
}
It 'writes state-latest.json as a real file, not a link' {
    & $runner @args | Out-Null
    (Get-Item (Join-Path $TestDrive 'state-latest.json')).LinkType | Should -BeNullOrEmpty
}
It 'reports counts by status AND provenance, and no blended percentage' {
    $state = & $runner @args -PassThru
    $state.summary.byStatus | Should -Not -BeNullOrEmpty
    $state.summary.byProvenance | Should -Not -BeNullOrEmpty
    $state.summary.PSObject.Properties.Name | Should -Not -Contain 'percentCompliant'
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `pwsh -c "Invoke-Pester compliance/tests/state-emitter.Tests.ps1"`
Expected: FAIL.

- [ ] **Step 3: Implement**

The runner loads the catalog, loads every assessment, runs each collector, joins evidence to controls, calls `Get-MlsControlStatus` per requirement, and writes the artifact. Then `.github/workflows/compliance.yml` runs it on push to `main`, nightly, and on dispatch — committing the dated artifact.

The workflow needs `contents: write` to commit. Per the remediation plan's Task 5 lesson, it does **not** also run `npm ci` in that job: the install and the privileged commit are separate jobs.

- [ ] **Step 4: Verify**

Run: `pwsh -c "Invoke-Pester compliance/tests/"` and `actionlint .github/workflows/compliance.yml`
Expected: PASS, silent.

- [ ] **Step 5: Commit**

```bash
git add compliance/ .github/workflows/compliance.yml
git commit -m "feat(compliance): state emitter and collection workflow

Joins catalog, assessments and collected evidence into a dated artifact
committed on every run, so git log becomes the record of when the estate
became compliant and when it regressed. Summary reports counts by status
and provenance; there is deliberately no blended percentage."
```

---

## Task 9: App scaffold

**Files:**
- Create: `apps/compliance/` — `package.json`, `vite.config.ts`, `tsconfig.json`, `index.html`, `src/main.tsx`, `src/App.tsx`, `Dockerfile`, `nginx.conf.template`
- Modify: root `package.json` (workspaces)
- Test: `apps/compliance/tests/app.test.tsx`

**Interfaces:**
- Consumes: Task 8's state artifact.
- Produces: a workspace that builds, tests and serves.

- [ ] **Step 1: Write the failing test**

```tsx
it("renders the family summary from a state artifact", () => {
  render(<App state={fixtureState} catalog={fixtureCatalog} />);
  expect(screen.getByText(/Access Control/)).toBeInTheDocument();
});
it("never displays a blended compliance percentage", () => {
  const { container } = render(<App state={fixtureState} catalog={fixtureCatalog} />);
  expect(container.textContent).not.toMatch(/\d+%\s*compliant/i);
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd apps/compliance && npx vitest run`
Expected: FAIL — nothing exists.

- [ ] **Step 3: Implement**

Mirror `apps/control-tower`: React 18, Fluent UI v9, vite, vitest, multi-stage Dockerfile ending in nginx **with `USER nginx`** — the frontends that predate this run as root, and the newest app should not repeat that. Add the CSP and security headers from the remediation plan's Task 14 to `nginx.conf.template` from the start.

Add `apps/compliance` to the root `package.json` workspaces.

- [ ] **Step 4: Verify**

Run: `npm test` from the repo root.
Expected: exit 0 across 8 workspaces.

- [ ] **Step 5: Commit**

```bash
git add apps/compliance/ package.json package-lock.json
git commit -m "feat(compliance-app): scaffold

Mirrors control-tower's stack. Ships non-root and with a CSP from its
first commit rather than acquiring both in a later remediation."
```

---

## Task 10: The board

**Files:**
- Create: `apps/compliance/src/Board.tsx`, `FamilyCard.tsx`, `StatusBadge.tsx`, `ProvenanceBadge.tsx`
- Test: `apps/compliance/tests/board.test.tsx`

**Interfaces:**
- Consumes: state + catalog.
- Produces: `<Board state catalog framework />`.

- [ ] **Step 1: Write the failing tests**

```tsx
it("shows all 14 families with per-status counts", () => {
  render(<Board state={fixtureState} catalog={fixtureCatalog} framework="nist-800-171r2" />);
  expect(screen.getAllByTestId("family-card")).toHaveLength(14);
});

it("visually distinguishes machine-verified from asserted", () => {
  render(<Board state={fixtureState} catalog={fixtureCatalog} framework="nist-800-171r2" />);
  const verified = screen.getByTestId("control-3.5.3");
  const asserted = screen.getByTestId("control-3.6.1");
  expect(within(verified).getByTestId("provenance")).toHaveTextContent(/verified/i);
  expect(within(asserted).getByTestId("provenance")).toHaveTextContent(/asserted/i);
  // The distinction must not rely on colour alone.
  expect(within(asserted).getByTestId("provenance")).toHaveAttribute("aria-label");
});

it("renders NOT_ASSESSED distinctly from GAP", () => {
  render(<Board state={fixtureState} catalog={fixtureCatalog} framework="nist-800-171r2" />);
  expect(within(screen.getByTestId("control-3.7.1")).getByTestId("status"))
    .toHaveTextContent(/not assessed/i);
});

it("shows how fresh the evidence is", () => {
  render(<Board state={fixtureState} catalog={fixtureCatalog} framework="nist-800-171r2" />);
  expect(screen.getByTestId("collected-at")).toBeInTheDocument();
});
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd apps/compliance && npx vitest run tests/board.test.tsx`
Expected: FAIL.

- [ ] **Step 3: Implement**

Family cards with per-status counts; a control list per family. `NOT_ASSESSED` renders grey and distinct from `GAP` red — conflating "we did not look" with "we looked and failed" is the other way compliance boards mislead. Provenance is a badge with an `aria-label`, never colour alone.

- [ ] **Step 4: Verify**

Run: `cd apps/compliance && npm test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/compliance/
git commit -m "feat(compliance-app): the board

Fourteen family cards with per-status counts. NOT_ASSESSED renders
distinctly from GAP — conflating 'we did not look' with 'we looked and
failed' is how compliance boards mislead — and provenance is carried by
a labelled badge rather than colour alone."
```

---

## Task 11: Control detail and framework views

**Files:**
- Create: `apps/compliance/src/ControlDetail.tsx`, `FrameworkSwitcher.tsx`
- Test: `apps/compliance/tests/control-detail.test.tsx`, `framework-view.test.tsx`

- [ ] **Step 1: Write the failing tests**

```tsx
it("shows the criterion's actual command and observed value", () => {
  // Spec §6.1: mapping correctness is a human judgment, so the reader must be
  // able to see the raw evidence and judge it rather than trust the mapping.
  render(<ControlDetail control="3.5.3" state={fixtureState} catalog={fixtureCatalog} />);
  expect(screen.getByText(/GET \/v1\.0\/identity\/conditionalAccess/)).toBeInTheDocument();
  expect(screen.getByText(/enabledForReportingButNotEnforced/)).toBeInTheDocument();
});

it("shows the recommendation for a gap", () => {
  render(<ControlDetail control="3.5.3" state={fixtureState} catalog={fixtureCatalog} />);
  expect(screen.getByTestId("recommendation")).not.toBeEmptyDOMElement();
});

it("links evidence to its artifact", () => {
  render(<ControlDetail control="3.5.3" state={fixtureState} catalog={fixtureCatalog} />);
  expect(screen.getByRole("link", { name: /L03/ })).toHaveAttribute("href", expect.stringMatching(/^https?:\/\//));
});

it("relabels the same records under a CMMC view", () => {
  render(<Board state={fixtureState} catalog={fixtureCatalog} framework="cmmc-2.0" />);
  expect(screen.getByTestId("control-3.5.3")).toHaveTextContent("L2-3.5.3");
});

it("shows only the 17 L1 practices in the CMMC Level 1 view", () => {
  render(<Board state={fixtureState} catalog={fixtureCatalog} framework="far-52.204-21" />);
  expect(screen.getAllByTestId(/^control-/)).toHaveLength(17);
});
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd apps/compliance && npx vitest run`
Expected: FAIL.

- [ ] **Step 3: Implement**

Detail view renders status, provenance, every evidence record with its command and observed value, the recommendation, references, and the framework mappings. The switcher filters and relabels the same records — no second data source.

All evidence links go through the same `https?://` guard the remediation plan added to the Adaptive Card renderer; artifact paths render as repo-relative links.

- [ ] **Step 4: Verify**

Run: `cd apps/compliance && npm test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/compliance/
git commit -m "feat(compliance-app): control detail and framework views

Detail renders each criterion's actual command and observed value beside
the control, so a reader can judge the mapping rather than trust it.
Framework views filter and relabel the same assessment records — one
source of truth, no crosswalk state."
```

---

## Task 12: Trend view

**Files:**
- Create: `apps/compliance/src/Trend.tsx`
- Test: `apps/compliance/tests/trend.test.tsx`

- [ ] **Step 1: Write the failing test**

```tsx
it("plots status counts across committed state artifacts", () => {
  render(<Trend history={[stateAug20, stateAug26]} />);
  expect(screen.getByTestId("trend-chart")).toBeInTheDocument();
});
it("names the date a control regressed", () => {
  render(<Trend history={[stateAug20, stateAug26]} />);
  expect(screen.getByText(/3\.3\.1.*2026-08-26/)).toBeInTheDocument();
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd apps/compliance && npx vitest run tests/trend.test.tsx`
Expected: FAIL.

- [ ] **Step 3: Implement**

Read the bundled history, plot counts by status over time, and list transitions. This is the capability the committed-artifact design buys and most GRC tooling cannot offer.

- [ ] **Step 4: Verify**

Run: `cd apps/compliance && npm test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/compliance/
git commit -m "feat(compliance-app): compliance-over-time view

Plots status counts across committed state artifacts and names the date
each control changed. This is what the committed-artifact design buys."
```

---

## Task 13: Container app with Easy Auth

**Files:**
- Modify: `infra/bicep/apps/main.bicep`, `demo.bicepparam`, `infra/bicep/naming.bicep`
- Test: `verification/tests/compliance-app.Tests.ps1`

**Interfaces:**
- Consumes: Task 9's image.
- Produces: `mls-compliance-demo-ca`, external ingress, Easy Auth, `minReplicas: 0`.

- [ ] **Step 1: Write the failing test**

```powershell
It 'requires authentication on the compliance app' {
    $bicep = Get-Content 'infra/bicep/apps/main.bicep' -Raw
    $block = $bicep.Substring($bicep.IndexOf('module complianceApp'))
    $block | Should -Match 'authConfig'
    $block | Should -Match "unauthenticatedClientAction:\s*'RedirectToLoginPage'"
}
It 'scales to zero like its siblings' {
    ... | Should -Match 'scaleSettings: scaleToZero'
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `pwsh -c "Invoke-Pester verification/tests/compliance-app.Tests.ps1"`
Expected: FAIL.

- [ ] **Step 3: Implement**

Add `complianceApp` to `main.bicep` and `complianceName` to `naming.bicep` (`appKeys.compliance = 'compliance'`). Configure Container Apps built-in authentication with the Entra provider, `unauthenticatedClientAction: 'RedirectToLoginPage'`, and `requireAuthentication: true`.

No managed identity, no secrets, no RBAC grants — the app reads only baked-in files.

- [ ] **Step 4: Verify**

Run: `az bicep build --file infra/bicep/apps/main.bicep --stdout > /dev/null` and `pwsh -c "Invoke-Pester verification/"`
Expected: exit 0, PASS.

- [ ] **Step 5: Commit**

```bash
git add infra/bicep/ verification/tests/
git commit -m "infra(L7): compliance container app behind Easy Auth

Platform authentication with Entra rather than an application gate — a
static SPA has nowhere to keep a secret. No identity, no secrets, no RBAC
grants: the app reads only baked-in files."
```

---

## Task 14: `query_compliance` MCP tool

**Files:**
- Create: `apps/mcp-tools/src/tools/compliance.ts`
- Modify: `apps/mcp-tools/src/tools/index.ts`, `backends.ts`
- Test: `apps/mcp-tools/tests/compliance-tool.test.ts`

**Interfaces:**
- Consumes: Task 8's state artifact (baked into the mcp-tools image).
- Produces: `query_compliance(control?, family?, framework?, status?)`.

- [ ] **Step 1: Write the failing tests**

```typescript
it("returns a single control with its evidence and recommendation", async () => {
  const r = await registry.call("query_compliance", { control: "3.5.3" });
  expect(r.controls[0].status).toBe("GAP");
  expect(r.controls[0].provenance).toBe("machine-verified");
  expect(r.controls[0].recommendation).toBeTruthy();
});

it("filters by status across the whole catalog", async () => {
  const r = await registry.call("query_compliance", { status: "GAP" });
  expect(r.controls.every((c) => c.status === "GAP")).toBe(true);
});

it("agrees with the board for every control", async () => {
  // Parity: one source of truth. If these ever diverge, one of them is lying.
  for (const c of fixtureState.controls) {
    const r = await registry.call("query_compliance", { control: c.control });
    expect(r.controls[0].status).toBe(c.status);
    expect(r.controls[0].provenance).toBe(c.provenance);
  }
});

it("never invents a recommendation", async () => {
  const r = await registry.call("query_compliance", { control: "3.9.1" });
  expect(r.controls[0].recommendation ?? null).toBe(fixtureAssessment["3.9.1"]?.recommendation ?? null);
});
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd apps/mcp-tools && npx vitest run tests/compliance-tool.test.ts`
Expected: FAIL.

- [ ] **Step 3: Implement**

A backend reading the bundled artifact, registered like the other five tools. The tool description tells the agent it returns *authored* recommendations and must not extrapolate — the guard against confident wrong compliance advice.

Update the `/healthz` tool count from 5 to 6 and the assertions that pin it.

- [ ] **Step 4: Verify**

Run: `cd apps/mcp-tools && npm test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/mcp-tools/
git commit -m "feat(mcp-tools): query_compliance tool

Lets the Ask tab answer compliance questions from the same artifact the
board renders. A parity test asserts tool and board never disagree, and
the tool returns only authored recommendations."
```

---

## Task 15: App CI and deployment

**Files:**
- Create: `.github/workflows/app-compliance-ci.yml`
- Modify: `.github/workflows/layer-07-apps.yml`

- [ ] **Step 1: Author the workflow**

Copy `app-control-tower-ci.yml`'s structure, including both fork guards from the remediation work: `preflight` gets the head-repo check and `deploy` gets `github.event_name != 'pull_request'`. Split `npm ci` out of any job holding `id-token: write` or `packages: write`.

The build step bakes the catalog, `state-latest.json` and the history directory into the bundle.

- [ ] **Step 2: Verify**

Run: `actionlint .github/workflows/app-compliance-ci.yml`
Expected: no output.

- [ ] **Step 3: Confirm the guards**

```bash
grep -n "head.repo.full_name\|event_name != 'pull_request'" .github/workflows/app-compliance-ci.yml
```
Expected: both present.

- [ ] **Step 4: Run the full suite**

Run: `npm test && pwsh -c "Invoke-Pester compliance/ verification/"`
Expected: green.

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/
git commit -m "ci(compliance-app): build, scan and deploy

Carries both fork guards from the outset, and keeps npm ci out of any
job holding a privileged token."
```

---

## Task 16: Full verification and documentation

**Files:**
- Modify: `README.md`, `docs/BRIEF.md`, `docs/runbooks/demo-script.md`
- Create: `docs/runbooks/layers/L12.md`

- [ ] **Step 1: Run every gate**

```bash
pwsh -c "Invoke-Pester scripts/,infra/,data/,verification/,compliance/"
pwsh -c "Get-ChildItem -Path scripts,infra,verification,data,compliance,.github -Recurse -Include *.ps1,*.psm1 |
         ForEach-Object { Invoke-ScriptAnalyzer -Path \$_.FullName -Severity Error,Warning }"
npm test
cd data/generators && python -m pytest -q && cd ../..
for f in infra/bicep/*/main.bicep; do az bicep build --file "$f" --stdout > /dev/null || echo "FAIL $f"; done
actionlint .github/workflows/*.yml
```

Expected: all green; PSScriptAnalyzer 0.

- [ ] **Step 2: Verify the platform against itself**

Run the collectors over the real repo and confirm the board reports the *actual* posture — including every gap the remediation plan has not yet closed. A board that shows all green at this point is a bug, not a success.

- [ ] **Step 3: Write the layer playbook**

`docs/runbooks/layers/L12.md` following the L01-L11 pattern: purpose, preconditions, deploy procedure, validation cycle with named criteria, teardown, failure modes.

- [ ] **Step 4: Update the narrative docs**

README gains the compliance platform as showpiece #4 — or, if it displaces one, say which and why. `demo-script.md` gains the segment: open on the honest board, drill into a gap, ask the agent about it, show the trend.

- [ ] **Step 5: Commit**

```bash
git add compliance/ apps/ docs/ README.md
git commit -m "verify: compliance platform green end to end

All gates replayed. The board reports the estate's real posture,
including gaps the remediation plan has not yet closed — an all-green
board at this stage would be a defect."
```

---

## Self-Review

**Spec coverage.** §3.1 catalog → T1. §3.2 assessment schema → consumed from remediation T1; validated in T3. §3.3 state → T8. §3.4 derivation → T3. §4 collectors → T4-T7. §4.2 `-Control` → T2. §4.3 pre-tenant behaviour → T6. §5.1 static SPA → T9-T12. §5.2 Easy Auth → T13. §5.3 MCP tool → T14. §6 testing → distributed through every task; §6.1's transparency requirement → T11's command/observed test. §7 out-of-scope items appear nowhere, correctly.

**Type consistency.** `Get-MlsControlStatus` returns `@{ Status; Provenance; Observed }` in T3 and is consumed with those names in T8. `New-MlsEvidence` produces lowercase JSON fields (`control`, `source`, `status`, `observed`, `collectedAt`, `artifact`) in T4, consumed identically in T5-T8 and rendered in T11. Framework keys are `nist-800-171r2`, `nist-800-53r5`, `cmmc-2.0`, `far-52.204-21` in T1 and used verbatim in T11's switcher.

**Placeholder scan.** T13's second test elides an assertion body with `...`; the executor should mirror the first test's structure. Every other step carries runnable content.

**Dependency on the remediation plan.** T1-T3 need nothing from it. T5 needs Task 2's `-Control` annotations, which are in this plan. T6's `repo-static` checks will *fail* until remediation closes the corresponding findings — that is intended and is what makes the before/after narrative real. Only remediation Task 1 (the register) is a hard prerequisite, and only from T7's `manual` collector onward.
