#!/usr/bin/env bash
# Test every Gemini generateContent model used by WhisperShortcut (and migration candidates).
# Reads GEMINI_API_KEY from .env at repo root, or accepts it via env var / positional arg.
# Usage: ./scripts/test-gemini-models.sh
#    or: GEMINI_API_KEY=your_key ./scripts/test-gemini-models.sh
#    or: ./scripts/test-gemini-models.sh your_api_key

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/../.env"
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  set -a; source "$ENV_FILE"; set +a
fi

API_KEY="${GEMINI_API_KEY:-${1:-}}"
if [[ -z "$API_KEY" ]]; then
  echo "Usage: GEMINI_API_KEY=your_key $0   (or put it in .env)"
  exit 1
fi

# Currently referenced in code (TranscriptionModels.swift, SettingsConfiguration.swift PromptModel).
declare -a CURRENT_TEXT_MODELS=(
  "gemini-2.5-flash"
  "gemini-2.5-flash-lite"
  "gemini-2.5-pro"
  "gemini-3-flash-preview"
  "gemini-3-pro-preview"
  "gemini-3.1-pro-preview"
  "gemini-3.1-flash-lite"
  "gemini-3.5-flash"
)

# Legacy / migration targets — slugs we still accept via migrateLegacyTranscriptionRawValue
# and migrateLegacyPromptRawValue but no longer use in fresh selections.
declare -a LEGACY_TEXT_MODELS=(
  "gemini-3.1-flash-lite-preview"
)

# Migration candidates surfaced by the models index (ai.google.dev/gemini-api/docs/models).
declare -a CANDIDATE_TEXT_MODELS=(
  "gemini-flash-lite-latest"
)

BASE="https://generativelanguage.googleapis.com/v1beta/models"
BODY='{"contents":[{"parts":[{"text":"Reply with exactly: OK"}]}]}'

PASS=0
FAIL=0

test_text_model() {
  local model="$1"
  local label="$2"
  local url="${BASE}/${model}:generateContent"
  printf "%-35s [%s] " "$model" "$label"
  local response http_code body
  response=$(curl -sS -w "\n%{http_code}" -X POST "$url" \
    -H "x-goog-api-key: $API_KEY" \
    -H "Content-Type: application/json" \
    -d "$BODY" 2>/dev/null) || true
  http_code=$(echo "$response" | tail -n1)
  body=$(echo "$response" | sed '$d')
  if [[ "$http_code" == "200" ]]; then
    if echo "$body" | grep -q '"text"'; then
      echo "OK"
      ((PASS++)) || true
    else
      echo "FAIL (200 but no text)"
      ((FAIL++)) || true
    fi
  else
    local err
    err=$(echo "$body" | grep -o '"message":"[^"]*"' | head -1 | sed 's/"message":"//;s/"$//')
    echo "FAIL HTTP $http_code ${err:0:60}"
    ((FAIL++)) || true
  fi
}

echo "=== Gemini text-generation models (current enum cases) ==="
for m in "${CURRENT_TEXT_MODELS[@]}"; do test_text_model "$m" "current"; done

echo ""
echo "=== Gemini text-generation legacy slugs (migrate-only, must still serve for back-compat) ==="
for m in "${LEGACY_TEXT_MODELS[@]}"; do test_text_model "$m" "legacy"; done

echo ""
echo "=== Gemini text-generation candidates (migration targets) ==="
for m in "${CANDIDATE_TEXT_MODELS[@]}"; do test_text_model "$m" "candidate"; done

# TTS models (audio output). responseModalities=AUDIO, voiceConfig Charon.
echo ""
echo "=== Gemini TTS models ==="
declare -a CURRENT_TTS=(
  "gemini-2.5-flash-preview-tts"
  "gemini-2.5-pro-preview-tts"
)
declare -a CANDIDATE_TTS=(
  "gemini-3.1-flash-tts-preview"
)
TTS_BODY='{"contents":[{"parts":[{"text":"Say the following: Hello"}]}],"generationConfig":{"responseModalities":["AUDIO"],"speechConfig":{"voiceConfig":{"prebuiltVoiceConfig":{"voiceName":"Charon"}}}}}'

test_tts_model() {
  local model="$1"
  local label="$2"
  local url="${BASE}/${model}:generateContent"
  printf "%-35s [%s] " "$model" "$label"
  local response http_code body
  response=$(curl -sS -w "\n%{http_code}" -X POST "$url" \
    -H "x-goog-api-key: $API_KEY" \
    -H "Content-Type: application/json" \
    -d "$TTS_BODY" 2>/dev/null) || true
  http_code=$(echo "$response" | tail -n1)
  body=$(echo "$response" | sed '$d')
  if [[ "$http_code" == "200" ]]; then
    if echo "$body" | grep -q '"inlineData"'; then
      echo "OK"
      ((PASS++)) || true
    else
      echo "FAIL (200 but no inlineData)"
      ((FAIL++)) || true
    fi
  else
    local err
    err=$(echo "$body" | grep -o '"message":"[^"]*"' | head -1 | sed 's/"message":"//;s/"$//')
    echo "FAIL HTTP $http_code ${err:0:60}"
    ((FAIL++)) || true
  fi
}

for m in "${CURRENT_TTS[@]}"; do test_tts_model "$m" "current"; done
for m in "${CANDIDATE_TTS[@]}"; do test_tts_model "$m" "candidate"; done

echo "---"
echo "Passed: $PASS  Failed: $FAIL"
exit $(( FAIL > 0 ? 1 : 0 ))
