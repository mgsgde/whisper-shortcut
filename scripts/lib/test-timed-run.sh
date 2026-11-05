#!/usr/bin/env bash
# Self-test for timed-run.sh — no Xcode involved.
#
#     bash scripts/lib/test-timed-run.sh [path/to/timed-run.sh]
#
# Proves: (a) a child that left the process group survives the group kill but dies in the
# orphan sweep; (b) a command that exits 0 while the timeout flag is set is a pass, not 124;
# plus the plain timeout / exit-code paths. Exits non-zero on the first failed check.
set -uo pipefail
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=daily-app.sh
source "${LIB_DIR}/daily-app.sh"
# shellcheck source=timed-run.sh
source "${1:-${LIB_DIR}/timed-run.sh}"

WORK="$(mktemp -d /tmp/timed-run-test.XXXXXX)"
trap 'pkill -f "${WORK}/build/" 2>/dev/null; rm -rf "$WORK"' EXIT
mkdir -p "$WORK/build"; ln -s /bin/sleep "$WORK/build/hostsleep"   # a "test host": worktree path in its argv[0]
FAILED=0
check() { # check <name> <expected> <actual>
    if [[ "$2" == "$3" ]]; then echo "ok    $1 (=$3)"; else echo "FAIL  $1: expected $2, got $3"; FAILED=1; fi
}

# plain paths
run_with_timeout 5 "$WORK/a.log" bash -c 'echo hi; exit 3'; check "exit code passes through" 3 $?
run_with_timeout 5 "$WORK/b.log" true;                       check "success is 0" 0 $?
run_with_timeout 1 "$WORK/c.log" sleep 60;                   check "hung command times out" 124 $?
grep -q 'TIMED OUT' "$WORK/c.log";                           check "timeout is written to the log" 0 $?

# (b) success + late flag: the command traps the watchdog's TERM and exits 0, i.e. the timeout
# flag exists AND wait returned 0. That must be a pass.
run_with_timeout 1 "$WORK/d.log" bash -c 'trap "exit 0" TERM; sleep 30 & wait'
check "rc=0 with the timeout flag set returns 0" 0 $?

# (a) a child in its OWN process group, with the worktree path in its command line (what an
# xcodebuild test host looks like), outlives the group kill ...
run_with_timeout 1 "$WORK/e.log" bash -c \
    "perl -e 'setpgrp(0,0); exec \"${WORK}/build/hostsleep\",\"777\"' & wait"
check "parent still times out" 124 $?
sleep 1
pgrep -f "hostsleep 777" >/dev/null; check "setpgrp child survives the group kill (why the sweep exists)" 0 $?
# ... and the sweep, scoped to the directory, takes it down.
reap_timed_out_orphans "$WORK" >/dev/null
sleep 1
pgrep -f "hostsleep 777" >/dev/null; check "setpgrp child is dead after reap_timed_out_orphans" 1 $?

# Toolchain orphans live under /Applications (/Applications/Xcode.app/…/xctest, swift-frontend)
# and carry the worktree path in their command line: they must die, while the installed release
# must survive. Fake argv0s via perl's indirect exec; nothing is written under /Applications.
perl -e 'exec {"/bin/sleep"} $ARGV[0], "779"' "/Applications/Xcode.app/Contents/Developer/usr/bin/xctest ${WORK}/build/x" & disown
perl -e 'exec {"/bin/sleep"} $ARGV[0], "780"' "/Applications/WhisperShortcut.app/Contents/MacOS/WhisperShortcut ${WORK}/build/y" & disown
sleep 1
pgrep -f "xctest ${WORK}" >/dev/null; check "fake /Applications/Xcode.app xctest is running" 0 $?
reap_timed_out_orphans "$WORK" >/dev/null
sleep 1
pgrep -f "xctest ${WORK}" >/dev/null; check "xctest under /Applications/Xcode.app is reaped" 1 $?
pgrep -f "WhisperShortcut.app/Contents/MacOS/WhisperShortcut ${WORK}" >/dev/null
check "installed release (/Applications/WhisperShortcut*) is spared" 0 $?
pkill -f "WhisperShortcut.app/Contents/MacOS/WhisperShortcut ${WORK}" 2>/dev/null

# the call-site wrapper does both in one go
( cd "$WORK" && run_gate_with_timeout 1 "$WORK/f.log" bash -c \
    "perl -e 'setpgrp(0,0); exec \"${WORK}/build/hostsleep\",\"778\"' & wait" ) >/dev/null
check "run_gate_with_timeout returns 124" 124 $?
sleep 1
pgrep -f "hostsleep 778" >/dev/null; check "run_gate_with_timeout leaves no orphan" 1 $?

(( FAILED == 0 )) && echo "ALL PASSED" || { echo "SOME CHECKS FAILED"; exit 1; }
