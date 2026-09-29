import Foundation

enum PrivacyCopy {
  static let promiseTitle = "Privacy promise"

  static let promiseBullets: [String] = [
    "With an offline model, audio never leaves your Mac. With a cloud model, audio is sent only to the provider you chose (OpenAI, Google Gemini, xAI, or Anthropic) and deleted afterwards.",
    "API keys are stored in the macOS Keychain. They never leave your machine except in authenticated requests to the provider you configured.",
    "No third-party tracking. Optional anonymous usage statistics, off unless you turn them on: counts only — never your words, audio, or which apps you use — sent to our own small server, whose code is public.",
    "Smart Improvement is optional: when on, your usage logs are sent to your chosen provider to refine prompts — never to us or anyone else. You control it during setup and in Settings.",
  ]

  // Open source is surfaced as its own prominent banner (OpenSourceBanner) rather
  // than a buried bullet, so it reads at a glance — it's the strongest trust signal.
  static let openSourceHeadline = "Open source"
  static let openSourceDetail = "Every line is public on GitHub — audit it or build it yourself."
}
