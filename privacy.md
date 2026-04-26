# Privacy Policy for WhisperShortcut

**Last updated:** April 26, 2026

## Overview

WhisperShortcut is a macOS menu bar app for dictation, voice editing, AI chat, text-to-speech, live meeting transcription, and related productivity workflows. This policy explains what data is stored locally, what may be sent to third-party services when you use cloud features, and what controls you have.

WhisperShortcut is local-first and bring-your-own-key. The app has no backend service operated by us and does not sell user data.

## Data Collection Summary

WhisperShortcut is designed to minimize data collection:

- No analytics or tracking.
- No crash reporting operated by us.
- No data sold to third parties.
- App data is stored locally on your Mac.
- API keys and OAuth refresh tokens are stored in macOS Keychain.
- Offline Whisper dictation can run without sending audio to a cloud service.

## What Data Is Stored Locally

### API Keys And OAuth Tokens

- **Google Gemini API key**: Used for cloud transcription, Dictate Prompt, Chat with Gemini, TTS, Smart Improvement, and Live Meeting. Stored in macOS Keychain until you delete it.
- **xAI API key**: Optional. Used only for Grok chat models. Stored in macOS Keychain until you delete it.
- **Google OAuth refresh token**: Optional. Created only if you connect a Google account for Calendar, Tasks, and Gmail tools. Stored in macOS Keychain until you disconnect Google.

### App Preferences

WhisperShortcut stores settings such as keyboard shortcuts, selected models, notification preferences, TTS voice, chat behavior, and feature toggles in local app storage and UserDefaults.

### Temporary Audio Files

Audio recorded for dictation, prompt workflows, TTS-related processing, or live meeting transcription is stored temporarily while processing is in progress. Temporary audio files are deleted after processing when possible.

### Chat Sessions

Chat sessions, messages, model choices, and local chat metadata are stored on your Mac so you can continue previous conversations.

### Live Meeting Transcripts

Live Meeting transcripts are saved locally under the app data folder, usually in `Meetings/`, unless you discard them.

### User Context And Interaction Logs

If **Save usage data** is enabled, WhisperShortcut stores local JSONL interaction logs under `UserContext/`. These logs may include mode names, timestamps, result snippets, and prompt-related history used to improve system prompts and user context.

Interaction logs are used when you run **Generate with AI**, **Improve from usage**, or related Smart Improvement features. The app reads recent local logs, builds a summary payload, and sends that payload to Google Gemini only when you initiate or enable that improvement flow.

Log retention and cleanup are managed by the app. You can delete interaction data from Settings or by removing the `UserContext/` folder manually.

## App Data Location

WhisperShortcut uses one canonical local app data path for sandboxed and non-sandboxed builds:

```text
~/Library/Containers/com.magnusgoedde.whispershortcut/Data/Library/Application Support/WhisperShortcut/
```

See [`docs/data-directories.md`](docs/data-directories.md) for details.

Older versions may have stored some meeting files in `~/Documents/WhisperShortcut/`.

## Third-Party Services

### Google Gemini API

When you use Gemini-powered cloud features, WhisperShortcut sends the minimum needed audio, text, screenshots, image attachments, or prompt context to Google's Gemini API. This may include:

- Dictation audio for cloud transcription.
- Clipboard text and voice instructions for Dictate Prompt and Prompt & Read.
- Text for TTS audio generation.
- Chat messages, attachments, screenshots, and tool results for Gemini chat.
- Meeting audio chunks for Live Meeting transcription.
- Recent interaction summaries for Smart Improvement when you run those features.

Google's processing and retention are governed by Google's policies and the terms for the Gemini API.

### xAI Grok API

If you choose a Grok chat model, WhisperShortcut sends chat messages and relevant chat context to xAI using your xAI API key. Grok models are used only when selected.

### Google Account Integrations

If you connect a Google account, WhisperShortcut can use Google Calendar, Google Tasks, and Gmail APIs when you ask the chat to perform those actions. The app requests only the scopes needed for those tools.

- Calendar tools can list and create calendar events.
- Tasks tools can list, create, complete, and delete tasks.
- Gmail tools are read-only and can search/read messages so the assistant can answer your email-related requests.

Google OAuth tokens are stored in Keychain. You can disconnect Google in Settings or with the `/disconnect-google` chat command.

## What We Do Not Collect

- Personal information for analytics or tracking.
- Usage analytics.
- Crash reports operated by us.
- Audio recordings beyond temporary processing.
- Clipboard content except when needed for a user-triggered feature.
- Email, calendar, or task data except when you explicitly use connected Google tools.

## Data Storage And Security

- App data is local to your macOS user account.
- API keys and OAuth tokens are stored in macOS Keychain.
- WhisperShortcut does not run a server that receives your app data.
- Clipboard content remains under your control and is read only for workflows you trigger.

## Your Controls

- Remove API keys in Settings.
- Disconnect Google in Settings or with `/disconnect-google`.
- Disable **Save usage data** in Smart Improvement settings.
- Delete interaction data from Settings.
- Delete meeting transcripts from the `Meetings/` folder.
- Revoke microphone or accessibility permissions in macOS System Settings.
- Delete the app data folder manually if you want to remove local files after uninstalling.

## Permissions

- **Microphone**: Required for recording audio.
- **Accessibility**: Required for selected-text capture, auto-paste, and workflows that interact with the active app.
- **Keychain**: Used to store API keys and OAuth tokens.

## Children's Privacy

WhisperShortcut does not knowingly collect personal information from children under 13. The app is designed for general use and does not target children specifically.

## Changes To This Policy

We may update this policy from time to time by updating the date and publishing the new version in this repository.

## Contact

For questions about this privacy policy or data practices, use the GitHub repository: [https://github.com/mgsgde/whisper-shortcut](https://github.com/mgsgde/whisper-shortcut).
