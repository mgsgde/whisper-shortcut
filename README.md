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

### Option 1: Free Installation (Recommended)

#### Method A: Download from Releases

1. Download the latest release from the [Releases page](https://github.com/yourusername/whisper-shortcut/releases)
2. Drag the app to your Applications folder
3. Launch the app and configure your OpenAI API key in Settings

#### Method B: Install Script (For Developers)

If you have the source code and want to build from source:

```bash
# Clone the repository
git clone https://github.com/yourusername/whisper-shortcut.git
cd whisper-shortcut

# Run the installation script
./install.sh
```

The install script will:

- ✅ Check for Xcode command line tools
- ✅ Build the app in Release configuration
- ✅ Install it to `/Applications/`
- ✅ Set proper permissions
- ✅ Provide next steps for configuration

**Prerequisites for install script:**

- macOS 15.5+
- Xcode command line tools installed
- Git (for cloning the repository)

### Option 2: App Store (Support the Project)

If you'd like to support the development of WhisperShortcut, you can also download it from the Mac App Store:

**[Download WhisperShortcut on the Mac App Store](https://apps.apple.com/us/app/whispershortcut/id6749648401)**

- ✅ Same features as the free version
- ✅ Automatic updates through the App Store
- ✅ Supports the continued development of the project
- ✅ Leave a positive review to help others discover the app

**Note**: All versions are identical in functionality. The App Store version is simply a way to support the project if you find it useful!

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

### Creating GitHub Releases

The project includes a release script that automates the GitHub release process:

```bash
# Method 1: Interactive (create template and edit)
./scripts/release.sh

# Method 2: Use existing release notes file
./scripts/release.sh RELEASE_NOTES_v1.1.md

# Method 3: Use template file directly
./scripts/release.sh scripts/release_template.md

# Method 4: Show help
./scripts/release.sh --help
```

**What the release script does:**

1. ✅ Checks for uncommitted changes
2. ✅ Builds the app in Release configuration
3. ✅ Creates a zip file of the app
4. ✅ Creates and pushes a git tag
5. ✅ Creates a GitHub release (draft)
6. ✅ Provides next steps for publishing

**Release Notes Options:**

- **Interactive mode**: Script creates a template and opens it in your editor
- **File mode**: Use an existing markdown file with release notes
- **Template mode**: Use the built-in template file directly
- **Help**: Show usage information and examples

**Prerequisites for releases:**

- GitHub CLI (`gh`) installed (optional, for automatic release creation)
- Git configured with proper remote origin
- Xcode command line tools installed

**Manual Release Process (if not using the script):**

1. **Build the app:**

   ```bash
   xcodebuild clean -project WhisperShortcut.xcodeproj -scheme WhisperShortcut -configuration Release
   xcodebuild build -project WhisperShortcut.xcodeproj -scheme WhisperShortcut -configuration Release -derivedDataPath build
   ```

2. **Create a zip file:**

   ```bash
   cd build/Build/Products/Release
   zip -r WhisperShortcut-1.2.0.zip WhisperShortcut.app
   ```

3. **Create a git tag:**

   ```bash
   git tag -a v1.2.0 -m "Release 1.2.0"
   git push origin v1.2.0
   ```

4. **Create GitHub release:**
   - Go to: `https://github.com/yourusername/whisper-shortcut/releases`
   - Click "Create a new release"
   - Choose the tag you just created
   - Add release notes and upload the zip file
   - Publish the release

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
