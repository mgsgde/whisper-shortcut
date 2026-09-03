#!/usr/bin/env bash
# Create ~/.config/whispershortcut-implementer/env for run-implementer.sh.
# Idempotent — never overwrites an existing config. Architecture: plans/agent-loops.md.
set -euo pipefail

CONFIG_DIR="${HOME}/.config/whispershortcut-implementer"
CONFIG_FILE="${CONFIG_DIR}/env"

if [[ -f "$CONFIG_FILE" ]]; then
    echo "Config already exists: ${CONFIG_FILE} (not touched)"
    exit 0
fi

mkdir -p "$CONFIG_DIR"
cat >"$CONFIG_FILE" <<'EOF'
# Autonomous-implementer config — loaded by scripts/implementer/run-implementer.sh.
# chmod 600. Architecture: plans/agent-loops.md.

# Kill switch: the runner refuses to start unless this is exactly 1.
# Works without a rebuild — it is read at run time, so it is a real off switch.
IMPLEMENTER_ENABLED=0

# Cost tiering ("Cursor builds, Claude judges"): bulk implementation runs on the
# Cursor subscription, the scarcer Claude tier does the judging. Builder never
# judges its own work — the same proposer-is-never-the-judge rule the loops use.
IMPLEMENTER_BUILD_AGENT=cursor     # cursor | claude
IMPLEMENTER_BUILD_MODEL=auto       # cursor-agent model (auto = quota-friendly router)
IMPLEMENTER_REVIEW_AGENT=claude    # claude | none (none = skip the review gate)
IMPLEMENTER_REVIEW_MODEL=opus

IMPLEMENTER_TIMEOUT_SECONDS=7200   # hard cap for ONE build-agent phase
IMPLEMENTER_MAX_RUNS_PER_MONTH=10  # cumulative brake; counter in runs-YYYY-MM next to this file

# Live transcription roundtrips in the test gate spend the app's own provider keys (real money,
# ~1 cent a run). Off by default; set to 1 for a change that touches a provider request path.
IMPLEMENTER_LIVE_TESTS=0
IMPLEMENTER_SCOPE=app              # app | app-docs (see run-implementer.sh)

# After a fully green run, leave the BRANCH build running as your app, so you experience the
# change the moment it is ready instead of having to launch it. Only after every gate AND the
# reviewer's APPROVE; a failed run always restores your own build. 0 = old behaviour.
IMPLEMENTER_LAUNCH_BRANCH_BUILD=1

# Push the branch and open a PR — the approval surface (merge = approval), same as
# sabaki.dance. Pushing a branch publishes nothing to users: the release workflow
# fires on v* tags only. Set 0 to keep the branch local instead.
IMPLEMENTER_PUSH_PR=1

# Only after 5 consecutive clean MERGED rows in plans/implementer-log.md, and only
# by your hand — it lets the runner pick a proposal when the queue has no BUILD row.
# IMPLEMENTER_SELF_PICK=1

# --- Schedule (tick.sh, installed with scripts/implementer/install-tick.sh) -------------
# Second switch on purpose: IMPLEMENTER_ENABLED is the master kill switch every implementer
# script shares, this one stops only the hourly schedule. Read at run time, so turning the
# automation off never needs an edit or a rebuild.
IMPLEMENTER_TICK_ENABLED=0
IMPLEMENTER_GROOM=1                # file loop proposals into the queue on every tick

# --- The VETO lane ----------------------------------------------------------------------
# Rows the groomer can justify but no gate can judge are announced by mail with a deadline and
# promoted to BUILD on silence. Adding this lane LOOSENED a gate, which plans/agent-loops.md
# reserves for a human — decided 2026-09-03. Set to 0 and everything the groomer cannot prove
# lands in ASK instead, which is the pre-2026-09-03 behaviour.
IMPLEMENTER_VETO_LANE=1
IMPLEMENTER_VETO_DAYS_COPY=1       # windows are per class because blast radius differs,
IMPLEMENTER_VETO_DAYS_UI=2         # not because your attention does
IMPLEMENTER_VETO_DAYS_BUGFIX=2
IMPLEMENTER_VETO_DAYS_MODEL=3
IMPLEMENTER_MAX_INFLIGHT=3         # BUILD+VETO rows still OPEN; a VETO row is a queued build

# Where the loop jobs drop their proposal JSON for the groomer.
# IMPLEMENTER_INCOMING_DIR=~/.local/state/whispershortcut-implementer/incoming
EOF
chmod 600 "$CONFIG_FILE"
echo "Created ${CONFIG_FILE}"
echo "Review it, then set IMPLEMENTER_ENABLED=1 to arm the runner."
echo "For the hourly lane: bash scripts/implementer/install-tick.sh, then IMPLEMENTER_TICK_ENABLED=1."
