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

echo "🧪 Running WhisperShortcut tests..."
echo "   Scheme:    $SCHEME"
echo "   Test plan: $TEST_PLAN"
echo ""

# A running app can receive SIGTERM during XCTest bootstrap and exit before the
# test runner connects (FullApp's clean-shutdown handler).
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
