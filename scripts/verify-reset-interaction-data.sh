#!/bin/bash
# verify-reset-interaction-data.sh
# Verifies that reset-whisper-defaults.sh correctly deletes interaction data
# in both locations (non-sandbox and sandbox). Creates dummy data, runs the
# same deletion logic, then checks both paths are gone. Does NOT touch UserDefaults.

set -e

BUNDLE_ID="com.magnusgoedde.whispershortcut"
CONTEXT_DIR_MAIN="$HOME/Library/Application Support/WhisperShortcut/UserContext"
CONTEXT_DIR_SANDBOX="$HOME/Library/Containers/$BUNDLE_ID/Data/Library/Application Support/WhisperShortcut/UserContext"

echo "🔍 Verify: Interaction data deletion (main + sandbox paths)"
echo "============================================================"

# 1. Create dummy UserContext dirs and interaction files in both locations
echo ""
echo "1️⃣  Creating dummy interaction data in both paths..."
for CONTEXT_DIR in "$CONTEXT_DIR_MAIN" "$CONTEXT_DIR_SANDBOX"; do
    mkdir -p "$CONTEXT_DIR"
    echo '{"mode":"transcription","timestamp":"2025-02-19T12:00:00.000Z","text":"test"}' > "$CONTEXT_DIR/interactions-2025-02-19.jsonl"
    echo "# test" > "$CONTEXT_DIR/user-context.md"
    echo "   Created: $CONTEXT_DIR (interactions-*.jsonl + user-context.md)"
done

# 2. Verify files exist
echo ""
echo "2️⃣  Verifying dummy data exists..."
FAIL=0
for CONTEXT_DIR in "$CONTEXT_DIR_MAIN" "$CONTEXT_DIR_SANDBOX"; do
    if [[ -d "$CONTEXT_DIR" && -f "$CONTEXT_DIR/interactions-2025-02-19.jsonl" ]]; then
        echo "   ✅ $CONTEXT_DIR"
    else
        echo "   ❌ Missing or invalid: $CONTEXT_DIR"
        FAIL=1
    fi
done
[[ $FAIL -eq 1 ]] && exit 1

# 3. Run same deletion logic as reset-whisper-defaults.sh
echo ""
echo "3️⃣  Running deletion (same logic as reset-whisper-defaults.sh)..."
for CONTEXT_DIR in "$CONTEXT_DIR_MAIN" "$CONTEXT_DIR_SANDBOX"; do
    if [[ -d "$CONTEXT_DIR" ]]; then
        rm -rf "$CONTEXT_DIR"
        echo "   Removed: $CONTEXT_DIR"
    fi
done

# 4. Verify both paths are gone
echo ""
echo "4️⃣  Verifying both paths are deleted..."
FAIL=0
for CONTEXT_DIR in "$CONTEXT_DIR_MAIN" "$CONTEXT_DIR_SANDBOX"; do
    if [[ -d "$CONTEXT_DIR" ]]; then
        echo "   ❌ Still exists: $CONTEXT_DIR"
        FAIL=1
    else
        echo "   ✅ Gone: $CONTEXT_DIR"
    fi
done

echo ""
if [[ $FAIL -eq 0 ]]; then
    echo "✅ Verification passed: interaction data is correctly deleted in both locations."
    exit 0
else
    echo "❌ Verification failed: some paths were not deleted."
    exit 1
fi
