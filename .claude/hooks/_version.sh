#!/bin/bash
#
# _version.sh — single source of truth for beads-compound plugin version
#
# Sourced by auto-recall.sh (via $SCRIPT_DIR) and provision-memory.sh
# (via $HOOKS_SOURCE_DIR). Distributed alongside the other hooks by
# scripts/playbook-init.sh (which copies *.sh from .claude/hooks/).
#
# To bump the version, edit only this file. Both consumers will pick up
# the change on the next hook invocation.
#

BEADS_COMPOUND_VERSION="0.6.7"
