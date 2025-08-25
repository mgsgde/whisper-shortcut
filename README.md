# WhisperShortcut

**Speech-to-text** shortcut with **OpenAI Whisper API**

## How it works

1. **Setup** - Configure your OpenAI API key ([Get one here](https://platform.openai.com/account/api-keys))
2. **Press Shortcut** - Start recording with a keyboard shortcut
3. **Transcribe** - Uses OpenAI's Whisper API for accurate speech-to-text
4. **Paste from Clipboard** - Automatically copies transcription to your clipboard

## App Store (Support the Project)

**[Download from Mac App Store](https://apps.apple.com/us/app/whispershortcut/id6749648401)**

If you like WhisperShortcut, please consider leaving a review on the App Store :)

## Free Download

1. Download from [Releases](https://github.com/mgsgde/whisper-shortcut/releases)
2. Drag to Applications folder
3. Launch and configure your OpenAI API key

## Features

- **Dual Recording Modes**:
  - **Transcription Mode**: Audio → Text transcription
  - **Prompt Mode**: Audio → GPT-4o AI assistant execution
- **Customizable Shortcuts**: Configurable keyboard shortcuts for both modes
- **Instant Processing**: OpenAI Whisper + GPT-4o APIs for accurate results
- **Clipboard Integration**: Automatic copy to clipboard
- **Tabbed Settings**: Clean, organized settings interface
- **Menu Bar Interface**: Minimal macOS menu bar app
- **Retry Functionality**: One-click retry for failed operations
- **Secure**: API keys stored in macOS Keychain

## Privacy

- Audio processed locally and sent to OpenAI
- No permanent audio storage
- API keys stored securely in Keychain
- No telemetry collected

## Development

### Prerequisites

- macOS 15.5+
- Xcode 16.0+
- OpenAI API key

### Build from Source

```bash
git clone https://github.com/mgsgde/whisper-shortcut.git
cd whisper-shortcut
open WhisperShortcut.xcodeproj
```

### Build and Run

```bash
# Build the application
xcodebuild -project WhisperShortcut.xcodeproj -scheme WhisperShortcut -configuration Debug build

# Run the application
open /Users/mgsgde/Library/Developer/Xcode/DerivedData/WhisperShortcut-budjpsyyuwuiqxgeultiqzrgjcos/Build/Products/Debug/WhisperShortcut.app
```

### Testing

#### Test-Driven Development (TDD)

This project follows **Test-Driven Development** practices:

1. **Write tests first** before implementing features
2. **Run tests frequently** during development
3. **Keep tests simple** and focused on single behaviors
4. **Maintain high test coverage** for critical functionality

#### Running Tests

```bash
# Run tests directly with Xcode (alternative)
xcodebuild test -project WhisperShortcut.xcodeproj -scheme WhisperShortcut -destination 'platform=macOS'

# Run specific test class
xcodebuild test -project WhisperShortcut.xcodeproj -scheme WhisperShortcut -destination 'platform=macOS' -only-testing:WhisperShortcutTests/TranscriptionServiceTests

# Run specific test method
xcodebuild test -project WhisperShortcut.xcodeproj -scheme WhisperShortcut -destination 'platform=macOS' -only-testing:WhisperShortcutTests/TranscriptionServiceTests/testModelSelection
```

## License

MIT License - see [LICENSE](LICENSE) file for details.

---

Made with ❤️ in Karlsruhe, Germany
