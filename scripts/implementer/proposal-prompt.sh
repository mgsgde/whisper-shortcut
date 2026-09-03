#!/usr/bin/env bash
# Prints the block every loop job appends to its Claude prompt, telling it to drop a machine-
# readable proposal file next to its prose report.
#
#     bash scripts/implementer/proposal-prompt.sh <loop-name> >> "$PROMPT_FILE"
#
# Why a sidecar rather than parsing the reports: the groomer must contain no judgement
# (scripts/implementer/groom-queue.py), and a parser guessing which paragraph of a monthly audit
# is a proposal is exactly that. The loop already knows what it is proposing — it just has to
# say so in a form a lookup table can read. One place to maintain the schema; four callers.
set -euo pipefail
LOOP="${1:?usage: proposal-prompt.sh <loop-name>}"
INCOMING="${IMPLEMENTER_INCOMING_DIR:-$HOME/.local/state/whispershortcut-implementer/incoming}"
mkdir -p "$INCOMING"

cat <<EOF

## Also: hand your proposals to the implementer

Besides the report above, write a JSON file to:

    ${INCOMING}/${LOOP}-$(date +%Y-%m-%d-%H%M%S).json

It holds a LIST of the proposals from this run that are concrete enough to build — usually 0 to
3, and **an empty list \`[]\` is the right answer whenever this run's honest verdict is "build
nothing"**. Do not invent a proposal to fill the file. Each object:

    {
      "source":    "${LOOP} $(date +%Y-%m-%d) — <which ledger row / section this came from>",
      "title":     "<max 80 chars, distinct enough that the same finding next month matches it>",
      "proposal":  "<ONE line, imperative, naming the files to change. This becomes the queue row a build agent works from.>",
      "falsifier": "<what measurement, on what date, would show this did NOT work. Name the exact query or log line. No falsifier means the row cannot build unattended.>",
      "class":     "instrumentation | bug-fix | model-migration | ui | copy | other",
      "paths":     ["WhisperShortcut/…"],
      "gap":       <instrumentation only: the OPEN row number in plans/instrumentation-gaps.md this closes>
    }

Pick \`class\` by what the change IS, never by how badly you want it built — it decides which
gate the proposal has to pass, and a mislabelled row is the one way this pipeline can build
something nobody agreed to:

- \`instrumentation\` — adds or repairs a logged field. Must set \`gap\` to an OPEN row in
  plans/instrumentation-gaps.md. Builds immediately; the gap row is the checker.
- \`bug-fix\` — a defect with a repro. \`model-migration\` — a model ID swap the audit justified.
  \`ui\`, \`copy\` — user-visible surface. These get a veto window: announced by mail, built on
  silence, stopped with \`bash scripts/implementer/veto.sh <#>\`.
- \`other\` (or anything you are unsure about) — filed for a human decision. Use it freely;
  nothing is lost, and a wrong \`class\` costs more than a cautious one.

Constraints that are checked, not trusted: \`paths\` must all start with \`WhisperShortcut/\`,
\`WhisperShortcutTests/\` or \`plans/implementer-\`; anything else is filed for a human instead.
Do not set a flag, a deadline or a queue number — the groomer assigns those, and it is the only
thing here allowed to.
EOF
