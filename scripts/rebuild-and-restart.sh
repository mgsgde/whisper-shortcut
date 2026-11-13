#!/bin/bash

# WhisperShortcut Rebuild and Restart Script
# Builds the project, kills any running dev instances, and starts the app that was just built.
# NOTHING under /Applications and not the daily Dev app (~/Applications/WhisperShortcut Dev.app,
# see scripts/dev-daily.sh) is ever killed: see kill_unprotected in lib/daily-app.sh. While your
# daily instance (release or daily Dev) runs, this build launches as a sidecar next to it
# (badge TEST, no hotkeys), even from the main checkout.
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
#   bash scripts/rebuild-and-restart.sh --build-only           # build, print "Build successful", exit 0: no guard, no kill, no launch
#   bash scripts/rebuild-and-restart.sh --replace              # kill every non-/Applications instance, launch this build
#   bash scripts/rebuild-and-restart.sh --sidecar --profile <name> [--fresh] [--no-models] [--allow-model-downloads] [--no-build] [--app-arg <arg>]...
#        # launch this build as an isolated TEST PROFILE: own bundle id, settings, data and
#        # (in-memory) keychain, shared offline models read-only. --fresh wipes that profile first
#        # (first-launch state, onboarding). Never touches any other instance. See
#        # WhisperShortcut/TestProfile.swift and scripts/lib/test-profile.sh.
#
# Main checkout: replaces the running dev instance (default) unless your daily instance (release
# or daily Dev) runs, then it is a sidecar. Worktree: sidecar by default, because an agent's worktree build must
# not take the user's all-day instance away (all instances bind the same global hotkeys). A sidecar
# runs with `--sidecar`: badge TEST, no hotkeys / Fn key / MCP / Sparkle / daily auto-run. Only the
# previous sidecar of this very build is restarted. (The app also turns itself into a sidecar when
# a Dev build starts while the release runs, so Xcode's Run button is safe too.)

set -e  # Exit on any error

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/daily-app.sh
source "$SCRIPT_DIR/lib/daily-app.sh"
# shellcheck source=lib/build-lock.sh
source "$SCRIPT_DIR/lib/build-lock.sh"
# shellcheck source=lib/test-profile.sh
source "$SCRIPT_DIR/lib/test-profile.sh"
# shellcheck source=lib/worktree.sh
source "$SCRIPT_DIR/lib/worktree.sh"
# Parse flags (order-independent)
APP_STORE=false
DEVELOPMENT=false
LAUNCH_FROM_MAIN=false
FORCE_SIDECAR=false
FORCE_REPLACE=false
BUILD_ONLY=false
PROFILE=""
PROFILE_FRESH=false
PROFILE_MODELS=shared
PROFILE_ALLOW_DOWNLOADS=false
NO_BUILD=false
APP_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --app-store) APP_STORE=true ;;
    --development|development) DEVELOPMENT=true ;;
    --launch-from-main) LAUNCH_FROM_MAIN=true ;;
    --sidecar) FORCE_SIDECAR=true ;;
    --replace) FORCE_REPLACE=true ;;
    --build-only) BUILD_ONLY=true ;;
    --profile)
      [[ $# -ge 2 ]] || { echo "❌ --profile needs a name" >&2; exit 2; }
      PROFILE="$2"; shift ;;
    --fresh) PROFILE_FRESH=true ;;
    --no-models) PROFILE_MODELS=none ;;
    --allow-model-downloads) PROFILE_ALLOW_DOWNLOADS=true ;;
    --no-build) NO_BUILD=true ;;
    --app-arg)
      [[ $# -ge 2 ]] || { echo "❌ --app-arg needs a value" >&2; exit 2; }
      APP_ARGS+=("$2"); shift ;;
  esac
  shift
done

# A test profile is always a sidecar and never replaces anything; refuse combinations that would.
if [[ -n "$PROFILE" ]]; then
  profile_valid_name "$PROFILE" || { echo "❌ invalid profile name \"$PROFILE\" (a-z, 0-9, -; max 32)" >&2; exit 2; }
  if [[ "$APP_STORE" == true || "$FORCE_REPLACE" == true || "$LAUNCH_FROM_MAIN" == true || "$BUILD_ONLY" == true ]]; then
    echo "❌ --profile cannot be combined with --app-store, --replace, --launch-from-main or --build-only" >&2
    exit 2
  fi
  FORCE_SIDECAR=true
elif [[ "$PROFILE_FRESH" == true || "$PROFILE_MODELS" == none || "$PROFILE_ALLOW_DOWNLOADS" == true || "$NO_BUILD" == true || ${#APP_ARGS[@]} -gt 0 ]]; then
  echo "❌ --fresh, --no-models, --allow-model-downloads, --no-build and --app-arg need --profile <name>" >&2
  exit 2
fi

if [[ "$APP_STORE" == true ]]; then
  DERIVED_DATA="$PROJECT_DIR/build/DerivedData-AppStore"
  APP_PATH="$DERIVED_DATA/Build/Products/Debug/WhisperShortcut-AppStore.app"
else
  DERIVED_DATA="$PROJECT_DIR/build/DerivedData"
  APP_PATH="$DERIVED_DATA/Build/Products/Debug/WhisperShortcut Dev.app"
fi

# An app launched from a worktree dies with it: `git worktree remove` deletes the binary under
# the running process, macOS TCC can no longer resolve its path, and every dictation records
# silence until it is relaunched (queue #10, 2026-09-16). In any linked git worktree (asked of git, so
# .claude/worktrees/<n> and <parent>/.worktrees/<n> both count) we therefore say so before
# launching, and offer to launch the main checkout's app instead.
IN_WORKTREE=false
MAIN_ROOT="$PROJECT_DIR"
if _wt_root="$(worktree_main_root "$PROJECT_DIR")"; then
  MAIN_ROOT="$_wt_root"
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
if [[ -n "$PROFILE" ]]; then
  SIDECAR=true   # whatever runs: a profile only ever stops its own previous instance
elif [[ "$FORCE_SIDECAR" == true && "$IN_WORKTREE" != true ]]; then
  # Without a running daily instance the main checkout's build IS the daily instance, and the
  # sidecar path kills the previous instance of this very bundle path: it would take it away.
  if daily_instance_running; then
    SIDECAR=true   # same as the default launch below: sidecar next to the daily instance
  else
    echo "ℹ️  --sidecar ignored: the main checkout's build is the daily instance."
  fi
elif [[ "$FORCE_SIDECAR" == true ]]; then
  SIDECAR=true
elif [[ "$IN_WORKTREE" == true && "$FORCE_REPLACE" != true && "$LAUNCH_FROM_MAIN" != true ]]; then
  SIDECAR=true
fi

cd "$PROJECT_DIR"

# One Xcode run at a time on this Mac (see lib/build-lock.sh: seven concurrent runs took the load
# average to 162 on 2026-11-03). A rebuild collides with run-tests.sh just the same, so it takes
# the same lock. Taken before anything is built (the scheme check below shells out to xcodebuild
# too) or stopped. CI is skipped: one job per isolated runner, nothing to serialize against.
# The default 1200 s wait stays: this script is interactive, and waiting with a progress line
# every 60 s beats two xcodebuilds thrashing a 10-core machine. Exit 75 (EX_TEMPFAIL) is passed
# on unchanged: "another run holds the machine", not "the build failed".
if [[ "$NO_BUILD" == true ]]; then
  :   # --profile --no-build: relaunch the existing build, no xcodebuild, no build lock
elif [[ "${CI:-}" != "true" ]]; then
  lock_rc=0
  acquire_build_lock || lock_rc=$?
  [[ "$lock_rc" -eq 0 ]] || exit "$lock_rc"
  trap release_build_lock EXIT
fi

# --no-build (profiles only) skips everything down to "Build successful" and relaunches the
# product already in DerivedData.
if [[ "$NO_BUILD" != true ]]; then
  # Keychain items live in the data protection keychain, which needs the keychain-access-groups
  # entitlement and therefore a provisioning profile. With an Apple Development identity *from the
  # team the project requires* we use the project's own signing, which keeps the designated
  # requirement stable, so mic/TCC grants survive rebuilds. The direct target's Debug config (bundle
  # ….whispershortcut.dev) signs Manually with the "WhisperShortcut Dev (Mac Development)" profile:
  # Xcode has no account signed in, so Automatic signing cannot mint a managed profile for the .dev
  # App ID. That profile was made with `asc profiles create` and expires 2027-10-20 — renew it the
  # same way (WhisperShortcut/Docs/data-directories.md → "Debug build identity"). The App Store
  # target stays on Automatic signing; -allowProvisioningUpdates lets Xcode renew its team profile.
  #
  # The check is team-aware, not just "an identity exists": an identity from another team has no
  # profile for this project's team, so that branch would fail with "No profile for team '…'
  # matching '…' found" instead of falling back. The required team is read from the project
  # (DEVELOPMENT_TEAM in project.pbxproj, so a fork with its own team works) and compared with the
  # team id in the identity's certificate (organizationalUnitName). If either cannot be determined,
  # we do not guess: no required team keeps the old behaviour, an unreadable identity team means
  # ad-hoc.
  # No usable identity (e.g. cloners without an account) → ad-hoc, with the entitlement stripped
  # from a copy of the entitlements file (an ad-hoc build cannot carry it); the app then falls back
  # to the legacy keychain.
  REQUIRED_TEAM=$(sed -nE 's/.*DEVELOPMENT_TEAM = ([A-Z0-9]+);.*/\1/p' \
    "$PROJECT_DIR/WhisperShortcut.xcodeproj/project.pbxproj" 2>/dev/null | head -n1 || true)

  # Team id of a codesigning identity's certificate: its organizationalUnitName. Empty when the
  # certificate cannot be read or parsed, which callers treat as "not the project's team".
  identity_team() {
    local identity="$1" subject
    subject=$(security find-certificate -c "$identity" -p 2>/dev/null \
      | openssl x509 -noout -subject -nameopt multiline 2>/dev/null) || return 0
    printf '%s\n' "$subject" | sed -nE 's/^ *organizationalUnitName *= *(.*)$/\1/p' | head -n1
  }

  SIGN_ARGS=()
  # Every Apple Development identity, not just the first: a machine can hold identities from several
  # teams (a personal one and an employer's), and `grep -m1` picked whichever the keychain listed
  # first. If that one belonged to another team, the script fell back to ad-hoc even though a usable
  # identity was right there — the exact case this fallback exists for.
  IDENTITIES=()
  while IFS= read -r line; do
    IDENTITIES+=("$(printf '%s' "$line" | sed -E 's/.*"(.*)".*/\1/')")
  done < <(security find-identity -v -p codesigning 2>/dev/null | grep "Apple Development" || true)

  IDENTITY=""
  IDENTITY_TEAM=""
  for candidate in "${IDENTITIES[@]}"; do
    [[ -n "$candidate" ]] || continue
    candidate_team=$(identity_team "$candidate")
    if [[ -z "$REQUIRED_TEAM" || "$candidate_team" == "$REQUIRED_TEAM" ]]; then
      IDENTITY="$candidate"
      IDENTITY_TEAM="$candidate_team"
      break
    fi
    # Remember the first non-matching one for the ad-hoc reason line below.
    if [[ -z "$IDENTITY_TEAM" ]]; then
      IDENTITY_TEAM="$candidate_team"
    fi
  done

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
    if [[ ${#IDENTITIES[@]} -eq 0 ]]; then
      ADHOC_REASON="no Apple Development identity"
    elif [[ -z "$IDENTITY_TEAM" ]]; then
      ADHOC_REASON="identity team unreadable, project team $REQUIRED_TEAM"
    else
      ADHOC_REASON="no identity for project team $REQUIRED_TEAM (found $IDENTITY_TEAM)"
    fi
    echo "🔏 Signing: ad-hoc ($ADHOC_REASON; legacy keychain, prompts on rebuilds)"
  fi

  # Sync the root README and docs/guide.md into the app bundle so Xcode's file-system-synchronized
  # group bundles it and the chat's list_whisper_shortcut_docs /
  # read_whisper_shortcut_doc tools can read it. The standalone docs/ tree was
  # removed in cf0dd3a (data-directories was inlined into privacy.md), so other
  # bundled docs under WhisperShortcut/Docs/ are now edited in place — no sync.
  echo "📚 Syncing bundled docs..."
  mkdir -p "$PROJECT_DIR/WhisperShortcut/Docs"
  cp "$PROJECT_DIR/README.md" "$PROJECT_DIR/WhisperShortcut/Docs/README.md"
  cp "$PROJECT_DIR/docs/guide.md" "$PROJECT_DIR/WhisperShortcut/Docs/guide.md"

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
else
  [[ -d "$APP_PATH" ]] || { echo "❌ --no-build: no build at $APP_PATH; run without --no-build first." >&2; exit 1; }
  echo "⏭️  --no-build: using the existing build at $APP_PATH"
fi

# --build-only: callers (scripts/dev-daily.sh) install the product themselves.
[[ "$BUILD_ONLY" == true ]] && exit 0

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

# Computed before anything is killed; the daily instance (release or daily Dev) is never among the victims.
RELEASE_UP=false
daily_instance_running && RELEASE_UP=true

if [[ -n "$PROFILE" ]]; then
  # Test profile: stop only this profile's previous instance (matched by its own bundle path,
  # build/profiles/<name>/), optionally wipe its container, re-make the bundle, launch it.
  PROFILE_APP="$(profile_app_path "$PROJECT_DIR" "$PROFILE")"
  echo "🔄 Profile \"$PROFILE\": stopping only its own previous instance (every other instance stays untouched)..."
  kill_unprotected -f "$PROFILE_APP/Contents/MacOS"
  if pgrep -f "$PROFILE_APP/Contents/MacOS" >/dev/null 2>&1; then
    echo "❌ The previous instance of profile \"$PROFILE\" is still alive after kill attempts — aborting."
    exit 1
  fi
  if [[ "$PROFILE_FRESH" == true ]]; then
    wipe_profile "$PROFILE" || exit 1
  fi
  make_profile_bundle "$APP_PATH" "$PROJECT_DIR" "$PROFILE" "$PROFILE_MODELS" "$PROFILE_ALLOW_DOWNLOADS" || {
    echo "❌ Could not build an isolated profile bundle — nothing was launched." >&2
    exit 1
  }
  # -n: always a new process. --sidecar is redundant (a profile is always one) but keeps every
  # sidecar check in scripts working; --profile must match the bundle or the app refuses to run.
  open -n "$PROFILE_APP" --args --sidecar --profile "$PROFILE" ${APP_ARGS[@]+"${APP_ARGS[@]}"}
  PROFILE_PID=""
  for _ in $(seq 1 20); do
    PROFILE_PID="$(pgrep -f "$PROFILE_APP/Contents/MacOS" 2>/dev/null | head -n1 || true)"
    [[ -n "$PROFILE_PID" ]] && break
    sleep 0.5
  done
  sleep 2
  if [[ -z "$PROFILE_PID" ]] || ! kill -0 "$PROFILE_PID" 2>/dev/null; then
    echo "❌ Profile \"$PROFILE\" did not stay up. If it refused to run, the reason is in the log:" >&2
    echo "   bash scripts/logs.sh -t 2m | grep TEST-PROFILE" >&2
    exit 1
  fi
  echo "🧪 Profile \"$PROFILE\" running: pid $PROFILE_PID (badge \"TEST $PROFILE\"; no hotkeys, MCP, telemetry or updates; keys in memory only)."
  echo "   Drive it: WS_PROFILE=$PROFILE bash .agents/skills/run-whisper-shortcut/driver.sh <command>"
  exit 0
fi

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
# (the /Applications release or the daily Dev), and a dev build overwriting it made scripts relaunch the wrong app.
if [[ "$RELEASE_UP" == true ]]; then
  open -n "$APP_PATH" --args --sidecar
  echo "🧪 Your daily instance (release or daily Dev) keeps running; this build runs next to it as a sidecar (badge TEST, no hotkeys)."
else
  open -n "$APP_PATH"
fi

echo "🎉 WhisperShortcut has been rebuilt and restarted!"
