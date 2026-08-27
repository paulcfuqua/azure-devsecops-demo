# Auto-label policy design — `mls-operations` (design-only, not implemented)

> **Status: documented only.** No script in this repo applies any part of this design.
> `infra/purview/labels.ps1` has no auto-labeling function, no runtime entitlement
> check, and no call into any auto-label cmdlet. This file exists because
> `docs/runbooks/layers/L04.md` names it, and a finding (F18, closed by Task 20 —
> see `compliance/findings/2026-08-26-prepublication-review.md#f18` and
> `compliance/assessment/CM-6.json`) confirmed that L04.md previously claimed this
> design was *applied by the same script* that publishes the static label policy.
> That claim was corrected, not implemented — see "Why this stays design-only" below.

## What this would do, if built

Auto-label the `mls-operations` Fabric lakehouse workspace (launch telemetry
summaries, supplier pricing, incident findings) with the same four-label taxonomy
`labels.ps1` creates — `Public` / `Internal` / `Confidential` / `Export-Controlled` —
so that content matching a sensitivity pattern picks up the right label without a
human applying it by hand. Candidate triggers, sketched only (none of this is
tuned, tested, or normative):

| Content pattern (illustrative) | Target label |
|---|---|
| Supplier pricing / cost figures, incident findings | `Confidential` |
| Launch dates, vehicle names, published mission facts | `Public` (default floor) |
| Everything else in the workspace | `Internal` (default) |
| Fictional export-controlled technical data markers | `Export-Controlled` |

A real implementation would run in simulation mode first (report matches without
labeling anything), then move to enforce only after a human reviews a sample of
what it would have labeled — the standard Purview auto-labeling rollout pattern.

## Why this stays design-only

Two independent reasons, not one — closing either alone would not make this
implementable in `labels.ps1` as written:

1. **Licensing.** Auto-labeling is an AIP P2 entitlement
   (`docs/runbooks/g0-bootstrap.md` licensing table), carried by the M365 E5 / EMS
   E5 trials during their windows. This is the reason `L04.md` originally gave, and
   it is real — but it is not the only reason, and fixing it alone does not unlock
   an apply path.

2. **Mechanism mismatch (the reason the "applied by the same script... checked at
   runtime" language in `L04.md` was simply wrong, independent of licensing).**
   `labels.ps1`'s only authenticated surface is a Security & Compliance PowerShell
   session (`Connect-IPPSSession`). The S&C cmdlets that actually *apply*
   auto-labeling — `New-AutoSensitivityLabelPolicy` / `Set-AutoSensitivityLabelPolicy`
   — scope to `ExchangeLocation`, `SharePointLocation`, `OneDriveLocation`,
   `TeamsLocation`, and similar: Exchange, SharePoint, OneDrive, Teams. None of
   those location types is a Fabric workspace. Applying a sensitivity label to a
   Fabric item (a lakehouse, a semantic model, a report) is a different Purview
   Information Protection surface entirely, reached through the Fabric admin
   portal / Purview compliance portal's Fabric data map or the Fabric REST API's
   item-level sensitivity-label assignment — not through any cmdlet available in
   an S&C PowerShell session. So even with the AIP P2 entitlement present and a
   perfect runtime check for it, `labels.ps1` would still have no cmdlet that
   reaches Fabric. There is no "same script" apply path to add here without giving
   the script an entirely different authenticated connection (Fabric REST, not
   S&C PowerShell) and a non-trivial new dependency surface.

Given both, the honest record is: this design is real and worth keeping for a
future contributor who wants to wire up the Fabric-native integration properly,
but it is not a deploy step, it has no entitlement gate because there is nothing
for a gate to protect, and `docs/runbooks/layers/L04.md` now says exactly that.

## If this is ever built

A real implementation would need, at minimum:

- A Fabric REST or Fabric-admin-portal integration (not S&C PowerShell) capable of
  reading and setting an item's sensitivity label.
- Its own idempotent create-if-absent / update-on-drift script, tested the same way
  `infra/purview/labels.ps1` and `infra/purview/tests/labels.Tests.ps1` are tested,
  living beside them rather than inside `labels.ps1`.
- A genuine runtime entitlement check (Graph `Get-MgSubscribedSku` service-plan
  lookup for `AAD_PREMIUM_P2`/`INFORMATION_PROTECTION_COMPLIANCE`, or equivalent)
  with a loud, explicit degrade warning when absent — simulation-only, never a
  silent skip — plus a corresponding Verifier criterion, the same shape as this
  task added for the static label policy (`verification/layer-04-audit.ps1` V4.3).
- Sign-off from the sponsor before moving from simulate to enforce, per the
  general auto-labeling rollout pattern Microsoft documents, since a wrong
  auto-applied label is a availability/usability regression for the demo, not a
  security one.

None of that exists yet. This file is the design note, not a promise of a deploy
date.
