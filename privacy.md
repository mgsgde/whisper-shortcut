# Privacy Policy for WhisperShortcut

**Last updated:** May 12, 2026

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
- **OpenAI API key**: Optional. Used for OpenAI Transcribe, OpenAI Dictate Prompt, and OpenAI chat models. Stored in macOS Keychain until you delete it.
- **xAI API key**: Optional. Used only for Grok chat models. Stored in macOS Keychain until you delete it.
- **Google OAuth refresh token**: Optional. Created only if you connect a Google account for Calendar, Tasks, and Gmail tools. Stored in macOS Keychain until you disconnect Google.
- **Trello API key and token**: Optional. Created only if you connect Trello for board, list, and card tools. Stored in macOS Keychain until you delete the API key or disconnect Trello.

### App Preferences

WhisperShortcut stores settings such as keyboard shortcuts, selected models, notification preferences, TTS voice, chat behavior, and feature toggles in local app storage and UserDefaults.

### Temporary Audio Files

Audio recorded for dictation, prompt workflows, TTS-related processing, or live meeting transcription is stored temporarily while processing is in progress. Temporary audio files are deleted after processing when possible.

If **Save usage data** is enabled, recent successful dictation audio may also be copied briefly into `UserContext/audio-samples/` so Smart Improvement can verify text-based dictation and glossary suggestions. These samples are capped, used only as verifier evidence, and deleted at the start of the next Smart Improvement run or when you delete interaction data.

### Chat Sessions

Chat sessions, messages, model choices, and local chat metadata are stored on your Mac so you can continue previous conversations.

### Live Meeting Transcripts

Live Meeting transcripts are saved locally under the app data folder, usually in `Meetings/`, unless you discard them.

### User Context And Interaction Logs

If **Save usage data** is enabled, WhisperShortcut stores local JSONL interaction logs under `UserContext/`. These logs may include mode names, timestamps, result snippets, prompt-related history, and optional references to short-lived dictation audio samples used to improve system prompts, user context, and dictation glossary suggestions.

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

### OpenAI API

When you choose OpenAI models, WhisperShortcut sends the minimum needed audio, text, images, chat messages, tool results, or prompt context to OpenAI using your OpenAI API key. This may include:

- Dictation audio for OpenAI Transcribe.
- Clipboard text and voice instructions for OpenAI Dictate Prompt.
- Chat messages, screenshots, image attachments, and tool results for OpenAI chat.
- Optional hosted web search requests when enabled for supported OpenAI chat models.

OpenAI models are used only when selected. OpenAI's processing and retention are governed by OpenAI's policies and API terms.

### xAI Grok API

If you choose a Grok chat model, WhisperShortcut sends chat messages and relevant chat context to xAI using your xAI API key. Grok models are used only when selected.

### Self-Hosted Transcription Endpoint

If you configure the Self-hosted Transcription Endpoint, WhisperShortcut sends dictation audio directly from your Mac to the endpoint URL you provide. This feature is intended for user-controlled or self-hosted OpenAI-compatible `/v1/audio/transcriptions` services. You are responsible for the endpoint, credentials, logs, storage, and retention behavior of that service.

### Google Account Integrations

If you connect a Google account, WhisperShortcut can use Google Calendar, Google Tasks, and Gmail APIs when you ask the chat to perform those actions. The app requests only the scopes needed for those tools.

- Calendar tools can list and create calendar events.
- Tasks tools can list, create, complete, and delete tasks.
- Gmail tools are read-only and can search/read messages so the assistant can answer your email-related requests.

Google OAuth tokens are stored in Keychain. You can disconnect Google in Settings or with the `/disconnect-google` chat command.

### Trello Integration

If you connect Trello, WhisperShortcut can use Trello's API when you ask chat to work with boards, lists, and cards. The app can list boards, lists, and cards; create cards; update card name, description, or due date; move cards between lists; and archive cards.

Trello uses a manual token flow. Your Trello Power-Up API key and user token are stored in Keychain. You can disconnect Trello in Settings or with the `/disconnect-trello` chat command. Trello's processing and retention are governed by Atlassian/Trello policies and terms.

## What We Do Not Collect

- Personal information for analytics or tracking.
- Usage analytics.
- Crash reports operated by us.
- Audio recordings beyond temporary processing and the short-lived Smart Improvement verification samples described above.
- Clipboard content except when needed for a user-triggered feature.
- Email, calendar, task, Trello board, list, or card data except when you explicitly use connected tools.

## Data Protection Mechanisms For Sensitive Data

We apply the following safeguards to sensitive data, including API keys, OAuth tokens, Trello tokens, and Google Workspace data accessed through user-authorized scopes (Calendar, Tasks, Gmail):

- **Encryption in transit:** All communication with Google APIs (Gemini, Calendar, Tasks, Gmail), OpenAI APIs, xAI APIs, and Trello APIs uses HTTPS with TLS 1.2 or higher. App Transport Security is enforced (`NSAllowsArbitraryLoads = false`), so the app does not accept insecure or downgraded connections for built-in cloud endpoints.
- **Credential protection at rest:** Google API keys, OpenAI API keys, xAI API keys, Google OAuth access and refresh tokens, Trello API keys, and Trello user tokens are stored exclusively in the **macOS Keychain**, which provides OS-level encryption and per-app access controls. They are never written to plain configuration files, logs, or any backend.
- **Local data isolation:** App files (chat sessions, live meeting transcripts, interaction logs, preferences) are stored inside the app's macOS user container at `~/Library/Containers/com.magnusgoedde.whispershortcut/Data/Library/Application Support/WhisperShortcut/` and are protected by macOS user account and file permission controls.
- **Least-privilege access:** WhisperShortcut requests only the minimum OAuth scopes required for the features you enable: `calendar.events`, `tasks`, and `gmail.readonly`. No additional scopes are requested in the background.
- **User-controlled access and revocation:** You can disconnect your Google account at any time from in-app Settings or with the `/disconnect-google` chat command, which deletes the locally stored OAuth tokens. You can additionally revoke the app's access at any time in your [Google Account permissions](https://myaccount.google.com/permissions).
- **User-controlled Trello revocation:** You can disconnect Trello at any time from in-app Settings or with the `/disconnect-trello` chat command. You can also revoke the token in Trello/Atlassian account settings.
- **Retention and deletion controls:** Temporary audio files are deleted after processing. Smart Improvement audio verification samples are capped and deleted at the start of the next Smart Improvement run or when interaction data is deleted. Interaction logs older than 90 days are deleted automatically; only the last 30 days are read for Smart Improvement features. You can delete API keys, chat sessions, meeting transcripts, and interaction data at any time from in-app Settings.
- **No server-side storage by WhisperShortcut:** WhisperShortcut does not operate a backend that receives, stores, or processes user content, API keys, or OAuth tokens. All credentials and user data remain on your device or are sent directly from your device to the third-party API provider you configured.
- **No sale of personal data:** We do not sell, rent, or trade personal data to third parties.
- **AI/ML training disclosure for Workspace APIs:** Data accessed from Google Workspace APIs (Calendar, Tasks, Gmail) through this app is used solely to provide the user-requested feature in that session and is **not used by WhisperShortcut to develop, improve, or train generalized AI/ML models**. Workspace data is not shared with third parties for AI/ML training. When such data is included in a request to a configured cloud AI provider (e.g. Google Gemini using your own API key) to produce the response you asked for, that provider's own terms and policies apply to its handling.

## Your Controls

- Remove API keys in Settings.
- Disconnect Google in Settings or with `/disconnect-google`.
- Disconnect Trello in Settings or with `/disconnect-trello`.
- Disable **Save usage data** in Smart Improvement settings.
- Delete interaction data from Settings.
- Delete meeting transcripts from the `Meetings/` folder.
- Revoke microphone or accessibility permissions in macOS System Settings.
- Delete the app data folder manually if you want to remove local files after uninstalling.

## Permissions

- **Microphone**: Required for recording audio.
- **Accessibility**: Required for selected-text capture, auto-paste, and workflows that interact with the active app.
- **Keychain**: Used to store API keys, OAuth tokens, and Trello tokens.

## Children's Privacy

WhisperShortcut does not knowingly collect personal information from children under 13. The app is designed for general use and does not target children specifically.

## Changes To This Policy

We may update this policy from time to time by updating the date and publishing the new version in this repository.

## Contact

For questions about this privacy policy or data practices, use the GitHub repository: [https://github.com/mgsgde/whisper-shortcut](https://github.com/mgsgde/whisper-shortcut).
