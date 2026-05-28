import Foundation

enum PrivacyCopy {
  static let promiseTitle = "Privacy promise"

  static let promiseBullets: [String] = [
    "Your audio is processed locally, then sent to your chosen provider (OpenAI, Google Gemini, or xAI) for transcription, and deleted afterwards.",
    "API keys are stored in the macOS Keychain. They never leave your machine except in authenticated requests to the provider you configured.",
    "No telemetry, no analytics, no third-party tracking.",
    "Open source — you can audit the code.",
  ]

  static let contactEmail = "mgsgde@gmail.com"

  static let fallbackPolicy = """
  WhisperShortcut Privacy Policy

  WhisperShortcut runs entirely on your Mac. We do not operate a server.

  What we collect
  - Nothing. The app has no telemetry, no analytics, and no third-party tracking SDKs.

  What you send (controlled by you)
  - Audio you record is sent to the AI provider you choose (Google Gemini, OpenAI, or
    xAI) for transcription. After the request completes we discard the audio.
  - Text you type in chat or Dictate Prompt is sent to the provider you selected for
    that request.
  - Screenshots you attach to chat messages are sent to the provider along with that
    message.

  Where it goes
  - Requests go directly from your Mac to the provider you configured. We do not proxy
    traffic through any server.
  - Each provider's own privacy policy governs how they handle that data.

  How API keys are stored
  - API keys are stored in the macOS Keychain. They never leave your machine except as
    part of authenticated requests to the provider you configured.

  Permissions used
  - Microphone — required to record audio for dictation.
  - Accessibility — optional. Used to auto-paste transcribed text into other apps.
  - Screen Recording — optional. Used only when you attach screenshots in chat.

  Open source
  - The app is open source so you can audit the code.

  Contact
  - Questions or concerns: mgsgde@gmail.com
  """
}
