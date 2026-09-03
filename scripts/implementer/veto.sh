#!/usr/bin/env bash
# Stop a VETO row before its window runs out — the operator's only obligation in that lane.
#
#     bash scripts/implementer/veto.sh 7
#
# The row becomes ASK: it does not build unattended any more, but it stays in the queue as a
# decision to make. A stopped proposal is still a finding somebody had.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ $# -eq 1 ]] || { echo "usage: veto.sh <queue-row-number>" >&2; exit 2; }
exec python3 "${SCRIPT_DIR}/queue-edit.py" veto "$1"
