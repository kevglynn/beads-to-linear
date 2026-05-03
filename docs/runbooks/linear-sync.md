# Linear Sync Operations Runbook

**Last updated:** 2026-05-02
**Audience:** Ops engineers, team leads, anyone maintaining the beads ↔ Linear sync
**Architecture reference:** [PLAN.md §5](../../PLAN.md) (recommended architecture)

---

## Table of Contents

1. [Adding a New Developer](#1-adding-a-new-developer)
2. [Offboarding a Developer](#2-offboarding-a-developer)
3. [Rotating OAuth Credentials](#3-rotating-oauth-credentials)
4. [Handling Linear API Outage](#4-handling-linear-api-outage)
5. [Debugging a Sync Conflict](#5-debugging-a-sync-conflict)
6. [Adding a New Linear Team](#6-adding-a-new-linear-team)
7. [Recovering from Mass Bad Sync](#7-recovering-from-mass-bad-sync)
8. [Reading the Sync Audit Log](#8-reading-the-sync-audit-log)
9. [CI Worker Troubleshooting](#9-ci-worker-troubleshooting)
10. [Monitoring and Alerting](#10-monitoring-and-alerting)

---

## 1. Adding a New Developer

**When to use this:** A new developer joins the team and needs local beads ↔ Linear pull sync.

**Prerequisites:**
- Developer has `bd` installed and on their `PATH` (verify: `bd version`)
- Developer has `git clone` access to the project repository
- Developer has a Linear account in the org workspace
- Developer has generated a personal Linear API key at **Settings → API → Personal API keys** in Linear

### Steps

#### 1.1 Generate and export the Linear API key

The developer generates a personal API key in Linear and exports it in their
shell profile (`~/.zshrc`, `~/.bashrc`, etc.):

```bash
echo 'export LINEAR_API_KEY="lin_api_XXXXXXXXXXXXXXXXXXXX"' >> ~/.zshrc
source ~/.zshrc
```

**CRITICAL:** The key must NEVER be stored in `.beads/config.yaml`. That file
is git-tracked and commits would leak the credential to every collaborator.
See [PLAN.md §6 PR-1](../../PLAN.md) for the upstream fix that enforces this.

Verify the key is set:

```bash
echo $LINEAR_API_KEY
# Expected: lin_api_XXXXXXXXXXXXXXXXXXXX (not empty)
```

#### 1.2 Verify beads database health

```bash
cd $REPO_ROOT
bd doctor --agent
```

Expected output includes `SUMMARY: ok`. If the summary reports issues,
follow the remediation commands in the output before proceeding.

#### 1.3 Install the pull cron

```bash
cd $REPO_ROOT
bash scripts/install-pull-cron.sh
```

The script:
- Installs a cron job that runs `bd linear sync --pull --prefer-linear` every 15 minutes with random jitter (up to 180s)
- Validates that `LINEAR_API_KEY` is set in the environment
- Refuses to install if `linear.api_key` is present in `.beads/config.yaml`

Expected output:

```
✓ LINEAR_API_KEY is set
✓ No linear.api_key found in .beads/config.yaml
✓ Cron job installed: bd linear sync --pull --prefer-linear
  Schedule: */15 * * * * (with jitter up to 180s)
```

#### 1.4 Verify first sync works

Run a manual pull to confirm connectivity:

```bash
cd $REPO_ROOT
bd linear sync --pull --prefer-linear
```

Expected output:

```
Linear sync complete (pull)
  Pulled: N issues
  Created locally: N
  Updated locally: N
  Conflicts resolved (prefer-linear): N
  Errors: 0
```

If errors appear, check:
- `LINEAR_API_KEY` is valid (not expired or revoked)
- `linear.team_ids` in `.beads/config.yaml` includes the correct team
- Network connectivity to `https://api.linear.app/graphql`

#### 1.5 Configure state mapping

Set the push-target state mappings (Linear state → beads status):

```bash
bd config set linear.state_map.todo open
bd config set linear.state_map.in\ progress in_progress
bd config set linear.state_map.done closed
```

**Critical:** Each beads status must map to exactly one Linear state for
push. Adding duplicate mappings (e.g., both "todo" and "backlog" → "open")
causes push to fail with an ambiguity error. Pull-direction type defaults
(backlog→open, canceled→closed, etc.) work without explicit entries.

If push fails with `maps beads status "X" to multiple Linear states`,
remove the extra mapping: `bd config unset linear.state_map.<name>`.

#### 1.6 Validate config against org template

Compare the developer's config against the org template:

```bash
diff <(grep -E '^linear\.' $REPO_ROOT/.beads/config.yaml | sort) \
     <(grep -E '^linear\.' $REPO_ROOT/templates/.beads/config.yaml | sort)
```

Key fields that must match the org template:
- `linear.team_ids`
- `linear.priority_map.*`
- `linear.state_map.*`
- `linear.label_type_map.*`
- `linear.id_mode`

Fix any drift before the developer starts working.

---

## 2. Offboarding a Developer

**When to use this:** A developer leaves the team or org and their sync access needs to be revoked.

**Prerequisites:**
- Know the developer's Linear username/email
- Know which beads they have in-progress (`bd list --status=in_progress`)
- Have access to Linear workspace admin settings

### Steps

#### 2.1 Revoke the Linear API key

In Linear: **Settings → API → Personal API keys** (workspace admin view).
Locate the departing developer's key and revoke it. The key becomes invalid
immediately — their next cron pull will fail silently (expected behavior).

If the developer created the key themselves, they can also revoke it from
their own settings page during their offboarding checklist.

#### 2.2 Remove the pull cron

On the developer's machine (or have them run this before laptop return):

```bash
cd $REPO_ROOT
bash scripts/install-pull-cron.sh --uninstall
```

Expected output:

```
✓ Cron job removed for: bd linear sync --pull
```

If the machine is already wiped, the cron is harmless — it will fail on
every attempt because the API key is revoked, and the cron entry will be
orphaned until the machine is reimaged.

#### 2.3 Reassign in-progress beads

List the departing developer's in-progress work:

```bash
bd list --status=in_progress
```

For each bead assigned to the departing developer:

```bash
bd update <bead-id> --assign <new-owner>
```

If the bead should be returned to the backlog instead:

```bash
bd update <bead-id> --status=open --unassign
```

#### 2.4 Audit Linear issues attributed to the departing developer

Check which Linear issues were last modified by the departing developer's
sync runs. Their personal API key was used for pull-only operations, so the
CI worker (OAuth `actor=app`) is the only entity that wrote to Linear on
their behalf. No Linear issues need reassignment for auth reasons.

However, review any Linear issues assigned to the departing developer and
reassign in Linear's UI as part of the standard offboarding workflow.

#### 2.5 Clean up environment variable references

If the org uses a shared dotfiles repo or secrets manager, remove the
departing developer's `LINEAR_API_KEY` entry.

---

## 3. Rotating OAuth Credentials

**When to use this:** Scheduled credential rotation, suspected compromise, or the 30-day OAuth token TTL is approaching and you want a proactive rotation of the underlying client secret.

**Prerequisites:**
- Access to Linear's developer portal (workspace admin)
- Access to CI secrets management (GitHub Actions secrets, or equivalent)
- The CI worker is currently operational

### Steps

#### 3.1 Generate a new client secret

In Linear: **Settings → API → OAuth applications → [your app] → Regenerate client secret**.

Copy the new `client_secret`. The old secret remains valid for up to 30 days
(existing tokens minted with it continue to work until they expire).

#### 3.2 Update CI secrets

In GitHub Actions (or your CI provider):

```bash
# GitHub CLI
gh secret set LINEAR_OAUTH_CLIENT_SECRET --body "<new-client-secret>" --repo <org>/<repo>
```

For other CI providers, update the equivalent secret store. The
`LINEAR_OAUTH_CLIENT_ID` does not change during rotation — only the secret.

#### 3.3 Verify CI worker authenticates with new credential

Trigger a manual CI run to confirm:

```bash
# GitHub Actions
gh workflow run linear-sync.yml --repo <org>/<repo>
```

Watch the run logs for successful OAuth token acquisition:

```
OAuth token acquired (actor=app, expires_in=2592000)
```

If the run fails with an auth error:
- Verify the new secret was saved correctly (no trailing whitespace)
- Verify `LINEAR_OAUTH_CLIENT_ID` is still correct
- Check Linear's developer portal — ensure the OAuth app is still active

#### 3.4 Old credential expiration

The old `client_secret` auto-expires based on Linear's token TTL (30 days).
Existing access tokens minted with the old secret continue to work until
their individual TTL expires. No explicit revocation is needed unless
compromise is suspected.

**If compromise is suspected:** Revoke the OAuth app entirely in Linear's
developer portal, create a new OAuth app, and update all CI secrets with
the new `client_id` and `client_secret`. This invalidates all existing
tokens immediately.

---

## 4. Handling Linear API Outage

**When to use this:** The CI worker fails to push, pull crons return errors, or Linear's status page reports degradation.

**Prerequisites:** None — this is a response procedure.

### Symptoms

- CI workflow `linear-sync` fails with HTTP 5xx errors or connection timeouts
- Developer pull crons log errors (visible in system cron logs: `grep bd /var/log/syslog` or `log show --predicate 'process == "bd"' --last 1h` on macOS)
- Developers report `bd linear sync --pull` failures

### Steps

#### 4.1 Check Linear's status page

```bash
open https://status.linear.app
# Or:
curl -s https://status.linear.app | grep -i "operational\|degraded\|outage"
```

If Linear reports an outage, proceed to 4.2. If Linear reports operational
but you see errors, skip to [§9 CI Worker Troubleshooting](#9-ci-worker-troubleshooting).

#### 4.2 Understand the impact

**Beads continues working locally.** The local-first design means developers
can `bd create`, `bd update`, `bd close`, `bd list` with zero degradation.
No developer workflow is blocked by a Linear outage.

**What stops during the outage:**
- CI push to Linear: new/updated beads queue in git (`.beads/issues.jsonl` accumulates deltas)
- Per-laptop pulls: developers don't receive Linear-side updates (PM priority changes, status updates)

#### 4.3 CI pushes queue automatically

The CI worker triggers on git push events. During a Linear outage:
1. Developers continue pushing code (and `.beads/issues.jsonl` updates) to git
2. The CI workflow runs and fails — the failure is recorded in CI logs
3. Subsequent pushes carry the accumulated JSONL delta

**When Linear recovers:** The next git push (or manual CI re-trigger) picks
up all accumulated changes and pushes them to Linear in one batch. No manual
intervention is needed.

```bash
# To manually re-trigger after recovery:
gh workflow run linear-sync.yml --repo <org>/<repo>
```

#### 4.4 Pull crons fail gracefully

Per-laptop pull crons that fail during an outage simply exit non-zero. The
next cron attempt (15 minutes later) retries automatically. No cleanup is
needed.

Developers who need a Linear update urgently can run a manual pull after
recovery:

```bash
bd linear sync --pull --prefer-linear
```

#### 4.5 Communication

If the outage lasts more than one cron cycle (15+ minutes), notify the team:
- Beads continues working locally — no workflow changes needed
- Linear board is stale until recovery — PMs should be aware
- Pushes will catch up automatically when Linear recovers

---

## 5. Debugging a Sync Conflict

**When to use this:** A developer reports that a bead's local state doesn't match Linear, or the CI worker logs a conflict resolution.

**Prerequisites:**
- Access to CI logs (to see worker push outcomes)
- The `bd linear history` command is available (requires upstream PR-8)

### Steps

#### 5.1 Check recent sync history

```bash
cd $REPO_ROOT
bd linear history
```

Expected output:

```
Run ID       Timestamp             Push  Pull  Conflicts  Errors
─────────    ────────────────────  ────  ────  ─────────  ──────
run-a1b2c3   2026-05-02T14:00:00  12    0     1          0
run-d4e5f6   2026-05-02T13:45:00  0     8     0          0
...
```

#### 5.2 Identify the conflicting bead

```bash
bd linear history --detail <run-id>
```

Expected output:

```
Run: run-a1b2c3
Timestamp: 2026-05-02T14:00:00Z
Direction: push

Issues:
  btl-xyz  PUSHED     Created in Linear as KEV-42
  btl-abc  CONFLICT   Local: status=in_progress, Linear: status=done
                       Resolution: prefer-linear → status=done
  btl-def  PUSHED     Updated title in Linear
```

#### 5.3 Inspect local and remote state

```bash
# Local state
bd show <bead-id>

# Check the external_ref to find the Linear issue
bd show <bead-id> | grep external_ref
# Expected: https://linear.app/kevglynn/issue/KEV-42/...
```

Open the Linear issue URL to compare field-by-field.

#### 5.4 Resolve the conflict

The default conflict policy is `--prefer-linear` on pulls (Linear wins).
If the developer's local state should take precedence:

1. Edit the bead locally to reflect the desired state:
   ```bash
   bd update <bead-id> --status=in_progress  # or whatever the correct state is
   ```

2. Commit and push to git:
   ```bash
   git add .beads/issues.jsonl
   git commit -m "fix: correct status for <bead-id>"
   git push
   ```

3. The CI worker picks up the push and updates Linear with the local state.

4. Verify on the next pull:
   ```bash
   bd linear sync --pull --prefer-linear
   bd show <bead-id>
   ```

#### 5.5 Recurring conflicts

If the same bead repeatedly conflicts, check:
- Is a PM changing the issue in Linear between pull cycles?
- Is the developer editing the bead locally between push cycles?
- Are two developers editing the same bead?

Resolution: coordinate on who "owns" the field in question. The architecture
enforces `--prefer-linear` on pulls, so Linear edits always win on the
next pull cycle. Developers override by pushing through git → CI.

---

## 6. Adding a New Linear Team

**When to use this:** A new team is adopting the beads ↔ Linear sync, or a new Linear team is created that needs to receive beads.

**Prerequisites:**
- The new team exists in the Linear workspace
- You know the team's Linear team ID (find it in Linear: **Settings → Teams → [team] → Team ID**)
- You have access to `.beads/config.yaml` in the project repo

### Steps

#### 6.1 Update project config

Add the new team ID to `linear.team_ids` in `.beads/config.yaml`:

```yaml
linear:
  team_ids: "EXISTING_ID,NEW_TEAM_ID"
```

Commit the change:

```bash
git add .beads/config.yaml
git commit -m "chore: add Linear team NEW_TEAM_ID to sync config"
git push
```

#### 6.2 Update CI worker config

If the CI worker uses environment-variable overrides for team IDs, update
the CI secret:

```bash
gh secret set LINEAR_TEAM_IDS --body "EXISTING_ID,NEW_TEAM_ID" --repo <org>/<repo>
```

If the CI worker reads from `.beads/config.yaml` (the default), the git
push in 6.1 is sufficient.

#### 6.3 Run initial sync with `--create-only`

To avoid overwriting existing Linear issues in the new team, run the first
sync in create-only mode:

```bash
bd linear sync --push --create-only --team NEW_TEAM_ID
```

This creates Linear issues for beads that don't yet have an `external_ref`
but skips updates to any issues that already exist in Linear.

#### 6.4 Verify the mapping with dry-run

Before enabling ongoing sync, verify what would be synced:

```bash
bd linear sync --push --dry-run --team NEW_TEAM_ID
```

Expected output:

```
Dry run — no changes will be made to Linear

Would create: 15 issues
Would update: 0 issues
Would archive: 0 issues
```

Review the "would create" list. If issues show up as "would update" that
you don't want touched, investigate their `external_ref` mapping.

#### 6.5 Enable ongoing sync

Once the initial create-only sync is verified, the CI worker's normal
push flow handles the new team automatically (multi-team routing uses
`linear.team_ids`). No further configuration is needed.

Notify developers on the new team to run [§1 Adding a New Developer](#1-adding-a-new-developer) to set up their pull cron.

---

## 7. Recovering from Mass Bad Sync

**When to use this:** A bad push synced incorrect data to Linear at scale — wrong mappings, corrupted JSONL, bulk status changes, etc.

**Prerequisites:**
- Access to CI workflow controls (to disable the worker)
- Access to the sync audit log (requires upstream PR-8)
- Access to Linear workspace admin

### STOP — Disable the CI workflow immediately

```bash
# GitHub Actions — disable the workflow
gh workflow disable linear-sync.yml --repo <org>/<repo>
```

This prevents further damage while you assess.

### Steps

#### 7.1 Assess the damage

Determine what was synced and when:

```bash
bd linear history --since <disaster-time>
```

For a specific run:

```bash
bd linear history --detail <run-id>
```

This shows every issue that was created, updated, or archived in that run,
with before/after values.

#### 7.2 Determine recovery path

**If the audit log exists (PR-8 has landed):**

The audit log records every Linear mutation with bead ID, Linear issue ID,
field-level before/after values, and timestamps. Use the rollback script:

```bash
# Preview what would be rolled back
bash scripts/audit/rollback-sync.sh <run-id> --dry-run

# Execute the rollback
bash scripts/audit/rollback-sync.sh <run-id>
```

The script reads the audit log for the specified run, generates compensating
GraphQL mutations that restore each Linear issue to its pre-sync state, and
executes them via the OAuth credential.

**If the audit log does NOT exist:**

Manual reconciliation is required:

1. In Linear, use **Settings → Audit log** to see recent changes attributed to the OAuth app
2. For each incorrectly modified issue, use Linear's issue history (visible in the issue's activity feed) to identify the pre-sync state
3. Manually revert each issue in Linear's UI, or script bulk updates via the GraphQL API

#### 7.3 Fix the root cause

Common causes of mass bad sync:
- **JSONL merge conflict markers** in `.beads/issues.jsonl` (git conflict not resolved before push)
- **Mapping misconfiguration** (`linear.state_map.*` or `linear.priority_map.*` changed incorrectly)
- **Corrupted beads database** (`bd doctor --agent` to check)
- **Wrong team ID** (issues pushed to the wrong Linear team)

Fix the root cause before re-enabling the CI workflow.

#### 7.4 Re-enable the CI workflow

```bash
# Verify the fix
bd linear sync --push --dry-run

# Re-enable
gh workflow enable linear-sync.yml --repo <org>/<repo>

# Trigger a manual run to verify
gh workflow run linear-sync.yml --repo <org>/<repo>
```

Monitor the first run closely — check CI logs and `bd linear history` for
the new run's outcomes.

#### 7.5 Post-incident

- Document what happened in the team's incident log
- If a new failure mode was discovered, file a bead for a preventive fix
- If the audit log was missing and would have helped, track PR-8's status

---

## 8. Reading the Sync Audit Log

**When to use this:** Routine monitoring, forensics, compliance auditing, or debugging sync behavior.

**Prerequisites:**
- `bd linear history` subcommand is available (requires upstream PR-8)

### Commands

#### Last 10 sync runs

```bash
bd linear history
```

Expected output:

```
Run ID       Timestamp             Direction  Push  Pull  Conflicts  Errors
─────────    ────────────────────  ─────────  ────  ────  ─────────  ──────
run-a1b2c3   2026-05-02T14:00:00  push       12    0     1          0
run-d4e5f6   2026-05-02T13:45:00  pull       0     8     0          0
run-g7h8i9   2026-05-02T13:30:00  push       3     0     0          0
...
```

#### Filter by date range

```bash
bd linear history --since 2026-05-01
bd linear history --since 2026-05-01 --until 2026-05-02
```

#### Detailed per-issue breakdown

```bash
bd linear history --detail <run-id>
```

Expected output:

```
Run: run-a1b2c3
Timestamp: 2026-05-02T14:00:00Z
Direction: push
Duration: 2.3s

Issues:
  Bead ID    Linear ID   Action    Details
  ────────   ─────────   ────────  ───────
  btl-xyz    KEV-42      CREATED   Title: "Fix login bug"
  btl-abc    KEV-18      UPDATED   status: open → in_progress
  btl-def    KEV-31      CONFLICT  priority: 2 (local) vs 1 (linear), resolved: prefer-linear
  btl-ghi    KEV-55      ARCHIVED  Bead removed from JSONL

Errors: none
```

#### JSON export for programmatic analysis

```bash
bd linear history --json > report.json
```

The JSON format includes full before/after values for each mutation,
suitable for feeding into monitoring dashboards or compliance tooling.

#### Query helpers (scripts/audit/)

Pre-built queries for common audit questions:

```bash
# All conflicts in the last 7 days
bash scripts/audit/query-conflicts.sh --since 7d

# All issues created via sync (vs. natively in Linear)
bash scripts/audit/query-created.sh --since 30d

# All archived issues (beads that disappeared from JSONL)
bash scripts/audit/query-archived.sh --since 30d
```

---

## 9. CI Worker Troubleshooting

**When to use this:** The `linear-sync` CI workflow is failing, and you need to diagnose and fix it.

**Prerequisites:**
- Access to CI logs (GitHub Actions or equivalent)
- Access to CI secrets management

### Quick reference

| Script | Purpose | Invocation |
|--------|---------|------------|
| `scripts/ci-linear-push.sh` | CI worker push entrypoint | Called by workflow; also `bash scripts/ci-linear-push.sh --dry-run` locally |
| `scripts/ci-linear-push.sh --max-delta N` | Override volume safety threshold | When a legitimate bulk push is needed |
| `scripts/lib/external-refs.sh --self-test` | Validate external refs library | `bash scripts/lib/external-refs.sh --self-test` |

### Check CI logs

```bash
# GitHub Actions — view recent runs
gh run list --workflow=linear-sync.yml --repo <org>/<repo> --limit 5

# View logs for a specific run
gh run view <run-id> --repo <org>/<repo> --log

# Download sync log artifact
gh run download <run-id> --repo <org>/<repo> --name sync-log-<run-id>
```

### Common failures

#### Push-volume safety check blocked (exit code 2)

**Symptoms:** Logs show `Push-volume safety check FAILED` with exit code 2.

**Cause:** More new beads (without existing external refs) than the
`BTL_MAX_PUSH_DELTA` threshold (default: 100). This usually means a bad
merge brought in a large JSONL, a bulk import, or corrupted data.

**Diagnosis:**

```bash
# Check how many beads lack external refs
jq -r '.id' .beads/issues.jsonl | wc -l
jq '.refs | length' .beads/external_refs.json
```

**Resolution:**
- If the push is legitimate (e.g., first sync of a large project): re-run
  the workflow via `workflow_dispatch` with a higher `max_delta` value, or
  set `BTL_MAX_PUSH_DELTA=<N>` in the CI environment.
- If the push is accidental (bad merge): revert the commit, fix the JSONL,
  and push again.

#### bd not found or build failure

**Symptoms:** `bd is not on PATH` or Go compilation errors during the
"Install bd" step.

**Diagnosis:** The workflow installs bd from the `gastownhall/beads` GitHub
releases or builds from source using Go. Check:
- Is the `BD_VERSION` in the workflow YAML still valid?
- Is `gastownhall/beads` accessible from the runner?
- Is Go available on the runner?

**Resolution:** Update `BD_VERSION` in `.github/workflows/linear-sync.yml`
to match the latest beads release tag.

#### Rate limit hit (HTTP 429)

**Symptoms:** Logs show `429 Too Many Requests` or `rate limit exceeded`.

**Diagnosis:**

```bash
# Check the logs for rate limit headers
gh run view <run-id> --repo <org>/<repo> --log | grep -i "rate.limit\|retry-after"
```

**Resolution:**
- If using personal API key: 2,500 req/hr limit. Switch to OAuth `actor=app` for 5,000+ req/hr with dynamic scaling.
- If using OAuth: check workspace paid-user count — rate limit scales with it.
- If a large batch triggered the limit: the worker retries automatically with backoff. Wait for the next run.
- If `Retry-After` header parsing is available (PR-6): the worker respects the server's hint automatically.

#### Auth header format mismatch

**Symptoms:** 400 error with `"It looks like you're trying to use an API key as a Bearer token"`.

**Cause:** Personal API keys (`lin_api_*`) use `Authorization: <key>` (no
Bearer prefix). OAuth tokens (`lin_oauth_*`) use `Authorization: Bearer <token>`.
Mixing these up produces a 400.

**Resolution:** Ensure the CI worker uses the correct header format for its
credential type. The `bd` CLI handles this automatically, but custom scripts
or curl commands must match the format to the token type.

#### Auth expired (HTTP 401)

**Symptoms:** Logs show `401 Unauthorized` or `invalid_token`.

**Diagnosis:**
- OAuth token TTL is 30 days. If the CI worker hasn't run in 30+ days, the cached token expired.
- Check if the OAuth app was revoked in Linear's developer portal.

**Resolution:**

```bash
# If OAuth — the worker auto-fetches a new token on 401 (PR-3).
# If it still fails, verify the client_secret is current:
gh secret list --repo <org>/<repo> | grep LINEAR_OAUTH

# If personal API key — verify it's not revoked:
# (Have the key owner check Linear → Settings → API → Personal API keys)
```

#### JSONL parse error

**Symptoms:** Logs show `json: cannot unmarshal` or `invalid character`.

**Diagnosis:** The `.beads/issues.jsonl` file likely contains git merge
conflict markers (`<<<<<<<`, `=======`, `>>>>>>>`).

```bash
# Check for merge conflict markers
cd $REPO_ROOT
grep -n "^<<<<<<\|^======\|^>>>>>>" .beads/issues.jsonl
```

**Resolution:**
1. Resolve the merge conflict in `.beads/issues.jsonl`
2. Regenerate a clean JSONL: `bd export --force`
3. Commit and push: `git add .beads/issues.jsonl && git commit -m "fix: resolve JSONL merge conflict" && git push`

#### Manual re-run

```bash
# Normal re-run
gh workflow run linear-sync.yml --repo <org>/<repo>

# Dry-run (no Linear writes, no git push)
gh workflow run linear-sync.yml --repo <org>/<repo> -f dry_run=true

# Override push-volume safety threshold
gh workflow run linear-sync.yml --repo <org>/<repo> -f max_delta=500

# Local dry-run for debugging (requires LINEAR_API_KEY or OAuth env vars)
bash scripts/ci-linear-push.sh --dry-run
```

Or from the GitHub Actions UI: navigate to the workflow → "Run workflow" button.

#### Nuclear option

If the CI worker's state is thoroughly confused:

```bash
# From a clean checkout on a machine with the OAuth credential:
git clone <repo> /tmp/clean-sync
cd /tmp/clean-sync
bd import .beads/issues.jsonl
bd linear sync --push --force
```

**WARNING:** `--force` overrides all conflict resolution and pushes local
state to Linear unconditionally. Use only when you are certain the local
JSONL represents the correct state. This is a destructive operation for any
Linear-side edits that haven't been pulled back.

---

## 10. Monitoring and Alerting

**When to use this:** Setting up or maintaining the observability layer for the sync system.

**Prerequisites:**
- Access to the org's monitoring platform (Grafana / Datadog / equivalent)
- CI workflow is deployed and running

### Key metrics

| Metric | Source | Healthy range |
|--------|--------|---------------|
| Sync success rate | CI workflow outcomes | ≥ 99.5% |
| Push count per run | `bd linear history --json` | Varies by team activity |
| Pull count per dev | Dev cron logs | 1 per 15-min cycle |
| API quota utilization | Linear rate-limit response headers | < 80% of limit |
| Conflict count per run | `bd linear history --json` | Low and stable (not growing) |
| Sync duration | CI workflow timing | < 60s for typical runs |
| External_ref coverage | `bd list --json \| jq '[.[] \| select(.external_ref)] \| length'` | 100% of non-wisp beads |

### Alert thresholds

| Condition | Severity | Action |
|-----------|----------|--------|
| Sync failure (any CI run) | Warning | Check [§9 CI Worker Troubleshooting](#9-ci-worker-troubleshooting) |
| 3+ consecutive sync failures | Critical | Page on-call; check [§4 Linear API Outage](#4-handling-linear-api-outage) |
| Rate limit breach (429 response) | Warning | Check quota; consider batch mutation adoption (PR-4) |
| Rate limit quota > 90% utilized | Warning | Review push volume; stagger large operations |
| Conflict count trending upward | Warning | Review who's editing the same beads; check pull cron health across devs |
| Drift: beads without `external_ref` older than 24h | Warning | CI worker may not be triggering; check workflow config |
| JSONL parse error | Critical | Merge conflict markers in JSONL; see [§9 JSONL parse error](#jsonl-parse-error) |

### Dashboard setup

See bead `btl-6mr` for the monitoring dashboard configuration. The
dashboard should display:

- **Sync health panel:** Success/failure trend over 7 days
- **Push/pull volume:** Stacked bar chart of issues synced per run
- **Conflict trend:** Line chart of conflicts per run over 30 days
- **API quota gauge:** Current utilization as percentage of limit
- **Last successful sync:** Timestamp (alert if > 30 minutes stale)

### CI-native alerting

If you don't have a dedicated monitoring platform, GitHub Actions provides
basic alerting via workflow failure notifications:

1. In the repo: **Settings → Notifications → Actions** — configure email alerts for workflow failures
2. For Slack: use the `slackapi/slack-github-action` in the workflow YAML to post failure notifications

### Health check script

For a quick manual health check:

```bash
cd $REPO_ROOT

# CI worker status
gh run list --workflow=linear-sync.yml --repo <org>/<repo> --limit 3

# Local sync status
bd linear history

# Beads without external_ref (potential sync gaps)
bd list --json | python3 -c "
import json, sys
beads = json.load(sys.stdin)
missing = [b for b in beads if not b.get('external_ref') and b.get('type') not in ('wisp', 'memory')]
if missing:
    print(f'WARNING: {len(missing)} beads without external_ref:')
    for b in missing:
        print(f'  {b[\"id\"]}: {b[\"title\"]}')
else:
    print('OK: all non-wisp beads have external_ref')
"

# Config drift check
diff <(grep -E '^linear\.' .beads/config.yaml | sort) \
     <(grep -E '^linear\.' templates/.beads/config.yaml | sort) \
  && echo "OK: config matches template" \
  || echo "WARNING: config drift detected"
```

---

## 11. Lessons from Dogfooding (2026-05-02)

Findings from the first real sync of 32 beads to Linear using this project's own workspace.

| # | Finding | Impact | Fix |
|---|---------|--------|-----|
| 1 | State map key direction is non-obvious: key=Linear state, value=beads status | Every dev will hit this on first setup | Updated config template, onboarding guide §3, and runbook §1.5 with explicit instructions |
| 2 | Push requires strict 1:1 mapping per beads status; pull is forgiving via type defaults | Adding "backlog→open" alongside "todo→open" breaks push | Document: only set push targets, let defaults handle pull |
| 3 | OAuth `client_credentials` requires explicit `scope=read,write` | Token request fails with `invalid_scope` if omitted | Documented in PLAN.md d15, CI worker script handles it |
| 4 | Personal API keys use `Authorization: <key>` (no Bearer); OAuth uses `Bearer <token>` | curl commands with wrong header get 400 | Added auth header format section to runbook §9 |
| 5 | `bd config unset` exists and works | Essential for fixing config mistakes | Added to runbook and FAQ |
| 6 | OAuth app `actor=application` gives bot identity (`beads-sync-bot`) with standard rate limits (2M complexity / 5K req) | App identity confirmed separate from personal account | Validated in PLAN.md d15 |
| 7 | Bidirectional sync works end-to-end: push 32 beads, edit in Linear, pull change back in <1 min | Core value proposition validated | No fix needed — it works |

---

## Cross-References

- **Architecture:** [PLAN.md §5](../../PLAN.md) — recommended architecture and decision log
- **Rollout phases:** [PLAN.md §8](../../PLAN.md) — phased rollout with entry/exit criteria
- **Upstream PRs:** [PLAN.md §6](../../PLAN.md) — PR-0 through PR-8 descriptions and sequencing
- **Onboarding guide:** `docs/onboarding/` (per-developer setup walkthrough)
- **Config reference:** upstream `docs/CONFIG.md` in `gastownhall/beads`
- **Integration charter:** upstream `docs/INTEGRATION_CHARTER.md` (scope decisions and constraints)
- **Monitoring dashboard:** bead `btl-6mr`
