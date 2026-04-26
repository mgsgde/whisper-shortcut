# WhisperShortcut

WhisperShortcut is a macOS menu bar app for voice-first productivity: dictation, voice editing, AI chat, text-to-speech, and live meeting transcription.

The app is local-first and bring-your-own-key. There is no backend or subscription service in this repository. Cloud features use your Google Gemini API key and, optionally, your xAI API key for Grok chat models.

## Download

- Download the latest signed `.dmg` from [GitHub Releases](https://github.com/mgsgde/whisper-shortcut/releases).
- The app is also available on the [Mac App Store](https://apps.apple.com/us/app/whispershortcut/id6749648401).
- Demo video: [Watch on YouTube](https://youtu.be/ZaD2iSZ0Y2M).

## Features

- **Dictate**: Record speech and copy the transcription to your clipboard. Use Gemini models online or local Whisper models offline.
- **Dictate Prompt**: Speak an instruction that edits the current clipboard text, for example "make this shorter" or "translate this to English".
- **Read Aloud**: Read clipboard text aloud with Gemini TTS voices.
- **Prompt & Read**: Edit text with a spoken instruction, then read the result aloud automatically.
- **Chat**: Use a persisted multi-session chat window with Gemini or Grok models, screenshots, image attachments, slash commands, and optional web grounding.
- **Google integrations**: Connect a Google account so chat can work with Calendar, Tasks, and Gmail through controlled local tools.
- **Live Meeting**: Record meetings in chunks, transcribe them as they complete, keep an in-app transcript, and save meeting files locally.
- **Smart Improvement**: Let the app improve system prompts and user context from usage logs or a spoken instruction.

## Requirements

- macOS 15.5 or later
- Xcode 16.0 or later for development
- Google Gemini API key for cloud transcription, prompt workflows, chat, TTS, Smart Improvement, and live meetings
- Optional xAI API key for Grok chat models
- Optional Google account connection for Calendar, Tasks, and Gmail tools

Offline Whisper dictation works without an API key after downloading a local model in Settings.

## Installation

1. Download the latest `.dmg` from [Releases](https://github.com/mgsgde/whisper-shortcut/releases).
2. Open the DMG and drag `WhisperShortcut.app` into `/Applications`.
3. Start WhisperShortcut from Applications.
4. Open Settings from the menu bar app and add your Google Gemini API key if you want cloud features.
5. Grant microphone and accessibility permissions when macOS asks.

## Common Workflows

### Dictation

1. Configure a Dictate shortcut in Settings.
2. Choose a Gemini or Whisper transcription model.
3. Press the shortcut, speak, then stop recording.
4. The transcription is copied to the clipboard, and can optionally be pasted automatically.

Long recordings are split into chunks and processed in parallel.

### Dictate Prompt

1. Copy text you want to edit.
2. Press the Dictate Prompt shortcut.
3. Speak an instruction, such as "turn this into bullet points".
4. The edited result is copied to the clipboard.

### Chat

Open the chat window from the menu bar or its configured shortcut. Chat sessions are stored locally and can use slash commands such as `/new`, `/model`, `/screenshot`, `/settings`, `/grok`, `/gemini`, `/connect-google`, `/disconnect-google`, and `/meeting`.

Gemini models use your Google API key. Grok models use your xAI API key.

### Live Meeting

Use `/meeting` in chat or the Meeting shortcut to start and stop live meeting recording. Audio is rotated into chunks, transcribed, and appended to the meeting transcript. Saved transcripts live in the app's Application Support folder.

## Build From Source

```bash
git clone https://github.com/mgsgde/whisper-shortcut.git
cd whisper-shortcut
bash install.sh
```

For development, build and restart the app with:

```bash
bash scripts/rebuild-and-restart.sh
```

Useful scripts:

- `scripts/rebuild-and-restart.sh`: Build Debug and restart the local app.
- `scripts/logs.sh`: Stream or filter app logs.
- `scripts/create-release.sh`: Create a tagged release.
- `scripts/test-gemini-models.sh`: Check configured Gemini model availability.

## Project Structure

- `WhisperShortcut/`: Swift source for the macOS app.
- `WhisperShortcut.xcodeproj/`: Xcode project and shared schemes.
- `scripts/`: Local development and release helper scripts.
- `.github/workflows/release.yml`: GitHub Actions workflow for signed, notarized release builds.
- `plans/`: Shared implementation plans and specs.

Core files:

- `AppState.swift`: Central app state machine.
- `MenuBarController.swift`: Main app orchestrator.
- `SpeechService.swift`: Dictation and prompt workflow logic.
- `ChatView.swift`: Chat UI and view model.
- `ChatTools.swift`: Local tool registry for chat integrations.
- `TranscriptionModels.swift`: Gemini and Whisper transcription model definitions.
- `Settings/`: Settings UI, defaults, and persistence.

## Data And Privacy

WhisperShortcut stores settings, chat sessions, meeting transcripts, usage logs, and downloaded models on your Mac. API keys and OAuth refresh tokens are stored in Keychain.

WhisperShortcut uses one canonical app data location so sandboxed and non-sandboxed builds see the same files:

`~/Library/Containers/com.magnusgoedde.whispershortcut/Data/Library/Application Support/WhisperShortcut/`

See [`docs/data-directories.md`](docs/data-directories.md) for details.

## License

MIT License. See [LICENSE](LICENSE) for details.
