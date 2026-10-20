#!/bin/bash
# Refuse to stop WhisperShortcut while it is recording a live meeting.
#
#     bash scripts/meeting-guard.sh             # exit 1 (with a message) if any instance records a meeting
#     bash scripts/meeting-guard.sh --dev-only  # ignore the /Applications release (for scripts that
#                                               # never stop it: rebuild-and-restart, run-tests, driver)
#
# On 2026-10-20 an update script quit the running app mid-meeting and the last eight minutes were
# never recorded. The app keeps a marker file (live-meeting-recording.json, see
# LiveMeetingRecordingMarker.swift) while a meeting records; every script that kills or quits the
# app calls this first. A stale marker (its pid is dead) or one left by a deliberate user Quit is
# ignored. Override with ALLOW_STOP_DURING_MEETING=1.

DEV_ONLY=false
[[ "${1:-}" == "--dev-only" ]] && DEV_ONLY=true

IDS=(com.magnusgoedde.whispershortcut com.magnusgoedde.whispershortcut.dev)
FILES=()
for id in "${IDS[@]}"; do
  FILES+=("$HOME/Library/Containers/$id/Data/Library/Application Support/WhisperShortcut/live-meeting-recording.json")
done
FILES+=("$HOME/Library/Application Support/WhisperShortcut/live-meeting-recording.json")

for f in "${FILES[@]}"; do
  [[ -f "$f" ]] || continue
  pid=$(plutil -extract pid raw -o - "$f" 2>/dev/null) || continue
  stem=$(plutil -extract stem raw -o - "$f" 2>/dev/null || echo "unknown")
  user_quit=$(plutil -extract userQuit raw -o - "$f" 2>/dev/null || echo "false")
  [[ "$pid" =~ ^[0-9]+$ ]] || continue
  kill -0 "$pid" 2>/dev/null || continue
  if [[ "$DEV_ONLY" == true ]]; then
    cmd=$(ps -o command= -p "$pid" 2>/dev/null || true)
    [[ "$cmd" == /Applications/* ]] && continue
  fi
  [[ "$user_quit" == "true" || "$user_quit" == "1" ]] && continue

  if [[ "${ALLOW_STOP_DURING_MEETING:-}" == "1" ]]; then
    echo "⚠️  WhisperShortcut is recording a meeting ($stem, pid $pid) — stopping anyway (ALLOW_STOP_DURING_MEETING=1)." >&2
    exit 0
  fi
  echo "❌ WhisperShortcut is recording a meeting ($stem, pid $pid). Stopping the app now would cut the recording. Stop the meeting first, or rerun with ALLOW_STOP_DURING_MEETING=1." >&2
  exit 1
done
exit 0
