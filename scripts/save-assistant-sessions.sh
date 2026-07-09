#!/usr/bin/env bash
# The tmux server may have been started with a limited PATH (e.g. via a
# systemd user service with a whitelisted runtime environment). That PATH
# is inherited by every hook this script runs in, so utilities like
# python3 — needed by Python-based session lookup methods (Codex + pi) —
# can be missing even though they are installed and work fine from an
# interactive shell. Augment PATH with common system locations so the
# hook context sees what the rest of the system sees.
if ! command -v python3 >/dev/null 2>&1; then
	for _dir in /run/current-system/sw/bin /opt/homebrew/bin /usr/local/bin /usr/bin; do
		if [ -x "$_dir/python3" ]; then
			PATH="$_dir:$PATH"
			break
		fi
	done
	unset _dir
fi

# tmux-resurrect save hook — collects assistant session IDs from all tmux panes.
# Writes a sidecar JSON file alongside resurrect's save files.
#
# Detection: inspects child processes of each tmux pane shell via ps.
# Session IDs: extracted from process args, hook state files, or tool-native files.
#
# Called automatically by tmux-resurrect after each save via:
#   set -g @resurrect-hook-post-save-all '/path/to/save-assistant-sessions.sh'

set -euo pipefail

# Source shared detection library (detect_tool, pane_has_assistant, posix_quote)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-detect.sh
source "$SCRIPT_DIR/lib-detect.sh"

STATE_DIR="${TMUX_ASSISTANT_RESURRECT_DIR:-${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/tmux-assistant-resurrect}"
# Follow tmux-resurrect's own save-dir resolution (see resurrect_data_dir in
# lib-detect.sh) instead of hardcoding ~/.tmux/resurrect, so our sidecar lands
# next to resurrect's saves on both legacy and XDG installs.
RESURRECT_DIR="$(resurrect_data_dir)"
OUTPUT_FILE="${RESURRECT_DIR}/assistant-sessions.json"
LOG_FILE="${RESURRECT_DIR}/assistant-save.log"

mkdir -p -m 0700 "$STATE_DIR"
mkdir -p "$RESURRECT_DIR"

# Rotate log: keep only the most recent 500 lines to prevent unbounded growth
# (continuum saves every 5 minutes, so this grows ~12 lines/hour).
if [ -f "$LOG_FILE" ]; then
	tail -n 500 "$LOG_FILE" >"${LOG_FILE}.tmp" 2>/dev/null && mv "${LOG_FILE}.tmp" "$LOG_FILE" || true
fi

log() {
	local msg="[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"
	echo "$msg" >&2
	echo "$msg" >>"$LOG_FILE"
}

USED_CODEX_SESSION_IDS=""
USED_PI_SESSION_IDS=""
USED_OMP_SESSION_IDS=""

# --- Session ID extraction ---

get_claude_session() {
	local claude_pid="$1"
	local args="$2"

	# Method 1: SessionStart hook state file (keyed by Claude PID).
	# The hook walks up the process tree to find the main 'claude' process,
	# so the state file is named claude-{claude_pid}.json.
	local state_file="$STATE_DIR/claude-${claude_pid}.json"
	if [ -f "$state_file" ]; then
		local sid
		sid=$(jq -r '.session_id // empty' "$state_file" 2>/dev/null || true)
		if [ -n "$sid" ]; then
			echo "$sid"
			return
		fi
	fi

	# Method 2: --resume flag in process args (chicken-and-egg fallback)
	# After restore, claude is launched as `claude --resume <session_id>`.
	# Supports both `--resume <id>` and `--resume=<id>` forms.
	# If the SessionStart hook hasn't fired yet, the ID is still in the args.
	local sid
	sid=$(echo "$args" | sed -n "s/.*--resume[= ] *\([A-Za-z0-9_-]*\).*/\1/p")
	if [ -n "$sid" ]; then
		echo "$sid"
		return
	fi
}

get_opencode_session() {
	local child_pid="$1"
	local args="$2"
	local cwd="${3:-}"
	local allow_db_fallback="${4:-1}"

	# Method 1: -s flag in process args (fastest)
	local sid
	sid=$(echo "$args" | sed -n 's/.*-s \(ses_[A-Za-z0-9_]*\).*/\1/p')
	if [ -n "$sid" ]; then
		echo "$sid"
		return
	fi

	# Method 2: --session flag in process args (supports --session=<id> too)
	sid=$(echo "$args" | sed -n 's/.*--session[= ] *\(ses_[A-Za-z0-9_]*\).*/\1/p')
	if [ -n "$sid" ]; then
		echo "$sid"
		return
	fi

	# Method 3: plugin state file (handles runtime session switches)
	local state_file="$STATE_DIR/opencode-${child_pid}.json"
	if [ -f "$state_file" ]; then
		sid=$(jq -r '.session_id // empty' "$state_file" 2>/dev/null || true)
		if [ -n "$sid" ]; then
			echo "$sid"
			return
		fi
	fi

	# Method 4: SQLite database (version-resilient fallback).
	# OpenCode stores sessions in ~/.local/share/opencode/opencode.db.
	# Query the most recently updated session matching the pane's cwd.
	# Uses python3 (available on Linux and macOS) since sqlite3 CLI
	# is not always installed (e.g. missing on Ubuntu minimal).
	#
	# Limitation: this is NOT PID-specific. If two OpenCode instances run in
	# the same directory (both without -s flags and without plugin state files),
	# both panes get the most recently updated session ID — one of them will be
	# wrong. To avoid this, launch with explicit session IDs: opencode -s <id>.
	local db_file="${HOME}/.local/share/opencode/opencode.db"
	if [ "$allow_db_fallback" = "1" ] && [ -n "$cwd" ] && [ -f "$db_file" ] && command -v python3 >/dev/null 2>&1; then
		sid=$(python3 -c "
import sqlite3, sys
try:
    conn = sqlite3.connect('file:' + sys.argv[1] + '?mode=ro', uri=True)
    cur = conn.cursor()
    cur.execute(
        'SELECT id FROM session WHERE directory = ? ORDER BY time_updated DESC LIMIT 1',
        (sys.argv[2],))
    row = cur.fetchone()
    if row:
        print(row[0])
    conn.close()
except Exception:
    pass
" "$db_file" "$cwd" 2>/dev/null || true)
		if [ -n "$sid" ]; then
			echo "$sid"
			return
		fi
	fi
}

get_codex_session() {
	local child_pid="$1"
	local args="$2"
	local cwd="${3:-}"

	# Method 1: session-tags.jsonl (written by Codex at runtime)
	local tags_file="${HOME}/.codex/session-tags.jsonl"
	if [ -f "$tags_file" ]; then
		local sid
		sid=$(grep "\"pid\": *${child_pid}[,}]" "$tags_file" 2>/dev/null |
			tail -1 |
			jq -r '.session // empty' 2>/dev/null || true)
		if [ -n "$sid" ]; then
			echo "$sid"
			return
		fi
	fi

	# Method 2: resume arg in process args (chicken-and-egg fallback)
	# After restore, codex is launched as `codex resume <session_id>`.
	local sid
	sid=$(echo "$args" | sed -n "s/.*resume  *\([A-Za-z0-9_-]*\).*/\1/p")
	if [ -n "$sid" ]; then
		echo "$sid"
		return
	fi

	# Method 3: Codex thread state DB (Codex >= ~0.118 persist state in
	# SQLite: ~/.codex/state_*.sqlite, table `threads`, columns id/cwd/
	# updated_at/archived).  This is the canonical current source — codex
	# writes a `threads` row per session and bumps `updated_at` on every
	# user turn.  A long-lived session that started days ago keeps its
	# same `id` in this table even though no new rollout JSONL is ever
	# written, which is exactly the case Method 4 misses.
	#
	# Strategy: among threads matching our process's cwd that are unarchived
	# and have been updated during this process's lifetime, pick the most
	# recently updated one that isn't already assigned to another pane.
	#
	# The DB file is versioned (state_5.sqlite, bumping on schema changes).
	# We glob for state_*.sqlite inside python3 (avoids `ls -t` pipe and
	# handles spaces in paths cleanly) and pick the newest by mtime.
	if [ -n "$cwd" ] && command -v python3 >/dev/null 2>&1; then
		local etimes
		etimes=$(ps -o etimes= -p "$child_pid" 2>/dev/null | tr -d ' ' || true)
		sid=$(
			USED_CODEX_SESSION_IDS="$USED_CODEX_SESSION_IDS" python3 - "$HOME/.codex" "$cwd" "$etimes" <<'PY'
import glob, os, sqlite3, sys, time

codex_home = sys.argv[1]
cwd = sys.argv[2]
etimes_raw = sys.argv[3].strip()
used = {sid for sid in os.environ.get("USED_CODEX_SESSION_IDS", "").split("\t") if sid}

# Find the newest state_*.sqlite by mtime.
dbs = sorted(glob.glob(os.path.join(codex_home, "state_*.sqlite")),
             key=os.path.getmtime, reverse=True)
if not dbs:
    sys.exit(0)

process_start = None
if etimes_raw.isdigit():
    process_start = time.time() - int(etimes_raw)

# Open read-only so we never conflict with a running codex writer.
try:
    con = sqlite3.connect(f"file:{dbs[0]}?mode=ro", uri=True)
except sqlite3.Error:
    sys.exit(0)

try:
    cur = con.cursor()
    cur.execute(
        "SELECT id, updated_at FROM threads "
        "WHERE cwd = ? AND archived = 0 "
        "ORDER BY updated_at DESC",
        (cwd,),
    )
    rows = cur.fetchall()
finally:
    con.close()

# Prefer threads whose last update happened after the process started
# (rules out stale threads in the same cwd). Fall back to most-recent
# overall if nothing qualifies — covers the edge case where a session
# was spawned but hasn't had any user turns yet.
def pick(rows, require_after_start):
    for sid, updated_at in rows:
        if sid in used:
            continue
        if require_after_start and process_start is not None and updated_at < process_start:
            continue
        return sid
    return None

sid = pick(rows, require_after_start=True) or pick(rows, require_after_start=False)
if sid:
    print(sid)
PY
		)
		if [ -n "$sid" ]; then
			echo "$sid"
			return
		fi
	fi

	# Method 4: Codex rollout session files (Codex ~0.100-0.117 wrote
	# these; newer versions have moved to SQLite, see Method 3).
	# Releases in that window persisted session metadata under
	# ~/.codex/sessions/*/*.jsonl and included a session_meta record
	# with both id and cwd.
	# We rank candidates by:
	# - matching cwd
	# - preferring session IDs not already assigned during this save
	# - preferring sessions created before the current process start time
	# - preferring sessions closest to the current process start time
	# - preferring recently modified rollout files
	local sessions_root="${HOME}/.codex/sessions"
	if [ -n "$cwd" ] && [ -d "$sessions_root" ] && command -v python3 >/dev/null 2>&1; then
		local etimes
		etimes=$(ps -o etimes= -p "$child_pid" 2>/dev/null | tr -d ' ' || true)
		sid=$(
			USED_CODEX_SESSION_IDS="$USED_CODEX_SESSION_IDS" python3 - "$sessions_root" "$cwd" "$etimes" <<'PY'
import datetime, json, os, sys, time

sessions_root = sys.argv[1]
cwd = sys.argv[2]
etimes_raw = sys.argv[3].strip()
used = {sid for sid in os.environ.get("USED_CODEX_SESSION_IDS", "").split("\t") if sid}

process_start = None
if etimes_raw.isdigit():
    process_start = time.time() - int(etimes_raw)

def parse_ts(value):
    if not value:
        return None
    try:
        return datetime.datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
    except Exception:
        return None

candidates = []
for root, _, files in os.walk(sessions_root):
    for name in files:
        if not name.endswith(".jsonl"):
            continue
        path = os.path.join(root, name)
        try:
            with open(path, "r", encoding="utf-8") as f:
                first = f.readline()
            if not first:
                continue
            record = json.loads(first)
            if record.get("type") != "session_meta":
                continue
            payload = record.get("payload") or {}
            if payload.get("cwd") != cwd:
                continue
            sid = payload.get("id")
            if not sid:
                continue
            candidates.append((sid, parse_ts(payload.get("timestamp")), os.path.getmtime(path)))
        except Exception:
            continue

if not candidates:
    sys.exit(0)

def score(item):
    sid, session_start, mtime = item
    reused = sid in used
    if process_start is None or session_start is None:
        prior = 0
        distance = float("inf")
    else:
        prior = 1 if session_start <= process_start + 120 else 0
        distance = abs(process_start - session_start)
    return (
        0 if reused else 1,
        prior,
        -distance,
        mtime,
    )

best = max(candidates, key=score)
print(best[0])
PY
		)
		if [ -n "$sid" ]; then
			echo "$sid"
			return
		fi
	fi
}

_arg_value() {
	local args="$1"
	shift
	# Disable pathname expansion while splitting: an argv value containing a
	# glob char (e.g. `--cwd '*'`) would otherwise expand against the cwd and
	# resolve the wrong session directory. Preserve the caller's noglob state
	# so we never re-enable globbing for a caller that had it off.
	local -a words
	local _had_noglob=0
	case $- in *f*) _had_noglob=1 ;; esac
	set -f
	words=($args)
	[ "$_had_noglob" = 1 ] || set +f
	local i n word flag next
	n=${#words[@]}
	for ((i = 0; i < n; i++)); do
		word="${words[$i]}"
		for flag in "$@"; do
			case "$word" in
			"$flag="*)
				echo "${word#*=}"
				return
				;;
			"$flag")
				next=$((i + 1))
				if [ "$next" -lt "$n" ]; then
					case "${words[$next]}" in
					-*) ;;
					*)
						echo "${words[$next]}"
						return
						;;
					esac
				fi
				;;
			esac
		done
	done
	return 0
}

resolve_path_against() {
	local base="$1"
	local path="$2"
	case "$path" in
	/*)
		echo "$path"
		;;
	*)
		if command -v python3 >/dev/null 2>&1; then
			python3 - "$base" "$path" <<'PY'
import os, sys
print(os.path.abspath(os.path.join(sys.argv[1], sys.argv[2])))
PY
		else
			echo "${base%/}/$path"
		fi
		;;
	esac
}

jsonl_session_id_from_file() {
	local session_file="$1"
	[ -f "$session_file" ] || return 0
	command -v python3 >/dev/null 2>&1 || return 0
	python3 - "$session_file" <<'PY'
import json, sys

try:
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        first = f.readline()
        second = f.readline()
except Exception:
    sys.exit(0)

for raw in (first, second if first else ""):
    if not raw:
        continue
    try:
        header = json.loads(raw)
    except Exception:
        continue
    if header.get("type") == "title":
        continue
    if header.get("type") != "session":
        sys.exit(0)
    sid = header.get("id")
    if isinstance(sid, str) and sid:
        print(sid)
    sys.exit(0)
PY
}

select_jsonl_session_id() {
	local child_pid="$1"
	local cwd="$2"
	local used_ids="$3"
	shift 3
	[ -n "$cwd" ] || return 0
	[ "$#" -gt 0 ] || return 0
	command -v python3 >/dev/null 2>&1 || return 0

	local etimes
	etimes=$(ps -o etimes= -p "$child_pid" 2>/dev/null | tr -d ' ' || true)
	python3 - "$cwd" "$etimes" "$used_ids" "$@" <<'PY'
import datetime, glob, json, os, sys, time

cwd = sys.argv[1]
etimes_raw = sys.argv[2].strip()
used = {sid for sid in sys.argv[3].split("\t") if sid}
session_dirs = []
seen_dirs = set()
for session_dir in sys.argv[4:]:
    if not session_dir or not os.path.isdir(session_dir):
        continue
    key = os.path.abspath(session_dir)
    if key in seen_dirs:
        continue
    seen_dirs.add(key)
    session_dirs.append(session_dir)

process_start = None
if etimes_raw.isdigit():
    process_start = time.time() - int(etimes_raw)

def parse_ts(value):
    if not value:
        return None
    try:
        return datetime.datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
    except Exception:
        return None

def read_logical_header(path):
    with open(path, "r", encoding="utf-8") as f:
        first = f.readline()
        second = f.readline()
    for raw in (first, second if first else ""):
        if not raw:
            continue
        header = json.loads(raw)
        if header.get("type") == "title":
            continue
        return header
    return None

candidates = []
for session_dir in session_dirs:
    for path in glob.glob(os.path.join(session_dir, "*.jsonl")):
        try:
            header = read_logical_header(path)
            if not header or header.get("type") != "session":
                continue
            sid = header.get("id")
            if not sid:
                continue
            header_cwd = header.get("cwd")
            if isinstance(header_cwd, str) and header_cwd and header_cwd != cwd:
                continue
            candidates.append((sid, parse_ts(header.get("timestamp")), os.path.getmtime(path)))
        except Exception:
            continue

if not candidates:
    sys.exit(0)

def score(item):
    sid, created_at, mtime = item
    reused = sid in used
    if process_start is None:
        active = 0
        prior = 0
        distance = float("inf")
    else:
        active = 1 if mtime >= process_start - 300 else 0
        prior = 1 if created_at is not None and created_at <= process_start + 120 else 0
        distance = abs(process_start - created_at) if created_at is not None else float("inf")
    return (
        0 if reused else 1,
        active,
        prior,
        -distance,
        mtime,
    )

best = max(candidates, key=score)
print(best[0])
PY
}

get_pi_session() {
	local child_pid="$1"
	local args="$2"
	local cwd="${3:-}"

	# Method 1: --session flag in process args (chicken-and-egg fallback)
	# After restore, pi is launched as `pi --session <session_id>`.
	# Supports both `--session <id>` and `--session=<id>` forms.
	local sid
	sid=$(echo "$args" | sed -n 's/.*--session[= ] *\([A-Za-z0-9_-]*\).*/\1/p')
	if [ -n "$sid" ]; then
		echo "$sid"
		return
	fi

	# Method 2: session files under ~/.pi/agent/sessions/--<cwd>--.
	# Pi writes one JSONL file per session with a session header. The shared
	# selector keeps the existing process-time scoring and same-cwd dedup policy.
	local sessions_root="${PI_CODING_AGENT_SESSION_DIR:-${HOME}/.pi/agent/sessions}"
	if [ -n "$cwd" ] && [ -d "$sessions_root" ]; then
		local safe_cwd session_dir
		safe_cwd=$(echo "$cwd" | sed -e 's#^[\\/]*##' -e 's#[/\\:]#-#g')
		session_dir="${sessions_root}/--${safe_cwd}--"
		sid=$(select_jsonl_session_id "$child_pid" "$cwd" "$USED_PI_SESSION_IDS" "$session_dir")
		if [ -n "$sid" ]; then
			echo "$sid"
			return
		fi
	fi
}

omp_config_root() {
	echo "${PI_CONFIG_DIR:-${HOME}/.omp}"
}

omp_agent_dir() {
	local profile="$1"
	local config_root
	config_root=$(omp_config_root)
	if [ -n "$profile" ]; then
		echo "${config_root}/profiles/${profile}/agent"
	elif [ -n "${PI_CODING_AGENT_DIR:-}" ]; then
		echo "$PI_CODING_AGENT_DIR"
	else
		echo "${config_root}/agent"
	fi
}

omp_session_root() {
	local profile="$1"
	local xdg_data_home="${XDG_DATA_HOME:-${HOME}/.local/share}"
	local config_root
	config_root=$(omp_config_root)
	if [ -n "$profile" ]; then
		if [ -d "${xdg_data_home}/omp/profiles/${profile}" ]; then
			echo "${xdg_data_home}/omp/profiles/${profile}/sessions"
		else
			echo "${config_root}/profiles/${profile}/agent/sessions"
		fi
	elif [ -d "${xdg_data_home}/omp" ]; then
		echo "${xdg_data_home}/omp/sessions"
	elif [ -n "${PI_CODING_AGENT_DIR:-}" ]; then
		echo "${PI_CODING_AGENT_DIR}/sessions"
	else
		echo "${config_root}/agent/sessions"
	fi
}

omp_terminal_session_root() {
	local profile="$1"
	local xdg_state_home="${XDG_STATE_HOME:-${HOME}/.local/state}"
	if [ -n "$profile" ]; then
		if [ -d "${xdg_state_home}/omp/profiles/${profile}" ]; then
			echo "${xdg_state_home}/omp/profiles/${profile}/terminal-sessions"
		else
			echo "$(omp_agent_dir "$profile")/terminal-sessions"
		fi
	elif [ -d "${xdg_state_home}/omp" ]; then
		echo "${xdg_state_home}/omp/terminal-sessions"
	else
		echo "$(omp_agent_dir "")/terminal-sessions"
	fi
}

omp_terminal_id_from_tty() {
	local pane_tty="$1"
	pane_tty="${pane_tty#/dev/}"
	echo "$pane_tty" | sed -e 's#[/\\:]#-#g'
}

omp_sanitize_path_name() {
	echo "$1" | sed -e 's#[/\\:]#-#g'
}

omp_session_dir_names() {
	local cwd="$1"
	local home="${HOME%/}"
	local tmp="${TMPDIR:-/tmp}"
	tmp="${tmp%/}"
	local primary rel legacy
	case "$cwd" in
	"$home")
		primary="-"
		;;
	"$home"/*)
		rel="${cwd#"$home"/}"
		primary="-$(omp_sanitize_path_name "$rel")"
		;;
	"$tmp")
		primary="-tmp"
		;;
	"$tmp"/*)
		rel="${cwd#"$tmp"/}"
		primary="-tmp-$(omp_sanitize_path_name "$rel")"
		;;
	*)
		primary="--$(echo "$cwd" | sed -e 's#^[\\/]*##' -e 's#[/\\:]#-#g')--"
		;;
	esac
	legacy="--$(echo "$cwd" | sed -e 's#^[\\/]*##' -e 's#[/\\:]#-#g')--"
	echo "$primary"
	[ "$legacy" != "$primary" ] && echo "$legacy"
}

get_omp_breadcrumb_session() {
	local pane_tty="$1"
	local lookup_cwd="$2"
	local profile="$3"
	[ -n "$pane_tty" ] || return 0
	[ -n "$lookup_cwd" ] || return 0

	local terminal_id root breadcrumb recorded_cwd session_file sid
	terminal_id=$(omp_terminal_id_from_tty "$pane_tty")
	[ -n "$terminal_id" ] || return 0
	root=$(omp_terminal_session_root "$profile")
	breadcrumb="${root}/${terminal_id}"
	[ -f "$breadcrumb" ] || return 0

	{
		IFS= read -r recorded_cwd || true
		IFS= read -r session_file || true
	} <"$breadcrumb"
	[ "$recorded_cwd" = "$lookup_cwd" ] || return 0
	[ -f "$session_file" ] || return 0

	sid=$(jsonl_session_id_from_file "$session_file")
	if [ -n "$sid" ]; then
		echo "$sid"
	fi
}

get_omp_session() {
	local child_pid="$1"
	local args="$2"
	local pane_cwd="${3:-}"
	local pane_tty="${4:-}"

	local sid
	sid=$(_arg_value "$args" --resume -r --session)
	if [ -n "$sid" ]; then
		echo "$sid"
		return
	fi

	local lookup_cwd="$pane_cwd"
	local cwd_arg
	cwd_arg=$(_arg_value "$args" --cwd)
	if [ -n "$cwd_arg" ]; then
		lookup_cwd=$(resolve_path_against "$pane_cwd" "$cwd_arg")
	fi

	local profile
	profile=$(_arg_value "$args" --profile)

	sid=$(get_omp_breadcrumb_session "$pane_tty" "$lookup_cwd" "$profile")
	if [ -n "$sid" ]; then
		echo "$sid"
		return
	fi

	local custom_session_dir
	custom_session_dir=$(_arg_value "$args" --session-dir)
	if [ -n "$custom_session_dir" ]; then
		custom_session_dir=$(resolve_path_against "$lookup_cwd" "$custom_session_dir")
		sid=$(select_jsonl_session_id "$child_pid" "$lookup_cwd" "$USED_OMP_SESSION_IDS" "$custom_session_dir")
		if [ -n "$sid" ]; then
			echo "$sid"
			return
		fi
	fi

	local session_root dir_name
	local -a session_dirs=()
	session_root=$(omp_session_root "$profile")
	while IFS= read -r dir_name; do
		[ -n "$dir_name" ] && session_dirs+=("${session_root}/${dir_name}")
	done <<<"$(omp_session_dir_names "$lookup_cwd")"
	sid=$(select_jsonl_session_id "$child_pid" "$lookup_cwd" "$USED_OMP_SESSION_IDS" "${session_dirs[@]}")
	if [ -n "$sid" ]; then
		echo "$sid"
	fi
}

# Resolve grok's active-sessions registry path. grok records every live
# interactive session in ~/.grok/active_sessions.json as an array of
#   { "session_id": "<uuid>", "pid": <int>, "cwd": "<path>", "opened_at": "..." }
# and updates it on session open/close. GROK_HOME lets tests (and unusual
# installs) point this at a fixture directory.
grok_active_sessions_file() {
	echo "${GROK_HOME:-$HOME/.grok}/active_sessions.json"
}

get_grok_session() {
	local child_pid="$1"
	local args="$2"

	# Method 1 (primary): PID lookup in grok's active-sessions registry.
	# Authoritative for every running session regardless of launch form — a
	# bare `grok` (no args) is recorded here with its session_id — and lookup
	# is keyed by PID, so two sessions sharing a cwd never collide (the
	# cwd-scoped ambiguity that opencode/codex/pi fallbacks suffer from does
	# not apply to grok).
	local registry sid
	registry=$(grok_active_sessions_file)
	if [ -f "$registry" ]; then
		sid=$(jq -r --arg pid "$child_pid" \
			'.[]? | select((.pid | tostring) == $pid) | .session_id // empty' \
			"$registry" 2>/dev/null | head -n1 || true)
		if [ -n "$sid" ]; then
			echo "$sid"
			return
		fi
	fi

	# Method 2 (fallback): -r/--resume <uuid> in process args. Covers the
	# chicken-and-egg window right after a restore, before grok has rewritten
	# active_sessions.json. Anchored to a 36-char UUID so a trailing prompt
	# positional can't be mistaken for the ID. Handles `--resume <id>`,
	# `--resume=<id>`, `-r <id>`, and `-r=<id>`.
	sid=$(echo "$args" | sed -n 's/.*--resume[= ] *\([0-9a-fA-F]\{8\}-[0-9a-fA-F-]\{27\}\).*/\1/p')
	[ -z "$sid" ] && sid=$(echo "$args" | sed -n 's/.*-r[= ] *\([0-9a-fA-F]\{8\}-[0-9a-fA-F-]\{27\}\).*/\1/p')
	if [ -n "$sid" ]; then
		echo "$sid"
		return
	fi
}

register_codex_session_id() {
	local sid="$1"
	[ -z "$sid" ] && return
	case "$USED_CODEX_SESSION_IDS" in
	*"$sid"*) ;;
	*)
		USED_CODEX_SESSION_IDS="${USED_CODEX_SESSION_IDS}"$'\t'"$sid"
		;;
	esac
}

register_pi_session_id() {
	local sid="$1"
	[ -z "$sid" ] && return
	case "$USED_PI_SESSION_IDS" in
	*"$sid"*) ;;
	*)
		USED_PI_SESSION_IDS="${USED_PI_SESSION_IDS}"$'\t'"$sid"
		;;
	esac
}

register_omp_session_id() {
	local sid="$1"
	[ -z "$sid" ] && return
	case "$USED_OMP_SESSION_IDS" in
	*"$sid"*) ;;
	*)
		USED_OMP_SESSION_IDS="${USED_OMP_SESSION_IDS}"$'\t'"$sid"
		;;
	esac
}

# --- CLI args extraction helpers ---

# Strip a long option: --flag, --flag=val, or --flag val.
# Value (if space-separated) must not start with "-" to avoid consuming next flag.
_strip_long_opt() {
	echo "$2" | sed -E "s/(^| )$1(=[^ ]*| +[^- ][^ ]*)?( |$)/ /g"
}

# Strip a short option: -X or -X val.
_strip_short_opt() {
	echo "$2" | sed -E "s/(^| )$1( +[^- ][^ ]*)?( |$)/ /g"
}

# Strip a boolean long option (no value): --flag
_strip_bool_opt() {
	echo "$2" | sed -E "s/(^| )$1( |$)/ /g"
}

# Strip known subcommands from args (e.g. "resume <id>" or "fork <id>").
# Usage: _strip_subcmds "args" subcmd1 subcmd2 ...
#
# Scans all args left-to-right. Each non-dash token is checked against the
# list of known subcommands. If it matches, the token and an optional
# following positional value (non-dash) are removed. Non-matching bare
# tokens (e.g. option values like "o3" in `--model o3 resume`) are
# skipped — scanning continues past them to find the actual subcommand.
_strip_subcmds() {
	local -a words=($1)
	shift
	local -a targets=("$@")
	local i=0 n=${#words[@]}
	while [ "$i" -lt "$n" ]; do
		case "${words[$i]}" in
		-*) i=$((i + 1)) ;;
		*)
			local matched=0 t
			for t in "${targets[@]}"; do
				if [ "${words[$i]}" = "$t" ]; then
					matched=1
					unset 'words[i]'
					local nxt=$((i + 1))
					if [ "$nxt" -lt "$n" ]; then
						case "${words[$nxt]}" in
						-*) ;;
						*) unset 'words[nxt]'; i=$((i + 1)) ;;
						esac
					fi
					break
				fi
			done
			i=$((i + 1))
			;;
		esac
	done
	[ "${#words[@]}" -gt 0 ] && echo "${words[*]}"
	return 0
}

# Discover session-identity flags from a tool's --help output.
# Matches long option names against a keyword pattern and emits lines of
# "long [short]" pairs (e.g. "--resume -r" or "--fork-session").
# Cached per tool in _SESSION_FLAGS_<tool> to avoid repeated --help calls.
_discover_session_flags() {
	local tool="$1" pattern="$2"
	local cache_var="_SESSION_FLAGS_${tool}"
	local cached="${!cache_var:-}"
	if [ -n "$cached" ]; then
		echo "$cached"
		return
	fi

	local help_out result=""
	local fallback_var="SESSION_FLAGS_FALLBACK_${tool}"
	local fallback="${!fallback_var:-}"
	help_out=$("$tool" --help 2>/dev/null) || true
	if [ -n "$help_out" ]; then
		local line long short
		while IFS= read -r line; do
			long=$(echo "$line" | grep -oE -- '--[a-z][-a-z]*' | head -1) || continue
			echo "$long" | grep -qE "$pattern" || continue
			# Extract short flag: handles both "-X, --long" and "--long, -X" formats
			short=$(echo "$line" | grep -oE '(^|\s|,\s*)-[a-zA-Z](\s|,|$)' | grep -oE '\-[a-zA-Z]' | head -1 || true)
			result="${result}${long}${short:+ ${short}}
"
		done <<<"$(echo "$help_out" | grep -E '^\s+(-[a-zA-Z],\s+)?--')"
	fi

	if [ -n "$fallback" ]; then
		result="${result}${fallback}
"
	fi
	result=$(echo "$result" | sort -u | sed '/^$/d')
	printf -v "$cache_var" '%s' "${result:--}"
	[ -n "$result" ] && echo "$result"
	return 0
}

# Discover which session-identity subcommands a tool actually supports, by
# matching a pattern of candidate subcommand names against the tool's --help.
# Emits the confirmed subcommand names (one per line, in pattern order).
# Cached per tool in _SESSION_SUBCMDS_<tool> to avoid repeated --help calls:
# like _discover_session_flags this is called from extract_cli_args inside a
# $() subshell per pane, so the cache only pays off when warmed in main's shell.
_discover_session_subcmds() {
	local tool="$1" subcmd_pattern="$2"
	local cache_var="_SESSION_SUBCMDS_${tool}"
	local cached="${!cache_var:-}"
	if [ -n "$cached" ]; then
		[ "$cached" = "-" ] || echo "$cached"
		return 0
	fi

	# When --help is unavailable (tmux hooks may run with a limited PATH that
	# cannot resolve the binary), assume every candidate is supported so known
	# session subcommands are still stripped — matches prior behavior.
	local help_out subcmd result=""
	help_out=$("$tool" --help 2>/dev/null) || true
	for subcmd in $(echo "$subcmd_pattern" | tr '|' ' '); do
		if [ -z "$help_out" ] || echo "$help_out" | grep -qw "$subcmd"; then
			result="${result}${subcmd}
"
		fi
	done
	result=$(echo "$result" | sed '/^$/d')
	printf -v "$cache_var" '%s' "${result:--}"
	[ -n "$result" ] && echo "$result"
	return 0
}

# Session-identity flag name patterns per tool.
# Matched against long option names from --help. Flag names are semantic
# (--resume always means resume), so new flags like --resume-from are
# auto-discovered without script changes.
SESSION_FLAG_PATTERN_claude='^--(resume|continue|session-id|fork-session|from-pr)$'
SESSION_FLAG_PATTERN_opencode='^--session$'
SESSION_FLAG_PATTERN_pi='^--(session|resume|continue|fork)$'
SESSION_FLAG_PATTERN_omp='^--(session|resume|continue|fork)$'
SESSION_FLAG_PATTERN_grok='^--(resume|continue|session-id|fork-session)$'
# codex uses subcommands (resume, fork), not --flags — handled separately.
SESSION_SUBCMD_PATTERN_codex='resume|fork'
# Codex resume/fork have subcommand-specific picker flags that must also
# be stripped (they are not top-level options and break restore if kept).
SESSION_SUBCMD_FLAGS_codex='--last --all --include-non-interactive'

# Static fallbacks for when <tool> --help is unavailable (tmux hooks may
# run with a limited PATH that cannot resolve the binary).
SESSION_FLAGS_FALLBACK_claude="--continue -c
--fork-session
--from-pr
--resume -r
--session-id"
SESSION_FLAGS_FALLBACK_opencode="--session -s"
SESSION_FLAGS_FALLBACK_pi="--continue -c
--fork
--resume -r
--session"
SESSION_FLAGS_FALLBACK_omp="--continue -c
--fork
--resume -r
--session"
SESSION_FLAGS_FALLBACK_grok="--continue -c
--fork-session
--resume -r
--session-id -s"

# Pre-warm session-identity discovery once per tool present in a tab-separated
# MATCHES blob (tool name in field 2). extract_cli_args runs in a $() subshell
# per pane and the discovery helpers cache into a shell var that does not
# survive the subshell, so without warming in main's shell `<tool> --help`
# re-runs for every assistant pane (e.g. 8 claude panes => 8 × `claude --help`).
# Driven off the SESSION_*_PATTERN_<tool> tables so every assistant is covered —
# flag-based (claude/opencode/pi) and subcommand-based (codex) alike — and new
# tools warm automatically once they gain a pattern, with no hardcoded list.
_warm_session_discovery() {
	local matches="$1"
	[ -n "$matches" ] || return 0
	local tool flag_pat sub_pat
	while IFS= read -r tool; do
		# Skip blanks and names that are not valid shell identifier suffixes:
		# the indirect expansions below would otherwise abort under set -e.
		case "$tool" in
		'' | *[!A-Za-z0-9_]*) continue ;;
		esac
		flag_pat="SESSION_FLAG_PATTERN_${tool}"
		sub_pat="SESSION_SUBCMD_PATTERN_${tool}"
		if [ -n "${!flag_pat:-}" ]; then
			_discover_session_flags "$tool" "${!flag_pat}" >/dev/null
		fi
		if [ -n "${!sub_pat:-}" ]; then
			_discover_session_subcmds "$tool" "${!sub_pat}" >/dev/null
		fi
	done <<<"$(printf '%s\n' "$matches" | cut -f2 | sort -u)"
	return 0
}

# --- CLI args extraction ---

# Extract CLI args from a process's full command line, stripping the binary
# name/path and tool-specific session/resume arguments.
#
# Usage: extract_cli_args <tool> <full_args_from_ps>
# Returns: the remaining flags/args as a single whitespace-normalized string.
#
# Session-identity flags are discovered dynamically from <tool> --help,
# matched by name pattern. This keeps stripping in sync with the installed
# tool version without manual flag list maintenance.
extract_cli_args() {
	local tool="$1" raw_args="$2"

	# Strip binary name/path: remove first token (which is the binary or /path/to/binary).
	local args="${raw_args#* }"
	# If there was no space (bare binary name), args equals raw_args — set to empty
	if [ "$args" = "$raw_args" ]; then
		echo ""
		return
	fi

	# Node.js processes (claude, codex) may show a second token that is the
	# script path, e.g. `claude /usr/local/bin/claude --resume ...`.
	# Strip any leading token that is a path ending in the tool binary name.
	local first_arg="${args%% *}"
	case "$first_arg" in
	*/"$tool")
		args="${args#"$first_arg"}"
		args="${args# }"
		;;
	esac

	# Strip tool-specific session/resume flags.
	local pattern_var="SESSION_FLAG_PATTERN_${tool}"
	local pattern="${!pattern_var:-}"
	local subcmd_var="SESSION_SUBCMD_PATTERN_${tool}"
	local subcmd_pattern="${!subcmd_var:-}"

	if [ -n "$pattern" ]; then
		local flags line long short
		flags=$(_discover_session_flags "$tool" "$pattern")
		if [ "$flags" != "-" ] && [ -n "$flags" ]; then
			while IFS= read -r line; do
				long="${line%% *}"
				short="${line#"$long"}"
				short="${short# }"
				args=$(_strip_long_opt "$long" "$args")
				[ -n "$short" ] && args=$(_strip_short_opt "$short" "$args")
			done <<< "$flags"
		fi
	fi

	if [ -n "$subcmd_pattern" ]; then
		local subcmd
		local -a confirmed_subcmds=()
		while IFS= read -r subcmd; do
			[ -n "$subcmd" ] && confirmed_subcmds+=("$subcmd")
		done <<<"$(_discover_session_subcmds "$tool" "$subcmd_pattern")"
		if [ "${#confirmed_subcmds[@]}" -gt 0 ]; then
			args=$(_strip_subcmds "$args" "${confirmed_subcmds[@]}")
			# Strip subcommand-specific picker flags (e.g. codex resume --last)
			local subcmd_flags_var="SESSION_SUBCMD_FLAGS_${tool}"
			local subcmd_flags="${!subcmd_flags_var:-}"
			local flag
			for flag in $subcmd_flags; do
				args=$(_strip_bool_opt "$flag" "$args")
			done
		fi
	fi

	# Normalize whitespace: collapse multiple spaces, trim leading/trailing
	echo "$args" | sed -E 's/  +/ /g; s/^ //; s/ $//'
}

# Resolve all detected assistant candidates for one pane and emit at most one
# session entry (first resolvable candidate in BFS order).
#
# Preserves legacy OpenCode behavior:
#   pass 1: PID-specific only (no DB fallback)
#   pass 2: OpenCode-only with DB fallback enabled
resolve_pane_candidates() {
	local pane_target="$1"
	local pane_cwd="$2"
	local pane_tty="$3"
	local pane_candidates="$4"
	local us="$5"
	local has_assoc_cache="$6"
	local state_cache_file="$7"
	local parts_file="$8"

	local resolved=0 first_tool="" first_pid=""
	for pass in 1 2; do
		[ "$resolved" -eq 1 ] && break
		local allow_opencode_db=0
		[ "$pass" -eq 2 ] && allow_opencode_db=1
		while IFS="$us" read -r cand_tool cand_pid cand_args; do
			[ -z "$cand_tool" ] && continue
			[ -z "$first_tool" ] && first_tool="$cand_tool" && first_pid="$cand_pid"

			# Pass 2 is only for OpenCode DB fallback.
			if [ "$pass" -eq 2 ] && [ "$cand_tool" != "opencode" ]; then
				continue
			fi

			local cached="" cached_sid="" cached_model="" cached_env="null"
			if [ "$has_assoc_cache" -eq 1 ]; then
				cached="${STATE_CACHE[$cand_pid]:-}"
			elif [ -s "$state_cache_file" ]; then
				cached=$(awk -F"$us" -v p="$cand_pid" '$1 == p {for(i=2;i<=NF;i++) printf "%s%s",$i,(i<NF?FS:""); print ""; exit}' "$state_cache_file")
			fi
			if [ -n "$cached" ]; then
				cached_sid="${cached%%"$us"*}"
				local _rest="${cached#*"$us"}"
				cached_model="${_rest%%"$us"*}"
				cached_env="${_rest#*"$us"}"
				[ -z "$cached_env" ] && cached_env="null"
			fi

			local session_id=""
			case "$cand_tool" in
			claude)
				session_id="$cached_sid"
				# Keep legacy fallback behavior when cache misses (state file + --resume).
				[ -z "$session_id" ] && session_id=$(get_claude_session "$cand_pid" "$cand_args")
				;;
			opencode)
				session_id="$cached_sid"
				[ -z "$session_id" ] && session_id=$(get_opencode_session "$cand_pid" "$cand_args" "$pane_cwd" "$allow_opencode_db")
				;;
			codex) session_id=$(get_codex_session "$cand_pid" "$cand_args" "$pane_cwd") ;;
			pi) session_id=$(get_pi_session "$cand_pid" "$cand_args" "$pane_cwd") ;;
			omp) session_id=$(get_omp_session "$cand_pid" "$cand_args" "$pane_cwd" "$pane_tty") ;;
			grok) session_id=$(get_grok_session "$cand_pid" "$cand_args") ;;
			esac

			if [ -n "$session_id" ]; then
				local cli_args model="" env_json="null" state_file=""
				cli_args=$(extract_cli_args "$cand_tool" "$cand_args")
				model="$cached_model"
				env_json="$cached_env"

				# If cache wasn't available, fall back to direct state-file enrichment.
				case "$cand_tool" in
				claude) state_file="$STATE_DIR/claude-${cand_pid}.json" ;;
				opencode) state_file="$STATE_DIR/opencode-${cand_pid}.json" ;;
				esac
				if [ -n "$state_file" ] && [ -f "$state_file" ]; then
					[ -z "$model" ] && model=$(jq -r '.model // empty' "$state_file" 2>/dev/null || true)
					if [ "$env_json" = "null" ]; then
						env_json=$(jq '.env // null' "$state_file" 2>/dev/null || echo "null")
					fi
				fi

				# Fallback: parse --model from CLI args if not in state file.
				# Regex stored in variable for bash 3.2 compat (inline capture groups fail).
				local _model_re='--model[= ]([^ ]+)'
				if [ -z "$model" ] && [[ "$cand_args" =~ $_model_re ]]; then
					model="${BASH_REMATCH[1]}"
				fi

				# Write TSV for batch JSON conversion (replaces per-entry jq -n).
				printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
					"$pane_target" "$cand_tool" "$session_id" "$pane_cwd" "$cand_pid" "$model" "$cli_args" "$env_json" >>"$parts_file"

				case "$cand_tool" in
				codex) register_codex_session_id "$session_id" ;;
				pi) register_pi_session_id "$session_id" ;;
				omp) register_omp_session_id "$session_id" ;;
				esac
				resolved=1
				break
			fi
		done <<<"$pane_candidates"
	done

	if [ "$resolved" -eq 0 ] && [ -n "$first_tool" ]; then
		log "detected $first_tool in $pane_target (pid $first_pid) but no session ID available"
	fi
}

# --- Main ---

main() {
	PS_FILE=$(mktemp)
	PANE_FILE=$(mktemp)
	PARTS_FILE=$(mktemp)
	STATE_CACHE_FILE=$(mktemp)
	trap 'rm -f "$PS_FILE" "$PANE_FILE" "$PARTS_FILE" "$STATE_CACHE_FILE"' EXIT INT TERM

	# Timestamp for the JSON output envelope
	local SAVE_TS
	SAVE_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

	# Snapshot process table and pane info to temp files (each read once)
	ps -eo pid=,ppid=,args= >"$PS_FILE" 2>/dev/null
	if [ ! -s "$PS_FILE" ]; then
		log "ps snapshot failed or empty, skipping save"
		rm -f "$PS_FILE" "$PANE_FILE" "$PARTS_FILE"
		return 1
	fi
	tmux list-panes -a -F "#{session_name}:#{window_index}.#{pane_index}|#{pane_pid}|#{pane_current_path}|#{pane_tty}" >"$PANE_FILE"

	# --- Single awk pass: detect assistant tools across ALL pane process trees ---
	# Replaces ~200 separate echo|awk pipe invocations with one pass.
	# Reads pane list + ps snapshot, builds process tree in memory,
	# BFS-walks descendants for each pane PID, detects tools.
	# Output (tab-delimited): target\ttool\ttool_pid\ttool_args\tcwd\tpane_tty
	# NOTE: emit all candidates per pane (pane PID + descendants) in BFS order.
	# The shell pass below preserves legacy two-pass OpenCode behavior:
	# 1) PID-specific only, then 2) DB fallback.
	local MATCHES
	MATCHES=$(awk '
		NR == FNR {
			# First file: pane data (pipe-delimited)
			split($0, p, "|")
			pane_target[p[2]] = p[1]
			pane_cwd[p[2]] = p[3]
			pane_tty[p[2]] = p[4]
			pane_list[++pane_count] = p[2]
			next
		}
		{
			# Second file: ps output (whitespace-delimited)
			pid = $1+0; ppid = $2+0
			line = $0
			sub(/^[ \t]*[0-9]+[ \t]+[0-9]+[ \t]*/, "", line)
			gsub(/\n/, " ", line)  # Normalize multi-line args (Linux prctl)

			proc_args[pid] = line
			# First child concatenation produces "" SUBSEP pid; the k > 0 guard
			# in the BFS loop below filters the resulting empty first element.
			child_list[ppid] = (ppid in child_list) ? child_list[ppid] SUBSEP pid : "" pid

			# Detect tool in command args
			# Keep patterns aligned with detect_tool() in lib-detect.sh:
			# - bare binary at start, or path component (/tool)
			# - opencode excludes "opencode run " subprocesses
			# - omp excludes hidden "__omp_worker_" subprocesses
			if      (line ~ /(^claude( |$)|\/claude( |$))/)                                      proc_tool[pid] = "claude"
			else if (line ~ /(^opencode( |$)|\/opencode( |$))/ && line !~ /opencode run /)       proc_tool[pid] = "opencode"
			else if (line ~ /(^codex( |$)|\/codex( |$))/)                                        proc_tool[pid] = "codex"
			else if (line ~ /(^pi( |$)|\/pi( |$))/)                                              proc_tool[pid] = "pi"
			else if (line ~ /(^omp( |$)|\/omp( |$))/ && line !~ /__omp_worker_/)                 proc_tool[pid] = "omp"
			else if (line ~ /(^grok( |$)|\/grok( |$))/)                                          proc_tool[pid] = "grok"
		}
		END {
			for (i = 1; i <= pane_count; i++) {
				root = pane_list[i]+0
				target = pane_target[pane_list[i]]
				cwd = pane_cwd[pane_list[i]]
				tty = pane_tty[pane_list[i]]

				# Check pane PID itself (handles exec-replaced shells)
				if (root in proc_tool && proc_tool[root] != "") {
					printf "%s\t%s\t%d\t%s\t%s\t%s\n", target, proc_tool[root], root, proc_args[root], cwd, tty
				}

				# BFS through descendant processes
				delete queue
				qs = 1; qe = 0
				if (root in child_list) {
					nc = split(child_list[root], kids, SUBSEP)
					for (j = 1; j <= nc; j++) {
						k = kids[j]+0
						if (k > 0) { queue[++qe] = k }
					}
				}

				while (qs <= qe) {
					cur = queue[qs++]+0
					if (cur in proc_tool && proc_tool[cur] != "") {
						printf "%s\t%s\t%d\t%s\t%s\t%s\n", target, proc_tool[cur], cur, proc_args[cur], cwd, tty
					}
					if (cur in child_list) {
						nc = split(child_list[cur], kids, SUBSEP)
						for (j = 1; j <= nc; j++) {
							k = kids[j]+0
							if (k > 0) { queue[++qe] = k }
						}
					}
				}
			}
		}
	' "$PANE_FILE" "$PS_FILE")

	rm -f "$PS_FILE" "$PANE_FILE"

	# --- Pre-cache all state files in one jq call (requires jq 1.7+) ---
	# Replaces ~58 per-file jq invocations with one jq + bash associative array.
	# Uses jq 1.7+ input_filename to map filenames to PIDs.
	# Keys: PID. Values: session_id<US>model<US>env_json
	# Delimiter: US (unit separator \x1f) instead of TAB because bash read
	# collapses consecutive whitespace IFS characters (including TAB),
	# silently merging empty fields with the next non-empty field.
	#
	# Tradeoff: jq aborts at the first parse error (jqlang/jq#1942), so a
	# corrupt state file drops cache entries for files listed after it. Those
	# sessions fall through to per-session extraction (--resume args, per-file
	# jq in get_*_session) and still save correctly — just without the batch
	# speedup. Corrupt files are rare (hooks write atomically) and transient
	# (overwritten on next hook invocation). Pre-validating with `jq empty`
	# per file costs ~190ms (60 files), which negates the entire batch gain.
	local US=$'\x1f'
	local HAS_ASSOC_CACHE=0
	# Feature-detect jq 1.7+ (input_filename support). Use echo+pipe so jq
	# has valid JSON input — /dev/null has no content and causes a parse error.
	if echo '{}' | jq 'input_filename' >/dev/null 2>&1; then
		local state_files=()
		for _f in "$STATE_DIR"/claude-*.json "$STATE_DIR"/opencode-*.json; do
			[ -f "$_f" ] && state_files+=("$_f")
		done
		if [ ${#state_files[@]} -gt 0 ]; then
			jq -r '[
					(input_filename | split("/") | .[-1] | split("-")[1:] | join("-") | rtrimstr(".json")),
					(.session_id // ""),
					(.model // ""),
					((.env // null) | tojson)
				] | join("\u001f")' "${state_files[@]}" 2>/dev/null >"$STATE_CACHE_FILE" || true

			if [ "${BASH_VERSINFO[0]:-0}" -ge 4 ] && [ -s "$STATE_CACHE_FILE" ]; then
				HAS_ASSOC_CACHE=1
				# shellcheck disable=SC2034
				declare -A STATE_CACHE
				while IFS="$US" read -r _pid _sid _model _env; do
					STATE_CACHE["$_pid"]="$_sid$US$_model$US$_env"
				done <"$STATE_CACHE_FILE"
			elif [ "${BASH_VERSINFO[0]:-0}" -lt 4 ] && [ -s "$STATE_CACHE_FILE" ]; then
				log "bash < 4 detected; associative cache disabled (falling through to direct state-file reads)"
			fi
		fi
	else
		log "jq < 1.7 detected; state file cache disabled (falling through to per-file reads)"
	fi

	# Pre-warm session-identity discovery so the per-pane $() subshells inherit
	# a populated cache instead of each re-running `<tool> --help`. Warming must
	# happen here in main's shell — the subshells cannot write back into it.
	# Only tools present in MATCHES are warmed (see _warm_session_discovery).
	_warm_session_discovery "$MATCHES"

	# Process only matched panes (those with a detected tool)
	if [ -n "$MATCHES" ]; then
		local current_target="" current_cwd="" current_tty="" pane_candidates=""
		while IFS=$'\t' read -r target tool cpid cargs cwd tty; do
			[ -z "$target" ] && continue

			# If pane changed, process the previous pane's candidate list.
			if [ -n "$current_target" ] && [ "$target" != "$current_target" ]; then
				resolve_pane_candidates "$current_target" "$current_cwd" "$current_tty" "$pane_candidates" "$US" "$HAS_ASSOC_CACHE" "$STATE_CACHE_FILE" "$PARTS_FILE"
				pane_candidates=""
			fi

			current_target="$target"
			current_cwd="$cwd"
			current_tty="$tty"
			# Candidate tuples are US-delimited; a literal \x1f inside process args
			# would break parsing, but this is practically unlikely for CLI argv.
			pane_candidates="${pane_candidates}${tool}${US}${cpid}${US}${cargs}"$'\n'
		done <<<"$MATCHES"

		# Process final pane candidate list.
		if [ -n "$current_target" ] && [ -n "$pane_candidates" ]; then
			resolve_pane_candidates "$current_target" "$current_cwd" "$current_tty" "$pane_candidates" "$US" "$HAS_ASSOC_CACHE" "$STATE_CACHE_FILE" "$PARTS_FILE"
		fi
	fi

	# Single jq: convert TSV to JSON array + build final output (replaces N+3 jq calls)
	local count=0
	if [ -s "$PARTS_FILE" ]; then
		jq -Rs --arg ts "$SAVE_TS" '
			split("\n") | map(select(length > 0) | split("\t") |
			{pane:.[0], tool:.[1], session_id:.[2], cwd:.[3], pid:.[4], model:.[5], cli_args:.[6],
			 env:(.[7] // "null" | try fromjson catch null)})
			| {timestamp: $ts, sessions: .}
		' "$PARTS_FILE" >"$OUTPUT_FILE"
		count=$(jq '.sessions | length' "$OUTPUT_FILE")
	else
		jq -n --arg ts "$SAVE_TS" '{timestamp: $ts, sessions: []}' >"$OUTPUT_FILE"
	fi

	log "saved $count assistant session(s) to $OUTPUT_FILE"

	# The sidecar is overwritten in place on every save, so a save that fires
	# at the wrong moment (e.g. mid-restore, before assistants have been
	# replayed) destroys the only copy of the pane→session mapping — fresh
	# sessions have no --resume arg in their pane command line, making the
	# sidecar the sole durable record. Keeping a bounded history turns that
	# loss into a one-file rollback.
	archive_sidecar_history

	# Strip captured pane contents for assistant panes so tmux-resurrect
	# won't restore stale TUI output that the post-restore hook would
	# immediately replace. Non-assistant pane contents are preserved.
	if [ "$count" -gt 0 ]; then
		strip_assistant_pane_contents
	fi
}

# Archive one timestamped copy of the sidecar per distinct state under
# $RESURRECT_DIR/assistant-sessions-history/, bounded to the newest
# @assistant-resurrect-sidecar-history entries (default 100; 0 disables).
# The sidecar's .timestamp field changes on every save, so dedup compares
# the document with that field stripped; pid churn (assistant restarts)
# deliberately counts as a new state. Recovery:
#   cp assistant-sessions-history/<pick>.json assistant-sessions.json
#   bash scripts/restore-assistant-sessions.sh
archive_sidecar_history() {
	local limit
	limit=$(tmux show-option -gqv @assistant-resurrect-sidecar-history 2>/dev/null || true)
	case "$limit" in '' | *[!0-9]*) limit=100 ;; esac
	[ "$limit" -eq 0 ] && return 0
	[ -f "$OUTPUT_FILE" ] || return 0

	local hist_dir="$RESURRECT_DIR/assistant-sessions-history"
	mkdir -p "$hist_dir" 2>/dev/null || return 0

	# Skip if nothing but the save timestamp changed since the newest copy
	local newest
	newest=$(ls -t "$hist_dir"/assistant-sessions-*.json 2>/dev/null | head -1 || true)
	if [ -n "$newest" ] &&
		[ "$(jq -S 'del(.timestamp)' "$OUTPUT_FILE" 2>/dev/null)" = "$(jq -S 'del(.timestamp)' "$newest" 2>/dev/null)" ]; then
		return 0
	fi

	cp "$OUTPUT_FILE" "$hist_dir/assistant-sessions-$(date -u +%Y%m%dT%H%M%S).json" 2>/dev/null || return 0

	# Prune oldest copies beyond the limit
	ls -t "$hist_dir"/assistant-sessions-*.json 2>/dev/null | tail -n +$((limit + 1)) | while IFS= read -r f; do
		rm -f "$f"
	done
}

# Remove assistant pane entries from tmux-resurrect's pane_contents.tar.gz.
# tmux-resurrect stores captured pane text in an archive with entries like:
#   ./pane_contents/pane-{session_name}:{window_index}.{pane_index}
# Our saved JSON uses the same "{session}:{window}.{pane}" target format,
# so the mapping is direct.
#
# Upstream assumption: tmux-resurrect archive layout uses the naming convention
# described above. Verified against tmux-resurrect helpers.sh:pane_contents_file().
strip_assistant_pane_contents() {
	local archive="$RESURRECT_DIR/pane_contents.tar.gz"
	[ -f "$archive" ] || return 0

	# Collect pane targets from the sessions we just saved
	local panes
	panes=$(jq -r '.sessions[].pane' "$OUTPUT_FILE" 2>/dev/null) || return 0
	[ -z "$panes" ] && return 0

	local tmpdir
	tmpdir=$(mktemp -d) || return 0

	# Extract, remove assistant pane files, re-archive.
	# If any step fails, log a warning and leave the archive untouched.
	if ! (gzip -d <"$archive" | tar xf - -C "$tmpdir") 2>/dev/null; then
		log "warning: failed to extract pane_contents archive, skipping content stripping"
		rm -rf "$tmpdir"
		return 0
	fi

	local removed=0
	while IFS= read -r pane_target; do
		local content_file="$tmpdir/pane_contents/pane-${pane_target}"
		if [ -f "$content_file" ]; then
			rm -f "$content_file"
			removed=$((removed + 1))
		fi
	done <<<"$panes"

	if [ "$removed" -gt 0 ]; then
		if tar cf - -C "$tmpdir" ./pane_contents/ | gzip >"${archive}.tmp" 2>/dev/null; then
			mv "${archive}.tmp" "$archive"
			log "stripped pane contents for $removed assistant pane(s)"
		else
			log "warning: failed to repack pane_contents archive"
			rm -f "${archive}.tmp"
		fi
	fi

	rm -rf "$tmpdir"
}

# Retained for backward compatibility — main() no longer calls this directly
# (batched processing replaced per-pane emit), but external scripts or tests
# may source this file and call emit_session().
emit_session() {
	local target="$1" tool="$2" cpid="$3" cargs="$4" cwd="$5"
	local allow_opencode_db="${6:-1}"
	local log_missing="${7:-1}"
	local session_id=""
	case "$tool" in
	claude) session_id=$(get_claude_session "$cpid" "$cargs") ;;
	opencode) session_id=$(get_opencode_session "$cpid" "$cargs" "$cwd" "$allow_opencode_db") ;;
	codex) session_id=$(get_codex_session "$cpid" "$cargs" "$cwd") ;;
	pi) session_id=$(get_pi_session "$cpid" "$cargs" "$cwd") ;;
	omp) session_id=$(get_omp_session "$cpid" "$cargs" "$cwd" "") ;;
	grok) session_id=$(get_grok_session "$cpid" "$cargs") ;;
	esac

	if [ -n "$session_id" ]; then
		# Extract CLI args (flags without binary name and session/resume args)
		local cli_args
		cli_args=$(extract_cli_args "$tool" "$cargs")

		# Read enriched fields from state file (if available)
		local state_file="" model="" env_json="null"
		case "$tool" in
		claude) state_file="$STATE_DIR/claude-${cpid}.json" ;;
		opencode) state_file="$STATE_DIR/opencode-${cpid}.json" ;;
		esac

		if [ -n "$state_file" ] && [ -f "$state_file" ]; then
			model=$(jq -r '.model // empty' "$state_file" 2>/dev/null || true)
			env_json=$(jq '.env // null' "$state_file" 2>/dev/null || echo "null")
		fi

		# Fallback: parse --model from CLI args if not in state file
		if [ -z "$model" ]; then
			model=$(echo "$cargs" | sed -n 's/.*--model[= ] *\([^ ]*\).*/\1/p')
		fi

		jq -n \
			--arg pane "$target" \
			--arg tool "$tool" \
			--arg sid "$session_id" \
			--arg cwd "$cwd" \
			--arg pid "$cpid" \
			--arg model "$model" \
			--arg cli_args "$cli_args" \
			--argjson env "${env_json:-null}" \
			'{pane: $pane, tool: $tool, session_id: $sid, cwd: $cwd, pid: $pid, model: $model, cli_args: $cli_args, env: $env}' >>"$PARTS_FILE"
		case "$tool" in
		codex) register_codex_session_id "$session_id" ;;
		pi) register_pi_session_id "$session_id" ;;
		omp) register_omp_session_id "$session_id" ;;
		esac
		return 0
	else
		if [ "$log_missing" = "1" ]; then
			log "detected $tool in $target (pid $cpid) but no session ID available"
		fi
		return 1
	fi
}

# Allow sourcing this script without executing main (for unit tests).
# When sourced, only functions and variables are defined.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
	main "$@"
fi
