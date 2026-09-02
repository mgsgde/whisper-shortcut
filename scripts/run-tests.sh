#!/bin/bash

# WhisperShortcut Test Runner
# Runs the WhisperShortcut-AppStore test plan (live LLM + transcription roundtrips).
#
# Usage:
#   bash scripts/run-tests.sh              # full plan (live tests skip without .env)
#   bash scripts/run-tests.sh --hermetic   # offline subset; no .env, no live network

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

HERMETIC_RUN=false
for arg in "$@"; do
  case "$arg" in
    --hermetic) HERMETIC_RUN=true ;;
    *)
      echo "Unknown argument: $arg" >&2
      echo "Usage: bash scripts/run-tests.sh [--hermetic]" >&2
      exit 1
      ;;
  esac
done

# Provider API keys come from the gitignored .env at repo root (same file the
# test-*-models.sh scripts use). Exporting them here means the xctest process
# inherits them, and KeychainManager's DEBUG env override picks them up — so the
# live roundtrip tests never touch the login Keychain (no macOS ACL prompt) and
# no secret ever lands in the committed .xctestplan. Tests for a provider whose
# key is absent simply skip.
#
# Hermetic runs skip this on purpose: CI has no .env, and live-network suites
# are filtered out of WhisperShortcut-Hermetic.xctestplan.
ENV_FILE="$PROJECT_DIR/.env"
if [[ "$HERMETIC_RUN" == true ]]; then
  export HERMETIC=1
  echo "ℹ️  Hermetic run — not loading .env; live-network tests are skipped."
elif [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  set -a; source "$ENV_FILE"; set +a
else
  echo "ℹ️  No .env at repo root — tests will fall back to the Keychain (may prompt)."
fi

SCHEME="WhisperShortcut-AppStore"
if [[ "$HERMETIC_RUN" == true ]]; then
  TEST_PLAN="WhisperShortcut-Hermetic"
else
  TEST_PLAN="WhisperShortcut-AppStore"
fi
RESULT_BUNDLE="/tmp/WhisperShortcutTestResults-$(date +%s).xcresult"

# Build into a derived-data directory of our own, inside this checkout.
#
# Without it, xcodebuild uses the shared ~/Library/Developer/Xcode/DerivedData, which every other
# checkout and every parallel agent session also builds into — and a build starting there cancels
# one already running: five consecutive runs died with "** BUILD INTERRUPTED **" on 2026-09-01
# while two other worktrees were building. It is not the app's derived data either
# (`build/DerivedData`, written by rebuild-and-restart.sh): sharing that would let a rebuild in
# THIS checkout interrupt a test run in the same way. Costs one cold build per checkout; `build/`
# is gitignored.
DERIVED_DATA="$PROJECT_DIR/build/DerivedData-tests"

# The app the user actually runs day-to-day is the default WhisperShortcut build
# produced by rebuild-and-restart.sh (fixed derivedData path). We relaunch it once
# tests finish so the user isn't left without a running app — see the EXIT trap below.
RELAUNCH_APP="$PROJECT_DIR/build/DerivedData/Build/Products/Debug/WhisperShortcut.app"

echo "🧪 Running WhisperShortcut tests..."
echo "   Scheme:    $SCHEME"
echo "   Test plan: $TEST_PLAN"
echo ""

# Tests need the app stopped: a running instance can receive SIGTERM during XCTest
# bootstrap and exit before the test runner connects (FullApp's clean-shutdown handler).
# We relaunch it on EXIT regardless of whether the tests passed, so killing it here
# is non-destructive from the user's point of view. CI has no running app to restore.
relaunch_app() {
  if [[ "${CI:-}" == "true" ]]; then
    return 0
  fi
  if [[ -d "$RELAUNCH_APP" ]]; then
    echo ""
    echo "🚀 Relaunching WhisperShortcut..."
    open "$RELAUNCH_APP"
  else
    echo ""
    echo "ℹ️  No built app at $RELAUNCH_APP — run scripts/rebuild-and-restart.sh to build it. Skipping relaunch."
  fi
}
trap relaunch_app EXIT

if [[ "${CI:-}" != "true" ]]; then
  pkill -f "WhisperShortcut" 2>/dev/null || true
  sleep 1
fi

cd "$PROJECT_DIR"

# Serialize: Shortcut display calls TISCopyCurrentKeyboardLayoutInputSource,
# which HIToolbox aborts if two threads hit it at once.
XCODEBUILD_ARGS=(
  test
  -scheme "$SCHEME"
  -testPlan "$TEST_PLAN"
  -destination 'platform=macOS'
  -derivedDataPath "$DERIVED_DATA"
  -resultBundlePath "$RESULT_BUNDLE"
  -skipPackagePluginValidation
  -parallel-testing-enabled NO
)

if [[ "$HERMETIC_RUN" == true ]]; then
  # Pin check (same flag the release archive uses) plus ad-hoc sign so CI
  # does not need a Developer ID or any repository secret.
  XCODEBUILD_ARGS+=(
    -disableAutomaticPackageResolution
    CODE_SIGN_IDENTITY=-
    CODE_SIGNING_REQUIRED=NO
    DEVELOPMENT_TEAM=
  )
fi

xcodebuild "${XCODEBUILD_ARGS[@]}"

echo ""
echo "✅ All tests passed."
echo "   Results: $RESULT_BUNDLE"
