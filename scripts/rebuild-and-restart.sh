#!/bin/bash

# WhisperShortcut Rebuild and Restart Script
# Builds the project, kills any running instances, and starts the app that was just built.
# Uses a fixed derivedData path so we always launch the build we just produced (not an old one).
#
# Usage:
#   bash scripts/rebuild-and-restart.sh                        # Default build, production API
#   bash scripts/rebuild-and-restart.sh --app-store            # App Store build
#   bash scripts/rebuild-and-restart.sh --development          # Local API (localhost:8080)

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

cd "$PROJECT_DIR"

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
  xcodebuild -project WhisperShortcut.xcodeproj -scheme "$SCHEME" -configuration Debug \
    -derivedDataPath "$DERIVED_DATA" \
    build
else
  echo "🔨 Building WhisperShortcut (configuration: Debug)..."
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
