#!/bin/bash

echo "🎙️ Starting WhisperShortcut in development mode..."

# Kill any running instances
pkill -f "WhisperShortcut" 2>/dev/null || true

# Build the app
echo "📦 Building..."
cd WhisperShortcut && \
swift build -c release && \
mkdir -p WhisperShortcut.app/Contents/MacOS && \
cp .build/release/WhisperShortcut WhisperShortcut.app/Contents/MacOS/ && \
cp Info.plist WhisperShortcut.app/Contents/ && \
chmod +x WhisperShortcut.app/Contents/MacOS/WhisperShortcut && \
echo "🔐 Signing app for Keychain access..." && \
codesign --deep --force --sign - WhisperShortcut.app && \
cd ..

# Run locally
echo "🔥 Running locally..."
open WhisperShortcut/WhisperShortcut.app
echo "✅ App launched locally! Look for 🎙️ in menu bar" 