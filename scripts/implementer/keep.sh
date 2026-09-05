#!/usr/bin/env bash
# Keep an ASK row instead of leaving it to sit — the inverse of veto.sh.
#
#     bash scripts/implementer/keep.sh 7          # park it in the BUILD lane
#     bash scripts/implementer/keep.sh 7 VETO     # park it in the VETO lane
#
# It PARKS rather than releases: the row waits in DEFERRED for a free build slot, so keeping
# ten rows queues ten builds behind the in-flight cap instead of starting ten at once.
#
# BUILD means "my yes replaces the veto window" and is the right answer on a row you filed
# yourself. VETO keeps the window: when a slot frees, the row is announced and anyone still has
# the days to stop it.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ $# -ge 1 && $# -le 2 ]] || { echo "usage: keep.sh <queue-row-number> [BUILD|VETO]" >&2; exit 2; }
exec python3 "${SCRIPT_DIR}/queue-edit.py" keep "$@"
