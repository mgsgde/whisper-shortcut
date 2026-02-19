#!/bin/bash
# reset-whisper-defaults.sh
# Resets WhisperShortcut to factory defaults.
#
# What gets reset:
#   - UserDefaults (all settings: prompts, shortcuts, notifications, etc.)
#   - Application Support: WhisperShortcut/UserContext/
#     (user-context.md, suggested prompts, and all historical interaction data:
#      interactions-YYYY-MM-DD.jsonl used for Smart Improvement / "Generate with AI")
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
# Non-sandbox (App Sandbox disabled) and sandbox (when enabled) locations
CONTEXT_DIR_MAIN="$HOME/Library/Application Support/WhisperShortcut/UserContext"
CONTEXT_DIR_SANDBOX="$HOME/Library/Containers/$BUNDLE_ID/Data/Library/Application Support/WhisperShortcut/UserContext"
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

# Remove plist in main Preferences and in sandbox container (if app was ever run sandboxed)
PLIST_SANDBOX="$HOME/Library/Containers/$BUNDLE_ID/Data/Library/Preferences/$BUNDLE_ID.plist"
for P in "$PLIST_PATH" "$PLIST_SANDBOX"; do
    if [[ -f "$P" ]]; then
        echo "📄 Removing plist: $P"
        rm "$P"
    fi
done

# --- Application Support (UserContext) ---
# Clear both possible locations (non-sandbox and sandboxed app)
echo ""
echo "🗑️  Resetting User Context / suggested prompts / interaction logs..."
for CONTEXT_DIR in "$CONTEXT_DIR_MAIN" "$CONTEXT_DIR_SANDBOX"; do
    if [[ -d "$CONTEXT_DIR" ]]; then
        rm -rf "$CONTEXT_DIR"
        echo "✅ Removed: $CONTEXT_DIR"
    fi
done
if [[ ! -d "$CONTEXT_DIR_MAIN" && ! -d "$CONTEXT_DIR_SANDBOX" ]]; then
    echo "ℹ️  No UserContext directory found (checked both main and sandbox paths)"
fi

echo ""
echo "✅ Done. Reset: UserDefaults + UserContext."
echo ""
echo "🔄 Next steps:"
echo "   1. Restart WhisperShortcut to see the changes"
echo "   2. System prompts and settings will use app defaults"
echo ""
echo "💡 Not reset: API key (Keychain), live meeting transcripts (Documents)."
