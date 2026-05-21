#!/usr/bin/env bash
# Test every OpenAI chat/transcription model used by WhisperShortcut (and migration candidates).
# Reads OPENAI_API_KEY from .env at repo root.
# Usage: ./scripts/test-openai-models.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/../.env"
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  set -a; source "$ENV_FILE"; set +a
fi

API_KEY="${OPENAI_API_KEY:-${1:-}}"
if [[ -z "$API_KEY" ]]; then
  echo "Usage: OPENAI_API_KEY=your_key $0   (or put it in .env)"
  exit 1
fi

# Currently referenced in SettingsConfiguration.swift PromptModel + SpeechService.swift transcription paths.
declare -a CURRENT_CHAT_MODELS=(
  "gpt-5"
  "gpt-5-mini"
  "gpt-5.5"
)
# gpt-audio (renamed from gpt-4o-audio-preview) requires audio modality — tested separately below.
declare -a CURRENT_AUDIO_CHAT_MODELS=(
  "gpt-audio"
)
# Legacy slugs we accept via migrateLegacyPromptRawValue but no longer use in fresh selections.
# Expected behaviour: 404 (model removed). Surfaces upstream renames if a slug suddenly returns 200.
declare -a LEGACY_CHAT_MODELS=(
  "gpt-4o-audio-preview"
)
declare -a CANDIDATE_CHAT_MODELS=(
  "chat-latest"
  "gpt-5-chat-latest"
)
declare -a CURRENT_TRANSCRIPTION_MODELS=(
  "gpt-4o-transcribe"
  "gpt-4o-mini-transcribe"
)

PASS=0
FAIL=0

test_chat_model() {
  local model="$1"
  local label="$2"
  printf "%-25s [%s] " "$model" "$label"
  local response http_code body
  response=$(curl -sS -w "\n%{http_code}" -X POST "https://api.openai.com/v1/chat/completions" \
    -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: application/json" \
    -d "$(printf '{"model":"%s","messages":[{"role":"user","content":"Reply with exactly: OK"}],"max_completion_tokens":16}' "$model")" 2>/dev/null) || true
  http_code=$(echo "$response" | tail -n1)
  body=$(echo "$response" | sed '$d')
  if [[ "$http_code" == "200" ]]; then
    if echo "$body" | grep -q '"content"'; then
      echo "OK"
      ((PASS++)) || true
    else
      echo "FAIL (200 but no content)"
      ((FAIL++)) || true
    fi
  else
    local err
    err=$(echo "$body" | grep -o '"message":[ ]*"[^"]*"' | head -1 | sed 's/"message":[ ]*"//;s/"$//')
    echo "FAIL HTTP $http_code ${err:0:80}"
    ((FAIL++)) || true
  fi
}

# Transcription test: send a tiny silent wav and check the endpoint accepts the model ID.
# We use a 0.1s mono 16k WAV generated on-the-fly via head -c (44-byte header + zeros).
make_silent_wav() {
  local out="$1"
  python3 - "$out" <<'PY'
import struct,sys,wave
out=sys.argv[1]
with wave.open(out,'wb') as w:
  w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000)
  w.writeframes(b'\x00\x00'*1600)  # 0.1s silence
PY
}

test_transcription_model() {
  local model="$1"
  local label="$2"
  local wav="/tmp/oai_test_${model//[^a-zA-Z0-9]/_}.wav"
  make_silent_wav "$wav"
  printf "%-25s [%s] " "$model" "$label"
  local response http_code body
  response=$(curl -sS -w "\n%{http_code}" -X POST "https://api.openai.com/v1/audio/transcriptions" \
    -H "Authorization: Bearer $API_KEY" \
    -F "file=@$wav;type=audio/wav" \
    -F "model=$model" 2>/dev/null) || true
  http_code=$(echo "$response" | tail -n1)
  body=$(echo "$response" | sed '$d')
  rm -f "$wav"
  if [[ "$http_code" == "200" ]]; then
    echo "OK"
    ((PASS++)) || true
  else
    local err
    err=$(echo "$body" | grep -o '"message":[ ]*"[^"]*"' | head -1 | sed 's/"message":[ ]*"//;s/"$//')
    echo "FAIL HTTP $http_code ${err:0:80}"
    ((FAIL++)) || true
  fi
}

echo "=== OpenAI chat models (current enum cases, text-only) ==="
for m in "${CURRENT_CHAT_MODELS[@]}"; do test_chat_model "$m" "current"; done

echo ""
echo "=== OpenAI audio chat models (input_audio required) ==="
test_audio_chat_model() {
  local model="$1"
  local label="$2"
  local wav="/tmp/oai_audio_${model//[^a-zA-Z0-9]/_}.wav"
  make_silent_wav "$wav"
  printf "%-25s [%s] " "$model" "$label"
  local b64
  b64=$(base64 < "$wav" | tr -d '\n')
  local response http_code body
  response=$(curl -sS -w "\n%{http_code}" -X POST "https://api.openai.com/v1/chat/completions" \
    -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: application/json" \
    -d "$(printf '{"model":"%s","modalities":["text"],"messages":[{"role":"user","content":[{"type":"input_audio","input_audio":{"data":"%s","format":"wav"}}]}],"max_completion_tokens":16}' "$model" "$b64")" 2>/dev/null) || true
  http_code=$(echo "$response" | tail -n1)
  body=$(echo "$response" | sed '$d')
  rm -f "$wav"
  if [[ "$http_code" == "200" ]]; then
    echo "OK"
    ((PASS++)) || true
  else
    local err
    err=$(echo "$body" | grep -o '"message":[ ]*"[^"]*"' | head -1 | sed 's/"message":[ ]*"//;s/"$//')
    echo "FAIL HTTP $http_code ${err:0:80}"
    ((FAIL++)) || true
  fi
}
for m in "${CURRENT_AUDIO_CHAT_MODELS[@]}"; do test_audio_chat_model "$m" "current"; done

echo ""
echo "=== OpenAI legacy chat slugs (must 404 — confirms slug was retired by OpenAI) ==="
test_legacy_retired_chat_model() {
  local model="$1"
  printf "%-25s [%s] " "$model" "legacy"
  local response http_code
  response=$(curl -sS -w "\n%{http_code}" -X POST "https://api.openai.com/v1/chat/completions" \
    -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: application/json" \
    -d "$(printf '{"model":"%s","messages":[{"role":"user","content":"ping"}],"max_completion_tokens":4}' "$model")" 2>/dev/null) || true
  http_code=$(echo "$response" | tail -n1)
  if [[ "$http_code" == "404" ]]; then
    echo "OK (correctly removed by OpenAI; migrateLegacyPromptRawValue handles persisted values)"
    ((PASS++)) || true
  elif [[ "$http_code" == "200" ]]; then
    echo "UNEXPECTED 200 — OpenAI un-retired this slug; reconsider migration mapping"
    ((FAIL++)) || true
  else
    echo "UNEXPECTED HTTP $http_code — investigate"
    ((FAIL++)) || true
  fi
}
for m in "${LEGACY_CHAT_MODELS[@]}"; do test_legacy_retired_chat_model "$m"; done

echo ""
echo "=== OpenAI chat candidates (migration targets) ==="
for m in "${CANDIDATE_CHAT_MODELS[@]}"; do test_chat_model "$m" "candidate"; done

echo ""
echo "=== OpenAI transcription models ==="
for m in "${CURRENT_TRANSCRIPTION_MODELS[@]}"; do test_transcription_model "$m" "current"; done

echo "---"
echo "Passed: $PASS  Failed: $FAIL"
exit $(( FAIL > 0 ? 1 : 0 ))
