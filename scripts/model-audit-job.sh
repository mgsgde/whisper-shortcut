#!/bin/bash

# Monthly model-audit job for WhisperShortcut.
#
# Two things have to happen every month, and only one of them can be automated away:
#   1. Measure. The test scripts and scripts/benchmark-transcription.py run first, unattended,
#      and their raw output is saved. This is the part that needs local API keys, macOS `say`,
#      and the app's own prompt/glossary — a cloud routine cannot do it.
#   2. Judge. A headless Claude session then reads those measurements, checks each provider's
#      current lineup against what the app ships, applies the Pareto rule, and writes a report.
#
# It deliberately does NOT change code. Model migrations are a decision, not a cron job; the
# report ends with a recommendation the user applies (or ignores) in an interactive session.
#
# The result is emailed (subject carries the one-line verdict, raw measurements attached), with a
# macOS notification as the fallback when mail cannot go out. Failures are reported the same way —
# an audit that silently stops running is worse than none, because it looks like all is well.
#
# Installed via ~/Library/LaunchAgents/com.whispershortcut.model-audit.plist.
# Costs a few cents in API calls per run (~400 short transcription requests).

# Usage: model-audit-job.sh [--measure-only] [--quick]
#   --measure-only  run the scripts and benchmark, skip the Claude judging pass
#   --quick         fewer benchmark rounds (smoke test that the plumbing works, not a real audit)
set -uo pipefail
export PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin"

# Model settings for the unattended judging pass, pinned rather than inherited so a change to
# ~/.claude/settings.json cannot silently alter what the monthly audit runs on.
#
# Opus, because the constraint here is not money: the CLI authenticates against a Claude Max
# subscription (`billingType: stripe_subscription`, `hasExtraUsageEnabled: false`, and no
# ANTHROPIC_API_KEY anywhere), so a monthly run consumes rate-limit capacity, not dollars. What
# it costs is a slice of one 5-hour window, once a month — and the audit's whole value is the
# quality of a judgement call (is this model really dominated on every axis?), which is exactly
# where the stronger model earns its slot.
#
# `--max-budget-usd` stays as a backstop for the case where an ANTHROPIC_API_KEY does enter the
# environment later and the run becomes dollar-billed. Under subscription auth there is no
# dollar spend for it to cap — do not mistake it for the thing keeping this job small.
AUDIT_MODEL="${AUDIT_MODEL:-opus}"
AUDIT_EFFORT="${AUDIT_EFFORT:-high}"
AUDIT_BUDGET_USD="${AUDIT_BUDGET_USD:-10}"

MEASURE_ONLY=0
BENCH_ARGS=()
for arg in "$@"; do
  case "$arg" in
    --measure-only) MEASURE_ONLY=1 ;;
    --quick) BENCH_ARGS+=(--rounds 1) ;;
    *) echo "unknown flag: $arg"; exit 2 ;;
  esac
done

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO" || exit 1

STAMP="$(date +%Y-%m-%d)"
REPORT_DIR="$REPO/plans/model-audits"
RAW="$REPORT_DIR/$STAMP-measurements.txt"
REPORT="$REPORT_DIR/$STAMP-audit.md"
mkdir -p "$REPORT_DIR"

echo "=== Model audit started: $(date '+%Y-%m-%d %H:%M:%S') ==="

if [ ! -f "$REPO/.env" ]; then
  echo "ERROR: no .env at repo root — cannot run live checks. Aborting."
  exit 1
fi

# ---------------------------------------------------------------- 1. measure
{
  echo "# Measurements — $STAMP"
  echo
  echo "## Model availability (test scripts)"
  for s in test-gemini-models.sh test-openai-models.sh test-grok-models.sh; do
    echo; echo "### $s"
    bash "$REPO/scripts/$s" 2>&1 || echo "(script exited non-zero — see lines above)"
  done
  echo
  echo "## Transcription benchmark"
  # -u: stdout is a pipe here, so Python would buffer ~8 KB and the log would stay empty for the
  # whole 20-minute benchmark. For a cron job whose only diagnostic is this file, a log that
  # only materialises at the end is the difference between "still working" and "wedged".
  python3 -u "$REPO/scripts/benchmark-transcription.py" "${BENCH_ARGS[@]+"${BENCH_ARGS[@]}"}" 2>&1 \
    || echo "(benchmark exited non-zero — see lines above)"
  echo
  echo "## Dictate Prompt benchmark"
  # Dictate Prompt is a separate code path (chat completions + inline input_audio) that the
  # transcription benchmark cannot see, and it is where audio-chat model changes actually land.
  # Scores rule compliance — does the model apply the spoken instruction rather than append it,
  # keep the register, leave facts alone — post-processing, i.e. what reaches the clipboard.
  python3 -u "$REPO/scripts/benchmark-dictate-prompt.py" "${BENCH_ARGS[@]+"${BENCH_ARGS[@]}"}" 2>&1 \
    || echo "(dictate-prompt benchmark exited non-zero — see lines above)"
} | tee "$RAW"

echo "Measurements written to $RAW"

if [ "$MEASURE_ONLY" -eq 1 ]; then
  echo "=== --measure-only: skipping the judging pass. Done: $(date '+%H:%M:%S') ==="
  exit 0
fi

# ---------------------------------------------------------------- 2. judge
# The prompt goes through a temp file rather than PROMPT=$(cat <<EOF …): macOS ships bash 3.2,
# which mis-parses an apostrophe inside a here-document nested in a command substitution
# ("unexpected EOF while looking for matching `''"). Writing the heredoc to a file first avoids
# the nesting entirely, and keeps `$REPO`/`$RAW` expansion (a quoted <<'EOF' would not).
PROMPT_FILE="$(mktemp -t wsmodelaudit)"
trap 'rm -f "$PROMPT_FILE"' EXIT
cat > "$PROMPT_FILE" <<EOF
You are the monthly model-audit job for WhisperShortcut (repo: $REPO).

The measurements have ALREADY been taken — do not re-run the test scripts or the benchmark.
Read them from: $RAW

Now follow the workflow in .cursor/commands/audit-llm-models.md, with these adjustments:
- Skip workflow steps 4 and 5 (running the scripts) — use $RAW instead. If a suite failed or was
  skipped in there, say so in the report rather than guessing what it would have shown.
- Do all the live web research: fetch each provider's current model index, pricing page and
  deprecation table (URLs are in the llm-model-docs skill). Training data is stale — every claim
  about a model that exists, its price, or its GA status must come from a page you fetched today.
- Compare against what the app ships today by reading TranscriptionModels.swift and
  Settings/Shared/SettingsConfiguration.swift.

Write the report to: $REPORT

The report's FIRST line must be a single-line verdict in exactly this form, because the job reads
it back and puts it in the macOS notification that tells the user the audit ran:

    VERDICT: <one sentence, max 120 chars, naming the actionable finding or "nothing to change">

Examples: "VERDICT: gpt-4o-transcribe dominated by gpt-transcribe; 1 new frontier model to add"
or "VERDICT: nothing to change — lineup is current and no model is dominated".

After that line, structure the report exactly as the "Output format" section of
audit-llm-models.md prescribes, and lead with a short "What changed since last month" section —
diff against the most recent previous report in $REPORT_DIR, if one exists.

Keep the report tight. It is read once a month by one person who wants to know whether to act.
Do not restate provider documentation at length; cite and link it.

The two questions the report must answer unambiguously:
1. Is any model we ship Pareto-dominated (a sibling from the same provider that is better or
   equal on EVERY axis — price in and out, quality, speed, context window — and strictly better
   on at least one)? If yes, name it and the sibling that dominates it, with numbers. If nothing
   is dominated, say that explicitly.
2. Is any model NOT in our lineup that should be — a new frontier model, or one that the
   benchmark shows would make a better default for its role?

Hard constraints:
- Do NOT change any code, defaults, or enum cases. Report only. The user applies migrations
  interactively.
- Do NOT recommend a model you have not seen serve a real request, either in $RAW or via a curl
  probe you run yourself.
- If a recommendation contradicts a measurement (e.g. a cheaper model that the benchmark shows
  leaks hallucinated transcripts), the measurement wins — say so.
EOF

# A launchd job nobody is watching must say something when it finishes — and especially when it
# fails. Silence is indistinguishable from "never ran".
#
# Email is the primary channel: it reaches the user off the Mac, and the report is worth reading
# in full rather than as a one-line banner. The macOS notification stays as the fallback for the
# case the mail cannot go out — most likely the login Keychain being locked at 09:17, which is a
# normal morning condition, not an error worth failing the whole job over.
AUDIT_MAIL_TO="${AUDIT_MAIL_TO:-mail@magnus-goedde.de}"

notify() {
  osascript -e "display notification \"$(printf '%s' "$2" | sed 's/"/\\"/g')\" with title \"$1\"" \
    >/dev/null 2>&1 || true
}

# report_out <subject> <body-file> [attachment …] — mail it, notify locally if that fails.
report_out() {
  local subject="$1" body="$2"; shift 2
  local attach_args=()
  for a in "$@"; do attach_args+=(--attach "$a"); done
  if python3 "$REPO/scripts/send-report-mail.py" --to "$AUDIT_MAIL_TO" \
       --subject "$subject" --body-file "$body" "${attach_args[@]+"${attach_args[@]}"}"; then
    return 0
  fi
  echo "WARN: could not send mail — falling back to a local notification"
  notify "$subject" "Email failed. Report: $body"
}

echo "Judging pass: model=$AUDIT_MODEL effort=$AUDIT_EFFORT budget=\$$AUDIT_BUDGET_USD"
claude -p --dangerously-skip-permissions \
  --model "$AUDIT_MODEL" --effort "$AUDIT_EFFORT" --max-budget-usd "$AUDIT_BUDGET_USD" \
  "$(cat "$PROMPT_FILE")" 2>&1
STATUS=$?

if [ $STATUS -ne 0 ] || [ ! -f "$REPORT" ]; then
  # A failed audit still has value: the measurements ran, so mail those and say what broke.
  # Reporting the failure matters more than the report itself — an audit that silently stops
  # happening is worse than one that never existed, because it looks like everything is fine.
  FAIL_NOTE="$(mktemp -t wsauditfail)"
  {
    if [ $STATUS -ne 0 ]; then
      echo "VERDICT: audit FAILED — claude exited with status $STATUS."
    else
      echo "VERDICT: audit INCOMPLETE — the judging pass wrote no report."
    fi
    echo
    echo "The measurements did run and are attached. Log: $REPO/build/logs/model-audit.log"
    echo "Re-run manually with: bash scripts/model-audit-job.sh"
  } > "$FAIL_NOTE"
  report_out "WhisperShortcut model audit FAILED ($STAMP)" "$FAIL_NOTE" "$RAW"
  rm -f "$FAIL_NOTE"
  exit 1
fi

# `LATEST.md` always points at the newest report, so there is one stable path to open.
ln -sf "$(basename "$REPORT")" "$REPORT_DIR/LATEST.md"

VERDICT="$(head -1 "$REPORT" | sed 's/^VERDICT:[[:space:]]*//')"
[ -n "$VERDICT" ] || VERDICT="Report written (no verdict line found)"
# The verdict goes in the subject so it is readable from a phone lock screen without opening
# the mail; the report is the body, the raw measurements are attached for anything questionable.
report_out "WhisperShortcut model audit — $VERDICT" "$REPORT" "$RAW"
echo "VERDICT: $VERDICT"
echo "Report: $REPORT"
echo "=== Model audit finished: $(date '+%Y-%m-%d %H:%M:%S') ==="
