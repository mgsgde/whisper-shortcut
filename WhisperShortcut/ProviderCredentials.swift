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

    /// Whether a usable key is stored, under exactly the trimming rule `require` applies — so a
    /// key of pure whitespace can never read as "configured" here and then fail there.
    fileprivate var hasStoredKey: Bool {
      guard let key = storedKey?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
      return !key.isEmpty
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
    case .local, .localMLX: return .none
    }
  }

  /// Whether the user currently has what this provider needs.
  var hasCredential: Bool {
    switch credentialRequirement {
    case .key(let kind): return kind.hasStoredKey
    case .gemini: return GeminiCredentialProvider.shared.hasCredential()
    case .endpoint: return OpenAIChatPreferences.isConfigured
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
      return "No Google API key configured. Add your Gemini API key in Settings → General to use Gemini models."
    case .endpoint:
      return "Custom endpoint is not configured — set URL and API key in Settings → Chat."
    case .none:
      return ""
    }
  }

  /// True for providers the user has to bring a credential for at all. Excludes `local` (needs
  /// none) and `customOpenAI` (configured by endpoint), so neither can satisfy an "any key?" check.
  var requiresUserSuppliedCredential: Bool {
    switch credentialRequirement {
    case .key, .gemini: return true
    case .endpoint, .none: return false
    }
  }
}
