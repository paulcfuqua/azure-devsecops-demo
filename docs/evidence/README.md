# Evidence

Screenshots of the running estate, captured to support a claim that a reader would
otherwise have to take on trust.

**This folder is empty on purpose.** It held two captures from an earlier build, and they
were removed rather than kept: the Container Apps domain changes on every rebuild, so a
screenshot taken before one shows a hostname that no longer resolves and figures that no
longer match the lakehouse. Stale evidence is worse than none — it looks like proof.

## What belongs here

A capture earns its place if it shows something the repository cannot assert in text:

- **The control tower's Dev, Sec and Ops tabs** rendering live rows — the claim that the
  apps serve real data rather than fixtures.
- **The Ask tab answering a question from the lakehouse**, with the answer visible beside
  the question.
- **The compliance board**, showing counts by status and provenance and no percentage
  anywhere.
- **A layer audit's criterion table**, green and red together in one frame.

## How to capture one that is worth keeping

1. **Sign in first.** All three dashboards are behind Container Apps Easy Auth; an
   anonymous request gets a 401, which is the control working.
2. **Name the file for what it proves, and date it** —
   `YYYY-MM-DD-<surface>-<claim>.png`.
3. **Record the provenance beside it in this file**: what was on screen, which estate, and
   what independently corroborates the numbers. A screenshot is a claim; the corroboration
   is what makes it evidence.
4. **Re-capture after a rebuild.** The estate is designed to be destroyed and rebuilt, and
   every capture has a shelf life that ends at the next teardown.

The verification reports under `verification/reports/` are the machine-readable half of
the same argument, and they do not go stale silently — they carry the run that produced
them.
