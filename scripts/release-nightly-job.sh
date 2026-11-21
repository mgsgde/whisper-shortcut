#!/bin/bash

# Nightly automatic GitHub release (Sparkle DMG, "Latest" channel).
#
# Why: owner decision 2026-11-20 — GitHub releases are cut automatically, once a night, instead
# of by hand after a go. App Store submission stays manual (out of scope here). Stable promotion
# stays the Tuesday job (scripts/stable-promote-job.sh).
#
# What it does, in order (details at each step below):
#   gates -> newest green main CI sha -> anything user-visible since the last tag? -> full live
#   test plan in a detached worktree -> bump Info.plist + bundled docs -> release notes (EN/DE)
#   via headless `claude -p --model sonnet` -> commit "Update to version X.YZ" -> push to main
#   -> scripts/create-release.sh (the tag push triggers .github/workflows/release.yml).
#   If main moved during the tests, the version bump is cherry-picked onto the new tip for main
#   and the tag still points at the tested commit.
#
# Cadence: launchd fires every 30 minutes (StartInterval; a laptop misses calendar slots). The
# gates here decide: night window (local hour >= 21 or < 9), at most one release per 20 hours.
# A busy build slot (the test script exits 75) just means "retry next tick".
#
# State lives in build/release-nightly/ of the MAIN checkout (gitignored via build/):
#   hold          if this file exists, nothing is released; mails once a week. Contents = reason.
#   last-release  epoch seconds of the last successful release (20 h gate)
#   held-sha      sha whose live tests were red; not retried or re-mailed until main moves
#   failed-sha    "<sha> <step> <timestamp>": the notes step or create-release.sh failed at this sha;
#                 mailed once, not retried (unless --force) until main moves
#   pushed-untagged  "<version> <sha>": the release commit is on main but the tag is missing; the
#                 next ticks only retry create-release.sh for it (never bump again)
#   hold-mailed   ISO week the hold reminder was last mailed
#   src/          the detached release worktree
#   lock.d/       single-run lock (a stale pid is taken over)
# Log: build/logs/release-nightly.log
#
# Hold switch (from the main checkout):
#   echo "reason" > build/release-nightly/hold      # stop releasing
#   rm build/release-nightly/hold                   # resume
#
# Hotfix now, outside the night window / once-a-night limit, without the live test plan:
#   bash scripts/release-nightly-job.sh --force --skip-tests
#
# Install (not done automatically; template: scripts/com.whispershortcut.release-nightly.plist):
#   cp scripts/com.whispershortcut.release-nightly.plist ~/Library/LaunchAgents/
#   launchctl load ~/Library/LaunchAgents/com.whispershortcut.release-nightly.plist
# Uninstall:
#   launchctl unload ~/Library/LaunchAgents/com.whispershortcut.release-nightly.plist
#
# Usage: release-nightly-job.sh [--dry-run] [--force] [--skip-tests]
#   --force       ignore the night window, the 20-hour gate and held-sha (hold still applies)
#   --skip-tests  do not run the live test plan (manual hotfix runs)
#   --dry-run     every read-only step (gates, tag, green sha, commit list, new version, the
#                 claude prompt printed, not executed); no tests, no worktree changes, no
#                 commit/push/tag/mail
set -uo pipefail
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

FORCE=0
DRY=0
SKIP_TESTS=0
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    --dry-run) DRY=1 ;;
    --skip-tests) SKIP_TESTS=1 ;;
    *) echo "unknown flag: $arg"; exit 2 ;;
  esac
done

# Main checkout. `git worktree list | head -1` is the bare git dir in a submodule, so ask the
# common git dir where its work tree is (core.worktree); a plain repo falls back to the first
# listed worktree. Same trick as dev-daily.sh.
_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_common="$(git -C "$_here" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
_wt="$(git --git-dir="$_common" config --get core.worktree 2>/dev/null || true)"
if [[ -n "$_wt" ]]; then
  MAIN_ROOT="$(cd "$_common" && cd "$_wt" && pwd)"
else
  MAIN_ROOT="$(git -C "$_here" worktree list --porcelain 2>/dev/null | awk '/^worktree /{sub(/^worktree /,""); print; exit}')"
fi
if [[ -z "$MAIN_ROOT" ]]; then echo "release-nightly: cannot resolve the main checkout" >&2; exit 1; fi

STATE="$MAIN_ROOT/build/release-nightly"
SRC="$STATE/src"
GH_REPO="mgsgde/whisper-shortcut"
REPO_URL="https://github.com/$GH_REPO"
AUDIT_MAIL_TO="${AUDIT_MAIL_TO:-mail@magnus-goedde.de}"
CLAUDE_TIMEOUT="${RELEASE_NOTES_TIMEOUT_SECONDS:-600}"
MIN_GAP_SECONDS=72000   # 20 hours
mkdir -p "$STATE" "$MAIN_ROOT/build/logs"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') release-nightly: $*"; }
notify() {
  osascript -e "display notification \"$(printf '%s' "$2" | sed 's/"/\\"/g')\" with title \"$1\"" \
    >/dev/null 2>&1 || true
}

# report_out <subject> <body-file> [send-report-mail.py flags …]
report_out() {
  local subject="$1" body="$2"; shift 2
  if python3 "$MAIN_ROOT/scripts/send-report-mail.py" --to "$AUDIT_MAIL_TO" \
       --subject "$subject" --body-file "$body" "$@"; then
    return 0
  fi
  log "WARN: could not send mail, falling back to a local notification"
  notify "$subject" "Email failed. Body: $body"
}

# mail_text <subject> <verdict> <lines…> — write the lines to a file and mail it (no-op in dry-run).
mail_text() {
  local subject="$1" verdict="$2"; shift 2
  if [[ "$DRY" == 1 ]]; then log "[dry-run] would mail ($verdict): $subject"; return 0; fi
  local body
  body="$STATE/mail-$(date +%Y%m%d-%H%M%S).md"
  printf '%s\n' "$@" > "$body"
  report_out "$subject" "$body" --verdict "$verdict"
}

# record_failure <step> <subject> <verdict> <lines…> — write failed-sha and mail ONCE per sha.
# FAIL_SHA overrides the sha (default: TARGET).
record_failure() {
  local step="$1" subject="$2" verdict="$3"; shift 3
  local fsha="${FAIL_SHA:-${TARGET:-unknown}}" prev
  prev="$(cut -d' ' -f1 "$STATE/failed-sha" 2>/dev/null || true)"
  if [[ "$DRY" == 0 ]]; then echo "$fsha $step $(date -u +%FT%TZ)" > "$STATE/failed-sha"; fi
  if [[ "$prev" == "$fsha" ]]; then
    log "failure at ${fsha:0:8} ($step) already mailed, not mailing again."
  else
    mail_text "$subject" "$verdict" "$@"
  fi
}

# prepare_worktree <sha> — the detached release worktree at <sha>
prepare_worktree() {
  local sha="$1"
  if [[ -e "$SRC/.git" ]]; then
    git -C "$SRC" checkout -q --detach -f "$sha" || { log "checkout failed in $SRC"; return 1; }
  else
    git -C "$MAIN_ROOT" worktree prune
    rm -rf "$SRC"
    git -C "$MAIN_ROOT" worktree add -q --detach "$SRC" "$sha" || { log "worktree add failed"; return 1; }
  fi
  git -C "$SRC" clean -fdq
}

# retry_tag <version> <sha> — the release commit <sha> is on main; only (re)try the tag.
retry_tag() {
  local sha="$2" tag="v$1"
  if git -C "$MAIN_ROOT" rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
    log "tag $tag exists already, clearing pushed-untagged."
    rm -f "$STATE/pushed-untagged"
    git -C "$MAIN_ROOT" update-ref -d "refs/release-nightly/$tag" 2>/dev/null || true
    return 0
  fi
  log "release commit ${sha:0:8} for $tag is on main without a tag, retrying create-release.sh only."
  if [[ "$DRY" == 1 ]]; then log "[dry-run] would run create-release.sh --tag $tag from ${sha:0:8}"; return 0; fi
  git -C "$MAIN_ROOT" cat-file -e "$sha^{commit}" 2>/dev/null || { log "pushed sha ${sha:0:8} not fetched locally, retry next tick."; return 0; }
  prepare_worktree "$sha" || return 0
  if ( cd "$SRC" && bash scripts/create-release.sh --tag "$tag" --yes --skip-tests --allow-dirty ); then
    date +%s > "$STATE/last-release"
    rm -f "$STATE/held-sha" "$STATE/failed-sha" "$STATE/pushed-untagged"
    git -C "$MAIN_ROOT" update-ref -d "refs/release-nightly/$tag" || true
    log "released $tag (tag retry)."
    { cat "$SRC/.github/RELEASE_NOTES.md"; echo; echo "Build: $REPO_URL/actions"; } > "$STATE/mail-release.md"
    report_out "Released $tag" "$STATE/mail-release.md" --verdict fyi
    notify "WhisperShortcut" "Released $tag"
    return 0
  fi
  log "create-release.sh failed again for $tag."
  FAIL_SHA="$sha" record_failure tag "Nightly release: tag $tag still failing" needs-fix \
    "The version commit ${sha} is on main, but create-release.sh failed to tag $tag (retry)." "" \
    "Tag by hand from a checkout of that commit: bash scripts/create-release.sh --tag $tag --yes --skip-tests --allow-dirty"
  return 0
}

# ------------------------------------------------------------------ single-run lock
# mkdir is atomic and macOS ships no flock(1). A dead pid means a crashed run: take over.
if [[ "$DRY" == 0 ]]; then
  LOCK="$STATE/lock.d"
  if ! mkdir "$LOCK" 2>/dev/null; then
    old="$(cat "$LOCK/pid" 2>/dev/null || true)"
    if [[ -n "$old" ]] && kill -0 "$old" 2>/dev/null; then
      log "another run is still going (pid $old), skipping."
      exit 0
    fi
    log "stale lock (pid ${old:-?}), taking over."
    rm -rf "$LOCK"
    mkdir "$LOCK" 2>/dev/null || { log "lost the lock race, skipping."; exit 0; }
  fi
  echo $$ >"$LOCK/pid"
  trap 'rm -rf "$LOCK"' EXIT
fi

# ------------------------------------------------------------------ 1. gates
if [[ -f "$STATE/hold" ]]; then
  WEEK="$(date +%G-W%V)"
  if [[ "$(cat "$STATE/hold-mailed" 2>/dev/null || true)" == "$WEEK" ]]; then
    log "on hold (already mailed this week)."
    exit 0
  fi
  log "on hold: $(head -n1 "$STATE/hold")"
  if [[ "$DRY" == 1 ]]; then log "[dry-run] would mail the hold reminder (fyi)"; exit 0; fi
  mail_text "Nightly release is on hold" fyi \
    "The nightly release is on hold. Nothing was released." "" \
    "build/release-nightly/hold:" "" "$(cat "$STATE/hold")"
  echo "$WEEK" > "$STATE/hold-mailed"
  exit 0
fi

if [[ "$FORCE" == 0 ]]; then
  HOUR=$((10#$(date +%H)))
  if (( HOUR < 21 && HOUR >= 9 )); then
    log "outside the night window (hour $HOUR), skipping."
    exit 0
  fi
  if [[ -f "$STATE/last-release" ]]; then
    AGE=$(( $(date +%s) - $(tr -d '[:space:]' < "$STATE/last-release") ))
    if (( AGE < MIN_GAP_SECONDS )); then
      log "last release was $((AGE / 3600)) h ago (< 20 h), skipping."
      exit 0
    fi
  fi
fi

log "=== nightly release check started (dry=$DRY force=$FORCE skip_tests=$SKIP_TESTS) ==="

plist_read() { /usr/libexec/PlistBuddy -c "Print :$2" "$1"; }

# next_version <X.YZ> -> X.(YZ+1) in hundredths, rolling 8.99 -> 9.00 like the history does.
next_version() {
  local major="${1%%.*}" minor="${1##*.}" n
  n=$(( 10#$major * 100 + 10#$minor + 1 ))
  printf '%d.%02d' $(( n / 100 )) $(( n % 100 ))
}
# higher_version <a> <b>: the larger X.YZ
higher_version() {
  local a=$(( 10#${1%%.*} * 100 + 10#${1##*.} )) b=$(( 10#${2%%.*} * 100 + 10#${2##*.} ))
  if (( a >= b )); then echo "$1"; else echo "$2"; fi
}

# ------------------------------------------------------------------ 2. tag, green sha, commits
git -C "$MAIN_ROOT" fetch -q origin --tags || { log "git fetch failed, retry next tick."; exit 0; }
LAST_TAG="$(git -C "$MAIN_ROOT" tag --list 'v*' --sort=-v:refname | head -n1)"
[[ -n "$LAST_TAG" ]] || { log "no v* tag found, refusing to guess a base."; exit 0; }

if [[ -f "$STATE/pushed-untagged" ]]; then
  read -r PU_VER PU_SHA < "$STATE/pushed-untagged"
  if [[ -n "${PU_VER:-}" && -n "${PU_SHA:-}" ]]; then
    retry_tag "$PU_VER" "$PU_SHA"
    exit 0
  fi
  log "malformed pushed-untagged file, ignoring it."
fi

# RELEASE_NIGHTLY_TARGET overrides the sha (testing the dry-run before CI has a push run on main).
TARGET="${RELEASE_NIGHTLY_TARGET:-$(gh run list --repo "$GH_REPO" --workflow CI --branch main --event push --status success \
  --limit 1 --json headSha -q '.[0].headSha' 2>/dev/null || true)}"
if [[ -z "$TARGET" ]]; then log "no green main CI yet."; exit 0; fi
git -C "$MAIN_ROOT" cat-file -e "$TARGET^{commit}" 2>/dev/null \
  || { log "green sha ${TARGET:0:8} not fetched locally, retry next tick."; exit 0; }

# Never release commits that were not CI-green: the green sha must be the tip of main.
if [[ -z "${RELEASE_NIGHTLY_TARGET:-}" ]]; then
  TIP="$(git -C "$MAIN_ROOT" ls-remote origin main 2>/dev/null | awk '{print $1; exit}')"
  [[ -n "$TIP" ]] || { log "git ls-remote failed, retry next tick."; exit 0; }
  if [[ "$TIP" != "$TARGET" ]]; then
    log "main tip ${TIP:0:8} not green yet (newest green ${TARGET:0:8}) — waiting"
    exit 0
  fi
fi

if [[ "$FORCE" == 0 && -f "$STATE/failed-sha" && "$(cut -d' ' -f1 "$STATE/failed-sha")" == "$TARGET" ]]; then
  log "${TARGET:0:8} failed before ($(cut -d' ' -f2- "$STATE/failed-sha")), not retrying until main moves (or use --force)."
  exit 0
fi

# A release commit pushed earlier whose tag is missing (no state file): tag it, never bump again.
LEFT_PLIST="$(mktemp -t rn-left)"
git -C "$MAIN_ROOT" show "$TARGET:WhisperShortcut/Info.plist" > "$LEFT_PLIST" 2>/dev/null || true
LEFT_VER="$(plist_read "$LEFT_PLIST" CFBundleShortVersionString 2>/dev/null || true)"
rm -f "$LEFT_PLIST"
if [[ -n "$LEFT_VER" && "$(higher_version "$LEFT_VER" "${LAST_TAG#v}")" == "$LEFT_VER" && "$LEFT_VER" != "${LAST_TAG#v}" ]]; then
  log "Info.plist at ${TARGET:0:8} is $LEFT_VER, newer than $LAST_TAG: tagging it instead of bumping."
  retry_tag "$LEFT_VER" "$TARGET"
  exit 0
fi

if [[ "$FORCE" == 0 && -f "$STATE/held-sha" && "$(cat "$STATE/held-sha")" == "$TARGET" ]]; then
  log "${TARGET:0:8} was held (live tests red), not retrying until main moves."
  exit 0
fi

COMMITS="$(git -C "$MAIN_ROOT" log --no-merges --format='- %s%n%b' "$LAST_TAG..$TARGET" 2>/dev/null \
  | awk '/^- Update to version/{skip=1; next} /^- /{skip=0} !skip' | sed '/^$/d')"
if [[ -z "$COMMITS" ]]; then log "nothing to release since $LAST_TAG at ${TARGET:0:8}."; exit 0; fi
NCOMMITS="$(printf '%s\n' "$COMMITS" | grep -c '^- ')"
log "$LAST_TAG..${TARGET:0:8}: $NCOMMITS commit(s) to release."

# ------------------------------------------------------------------ 3. new version
PREV_VER="${LAST_TAG#v}"
compute_new_version() {  # $1 = plist short version
  NEW_VER="$(next_version "$(higher_version "$1" "$PREV_VER")")"
  NEW_TAG="v$NEW_VER"
}

# ------------------------------------------------------------------ 4. release-notes prompt
build_prompt() {
  local prev_en prev_de
  prev_en="$(git -C "$MAIN_ROOT" show "$LAST_TAG:.github/RELEASE_NOTES.md" 2>/dev/null || true)"
  prev_de="$(git -C "$MAIN_ROOT" show "$LAST_TAG:.github/RELEASE_NOTES.de.md" 2>/dev/null || true)"
  cat <<PROMPT
You write the release notes for WhisperShortcut $NEW_TAG, a macOS menu bar dictation app.
Repository: $REPO_URL

Source material, the commits since $LAST_TAG (newest first, subject lines and bodies):

$(printf '%s\n' "$COMMITS" | head -n 400)

Write two files, English and German, in exactly the format of the previous release notes below.

Rules:
- User-facing language, grouped under "## Heading" sections with "- " bullets. No commit hashes, PR numbers or issue ids.
- Omit developer-only changes: tests, CI, refactors, tooling, docs for contributors. If nothing is user-facing, write a single section "## Fixes and internal improvements" with one short line (German: "## Fehlerbehebungen und interne Verbesserungen").
- German is natural, user-facing, formal address (Sie-Form), not a word-for-word translation.
- End each file with the "## Installation" section exactly as in the examples (German text as in the German example), then the changelog line with the compare link $REPO_URL/compare/$LAST_TAG...$NEW_TAG
- Use the real URLs above. Never write placeholders such as USER/REPO or your-repo.

Output format, STRICT. Nothing before, between or after except this structure, no code fences, no commentary:
=====EN=====
<the English file content>
=====DE=====
<the German file content>

Previous English notes (format example):
-----
$prev_en
-----

Previous German notes (format example):
-----
$prev_de
-----
PROMPT
}

if [[ "$DRY" == 1 ]]; then
  PLIST_TMP="$(mktemp -t rn-plist)"
  git -C "$MAIN_ROOT" show "$TARGET:WhisperShortcut/Info.plist" > "$PLIST_TMP"
  CUR_SHORT="$(plist_read "$PLIST_TMP" CFBundleShortVersionString)"
  CUR_BUILD="$(plist_read "$PLIST_TMP" CFBundleVersion)"
  rm -f "$PLIST_TMP"
  compute_new_version "$CUR_SHORT"
  log "[dry-run] plist at ${TARGET:0:8}: version $CUR_SHORT build $CUR_BUILD; latest tag $LAST_TAG"
  log "[dry-run] new version would be $NEW_VER (build $((CUR_BUILD + 1))), tag $NEW_TAG"
  log "[dry-run] commits to release:"
  printf '%s\n' "$COMMITS" | head -n 40
  if [[ "$SKIP_TESTS" == 1 ]]; then
    log "[dry-run] live tests: skipped (--skip-tests)"
  else
    log "[dry-run] live tests: would run the full test script in $SRC with BUILD_LOCK_WAIT_SECONDS=0"
  fi
  log "[dry-run] claude prompt (NOT executed; would run: claude -p --model sonnet --output-format text, ${CLAUDE_TIMEOUT}s limit):"
  echo "-------- PROMPT BEGIN --------"
  build_prompt
  echo "-------- PROMPT END --------"
  log "[dry-run] would then commit 5 release files, push HEAD:main (if main moved: cherry-pick the version bump onto the new tip and tag the tested commit), run create-release.sh --tag $NEW_TAG, mail Released $NEW_TAG."
  exit 0
fi

# ------------------------------------------------------------------ 5. worktree at the target sha
prepare_worktree "$TARGET" || exit 0

# ------------------------------------------------------------------ 6. live test plan
if [[ "$SKIP_TESTS" == 1 ]]; then
  log "live tests skipped (--skip-tests)."
else
  if ! bash "$MAIN_ROOT/scripts/meeting-guard.sh" --dev-only; then
    log "meeting recording — retry next tick"
    exit 0
  fi
  TEST_LOG="$STATE/tests-${TARGET:0:8}.log"
  log "running the live test plan at ${TARGET:0:8} (log: $TEST_LOG)"
  ( cd "$SRC" && BUILD_LOCK_WAIT_SECONDS=0 bash scripts/run-tests.sh ) >"$TEST_LOG" 2>&1
  rc=$?
  if [[ $rc -eq 75 ]]; then
    log "build slot busy (exit 75), retry next tick."
    exit 0
  elif [[ $rc -ne 0 ]]; then
    log "live tests RED (exit $rc) at ${TARGET:0:8}."
    echo "$TARGET" > "$STATE/held-sha"
    mail_text "Nightly release held: live tests red at ${TARGET:0:8}" needs-fix \
      "The nightly release was held. The test script exited $rc at $TARGET." "" \
      "This sha is not retried until main moves. Fix, or hotfix with: bash scripts/release-nightly-job.sh --force --skip-tests" "" \
      "Tail of $TEST_LOG:" "" "$(tail -n 60 "$TEST_LOG")"
    exit 0
  fi
  log "live tests green."
  git -C "$SRC" checkout -q --detach -f "$TARGET"
  git -C "$SRC" clean -fdq
fi

# ------------------------------------------------------------------ 7. bump versions + bundled docs
PLIST="$SRC/WhisperShortcut/Info.plist"
CUR_SHORT="$(plist_read "$PLIST" CFBundleShortVersionString)"
CUR_BUILD="$(plist_read "$PLIST" CFBundleVersion)"
compute_new_version "$CUR_SHORT"
NEW_BUILD=$((CUR_BUILD + 1))
if git -C "$MAIN_ROOT" rev-parse -q --verify "refs/tags/$NEW_TAG" >/dev/null; then
  log "tag $NEW_TAG already exists, refusing."
  exit 0
fi
log "releasing $NEW_TAG (build $NEW_BUILD), previous $LAST_TAG."
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $NEW_VER" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEW_BUILD" "$PLIST"
mkdir -p "$SRC/WhisperShortcut/Docs"
cp "$SRC/README.md" "$SRC/WhisperShortcut/Docs/README.md"
cp "$SRC/docs/guide.md" "$SRC/WhisperShortcut/Docs/guide.md"

# ------------------------------------------------------------------ 8. release notes via headless Claude
fail_notes() {
  log "release notes failed: $1"
  record_failure notes "Nightly release failed: release notes at ${TARGET:0:8}" needs-fix \
    "Could not produce valid release notes for $NEW_TAG: $1" "" \
    "Nothing was committed or tagged. Not retried until main moves (or --force)." "" "$(printf '%s\n' "${2:-}" | head -n 60)"
  exit 0
}

PROMPT="$(build_prompt)"
OUT="$STATE/notes-output.txt"
( cd "$STATE" && perl -e 'alarm shift; exec @ARGV' "$CLAUDE_TIMEOUT" \
    claude -p --model sonnet --output-format text "$PROMPT" </dev/null ) >"$OUT" 2>"$STATE/notes-error.txt"
crc=$?
[[ $crc -eq 0 && -s "$OUT" ]] || fail_notes "claude exited $crc" "$(cat "$STATE/notes-error.txt" 2>/dev/null)"

trim_blank() { awk 'NF{p=1} p{buf[++n]=$0} END{while(n&&buf[n]!~/[^[:space:]]/)n--; for(i=1;i<=n;i++)print buf[i]}'; }
EN="$(awk '/^=====EN=====$/{s=1; next} /^=====DE=====$/{s=0} s' "$OUT" | trim_blank)"
DE="$(awk '/^=====DE=====$/{s=1; next} s' "$OUT" | trim_blank)"
COMPARE="$REPO_URL/compare/$LAST_TAG...$NEW_TAG"
[[ -n "$EN" && -n "$DE" ]] || fail_notes "missing or empty EN/DE section" "$(head -c 3000 "$OUT")"
grep -qF "$COMPARE" <<<"$EN" || fail_notes "EN notes lack the compare link $COMPARE" "$EN"
grep -qF "$COMPARE" <<<"$DE" || fail_notes "DE notes lack the compare link $COMPARE" "$DE"
if grep -qiE 'USER/REPO|your-repo' <<<"$EN"$'\n'"$DE"; then fail_notes "placeholder URL in the notes" "$EN"; fi
printf '%s\n' "$EN" > "$SRC/.github/RELEASE_NOTES.md"
printf '%s\n' "$DE" > "$SRC/.github/RELEASE_NOTES.de.md"

# ------------------------------------------------------------------ 9. commit, push, tag
RELEASE_FILES=(WhisperShortcut/Info.plist .github/RELEASE_NOTES.md .github/RELEASE_NOTES.de.md
               WhisperShortcut/Docs/README.md WhisperShortcut/Docs/guide.md)
git -C "$SRC" add -- "${RELEASE_FILES[@]}"
if ! git -C "$SRC" commit -q -m "Update to version $NEW_VER"; then
  log "commit failed"
  record_failure commit "Nightly release failed: commit at ${TARGET:0:8}" needs-fix \
    "git commit failed in the release worktree for $NEW_TAG." "Nothing was pushed."
  exit 0
fi
RELEASE_SHA="$(git -C "$SRC" rev-parse HEAD)"
# The tag points at this commit. If main moved it is not on origin/main, so keep it reachable
# until create-release.sh tags it (a later worktree prune/gc must not drop it first).
git -C "$MAIN_ROOT" update-ref "refs/release-nightly/$NEW_TAG" "$RELEASE_SHA"

# Give up on this release: worktree back at the tested target, drop the keep-alive ref.
restore_to_target() {
  git -C "$SRC" checkout -q --detach -f "$TARGET" 2>/dev/null || true
  git -C "$SRC" reset -q --hard "$TARGET" 2>/dev/null || true
  git -C "$SRC" clean -fdq
  git -C "$MAIN_ROOT" update-ref -d "refs/release-nightly/$NEW_TAG" 2>/dev/null || true
}

if git -C "$SRC" push -q origin HEAD:main 2>"$STATE/push-error.txt"; then
  MAIN_SHA="$RELEASE_SHA"
  log "pushed release commit ${RELEASE_SHA:0:8} to main."
else
  log "push rejected (main moved?), cherry-picking the version bump onto the new tip: $(head -n2 "$STATE/push-error.txt" | tr '\n' ' ')"
  MAIN_SHA=""
  for attempt in 1 2 3; do
    if ! git -C "$SRC" fetch -q origin main; then
      log "fetch origin main failed (attempt $attempt/3)."
      continue
    fi
    NEW_TIP="$(git -C "$SRC" rev-parse FETCH_HEAD 2>/dev/null)" || NEW_TIP=""
    if [[ -z "$NEW_TIP" ]]; then
      log "FETCH_HEAD missing after fetch (attempt $attempt/3)."
      continue
    fi
    if ! git -C "$SRC" checkout -q --detach -f FETCH_HEAD; then
      log "checkout of new main tip ${NEW_TIP:0:8} failed (attempt $attempt/3)."
      continue
    fi
    if ! git -C "$SRC" cherry-pick "$RELEASE_SHA"; then
      git -C "$SRC" cherry-pick --abort || true
      log "cherry-pick of ${RELEASE_SHA:0:8} onto ${NEW_TIP:0:8} failed, dropping the local release commit, retry next tick."
      restore_to_target
      exit 0
    fi
    if git -C "$SRC" push -q origin HEAD:main 2>"$STATE/push-error.txt"; then
      MAIN_SHA="$(git -C "$SRC" rev-parse HEAD)"
      log "main moved during the release (tip ${NEW_TIP:0:8}); pushed the version bump as ${MAIN_SHA:0:8}, tagging the tested commit ${RELEASE_SHA:0:8}"
      if ! git -C "$SRC" checkout -q --detach -f "$RELEASE_SHA"; then
        log "version bump is on main as ${MAIN_SHA:0:8}, but checkout of tested commit ${RELEASE_SHA:0:8} failed; tag retries next tick."
        echo "$NEW_VER $RELEASE_SHA" > "$STATE/pushed-untagged"
        exit 0
      fi
      break
    fi
    log "push of cherry-picked bump rejected (attempt $attempt/3): $(head -n2 "$STATE/push-error.txt" | tr '\n' ' ')"
  done
  if [[ -z "$MAIN_SHA" ]]; then
    log "push rejected after 3 attempts to cherry-pick the version bump onto main, retry next tick: $(head -n2 "$STATE/push-error.txt" | tr '\n' ' ')"
    restore_to_target
    exit 0
  fi
fi
echo "$NEW_VER $RELEASE_SHA" > "$STATE/pushed-untagged"

if ! ( cd "$SRC" && bash scripts/create-release.sh --tag "$NEW_TAG" --yes --skip-tests --allow-dirty ); then
  log "create-release.sh FAILED after the release commit was pushed."
  FAIL_SHA="$RELEASE_SHA" record_failure tag "Nightly release: tag $NEW_TAG failed after the version commit" needs-fix \
    "The version commit $RELEASE_SHA is on main, but create-release.sh failed to tag $NEW_TAG." "" \
    "The next ticks retry only the tag. Or by hand from a checkout of that commit: bash scripts/create-release.sh --tag $NEW_TAG --yes --skip-tests --allow-dirty"
  exit 0
fi

date +%s > "$STATE/last-release"
rm -f "$STATE/held-sha" "$STATE/failed-sha" "$STATE/pushed-untagged"
git -C "$MAIN_ROOT" update-ref -d "refs/release-nightly/$NEW_TAG" || true
log "released $NEW_TAG."
{
  cat "$SRC/.github/RELEASE_NOTES.md"
  echo
  echo "Build: $REPO_URL/actions"
} > "$STATE/mail-release.md"
report_out "Released $NEW_TAG" "$STATE/mail-release.md" --verdict fyi
notify "WhisperShortcut" "Released $NEW_TAG"
exit 0
