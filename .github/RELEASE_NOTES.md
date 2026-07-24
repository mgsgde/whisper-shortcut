# WhisperShortcut 7.93

Adds **Voice Feedback** — teach the app to transcribe and write the way you want just by speaking — plus cost and accuracy tuning.

## Installation

Download the latest build from the [Releases page](https://github.com/mgsgde/whisper-shortcut/releases), move **WhisperShortcut.app** to your Applications folder, and launch it.

## What's New

### 🎓 Voice Feedback (new)

- **Correct the app by speaking.** Press the Voice Feedback shortcut (default ⌘5) and say something like *"my name is spelled G-ö-d-d-e"* or *"stop capitalizing every noun in Dictate Prompt output."* The app turns your instruction into a concrete change to the right part of your context — the transcription prompt, the Whisper glossary, Dictate Prompt, or Chat.
- **You review before anything changes.** The proposed edit is shown in a diff window; nothing is applied until you accept it, and every change is recorded so you can revert it.
- **Editable shortcut.** Configure it in Settings → Smart Improvement; it also appears in the status menu and the shortcuts overview.

### 🧠 Smarter, cheaper models

- **Lower cost by default.** Gemini models now default to 3.5 Flash-Lite, and thinking levels were tuned so background tasks stop billing unnecessary reasoning tokens.

### ✅ Accuracy & self-knowledge

- **Fewer wrong glossary learns.** The fast glossary learner no longer accepts loose fuzzy matches that could teach the wrong spelling.
- **The in-app Chat now knows the app.** Ask it "what can this app do?" or "explain feature X" and it answers from the app's real, current features and your actual keyboard shortcuts instead of guessing.

**Full Changelog**: https://github.com/mgsgde/whisper-shortcut/compare/v7.92...v7.93
