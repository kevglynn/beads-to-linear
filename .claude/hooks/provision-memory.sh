#!/bin/bash
#
# Shared memory provisioning for beads-compound
#
# Provides a single function to set up .beads/memory/ with knowledge tracking.
# Used by auto-recall.sh (native plugin), check-memory.sh (global install),
# and install.sh (manual install) to avoid duplicating setup logic.
#
# Usage:
#   source provision-memory.sh
#   provision_memory_dir "/path/to/project" "/path/to/hooks/dir"
#

provision_memory_dir() {
  local PROJECT_DIR="$1"
  local HOOKS_SOURCE_DIR="$2"

  local MEMORY_DIR="$PROJECT_DIR/.beads/memory"

  mkdir -p "$MEMORY_DIR"

  # Create empty knowledge file if missing
  if [[ ! -f "$MEMORY_DIR/knowledge.jsonl" ]]; then
    touch "$MEMORY_DIR/knowledge.jsonl"
  fi

  # Copy recall.sh if available
  if [[ -f "$HOOKS_SOURCE_DIR/recall.sh" ]]; then
    cp "$HOOKS_SOURCE_DIR/recall.sh" "$MEMORY_DIR/recall.sh"
    chmod +x "$MEMORY_DIR/recall.sh"
  fi

  # Copy knowledge-db.sh if available
  if [[ -f "$HOOKS_SOURCE_DIR/knowledge-db.sh" ]]; then
    cp "$HOOKS_SOURCE_DIR/knowledge-db.sh" "$MEMORY_DIR/knowledge-db.sh"
    chmod +x "$MEMORY_DIR/knowledge-db.sh"
  fi

  # Setup .gitattributes for union merge (per-directory, scoped to .beads/memory/)
  # Atomic write: stage to mktemp, then mv. A SIGKILL/OOM mid-write would
  # otherwise leave .gitattributes half-written, and the next run's
  # `grep -q 'knowledge.jsonl'` idempotency check would falsely report
  # "already provisioned" without repairing the partial file. Same pattern
  # as install-aliases.sh and playbook-init.sh (introduced in v1.1.0).
  local GITATTR="$MEMORY_DIR/.gitattributes"

  if [[ ! -f "$GITATTR" ]] || ! grep -q 'knowledge.jsonl' "$GITATTR" 2>/dev/null; then
    local GITATTR_TMP
    GITATTR_TMP="$(mktemp "${GITATTR}.tmp.XXXXXX")"
    {
      [[ -f "$GITATTR" ]] && cat "$GITATTR"
      echo "knowledge.jsonl merge=union"
      echo "knowledge.archive.jsonl merge=union"
    } > "$GITATTR_TMP"
    mv "$GITATTR_TMP" "$GITATTR"
  fi

  # Write installed version for staleness detection by auto-recall.sh.
  # Source single-source-of-truth from _version.sh distributed alongside
  # the hooks; falls back to "unknown" if the file is missing (in which
  # case auto-recall.sh will treat any project version as a mismatch and
  # emit the update prompt — safe-fail behavior).
  # shellcheck source=_version.sh
  if [[ -f "$HOOKS_SOURCE_DIR/_version.sh" ]]; then
    source "$HOOKS_SOURCE_DIR/_version.sh"
  else
    BEADS_COMPOUND_VERSION="unknown"
  fi
  # Atomic write: same rationale as the .gitattributes block above. A
  # half-written .beads-compound-version (0 bytes after a SIGKILL between
  # truncate and write) reads as empty, which auto-recall.sh interprets as
  # a stale install and emits a spurious update prompt every session.
  local VERSION_FILE="$MEMORY_DIR/.beads-compound-version"
  local VERSION_TMP
  VERSION_TMP="$(mktemp "${VERSION_FILE}.tmp.XXXXXX")"
  echo "$BEADS_COMPOUND_VERSION" > "$VERSION_TMP"
  mv "$VERSION_TMP" "$VERSION_FILE"

  # Create .beads/memory/.gitignore to ignore the SQLite FTS cache
  # (rebuilt from knowledge.jsonl on first use — no need to commit it)
  # Atomic write: a half-written heredoc passes the existence check on
  # the next run, so the partial .gitignore would persist indefinitely
  # and the SQLite cache could end up committed.
  local MEMORY_GITIGNORE="$MEMORY_DIR/.gitignore"
  if [[ ! -f "$MEMORY_GITIGNORE" ]]; then
    local GITIGNORE_TMP
    GITIGNORE_TMP="$(mktemp "${MEMORY_GITIGNORE}.tmp.XXXXXX")"
    cat > "$GITIGNORE_TMP" << 'EOF'
# SQLite FTS cache (rebuilt from knowledge.jsonl on first use)
knowledge.db
knowledge.db-journal
knowledge.db-wal
knowledge.db-shm
EOF
    mv "$GITIGNORE_TMP" "$MEMORY_GITIGNORE"
  fi

  # Check if project .gitignore contains a .beads/ pattern, which would cause
  # all beads issue/comment data to be untracked (data loss risk on new clones).
  # bd init no longer adds .beads/ to project .gitignore — if it's there, it's
  # from an older version of beads-compound or a manual addition.
  if git -C "$PROJECT_DIR" rev-parse --git-dir &>/dev/null 2>&1; then
    local GITIGNORE="$PROJECT_DIR/.gitignore"
    if [[ -f "$GITIGNORE" ]] && grep -qE '^\s*\.beads/?(\s|$)' "$GITIGNORE" 2>/dev/null \
      && ! grep -qE '^\s*!\.beads/' "$GITIGNORE" 2>/dev/null; then
      echo ""
      echo "[!] Warning: .beads/ is listed in your project .gitignore."
      echo "    This means your beads issues, comments, and knowledge are not"
      echo "    tracked by git. If you lose your local copy, all of this data"
      echo "    will be permanently lost."
      echo ""
      echo "    Modern beads (bd init) no longer adds .beads/ to .gitignore."
      echo "    If you want .beads/ to be invisible to git, use: bd init --stealth"
      echo "    (which uses .git/info/exclude instead, keeping data safe)."
      echo ""
      if [[ "${BEADS_AUTO_YES:-false}" == "true" ]] || ! [[ -t 0 ]]; then
        # Non-interactive mode (hook context or --yes flag): warn but don't modify
        echo "    [non-interactive] Leaving .gitignore unchanged. Re-run install to fix interactively."
      else
        read -r -p "    Remove .beads/ from .gitignore? [Y/n] " response
        case "${response:-Y}" in
          [nN]|[nN][oO])
            echo "    Left unchanged. Your beads data may not be committed to git."
            ;;
          *)
            # Remove lines matching .beads/ (with optional trailing slash and whitespace)
            local TMPFILE
            TMPFILE=$(mktemp)
            grep -vE '^\s*\.beads/?(\s|$)' "$GITIGNORE" > "$TMPFILE"
            mv "$TMPFILE" "$GITIGNORE"
            echo "    Removed .beads/ from .gitignore."
            echo "    Run: git add .beads/ && git commit -m 'track beads data'"
            ;;
        esac
      fi
      echo ""
    fi
  fi

  # Stage specific known files only (use -f to override parent .gitignore
  # in case negation rules haven't been picked up yet by this git session)
  if git -C "$PROJECT_DIR" rev-parse --git-dir &>/dev/null 2>&1; then
    (cd "$PROJECT_DIR" && git add -f \
      .beads/memory/knowledge.jsonl \
      .beads/memory/.gitattributes \
      .beads/memory/.gitignore \
      .beads/memory/.beads-compound-version \
      .beads/memory/recall.sh \
      .beads/memory/knowledge-db.sh \
      2>/dev/null) || true
  fi
}
