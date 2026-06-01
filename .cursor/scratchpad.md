# Agent Scratchpad — beads-to-linear

## Background and Motivation

Owner: Kevin Glynn (top contributor to `gastownhall/beads` on GitHub).

**What we built:** A sync layer so devs keep using beads locally
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

## Project Status: Core Work Complete

All 19 original beads are **closed**. The sync architecture, upstream PR
train, CI worker, cron installer, runbook, backfill script, and pilot
validation are done. Summary of what shipped:

### Upstream PRs to gastownhall/beads (9 PRs)
- PR-0 `btl-hgv`: Type mapping completion (canary)
- PR-1 `btl-lp5`: Refuse to write linear.api_key to git-tracked config
- PR-2 `btl-3hg`: Federation respects ephemeral/wisp filters
- PR-3 `btl-11r`: OAuth client-credentials support
- PR-4 `btl-09x`: issueBatchCreate and issueBatchUpdate adoption
- PR-5 `btl-bw2`: Idempotency markers on Linear issue creation
- PR-6 `btl-4k5`: Retry-After header parsing and adaptive backoff
- PR-7 `btl-m2x`: Per-workspace concurrency lock
- PR-8 `btl-2jg`: Persistent sync audit log

### Org-internal tooling (this repo)
- CI worker for centralized Linear push (`btl-wxa`)
- Per-laptop pull cron installer (`btl-3zh`)
- Operations runbook (`btl-pjn`)
- Jira → Linear backfill script (`btl-53l`)
- Config template, onboarding guide, branch protection rules
- Monitoring/alerting dashboard, JSONL merge strategy
- Pilot validation (50-bead burn-in with exit criteria)

### Architecture decisions (all closed → option a)
- Credential strategy (`btl-0nz`)
- Pull cadence (`btl-oyn`)
- Conflict resolution policy (`btl-65f`)

### Bugs found and fixed along the way
- Batch create silently drops new issues (`btl-znv`)
- `bd export` includes wisps/memories in JSONL (`btl-16t`, `btl-wqv`)
- Priority mapping not configured (`btl-pcy`)
- Stale-push edge case for pre-mapping beads (`btl-d99`)
- CI push script fixes (`btl-x29`), health check bugs (`btl-7ay`)
- External_ref storage separation (`btl-4yx`)

## What's Left

**No open beads.** The ready queue is empty.

5 ingestion/munchbot beads were closed and removed from this project on
2026-05-08 — they belong in the munchbot repo, not here.

### Potential next steps (not yet planned)
- Phase 2 rollout to org Linear workspace (blocked on org workspace provisioning)
- Upstream PR follow-up: check merge status, address reviewer feedback
- Dogfooding: continued use of the sync pipeline on this repo itself
- Contributing the integration back upstream per the strategic angle

## Confirmed Environment

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
  admin. ALL Phase 0/Phase 1 sync experiments target this.
- **gh active account note**: scripts running as `kev-pryon` (work)
  cannot operate on `kevglynn/*` repos.

## Dirty Working Tree

10 uncommitted changes as of 2026-05-08:
- Modified: `.beads/issues.jsonl`, `.claude/rules/operating-model.md`,
  `.cursor/rules/operating-model.mdc`, `CLAUDE.md`, `PLAN.md`
- Untracked: `.claude/rules/parallel-subagent-safety.md`,
  `.claude/rules/session-lifecycle.md`,
  `.cursor/rules/session-lifecycle.mdc`,
  two `.bak` files (safe to delete)

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
- Keep project beads scoped to the repo's purpose. Ingestion/munchbot
  beads were misplaced here and had to be cleaned out.
