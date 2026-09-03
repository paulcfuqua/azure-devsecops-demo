# The re-baseline run — teardown, rebuild, and telling the truth afterwards

*Written 2026-09-02, for the session that runs it. This is a plan and a prompt, not a
record; when the run is done this file should be deleted, and what it produced should be
in the documents themselves.*

## What this run is for

Two things at once, and the order matters:

1. **Prove the estate rebuilds.** Phase 1 of the sponsor direction. Everything else is
   measured against a rebuilt estate — if it cannot be recreated, nothing built on it can
   be trusted or shown twice.
2. **Re-baseline the documentation to what is actually true**, so the repository can be
   handed to a stranger as a stable deliverable rather than a construction diary.

The second is not tidying. Today the README opens by telling a first-time reader:

> No `az login` has ever run on the machine that built this. There is no tenant, no
> subscription, no resource group, no running container.

There are **thirty** resources. That sentence was true and load-bearing on 2026-08-28 and
is now the first thing a newcomer reads.

## Sequence: capture during, rewrite after

**Not** "fix everything then document", and **not** "document each layer as it lands".
The split follows CLAUDE.md's own rule — *a run is an expensive, rate-limited observation:
it returns everything it saw.*

**DURING the rebuild — capture, do not rewrite.** A teardown-and-rebuild is a rare
observation event. The gap between what a runbook *claims* a layer does and what actually
happens is only visible while it is happening, and is unrecoverable afterwards. So each
layer produces a short delta and nothing more:

```
L06  runbook says      : <the claim>
     actually happened : <what was observed>
     surprised me      : <anything the doc did not prepare you for>
     doc action        : rewrite | delete | correct one line | none
```

**AFTER the rebuild — one re-baselining pass.** Prose written at L2 can be false by L11:
FQDNs change, the Log Analytics workspace is new, findings appear. Rewriting during the
run means writing twice. Rewriting after means writing once, against a settled estate,
with every delta already captured.

The one exception: a document that would **actively mislead the operator running the
rebuild** gets corrected immediately. A runbook that sends someone to a dead command is
not a documentation debt, it is a live hazard.

## Agent topology — reactive, not pre-spawned

The repository defines five: `platform-lead` (L0/L1/L6/L11), `identity-governance-lead`
(L2/L3/L4), `data-copilot-lead` (L5/L7/L8), `devsecops-lead` (L9/L10), and `verifier`.

**Do not spawn all five to watch.** The rebuild is sequential by construction — `infra-up`
runs layers in order and each waits on the previous layer's sign-off — so parallel
watchers spend tokens on waiting. The Verifier is already wired into the workflow as a job
per layer; it does not need a second instance narrating.

Instead:

- **One driver** runs `infra-up`, watches, and records the per-layer delta above.
- **Dispatch the owning lead only when a layer fails**, with the failure in hand. That is
  where the specialists earn their cost — diagnosing L3 Entra propagation or L8 solution
  packing is exactly what they know and the driver does not.
- **The Verifier stays as it is:** in-workflow, reading only `verification/`, as
  `mls-verifier`. Its independence is the thing that makes sign-off worth anything, and a
  second Verifier instance run by the driver would quietly break that.

## Known documentation debt, measured 2026-09-02

Start here rather than re-surveying:

| Document | Problem |
|---|---|
| `README.md` | Opens with "no tenant… no running container" — false. References **Phase P** and **Phase Q**, internal build checkpoints meaningless to a newcomer. Says the register has "grown to 44"; it is 166. |
| `docs/runbooks/layers/L01–L12` | Thirteen files, all carrying forward-looking language — "will be", "not yet run", "once L*n* completes" — written before the layers existed. |
| `docs/DEMO-READINESS.md` | 2,462 lines and growing. Genuinely valuable **as a register**, and wrong as a front door. Its SCORECARD is the live part; the findings below it are history. Consider splitting rather than pruning: the register's value is that nothing was quietly removed. |
| `docs/BY-THE-NUMBERS.md` | Already carries a pre-tenant and a deployed column. Needs the deployed column re-measured after the rebuild, not restructuring. |
| `docs/superpowers/plans/*` | Five completed plans. They are history and should say so at the top rather than reading as current intent. |

**A rule for the pass:** delete a checkpoint reference, keep a finding. "Phase Q made
everything tenant-independent" is scaffolding a stranger does not need. "The scan reported
zero High-risk alerts against a login page for three weeks" is the argument the repository
exists to make.

## What "stable" means when this is done

A stranger clones the repo and can answer, from the documents alone:

- What is this, and what does it do that is unusual?
- What is deployed right now, and what does it cost?
- How do I stand it up in my own tenant, and how do I tear it down?
- What is verified, by whom, and what is honestly not?
- Where do I look when something fails?

The last two are the differentiator. Most demo repositories answer the first three.

## The prompt

> Read `docs/DEMO-READINESS.md` (SCORECARD and BLOCKER TREE first), then `CLAUDE.md`.
> We are doing the re-baseline run described in `docs/runbooks/rebaseline-run.md`.
>
> **Phase 1 — prove the rebuild.** Tear down and rebuild the estate. Drive it yourself;
> dispatch the owning workstream lead only when a layer fails, with the failure in hand.
> For every layer, record the four-line delta from that document. Fix what breaks. Do not
> rewrite documentation yet, except where a document would actively mislead the operator
> doing the rebuild — correct that immediately and note it.
>
> **Phase 2 — re-baseline the documentation** to the estate that now exists. Use the
> deltas. Start with `README.md`, which currently opens by telling the reader there is no
> tenant. Remove build-checkpoint scaffolding — Phase P, Phase Q, "will be", "not yet" —
> and keep findings. Re-measure `BY-THE-NUMBERS.md`'s deployed column. The target is a
> repository a stranger can be pointed at as stable.
>
> Two standing rules from CLAUDE.md that this run will test hard: **a change is finished
> when a rebuild reproduces it, not when the thing works**; and **evidence that cannot
> distinguish two states is not evidence.** Several fixes from 2026-09-02 have never been
> through a teardown — derived DAST targets, Entra probe roles, the posture feeds, and an
> Easy Auth audience that was hand-patched and then reverted to the template. If any of
> them fail to survive, that is the most valuable result this run can produce.
