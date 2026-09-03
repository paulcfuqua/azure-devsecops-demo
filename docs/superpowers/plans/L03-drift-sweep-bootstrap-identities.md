# L3 — the drift sweep, bootstrap identities, and the fused retry window

Layer L3 (Identity & Governance). Fixes the blocker that stopped the 2026-09-03 rebuild at
`verify L3 (mls-verifier)`, plus two defects on the same line and in the same criterion.

## The failure

```
[FAIL   ] V3.1  observed: users 5/5; groups 7/7; appRegistrations 4/4
                | drift - mls-prefixed app registrations absent from the manifest: mls-purview
```

Every declared object resolved. The only problem is the drift sweep, which found a real
`mls`-prefixed app registration that `infra/entra/manifest.json` does not declare.

## Three defects, one criterion

### D1 — `mls-purview` is a bootstrap identity that nothing declares

`docs/runbooks/g0-bootstrap.md` step 11c creates it by hand:

    az ad app create --display-name mls-purview --sign-in-audience AzureADMyOrg

with an `openssl`-minted X.509 certificate, `Exchange.ManageAsApp` granted directly via
Graph, and membership of **Compliance Administrator**. It exists because Security &
Compliance PowerShell has no federated path (CLAUDE.md hard rule 5), and L4 cannot apply
the label taxonomy without it. It is legitimate, and it is the same class of object as
`mls-github-deployer` and `mls-verifier` — created at G0, by a human, out of band.

**It has never been declared anywhere a check can read.**

### D2 — the exemption list hardcodes the company prefix

`verification/layer-03-audit.ps1:122`

    $_ -notin @('mls-github-deployer', 'mls-verifier')

Two literals in a file that resolves `${prefix}` correctly everywhere else, including in
the drift messages emitted two lines below. This is F90's class: a rebrand reaches Azure
and leaves identity behind. After `MLS_COMPANY_PREFIX=acme`, the sweep would look for
`acme`-prefixed apps, find `acme-github-deployer` and `acme-verifier`, match neither
literal, and V3.1 would fail permanently on a correct estate.

### D3 — the drift sweep inherits a propagation window it can never use

V3.1 fuses two questions under one 45-minute retry window:

1. *Do the manifest's declared objects exist yet?* — legitimately propagation-sensitive.
2. *Is there an undeclared prefixed registration?* — settled at the first poll.

**Propagation makes a declared object appear LATE. It cannot make an EXTRA object
disappear.** So the drift half's verdict cannot change by waiting. The 2026-09-03 run
burned **45.9 minutes** of a critical path whose headline claim is a sub-60-minute
kill/rebuild cycle, re-asking a question answered at minute zero — while the counts half
had already reported `5/5; 7/7; 4/4`.

## Decision: declare, do not exempt-by-literal

The question posed was (a) declare `mls-purview` in `manifest.json`, or (b) add it to the
audit's exemption list. **Both, in the sense that matters: it is declared in the manifest,
in a key that L3 does not apply, and the audit derives its exemption from that key.**

### Why not (a) as posed — `appRegistrations`

`infra/entra/apply-entra.ps1:1292` iterates `appRegistrations` and, for every entry, calls
`Initialize-EntraApplication` (create-if-absent) and then `Initialize-EntraServicePrincipal`.
Declaring `mls-purview` there would mean:

* On a tenant where it exists, `mls-github-deployer` — which holds
  `Application.ReadWrite.OwnedBy`, covering only registrations **it** created — attempts to
  update a registration it does not own. That is a 403 in the middle of L3.
* On a tenant where it does not (a fresh clone, or after a G3 teardown), L3 **creates an
  impostor**: an `mls-purview` with no certificate, no `Exchange.ManageAsApp`, and no
  Compliance Administrator role, while `PURVIEW_APP_ID` still names the old GUID. L4 would
  then hold a registration that looks declared and can do nothing — and **V3.1 would go
  green on it**, because a registration resolving to exactly one object is all it asserts.

That last line is the deciding one. It is this repository's most expensive shape: asserting
the artefact (a registration exists) where the control is the capability (an identity that
can actually authenticate to Security & Compliance).

### Why not (b) as posed — a second literal list

An exemption list inside the audit is a second source of truth for "which identities this
estate has", sitting in the one file whose job is to have no independent knowledge. It is
also where D2 came from. Adding a third literal to a two-literal list fixes today and
guarantees the next G0 identity fails the same way.

### What is done instead

A new manifest key, `bootstrapAppRegistrations`, tokenised `${prefix}` like everything else:

* **`apply-entra.ps1` never touches it.** It iterates `appRegistrations` only. A schema
  assertion makes that explicit and forbids a name appearing in both arrays — an identity
  that is both L3-managed and externally managed is exactly how the impostor above gets
  created.
* **The audit derives its drift exemption from it.** No literals, prefix resolved from
  `naming.bicep` / `MLS_COMPANY_PREFIX` exactly as the rest of the manifest is.
* **The sweep keeps its teeth.** The exemption is a per-name declaration in a reviewed,
  committed file — not a pattern. `mls-evil-app` still fails. `mls-purview-2` still fails.
  Adding a bootstrap identity remains a deliberate act with a diff.
* **The audit reports what it saw.** The observed line names which bootstrap identities
  were present, so the report distinguishes *exempt and present* from *exempt and absent* —
  today an absent `mls-verifier` is invisible to V3.1, because it is in nobody's expected
  set.

Absence of a bootstrap identity is reported, not failed: `layer-04-purview.yml` documents a
degrade path where `PURVIEW_APP_ID` is unset and L4 runs under a human login (F43), and a
clone that has not run G0 step 11c is that case, not drift.

### D3 — `-Final` on the drift verdict

`New-MlsCheckResult -Final` already exists and already means this: `MlsAudit.psm1:1536`
breaks the retry loop on it, and `Test-ConditionalAccessState` uses it two hundred lines
below for the same reason ("wrong state or scope is not a propagation artifact"). When the
sweep finds an extra object, V3.1 cannot become PASS by waiting, so it returns `-Final` and
fails in seconds. A short count with no drift retries the full window, unchanged.

No new criterion id: V3.1's identity, control mapping (3.1.1, 3.5.1) and acceptance
criterion in the master plan all stay as they are.

## Work

1. `infra/entra/manifest.json` — add `bootstrapAppRegistrations` with the three G0
   identities, each carrying `createdBy` and `notes` naming the runbook step.
2. `infra/entra/apply-entra.ps1` — validate the new key in `Assert-ManifestSchema`; assert
   disjointness from `appRegistrations`.
3. `verification/layer-03-audit.ps1` — derive the exemption; report presence; `-Final` on
   drift.
4. `verification/tests/layer-03-audit.Tests.ps1` — drift still fails on an undeclared app;
   a bootstrap identity does not; drift does not consume the retry window; absence is
   reported not failed.
5. `verification/tests/failure-classes.Tests.ps1` — repo-wide sweep for the hardcoded
   company prefix in the verification and deploy path (D2's class).
6. Docs: L03 runbook, g0-bootstrap step 11c, and a register entry.

## Not in scope

* Deleting or recreating any Entra object (G3).
* Applying anything to the tenant by hand — a fix a rebuild does not reproduce is not one.
* `scripts/bootstrap/01-root-oidc.ps1`'s `'mls-github-deployer'` parameter *defaults*.
  They are overridable inputs to a human-run G0 script, not a check's private knowledge,
  and changing them is a G0 change on the critical path of a running rebuild. Recorded in
  the register instead.
