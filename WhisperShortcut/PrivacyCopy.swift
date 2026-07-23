import Foundation

enum PrivacyCopy {
  static let promiseTitle = "Privacy promise"

  static let promiseBullets: [String] = [
    "With offline Whisper, audio never leaves your Mac. With a cloud model, audio is sent only to the provider you chose (OpenAI, Google Gemini, xAI, or Anthropic) and deleted afterwards.",
    "API keys are stored in the macOS Keychain. They never leave your machine except in authenticated requests to the provider you configured.",
    "No hidden telemetry and no third-party tracking — we don't run a server.",
    "Smart Improvement is optional: when on, your usage logs are sent to your chosen provider to refine prompts — never to us or anyone else. You control it during setup and in Settings.",
  ]

  // Open source is surfaced as its own prominent banner (OpenSourceBanner) rather
  // than a buried bullet, so it reads at a glance — it's the strongest trust signal.
  static let openSourceHeadline = "Open source"
  static let openSourceDetail = "Every line is public on GitHub — audit it or build it yourself."
}
