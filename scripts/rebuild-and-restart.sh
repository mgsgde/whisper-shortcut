#!/bin/bash

# WhisperShortcut Rebuild and Restart Script
# Builds the project, kills any running instances, and starts the app that was just built.
# Uses a fixed derivedData path so we always launch the build we just produced (not an old one).
#
# Usage:
#   bash scripts/rebuild-and-restart.sh                        # GitHub build (SUBSCRIPTION_ENABLED), production API
#   bash scripts/rebuild-and-restart.sh --development          # GitHub build, local API (localhost:8080)
#   bash scripts/rebuild-and-restart.sh --app-store            # App Store build (no SUBSCRIPTION_ENABLED), production API
#   bash scripts/rebuild-and-restart.sh --app-store --development  # App Store build, local API

set -e  # Exit on any error

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# Parse flags (order-independent)
APP_STORE=false
DEVELOPMENT=false
for arg in "$@"; do
  case "$arg" in
    --app-store) APP_STORE=true ;;
    --development|development) DEVELOPMENT=true ;;
  esac
done

if [[ "$APP_STORE" == true ]]; then
  DERIVED_DATA="$PROJECT_DIR/build/DerivedData-AppStore"
  APP_PATH="$DERIVED_DATA/Build/Products/Debug/WhisperShortcut-AppStore.app"
else
  DERIVED_DATA="$PROJECT_DIR/build/DerivedData"
  APP_PATH="$DERIVED_DATA/Build/Products/Debug/WhisperShortcut.app"
fi

# API endpoint
if [[ "$DEVELOPMENT" == true ]]; then
  defaults delete com.magnusgoedde.whispershortcut WSUseProductionAPI 2>/dev/null || true
  echo "📡 Using local API (localhost:8080)."
else
  defaults write com.magnusgoedde.whispershortcut WSUseProductionAPI -bool true
  echo "📡 Using production API (whispershortcut.com)."
fi

cd "$PROJECT_DIR"

# Build variant
if [[ "$APP_STORE" == true ]]; then
  # The App Store build requires a separate Xcode target (WhisperShortcut-AppStore) that
  # excludes GoogleSignIn from its SPM dependencies. Overriding SWIFT_ACTIVE_COMPILATION_CONDITIONS
  # at the CLI level breaks SPM package builds (GTMAppAuth loses its transitive deps).
  SCHEME="WhisperShortcut-AppStore"
  echo "🏪 Building App Store variant (scheme: $SCHEME, no SUBSCRIPTION_ENABLED)..."
  if ! xcodebuild -project WhisperShortcut.xcodeproj -list 2>/dev/null | grep -q "WhisperShortcut-AppStore"; then
    echo ""
    echo "❌  Scheme 'WhisperShortcut-AppStore' not found."
    echo "   Create a separate Xcode target + scheme named 'WhisperShortcut-AppStore' first:"
    echo "   1. In Xcode: duplicate the WhisperShortcut target"
    echo "   2. Remove GoogleSignIn from the new target's SPM dependencies"
    echo "   3. Remove SUBSCRIPTION_ENABLED from its build settings"
    echo "   4. Create a matching scheme named 'WhisperShortcut-AppStore'"
    exit 1
  fi
  xcodebuild -project WhisperShortcut.xcodeproj -scheme "$SCHEME" -configuration Debug \
    -derivedDataPath "$DERIVED_DATA" \
    build
else
  echo "🔨 Building GitHub variant (SUBSCRIPTION_ENABLED, configuration: Debug)..."
  xcodebuild -project WhisperShortcut.xcodeproj -scheme WhisperShortcut -configuration Debug \
    -derivedDataPath "$DERIVED_DATA" \
    build
fi

echo "✅ Build successful!"

echo "🔄 Killing any running WhisperShortcut instances..."
pkill -f WhisperShortcut || true

echo "⏳ Waiting for app to fully close..."
sleep 1

echo "🚀 Starting WhisperShortcut application (this build)..."
open "$APP_PATH"

echo "🎉 WhisperShortcut has been rebuilt and restarted!"
