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
  # xAI's flagship. Added to PromptModel 2026-07-22 — it does NOT replace grok-4.3 (pricier,
  # 500k context vs 1M), both sit on the price/quality frontier.
  "grok-4.5"
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

# --- Audio paths -------------------------------------------------------------
# These are NOT chat completions and do NOT appear in GET /v1/models, so the loops above can
# never cover them. Both ship: TranscriptionModel.xaiTranscribe and TTSModel.grokVoiceTTS.
# Each request below mirrors the app's real body — see SpeechService.transcribeWithXAI /
# synthesizeXAITTS. In particular the TTS check sends NO `model` field, exactly like the app;
# adding one is what makes this test lie (the `grok-voice-tts-1.0` slug 404s upstream).

test_stt() {
  printf "%-35s [%s] " "grok-stt" "current"
  local wav response http_code body
  wav=$(mktemp -t grokstt).wav
  # 1 s of silence, 16 kHz mono s16le — enough to prove the endpoint accepts our multipart shape.
  python3 - "$wav" <<'PY' 2>/dev/null
import struct, sys, wave
w = wave.open(sys.argv[1], "wb"); w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000)
w.writeframes(struct.pack("<" + "h" * 16000, *([0] * 16000))); w.close()
PY
  response=$(curl -sS -w "\n%{http_code}" -X POST "https://api.x.ai/v1/stt" \
    -H "Authorization: Bearer $API_KEY" \
    -F model=grok-stt -F language=en -F format=json -F "file=@$wav" 2>/dev/null) || true
  http_code=$(echo "$response" | tail -n1)
  body=$(echo "$response" | sed '$d')
  rm -f "$wav"
  if [[ "$http_code" == "200" ]]; then
    # Silence must transcribe to an empty string. A non-empty transcript here is a hallucination
    # signal worth investigating, not a pass.
    if echo "$body" | grep -q '"text":[ ]*""'; then
      echo "OK (silence → empty, no hallucination)"
    else
      echo "OK (WARN: silence produced text — ${body:0:60})"
    fi
    ((PASS++)) || true
  else
    echo "FAIL HTTP $http_code ${body:0:80}"
    ((FAIL++)) || true
  fi
}

test_tts() {
  local voice="$1"
  printf "%-35s [%s] " "tts voice_id=$voice" "current"
  local out http_code size
  out=$(mktemp -t groktts)
  http_code=$(curl -sS -o "$out" -w "%{http_code}" -X POST "https://api.x.ai/v1/tts" \
    -H "Authorization: Bearer $API_KEY" -H "Content-Type: application/json" \
    -d "$(printf '{"text":"OK","voice_id":"%s","language":"auto","output_format":{"codec":"pcm","sample_rate":24000}}' "$voice")" 2>/dev/null) || true
  size=$(wc -c < "$out" | tr -d ' ')
  rm -f "$out"
  if [[ "$http_code" == "200" && "$size" -gt 1000 ]]; then
    echo "OK (${size} bytes PCM)"
    ((PASS++)) || true
  else
    echo "FAIL HTTP $http_code (${size} bytes)"
    ((FAIL++)) || true
  fi
}

echo ""
echo "=== Grok speech-to-text (/v1/stt — TranscriptionModel.xaiTranscribe) ==="
test_stt

echo ""
echo "=== Grok text-to-speech (/v1/tts — TTSModel.grokVoiceTTS, all shipped voices) ==="
# Must match TTSVoice.xaiVoices in SettingsConfiguration.swift.
for v in eve ara rex sal leo; do test_tts "$v"; done

echo "---"
echo "Passed: $PASS  Failed: $FAIL"
exit $(( FAIL > 0 ? 1 : 0 ))
