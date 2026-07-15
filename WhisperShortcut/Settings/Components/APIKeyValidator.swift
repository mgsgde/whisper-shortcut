import Foundation

/// The provider an API key belongs to.
enum APIKeyProvider {
  case google
  case openai
  case xai
  case anthropic
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
