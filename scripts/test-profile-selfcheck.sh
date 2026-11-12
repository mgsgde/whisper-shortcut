#!/bin/bash
# Proves that a test profile leaves the daily instances alone.
#
#     bash scripts/test-profile-selfcheck.sh [--no-build] [profile-name]   # default name: selfcheck
#
# 1. Records the release's and the Dev build's defaults plists and data folders (sha-256 of every
#    file; size + mtime for the large model folders), their running pids, and the login keychain.
# 2. Launches a --fresh profile with --profile-selfcheck: the app itself flips settings through
#    UserDefaults.standard, adds a glossary word through SystemPromptsStore and stores a dummy key
#    through KeychainManager, then reports where they landed (profile-selfcheck.json).
# 3. Checks that report, quits the profile by its own pid, and asserts that every recorded file is
#    byte-identical, every recorded process kept its pid, and the dummy key is in no keychain.
# Exit 0 only when every check passed. Never stops, restarts or edits anything but the profile.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/test-profile.sh
source "$SCRIPT_DIR/lib/test-profile.sh"

BUILD_ARGS=()
PROFILE=selfcheck
for arg in "$@"; do
  case "$arg" in
    --no-build) BUILD_ARGS+=(--no-build) ;;
    *) PROFILE="$arg" ;;
  esac
done
profile_valid_name "$PROFILE" || { echo "invalid profile name: $PROFILE" >&2; exit 2; }

DAILY_IDS=(com.magnusgoedde.whispershortcut com.magnusgoedde.whispershortcut.dev)
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ws-profile-selfcheck.XXXXXX")"
FAILED=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; FAILED=1; }

# Everything of one daily instance a profile could conceivably write to.
snapshot() {
  local out="$1" id data
  : > "$out"
  for id in "${DAILY_IDS[@]}"; do
    data="$HOME/Library/Containers/$id/Data"
    [[ -d "$data" ]] || continue
    # Defaults: the domain plist itself (the UUID-named plists next to it belong to system frameworks).
    [[ -f "$data/Library/Preferences/$id.plist" ]] && shasum -a 256 "$data/Library/Preferences/$id.plist" >> "$out"
    # The app's data root: hash everything except the model folders, which only get size + mtime.
    find "$data/Library/Application Support/WhisperShortcut" -type f \
      -not -path "*/WhisperShortcut/WhisperKit/*" -not -path "*/WhisperShortcut/MLXModels/*" \
      -not -path "*/WhisperShortcut/Qwen3Models/*" \
      -print0 2>/dev/null | xargs -0 shasum -a 256 2>/dev/null >> "$out"
    for rel in "${PROFILE_MODEL_PATHS[@]}"; do
      [[ -d "$data/$rel" ]] && find "$data/$rel" -type f -exec stat -f '%z %m %N' {} + 2>/dev/null >> "$out"
    done
  done
  for f in "$HOME"/Library/Preferences/com.magnusgoedde.whispershortcut*.plist; do
    [[ -f "$f" ]] && shasum -a 256 "$f" >> "$out"
  done
  sort -o "$out" "$out"
}

# pid + command of every WhisperShortcut process that is not this profile.
other_processes() {
  local profile_app; profile_app="$(profile_app_path "$PROJECT_DIR" "$PROFILE")"
  ps -axo pid=,command= | grep -E '/WhisperShortcut[^/]*\.app/Contents/MacOS/' | grep -v grep \
    | grep -vF "$profile_app/" | sed 's/^ *//' | sort
}

echo "== Test profile self-check (profile \"$PROFILE\") =="
if ! bash "$SCRIPT_DIR/meeting-guard.sh"; then
  echo "A meeting is recording; not launching anything." >&2
  exit 1
fi

snapshot "$WORK/before.txt"
other_processes > "$WORK/procs-before.txt"
echo "Recorded $(wc -l < "$WORK/before.txt" | tr -d ' ') files of the daily instances; other WhisperShortcut processes:"
sed 's/^/  /' "$WORK/procs-before.txt"
[[ -s "$WORK/procs-before.txt" ]] || echo "  (none)"

echo "-- launching a fresh profile"
bash "$SCRIPT_DIR/rebuild-and-restart.sh" --sidecar --profile "$PROFILE" --fresh \
  ${BUILD_ARGS[@]+"${BUILD_ARGS[@]}"} --app-arg --profile-selfcheck > "$WORK/launch.log" 2>&1
launch_rc=$?
grep -E '^(🧽|🧪|   bundle id|❌|⏭️|✅ Build)' "$WORK/launch.log" | sed 's/^/  /'
if [[ $launch_rc -ne 0 ]]; then
  fail "profile launch (exit $launch_rc); full log: $WORK/launch.log"
  exit 1
fi

PROFILE_APP="$(profile_app_path "$PROJECT_DIR" "$PROFILE")"
PROFILE_PID="$(pgrep -f "$PROFILE_APP/Contents/MacOS" | head -n1)"
REPORT="$(profile_app_support "$PROFILE")/profile-selfcheck.json"
for _ in $(seq 1 60); do [[ -f "$REPORT" ]] && break; sleep 0.5; done

json() { plutil -extract "$1" raw -o - "$REPORT" 2>/dev/null; }
if [[ -f "$REPORT" ]]; then
  pass "profile pid $PROFILE_PID wrote $REPORT"
  [[ "$(json bundleID)" == "$(profile_bundle_id "$PROFILE")" ]] && pass "runs as $(json bundleID)" || fail "bundle id $(json bundleID)"
  [[ "$(json home)" == "$(profile_container "$PROFILE")/Data" ]] && pass "home is the profile container" || fail "home $(json home)"
  [[ "$(json defaultsProbeReadBack)" == true ]] && pass "settings written through UserDefaults.standard" || fail "defaults probe"
  [[ "$(json glossaryContainsWord)" == true ]] && pass "glossary word added through SystemPromptsStore" || fail "glossary word"
  [[ "$(json keychainBackend)" == memory && "$(json keychainReadBack)" == true ]] \
    && pass "dummy key stored in the in-memory keychain" || fail "keychain backend $(json keychainBackend)"
else
  fail "no self-check report at $REPORT"
fi

# Shared models: links into the source container, never copies.
link="$(profile_container "$PROFILE")/Data/Library/Application Support/WhisperShortcut/WhisperKit"
if [[ -L "$link" ]]; then pass "models shared read-only: WhisperKit -> $(readlink "$link")"
else echo "INFO  no WhisperKit link (no model downloaded in the source container)"; fi

echo "-- quitting the profile (its own pid only)"
WS_PROFILE="$PROFILE" bash "$PROJECT_DIR/.agents/skills/run-whisper-shortcut/driver.sh" quit >/dev/null
for _ in $(seq 1 20); do kill -0 "$PROFILE_PID" 2>/dev/null || break; sleep 0.5; done
if kill -0 "$PROFILE_PID" 2>/dev/null; then fail "profile pid $PROFILE_PID still running"; else pass "profile pid $PROFILE_PID quit"; fi

PLIST="$(profile_defaults_plist "$PROFILE")"
probe="$(json probe)"
# cfprefsd writes the plist to disk lazily after the process exits; if it has not yet, ask cfprefsd
# for that exact file (the profile container's plist), which is what the next launch reads.
on_disk=false
for _ in $(seq 1 30); do
  if [[ "$(plutil -extract testProfileSelfcheckProbe raw -o - "$PLIST" 2>/dev/null)" == "$probe" ]]; then on_disk=true; break; fi
  sleep 1
done
if [[ -n "$probe" && "$on_disk" == true ]]; then
  pass "settings landed in the profile's own plist ($PLIST)"
elif [[ -n "$probe" && "$(defaults read "${PLIST%.plist}" testProfileSelfcheckProbe 2>/dev/null)" == "$probe" ]]; then
  pass "settings landed in the profile's own defaults domain (cfprefsd; not flushed to $PLIST within 30 s)"
else
  fail "probe not found in $PLIST"
fi
if grep -q "Zyxqvselfcheck" "$(profile_app_support "$PROFILE")/UserContext/system-prompts.md" 2>/dev/null; then
  pass "glossary word landed in the profile's own system-prompts.md"
else
  fail "glossary word not in the profile's system-prompts.md"
fi

snapshot "$WORK/after.txt"
other_processes > "$WORK/procs-after.txt"
if cmp -s "$WORK/before.txt" "$WORK/after.txt"; then
  pass "daily instances: all $(wc -l < "$WORK/after.txt" | tr -d ' ') recorded files byte-identical (defaults plists, data folders, model folders)"
else
  fail "daily instance files changed:"
  diff "$WORK/before.txt" "$WORK/after.txt" | sed 's/^/      /' | head -40
fi
if cmp -s "$WORK/procs-before.txt" "$WORK/procs-after.txt"; then
  pass "other WhisperShortcut processes unchanged ($(wc -l < "$WORK/procs-after.txt" | tr -d ' '), same pids)"
else
  fail "other WhisperShortcut processes changed:"
  diff "$WORK/procs-before.txt" "$WORK/procs-after.txt" | sed 's/^/      /'
fi
if security find-generic-password -s com.whispershortcut.openai -a test-profile-selfcheck >/dev/null 2>&1; then
  fail "the dummy key reached the login keychain"
else
  pass "dummy key is in no login keychain item"
fi
for id in "${DAILY_IDS[@]}"; do
  if grep -q Zyxqvselfcheck "$HOME/Library/Containers/$id/Data/Library/Application Support/WhisperShortcut/UserContext/system-prompts.md" 2>/dev/null; then
    fail "glossary word found in $id"
  fi
done

rm -rf "$WORK"
if [[ $FAILED -eq 0 ]]; then echo "RESULT: PASS"; else echo "RESULT: FAIL"; fi
exit $FAILED
