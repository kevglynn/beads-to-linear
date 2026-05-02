#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# external-refs.sh — read/write helpers for .beads/external_refs.json
#
# The external_refs.json file is the CI worker's write surface. Dev laptops
# never write to it; they read it via git pull. This separation is the core
# safety mechanism that prevents the pre-commit hook from stripping external
# refs on every dev push. See PLAN.md §5 "External_ref storage separation".
#
# Requires: jq (available on GitHub Actions runners by default)
# ---------------------------------------------------------------------------

set -euo pipefail

# ── config ────────────────────────────────────────────────────────────────

EXTERNAL_REFS_FILE="${EXTERNAL_REFS_FILE:-.beads/external_refs.json}"

# ── preflight ─────────────────────────────────────────────────────────────

_require_jq() {
  command -v jq &>/dev/null \
    || { echo "ERROR: jq is required but not found on PATH" >&2; return 1; }
}

_ensure_file() {
  if [[ ! -f "$EXTERNAL_REFS_FILE" ]]; then
    init_external_refs
  fi
}

# ── public API ────────────────────────────────────────────────────────────

# Create an empty external_refs.json (idempotent — won't overwrite existing)
init_external_refs() {
  _require_jq
  if [[ -f "$EXTERNAL_REFS_FILE" ]]; then
    return 0
  fi
  mkdir -p "$(dirname "$EXTERNAL_REFS_FILE")"
  cat > "$EXTERNAL_REFS_FILE" <<'JSON'
{
  "version": 1,
  "updated_at": null,
  "refs": {}
}
JSON
}

# Read a single ref by bead_id. Outputs the ref object as JSON, or empty
# string if not found. Exit 0 either way (absence is not an error).
#   get_external_ref <bead_id>
get_external_ref() {
  _require_jq
  _ensure_file
  local bead_id="$1"
  jq -r --arg id "$bead_id" '.refs[$id] // empty' "$EXTERNAL_REFS_FILE"
}

# Set (upsert) a ref for a bead_id. Writes atomically via temp file.
#   set_external_ref <bead_id> <linear_id> <linear_url>
set_external_ref() {
  _require_jq
  _ensure_file
  local bead_id="$1" linear_id="$2" linear_url="$3"
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  local tmp
  tmp="$(mktemp "${EXTERNAL_REFS_FILE}.XXXXXX")"

  jq --arg id "$bead_id" \
     --arg lid "$linear_id" \
     --arg url "$linear_url" \
     --arg now "$now" \
     '.refs[$id] = {linear_id: $lid, linear_url: $url, synced_at: $now}
      | .updated_at = $now' \
     "$EXTERNAL_REFS_FILE" > "$tmp"

  mv -f "$tmp" "$EXTERNAL_REFS_FILE"
}

# List all bead_ids that have an external ref. One per line.
list_external_ref_ids() {
  _require_jq
  _ensure_file
  jq -r '.refs | keys[]' "$EXTERNAL_REFS_FILE"
}

# Return the count of refs in external_refs.json.
count_external_refs() {
  _require_jq
  _ensure_file
  jq '.refs | length' "$EXTERNAL_REFS_FILE"
}

# Find bead_ids present in external_refs.json but NOT in issues.jsonl.
# These are "disappeared" beads that should trigger the archive policy (d12).
#   find_disappeared_beads <path/to/issues.jsonl>
find_disappeared_beads() {
  _require_jq
  _ensure_file
  local jsonl_path="$1"

  if [[ ! -f "$jsonl_path" ]]; then
    # No JSONL means everything in refs has "disappeared"
    list_external_ref_ids
    return 0
  fi

  # Extract bead IDs from JSONL (each line is a JSON object with an "id" field)
  local jsonl_ids
  jsonl_ids="$(jq -r '.id' "$jsonl_path" | sort -u)"

  local ref_ids
  ref_ids="$(list_external_ref_ids | sort -u)"

  # comm -23: lines only in ref_ids (i.e., disappeared from JSONL)
  comm -23 <(echo "$ref_ids") <(echo "$jsonl_ids")
}

# Merge a set of new refs (as a JSON object keyed by bead_id) into
# external_refs.json. Used by the worker to batch-update after a push.
#   merge_external_refs <new_refs_json_file>
merge_external_refs() {
  _require_jq
  _ensure_file
  local new_refs_file="$1"
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  local tmp
  tmp="$(mktemp "${EXTERNAL_REFS_FILE}.XXXXXX")"

  jq --slurpfile new "$new_refs_file" \
     --arg now "$now" \
     '.refs = (.refs * $new[0]) | .updated_at = $now' \
     "$EXTERNAL_REFS_FILE" > "$tmp"

  mv -f "$tmp" "$EXTERNAL_REFS_FILE"
}

# Check whether external_refs.json has changed relative to git HEAD.
# Returns 0 (true) if changed, 1 (false) if unchanged.
external_refs_changed() {
  ! git diff --quiet HEAD -- "$EXTERNAL_REFS_FILE" 2>/dev/null
}

# ── self-test (when sourced with --self-test) ─────────────────────────────

if [[ "${1:-}" == "--self-test" ]]; then
  _require_jq
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' EXIT
  EXTERNAL_REFS_FILE="$tmpdir/external_refs.json"

  init_external_refs
  [[ -f "$EXTERNAL_REFS_FILE" ]] || { echo "FAIL: init did not create file" >&2; exit 1; }

  set_external_ref "btl-abc" "lin123" "https://linear.app/kevglynn/issue/KEV-1/test"
  set_external_ref "btl-def" "lin456" "https://linear.app/kevglynn/issue/KEV-2/test"

  result="$(get_external_ref "btl-abc")"
  echo "$result" | jq -e '.linear_id == "lin123"' >/dev/null \
    || { echo "FAIL: get_external_ref wrong" >&2; exit 1; }

  count="$(count_external_refs)"
  [[ "$count" -eq 2 ]] || { echo "FAIL: expected 2 refs, got $count" >&2; exit 1; }

  ids="$(list_external_ref_ids)"
  echo "$ids" | grep -q "btl-abc" || { echo "FAIL: btl-abc not listed" >&2; exit 1; }
  echo "$ids" | grep -q "btl-def" || { echo "FAIL: btl-def not listed" >&2; exit 1; }

  # Disappearance test: JSONL only has btl-abc → btl-def disappeared
  echo '{"id":"btl-abc","title":"test"}' > "$tmpdir/issues.jsonl"
  disappeared="$(find_disappeared_beads "$tmpdir/issues.jsonl")"
  echo "$disappeared" | grep -q "btl-def" \
    || { echo "FAIL: btl-def should be disappeared" >&2; exit 1; }
  echo "$disappeared" | grep -qv "btl-abc" \
    || { echo "FAIL: btl-abc should NOT be disappeared" >&2; exit 1; }

  echo "All self-tests passed."
fi
