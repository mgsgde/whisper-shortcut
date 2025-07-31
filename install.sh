#!/bin/bash

echo "🎙️ Installing WhisperShortcut to Applications..."

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

# Install to Applications
echo "📱 Installing to Applications..."
# Remove old version
if [ -d "/Applications/WhisperShortcut.app" ]; then
  sudo rm -rf /Applications/WhisperShortcut.app
fi
# Copy to Applications
sudo cp -R WhisperShortcut/WhisperShortcut.app /Applications/
sudo chmod +x /Applications/WhisperShortcut.app/Contents/MacOS/WhisperShortcut
echo "✅ Installed to Applications!"

# Ask if user wants to launch
read -p "Launch now? (y/n): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
  open /Applications/WhisperShortcut.app
  echo "✅ App launched! Look for ��️ in menu bar"
fi 