import Foundation

/// Single source of truth for "does the user have a usable API key for provider X?".
///
/// Before this existed the same guard was hand-written at a dozen call sites (each chat provider,
/// `SpeechService`'s TTS and transcription paths, `ContextDerivation`'s pre-flight check), which let
/// three kinds of drift accumulate: two different message wordings for the same condition, a wrong
/// Settings destination for xAI ("→ Chat"; the key field lives under General), and inconsistent
/// trimming — some sites trimmed whitespace off the stored key, others sent it verbatim into an
/// `Authorization` header. Routing every check through here means one place to change a message and
/// one trimming rule for all of them.
enum ProviderCredentials {

  /// Providers that authenticate with a user-supplied key from the Keychain. Gemini is absent on
  /// purpose — it resolves through `GeminiCredentialProvider` (which also supports OAuth), and the
  /// local provider needs no key at all.
  enum Kind {
    case openAI
    case xAI
    case anthropic

    var displayName: String {
      switch self {
      case .openAI: return "OpenAI"
      case .xAI: return "xAI"
      case .anthropic: return "Anthropic"
      }
    }

    /// What the key unlocks, used to make the "add a key" message actionable.
    var capability: String {
      switch self {
      case .openAI: return "OpenAI models"
      case .xAI: return "Grok models"
      case .anthropic: return "Claude models"
      }
    }

    fileprivate var storedKey: String? {
      switch self {
      case .openAI: return KeychainManager.shared.get(.openAI)
      case .xAI: return KeychainManager.shared.get(.xai)
      case .anthropic: return KeychainManager.shared.get(.anthropic)
      }
    }
  }

  /// The key for `kind`, trimmed and guaranteed non-empty, or a `.networkError` naming the exact
  /// Settings location. All three key fields live under Settings → General.
  static func require(_ kind: Kind) throws -> String {
    guard let key = kind.storedKey?.trimmingCharacters(in: .whitespacesAndNewlines),
          !key.isEmpty else {
      throw TranscriptionError.networkError(missingKeyMessage(kind))
    }
    return key
  }

  /// Message shown when no key is stored.
  static func missingKeyMessage(_ kind: Kind) -> String {
    "No \(kind.displayName) API key configured. Add your \(kind.displayName) API key in Settings → General to use \(kind.capability)."
  }

  /// Message shown when the provider rejects the key we sent (HTTP 401/403).
  static func invalidKeyMessage(_ kind: Kind) -> String {
    "\(kind.displayName) API key is invalid. Check the key in Settings → General."
  }

  /// Pre-flight check for callers that only need to fail early and don't hold the key themselves
  /// (the provider re-resolves it when it builds the request). Providers that carry no Keychain key
  /// — Gemini, local — pass through; `customOpenAI` validates its endpoint configuration instead.
  static func verifyConfigured(_ provider: ChatModelProvider) throws {
    switch provider {
    case .openai:
      _ = try require(.openAI)
    case .grok:
      _ = try require(.xAI)
    case .anthropic:
      _ = try require(.anthropic)
    case .customOpenAI:
      guard OpenAIChatPreferences.isConfigured else {
        throw TranscriptionError.networkError(
          "Custom endpoint is not configured — set URL and API key in Settings → Chat.")
      }
    case .gemini, .local:
      break
    }
  }
}
