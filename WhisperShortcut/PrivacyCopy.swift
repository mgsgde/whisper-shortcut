import Foundation

enum PrivacyCopy {
  static let promiseTitle = "Privacy promise"

  static let promiseBullets: [String] = [
    "Your audio is processed locally, then sent to your chosen provider (OpenAI, Google Gemini, or xAI) for transcription, and deleted afterwards.",
    "API keys are stored in the macOS Keychain. They never leave your machine except in authenticated requests to the provider you configured.",
    "No hidden telemetry and no third-party tracking — we don't run a server.",
    "Smart Improvement is optional: when on, your usage logs are sent to your chosen provider to refine prompts — never to us or anyone else. You control it during setup and in Settings.",
    "Open source — you can audit the code.",
  ]
}
