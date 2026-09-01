# Evidence

Screenshots of the running estate, kept because the outbrief (Direction phase 4) is built
from them and **a screenshot is a claim**. A picture of a dashboard proves nothing on its
own: the same image is produced by real data, by fixtures, and by a mocked provider. What
makes one admissible is the provenance recorded beside it.

Every file here carries, in this README:

- **when** it was taken, and **which revision** of the app served it;
- **what the data path was** — which store the numbers came from, and how the app
  authenticated to it;
- **what was independently checked**, so the image is corroborated rather than trusted.

An image that cannot be given those three lines does not belong in the outbrief.

---

## `2026-09-01-control-tower-ops-lakehouse.png`

Control Tower, **Ops** tab, taken 2026-09-01 from
`mls-control-tower-demo-ca.happymeadow-9e15a087.centralus.azurecontainerapps.io`, signed in
through Easy Auth as a real interactive user.

**Data path.** Fabric lakehouse → `data-api` (`MLS_DATA_BACKENDS=cloud`), authenticated with
the container app's **user-assigned managed identity** over the Fabric SQL analytics
endpoint — no stored credential anywhere in the path. Served to the browser through the
app's `/api` proxy.

**Independently checked.** The two routes behind this page were probed directly from the
authenticated browser context in the same session and returned
`tables/cost_daily` → **4,515 rows** and `tables/telemetry_summary` → **1,200 rows**, with
HTTP 200. The rendered figures agree with those payloads: 23,561 k$ total program spend
across 30 monthly points, 1,200 flights, 402 with at least one anomaly.

**What it does NOT show, stated because omission is how screenshots mislead.** The Dev and
Sec tabs were failing when this was taken — three GitHub feeds answering 503 because
`MLS_GITHUB_TOKEN` was unprovisioned, and the two Defender feeds returning an empty
`{"value":[]}` whose emptiness is not yet distinguishable from a denial. This image is
evidence for the lakehouse data path and for nothing else.

**Why it matters.** It is the first render of real estate data in a browser in this
project, and it closes F101 — which the register had recorded as the largest hole, on the
strength of a documented Fabric limitation that the running estate contradicts.
