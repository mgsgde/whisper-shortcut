#!/bin/bash

# Biweekly "did a provider ship a new model?" check for WhisperShortcut.
#
# Why this exists next to model-audit-job.sh: the audit runs once a month and is expensive
# (benchmarks + an Opus judging pass). grok-4.7 shipped ~2026-09-20, two and a half weeks after
# the 2026-09-03 audit, and the app only learned about it when the user noticed `/grok` still
# said 4.6. This job closes that gap cheaply: it only lists each provider's model IDs, no Claude,
# no benchmarks, a few seconds of HTTP.
#
# What counts as "new": an ID the provider lists now that (a) was not in the list at the last run
# and (b) is not already referenced anywhere in the app's Swift sources. It does NOT judge — the
# mail is a heads-up; whether to add the model (Pareto rule, see llm-model-docs) is decided in an
# interactive session or by the monthly audit.
#
# Sources:
#   Gemini    GET generativelanguage.googleapis.com/v1beta/models   (GEMINI_API_KEY from .env)
#   xAI       GET api.x.ai/v1/models                                (XAI_API_KEY)
#   OpenAI    GET api.openai.com/v1/models                          (OPENAI_API_KEY)
#   Anthropic model IDs scraped from the public models overview page — there is deliberately no
#             ANTHROPIC_API_KEY on this machine (scheduled jobs run on the subscription).
#
# State lives in build/model-lineup/ (gitignored): one seen-<provider>.txt per provider plus the
# last-run stamp. Delete the directory to re-seed.
#
# Cadence: launchd fires daily (StartInterval — a calendar slot that falls while the lid is shut
# is simply lost on a laptop); the 13-day gate below is what makes it biweekly.
# Installed via ~/Library/LaunchAgents/com.whispershortcut.model-lineup-check.plist
# (template: scripts/com.whispershortcut.model-lineup-check.plist).
#
# Usage: model-lineup-check.sh [--force] [--seed]
#   --force  ignore the 13-day gate
#   --seed   record the current lists as seen without mailing (first install)
set -uo pipefail
export PATH="/usr/local/bin:/usr/bin:/bin"

FORCE=0
SEED=0
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    --seed) SEED=1; FORCE=1 ;;
    *) echo "unknown flag: $arg"; exit 2 ;;
  esac
done

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO" || exit 1
STATE_DIR="$REPO/build/model-lineup"
mkdir -p "$STATE_DIR"
STAMP="$(date +%Y-%m-%d)"
GATE_DAYS=13

AUDIT_MAIL_TO="${AUDIT_MAIL_TO:-mail@magnus-goedde.de}"

notify() {
  osascript -e "display notification \"$(printf '%s' "$2" | sed 's/"/\\"/g')\" with title \"$1\"" \
    >/dev/null 2>&1 || true
}

# report_out <subject> <body-file> [send-report-mail.py flags …] — same contract as
# model-audit-job.sh: mail first, local notification when the mail cannot go out.
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
if [ "$FORCE" -eq 0 ] && [ -f "$STATE_DIR/last-run" ]; then
  LAST="$(cat "$STATE_DIR/last-run")"
  LAST_EPOCH="$(date -j -f '%Y-%m-%d' "$LAST" '+%s' 2>/dev/null || echo 0)"
  AGE_DAYS=$(( ( $(date +%s) - LAST_EPOCH ) / 86400 ))
  if [ "$AGE_DAYS" -lt "$GATE_DAYS" ]; then
    exit 0  # quiet: this fires daily, the gate is the normal path
  fi
fi

echo "=== Model lineup check started: $(date '+%Y-%m-%d %H:%M:%S') ==="

if [ -f "$REPO/.env" ]; then
  set -a; source "$REPO/.env"; set +a
fi

# ------------------------------------------------------------------ 1. fetch current IDs
# Each fetcher prints one ID per line, filtered to the families the app could ever offer
# (chat / speech / TTS), so embeddings, image-only and dated snapshots don't page anyone.
fetch_gemini() {
  [ -n "${GEMINI_API_KEY:-}" ] || return 1
  curl -sf --max-time 30 \
    "https://generativelanguage.googleapis.com/v1beta/models?pageSize=1000&key=$GEMINI_API_KEY" |
    python3 -c '
import json, sys
for m in json.load(sys.stdin)["models"]:
    i = m["name"].removeprefix("models/")
    if i.startswith("gemini-") and "embedding" not in i:
        print(i)'
}

fetch_xai() {
  [ -n "${XAI_API_KEY:-}" ] || return 1
  curl -sf --max-time 30 https://api.x.ai/v1/models -H "Authorization: Bearer $XAI_API_KEY" |
    python3 -c '
import json, sys
for m in json.load(sys.stdin)["data"]:
    print(m["id"])'
}

fetch_openai() {
  [ -n "${OPENAI_API_KEY:-}" ] || return 1
  curl -sf --max-time 30 https://api.openai.com/v1/models -H "Authorization: Bearer $OPENAI_API_KEY" |
    python3 -c '
import json, re, sys
for m in json.load(sys.stdin)["data"]:
    i = m["id"]
    if re.match(r"^(gpt-|o[0-9])", i) and not re.search(r"-\d{4}-\d{2}-\d{2}$", i):
        print(i)'
}

fetch_anthropic() {
  curl -sfL --max-time 30 https://platform.claude.com/docs/en/about-claude/models/overview |
    grep -oE 'claude-(opus|sonnet|haiku|fable|mythos)-[0-9]+(-[0-9]+)*' |
    grep -vE -- '-[0-9]{8}$'
}

NEW_FILE="$(mktemp)"
FAIL_FILE="$(mktemp)"
trap 'rm -f "$NEW_FILE" "$FAIL_FILE"' EXIT
SWIFT_SOURCES="$REPO/WhisperShortcut"

for provider in gemini xai openai anthropic; do
  current="$(mktemp)"
  if ! "fetch_$provider" 2>/dev/null | sort -u >"$current" || [ ! -s "$current" ]; then
    echo "$provider" >>"$FAIL_FILE"
    echo "  $provider: FETCH FAILED"
    rm -f "$current"
    continue
  fi
  seen="$STATE_DIR/seen-$provider.txt"
  touch "$seen"
  count=0
  while IFS= read -r id; do
    grep -qxF "$id" "$seen" && continue
    # Already wired into the app (any rawValue / string literal) → not news.
    grep -rqF "\"$id\"" "$SWIFT_SOURCES" --include='*.swift' && continue
    echo "    unseen: $id"
    [ "$SEED" -eq 1 ] || echo "$provider	$id" >>"$NEW_FILE"
    count=$((count + 1))
  done <"$current"
  echo "  $provider: $(wc -l <"$current" | tr -d ' ') listed, $count unseen & not in app"
  # Union, not replace: a model the provider briefly hides must not re-alert when it returns.
  sort -u "$seen" "$current" -o "$seen"
  rm -f "$current"
done

echo "$STAMP" >"$STATE_DIR/last-run"

if [ "$SEED" -eq 1 ]; then
  echo "Seeded $STATE_DIR — no mail sent."
  exit 0
fi

# ------------------------------------------------------------------ 2. report
NEW_COUNT="$(wc -l <"$NEW_FILE" | tr -d ' ')"
FAIL_COUNT="$(wc -l <"$FAIL_FILE" | tr -d ' ')"

if [ "$NEW_COUNT" -eq 0 ] && [ "$FAIL_COUNT" -eq 0 ]; then
  echo "Nothing new. No mail."
  exit 0
fi

BODY="$STATE_DIR/$STAMP-report.md"
{
  echo "# Model lineup check — $STAMP"
  echo
  if [ "$NEW_COUNT" -gt 0 ]; then
    echo "Provider model IDs that appeared since the last check and are not referenced anywhere"
    echo "in the app yet:"
    echo
    while IFS=$'\t' read -r p id; do echo "- **$p**: \`$id\`"; done <"$NEW_FILE"
    echo
    echo "This is a heads-up, not a verdict. To decide, open a session and ask for the"
    echo "llm-model-docs lineup check (Pareto rule: add the frontier point, set chatReplacement"
    echo "on whatever it dominates). Otherwise the monthly model audit picks it up."
    echo
  fi
  if [ "$FAIL_COUNT" -gt 0 ]; then
    echo "## Could not fetch"
    echo
    while IFS= read -r p; do echo "- $p"; done <"$FAIL_FILE"
    echo
    echo "Check the key in whisper-shortcut/.env, or the page for anthropic. Re-run:"
    echo "\`bash scripts/model-lineup-check.sh --force\`"
  fi
} >"$BODY"

if [ "$FAIL_COUNT" -gt 0 ] && [ "$NEW_COUNT" -eq 0 ]; then
  report_out "Model lineup check: fetch failed ($(paste -sd, "$FAIL_FILE"))" "$BODY" \
    --verdict needs-fix
elif [ "$NEW_COUNT" -gt 0 ]; then
  report_out "Model lineup check: $NEW_COUNT new model ID(s) — $(cut -f2 "$NEW_FILE" | head -3 | paste -sd, -)" \
    "$BODY" --verdict needs-decision --verdict-count "$NEW_COUNT"
fi
echo "Report: $BODY"
