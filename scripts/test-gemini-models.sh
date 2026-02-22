#!/usr/bin/env bash
# Test all Gemini generateContent models used by WhisperShortcut.
# Usage: GEMINI_API_KEY=your_key ./scripts/test-gemini-models.sh
#    or: ./scripts/test-gemini-models.sh your_api_key

set -e

API_KEY="${GEMINI_API_KEY:-${1:-}}"
if [[ -z "$API_KEY" ]]; then
  echo "Usage: GEMINI_API_KEY=your_key $0"
  echo "   or: $0 your_api_key"
  exit 1
fi

# Text-capable generateContent models only (TranscriptionModels.swift). TTS models use audio output and a different API.
declare -a MODELS=(
  "gemini-2.0-flash"
  "gemini-2.5-flash"
  "gemini-2.5-flash-lite"
  "gemini-3-flash-preview"
  "gemini-3-pro-preview"
  "gemini-3.1-pro-preview"
)

BASE="https://generativelanguage.googleapis.com/v1beta/models"
BODY='{"contents":[{"parts":[{"text":"Reply with exactly: OK"}]}]}'

PASS=0
FAIL=0

for model in "${MODELS[@]}"; do
  url="${BASE}/${model}:generateContent"
  printf "%-30s " "$model"
  response=$(curl -s -w "\n%{http_code}" -X POST "$url" \
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
      echo "FAIL (200 but no text in response)"
      ((FAIL++)) || true
    fi
  else
    err=$(echo "$body" | grep -o '"message":"[^"]*"' | head -1 | sed 's/"message":"//;s/"$//')
    echo "FAIL HTTP $http_code ${err:0:50}"
    ((FAIL++)) || true
  fi
done

# TTS models (SettingsConfiguration TTSModel): generateContent with responseModalities AUDIO, v1beta
echo ""
echo "TTS models (audio output):"
declare -a TTS_MODELS=(
  "gemini-2.5-flash-preview-tts"
  "gemini-2.5-pro-preview-tts"
)
TTS_BODY='{"contents":[{"parts":[{"text":"Say the following: Hello"}]}],"generationConfig":{"responseModalities":["AUDIO"],"speechConfig":{"voiceConfig":{"prebuiltVoiceConfig":{"voiceName":"Charon"}}}}}'

for model in "${TTS_MODELS[@]}"; do
  url="${BASE}/${model}:generateContent"
  printf "%-35s " "$model"
  response=$(curl -s -w "\n%{http_code}" -X POST "$url" \
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
      echo "FAIL (200 but no inlineData in response)"
      ((FAIL++)) || true
    fi
  else
    err=$(echo "$body" | grep -o '"message":"[^"]*"' | head -1 | sed 's/"message":"//;s/"$//')
    echo "FAIL HTTP $http_code ${err:0:50}"
    ((FAIL++)) || true
  fi
done

echo "---"
echo "Passed: $PASS  Failed: $FAIL"
exit $(( FAIL > 0 ? 1 : 0 ))
