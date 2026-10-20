#!/bin/bash
# Shared helpers: which app bundle is the user's "daily" WhisperShortcut instance.
# Sourced by rebuild-and-restart.sh, run-tests.sh and ensure-app-running.sh, so that after any of
# them stops the app, the same bundle the user was running comes back (not whatever build the
# calling script happens to know about).

DAILY_APP_FILE="$HOME/Library/Caches/whispershortcut-dev/daily-app"

# Record the bundle the user's own instance runs from. Skips sidecars (--sidecar) and anything
# under a worktree. Writes nothing when no such instance is running.
record_daily_app() {
  local name pid cmd app=""
  for name in "WhisperShortcut Dev" WhisperShortcut WhisperShortcut-AppStore; do
    for pid in $(pgrep -x "$name" 2>/dev/null || true); do
      cmd=$(ps -o command= -p "$pid" 2>/dev/null || true)
      [[ -z "$cmd" || "$cmd" == *"--sidecar"* || "$cmd" == *"/.claude/worktrees/"* ]] && continue
      [[ "$cmd" == *.app/Contents/MacOS/* ]] || continue
      app="${cmd%%.app/Contents/MacOS/*}.app"
      break 2
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
