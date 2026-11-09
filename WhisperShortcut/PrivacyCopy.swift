import Foundation

enum PrivacyCopy {
  static let promiseTitle: LocalizedStringResource = "Privacy promise"

  static let promiseBullets: [LocalizedStringResource] = [
    "With an offline model, audio never leaves your Mac. With a cloud model, audio is sent only to the provider you chose (OpenRouter, OpenAI, Google Gemini, xAI, or Anthropic) and deleted afterwards.",
    "API keys are stored in the macOS Keychain. They never leave your machine except in authenticated requests to the provider you configured.",
    "No third-party tracking. Optional anonymous usage statistics, off unless you turn them on: counts only — never your words, audio, or which apps you use — sent to our own small server, whose code is public.",
    "Usage data is optional and stays on this Mac. When you turn on \"Save usage data\" in Settings → Privacy & Permissions, the in-app Chat (and an AI app you connect, if you allow it) can read it when you ask them to tune WhisperShortcut; what they read goes only to the model you chose for them, never to us or anyone else.",
  ]

  // Open source is surfaced as its own prominent banner (OpenSourceBanner) rather
  // than a buried bullet, so it reads at a glance — it's the strongest trust signal.
  static let openSourceHeadline: LocalizedStringResource = "Open source"
  static let openSourceDetail: LocalizedStringResource = "Every line is public on GitHub — audit it or build it yourself."
}
