#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# ci-linear-push.sh — CI worker entrypoint for beads → Linear push sync.
#
# Called by .github/workflows/linear-sync.yml. This is the sole Linear writer
# in the architecture. See PLAN.md §5.
#
# Pipeline:
#   1. Detect delta (compare current vs previous issues.jsonl)
#   2. Enforce push-volume safety check (refuse if delta > threshold)
#   3. Import beads from JSONL into fresh local DB
#   4. Run bd linear sync --push --json
#   5. Parse sync output, extract external refs
#   6. Merge into .beads/external_refs.json
#   7. Handle disappeared beads (d12: archive in Linear)
#   8. Commit and push external_refs.json back to main
#
# Requires: bd, jq, git
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source the external-refs library
# shellcheck source=lib/external-refs.sh
source "$SCRIPT_DIR/lib/external-refs.sh"

# ── configuration ─────────────────────────────────────────────────────────

ISSUES_JSONL="${REPO_ROOT}/.beads/issues.jsonl"
EXTERNAL_REFS_FILE="${REPO_ROOT}/.beads/external_refs.json"
SYNC_HISTORY_DIR="${REPO_ROOT}/.beads/sync-history"
MAX_PUSH_DELTA="${BTL_MAX_PUSH_DELTA:-100}"

export EXTERNAL_REFS_FILE

# ── colours (plain in CI, colorized locally) ──────────────────────────────

if [[ -z "${CI:-}" ]] && [[ -t 1 ]]; then
  RED=$'\033[0;31m'  GREEN=$'\033[0;32m'  YELLOW=$'\033[0;33m'
  CYAN=$'\033[0;36m' BOLD=$'\033[1m'      RESET=$'\033[0m'
else
  RED=""  GREEN=""  YELLOW=""  CYAN=""  BOLD=""  RESET=""
fi

# ── helpers ───────────────────────────────────────────────────────────────

die()  { printf '%s%sERROR:%s %b\n' "$RED" "$BOLD" "$RESET" "$1" >&2; exit "${2:-1}"; }
warn() { printf '%s%sWARN:%s %s\n'  "$YELLOW" "$BOLD" "$RESET" "$1" >&2; }
ok()   { printf '%s%s✔%s %s\n'      "$GREEN" "$BOLD" "$RESET" "$1"; }
info() { printf '%s%s→%s %s\n'      "$CYAN" "$BOLD" "$RESET" "$1"; }
step() { printf '\n%s%s── %s ──%s\n' "$BOLD" "$CYAN" "$1" "$RESET"; }

usage() {
  cat <<EOF
${BOLD:-}Usage:${RESET:-} ci-linear-push.sh [OPTIONS]

CI worker entrypoint that pushes beads to Linear and commits external_refs
back to main. This is the sole Linear writer in the beads-to-linear
architecture.

${BOLD:-}Options${RESET:-}
  --dry-run       Run all steps but skip the actual Linear push and git push
  --max-delta N   Override push-volume safety threshold (default: $MAX_PUSH_DELTA)
  --help          Show this help

${BOLD:-}Environment${RESET:-}
  LINEAR_API_KEY               Linear API key (fallback auth)
  LINEAR_OAUTH_CLIENT_ID       OAuth client ID (preferred auth)
  LINEAR_OAUTH_CLIENT_SECRET   OAuth client secret (preferred auth)
  BTL_MAX_PUSH_DELTA           Push-volume safety threshold (default: $MAX_PUSH_DELTA)
  GITHUB_RUN_ID                Set by GitHub Actions; used for sync log naming
  CI                           Set by GitHub Actions; disables colors

${BOLD:-}Exit codes${RESET:-}
  0   Sync completed (may have been a no-op)
  1   Fatal error (missing deps, bad config, push failure)
  2   Push-volume safety check blocked the push
EOF
}

# ── arg parsing ───────────────────────────────────────────────────────────

DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)     DRY_RUN=true;        shift ;;
    --max-delta)   MAX_PUSH_DELTA="$2"; shift 2 ;;
    --help|-h)     usage; exit 0 ;;
    *) die "Unknown option: $1  (try --help)" ;;
  esac
done

# ── preflight checks ─────────────────────────────────────────────────────

step "Preflight"

for cmd in bd jq git; do
  command -v "$cmd" &>/dev/null || die "$cmd is not on PATH"
done

if [[ -n "${LINEAR_OAUTH_CLIENT_ID:-}" ]] && [[ -n "${LINEAR_OAUTH_CLIENT_SECRET:-}" ]]; then
  ok "Auth: OAuth client-credentials configured"
elif [[ -n "${LINEAR_API_KEY:-}" ]]; then
  ok "Auth: LINEAR_API_KEY configured (personal key fallback)"
else
  die "No Linear credentials found.\n  Set LINEAR_OAUTH_CLIENT_ID + LINEAR_OAUTH_CLIENT_SECRET (preferred)\n  or LINEAR_API_KEY (fallback)."
fi

[[ -f "$ISSUES_JSONL" ]] || die "issues.jsonl not found at $ISSUES_JSONL"

issue_count="$(wc -l < "$ISSUES_JSONL" | tr -d ' ')"
ok "Found issues.jsonl with $issue_count entries"

# ── step 1: delta detection ──────────────────────────────────────────────

step "Delta detection"

added_lines=0
removed_lines=0
changed_ids=0

if git log --oneline -1 HEAD -- "$ISSUES_JSONL" &>/dev/null; then
  if git show HEAD~1:.beads/issues.jsonl &>/dev/null 2>&1; then
    diff_output="$(git diff HEAD~1 HEAD -- .beads/issues.jsonl || true)"

    if [[ -n "$diff_output" ]]; then
      added_lines="$(echo "$diff_output" | grep -c '^+{' || true)"
      removed_lines="$(echo "$diff_output" | grep -c '^-{' || true)"

      added_ids="$(echo "$diff_output" \
        | grep '^+{' \
        | jq -r '.id // empty' 2>/dev/null \
        | sort -u || true)"
      removed_ids="$(echo "$diff_output" \
        | grep '^-{' \
        | jq -r '.id // empty' 2>/dev/null \
        | sort -u || true)"
      all_changed_ids="$(printf '%s\n%s' "$added_ids" "$removed_ids" \
        | sort -u | grep -v '^$' || true)"
      changed_ids="$(echo "$all_changed_ids" | grep -c . || true)"
    fi

    info "Delta since HEAD~1: +$added_lines / -$removed_lines lines, $changed_ids unique beads changed"
  else
    info "No previous commit with issues.jsonl — treating entire file as new"
    changed_ids="$issue_count"
  fi
else
  info "issues.jsonl has no git history — treating entire file as new"
  changed_ids="$issue_count"
fi

if [[ "$changed_ids" -eq 0 ]] && [[ "$added_lines" -eq 0 ]] && [[ "$removed_lines" -eq 0 ]]; then
  ok "No delta detected — this is a no-op sync"
  # Still continue: external_refs may need updating from a prior partial run
fi

# ── step 2: import beads from JSONL ──────────────────────────────────────

step "Import"

info "Importing beads from $ISSUES_JSONL"
if bd import "$ISSUES_JSONL" 2>&1; then
  ok "Import complete"
else
  import_exit=$?
  warn "bd import exited with code $import_exit — continuing with best-effort sync"
fi

# ── step 3: load existing external_refs for dedup ────────────────────────

step "External refs"

_ensure_file
existing_ref_count="$(count_external_refs)"
ok "Loaded $existing_ref_count existing external refs"

# ── step 4: push-volume safety check ────────────────────────────────────

step "Push-volume safety check"

# Count beads without an existing external_ref — these are "new" to Linear.
# Updated beads (those with refs) are bounded by existing count and less
# likely to be a bad-merge flood.
new_bead_count=0
while IFS= read -r bead_id; do
  ref="$(get_external_ref "$bead_id")"
  if [[ -z "$ref" ]]; then
    new_bead_count=$((new_bead_count + 1))
  fi
done < <(jq -r '.id' "$ISSUES_JSONL")

info "New beads (no existing external_ref): $new_bead_count"
info "Push-volume threshold: $MAX_PUSH_DELTA"

if [[ "$new_bead_count" -gt "$MAX_PUSH_DELTA" ]]; then
  cat >&2 <<EOF

${RED}${BOLD}Push-volume safety check FAILED${RESET}

  New beads to push: $new_bead_count
  Threshold:         $MAX_PUSH_DELTA

  This likely indicates a bad merge, bulk import, or corrupted JSONL.

  To override, re-run with:
    BTL_MAX_PUSH_DELTA=$new_bead_count bash scripts/ci-linear-push.sh
    or: --max-delta $new_bead_count
    or: workflow_dispatch with max_delta=$new_bead_count

EOF
  die "Push-volume safety check blocked the push" 2
fi

ok "Push volume within safe limits ($new_bead_count new, threshold $MAX_PUSH_DELTA)"

# ── step 5: push to Linear ──────────────────────────────────────────────

step "Linear push"

mkdir -p "$SYNC_HISTORY_DIR"
RUN_ID="${GITHUB_RUN_ID:-local-$(date +%s)}"
SYNC_OUTPUT_FILE="$SYNC_HISTORY_DIR/${RUN_ID}.json"

SYNC_EXIT=0

if [[ "$DRY_RUN" == true ]]; then
  warn "DRY RUN — skipping actual Linear push"
  cat > "$SYNC_OUTPUT_FILE" <<'JSON'
{"created":[],"updated":[],"archived":[],"errors":[],"dry_run":true}
JSON
else
  info "Running: bd linear sync --push --json"

  if bd linear sync --push --json > "$SYNC_OUTPUT_FILE" 2>&1; then
    ok "Linear push completed successfully"
  else
    SYNC_EXIT=$?
    warn "bd linear sync exited with code $SYNC_EXIT"

    # If the output file is empty or not valid JSON, write a fallback
    if [[ ! -s "$SYNC_OUTPUT_FILE" ]] || ! jq empty "$SYNC_OUTPUT_FILE" 2>/dev/null; then
      info "Sync output was not valid JSON — capturing stderr"
      # Move whatever was captured and create a structured error log
      local_output="$(cat "$SYNC_OUTPUT_FILE" 2>/dev/null || echo "")"
      cat > "$SYNC_OUTPUT_FILE" <<EOF
{
  "created": [],
  "updated": [],
  "archived": [],
  "errors": [{"message": "bd linear sync failed with exit code $SYNC_EXIT", "raw_output": $(echo "$local_output" | jq -Rs .)}],
  "exit_code": $SYNC_EXIT
}
EOF
    fi
  fi
fi

ok "Sync output saved to $SYNC_OUTPUT_FILE"

# Log key metrics from sync output
created_count="$(jq '.created | length // 0' "$SYNC_OUTPUT_FILE" 2>/dev/null || echo 0)"
updated_count="$(jq '.updated | length // 0' "$SYNC_OUTPUT_FILE" 2>/dev/null || echo 0)"
error_count="$(jq '.errors | length // 0' "$SYNC_OUTPUT_FILE" 2>/dev/null || echo 0)"

info "Sync results: created=$created_count updated=$updated_count errors=$error_count"

if [[ "$error_count" -gt 0 ]]; then
  warn "Sync produced $error_count error(s) — check $SYNC_OUTPUT_FILE for details"
  jq -r '.errors[] | "  - \(.message // .error // tostring)"' "$SYNC_OUTPUT_FILE" 2>/dev/null || true
fi

# ── step 6: parse sync output and merge external_refs ────────────────────

step "Merge external refs"

TEMP_REFS="$(mktemp)"
trap 'rm -f "$TEMP_REFS"' EXIT

# Build a refs object from the sync output.
# bd linear sync --push --json emits: {created: [{id, external_ref, ...}], updated: [...]}
# We normalize into the external_refs.json format.
jq -r '
  def extract_ref:
    select(.id != null and .external_ref != null)
    | {(.id): {
        linear_id: (.linear_id // (.external_ref | capture("issue/(?<key>[A-Z]+-[0-9]+)") | .key) // "unknown"),
        linear_url: .external_ref,
        synced_at: (now | strftime("%Y-%m-%dT%H:%M:%SZ"))
      }};
  [(.created // [])[], (.updated // [])[]]
  | map(extract_ref)
  | add // {}
' "$SYNC_OUTPUT_FILE" > "$TEMP_REFS" 2>/dev/null || echo '{}' > "$TEMP_REFS"

new_ref_count="$(jq 'length' "$TEMP_REFS")"

if [[ "$new_ref_count" -gt 0 ]]; then
  info "Merging $new_ref_count new/updated external refs"
  merge_external_refs "$TEMP_REFS"
  ok "External refs updated (total: $(count_external_refs))"
else
  info "No new external refs from sync output"

  # If external_refs.json is empty/missing but the JSONL has external_refs,
  # seed from the JSONL itself (handles initial adoption and recovery).
  if [[ "$(count_external_refs)" -eq 0 ]]; then
    jsonl_refs="$(jq -r 'select(.external_ref != null and .external_ref != "") | .id' "$ISSUES_JSONL" | wc -l | tr -d ' ')"
    if [[ "$jsonl_refs" -gt 0 ]]; then
      info "Seeding external_refs.json from $jsonl_refs JSONL entries"
      jq -s '
        map(select(.external_ref != null and .external_ref != ""))
        | map({(.id): {
            linear_url: .external_ref,
            linear_id: (.external_ref | capture("issue/(?<key>[A-Z]+-[0-9]+)") | .key),
            synced_at: .updated_at
          }})
        | add // {}
      ' "$ISSUES_JSONL" > "$TEMP_REFS"
      merge_external_refs "$TEMP_REFS"
      ok "Seeded external_refs.json with $jsonl_refs refs"
    fi
  fi
fi

# ── step 7: handle disappeared beads (decision d12 — archive) ────────────

step "Disappearance check"

disappeared="$(find_disappeared_beads "$ISSUES_JSONL")"
disappeared_count=0

if [[ -n "$disappeared" ]]; then
  disappeared_count="$(echo "$disappeared" | wc -l | tr -d ' ')"
  info "Found $disappeared_count bead(s) in external_refs.json but not in issues.jsonl"

  while IFS= read -r bead_id; do
    ref_json="$(get_external_ref "$bead_id")"
    linear_id="$(echo "$ref_json" | jq -r '.linear_id')"

    if [[ "$DRY_RUN" == true ]]; then
      warn "DRY RUN — would archive Linear issue $linear_id (bead $bead_id)"
    else
      info "Archiving Linear issue $linear_id (bead $bead_id disappeared from JSONL)"
      if bd linear archive "$linear_id" 2>/dev/null; then
        ok "Archived $linear_id"
      else
        warn "Could not archive $linear_id — bd linear archive may not be implemented yet"
      fi
    fi
  done <<< "$disappeared"
else
  ok "No disappeared beads"
fi

# ── step 8: commit and push external_refs.json ──────────────────────────

step "Commit back"

cd "$REPO_ROOT"

if external_refs_changed; then
  info "external_refs.json has changes — committing"

  git add .beads/external_refs.json
  git add .beads/sync-history/ 2>/dev/null || true

  if [[ "$DRY_RUN" == true ]]; then
    warn "DRY RUN — skipping git commit and push"
    git diff --cached --stat
  else
    # [skip ci] prevents self-triggering since the workflow only watches
    # issues.jsonl, but this is defense-in-depth.
    git commit -m "sync: update external_refs from Linear push [skip ci]"

    # Retry loop for push: handle concurrent pushes with rebase
    max_retries=3
    for attempt in $(seq 1 $max_retries); do
      if git push --no-verify origin main 2>&1; then
        ok "Pushed external_refs.json to main"
        break
      else
        if [[ "$attempt" -lt "$max_retries" ]]; then
          warn "Push failed (attempt $attempt/$max_retries) — rebasing and retrying"
          git pull --rebase origin main
        else
          die "Failed to push external_refs.json after $max_retries attempts"
        fi
      fi
    done
  fi
else
  ok "No changes to external_refs.json — nothing to commit"
fi

# ── summary ──────────────────────────────────────────────────────────────

step "Summary"

ok "Sync run $RUN_ID complete"
info "Issues in JSONL:        $issue_count"
info "Delta (changed beads):  $changed_ids"
info "New beads pushed:       $created_count"
info "Updated beads:          $updated_count"
info "Sync errors:            $error_count"
info "New external refs:      $new_ref_count"
info "Existing external refs: $existing_ref_count"
info "Disappeared beads:      $disappeared_count"
info "Sync log:               $SYNC_OUTPUT_FILE"

if [[ "$DRY_RUN" == true ]]; then
  warn "This was a DRY RUN — no data was pushed to Linear or git"
fi

# Exit with sync's exit code if it failed (but still run cleanup above)
if [[ "$SYNC_EXIT" -ne 0 ]]; then
  die "Sync completed with errors (bd exit code: $SYNC_EXIT)"
fi
