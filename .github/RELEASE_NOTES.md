## Dictate Prompt
- **Faster and leaner.** Spoken Dictate Prompts with Gemini answer in about 3 seconds instead of 12, and cost far less.
- **No more full-screen screenshots.** Instead of a picture of your whole screen, Dictate Prompt reads the text field you are typing in. It sends a picture of the front window only when the field is empty, very short or can't be read. Password fields and password managers are never read or captured.
- The setting "Include screenshot" is now called "Front window as fallback". It stays on.

## Setup
- **Fn key conflict explained.** If macOS still uses the 🌐/Fn key itself, a card tells you why Fn dictation won't work yet. In the version from GitHub, one click frees the key (after you confirm). If macOS keeps opening the emoji picker, log out and back in once.
- **Paste is on once Accessibility is granted.** If you have granted Accessibility and never changed the setting, WhisperShortcut now pastes the result automatically. This includes existing users. You can switch it off in Settings.
- **Move to Applications.** If you start WhisperShortcut from the Downloads folder or the DMG, it offers to move itself to Applications.
- **Offline dictation language.** When you pick Offline, the dictation language is set from your Mac's language, if the offline model supports it.

## Claude & AI apps
- **Disconnect.** Each AI app card in Settings now has a Disconnect button that removes WhisperShortcut from that app again.

## Dictation
- After a title such as "Frau", "Herr", "Dr." or "Prof.", a misheard name is corrected to the spelling in your glossary.

## Chat
- **Gemma 4 26B offline.** Macs with 32 GB of memory or more can download Gemma 4 26B as an offline chat model (`/mlxgemma`).

## Installation
Download the DMG from the [releases page](https://github.com/mgsgde/whisper-shortcut/releases), open it, and drag WhisperShortcut to your Applications folder.

**Full changelog:** https://github.com/mgsgde/whisper-shortcut/compare/v8.82...v8.83
