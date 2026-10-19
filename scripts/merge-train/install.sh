#!/usr/bin/env bash
# Put the merge train under launchd. Idempotent — re-running reloads it.
#
#     bash scripts/merge-train/install.sh          # install / reload
#     bash scripts/merge-train/install.sh --remove # unload and delete
#
# Nothing is merged until a PR carries the `merge-train` label. See scripts/merge-train/README.md.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LABEL="com.whispershortcut.merge-train"
SRC="${SCRIPT_DIR}/${LABEL}.plist"
DEST="${HOME}/Library/LaunchAgents/${LABEL}.plist"
STATE="${HOME}/.local/state/whispershortcut-merge-train"

if [[ "${1:-}" == "--remove" ]]; then
    launchctl unload "$DEST" 2>/dev/null || true
    rm -f "$DEST"
    echo "Removed ${DEST}"
    exit 0
fi

# The plist's bootstrap runs `git show origin/main:scripts/merge-train/train.sh`. Installing it
# before that file is on main would make every run fall through to whatever branch the shared
# checkout is sitting on. Refuse rather than schedule that.
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
if ! git -C "$REPO_ROOT" cat-file -e origin/main:scripts/merge-train/train.sh 2>/dev/null; then
    echo "REFUSING: scripts/merge-train/train.sh is not on origin/main yet." >&2
    echo "Merge the branch first — the plist bootstraps from main by design." >&2
    exit 1
fi

mkdir -p "${HOME}/Library/LaunchAgents" "$STATE"
launchctl unload "$DEST" 2>/dev/null || true
sed "s|__HOME__|${HOME}|g" "$SRC" >"$DEST"
launchctl load "$DEST"
echo "Installed and loaded ${DEST} (every 20 minutes)."
echo
echo "Pause:    touch ${STATE}/PAUSED"
echo "Resume:   rm ${STATE}/PAUSED"
echo "Dry run:  bash scripts/merge-train/train.sh --dry-run"
echo "Log:      ${STATE}/launchd.log  ·  ${STATE}/runs.tsv"
