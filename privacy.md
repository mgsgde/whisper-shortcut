# Privacy Policy for WhisperShortcut

**Last updated:** February 21, 2025

## Overview

WhisperShortcut is a macOS menu bar application with four main features: **Speech-to-Text** (transcription), **Speech-to-Prompt** (AI text modification via voice), **Read Aloud** (text-to-speech), and **Prompt & Read** (combined AI + TTS). This privacy policy explains how we handle your data and what information is collected, stored, or transmitted.

## Data Collection Summary

**WhisperShortcut collects minimal data and prioritizes your privacy:**

- ✅ **No personal information collected**
- ✅ **No analytics or tracking**
- ✅ **No crash reporting**
- ✅ **No data sold to third parties**
- ✅ **All data stored locally on your device**
- ✅ **Offline option**: Speech-to-Text can use local Whisper models without sending data to any server

## What Data We Collect

### 1. API Key (Required for Cloud Features)

- **What**: Your Google API key
- **Where**: Stored securely in macOS Keychain
- **Purpose**: Required for Google Gemini (transcription, AI prompting, TTS). Not needed when using offline Whisper for Speech-to-Text
- **Retention**: Stored locally until you delete it
- **Access**: Only accessible by the app on your device

### 2. App Preferences

- **What**: Keyboard shortcuts, model selections, auto-paste toggle, TTS voice, and other settings
- **Where**: Stored locally in macOS UserDefaults
- **Purpose**: To remember your preferred configuration
- **Retention**: Stored locally until you reset to defaults
- **Access**: Only accessible by the app on your device

### 3. Temporary Audio Files

- **What**: Audio recordings during transcription or prompting
- **Where**: Stored temporarily in app's document directory
- **Purpose**: Required for transcription and AI processing
- **Retention**: Automatically deleted after processing
- **Access**: Only accessible by the app on your device

### 4. Live Meeting Transcripts (Optional)

- **What**: Transcript files from Live Meeting mode
- **Where**: Saved in the app data folder under `Meetings/` (e.g. `Meeting-YYYY-MM-DD-HHmmss.txt`). The app uses the path `~/Library/Containers/com.magnusgoedde.whispershortcut/Data/Library/Application Support/WhisperShortcut/Meetings/`. Older versions may have saved to `~/Documents/WhisperShortcut/`.
- **Purpose**: Persistent record of live meeting transcription
- **Retention**: Stored until you delete the files manually
- **Access**: Only you can access these files on your device

### 5. User Context / Interaction Logs

- **What**: Logs of transcriptions, prompt interactions, and read-aloud actions (mode, timestamps, and result snippets). When automatic system prompt improvement applies a new prompt, a history entry (timestamp, source, lengths, and the applied prompt text) is appended to `system-prompt-history-dictation.jsonl`, `system-prompt-history-prompt-mode.jsonl`, or `system-prompt-history-prompt-and-read.jsonl` in the same folder so you can review how prompts changed over time. When you apply suggested user context, a similar history entry is appended to `user-context-history.jsonl` so you can review how your user context (user-context.md) evolved.
- **Where**: Stored locally in the app data folder under `UserContext/` as JSONL files (e.g. `interactions-YYYY-MM-DD.jsonl`, and optionally `system-prompt-history-*.jsonl`, `user-context-history.jsonl`). The app uses the path `~/Library/Containers/com.magnusgoedde.whispershortcut/Data/Library/Application Support/WhisperShortcut/UserContext/`. See `docs/data-directories.md` in the repository for details.
- **Purpose**: Used when you click **"Generate with AI"** in Settings to derive suggested system prompts and user context, or for **automatic system prompt improvement** (if enabled). Improves quality of those suggestions. System prompt history files let you manually review how your Dictation, Dictate Prompt, and Prompt & Read prompts evolved; user context history records how user-context.md changed when you applied suggestions.
- **When it’s collected**: Interaction logging is always on (no toggle). Data stays on your device until you delete it or it is automatically removed (see retention)
- **Retention**: Log files older than **90 days** are automatically deleted. For **"Generate with AI"** and automatic improvement, only interactions from the **last 30 days** are read and sent to Google Gemini.
- **Gemini Analysis**: 
  - **Manual**: When you click **"Generate with AI"** (in Settings > General for User Context, or in the Dictate / Dictate Prompt / Dictate Prompt & Read tabs), aggregated interaction data from the last 30 days is sent to Google Gemini to generate suggested prompts. This is a one-time action per click; you initiate it manually.
  - **Automatic**: If automatic improvement is enabled (Settings > General > Smart Improvement), the app periodically (configurable: every 3, 7, 14, or 30 days, or "Always"/"Never") analyzes your interaction logs in the background and generates suggested prompts. Aggregated interaction data from the last 30 days is sent to Google Gemini. A pop-up appears when suggestions are ready, allowing you to review and accept or reject them. You can disable automatic improvement at any time by setting the interval to "Never" (this also disables interaction logging).
- **Deletion**: You can delete all interaction logs and derived files at any time via **Settings > General > Data & Reset > Delete interaction data**, or by removing the `UserContext` folder in the app data path (e.g. in Finder: Go → Go to Folder, paste the path from Settings or from `docs/data-directories.md`, then delete the `UserContext` folder).
- **Access**: Only accessible by the app on your device, except when you use "Generate with AI" or when automatic improvement runs, at which point the aggregated text is sent to Gemini as described above.

## What Data We Do NOT Collect

- ❌ Personal information (name, email, address)
- ❌ Usage analytics or tracking data
- ❌ Crash reports or diagnostic information
- ❌ Audio recordings (beyond temporary processing)
- ❌ Transcription text content (we do not store or transmit it beyond what's needed for the feature)
- ❌ Clipboard content (beyond temporary use during Speech-to-Prompt / Prompt & Read)

## Third-Party Services

### Google Gemini API

WhisperShortcut uses Google's Gemini API for:

- **Speech-to-Text (cloud mode)**: Audio → transcribed text
- **Speech-to-Prompt**: Audio + clipboard text → modified text (clipboard content is sent to apply your voice instruction)
- **Read Aloud / TTS**: Text → synthesized speech
- **Prompt & Read**: Same as Speech-to-Prompt, plus TTS for the result
- **Live Meeting**: Continuous audio chunks → transcribed text

- **Data Sent**: Audio files and/or text (depending on feature)
- **Data Received**: Transcribed text, AI-modified text, or audio
- **Privacy**: Subject to [Google's Privacy Policy](https://policies.google.com/privacy)
- **Retention**: Google may retain data according to their policy

**Note**: When you use cloud features, your audio and/or text may be sent to Google's servers. For offline Speech-to-Text with Whisper, no data leaves your device.

## Data Storage and Security

### Local Storage

- All app data is stored locally on your macOS device
- API keys are encrypted in macOS Keychain
- No data is transmitted to our servers

### Audio Processing

- Audio is recorded locally in WAV format (24kHz, mono)
- Files are automatically deleted after processing
- No audio files are permanently stored

### Clipboard Management

- **Copy**: Transcriptions and AI responses are copied to your system clipboard
- **Read**: Speech-to-Prompt and Prompt & Read read clipboard/selected text only when you use those features; it is sent to Gemini to apply your voice instruction
- Clipboard data is not stored by the app; it remains under your control

## Your Rights and Controls

### Data Access

- All data is stored locally on your device
- You can access and modify preferences through the app settings
- You can delete your API key through the app settings

### Data Deletion

- Delete API key: Use the app's settings to remove your API key
- Reset preferences: Use the app's reset to defaults feature
- Delete Live Meeting transcripts: Remove files from the app data folder under `Meetings/` (path shown in Settings > General, or see `docs/data-directories.md`). Legacy files may be in `~/Documents/WhisperShortcut/`.
- Delete User Context / interaction logs: Use **Settings > General > Data & Reset > Delete interaction data**, or remove the `UserContext` folder in the app data path (see path in Settings or `docs/data-directories.md`).
- Disable automatic improvement and interaction logging: Settings > General > Smart Improvement > set interval to "Never".
- Uninstall: Remove the app to delete all local data (except the app data folder contents such as Meetings and UserContext, which you can delete manually or via Settings before uninstalling).

### Permissions

- **Microphone**: Required for recording. You can revoke access in macOS System Settings → Privacy & Security → Microphone.
- **Accessibility**: Required for Speech-to-Prompt, Prompt & Read, Read Aloud (selected text capture), and auto-paste. You can revoke in System Settings → Privacy & Security → Accessibility.

## Children's Privacy

WhisperShortcut does not knowingly collect personal information from children under 13. The app is designed for general use and does not target children specifically.

## Changes to This Policy

We may update this privacy policy from time to time. We will notify users of any material changes by:

- Updating the "Last updated" date
- Posting the new policy in the app repository
- Including a summary of changes

## Contact Information

If you have questions about this privacy policy or our data practices, please contact us through the GitHub repository: [https://github.com/mgsgde/whisper-shortcut](https://github.com/mgsgde/whisper-shortcut)

## Legal Basis

This privacy policy is provided to comply with:

- Apple App Store requirements
- General Data Protection Regulation (GDPR) principles
- California Consumer Privacy Act (CCPA) requirements
- Other applicable privacy laws and regulations

---

**WhisperShortcut is committed to protecting your privacy and ensuring transparency about our data practices.**
