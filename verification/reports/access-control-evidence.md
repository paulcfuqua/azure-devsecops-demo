# Access-control evidence — Meridian lakehouse

**Collected:** 2026-09-20T18:20:02Z  
**Database:** `mls_operations` on the Fabric lakehouse SQL analytics endpoint  
**Read by:** `admin@paulcfuquahotmail.onmicrosoft.com` — privileged role: 0, standard role: 0

Every statement behind this file is a `SELECT`. Re-run `verification/capture-access-control-evidence.ps1` to reproduce it.

## Verdict: CONTROL DEMONSTRATED

| | rows |
|---|---|
| `defect_reports` (base table) | **900** |
| `v_defect_reports` (through the security policy) | **761** |
| classified `THIRD_PARTY_PROPRIETARY` | **139** |
| removed by the filter | **139** |

900 − 139 = 761. The row-level security policy removed exactly the restricted rows, and returned no error while doing it.

Policy `sp_defect_tier` — enabled: **True**, FILTER predicate bound to `v_defect_reports`.

`hr_roster`: 240 rows, 240 with a populated `salary_usd`.

## What this evidence does NOT show

Stated here rather than in a footnote, because an evidence file carrying only the flattering half is marketing.

- **The column denials are inert.** `CREATE USER` is unsupported on this endpoint (Msg 22424), so no principal can join `mls_data_standard`, so a `DENY` targeting it binds nobody. The objects exist and enforce nothing. Column-level enforcement needs a Fabric Warehouse, where database principals exist. (F218)
- **There is no tiering.** Every caller sits outside the privileged role, so every caller is filtered identically. This supports *3PPI is hidden from every automated caller* — not *different accounts see different data*. (F218)
- **Silence is the intended behaviour.** A filtered caller gets no error and no indication rows were removed. That is correct for row-level security, where the existence of a record is itself sensitive — and it means this evidence, not the caller's experience, is how the control is observed.

## Independently checked

`V4.5` in `verification/layer-04-audit.ps1` asserts this same comparison on every L4 run, as `mls-verifier`, and fails when the shortfall does not equal the restricted count. This file is the human-readable capture; that criterion is the machine-checked one.
