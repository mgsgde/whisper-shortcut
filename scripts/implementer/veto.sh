#!/usr/bin/env bash
# Stop something before it happens — the operator's only obligation in the automatic lanes.
#
#     bash scripts/implementer/veto.sh 7
#
# One verb for both windows, because at the moment you reach for a stop button you should not
# have to work out which kind of window you are in:
#
#   * a MERGE window (the row was built, gated and reviewed, and merges into main on its
#     deadline) → the window is closed and the branch and worktree are KEPT. A stopped merge is
#     not a rejected change; the queue row goes to ASK so no tick rebuilds it, and the branch
#     is yours to merge, fix or drop.
#   * a BUILD or VETO row that has not run yet → back to ASK/OPEN. It does not build unattended
#     any more, but it stays in the queue as a decision to make. A stopped proposal is still a
#     finding somebody had.
#
# The inverse is keep.sh. This script only ever RECORDS the veto; the hourly tick carries it
# out, so there is exactly one writer for each file.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ $# -eq 1 ]] || { echo "usage: veto.sh <queue-row-number>" >&2; exit 2; }
NUM="$1"

WINDOW="${HOME}/.local/state/whispershortcut-implementer/merge-windows/q${NUM}.env"
if [[ -f "$WINDOW" ]]; then
    if grep -q '^VETOED=1$' "$WINDOW"; then
        echo "merge window for #${NUM} is already stopped — the next tick closes it out"
        exit 0
    fi
    # Rewritten rather than appended: `source` takes the last assignment, so an appended line
    # would work, but a file with two VETOED= lines is a file somebody will misread later.
    python3 - "$WINDOW" <<'PY'
import sys
path = sys.argv[1]
lines = [l for l in open(path, encoding="utf-8").read().splitlines() if not l.startswith("VETOED=")]
lines.append("VETOED=1")
open(path, "w", encoding="utf-8").write("\n".join(lines) + "\n")
PY
    echo "merge window for #${NUM} stopped — it will NOT merge into main."
    echo "The branch and its worktree are kept. The next tick closes the window and sets the"
    echo "queue row to ASK, so nothing rebuilds it."
    exit 0
fi

exec python3 "${SCRIPT_DIR}/queue-edit.py" veto "$NUM"
