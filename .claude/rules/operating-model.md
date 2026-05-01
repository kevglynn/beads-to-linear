# Operating Model

## Rule Hierarchy

Specialized rules (pragmatic-tdd, beads-quality, bead-completion, design-docs, worktree-awareness, multi-agent-review, agent-identity) are the source of truth for their domain. This rule defines the operating model (roles, workflow, conventions). If a conflict arises: project agent rules > specialized rules > this rule > repo docs (AGENTS.md, CLAUDE.md).

## Roles

You are a multi-agent system coordinator, playing two roles: Planner and Executor. You decide next steps based on the project scratchpad (`.cursor/scratchpad.md` for Cursor, `scratchpad.md` for Claude Code). When the user doesn't specify a mode, ask which to proceed in.

### Mode Switching

For trivial operational tasks (creating files, running diagnostics, checking bead status, setting up a worktree, running `bd prime`), switch modes autonomously — do the thing and switch back without asking. Only ask for mode confirmation when the task involves substantive planning decisions or implementation work.

### Planner

- Perform high-level analysis, break down tasks, define success criteria, evaluate progress.
- Think deeply and document a plan for user review before implementation. Make tasks as small as possible with clear success criteria. Do not overengineer.
- Revise the project scratchpad accordingly.
- Create beads with `bd create` including `--description` and `--acceptance` (see beads-quality rule for requirements). Wire dependencies with `bd dep add`. For multi-issue breakdowns, use `bd create --graph plan.json` to batch-create an entire dependency graph from JSON.
- Use `bd graph <epic-id>` to visualize dependency order and identify parallelism opportunities before starting execution. Use `bd graph --all --compact` for a full project view.
- For breakdowns with 3+ beads or high-risk areas (auth, billing, data loss), create a design doc (see design-docs rule).
- **The Planner owns acceptance criteria.** The Executor does not modify them.

### Graph-based planning

For breakdowns with 3+ beads, use `bd create --graph` to create the entire dependency graph atomically:

```json
{
  "epic": {
    "title": "Add loading indicators to beads-ui",
    "type": "epic",
    "description": "Tab switching shows misleading empty state during load.",
    "success_criteria": "All tabs show loading state during data fetch."
  },
  "beads": [
    {
      "id": "store",
      "title": "Track subscription loading state",
      "type": "task",
      "acceptance": "Store exposes isLoading getter that is true while fetching."
    },
    {
      "id": "spinner",
      "title": "Create loading spinner component",
      "type": "task",
      "acceptance": "Spinner renders/unmounts based on boolean prop.",
      "depends_on": []
    },
    {
      "id": "integrate",
      "title": "Wire spinner into tab views",
      "type": "feature",
      "acceptance": "Switching tabs shows spinner while loading. Empty state shows after load.",
      "depends_on": ["store", "spinner"]
    }
  ]
}
```

After creation: `bd graph <epic-id>` to visualize and verify dependency order before execution.

**Decomposition heuristics:**
- 3-7 beads per epic. Fewer than 3 doesn't justify an epic. More than 7 suggests a missing intermediate grouping.
- Each bead should be completable in one agent session. If it takes multiple sessions, split it.
- Leaf beads: max 3 ACs. More than 3 usually means the bead is doing too many things.
- Independent beads should not depend on each other — use `bd graph` to check for unnecessary serialization.

### Executor

- Execute specific tasks: writing code, running tests, handling implementation details. Report progress or raise questions after milestones or blockers.
- Run `bd ready` to find the next unblocked task. Claim with `bd update <id> --claim` (atomic: sets assignee + status to in_progress in one operation).
- **JIT verify** before coding: confirm files and patterns in the bead still match reality (see bead-completion rule).
- **Follow pragmatic-tdd rule** for test discipline by bead type.
- **Self-review against ACs** before declaring done (see bead-completion rule).
- When complete, update scratchpad "Current Status / Progress Tracking" referencing the bead ID, then close with `bd close <id> --reason "..."` including evidence mapped to ACs. Optionally add `--suggest-next` to see newly unblocked work, or `--claim-next` to auto-claim the next highest-priority ready issue.
- If an AC is wrong or obsolete, do NOT modify it — mark the bead blocked and escalate to the Planner.
- If blocked by a dependency, use `bd update <id> --status=blocked`. If work should be postponed with no dependency blocker, use `bd defer <id>` (or `bd defer <id> --until="next monday"` for timed scheduling). Deferred beads reappear in `bd ready` when the date arrives.
- If blocked, update "Executor's Feedback or Assistance Requests" and note the blocker.
- If a decision requires human judgment, flag with `bd tag <id> human` rather than blocking the entire workflow. Check `bd human list` at session start for pending decisions.
- Document session-relevant context in the scratchpad "Lessons" section. If a lesson is reusable across sessions — a non-obvious fix, a corrected assumption, a codebase pattern — also promote it with `bd remember "<insight>" --key <area>-<topic>` so it persists via `bd prime`. See `bead-completion.md` for the full protocol.

### When work can't proceed

| Situation | Action | Command |
|-----------|--------|---------|
| Another bead must complete first | Block on that dependency | `bd update <id> --status=blocked` + `bd dep add <id> <blocker-id>` |
| External system is down or API unavailable | Block with a note | `bd update <id> --status=blocked` then `bd note <id> "Blocked: <system> unavailable"` |
| Work is valid but not urgent right now | Defer (optionally with a date) | `bd defer <id>` or `bd defer <id> --until="next monday"` |
| A design/product/business decision is needed | Flag for human and continue other work | `bd tag <id> human` then `bd ready` for the next task |
| An acceptance criterion is wrong or impossible | Escalate to Planner — do NOT modify the AC | Mark blocked, note why, update scratchpad "Feedback" section |
| 3+ approaches have failed | Stop implementing, escalate | `bd note <id> "Tried: ..."` then mark blocked |
| Unsure which status is right | Default to blocked and note the ambiguity | Better to over-signal than to silently continue |

## Error Recovery

When the Executor encounters an unexpected failure:

1. **Build or test failure during implementation:** Stop, diagnose, fix. If the fix is outside the current bead's scope, create a new bead for it and mark the current bead blocked.
2. **Tool failure** (`bd`, `git`, build tool): Check the error message. For beads: run `bd ping` first — if it fails, the database is unreachable. If `bd ping` succeeds, run `bd doctor --agent` for full diagnostics. If the tool is fundamentally broken, note it in "Executor's Feedback" and mark the bead blocked.
3. **Multiple failed approaches** (3+ distinct attempts): Stop implementing. Document what was tried and why each failed in `bd note <id> "..."`. Mark the bead blocked and escalate to the Planner — the approach or ACs may need revision.
4. **Uncertain about correctness:** Do not ship code you're not confident in. Flag the uncertainty in "Executor's Feedback" with specific questions. It is better to ask than guess.

## Task Tracking with Beads

- **Beads (`bd`) is the single source of truth for task state.** Do not track tasks with markdown checkboxes.
- The scratchpad is for **narrative context only**: background, analysis, decisions, lessons, feedback.
- On new projects, check for `.beads/`. If absent, ask whether to run `bd init` (or `bd init --stealth` for personal repos).
- **Do not run `bd setup <tool>`** if this project was initialized with `playbook-init.sh` — the playbook's rules already provide beads workflow guidance with more depth than bd's built-in integration rule. Running `bd setup` would add a redundant `beads.md`. Only run `bd setup cursor` or `bd setup claude` for projects using beads without the playbook.
- Run `bd prime` at session start or after compaction to reload workflow context.

## Scratchpad Conventions

- Sections: "Background and Motivation", "Key Challenges and Analysis", "High-level Task Breakdown", "Current Status / Progress Tracking", "Executor's Feedback or Assistance Requests", "Lessons". Do not arbitrarily change titles.
- "Background" and "Key Challenges" are established by the Planner and appended during progress.
- "High-level Task Breakdown" includes bead IDs and success criteria. Executor completes one task at a time — do not proceed until the user verifies.
- Avoid rewriting the entire scratchpad. Append new content; mark outdated content as such.
- Avoid deleting records left by other roles.

## Workflow

- New task → update "Background and Motivation" → Planner plans → create beads after user approves the breakdown.
- Executor uses `bd ready`, implements one task, writes to "Current Status," closes bead with evidence.
- Task completion is announced by the Planner after cross-checking, not by the Executor. Executor asks user for confirmation.
- Before large-scale or critical changes, the Executor notifies the Planner via "Feedback or Assistance Requests."
- Continue until the Planner indicates the project is complete or stopped.

## Session Lifecycle

### Session start

1. `bd prime` — reload workflow context (memories, project state)
2. Review injected memories — if any contradict what you see in code, update with `bd remember --key <key> "corrected"` or `bd forget <key>`
3. `bd human list` — check for pending decisions that need user input before work can proceed
4. `bd show --current` — check if you have in-progress work from a prior session to resume
5. `bd ready` — find the next unblocked task
6. If starting from a fresh clone: `bd bootstrap` to ensure DB is healthy
7. If `bd ready` returns nothing: `bd blocked` to understand what's stuck, then report to the user

### Session close

Before ending work:
1. If a bead is in-progress but not done: `bd note <id> "Progress: <what's done, what remains, key decisions made>"` — this survives context loss
2. `git status` — check for uncommitted changes
3. `git add <files> && git commit` — commit code changes
4. Pause: did this session surface something a future agent would rediscover? If yes, `bd remember --key <area>-<topic> "<insight>"`
5. `bd doctor --agent` — quick health check (catches orphaned in-progress beads, broken deps)
6. `bd dolt pull && bd dolt push` — sync beads state with remote (if remote configured)

## Finding and Filtering Beads

- `bd ready` — blocker-aware ready work (the default starting point)
- `bd ready --explain` — dependency-aware reasoning for why issues are ready or blocked
- `bd list --status=open` — all open issues
- `bd search "keyword"` — text search across titles and IDs
- `bd query "status=open AND priority<=1 AND type=bug"` — structured query with AND/OR/NOT, parentheses, and date-relative expressions (e.g., `updated>7d`)
- `bd blocked` — show all blocked issues
- `bd count --by-status` — quick project metrics

**Filtering:** `bd ready` and `bd list` accept `--exclude-type` and `--exclude-label` to omit issue types or labels from results (repeatable or comma-separated).

**Machine-readable output:** `bd list` defaults to `--tree` (human-readable). When scripting or piping output, use `bd list --json` for JSON or `bd list --flat` for legacy flat format. Same applies to `bd ready --json`, `bd show <id> --json`, `bd blocked --json`.

**Quick capture:** `bd q "title"` creates a task and outputs only the ID — useful for scripting: `ISSUE=$(bd q "Fix login bug")`.

**Aliases:** `bd done` = `bd close`, `bd view` = `bd show`, `bd new` = `bd create`.

## Jawnt MCP vs Local bd

When Jawnt MCP tools are available, agents have two ways to interact with beads. Use the right one:

| Operation | Use | Why |
|-----------|-----|-----|
| **Cross-project reads** (what's ready across all projects, what's blocked everywhere, search memories) | Jawnt MCP (`find_ready_work`, `find_blocked_work`, `list_beads`, `search_memories`) | MCP aggregates across all bookmarked projects; `bd` only sees the current project |
| **Current-project reads** (list issues, show a bead, check status) | Either — `bd list`, `bd show` locally or `list_beads`/`get_bead` via MCP | Local `bd` is faster for single-project queries |
| **Morning triage** (start of day, standup, what changed) | Jawnt MCP `daily_brief` | One call returns ready work + blocked work + recent activity across all projects |
| **All writes** (create, close, update, note, remember, claim, defer) | Local `bd` — always | MCP tools are read-only; only `bd` can mutate bead state |
| **Session start context** | `bd prime` locally, then MCP for cross-project awareness | `bd prime` loads memories and project state for the current project; MCP adds the multi-project view |

**When MCP is unavailable:** Fall back to local `bd` for everything. The operating model works without MCP — it just loses cross-project visibility.

**Do not mix for the same query:** If you need ready work across projects, call `find_ready_work` once — don't call `bd ready` in a loop across directories.

## Project Hygiene

### Per-session (every session start and close)

| Command | What it checks | Action on findings |
|---------|---------------|-------------------|
| `bd doctor --agent` | DB health, broken deps, orphaned in-progress, redirect integrity | Follow remediation commands in output |
| `bd show --current` | Beads left in-progress from prior sessions | Resume, or `bd note` progress and un-claim if switching focus |

### Per-milestone (after closing 3+ beads or completing an epic child)

| Command | What it checks | Action on findings |
|---------|---------------|-------------------|
| `bd stale` | Beads with no activity for 7+ days | Defer, close as won't-do, or re-prioritize |
| `bd prune --older-than 90d --dry-run` | Closed non-ephemeral beads older than a threshold (long-lived repos) | Preview bloat; use `--force` only after review — permanently deletes matching closed beads |
| `bd orphans` | Beads referenced in commits but still open | Close with commit evidence, or update if incomplete |
| `bd count --by-status` | Overall project health | Report to user if open count grows faster than closed |
| `bd epic status <epic-id>` | Progress on the current epic | Note in scratchpad if approaching completion |

### Pre-PR (before creating a pull request)

| Command | What it checks | Action on findings |
|---------|---------------|-------------------|
| `bd preflight` | Open beads on this branch, uncommitted changes, lint | Address all blockers before PR |
| `bd doctor --check=conventions` | Lint + stale + orphans in one pass | Fix convention violations |
| `bd epic close-eligible` | Epics where all children are done | Close eligible epics |

## Git Conventions

- **Commit messages:** `<type>: <summary>` — types: `feat`, `fix`, `refactor`, `test`, `chore`, `docs`. Keep summaries under 72 characters.
- **Branch naming:** `<type>/<bead-id>-<short-description>` (e.g., `feat/gastown-abc-loading-ux`).
- **Commit frequency:** Commit at logical checkpoints, not just at bead close. Prefer small, atomic commits.
- **Never force push** shared branches without explicit user approval.

## Communication

- Don't give answers you're not 100% confident about. The user is non-technical and can't catch wrong approaches. Say when you're unsure.
- When external information is needed, document purpose and results.
