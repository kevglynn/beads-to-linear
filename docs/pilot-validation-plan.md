# Phase 1 Pilot Validation Plan — 50-Bead Burn-In

**Date:** 2026-05-02
**Bead:** `btl-apg`
**Status:** Draft
**Architecture reference:** [PLAN.md §5](../PLAN.md) (recommended architecture), [PLAN.md §8](../PLAN.md) (rollout phases)

---

## 1. Pilot Scope

### Team composition

- **3–5 developers** from one team, recruited as volunteers
- Mix of bead power-users (daily `bd` usage) and beads newcomers (onboarded during pilot)
- One developer designated as **pilot coordinator** — triages issues, collects feedback, owns the daily check

### Repository

- One production repo with active beads usage (20–100 open beads at pilot start)
- Repo must NOT be actively dual-writing to Jira (avoids three-way race)
- Repo must have a clear Linear team boundary (no cross-team issue sharing during pilot)

### Duration

Defined by sync cycles, not calendar units:

| Milestone | Trigger |
|---|---|
| Pilot start | Entry criteria met (§2) |
| First checkpoint | 20 beads synced + 10 consecutive clean CI runs |
| Second checkpoint | 50 beads synced + 20 consecutive clean CI runs |
| Exit evaluation | All exit criteria met (§4) |

### Target coverage

50+ beads synced through the CI worker, covering:

| Issue type | Minimum count | Notes |
|---|---|---|
| `task` | 15 | Bread and butter |
| `bug` | 5 | Status lifecycle: open → in_progress → closed |
| `feature` | 5 | Multi-field updates (title, description, priority) |
| `epic` | 2 | Parent-child hierarchy roundtrip |
| `spike` | 2 | Type mapping via `linear.label_type_map` (requires PR-0) |
| `decision` | 2 | Type mapping (requires PR-0) |
| `story` | 2 | Type mapping (requires PR-0) |
| Any type | — | Remainder to reach 50+ |

---

## 2. Entry Criteria

Every item must be true before the pilot begins. The pilot coordinator verifies each item and records evidence.

### 2.1 Upstream PRs

| PR | Required status | Why |
|---|---|---|
| PR-1 (refuse git-tracked secrets) | **Merged** | P0 — without this, pilot devs risk leaking API keys to git |
| PR-3 (OAuth client-credentials) | **Merged or validated workaround** | CI worker needs `actor=app` identity. If not merged, the validated `beads-sync-bot` OAuth app (decision d15) with manual token management is the stop-gap |
| PR-0 (type mapping canary) | **Merged** (strongly recommended) | Required for `spike`, `decision`, `story`, `milestone` type coverage. Pilot can proceed without it but with reduced type coverage |

Verify PR status:

```bash
gh pr list --repo gastownhall/beads --search "author:kevglynn" --state all
```

### 2.2 Infrastructure

| Item | Verification command | Expected result |
|---|---|---|
| CI worker deployed | `gh workflow list --repo <org>/<repo>` | `linear-sync` workflow exists and is enabled |
| CI worker dry-run passes | `gh workflow run linear-sync.yml --repo <org>/<repo>` then check logs | Run completes with 0 errors, 0 pushes (no-op) |
| OAuth credential in CI secrets | `gh secret list --repo <org>/<repo> \| grep LINEAR_OAUTH` | `LINEAR_OAUTH_CLIENT_ID` and `LINEAR_OAUTH_CLIENT_SECRET` present |
| Linear team configured | Open `https://linear.app/<workspace>/settings/teams` | Pilot team exists with correct workflow states |
| `.gitattributes` merge strategy | `grep 'issues.jsonl' .gitattributes` | `.beads/issues.jsonl merge=union` |

### 2.3 Per-developer readiness

Run on **each** pilot developer's machine:

```bash
# Beads health
bd doctor --agent
# Expected: SUMMARY: ok

# API key is in env, NOT in config.yaml
echo $LINEAR_API_KEY | head -c 10
# Expected: lin_api_XX (not blank)

grep -c 'api_key' .beads/config.yaml
# Expected: 0 (no api_key in tracked config)

# Pull cron installed
bash scripts/install-pull-cron.sh --status
# Expected: ✓ Pull cron active

# Manual pull works
bd linear sync --pull --prefer-linear --dry-run
# Expected: no errors
```

### 2.4 Config consistency

All pilot devs must use the same Linear configuration. Verify against org template:

```bash
diff <(grep -E '^linear\.' .beads/config.yaml | sort) \
     <(grep -E '^linear\.' templates/.beads/config.yaml | sort)
```

Key fields that must match:
- `linear.team_ids`
- `linear.priority_map.*`
- `linear.state_map.*`
- `linear.label_type_map.*`
- `linear.id_mode`

### 2.5 Baseline snapshot

Before the first sync, capture the starting state:

```bash
# Count of beads by type
bd count --by-type > /tmp/pilot-baseline-types.txt

# Count of beads with/without external_ref
bd list --json | python3 -c "
import json, sys
beads = json.load(sys.stdin)
with_ref = len([b for b in beads if b.get('external_ref')])
without_ref = len([b for b in beads if not b.get('external_ref') and b.get('type') not in ('wisp', 'memory')])
print(f'With external_ref: {with_ref}')
print(f'Without external_ref: {without_ref}')
print(f'Total syncable: {with_ref + without_ref}')
" > /tmp/pilot-baseline-refs.txt

# Snapshot of Linear team issue count
# (manual: note the count in Linear's team view)
```

---

## 3. Test Scenarios

### 3.1 Test matrix — push path (dev → Linear)

| # | Scenario | How to execute | Expected outcome | How to verify |
|---|---|---|---|---|
| P1 | Create bead locally, push to Linear | `bd create --type task --title "Pilot test P1" && git add .beads/issues.jsonl && git commit -m "test: pilot P1" && git push` | Linear issue created in pilot team with matching title, description, priority | `bd show <id>` for `external_ref` URL; open URL in browser; verify title/priority match |
| P2 | Close bead locally, push status change | `bd close <id> --reason "Pilot test" && git add . && git commit -m "test: pilot P2" && git push` | Linear issue moves to Done state | Open Linear issue; verify status = Done |
| P3 | Update priority locally, push change | `bd update <id> --priority 1 && git add . && git commit -m "test: pilot P3" && git push` | Linear issue priority updated to Urgent | Open Linear issue; verify priority matches |
| P4 | Update title + description locally | `bd update <id> --title "Updated title" && git add . && git commit -m "test: pilot P4" && git push` | Linear issue title updated | Compare Linear issue title to local |
| P5 | Push multiple beads in single commit | Create 5+ beads, commit all, push once | All 5+ appear in Linear in one CI run | `bd list --json \| jq '[.[] \| select(.external_ref)] \| length'`; compare before/after |
| P6 | Push epic with children | Create epic + 2 child tasks with `--parent`, push | Epic and children appear in Linear; parent relationship preserved if PR-10 landed | Open Linear epic; verify sub-issues listed |
| P7 | Push typed beads (spike, decision) | Create `--type spike` and `--type decision` beads, push | Linear issues have correct type labels | Requires PR-0 merged; verify labels in Linear |

### 3.2 Test matrix — pull path (Linear → dev)

| # | Scenario | How to execute | Expected outcome | How to verify |
|---|---|---|---|---|
| L1 | PM changes priority in Linear | In Linear UI: change pilot issue priority to Urgent | Local bead priority updated after pull | `bd linear sync --pull --prefer-linear && bd show <id>` — priority should match Linear |
| L2 | PM changes status in Linear | In Linear UI: move issue to In Progress | Local bead status updated after pull | `bd show <id>` — status should be `in_progress` |
| L3 | PM creates issue in Linear | In Linear UI: create new issue in pilot team | New local bead created after pull | `bd linear sync --pull --prefer-linear && bd list` — new bead appears with `external_ref` pointing to the Linear issue |
| L4 | PM edits title in Linear | In Linear UI: change issue title | Local bead title updated after pull | `bd show <id>` — title matches Linear |
| L5 | Pull after laptop sleep | Close laptop lid for >15 min, reopen | Next cron pull succeeds; no duplicate actions | Check cron log: `tail -20 ~/.beads-sync.log` — clean run, no errors |
| L6 | Pull with stale `last_sync` | Delete `.beads/last_pull` timestamp, run manual pull | Full re-sync succeeds without duplicates | `bd list` — no duplicate beads; `bd linear sync --pull --prefer-linear` output shows 0 errors |

### 3.3 Test matrix — conflict and edge cases

| # | Scenario | How to execute | Expected outcome | How to verify |
|---|---|---|---|---|
| C1 | Two devs modify same bead | Dev A changes priority, Dev B changes title; both push | JSONL merge conflict if same line, auto-resolved if different fields; CI pushes the merged result | Both changes reflected in Linear after CI run |
| C2 | Dev edits bead, PM edits same issue in Linear | Dev updates title locally + pushes; PM updates priority in Linear before next pull | After push: Linear has dev's title. After pull: dev gets PM's priority (`--prefer-linear`) | `bd show <id>` after full cycle — title from dev, priority from PM |
| C3 | `merge=union` JSONL merge | Dev A adds issue X, Dev B adds issue Y, both push to same branch | Git auto-merges; both issues present in JSONL | `wc -l .beads/issues.jsonl` increases by 2; both beads visible in `bd list` |
| C4 | JSONL merge conflict (same issue, both sides) | Dev A and Dev B both edit the same issue's title and push | Git marks conflict; manual resolution by `updated_at` timestamp | `grep '<<<' .beads/issues.jsonl` finds markers; resolve per [merge strategy](merge-strategy.md) |
| C5 | Bead disappears from JSONL | Delete a bead locally (`bd update <id> --delete`) or convert to wisp, push | Linear issue archived (decision d12) | Open Linear issue URL — should show "Archived" status |
| C6 | CI worker rate limit behavior | Push 50+ beads in a single commit (cold-start scenario) | Worker uses batch mutations (PR-4) or retries with backoff if rate-limited | CI logs show batch or retry behavior; all issues eventually created |
| C7 | OAuth token near-expiry | Set CI secret to an expired token (or wait for 30-day TTL in a long-running pilot) | Worker auto-fetches new token on 401; run succeeds | CI logs: `OAuth token acquired` after initial 401 |
| C8 | Duplicate bead ID across devs | Two devs independently create beads; push overlapping JSONL | Idempotency marker (PR-5) prevents duplicate Linear issues | Linear has exactly one issue per bead ID; no orphaned duplicates |

### 3.4 Test matrix — failure recovery

| # | Scenario | How to execute | Expected outcome | How to verify |
|---|---|---|---|---|
| F1 | CI worker fails mid-push | Kill CI run manually (or simulate via network block) | Next CI run picks up where left off; no duplicate Linear issues | Compare Linear issue count before/after recovery run; idempotency markers prevent dupes |
| F2 | Pull cron fails after laptop sleep | Check cron log after waking from sleep | Failed run logged; next 15-min cron succeeds | `tail ~/.beads-sync.log` — one failure, then clean run |
| F3 | Linear API outage | (Wait for natural outage or simulate with hosts file block) | CI pushes queue in git; pulls fail gracefully; both recover after outage ends | Per [runbook §4](runbooks/linear-sync.md#4-handling-linear-api-outage): local beads unaffected; sync resumes automatically |
| F4 | Corrupted JSONL pushed to git | Introduce a malformed JSON line, push | CI worker fails with parse error; alerting fires | CI log shows JSON parse error; [runbook §9](runbooks/linear-sync.md#jsonl-parse-error) recovery: `bd export --force && git push` |

---

## 4. Exit Criteria

All criteria must be met simultaneously. The pilot coordinator evaluates after every CI checkpoint.

### 4.1 Quantitative

| Criterion | Threshold | How to measure |
|---|---|---|
| Beads synced | ≥ 50 unique beads pushed through CI worker | `cat .beads/external_refs.json \| python3 -c "import json,sys; print(len(json.load(sys.stdin)['refs']))"` |
| Sync success rate | ≥ 99.5% over 20+ consecutive CI runs | `gh run list --workflow=linear-sync.yml --limit 30 \| grep -c completed` vs total |
| Zero data loss | Every non-wisp bead has a corresponding Linear issue | See §5 coverage check command |
| Zero credential leaks | No `lin_api_*` or `lin_oauth_*` tokens in any git commit | `git log --all -p \| grep -c 'lin_api_\|lin_oauth_'` — must be 0 |
| Conflict resolution | ≥ 2 conflicts encountered and explicitly resolved | Pilot log entries |
| No manual intervention | Normal sync cycles require zero human action | Pilot coordinator confirms |

### 4.2 Qualitative

| Criterion | Method |
|---|---|
| No workflow disruption | Each pilot dev confirms their day-to-day `bd` usage was unaffected |
| Developer satisfaction | Brief survey (3 questions below) — ≥ 80% positive on each |
| Runbook coverage | Every friction point encountered during pilot has a runbook entry |

### Developer survey (administered at pilot exit)

1. **Transparency:** "Did the sync system work without you having to think about it?" (Yes / Mostly / No)
2. **Disruption:** "Did the sync cause any problems with your local beads workflow?" (None / Minor / Major)
3. **Recommendation:** "Would you recommend this to another team?" (Yes / Maybe / No)

Pass threshold: ≥ 80% answer the positive option (Yes/None/Yes) on each question.

---

## 5. Metrics to Track

### Per-cycle metrics

Collected after every CI sync run and every developer pull:

| Metric | Source | Healthy range | Alert threshold |
|---|---|---|---|
| Push success/failure | CI workflow exit code | 100% success | Any failure |
| Push latency (git push → Linear issue created) | CI run duration | < 60s | > 120s |
| Pull latency (Linear change → local bead updated) | Timestamp diff: Linear `updatedAt` vs local `updated_at` after pull | < 20 min (15-min cron + jitter) | > 30 min |
| Issues pushed per run | CI log: `bd linear sync --push --json` output | Varies | Spike > 50 in one run (investigate) |
| Issues pulled per cycle | `bd linear sync --pull` output | Varies | 0 for 3+ consecutive cycles (pull may be broken) |
| Conflicts resolved per cycle | CI log conflict count | Low and stable | Trending upward |
| API quota utilization | Linear rate-limit response headers (`X-RateLimit-Requests-Remaining`) | < 50% of limit | > 80% of limit |

### Aggregate metrics (checked daily by pilot coordinator)

| Metric | Command | Healthy state |
|---|---|---|
| External_ref coverage | See command below | 100% of non-wisp beads |
| Sync gap (beads without Linear issue) | See command below | 0 gaps older than 1 CI cycle |
| Config drift | `diff` against org template (see §2.4) | No drift |
| Cron health across devs | Each dev runs `scripts/install-pull-cron.sh --status` | All active |

**External_ref coverage check:**

```bash
bd list --json | python3 -c "
import json, sys
beads = json.load(sys.stdin)
syncable = [b for b in beads if b.get('type') not in ('wisp', 'memory')]
missing = [b for b in syncable if not b.get('external_ref')]
coverage = (len(syncable) - len(missing)) / len(syncable) * 100 if syncable else 100
print(f'Coverage: {coverage:.1f}% ({len(syncable) - len(missing)}/{len(syncable)})')
if missing:
    print(f'Missing external_ref ({len(missing)}):')
    for b in missing[:10]:
        print(f'  {b[\"id\"]}: {b.get(\"title\", \"(no title)\")}')
    if len(missing) > 10:
        print(f'  ... and {len(missing) - 10} more')
"
```

---

## 6. Risk Register

| # | Risk | Likelihood | Impact | Mitigation | Rollback |
|---|---|---|---|---|---|
| R1 | Upstream PR-1 not merged in time — devs risk leaking API keys | Medium | High (credential exposure) | Stop-gap: pre-commit hook that scans for `lin_api_` in tracked files; documented env-var-only policy in [onboarding guide](onboarding/dev-setup.md) | Revert any exposed keys immediately; rotate via Linear settings |
| R2 | PR-3 (OAuth) not merged — CI worker runs on personal API key | Medium | Medium (audit trail attribution) | Use validated `beads-sync-bot` OAuth app (decision d15) with manual token refresh; all writes attributed to bot, not a person | Acceptable for pilot scope; block Phase 2 until PR-3 merges |
| R3 | JSONL merge conflicts disrupt developer workflow | Medium | Low (developer friction) | `merge=union` in `.gitattributes` auto-resolves most cases; [merge strategy doc](merge-strategy.md) covers manual resolution | `bd export --force` regenerates clean JSONL from local DB |
| R4 | Linear API outage during pilot | Low | Low (sync pauses, beads unaffected) | Beads is local-first — developers continue working; sync queues in git and catches up after recovery. See [runbook §4](runbooks/linear-sync.md#4-handling-linear-api-outage) | N/A — outage is self-healing |
| R5 | Rate limit exhaustion on push (50+ beads in cold start) | Low | Medium (sync backlog) | Batch mutations (PR-4) push 50 issues per API call; without PR-4, worker retries with backoff | Reduce batch size; stagger initial sync across multiple pushes |
| R6 | Duplicate Linear issues from interrupted sync | Medium | Medium (cleanup overhead) | Idempotency markers (PR-5) prevent duplicates; without PR-5, manual dedup via Linear bulk archive | `bd linear history --detail <run-id>` to identify dupes; archive extras in Linear |
| R7 | Config drift between pilot devs | Medium | Low (inconsistent sync behavior) | Daily config check (§2.4 diff command); org template enforced at onboarding | Re-run onboarding §1.5–1.6 from [runbook](runbooks/linear-sync.md#1-adding-a-new-developer) |
| R8 | Pilot dev accidentally runs `bd linear sync --push` locally | Low | Medium (bypasses CI single-writer) | Document in [onboarding "What NOT to do"](onboarding/dev-setup.md#what-not-to-do); pre-commit hook warns if local push attempted | Local push is safe but bypasses audit trail; re-sync via CI to reconcile |
| R9 | OAuth token expires mid-pilot (30-day TTL) | Low (pilot duration < 30 days of cycles) | High if unmitigated | CI worker auto-refreshes on 401 (PR-3); monitoring alerts on auth failure; [runbook §3](runbooks/linear-sync.md#3-rotating-oauth-credentials) covers rotation | Manual token refresh: re-run OAuth client_credentials grant, update CI secret |
| R10 | Wisp/ephemeral data leaks to Linear | Low (`bd export` filters by default) | High (privacy violation) | Pre-commit hook passes `--exclude-type wisp --exclude-type memory` explicitly (PLAN.md §5 correction); verify in CI worker entrypoint | Archive leaked issues in Linear; audit `external_refs.json` for wisp IDs |

---

## 7. Rollback Procedure

If the pilot must be aborted at any point:

### Step 1: Disable the CI worker

```bash
gh workflow disable linear-sync.yml --repo <org>/<repo>
```

### Step 2: Remove pilot Linear issues

Linear has a 7-day soft-delete window. Bulk-archive pilot issues:

```bash
# Get all Linear issue IDs created during pilot
cat .beads/external_refs.json | python3 -c "
import json, sys
refs = json.load(sys.stdin)['refs']
for bead_id, ref in refs.items():
    print(ref['linear_id'])
" > /tmp/pilot-linear-ids.txt

# Archive each (or use Linear's bulk-select in UI)
# Linear UI: select all pilot issues → Actions → Archive
```

### Step 3: Uninstall pull cron on each dev's machine

```bash
bash scripts/install-pull-cron.sh --uninstall
```

### Step 4: Revert config changes

```bash
git checkout main -- .beads/config.yaml
git checkout main -- .beads/external_refs.json
git commit -m "chore: revert pilot sync config"
git push
```

### Step 5: Verify local beads state

Local beads databases are unaffected throughout — the local-first design means no pilot activity corrupts a developer's local DB. Verify:

```bash
bd doctor --agent
# Expected: SUMMARY: ok
```

---

## 8. Go/No-Go Checklist for Broader Rollout (Phase 2+)

After the pilot succeeds (all §4 exit criteria met), evaluate readiness for expanding from the pilot team to additional teams and eventually all 50 developers.

### Must-have for Phase 2 (bidirectional sync, one team)

| # | Criterion | Evidence required |
|---|---|---|
| G1 | All Phase 1 exit criteria met | Pilot coordinator sign-off with metrics |
| G2 | PR-5 (idempotency markers) merged upstream | `gh pr view --repo gastownhall/beads` — merged |
| G3 | PR-6 (Retry-After parsing) merged upstream | Same |
| G4 | Per-laptop pull cron validated across all pilot devs | Each dev: `scripts/install-pull-cron.sh --status` shows active, `~/.beads-sync.log` shows clean runs |
| G5 | Runbook updated with all pilot friction points | Diff `docs/runbooks/linear-sync.md` — new sections for every incident |
| G6 | Zero unresolved security findings | No leaked credentials, no wisp leaks, no auth misconfigurations |

### Must-have for Phase 3 (3–5 teams)

| # | Criterion | Evidence required |
|---|---|---|
| G7 | Phase 2 exit criteria met (PLAN.md §8) | Sync success rate ≥ 99.5% over 50 consecutive runs |
| G8 | PR-7 (concurrency lock) merged upstream | Prevents race conditions in CI |
| G9 | Multi-team Linear config validated | `linear.team_ids` with multiple teams; push routes correctly |
| G10 | Cross-team relation roundtrip verified | Create `blocks`/`related` dep across teams; verify in Linear |
| G11 | Zero ID collisions over 200 sync cycles | `external_refs.json` has no duplicate `linear_id` values |

### Must-have for Phase 4 (full org, all 50 devs)

| # | Criterion | Evidence required |
|---|---|---|
| G12 | Phase 3 exit criteria met | Sign-off from each expanded team |
| G13 | PR-8 (audit log) merged upstream | Forensic recovery capability confirmed |
| G14 | Jira → Linear backfill complete | Historical issues migrated; no dual-write |
| G15 | Monitoring dashboard operational | [Bead btl-6mr](../PLAN.md): alerts firing correctly for failures, rate limits, drift |
| G16 | On-call rotation established | Named person for sync issues; escalation path documented |

---

## 9. Daily Pilot Check Script

The pilot coordinator runs this daily to track health:

```bash
#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="${1:-.}"
cd "$REPO_ROOT"

echo "=== Pilot Health Check — $(date -Iseconds) ==="
echo ""

echo "--- CI Worker Status ---"
gh run list --workflow=linear-sync.yml --repo <org>/<repo> --limit 5 2>/dev/null || echo "(CI workflow not found)"
echo ""

echo "--- External Ref Coverage ---"
bd list --json 2>/dev/null | python3 -c "
import json, sys
beads = json.load(sys.stdin)
syncable = [b for b in beads if b.get('type') not in ('wisp', 'memory')]
missing = [b for b in syncable if not b.get('external_ref')]
coverage = (len(syncable) - len(missing)) / len(syncable) * 100 if syncable else 100
print(f'Coverage: {coverage:.1f}% ({len(syncable) - len(missing)}/{len(syncable)} beads)')
if missing:
    print(f'  GAPS ({len(missing)}):')
    for b in missing[:5]:
        print(f'    {b[\"id\"]}: {b.get(\"title\", \"(no title)\")}')
" || echo "(bd list failed)"
echo ""

echo "--- Config Drift ---"
if [ -f templates/.beads/config.yaml ]; then
    drift=$(diff <(grep -E '^linear\.' .beads/config.yaml 2>/dev/null | sort) \
                 <(grep -E '^linear\.' templates/.beads/config.yaml 2>/dev/null | sort) || true)
    if [ -z "$drift" ]; then
        echo "OK: config matches template"
    else
        echo "WARNING: config drift detected"
        echo "$drift"
    fi
else
    echo "(no org template found)"
fi
echo ""

echo "--- Beads DB Health ---"
bd doctor --agent 2>/dev/null || echo "(bd doctor failed)"
echo ""

echo "--- Recent Sync History ---"
bd linear history 2>/dev/null || echo "(bd linear history not available — requires PR-8)"
echo ""

echo "=== End Health Check ==="
```

---

## 10. Pilot Log Template

Each pilot dev maintains a brief log of notable events. The pilot coordinator consolidates daily.

| Date | Dev | Event | Category | Notes |
|---|---|---|---|---|
| _YYYY-MM-DD_ | _initials_ | _what happened_ | Push / Pull / Conflict / Error / Friction | _details, commands run, resolution_ |

Categories:
- **Push**: bead created/updated/archived in Linear via CI
- **Pull**: Linear change received locally via cron or manual pull
- **Conflict**: merge conflict in JSONL or field-level conflict resolved by `--prefer-linear`
- **Error**: any sync failure (CI or local)
- **Friction**: anything confusing, undocumented, or requiring manual intervention

---

## Cross-References

- **Architecture:** [PLAN.md §5](../PLAN.md) — recommended architecture, decision log, Mermaid diagram
- **Rollout phases:** [PLAN.md §8](../PLAN.md) — Phase 0–4 entry/exit criteria
- **Runbook:** [docs/runbooks/linear-sync.md](runbooks/linear-sync.md) — operational procedures
- **Onboarding guide:** [docs/onboarding/dev-setup.md](onboarding/dev-setup.md) — per-developer setup
- **Merge strategy:** [docs/merge-strategy.md](merge-strategy.md) — JSONL conflict resolution
- **Upstream PRs:** [PLAN.md §6](../PLAN.md) — PR-0 through PR-8 scope and sequencing
