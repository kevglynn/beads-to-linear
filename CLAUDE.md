# Project Instructions for AI Agents

## What This Project Is

**beads-to-linear** is a planning workspace and org-internal tooling repo for
synchronizing local-first [beads](https://github.com/gastownhall/beads) issue
tracking with [Linear](https://linear.app) as the org-wide source of truth.

**The deployed system works like this:** Devs use beads locally — `bd create`,
`bd close`, `bd list` — exactly as they do today. When they `git push`, their
`.beads/issues.jsonl` goes with it. A CI worker (the sole Linear writer) picks
up the delta and pushes to Linear via `bd linear sync --push`. A per-laptop
cron pulls updates back from Linear every 15 minutes via `bd linear sync
--pull --prefer-linear`. Devs never touch Linear directly; PMs see a
continuously-current Linear board without anyone doing double-entry.

**This repo contains:**
- `PLAN.md` — the architecture and execution plan (source of truth for decisions)
- `docs/initial-bead-plan.json` — the graph-apply seed that created 19 tracked beads
- Org-internal tooling (CI workflow, cron installer, runbook, backfill script) — to be built
- Planning artifacts only; the actual beads improvements go upstream as PRs to `gastownhall/beads`

**Key repos:**
- Upstream beads: `gastownhall/beads` (https://github.com/gastownhall/beads)
- Kevin's fork: `kevglynn/beads` (https://github.com/kevglynn/beads)
- This repo: `kevglynn/beads-to-linear` (https://github.com/kevglynn/beads-to-linear)
- Sandbox Linear workspace: https://linear.app/kevglynn

See `PLAN.md` §1a for per-persona descriptions of what the deployed system
looks like (devs, PMs, repo owners, project lead).

<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:ca08a54f -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

Bead prefix: `btl-`. Two epics: `btl-0bk` (centralized sync architecture),
`btl-9pf` (upstream PRs to gastownhall/beads). Run `bd ready` to see
actionable work.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

## Session Completion

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   bd dolt push
   git push
   git status  # MUST show "up to date with origin"
   ```
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed AND pushed
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing - that leaves work stranded locally
- NEVER say "ready to push when you are" - YOU must push
- If push fails, resolve and retry until it succeeds
<!-- END BEADS INTEGRATION -->


## Build & Test

This repo is primarily docs and scripts — no build step. Validate with:

```bash
bd status             # Check bead database health
bd ready              # See actionable work
python3 -c "import json; json.load(open('docs/initial-bead-plan.json'))"  # Validate plan JSON
```

## Architecture Overview

See `PLAN.md` §5 for the full architecture with Mermaid diagram. In short:

- **Write path:** Dev laptops → `git push` (carries `.beads/issues.jsonl`) → CI worker → Linear API
- **Read path:** Linear API → per-laptop `bd linear sync --pull` on 15-min jittered cron
- **Single writer:** Only the CI worker pushes to Linear (OAuth `actor=app`). Devs never push.
- **Conflict policy:** `--prefer-linear` on pulls. Linear is the org source of truth.
- **Privacy:** Wisps/ephemeral beads are excluded at export time; they never reach Linear or git.

## Conventions & Patterns

- All architecture decisions are in `PLAN.md` §9 (resolved) and tracked as `decision`-type beads
- Upstream PRs to gastownhall/beads are tracked as `task-prN` beads under `epic-upstream` (btl-9pf)
- Org-internal tooling is tracked under `epic-arch` (btl-0bk)
- Issue prefix is `btl-` (set via `bd rename-prefix`)

<!-- JAWNT_AGENT_RULES_BEGIN hash:4d2353d34d227847 -->

# Jawnt Context Rule

When questions involve multiple projects, locating a project by topic, or understanding the user's development landscape, use Jawnt MCP tools FIRST before filesystem exploration.

## Available Jawnt MCP tools

- `list_projects` — all bookmarked projects with git branch, dirty state, tech stack, beads status, plan status. Accepts optional group filter. Use for project status overview or understanding the full development landscape.
- `get_project` — full enriched context for a single project by path, path suffix, or display name.
- `search_projects` — search across project names, groups, tech stack, git branches, and commit messages. Prefer this over filesystem exploration or grep for cross-project questions.
- `get_plan` — a project's active plan: goal, status, linked beads, success criteria. Use to understand the governing initiative.
- `list_beads` — beads (issues/tasks) for a specific project or across all projects. Use for cross-project task overview.
- `get_bead` — full detail for a single bead by ID. Use after list_beads or find_ready_work.
- `find_blocked_work` — all blocked beads across projects. Answers "what's stuck?"
- `find_ready_work` — all unblocked beads ready for work, sorted by priority across ALL projects. Prefer this over running `bd ready` locally. Use when the user asks "what should I work on next?", "next task", "pick up work", or "what's ready?"
- `search_memories` — search past lessons, locked decisions, and session insights across projects. Use for "what did we learn about X?", "any past lessons?", "what decisions were locked?", or any question about institutional knowledge. Do NOT use filesystem exploration for this — memories are stored in beads, not plain files.
- `recent_activity` — recent git activity across projects sorted by commit date. Use for "what did I work on yesterday?", "which projects changed this week?", or "what did I do recently?"
- `daily_brief` — morning triage in one call: ready work + blocked work + recent activity combined. Use for "start my day", "morning triage", "daily standup", or "give me a triage report". Replaces calling find_ready_work + find_blocked_work + recent_activity separately.
- `list_groups` — all project groups with member counts.
- `list_running_processes` — active dev processes for bookmarked projects: Jawnt-launched scripts (managed) and terminal-started dev servers detected by Jawnt (detected). Stop semantics: managed scripts stop via Jawnt; detected servers must be stopped from the terminal that started them.

## When to use Jawnt

- "Which project has X?" → `search_projects`
- "What am I working on?" → `list_projects`
- "Where was I working on [topic]?" → `search_projects`
- "What's the plan for this project?" → `get_plan`
- "What's blocked?" → `find_blocked_work`
- "What should I work on next?" → `find_ready_work`
- "Next task / pick up work / what's ready?" → `find_ready_work`
- "What did we learn about [topic]?" → `search_memories`
- "Any past lessons about [topic]?" → `search_memories`
- "What decisions were locked for [project]?" → `search_memories`
- "What did I work on yesterday?" → `recent_activity`
- "Which projects changed this week?" → `recent_activity`
- "Start my day / morning triage / daily standup" → `daily_brief`
- "Give me a triage report" → `daily_brief`
- "What should I pick up, what's stuck, and what changed?" → `daily_brief`
- "What's running?" → `list_running_processes`
- "Is anything on port 3000?" → `list_running_processes`

## When NOT to use Jawnt

- Questions about code within the currently open project — use normal file tools.
- Jawnt only knows about bookmarked projects. If a project isn't in Jawnt, it won't appear.

## Anti-patterns — do NOT do these

- Do NOT scan the home directory, list directories outside the current workspace, or explore `~/.claude/`, `~/.cursor/`, or other IDE config dirs for cross-project information — Jawnt already aggregates this.
- Do NOT run `bd ready` locally when `find_ready_work` is available — the MCP tool returns priority-sorted work across ALL projects, not just the current one.
- Do NOT use filesystem grep/find to locate projects by topic or tech stack — use `search_projects` instead.
- Do NOT explore the filesystem to answer "what did we learn about X?" or "what decisions were made?" — use `search_memories`, which searches bd remember entries across all projects.

## Fallback

If Jawnt MCP tools are unavailable, check ~/.jawnt/context.json which contains the same enriched project graph as a JSON file. Do NOT scan the user's home directory or list filesystem contents to find projects — this is slow, token-wasteful, and exposes sensitive paths.
## Claude Code — critical tool-routing reminders

Claude Code agents MUST use Jawnt MCP tools for cross-project queries. Common mistakes to avoid:

1. **Institutional knowledge queries** ("what did we learn?", "any past lessons?", "what decisions were locked?") → call `search_memories` FIRST. Do not search the filesystem, read random files, or time out exploring directories.
2. **Ready work queries** ("what should I work on?", "next task", "what's ready?") → call `find_ready_work`. Do not run `bd ready` in a shell — the MCP tool gives priority-sorted results across ALL projects.
3. **Cross-project queries** ("which project uses X?", "where was I working on Y?") → call `search_projects`. Do not list directories under `~`, explore `~/.claude/`, or scan the filesystem.
4. **Project status** ("what am I working on?", "show my projects") → call `list_projects` or fetch `jawnt://status`. Do not construct this by reading git repos individually.

When in doubt, call the Jawnt MCP tool. It is faster, more complete, and avoids security/privacy risks from filesystem exploration.

<!-- JAWNT_AGENT_RULES_END -->
