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

## Pass 2 — Upstream PR candidates (proposed 2026-06-08, PENDING USER APPROVAL)

Second pass over open `gastownhall/beads` issues to find high-value,
high-merge-probability fixes to PR from the `kevglynn/beads` fork. The first
pass was Linear-sync focused (9 PRs); this pass targets general `bd`
correctness/UX, matching the maintainer's demonstrated willingness to merge
small, self-contained `fix(...)`/`feat(...)` PRs in `create`, `graph`,
`init`, `list`, `dep`, `config`, `prime`.

### Selection method
- Enumerated ~200 open issues; cross-referenced against the ~16 open
  kevglynn PRs and all merged/closed kevglynn PRs to avoid duplicates.
- For each candidate, checked GitHub for an existing linked PR (any author).
- Filtered OUT: anything with a competing open PR, Dolt storage-internals
  (maintainer/Dolt-owned, e.g. #4293/#4259/#4128), large redesigns, and
  items the maintainer explicitly deferred (#4068) or flagged for design
  discussion (#4040).

### Excluded after vetting (had competing open PRs)
#3916 (PR#3917), #3851 (PR#4030), #3693 (PR#3694), #4241 (PR#4242),
#4040 (PR#4034/#4035, needs discussion), #3898 (PR#3868), #4068 (deferred
to storage rewrite).

### Proposed set (no competing PR; clear scope)
| Issue | Type | What | Value | Merge prob |
|-------|------|------|-------|------------|
| #3893 | bug | `bd create --graph --dry-run` silently persists to DB instead of previewing | High — data-integrity footgun (we hit this ourselves; see Lessons) | High |
| #4164 | bug | `claim()` hardcodes `WHERE status='open'`, blocking claims under configured custom statuses | High — blocks custom-status lifecycles (real downstream tool) | Med-High (touches claim semantics) |
| #3490 | feat | `bd init --init-if-missing` flag for idempotent orchestration | Med-High — orchestration ergonomics | High (additive, non-breaking) |
| #3941 | bug | `bd prime --memories-only` outputs full custom PRIME.md instead of memories; memories silently dropped | Med-High — breaks memory injection in hooks | High |
| #3961 | feat | `bd prime --no-memories` flag to omit memories section | Med — context-budget for memory-heavy workspaces | High (additive) |
| #3834 | feat | `bd lint`: accept "Acceptance Criteria" for epics, unifying mandatory sections (optional add-on) | Low-Med — agent ergonomics | Med (maintainer may prefer the distinction) |

`#3941` and `#3961` both touch the `bd prime` memories-rendering path → sequence
them (do the bug fix #3941 first, then add the flag #3961) to avoid self-conflict.
All other items are independent (different subsystems) → no inter-bead blocks.

### Watching but not proposing
- #3965 (`bd update` no longer touches `last-touched`): the issue itself
  offers "fix OR update docs" — maintainer may intend the new read-marker
  behavior, so merge intent is ambiguous. Hold unless user wants it.

### Proposed bead structure (epic + children)
Epic "Upstream contribution pass 2 — high-merge-probability bd fixes" with the
5 core issues as children (optionally + #3834). One branch + one PR per child
from the fork, mirroring the established `fix/NNNN-...` / `feat/NNNN-...` pattern.

### APPROVED + CREATED 2026-06-08 (epic btl-gk8)
User approved core+3834+3965. Parallel read-only explore agents mapped all
fixes to exact files/lines. Two items changed after verification:
- **#3893 DROPPED** — already fixed & merged by PR #3762 (commit 480ffe4d4) on
  origin/main on 2026-05-14. Issue still open (0 comments) but core bug gone.
  Not worth a redundant PR.
- **#3965 REFRAMED** — `bd update` already touches last-touched on main
  (update.go:531). Real residual: `bd close` never sets last-touched for the
  closed issue despite its docs (close.go only does it for --claim-next).
  PR fixes the close case + adds os.Chtimes mtime bump. Weakest of the batch.

Final set = 6 PRs. Beads (this project, prefix btl-):
- btl-gk8  EPIC
- btl-cdy  #4164 claim custom statuses (bug, P1) → fix/4164-claim-custom-statuses
- btl-0ux  #3941 prime custom-PRIME drops memories (bug, P1) → fix/3941-prime-memories-custom-primemd
- btl-4of  #3961 prime --no-memories (feat, P2) → feat/3961-prime-no-memories  [blocked by btl-0ux]
- btl-re7  #3490 init --init-if-missing (feat, P2) → feat/3490-init-if-missing
- btl-rz3  #3834 lint epic Acceptance Criteria (feat, P2) → feat/3834-lint-epic-acceptance
- btl-tr8  #3965 bd close last-touched (bug, P2) → fix/3965-close-last-touched

Implementation: git worktrees off origin/main under ~/beads-pass2/. Build via
`make build`, test touched packages via `go test -tags gms_pure_go ./pkg/...`,
`make fmt`, document new flags in docs/CLI_REFERENCE.md, push to kevglynn fork
(SSH), `gh pr create` into gastownhall/beads (gh switched to kevglynn).

### DONE 2026-06-08/09 — all 6 Pass-2 PRs opened, epic btl-gk8 closed (6/6)
All work done in the single reused worktree ~/beads-pass2/3490 (branched fresh
off origin/main per item; the prime pair was stacked). Tests run with
`CGO_ENABLED=1 go test -tags gms_pure_go ./cmd/bd/` against the cmd/bd Dolt
container harness (no BEADS_TEST_EMBEDDED_DOLT gate needed for the
buildBDUnderTest/initBeadsWorkspace path).

- btl-re7 #3490 init --init-if-missing → PR #4332
- btl-cdy #4164 claim honors custom active statuses → PR #4334
- btl-0ux #3941 prime: custom PRIME.md drops memories + --memories-only fix → PR #4335
- btl-4of #3961 prime --no-memories (stacked on #4335) → PR #4336
- btl-rz3 #3834 lint accepts Acceptance Criteria heading for epics → PR #4337
- btl-tr8 #3965 bd close updates last-touched (+ os.Chtimes mtime bump) → PR #4338

Notes for follow-up:
- #4336 is stacked on #4335 — if maintainer merges #4335 first, #4336 auto-cleans;
  otherwise it shows both commits. Watch for rebase need.
- Doc-freshness CI: regenerate with the CGO_ENABLED=0 -tags gms_pure_go binary,
  then run scripts/generate-cli-docs.sh AND scripts/generate-llms-full.sh; both
  have a --check mode the CI uses. `timeout` is absent on macOS (check-doc-flags
  fails locally for that reason only) — the --check subcommands work directly.

### INCIDENT (re-confirmed Lesson): installed bd 1.0.3 --graph ignores --dry-run
Ran `bd create --graph pass2-graph.json --dry-run` to preview; installed bd is
1.0.3 (predates #3762) so it PERSISTED all 7 beads. End state was exactly the
intended graph (parent/child + the primeflag→primebug blocks edge all correct),
so kept them — no cleanup. Reminder: this project's local bd is 1.0.3; do not
trust --dry-run on --graph here.

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
