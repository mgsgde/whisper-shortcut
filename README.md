# WhisperShortcut

**Speech-to-Text**, **Voice-to-Prompt**, and **Gemini Chat** for macOS with **Google Gemini** and **Offline Whisper** support

📺 **[Watch Demo Video](https://youtu.be/ZaD2iSZ0Y2M)**

## Download & Support

**[Download for FREE via GitHub Releases](https://github.com/mgsgde/whisper-shortcut/releases)**

### Support the Project

WhisperShortcut is open source and free to use. If you want to support the development, you can purchase and review the app on the App Store:

**[Buy on Mac App Store](https://apps.apple.com/us/app/whispershortcut/id6749648401)**

## How it works

### Transcription Mode (Speech-to-Text)

Choose between **cloud** (Google Gemini) or **offline** (Whisper) transcription:

1. **Setup** - For cloud transcription: Configure your Gemini API key [here](https://aistudio.google.com/app/apikey). For offline transcription: Download a Whisper model in Settings (no API key needed).
2. **Press Shortcut** - Start recording with a keyboard shortcut
3. **Transcribe** - Uses your selected model (Gemini or Whisper) for accurate speech-to-text
4. **Copy to Clipboard** - Automatically copies transcription to your clipboard

**Advanced Features:**

- **Chunked Transcription**: Long recordings are automatically split into chunks and processed in parallel for better performance
- **Real-time Progress**: See the status of each chunk as it's being processed

### Prompt Mode (Voice-to-Prompt)

Speak instructions that apply to selected clipboard text:

1. **Select Text** - Copy text you want to modify to your clipboard
2. **Press Shortcut** - Start recording your voice instruction
3. **Process** - Gemini processes both your voice instruction and the selected text
4. **Get Result** - Modified text is automatically copied to your clipboard

### Read Aloud Mode (Text-to-Speech)

Read selected text aloud using AI-powered voices:

1. **Select Text** - Copy text you want to hear to your clipboard
2. **Press Shortcut** - Start the read aloud process
3. **Listen** - Selected text is read aloud using your chosen voice

### Prompt & Read Mode

Combine AI prompting with text-to-speech in one workflow:

1. **Select Text** - Copy text you want to modify to your clipboard
2. **Press Shortcut** - Start recording your voice instruction
3. **Process & Read** - Gemini processes your voice instruction and selected text, then reads the result aloud automatically

### Gemini Chat

A dedicated chat window for multi-turn conversations with Gemini (separate from voice dictation):

1. **Open** - Choose **Open Gemini** from the menu bar (you can set a keyboard shortcut in Settings)
2. **Chat** - Type messages, use multiple tabs for separate threads, and pick the model in Settings (Open Gemini tab) or with slash commands such as `/model`
3. **Images** - Attach images from the input area, or use **Gemini → Capture Screenshot** (e.g. **⇧⌘S**) to send a screen capture to the model
4. **Tools** - The model can use controlled helpers: read or write the clipboard, and open `http`/`https` links in your default browser

Requires a Gemini API key (Settings → General). Chats are persisted on your Mac so you can pick up where you left off.

### Live Meeting Transcription

Real-time meeting transcription inside the app (e.g. for calls or meetings):

1. **Open Meeting** - From the menu bar, choose **Open Meeting** (or use its shortcut)
2. **New Meeting** - In the Meeting window, click **New Meeting** to start recording (requires a Gemini API key). The transcript appears in the Meeting view as chunks complete
3. **Streaming** - Audio is recorded in timed segments (default interval configurable in **Settings → Live Meeting**), each segment is transcribed with Gemini, and text is appended in the UI
4. **Save & library** - Transcripts are saved as text files under the app’s Application Support folder (meeting library). Use **Open Meeting** in the toolbar to browse past meetings when no live session is running
5. **Optional timestamps** - Enable `[MM:SS]` markers in **Settings → Live Meeting**
6. **End Meeting** - Click **End Meeting**, optionally name the file, or discard the transcript from the same flow

You can keep the Meeting window visible alongside other apps while you work.

### Smart Improvement

You can improve your system prompts and user context in two ways:

1. **Improve from usage** – **Save usage data** is on by default; the app stores interaction logs (what you dictated, which mode you used). When you have enough data, click **"Improve from usage"** in Settings → Smart Improvement. Gemini (model selectable in Settings) analyzes your logs and suggests updates for: **User Context** (language, topics, style), **Dictation** (Speech-to-Text system prompt), **Dictate Prompt** system prompt, and **Prompt & Read** system prompt. Suggestions are applied automatically; a popup tells you what was improved. Check the relevant settings tabs to review or edit.
2. **Improve from voice** – Use the **Improve from voice** shortcut (e.g. Cmd+6). Record a voice instruction (e.g. "always add bullet points", "I work in legal"); the app transcribes it and updates system prompts accordingly. No interaction logs required.
3. **Automatic Improve from usage** (optional) – In the same Smart Improvement section, set **Run Improve from usage automatically** to an interval (or Off). When enabled, the app can run **Improve from usage** in the background on that schedule while the app is open.

**Settings** (Settings → Smart Improvement): **Save usage data** (on by default), **Run Improve from usage automatically**, **model** (default: Gemini 3 Flash), and the **Improve from voice** shortcut. The same model is used for "Generate with AI" in the prompt and user-context settings.

## Installation

### Recommended: Download App

1. Download the latest `.dmg` file from the [Releases page](https://github.com/mgsgde/whisper-shortcut/releases).
2. Open the DMG and drag `WhisperShortcut` to your Applications folder.

### Build from Source

```bash
# Clone the repository
git clone https://github.com/mgsgde/whisper-shortcut.git
cd whisper-shortcut

# Install the app
bash install.sh
```

## Features

- **Speech-to-Text Transcription**: Audio → Text transcription using Google Gemini (cloud) or Whisper (offline)
  - **Chunked Transcription**: Automatic parallel processing of long recordings for improved performance
  - **Real-time Progress Tracking**: Visual status grid showing progress of each audio chunk
- **Voice-to-Prompt Mode**: Speak instructions to modify selected clipboard text using Gemini AI
- **Read Aloud Mode**: Text-to-speech functionality to read selected text aloud with AI voices
- **Prompt & Read Mode**: Combined workflow that processes text with AI and reads the result aloud
- **Gemini Chat**: Multi-tab chat window with Gemini, image attachments, screen capture to chat, slash commands (e.g. `/model`), persisted sessions, and safe local tools (clipboard read/write, open browser links)
- **Offline Support (Privacy Mode)**: Use local Whisper models for completely offline transcription
- **Smart Clipboard Integration**: Automatic copy to clipboard for transcription and prompt modes
- **Customizable Shortcuts**: Configurable keyboard shortcuts for each mode (including Open Gemini and Open Meeting)
- **Multiple TTS Models & Voices**: Choose from Gemini 2.5 Flash/Pro TTS models and 10 AI voices (e.g. Charon, Puck, Kore)
- **Live Meeting Transcription**: Real-time transcription in the Meeting window; transcripts saved for the meeting library; configurable chunk interval and optional timestamps
- **Smart Improvement**: System prompt and user context improvements via "Improve from usage" (with optional automatic scheduling), "Improve from voice" shortcut, or manual review in settings; suggestions applied automatically when you run improvement

## Development

### Prerequisites

- macOS 15.5+
- Xcode 16.0+
- Gemini API key (required for cloud transcription, prompt workflows, Gemini Chat, and Live Meeting; optional for offline Whisper-only transcription)

## License

MIT License - see [LICENSE](LICENSE) file for details.

---

Made in Karlsruhe, Germany 🇩🇪
