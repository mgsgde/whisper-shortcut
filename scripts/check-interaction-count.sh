#!/bin/bash
# Count interaction log entries in UserContext (JSONL = one JSON object per line).
# Checks sandbox container first (app from App Store or when sandboxed), then non-sandbox path.
SANDBOX_CONTEXT="$HOME/Library/Containers/com.magnusgoedde.whispershortcut/Data/Library/Application Support/WhisperShortcut/UserContext"
CONTEXT_DIR="$HOME/Library/Application Support/WhisperShortcut/UserContext"
if [[ -d "$SANDBOX_CONTEXT" ]]; then
  CONTEXT_DIR="$SANDBOX_CONTEXT"
  echo "Using sandbox: $CONTEXT_DIR"
elif [[ -d "$CONTEXT_DIR" ]]; then
  echo "Using: $CONTEXT_DIR"
else
  echo "UserContext not found in sandbox or Application Support. Run the app and do at least one dictation/prompt."
  exit 1
fi
total=0
for f in "$CONTEXT_DIR"/interactions-*.jsonl; do
  [[ -f "$f" ]] || continue
  count=$(wc -l < "$f" | tr -d ' ')
  echo "$(basename "$f"): $count entries"
  total=$((total + count))
done
if [[ $total -eq 0 ]]; then
  echo "No interaction files or all empty."
  exit 1
fi
echo "---"
echo "Total: $total interaction(s)"
