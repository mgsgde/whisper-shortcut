# shellcheck shell=bash
# shellcheck disable=SC2034  # the XCODEBUILD_* settings are consumed by the sourcing scripts
# Run a command under a wall-clock limit — sourced by the implementer scripts for xcodebuild.
#
#     run_with_timeout <seconds> <log_file> <command…>
#
# stdout+stderr go to <log_file>, stdin is /dev/null (xcodebuild reads it and would swallow a
# caller's `read` loop). Returns the command's exit code, or 124 when the limit hit.
#
# The command runs in its OWN process group and the watchdog kills the whole group: killing just
# xcodebuild's pid leaves xctest and the test host app alive, still holding the tick lock's
# worktree and the Mac's screen (a test step hung 12:37–23:23 on 2026-10-19). `setpgrp` is done
# in perl because macOS ships no setsid(1) and `set -m` would change every other job in the
# calling script.

# Defaults for the two xcodebuild shapes; callers may override from the env file.
XCODEBUILD_BUILD_TIMEOUT_SECONDS="${IMPLEMENTER_XCODEBUILD_BUILD_TIMEOUT_SECONDS:-2400}"
XCODEBUILD_TEST_TIMEOUT_SECONDS="${IMPLEMENTER_XCODEBUILD_TEST_TIMEOUT_SECONDS:-3600}"
# Per-test cap on top of the whole-run cap; parallel testing stays off (scripts/run-tests.sh
# documents why — parallel clones launch several test hosts and one wedges the others).
XCODEBUILD_TEST_TIMEOUT_ARGS=(
    -test-timeouts-enabled YES -maximum-test-execution-time-allowance 600
    -parallel-testing-enabled NO
)

run_with_timeout() {
    local secs="$1" log_file="$2" pid watchdog rc timeout_flag sleeper
    shift 2
    timeout_flag="${log_file}.timed-out"
    rm -f "$timeout_flag"
    perl -e 'setpgrp(0, 0); exec @ARGV or die "exec failed: $!\n"' "$@" </dev/null >"$log_file" 2>&1 &
    pid=$!
    (
        sleep "$secs"
        : >"$timeout_flag"
        kill -TERM -- "-${pid}" 2>/dev/null
        sleep 15
        kill -KILL -- "-${pid}" 2>/dev/null
    ) &
    watchdog=$!
    disown "$watchdog" 2>/dev/null
    wait "$pid" 2>/dev/null; rc=$?
    # The watchdog's own `sleep` is a child of the subshell and would outlive it. Note its pid
    # BEFORE killing the subshell (afterwards it is reparented), and kill the subshell first so
    # it cannot wake up and flag a timeout that did not happen.
    sleeper=$(pgrep -P "$watchdog" 2>/dev/null)
    kill "$watchdog" 2>/dev/null
    # shellcheck disable=SC2086
    [[ -z "$sleeper" ]] || kill $sleeper 2>/dev/null
    wait "$watchdog" 2>/dev/null
    if [[ -f "$timeout_flag" ]]; then
        rm -f "$timeout_flag"
        # A flag with rc=0 is the race where the command finished green and the watchdog woke
        # before it was killed: that is a pass, not a timeout. (A command that was really killed
        # by the watchdog never exits 0.)
        (( rc == 0 )) && return 0
        # The leader may have exited on TERM while its children ignored it; the watchdog's own
        # KILL step was just cancelled, so do it here.
        kill -KILL -- "-${pid}" 2>/dev/null
        echo "TIMED OUT after ${secs}s — the command's whole process group was killed." >>"$log_file"
        return 124
    fi
    return "$rc"
}

# Reap what the group kill cannot reach: xcodebuild's children that made their own process group
# or session (xctest, the test host app, swift-frontend, LaunchServices-launched processes). A
# call site runs this when run_with_timeout returned 124, with the directory it built in —
# `<dir>/` is in every one of those command lines (derivedDataPath, the test host's path), and
# scoping by it leaves the operator's own xcodebuilds and the installed release alone.
# Needs kill_unprotected from daily-app.sh (both callers source it).
reap_timed_out_orphans() { # reap_timed_out_orphans <build-dir>
    local dir="$1" pattern
    [[ -n "$dir" && "$dir" != "/" ]] || return 0
    pattern=$(printf '%s' "${dir%/}/" | sed 's/[][\\.*^$+?(){}|]/\\&/g')
    kill_unprotected -f "$pattern"
}

# run_with_timeout for the gates: on a timeout, also reap the orphans of the current directory
# (the worktree the call site cd'd into). Every xcodebuild gate calls this, not run_with_timeout.
run_gate_with_timeout() { # run_gate_with_timeout <seconds> <log_file> <command…>
    local rc=0
    run_with_timeout "$@" || rc=$?
    if (( rc == 124 )); then
        reap_timed_out_orphans "$PWD"
    fi
    return "$rc"
}
