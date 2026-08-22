# Meridian Launch Systems — Azure DevSecOps Demo

An agent-team-built, fully code-defined enterprise Azure environment themed for the space
launch industry. The **repo is the product; the Azure environment is a build artifact** —
it can be destroyed and rebuilt from nothing via pipelines to keep idle cost near zero.

*Meridian Launch Systems* is a fictional company. All data is synthetic.

## Status

**Phase P (pre-tenant scaffold).** Decisions locked 2026-08-22: monorepo, Anthropic
API, dual E5 trials. Scaffold work proceeds; nothing has been written to Azure and the
tenant is deliberately not yet activated.

| Gate | Meaning | Status |
|------|---------|--------|
| G0 | Human bootstrap (tenant, OIDC root, Fabric capacity, licensing) | Deferred by sponsor — trial-rate strategy in `docs/runbooks/g0-bootstrap.md` |
| G1 | One-time master plan approval | **Amended 2026-08-22:** scaffold phase approved (Phase P); Azure deploy authorization (G1b) awaits tenant activation |
| G2 | Spend-profile changes (per occurrence) | n/a |
| G3 | Tenant-level destructive ops (per occurrence) | n/a |
| G4 | Exception escalation (event-driven) | n/a |

## Key documents

- [Project brief (decision record)](docs/BRIEF.md)
- [Design spec + pressure-test findings](docs/superpowers/specs/2026-08-22-azure-devsecops-demo-design.md)
- [G1 master plan](docs/superpowers/plans/2026-08-22-g1-master-plan.md)
- [Working agreements for all agents](CLAUDE.md)

## The three showpieces

1. **Copilot service** — natural-language questions over the Fabric lakehouse + ops/sec/
   cost APIs; answers rendered from JSON component specs by a fixed Fluent UI renderer.
2. **Control tower** — Dev / Sec / Ops posture on Well-Architected pillars, fed by live
   Azure, GitHub, and Defender APIs plus cost exports in the lakehouse.
3. **Self-healing pipeline** — vulnerability finding → agent triage → patch PR → CI
   gauntlet → auto-merge on green → deploy → finding closed. The PR trail is the demo.
