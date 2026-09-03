#!/usr/bin/env bash
# Put the hourly implementer tick under launchd. Idempotent — re-running reloads it.
#
#     bash scripts/implementer/install-tick.sh          # install / reload
#     bash scripts/implementer/install-tick.sh --remove # unload and delete
#
# The tick itself does nothing until BOTH switches in ~/.config/whispershortcut-implementer/env
# are 1 (IMPLEMENTER_ENABLED, IMPLEMENTER_TICK_ENABLED), so installing this is safe and
# reversible on its own. Architecture: plans/agent-loops.md.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LABEL="com.whispershortcut.implementer-tick"
SRC="${SCRIPT_DIR}/${LABEL}.plist"
DEST="${HOME}/Library/LaunchAgents/${LABEL}.plist"

if [[ "${1:-}" == "--remove" ]]; then
    launchctl unload "$DEST" 2>/dev/null || true
    rm -f "$DEST"
    echo "Removed ${DEST}"
    exit 0
fi

# The plist's bootstrap runs `git show origin/main:scripts/implementer/tick.sh`. Installing it
# while that file is not on main yet means every hour falls through to the working tree — which
# is whatever branch the shared checkout is sitting on. Refuse rather than schedule that.
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
if ! git -C "$REPO_ROOT" cat-file -e origin/main:scripts/implementer/tick.sh 2>/dev/null; then
    echo "REFUSING: scripts/implementer/tick.sh is not on origin/main yet." >&2
    echo "Merge the branch first — the plist bootstraps from main by design." >&2
    exit 1
fi

mkdir -p "${HOME}/Library/LaunchAgents"
launchctl unload "$DEST" 2>/dev/null || true
cp "$SRC" "$DEST"
launchctl load "$DEST"
echo "Installed and loaded ${DEST} (hourly)."
echo
echo "It stays inert until you arm it in ~/.config/whispershortcut-implementer/env:"
echo "    IMPLEMENTER_ENABLED=1"
echo "    IMPLEMENTER_TICK_ENABLED=1"
echo
echo "Logs: build/logs/implementer/tick-\$(date +%F).log  ·  /tmp/${LABEL}.{out,err}"
