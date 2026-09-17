#!/bin/bash

# WhisperShortcut Rebuild and Restart Script
# Builds the project, kills any running instances, and starts the app that was just built.
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
  APP_PATH="$DERIVED_DATA/Build/Products/Debug/WhisperShortcut.app"
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
    MAIN_APP="$MAIN_ROOT/build/DerivedData/Build/Products/Debug/WhisperShortcut.app"
  fi
elif [[ "$LAUNCH_FROM_MAIN" == true ]]; then
  echo "ℹ️  --launch-from-main ignored: this is the main checkout."
  LAUNCH_FROM_MAIN=false
fi

cd "$PROJECT_DIR"

# Stable signature → keychain "Always Allow" and mic/TCC grants survive rebuilds.
# No Apple Development identity (e.g. cloners without an account) → fall back to ad-hoc.
SIGN_ARGS=()
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 "Apple Development" | sed -E 's/.*"(.*)".*/\1/')
[[ -n "$IDENTITY" ]] && SIGN_ARGS=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" CODE_SIGNING_ALLOWED=YES)
echo "🔏 Signing: ${IDENTITY:-ad-hoc (keychain re-prompts on rebuilds)}"

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
kill_app WhisperShortcut
kill_app WhisperShortcut-AppStore

# Sanity check before launching — without this, `open` would silently foreground a leftover
# instance (giving the illusion of a relaunch while we keep testing the stale build).
if pgrep -x WhisperShortcut >/dev/null 2>&1 || pgrep -x WhisperShortcut-AppStore >/dev/null 2>&1; then
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
