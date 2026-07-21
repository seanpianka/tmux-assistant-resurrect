#!/usr/bin/env bash
# Claude Code SessionEnd hook — removes the session tracking state file.
# Receives JSON on stdin with session_id, cwd, etc.
#
# Install: add to ~/.claude/settings.json under hooks.SessionEnd

set -euo pipefail

# Source shared find_claude_pid() helper
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-claude-pid.sh
source "$HOOK_DIR/lib-claude-pid.sh"

STATE_DIR="${TMUX_ASSISTANT_RESURRECT_DIR:-${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/tmux-assistant-resurrect}"
INPUT=$(cat)

if [ -n "${TMUX_PANE:-}" ] && command -v agentmux >/dev/null 2>&1; then
	printf '%s' "$INPUT" | agentmux chat-event claude end >/dev/null 2>&1 || true
fi

CLAUDE_PID=$(find_claude_pid)
rm -f "$STATE_DIR/claude-$CLAUDE_PID.json" 2>/dev/null || true
