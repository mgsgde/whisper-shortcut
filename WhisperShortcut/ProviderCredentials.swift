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
    case openRouter

    var displayName: String {
      switch self {
      case .openAI: return "OpenAI"
      case .xAI: return "xAI"
      case .anthropic: return "Anthropic"
      case .openRouter: return "OpenRouter"
      }
    }

    /// What the key unlocks, used to make the "add a key" message actionable.
    var capability: String {
      switch self {
      case .openAI: return "OpenAI models"
      case .xAI: return String(localized: "Grok models")
      case .anthropic: return String(localized: "Claude models")
      case .openRouter: return "OpenRouter models"
      }
    }

    fileprivate var storedKey: String? {
      switch self {
      case .openAI: return KeychainManager.shared.get(.openAI)
      case .xAI: return KeychainManager.shared.get(.xai)
      case .anthropic: return KeychainManager.shared.get(.anthropic)
      case .openRouter: return KeychainManager.shared.get(.openRouter)
      }
    }

    /// Whether a usable key is stored, under exactly the trimming rule `require` applies — so a
    /// key of pure whitespace can never read as "configured" here and then fail there.
    fileprivate var hasStoredKey: Bool {
      guard let key = storedKey?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
      return !key.isEmpty
    }
  }

  /// Whether a usable key is stored. `Kind.hasStoredKey` stays fileprivate so a caller that needs
  /// the key itself still goes through `require` and its error. Presence checks (pickers, the
  /// reconciler, transcription) were calling `KeychainManager.hasNonEmpty`, which does not trim,
  /// so a whitespace-only key read as configured there and missing in `verifyConfigured`.
  static func hasKey(_ kind: Kind) -> Bool {
    kind.hasStoredKey
  }

  /// The key for `kind`, trimmed and guaranteed non-empty, or a `.networkError` naming the exact
  /// Settings location. All three key fields live under Settings → Accounts.
  static func require(_ kind: Kind) throws -> String {
    guard let key = kind.storedKey?.trimmingCharacters(in: .whitespacesAndNewlines),
          !key.isEmpty else {
      throw TranscriptionError.networkError(missingKeyMessage(kind))
    }
    return key
  }

  /// Message shown when no key is stored.
  static func missingKeyMessage(_ kind: Kind) -> String {
    let name = kind.displayName
    switch kind {
    case .openAI: return String(localized: "No \(name) API key configured. Add your \(name) API key in Settings → Accounts to use OpenAI models.")
    case .xAI: return String(localized: "No \(name) API key configured. Add your \(name) API key in Settings → Accounts to use Grok models.")
    case .anthropic: return String(localized: "No \(name) API key configured. Add your \(name) API key in Settings → Accounts to use Claude models.")
    case .openRouter: return String(localized: "No \(name) API key configured. Add your \(name) API key in Settings → Accounts to use OpenRouter models.")
    }
  }

  /// Message shown when the provider rejects the key we sent (HTTP 401/403).
  static func invalidKeyMessage(_ kind: Kind) -> String {
    let name = kind.displayName
    return String(localized: "\(name) API key is invalid. Check the key in Settings → Accounts.")
  }

  /// Pre-flight check for callers that only need to fail early and don't hold the key themselves
  /// (the provider re-resolves it when it builds the request).
  static func verifyConfigured(_ provider: ChatModelProvider) throws {
    guard provider.hasCredential else {
      throw TranscriptionError.networkError(provider.credentialRequiredMessage)
    }
  }

  /// Whether any provider the user must supply a credential for is configured.
  ///
  /// Drives the "you have no keys at all" safety nets (the menu's disabled state, the first-run
  /// fallback that opens Settings). Both used to spell this out as a four-term `||` chain, written
  /// twice — and neither chain was updated when a provider was added, which is exactly the drift
  /// this replaces.
  static var anyChatCredentialConfigured: Bool {
    ChatModelProvider.allCases.contains { $0.requiresUserSuppliedCredential && $0.hasCredential }
      || ChatGPTPlanPreferences.isConfigured
  }
}

// MARK: - ChatModelProvider → credential

extension ChatModelProvider {

  /// What it takes to reach this provider. **The only per-provider credential switch in the app** —
  /// `hasCredential`, `credentialRequiredMessage` and `requiresUserSuppliedCredential` all derive
  /// from it, so adding a provider means answering this once instead of finding four call sites.
  enum CredentialRequirement {
    /// A user-supplied API key in the Keychain.
    case key(ProviderCredentials.Kind)
    /// Gemini resolves through `GeminiCredentialProvider` rather than the Keychain directly, so the
    /// injectable seam the Gemini paths already use stays the only way in.
    case gemini
    /// Configured by endpoint (URL + optional key), not by a key alone.
    case endpoint
    /// Signed in with ChatGPT (`ChatGPTPlanCredentials`). **Not an API key**: it is an OAuth session,
    /// so it is excluded from `requiresUserSuppliedCredential` and from every key field/validation.
    case chatGPTPlan
    /// Nothing to configure — reachability surfaces at request time.
    case none
  }

  var credentialRequirement: CredentialRequirement {
    switch self {
    case .gemini: return .gemini
    case .openai: return .key(.openAI)
    case .grok: return .key(.xAI)
    case .anthropic: return .key(.anthropic)
    case .customOpenAI: return .endpoint
    case .openRouter: return .key(.openRouter)
    case .chatGPTPlan: return .chatGPTPlan
    case .local, .localMLX: return .none
    }
  }

  /// Whether the user currently has what this provider needs.
  var hasCredential: Bool {
    switch credentialRequirement {
    case .key(let kind): return kind.hasStoredKey
    case .gemini: return GeminiCredentialProvider.shared.hasCredential()
    case .endpoint: return OpenAIChatPreferences.isConfigured
    case .chatGPTPlan: return ChatGPTPlanPreferences.isConfigured
    case .none: return true
    }
  }

  /// Actionable message shown when this provider can't run for lack of a credential. Every one of
  /// them names the Settings tab the field actually lives in — the wording that used to exist only
  /// on the `ProviderCredentials` side of the split.
  var credentialRequiredMessage: String {
    switch credentialRequirement {
    case .key(let kind):
      return ProviderCredentials.missingKeyMessage(kind)
    case .gemini:
      return String(localized: "No Google API key configured. Add your Gemini API key in Settings → Accounts to use Gemini models.")
    case .endpoint:
      return String(localized: "Your own server is not set up. Add its base URL and key in Settings → Chat.")
    case .chatGPTPlan:
      return String(localized: "Sign in with ChatGPT in Settings → Accounts to use your ChatGPT plan.")
    case .none:
      return ""
    }
  }

  /// True for providers the user has to bring a credential for at all. Excludes `local` (needs
  /// none) and `customOpenAI` (configured by endpoint), so neither can satisfy an "any key?" check.
  var requiresUserSuppliedCredential: Bool {
    switch credentialRequirement {
    case .key, .gemini: return true
    case .endpoint, .chatGPTPlan, .none: return false
    }
  }
}
