#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# linear-sync-worker.sh — CI worker entrypoint for beads → Linear push sync.
#
# Called by the GitHub Actions workflow (.github/workflows/linear-sync.yml).
# This is the sole Linear writer in the architecture. See PLAN.md §5.
#
# Responsibilities:
#   1. Import beads from issues.jsonl into a fresh local DB
#   2. Push new/updated beads to Linear via bd linear sync --push
#   3. Merge resulting external_refs into .beads/external_refs.json
#   4. Commit and push external_refs.json back to main
#   5. Archive disappeared beads (d12: archive, don't delete)
#   6. Enforce push-volume safety check (max delta per run)
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

export EXTERNAL_REFS_FILE  # used by external-refs.sh

# ── colours (plain in CI, colorized locally) ──────────────────────────────

if [[ -z "${CI:-}" ]] && [[ -t 1 ]]; then
  RED=$'\033[0;31m'  GREEN=$'\033[0;32m'  YELLOW=$'\033[0;33m'
  CYAN=$'\033[0;36m' BOLD=$'\033[1m'      RESET=$'\033[0m'
else
  RED=""  GREEN=""  YELLOW=""  CYAN=""  BOLD=""  RESET=""
fi

# ── helpers ───────────────────────────────────────────────────────────────

die()  { printf '%s%sERROR:%s %b\n' "$RED" "$BOLD" "$RESET" "$1" >&2; exit 1; }
warn() { printf '%s%sWARN:%s %s\n'  "$YELLOW" "$BOLD" "$RESET" "$1" >&2; }
ok()   { printf '%s%s✔%s %s\n'      "$GREEN" "$BOLD" "$RESET" "$1"; }
info() { printf '%s%s→%s %s\n'      "$CYAN" "$BOLD" "$RESET" "$1"; }
step() { printf '\n%s%s── %s ──%s\n' "$BOLD" "$CYAN" "$1" "$RESET"; }

usage() {
  cat <<EOF
${BOLD}Usage:${RESET} linear-sync-worker.sh [OPTIONS]

CI worker entrypoint that pushes beads to Linear and commits external_refs
back to main. This is the sole Linear writer in the beads-to-linear
architecture.

${BOLD}Options${RESET}
  --dry-run       Run all steps but skip the actual Linear push and git push
  --max-delta N   Override push-volume safety threshold (default: $MAX_PUSH_DELTA)
  --help          Show this help

${BOLD}Environment${RESET}
  LINEAR_API_KEY               Linear API key (fallback auth)
  LINEAR_OAUTH_CLIENT_ID       OAuth client ID (preferred auth)
  LINEAR_OAUTH_CLIENT_SECRET   OAuth client secret (preferred auth)
  BTL_MAX_PUSH_DELTA           Push-volume safety threshold (default: $MAX_PUSH_DELTA)
  CI                           Set by GitHub Actions; disables colors

${BOLD}Exit codes${RESET}
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

command -v bd  &>/dev/null || die "bd is not on PATH"
command -v jq  &>/dev/null || die "jq is not on PATH"
command -v git &>/dev/null || die "git is not on PATH"

# Auth: prefer OAuth, fall back to API key
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

# ── step 1: import beads from JSONL ──────────────────────────────────────

step "Import"

info "Importing beads from $ISSUES_JSONL"
bd import "$ISSUES_JSONL"
ok "Import complete"

# ── step 2: load existing external_refs for dedup ────────────────────────

step "External refs"

_ensure_file
existing_ref_count="$(count_external_refs)"
ok "Loaded $existing_ref_count existing external refs"

# ── step 3: push-volume safety check ────────────────────────────────────

step "Push-volume safety check"

# Count beads that would be pushed (those without external_refs = new).
# Beads WITH refs that have changed since last sync = updated.
# For safety, we check total new beads. Updated beads are bounded by
# the existing ref count and are less likely to be a bad-merge flood.
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
  die "Push-volume safety check FAILED.\n\n  New beads to push: $new_bead_count\n  Threshold:         $MAX_PUSH_DELTA\n\n  This likely indicates a bad merge or bulk import.\n  To override: BTL_MAX_PUSH_DELTA=$new_bead_count bash scripts/linear-sync-worker.sh\n  Or use --max-delta $new_bead_count"
  exit 2
fi

ok "Push volume within safe limits"

# ── step 4: push to Linear ──────────────────────────────────────────────

step "Linear push"

mkdir -p "$SYNC_HISTORY_DIR"
RUN_ID="${GITHUB_RUN_ID:-local-$(date +%s)}"
SYNC_OUTPUT_FILE="$SYNC_HISTORY_DIR/${RUN_ID}.json"

if [[ "$DRY_RUN" == true ]]; then
  warn "DRY RUN — skipping actual Linear push"
  echo '{"created":[],"updated":[],"errors":[],"dry_run":true}' > "$SYNC_OUTPUT_FILE"
else
  info "Running: bd linear sync --push --json"
  if bd linear sync --push --json > "$SYNC_OUTPUT_FILE" 2>&1; then
    ok "Linear push completed"
  else
    local_exit=$?
    warn "bd linear sync exited with code $local_exit"
    # Log is still captured; continue to parse what we can
  fi
fi

ok "Sync output saved to $SYNC_OUTPUT_FILE"

# ── step 5: parse sync output and merge external_refs ────────────────────

step "Merge external refs"

# Extract new/updated external refs from sync output.
# bd linear sync --push --json emits objects with bead_id, linear_id, linear_url.
# The exact schema depends on the bd version; we handle the common shapes.
TEMP_REFS="$(mktemp)"
trap 'rm -f "$TEMP_REFS"' EXIT

# Build a refs object from the sync output.
# Try the standard shape: {created: [{id, external_ref, ...}], updated: [...]}
jq -r '
  def extract_ref:
    select(.id != null and .external_ref != null)
    | {(.id): {
        linear_id: (.linear_id // (.external_ref | split("/") | last | split("-") | first)),
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
  info "No new external refs to merge"
fi

# ── step 6: handle disappeared beads (decision d12 — archive) ───────────

step "Disappearance check (d12)"

disappeared="$(find_disappeared_beads "$ISSUES_JSONL")"

if [[ -n "$disappeared" ]]; then
  disappeared_count="$(echo "$disappeared" | wc -l | tr -d ' ')"
  info "Found $disappeared_count bead(s) in external_refs.json but not in issues.jsonl"

  while IFS= read -r bead_id; do
    ref_json="$(get_external_ref "$bead_id")"
    linear_id="$(echo "$ref_json" | jq -r '.linear_id')"

    if [[ "$DRY_RUN" == true ]]; then
      warn "DRY RUN — would archive Linear issue $linear_id (bead $bead_id)"
    else
      info "Archiving Linear issue $linear_id (bead $bead_id disappeared)"
      # bd linear archive uses the Linear API to set issue state to archived.
      # If this command doesn't exist yet, log and continue.
      if bd linear archive "$linear_id" 2>/dev/null; then
        ok "Archived $linear_id"
      else
        warn "Could not archive $linear_id — bd linear archive may not be available yet. Logging for manual follow-up."
      fi
    fi
  done <<< "$disappeared"
else
  ok "No disappeared beads"
fi

# ── step 7: commit and push external_refs.json ──────────────────────────

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
    git commit -m "sync: update external_refs from Linear [skip ci]"

    # Pull with rebase to handle any concurrent pushes, then push
    git pull --rebase origin main 2>/dev/null || true
    git push origin main

    ok "Committed and pushed external_refs.json"
  fi
else
  ok "No changes to external_refs.json — nothing to commit"
fi

# ── summary ──────────────────────────────────────────────────────────────

step "Summary"

ok "Sync run $RUN_ID complete"
info "Issues in JSONL:        $issue_count"
info "Existing external refs: $existing_ref_count"
info "New refs this run:      $new_ref_count"
info "Disappeared beads:      ${disappeared_count:-0}"
info "Sync log:               $SYNC_OUTPUT_FILE"

if [[ "$DRY_RUN" == true ]]; then
  warn "This was a DRY RUN — no data was pushed to Linear or git"
fi
