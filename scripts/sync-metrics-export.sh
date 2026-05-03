#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# sync-metrics-export.sh — export sync metrics in Prometheus exposition format.
#
# Outputs text/plain metrics suitable for consumption by Prometheus, Datadog
# agent, Grafana Agent, or any OpenMetrics-compatible scraper.
#
# Requires: gh, jq, git
# Optional: bd (for bead-level metrics)
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── configuration ──────────────────────────────────────────────────────────

ISSUES_JSONL="${REPO_ROOT}/.beads/issues.jsonl"
EXTERNAL_REFS_FILE="${REPO_ROOT}/.beads/external_refs.json"
SYNC_HISTORY_DIR="${REPO_ROOT}/.beads/sync-history"
CRON_MARKER="# beads-to-linear-sync"
SYNC_LOG_FILE="$HOME/.beads-sync.log"

GH_REPO=""
METRIC_PREFIX="btl_sync"

# ── colours ────────────────────────────────────────────────────────────────

RED=$'\033[0;31m' BOLD=$'\033[1m' RESET=$'\033[0m'
if [[ ! -t 2 ]]; then RED="" BOLD="" RESET=""; fi

# ── helpers ────────────────────────────────────────────────────────────────

die() { printf '%sERROR:%s %b\n' "$RED" "$RESET" "$1" >&2; exit 1; }

usage() {
  cat <<EOF
Usage: sync-metrics-export.sh [OPTIONS]

Export sync metrics in Prometheus exposition format (text/plain).

Options
  --repo OWNER/REPO   GitHub repo (default: auto-detect from git remote)
  --prefix PREFIX     Metric name prefix (default: btl_sync)
  --help              Show this help

Metrics exported
  ${METRIC_PREFIX}_success_total              Total successful CI sync runs
  ${METRIC_PREFIX}_failure_total              Total failed CI sync runs
  ${METRIC_PREFIX}_last_success_timestamp     Unix timestamp of last successful sync
  ${METRIC_PREFIX}_issues_pushed              Issues pushed in the most recent run
  ${METRIC_PREFIX}_issues_pulled              Issues pulled in the most recent run
  ${METRIC_PREFIX}_conflicts_total            Conflicts in the most recent run
  ${METRIC_PREFIX}_api_quota_remaining        API quota remaining after last sync
  ${METRIC_PREFIX}_external_ref_coverage_ratio  Fraction of trackable beads with Linear IDs

Examples
  # Print to stdout
  ./scripts/sync-metrics-export.sh

  # Pipe to a file for scraping
  ./scripts/sync-metrics-export.sh > /tmp/btl_metrics.prom

  # Use with a custom prefix
  ./scripts/sync-metrics-export.sh --prefix myorg_linear_sync
EOF
}

# ── arg parsing ────────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)    GH_REPO="$2";       shift 2 ;;
    --prefix)  METRIC_PREFIX="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) die "Unknown option: $1  (try --help)" ;;
  esac
done

# ── resolve repo ───────────────────────────────────────────────────────────

if [[ -z "$GH_REPO" ]]; then
  GH_REPO="$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null \
    | sed -E 's#.*github\.com[:/]##; s#\.git$##')" \
    || die "Cannot detect GitHub repo. Use --repo OWNER/REPO."
fi

# ── metric helpers ─────────────────────────────────────────────────────────

emit_help() {
  local name="$1" type="$2" help="$3"
  printf '# HELP %s %s\n' "$name" "$help"
  printf '# TYPE %s %s\n' "$name" "$type"
}

emit_metric() {
  local name="$1" value="$2"
  shift 2
  local labels=""
  if [[ $# -gt 0 ]]; then
    labels="{"
    local first=true
    while [[ $# -gt 0 ]]; do
      if $first; then first=false; else labels+=","; fi
      labels+="$1=\"$2\""
      shift 2
    done
    labels+="}"
  fi
  printf '%s%s %s\n' "$name" "$labels" "$value"
}

# ── collect CI run metrics ─────────────────────────────────────────────────

collect_ci_metrics() {
  local success_total=0 failure_total=0 last_success_ts=0

  if command -v gh &>/dev/null; then
    local runs_json
    runs_json="$(gh run list --workflow=linear-sync.yml --repo "$GH_REPO" \
      --limit 50 --json conclusion,createdAt 2>/dev/null || echo '[]')"

    success_total="$(echo "$runs_json" | jq '[.[] | select(.conclusion == "success")] | length')"
    failure_total="$(echo "$runs_json" | jq '[.[] | select(.conclusion == "failure")] | length')"

    local last_success_time
    last_success_time="$(echo "$runs_json" | jq -r '[.[] | select(.conclusion == "success")] | .[0].createdAt // "none"')"

    if [[ "$last_success_time" != "none" ]]; then
      last_success_ts="$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$last_success_time" +%s 2>/dev/null \
        || date -d "$last_success_time" +%s 2>/dev/null \
        || echo 0)"
    fi
  fi

  emit_help "${METRIC_PREFIX}_success_total" "counter" "Total successful CI sync runs"
  emit_metric "${METRIC_PREFIX}_success_total" "$success_total" "repo" "$GH_REPO"

  emit_help "${METRIC_PREFIX}_failure_total" "counter" "Total failed CI sync runs"
  emit_metric "${METRIC_PREFIX}_failure_total" "$failure_total" "repo" "$GH_REPO"

  emit_help "${METRIC_PREFIX}_last_success_timestamp" "gauge" "Unix timestamp of last successful sync"
  emit_metric "${METRIC_PREFIX}_last_success_timestamp" "$last_success_ts" "repo" "$GH_REPO"
}

# ── collect sync output metrics ────────────────────────────────────────────

collect_sync_metrics() {
  local issues_pushed=0 issues_pulled=0 conflicts=0
  local quota_remaining=-1

  if [[ -d "$SYNC_HISTORY_DIR" ]]; then
    local latest_log
    latest_log="$(ls -t "$SYNC_HISTORY_DIR"/*.json 2>/dev/null | head -1)"

    if [[ -n "$latest_log" ]]; then
      issues_pushed="$(jq '(.created // []) | length' "$latest_log" 2>/dev/null || echo 0)"
      local updated
      updated="$(jq '(.updated // []) | length' "$latest_log" 2>/dev/null || echo 0)"
      issues_pushed="$(( issues_pushed + updated ))"

      issues_pulled="$(jq '.pulled // 0' "$latest_log" 2>/dev/null || echo 0)"
      conflicts="$(jq '(.conflicts // []) | length' "$latest_log" 2>/dev/null || echo 0)"

      quota_remaining="$(jq '.rate_limit.remaining // .api_quota_remaining // -1' "$latest_log" 2>/dev/null || echo -1)"
    fi
  fi

  emit_help "${METRIC_PREFIX}_issues_pushed" "gauge" "Issues pushed in the most recent sync run"
  emit_metric "${METRIC_PREFIX}_issues_pushed" "$issues_pushed" "repo" "$GH_REPO"

  emit_help "${METRIC_PREFIX}_issues_pulled" "gauge" "Issues pulled in the most recent sync run"
  emit_metric "${METRIC_PREFIX}_issues_pulled" "$issues_pulled" "repo" "$GH_REPO"

  emit_help "${METRIC_PREFIX}_conflicts_total" "gauge" "Conflicts in the most recent sync run"
  emit_metric "${METRIC_PREFIX}_conflicts_total" "$conflicts" "repo" "$GH_REPO"

  emit_help "${METRIC_PREFIX}_api_quota_remaining" "gauge" "API quota remaining after last sync"
  emit_metric "${METRIC_PREFIX}_api_quota_remaining" "$quota_remaining" "repo" "$GH_REPO"
}

# ── collect coverage metrics ───────────────────────────────────────────────

collect_coverage_metrics() {
  local total_beads=0 trackable=0 covered=0 ratio=0

  if [[ -f "$ISSUES_JSONL" ]]; then
    total_beads="$(wc -l < "$ISSUES_JSONL" | tr -d ' ')"
    local wisps
    wisps="$(jq -r 'select(.type == "wisp" or .type == "memory" or .ephemeral == true) | .id' \
      "$ISSUES_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
    trackable="$(( total_beads - wisps ))"
  fi

  if [[ -f "$EXTERNAL_REFS_FILE" ]]; then
    covered="$(jq '.refs | length' "$EXTERNAL_REFS_FILE" 2>/dev/null || echo 0)"
  fi

  if [[ "$trackable" -gt 0 ]]; then
    # Output as a decimal ratio (0.0–1.0) for Prometheus convention
    ratio="$(awk "BEGIN { printf \"%.4f\", $covered / $trackable }")"
  elif [[ "$trackable" -eq 0 && "$total_beads" -eq 0 ]]; then
    ratio="1"  # vacuously covered
  fi

  emit_help "${METRIC_PREFIX}_external_ref_coverage_ratio" "gauge" \
    "Fraction of trackable beads with Linear IDs (0.0-1.0)"
  emit_metric "${METRIC_PREFIX}_external_ref_coverage_ratio" "$ratio" "repo" "$GH_REPO"
}

# ── output ─────────────────────────────────────────────────────────────────

collect_ci_metrics
echo ""
collect_sync_metrics
echo ""
collect_coverage_metrics
