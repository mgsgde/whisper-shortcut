# WhisperShortcut

A macOS menu bar app that provides quick audio transcription using OpenAI's Whisper API. Record audio with a keyboard shortcut and get instant transcriptions copied to your clipboard.

## Features

- **Quick Recording**: Start/stop recording with customizable keyboard shortcuts
- **Instant Transcription**: Uses OpenAI's Whisper API for accurate speech-to-text
- **Clipboard Integration**: Automatically copies transcriptions to clipboard
- **Menu Bar Interface**: Clean, minimal interface in the macOS menu bar
- **Settings Management**: Easy API key configuration and shortcut customization
- **Retry Functionality**: Automatically retry failed transcriptions with one click
- **Error Handling**: Comprehensive error messages and timeout management

## Installation

1. Download the latest release from the [Releases page](https://github.com/yourusername/whisper-shortcut/releases)
2. Drag the app to your Applications folder
3. Launch the app and configure your OpenAI API key in Settings

## Setup

1. **Get an OpenAI API Key**: Sign up at [OpenAI](https://platform.openai.com/) and create an API key
2. **Configure the App**: Open Settings from the menu bar and enter your API key
3. **Customize Shortcuts**: Set your preferred keyboard shortcuts for recording
4. **Start Recording**: Use your configured shortcut or click the menu bar icon

## Usage

### Basic Recording

- Press your configured shortcut to start recording
- Speak clearly into your microphone
- Press the shortcut again to stop recording
- The transcription will automatically be copied to your clipboard

### Retry Functionality

When transcription fails (due to network issues, timeouts, or server errors), the app will:

- Show a "🔄 Retry Transcription" option in the menu
- Keep the audio file available for retry
- Allow you to retry with one click
- Automatically clean up files after successful retry

**Retryable Errors:**

- ⏰ Timeout errors (network issues)
- ❌ Network errors (connection problems)
- ❌ Server errors (OpenAI server issues)
- ⏳ Rate limit errors (temporary limits)

### Menu Bar Interface

- **🎙️**: Ready to record
- **🔴**: Currently recording
- **⏳**: Transcribing audio
- **✅**: Transcription successful
- **❌**: Transcription failed (retry available)

## Configuration

### Keyboard Shortcuts

- **Start Recording**: Default `Cmd+Shift+R`
- **Stop Recording**: Default `Cmd+Shift+S`
- **Settings**: Access via menu bar

### API Key Management

- Securely stored in macOS Keychain
- Validated on save
- No local storage of sensitive data

## Troubleshooting

### Common Issues

**"No API key configured"**

- Open Settings and add your OpenAI API key
- Ensure the key is valid and has sufficient credits

**"Timeout Error"**

- Check your internet connection
- Try using shorter audio recordings
- Use the retry functionality to attempt again

**"Rate Limited"**

- Wait a moment and try again
- OpenAI has rate limits on API usage

**"File too large"**

- Keep recordings under 25MB
- Use shorter audio clips

### Retry Tips

- For timeout errors, try again immediately
- For network errors, check your connection first
- For rate limits, wait 1-2 minutes before retrying
- The retry button will disappear after successful transcription

## Development

### Building from Source

```bash
git clone https://github.com/yourusername/whisper-shortcut.git
cd whisper-shortcut
open WhisperShortcut.xcodeproj
```

### Requirements

- macOS 15.5+
- Xcode 16.0+
- OpenAI API key

## Privacy

- Audio files are processed locally and sent to OpenAI for transcription
- No audio data is stored permanently
- API keys are stored securely in macOS Keychain
- No telemetry or analytics are collected

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.
