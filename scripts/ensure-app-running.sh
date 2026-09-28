#!/bin/bash
# Put the user's WhisperShortcut back if development left it stopped.
#
#     bash scripts/ensure-app-running.sh
#
# Tests, gates and the run-whisper-shortcut driver all stop the app, and any of them can die
# before relaunching it (tool timeout, SIGKILL, an early `return`). This is the one place that
# restores it: the scripts call it after they are done with the app, and a Claude Code Stop hook
# (.claude/settings.json) calls it at the end of every agent turn as a backstop.
#
# Always launches the MAIN checkout's build — never a worktree's, whose binary vanishes (and
# loses the microphone) when the worktree is removed. Does nothing when an instance is already
# running, when something currently owns the app (a test run, a rebuild), or on CI.

[[ "${CI:-}" == "true" ]] && exit 0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MAIN_ROOT="${PROJECT_DIR%%/.claude/worktrees/*}"
MAIN_APP="$MAIN_ROOT/build/DerivedData/Build/Products/Debug/WhisperShortcut.app"

# Already running (direct or App Store build, or a test host).
pgrep -x WhisperShortcut >/dev/null 2>&1 && exit 0
pgrep -x WhisperShortcut-AppStore >/dev/null 2>&1 && exit 0

# Someone stopped it on purpose and will bring it back: a test run needs it gone, and
# rebuild-and-restart.sh is between its kill and its launch.
pgrep -f 'xcodebuild (.* )?test( |$)' >/dev/null 2>&1 && exit 0
pgrep -f 'rebuild-and-restart\.sh' >/dev/null 2>&1 && exit 0

if [[ ! -d "$MAIN_APP" ]]; then
  echo "ℹ️  WhisperShortcut is not running and there is no build at $MAIN_APP — run scripts/rebuild-and-restart.sh."
  exit 0
fi

echo "🚀 WhisperShortcut was not running — relaunching $MAIN_APP"
open "$MAIN_APP" || echo "⚠️  could not relaunch $MAIN_APP"
exit 0
