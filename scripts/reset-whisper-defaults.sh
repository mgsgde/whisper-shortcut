#!/bin/bash
# reset-whisper-defaults.sh
# Script to reset WhisperShortcut UserDefaults for testing

echo "🎙️ WhisperShortcut UserDefaults Reset Script"
echo "============================================="

# Check if we're on macOS
if [[ "$OSTYPE" != "darwin"* ]]; then
    echo "❌ Error: This script only works on macOS"
    exit 1
fi

# Bundle identifier for WhisperShortcut
BUNDLE_ID="com.magnusgoedde.whispershortcut"

echo "📋 Current UserDefaults for $BUNDLE_ID:"
echo "----------------------------------------"

# Show current UserDefaults
if defaults read "$BUNDLE_ID" 2>/dev/null; then
    echo ""
    echo "✅ Found UserDefaults for $BUNDLE_ID"
else
    echo "ℹ️  No UserDefaults found for $BUNDLE_ID"
fi

echo ""
echo "🗑️  Resetting UserDefaults..."

# Delete all UserDefaults for the app
defaults delete "$BUNDLE_ID" 2>/dev/null

# Also try to remove the plist file if it exists
PLIST_PATH="$HOME/Library/Preferences/$BUNDLE_ID.plist"
if [ -f "$PLIST_PATH" ]; then
    echo "📄 Removing plist file: $PLIST_PATH"
    rm "$PLIST_PATH"
fi

echo ""
echo "✅ Done! All UserDefaults cleared for $BUNDLE_ID"
echo ""
echo "🔄 Next steps:"
echo "   1. Restart WhisperShortcut to see the changes"
echo "   2. The app will behave as if it's the first time running"
echo ""
echo "💡 Tip: You can also use this command manually:"
echo "   defaults delete $BUNDLE_ID"
