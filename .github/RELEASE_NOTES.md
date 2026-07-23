# WhisperShortcut 7.92

A polish release: Settings and Chat are now navigable with VoiceOver, and a batch of visual inconsistencies across both windows has been cleaned up.

## Installation

Download the latest build from the [Releases page](https://github.com/mgsgde/whisper-shortcut/releases), move **WhisperShortcut.app** to your Applications folder, and launch it.

## What's New

### ♿️ Accessibility

- **Model tiles are selectable with VoiceOver.** Picking a transcription, chat, or voice model was previously impossible without a mouse — the tiles were tappable areas with no button role or name.
- **Toggles and dropdowns announce what they control.** A dozen switches and pickers in General, Chat, Dictate Prompt, Read Aloud, and Improve had no spoken label.
- **Every icon-only button now has a name** — the show/hide eye on each API key field, sidebar and tab controls, send/stop, banner dismiss, add-header, and clear-shortcut.
- **Collapsible sidebar sections** in Chat are exposed as real controls, with their expanded/collapsed state announced.

### 🎨 Interface polish

- The **Read Aloud voice picker** now uses the same tiles as every other model picker, so it highlights on hover and shows the recommended star.
- **Section headers across Settings** carry icons consistently, including the prompt and glossary editors.
- Fixed a **doubled gap** above the offline model list, unified card padding and button corners, and matched the vertical spacing of your chat bubbles to the assistant's.
- The **chat composer** no longer draws its text with system colors, which could render it nearly black against the dark composer when macOS was set to light appearance.
- The **Smart Improvement review window** no longer clips its own content at the smallest size it allows you to drag it to.
- Removed a stray emoji from the Google API key section.

### 🧹 Maintenance

- Updated swift-crypto to 4.5.1 and swift-jinja to 2.4.1.

**Full Changelog**: https://github.com/mgsgde/whisper-shortcut/compare/v7.91...v7.92
