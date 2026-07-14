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
  "gemini-3.1-pro-preview"
  "gemini-3.1-flash-lite"
  "gemini-3.5-flash"
)

# Legacy / migration targets — slugs we still accept via migrateLegacyTranscriptionRawValue
# and migrateLegacyPromptRawValue but no longer use in fresh selections.
declare -a LEGACY_TEXT_MODELS=(
  "gemini-3.1-flash-lite-preview"
  # Removed from the enum 2026-07-14 (forwarded via migrateLegacy*RawValue). Still SERVE today —
  # gemini-2.5-* shut down 2026-10-16, gemini-3-flash-preview is deprecated-pending. Expect 200
  # until those dates, at which point they move to LEGACY_RETIRED_TEXT_MODELS (must 404).
  "gemini-2.5-flash"
  "gemini-2.5-flash-lite"
  "gemini-2.5-pro"
  "gemini-3-flash-preview"
)

# Retired by Google — still in enum until migrate; must 404 (see ai.google.dev/gemini-api/docs/deprecations).
declare -a LEGACY_RETIRED_TEXT_MODELS=(
  "gemini-3-pro-preview"
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
echo "=== Gemini text-generation retired slugs (must 404 — confirms shutdown; enum cleanup pending) ==="
test_legacy_retired_text_model() {
  local model="$1"
  printf "%-35s [%s] " "$model" "legacy-retired"
  local response http_code
  response=$(curl -sS -w "\n%{http_code}" -X POST "${BASE}/${model}:generateContent" \
    -H "x-goog-api-key: $API_KEY" \
    -H "Content-Type: application/json" \
    -d "$BODY" 2>/dev/null) || true
  http_code=$(echo "$response" | tail -n1)
  if [[ "$http_code" == "404" ]]; then
    echo "OK (correctly removed by Google; add migrateLegacy* mapping when enum case is removed)"
    ((PASS++)) || true
  elif [[ "$http_code" == "200" ]]; then
    echo "UNEXPECTED 200 — Google un-retired this slug; move back to current and reconsider migration"
    ((FAIL++)) || true
  else
    echo "UNEXPECTED HTTP $http_code — investigate"
    ((FAIL++)) || true
  fi
}
for m in "${LEGACY_RETIRED_TEXT_MODELS[@]}"; do test_legacy_retired_text_model "$m"; done

echo ""
echo "=== Gemini text-generation candidates (migration targets) ==="
for m in "${CANDIDATE_TEXT_MODELS[@]}"; do test_text_model "$m" "candidate"; done

# TTS models (audio output). responseModalities=AUDIO, voiceConfig Charon.
echo ""
echo "=== Gemini TTS models ==="
declare -a CURRENT_TTS=(
  "gemini-3.1-flash-tts-preview"
)
# Migrate-only — removed from the TTSModel enum (forward to 3.1 Flash TTS via
# migrateLegacyReadAloudRawValue). Should still serve until Google's 2026-10-16 shutdown.
declare -a CANDIDATE_TTS=(
  "gemini-2.5-flash-preview-tts"
  "gemini-2.5-pro-preview-tts"
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
