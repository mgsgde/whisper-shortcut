import Foundation

/// An LLM provider whose API key the user enters in Settings ▸ General and whose key can be
/// validated online. Deliberately narrower than `KeychainCredential`: Trello and the custom
/// OpenAI-compatible proxy are stored credentials too, but have no validation endpoint and no
/// entry section of this shape.
///
/// Everything the settings UI needs to render a provider's key section hangs off this enum, so
/// `APIKeyEntrySection` is one view driven by data rather than one hand-copied view per provider.
enum APIKeyProvider: CaseIterable {
  case google
  case openai
  case xai
  case anthropic

  /// Where this provider's key is stored.
  var credential: KeychainCredential {
    switch self {
    case .google: return .google
    case .openai: return .openAI
    case .xai: return .xai
    case .anthropic: return .anthropic
    }
  }

  var sectionTitle: String {
    switch self {
    case .google: return "Google API Key"
    case .openai: return "OpenAI API Key"
    case .xai: return "xAI API Key (Grok)"
    case .anthropic: return "Anthropic API Key (Claude)"
    }
  }

  var sectionSubtitle: String {
    switch self {
    case .google:
      return "Powers Gemini transcription, Dictate Prompt, Read Aloud, and Chat. Get a key from Google AI Studio (link below)."
    case .openai:
      return "Add an OpenAI API key to use OpenAI's transcription models (gpt-4o-transcribe, gpt-4o-mini-transcribe). Get a key from the OpenAI platform (link below)."
    case .xai:
      return "Add an xAI API key to use Grok models in the chat window. Get a key from the xAI console (link below)."
    case .anthropic:
      return "Add an Anthropic API key to use Claude models in the chat window. Get a key from the Anthropic Console (link below)."
    }
  }

  /// Placeholder shown in the empty key field — the provider's key prefix.
  var keyPlaceholder: String {
    switch self {
    case .google: return "AIza..."
    case .openai: return "sk-..."
    case .xai: return "xai-..."
    case .anthropic: return "sk-ant-..."
    }
  }

  /// Link rows rendered under the key field. A list rather than a single URL because Google
  /// also points at the Cloud console for quota configuration.
  var helpLinks: [APIKeyHelpLink] {
    switch self {
    case .google:
      return [
        APIKeyHelpLink(
          intro: "Need an API key? Get one at ",
          label: "aistudio.google.com/api-keys",
          url: URL(string: "https://aistudio.google.com/api-keys")!),
        APIKeyHelpLink(
          intro: "Configure rate limits at ",
          label: "console.cloud.google.com/.../quotas",
          url: URL(string: "https://console.cloud.google.com/apis/api/generativelanguage.googleapis.com/quotas")!),
      ]
    case .openai:
      return [
        APIKeyHelpLink(
          intro: "Get an API key at ",
          label: "platform.openai.com/api-keys",
          url: URL(string: "https://platform.openai.com/api-keys")!)
      ]
    case .xai:
      return [
        APIKeyHelpLink(
          intro: "Get an API key at ",
          label: "console.x.ai",
          url: URL(string: "https://console.x.ai")!)
      ]
    case .anthropic:
      return [
        APIKeyHelpLink(
          intro: "Get an API key at ",
          label: "console.anthropic.com",
          url: URL(string: "https://console.anthropic.com/settings/keys")!)
      ]
    }
  }
}

/// One "get a key here" link row under an API key field.
struct APIKeyHelpLink: Identifiable {
  let intro: String
  let label: String
  let url: URL

  var id: String { label }
}

/// Outcome of a live API-key validation request.
enum APIKeyValidationResult {
  case valid        // provider accepted the key (HTTP 2xx)
  case invalid      // provider rejected the key (auth error: 400/401/403)
  case unverified   // couldn't determine (network error, timeout, unexpected status)
}

/// Validates an API key against its provider with a single lightweight read-only request
/// (listing models / key info). Keeps it cheap and side-effect-free so it's safe to run on a
/// debounce while the user types. Network failures map to `.unverified`, never `.invalid`, so
/// being offline never falsely tells the user their key is wrong.
enum APIKeyValidator {
  private static let timeout: TimeInterval = 10

  static func validate(_ provider: APIKeyProvider, key: String) async -> APIKeyValidationResult {
    let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return .unverified }

    var request: URLRequest
    switch provider {
    case .google:
      // The key rides in the query string for Google's Generative Language API.
      guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models?key=\(trimmed)") else {
        return .unverified
      }
      request = URLRequest(url: url)
    case .openai:
      guard let url = URL(string: "https://api.openai.com/v1/models") else { return .unverified }
      request = URLRequest(url: url)
      request.setValue("Bearer \(trimmed)", forHTTPHeaderField: "Authorization")
    case .xai:
      guard let url = URL(string: "https://api.x.ai/v1/api-key") else { return .unverified }
      request = URLRequest(url: url)
      request.setValue("Bearer \(trimmed)", forHTTPHeaderField: "Authorization")
    case .anthropic:
      guard let url = URL(string: "https://api.anthropic.com/v1/models") else { return .unverified }
      request = URLRequest(url: url)
      request.setValue(trimmed, forHTTPHeaderField: "x-api-key")
      request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    }
    request.httpMethod = "GET"
    request.timeoutInterval = timeout

    do {
      let (_, response) = try await URLSession.shared.data(for: request)
      guard let http = response as? HTTPURLResponse else { return .unverified }
      switch http.statusCode {
      case 200...299:
        DebugLogger.log("API-KEY-VALIDATION: \(provider) valid (\(http.statusCode))")
        return .valid
      case 400, 401, 403:
        DebugLogger.log("API-KEY-VALIDATION: \(provider) invalid (\(http.statusCode))")
        return .invalid
      default:
        DebugLogger.log("API-KEY-VALIDATION: \(provider) unverified (\(http.statusCode))")
        return .unverified
      }
    } catch {
      DebugLogger.log("API-KEY-VALIDATION: \(provider) unverified (network error: \(error.localizedDescription))")
      return .unverified
    }
  }
}
