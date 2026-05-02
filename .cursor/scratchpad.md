# Agent Scratchpad — beads-to-linear

## Background and Motivation

Owner: Kevin Glynn (top contributor to `gastownhall/beads` on GitHub).

**What we're building:** A sync layer so devs keep using beads locally
while Linear automatically reflects their work for PMs and leadership.
One CI worker is the sole Linear writer (pushes on every `git push`);
per-laptop crons pull Linear updates back every 15 minutes. No dev
touches Linear directly. No double-entry. PMs get a live board.

**What this repo is:** Planning workspace + org-internal tooling (CI
workflow, cron installer, runbook, backfill script). Improvements to
beads itself go upstream as PRs to `gastownhall/beads`.

**Strategic angle:** Successful integration gets contributed back upstream,
positioning beads as the local-first agent-native frontend to Linear in
the post-AI-era issue tracking landscape.

**Deployment model:** Opt-in per team. Prove with a pilot team first
against the sandbox workspace (`linear.app/kevglynn`), then roll out
org-wide. Teams that don't opt in are unaffected.

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

Seeded from `PLAN.md` §10 via `bd create --graph docs/initial-bead-plan.json`.
Result: 19 beads, 13 dep edges, 2 parent-child epic groupings, prefix `btl-`.

| Symbolic key                    | bd ID    | Type     | Pri | Notes                          |
| ------------------------------- | -------- | -------- | --- | ------------------------------ |
| epic-arch                       | btl-0bk  | epic     | P1  | Centralized sync architecture  |
| epic-upstream                   | btl-9pf  | epic     | P1  | 9-PR train to gastownhall/beads |
| task-pr0                        | btl-hgv  | task     | P2  | Canary: type mapping           |
| task-pr1                        | btl-lp5  | task     | P1  | P0 SECURITY: refuse git keys   |
| task-pr2                        | btl-3hg  | task     | P2  | P1 PRIVACY: federation wisp    |
| task-pr3                        | btl-11r  | task     | P1  | OAuth client-credentials       |
| task-pr4                        | btl-09x  | task     | P1  | Batch mutations                |
| task-pr5                        | btl-bw2  | task     | P1  | Idempotency markers            |
| task-pr6                        | btl-4k5  | task     | P2  | Retry-After / circuit breaker  |
| task-pr7                        | btl-m2x  | task     | P3  | Concurrency lock               |
| task-pr8                        | btl-2jg  | task     | P3  | Persistent audit log           |
| task-ci-worker                  | btl-wxa  | task     | P2  | Org CI worker                  |
| task-pull-cron                  | btl-3zh  | task     | P3  | Per-laptop pull cron installer |
| task-runbook                    | btl-pjn  | task     | P3  | Operations runbook             |
| task-backfill                   | btl-53l  | task     | P4  | Jira → Linear backfill         |
| spike-oauth-app                 | btl-6tt  | spike    | P2  | Validate OAuth in sandbox      |
| decision-credential-strategy    | btl-0nz  | decision | P2  | CLOSED: option (a)             |
| decision-pull-cadence           | btl-oyn  | decision | P3  | CLOSED: option (a)             |
| decision-conflict-policy        | btl-65f  | decision | P2  | CLOSED: option (a)             |

Ready queue right now (after closing 3 decisions):
1. **btl-hgv** task-pr0 — canary upstream PR (start here)
2. **btl-6tt** spike-oauth-app — validate OAuth in sandbox
3. **btl-pjn** task-runbook — can run in parallel
4. (epics btl-0bk, btl-9pf show as ready but are containers, not actionable)

## Current Status / Progress Tracking

- [x] Project scaffolded with ai-dev-playbook
- [x] Local context audit: confirmed `bd linear` already exists
- [x] Deep-dive orchestrator pass 1 (6 parallel specialists)
- [x] Deep-dive orchestrator pass 2 (3 cross-pollination agents)
- [x] PLAN.md written (990 lines, all 11 sections)
- [x] §9 open decisions resolved by human (all 10 → option a)
- [x] §10 translated into 19 beads with deps + parent-child wiring
- [x] 3 ADR-style decision beads closed with resolution notes
- [ ] First commit of seed plan + bead state
- [ ] Begin work on ready queue (btl-hgv canary PR or btl-6tt OAuth spike)

## Executor's Feedback or Assistance Requests

### Confirmed environment (2026-05-01)

- **Upstream beads repo**: `gastownhall/beads`
  (https://github.com/gastownhall/beads), local clone `~/beads`
- **Owner's fork**: `kevglynn/beads` (https://github.com/kevglynn/beads),
  local clone `~/beads-fix` (active branch `fix/list-json-flag`)
- **This project's repo**: `kevglynn/beads-to-linear`
  (https://github.com/kevglynn/beads-to-linear) — public, account
  `kevglynn` (NOT `kev-pryon`, which lacks org rights)
- **Org Linear workspace**: not provisioned yet ("coming"). Phase 2+
  of any rollout plan must NOT assume it exists; design Phase 1 to be
  fully validated without it.
- **Sandbox Linear workspace**: https://linear.app/kevglynn — owner has
  admin. ALL Phase 0/Phase 1 sync experiments target this. Architecture
  decisions about rate limits, webhooks, conflict policy will be
  validated end-to-end here before any org-Linear involvement.
- **gh active account note**: scripts running as `kev-pryon` (work)
  cannot operate on `kevglynn/*` repos. Document in Section 7 of PLAN
  (org-internal tooling) so any future automation gets the auth right.

## Lessons

- Always probe the existing tool surface before assuming "bespoke build".
  `bd linear` is mature; reframed scope from greenfield to gap-fill +
  org-orchestration.
- `bd create --graph <plan>` silently ignores `--dry-run`. Worth filing
  upstream as a small canary PR before or alongside PR-0 (super-low-risk
  change that builds reviewer trust). Discovered when our "preview"
  command actually wrote 19 beads to the database.
- `bd delete <id>` removes from Dolt but does NOT update
  `.beads/issues.jsonl` immediately — the next command's auto-import
  resurrects the deleted bead from JSONL. Workaround: run `bd export`
  immediately after `bd delete` to flush, OR prefer `bd close` over
  `bd delete` for audit-friendly removal.
- `bd config set issue-prefix` is rejected with a helpful error pointing
  to `bd rename-prefix <new>`. The new-prefix value must end with a
  hyphen (e.g., `btl-`, not `btl`).
- gh CLI auth: when an active account (`kev-pryon`) lacks rights to a
  target org/user, switch with `gh auth switch --user <other>` rather
  than re-authenticating. We have three accounts wired up: `kev-pryon`
  (work), `kevglynn` (personal), `Medhaug`.
