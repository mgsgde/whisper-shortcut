#!/bin/bash
# reset-whisper-defaults.sh
# Resets WhisperShortcut to factory defaults.
#
# What gets reset:
#   - UserDefaults (all settings: prompts, shortcuts, notifications, etc.)
#   - Application Support: WhisperShortcut/UserContext/ (user-context.md,
#     suggested prompts, interaction logs for "Generate with AI")
#
# What is NOT touched:
#   - Keychain (Google API key is kept)
#   - ~/Documents/WhisperShortcut/ (live meeting transcripts)

set -e

echo "🎙️ WhisperShortcut Reset to Defaults"
echo "====================================="

# Check if we're on macOS
if [[ "$OSTYPE" != "darwin"* ]]; then
    echo "❌ Error: This script only works on macOS"
    exit 1
fi

BUNDLE_ID="com.magnusgoedde.whispershortcut"
CONTEXT_DIR="$HOME/Library/Application Support/WhisperShortcut/UserContext"
PLIST_PATH="$HOME/Library/Preferences/$BUNDLE_ID.plist"

# --- UserDefaults ---
echo ""
echo "📋 Current UserDefaults for $BUNDLE_ID:"
echo "----------------------------------------"
if defaults read "$BUNDLE_ID" 2>/dev/null; then
    echo ""
    echo "✅ Found UserDefaults"
else
    echo "ℹ️  No UserDefaults found"
fi

echo ""
echo "🗑️  Resetting UserDefaults..."
defaults delete "$BUNDLE_ID" 2>/dev/null || true

if [[ -f "$PLIST_PATH" ]]; then
    echo "📄 Removing plist: $PLIST_PATH"
    rm "$PLIST_PATH"
fi

# --- Application Support (UserContext) ---
echo ""
echo "🗑️  Resetting User Context / suggested prompts..."
if [[ -d "$CONTEXT_DIR" ]]; then
    rm -rf "$CONTEXT_DIR"
    echo "✅ Removed: $CONTEXT_DIR"
else
    echo "ℹ️  No UserContext directory found"
fi

echo ""
echo "✅ Done. Reset: UserDefaults + UserContext."
echo ""
echo "🔄 Next steps:"
echo "   1. Restart WhisperShortcut to see the changes"
echo "   2. System prompts and settings will use app defaults"
echo ""
echo "💡 Not reset: API key (Keychain), live meeting transcripts (Documents)."
