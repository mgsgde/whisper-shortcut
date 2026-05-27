# WhisperShortcut 7.32

Stability release focused on three latent bugs uncovered during a code review pass — nothing user-visible has changed when things work, but a handful of edge cases that previously failed silently now don't.

## Fixes
- **Chat with an audio-only model no longer 400s.** If you ever picked `OpenAI GPT Audio` for chat (it's a Dictate Prompt model, but the chat picker didn't guard against it), the next text message would be rejected by the API. The chat path now falls back to the default chat model for any selection that isn't text-chat-capable — matching what the rest of the app already does.
- **Stop now reliably cancels the right task.** If a Stop landed while a new dictation, prompt, or Read Aloud was already starting on top of the previous one, the `cancel()` could end up wired to the wrong task and the action would keep running in the background. The cancel-surface now identity-checks the task it's clearing.
- **Shortcut recorder cross-row safety.** Opening the recorder in one settings row, switching to another row that takes over, then closing the first row's tab could leave the second recorder's cancel handle nilled out — two NSEvent monitors would end up live and the next keystroke would write into both bindings. Fixed by only clearing the registry slot if the closing row was actually the active recorder.

## Behind the scenes
- Dropped four dead `ShortcutConfig` fields (`stopRecording`, `stopPrompting`, `toggleMeeting`, `stopMeeting`) — leftovers from a pre-toggle design that nothing actually read.
- Deduplicated the three places that loaded the chat model from `UserDefaults` with migration into a single helper.
- `/review-code` now accepts an iteration count (`/review-code 3`) for running multiple review/fix passes in one go — LLM-context tooling only, no user-facing effect.

## Installation
Download the latest `.dmg` from [Releases](https://github.com/mgsgde/whisper-shortcut/releases).

## Full changelog

[Compare v7.31…v7.32](https://github.com/mgsgde/whisper-shortcut/compare/v7.31...v7.32)
