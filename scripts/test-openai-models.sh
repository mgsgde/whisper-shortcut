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
  "gpt-5.4"
  "gpt-5.4-mini"
  "gpt-5.5"
  # GPT-5.6 family, added to PromptModel 2026-07-22. sol/terra are priced identically to
  # gpt-5.5 / gpt-5.4, which is why those two are now hidden from chat (chatReplacement).
  "gpt-5.6-sol"
  "gpt-5.6-terra"
  "gpt-5.6-luna"
)
# gpt-audio (renamed from gpt-4o-audio-preview) requires audio modality — tested separately below.
declare -a CURRENT_AUDIO_CHAT_MODELS=(
  # Promoted from candidate 2026-08-02: OpenAI deprecated `gpt-audio` (shutdown 2027-01-20) and
  # names 1.5 as the replacement, at identical pricing.
  "gpt-audio-1.5"
)
# Legacy slugs we accept via migrateLegacyPromptRawValue but no longer use in fresh selections.
# Expected behaviour: 404 (model removed). Surfaces upstream renames if a slug suddenly returns 200.
declare -a LEGACY_CHAT_MODELS=(
  "gpt-4o-audio-preview"
  # Retired by OpenAI 2026-07-23; replacement gpt-5.6-sol. Kept here so the suite proves the
  # retirement rather than exiting non-zero on a stale `candidate` entry.
  "gpt-5-chat-latest"
)
declare -a CANDIDATE_CHAT_MODELS=(
  "chat-latest"
  # gpt-5.4 / gpt-5.4-mini were promoted to CURRENT_CHAT_MODELS (2026-07-14 migration: the app's
  # OpenAI flagship + mini now point at these). The superseded gpt-5 / gpt-5-mini still serve but
  # are no longer referenced — persisted selections forward via migrateLegacyPromptRawValue.
  # gpt-5.6 family promoted to CURRENT_CHAT_MODELS on 2026-07-22 (the 401 staged-rollout gating
  # seen on 2026-07-14 is gone: 10/10 consecutive 200s each). "gpt-5.6" is an alias for -sol.
  # gpt-5.5-pro intentionally NOT listed: 404s on this key (10/10, 2026-07-22) — not entitled.
)
# Audio-chat candidates (input_audio) — newer generations of gpt-audio.
# gpt-audio-1.5 graduated to CURRENT_AUDIO_CHAT_MODELS on 2026-08-02: OpenAI deprecated
# `gpt-audio` and the probe now sends real speech, which was the condition this note asked for.
declare -a CANDIDATE_AUDIO_CHAT_MODELS=(
  "gpt-audio-mini"
)
declare -a CURRENT_TRANSCRIPTION_MODELS=(
  # OpenAI's recommended starting model since the 2026 audio refresh; added to TranscriptionModel
  # 2026-08-02. Billed by duration ($0.0045/min) instead of tokens, and it takes vocabulary via
  # the `keywords` field rather than `prompt` — see sendOpenAICompatibleTranscriptionRequest.
  "gpt-transcribe"
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
# Audio-chat probe. Uses the committed speech fixture plus a text instruction rather than the
# silent WAV the other probes use: an audio-only request carrying nothing but digital silence made
# gpt-audio-1.5 return HTTP 500 "the model produced invalid content" on roughly half of attempts,
# which is a property of the stimulus, not of the model — the same model answers 3/3 with real
# speech (verified 2026-08-02). A probe that fails on a healthy model teaches the reader to ignore
# the suite, so it has to send something a real caller would send.
test_audio_chat_model() {
  local model="$1"
  local label="$2"
  local wav="$SCRIPT_DIR/../WhisperShortcutTests/sample.wav"
  printf "%-25s [%s] " "$model" "$label"
  if [[ ! -f "$wav" ]]; then
    echo "SKIP (speech fixture missing: $wav)"
    return
  fi
  local b64
  b64=$(base64 < "$wav" | tr -d '\n')
  local response http_code body
  response=$(curl -sS -w "\n%{http_code}" -X POST "https://api.openai.com/v1/chat/completions" \
    -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: application/json" \
    -d "$(printf '{"model":"%s","modalities":["text"],"messages":[{"role":"user","content":[{"type":"text","text":"Transcribe the audio. Reply with the transcript only."},{"type":"input_audio","input_audio":{"data":"%s","format":"wav"}}]}],"max_completion_tokens":64}' "$model" "$b64")" 2>/dev/null) || true
  http_code=$(echo "$response" | tail -n1)
  body=$(echo "$response" | sed '$d')
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
for m in "${CANDIDATE_AUDIO_CHAT_MODELS[@]}"; do test_audio_chat_model "$m" "candidate"; done

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
