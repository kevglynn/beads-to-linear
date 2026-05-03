#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# test-oauth-concurrency.sh — Spike btl-9fz
#
# Fires concurrent OAuth client_credentials token requests against Linear's
# token endpoint and validates:
#   1. Whether concurrent acquisition is safe (no mutual invalidation)
#   2. Whether multiple tokens from the same app are all valid
#   3. Whether rate-limit quota is shared across tokens
#
# Requires: LINEAR_OAUTH_CLIENT_ID, LINEAR_OAUTH_CLIENT_SECRET env vars
# Idempotent: creates test issues with distinctive titles, cleans up after.
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="$SCRIPT_DIR/.results"
CONCURRENCY="${BTL_SPIKE_CONCURRENCY:-5}"
LINEAR_TOKEN_URL="https://api.linear.app/oauth/token"
LINEAR_API_URL="https://api.linear.app/graphql"

# ── colours ────────────────────────────────────────────────────────────────

if [[ -t 1 ]]; then
  RED=$'\033[0;31m'  GREEN=$'\033[0;32m'  YELLOW=$'\033[0;33m'
  CYAN=$'\033[0;36m' BOLD=$'\033[1m'      RESET=$'\033[0m'
else
  RED=""  GREEN=""  YELLOW=""  CYAN=""  BOLD=""  RESET=""
fi

die()  { printf '%s%sERROR:%s %b\n' "$RED" "$BOLD" "$RESET" "$1" >&2; exit 1; }
info() { printf '%s%s▸%s %s\n'      "$CYAN" "$BOLD" "$RESET" "$1"; }
ok()   { printf '%s%s✔%s %s\n'      "$GREEN" "$BOLD" "$RESET" "$1"; }
warn() { printf '%s%sWARN:%s %s\n'  "$YELLOW" "$BOLD" "$RESET" "$1"; }

# ── preflight ──────────────────────────────────────────────────────────────

[[ -n "${LINEAR_OAUTH_CLIENT_ID:-}" ]]     || die "LINEAR_OAUTH_CLIENT_ID is not set"
[[ -n "${LINEAR_OAUTH_CLIENT_SECRET:-}" ]] || die "LINEAR_OAUTH_CLIENT_SECRET is not set"

command -v curl >/dev/null || die "curl is required"
command -v jq   >/dev/null || die "jq is required"

rm -rf "$RESULTS_DIR"
mkdir -p "$RESULTS_DIR"

# ── helpers ────────────────────────────────────────────────────────────────

fetch_token() {
  local idx="$1"
  local outfile="$RESULTS_DIR/token-$idx.json"

  curl -s -X POST "$LINEAR_TOKEN_URL" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=client_credentials&client_id=${LINEAR_OAUTH_CLIENT_ID}&client_secret=${LINEAR_OAUTH_CLIENT_SECRET}&scope=read,write" \
    -o "$outfile" \
    -w "%{http_code}" > "$RESULTS_DIR/token-$idx.status"
}

query_viewer() {
  local token="$1"
  local idx="$2"

  curl -s -X POST "$LINEAR_API_URL" \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    -d '{"query":"{ viewer { id name email } }"}' \
    -o "$RESULTS_DIR/viewer-$idx.json" \
    -w "%{http_code}" > "$RESULTS_DIR/viewer-$idx.status"
}

query_rate_limits() {
  local token="$1"
  local idx="$2"

  curl -s -D "$RESULTS_DIR/headers-$idx.txt" -X POST "$LINEAR_API_URL" \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    -d '{"query":"{ viewer { id } }"}' \
    -o "$RESULTS_DIR/ratelimit-$idx.json"
}

# ── Test 1: Concurrent token acquisition ──────────────────────────────────

info "Test 1: Firing $CONCURRENCY concurrent token requests..."

pids=()
for i in $(seq 1 "$CONCURRENCY"); do
  fetch_token "$i" &
  pids+=($!)
done

failed=0
for pid in "${pids[@]}"; do
  wait "$pid" || ((failed++))
done

if [[ $failed -gt 0 ]]; then
  die "Test 1: $failed of $CONCURRENCY token requests failed at the HTTP level"
fi

# Collect results
tokens=()
token_errors=0
for i in $(seq 1 "$CONCURRENCY"); do
  status=$(cat "$RESULTS_DIR/token-$i.status")
  if [[ "$status" != "200" ]]; then
    warn "Token $i: HTTP $status"
    cat "$RESULTS_DIR/token-$i.json" >&2
    ((token_errors++))
    continue
  fi

  token=$(jq -r '.access_token // empty' "$RESULTS_DIR/token-$i.json")
  if [[ -z "$token" ]]; then
    warn "Token $i: no access_token in response"
    jq . "$RESULTS_DIR/token-$i.json" >&2
    ((token_errors++))
    continue
  fi

  tokens+=("$token")
  expires_in=$(jq -r '.expires_in // "unknown"' "$RESULTS_DIR/token-$i.json")
  info "Token $i: acquired (expires_in=${expires_in}s, prefix=${token:0:8}...)"
done

if [[ $token_errors -gt 0 ]]; then
  die "Test 1: $token_errors token acquisitions failed"
fi

ok "Test 1: All $CONCURRENCY tokens acquired successfully"

# Compare tokens — are they identical or different?
unique_tokens=$(printf '%s\n' "${tokens[@]}" | sort -u | wc -l | tr -d ' ')
info "Unique tokens: $unique_tokens out of $CONCURRENCY"

if [[ "$unique_tokens" -eq 1 ]]; then
  ok "Test 1 finding: Linear returns the SAME token for concurrent requests (deduplication)"
else
  warn "Test 1 finding: Linear returns DIFFERENT tokens for concurrent requests ($unique_tokens unique)"
fi

# ── Test 2: Token reuse safety — do all tokens still work? ────────────────

info "Test 2: Validating all $CONCURRENCY tokens with viewer query..."

pids=()
for i in $(seq 0 $((${#tokens[@]} - 1))); do
  query_viewer "${tokens[$i]}" "$i" &
  pids+=($!)
done

for pid in "${pids[@]}"; do
  wait "$pid" || true
done

valid_tokens=0
invalid_tokens=0
for i in $(seq 0 $((${#tokens[@]} - 1))); do
  status=$(cat "$RESULTS_DIR/viewer-$i.status")
  if [[ "$status" == "200" ]]; then
    viewer_id=$(jq -r '.data.viewer.id // "unknown"' "$RESULTS_DIR/viewer-$i.json")
    viewer_name=$(jq -r '.data.viewer.name // "unknown"' "$RESULTS_DIR/viewer-$i.json")
    errors=$(jq -r '.errors // empty' "$RESULTS_DIR/viewer-$i.json")
    if [[ -n "$errors" && "$errors" != "null" ]]; then
      warn "Token $i: GraphQL errors: $errors"
      ((invalid_tokens++))
    else
      info "Token $i: valid (viewer=$viewer_name, id=$viewer_id)"
      ((valid_tokens++))
    fi
  else
    warn "Token $i: HTTP $status — token may have been invalidated"
    ((invalid_tokens++))
  fi
done

if [[ $invalid_tokens -eq 0 ]]; then
  ok "Test 2: All $CONCURRENCY tokens are valid — no mutual invalidation"
else
  warn "Test 2: $invalid_tokens of $CONCURRENCY tokens are invalid"
  if [[ $valid_tokens -gt 0 ]]; then
    warn "Test 2 finding: Later tokens MAY invalidate earlier ones"
  else
    die "Test 2: ALL tokens invalid — possible rate limiting or credential issue"
  fi
fi

# ── Test 3: Rate limit identity — shared or per-token? ────────────────────

info "Test 3: Checking rate-limit headers across tokens..."

# Use first and last token (if different) to compare rate-limit state
first_token="${tokens[0]}"
last_token="${tokens[$((${#tokens[@]} - 1))]}"

query_rate_limits "$first_token" "first"
sleep 1  # small gap to let counters update
query_rate_limits "$last_token" "last"

extract_header() {
  local file="$1" header="$2"
  grep -i "^${header}:" "$file" 2>/dev/null | sed 's/^[^:]*: *//' | tr -d '\r' || echo "not-present"
}

first_remaining=$(extract_header "$RESULTS_DIR/headers-first.txt" "x-ratelimit-requests-remaining")
last_remaining=$(extract_header "$RESULTS_DIR/headers-last.txt" "x-ratelimit-requests-remaining")
first_complexity=$(extract_header "$RESULTS_DIR/headers-first.txt" "x-ratelimit-complexity-remaining")
last_complexity=$(extract_header "$RESULTS_DIR/headers-last.txt" "x-ratelimit-complexity-remaining")

info "First token  — requests remaining: $first_remaining, complexity remaining: $first_complexity"
info "Last token   — requests remaining: $last_remaining, complexity remaining: $last_complexity"

if [[ "$first_remaining" == "$last_remaining" ]] && [[ "$unique_tokens" -gt 1 ]]; then
  warn "Test 3: Same rate-limit remaining despite different tokens — likely SHARED quota"
elif [[ "$first_remaining" != "$last_remaining" ]] && [[ "$unique_tokens" -gt 1 ]]; then
  remaining_diff=$((first_remaining - last_remaining))
  if [[ $remaining_diff -le 3 && $remaining_diff -ge -3 ]]; then
    info "Test 3: Rate-limit counters differ by $remaining_diff (likely shared, consumed by our queries)"
  else
    warn "Test 3: Rate-limit counters differ significantly — may be per-token quota"
  fi
fi

# ── Summary ───────────────────────────────────────────────────────────────

echo ""
echo "${BOLD}═══════════════════════════════════════════════════════════════${RESET}"
echo "${BOLD}  OAuth Concurrency Spike Results${RESET}"
echo "${BOLD}═══════════════════════════════════════════════════════════════${RESET}"
echo ""
echo "  Concurrent requests:    $CONCURRENCY"
echo "  Unique tokens returned: $unique_tokens"
echo "  Valid tokens (post-test): $valid_tokens / ${#tokens[@]}"
echo "  Rate-limit sharing:     $(
  if [[ "$unique_tokens" -eq 1 ]]; then
    echo "N/A (same token)"
  elif [[ "$first_remaining" == "$last_remaining" ]]; then
    echo "SHARED"
  else
    echo "see headers above"
  fi
)"
echo ""
echo "  Results saved to: $RESULTS_DIR/"
echo "${BOLD}═══════════════════════════════════════════════════════════════${RESET}"
