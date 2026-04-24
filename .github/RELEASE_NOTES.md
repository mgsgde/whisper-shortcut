# WhisperShortcut 7.0.0

## Installation

Download the latest build from [Releases](https://github.com/mgsgde/whisper-shortcut/releases).

## Changes

### Chat and live meeting

- **Unified window**: Live meeting is merged into the main Chat experience; meeting sessions show an indicator in the sidebar, and redundant meeting-only window code was removed.
- **Silence detection**: Shared silence-based behavior for Dictate and live meeting recording; Dictate gains silence detection and a meeting control in the composer toolbar.
- **Reliability**: Fixes across live meeting and chat flows (including streaming, tool responses, and ordering).

### Google account and Gemini tools

- **Calendar**: Gemini can use Google Calendar via chat tools; `/connect-calendar` and `/disconnect-calendar` slash commands; calendar event deletion support and improved API logging.
- **Tasks**: Google Tasks integration with support for multiple lists, task deletion tool, and clearer disambiguation between calendar and tasks tools.
- **Gmail**: Read-only Gmail integration in chat.
- **Fixes**: URL-encoding for IDs, Gmail error logging, OAuth type renames, `delete_event` in system instruction, and Gemini request-shape fixes (`call_id` / `callId` handling).

### Settings and product naming

- **Settings layout**: Context settings tab removed; per-mode prompt editors added; default open-settings shortcut is now ⌘3 (was ⌘7).
- **Naming**: “Open Gemini” is now **Chat**; “Prompt Mode” is now **Dictate Prompt**; Google Calendar connection copy is aligned with **Google Account** where appropriate.
- **Removed**: Prompt Read Mode (`promptAndRead`), Chat Read Aloud, and legacy TTS selection UI; legacy Gemini 2.0 models migrated toward Gemini 3.1 Flash Lite.

### Chat quality of life

- Pin replaces archive; delete older chats; improved AI-generated titles; fixes for `<typed_by_user>` leaking into titles; better text selection in replies.

### Other

- CI: Dependabot Swift discovery fix; removed npm config for a non-existent website path.

## Full changelog

[Compare v6.12.0…v7.0.0](https://github.com/mgsgde/whisper-shortcut/compare/v6.12.0...v7.0.0)
