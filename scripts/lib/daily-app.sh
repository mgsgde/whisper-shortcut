#!/bin/bash
# Shared helpers: which app bundle is the user's "daily" WhisperShortcut instance.
# Sourced by rebuild-and-restart.sh, run-tests.sh and ensure-app-running.sh, so that after any of
# them stops the app, the same bundle the user was running comes back (not whatever build the
# calling script happens to know about).

DAILY_APP_FILE="$HOME/Library/Caches/whispershortcut-dev/daily-app"

# The daily Dev instance (scripts/dev-daily.sh): a Debug build kept up to date from origin/main.
DEV_DAILY_APP="$HOME/Applications/WhisperShortcut Dev.app"

# Hard rule for every dev script: nothing under /Applications (the installed release) AND the
# daily Dev app (the user's real daily instance) is ever killed. Anything that stops
# WhisperShortcut goes through kill_unprotected, never a bare pkill. Only dev-daily.sh stops the
# daily Dev app, deliberately.
is_protected_cmd() {
  [[ "$1" == /Applications/* || "$1" == "$DEV_DAILY_APP/"* ]]
}

# kill_unprotected -x NAME | -f REGEX
# SIGTERM every matching process whose command line is not protected, wait up to 5s, then SIGKILL
# the survivors. Echoes one line per kill; matches under /Applications are skipped silently.
# Adds the number of processes it signalled to KILLED_COUNT (callers that must restore what they
# stopped read it; it is a global because the function is called in the caller's shell).
# (-f patterns also match the calling script's own command line when it runs from a path that
# contains the pattern: give patterns that only a launched app can match.)
kill_unprotected() {
  local mode="$1" pattern="$2" pid cmd pids=() alive=()
  for pid in $(pgrep "$mode" "$pattern" 2>/dev/null || true); do
    [[ "$pid" == "$$" ]] && continue
    cmd=$(ps -o command= -p "$pid" 2>/dev/null || true)
    [[ -z "$cmd" ]] && continue
    is_protected_cmd "$cmd" && continue
    pids+=("$pid")
    KILLED_COUNT=$(( ${KILLED_COUNT:-0} + 1 ))
    echo "  • SIGTERM → pid $pid (${cmd%%.app/Contents/MacOS/*}.app)"
    kill "$pid" 2>/dev/null || true
  done
  [[ ${#pids[@]} -eq 0 ]] && return 0
  for _ in 1 2 3 4 5; do
    sleep 1
    alive=()
    for pid in "${pids[@]}"; do kill -0 "$pid" 2>/dev/null && alive+=("$pid"); done
    [[ ${#alive[@]} -eq 0 ]] && return 0
  done
  echo "  • ⚠️  Did not quit within 5s — SIGKILL → ${alive[*]}"
  kill -9 "${alive[@]}" 2>/dev/null || true
  sleep 1
  return 0
}

# True when the installed release runs (MCP helper processes started with --mcp-stdio do not count: they own no hotkeys).
release_running() {
  local pid cmd
  for pid in $(pgrep -f "^/Applications/WhisperShortcut" 2>/dev/null || true); do
    cmd=$(ps -o command= -p "$pid" 2>/dev/null || true)
    [[ "$cmd" == *" --mcp-stdio"* ]] && continue
    [[ "$cmd" == /Applications/WhisperShortcut* ]] && return 0
  done
  return 1
}

# True when the daily Dev instance runs (--mcp-stdio helpers own no hotkeys and do not count).
daily_dev_running() {
  local pid cmd
  for pid in $(pgrep -f "^$DEV_DAILY_APP/Contents/MacOS/" 2>/dev/null || true); do
    cmd=$(ps -o command= -p "$pid" 2>/dev/null || true)
    [[ "$cmd" == *" --mcp-stdio"* ]] && continue
    [[ "$cmd" == "$DEV_DAILY_APP/Contents/MacOS/"* ]] && return 0
  done
  return 1
}

# True when the user's own instance runs, whichever flavor: the release or the daily Dev.
daily_instance_running() {
  release_running || daily_dev_running
}

# Record the bundle the user's own instance runs from: a running /Applications release wins, else
# a non-sidecar instance outside worktrees. Writes nothing when no such instance is running.
record_daily_app() {
  local name pid cmd app="" pass
  for pass in release other; do
    for name in "WhisperShortcut Dev" WhisperShortcut WhisperShortcut-AppStore; do
      for pid in $(pgrep -x "$name" 2>/dev/null || true); do
        cmd=$(ps -o command= -p "$pid" 2>/dev/null || true)
        [[ -z "$cmd" || "$cmd" == *"--sidecar"* || "$cmd" == *"/.claude/worktrees/"* ]] && continue
        [[ "$cmd" == *.app/Contents/MacOS/* ]] || continue
        [[ "$pass" == release ]] && ! is_protected_cmd "$cmd" && continue
        app="${cmd%%.app/Contents/MacOS/*}.app"
        break 3
      done
    done
  done
  if [[ -n "$app" && -d "$app" ]]; then
    mkdir -p "$(dirname "$DAILY_APP_FILE")"
    printf '%s\n' "$app" > "$DAILY_APP_FILE"
  fi
  return 0
}

# Echo the recorded daily app if it still exists outside a worktree, else $1.
daily_app_or() {
  local app=""
  [[ -r "$DAILY_APP_FILE" ]] && app="$(head -n1 "$DAILY_APP_FILE")"
  if [[ -n "$app" && -d "$app" && "$app" != *"/.claude/worktrees/"* ]]; then
    echo "$app"
  else
    echo "$1"
  fi
}
