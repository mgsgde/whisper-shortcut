#!/bin/bash

# WhisperShortcut Rebuild and Restart Script
# Builds the project, kills any running instances, and starts the app that was just built.
# The Debug build is "WhisperShortcut Dev" (bundle com.magnusgoedde.whispershortcut.dev): its own
# TCC entries (Accessibility, Microphone, Screen Recording), keychain group and container, so it
# never collides with the installed /Applications release. Settings/history can be copied over
# once with scripts/copy-release-data-to-dev.sh.
# Uses a fixed derivedData path so we always launch the build we just produced (not an old one).
#
# Usage:
#   bash scripts/rebuild-and-restart.sh                        # Default build, production API
#   bash scripts/rebuild-and-restart.sh --app-store            # App Store build
#   bash scripts/rebuild-and-restart.sh --development          # currently a no-op (flag parsed but unused; no scheme/endpoint switch)
#   bash scripts/rebuild-and-restart.sh --launch-from-main     # inside a .claude/worktrees/ checkout: build here, but
#                                                              # relaunch the MAIN checkout's app (see warning below)

set -e  # Exit on any error

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# Parse flags (order-independent)
APP_STORE=false
DEVELOPMENT=false
LAUNCH_FROM_MAIN=false
for arg in "$@"; do
  case "$arg" in
    --app-store) APP_STORE=true ;;
    --development|development) DEVELOPMENT=true ;;
    --launch-from-main) LAUNCH_FROM_MAIN=true ;;
  esac
done

if [[ "$APP_STORE" == true ]]; then
  DERIVED_DATA="$PROJECT_DIR/build/DerivedData-AppStore"
  APP_PATH="$DERIVED_DATA/Build/Products/Debug/WhisperShortcut-AppStore.app"
else
  DERIVED_DATA="$PROJECT_DIR/build/DerivedData"
  APP_PATH="$DERIVED_DATA/Build/Products/Debug/WhisperShortcut Dev.app"
fi

# An app launched from a worktree dies with it: `git worktree remove` deletes the binary under
# the running process, macOS TCC can no longer resolve its path, and every dictation records
# silence until it is relaunched (queue #10, 2026-09-16). Inside .claude/worktrees/ we therefore
# say so before launching, and offer to launch the main checkout's app instead.
IN_WORKTREE=false
MAIN_ROOT="${PROJECT_DIR%%/.claude/worktrees/*}"
if [[ "$MAIN_ROOT" != "$PROJECT_DIR" ]]; then
  IN_WORKTREE=true
  if [[ "$APP_STORE" == true ]]; then
    MAIN_APP="$MAIN_ROOT/build/DerivedData-AppStore/Build/Products/Debug/WhisperShortcut-AppStore.app"
  else
    MAIN_APP="$MAIN_ROOT/build/DerivedData/Build/Products/Debug/WhisperShortcut Dev.app"
  fi
elif [[ "$LAUNCH_FROM_MAIN" == true ]]; then
  echo "ℹ️  --launch-from-main ignored: this is the main checkout."
  LAUNCH_FROM_MAIN=false
fi

cd "$PROJECT_DIR"

# Keychain items live in the data protection keychain, which needs the keychain-access-groups
# entitlement and therefore a provisioning profile. With an Apple Development identity we use the
# project's own signing (team Z59J7V26UT), which keeps the designated requirement stable, so
# mic/TCC grants survive rebuilds. The direct target's Debug config (bundle ….whispershortcut.dev)
# signs Manually with the "WhisperShortcut Dev (Mac Development)" profile: Xcode has no account
# signed in, so Automatic signing cannot mint a managed profile for the .dev App ID. That profile
# was made with `asc profiles create` and expires 2027-10-20 — renew it the same way
# (WhisperShortcut/Docs/data-directories.md → "Debug build identity"). The App Store target stays
# on Automatic signing; -allowProvisioningUpdates lets Xcode renew its team profile.
# No identity (e.g. cloners without an account) → ad-hoc, with the entitlement stripped from a
# copy of the entitlements file (an ad-hoc build cannot carry it); the app then falls back to the
# legacy keychain.
SIGN_ARGS=()
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 "Apple Development" | sed -E 's/.*"(.*)".*/\1/')
if [[ -n "$IDENTITY" ]]; then
  SIGN_ARGS=(-allowProvisioningUpdates)
  echo "🔏 Signing: $IDENTITY (project signing settings)"
else
  if [[ "$APP_STORE" == true ]]; then
    ENTITLEMENTS_SRC="$PROJECT_DIR/WhisperShortcut/WhisperShortcut-AppStore.entitlements"
  else
    ENTITLEMENTS_SRC="$PROJECT_DIR/WhisperShortcut/WhisperShortcut.entitlements"
  fi
  STRIPPED="$DERIVED_DATA/adhoc.entitlements"
  mkdir -p "$DERIVED_DATA"
  cp "$ENTITLEMENTS_SRC" "$STRIPPED"
  /usr/libexec/PlistBuddy -c 'Delete :keychain-access-groups' "$STRIPPED" >/dev/null 2>&1 || true
  SIGN_ARGS=(CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER= CODE_SIGN_ENTITLEMENTS="$STRIPPED")
  echo "🔏 Signing: ad-hoc (no Apple Development identity; legacy keychain, prompts on rebuilds)"
fi

# Sync the root README into the app bundle so Xcode's file-system-synchronized
# group bundles it and the chat's list_whisper_shortcut_docs /
# read_whisper_shortcut_doc tools can read it. The standalone docs/ tree was
# removed in cf0dd3a (data-directories was inlined into privacy.md), so other
# bundled docs under WhisperShortcut/Docs/ are now edited in place — no sync.
echo "📚 Syncing bundled docs..."
mkdir -p "$PROJECT_DIR/WhisperShortcut/Docs"
cp "$PROJECT_DIR/README.md" "$PROJECT_DIR/WhisperShortcut/Docs/README.md"

# Build variant
if [[ "$APP_STORE" == true ]]; then
  SCHEME="WhisperShortcut-AppStore"
  echo "🏪 Building App Store variant (scheme: $SCHEME)..."
  if ! xcodebuild -project WhisperShortcut.xcodeproj -list 2>/dev/null | grep -q "WhisperShortcut-AppStore"; then
    echo ""
    echo "❌  Scheme 'WhisperShortcut-AppStore' not found."
    echo "   Create a separate Xcode target + scheme named 'WhisperShortcut-AppStore' first."
    exit 1
  fi
  # mlx-swift ships a Linux-only CudaBuild plugin that no-ops on macOS;
  # Xcode still refuses unknown plugins unless we skip validation.
  xcodebuild -project WhisperShortcut.xcodeproj -scheme "$SCHEME" -configuration Debug \
    -derivedDataPath "$DERIVED_DATA" \
    -skipPackagePluginValidation \
    "${SIGN_ARGS[@]}" \
    build
else
  echo "🔨 Building WhisperShortcut (configuration: Debug)..."
  # mlx-swift ships a Linux-only CudaBuild plugin that no-ops on macOS;
  # Xcode still refuses unknown plugins unless we skip validation.
  xcodebuild -project WhisperShortcut.xcodeproj -scheme WhisperShortcut -configuration Debug \
    -derivedDataPath "$DERIVED_DATA" \
    -skipPackagePluginValidation \
    "${SIGN_ARGS[@]}" \
    build
fi

echo "✅ Build successful!"

# The build is ready; do not take a recording meeting down to install it (2026-10-20 incident).
if [[ "${CI:-}" != "true" ]]; then
  bash "$SCRIPT_DIR/meeting-guard.sh" || { echo "ℹ️  The build is ready; rerun this script once the meeting has ended." >&2; exit 1; }
fi

echo "🔄 Killing any running WhisperShortcut instances..."
# `pkill -f WhisperShortcut` ALSO matches this script's command line (it runs from a path
# containing "WhisperShortcut"), and AppKit's SIGTERM handler can take several seconds to
# flush. The original `pkill || true; sleep 1; open` could leave a stale instance running,
# and `open` would just foreground it instead of launching the fresh build. Match by exact
# executable name and verify termination before relaunching.
kill_app() {
  local NAME="$1"
  local PIDS
  PIDS=$(pgrep -x "$NAME" 2>/dev/null || true)
  [[ -z "$PIDS" ]] && return 0
  echo "  • SIGTERM → $NAME (pids: $PIDS)"
  kill $PIDS 2>/dev/null || true
  for _ in 1 2 3 4 5; do
    sleep 1
    PIDS=$(pgrep -x "$NAME" 2>/dev/null || true)
    [[ -z "$PIDS" ]] && return 0
  done
  PIDS=$(pgrep -x "$NAME" 2>/dev/null || true)
  if [[ -n "$PIDS" ]]; then
    echo "  • ⚠️  Did not quit within 5s — SIGKILL → $PIDS"
    kill -9 $PIDS 2>/dev/null || true
    sleep 1
  fi
}
# All of them, not just the one we are about to launch: the dev build, an older Debug build still
# named "WhisperShortcut", and the installed /Applications release (also "WhisperShortcut") all
# bind the same global hotkeys, so only one may run at a time.
APP_PROCESS_NAMES=("WhisperShortcut Dev" WhisperShortcut WhisperShortcut-AppStore)
for name in "${APP_PROCESS_NAMES[@]}"; do kill_app "$name"; done

# Sanity check before launching — without this, `open` would silently foreground a leftover
# instance (giving the illusion of a relaunch while we keep testing the stale build).
any_app_alive() {
  local name
  for name in "${APP_PROCESS_NAMES[@]}"; do pgrep -x "$name" >/dev/null 2>&1 && return 0; done
  return 1
}
if any_app_alive; then
  echo "❌ A WhisperShortcut instance is still alive after kill attempts — aborting so you don't test the stale build."
  exit 1
fi

if [[ "$IN_WORKTREE" == true && "$LAUNCH_FROM_MAIN" == true ]]; then
  if [[ -d "$MAIN_APP" ]]; then
    echo "🚀 Starting the MAIN checkout's app (--launch-from-main; this worktree's build was only compiled)..."
    APP_PATH="$MAIN_APP"
  else
    echo "⚠️  --launch-from-main: no build at $MAIN_APP — launching this worktree's build instead."
    LAUNCH_FROM_MAIN=false
  fi
fi
if [[ "$IN_WORKTREE" == true && "$LAUNCH_FROM_MAIN" != true ]]; then
  echo ""
  echo "⚠️  ⚠️  ⚠️  Launching from a WORKTREE: $PROJECT_DIR"
  echo "   This app runs from the worktree's build/DerivedData. When the worktree is removed the"
  echo "   binary vanishes under it, macOS revokes microphone access, and every dictation records"
  echo "   silence until you relaunch. Before removing the worktree, relaunch the main checkout's app:"
  echo "       open '$MAIN_APP'"
  echo "   or remove it with the guard, which refuses while this app is alive:"
  echo "       bash '$MAIN_ROOT/scripts/worktree-remove.sh' [--relaunch-main] '$PROJECT_DIR'"
  echo "   (Rerun with --launch-from-main to build here but keep running the main checkout's app.)"
  echo ""
fi
echo "🚀 Starting WhisperShortcut application ($( [[ "$LAUNCH_FROM_MAIN" == true ]] && echo main checkout || echo this build ))..."
open "$APP_PATH"

echo "🎉 WhisperShortcut has been rebuilt and restarted!"
