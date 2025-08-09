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

## Development

### Prerequisites

- macOS 15.5+
- Xcode 16.0+
- OpenAI API key

### Building from Source

```bash
# Clone the repository
git clone https://github.com/yourusername/whisper-shortcut.git
cd whisper-shortcut

# Open in Xcode
open WhisperShortcut.xcodeproj
```

### Testing

**Rule: Always run tests after making code changes to ensure no regressions.**

#### Method 1: Test Script (Recommended) ✅

The project includes a robust test script that handles all the complexities of running Xcode tests via command line:

```bash
# Run tests normally
./scripts/test.sh

# Run tests with verbose output
./scripts/test.sh -v

# Clean and run tests (removes DerivedData)
./scripts/test.sh -c

# Clean and run tests with verbose output
./scripts/test.sh -v -c

# Show help and available options
./scripts/test.sh -h
```

**Features of the test script:**

- ✅ Handles "Early unexpected exit" errors gracefully
- ✅ Colored output for easy reading
- ✅ Automatic cleanup of existing test results
- ✅ Proper error handling and status reporting
- ✅ Consistent test execution across environments

#### Method 2: Xcode Command Line

```bash
# Run tests using xcodebuild (basic)
xcodebuild test -scheme WhisperShortcut -destination 'platform=macOS,arch=arm64' -derivedDataPath ./DerivedData

# Run tests with result bundle (recommended for debugging)
xcodebuild test -scheme WhisperShortcut -destination 'platform=macOS,arch=arm64' -derivedDataPath ./DerivedData -resultBundlePath ./TestResults.xcresult -only-testing:WhisperShortcutTests

# Run tests with verbose output
xcodebuild test -scheme WhisperShortcut -destination 'platform=macOS,arch=arm64' -derivedDataPath ./DerivedData -verbose
```

#### Method 3: Xcode IDE

1. Open `WhisperShortcut.xcodeproj` in Xcode
2. Select **Product > Test** (⌘U) or click the test diamond icon
3. View results in the Test navigator

### Test Coverage

The test suite includes **16 tests** covering:

- **RetryFunctionalityTests** (9 tests): Error detection and parsing, retry logic
- **ClipboardManagerTests** (2 tests): Clipboard functionality and text formatting
- **TranscriptionServiceTests** (2 tests): API key validation
- **TranscriptionServiceIntegrationTests** (3 tests): Real API integration tests

**Test Results:**

- Test results are saved to: `./TestResults.xcresult` (when using result bundle)
- DerivedData location: `./DerivedData`
- Logs location: `./DerivedData/Logs/Test/`

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

- **For new users**: You may need to set up billing first
  - Visit platform.openai.com
  - Go to Settings → Billing
  - Add a payment method and purchase credits
  - OpenAI no longer provides free trial credits
- **For existing users**: Wait a moment and try again
- OpenAI has rate limits on API usage

**"File too large"**

- Keep recordings under 25MB
- Use shorter audio clips

### Retry Tips

- For timeout errors, try again immediately
- For network errors, check your connection first
- For rate limits, wait 1-2 minutes before retrying
- The retry button will disappear after successful transcription

### Development Issues

**Tests not running**

- Ensure Xcode is installed and up to date
- Check that you're running from the project root directory
- Try cleaning DerivedData: `./scripts/test.sh -c`

**Build errors**

- Clean build artifacts: `rm -rf DerivedData build`
- Ensure all dependencies are installed
- Check Xcode version compatibility

## Privacy

- Audio files are processed locally and sent to OpenAI for transcription
- No audio data is stored permanently
- API keys are stored securely in macOS Keychain
- No telemetry or analytics are collected

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

### Development Workflow

1. Fork the repository
2. Create a feature branch: `git checkout -b feature/your-feature`
3. Make your changes
4. Run tests: `./scripts/test.sh`
5. Commit your changes: `git commit -am 'Add some feature'`
6. Push to the branch: `git push origin feature/your-feature`
7. Submit a Pull Request
