#!/usr/bin/env bash
# Test every Grok model used by WhisperShortcut (and migration candidates) against the
# OpenAI-compatible xAI chat completions endpoint. Reads XAI_API_KEY from .env at repo root.
# Usage: ./scripts/test-grok-models.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/../.env"
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  set -a; source "$ENV_FILE"; set +a
fi

API_KEY="${XAI_API_KEY:-${1:-}}"
if [[ -z "$API_KEY" ]]; then
  echo "Usage: XAI_API_KEY=your_key $0   (or put it in .env)"
  exit 1
fi

# Currently referenced in SettingsConfiguration.swift PromptModel.
declare -a CURRENT_MODELS=(
  "grok-4.20-0309-non-reasoning"
  "grok-4.20-0309-reasoning"
  "grok-4.3"
)
# Legacy slugs that we accept via migrateLegacyPromptRawValue but no longer expose in fresh
# selections. xAI silently redirects these to grok-4.3 (per May-15-2026 retirement notice).
declare -a LEGACY_MODELS=(
  "grok-4-1-fast-non-reasoning"
)
# Candidates surfaced by docs.x.ai/docs/models. (grok-4.20-multi-agent-0309 is excluded —
# it requires the multi-agent endpoint, not /chat/completions, so it's not a drop-in candidate.)
declare -a CANDIDATE_MODELS=(
  "grok-build-0.1"
)

PASS=0
FAIL=0

test_model() {
  local model="$1"
  local label="$2"
  printf "%-35s [%s] " "$model" "$label"
  local response http_code body
  response=$(curl -sS -w "\n%{http_code}" -X POST "https://api.x.ai/v1/chat/completions" \
    -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: application/json" \
    -d "$(printf '{"model":"%s","messages":[{"role":"user","content":"Reply with exactly: OK"}],"max_tokens":16}' "$model")" 2>/dev/null) || true
  http_code=$(echo "$response" | tail -n1)
  body=$(echo "$response" | sed '$d')
  if [[ "$http_code" == "200" ]]; then
    # Check if the response model differs from the requested model — that means xAI silently
    # redirected an old slug to a current one.
    local served
    served=$(echo "$body" | grep -o '"model":[ ]*"[^"]*"' | head -1 | sed 's/"model":[ ]*"//;s/"$//')
    if [[ -n "$served" && "$served" != "$model" ]]; then
      echo "OK (redirected → $served)"
    else
      echo "OK"
    fi
    ((PASS++)) || true
  else
    local err
    err=$(echo "$body" | grep -o '"message":[ ]*"[^"]*"' | head -1 | sed 's/"message":[ ]*"//;s/"$//')
    echo "FAIL HTTP $http_code ${err:0:80}"
    ((FAIL++)) || true
  fi
}

echo "=== Grok chat models (current enum cases) ==="
for m in "${CURRENT_MODELS[@]}"; do test_model "$m" "current"; done

echo ""
echo "=== Grok legacy slugs (must keep serving via redirect for back-compat) ==="
for m in "${LEGACY_MODELS[@]}"; do test_model "$m" "legacy"; done

echo ""
echo "=== Grok chat candidates ==="
for m in "${CANDIDATE_MODELS[@]}"; do test_model "$m" "candidate"; done

echo "---"
echo "Passed: $PASS  Failed: $FAIL"
exit $(( FAIL > 0 ? 1 : 0 ))
