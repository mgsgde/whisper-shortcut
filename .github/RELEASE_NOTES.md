# Release v6.6

## Installation

Download the latest release from [GitHub Releases](https://github.com/mgsgde/whisper-shortcut/releases).

## Changes

### New in this release

- Added persistent session memory support in Gemini Chat, including `/remember` command handling and memory-aware system instruction injection.
- Added the new WhisperShortcut App Store target and updated project/rebuild scripts to support release workflows more reliably.
- Added compile-time gating for subscription-specific code paths (`SUBSCRIPTION_ENABLED`) and aligned subscription model usage with backend-driven configuration.

### Prompt and chat quality improvements

- Improved prompt-mode screenshot context handling and refined multiple system prompts for clearer and safer AI behavior.
- Strengthened privacy guardrails and improved markdown paragraph break normalization in responses.
- Improved AI text editing and prompt clarity for more predictable output.

### Authentication, backend, and subscription flow

- Expanded Google Sign-In and backend account integrations (credential checks, subscription status checks, API URL/account settings).
- Improved Gemini credential handling across API key and signed-in flows, including clearer error messaging for voice output requirements.
- Added clearer handling for daily backend limits and top-up flows in the app UI.

### Reliability and logging

- Improved request handling and error pathways across Gemini and TTS flows.
- Added Gemini/TTS round-trip latency logging and other logging refinements.
- Removed obsolete debug logs and cleaned up unused code paths.

### Meeting and transcription improvements

- Added and refined meeting summary generation, transcript handling, and meeting window behavior (including rename/open flow improvements).
- Added transcription model selection for Live Meeting and improved markdown rendering for meeting outputs.

## Full Changelog

For a complete list of changes, see the [full changelog](https://github.com/mgsgde/whisper-shortcut/compare/v6.5...v6.6).
