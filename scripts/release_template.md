# WhisperShortcut {{VERSION}}

**Release Date:** {{DATE}}  
**Build:** {{BUILD}}  
**macOS:** 15.5+  
**Minimum Xcode:** 16.0+

## 🎉 What's New

### Core Features

- 🎙️ **Instant Voice-to-Text**: Record audio with keyboard shortcuts and get instant transcriptions
- 📋 **Automatic Clipboard Integration**: Transcriptions are automatically copied to your clipboard
- 🎯 **Menu Bar Interface**: Clean, minimal interface that stays out of your way
- ⚡ **Lightning-Fast**: Uses OpenAI's Whisper AI for high-quality transcription
- 🔄 **Retry Functionality**: Automatically retry failed transcriptions with one click

### User Experience

- 🎨 **Modern UI**: Beautiful, native macOS interface with emoji status indicators
- ⌨️ **Customizable Shortcuts**: Set your preferred keyboard shortcuts for recording
- 🔐 **Secure API Key Management**: API keys stored securely in macOS Keychain
- 🎯 **Smart Error Handling**: Comprehensive error messages and timeout management
- 📊 **Real-time Status**: Visual feedback with status icons (🎙️, 🔴, ⏳, ✅, ❌)

## 🎯 Key Features

### Recording & Transcription

- **Quick Recording**: Start/stop recording with customizable keyboard shortcuts
- **Instant Transcription**: Uses OpenAI's Whisper API for accurate speech-to-text
- **Clipboard Integration**: Automatically copies transcriptions to clipboard
- **Retry Functionality**: Automatically retry failed transcriptions with one click

### User Interface

- **Menu Bar Interface**: Clean, minimal interface in the macOS menu bar
- **Status Indicators**:
  - 🎙️ Ready to record
  - 🔴 Currently recording
  - ⏳ Transcribing audio
  - ✅ Transcription successful
  - ❌ Transcription failed (retry available)

## 🚀 Getting Started

### Installation

1. Download `WhisperShortcut-{{VERSION}}.zip` from this release
2. Extract the zip file
3. Drag `WhisperShortcut.app` to your Applications folder
4. Launch the app and configure your OpenAI API key in Settings

### Setup

1. **Get an OpenAI API Key**: Sign up at [OpenAI](https://platform.openai.com/) and create an API key
2. **Configure the App**: Open Settings from the menu bar and enter your API key
3. **Customize Shortcuts**: Set your preferred keyboard shortcuts for recording
4. **Start Recording**: Use your configured shortcut or click the menu bar icon

## 🔧 Technical Details

### System Requirements

- **macOS**: 15.5 or later
- **Architecture**: Universal (Intel + Apple Silicon)
- **Storage**: ~2MB
- **Permissions**: Microphone access, Keychain access

### Privacy & Security

- ✅ No personal information collected
- ✅ No analytics or tracking
- ✅ No crash reporting
- ✅ All data stored locally on your device
- ✅ API keys stored securely in macOS Keychain
- ✅ Audio files processed locally and deleted after transcription

## 🐛 Bug Fixes

-

## 🔄 Retry Functionality

When transcription fails (due to network issues, timeouts, or server errors), the app will:

- Show a "🔄 Retry Transcription" option in the menu
- Keep the audio file available for retry
- Allow you to retry with one click
- Automatically clean up files after successful retry

**Retryable Errors**:

- ⏰ Timeout errors (network issues)
- ❌ Network errors (connection problems)
- ❌ Server errors (OpenAI server issues)
- ⏳ Rate limit errors (temporary limits)

## 🎯 Perfect For

- Creating prompts for ChatGPT, Claude, Gemini, and other LLMs
- Voice input for AI assistants that lack good speech recognition
- Consistent speech-to-text across all AI platforms
- Quick note-taking and transcription needs
- Accessibility and hands-free computing

## 📞 Support

- **GitHub Issues**: [Report bugs or request features](https://github.com/mgsgde/whisper-shortcut/issues)
- **Documentation**: [README.md](https://github.com/mgsgde/whisper-shortcut/blob/main/README.md)
- **Privacy Policy**: [privacy.md](https://github.com/mgsgde/whisper-shortcut/blob/main/privacy.md)

---

**Thank you for using WhisperShortcut!** 🎙️
