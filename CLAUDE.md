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
