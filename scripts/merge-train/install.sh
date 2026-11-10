#!/usr/bin/env bash
# Put the merge train and the Monday stale-PR sweep under launchd. Idempotent — re-running reloads them.
#
#     bash scripts/merge-train/install.sh          # install / reload both
#     bash scripts/merge-train/install.sh --remove # unload and delete both
#
# The train is opt-out. See scripts/merge-train/README.md.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE="${HOME}/.local/state/whispershortcut-merge-train"
AGENTS="${HOME}/Library/LaunchAgents"

remove_plist() {
    local label="$1"
    local dest="${AGENTS}/${label}.plist"
    launchctl unload "$dest" 2>/dev/null || true
    rm -f "$dest"
    echo "Removed ${dest}"
}

install_plist() {
    local label="$1" schedule="$2"
    local src="${SCRIPT_DIR}/${label}.plist"
    local dest="${AGENTS}/${label}.plist"
    launchctl unload "$dest" 2>/dev/null || true
    sed "s|__HOME__|${HOME}|g" "$src" >"$dest"
    launchctl load "$dest"
    echo "Installed and loaded ${dest} (${schedule})."
}

if [[ "${1:-}" == "--remove" ]]; then
    remove_plist "com.whispershortcut.merge-train"
    remove_plist "com.whispershortcut.stale-prs"
    exit 0
fi

# Each plist's bootstrap runs `git show origin/main:scripts/merge-train/<script>`. Installing
# before that file is on main would make every run fall through to whatever branch the shared
# checkout is sitting on. Refuse rather than schedule that.
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
missing=()
for rel in scripts/merge-train/train.sh scripts/merge-train/stale-prs.sh; do
    if ! git -C "$REPO_ROOT" cat-file -e "origin/main:${rel}" 2>/dev/null; then
        missing+=("$rel")
    fi
done
if (( ${#missing[@]} > 0 )); then
    echo "REFUSING: not on origin/main yet: ${missing[*]}" >&2
    echo "Merge the branch first — the plists bootstrap from main by design." >&2
    exit 1
fi

mkdir -p "$AGENTS" "$STATE"
install_plist "com.whispershortcut.merge-train" "every 20 minutes"
install_plist "com.whispershortcut.stale-prs" "Mondays at 08:30"
echo
echo "Pause:    touch ${STATE}/PAUSED    # the train only; the Monday list still runs"
echo "Resume:   rm ${STATE}/PAUSED"
echo "Dry run:  bash scripts/merge-train/train.sh --dry-run"
echo "          bash scripts/merge-train/stale-prs.sh --dry-run"
echo "Log:      ${STATE}/launchd.log  ·  ${STATE}/runs.tsv"
echo "          ${STATE}/stale-launchd.log  ·  ${STATE}/stale-runs.tsv"
