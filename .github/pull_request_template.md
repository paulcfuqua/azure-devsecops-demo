<!--
Meridian Launch Systems demo — pull request template.
Working agreements: CLAUDE.md. Layer playbooks: docs/runbooks/layers/.
Keep this short: the checklists exist to catch the four things that actually go
wrong in this repo, not to perform process.
-->

## What and why

<!-- One paragraph. If this PR belongs to a layer, name it (L2 … L11). -->

**Layer:** <!-- L6 / L9 / n/a -->
**Playbook:** <!-- docs/runbooks/layers/LNN.md, or n/a -->

## Gates

<!-- CLAUDE.md hard rule 2. Delete the lines that do not apply. -->

- [ ] **No gate needed** — authoring only, or an RG-scoped change (teardown of demo resources is gate-free by design).
- [ ] **G2 (spend-profile increase)** — cost delta and duration stated below, human approval linked.
- [ ] **G3 (tenant-level deletion)** — Entra objects / labels / Fabric workspace shell / OIDC federation; per-occurrence approval linked.
- [ ] **G4 (escalation)** — second consecutive layer audit failure, cost anomaly, or credential failure.

**Cost delta:** <!-- e.g. "$0" / "+$0.36/hr for a ~2 h Fabric resume window" -->

## Checks

- [ ] `lint-ci` is green (actionlint, PSScriptAnalyzer + Pester, pytest, vitest).
- [ ] No IDs, keys, or tenant values committed — tenant/subscription/client IDs live in the `demo` GitHub environment, and the only stored secret is `ANTHROPIC_API_KEY` (CLAUDE.md hard rule 5).
- [ ] Synthetic data only; no real person's PII, nothing proprietary (hard rule 4).
- [ ] Resource names come from `infra/bicep/naming.bicep`; no new hardcoded company prefix.
- [ ] Required tags unchanged or still complete: `env`, `app`, `costCenter`, `owner`, `dataClassification`, `managedBy=iac`.
- [ ] If this changes a deploy path, the matching **teardown** and **`verification/layer-NN-audit.ps1`** are covered — a layer without all three is not done.

## Verification

<!--
What did you actually run, and what did it print? Evidence, not assertion.
For a layer PR, name the criteria this satisfies (e.g. V6.1, V7.4).
-->

```
```

## Open items

<!--
Anything a reviewer must carry forward. Reference the Phase P table where it
applies (P-1 target ports, P-2 NIST identity, P-3 Key Vault purge protection,
P-4 PSScriptAnalyzer in CI, P-5 duplicate spec validation, P-7 Docker build
context). Say "none" if there are none.
-->

none
