#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# jira-to-linear-backfill.sh — orchestrate the 5-step Jira → Linear → beads
# migration sequence. See PLAN.md §8 "Backfill plan".
#
# The order matters. Doing it wrong creates duplicates that require
# significant cleanup. The sequence:
#
#   1. Validate Linear's native Jira import completed
#   2. Stabilize imported data (counts, hierarchy, user mapping)
#   3. Beads create-only push (new beads → Linear, skip existing)
#   4. Beads ↔ Linear external_ref reconciliation
#   5. Switch to bidirectional sync mode
#
# Scope: all open Jira issues + last 12 months of closed (decision d7).
# Older closed issues stay in Jira archive.
#
# Requires: bd, jq, curl, git
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/external-refs.sh
source "$SCRIPT_DIR/lib/external-refs.sh"

# ── configuration ──────────────────────────────────────────────────────────

STATE_FILE="${REPO_ROOT}/.backfill-state.json"
EXTERNAL_REFS_FILE="${REPO_ROOT}/.beads/external_refs.json"
ISSUES_JSONL="${REPO_ROOT}/.beads/issues.jsonl"
LINEAR_API="${LINEAR_API_URL:-https://api.linear.app/graphql}"

export EXTERNAL_REFS_FILE

TOTAL_STEPS=5

# ── colours (plain in CI, colorized locally) ───────────────────────────────

if [[ -z "${CI:-}" ]] && [[ -t 1 ]]; then
  RED=$'\033[0;31m'  GREEN=$'\033[0;32m'  YELLOW=$'\033[0;33m'
  CYAN=$'\033[0;36m' BOLD=$'\033[1m'      RESET=$'\033[0m'
else
  RED=""  GREEN=""  YELLOW=""  CYAN=""  BOLD=""  RESET=""
fi

# ── helpers ────────────────────────────────────────────────────────────────

die()     { printf '%s%sERROR:%s %b\n' "$RED" "$BOLD" "$RESET" "$1" >&2; exit 1; }
warn()    { printf '%s%sWARN:%s %s\n'  "$YELLOW" "$BOLD" "$RESET" "$1" >&2; }
ok()      { printf '%s%s✔%s %s\n'      "$GREEN" "$BOLD" "$RESET" "$1"; }
info()    { printf '%s%s→%s %s\n'      "$CYAN" "$BOLD" "$RESET" "$1"; }
step_hdr() { printf '\n%s%s══ Step %s/%s: %s ══%s\n' "$BOLD" "$CYAN" "$1" "$TOTAL_STEPS" "$2" "$RESET"; }

confirm_proceed() {
  local prompt="${1:-Continue?}"
  if [[ "$DRY_RUN" == true ]]; then
    return 0
  fi
  printf '\n%s%s%s [y/N] ' "$BOLD" "$prompt" "$RESET"
  read -r answer
  case "$answer" in
    [Yy]|[Yy][Ee][Ss]) return 0 ;;
    *) info "Aborted by user."; exit 0 ;;
  esac
}

# ── Linear API helper ─────────────────────────────────────────────────────

linear_graphql() {
  local query="$1"
  local auth_header

  if [[ -n "${LINEAR_OAUTH_TOKEN:-}" ]]; then
    auth_header="Authorization: Bearer $LINEAR_OAUTH_TOKEN"
  elif [[ -n "${LINEAR_API_KEY:-}" ]]; then
    auth_header="Authorization: $LINEAR_API_KEY"
  else
    die "No Linear credentials. Set LINEAR_API_KEY or LINEAR_OAUTH_TOKEN."
  fi

  curl -sS --fail-with-body \
    -H "Content-Type: application/json" \
    -H "$auth_header" \
    -d "$query" \
    "$LINEAR_API" 2>&1
}

linear_issue_count() {
  local team_id="$1"
  local filter="${2:-}"

  local query
  if [[ -n "$filter" ]]; then
    query="{\"query\":\"{ issueCount(filter: { team: { key: { eq: \\\"${team_id}\\\" } }${filter} }) }\"}"
  else
    query="{\"query\":\"{ issueCount(filter: { team: { key: { eq: \\\"${team_id}\\\" } } }) }\"}"
  fi

  local result
  result="$(linear_graphql "$query")"
  echo "$result" | jq -r '.data.issueCount // 0'
}

linear_issues_with_jira_label() {
  local team_id="$1"
  local query
  query="{\"query\":\"{ issues(filter: { team: { key: { eq: \\\"${team_id}\\\" } }, labels: { name: { containsIgnoreCase: \\\"jira\\\" } } }, first: 1) { totalCount: nodes { id } } }\"}"

  local result
  result="$(linear_graphql "$query")" 2>/dev/null || echo '{"data":{"issues":{"totalCount":[]}}}'
  echo "$result" | jq '.data.issues.totalCount | length // 0' 2>/dev/null || echo "0"
}

linear_search_by_description() {
  local team_id="$1" search_term="$2"
  local query
  query="{\"query\":\"{ issues(filter: { team: { key: { eq: \\\"${team_id}\\\" } }, description: { contains: \\\"${search_term}\\\" } }, first: 250) { nodes { id identifier title description } } }\"}"

  linear_graphql "$query"
}

# ── state management ──────────────────────────────────────────────────────

init_state() {
  if [[ ! -f "$STATE_FILE" ]]; then
    cat > "$STATE_FILE" <<JSON
{
  "version": 1,
  "jira_project": null,
  "linear_team": null,
  "started_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "completed_steps": [],
  "step_results": {},
  "last_step_at": null
}
JSON
  fi
}

read_state() {
  local key="$1"
  jq -r "$key" "$STATE_FILE" 2>/dev/null || echo "null"
}

update_state() {
  local tmp
  tmp="$(mktemp "${STATE_FILE}.XXXXXX")"
  jq "$1" "$STATE_FILE" > "$tmp"
  mv -f "$tmp" "$STATE_FILE"
}

mark_step_complete() {
  local step_num="$1"
  local result_json="${2:-{}}"
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  local tmp
  tmp="$(mktemp "${STATE_FILE}.XXXXXX")"

  jq --argjson step "$step_num" \
     --argjson result "$result_json" \
     --arg now "$now" \
     '
      .completed_steps = (.completed_steps + [$step] | unique | sort)
      | .step_results[($step | tostring)] = ($result + {completed_at: $now})
      | .last_step_at = $now
     ' "$STATE_FILE" > "$tmp"

  mv -f "$tmp" "$STATE_FILE"
}

step_is_complete() {
  local step_num="$1"
  jq -e --argjson s "$step_num" '.completed_steps | index($s) != null' "$STATE_FILE" &>/dev/null
}

last_completed_step() {
  jq -r '.completed_steps | max // 0' "$STATE_FILE"
}

# ── usage ──────────────────────────────────────────────────────────────────

usage() {
  cat <<EOF
${BOLD}Usage:${RESET} jira-to-linear-backfill.sh [OPTIONS]

Orchestrate the 5-step Jira → Linear → beads migration.
See PLAN.md §8 "Backfill plan" for the full sequence.

${BOLD}Options${RESET}
  --dry-run                Preview each step's actions without executing
  --step N                 Resume from step N (1-5). Default: auto-detect
  --jira-project KEY       Jira project key (e.g., PROJ). Required on first run
  --linear-team KEY        Linear team key (e.g., KEV). Default: from config
  --reset                  Clear backfill state and start fresh
  --status                 Show current backfill progress and exit
  --help                   Show this help

${BOLD}Steps${RESET}
  1  Validate Linear's native Jira import completed
  2  Stabilize imported data (counts, hierarchy, user mapping)
  3  Beads create-only push (new beads that lack Linear counterparts)
  4  Beads ↔ Linear external_ref reconciliation
  5  Switch to bidirectional sync mode

${BOLD}Environment${RESET}
  LINEAR_API_KEY             Personal Linear API key (read path)
  LINEAR_OAUTH_TOKEN         OAuth token (preferred for write operations)
  LINEAR_OAUTH_CLIENT_ID     OAuth client ID (for CI worker)
  LINEAR_OAUTH_CLIENT_SECRET OAuth client secret (for CI worker)

${BOLD}Scope${RESET}
  All open Jira issues + last 12 months of closed (decision d7).
  Older closed issues stay in Jira archive.

${BOLD}State${RESET}
  Progress is tracked in ${STATE_FILE}.
  Re-running picks up where it left off (idempotent).

${BOLD}Examples${RESET}
  # First run: preview the full sequence
  ./scripts/jira-to-linear-backfill.sh --jira-project PROJ --dry-run

  # Execute for real
  ./scripts/jira-to-linear-backfill.sh --jira-project PROJ

  # Resume from step 3 after fixing an issue
  ./scripts/jira-to-linear-backfill.sh --step 3

  # Check current progress
  ./scripts/jira-to-linear-backfill.sh --status

${BOLD}Exit codes${RESET}
  0   All steps completed (or dry-run finished)
  1   Fatal error (missing deps, failed precondition, API error)
  2   User aborted at confirmation prompt
EOF
}

# ── arg parsing ────────────────────────────────────────────────────────────

DRY_RUN=false
START_STEP=""
JIRA_PROJECT=""
LINEAR_TEAM=""
MODE="run"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)        DRY_RUN=true;        shift ;;
    --step)           START_STEP="$2";     shift 2 ;;
    --jira-project)   JIRA_PROJECT="$2";   shift 2 ;;
    --linear-team)    LINEAR_TEAM="$2";    shift 2 ;;
    --reset)          MODE="reset";        shift ;;
    --status)         MODE="status";       shift ;;
    --help|-h)        usage; exit 0 ;;
    *) die "Unknown option: $1  (try --help)" ;;
  esac
done

# ── modes: reset / status ─────────────────────────────────────────────────

do_reset() {
  if [[ -f "$STATE_FILE" ]]; then
    rm -f "$STATE_FILE"
    ok "Backfill state cleared."
  else
    info "No state file found — nothing to reset."
  fi
  exit 0
}

do_status() {
  if [[ ! -f "$STATE_FILE" ]]; then
    info "No backfill in progress. Run with --jira-project KEY to start."
    exit 0
  fi

  printf '\n%s%s── Jira → Linear Backfill Status ──%s\n\n' "$BOLD" "$CYAN" "$RESET"

  local jira_proj linear_team started completed last_at
  jira_proj="$(read_state '.jira_project')"
  linear_team="$(read_state '.linear_team')"
  started="$(read_state '.started_at')"
  completed="$(read_state '.completed_steps')"
  last_at="$(read_state '.last_step_at')"

  info "Jira project:     $jira_proj"
  info "Linear team:      $linear_team"
  info "Started:          $started"
  info "Last activity:    ${last_at}"
  info "Completed steps:  ${completed}"
  echo ""

  for s in 1 2 3 4 5; do
    local label status_icon
    case $s in
      1) label="Validate Jira import" ;;
      2) label="Stabilize imported data" ;;
      3) label="Beads create-only push" ;;
      4) label="External_ref reconciliation" ;;
      5) label="Switch to bidirectional" ;;
    esac
    if step_is_complete "$s"; then
      local completed_at
      completed_at="$(read_state ".step_results[\"$s\"].completed_at")"
      status_icon="${GREEN}✔${RESET}"
      printf '  %b Step %s: %s  (%s)\n' "$status_icon" "$s" "$label" "$completed_at"
    else
      status_icon="${YELLOW}○${RESET}"
      printf '  %b Step %s: %s\n' "$status_icon" "$s" "$label"
    fi
  done
  echo ""

  local last
  last="$(last_completed_step)"
  if [[ "$last" -ge $TOTAL_STEPS ]]; then
    ok "Backfill complete."
  else
    local next=$(( last + 1 ))
    info "Next step: $next. Resume with: ./scripts/jira-to-linear-backfill.sh --step $next"
  fi
  exit 0
}

case "$MODE" in
  reset)  do_reset ;;
  status) do_status ;;
  run)    ;; # fall through
esac

# ── preflight checks ──────────────────────────────────────────────────────

printf '\n%s%s══ Jira → Linear → Beads Backfill ══%s\n' "$BOLD" "$CYAN" "$RESET"
if [[ "$DRY_RUN" == true ]]; then
  warn "DRY RUN — no changes will be made"
fi
echo ""

command -v bd   &>/dev/null || die "bd is not on PATH"
command -v jq   &>/dev/null || die "jq is not on PATH"
command -v curl &>/dev/null || die "curl is not on PATH"
command -v git  &>/dev/null || die "git is not on PATH"
ok "All required tools found"

if [[ -z "${LINEAR_API_KEY:-}" ]] && [[ -z "${LINEAR_OAUTH_TOKEN:-}" ]]; then
  die "No Linear credentials.\n  Set LINEAR_API_KEY or LINEAR_OAUTH_TOKEN."
fi
ok "Linear credentials configured"

# Resolve Linear team
if [[ -z "$LINEAR_TEAM" ]]; then
  LINEAR_TEAM="$(bd config get linear.team_ids 2>/dev/null | cut -d',' -f1 || true)"
  if [[ -z "$LINEAR_TEAM" ]]; then
    die "Could not determine Linear team.\n  Pass --linear-team KEY or set linear.team_ids in config."
  fi
fi
ok "Linear team: $LINEAR_TEAM"

# Initialize state
init_state

# Resolve Jira project (required on first run, loaded from state on resume)
if [[ -n "$JIRA_PROJECT" ]]; then
  update_state --arg jp "$JIRA_PROJECT" '.jira_project = $jp'
  update_state --arg lt "$LINEAR_TEAM" '.linear_team = $lt'
else
  JIRA_PROJECT="$(read_state '.jira_project')"
  if [[ "$JIRA_PROJECT" == "null" || -z "$JIRA_PROJECT" ]]; then
    die "Jira project key required.\n  First run: --jira-project KEY\n  Resume: state file remembers it."
  fi
fi
ok "Jira project: $JIRA_PROJECT"

# Determine start step
if [[ -n "$START_STEP" ]]; then
  if [[ "$START_STEP" -lt 1 || "$START_STEP" -gt $TOTAL_STEPS ]]; then
    die "Step must be between 1 and $TOTAL_STEPS"
  fi
else
  START_STEP=$(( $(last_completed_step) + 1 ))
  if [[ "$START_STEP" -gt $TOTAL_STEPS ]]; then
    ok "All steps already completed."
    info "To re-run, use --reset first, or --step N to re-run a specific step."
    exit 0
  fi
fi
info "Starting from step $START_STEP"
echo ""

# ══════════════════════════════════════════════════════════════════════════
# STEP 1: Validate Linear's native Jira import completed
# ══════════════════════════════════════════════════════════════════════════

run_step_1() {
  step_hdr 1 "Validate Jira import"

  if step_is_complete 1 && [[ -z "${FORCE_STEP:-}" ]]; then
    ok "Already completed — skipping (use --reset to re-run)"
    return 0
  fi

  info "Checking if Linear has issues imported from Jira project $JIRA_PROJECT..."
  info "Linear's native Jira importer preserves Jira keys and establishes ID mappings."
  echo ""

  # Check for issues in the target team
  local total_count
  total_count="$(linear_issue_count "$LINEAR_TEAM")" || die "Failed to query Linear API"
  info "Total issues in Linear team $LINEAR_TEAM: $total_count"

  if [[ "$total_count" -eq 0 ]]; then
    echo ""
    warn "No issues found in Linear team $LINEAR_TEAM."
    echo ""
    echo "  The Jira import must happen first, through Linear's native importer:"
    echo ""
    echo "  1. Go to Linear → Settings → Import & Export → Import from Jira"
    echo "  2. Select Jira project: $JIRA_PROJECT"
    echo "  3. Import scope: all open issues + last 12 months of closed (d7)"
    echo "  4. Wait for the import to complete (Linear shows progress)"
    echo "  5. Re-run this script"
    echo ""
    die "Jira import has not been performed yet."
  fi

  # Look for signs of Jira import: issues with Jira-style identifiers in
  # description/comments, or issues created by the import process.
  # Linear's importer typically adds "[Imported from Jira]" or preserves
  # the Jira key in the description.
  local jira_key_pattern="$JIRA_PROJECT-"
  local search_result
  search_result="$(linear_search_by_description "$LINEAR_TEAM" "$jira_key_pattern")" 2>/dev/null || true

  local imported_count=0
  if [[ -n "$search_result" ]]; then
    imported_count="$(echo "$search_result" | jq '.data.issues.nodes | length' 2>/dev/null || echo 0)"
  fi

  info "Issues containing '$jira_key_pattern' in description: $imported_count"

  if [[ "$imported_count" -eq 0 ]]; then
    warn "No issues with Jira key pattern found."
    warn "This could mean:"
    warn "  - The Jira import hasn't been run yet"
    warn "  - Linear's importer didn't preserve Jira keys in descriptions"
    warn "  - The Jira project key '$JIRA_PROJECT' is wrong"
    echo ""
    if [[ "$DRY_RUN" == true ]]; then
      warn "DRY RUN — would prompt for confirmation to proceed"
    else
      confirm_proceed "No Jira-imported issues detected. Proceed anyway?"
    fi
  else
    ok "Jira import detected: $imported_count issues with Jira key references"
  fi

  local result
  result="$(jq -n \
    --argjson total "$total_count" \
    --argjson imported "$imported_count" \
    --arg team "$LINEAR_TEAM" \
    '{total_issues: $total, jira_imported: $imported, team: $team}')"

  mark_step_complete 1 "$result"
  ok "Step 1 complete"
}

# ══════════════════════════════════════════════════════════════════════════
# STEP 2: Stabilize imported data
# ══════════════════════════════════════════════════════════════════════════

run_step_2() {
  step_hdr 2 "Stabilize imported data"

  if step_is_complete 2 && [[ -z "${FORCE_STEP:-}" ]]; then
    ok "Already completed — skipping"
    return 0
  fi

  info "Validating Linear state after Jira import..."
  echo ""

  # Count issues by state type
  local total open_count closed_count
  total="$(linear_issue_count "$LINEAR_TEAM")"

  # Use state type filter: completed/canceled = closed, the rest = open
  local completed_query=', state: { type: { in: [\"completed\", \"canceled\"] } }'
  local active_query=', state: { type: { nin: [\"completed\", \"canceled\"] } }'

  closed_count="$(linear_issue_count "$LINEAR_TEAM" "$completed_query")" || closed_count="unknown"
  open_count="$(linear_issue_count "$LINEAR_TEAM" "$active_query")" || open_count="unknown"

  info "Issue counts in Linear team $LINEAR_TEAM:"
  info "  Total:   $total"
  info "  Open:    $open_count"
  info "  Closed:  $closed_count"
  echo ""

  # Check for issues without assignees (common post-import if user mapping
  # wasn't configured in the importer)
  local unassigned_query=', assignee: { null: true }'
  local unassigned_count
  unassigned_count="$(linear_issue_count "$LINEAR_TEAM" "$unassigned_query")" || unassigned_count="unknown"

  if [[ "$unassigned_count" != "unknown" && "$unassigned_count" -gt 0 ]]; then
    warn "$unassigned_count issues have no assignee (Jira → Linear user mapping may need attention)"
  else
    ok "All issues have assignees"
  fi

  # Check for sub-issues (hierarchy validation)
  local sub_issue_query=', parent: { null: false }'
  local sub_issue_count
  sub_issue_count="$(linear_issue_count "$LINEAR_TEAM" "$sub_issue_query")" || sub_issue_count="unknown"
  info "Issues with parent (sub-issues): $sub_issue_count"

  echo ""
  info "Stabilization checklist (verify manually):"
  echo "  [ ] Jira epics mapped correctly to Linear projects or parent issues"
  echo "  [ ] Jira users mapped to correct Linear members"
  echo "  [ ] Labels/status mappings look correct in Linear"
  echo "  [ ] No duplicate issues from the import"
  echo "  [ ] Linear's Jira-sync transition mode is still active (if needed)"
  echo ""

  if [[ "$DRY_RUN" == true ]]; then
    warn "DRY RUN — would prompt for confirmation that stabilization is complete"
  else
    confirm_proceed "Have you reviewed the imported data and confirmed it's stable?"
  fi

  local result
  result="$(jq -n \
    --argjson total "$total" \
    --arg open "$open_count" \
    --arg closed "$closed_count" \
    --arg unassigned "$unassigned_count" \
    --arg sub_issues "$sub_issue_count" \
    '{total: $total, open: $open, closed: $closed, unassigned: $unassigned, sub_issues: $sub_issues}')"

  mark_step_complete 2 "$result"
  ok "Step 2 complete"
}

# ══════════════════════════════════════════════════════════════════════════
# STEP 3: Beads create-only push
# ══════════════════════════════════════════════════════════════════════════

run_step_3() {
  step_hdr 3 "Beads create-only push"

  if step_is_complete 3 && [[ -z "${FORCE_STEP:-}" ]]; then
    ok "Already completed — skipping"
    return 0
  fi

  info "Pushing beads that don't have Linear counterparts..."
  info "Mode: --create-only (will NOT overwrite Jira-imported data)"
  echo ""

  # Count beads and those already linked
  if [[ ! -f "$ISSUES_JSONL" ]]; then
    die "issues.jsonl not found at $ISSUES_JSONL\n  Run 'bd export' first."
  fi

  local total_beads
  total_beads="$(wc -l < "$ISSUES_JSONL" | tr -d ' ')"

  _ensure_file
  local linked_count unlinked_count
  linked_count="$(count_external_refs)"
  unlinked_count=$((total_beads - linked_count))
  if [[ "$unlinked_count" -lt 0 ]]; then
    unlinked_count=0
  fi

  info "Total beads in JSONL:             $total_beads"
  info "Already linked (external_ref):    $linked_count"
  info "Unlinked (candidates for push):   $unlinked_count"
  echo ""

  if [[ "$unlinked_count" -eq 0 ]]; then
    ok "All beads already have external_refs — nothing to push"
    mark_step_complete 3 '{"pushed": 0, "skipped": '"$total_beads"'}'
    return 0
  fi

  # Run a dry-run first to preview
  info "Previewing what would be pushed:"
  bd linear sync --push --create-only --dry-run 2>&1 | while IFS= read -r line; do
    info "  $line"
  done || true
  echo ""

  if [[ "$DRY_RUN" == true ]]; then
    warn "DRY RUN — skipping actual push"
    mark_step_complete 3 '{"dry_run": true, "would_push": '"$unlinked_count"'}'
    return 0
  fi

  confirm_proceed "Push $unlinked_count new beads to Linear (create-only)?"

  info "Running: bd linear sync --push --create-only"
  local push_output
  if push_output="$(bd linear sync --push --create-only 2>&1)"; then
    ok "Create-only push completed"
  else
    local exit_code=$?
    warn "Push exited with code $exit_code"
    echo "$push_output" | while IFS= read -r line; do
      warn "  $line"
    done
    die "Create-only push failed. Check output above and resolve before continuing."
  fi

  echo "$push_output" | while IFS= read -r line; do
    info "  $line"
  done

  mark_step_complete 3 "$(jq -n --argjson count "$unlinked_count" '{pushed: $count}')"
  ok "Step 3 complete"
}

# ══════════════════════════════════════════════════════════════════════════
# STEP 4: Beads ↔ Linear external_ref reconciliation
# ══════════════════════════════════════════════════════════════════════════

run_step_4() {
  step_hdr 4 "External_ref reconciliation"

  if step_is_complete 4 && [[ -z "${FORCE_STEP:-}" ]]; then
    ok "Already completed — skipping"
    return 0
  fi

  info "Matching existing beads to their Linear counterparts..."
  info "For beads with Jira IDs: look up the corresponding Linear issue"
  info "(Linear's importer preserves Jira keys)."
  echo ""

  if [[ ! -f "$ISSUES_JSONL" ]]; then
    die "issues.jsonl not found at $ISSUES_JSONL"
  fi

  _ensure_file

  # Find beads that still lack external_refs
  local unlinked_beads=()
  local already_linked=0
  local total=0

  while IFS= read -r line; do
    total=$((total + 1))
    local bead_id
    bead_id="$(echo "$line" | jq -r '.id')"

    local existing_ref
    existing_ref="$(get_external_ref "$bead_id")"
    if [[ -n "$existing_ref" ]]; then
      already_linked=$((already_linked + 1))
      continue
    fi
    unlinked_beads+=("$bead_id")
  done < "$ISSUES_JSONL"

  info "Total beads:        $total"
  info "Already linked:     $already_linked"
  info "Need reconciling:   ${#unlinked_beads[@]}"
  echo ""

  if [[ ${#unlinked_beads[@]} -eq 0 ]]; then
    ok "All beads have external_refs — reconciliation complete"
    mark_step_complete 4 '{"reconciled": 0, "already_linked": '"$already_linked"'}'
    return 0
  fi

  # Attempt to match unlinked beads to Linear issues.
  # Strategy: search Linear for issues whose description contains the
  # bead's idempotency marker or title.
  local matched=0
  local unmatched=0
  local match_details=()

  for bead_id in "${unlinked_beads[@]}"; do
    local bead_line
    bead_line="$(jq -r --arg id "$bead_id" 'select(.id == $id)' "$ISSUES_JSONL" | head -1)"

    if [[ -z "$bead_line" ]]; then
      unmatched=$((unmatched + 1))
      continue
    fi

    local bead_title
    bead_title="$(echo "$bead_line" | jq -r '.title // ""')"

    # Try idempotency marker first (if present)
    local marker_search="bd-idempotency.*${bead_id}"
    local search_result
    search_result="$(linear_search_by_description "$LINEAR_TEAM" "bd-idempotency: " 2>/dev/null || echo '{}')"

    local linear_match_id="" linear_match_url="" linear_match_ident=""

    # Search by idempotency marker in description
    if [[ -n "$search_result" ]]; then
      local candidate
      candidate="$(echo "$search_result" | jq -r \
        --arg bid "$bead_id" \
        '.data.issues.nodes[]
         | select(.description != null and (.description | contains($bid)))
         | {id: .id, identifier: .identifier, title: .title}' 2>/dev/null | head -1 || true)"

      if [[ -n "$candidate" && "$candidate" != "null" ]]; then
        linear_match_id="$(echo "$candidate" | jq -r '.id')"
        linear_match_ident="$(echo "$candidate" | jq -r '.identifier')"
      fi
    fi

    # Fall back: search by Jira key if bead has an external_ref that looks like Jira
    if [[ -z "$linear_match_id" ]]; then
      local jira_ref
      jira_ref="$(echo "$bead_line" | jq -r '.external_ref // ""')"

      if [[ "$jira_ref" == *"$JIRA_PROJECT-"* ]]; then
        local jira_key
        jira_key="$(echo "$jira_ref" | grep -oE "${JIRA_PROJECT}-[0-9]+" | head -1 || true)"

        if [[ -n "$jira_key" ]]; then
          local jira_search
          jira_search="$(linear_search_by_description "$LINEAR_TEAM" "$jira_key" 2>/dev/null || echo '{}')"

          candidate="$(echo "$jira_search" | jq -r \
            --arg jk "$jira_key" \
            '.data.issues.nodes[]
             | select(.description != null and (.description | contains($jk)))
             | {id: .id, identifier: .identifier, title: .title}' 2>/dev/null | head -1 || true)"

          if [[ -n "$candidate" && "$candidate" != "null" ]]; then
            linear_match_id="$(echo "$candidate" | jq -r '.id')"
            linear_match_ident="$(echo "$candidate" | jq -r '.identifier')"
          fi
        fi
      fi
    fi

    if [[ -n "$linear_match_id" ]]; then
      local linear_url="https://linear.app/${LINEAR_TEAM}/issue/${linear_match_ident}"

      if [[ "$DRY_RUN" == true ]]; then
        info "  MATCH (dry-run): $bead_id → $linear_match_ident ($bead_title)"
      else
        set_external_ref "$bead_id" "$linear_match_id" "$linear_url"
        ok "  Linked: $bead_id → $linear_match_ident"
      fi
      matched=$((matched + 1))
    else
      if [[ "$DRY_RUN" == true ]]; then
        info "  NO MATCH: $bead_id ($bead_title)"
      else
        warn "  No match found for: $bead_id ($bead_title)"
      fi
      unmatched=$((unmatched + 1))
    fi
  done

  echo ""
  info "Reconciliation results:"
  info "  Matched:   $matched"
  info "  Unmatched: $unmatched"

  if [[ "$unmatched" -gt 0 ]]; then
    echo ""
    warn "$unmatched beads could not be matched to Linear issues."
    warn "These will be created as new Linear issues on the next push."
    warn "Review them manually if they should be linked to existing issues."
  fi

  local result
  result="$(jq -n \
    --argjson matched "$matched" \
    --argjson unmatched "$unmatched" \
    --argjson already "$already_linked" \
    '{matched: $matched, unmatched: $unmatched, already_linked: $already}')"

  mark_step_complete 4 "$result"
  ok "Step 4 complete"
}

# ══════════════════════════════════════════════════════════════════════════
# STEP 5: Switch to bidirectional sync mode
# ══════════════════════════════════════════════════════════════════════════

run_step_5() {
  step_hdr 5 "Switch to bidirectional sync"

  if step_is_complete 5 && [[ -z "${FORCE_STEP:-}" ]]; then
    ok "Already completed — skipping"
    return 0
  fi

  info "Transitioning from create-only to full bidirectional sync..."
  echo ""

  # Validate config
  info "Checking sync configuration..."
  bash "$SCRIPT_DIR/validate-config.sh" 2>&1 | while IFS= read -r line; do
    info "  $line"
  done || true
  echo ""

  # Validate pull cron status
  info "Checking pull cron status..."
  if bash "$SCRIPT_DIR/install-pull-cron.sh" --status 2>&1 | grep -q "Cron is installed"; then
    ok "Pull cron is installed"
  else
    warn "Pull cron is NOT installed"
    echo ""
    echo "  Install it with:"
    echo "    bash scripts/install-pull-cron.sh"
    echo ""
    if [[ "$DRY_RUN" != true ]]; then
      confirm_proceed "Continue without pull cron? (You can install it later)"
    fi
  fi

  # Test a pull to verify round-trip
  info "Testing pull sync (--prefer-linear)..."
  echo ""

  if [[ "$DRY_RUN" == true ]]; then
    warn "DRY RUN — would run: bd linear sync --pull --prefer-linear --dry-run"
    bd linear sync --pull --prefer-linear --dry-run 2>&1 | while IFS= read -r line; do
      info "  $line"
    done || true
  else
    confirm_proceed "Run a test pull to verify round-trip sync?"

    info "Running: bd linear sync --pull --prefer-linear"
    if bd linear sync --pull --prefer-linear 2>&1 | while IFS= read -r line; do
      info "  $line"
    done; then
      ok "Pull sync succeeded"
    else
      warn "Pull sync had issues — check output above"
    fi
  fi

  echo ""
  info "Bidirectional sync checklist:"
  echo "  [ ] CI worker is deployed and running (linear-sync workflow)"
  echo "  [ ] Pull cron installed on developer laptops"
  echo "  [ ] LINEAR_API_KEY set in env (not in config.yaml)"
  echo "  [ ] Config validated against org template"
  echo "  [ ] Linear's Jira-sync transition mode can be disabled"
  echo ""

  if [[ "$DRY_RUN" != true ]]; then
    confirm_proceed "Confirm bidirectional sync is operational?"
  fi

  # Final validation: check external_ref coverage
  _ensure_file
  local total_beads ref_count coverage_pct
  total_beads="$(wc -l < "$ISSUES_JSONL" | tr -d ' ')"
  ref_count="$(count_external_refs)"

  if [[ "$total_beads" -gt 0 ]]; then
    coverage_pct=$(( (ref_count * 100) / total_beads ))
  else
    coverage_pct=100
  fi

  info "External_ref coverage: $ref_count / $total_beads ($coverage_pct%)"

  if [[ "$coverage_pct" -lt 90 ]]; then
    warn "Coverage is below 90% — some beads may not be synced to Linear"
    warn "Run step 4 again or investigate unlinked beads"
  else
    ok "Coverage looks healthy"
  fi

  local result
  result="$(jq -n \
    --argjson total "$total_beads" \
    --argjson linked "$ref_count" \
    --argjson coverage "$coverage_pct" \
    '{total_beads: $total, linked: $linked, coverage_pct: $coverage}')"

  mark_step_complete 5 "$result"
  ok "Step 5 complete"
}

# ── main execution loop ───────────────────────────────────────────────────

for step_num in $(seq "$START_STEP" "$TOTAL_STEPS"); do
  case "$step_num" in
    1) run_step_1 ;;
    2) run_step_2 ;;
    3) run_step_3 ;;
    4) run_step_4 ;;
    5) run_step_5 ;;
  esac

  # Confirmation between steps (live mode only, not after the last step)
  if [[ "$step_num" -lt "$TOTAL_STEPS" ]] && [[ "$DRY_RUN" != true ]]; then
    echo ""
    confirm_proceed "Proceed to step $(( step_num + 1 ))?"
  fi
done

# ── summary ───────────────────────────────────────────────────────────────

printf '\n%s%s══ Backfill Summary ══%s\n\n' "$BOLD" "$CYAN" "$RESET"

ok "All $TOTAL_STEPS steps completed"
info "Jira project:  $JIRA_PROJECT"
info "Linear team:   $LINEAR_TEAM"
info "State file:    $STATE_FILE"

if [[ "$DRY_RUN" == true ]]; then
  echo ""
  warn "This was a DRY RUN — no changes were made"
  info "Run without --dry-run to execute for real"
fi

echo ""
info "Next steps:"
echo "  1. Verify Linear board reflects all beads correctly"
echo "  2. Ensure CI worker (linear-sync workflow) is active"
echo "  3. Confirm pull cron is installed on all developer laptops"
echo "  4. Disable Linear's Jira-sync transition mode when ready"
echo "  5. Decommission Jira project $JIRA_PROJECT"
