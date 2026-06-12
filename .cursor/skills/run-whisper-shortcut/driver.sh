#!/bin/bash
# WhisperShortcut driver — launch and drive the macOS menu-bar app, take screenshots.
#
# WhisperShortcut is an LSUIElement (menu-bar-only, no Dock icon) app. There is no
# main window — every surface is reached through the status-item menu. This driver
# wraps `osascript` (System Events / Accessibility) to open the menu and click items,
# and `screencapture` to save PNGs.
#
# PERMISSIONS (one-time, granted to the *terminal app* that runs this — Terminal,
# iTerm, VS Code, Cursor, …): System Settings ▸ Privacy & Security ▸
#   • Accessibility   (so System Events can click the menu)   — REQUIRED
#   • Screen Recording (so screencapture can read the display) — REQUIRED for screenshots
# Without Accessibility, osascript clicks silently no-op. Without Screen Recording,
# screencapture prints "could not create image from display".
#
# Usage:
#   bash driver.sh build              # rebuild + relaunch (scripts/rebuild-and-restart.sh)
#   bash driver.sh ensure             # launch the already-built app if not running
#   bash driver.sh items              # print the status-menu item names
#   bash driver.sh menu [name]        # open the status menu and screenshot it
#   bash driver.sh open <MenuItem>    # click a status-menu item (e.g. Configure, Chat)
#   bash driver.sh shot <MenuItem> [name]  # open that item's window, then screenshot it
#   bash driver.sh ss [name]          # screenshot front WS window (cropped) or full screen
#   bash driver.sh close              # close the front WS window
#   bash driver.sh quit               # quit the app
#
# Menu items: Dictate, Dictate Prompt, Screenshot, Read Aloud, Chat, Configure, Quit WhisperShortcut
# ("Configure" opens Settings; its window is titled "Settings". "Chat" opens the chat window.)
#
# Screenshots land in $WS_SHOT_DIR (default /tmp). `shot Configure settings` → /tmp/ws-settings.png

set -euo pipefail

APP="WhisperShortcut"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"   # .claude/skills/run-whisper-shortcut → project root
APP_PATH="$PROJECT_DIR/build/DerivedData/Build/Products/Debug/$APP.app"
SHOT_DIR="${WS_SHOT_DIR:-/tmp}"

is_running() { pgrep -x "$APP" >/dev/null 2>&1; }

require_running() {
  if ! is_running; then
    echo "❌ $APP is not running. Run: bash driver.sh build   (or: bash driver.sh ensure)" >&2
    exit 1
  fi
}

# Open the status menu (leaves it open).
open_menu() {
  osascript -e "tell application \"System Events\" to tell process \"$APP\" to click menu bar item 1 of menu bar 2" >/dev/null
  sleep 0.4
}

# Dismiss any open menu (Escape).
dismiss() { osascript -e 'tell application "System Events" to key code 53' >/dev/null 2>&1 || true; }

# Click a status-menu item by exact name.
click_item() {
  local name="$1"
  osascript -e "tell application \"System Events\" to tell process \"$APP\"
    click menu bar item 1 of menu bar 2
    delay 0.3
    click menu item \"$name\" of menu 1 of menu bar item 1 of menu bar 2
  end tell" >/dev/null
}

# Echo "x y w h" of the front WS window in screen points, or nothing if no window.
front_window_bounds() {
  osascript <<EOF 2>/dev/null || true
tell application "System Events" to tell process "$APP"
  if (count of windows) is 0 then return ""
  set p to position of window 1
  set s to size of window 1
  return ((item 1 of p) as text) & " " & ((item 2 of p) as text) & " " & ((item 1 of s) as text) & " " & ((item 2 of s) as text)
end tell
EOF
}

# Screenshot: crop to the front WS window if there is one, else full screen.
shoot() {
  local out="$SHOT_DIR/ws-${1:-shot}.png"
  local b; b="$(front_window_bounds)"
  if [[ -n "$b" ]]; then
    # shellcheck disable=SC2086
    set -- $b
    screencapture -x -R"$1,$2,$3,$4" "$out"
  else
    screencapture -x "$out"
  fi
  echo "$out"
}

cmd="${1:-}"; shift || true
case "$cmd" in
  build)
    bash "$PROJECT_DIR/scripts/rebuild-and-restart.sh" "$@"
    ;;
  ensure)
    if is_running; then echo "already running"; else open "$APP_PATH"; sleep 2; echo "launched"; fi
    ;;
  items)
    require_running
    osascript -e "tell application \"System Events\" to tell process \"$APP\"
      click menu bar item 1 of menu bar 2
      delay 0.3
      set ns to name of menu items of menu 1 of menu bar item 1 of menu bar 2
      key code 53
      return ns
    end tell"
    ;;
  menu)
    require_running; open_menu
    out="$SHOT_DIR/ws-${1:-menu}.png"; screencapture -x "$out"; dismiss; echo "$out"
    ;;
  open)
    require_running
    [[ -n "${1:-}" ]] || { echo "usage: open <MenuItem>" >&2; exit 1; }
    click_item "$1"; sleep 1.2; echo "opened: $1"
    ;;
  shot)
    require_running
    [[ -n "${1:-}" ]] || { echo "usage: shot <MenuItem> [name]" >&2; exit 1; }
    item="$1"; name="${2:-$(echo "$item" | tr '[:upper:] ' '[:lower:]-')}"
    click_item "$item"; sleep 1.5; shoot "$name"
    ;;
  ss)
    require_running; shoot "${1:-shot}"
    ;;
  close)
    require_running
    osascript -e "tell application \"System Events\" to tell process \"$APP\" to click button 1 of window 1" >/dev/null 2>&1 || true
    echo "closed"
    ;;
  quit)
    osascript -e "tell application \"$APP\" to quit" >/dev/null 2>&1 || pkill -x "$APP" || true
    echo "quit"
    ;;
  *)
    sed -n '2,40p' "$SCRIPT_DIR/driver.sh"
    exit 1
    ;;
esac
