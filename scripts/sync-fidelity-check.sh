#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# sync-fidelity-check.sh — Measures sync accuracy between beads and Linear.
#
# Reports: title/status/priority fidelity, timestamp drift, cron health,
# coverage gaps, and data integrity issues.
#
# Requires: bd, jq, python3, LINEAR_API_KEY
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

BD="${BD_BIN:-bd}"
if [[ -x /tmp/bd-dev ]]; then
  BD=/tmp/bd-dev
fi

[[ -f ~/.secrets ]] && source ~/.secrets 2>/dev/null

if [[ -z "${LINEAR_API_KEY:-}" ]]; then
  echo "ERROR: LINEAR_API_KEY not set" >&2
  exit 1
fi

TEAM_ID="$($BD config get linear.team_ids 2>/dev/null | sed 's/^[^=]*= *//' || echo "")"
if [[ -z "$TEAM_ID" ]]; then
  echo "ERROR: linear.team_ids not configured" >&2
  exit 1
fi

ISSUES_JSONL="$REPO_ROOT/.beads/issues.jsonl"
SYNC_LOG="${HOME}/.beads-sync.log"
EXTERNAL_REFS="$REPO_ROOT/.beads/external_refs.json"

TMPDIR_FIDELITY="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_FIDELITY"' EXIT

# Fetch Linear data
curl -s https://api.linear.app/graphql \
  -H "Authorization: $LINEAR_API_KEY" \
  -H "Content-Type: application/json" \
  -d "{\"query\":\"{ team(id: \\\"${TEAM_ID}\\\") { issues(first: 100) { nodes { id identifier title state { name type } priority updatedAt } } } }\"}" \
  > "$TMPDIR_FIDELITY/linear.json"

python3 "$SCRIPT_DIR/sync-fidelity-check.py" \
  --linear "$TMPDIR_FIDELITY/linear.json" \
  --jsonl "$ISSUES_JSONL" \
  --sync-log "$SYNC_LOG" \
  --external-refs "$EXTERNAL_REFS"
