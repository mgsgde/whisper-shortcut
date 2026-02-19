#!/bin/bash

# reset-restart-logs.sh
# Resets WhisperShortcut to defaults, rebuilds & restarts the app, then streams logs.
# Usage: bash scripts/reset-restart-logs.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

echo "🔄 Reset → Rebuild & Restart → Logs"
echo "===================================="
echo ""

# 1. Reset to defaults
echo "1️⃣  Resetting to defaults..."
bash "$SCRIPT_DIR/reset-whisper-defaults.sh"
echo ""

# 2. Rebuild and restart
echo "2️⃣  Rebuilding and restarting..."
bash "$SCRIPT_DIR/rebuild-and-restart.sh"
echo ""

# 3. Stream logs (foreground; Ctrl+C to stop)
echo "3️⃣  Starting log stream (Ctrl+C to stop)..."
echo ""
exec bash "$SCRIPT_DIR/logs.sh" "$@"
