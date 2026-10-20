#!/bin/bash
# Copy the installed release's settings and history into the Debug build's own container — once,
# and only when you ask for it.
#
# The local Debug build runs as "WhisperShortcut Dev" (bundle com.magnusgoedde.whispershortcut.dev)
# so macOS TCC and the keychain never mix it up with the /Applications release. The price is a
# separate sandbox container: the dev app starts empty. This script clones the release's data
# into it:
#
#   Library/Application Support/WhisperShortcut  context files, history, meetings, local models
#   Library/Application Support/FluidAudio       offline ASR models
#   Documents                                    model downloads, meeting audio
#   Library/Preferences/<bundle>.plist           all settings (UserDefaults), renamed for .dev
#
# Files are APFS clones (cp -c): instant, and they take no extra disk until one side changes.
# macOS App Data protection may ask once whether your terminal may access data from other apps;
# answer Allow, or the copy fails with "Operation not permitted".
#
# NOT copied: API keys. They live in the keychain under each build's own access group
# (TeamID.<bundle id>), which the dev app cannot read. Re-enter them once in the dev app's
# Settings.
#
# Usage:
#   bash scripts/copy-release-data-to-dev.sh            # refuses if the dev app already has data
#   bash scripts/copy-release-data-to-dev.sh --force    # overwrite the dev app's data

set -euo pipefail

RELEASE_ID="com.magnusgoedde.whispershortcut"
DEV_ID="com.magnusgoedde.whispershortcut.dev"
SRC="$HOME/Library/Containers/$RELEASE_ID/Data"
DST="$HOME/Library/Containers/$DEV_ID/Data"

FORCE=false
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=true ;;
    -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
    *) echo "copy-release-data-to-dev: unknown argument $arg" >&2; exit 2 ;;
  esac
done

[[ -d "$SRC" ]] || { echo "❌ No release data at $SRC — nothing to copy." >&2; exit 1; }

# macOS creates (and registers) a sandbox container on first launch; a directory we create by
# hand is not a valid container. So the dev app has to have run once.
if [[ ! -d "$DST/Library" ]]; then
  echo "❌ The dev app has no container yet. Launch it once (bash scripts/rebuild-and-restart.sh)," >&2
  echo "   then run this script again." >&2
  exit 1
fi

# A first launch alone leaves only onboarding state behind; a finished onboarding means the dev
# app has been set up and used, and its data is worth not overwriting by accident.
DEV_ONBOARDED=$(defaults read "$DST/Library/Preferences/$DEV_ID" hasCompletedOnboarding 2>/dev/null || echo 0)
if [[ "$DEV_ONBOARDED" == "1" && "$FORCE" != true ]]; then
  echo "❌ The dev app is already set up with its own data in $DST." >&2
  echo "   Rerun with --force to replace it with the release's data." >&2
  exit 1
fi

# Both apps must be stopped: the release could write while we copy, and the dev app would
# overwrite the copied preferences from its in-memory state on quit.
bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/meeting-guard.sh" || exit 1
# This is the one script that quits the /Applications release on purpose (you run it by hand).
# It remembers every bundle it quits and opens them again at the end.
echo "ℹ️  Running apps are quit for the copy and relaunched afterwards."
RESTART_APPS=()
for name in "WhisperShortcut Dev" WhisperShortcut WhisperShortcut-AppStore; do
  for pid in $(pgrep -x "$name" 2>/dev/null || true); do
    cmd=$(ps -o command= -p "$pid" 2>/dev/null || true)
    [[ "$cmd" == *.app/Contents/MacOS/* ]] && RESTART_APPS+=("${cmd%%.app/Contents/MacOS/*}.app")
  done
  if pgrep -x "$name" >/dev/null 2>&1; then
    echo "• Quitting $name"
    osascript -e "tell application \"$name\" to quit" >/dev/null 2>&1 || pkill -x "$name" || true
  fi
done
sleep 2
for name in "WhisperShortcut Dev" WhisperShortcut WhisperShortcut-AppStore; do
  if pgrep -x "$name" >/dev/null 2>&1; then
    echo "❌ $name is still running — quit it and try again." >&2
    exit 1
  fi
done

# Runs on every exit after the quit above, so a failed copy does not leave you without your app.
restart_quit_apps() {
  local app
  [[ ${#RESTART_APPS[@]} -gt 0 ]] || return 0
  while IFS= read -r app; do
    [[ -d "$app" ]] || continue
    echo "🚀 Relaunching $app"
    open -n "$app" || echo "⚠️  could not relaunch $app" >&2
  done < <(printf '%s\n' "${RESTART_APPS[@]}" | sort -u)
}
trap restart_quit_apps EXIT

clone_dir() { # clone_dir <path relative to Data>
  local rel="$1"
  [[ -d "$SRC/$rel" ]] || { echo "  – $rel (not in release, skipped)"; return 0; }
  rm -rf "${DST:?}/$rel"
  mkdir -p "$(dirname "$DST/$rel")"
  cp -cRp "$SRC/$rel" "$DST/$rel"
  echo "  ✓ $rel"
}

echo "📦 Cloning release data into the dev container…"
clone_dir "Library/Application Support/WhisperShortcut"
clone_dir "Library/Application Support/FluidAudio"
clone_dir "Documents"

# Preferences go through cfprefsd (defaults export/import), not cp: it caches domains, and a
# plist copied behind its back can be silently overwritten by the stale cached copy.
SRC_PREFS="$SRC/Library/Preferences/$RELEASE_ID"
DST_PREFS="$DST/Library/Preferences/$DEV_ID"
if [[ -f "$SRC_PREFS.plist" ]]; then
  mkdir -p "$(dirname "$DST_PREFS")"
  defaults export "$SRC_PREFS" - | defaults import "$DST_PREFS" -
  echo "  ✓ Library/Preferences/$DEV_ID.plist (from $RELEASE_ID.plist)"
else
  echo "  – no release preferences found, skipped"
fi

echo ""
echo "✅ Done. Start the dev app with: bash scripts/rebuild-and-restart.sh (apps quit above are relaunched now)"
echo "   API keys were NOT copied (the keychain keeps them per build) — re-enter them once in"
echo "   WhisperShortcut Dev → Settings."
