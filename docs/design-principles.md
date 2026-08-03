# Design Principles

## Direct process detection

Agent detection uses direct process inspection rather than LLM-based
classification or screen content analysis. The save script:

1. Takes a single `ps -eo pid=,ppid=,args=` snapshot (efficient, no per-pane calls)
2. For each tmux pane, finds direct child processes of the pane's shell
3. Matches binary names via `case` patterns (`*/claude`, `*/opencode`, `*/codex`, `*/pi`, `*/omp`, `*/grok`)
4. Excludes known false positives (e.g., `opencode run ...` LSP subprocesses)

This is simple, fast, and deterministic. No API calls, no LLM costs, no
latency per pane.

## What scripts do

- Capture pane metadata from tmux (PIDs, working directories)
- Detect assistants by matching child process binary names
- Read session ID state files written by tool-native hooks/plugins
- Parse process arguments for session identifiers
- Format and write JSON output
- Send commands to tmux panes via `tmux send-keys`

## Session ID extraction

Session IDs are extracted through tool-native mechanisms -- infrastructure
plumbing, not interpretation. Each tool has a primary method and a fallback
to address the chicken-and-egg problem (session IDs may be in process args
before hooks/plugins have fired):

- **Claude Code**: `SessionStart` hook state file keyed by Claude's PID
  (primary); `--resume <id>` in process args (fallback -- note: Claude
  overwrites its process title, so this only works if args are still visible)
- **OpenCode**: `-s` / `--session` flag in process args (fast path); plugin
  state file (fallback for runtime session switches); SQLite database query
  at `~/.local/share/opencode/opencode.db` matching the pane's cwd (version-
  resilient fallback when the plugin hasn't fired)
- **Codex CLI**: open rollout descriptors owned by each Codex PID, joined to
  `~/.codex/state_*.sqlite` (primary); verified PID tags, explicit parent IDs,
  a previously verified pane parent, or a unique cwd parent (fallbacks).
  Parent rollouts outrank subagents and Guardians. Ambiguity opens the native
  picker; a direct child is exact only when it is the sole open rollout and the
  running command explicitly names it.
- **Pi**: `--session <id>` in process args (fallback); session header lookup in
  `~/.pi/agent/sessions/--<cwd>--/*.jsonl` (primary for fresh sessions)
- **Oh My Pi**: `--resume <id>` / `-r <id>` in process args (fallback);
  terminal breadcrumb lookup under `$XDG_STATE_HOME/omp` plus session JSONL
  lookup under `$XDG_DATA_HOME/omp` or `~/.omp/agent/sessions` (primary for
  fresh sessions, with `--profile` and `--session-dir` support)
- **Grok**: PID lookup in the `~/.grok/active_sessions.json` registry
  (primary); `-r <uuid>` / `--resume <uuid>` in process args (fallback). grok
  records every live interactive session (including a bare `grok` launched
  with no args) in the registry keyed by PID, so unlike the cwd-scoped
  fallbacks above, two sessions sharing a working directory never collide.
  Resume intentionally drops captured CLI args because grok reloads the
  session's own model/agent/context from disk and its prompt is a positional
  argument that must not be replayed.

## Adding a new assistant

To add support for a new tool:

1. Add a binary name pattern in `detect_tool()` (`case` statement)
2. Add a `get_<tool>_session()` function for session ID extraction
3. Add a restore command in `restore-assistant-sessions.sh`
4. Optionally add a hook/plugin if the tool doesn't expose session IDs externally

## Process title behavior

- **Claude Code** is a Node.js script that overwrites its process title via
  `process.title = 'claude'`. This means `--resume <id>` is NOT visible in
  `ps` output -- the state file from the `SessionStart` hook is the only
  reliable source of session IDs for Claude.
- **Codex CLI** may expose a resume ID in `ps`, but that alone is insufficient
  for a subagent. `lib-codex-session.sh` verifies process-owned rollouts and
  classifies `threads.thread_source` / `threads.source` before exact restore.
- **OpenCode** is a native Go binary (distributed via npm as `opencode-ai`
  or installed via `opencode upgrade`). Like Claude, the Go binary overwrites
  its process title, so `-s <id>` is NOT visible in `ps`. The plugin state
  file and SQLite database fallback are the reliable sources of session IDs.
- **Pi** stores sessions as JSONL files under `~/.pi/agent/sessions` keyed by
  encoded cwd. Session IDs are in the header line (`type: "session"`, `id`).
  Process args remain a useful fallback when launched with `--session`.
- **Oh My Pi** stores terminal breadcrumbs and JSONL session files under XDG
  directories when present, falling back to `~/.omp`. Session IDs are in the
  JSONL header; process args remain useful after restore via `--resume` / `-r`.

## macOS considerations

- `pgrep -P` is unreliable on macOS (silently misses children). Always use
  `ps -eo pid=,ppid=` with awk filtering instead.
- tmux 3.4 converts tab characters to underscores in `-F` format output. The
  save script uses pipe `|` as the delimiter instead.
