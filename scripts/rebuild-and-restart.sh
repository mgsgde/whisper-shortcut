#!/bin/bash

# WhisperShortcut Rebuild and Restart Script
# Builds the project, kills any running instances, and starts the app that was just built.
# Uses a fixed derivedData path so we always launch the build we just produced (not an old one).
#
# Usage:
#   bash scripts/rebuild-and-restart.sh           # Use local API (localhost:8080)
#   bash scripts/rebuild-and-restart.sh --production   # Use production API

set -e  # Exit on any error

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DERIVED_DATA="$PROJECT_DIR/build/DerivedData"
APP_PATH="$DERIVED_DATA/Build/Products/Debug/WhisperShortcut.app"

# Optional: --production to use production API
if [[ "${1:-}" == "--production" ]] || [[ "${1:-}" == "production" ]]; then
  defaults write com.magnusgoedde.whispershortcut WSUseProductionAPI -bool true
  echo "📡 Using production API (whispershortcut.com)."
else
  defaults delete com.magnusgoedde.whispershortcut WSUseProductionAPI 2>/dev/null || true
  echo "📡 Using local API (localhost:8080)."
fi

cd "$PROJECT_DIR"

echo "🔨 Building WhisperShortcut project (scheme: WhisperShortcut, configuration: Debug)..."
xcodebuild -project WhisperShortcut.xcodeproj -scheme WhisperShortcut -configuration Debug -derivedDataPath "$DERIVED_DATA" build

echo "✅ Build successful!"

echo "🔄 Killing any running WhisperShortcut instances..."
pkill -f WhisperShortcut || true

echo "⏳ Waiting for app to fully close..."
sleep 1

echo "🚀 Starting WhisperShortcut application (this build)..."
open "$APP_PATH"

echo "🎉 WhisperShortcut has been rebuilt and restarted!"
