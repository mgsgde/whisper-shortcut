#!/bin/bash

# WhisperShortcut Rebuild and Restart Script
# Builds the project, kills any running dev instances, and starts the app that was just built.
# NOTHING under /Applications is ever killed (the installed release is the user's daily instance):
# see kill_unprotected in lib/daily-app.sh. While the release runs, this build launches as a
# sidecar next to it (badge TEST, no hotkeys), even from the main checkout.
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
#   bash scripts/rebuild-and-restart.sh --sidecar              # launch this build NEXT TO the running instance (never kills it)
#   bash scripts/rebuild-and-restart.sh --replace              # kill every non-/Applications instance, launch this build
#
# Main checkout: replaces the running dev instance (default) unless the /Applications release
# runs, then it is a sidecar. Worktree: sidecar by default, because an agent's worktree build must
# not take the user's all-day instance away (all instances bind the same global hotkeys). A sidecar
# runs with `--sidecar`: badge TEST, no hotkeys / Fn key / MCP / Sparkle / daily auto-run. Only the
# previous sidecar of this very build is restarted. (The app also turns itself into a sidecar when
# a Dev build starts while the release runs, so Xcode's Run button is safe too.)

set -e  # Exit on any error

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/daily-app.sh
source "$SCRIPT_DIR/lib/daily-app.sh"
# Parse flags (order-independent)
APP_STORE=false
DEVELOPMENT=false
LAUNCH_FROM_MAIN=false
FORCE_SIDECAR=false
FORCE_REPLACE=false
for arg in "$@"; do
  case "$arg" in
    --app-store) APP_STORE=true ;;
    --development|development) DEVELOPMENT=true ;;
    --launch-from-main) LAUNCH_FROM_MAIN=true ;;
    --sidecar) FORCE_SIDECAR=true ;;
    --replace) FORCE_REPLACE=true ;;
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

# Sidecar unless told otherwise when in a worktree; --replace and --launch-from-main both mean
# "this is the instance the user runs", so they keep the kill-everything path.
SIDECAR=false
if [[ "$FORCE_SIDECAR" == true && "$IN_WORKTREE" != true ]]; then
  # Without a running release the main checkout's build IS the daily instance, and the sidecar
  # path kills the previous instance of this very bundle path: it would take it away.
  if release_running; then
    SIDECAR=true   # same as the default launch below: sidecar next to the release
  else
    echo "ℹ️  --sidecar ignored: the main checkout's build is the daily instance."
  fi
elif [[ "$FORCE_SIDECAR" == true ]]; then
  SIDECAR=true
elif [[ "$IN_WORKTREE" == true && "$FORCE_REPLACE" != true && "$LAUNCH_FROM_MAIN" != true ]]; then
  SIDECAR=true
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
  bash "$SCRIPT_DIR/meeting-guard.sh" --dev-only || { echo "ℹ️  The build is ready; rerun this script once the meeting has ended." >&2; exit 1; }
fi

# Stopping goes through kill_unprotected (lib/daily-app.sh): exact process name or this build's
# executable path, never a bare `pkill -f WhisperShortcut` (that also matches this script's own
# command line), and never anything whose command line starts with /Applications/. SIGTERM, up to
# 5s of grace for AppKit to flush, then SIGKILL; a stale instance left running would make `open`
# just foreground it instead of launching the fresh build.
# All dev instances, not just the one we are about to launch: the dev build and an older Debug
# build still named "WhisperShortcut" bind the same global hotkeys, so only one may run at a time.
APP_PROCESS_NAMES=("WhisperShortcut Dev" WhisperShortcut WhisperShortcut-AppStore)

# Computed before anything is killed; the release is never among the victims.
RELEASE_UP=false
release_running && RELEASE_UP=true

if [[ "$SIDECAR" == true ]]; then
  echo "🔄 Sidecar: restarting only this build's previous sidecar (other instances stay untouched)..."
  kill_unprotected -f "$APP_PATH/Contents/MacOS"
  if pgrep -f "$APP_PATH/Contents/MacOS" >/dev/null 2>&1; then
    echo "❌ The previous sidecar is still alive after kill attempts — aborting."
    exit 1
  fi
else
  # Remember which bundle the user's own instance ran from, so ensure-app-running.sh and
  # run-tests.sh bring that one back rather than a build of their own choosing.
  record_daily_app

  echo "🔄 Killing any running dev instances (anything under /Applications is left alone)..."
  for name in "${APP_PROCESS_NAMES[@]}"; do kill_unprotected -x "$name"; done

  # Sanity check before launching — without this, `open` would silently foreground a leftover
  # instance (giving the illusion of a relaunch while we keep testing the stale build).
  any_unprotected_alive() {
    local name pid cmd
    for name in "${APP_PROCESS_NAMES[@]}"; do
      for pid in $(pgrep -x "$name" 2>/dev/null || true); do
        cmd=$(ps -o command= -p "$pid" 2>/dev/null || true)
        [[ -n "$cmd" ]] && ! is_protected_cmd "$cmd" && return 0
      done
    done
    return 1
  }
  if any_unprotected_alive; then
    echo "❌ A dev WhisperShortcut instance is still alive after kill attempts — aborting so you don't test the stale build."
    exit 1
  fi
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
if [[ "$IN_WORKTREE" == true && "$LAUNCH_FROM_MAIN" != true && "$SIDECAR" != true && "$RELEASE_UP" != true ]]; then
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
if [[ "$SIDECAR" == true ]]; then
  # -n: the user's instance has the same bundle ID, plain `open` would just foreground it.
  open -n "$APP_PATH" --args --sidecar
  echo "🧪 Sidecar: launched this worktree's build next to your running instance (badge TEST; no global hotkeys, no Fn key). Your instance was not touched. To test hotkeys, quit the /Applications release yourself and rerun with --replace."
  exit 0
fi
echo "🚀 Starting WhisperShortcut application ($( [[ "$LAUNCH_FROM_MAIN" == true ]] && echo main checkout || echo this build ))..."
# -n: every dev instance was just killed, and the launch must not be folded into a stray one.
# The daily-app record is deliberately not touched here: it names the instance the user runs
# (the /Applications release), and a dev build overwriting it made scripts relaunch the wrong app.
if [[ "$RELEASE_UP" == true ]]; then
  open -n "$APP_PATH" --args --sidecar
  echo "🧪 The release in /Applications keeps running; this build runs next to it as a sidecar (badge TEST, no hotkeys)."
else
  open -n "$APP_PATH"
fi

echo "🎉 WhisperShortcut has been rebuilt and restarted!"
