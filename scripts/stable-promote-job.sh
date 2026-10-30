#!/bin/bash

# Weekly promotion of one WhisperShortcut release from Latest onto Stable.
#
# One appcast (releases/latest/download/appcast.xml, an asset of the newest published
# release). New items are tagged sparkle:channel latest, so only Latest users see them.
# Stable, the default, sees untagged items. Promotion removes that tag from one item
# via scripts/promote-stable.sh. Promote after ~7 days on Latest, never on a Friday:
# this job runs only on Tuesday, and only promotes a candidate frozen at least six
# days earlier (seven is the rule; six so a late Tuesday run still counts).
#
# Release assets of older releases must never be deleted: the appcast points at their
# DMGs. Rollback is a higher version number with the previous good code, then a
# promotion. Sparkle never downgrades.
#
# State lives in build/stable-channel/ (gitignored):
#   candidate   one line, "vX.Y YYYY-MM-DD" — the frozen date, not the day it ships
#   hold        if this file exists, do nothing but mail once a week; its contents
#               are the reason
#   last-run    YYYY-MM-DD, so a daily launchd fire runs the body at most once a day
#
# Manual overrides, from the main checkout:
#   echo "reason" > build/stable-channel/hold
#   echo "v8.72 $(date +%F)" > build/stable-channel/candidate   # replace the candidate
# Remove hold to let the next Tuesday proceed. Replacing candidate (a fix release)
# restarts the week, because the date on that line is the freeze date.
#
# Cadence: launchd fires daily (StartInterval — a calendar slot that falls while the
# lid is shut is simply lost on a laptop). The Tuesday gate below is what makes it
# weekly. Installed via ~/Library/LaunchAgents/com.whispershortcut.stable-promote.plist
# (template: scripts/com.whispershortcut.stable-promote.plist).
#
# Usage: stable-promote-job.sh [--force] [--dry-run]
#   --force    ignore the Tuesday gate and the once-a-day gate
#   --dry-run  print what would happen; no worktree, no tests, no promotion, no mail
set -uo pipefail
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

FORCE=0
DRY=0
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    --dry-run) DRY=1 ;;
    *) echo "unknown flag: $arg"; exit 2 ;;
  esac
done

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO" || exit 1
STATE_DIR="$REPO/build/stable-channel"
mkdir -p "$STATE_DIR" "$REPO/build/logs"
STAMP="$(date +%F)"

AUDIT_MAIL_TO="${AUDIT_MAIL_TO:-mail@magnus-goedde.de}"

notify() {
  osascript -e "display notification \"$(printf '%s' "$2" | sed 's/"/\\"/g')\" with title \"$1\"" \
    >/dev/null 2>&1 || true
}

# report_out <subject> <body-file> [send-report-mail.py flags …] — same contract as
# model-lineup-check.sh: mail first, local notification when the mail cannot go out.
report_out() {
  local subject="$1" body="$2"; shift 2
  if python3 "$REPO/scripts/send-report-mail.py" --to "$AUDIT_MAIL_TO" \
       --subject "$subject" --body-file "$body" "$@"; then
    return 0
  fi
  echo "WARN: could not send mail — falling back to a local notification"
  notify "$subject" "Email failed. Report: $body"
}

# ------------------------------------------------------------------ 0. cadence gate
if [ "$FORCE" -eq 0 ]; then
  if [ "$(date +%u)" != "2" ]; then
    [ "$DRY" -eq 1 ] && echo "dry-run: not Tuesday; would exit."
    exit 0
  fi
  if [ -f "$STATE_DIR/last-run" ] && [ "$(tr -d '[:space:]' < "$STATE_DIR/last-run")" = "$STAMP" ]; then
    [ "$DRY" -eq 1 ] && echo "dry-run: already ran today; would exit."
    exit 0
  fi
fi

echo "=== Stable promotion check started: $(date '+%Y-%m-%d %H:%M:%S') ==="

finish() {
  # A completed run, including "nothing to do", counts for the once-a-day gate.
  [ "$DRY" -eq 1 ] && return 0
  echo "$STAMP" > "$STATE_DIR/last-run"
}

# ------------------------------------------------------------------ 1. hold
if [ -f "$STATE_DIR/hold" ]; then
  echo "Promotion is on hold."
  if [ "$DRY" -eq 1 ]; then
    echo "dry-run: would mail (fyi) and exit. hold contains:"
    cat "$STATE_DIR/hold"
    exit 0
  fi
  BODY="$STATE_DIR/$STAMP-hold.md"
  {
    echo "Stable promotion is on hold. Nothing was promoted."
    echo
    echo "build/stable-channel/hold:"
    echo
    cat "$STATE_DIR/hold"
  } > "$BODY"
  report_out "Stable promotion is on hold" "$BODY" --verdict fyi
  finish
  exit 0
fi

# ------------------------------------------------------------------ 2. read the feed (same source as promote-stable.sh step 4)
FEED_TMP="$(mktemp -d)"
trap 'rm -rf "$FEED_TMP"' EXIT

fail_mail() {
  local subject="$1" detail="$2"
  echo "$detail" >&2
  if [ "$DRY" -eq 1 ]; then
    echo "dry-run: would mail needs-fix: $subject"
    printf '%s\n' "$detail"
    exit 1
  fi
  BODY="$STATE_DIR/$STAMP-fail.md"
  printf '%s\n' "$detail" > "$BODY"
  report_out "$subject" "$BODY" --verdict needs-fix
  finish
  exit 0
}

LATEST_TAG="$(gh release view --json tagName -q .tagName)" || fail_mail \
  "Stable promotion: could not read the latest release" \
  "gh release view failed, so the feed could not be read. Nothing was promoted."
if ! gh release download "$LATEST_TAG" -p appcast.xml -D "$FEED_TMP" || [ ! -s "$FEED_TMP/appcast.xml" ]; then
  fail_mail "Stable promotion: $LATEST_TAG has no appcast" \
    "Could not download appcast.xml from $LATEST_TAG. Nothing was promoted."
fi

# Prints "<shortVersion>\t<tagged|untagged>" per item.
python3 - "$FEED_TMP/appcast.xml" > "$FEED_TMP/items.tsv" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
items = re.findall(r"<item\b[^>]*>.*?</item>", text, flags=re.DOTALL)
short_re = re.compile(r"<sparkle:shortVersionString>([^<]*)</sparkle:shortVersionString>")
channel_re = re.compile(r"<sparkle:channel\b")
for item in items:
    match = short_re.search(item)
    if not match:
        continue
    state = "tagged" if channel_re.search(item) else "untagged"
    sys.stdout.write("%s\t%s\n" % (match.group(1).strip(), state))
PY

CURRENT_STABLE="$(awk -F '\t' '$2=="untagged" { print $1 }' "$FEED_TMP/items.tsv" | sort -V | tail -n 1 || true)"
if [ -z "$CURRENT_STABLE" ]; then
  echo "Stable currently serves: none"
else
  echo "Stable currently serves: $CURRENT_STABLE"
fi

version_is_newer() {
  # $1 candidate short version, $2 current Stable (empty if none). True when $1 is newer.
  [ -n "$1" ] || return 1
  [ -z "$2" ] && return 0
  [ "$1" = "$2" ] && return 1
  local top
  top="$(printf '%s\n%s\n' "$2" "$1" | sort -V | tail -n 1 || true)"
  [ "$top" = "$1" ]
}

item_state() {
  awk -F '\t' -v v="$1" '$1==v { print $2; exit }' "$FEED_TMP/items.tsv"
}

remove_worktree() {
  local wt="$1" log
  [ -e "$wt" ] || return 0
  log="$(mktemp)"
  if bash "$REPO/scripts/worktree-remove.sh" "$wt" >"$log" 2>&1; then
    cat "$log"
    rm -f "$log"
    return 0
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

# A linked worktree of this submodule can inherit a wrong core.worktree and then
# every git command writes into the module gitdir. Repair before tests run there.
ensure_worktree_toplevel() {
  local wt="$1" top expected gitdir
  expected="$(cd "$wt" && pwd -P)"
  top="$(git -C "$wt" rev-parse --show-toplevel 2>/dev/null || true)"
  if [ -n "$top" ]; then
    top="$(cd "$top" && pwd -P)"
  fi
  [ "$top" = "$expected" ] && return 0
  gitdir="$(sed -n 's/^gitdir: //p' "$wt/.git" 2>/dev/null || true)"
  if [ -z "$gitdir" ] || [ ! -d "$gitdir" ]; then
    echo "Worktree $wt resolves to '$top' and has no gitdir to repair." >&2
    return 1
  fi
  printf '[core]\n\tworktree = %s\n' "$expected" > "${gitdir}/config.worktree"
  top="$(git -C "$wt" rev-parse --show-toplevel 2>/dev/null || true)"
  [ -n "$top" ] && top="$(cd "$top" && pwd -P)"
  if [ "$top" != "$expected" ]; then
    echo "Worktree $wt still resolves to '$top'." >&2
    return 1
  fi
  echo "Repaired core.worktree for $wt"
}

CAND_TAG=""
CAND_DATE=""
CAND_VER=""
CAND_AGE=""
PROMOTED=""
WOULD_PROMOTE=""
FAILURE=""
FAIL_DETAIL=""

if [ -f "$STATE_DIR/candidate" ]; then
  cand_line="$(head -n 1 "$STATE_DIR/candidate")"
  CAND_TAG="${cand_line%% *}"
  CAND_DATE="${cand_line##* }"
  CAND_VER="${CAND_TAG#v}"
  if [[ ! "$CAND_TAG" =~ ^v[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || ! cand_epoch="$(date -j -f '%Y-%m-%d' "$CAND_DATE" '+%s' 2>/dev/null)"; then
    fail_mail "Stable promotion: candidate file is not readable" \
      "build/stable-channel/candidate must be one line: vX.Y YYYY-MM-DD. It contains: $cand_line"
  fi
  CAND_AGE="$(( ( $(date +%s) - cand_epoch ) / 86400 ))"
  echo "Candidate $CAND_TAG frozen $CAND_DATE ($CAND_AGE days ago)."
fi

# ------------------------------------------------------------------ 3. promote a candidate that has waited long enough
if [ -n "$CAND_TAG" ] && [ "$CAND_AGE" -ge 6 ]; then
  state="$(item_state "$CAND_VER")"
  if [ "$state" = "untagged" ]; then
    echo "$CAND_TAG is already on Stable. Skipping tests."
    if [ "$DRY" -eq 1 ]; then
      echo "dry-run: would drop candidate $CAND_TAG (already untagged)."
    else
      rm -f "$STATE_DIR/candidate"
      CAND_TAG=""
    fi
  elif ! version_is_newer "$CAND_VER" "$CURRENT_STABLE"; then
    # promote-stable.sh would refuse. Do not spend a test run on that.
    echo "$CAND_TAG is not newer than Stable (${CURRENT_STABLE:-none}). Not promoting."
    if [ "$DRY" -eq 1 ]; then
      echo "dry-run: would drop candidate $CAND_TAG."
    else
      rm -f "$STATE_DIR/candidate"
      CAND_TAG=""
    fi
  elif [ "$DRY" -eq 1 ]; then
    echo "dry-run: would check out $CAND_TAG, run scripts/run-tests.sh, then promote-stable.sh $CAND_TAG --yes."
    WOULD_PROMOTE="$CAND_TAG"
  else
    WT="$STATE_DIR/wt"
    LOG="$STATE_DIR/tests-${CAND_TAG}.log"
    if ! git -C "$REPO" fetch --tags; then
      FAILURE="fetch"
      FAIL_DETAIL="git fetch --tags failed. $CAND_TAG was not promoted. The candidate is unchanged."
    elif ! remove_worktree "$WT"; then
      FAILURE="worktree"
      FAIL_DETAIL="Could not remove $WT (an app may be running from it). $CAND_TAG was not promoted."
    elif ! git -C "$REPO" worktree add --detach "$WT" "$CAND_TAG"; then
      FAILURE="worktree"
      FAIL_DETAIL="git worktree add $CAND_TAG failed. Nothing was promoted. The candidate is unchanged."
    elif ! ensure_worktree_toplevel "$WT"; then
      FAILURE="worktree"
      FAIL_DETAIL="The worktree at $WT does not resolve to itself. $CAND_TAG was not promoted."
      remove_worktree "$WT" || true
    else
      set +e
      (
        # Hermetic: a gate must not depend on live API keys (an expired Gemini key would block
        # every promotion). The Parakeet env still runs the local offline-dictation tests.
        export TEST_RUNNER_WHISPERSHORTCUT_BENCH_PARAKEET=1
        bash "$WT/scripts/run-tests.sh" --hermetic
      ) >"$LOG" 2>&1
      test_rc=$?
      set +e
      remove_worktree "$WT" || echo "WARN: left worktree at $WT"
      summary="$(grep -E "Test run with|TEST SUCCEEDED|TEST FAILED" "$LOG" || true)"
      if [ "$test_rc" -ne 0 ]; then
        FAILURE="tests"
        FAIL_DETAIL="$(printf '%s\n' \
          "Tests for $CAND_TAG failed (exit $test_rc). Nothing was promoted. The candidate is unchanged." \
          "Log: build/stable-channel/tests-${CAND_TAG}.log" \
          "" \
          "$summary")"
        if [ -z "$summary" ]; then
          FAIL_DETAIL="$FAIL_DETAIL

$(tail -n 40 "$LOG")"
        fi
      else
        promote_out="$(mktemp)"
        if bash "$REPO/scripts/promote-stable.sh" "$CAND_TAG" --yes >"$promote_out" 2>&1; then
          cat "$promote_out"
          if grep -q "already on Stable" "$promote_out"; then
            echo "$CAND_TAG is already on Stable."
            rm -f "$STATE_DIR/candidate"
            CAND_TAG=""
          else
            PROMOTED="$CAND_TAG"
            rm -f "$STATE_DIR/candidate"
            CAND_TAG=""
          fi
        else
          cat "$promote_out" >&2
          FAILURE="promote"
          FAIL_DETAIL="$(printf '%s\n' \
            "Tests for ${CAND_TAG} were green, but promote-stable.sh failed. Nothing was promoted. The candidate is unchanged." \
            "" \
            "---- tests ----" \
            "$summary" \
            "" \
            "---- promote-stable.sh ----" \
            "$(cat "$promote_out")")"
        fi
        rm -f "$promote_out"
      fi
    fi
  fi
elif [ -n "$CAND_TAG" ]; then
  echo "Candidate $CAND_TAG is $CAND_AGE days old; waiting until 6."
  [ "$DRY" -eq 1 ] && echo "dry-run: would not test or promote $CAND_TAG yet."
fi

if [ -n "$FAILURE" ]; then
  [ "$DRY" -eq 1 ] && echo "dry-run: would mail needs-fix ($FAILURE)" && exit 1
  BODY="$STATE_DIR/$STAMP-fail.md"
  printf '%s\n' "$FAIL_DETAIL" > "$BODY"
  report_out "Stable: ${CAND_TAG:-candidate} was not promoted" "$BODY" --verdict needs-fix
  finish
  exit 0
fi

# A promotion this run moves Stable forward even though the downloaded feed is the
# pre-promotion copy. Otherwise the tag we just promoted is frozen again.
effective_promoted="${PROMOTED:-$WOULD_PROMOTE}"
if [ -n "$effective_promoted" ]; then
  promoted_ver="${effective_promoted#v}"
  if version_is_newer "$promoted_ver" "$CURRENT_STABLE"; then
    CURRENT_STABLE="$promoted_ver"
  fi
fi

# ------------------------------------------------------------------ 4. freeze the next candidate
# Newest published non-prerelease v* release. The list is newest-first; isLatest is
# requested so the payload matches the release that serves the feed when that release
# is a full release.
NEW_TAG="$(gh release list --exclude-drafts --exclude-pre-releases --json tagName,isLatest \
  --jq '[.[] | select(.tagName | test("^v[0-9]+[.][0-9]+([.][0-9]+)?$"))][0].tagName')" || NEW_TAG=""
if [ "$NEW_TAG" = "null" ]; then
  NEW_TAG=""
fi
NEW_VER="${NEW_TAG#v}"
FROZE=""
if [ -z "$NEW_TAG" ]; then
  echo "No published v* release to freeze."
elif ! version_is_newer "$NEW_VER" "$CURRENT_STABLE"; then
  echo "$NEW_TAG is not newer than Stable (${CURRENT_STABLE:-none}); not freezing it."
elif [ -n "$CAND_TAG" ] && [ "$NEW_TAG" = "$CAND_TAG" ]; then
  echo "Candidate stays $CAND_TAG (frozen $CAND_DATE)."
else
  if [ "$DRY" -eq 1 ]; then
    echo "dry-run: would freeze $NEW_TAG dated $STAMP (newer than Stable ${CURRENT_STABLE:-none})."
  else
    echo "Froze $NEW_TAG dated $STAMP (newer than Stable ${CURRENT_STABLE:-none})."
    printf '%s %s\n' "$NEW_TAG" "$STAMP" > "$STATE_DIR/candidate"
  fi
  FROZE="$NEW_TAG"
fi

# ------------------------------------------------------------------ 5. mail
if [ "$DRY" -eq 1 ]; then
  if [ -n "$WOULD_PROMOTE" ]; then
    echo "dry-run: would mail handled: Stable: $WOULD_PROMOTE promoted"
  fi
  if [ -n "$FROZE" ] && [ -z "$WOULD_PROMOTE" ]; then
    echo "dry-run: would mail fyi: froze candidate $FROZE"
  elif [ -n "$FROZE" ]; then
    echo "dry-run: promotion mail would also mention candidate $FROZE"
  fi
  if [ -z "$WOULD_PROMOTE" ] && [ -z "$FROZE" ]; then
    echo "dry-run: nothing to promote or freeze; no mail."
  fi
  exit 0
fi

if [ -n "$PROMOTED" ]; then
  summary="$(grep -E "Test run with|TEST SUCCEEDED|TEST FAILED" "$STATE_DIR/tests-${PROMOTED}.log" || true)"
  BODY="$STATE_DIR/$STAMP-promoted.md"
  {
    echo "Stable: $PROMOTED promoted."
    echo
    echo "$summary"
    if [ -n "$FROZE" ]; then
      echo
      echo "Froze the next candidate: $FROZE $STAMP."
    fi
  } > "$BODY"
  report_out "Stable: $PROMOTED promoted" "$BODY" \
    --verdict handled --verdict-handler "scripts/stable-promote-job.sh"
elif [ -n "$FROZE" ]; then
  BODY="$STATE_DIR/$STAMP-candidate.md"
  {
    echo "Froze $FROZE on $STAMP. Nothing was promoted today."
    echo
    echo "On the Tuesday when this date is at least six days ago, the job tests that tag and, if the tests are green, promotes it onto Stable."
    echo "Hold: write a reason to build/stable-channel/hold in the main checkout."
  } > "$BODY"
  report_out "Stable: froze candidate $FROZE" "$BODY" --verdict fyi
else
  echo "Nothing to promote or freeze. No mail."
fi

finish
exit 0
