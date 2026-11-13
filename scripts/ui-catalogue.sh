#!/bin/bash
# UI catalogue: every screen of a feature, in every state, in English and German, as numbered PNGs
# plus an index.md (screen, state, language → file). Runs only in isolated test profiles
# (scripts/rebuild-and-restart.sh --sidecar --profile …) and quits only its own profile's pid.
#
#   bash scripts/ui-catalogue.sh dictation-only [--out DIR] [--langs "en de"] [--no-build]
#                                               [--audio-de WAV] [--audio-en WAV] [--audio-live-de WAV]
#                                               [--only SLUG[,SLUG…]]
#
# --only captures just those shot slugs (empty: every shot, as before). The block from one
# launch call to the next runs only when it contains a named slug. Unselected shots keep their
# numbers, are not captured, and are left out of the index.
#
# States this Mac cannot produce on demand (🌐 key in conflict, microphone denied, a download at
# 40 %, a full disk, an Intel Mac …) come from the profile-only launch arguments in
# WhisperShortcut/TestProfileOverrides.swift. The test dictation runs on a WAV file instead of the
# microphone (--audio-file); without --audio-<lang> the script makes one with `say`. A given WAV is
# copied into the profile's own container at run time only. The German Dictate Live shot
# (slug live-result) uses --audio-live-de, or a `say` WAV with real pauses, copied the same way
# after launch because --fresh wipes the container.
#
# Needs Accessibility and Screen Recording for the terminal (see the run-whisper-shortcut skill).
# A macOS permission dialog of the profile app itself is photographed, never answered.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/test-profile.sh
source "$SCRIPT_DIR/lib/test-profile.sh"

SET="${1:-}"; shift || true
OUT=""
LANGS="en de"
BUILD=true
AUDIO_DE=""
AUDIO_EN=""
AUDIO_LIVE_DE=""
ONLY=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) OUT="$2"; shift ;;
    --langs) LANGS="$2"; shift ;;
    --no-build) BUILD=false ;;
    --audio-de) AUDIO_DE="$2"; shift ;;
    --audio-en) AUDIO_EN="$2"; shift ;;
    --audio-live-de) AUDIO_LIVE_DE="$2"; shift ;;
    --only) ONLY="${2//[[:space:]]/}"; shift ;;
    *) echo "unknown argument $1" >&2; exit 2 ;;
  esac
  shift
done
case "$SET" in
  dictation-only) ;;
  *) echo "usage: bash scripts/ui-catalogue.sh dictation-only [--out DIR] [--langs \"en de\"] [--no-build] [--only SLUG[,SLUG…]]" >&2; exit 2 ;;
esac
OUT="${OUT:-${TMPDIR:-/tmp}/ws-ui-catalogue/$SET}"
mkdir -p "$OUT"
# A partial run overwrites the shots it takes and leaves the previous pictures in place.
if [[ -z "$ONLY" ]]; then
  rm -f "$OUT"/*.png "$OUT/index.md"
fi
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# SwiftUI buttons here expose no title to Accessibility, so buttons are found by their order in
# the window's content (depth first), always inside the profile's own process (by pid). The walker
# is a small Swift helper (AXUIElementCreateApplication(pid)): System Events addresses processes by
# NAME, and the profile copy is named like the user's daily "WhisperShortcut Dev".
AXWALK="$WORK/ax-walk"
swiftc -O "$SCRIPT_DIR/lib/ax-walk.swift" -o "$AXWALK" 2>&1 | tail -n 5 >&2 || true

N=0
PROFILE=""
L=""
PID=""
# Set by launch when --only names no shot in the caller's block. Helpers that drive the app
# return immediately while it is true. quit_profile does not.
SKIP_BLOCK=false
# Shot slugs that appeared in a launch block this run, for the unknown-slug check.
SEEN=""

# ---------------------------------------------------------------------------------------------
# Strings: the German UI text for an English key, from the string catalogue.
t() {
  if [[ "$L" == en ]]; then printf '%s' "$1"; return; fi
  python3 - "$PROJECT_DIR/WhisperShortcut/Localizable.xcstrings" "$1" "$L" <<'PY'
import json, sys
path, key, lang = sys.argv[1:4]
entry = json.load(open(path))["strings"].get(key, {})
print(entry.get("localizations", {}).get(lang, {}).get("stringUnit", {}).get("value", key), end="")
PY
}

profile_pid() { pgrep -f "$(profile_app_path "$PROJECT_DIR" "$PROFILE")/Contents/MacOS" 2>/dev/null | head -n1 || true; }

ax() {
  [[ "$SKIP_BLOCK" == true ]] && return 0
  osascript -e "tell application \"System Events\" to tell (first process whose unix id is $PID)
$1
end tell" 2>&1
}

# True when slug $1 should be captured. An empty ONLY means every shot.
shot_wanted() {
  [[ -z "$ONLY" ]] && return 0
  case ",${ONLY}," in
    *,"$1",*) return 0 ;;
    *) return 1 ;;
  esac
}

# Remember a slug that exists in the catalogue, so a typo in --only can be reported.
note_slug() {
  case ",${SEEN}," in
    *,"$1",*) ;;
    *) SEEN="${SEEN:+$SEEN,}$1" ;;
  esac
}

# Warn for each --only slug that no launch block contained. Returns 1 when any were unknown.
report_unknown_slugs() {
  [[ -z "$ONLY" ]] && return 0
  local rest="${ONLY}," slug unknown=0
  while [[ "$rest" == *,* ]]; do
    slug="${rest%%,*}"
    rest="${rest#*,}"
    [[ -z "$slug" ]] && continue
    case ",${SEEN}," in
      *,"${slug}",*) ;;
      *) echo "⚠️ unknown slug: ${slug}"; unknown=1 ;;
    esac
  done
  return "$unknown"
}

# launch <app args…>: a fresh profile in language $L. Stops only this profile's previous pid.
# With --only set, the block from this call to the next launch (or the closing brace of the
# catalogue function) is skipped when it contains none of the named shots. A skip does not
# build, and it leaves BUILD set so the first block that does run still builds once.
launch() {
  if [[ -n "$ONLY" ]]; then
    local start line slug src wanted
    start=$(( BASH_LINENO[0] + 1 ))
    src="${BASH_SOURCE[0]:-$0}"
    wanted=false
    while IFS= read -r line; do
      [[ "$line" =~ ^[[:space:]]*# ]] && continue
      [[ "$line" =~ (^|[[:space:]])launch[[:space:]] ]] && break
      [[ "$line" =~ ^[[:space:]]*}[[:space:]]*$ ]] && break
      if [[ "$line" =~ (shot_window|shot_prompt|shot_menu)[[:space:]]+([A-Za-z0-9_-]+) ]]; then
        slug="${BASH_REMATCH[2]}"
        note_slug "$slug"
        if shot_wanted "$slug"; then wanted=true; fi
      fi
    done < <(tail -n +"$start" "$src")
    if [[ "$wanted" == false ]]; then
      SKIP_BLOCK=true
      return 0
    fi
    SKIP_BLOCK=false
  fi
  local args=(--sidecar --profile "$PROFILE" --fresh --app-arg -AppleLanguages --app-arg "($L)")
  [[ "$BUILD" == true ]] || args+=(--no-build)
  local a
  for a in "$@"; do args+=(--app-arg "$a"); done
  if [[ "$BUILD" == true ]]; then
    while pgrep -x xcodebuild >/dev/null 2>&1; do echo "   waiting for another xcodebuild…"; sleep 15; done
  fi
  if ! bash "$PROJECT_DIR/scripts/rebuild-and-restart.sh" "${args[@]}" >"$WORK/launch.log" 2>&1; then
    echo "❌ launch failed:"; tail -20 "$WORK/launch.log"; exit 1
  fi
  BUILD=false
  PID="$(profile_pid)"
  [[ -n "$PID" ]] || { echo "❌ profile $PROFILE not running"; exit 1; }
}

wait_window() {
  [[ "$SKIP_BLOCK" == true ]] && return 0
  local i
  for i in $(seq 1 30); do
    [[ "$(ax 'return count of windows')" =~ ^[1-9] ]] && { sleep 1.5; return 0; }
    sleep 0.5
  done
  echo "   (no window appeared)"; return 1
}

# record <screen> <state> <png path>
record() {
  printf '| %02d | %s | %s | %s | %s |\n' "$N" "$1" "$2" "$L" "$(basename "$3")" >>"$OUT/index.md"
  echo "  $(basename "$3")  —  $1 / $2"
}

FILE=""
next_file() { N=$((N + 1)); FILE="$(printf '%s/%02d-%s-%s.png' "$OUT" "$N" "$L" "$1")"; }

# The topmost on-screen window of the profile's pid (CGWindowID), optionally only one on the given
# window layer (101 = a menu). The status item itself (layer 25) never counts. Captured by id, so
# nothing of another app that overlaps it lands in the picture.
window_id() {
  [[ "$SKIP_BLOCK" == true ]] && return 0
  osascript -l JavaScript -e "
ObjC.import('CoreGraphics');
const list = ObjC.castRefToObject(\$.CGWindowListCopyWindowInfo(\$.kCGWindowListOptionOnScreenOnly, 0));
let found = '';
let bestArea = -1;
for (let i = 0; i < list.count; i++) {
  const w = list.objectAtIndex(i);
  const layer = w.objectForKey('kCGWindowLayer').js;
  if (w.objectForKey('kCGWindowOwnerPID').js != $PID || layer == 25) continue;
  if ('${1:-}' !== '' && layer != Number('${1:-}')) continue;
  const bounds = w.objectForKey('kCGWindowBounds');
  const width = bounds.objectForKey('Width').js;
  const height = bounds.objectForKey('Height').js;
  if (width < 50 || height < 50) continue;
  if (w.objectForKey('kCGWindowAlpha').js == 0) continue;
  const area = width * height;
  if (area > bestArea) {
    bestArea = area;
    found = String(w.objectForKey('kCGWindowNumber').js);
  }
}
found" 2>/dev/null
}

# A picture as large as a display is deleted unseen: it may hold other apps' windows.
guard_size() {
  [[ -f "$1" ]] || return 1
  local w h; w="$(sips -g pixelWidth "$1" | awk '/pixelWidth/{print $2}')"; h="$(sips -g pixelHeight "$1" | awk '/pixelHeight/{print $2}')"
  if osascript -l JavaScript -e "ObjC.import('AppKit'); const s = \$.NSScreen.screens; let hit = false;
for (let i = 0; i < s.count; i++) { const f = s.objectAtIndex(i).frame; const k = s.objectAtIndex(i).backingScaleFactor;
  if (Math.abs(f.size.width * k - $w) < 4 && Math.abs(f.size.height * k - $h) < 80) hit = true; } hit" 2>/dev/null | grep -q true; then
    rm -f "$1"; echo "   (display-sized picture deleted unseen)"; return 1
  fi
}

# Never a full-screen or region capture: other apps' windows (anything the user has open) must not
# land in a picture. No window found → no picture, and the index says so.
# A locked screen hides every window from capture. Wait for the unlock (up to 10 minutes)
# instead of recording a run of empty shots.
wait_unlocked() {
  [[ "$SKIP_BLOCK" == true ]] && return 0
  local n=0
  while ioreg -n Root -d1 | grep -q '"CGSSessionScreenIsLocked"=Yes'; do
    (( n == 0 )) && echo "   (screen is locked: waiting for it to be unlocked)"
    (( ++n > 60 )) && { echo "   (screen still locked after 10 minutes: giving up)"; return 1; }
    sleep 10
  done
}

capture_window() {   # capture_window <file> [layer]
  [[ "$SKIP_BLOCK" == true ]] && return 0
  local id="" i
  wait_unlocked || return 1
  for i in 1 2 3 4 5 6; do
    id="$(window_id "${2:-}")"
    [[ "$id" =~ ^[0-9]+$ ]] && break
    sleep 1
  done
  if [[ "$id" =~ ^[0-9]+$ ]]; then screencapture -x -o -l "$id" "$1"; guard_size "$1"; return; fi
  echo "   (no window of pid $PID found: not captured)"
  return 1
}

# shot_window <slug> <screen> <state>: the front window of the profile.
shot_window() {
  if [[ "$SKIP_BLOCK" == true ]] || ! shot_wanted "$1"; then next_file "$1"; return 0; fi
  next_file "$1"; local f="$FILE"
  if capture_window "$f"; then record "$2" "$3" "$f"; else record "$2" "$3 (NOT CAPTURED: window not found)" "-"; fi
}

# The microphone prompt is a macOS window owned by a system agent, not by the profile. Only a window
# of one of those agents is captured, by its id; never the screen.
prompt_window_id() {
  [[ "$SKIP_BLOCK" == true ]] && return 0
  osascript -l JavaScript -e "
ObjC.import('CoreGraphics');
const owners = ['UserNotificationCenter', 'CoreServicesUIAgent', 'universalAccessAuthWarn', 'WhisperShortcut Dev'];
const list = ObjC.castRefToObject(\$.CGWindowListCopyWindowInfo(\$.kCGWindowListOptionOnScreenOnly, 0));
let found = '';
for (let i = 0; i < list.count && !found; i++) {
  const w = list.objectAtIndex(i);
  const owner = w.objectForKey('kCGWindowOwnerName').js;
  const pid = w.objectForKey('kCGWindowOwnerPID').js;
  const layer = w.objectForKey('kCGWindowLayer').js;
  if (layer == 0 || layer == 25 || owners.indexOf(owner) < 0) continue;
  if (owner == 'WhisperShortcut Dev' && pid != $PID) continue;
  found = String(w.objectForKey('kCGWindowNumber').js);
}
found" 2>/dev/null
}

shot_prompt() {
  if [[ "$SKIP_BLOCK" == true ]] || ! shot_wanted "$1"; then next_file "$1"; return 0; fi
  next_file "$1"; local f="$FILE" id
  id="$(prompt_window_id)"
  if [[ "$id" =~ ^[0-9]+$ ]]; then
    screencapture -x -o -l "$id" "$f"
    if guard_size "$f"; then record "$2" "$3" "$f"; else record "$2" "$3 (NOT CAPTURED)" "-"; fi
  else
    echo "   (prompt window not found: not captured)"
    record "$2" "$3 (NOT CAPTURED: prompt window not found)" "-"
  fi
}

# shot_menu <slug> <screen> <state>: the status menu, as text. A menu is translucent, so a picture
# of it shows a blurred copy of whatever lies behind it (other apps' windows). The item titles,
# their enabled state and shortcuts are read through Accessibility instead and written to a .txt.
shot_menu() {
  if [[ "$SKIP_BLOCK" == true ]] || ! shot_wanted "$1"; then next_file "$1"; return 0; fi
  N=$((N + 1)); local f; f="$(printf '%s/%02d-%s-%s.txt' "$OUT" "$N" "$L" "$1")"
  ax 'click menu bar item 1 of menu bar 2' >/dev/null
  sleep 0.8
  ax 'set out to ""
repeat with mi in menu items of menu 1 of menu bar item 1 of menu bar 2
  set t to name of mi
  if t is missing value then
    set out to out & "----" & linefeed
  else
    set k to ""
    try
      set c to value of attribute "AXMenuItemCmdChar" of mi
      if c is not missing value then set k to "   [shortcut: " & c & "]"
    end try
    set e to ""
    if not (enabled of mi) then set e to "   (greyed out)"
    set out to out & t & e & k & linefeed
  end if
end repeat
return out' >"$f"
  osascript -e 'tell application "System Events" to key code 53' >/dev/null 2>&1
  record "$2" "$3 (text: item titles)" "$f"
}

click_menu_item() {
  [[ "$SKIP_BLOCK" == true ]] && return 0
  ax "click menu bar item 1 of menu bar 2
delay 0.4
click menu item \"$1\" of menu 1 of menu bar item 1 of menu bar 2" >/dev/null
}

# ax_walk dump | click-button <n, negative counts from the end> | click-role <AXRole> | set-field <text>
ax_walk() {
  [[ "$SKIP_BLOCK" == true ]] && return 0
  "$AXWALK" "$PID" "$@" 2>&1
}

click_nth() {
  [[ "$SKIP_BLOCK" == true ]] && return 0
  local r; r="$(ax_walk click-button "$1")"
  [[ "$r" == ok ]] || echo "   (button #$1 not found: $r)"
}

click_role() {
  [[ "$SKIP_BLOCK" == true ]] && return 0
  ax_walk click-role "$1" >/dev/null
}

# Sets the first text field's value through Accessibility (no keystrokes: they would go to
# whatever app is in front).
type_into_field() {
  [[ "$SKIP_BLOCK" == true ]] && return 0
  ax_walk set-field "$1" >/dev/null
}

# wait_for_text <text> [seconds]: until some text of the window contains it.
wait_for_text() {
  [[ "$SKIP_BLOCK" == true ]] && return 0
  local i limit="${2:-60}"
  for i in $(seq 1 "$limit"); do
    ax_walk dump | grep -qF -- "$1" && return 0
    sleep 1
  done
  echo "   (text \"$1\" did not appear)"; return 1
}

# The WAV for the test dictation, copied into the profile's own container (its sandbox can read it).
place_audio() {
  [[ "$SKIP_BLOCK" == true ]] && return 0
  local src="$1" dest
  dest="$(profile_container "$PROFILE")/Data/tmp/ws-catalogue-$L.wav"
  mkdir -p "$(dirname "$dest")"
  cp "$src" "$dest"
  printf '%s' "$dest"
}

audio_source() {
  local given="$AUDIO_EN" voice="Samantha" sentence="Today is a good day to try dictation."
  if [[ "$L" == de ]]; then
    given="$AUDIO_DE"; voice="Anna"
    sentence="Heute ist ein schöner Tag Komma und ich probiere das Diktieren aus Punkt"
  fi
  if [[ -n "$given" ]]; then printf '%s' "$given"; return; fi
  say -v "$voice" -o "$WORK/say-$L.wav" --data-format=LEI16@16000 "$sentence" 2>/dev/null \
    || say -o "$WORK/say-$L.wav" --data-format=LEI16@16000 "$sentence"
  printf '%s' "$WORK/say-$L.wav"
}

audio_path() { printf '%s' "$(profile_container "$PROFILE")/Data/tmp/ws-catalogue-$L.wav"; }

# Dictate Live from a file. The WAV is prepared in $WORK (or taken from --audio-live-de) and copied
# into the profile container only after launch: --fresh has wiped it. A temp name in that directory
# plus mv, so the app never sees a half-written file.
live_audio_path() { printf '%s' "$(profile_container "$PROFILE")/Data/tmp/ws-live-$L.wav"; }

live_audio_source() {
  if [[ -n "$AUDIO_LIVE_DE" ]]; then
    [[ -f "$AUDIO_LIVE_DE" ]] || { echo "❌ --audio-live-de not found: $AUDIO_LIVE_DE" >&2; return 1; }
    printf '%s' "$AUDIO_LIVE_DE"
    return 0
  fi
  local out="$WORK/live-de.wav"
  say -v Anna -o "$out" --data-format=LEI16@16000 "Heute ist ein schöner Tag Komma [[slnc 1200]] und ich probiere das Diktieren aus Punkt [[slnc 1200]] Danach mache ich eine Pause Punkt [[slnc 1200]] Das Glossar hilft bei Fachwörtern Punkt" || return 1
  printf '%s' "$out"
}

place_live_audio() {
  [[ "$SKIP_BLOCK" == true ]] && return 0
  local src="$1" dest dir tmp
  [[ -n "$src" && -f "$src" ]] || { echo "   (live audio missing)" >&2; return 1; }
  dest="$(live_audio_path)"
  dir="$(dirname "$dest")"
  mkdir -p "$dir"
  tmp="$(mktemp "$dir/.ws-live-$L.XXXXXX")" || return 1
  if ! cp "$src" "$tmp"; then
    rm -f "$tmp"
    echo "   (could not copy live audio)" >&2
    return 1
  fi
  mv "$tmp" "$dest"
}

# German title from the string catalogue ("Test für Live diktieren"). A menu-bar process keeps this
# window out of System Events' window list, so the title is read from the on-screen window list,
# the same list shot_window captures from.
wait_live_window() {
  [[ "$SKIP_BLOCK" == true ]] && return 0
  local title i names
  title="$(t "Live dictation test")"
  for i in $(seq 1 30); do
    names="$(osascript -l JavaScript -e "
ObjC.import('CoreGraphics');
const list = ObjC.castRefToObject(\$.CGWindowListCopyWindowInfo(\$.kCGWindowListOptionOnScreenOnly, 0));
let lines = [];
for (let i = 0; i < list.count; i++) {
  const w = list.objectAtIndex(i);
  if (w.objectForKey('kCGWindowOwnerPID').js != $PID) continue;
  if (w.objectForKey('kCGWindowLayer').js == 25) continue;
  lines.push(String(w.objectForKey('kCGWindowName').js || ''));
}
lines.join('\n')" 2>/dev/null || true)"
    if printf '%s\n' "$names" | grep -qxF -- "$title"; then sleep 1.5; return 0; fi
    sleep 0.5
  done
  echo "   (window titled \"$title\" did not appear)"
  return 1
}

wait_live_result() {
  [[ "$SKIP_BLOCK" == true ]] && return 0
  local result i
  result="$(profile_container "$PROFILE")/Data/tmp/live-result.txt"
  for i in $(seq 1 120); do
    [[ -f "$result" ]] && return 0
    sleep 1
  done
  echo "   (live-result.txt did not appear)"
  return 1
}

save_live_result() {
  [[ "$SKIP_BLOCK" == true ]] && return 0
  shot_wanted live-result || return 0
  local src txt text
  src="$(profile_container "$PROFILE")/Data/tmp/live-result.txt"
  [[ -f "$src" ]] || { echo "   (live-result.txt missing, not written beside the shot)"; return 1; }
  txt="${FILE%.png}.txt"
  cp "$src" "$txt"
  text="$(tr '\n' ' ' < "$txt" | sed 's/[[:space:]]\{2,\}/ /g;s/^[[:space:]]//;s/[[:space:]]$//')"
  record "Dictate Live (file)" "result: $text" "$txt"
}

quit_profile() {
  local pid; pid="$(profile_pid)"
  [[ -n "$pid" ]] && kill "$pid" 2>/dev/null
  sleep 1
}

# ---------------------------------------------------------------------------------------------
catalogue_dictation_only() {
  local free=(--globe free --mic granted --accessibility granted)
  local audio; audio="$(audio_source)"

  echo "── $L: first screen"
  launch --onboarding-step mode "${free[@]}"; wait_window
  shot_window mode "First screen" "default (Dictation only preselected)"
  launch --onboarding-step mode --recording-running "${free[@]}"; wait_window
  click_nth -1; sleep 1   # Continue
  shot_window mode-refused "First screen" "Continue refused: a recording is running"

  echo "── $L: 🌐 key"
  launch --onboarding-step globe --globe emoji --mic granted --accessibility granted; wait_window
  shot_window globe-emoji "🌐 key" "conflict: Show Emoji & Symbols"
  launch --onboarding-step globe --globe dictation --mic granted --accessibility granted; wait_window
  shot_window globe-dictation "🌐 key" "conflict: Start Dictation"
  launch --onboarding-step globe "${free[@]}"; wait_window
  shot_window globe-free "🌐 key" "free"

  echo "── $L: language"
  launch --onboarding-step language "${free[@]}"; wait_window
  shot_window language "Language" "Mac language preselected"
  launch --onboarding-step language --language-needs-pick "${free[@]}"; wait_window
  shot_window language-pick "Language" "needs an explicit pick (Mac language not supported)"

  echo "── $L: permissions"
  launch --onboarding-step permissions --globe free --mic not-determined --accessibility missing; wait_window
  shot_window perm-none "Permissions" "microphone not asked, Accessibility missing"
  launch --onboarding-step permissions --globe free --mic granted --accessibility missing; wait_window
  shot_window perm-mic "Permissions" "microphone granted, Accessibility missing"
  launch --onboarding-step permissions --globe free --mic denied --accessibility missing; wait_window
  shot_window perm-denied "Permissions" "microphone denied, Accessibility missing"
  launch --onboarding-step permissions "${free[@]}"; wait_window
  shot_window perm-all "Permissions" "both granted"

  echo "── $L: download"
  launch --onboarding-step download "${free[@]}" --download not-started; wait_window
  shot_window dl-not-started "Download" "not started"
  launch --onboarding-step download "${free[@]}" --download running:40; wait_window
  shot_window dl-running "Download" "running at 40 %"
  launch --onboarding-step download "${free[@]}" --download finished; wait_window
  shot_window dl-finished "Download" "finished"
  launch --onboarding-step download "${free[@]}" --download failed; wait_window; sleep 2.5
  shot_window dl-failed "Download" "failed (network connection lost)"
  launch --onboarding-step download "${free[@]}" --download not-started --disk-full; wait_window
  shot_window dl-disk "Download" "not enough disk space"

  echo "── $L: test dictation"
  launch --onboarding-step test "${free[@]}" --download running:40; wait_window
  shot_window test-waiting "Test" "download still running"
  launch --onboarding-step test --globe free --mic denied --accessibility granted; wait_window
  shot_window test-mic-denied "Test" "microphone denied"
  launch --onboarding-step test "${free[@]}" --audio-file "$(audio_path)"; wait_window
  place_audio "$audio" >/dev/null
  shot_window test-ready "Test" "ready to start"
  click_nth 1   # Try dictation
  wait_for_text "$(t "It works")" 90
  sleep 0.5
  shot_window test-result "Test" "result of a test dictation (audio file)"

  if [[ "$L" == de ]]; then
    echo "── $L: Dictate Live from a file"
    # Before launch: the app gives the copy at most 30s, and --fresh leaves nothing to copy into
    # until launch has returned. Skipped when --only names some other shot.
    local live_src=""
    if shot_wanted live-result; then
      live_src="$(live_audio_source)" || exit 1
    fi
    launch --live-audio-file "$(live_audio_path)"
    place_live_audio "$live_src" || exit 1
    wait_live_window
    wait_live_result
    if [[ "$SKIP_BLOCK" != true ]]; then sleep 0.5; fi
    shot_window live-result "Dictate Live (file)" "4 sentences with pauses, text in a window of the app"
    save_live_result
  fi

  echo "── $L: glossary"
  launch --onboarding-step glossary "${free[@]}" --audio-file "$(audio_path)"; wait_window
  place_audio "$audio" >/dev/null
  shot_window glossary "Glossary" "empty"
  type_into_field "Kizomba"
  click_nth 1; sleep 1   # Save
  shot_window glossary-saved "Glossary" "word saved, try again offered"
  click_nth 2   # Try dictation, below the saved word
  wait_for_text "$(t "It works")" 90
  sleep 0.5
  shot_window glossary-retry "Glossary" "result of the second test dictation"

  echo "── $L: last screen"
  launch --onboarding-step done "${free[@]}" --download finished; wait_window
  shot_window done-ready "Done" "ready (🌐 key, Live)"
  launch --onboarding-step done --globe emoji --mic granted --accessibility granted --download finished; wait_window
  shot_window done-shortcut "Done" "🌐 key still in conflict: key combination"
  launch --onboarding-step done --globe free --mic granted --accessibility missing --download finished; wait_window
  shot_window done-copied "Done" "Accessibility missing: text is copied"
  launch --onboarding-step done "${free[@]}" --download finished --intel; wait_window
  shot_window done-intel "Done" "Intel Mac: Live unavailable, plain dictation"
  launch --onboarding-step done --globe free --mic denied --accessibility granted --download running:40; wait_window
  shot_window done-almost "Done" "almost ready: microphone denied, download running"

  echo "── $L: Settings"
  launch --dictation-only on --settings-tab general "${free[@]}" --download finished; wait_window
  shot_window settings-general "Settings → General" "mode on"
  launch --dictation-only on --settings-tab general "${free[@]}" --download finished --recording-running; wait_window
  click_role AXCheckBox; sleep 1
  shot_window settings-general-refused "Settings → General" "switch refused: a recording is running"
  launch --dictation-only on --settings-tab dictate "${free[@]}" --download finished; wait_window
  shot_window settings-dictate "Settings → Dictate" "mode on"
  launch --dictation-only on --settings-tab dictate "${free[@]}" --download running:40; wait_window
  shot_window settings-dictate-dl "Settings → Dictate" "mode on, download running"
  launch --dictation-only off --settings-tab general "${free[@]}"; wait_window
  shot_window settings-general-off "Settings → General" "mode off"

  echo "── $L: status menu and popups"
  launch --dictation-only on "${free[@]}" --download finished; sleep 3
  shot_menu menu-on "Status menu" "mode on"
  launch --dictation-only on "${free[@]}" --download running:40; sleep 3
  shot_menu menu-on-dl "Status menu" "mode on, download running"
  launch --dictation-only off "${free[@]}"; sleep 3
  shot_menu menu-off "Status menu" "mode off"
  launch --dictation-only on "${free[@]}" --download running:40; sleep 3
  click_menu_item "$(t Dictate)"; sleep 1
  shot_window popup-dl-running "Popup after the dictation key" "mode on, download running"
  launch --dictation-only on "${free[@]}" --download not-started; sleep 3
  click_menu_item "$(t Dictate)"; sleep 1
  shot_window popup-dl-missing "Popup after the dictation key" "mode on, download not started"

  echo "── $L: macOS permission prompts of the profile app (photographed, not answered)"
  launch --onboarding-step permissions --globe free; wait_window
  click_nth 1; sleep 2.5   # Allow (microphone)
  shot_prompt prompt-mic "macOS prompt" "microphone (prompt window only)"
  quit_profile
}

{
  echo "# UI catalogue: $SET"
  echo
  echo "Generated $(date '+%Y-%m-%d %H:%M') by scripts/ui-catalogue.sh from $(git -C "$PROJECT_DIR" rev-parse --short HEAD)."
  echo
  echo "| # | Screen | State | Language | File |"
  echo "|---|---|---|---|---|"
} >"$OUT/index.md"

for L in $LANGS; do
  PROFILE="uicat-$L"
  "catalogue_${SET//-/_}"
  quit_profile
done
echo "✅ $N screenshots, index: $OUT/index.md"
report_unknown_slugs || exit 1
