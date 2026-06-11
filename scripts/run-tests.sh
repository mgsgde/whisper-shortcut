#!/bin/bash

# WhisperShortcut Test Runner
# Runs the WhisperShortcut-AppStore test plan (live LLM + transcription roundtrips).
#
# Usage:
#   bash scripts/run-tests.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

SCHEME="WhisperShortcut-AppStore"
TEST_PLAN="WhisperShortcut-AppStore"
RESULT_BUNDLE="/tmp/WhisperShortcutTestResults-$(date +%s).xcresult"

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
# is non-destructive from the user's point of view.
relaunch_app() {
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

pkill -f "WhisperShortcut" 2>/dev/null || true
sleep 1

cd "$PROJECT_DIR"

xcodebuild test \
  -scheme "$SCHEME" \
  -testPlan "$TEST_PLAN" \
  -destination 'platform=macOS' \
  -resultBundlePath "$RESULT_BUNDLE"

echo ""
echo "✅ All tests passed."
echo "   Results: $RESULT_BUNDLE"
