# Jira → Linear → Beads Backfill Runbook

**Last updated:** 2026-05-02
**Audience:** Project lead, ops engineers running the Jira-to-Linear migration
**Architecture reference:** [PLAN.md §8](../../PLAN.md) (backfill plan)
**Script:** [`scripts/jira-to-linear-backfill.sh`](../../scripts/jira-to-linear-backfill.sh)

---

## Overview

This runbook covers the one-time migration of issues from Jira to Linear, then reconciling beads with the resulting Linear state. The order of operations is critical — doing it wrong creates duplicates that require significant manual cleanup.

**Scope (decision d7):** All open Jira issues + last 12 months of closed issues. Older closed issues stay in the Jira archive.

### The 5-Step Sequence

| Step | Action | Who | Mode |
|------|--------|-----|------|
| 1 | Validate Linear's native Jira import | Script (validation only) | Automated |
| 2 | Stabilize imported data | Human + script checks | Semi-manual |
| 3 | Beads create-only push | Script via `bd linear sync` | Automated |
| 4 | External_ref reconciliation | Script (match beads ↔ Linear) | Automated |
| 5 | Switch to bidirectional sync | Script + human verification | Semi-manual |

---

## Prerequisites

### Tools

- `bd` — beads CLI ([gastownhall/beads](https://github.com/gastownhall/beads))
- `jq` — JSON processor
- `curl` — HTTP client
- `git` — version control

### Credentials

| Credential | Where | Purpose |
|------------|-------|---------|
| `LINEAR_API_KEY` | Shell env var | API access for validation and pull sync |
| `LINEAR_OAUTH_TOKEN` | Shell env var (optional) | OAuth token for write operations |
| Jira admin access | Jira web UI | Needed for the native import in step 1 |
| Linear workspace admin | Linear web UI | Needed to run the Jira importer |

### Before You Start

1. **Read [PLAN.md §8](../../PLAN.md)** — understand the full rollout context
2. **Verify beads health:**

   ```bash
   bd doctor --agent
   ```

3. **Export latest beads:**

   ```bash
   bd export --exclude-type wisp --exclude-type memory
   ```

4. **Validate config against org template:**

   ```bash
   bash scripts/validate-config.sh
   ```

5. **Back up the current state:**

   ```bash
   git stash  # if you have uncommitted changes
   cp -f .beads/external_refs.json .beads/external_refs.json.bak
   ```

---

## Running the Script

### Dry Run (always do this first)

Preview every step without making changes:

```bash
bash scripts/jira-to-linear-backfill.sh \
  --jira-project PROJ \
  --dry-run
```

Expected output: each step prints what it *would* do, with issue counts, match previews, and config checks. No Linear API writes, no state changes.

### Live Run

Execute the full sequence with confirmation prompts between steps:

```bash
bash scripts/jira-to-linear-backfill.sh \
  --jira-project PROJ
```

The script prompts for confirmation before each step and between steps. You can abort at any prompt by entering `n`.

### Resume After Interruption

The script tracks progress in `.backfill-state.json`. If interrupted, re-run and it picks up where it left off:

```bash
# Auto-resume from where it stopped
bash scripts/jira-to-linear-backfill.sh

# Or explicitly resume from a specific step
bash scripts/jira-to-linear-backfill.sh --step 3
```

### Check Progress

```bash
bash scripts/jira-to-linear-backfill.sh --status
```

### Start Over

```bash
bash scripts/jira-to-linear-backfill.sh --reset
```

---

## Step-by-Step Details

### Step 1: Validate Jira Import

**What happens:** The script checks whether Linear's native Jira importer has been run by counting issues in the target Linear team and searching for Jira key patterns in issue descriptions.

**Before this step — the manual Jira import:**

1. Open Linear → **Settings → Import & Export → Import from Jira**
2. Select the Jira project (e.g., `PROJ`)
3. Configure the import scope:
   - **All open issues** — import all
   - **Closed issues** — last 12 months only (decision d7)
   - **Attachments** — import (Linear handles this natively)
   - **Comments** — import (preserves Jira discussion history)
4. Map Jira users to Linear members when prompted
5. Start the import and **wait for it to complete** (Linear shows progress)

**Why Linear's native importer first:** It preserves Jira issue keys, establishes Jira ↔ Linear ID mappings natively, and handles attachment migration — none of which the beads sync can do.

**If the script says "No issues found":**
- Verify you ran the Jira import in Linear
- Check the `--linear-team` value matches the team that received the import
- Check that the `--jira-project` key is correct (case-sensitive)

### Step 2: Stabilize Imported Data

**What happens:** The script counts issues by state, checks for unassigned issues (user mapping gaps), validates hierarchy, and prompts you to verify the import manually.

**Manual checklist:**

- [ ] **Jira epics** mapped correctly to Linear projects or parent issues
- [ ] **Jira users** mapped to correct Linear members (check unassigned issues)
- [ ] **Labels and status** mappings look correct in Linear's board view
- [ ] **No duplicate issues** — scan the board for obvious duplicates
- [ ] **Jira-sync transition mode** is still active in Linear (if you need to keep Jira live during migration)

**Fixing common issues:**

| Problem | Fix |
|---------|-----|
| Unassigned issues | Reassign in Linear → bulk select → assign |
| Wrong status mapping | Update Linear workflow states to match Jira states |
| Missing labels | Create labels in Linear that match Jira labels |
| Duplicate issues | Archive duplicates in Linear (check which is the import and which is manual) |

### Step 3: Beads Create-Only Push

**What happens:** The script runs `bd linear sync --push --create-only`, which pushes beads that don't already have a Linear counterpart (no `external_ref`). Beads that are already linked to Linear issues are skipped.

**Key property:** `--create-only` prevents overwriting any Jira-imported data in Linear. It only creates new issues for beads that have no Linear match yet.

**If push fails:**
- Check Linear API credentials: `echo $LINEAR_API_KEY`
- Check team configuration: `bd config get linear.team_ids`
- Check state mapping: `bd config get linear.state_map`
- Check the bd error output for specific field mapping issues

**If too many beads would be pushed:**
- Review which beads lack `external_ref` — they may need manual matching (step 4)
- Some may be wisps that should be filtered: `bd export --exclude-type wisp`

### Step 4: External_ref Reconciliation

**What happens:** The script tries to match unlinked beads to existing Linear issues by:

1. Searching for the bead's idempotency marker (`<!-- bd-idempotency: <bead_id> -->`) in Linear issue descriptions
2. Searching for the Jira key (e.g., `PROJ-123`) in Linear issue descriptions (for beads that had Jira refs)

**Matched beads** get their `external_ref` updated in `.beads/external_refs.json` to point at the Linear issue.

**Unmatched beads** are logged. They will be created as new Linear issues on the next full sync push. Review unmatched beads to verify they genuinely don't have Linear counterparts.

**If too many beads are unmatched:**
- The Jira importer may not have preserved Jira keys in descriptions — check a sample issue in Linear
- The search may have hit Linear API pagination limits — run step 4 again to catch remaining matches
- Some beads may pre-date the Jira project — these correctly have no match

**Manual reconciliation for stubborn cases:**

```bash
# Find the bead
bd show <bead-id>

# Search Linear manually
# In Linear: Cmd+K → search for the issue title

# Link manually via external-refs helper
source scripts/lib/external-refs.sh
set_external_ref "<bead-id>" "<linear-issue-uuid>" "https://linear.app/<team>/issue/<identifier>"
```

### Step 5: Switch to Bidirectional Sync

**What happens:** The script validates the sync configuration, checks pull cron status, runs a test pull, and verifies external_ref coverage.

**Before confirming:**

1. **CI worker must be deployed** — the `linear-sync` GitHub Actions workflow should be active and triggered on pushes to `main` that touch `.beads/issues.jsonl`
2. **Pull cron must be installed** on developer laptops:

   ```bash
   bash scripts/install-pull-cron.sh
   ```

3. **Verify a round-trip:**
   - Edit a bead locally: `bd update <id> --priority 2`
   - Push to git: `git add .beads/issues.jsonl && git commit -m "test" && git push`
   - Wait for CI worker to push to Linear
   - Check the issue in Linear — priority should be updated
   - Run manual pull: `bd linear sync --pull --prefer-linear`
   - The bead should reflect any Linear-side changes

**After completing step 5:**

1. Disable Linear's Jira-sync transition mode (if it was active)
2. Announce to the team that beads ↔ Linear sync is live
3. Decommission the Jira project when ready (or archive it)

---

## State File

The script tracks progress in `.backfill-state.json` at the repo root. This file:

- Records which steps have been completed
- Stores step results (issue counts, match counts, etc.)
- Preserves the Jira project key and Linear team for resume
- Is **not** committed to git (add to `.gitignore` if desired)

**Schema:**

```json
{
  "version": 1,
  "jira_project": "PROJ",
  "linear_team": "KEV",
  "started_at": "2026-05-02T14:00:00Z",
  "completed_steps": [1, 2],
  "step_results": {
    "1": {
      "total_issues": 150,
      "jira_imported": 120,
      "team": "KEV",
      "completed_at": "2026-05-02T14:05:00Z"
    },
    "2": {
      "total": 150,
      "open": "85",
      "closed": "65",
      "completed_at": "2026-05-02T14:30:00Z"
    }
  },
  "last_step_at": "2026-05-02T14:30:00Z"
}
```

---

## Troubleshooting

### "No issues found in Linear team"

- Verify the Jira import was run in Linear (Settings → Import & Export)
- Check `--linear-team` matches the team that received the import
- The Linear team key is case-sensitive

### "No Jira-imported issues detected"

- Linear's importer may not preserve Jira keys in the description for all import modes
- Try proceeding (the script will ask for confirmation) — step 4 reconciliation uses multiple matching strategies

### Linear API rate limit (429)

- The reconciliation step (4) makes many API calls for large backlogs
- Wait for the rate limit window to reset (check `Retry-After` header)
- Resume with `--step 4` — the script picks up where it left off

### Beads create-only push creates duplicates

- This means step 4 (reconciliation) missed some matches
- Archive the duplicates in Linear
- Manually link the correct issues:

  ```bash
  source scripts/lib/external-refs.sh
  set_external_ref "<bead-id>" "<linear-uuid>" "<linear-url>"
  ```

### Script hangs at confirmation prompt

- The script requires interactive input in live mode
- Use `--dry-run` for non-interactive preview
- In CI environments, confirmation prompts block — this script is designed for interactive use

### State file corruption

- Reset and start over: `bash scripts/jira-to-linear-backfill.sh --reset`
- Steps are idempotent — re-running completed steps is safe

---

## Rollback

If something goes wrong during the backfill:

### Partial rollback (undo steps 3-5 only, preserve Jira import)

```bash
# 1. Remove external_refs created by the script
cp -f .beads/external_refs.json.bak .beads/external_refs.json

# 2. Archive beads-created issues in Linear (if step 3 ran)
# Use Linear's bulk actions or the sync audit log

# 3. Reset backfill state
bash scripts/jira-to-linear-backfill.sh --reset

# 4. Disable pull cron (if step 5 enabled it)
bash scripts/install-pull-cron.sh --uninstall
```

### Full rollback (undo everything including Jira import)

```bash
# 1-4 from partial rollback above, plus:

# 5. In Linear: Settings → bulk archive or delete imported issues
#    (within 7-day soft-delete window)

# 6. Revert beads state
cd $REPO_ROOT
git checkout .beads/external_refs.json
```

### Beads data is always safe

Beads is local-first. The backfill script never modifies the beads database directly — it only writes to `.beads/external_refs.json` (the linking layer). Your local beads data (`bd list`, `bd show`) is unaffected by any rollback.

---

## CLI Reference

```
Usage: jira-to-linear-backfill.sh [OPTIONS]

Options:
  --dry-run                Preview each step's actions without executing
  --step N                 Resume from step N (1-5). Default: auto-detect
  --jira-project KEY       Jira project key (e.g., PROJ). Required on first run
  --linear-team KEY        Linear team key (e.g., KEV). Default: from config
  --reset                  Clear backfill state and start fresh
  --status                 Show current backfill progress and exit
  --help                   Show this help

Exit codes:
  0   All steps completed (or dry-run finished)
  1   Fatal error (missing deps, failed precondition, API error)
  2   User aborted at confirmation prompt

Environment:
  LINEAR_API_KEY             Personal Linear API key
  LINEAR_OAUTH_TOKEN         OAuth token (preferred for writes)
  LINEAR_API_URL             Override Linear API endpoint (default: https://api.linear.app/graphql)
```

---

## Cross-References

- **Architecture:** [PLAN.md §5](../../PLAN.md) — recommended architecture
- **Backfill plan:** [PLAN.md §8](../../PLAN.md) — the 5-step sequence and rollout phases
- **Linear sync runbook:** [linear-sync.md](./linear-sync.md) — ongoing operations
- **Config template:** [templates/.beads/config.yaml](../../templates/.beads/config.yaml)
- **External refs library:** [scripts/lib/external-refs.sh](../../scripts/lib/external-refs.sh)
- **Bead:** `btl-53l` — tracking bead for this work
