# @mls/vuln-lab

> ## ⚠️ This package is deliberately vulnerable. It is NEVER imported by any deployed app.
>
> Nothing in `launch-ops`, `control-tower`, or `copilot-svc` may depend on
> `@mls/vuln-lab`, and it is not built into any container image. It exists only
> to hold known-vulnerable dependency **pins** so the L10 self-healing pipeline
> has real alerts to heal. A `require`/`import` of this package from an app is a
> bug — remove it.

## Purpose — showpiece #3 seed (L10)

The self-healing loop is the demo's third showpiece: **Dependabot alert → Claude
triage comment → patch PR → CI gauntlet (CodeQL, tests, Trivy, ZAP) → auto-merge
on green → deploy → alert closed**. That loop needs something real to heal. This
lab is that seed.

It contains **vulnerable dependencies, not exploit code** (spec F5). The three
pins are chosen so that each one:

1. carries a real published advisory that Dependabot and `npm audit` detect;
2. has a patched version available, so the heal has a clean upgrade path; and
3. is fixable **without a major-version bump**, so the patch PR lands green
   instead of breaking the build (L10 failure mode 4).

## The three seeded advisories

| Package | Pinned (vulnerable) | Advisory | CVE | Severity | First patched |
| --- | --- | --- | --- | --- | --- |
| `json5` | `2.2.0` | [GHSA-9c47-m6qq-7p4h](https://github.com/advisories/GHSA-9c47-m6qq-7p4h) — Prototype Pollution via `parse` | CVE-2022-46175 | high | `2.2.2` |
| `minimist` | `1.2.5` | [GHSA-xvch-5gv4-984h](https://github.com/advisories/GHSA-xvch-5gv4-984h) — Prototype Pollution | CVE-2021-44906 | critical | `1.2.6` |
| `semver` | `7.5.1` | [GHSA-c2qf-rxjj-qqgw](https://github.com/advisories/GHSA-c2qf-rxjj-qqgw) — Regular Expression Denial of Service | CVE-2022-25883 | high | `7.5.2` |

All three are zero-/light-dependency packages, so the audit surface is exactly
these three advisories and nothing else — the demo's alert count is stable and
explainable rather than drifting with transitive churn.

Verify:

```sh
cd apps/vuln-lab
npm install
npm audit          # 3 vulnerabilities (2 high, 1 critical)
```

Upgrading all three to their patched versions yields `found 0 vulnerabilities` —
that is the state a completed heal cycle leaves behind.

## `index.js` — trivial requires only

`index.js` requires each package and calls one harmless API on it with in-repo
literals (`JSON5.parse('{ ok: true }')`, `minimist(["--seeded","true"])`,
`semver.gt("1.2.3","1.2.2")`). **No vulnerable code path is executed**: no
untrusted input, no `process.argv`, no network data reaches any of them. The
requires exist so the dependencies are genuinely used — the manifest stays
honest and the upgrade PR has something to build and test against.

```sh
npm test   # node index.js — prints a status object, exit 0
```

## Re-arming after a heal — `reseed.ps1`

A successful heal cycle upgrades the pins and closes the alerts, which disarms
the lab. `reseed.ps1` (pwsh 7) restores it:

```powershell
pwsh apps/vuln-lab/reseed.ps1            # restore pins + lockfile, verify alerts
pwsh apps/vuln-lab/reseed.ps1 -WhatIf    # show what would change
pwsh apps/vuln-lab/reseed.ps1 -SkipAudit # offline: skip the verification step
```

It (1) rewrites the dependency block to the vulnerable pins, (2) regenerates
`package-lock.json` from them via `npm install --package-lock-only` (no packages
downloaded), and (3) verifies with `npm audit` that all three advisories are back,
throwing if any is missing — a silently-unarmed lab would waste an L10 audit
attempt.

The script **never commits or pushes**. Per CLAUDE.md the restored pins reach
`main` through a normal PR, and it is that merge which re-raises the Dependabot
alerts. The L10 playbook references this script at `apps/vuln-lab/reseed.ps1`.

## Notes

- Teardown for L10 means *re-arming*, not deleting (master plan §L10) — hence a
  re-seed script rather than a cleanup script.
- Because the pins are exact (not `^`-ranged), `npm audit fix` reports the fix as
  "outside the stated dependency range". That is intentional: the heal must come
  from the pipeline's patch PR, not from a local `audit fix`.
