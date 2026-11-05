#!/bin/bash
# Shared helper: a machine-wide mutex so only ONE Xcode build/test run happens on this Mac at a
# time. Sourced by run-tests.sh (and any other script that starts a heavy xcodebuild).
#
# Why it exists (2026-11-03): seven run-tests.sh runs were alive at once (three Claude Code
# sessions, a Cursor session, a Grok implementer run, one orphan). Load average 162 on 10 cores,
# swap 10.5 of 11 GB, and nothing finished: the oldest run had 18 seconds of CPU after 14 minutes
# 48 seconds of wall clock. This machine (10 cores, 16 GB) has room for exactly one test run.
# The per-checkout DerivedData in run-tests.sh removed the only thing that used to limit
# concurrency (parallel runs cancelling each other); this replaces it with a real lock.
#
# Knobs (environment):
#   BUILD_LOCK_WAIT_SECONDS   how long to wait for a held lock; default 1200. 0 = do not wait,
#                             fail at once (retry loops and the hourly tick use this).
#   BUILD_LOCK_MIN_FREE_GB    refuse to build below this much free space on /; default 20.
#
# Both refusals return 75 = EX_TEMPFAIL from sysexits.h: "busy, try later". A caller must be
# able to tell that apart from 1 = "the tests failed", so never turn 75 into 1.

BUILD_LOCK_DIR="/tmp/whispershortcut-build.lock"
# Set once this process owns the lock; release_build_lock only acts when it is non-empty.
BUILD_LOCK_HELD=""

# Lock holder's pid and start time, for messages. Either may be missing mid-acquire.
_build_lock_holder() {
  local pid since
  pid=$(cat "$BUILD_LOCK_DIR/pid" 2>/dev/null || true)
  since=$(cat "$BUILD_LOCK_DIR/since" 2>/dev/null || true)
  echo "pid ${pid:-unknown} since ${since:-unknown}"
}

# True when the lock is left over from a run that no longer exists.
_build_lock_is_stale() {
  local pid mtime now
  pid=$(cat "$BUILD_LOCK_DIR/pid" 2>/dev/null || true)
  if [[ -n "$pid" ]]; then
    kill -0 "$pid" 2>/dev/null && return 1
    return 0
  fi
  # No readable pid: either a holder between mkdir and writing its pid (milliseconds) or one that
  # died in that gap. Give it 60 seconds before calling it stale.
  mtime=$(stat -f %m "$BUILD_LOCK_DIR" 2>/dev/null || echo 0)
  now=$(date +%s)
  (( now - mtime > 60 ))
}

acquire_build_lock() {
  local wait_s="${BUILD_LOCK_WAIT_SECONDS:-1200}"
  local min_gb="${BUILD_LOCK_MIN_FREE_GB:-20}"
  local free_gb waited=0

  # Each checkout's DerivedData is about 5 GB and on 2026-11-03 the disk was at 96 percent
  # (43 GB of 926 GB free): a build that fills the disk is worse than a skipped build.
  free_gb=$(df -g / 2>/dev/null | awk 'END{print $4}')
  if [[ "$free_gb" =~ ^[0-9]+$ ]] && (( free_gb < min_gb )); then
    echo "⛔ Only ${free_gb} GB free on / (need ${min_gb} GB, BUILD_LOCK_MIN_FREE_GB) — not building." >&2
    return 75
  fi

  # mkdir is atomic and macOS has no flock(1).
  while ! mkdir "$BUILD_LOCK_DIR" 2>/dev/null; do
    if _build_lock_is_stale; then
      echo "ℹ️  Breaking stale build lock ($(_build_lock_holder))."
      rm -rf "$BUILD_LOCK_DIR"
      continue
    fi
    if (( waited >= wait_s )); then
      echo "⛔ Another Xcode run holds the machine ($(_build_lock_holder)); gave up after ${waited}s. Try again later." >&2
      return 75
    fi
    if (( waited > 0 && waited % 60 == 0 )); then
      echo "⏳ Waiting for the build lock held by $(_build_lock_holder) (${waited}s of ${wait_s}s)..."
    fi
    sleep 1
    waited=$((waited + 1))
  done

  echo "$$" > "$BUILD_LOCK_DIR/pid"
  date +%H:%M > "$BUILD_LOCK_DIR/since"
  BUILD_LOCK_HELD="$BUILD_LOCK_DIR"
  return 0
}

# Remove the lock, but only if this process owns it: never another run's.
release_build_lock() {
  [[ -n "$BUILD_LOCK_HELD" ]] || return 0
  if [[ "$(cat "$BUILD_LOCK_DIR/pid" 2>/dev/null || true)" == "$$" ]]; then
    rm -rf "$BUILD_LOCK_DIR"
  fi
  BUILD_LOCK_HELD=""
  return 0
}
