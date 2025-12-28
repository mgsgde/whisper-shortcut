#!/bin/bash

# Enable debug test menu in WhisperShortcut
# This allows you to test the retry functionality by simulating errors

echo "🔧 Enabling debug test menu in WhisperShortcut..."
defaults write com.magnusgoedde.whispershortcut enableDebugTestMenu -bool true
echo "✅ Debug test menu enabled!"
echo ""
echo "To disable it, run:"
echo "  defaults write com.magnusgoedde.whispershortcut enableDebugTestMenu -bool false"
echo ""
echo "You may need to restart the app for changes to take effect."








