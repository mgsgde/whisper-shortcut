#!/usr/bin/env bash
# Load the 22:00–07:00 keep-awake agent. Idempotent.  --remove unloads and deletes it.
set -euo pipefail
LABEL=com.whispershortcut.night-awake
SRC="$(cd "$(dirname "$0")" && pwd)/${LABEL}.plist"
DST="$HOME/Library/LaunchAgents/${LABEL}.plist"
launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
if [[ "${1:-}" == "--remove" ]]; then rm -f "$DST"; echo "Removed ${LABEL}"; exit 0; fi
cp "$SRC" "$DST"
launchctl bootstrap "gui/$(id -u)" "$DST"
echo "Installed ${LABEL}: caffeinate nightly 22:00 for 9 h"
