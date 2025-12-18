# Release Notes for Version 5.2.5

## Installation

Download the latest version from the [Releases page](https://github.com/mgsgde/whisper-shortcut/releases) or update through the App Store.

## Changes

### 🤖 Gemini 3 Flash Model Support

This release adds support for the latest Gemini 3 Flash model, providing enhanced performance and capabilities for both transcription and prompt processing.

**New Features:**

- **Gemini 3 Flash for Transcription**: Added the new Gemini 3 Flash model as an option for speech-to-text transcription, offering improved accuracy and speed
- **Gemini 3 Flash for Prompts**: Integrated Gemini 3 Flash into the prompt processing workflow, enabling more powerful AI-assisted text generation
- **Model Information**: Updated model descriptions and API endpoints to reflect the new Gemini 3 Flash capabilities

**User Experience Improvements:**

- **Model Initialization Notice**: Added helpful information in the Prompt Model Selection view explaining that the first execution may take longer due to model initialization, with subsequent prompts being faster
- **Enhanced Clarity**: Improved user understanding of expected performance during initial model use

**Technical Improvements:**

- Updated `TranscriptionModel` enum to include Gemini 3 Flash with proper configuration
- Updated `PromptModel` enum to include Gemini 3 Flash support
- Adjusted cost levels and model validation to incorporate the new model
- Enhanced settings configuration to properly display and handle Gemini 3 Flash

## What's Next

We're continuously working on improving WhisperShortcut. If you have suggestions or encounter any issues, please [open an issue](https://github.com/mgsgde/whisper-shortcut/issues) on GitHub.

---

**Full Changelog**: [5.2.4...5.2.5](https://github.com/mgsgde/whisper-shortcut/compare/v5.2.4...v5.2.5)
