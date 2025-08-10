# WhisperShortcut

**Speech-to-text** shortcut with **OpenAI Whisper API**

## How it works

1. **Press Shortcut** - Start recording with a keyboard shortcut
2. **Transcribe** - Uses OpenAI's Whisper API for accurate speech-to-text
3. **Paste from Clipboard** - Automatically copies transcription to your clipboard

## App Store (Support the Project)

**[Download from Mac App Store](https://apps.apple.com/us/app/whispershortcut/id6749648401)**

If you like WhisperShortcut, please consider leaving a review on the App Store :)

## Free Download

1. Download from [Releases](https://github.com/mgsgde/whisper-shortcut/releases)
2. Drag to Applications folder
3. Launch and configure your OpenAI API key

## Features

- **Quick Recording**: Start/stop with customizable keyboard shortcuts
- **Instant Transcription**: OpenAI Whisper API for accurate results
- **Clipboard Integration**: Automatic copy to clipboard
- **Menu Bar Interface**: Clean, minimal macOS menu bar app
- **Retry Functionality**: One-click retry for failed transcriptions
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

### Run Tests

```bash
./scripts/test.sh
```

## Contributing

Contributions welcome! Please submit a Pull Request.

1. Fork the repository
2. Create feature branch: `git checkout -b feature/your-feature`
3. Make changes and run tests: `./scripts/test.sh`
4. Commit and push: `git commit -am 'Add feature' && git push origin feature/your-feature`
5. Submit Pull Request

## License

MIT License - see [LICENSE](LICENSE) file for details.

---

Made with ❤️ in Karlsruhe, Germany
