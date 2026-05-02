#!/usr/bin/env bash
set -euo pipefail

# Validate a project's .beads/config.yaml against the org template.
# Usage: validate-config.sh [path/to/config.yaml] [--fix]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="${SCRIPT_DIR}/../templates/.beads/config.yaml"

# --- colors (disabled when not a tty) ---
if [[ -t 1 ]]; then
  RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
  CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
else
  RED=''; YELLOW=''; GREEN=''; CYAN=''; BOLD=''; RESET=''
fi

# --- arg parsing ---
CONFIG_PATH=""
FIX_MODE=false

for arg in "$@"; do
  case "$arg" in
    --fix) FIX_MODE=true ;;
    --help|-h)
      echo "Usage: $(basename "$0") [path/to/config.yaml] [--fix]"
      echo ""
      echo "Compares a project's .beads/config.yaml against the org template."
      echo "  --fix   Overwrite non-secret sections with template values (prompts first)"
      echo ""
      echo "Exit codes: 0=PASS, 1=WARN (drift), 2=FAIL (secrets found)"
      exit 0
      ;;
    *) CONFIG_PATH="$arg" ;;
  esac
done

CONFIG_PATH="${CONFIG_PATH:-.beads/config.yaml}"

# --- preflight ---
if [[ ! -f "$TEMPLATE" ]]; then
  echo -e "${RED}ERROR:${RESET} Org template not found at ${TEMPLATE}"
  echo "  Make sure you're running from the beads-to-linear repo, or fix SCRIPT_DIR."
  exit 1
fi

if [[ ! -f "$CONFIG_PATH" ]]; then
  echo -e "${RED}ERROR:${RESET} Config file not found: ${CONFIG_PATH}"
  echo "  Pass a path or run from a directory with .beads/config.yaml"
  exit 1
fi

echo -e "${BOLD}Validating:${RESET} ${CONFIG_PATH}"
echo -e "${BOLD}Template:${RESET}  ${TEMPLATE}"
echo ""

# --- detect yq ---
USE_YQ=false
if command -v yq &>/dev/null; then
  # Verify it's Mike Farah's yq (Go version), not the Python one
  if yq --version 2>&1 | grep -q "mikefarah\|github.com/mikefarah"; then
    USE_YQ=true
  fi
fi

WARNINGS=0
FAILURES=0

# --- helper: extract a yaml value ---
# With yq: precise structured access. Without: grep-based best-effort.
yaml_get() {
  local file="$1" key="$2"
  if $USE_YQ; then
    yq eval "$key" "$file" 2>/dev/null || echo "__MISSING__"
  else
    grep_yaml_key "$file" "$key"
  fi
}

grep_yaml_key() {
  local file="$1" yq_path="$2"
  # Convert yq path like .linear.team_ids to a simple key search.
  # This is best-effort — handles flat scalars and simple nested keys.
  local leaf
  leaf="$(echo "$yq_path" | sed 's/.*\.//')"
  local val
  val="$(grep -E "^\s*${leaf}:" "$file" 2>/dev/null | head -1 | sed 's/^[^:]*:\s*//' | sed 's/\s*#.*//' | sed 's/^"\(.*\)"$/\1/' | sed "s/^'\(.*\)'$/\1/")"
  if [[ -z "$val" ]]; then
    echo "__MISSING__"
  else
    echo "$val"
  fi
}

# --- check: secrets ---
check_secrets() {
  echo -e "${BOLD}[1/3] Checking for secrets...${RESET}"
  local found_secrets=false

  # Check for api_key, token, secret values in the config
  local patterns=("api_key" "api_token" "secret" "password" "credential")
  for pattern in "${patterns[@]}"; do
    local matches
    matches="$(grep -inE "^\s*[^#]*${pattern}\s*:" "$CONFIG_PATH" 2>/dev/null || true)"
    if [[ -n "$matches" ]]; then
      while IFS= read -r line; do
        # Skip lines where the value is empty, null, or a comment-only reference
        local val
        val="$(echo "$line" | sed 's/^[^:]*:\s*//' | sed 's/\s*#.*//')"
        if [[ -n "$val" && "$val" != "null" && "$val" != '""' && "$val" != "''" ]]; then
          echo -e "  ${RED}FAIL${RESET} Secret value found: ${line}"
          found_secrets=true
          FAILURES=$((FAILURES + 1))
        fi
      done <<< "$matches"
    fi
  done

  # Also check for bare Linear API key patterns (lin_api_...)
  if grep -qE 'lin_api_[A-Za-z0-9]' "$CONFIG_PATH" 2>/dev/null; then
    echo -e "  ${RED}FAIL${RESET} Linear API key pattern (lin_api_...) found in config"
    found_secrets=true
    FAILURES=$((FAILURES + 1))
  fi

  if ! $found_secrets; then
    echo -e "  ${GREEN}PASS${RESET} No secrets detected"
  else
    echo -e "  ${RED}^^^ Secrets must be in env vars, not config files${RESET}"
  fi
  echo ""
}

# --- check: key value drift ---
check_drift() {
  echo -e "${BOLD}[2/3] Checking key values against template...${RESET}"

  local keys=(
    ".linear.team_ids"
    ".linear.id_mode"
    ".linear.hash_length"
    ".linear.rate_limit_floor"
  )

  for key in "${keys[@]}"; do
    local tmpl_val config_val
    tmpl_val="$(yaml_get "$TEMPLATE" "$key")"
    config_val="$(yaml_get "$CONFIG_PATH" "$key")"

    if [[ "$config_val" == "__MISSING__" ]]; then
      echo -e "  ${YELLOW}WARN${RESET} Missing key: ${CYAN}${key}${RESET} (template: ${tmpl_val})"
      WARNINGS=$((WARNINGS + 1))
    elif [[ "$tmpl_val" != "$config_val" ]]; then
      echo -e "  ${YELLOW}WARN${RESET} Drift on ${CYAN}${key}${RESET}: config=${config_val}, template=${tmpl_val}"
      WARNINGS=$((WARNINGS + 1))
    else
      echo -e "  ${GREEN}PASS${RESET} ${key} = ${config_val}"
    fi
  done
  echo ""
}

# --- check: map sections ---
check_maps() {
  echo -e "${BOLD}[3/3] Checking mapping sections...${RESET}"

  if ! $USE_YQ; then
    echo -e "  ${YELLOW}SKIP${RESET} Map comparison requires yq (mikefarah/yq). Install with:"
    echo "         brew install yq   # macOS"
    echo "         snap install yq   # Linux"
    echo ""
    return
  fi

  local maps=(".linear.priority_map" ".linear.state_map" ".linear.label_type_map")
  for map_key in "${maps[@]}"; do
    local tmpl_map config_map
    tmpl_map="$(yq eval "${map_key}" "$TEMPLATE" 2>/dev/null)"
    config_map="$(yq eval "${map_key}" "$CONFIG_PATH" 2>/dev/null)"

    if [[ "$config_map" == "null" ]]; then
      echo -e "  ${YELLOW}WARN${RESET} Missing section: ${CYAN}${map_key}${RESET}"
      WARNINGS=$((WARNINGS + 1))
    elif [[ "$tmpl_map" != "$config_map" ]]; then
      echo -e "  ${YELLOW}WARN${RESET} Drift in ${CYAN}${map_key}${RESET}:"
      # Show a compact diff
      diff --color=auto <(echo "$tmpl_map") <(echo "$config_map") | sed 's/^/         /' || true
      WARNINGS=$((WARNINGS + 1))
    else
      echo -e "  ${GREEN}PASS${RESET} ${map_key} matches template"
    fi
  done
  echo ""
}

# --- run checks ---
check_secrets
check_drift
check_maps

# --- summary ---
echo -e "${BOLD}─── Summary ───${RESET}"

EXIT_CODE=0

if [[ $FAILURES -gt 0 ]]; then
  echo -e "${RED}FAIL${RESET}: ${FAILURES} secret(s) found in config — remove them and use env vars"
  EXIT_CODE=2
elif [[ $WARNINGS -gt 0 ]]; then
  echo -e "${YELLOW}WARN${RESET}: ${WARNINGS} value(s) differ from org template"
  EXIT_CODE=1
else
  echo -e "${GREEN}PASS${RESET}: Config matches org template"
fi

# --- fix mode ---
if $FIX_MODE && [[ $FAILURES -gt 0 ]]; then
  echo ""
  echo -e "${RED}Cannot --fix while secrets are present.${RESET}"
  echo "Remove secrets from ${CONFIG_PATH} first, then re-run with --fix."
  exit 2
fi

if $FIX_MODE && [[ $WARNINGS -gt 0 ]]; then
  echo ""
  echo -e "${BOLD}--fix requested.${RESET} This will overwrite non-secret config sections"
  echo "in ${CONFIG_PATH} with values from the org template."
  echo ""
  read -r -p "Proceed? [y/N] " confirm
  if [[ "$confirm" =~ ^[Yy]$ ]]; then
    cp -f "$TEMPLATE" "$CONFIG_PATH"
    echo -e "${GREEN}Done.${RESET} Config replaced with template values."
    echo "Review the file and re-add any project-specific overrides."
    EXIT_CODE=0
  else
    echo "Aborted."
  fi
fi

exit $EXIT_CODE
