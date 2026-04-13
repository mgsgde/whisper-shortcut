# WhisperShortcut 6.9.2

## Installation

Download the latest build from [Releases](https://github.com/mgsgde/whisper-shortcut/releases).

## Changes

- **Gemini reliability**: More resilient requests when Google’s API returns **503** or **500**—the client retries more times with appropriate backoff for transient server issues.
- **Speech-to-Prompt**: Gemini calls for prompt mode (including history and text flows) now use the same **automatic retry** path as other features, so brief outages are less likely to fail the whole action.
- **Retry from the error UI**: If you tap **Retry** after a service-unavailable style error, the app waits **3 seconds** before retrying so the service has time to recover.
- **Clearer messaging**: The “service unavailable” explanation now notes that **automatic retries already ran**, so you know what happened before trying again manually.

## Full changelog

[Compare v6.9.1…v6.9.2](https://github.com/mgsgde/whisper-shortcut/compare/v6.9.1...v6.9.2)
