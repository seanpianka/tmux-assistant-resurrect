#!/usr/bin/env bash
# tmux-resurrect restore hook — re-launches assistants with their saved session IDs.
# Reads the sidecar JSON written by save-assistant-sessions.sh.
#
# Called automatically by tmux-resurrect after restore via:
#   set -g @resurrect-hook-post-restore-all '/path/to/restore-assistant-sessions.sh'

set -euo pipefail

# Source shared detection library (detect_tool, pane_has_assistant, posix_quote)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-detect.sh
source "$SCRIPT_DIR/lib-detect.sh"

# Follow tmux-resurrect's own save-dir resolution (resurrect_data_dir in
# lib-detect.sh) so we read the sidecar from wherever resurrect saved it.
RESURRECT_DIR="$(resurrect_data_dir)"
INPUT_FILE="${RESURRECT_DIR}/assistant-sessions.json"
LOG_FILE="${RESURRECT_DIR}/assistant-restore.log"

# Rotate log: keep only the most recent 500 lines
if [ -f "$LOG_FILE" ]; then
	tail -n 500 "$LOG_FILE" >"${LOG_FILE}.tmp" 2>/dev/null && mv "${LOG_FILE}.tmp" "$LOG_FILE" || true
fi

log() {
	local msg="[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"
	echo "$msg" >&2
	echo "$msg" >>"$LOG_FILE"
}

if [ ! -f "$INPUT_FILE" ]; then
	log "no saved sessions found at $INPUT_FILE"
	exit 0
fi

# Read saved sessions
sessions=$(jq -r '.sessions // []' "$INPUT_FILE")
count=$(echo "$sessions" | jq 'length')

if [ "$count" -eq 0 ]; then
	log "no assistant sessions to restore"
	exit 0
fi

# Wait for panes to be fully initialized after resurrect restore
sleep 2

log "restoring $count assistant session(s)..."

# Use a temp file to avoid subshell variable scoping issues with pipes.
# results_dir collects one marker file per successfully restored pane — the
# workers below run as background jobs, so a shared counter variable would be
# lost with each subshell.
tmpfile=$(mktemp)
results_dir=$(mktemp -d)
trap 'rm -rf "$tmpfile" "$results_dir"' EXIT INT TERM
echo "$sessions" | jq -c '.[]' >"$tmpfile"

# Read the env-capture allowlist once; it is the same for every pane.
capture_env=$(tmux show-option -gqv @assistant-resurrect-capture-env 2>/dev/null || true)

# Wait for at least one client to attach to each target session before
# replaying. TUI tools that query the terminal at startup (OSC 11
# background-color for theme detection, cursor-shape, hyperlinks, etc.)
# get a null response if no terminal is attached when the query fires
# — tmux silently drops the query because there's no client to forward
# it to. crossterm-based tools cache that null response in a OnceLock
# and never retry, so a single bad startup permanently locks the tool
# to its fallback state for the lifetime of the process. Symptom seen
# in the wild: codex's diff palette permanently dark on a light
# terminal after every reboot, requiring a manual `codex resume` to
# clear.
#
# Poll every 100ms, cap at 5s so we don't hang the restore if the user
# never attaches a client. In normal boot flows where a kitty/wezterm/etc
# auto-attaches via `tmux new-session -A`, the wait resolves in < 200ms.
# This runs ONCE over all target sessions rather than once per pane: a
# 45-pane restore into detached sessions used to pay the 5s cap 45 times
# (~4 minutes of pure waiting).
target_sessions=$(jq -r '.pane | split(":")[0]' <"$tmpfile" | sort -u)
unattached=""
client_wait=0
while [ $client_wait -lt 50 ]; do
	unattached=""
	for s in $target_sessions; do
		tmux has-session -t "$s" 2>/dev/null || continue
		if [ "$(tmux list-clients -t "$s" 2>/dev/null | wc -l)" -eq 0 ]; then
			unattached="$unattached $s"
		fi
	done
	[ -z "$unattached" ] && break
	sleep 0.1
	client_wait=$((client_wait + 1))
done
if [ -n "$unattached" ]; then
	log "no client attached to session(s):$unattached after 5s; replaying anyway (TUI startup queries may miss responses)"
fi

# Restore one sidecar entry into its pane. Runs as a background job under the
# bounded pool below, so it may only touch the log (O_APPEND, single-line
# writes stay atomic) and its own $results_dir/<idx> success marker.
restore_one() {
	local entry="$1" idx="$2"
	local pane tool session_id cwd cli_args model env_json
	pane=$(echo "$entry" | jq -r '.pane')
	tool=$(echo "$entry" | jq -r '.tool')
	session_id=$(echo "$entry" | jq -r '.session_id')
	cwd=$(echo "$entry" | jq -r '.cwd')
	cli_args=$(echo "$entry" | jq -r '.cli_args // empty')
	model=$(echo "$entry" | jq -r '.model // empty')
	env_json=$(echo "$entry" | jq -c '.env // {}')

	# Check if the target pane's session exists
	local tmux_session="${pane%%:*}"
	if ! tmux has-session -t "$tmux_session" 2>/dev/null; then
		log "session '$tmux_session' does not exist, skipping pane $pane"
		return 0
	fi

	# Check if the specific pane exists
	if ! tmux list-panes -t "$pane" >/dev/null 2>&1; then
		log "pane $pane does not exist, skipping"
		return 0
	fi

	# Guard 1: skip if the pane is not running a shell.
	# After tmux-resurrect restore, panes should be running a shell (bash, zsh,
	# etc.). If something else is running (e.g., the user manually started vim,
	# or @resurrect-processes restored a non-assistant program), injecting
	# send-keys would feed commands into the wrong program.
	local pane_cmd
	pane_cmd=$(tmux display-message -t "$pane" -p '#{pane_current_command}' 2>/dev/null || true)
	# Strip leading '-' from login shells (e.g., -bash -> bash, -zsh -> zsh)
	pane_cmd="${pane_cmd#-}"
	case "$pane_cmd" in
	bash | zsh | fish | sh | dash | ksh | tcsh | csh | nu) ;;
	*)
		log "pane $pane is running '$pane_cmd' (not a shell), skipping"
		return 0
		;;
	esac

	# Guard 2: skip if the pane already has a running assistant (e.g., if
	# @resurrect-processes launched it, or user restarted manually).
	# Uses the same full tree walk + detect_tool() as the save script to
	# catch exec-replaced shells, wrappers (npx, env, direnv), and deep
	# process chains.
	local pane_shell_pid existing
	pane_shell_pid=$(tmux display-message -t "$pane" -p '#{pane_pid}' 2>/dev/null || true)
	if [ -n "$pane_shell_pid" ]; then
		existing=$(pane_has_assistant "$pane_shell_pid" || true)
		if [ -n "$existing" ]; then
			log "pane $pane already has a running assistant (pid $existing), skipping"
			return 0
		fi
	fi

	# Build env prefix: only restore user-configured vars from
	# @assistant-resurrect-capture-env. Exclude built-in vars (tmux_pane, shell)
	# which would be stale or already present in the shell environment.
	local env_prefix="" var val
	if [ -n "$env_json" ] && [ "$env_json" != "null" ] && [ "$env_json" != "{}" ]; then
		for var in $capture_env; do
			# Validate var name to prevent shell injection via crafted tmux option
			if ! [[ "$var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
				log "skipping invalid env var name: $var"
				continue
			fi
			val=$(echo "$env_json" | jq -r --arg k "$var" '.[$k] // empty')
			if [ -n "$val" ]; then
				env_prefix="${env_prefix}${var}=$(posix_quote "$val") "
			fi
		done
	fi

	# Build the resume command for each tool.
	# Apply posix_quote to session_id defensively — IDs are alphanumeric in
	# practice, but a corrupt/tampered sidecar JSON could inject shell commands.
	local safe_sid
	safe_sid=$(posix_quote "$session_id")

	# Quote cli_args tokens and disable glob expansion while splitting, so
	# args like "claude-opus-4-6[1m]" are treated literally.
	local safe_cli_args="" _arg
	if [ -n "$cli_args" ]; then
		set -f
		for _arg in $cli_args; do
			safe_cli_args="${safe_cli_args} $(posix_quote "$_arg")"
		done
		set +f
	fi

	# Add --model from the sidecar model field if not already in cli_args.
	# Only for Claude — OpenCode and Codex don't support --model.
	local safe_model_arg=""
	if [ -n "$model" ] && [ "$tool" = "claude" ]; then
		case "$cli_args" in
		*--model*) ;;
		*) safe_model_arg=" --model $(posix_quote "$model")" ;;
		esac
	fi

	local resume_cmd=""
	local assistant_env="env -u NO_COLOR"
	case "$tool" in
	claude)
		if [ -n "$safe_cli_args" ] || [ -n "$safe_model_arg" ]; then
			resume_cmd="${assistant_env} claude${safe_cli_args}${safe_model_arg} --resume ${safe_sid}"
		else
			resume_cmd="${assistant_env} claude --resume ${safe_sid}"
		fi
		;;
	opencode)
		if [ -n "$safe_cli_args" ]; then
			resume_cmd="${assistant_env} opencode${safe_cli_args} -s ${safe_sid}"
		else
			resume_cmd="${assistant_env} opencode -s ${safe_sid}"
		fi
		;;
	codex)
		if [ -n "$safe_cli_args" ]; then
			resume_cmd="${assistant_env} codex${safe_cli_args} resume ${safe_sid}"
		else
			resume_cmd="${assistant_env} codex resume ${safe_sid}"
		fi
		;;
	pi)
		if [ -n "$safe_cli_args" ]; then
			resume_cmd="${assistant_env} pi${safe_cli_args} --session ${safe_sid}"
		else
			resume_cmd="${assistant_env} pi --session ${safe_sid}"
		fi
		;;
	omp)
		if [ -n "$safe_cli_args" ]; then
			resume_cmd="${assistant_env} omp${safe_cli_args} --resume ${safe_sid}"
		else
			resume_cmd="${assistant_env} omp --resume ${safe_sid}"
		fi
		;;
	grok)
		# Deliberately ignore cli_args for grok. Resuming reloads the
		# session's own model/agent/context from disk, and grok's prompt is a
		# positional argument — replaying captured args risks re-submitting a
		# stale prompt into the resumed session. A clean `grok --resume <id>`
		# is the correct restore. The generic cwd `cd` below still runs first,
		# which also lets grok locate the (cwd-scoped) session directory.
		resume_cmd="${assistant_env} grok --resume ${safe_sid}"
		;;
	*)
		log "unknown tool '$tool' for pane $pane, skipping"
		return 0
		;;
	esac

	# Prepend env vars if present
	if [ -n "$env_prefix" ]; then
		resume_cmd="${env_prefix}${resume_cmd}"
	fi

	log "restoring $tool in $pane (session: $session_id, cmd: $resume_cmd)"

	# Clear the pane before launching: tmux-resurrect may have restored old
	# pane contents (captured terminal text from the previous session). Without
	# clearing, TUI tools like Claude show stale output above the new instance.
	# Uses tmux clear-history to wipe scrollback, then sends 'clear' to reset
	# the visible area.
	tmux send-keys -t "$pane" "clear" Enter 2>/dev/null || {
		log "pane $pane vanished mid-restore, skipping"
		return 0
	}
	tmux clear-history -t "$pane" 2>/dev/null || true
	sleep 0.3

	# Build the full command: cd to cwd (if it exists) then resume.
	# Use POSIX single-quote escaping (safe for bash, zsh, sh, dash, fish).
	if [ -n "$cwd" ] && [ "$cwd" != "null" ]; then
		local safe_cwd
		safe_cwd=$(posix_quote "$cwd")
		tmux send-keys -t "$pane" "cd ${safe_cwd} 2>/dev/null; ${resume_cmd}" Enter 2>/dev/null || {
			log "pane $pane vanished mid-restore, skipping"
			return 0
		}
	else
		tmux send-keys -t "$pane" "${resume_cmd}" Enter 2>/dev/null || {
			log "pane $pane vanished mid-restore, skipping"
			return 0
		}
	fi

	: >"$results_dir/$idx"
}

# Fan the entries out to a bounded pool of background jobs. Every pane restore
# is independent (own guards, own send-keys target), so they can run
# concurrently; the cap keeps the burst of assistant cold-starts (each claude
# is a node process, each codex a rust TUI) from stampeding the box, and
# replaces the old per-pane 1s stagger. Override the width with
#   set -g @assistant-resurrect-restore-parallelism '4'
# (1 restores the old strictly-sequential behavior). macOS ships bash 3.2,
# which has no `wait -n`, so the pool waits FIFO — fine here, since jobs are
# near-uniform in duration. A job that dies mid-flight only loses its own
# pane: the pool and the final count are unaffected.
parallel=$(tmux show-option -gqv @assistant-resurrect-restore-parallelism 2>/dev/null || true)
case "$parallel" in '' | *[!0-9]*) parallel=8 ;; esac
[ "$parallel" -lt 1 ] && parallel=1

pids=()
idx=0
while read -r entry; do
	idx=$((idx + 1))
	restore_one "$entry" "$idx" &
	pids+=("$!")
	if [ "${#pids[@]}" -ge "$parallel" ]; then
		wait "${pids[0]}" 2>/dev/null || true
		if [ "${#pids[@]}" -gt 1 ]; then
			pids=("${pids[@]:1}")
		else
			pids=()
		fi
	fi
done <"$tmpfile"
if [ "${#pids[@]}" -gt 0 ]; then
	for p in "${pids[@]}"; do
		wait "$p" 2>/dev/null || true
	done
fi

restored=$(find "$results_dir" -type f | wc -l | tr -d ' ')
log "restored $restored of $count assistant session(s)"
