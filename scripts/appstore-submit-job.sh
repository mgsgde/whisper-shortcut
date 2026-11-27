#!/bin/bash

# Weekly Mac App Store submission for one tag — the automated follow-up to a
# successful Stable promotion (owner decision, Magnus, 2026-11-20: the same
# version that lands on Stable is submitted to the App Store the same week,
# with release type AFTER_APPROVAL so Apple ships it automatically once
# reviewed). Automates the manual procedure in
# .cursor/commands/submit-appstore.md — read that file for the exact asc
# gotchas (symbol glyphs, `localizations upload` dropping whatsNew, the
# WAITING_FOR_REVIEW fold-in, PREV_LIVE resolution). This script follows it
# step for step; it does not restate the reasoning.
#
# State lives in build/appstore-weekly/ (gitignored) of the MAIN checkout:
#   hold           if this file exists, do nothing but mail fyi once per ISO
#                  week; its contents are the reason. Same convention as
#                  build/stable-channel/hold.
#   last-submitted one line, the tag last submitted successfully. Prevents
#                  re-submitting the same tag on a re-run.
#   failed-tag     "<tag> <step> <YYYY-MM-DD HH:MM:SS>" — the tag and step
#                  that failed, and when. A failure mails once; the same tag
#                  is not retried again unless --force.
#
# Usage: appstore-submit-job.sh <tag> [--dry-run] [--force] [--notes-file=<path>]
#   <tag>       the git tag to submit, e.g. v8.95 (must already be a
#               published GitHub release — /release or the Stable promotion
#               already cut it)
#   --dry-run   run every read-only step (state checks, asc read-only
#               queries, PREV_LIVE resolution, the English What's New text,
#               the locale list) and print what would happen. No worktree,
#               no build, no writes to App Store Connect, no state-file
#               writes, no mail.
#   --force     ignore a stored failed-tag for this tag and retry it anyway.
#   --notes-file=<path>  read the English What's New from this plain-text
#               file instead of the tag's GitHub release (and skip the
#               fold-in). For a manual submission that jumps several
#               versions past the live one.
#   APPSTORE_ASC_DIR  dir holding export-options-app-store.plist (default: $REPO/.asc)
#
# Mails on success ("App Store: <tag> submitted for review") and on any
# failure (step + last log lines), via scripts/send-report-mail.py. Logs to
# build/logs/appstore-submit.log.
#
# HARD RULE for anyone touching this file: never call a mutating `asc`
# command (builds upload, versions create/update/attach-build,
# localizations update, review submit, review submissions-cancel, ...)
# while DRY=1. Only list/status/info/--help calls are read-only enough to
# run unconditionally.
set -uo pipefail
# /usr/sbin holds pkgutil (the pkg-signature check); without it that check always failed.
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

APP_ID=6749648401
PLATFORM=MAC_OS

TAG=""
DRY=0
FORCE=0
NOTES_FILE=""
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY=1 ;;
    --force) FORCE=1 ;;
    --notes-file=*) NOTES_FILE="${arg#--notes-file=}" ;;
    v[0-9]*) TAG="$arg" ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

if [ -z "$TAG" ]; then
  echo "usage: appstore-submit-job.sh <tag> [--dry-run] [--force] [--notes-file=<path>]" >&2
  exit 2
fi
if [[ ! "$TAG" =~ ^v[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
  echo "tag must look like vX.Y or vX.Y.Z, got: $TAG" >&2
  exit 2
fi
TAG_VER="${TAG#v}"

if [ -n "$NOTES_FILE" ]; then
  if [ ! -s "$NOTES_FILE" ]; then
    echo "notes file not found or empty: $NOTES_FILE" >&2
    exit 2
  fi
  NOTES_FILE="$(cd "$(dirname "$NOTES_FILE")" && pwd)/$(basename "$NOTES_FILE")"
fi

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO" || exit 1
STATE_DIR="$REPO/build/appstore-weekly"
mkdir -p "$STATE_DIR" "$REPO/build/logs"
STAMP="$(date +%F)"
ISO_WEEK="$(date +%G-W%V)"
LOG="$REPO/build/logs/appstore-submit.log"

AUDIT_MAIL_TO="${AUDIT_MAIL_TO:-mail@magnus-goedde.de}"

if [ "$DRY" -eq 0 ]; then
  # Append this run to the shared log; still echo to stdout/stderr so a caller
  # (e.g. stable-promote-job.sh) sees it too.
  exec > >(tee -a "$LOG") 2>&1
fi

echo "=== App Store submission for $TAG started: $(date '+%Y-%m-%d %H:%M:%S') $([ "$DRY" -eq 1 ] && echo '(dry-run)') ==="

notify() {
  osascript -e "display notification \"$(printf '%s' "$2" | sed 's/"/\\"/g')\" with title \"$1\"" \
    >/dev/null 2>&1 || true
}

# Same contract as stable-promote-job.sh's report_out: mail first, local
# notification when the mail cannot go out.
report_out() {
  local subject="$1" body="$2"; shift 2
  if python3 "$REPO/scripts/send-report-mail.py" --to "$AUDIT_MAIL_TO" \
       --subject "$subject" --body-file "$body" "$@"; then
    return 0
  fi
  echo "WARN: could not send mail — falling back to a local notification"
  notify "$subject" "Email failed. Report: $body"
}

fyi_mail() {
  local subject="$1" detail="$2"
  if [ "$DRY" -eq 1 ]; then
    echo "dry-run: would mail (fyi): $subject"
    printf '%s\n' "$detail"
    return 0
  fi
  local body; body="$(mktemp)"
  printf '%s\n' "$detail" > "$body"
  report_out "$subject" "$body" --verdict fyi
  rm -f "$body"
}

fail_job() {
  local step="$1" detail="$2"
  echo "FAILED at step '$step': $detail" >&2
  if [ "$DRY" -eq 1 ]; then
    echo "dry-run: would record failed-tag and mail needs-fix ($step)"
    exit 1
  fi
  printf '%s %s %s\n' "$TAG" "$step" "$(date '+%F %T')" > "$STATE_DIR/failed-tag"
  local body; body="$(mktemp)"
  {
    echo "App Store submission for $TAG failed at step: $step"
    echo
    echo "$detail"
    echo
    echo "---- log tail (build/logs/appstore-submit.log) ----"
    tail -n 60 "$LOG" 2>/dev/null
  } > "$body"
  report_out "App Store: $TAG submission failed ($step)" "$body" --verdict needs-fix
  rm -f "$body"
  exit 1
}

version_is_newer() {
  # $1 candidate version, $2 baseline version (empty if none). True when $1 > $2.
  [ -n "$1" ] || return 1
  [ -z "$2" ] && return 0
  [ "$1" = "$2" ] && return 1
  local top
  top="$(printf '%s\n%s\n' "$2" "$1" | sort -V | tail -n 1 || true)"
  [ "$top" = "$1" ]
}

# ------------------------------------------------------------------ 0. hold
if [ -f "$STATE_DIR/hold" ]; then
  echo "App Store submission is on hold."
  MAILED_MARKER="$STATE_DIR/hold-mailed-$ISO_WEEK"
  if [ -f "$MAILED_MARKER" ]; then
    echo "Already mailed fyi for hold this ISO week ($ISO_WEEK); staying quiet."
  else
    fyi_mail "App Store submission is on hold" \
      "$(printf 'App Store submission is on hold. %s was not submitted.\n\nbuild/appstore-weekly/hold:\n\n%s' "$TAG" "$(cat "$STATE_DIR/hold")")"
    [ "$DRY" -eq 0 ] && touch "$MAILED_MARKER"
  fi
  exit 0
fi

# ------------------------------------------------------------------ 1. state gates
if [ -f "$STATE_DIR/last-submitted" ] && [ "$(tr -d '[:space:]' < "$STATE_DIR/last-submitted")" = "$TAG" ]; then
  echo "$TAG was already submitted successfully (build/appstore-weekly/last-submitted). Nothing to do."
  exit 0
fi

if [ -f "$STATE_DIR/failed-tag" ] && [ "$FORCE" -eq 0 ]; then
  failed_line="$(cat "$STATE_DIR/failed-tag")"
  failed_tag="${failed_line%% *}"
  if [ "$failed_tag" = "$TAG" ]; then
    echo "$TAG already failed and was mailed ($failed_line). Not retrying without --force."
    exit 0
  fi
fi
[ "$FORCE" -eq 1 ] && rm -f "$STATE_DIR/failed-tag"

# ------------------------------------------------------------------ 2. where does the App Store stand
asc_json() {
  # Run an asc command and return only stdout (JSON); asc sometimes writes
  # pagination warnings to stderr that would otherwise corrupt the parse.
  asc "$@" 2>/dev/null
}

VERSIONS_JSON="$(asc_json versions list --app "$APP_ID" --platform "$PLATFORM")" || \
  fail_job "asc-versions-list" "asc versions list failed. Nothing was changed."

LIVE_VER="$(printf '%s' "$VERSIONS_JSON" | python3 -c '
import json, sys
data = json.load(sys.stdin)
live = [v["attributes"]["versionString"] for v in data["data"]
        if v["attributes"].get("appStoreState") == "READY_FOR_SALE"]
def key(v):
    return [int(p) for p in v.split(".")]
print(sorted(live, key=key)[-1] if live else "")
')"
echo "App Store live version: ${LIVE_VER:-none}"

if ! version_is_newer "$TAG_VER" "$LIVE_VER"; then
  fyi_mail "App Store: $TAG is not newer than the live version" \
    "App Store already has ${LIVE_VER:-no live version} live, which is the same as or newer than $TAG. Nothing was submitted."
  exit 0
fi

REVIEW_STATUS_JSON="$(asc_json review status --app "$APP_ID")" || \
  fail_job "asc-review-status" "asc review status failed. Nothing was changed."

read -r TOP_VER TOP_VERSION_ID TOP_REVIEW_STATE TOP_SUBMISSION_ID TOP_SUBMISSION_STATE <<EOF
$(printf '%s' "$REVIEW_STATUS_JSON" | python3 -c '
import json, sys
d = json.load(sys.stdin)
v = d.get("version") or {}
sub = d.get("latestSubmission") or {}
print(v.get("version", ""), v.get("id", ""), d.get("reviewState", ""), sub.get("id", ""), sub.get("state", ""))
')
EOF

echo "Latest prepared/review version: ${TOP_VER:-none} reviewState=${TOP_REVIEW_STATE:-none} submission=${TOP_SUBMISSION_STATE:-none}"

FOLD_IN_VERSION_ID=""
if [ -n "$TOP_VER" ] && ! version_is_newer "$TAG_VER" "$TOP_VER"; then
  # App Store already has a prepared/submitted version for $TAG_VER or newer.
  case "$TOP_SUBMISSION_STATE" in
    IN_REVIEW)
      fyi_mail "App Store: $TOP_VER is already IN_REVIEW" \
        "Apple is already reviewing $TOP_VER (older than or equal to $TAG). Doing nothing this run; the next weekly submission after the next Stable promotion will try again."
      exit 0
      ;;
    WAITING_FOR_REVIEW)
      echo "$TOP_VER is WAITING_FOR_REVIEW (not yet picked up by Apple) — folding $TAG into it."
      if [ "$DRY" -eq 1 ]; then
        echo "dry-run: would cancel submission $TOP_SUBMISSION_ID and rename version $TOP_VERSION_ID to $TAG_VER."
        FOLD_IN_VERSION_ID="$TOP_VERSION_ID"
      else
        asc review submissions-cancel --id "$TOP_SUBMISSION_ID" --confirm \
          || fail_job "fold-in-cancel" "asc review submissions-cancel failed for submission $TOP_SUBMISSION_ID (version $TOP_VER)."
        asc versions update --version-id "$TOP_VERSION_ID" --version "$TAG_VER" \
          || fail_job "fold-in-rename" "asc versions update --version failed renaming $TOP_VER to $TAG_VER."
        FOLD_IN_VERSION_ID="$TOP_VERSION_ID"
      fi
      ;;
    *)
      fyi_mail "App Store: $TOP_VER already prepared (state $TOP_REVIEW_STATE/$TOP_SUBMISSION_STATE)" \
        "A version $TOP_VER already exists at App Store Connect in a state this job does not fold into automatically ($TOP_REVIEW_STATE / $TOP_SUBMISSION_STATE). Nothing was submitted for $TAG. Check manually with /submit-appstore."
      exit 0
      ;;
  esac
fi

PREV_LIVE="$LIVE_VER"
echo "PREV_LIVE (metadata baseline) = $PREV_LIVE"

# ------------------------------------------------------------------ 3. What's New (English, from the GitHub release)
fetch_release_notes_cut() {
  # $1 tag -> prints the user-facing part of its GitHub release body (drops
  # the "## Installation" section and everything after, which is DMG
  # install instructions and the compare link, not App Store copy).
  local tag="$1" body
  body="$(gh release view "$tag" --json body -q .body 2>/dev/null)" || return 1
  printf '%s\n' "$body" | sed '/^## Installation/,$d' | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}'
}

if [ -n "$NOTES_FILE" ]; then
  ENGLISH_NOTES="$(cat "$NOTES_FILE")"
  echo "What's New from $NOTES_FILE (not from the GitHub release)."
else
  ENGLISH_NOTES="$(fetch_release_notes_cut "$TAG")" || \
    fail_job "release-notes" "gh release view $TAG --json body failed. Nothing was submitted."
fi
if [ -z "$ENGLISH_NOTES" ]; then
  fail_job "release-notes" "$TAG's GitHub release body has no user-facing part (empty after cutting the Installation section)."
fi

if [ -n "$FOLD_IN_VERSION_ID" ] && [ -z "$NOTES_FILE" ]; then
  # Cumulative What's New: the folded-in version never shipped, so the notes
  # for every tag between it (exclusive) and $TAG (inclusive) must appear.
  FOLD_FROM_VER="$TOP_VER"
  CUM=""
  while read -r t; do
    [ -z "$t" ] && continue
    v="${t#v}"
    version_is_newer "$v" "$FOLD_FROM_VER" || continue
    notes_t="$(fetch_release_notes_cut "$t" || true)"
    [ -z "$notes_t" ] && continue
    if [ -z "$CUM" ]; then
      CUM="$t:
$notes_t"
    else
      CUM="$CUM

$t:
$notes_t"
    fi
  done < <(git -C "$REPO" tag --list 'v*' --sort=v:refname)
  [ -n "$CUM" ] && ENGLISH_NOTES="$CUM"
  echo "Folded in cumulative What's New since $FOLD_FROM_VER."
fi

strip_markdown() {
  # App Store What's New is plain text — GitHub release bodies are Markdown, and
  # those characters would otherwise show up literally in the store listing.
  python3 -c '
import re, sys
text = sys.stdin.read()
text = re.sub(r"^#{1,6}\s*(.+?)\s*$", r"\1:", text, flags=re.MULTILINE)  # "## Heading" -> "Heading:"
text = re.sub(r"\*\*(.+?)\*\*", r"\1", text)   # **bold**
text = re.sub(r"__(.+?)__", r"\1", text)       # __bold__
text = text.replace("`", "")                   # keep the word, drop backticks
text = re.sub(r"^-\s+", "• ", text, flags=re.MULTILINE)  # "- " bullets -> "• "
text = re.sub(r"\n{3,}", "\n\n", text)         # collapse 3+ blank lines to one
sys.stdout.write(text)
'
}

strip_forbidden_glyphs() {
  # Apple rejects symbol glyphs in What's New ("✕" etc., see
  # .cursor/commands/submit-appstore.md). Spell out keyboard-shortcut glyphs
  # this app's release notes use, then drop any remaining Unicode "Symbol,
  # other" character except the ones the doc confirms are fine (•, ×, –).
  python3 -c '
import sys, unicodedata
text = sys.stdin.read()
replacements = {
    "⌘": "Cmd", "⌥": "Option", "⇧": "Shift", "⌃": "Control", "⎋": "Esc",
    "✕": "x", "⏸": "pause", "▶": "play", "⏪": "rewind", "⏩": "fast-forward",
    "✗": "", "✓": "",
}
for glyph, word in replacements.items():
    text = text.replace(glyph, word)
allowed = {"•", "×", "–", "-", "—"}
out = []
for ch in text:
    if ch in allowed or not unicodedata.category(ch).startswith("So"):
        out.append(ch)
print("".join(out), end="")
'
}

ENGLISH_NOTES="$(printf '%s' "$ENGLISH_NOTES" | strip_markdown | strip_forbidden_glyphs)"
if [ "${#ENGLISH_NOTES}" -gt 4000 ]; then
  ENGLISH_NOTES="${ENGLISH_NOTES:0:3997}..."
fi
echo "English What's New (${#ENGLISH_NOTES} chars):"
printf '%s\n' "$ENGLISH_NOTES"

if [ "$DRY" -eq 1 ]; then
  echo "dry-run: would query the configured locale set and translate the above into each non-English one."
  echo "dry-run: would archive $TAG in a detached worktree, export + upload the .pkg, create/attach the App Store version, set What's New per locale, and submit for review."
  echo "dry-run: no worktree, no build, no asc writes, no mail for the remaining steps."
  exit 0
fi

# ------------------------------------------------------------------ 4. worktree at the tag
remove_worktree() {
  local wt="$1" log
  [ -e "$wt" ] || return 0
  log="$(mktemp)"
  if bash "$REPO/scripts/worktree-remove.sh" "$wt" >"$log" 2>&1; then
    cat "$log"; rm -f "$log"; return 0
  fi
  cat "$log" >&2
  if grep -q "Still running" "$log"; then
    rm -f "$log"
    echo "Not force-removing $wt: an app is running from it." >&2
    return 1
  fi
  rm -f "$log"
  echo "worktree-remove.sh refused with nothing running from $wt; falling back to git worktree remove --force"
  git -C "$REPO" worktree remove --force "$wt"
}

ensure_worktree_toplevel() {
  local wt="$1" top expected gitdir
  expected="$(cd "$wt" && pwd -P)"
  top="$(git -C "$wt" rev-parse --show-toplevel 2>/dev/null || true)"
  [ -n "$top" ] && top="$(cd "$top" && pwd -P)"
  [ "$top" = "$expected" ] && return 0
  gitdir="$(sed -n 's/^gitdir: //p' "$wt/.git" 2>/dev/null || true)"
  if [ -z "$gitdir" ] || [ ! -d "$gitdir" ]; then
    echo "Worktree $wt resolves to '$top' and has no gitdir to repair." >&2
    return 1
  fi
  printf '[core]\n\tworktree = %s\n' "$expected" > "${gitdir}/config.worktree"
  top="$(git -C "$wt" rev-parse --show-toplevel 2>/dev/null || true)"
  [ -n "$top" ] && top="$(cd "$top" && pwd -P)"
  [ "$top" = "$expected" ] || { echo "Worktree $wt still resolves to '$top'." >&2; return 1; }
}

WT="$STATE_DIR/wt"
git -C "$REPO" fetch --tags || fail_job "fetch" "git fetch --tags failed."
remove_worktree "$WT" || fail_job "worktree" "Could not remove stale worktree at $WT (an app may be running from it)."
git -C "$REPO" worktree add --detach "$WT" "$TAG" || fail_job "worktree" "git worktree add --detach $WT $TAG failed."
ensure_worktree_toplevel "$WT" || { remove_worktree "$WT" || true; fail_job "worktree" "Worktree $WT does not resolve to itself."; }

EXPECTED_FILE=""
cleanup_all() {
  [ -n "$EXPECTED_FILE" ] && rm -f "$EXPECTED_FILE"
  remove_worktree "$WT" || echo "WARN: left worktree at $WT" >&2
}
cleanup_worktree() { cleanup_all; }
trap cleanup_all EXIT

# .asc/ is gitignored, so it only exists in the main checkout. The stable-promote job runs
# this script from a worktree copy (build/stable-promote/src) and passes the real dir here.
ASC_DIR="${APPSTORE_ASC_DIR:-$REPO/.asc}"
[ -f "$ASC_DIR/export-options-app-store.plist" ] || \
  fail_job "export-options" "Missing $ASC_DIR/export-options-app-store.plist (see .cursor/commands/submit-appstore.md Preconditions)."
mkdir -p "$WT/.asc"
cp "$ASC_DIR/export-options-app-store.plist" "$WT/.asc/export-options-app-store.plist"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$WT/WhisperShortcut/Info.plist" 2>/dev/null)" \
  || fail_job "version" "Could not read CFBundleShortVersionString from $WT/WhisperShortcut/Info.plist."
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$WT/WhisperShortcut/Info.plist" 2>/dev/null)" \
  || fail_job "version" "Could not read CFBundleVersion from $WT/WhisperShortcut/Info.plist."
if [ "$VERSION" != "$TAG_VER" ]; then
  fail_job "version-mismatch" "Info.plist at $TAG says CFBundleShortVersionString=$VERSION, expected $TAG_VER."
fi
echo "Resolved VERSION=$VERSION BUILD=$BUILD"

# ------------------------------------------------------------------ 5. archive + export (build lock around this only)
source "$REPO/scripts/lib/build-lock.sh"
acquire_build_lock
LOCK_RC=$?
if [ "$LOCK_RC" -eq 75 ]; then
  echo "Build machine is busy; not building today. Will retry on the next run."
  trap - EXIT
  cleanup_worktree
  exit 0
elif [ "$LOCK_RC" -ne 0 ]; then
  fail_job "build-lock" "acquire_build_lock failed with exit $LOCK_RC."
fi

ARCHIVE_PATH="$WT/.asc/artifacts/WhisperShortcut-AppStore-$VERSION.xcarchive"
EXPORT_PATH="$WT/.asc/artifacts/export-appstore"
BUILD_LOG="$(mktemp)"
(
  cd "$WT" && \
  xcodebuild -project WhisperShortcut.xcodeproj -scheme WhisperShortcut-AppStore \
    -configuration Release -destination 'generic/platform=macOS' -allowProvisioningUpdates \
    -skipPackagePluginValidation \
    archive -archivePath "$ARCHIVE_PATH" && \
  rm -rf "$EXPORT_PATH" && \
  xcodebuild -exportArchive -archivePath "$ARCHIVE_PATH" -exportPath "$EXPORT_PATH" \
    -exportOptionsPlist "$WT/.asc/export-options-app-store.plist" -allowProvisioningUpdates
) >"$BUILD_LOG" 2>&1
BUILD_RC=$?
release_build_lock
if [ "$BUILD_RC" -ne 0 ]; then
  cp "$BUILD_LOG" "$STATE_DIR/$STAMP-archive-export.log"
  fail_job "archive-export" "Archive/export failed (exit $BUILD_RC). Log: build/appstore-weekly/$STAMP-archive-export.log. Tail:
$(tail -n 40 "$BUILD_LOG")"
fi
rm -f "$BUILD_LOG"

PKG="$EXPORT_PATH/WhisperShortcut.pkg"
[ -f "$PKG" ] || fail_job "export" "Export did not produce $PKG."
if ! pkgutil --check-signature "$PKG" 2>&1 | grep -q "3rd Party Mac Developer Installer"; then
  fail_job "pkg-signature" "$PKG is not signed with '3rd Party Mac Developer Installer' (pkgutil --check-signature)."
fi
echo "Archived and exported $PKG."

# ------------------------------------------------------------------ 6. upload + create/attach version
UPLOAD_JSON="$(asc builds upload --app "$APP_ID" --pkg "$PKG" --version "$VERSION" --build-number "$BUILD" --wait 2>&1)"
UPLOAD_RC=$?
echo "$UPLOAD_JSON"
[ "$UPLOAD_RC" -eq 0 ] || fail_job "upload" "asc builds upload failed (exit $UPLOAD_RC)."

BUILD_ID="$(printf '%s' "$UPLOAD_JSON" | python3 -c '
import json, sys, re
raw = sys.stdin.read()
try:
    d = json.loads(raw)
    for key in ("id",):
        if isinstance(d, dict) and key in d and isinstance(d[key], str):
            print(d[key]); sys.exit(0)
    if isinstance(d, dict) and "data" in d:
        data = d["data"]
        data = data[0] if isinstance(data, list) else data
        print(data.get("id", "")); sys.exit(0)
except Exception:
    pass
m = re.search(r"[0-9a-fA-F-]{36}", raw)
print(m.group(0) if m else "")
' 2>/dev/null)"
[ -n "$BUILD_ID" ] || fail_job "upload" "Could not parse a build ID out of asc builds upload's output."
echo "Uploaded build $BUILD_ID."

INFO_JSON="$(asc_json builds info --build-id "$BUILD_ID")" || fail_job "build-info" "asc builds info failed for $BUILD_ID."
PROCESSING_STATE="$(printf '%s' "$INFO_JSON" | python3 -c '
import json, sys
d = json.load(sys.stdin)
data = d.get("data", d)
attrs = data.get("attributes", data) if isinstance(data, dict) else {}
print(attrs.get("processingState", ""))
' 2>/dev/null)"
[ "$PROCESSING_STATE" = "VALID" ] || fail_job "build-info" "Build $BUILD_ID processingState is '$PROCESSING_STATE', not VALID."

if [ -n "$FOLD_IN_VERSION_ID" ]; then
  VERSION_ID="$FOLD_IN_VERSION_ID"
  echo "Reusing folded-in version $VERSION_ID (renamed to $VERSION)."
else
  EXISTING_VERSION_ID="$(printf '%s' "$VERSIONS_JSON" | python3 -c '
import json, sys
d = json.load(sys.stdin)
ver = sys.argv[1]
for v in d["data"]:
    if v["attributes"].get("versionString") == ver:
        print(v["id"]); break
' "$VERSION" 2>/dev/null)"
  if [ -n "$EXISTING_VERSION_ID" ]; then
    VERSION_ID="$EXISTING_VERSION_ID"
    echo "Version $VERSION already exists as $VERSION_ID; skipping create."
  else
    CREATE_JSON="$(asc versions create --app "$APP_ID" --platform "$PLATFORM" --version "$VERSION" \
      --copy-metadata-from "$PREV_LIVE" \
      --copy-fields "description,keywords,marketingUrl,promotionalText,supportUrl,whatsNew" 2>&1)"
    CREATE_RC=$?
    echo "$CREATE_JSON"
    [ "$CREATE_RC" -eq 0 ] || fail_job "versions-create" "asc versions create failed (exit $CREATE_RC)."
    VERSION_ID="$(printf '%s' "$CREATE_JSON" | python3 -c '
import json, sys
raw = sys.stdin.read()
try:
    d = json.loads(raw)
    data = d.get("data", d)
    data = data[0] if isinstance(data, list) else data
    print(data.get("id", ""))
except Exception:
    print("")
' 2>/dev/null)"
    [ -n "$VERSION_ID" ] || fail_job "versions-create" "Could not parse a version ID out of asc versions create's output."
  fi
fi
echo "Version ID: $VERSION_ID"

asc versions attach-build --version-id "$VERSION_ID" --build-id "$BUILD_ID" \
  || fail_job "attach-build" "asc versions attach-build failed for version $VERSION_ID build $BUILD_ID."
asc versions update --version-id "$VERSION_ID" --release-type AFTER_APPROVAL \
  || fail_job "release-type" "asc versions update --release-type AFTER_APPROVAL failed for $VERSION_ID."

# ------------------------------------------------------------------ 7. What's New per locale
LOCALES_JSON="$(asc_json localizations list --version "$VERSION_ID")" || \
  fail_job "locales" "asc localizations list failed for $VERSION_ID."
LOCALES="$(printf '%s' "$LOCALES_JSON" | python3 -c '
import json, sys
d = json.load(sys.stdin)
for v in d["data"]:
    print(v["attributes"]["locale"])
' 2>/dev/null)"
[ -n "$LOCALES" ] || fail_job "locales" "No locales returned by asc localizations list for $VERSION_ID."
echo "Locales configured: $(printf '%s' "$LOCALES" | tr '\n' ' ')"

translate_whats_new() {
  local locale="$1" text="$2"
  claude -p --model sonnet --permission-mode dontAsk --strict-mcp-config \
    "Translate the following Mac App Store \"What's New\" text into the language of App Store Connect locale \"$locale\". Keep the same tone and about the same length. Do not translate these product feature names, keep them in English exactly as written: Dictate Prompt, Read Aloud, Dictate Live, Live Meeting, Chat. The text is PLAIN TEXT, not Markdown — output plain text only: no '#' headings, no '**' or '__' emphasis, no backticks, no Markdown bullets ('-'); keep the '•' bullets and ':' headings exactly as styled in the input. Output ONLY the translated text — no preface, no quotes, no code fences.

TEXT:
$text"
}

EXPECTED_FILE="$(mktemp)"
LOCALE_FAILED=""  # space-separated; /bin/bash 3.2 has no associative arrays
while read -r loc; do
  [ -z "$loc" ] && continue
  if [ "$loc" = "en-US" ] || [ "$loc" = "en" ]; then
    text="$ENGLISH_NOTES"
  else
    text="$(translate_whats_new "$loc" "$ENGLISH_NOTES")"
    text="$(printf '%s' "$text" | strip_markdown | strip_forbidden_glyphs)"
  fi
  if [ -z "$text" ]; then
    echo "WARN: empty translation for locale $loc; skipping it this run." >&2
    LOCALE_FAILED="$LOCALE_FAILED $loc"
    continue
  fi
  printf '%s\t%s\n' "$loc" "${text:0:40}" >> "$EXPECTED_FILE"
  asc localizations update --version "$VERSION_ID" --locale "$loc" --whats-new "$text" \
    || fail_job "whats-new" "asc localizations update --whats-new failed for locale $loc."
done <<< "$LOCALES"

# Read back and verify every locale that was written.
READBACK_JSON="$(asc_json localizations list --version "$VERSION_ID")" || \
  fail_job "whats-new-readback" "asc localizations list (read-back) failed for $VERSION_ID."
READBACK_FAIL="$(python3 -c '
import json, sys
expected = {}
with open(sys.argv[1]) as f:
    for line in f:
        loc, prefix = line.rstrip("\n").split("\t", 1)
        expected[loc] = prefix
d = json.loads(sys.argv[2])
bad = []
for v in d["data"]:
    loc = v["attributes"]["locale"]
    if loc not in expected:
        continue
    whats_new = v["attributes"].get("whatsNew") or ""
    if not whats_new.startswith(expected[loc]):
        bad.append(loc)
print(",".join(bad))
' "$EXPECTED_FILE" "$READBACK_JSON" 2>/dev/null)"
if [ -n "$READBACK_FAIL" ]; then
  fail_job "whats-new-readback" "What's New did not stick for locale(s): $READBACK_FAIL."
fi
if [ -n "$LOCALE_FAILED" ]; then
  echo "WARN: locales with no translation this run: ${LOCALE_FAILED# }"
fi
echo "What's New written and verified for all locales."

# ------------------------------------------------------------------ 8. submit
asc review submit --app "$APP_ID" --platform "$PLATFORM" \
  --version-id "$VERSION_ID" --build-id "$BUILD_ID" --confirm \
  || fail_job "submit" "asc review submit failed for version $VERSION_ID build $BUILD_ID."

echo "$TAG" > "$STATE_DIR/last-submitted"
rm -f "$STATE_DIR/failed-tag"

BODY="$(mktemp)"
{
  echo "$TAG submitted for App Store review."
  echo
  echo "Version: $VERSION (build $BUILD), version ID $VERSION_ID, build ID $BUILD_ID."
  echo "Release type: AFTER_APPROVAL — Apple releases it automatically once approved."
  echo "Locales updated: $(printf '%s' "$LOCALES" | tr '\n' ' ')"
} > "$BODY"
report_out "App Store: $TAG submitted for review" "$BODY" --verdict handled --verdict-handler "scripts/appstore-submit-job.sh"
rm -f "$BODY"

trap - EXIT
cleanup_worktree
echo "=== Done: $TAG submitted. ==="
exit 0
