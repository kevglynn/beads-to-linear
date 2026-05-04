#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# sync-health-check.sh — comprehensive health check for the beads ↔ Linear
# sync system.  Can be run manually, by cron, or by monitoring systems.
#
# Checks: CI sync status, external_ref coverage, API quota, cron pull health,
# config drift, and error-state beads.
#
# Requires: gh, jq, git
# Optional: bd (for bead-level checks)
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── configuration ──────────────────────────────────────────────────────────

CRON_MARKER="# beads-to-linear-sync"
SYNC_LOG_FILE="$HOME/.beads-sync.log"
TEMPLATE_CONFIG="${REPO_ROOT}/templates/.beads/config.yaml"
ISSUES_JSONL="${REPO_ROOT}/.beads/issues.jsonl"
EXTERNAL_REFS_FILE="${REPO_ROOT}/.beads/external_refs.json"

WARN_SYNC_AGE_MINUTES=60        # warn if last CI sync > 60 min ago
CRIT_SYNC_AGE_MINUTES=360       # critical if > 6 hours
WARN_CRON_AGE_MINUTES=30        # warn if local cron hasn't run in 30 min
CRIT_CRON_AGE_MINUTES=120       # critical if > 2 hours
WARN_COVERAGE_PCT=90            # warn if external_ref coverage < 90%
WARN_QUOTA_PCT=80               # warn if API quota > 80% utilized

# ── output mode ────────────────────────────────────────────────────────────

OUTPUT_MODE="human"  # human | json | agent
GH_REPO=""           # auto-detected or overridden with --repo

# ── colours (disabled for non-tty or machine output) ──────────────────────

_setup_colors() {
  if [[ "$OUTPUT_MODE" == "human" ]] && [[ -t 1 ]]; then
    RED=$'\033[0;31m'  GREEN=$'\033[0;32m'  YELLOW=$'\033[0;33m'
    CYAN=$'\033[0;36m' BOLD=$'\033[1m'      RESET=$'\033[0m'
  else
    RED=""  GREEN=""  YELLOW=""  CYAN=""  BOLD=""  RESET=""
  fi
}

# ── helpers ────────────────────────────────────────────────────────────────

die()  { printf '%sERROR:%s %b\n' "$RED" "$RESET" "$1" >&2; exit 1; }

usage() {
  cat <<EOF
${BOLD:-}Usage:${RESET:-} sync-health-check.sh [OPTIONS]

Comprehensive health check for the beads ↔ Linear sync system.

${BOLD:-}Output modes${RESET:-}
  (default)     Human-readable with colored status indicators
  --json        Machine-consumable JSON
  --agent       Compact agent-friendly output

${BOLD:-}Options${RESET:-}
  --repo OWNER/REPO   GitHub repo (default: auto-detect from git remote)
  --help              Show this help

${BOLD:-}Exit codes${RESET:-}
  0   Healthy — all checks passed
  1   Warning — degraded but functional
  2   Critical — immediate attention required

${BOLD:-}Examples${RESET:-}
  # Quick manual check
  ./scripts/sync-health-check.sh

  # Feed to monitoring system
  ./scripts/sync-health-check.sh --json

  # Agent consumption
  ./scripts/sync-health-check.sh --agent
EOF
}

# ── arg parsing ────────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
  case "$1" in
    --json)    OUTPUT_MODE="json";  shift ;;
    --agent)   OUTPUT_MODE="agent"; shift ;;
    --repo)    GH_REPO="$2";       shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) die "Unknown option: $1  (try --help)" ;;
  esac
done

_setup_colors

# ── resolve repo ───────────────────────────────────────────────────────────

if [[ -z "$GH_REPO" ]]; then
  GH_REPO="$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null \
    | sed -E 's#.*github\.com[:/]##; s#\.git$##')" \
    || die "Cannot detect GitHub repo. Use --repo OWNER/REPO."
fi

# ── state tracking ─────────────────────────────────────────────────────────

OVERALL_STATUS="healthy"  # healthy | warning | critical
declare -a CHECK_RESULTS=()

record() {
  local status="$1" check="$2" detail="$3"
  CHECK_RESULTS+=("$(printf '{"status":"%s","check":"%s","detail":"%s"}' "$status" "$check" "$detail")")

  if [[ "$status" == "critical" ]]; then
    OVERALL_STATUS="critical"
  elif [[ "$status" == "warning" && "$OVERALL_STATUS" != "critical" ]]; then
    OVERALL_STATUS="warning"
  fi

  if [[ "$OUTPUT_MODE" == "human" ]]; then
    case "$status" in
      ok)       printf '  %s✔ PASS%s  %s — %s\n' "$GREEN" "$RESET" "$check" "$detail" ;;
      warning)  printf '  %s⚠ WARN%s  %s — %s\n' "$YELLOW" "$RESET" "$check" "$detail" ;;
      critical) printf '  %s✖ CRIT%s  %s — %s\n' "$RED" "$RESET" "$check" "$detail" ;;
    esac
  elif [[ "$OUTPUT_MODE" == "agent" ]]; then
    local icon
    case "$status" in ok) icon="OK";; warning) icon="WARN";; critical) icon="CRIT";; esac
    printf '%s %s: %s\n' "$icon" "$check" "$detail"
  fi
}

# ── check 1: last CI sync run ─────────────────────────────────────────────

check_ci_sync() {
  [[ "$OUTPUT_MODE" == "human" ]] && printf '\n%s── CI Sync Status ──%s\n' "$BOLD" "$RESET"

  if ! command -v gh &>/dev/null; then
    record "warning" "ci_sync" "gh CLI not installed — cannot check CI status"
    return
  fi

  local runs_json
  runs_json="$(gh run list --workflow=linear-sync.yml --repo "$GH_REPO" \
    --limit 5 --json status,conclusion,createdAt,databaseId,event 2>/dev/null)" \
    || { record "warning" "ci_sync" "Cannot query GitHub Actions (auth or repo issue)"; return; }

  local run_count
  run_count="$(echo "$runs_json" | jq 'length')"

  if [[ "$run_count" -eq 0 ]]; then
    record "warning" "ci_sync" "No CI sync runs found"
    return
  fi

  # Last run info
  local last_conclusion last_created last_status
  last_conclusion="$(echo "$runs_json" | jq -r '.[0].conclusion // "in_progress"')"
  last_status="$(echo "$runs_json" | jq -r '.[0].status')"
  last_created="$(echo "$runs_json" | jq -r '.[0].createdAt')"

  if [[ "$last_status" == "in_progress" || "$last_status" == "queued" ]]; then
    record "ok" "ci_sync_current" "Sync run currently ${last_status}"
  elif [[ "$last_conclusion" == "success" ]]; then
    record "ok" "ci_sync_last" "Last run succeeded at ${last_created}"
  else
    record "warning" "ci_sync_last" "Last run: ${last_conclusion} at ${last_created}"
  fi

  # Find last successful run
  local last_success_time
  last_success_time="$(echo "$runs_json" | jq -r '[.[] | select(.conclusion == "success")] | .[0].createdAt // "none"')"

  if [[ "$last_success_time" == "none" ]]; then
    record "critical" "ci_sync_success" "No successful sync in last 5 runs"
    return
  fi

  # Age of last successful sync
  local now_epoch success_epoch age_minutes
  now_epoch="$(date +%s)"
  success_epoch="$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$last_success_time" +%s 2>/dev/null \
    || date -d "$last_success_time" +%s 2>/dev/null \
    || echo "0")"

  if [[ "$success_epoch" -gt 0 ]]; then
    age_minutes="$(( (now_epoch - success_epoch) / 60 ))"

    if [[ "$age_minutes" -gt "$CRIT_SYNC_AGE_MINUTES" ]]; then
      record "critical" "ci_sync_age" "Last success was ${age_minutes}m ago (threshold: ${CRIT_SYNC_AGE_MINUTES}m)"
    elif [[ "$age_minutes" -gt "$WARN_SYNC_AGE_MINUTES" ]]; then
      record "warning" "ci_sync_age" "Last success was ${age_minutes}m ago (threshold: ${WARN_SYNC_AGE_MINUTES}m)"
    else
      record "ok" "ci_sync_age" "Last success ${age_minutes}m ago"
    fi
  fi

  # Consecutive failure count
  local consecutive_failures
  consecutive_failures="$(echo "$runs_json" | jq '[.[] | select(.conclusion != null)] | [foreach .[] as $r (0; if $r.conclusion != "success" then . + 1 else -1; break end)] | max // 0')"
  # Simpler: count from head until first success
  consecutive_failures="$(echo "$runs_json" | jq '[.[] | .conclusion] | [limit(length; range(length)) as $i | if .[$i] == "success" then $i else empty end] | .[0] // length')"

  if [[ "$consecutive_failures" -ge 3 ]]; then
    record "critical" "ci_consecutive_failures" "${consecutive_failures} consecutive failures — escalating"
  elif [[ "$consecutive_failures" -ge 1 ]]; then
    record "warning" "ci_consecutive_failures" "${consecutive_failures} consecutive failure(s)"
  else
    record "ok" "ci_consecutive_failures" "No consecutive failures"
  fi
}

# ── check 2: external_ref coverage ────────────────────────────────────────

check_coverage() {
  [[ "$OUTPUT_MODE" == "human" ]] && printf '\n%s── External Ref Coverage ──%s\n' "$BOLD" "$RESET"

  if [[ ! -f "$ISSUES_JSONL" ]]; then
    record "warning" "coverage" "issues.jsonl not found at ${ISSUES_JSONL}"
    return
  fi

  local total_beads=0 wisp_count=0 trackable_beads=0 covered=0

  total_beads="$(wc -l < "$ISSUES_JSONL" | tr -d ' ')"

  # Exclude wisps/ephemeral from coverage calculation
  wisp_count="$(jq -r 'select(.type == "wisp" or .type == "memory" or .ephemeral == true) | .id' "$ISSUES_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
  trackable_beads="$(( total_beads - wisp_count ))"

  if [[ "$trackable_beads" -eq 0 ]]; then
    record "ok" "coverage" "No trackable beads (total: ${total_beads}, wisps: ${wisp_count})"
    return
  fi

  # Count beads that have external refs
  if [[ -f "$EXTERNAL_REFS_FILE" ]]; then
    covered="$(jq 'length' "$EXTERNAL_REFS_FILE" 2>/dev/null || echo 0)"
  fi

  local coverage_pct
  coverage_pct="$(( covered * 100 / trackable_beads ))"

  record "ok" "coverage_total" "Total beads: ${total_beads} (trackable: ${trackable_beads}, wisps: ${wisp_count})"
  record "ok" "coverage_refs" "External refs: ${covered}"

  if [[ "$coverage_pct" -lt "$WARN_COVERAGE_PCT" ]]; then
    local missing="$(( trackable_beads - covered ))"
    record "warning" "coverage_pct" "Coverage: ${coverage_pct}% (${missing} beads without Linear ID)"
  else
    record "ok" "coverage_pct" "Coverage: ${coverage_pct}%"
  fi

  # List beads without external_ref (up to 10)
  if [[ -f "$EXTERNAL_REFS_FILE" ]] && [[ "$covered" -lt "$trackable_beads" ]]; then
    local ref_ids
    ref_ids="$(jq -r '.refs | keys[]' "$EXTERNAL_REFS_FILE" 2>/dev/null | sort)"
    local missing_ids
    missing_ids="$(jq -r 'select(.type != "wisp" and .type != "memory" and (.ephemeral // false) == false) | .id' "$ISSUES_JSONL" 2>/dev/null \
      | sort | comm -23 - <(echo "$ref_ids") | head -10)"

    if [[ -n "$missing_ids" ]]; then
      local count
      count="$(echo "$missing_ids" | wc -l | tr -d ' ')"
      if [[ "$OUTPUT_MODE" == "human" ]]; then
        printf '         Missing refs (showing up to 10):\n'
        echo "$missing_ids" | while IFS= read -r id; do
          printf '           %s\n' "$id"
        done
      fi
    fi
  fi
}

# ── check 3: API quota ────────────────────────────────────────────────────

check_api_quota() {
  [[ "$OUTPUT_MODE" == "human" ]] && printf '\n%s── API Quota ──%s\n' "$BOLD" "$RESET"

  # Check the most recent sync log for rate-limit info
  local sync_history_dir="${REPO_ROOT}/.beads/sync-history"
  if [[ ! -d "$sync_history_dir" ]]; then
    record "ok" "api_quota" "No sync history — quota check skipped"
    return
  fi

  local latest_log
  latest_log="$(ls -t "$sync_history_dir"/*.json 2>/dev/null | head -1)"

  if [[ -z "$latest_log" ]]; then
    record "ok" "api_quota" "No sync logs found — quota check skipped"
    return
  fi

  # Look for rate-limit fields in the log
  local quota_remaining quota_limit
  quota_remaining="$(jq -r '.rate_limit.remaining // .api_quota_remaining // empty' "$latest_log" 2>/dev/null)"
  quota_limit="$(jq -r '.rate_limit.limit // .api_quota_limit // empty' "$latest_log" 2>/dev/null)"

  if [[ -n "$quota_remaining" && -n "$quota_limit" && "$quota_limit" -gt 0 ]]; then
    local used_pct="$(( (quota_limit - quota_remaining) * 100 / quota_limit ))"
    if [[ "$used_pct" -ge 90 ]]; then
      record "critical" "api_quota" "Quota ${used_pct}% used (${quota_remaining}/${quota_limit} remaining)"
    elif [[ "$used_pct" -ge "$WARN_QUOTA_PCT" ]]; then
      record "warning" "api_quota" "Quota ${used_pct}% used (${quota_remaining}/${quota_limit} remaining)"
    else
      record "ok" "api_quota" "Quota ${used_pct}% used (${quota_remaining}/${quota_limit} remaining)"
    fi
  else
    record "ok" "api_quota" "No quota data in latest sync log"
  fi
}

# ── check 4: cron pull status ─────────────────────────────────────────────

check_cron_pull() {
  [[ "$OUTPUT_MODE" == "human" ]] && printf '\n%s── Cron Pull Status ──%s\n' "$BOLD" "$RESET"

  # Is the cron installed?
  local crontab_content
  crontab_content="$(crontab -l 2>/dev/null || true)"

  if echo "$crontab_content" | grep -qF "$CRON_MARKER"; then
    record "ok" "cron_installed" "Pull cron is installed"
  else
    record "warning" "cron_installed" "Pull cron is NOT installed (run install-pull-cron.sh)"
    return
  fi

  # Last sync log modification time
  if [[ -f "$SYNC_LOG_FILE" ]]; then
    local last_modified_epoch now_epoch age_minutes
    now_epoch="$(date +%s)"

    if stat --version &>/dev/null 2>&1; then
      last_modified_epoch="$(stat -c '%Y' "$SYNC_LOG_FILE" 2>/dev/null || echo 0)"
    else
      last_modified_epoch="$(stat -f '%m' "$SYNC_LOG_FILE" 2>/dev/null || echo 0)"
    fi

    if [[ "$last_modified_epoch" -gt 0 ]]; then
      age_minutes="$(( (now_epoch - last_modified_epoch) / 60 ))"

      if [[ "$age_minutes" -gt "$CRIT_CRON_AGE_MINUTES" ]]; then
        record "critical" "cron_age" "Last cron activity ${age_minutes}m ago (threshold: ${CRIT_CRON_AGE_MINUTES}m)"
      elif [[ "$age_minutes" -gt "$WARN_CRON_AGE_MINUTES" ]]; then
        record "warning" "cron_age" "Last cron activity ${age_minutes}m ago (threshold: ${WARN_CRON_AGE_MINUTES}m)"
      else
        record "ok" "cron_age" "Last cron activity ${age_minutes}m ago"
      fi
    fi

    # Check for errors in last 5 lines
    local recent_errors
    recent_errors="$(tail -20 "$SYNC_LOG_FILE" 2>/dev/null | grep -ciE 'error|fail|panic|fatal' || true)"
    if [[ "$recent_errors" -gt 0 ]]; then
      record "warning" "cron_errors" "Found ${recent_errors} error-like lines in recent cron log"
    else
      record "ok" "cron_errors" "No recent errors in cron log"
    fi
  else
    record "warning" "cron_log" "Cron log not found at ${SYNC_LOG_FILE} — no pulls have run yet"
  fi
}

# ── check 5: config drift ─────────────────────────────────────────────────

check_config_drift() {
  [[ "$OUTPUT_MODE" == "human" ]] && printf '\n%s── Config Drift ──%s\n' "$BOLD" "$RESET"

  if [[ ! -f "$TEMPLATE_CONFIG" ]]; then
    record "ok" "config_drift" "No org template found — drift check skipped"
    return
  fi

  local project_config="${REPO_ROOT}/.beads/config.yaml"
  if [[ ! -f "$project_config" ]]; then
    record "warning" "config_drift" "No .beads/config.yaml found"
    return
  fi

  # Use validate-config.sh if available (capture its exit code)
  local validate_exit=0
  local validate_output
  validate_output="$(bash "$SCRIPT_DIR/validate-config.sh" "$project_config" 2>&1)" || validate_exit=$?

  case "$validate_exit" in
    0) record "ok" "config_drift" "Config matches org template" ;;
    1) record "warning" "config_drift" "Config drift detected — run validate-config.sh for details" ;;
    2) record "critical" "config_drift" "Secrets found in config file!" ;;
    *) record "warning" "config_drift" "Config validation exited with code $validate_exit" ;;
  esac
}

# ── check 6: error-state beads ────────────────────────────────────────────

check_error_beads() {
  [[ "$OUTPUT_MODE" == "human" ]] && printf '\n%s── Error State Beads ──%s\n' "$BOLD" "$RESET"

  if ! command -v bd &>/dev/null; then
    record "ok" "error_beads" "bd not on PATH — error bead check skipped"
    return
  fi

  # Check for blocked beads
  local blocked_output
  blocked_output="$(bd blocked --json 2>/dev/null || echo "[]")"
  local blocked_count
  blocked_count="$(echo "$blocked_output" | jq 'length' 2>/dev/null || echo 0)"

  if [[ "$blocked_count" -gt 0 ]]; then
    record "warning" "blocked_beads" "${blocked_count} bead(s) in blocked state"
  else
    record "ok" "blocked_beads" "No blocked beads"
  fi

  # Check for stale in-progress beads (claimed but not updated recently)
  local in_progress
  in_progress="$(bd list --status=in_progress --json 2>/dev/null || echo "[]")"
  local in_progress_count
  in_progress_count="$(echo "$in_progress" | jq 'length' 2>/dev/null || echo 0)"

  if [[ "$in_progress_count" -gt 3 ]]; then
    record "warning" "stale_in_progress" "${in_progress_count} beads in_progress — possible orphans"
  else
    record "ok" "in_progress_beads" "${in_progress_count} bead(s) in progress"
  fi
}

# ── run all checks ────────────────────────────────────────────────────────

if [[ "$OUTPUT_MODE" == "human" ]]; then
  printf '%s%s═══ Sync Health Check ═══%s\n' "$BOLD" "$CYAN" "$RESET"
  printf 'Repo: %s\n' "$GH_REPO"
  printf 'Time: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
fi

check_ci_sync
check_coverage
check_api_quota
check_cron_pull
check_config_drift
check_error_beads

# ── output ─────────────────────────────────────────────────────────────────

EXIT_CODE=0
case "$OVERALL_STATUS" in
  healthy)  EXIT_CODE=0 ;;
  warning)  EXIT_CODE=1 ;;
  critical) EXIT_CODE=2 ;;
esac

if [[ "$OUTPUT_MODE" == "json" ]]; then
  printf '{'
  printf '"status":"%s",' "$OVERALL_STATUS"
  printf '"timestamp":"%s",' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '"repo":"%s",' "$GH_REPO"
  printf '"exit_code":%d,' "$EXIT_CODE"
  printf '"checks":['
  first=true
  for result in "${CHECK_RESULTS[@]}"; do
    if $first; then first=false; else printf ','; fi
    printf '%s' "$result"
  done
  printf ']}\n'

elif [[ "$OUTPUT_MODE" == "human" ]]; then
  printf '\n%s── Summary ──%s\n' "$BOLD" "$RESET"
  case "$OVERALL_STATUS" in
    healthy)  printf '  %s✔ HEALTHY%s — all checks passed\n' "$GREEN" "$RESET" ;;
    warning)  printf '  %s⚠ WARNING%s — degraded but functional\n' "$YELLOW" "$RESET" ;;
    critical) printf '  %s✖ CRITICAL%s — immediate attention required\n' "$RED" "$RESET" ;;
  esac

elif [[ "$OUTPUT_MODE" == "agent" ]]; then
  printf 'SUMMARY: %s (exit=%d)\n' "$OVERALL_STATUS" "$EXIT_CODE"
fi

exit $EXIT_CODE
