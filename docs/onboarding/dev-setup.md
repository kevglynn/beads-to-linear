# Developer Setup — beads + Linear Sync

Beads is a local-first issue tracker that lives on your laptop. You use it
from the terminal to create, track, and close work — and it automatically
syncs to Linear so PMs can see your board without you doing anything extra.
You never need to open Linear.

---

## Prerequisites

- **`bd` CLI** installed — see [beads installation](https://github.com/gastownhall/beads#installation) or `brew install beads`
- **Linear account** with API key access (your manager can invite you)
- **Git repo with `.beads/` directory** — already set up by eng ops. If you don't see `.beads/` in your repo root, ask your team lead

---

## Step 1: Generate your Linear API key

1. Go to <https://linear.app/settings/account/security/api-keys>
2. Click **Create key**
3. Set permission to **Read** only (you never push to Linear directly — the CI worker does that)
4. Name it something like `beads-pull-<your-name>` (e.g. `beads-pull-alice`)
5. Copy the key — you won't see it again

---

## Step 2: Set up the API key

Add the key to your secrets file so it's available in every terminal session:

```bash
echo 'export LINEAR_API_KEY="lin_api_YOUR_KEY_HERE"' >> ~/.secrets
source ~/.secrets
```

Verify it loaded:

```bash
echo $LINEAR_API_KEY | head -c 10
```

You should see something like `lin_api_cQ`. If it's blank, check that your
shell profile sources `~/.secrets` (add `source ~/.secrets` to your
`~/.zshrc` or `~/.bashrc` if needed).

> **Warning:** NEVER run `bd config set linear.api_key "..."` — that writes
> your key into `.beads/config.yaml`, which is tracked by git. Your key
> would end up in the repo for everyone to see. Always use the environment
> variable.

---

## Step 3: Configure the Linear state mapping

Before syncing, `bd` needs to know which Linear workflow states correspond
to beads statuses. The key direction is **Linear state → beads status**
(not the other way around).

For push to work, each beads status must map to exactly **one** Linear
state. Pull is more forgiving — the built-in type defaults handle most
cases automatically.

Set the push-target mappings:

```bash
bd config set linear.state_map.todo open
bd config set linear.state_map.in\ progress in_progress
bd config set linear.state_map.done closed
```

That's the minimum. Do NOT add extra mappings (e.g., "backlog" → "open")
unless you want them — duplicates cause push to fail with an ambiguity
error. The defaults already handle Backlog, Canceled, and In Review on
the pull path.

> **Gotcha:** If you see `linear.state_map maps beads status "X" to
> multiple Linear states`, you have two Linear states mapping to the same
> beads status. Remove the duplicate with `bd config unset linear.state_map.<name>`.

---

## Step 4: Install the pull cron

This sets up a background job that pulls Linear updates to your laptop every
15 minutes (with jitter so the whole team doesn't hit Linear at once).

```bash
cd your-project-repo
./scripts/install-pull-cron.sh
```

Check that it's running:

```bash
./scripts/install-pull-cron.sh --status
```

Expected output:

```
✓ Pull cron active — last run 3m ago, next in ~12m
```

---

## Step 5: Verify it works

Do a dry-run pull to confirm your credentials and config are correct:

```bash
bd linear sync --pull --prefer-linear --dry-run
```

Expected output (varies by project):

```
[dry-run] Would update 3 issues from Linear
[dry-run] No new remote issues to pull
```

Then check your local board:

```bash
bd list
```

You should see issues. Some may already have Linear links attached
(from earlier syncs by other teammates).

---

## Day-to-day workflow

Your workflow doesn't change — just use beads like normal:

```bash
bd create --type task --title "Fix the login bug"   # Create work
bd update <id> --status in_progress                 # Start working
bd close <id> --reason "Fixed null check in auth"   # Complete work
bd list                                             # See your board
bd ready                                            # See what's unblocked
```

**What happens behind the scenes:**

- When you `git push`, your `.beads/issues.jsonl` goes with it. A CI job
  picks up the changes and creates/updates the matching Linear issues.
- Every 15 minutes, the pull cron fetches updates from Linear (PM priority
  changes, status updates, new issues created in Linear) and applies them
  locally.

You don't need to think about any of this — it just works.

---

## Handling merge conflicts on issues.jsonl

Most merges auto-resolve because different issues live on different lines.
If you do get a conflict:

1. Open `.beads/issues.jsonl` — each conflicting line is a full JSON object
2. For each conflict, pick the version with the newer `updated_at` timestamp
3. Resolve and continue:

```bash
git add .beads/issues.jsonl
git rebase --continue
```

See [`docs/merge-strategy.md`](../merge-strategy.md) for the full strategy.

---

## What NOT to do

| Don't | Why |
|---|---|
| Run `bd linear sync --push` | The CI worker is the sole writer to Linear |
| Put API keys in `.beads/config.yaml` | That file is tracked by git — use `$LINEAR_API_KEY` env var |
| Edit `.beads/external_refs.json` by hand | The CI worker manages Linear↔bead ID mappings |
| Log into Linear to create issues | Just use `bd create` — it syncs automatically |

---

## FAQ

**"I don't see my bead in Linear."**
It shows up after your next `git push` + CI run. The CI job is the only
thing that writes to Linear, and it triggers on push.

**"Linear shows a different priority than my local."**
Normal. The pull cron uses `--prefer-linear`, which means Linear wins on
conflicts. If you disagree with the priority, change it locally and push —
the CI job will update Linear on the next run.

**"I accidentally ran `bd config set linear.api_key`."**
Check the damage: `git diff .beads/config.yaml`. Revert the file, move your
key to the env var, and make sure you don't commit the change:

```bash
git checkout -- .beads/config.yaml
```

**"The pull cron stopped working."**
Check status and logs:

```bash
./scripts/install-pull-cron.sh --status
cat ~/.beads-sync.log | tail -20
```

---

## Getting help

- **Sync runbook:** [`docs/runbooks/linear-sync.md`](../runbooks/linear-sync.md)
- **Architecture:** [`PLAN.md`](../../PLAN.md) (if you're curious how the plumbing works)
- **File an issue:** `bd create --type bug --title "sync: <describe problem>"`
