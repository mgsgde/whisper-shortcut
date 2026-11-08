#!/bin/bash
# The always-running "daily Dev instance".
#
#   bash scripts/dev-daily.sh status|update|install|use-dev|use-release
#
# A Debug build ("WhisperShortcut Dev", com.magnusgoedde.whispershortcut.dev) is installed at
# ~/Applications/WhisperShortcut Dev.app and used like the release (hotkeys, Fn key, MCP). The
# launchd job com.whispershortcut.dev-daily runs `update` every 10 minutes: it fetches origin/main,
# builds it in a detached worktree (build/dev-daily/src, via rebuild-and-restart.sh --build-only),
# stages the product and swaps it into place. A running Dev instance is only replaced when no
# meeting records (meeting-guard.sh --dev-only) and the user has been idle for 90 s. A build that
# does not survive 20 s after launch is rolled back and its SHA is remembered in bad-sha.
# `use-dev` / `use-release` swap which instance is live (guarded against live meetings); the app
# menu does the same through DailyInstanceSwitcher.swift. The dev scripts never kill the daily Dev
# app (is_protected_cmd in lib/daily-app.sh); only this script does, on purpose.
# State (gitignored via build/): build/dev-daily/{installed-sha,staged-sha,bad-sha,staged.app,
# previous.app,src,lock}. Log: build/logs/dev-daily.log.
set -uo pipefail
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

# Main checkout. `git worktree list | head -1` is the bare git dir (.../.git/modules/...) in a
# submodule, so ask the common git dir where its work tree is (core.worktree, relative to it);
# a plain repo falls back to the first listed worktree.
_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_common="$(git -C "$_here" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
_wt="$(git --git-dir="$_common" config --get core.worktree 2>/dev/null || true)"
if [[ -n "$_wt" ]]; then
  MAIN_ROOT="$(cd "$_common" && cd "$_wt" && pwd)"
else
  MAIN_ROOT="$(git -C "$_here" worktree list --porcelain 2>/dev/null | awk '/^worktree /{sub(/^worktree /,""); print; exit}')"
fi
if [[ -z "$MAIN_ROOT" ]]; then echo "dev-daily: cannot resolve the main checkout" >&2; exit 1; fi
STATE="$MAIN_ROOT/build/dev-daily"
SRC="$STATE/src"
LABEL="com.whispershortcut.dev-daily"
LOG="$MAIN_ROOT/build/logs/dev-daily.log"
RELEASE_ID="com.magnusgoedde.whispershortcut"
RELEASE_APP="/Applications/WhisperShortcut.app"
# shellcheck source=lib/daily-app.sh
source "$_here/lib/daily-app.sh"
mkdir -p "$STATE" "$MAIN_ROOT/build/logs"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') dev-daily: $*"; }
notify() { osascript -e "display notification \"$1\" with title \"WhisperShortcut Dev\"" >/dev/null 2>&1 || true; }
read_state() { [[ -r "$STATE/$1" ]] && head -n1 "$STATE/$1" || true; }
short() { echo "${1:0:8}"; }
origin_sha() { git -C "$MAIN_ROOT" ls-remote origin main 2>/dev/null | awk '{print $1; exit}'; }

daily_dev_pids() {
  local pid cmd
  for pid in $(pgrep -f "^$DEV_DAILY_APP/Contents/MacOS/" 2>/dev/null || true); do
    cmd=$(ps -o command= -p "$pid" 2>/dev/null || true)
    [[ "$cmd" == "$DEV_DAILY_APP/Contents/MacOS/"* ]] && echo "$pid"
  done
}
release_pids() {
  local pid cmd
  for pid in $(pgrep -f "^$RELEASE_APP/Contents/MacOS/" 2>/dev/null || true); do
    cmd=$(ps -o command= -p "$pid" 2>/dev/null || true)
    [[ "$cmd" == *" --mcp-stdio"* ]] && continue
    echo "$pid"
  done
}

# SIGTERM the daily Dev pids, wait up to 10 s, SIGKILL leftovers.
stop_daily_dev() {
  local pids pid alive
  pids=$(daily_dev_pids | tr '\n' ' ')
  [[ -z "${pids// }" ]] && return 0
  log "SIGTERM daily dev pid(s) $pids"
  for pid in $pids; do kill "$pid" 2>/dev/null || true; done
  for _ in $(seq 1 10); do
    sleep 1
    alive=""
    for pid in $pids; do kill -0 "$pid" 2>/dev/null && alive+="$pid "; done
    [[ -z "$alive" ]] && return 0
  done
  log "still alive after 10s, SIGKILL $alive"
  for pid in $alive; do kill -9 "$pid" 2>/dev/null || true; done
  sleep 1
}

acquire_lock() {
  if ! mkdir "$STATE/lock" 2>/dev/null; then
    local old; old=$(cat "$STATE/lock/pid" 2>/dev/null || true)
    if [[ -n "$old" ]] && kill -0 "$old" 2>/dev/null; then
      log "another run holds the lock (pid $old), exiting"
      return 1
    fi
    log "breaking stale lock (pid ${old:-?})"
    rm -rf "$STATE/lock"
    mkdir "$STATE/lock" 2>/dev/null || return 1
  fi
  echo $$ > "$STATE/lock/pid"
  trap 'rm -rf "$STATE/lock"' EXIT
}

# build_target SHA: stage a build of SHA into $STATE/staged.app (skips when already staged).
build_target() {
  local target="$1" product
  if [[ "$(read_state staged-sha)" == "$target" && -d "$STATE/staged.app" ]]; then
    log "staged build for $(short "$target") already present"
    return 0
  fi
  if [[ ! -d "$SRC/.git" && ! -f "$SRC/.git" ]]; then
    log "creating source worktree at $SRC"
    rm -rf "$SRC"
    git -C "$MAIN_ROOT" worktree add --detach "$SRC" "$target" >/dev/null 2>&1 \
      || git -C "$MAIN_ROOT" worktree add --detach "$SRC" origin/main >/dev/null 2>&1 \
      || { log "worktree add failed"; return 1; }
  fi
  git -C "$SRC" checkout -q --detach -f "$target" || { log "checkout of $(short "$target") failed"; return 1; }
  log "building $(short "$target")"
  if ! bash "$SRC/scripts/rebuild-and-restart.sh" --build-only; then
    log "build failed on $(short "$target")"
    return 1
  fi
  product="$SRC/build/DerivedData/Build/Products/Debug/WhisperShortcut Dev.app"
  rm -rf "$STATE/staged.app"
  ditto "$product" "$STATE/staged.app" || { log "ditto of staged build failed"; return 1; }
  echo "$target" > "$STATE/staged-sha"
  log "staged $(short "$target")"
}

# install_staged SHA: previous.app <- installed app, installed app <- staged.app.
install_staged() {
  local target="$1"
  rm -rf "$STATE/previous.app"
  [[ -d "$DEV_DAILY_APP" ]] && mv "$DEV_DAILY_APP" "$STATE/previous.app"
  mkdir -p "$HOME/Applications"
  ditto "$STATE/staged.app" "$DEV_DAILY_APP" || { log "install failed"; return 1; }
  echo "$target" > "$STATE/installed-sha"
  log "installed $(short "$target") at $DEV_DAILY_APP"
}

cmd_status() {
  local dp rp
  dp=$(daily_dev_pids | tr '\n' ' '); rp=$(release_pids | tr '\n' ' ')
  if [[ -n "${dp// }" ]]; then echo "running:      daily dev (pid ${dp% })"
  elif [[ -n "${rp// }" ]]; then echo "running:      release (pid ${rp% })"
  else echo "running:      none"; fi
  echo "installed:    $(read_state installed-sha || true)"
  echo "staged:       $(read_state staged-sha || true)"
  echo "origin/main:  $(origin_sha)"
  echo "bad shas:     $(cat "$STATE/bad-sha" 2>/dev/null | tr '\n' ' ')"
  launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1
  if [[ $? -eq 0 ]]; then echo "launchd:      loaded"; else echo "launchd:      not loaded"; fi
  echo "log:          $LOG"
  return 0
}

cmd_update() {
  acquire_lock || exit 0
  git -C "$MAIN_ROOT" fetch -q origin main || { log "fetch failed"; exit 1; }
  local target installed was_running=false old_installed idle
  target=$(git -C "$MAIN_ROOT" rev-parse origin/main 2>/dev/null) || { log "cannot resolve origin/main"; exit 1; }
  installed=$(read_state installed-sha)
  [[ "$target" == "$installed" ]] && exit 0
  if grep -qx "$target" "$STATE/bad-sha" 2>/dev/null; then exit 0; fi

  if ! build_target "$target"; then
    if [[ "$(read_state notified-sha)" != "$target" ]]; then
      notify "Dev build failed on $(short "$target")"
      echo "$target" > "$STATE/notified-sha"
    fi
    echo "$target" >> "$STATE/bad-sha"
    exit 1
  fi

  if daily_dev_running; then
    was_running=true
    if ! bash "$MAIN_ROOT/scripts/meeting-guard.sh" --dev-only >/dev/null 2>&1; then
      log "meeting recording, deferring swap to $(short "$target")"; exit 0
    fi
    idle=$(ioreg -c IOHIDSystem | awk '/HIDIdleTime/ {print int($NF/1000000000); exit}')
    if [[ "${idle:-0}" -lt 90 ]]; then
      log "user active (idle ${idle:-?}s), deferring swap to $(short "$target")"; exit 0
    fi
    stop_daily_dev
  fi

  old_installed="$installed"
  install_staged "$target" || exit 1
  [[ "$was_running" == true ]] || { log "daily dev not running, installed without launching"; exit 0; }

  log "launching $(short "$target")"
  open -n "$DEV_DAILY_APP"
  sleep 20
  if daily_dev_running; then
    notify "WhisperShortcut Dev updated: $(git -C "$MAIN_ROOT" log -1 --format=%s "$target")"
    log "updated to $(short "$target")"
  else
    log "new build died on launch, restoring previous"
    if [[ -d "$STATE/previous.app" ]]; then
      rm -rf "$DEV_DAILY_APP"
      ditto "$STATE/previous.app" "$DEV_DAILY_APP" && open -n "$DEV_DAILY_APP"
    fi
    echo "$target" >> "$STATE/bad-sha"
    if [[ -n "$old_installed" ]]; then echo "$old_installed" > "$STATE/installed-sha"; else rm -f "$STATE/installed-sha"; fi
    notify "Dev build $(short "$target") crashed on launch — back to the previous one"
  fi
}

cmd_install() {
  acquire_lock || exit 1
  git -C "$MAIN_ROOT" fetch -q origin main || { log "fetch failed"; exit 1; }
  local target
  target=$(git -C "$MAIN_ROOT" rev-parse origin/main) || exit 1
  build_target "$target" || exit 1
  install_staged "$target" || exit 1
  local plist="$HOME/Library/LaunchAgents/$LABEL.plist"
  mkdir -p "$HOME/Library/LaunchAgents"
  sed "s#__MAIN_ROOT__#$MAIN_ROOT#g" "$MAIN_ROOT/scripts/com.whispershortcut.dev-daily.plist" > "$plist"
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$plist" || { log "launchctl bootstrap failed"; exit 1; }
  log "launchd job loaded"
  cat <<MSG
Next steps:
  1. bash scripts/copy-release-data-to-dev.sh      (once, copies settings/history)
  2. scripts/dev-daily.sh use-dev                   (switch to the daily Dev instance)
  3. Re-enter your API keys in the Dev app (separate keychain).
MSG
}

cmd_use_dev() {
  bash "$MAIN_ROOT/scripts/meeting-guard.sh" || { echo "Refusing: a meeting is recording." >&2; exit 1; }
  [[ -d "$DEV_DAILY_APP" ]] || { echo "No daily Dev app installed; run dev-daily.sh install." >&2; exit 1; }
  if [[ -n "$(release_pids)" ]]; then
    osascript -e "tell application id \"$RELEASE_ID\" to quit"
    for _ in $(seq 1 50); do [[ -z "$(release_pids)" ]] && break; sleep 0.2; done
    if [[ -n "$(release_pids)" ]]; then echo "The release did not quit within 10 s; aborting." >&2; exit 1; fi
  fi
  open -n "$DEV_DAILY_APP" --args --takeover
}

cmd_use_release() {
  bash "$MAIN_ROOT/scripts/meeting-guard.sh" || { echo "Refusing: a meeting is recording." >&2; exit 1; }
  stop_daily_dev
  open "$RELEASE_APP"
}

case "${1:-}" in
  status) cmd_status ;;
  update) cmd_update ;;
  install) cmd_install ;;
  use-dev) cmd_use_dev ;;
  use-release) cmd_use_release ;;
  *) echo "usage: dev-daily.sh status|update|install|use-dev|use-release" >&2; exit 2 ;;
esac
