# Design: operationalise self-healing — remove the plants, automate three lanes

> **DESIGN RECORD.** What was designed and why, kept as the reasoning behind the system
> rather than a description of it. For what the estate does today read
> [DEMO-READINESS.md](../../DEMO-READINESS.md); for the findings behind this design read
> [findings/2026-09-04-finding-register.md](../../findings/2026-09-04-finding-register.md).

**Date:** 2026-09-05 · **Status:** sponsor-approved design, pending implementation plan
**Affects:** `.github/workflows/self-heal.yml`, `verification/layer-10-audit.ps1`,
`infra/bicep/` (a new ACR and the apps' pull identity), `apps/control-tower` (trail view,
window display), `docs/runbooks/layers/L10.md`
**Supersedes:** L10's seeded-alert model. V10.1 and V10.2 change meaning; see §6.
**G2:** approved 2026-09-05 — ACR Basic, `centralus`, **USD 0.1666/day (~USD 3.33 over the
remaining ~20-day window)**, from the Azure retail price API rather than from memory.

---

## 1. Purpose

The demo proved the self-healing chain closes a loop: on 2026-09-04 Copilot Autofix wrote a
fix for a seeded flaw, the gauntlet passed, the chain merged it unattended, and the alert
closed 71 seconds later. That is worth having proved. It is not an operations cycle.

**The operations cycle is: no findings; one arrives; it is healed; back to no findings.**
This design gets there by removing the thing standing in the way — a deliberately planted
CVE that the verification depended on — and by automating all three classes of finding this
estate actually produces, rather than the one class the plant was built to exercise.

The deliverable is **traceability at scale**: what came in, what resolved it, where it
landed, and when — for every finding, continuously, with a machine that independently
confirms the record rather than a record that asserts itself.

### Why the plant has to go

`apps/vuln-lab` holds deliberately unpatched CVEs and two seeded code flaws. It exists
because V10.1's deploy stage reads `mls-vuln-lab-demo-ca`, a placeholder container rolled
only by pushes touching `apps/vuln-lab/**`. So the criterion can be satisfied *only* by a
heal in the lab, which means the lab must always contain something to heal, which means
re-arming, which is **F190** — a pull request that reintroduces a critical alert and
therefore cannot merge past code scanning merge protection without an administrator
override.

The whole apparatus — seeded CVEs, `reseed.ps1`, the `--admin` override, F190 — exists to
feed one hard-coded path filter.

**PR #225 is the proof.** Copilot Autofix wrote a correct fix for a *real* alert in
`apps/mcp-tools`, the gauntlet passed, the chain merged it unattended — and V10.1 still
could not complete a trail, because the wrong application deployed.

L10.md concedes the limitation in its own words:

> *"What it does **not** prove is that the healed code runs somewhere; nothing can prove
> that about a package deliberately never deployed."*

Heal a real alert in a real app and that limitation disappears. `apps/mcp-tools` and
`apps/data-api` **are** built and deployed. The criterion moves from *"a placeholder
rolled"* to *"the healed code is running"*. **Removing the plant does not weaken the
verification; it is the only way the verification can mean what it claims.**

---

## 2. Three lanes, three different shapes

The estate produces three classes of finding. They are not variations on one mechanism, and
designing them as if they were is what produced the current bottleneck.

| Lane | Fix author | Trigger | Output | What we build |
|---|---|---|---|---|
| **1. Source flaws** | GitHub Copilot Autofix | CodeQL alert | pull request | request the fix, open the PR, adopt |
| **2. Dependencies** | Dependabot | security advisory | pull request | **adopt only** — Dependabot authors it |
| **3. Base images** | upstream, already published | base image updated | **an image** | **configuration only** — ACR Tasks |

Lanes 1 and 2 produce commits. **Lane 3 produces an artifact**: there is nothing to merge,
because nothing in the repository changes.

### Why lane 3 is not a Dependabot problem

Investigated 2026-09-05. `dependabot.yml` already configures `package-ecosystem: docker`
for all five application directories, and has opened **zero** pull requests, ever. The
reason is not a misconfiguration:

The Dockerfiles use **floating tags** — `nginx:1.31-alpine`, `node:24-alpine`,
`node:24-bookworm-slim`. Dependabot's docker ecosystem bumps *tags* (`1.31` → `1.32`). The
open findings are Alpine OS packages **inside** the image:

```
Package: libexpat
Installed Version: 2.8.2-r0
Vulnerability CVE-2026-76957
Fixed Version: 2.8.4-r0
```

Their fix ships when upstream **rebuilds the same tag**. No version string under our control
ever changes, so Dependabot correctly opens nothing. Of 37 open Trivy findings, 24 are OS
packages in the `launch-ops` image and 9 are npm's own bundled dependencies inside the Node
base image — 33 of 37 are fixed by a rebuild, not by a version bump. The remaining 4 are
`qs`, which Dependabot has already opened pull requests for.

**The correct mechanism is Azure Container Registry Tasks with base-image update triggers**
— first-party, purpose-built, and it watches the base and rebuilds when upstream publishes.
It replaces staleness heuristics we would otherwise invent.

### Lane 3 is self-verifying

The lane does not predict whether a rebuild helps. It rebuilds, re-scans, and compares:
fewer findings → deploy; same or worse → do not deploy, and report why. There is nothing to
revert because nothing merged. This is *test, deploy if pass, hold if fail* with no custom
machinery.

---

## 3. Release gating: the change window

**Detection and preparation run continuously. Release is gated.**

A fix is authored, built and proven green long before it is released — which is what change
control actually wants, and what a nightly-patching policy assumes.

| | Default | Configurable |
|---|---|---|
| Days | every day | each day toggled on/off |
| Start | 00:00 | yes |
| End | runs to completion | no — **shown as a projection** from the last five runs |

- **Lanes 1–2**: the pull request is prepared and green; **auto-merge is armed only inside
  the window**
- **Lane 3**: the rebuilt image deploys to a **0%-traffic revision** immediately; traffic
  shifts inside the window

### Where the configuration lives

**In git**, read by the workflow and *displayed* by the control tower. Not written by it.

The control tower is deliberately read-only: `data-api` holds Security Reader, both
frontends proxy straight through to it, and criteria depend on that property. More
importantly, a change window is a governance control — **the thing that makes it
trustworthy is that nobody can quietly widen it.** Git gives the audit trail (who widened
the patch window, when, in which pull request) for free.

The control tower renders the schedule, the next window, and the projection on the **Ops**
tab; the heal trail lives on **Sec**.

*Deferred, not rejected:* a "propose change" button that opens a pre-filled pull request.
Keeps the audit trail, removes the friction. Build it when the friction is real.

---

## 4. The trail: derived, never stored

**There is exactly one source of truth per fact, and no copy.** Two records of the same
compliance event that can disagree is an audit liability, not a feature.

```
GitHub alerts            what came in (created_at), what closed (fixed_at)
      │
      │  join: branch name  self-heal/<kind>-<alert-id>-*  +  label `self-heal`
      ▼
GitHub pull requests     what resolved it, merge commit, merged_at
      │
      │  join: MLS_HEAL_COMMIT / revision provenance
      ▼
Azure Container Apps     where it landed, when the revision was created
```

Verified against real data before this was designed:

```
alert #9  created 2026-08-28T23:52:35Z
          → PR #225  (self-heal/code-scanning-9-autofix)
          → merged   2026-09-04T12:26:51Z, commit 7eb75cee
          → alert fixed 2026-09-04T12:27:59Z
```

**A property that falls out for free:** an alert closed with *no* matching self-heal pull
request is visibly **not** automation — a human fix, or a dismissal. The view reports that
honestly rather than implying the chain closed everything.

### Four states

| State | Meaning |
|---|---|
| `healed` | closed, with a complete trail |
| `in-flight` | fix authored, not yet released |
| `pending-solution` | **no upstream fix exists** — holds and ages; not a failure |
| `not-automatable` | no automated path exists for this class |

---

## 5. Service levels

Per source and per severity. **Never averaged into one number** — a blended figure hides
the slice that is not moving, which is the failure the compliance platform was built to
avoid.

| Severity | SLO |
|---|---|
| critical / high | 7 days |
| medium / low | 30 days |

Configurable. The window is **declared** in configuration, not inherited from a default —
this repository has twice been bitten by criteria silently adopting a timeout nobody chose.

---

## 6. What the criteria assert

The current V10.1 and V10.2 verify one *seeded* alert's seven-stage trail. That framing dies
with the plant. The **stages survive** — they carry the governance weight — but they apply
**per healed finding** instead of to a pre-named one.

**V10.1 — the backlog drains, per source.** No *healable* finding remains open past its SLO.
Reported per lane and per severity.

**V10.2 — every closure is traceable.** For each alert closed since the last audit, either a
self-heal pull request explains it with a complete trail — authored by Autofix or
Dependabot, gauntlet green, merge pre-authorised (`Test-MergeProvenance`, F191), the
affected application's revision carries the merge commit, alert state `fixed`, timestamps
monotonic — **or** it is explicitly recorded as closed by other means. An unexplained
closure fails.

**V10.3 — the alert surface was readable.** Unchanged. F123's guard: a denial must never
read as "nothing to heal".

**V10.4 — `pending-solution` is not a dumping ground.** For every finding in that state,
verify that **no upstream fix actually exists**. This state legitimately does not count as
failure, which makes it the obvious place for a backlog to go and die quietly. An unverified
"no fix available" is the artefact-instead-of-capability trap this repository keeps paying
for.

### The deploy stage, rewritten

Old: *did the vuln-lab witness roll?*
New: **did the application this heal actually changed receive a revision carrying the merge
commit?**

```
PR changed files → apps/<name>/** → naming.bicep appKeys → mls-<key>-demo-ca → revision
```

Two cases reported rather than failed:

- a heal touching a path with **no deployed application** (`verification/`, `docs/`) — no
  deploy assertion is possible; say so
- a heal touching **several** applications — all of them must roll

---

## 7. What happens to the vuln-lab

`apps/vuln-lab`, `apps/vuln-lab/reseed.ps1` and `.github/workflows/vuln-lab-witness.yml`
**stay in the repository** and stop being load-bearing.

They become a **manual demonstration generator**: a deliberate way to arm a finding when the
queue is empty, when demonstrating the chain to an audience, or when testing a change to the
pipeline itself. No criterion depends on them.

**F190 dissolves.** Re-arming becomes a rare, deliberate act that a human authorises with
`--admin` and a stated reason — which is the right posture for reintroducing a critical
vulnerability — rather than something the verification requires every cycle.

**This also answers a question the new model raises:** with the plants gone, a quiet week
means nothing is healed, V10.2 has nothing recent to verify, and the chain could rot
unnoticed. A deliberate arm is how the chain is exercised on a quiet week. That is an
operation, and it is documented as one rather than left as folklore.

---

## 8. Preconditions — verified before implementation, not after

Two things this design rests on that have **not** been verified. Neither is a risk to manage;
both are facts to establish first.

**P1 — ACR Tasks must be able to track a Docker Hub base image.** The bases are
`nginx:1.31-alpine` and `node:24-*`, not in ACR. Tasks support external base images, but
this has not been confirmed at the Basic tier for our sources. **Lane 3 rests entirely on
it.** If it fails, lane 3 falls back to a scheduled rebuild against the existing GHCR
images, and this document is amended to say so.

**P2 — where ACR lives must not be inside the teardown set.** `infra-down.yml` deletes four
resource groups by name. An ACR inside them is destroyed by a teardown, and the rebuild then
cannot proceed: the applications would pull from a registry that only exists *after* the
estate exists.

**This is BLOCKER-E's exact shape, already paid for once** —
`02-fabric-capacity.ps1` defaulted the Fabric capacity into `<prefix>-rg-platform`, so an
ordinary teardown destroyed it and stranded the workspace. That was found the hard way. It
costs nothing to get right now and is expensive to discover during a teardown weeks from
now.

---

## 9. Scope

### In scope

- ACR (Basic, outside the teardown set) and ACR Tasks with base-image triggers
- Container Apps revision strategy: deploy at 0% traffic, shift by weight
- Three lanes automated. Lane 1 stays serial — Copilot Autofix is per-alert and documented
  as non-deterministic, so one fix is requested per run. Lanes 2 and 3 are adoption, not
  authorship, and batch: **adopt at most 10 eligible pull requests per lane per run**, a
  configurable cap whose purpose is to stop a bad day merging thirty changes at once. Ten
  is a starting value, not a measured one; raise it once a run has been observed.
- Change window in git, gating release; displayed on the Ops tab
- The derived trail, displayed on the Sec tab
- **V10.1, V10.2, V10.3, V10.4**
- L10 playbook rewritten; the seeded-alert model retired

### Documented as the framework, built when conditions demand

Recorded here so the reasoning is not lost, and deliberately **not** built now. The goal is
three working lanes, not a system hardened against every hypothetical.

- **Runtime rollback.** Revision traffic-shifting is the primitive and this design turns it
  on; *automating* rollback on runtime failure is project 2.
- **Freeze breaching an SLO.** A multi-day freeze can blow the 7-day critical SLO. The clock
  keeps running; surfacing "at risk because of freeze" is a display concern for later.
- **Emergency out-of-window release.** `--admin` with a logged reason already works, as used
  for #230.
- **V10.5 — auditing that releases stayed in-window.** The window functions without it; the
  machine verification of it is the next increment.

### Explicitly not this project

- **Demo → production hardening.** Its own spec.
- **The customisation audit** — every custom mechanism in this repository mapped against the
  first-party feature that should replace it. Three entries exist already: F193
  (hand-rolled push and PR creation versus `create-pull-request`, whose documentation
  describes the exact failure that cost nine days), lane 3 (custom rebuild scheduling versus
  ACR Tasks), and rollback (custom versus Container Apps revisions). That audit is the
  backbone of the production-hardening plan and should precede it.

---

## 10. Why this is worth doing

The current chain proves a loop can close. It cannot say anything about an estate's security
posture, because its only subject is a vulnerability we planted for it to find.

After this, the claim is one an auditor can use: **every finding this estate produces is
tracked from arrival to resolution to deployment, most of them are fixed without a human,
the ones that are not are visibly and verifiably waiting on an upstream fix, and releases
happen inside a change window somebody approved in a reviewable pull request.**

That is a different and much stronger statement than "watch it heal the thing we planted".
