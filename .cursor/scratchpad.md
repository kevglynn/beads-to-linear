# Agent Scratchpad — beads-to-linear

## Background and Motivation

Owner: Kevin Glynn (top contributor to `gastownhall/beads` on GitHub).

New leadership wants to migrate the org from **Jira → Linear**, and wants
**all locally-tracked beads to be synchronized to Linear** so Linear remains
the org-wide source of authority while devs keep using beads' local-first,
agent-friendly workflow on their laptops.

Strategic angle: a successful integration could be contributed back upstream
as a PR to `gastownhall/beads`, since Linear is positioned to become a
dominant post-AI-era issue tracker.

## Key Challenges and Analysis

### Reframing (post local-context discovery)

`bd` already ships a substantial Linear integration. Confirmed surface:

- `bd linear sync` (bidirectional, with `--pull / --push / --dry-run`)
- `bd linear pull / push / status / teams`
- Conflict policy: newer-timestamp wins by default; `--prefer-local` /
  `--prefer-linear` overrides
- Multi-team via `linear.team_ids`, single-team fallback `linear.team_id`
- Type filters (`--type`, `--exclude-type`, `--include-ephemeral`),
  subtree push (`--parent TICKET`), `--create-only`
- Configurable mappings: `linear.priority_map.*`, `linear.state_map.*`,
  `linear.label_type_map.*`, `linear.relation_map.*`, `linear.id_mode`
- Backed by **Dolt** (versioned SQL) → first-class history, branch, merge,
  diff via `bd vc`, `bd diff`, `bd history`, `bd branch`
- Federation: `bd federation sync` (peer-to-peer between workspaces)
- JSONL is the cross-tool interchange (`bd export` → `.beads/issues.jsonl`)
- Git hooks installed for export-on-commit, sync on pull/push

So this project is **NOT** a from-scratch sync tool. The right framing is:

1. Audit the existing `bd linear` for gaps that block multi-developer,
   org-wide rollout (rate limits, conflict storms, ID collision, webhook
   absence, observability, RBAC, partial-trust scopes).
2. Decide the deployment architecture: per-laptop sync, centralized
   reconciler, or hybrid (git-mediated queue + central worker).
3. Decide what to upstream to `gastownhall/beads` vs what stays as our
   org-internal orchestration tooling in this repo.
4. Plan a phased rollout that survives N concurrent writers.

### Open questions to resolve via deep dive

See orchestrator prompt for the full clustered question set (state of the
art, multi-dev gotchas, architecture options, beads contribution model,
Linear API specifics, failure modes, rollout).

## High-level Task Breakdown

(To be populated post-orchestrator synthesis as beads epics + child issues
with explicit deps.)

## Current Status / Progress Tracking

- [x] Project scaffolded with ai-dev-playbook (cursor + claude rules,
  beads, hooks, scratchpad, AGENTS.md, CODE_OF_CONDUCT.md)
- [x] Local context audit: confirmed `bd linear` already exists; captured
  its surface area
- [ ] Deep-dive orchestrator pass 1 (parallel specialist exploration)
- [ ] Deep-dive orchestrator pass 2 (cross-pollination + adversarial
  review)
- [ ] Synthesize architecture options + recommended path
- [ ] Translate plan into beads (epics + child issues with deps)

## Executor's Feedback or Assistance Requests

(empty)

## Lessons

- Always probe the existing tool surface before assuming "bespoke build".
  `bd linear` is mature; reframed scope from greenfield to gap-fill +
  org-orchestration.
