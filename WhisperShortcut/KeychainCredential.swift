import Foundation

/// Every secret this app stores in the login Keychain.
///
/// The raw value **is** the Keychain account name, so adding a credential is a single edit here —
/// it cannot end up with a save path but no delete path, which is what happened while each
/// provider had its own hand-copied `save…`/`get…`/`delete…` triple on `KeychainManager`.
///
/// The account names are load-bearing: they address items already in users' keychains. Never
/// change an existing raw value — that orphans the stored secret and reads as "my API key
/// vanished".
enum KeychainCredential: String, CaseIterable {
  /// Pre-multi-provider OpenAI key. Kept because it still addresses items written by older
  /// builds; new writes go to `.openAI`.
  case legacyOpenAI = "api-key"

  case google = "google-api-key"
  case xai = "xai-api-key"
  case anthropic = "anthropic-api-key"
  case openAI = "openai-api-key"

  case googleCalendarRefreshToken = "google-calendar-refresh-token"
  case trelloToken = "trello-token"
  case trelloAPIKey = "trello-api-key"

  case customTranscriptionBearerToken = "custom-transcription-bearer-token"
  case customTranscriptionHeaders = "custom-transcription-headers"
  case customOpenAIChatAPIKey = "custom-openai-chat-api-key"

  /// Keychain account name this credential is stored under.
  var accountName: String { rawValue }

  /// Environment variables consulted before the Keychain in DEBUG builds, in priority order.
  /// Lets live roundtrip tests reach real provider APIs without tripping the macOS ACL prompt
  /// that the `xctest` binary would otherwise raise. Empty for credentials tests never need.
  var environmentVariableNames: [String] {
    switch self {
    case .google: return ["WHISPERSHORTCUT_GOOGLE_API_KEY", "GOOGLE_API_KEY", "GEMINI_API_KEY"]
    case .xai: return ["WHISPERSHORTCUT_XAI_API_KEY", "XAI_API_KEY"]
    case .anthropic: return ["WHISPERSHORTCUT_ANTHROPIC_API_KEY", "ANTHROPIC_API_KEY"]
    case .openAI: return ["WHISPERSHORTCUT_OPENAI_API_KEY", "OPENAI_API_KEY"]
    default: return []
    }
  }
}
