#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# install-pull-cron.sh — install / uninstall / status the beads-to-linear
# per-laptop pull cron.  See PLAN.md §1a "For developers".
# ---------------------------------------------------------------------------

readonly CRON_MARKER="# beads-to-linear-sync"
readonly LOG_FILE="$HOME/.beads-sync.log"

# ── colours (disabled when stdout is not a terminal) ─────────────────────
if [[ -t 1 ]]; then
  RED=$'\033[0;31m'  GREEN=$'\033[0;32m'  YELLOW=$'\033[0;33m'
  BOLD=$'\033[1m'    RESET=$'\033[0m'
else
  RED=""  GREEN=""  YELLOW=""  BOLD=""  RESET=""
fi

# ── helpers ──────────────────────────────────────────────────────────────
die()  { printf '%s%sERROR:%s %b\n' "$RED" "$BOLD" "$RESET" "$1" >&2; exit 1; }
warn() { printf '%s%sWARN:%s %s\n'  "$YELLOW" "$BOLD" "$RESET" "$1" >&2; }
ok()   { printf '%s%s✔%s %s\n'      "$GREEN" "$BOLD" "$RESET" "$1"; }
info() { printf '%s\n' "$1"; }

usage() {
  cat <<EOF
${BOLD}Usage:${RESET} install-pull-cron.sh [OPTIONS]

Install (or manage) the per-developer cron that runs
  bd linear sync --pull --prefer-linear
every 15 minutes with jitter.

${BOLD}Modes${RESET}
  (default)       Install the cron job
  --uninstall     Remove the cron job
  --status        Show whether the cron is installed + last sync info

${BOLD}Options${RESET}
  --repo PATH     Repository root (default: git rev-parse --show-toplevel)
  --force         Reinstall even if already present
  --help          Show this help

${BOLD}Environment${RESET}
  LINEAR_API_KEY  Required for install. Personal read-only Linear API key.

${BOLD}Examples${RESET}
  # Install from inside the repo
  ./scripts/install-pull-cron.sh

  # Install for a specific repo path
  ./scripts/install-pull-cron.sh --repo /path/to/my-project

  # Check current status
  ./scripts/install-pull-cron.sh --status

  # Remove the cron entry
  ./scripts/install-pull-cron.sh --uninstall
EOF
}

# ── arg parsing ──────────────────────────────────────────────────────────
MODE="install"
REPO_PATH=""
FORCE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --uninstall) MODE="uninstall"; shift ;;
    --status)    MODE="status";    shift ;;
    --repo)      REPO_PATH="$2";   shift 2 ;;
    --force)     FORCE=true;       shift ;;
    --help|-h)   usage; exit 0 ;;
    *) die "Unknown option: $1  (try --help)" ;;
  esac
done

# ── resolve repo path ───────────────────────────────────────────────────
resolve_repo() {
  if [[ -n "$REPO_PATH" ]]; then
    REPO_PATH="$(cd "$REPO_PATH" && pwd)"
  elif git rev-parse --show-toplevel &>/dev/null; then
    REPO_PATH="$(git rev-parse --show-toplevel)"
  else
    die "Not inside a git repo and --repo not specified."
  fi
}

# ── cron helpers ─────────────────────────────────────────────────────────
current_crontab() {
  crontab -l 2>/dev/null || true
}

cron_is_installed() {
  current_crontab | grep -qF "$CRON_MARKER"
}

# ── install ──────────────────────────────────────────────────────────────
do_install() {
  resolve_repo

  # 1. Validate .beads/ directory
  [[ -d "$REPO_PATH/.beads" ]] \
    || die "No .beads/ directory in $REPO_PATH — is this a beads-enabled repo?"

  # 2. Validate bd is on PATH
  command -v bd &>/dev/null \
    || die "bd is not on PATH. Install beads first: https://github.com/gastownhall/beads"

  # 3. Validate LINEAR_API_KEY
  [[ -n "${LINEAR_API_KEY:-}" ]] \
    || die "LINEAR_API_KEY is not set.\n\n  Generate one at: https://linear.app/settings/api\n  Then:  export LINEAR_API_KEY=lin_api_...\n  And re-run this script."

  # 4. Refuse if linear.api_key is in .beads/config.yaml (credential-leak guard)
  local config_file="$REPO_PATH/.beads/config.yaml"
  if [[ -f "$config_file" ]]; then
    if grep -qE '^\s*api_key\s*:' "$config_file" 2>/dev/null; then
      die "Found api_key in $config_file.\n  This file is git-tracked — storing secrets here risks credential leaks.\n  Remove it:  bd config unset linear.api_key\n  Then use LINEAR_API_KEY env var instead."
    fi
  fi

  # 5. Idempotency check
  if cron_is_installed; then
    if [[ "$FORCE" == true ]]; then
      warn "Cron already installed — removing before reinstall (--force)."
      do_uninstall_quiet
    else
      die "Cron already installed. Use --force to reinstall, or --status to inspect."
    fi
  fi

  # 6. Build and install the cron entry
  local bd_path
  bd_path="$(command -v bd)"

  # Source ~/.secrets at runtime instead of embedding the key in the crontab
  local secrets_source=""
  if [[ -f "$HOME/.secrets" ]]; then
    secrets_source="source ${HOME}/.secrets && "
  elif [[ -f "$HOME/.zshrc" ]]; then
    secrets_source="source ${HOME}/.zshrc && "
  fi

  local cron_line
  cron_line="*/15 * * * * sleep \$((RANDOM \\% 180)) && ${secrets_source}cd ${REPO_PATH} && ${bd_path} linear sync --pull --prefer-linear >> ${LOG_FILE} 2>&1 ${CRON_MARKER}"

  ( current_crontab; printf '%s\n' "$cron_line" ) | crontab -

  ok "Cron installed successfully."
  info ""
  info "  Schedule:  every 15 min + 0-180s jitter"
  info "  Repo:      $REPO_PATH"
  info "  Log file:  $LOG_FILE"
  info "  API key:   ${LINEAR_API_KEY:0:10}…  (from env)"
  info ""

  # Next expected run: the next quarter-hour mark
  local now mins_past next_min
  now=$(date +%s)
  mins_past=$(( (now / 60) % 15 ))
  next_min=$(( 15 - mins_past ))
  local next_run
  next_run=$(date -d "+${next_min} minutes" 2>/dev/null || date -v+"${next_min}"M 2>/dev/null || echo "~${next_min} minutes from now")
  info "  Next cron trigger: ${BOLD}${next_run}${RESET}  (+ up to 3 min jitter)"
}

# ── uninstall ────────────────────────────────────────────────────────────
do_uninstall_quiet() {
  current_crontab | grep -vF "$CRON_MARKER" | crontab -
}

do_uninstall() {
  if ! cron_is_installed; then
    warn "No beads-to-linear cron found — nothing to remove."
    return 0
  fi
  do_uninstall_quiet
  ok "Cron entry removed."
}

# ── status ───────────────────────────────────────────────────────────────
do_status() {
  info "${BOLD}beads-to-linear pull cron status${RESET}"
  info ""

  # Cron installed?
  if cron_is_installed; then
    ok "Cron is installed"
    info "  Entry: $(current_crontab | grep -F "$CRON_MARKER")"
  else
    warn "Cron is NOT installed"
  fi
  info ""

  # Last sync from log
  if [[ -f "$LOG_FILE" ]]; then
    local last_modified
    if stat --version &>/dev/null 2>&1; then
      last_modified=$(stat -c '%y' "$LOG_FILE" 2>/dev/null)
    else
      last_modified=$(stat -f '%Sm' "$LOG_FILE" 2>/dev/null)
    fi
    info "  Log file:       $LOG_FILE"
    info "  Last modified:  ${last_modified:-unknown}"
    local line_count
    line_count=$(wc -l < "$LOG_FILE" | tr -d ' ')
    info "  Log lines:      $line_count"

    info ""
    info "  Last 5 log lines:"
    tail -5 "$LOG_FILE" | while IFS= read -r line; do
      info "    $line"
    done
  else
    info "  Log file:  $LOG_FILE  (not yet created — no syncs have run)"
  fi
  info ""

  # LINEAR_API_KEY presence
  if [[ -n "${LINEAR_API_KEY:-}" ]]; then
    ok "LINEAR_API_KEY is set in environment  (${LINEAR_API_KEY:0:10}…)"
  else
    warn "LINEAR_API_KEY is NOT set in current shell"
  fi
}

# ── dispatch ─────────────────────────────────────────────────────────────
case "$MODE" in
  install)   do_install   ;;
  uninstall) do_uninstall ;;
  status)    do_status    ;;
esac
