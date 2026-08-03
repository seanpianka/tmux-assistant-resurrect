#!/usr/bin/env bash

# Codex session identity helpers. A Codex process can hold rollout files for
# both its user-visible parent thread and internal subagents. Exact restore is
# safe only when process-owned rollout evidence identifies the parent, or when
# an explicitly resumed direct child is the process's sole open rollout.

codex_thread_kind_from_id() {
	local sid="$1"
	[ -n "$sid" ] || return 0
	command -v python3 >/dev/null 2>&1 || return 0
	python3 - "$HOME/.codex" "$sid" <<'PY'
import glob, json, os, sqlite3, sys

root, wanted = sys.argv[1:]

def kind(thread_source, source):
    ts = (thread_source or "").lower()
    src = (source if isinstance(source, str) else json.dumps(source or {})).lower()
    if "guardian" in src:
        return "guardian"
    if ts == "subagent" or "subagent" in src:
        try:
            data = json.loads(source) if isinstance(source, str) else (source or {})
            depth = ((data.get("subagent") or {}).get("thread_spawn") or {}).get("depth")
        except Exception:
            depth = None
        return "subagent" if depth == 1 else "nested_subagent"
    if ts == "user" or src in {"cli", "vscode", "appserver", "app_server", "codex_cli_rs"}:
        return "parent"
    return "unknown"

dbs = sorted(glob.glob(os.path.join(root, "state_*.sqlite")), key=os.path.getmtime, reverse=True)
for db in dbs[:1]:
    try:
        con = sqlite3.connect("file:" + db + "?mode=ro", uri=True)
        cols = {row[1] for row in con.execute("pragma table_info(threads)")}
        ts = "thread_source" if "thread_source" in cols else "NULL"
        row = con.execute(f"select {ts}, source, cwd from threads where id = ?", (wanted,)).fetchone()
        con.close()
        if row:
            print(kind(row[0], row[1]) + "\x1f" + (row[2] or ""))
            sys.exit(0)
    except Exception:
        pass

for base, _, files in os.walk(os.path.join(root, "sessions")):
    for name in files:
        if not name.endswith(".jsonl") or wanted not in name:
            continue
        try:
            with open(os.path.join(base, name), encoding="utf-8") as f:
                record = json.loads(f.readline())
            payload = record.get("payload") or {}
            if record.get("type") == "session_meta" and payload.get("id") == wanted:
                print(kind(payload.get("thread_source"), payload.get("source") or payload.get("originator")) + "\x1f" + (payload.get("cwd") or ""))
                sys.exit(0)
        except Exception:
            pass
PY
}

codex_unique_parent_for_cwd() {
	local cwd="$1"
	[ -n "$cwd" ] || return 0
	command -v python3 >/dev/null 2>&1 || return 0
	python3 - "$HOME/.codex" "$cwd" <<'PY'
import glob, json, os, sqlite3, sys
root, cwd = sys.argv[1:]
dbs = sorted(glob.glob(os.path.join(root, "state_*.sqlite")), key=os.path.getmtime, reverse=True)
parents = []
if dbs:
    try:
        con = sqlite3.connect("file:" + dbs[0] + "?mode=ro", uri=True)
        cols = {row[1] for row in con.execute("pragma table_info(threads)")}
        ts = "thread_source" if "thread_source" in cols else "NULL"
        rows = con.execute(f"select id, {ts}, source from threads where cwd = ? and archived = 0", (cwd,)).fetchall()
        con.close()
        for sid, thread_source, source in rows:
            t = (thread_source or "").lower()
            s = (source or "").lower()
            if t == "user" or s in {"cli", "vscode", "appserver", "app_server", "codex_cli_rs"}:
                parents.append(sid)
    except Exception:
        pass
if not parents:
    for base, _, files in os.walk(os.path.join(root, "sessions")):
        for name in files:
            if not name.endswith(".jsonl"):
                continue
            try:
                with open(os.path.join(base, name), encoding="utf-8") as f:
                    record = json.loads(f.readline())
                payload = record.get("payload") or {}
                source = str(payload.get("source") or payload.get("originator") or "").lower()
                if record.get("type") == "session_meta" and payload.get("cwd") == cwd and source in {"cli", "vscode", "appserver", "app_server", "codex_cli_rs"}:
                    parents.append(payload.get("id"))
            except Exception:
                pass
parents = list(dict.fromkeys(p for p in parents if p))
if len(parents) == 1:
    print(parents[0])
PY
}

# Build one process-owned rollout snapshot for every Codex PID in MATCHES.
# Linux reads /proc directly; macOS invokes lsof once for the complete PID set.
# Output: pid<US>thread_id<US>thread_kind<US>cwd.
codex_prepare_rollout_cache() {
	local matches="$1" raw_file="$2" cache_file="$3"
	: >"$raw_file"
	: >"$cache_file"
	local pids pid fd path pid_csv=""
	pids=$(printf '%s\n' "$matches" | awk -F '\t' '$2 == "codex" {print $3}' | sort -u)
	[ -n "$pids" ] || return 0

	if [ -d /proc ]; then
		for pid in $pids; do
			for fd in /proc/"$pid"/fd/*; do
				[ -e "$fd" ] || continue
				path=$(readlink "$fd" 2>/dev/null || true)
				case "$path" in
				*'/.codex/sessions/'*.jsonl) printf '%s\t%s\n' "$pid" "$path" >>"$raw_file" ;;
				esac
			done
		done
	elif command -v lsof >/dev/null 2>&1; then
		for pid in $pids; do
			[ -n "$pid_csv" ] && pid_csv="${pid_csv},"
			pid_csv="${pid_csv}${pid}"
		done
		lsof -a -p "$pid_csv" -Fn 2>/dev/null | awk '
			/^p[0-9]+$/ { pid=substr($0,2); next }
			/^n/ && /\/\.codex\/sessions\/.*\.jsonl$/ { print pid "\t" substr($0,2) }
		' >>"$raw_file" || true
	fi

	[ -s "$raw_file" ] || return 0
	command -v python3 >/dev/null 2>&1 || return 0
	python3 - "$HOME/.codex" "$raw_file" "$cache_file" <<'PY'
import glob, json, os, sqlite3, sys

root, raw_path, out_path = sys.argv[1:]

def kind(thread_source, source):
    ts = (thread_source or "").lower()
    src = (source if isinstance(source, str) else json.dumps(source or {})).lower()
    if "guardian" in src:
        return "guardian"
    if ts == "subagent" or "subagent" in src:
        try:
            data = json.loads(source) if isinstance(source, str) else (source or {})
            depth = ((data.get("subagent") or {}).get("thread_spawn") or {}).get("depth")
        except Exception:
            depth = None
        return "subagent" if depth == 1 else "nested_subagent"
    if ts == "user" or src in {"cli", "vscode", "appserver", "app_server", "codex_cli_rs"}:
        return "parent"
    return "unknown"

by_path, by_id = {}, {}
dbs = sorted(glob.glob(os.path.join(root, "state_*.sqlite")), key=os.path.getmtime, reverse=True)
if dbs:
    try:
        con = sqlite3.connect("file:" + dbs[0] + "?mode=ro", uri=True)
        cols = {row[1] for row in con.execute("pragma table_info(threads)")}
        ts = "thread_source" if "thread_source" in cols else "NULL"
        for sid, rollout, thread_source, source, cwd in con.execute(f"select id, rollout_path, {ts}, source, cwd from threads"):
            item = (sid, kind(thread_source, source), cwd or "")
            by_id[sid] = item
            if rollout:
                by_path[os.path.realpath(rollout)] = item
        con.close()
    except Exception:
        pass

seen, output = set(), []
with open(raw_path, encoding="utf-8") as raw:
    for line in raw:
        try:
            pid, path = line.rstrip("\n").split("\t", 1)
        except ValueError:
            continue
        item = by_path.get(os.path.realpath(path))
        if not item:
            try:
                with open(path, encoding="utf-8") as f:
                    record = json.loads(f.readline())
                payload = record.get("payload") or {}
                sid = payload.get("id")
                if record.get("type") == "session_meta" and sid:
                    item = by_id.get(sid) or (sid, kind(payload.get("thread_source"), payload.get("source") or payload.get("originator")), payload.get("cwd") or "")
            except Exception:
                pass
        if item and (pid, item[0]) not in seen:
            seen.add((pid, item[0]))
            output.append((pid,) + item)
with open(out_path, "w", encoding="utf-8") as out:
    for row in output:
        out.write("\x1f".join(row) + "\n")
PY
}

codex_previous_parent_for_pane() {
	local pane="$1" sidecar="$2"
	[ -n "$pane" ] && [ -f "$sidecar" ] || return 0
	jq -r --arg pane "$pane" '
		.sessions[]? | select(.pane == $pane and .tool == "codex" and
			.restore_mode == "exact" and .thread_kind == "parent") | .session_id
	' "$sidecar" 2>/dev/null | head -1
}

codex_resume_arg() {
	printf '%s\n' "$1" | sed -n 's/.*resume  *\([A-Za-z0-9_-]*\).*/\1/p'
}

# Output: session_id<US>restore_mode<US>thread_kind.
codex_resolve_session() {
	local child_pid="$1" args="$2" cwd="${3:-}" pane="${4:-}" us=$'\x1f'
	local explicit_id parent_count=0 total_count=0 only_id="" only_kind="" sid kind _owned_cwd
	explicit_id=$(codex_resume_arg "$args")

	if [ -n "${CODEX_ROLLOUT_CACHE_FILE:-}" ] && [ -s "$CODEX_ROLLOUT_CACHE_FILE" ]; then
		while IFS="$us" read -r _pid sid kind _owned_cwd; do
			[ "$_pid" = "$child_pid" ] || continue
			total_count=$((total_count + 1))
			only_id="$sid"
			only_kind="$kind"
			[ "$kind" = "parent" ] && parent_count=$((parent_count + 1))
		done <"$CODEX_ROLLOUT_CACHE_FILE"

		if [ "$parent_count" -eq 1 ]; then
			while IFS="$us" read -r _pid sid kind _owned_cwd; do
				[ "$_pid" = "$child_pid" ] && [ "$kind" = "parent" ] && printf '%s%s%s%s%s\n' "$sid" "$us" exact "$us" parent && return
			done <"$CODEX_ROLLOUT_CACHE_FILE"
		elif [ "$parent_count" -gt 1 ] && [ -n "$explicit_id" ]; then
			while IFS="$us" read -r _pid sid kind _owned_cwd; do
				[ "$_pid" = "$child_pid" ] && [ "$kind" = "parent" ] && [ "$sid" = "$explicit_id" ] && printf '%s%s%s%s%s\n' "$sid" "$us" exact "$us" parent && return
			done <"$CODEX_ROLLOUT_CACHE_FILE"
		fi

		# A sole process-owned subagent is resumable only when the running
		# command explicitly names that same thread.
		if [ "$total_count" -eq 1 ] && [ "$only_kind" = "subagent" ] && [ -n "$explicit_id" ] && [ "$explicit_id" = "$only_id" ]; then
			printf '%s%s%s%s%s\n' "$only_id" "$us" exact "$us" subagent
			return
		fi
	fi

	local tags_file="$HOME/.codex/session-tags.jsonl" tagged="" record=""
	if [ -f "$tags_file" ]; then
		tagged=$(grep "\"pid\": *${child_pid}[,}]" "$tags_file" 2>/dev/null | tail -1 | jq -r '.session // empty' 2>/dev/null || true)
	fi
	if [ -n "$tagged" ]; then
		record=$(codex_thread_kind_from_id "$tagged")
		kind="${record%%"$us"*}"
		if [ "$kind" = "parent" ]; then
			printf '%s%s%s%s%s\n' "$tagged" "$us" exact "$us" parent
			return
		fi
	fi

	if [ -n "$explicit_id" ]; then
		record=$(codex_thread_kind_from_id "$explicit_id")
		kind="${record%%"$us"*}"
		if [ "$kind" = "parent" ]; then
			printf '%s%s%s%s%s\n' "$explicit_id" "$us" exact "$us" parent
			return
		fi
	fi

	local previous=""
	previous=$(codex_previous_parent_for_pane "$pane" "${CODEX_PREVIOUS_SIDECAR:-}")
	if [ -n "$previous" ]; then
		printf '%s%s%s%s%s\n' "$previous" "$us" exact "$us" parent
		return
	fi

	sid=$(codex_unique_parent_for_cwd "$cwd")
	if [ -n "$sid" ]; then
		printf '%s%s%s%s%s\n' "$sid" "$us" exact "$us" parent
		return
	fi

	printf '%s%s%s%s%s\n' "" "$us" picker "$us" unknown
}
