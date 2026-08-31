# Meeting post-pass with speaker separation (gemini-3.5-transcribe)

Status: **backlog, not scheduled.** Measured 2026-08-27, worth building, deliberately not built yet.

## What this is not

Not a new entry in the dictation model picker. `gemini-3.5-transcribe` is dominated there and must
stay out: measured against the standard fixtures it needs a flat ~2.7 s per request regardless of
audio length (1.3 s / 8.2 s / 21.3 s audio all land between 2.57 s and 3.04 s median), where
`gpt-transcribe` returns in 0.9–1.5 s and `gemini-3.1-flash-lite` in 0.9–1.4 s. Glossary accuracy is
a tie with `gpt-transcribe` (4/4, 5/5, 3/3). Silence behaviour is clean (0/9 invented transcripts,
same as `gpt-transcribe`, against 9/9 for `gemini-3.1-flash-lite`). So: same output, slower. The
model-audit rule against offering dominated models applies.

## What is actually new

Speaker diarization, which this app cannot do with any model today.

Measured on a 21 s two-voice fixture, `diarization_mode: "speaker"` with word timestamps returned
all four speaker turns correctly:

```
spk:0 [0s      – 5s     ]  … first speaker, question
spk:1 [5s      – 11.400s]  … second speaker, answer
spk:0 [11.800s – 14.400s]  … first speaker, follow-up
spk:1 [14.500s – 20.700s]  … second speaker, answer
```

Second new thing: `mode: "smart"` resolves *self-corrections*, not just fillers. A spoken "she spends
about two days a week on it, no wait, more like a day and a half" comes back as "she spends about a
day and a half a week on it". No other model in the benchmark does this. That is the difference
between a raw transcript and a usable meeting note.

Latency, the reason it loses at dictation, costs nothing here: meeting chunks are transcribed
asynchronously while the transcript grows.

## The constraint that decides the design

**Diarization does not survive our chunk boundaries.** `LiveMeetingRecorder` rotates a chunk after
`liveMeetingChunkMinDuration` (10 s) on `liveMeetingSilenceDuration` (1.5 s) of silence. Each request
gets its own `spk:0` / `spk:1` with no identity across requests, so `spk:0` in minute 1 is not
`spk:0` in minute 12. Feeding chunks through diarization would produce labels that are confidently
wrong — worse than no labels.

So the shape is **not** a model swap on the existing chunk path:

1. Live path stays exactly as it is (chunked, whichever model the user picked). The user keeps
   seeing the transcript build up during the meeting.
2. On stop, run **one** additional pass over the whole recording with
   `mode: verbatim` + `diarization_mode: speaker` (or `smart` without diarization, see below) and
   replace the assembled transcript with the diarized version.
3. Surface it as a completed-meeting artifact, not as a live feature.

## API facts to build against (probed 2026-08-27, not from docs alone)

- Endpoint is **`POST /v1beta/interactions`**, not `:generateContent`. Called through
  `:generateContent` the model returns HTTP 200 with an empty part — it fails silently, which is why
  this cannot reuse the existing Gemini transcription path.
- `thinkingConfig` → HTTP 400 "Thinking level is not supported for this model".
  `systemInstruction` → HTTP 400 "Developer instruction is not enabled for this model". The whole
  `GeminiTranscriptionGenerationConfig` shape does not apply.
- Inline audio works: `input: [{type: "audio", data: <base64>, mime_type: "audio/wav"}]`. The
  parameter is `data`; `bytes` and `inline_data` are both rejected as unknown parameters.
- Config nests as `generation_config.transcription_config` with `mode`, `language_codes`,
  `custom_vocabulary` (up to 1000 phrases — the Glossary maps straight onto this).
- **`smart` and diarization are mutually exclusive.** Smart mode cannot be combined with timestamps
  or diarization, so step 2 above is a choice, not both. Decide before building; "who said it" and
  "cleaned up" cannot come from the same call.
- Unary limits: 1 h of audio, dropping to 30 min once diarization or word timestamps are on. Long
  meetings need a fallback.
- `gemini-3.5-transcribe-live` is **not** an option for this: it exposes only `bidiGenerateContent`,
  i.e. the WebSocket Live API. This repo contains no WebSocket client at all — the live-meeting path
  is HTTP chunking. That would be a new transport layer, not a feature.
- Price is not a factor at single-user volume: ~$0.005/min against ~$0.0008/min for
  `gemini-3.1-flash-lite` and ~$0.006/min for `gpt-transcribe`.

## Open questions before this becomes a plan

1. Diarized-verbatim or smart-cleaned? They cannot be combined. A meeting note probably wants
   speakers more than it wants tidied prose, but that is an assumption, not a measurement.
2. Two passes (one diarized, one smart) doubles the cost and gives two transcripts to reconcile.
   Probably not worth it — needs deciding, not assuming.
3. Speaker labels are `spk:0` / `spk:1`. Mapping them to names is a separate problem and should not
   be smuggled into this one.
4. What happens to a meeting longer than 30 minutes. Chunked diarization is ruled out above, so this
   needs its own answer.

## Fixture warning for whoever measures this next

`say -v Reed` and `say -v Rocko` resolve to the **English** voices, which read German text as
gibberish. An early two-speaker run looked like the model was dropping the second speaker entirely;
it was not — `gpt-transcribe` turned the same file into "Our office is well funded". Quote the full
name for a German second voice: `say -v "Reed (German (Germany))"`.
