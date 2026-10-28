import Foundation

/// User-facing chat error text.
///
/// Lifted out of `ChatViewModel` (R40). Neither function reads instance state.
enum ChatErrorFormatter {

  static func friendlyError(_ error: Error, provider: ChatModelProvider) -> String {
    let name = Self.chatProviderDisplayName(provider)
    // Its messages are already user-facing and specific (limit reached, sign-in expired, …).
    if let planError = error as? ChatGPTPlanError {
      return planError.errorDescription ?? String(localized: "ChatGPT request failed. Please try again.")
    }
    if let te = error as? TranscriptionError {
      switch te {
      case .invalidAPIKey, .incorrectAPIKey:
        return String(localized: "Invalid API key. Please check your API key in Settings.")
      case .rateLimited:
        return String(localized: "Rate limit reached. Please wait a moment and try again.")
      case .quotaExceeded:
        return String(localized: "API quota exceeded. Please try again later.")
      case .serverError, .serviceUnavailable:
        return String(localized: "\(name) is temporarily unavailable. Please try again in a few seconds.")
      case .networkError(let msg):
        let lower = msg.lowercased()
        if lower.contains("503") || lower.contains("unavailable")
          || lower.contains("502") || lower.contains("504") || lower.contains("500") {
          return String(localized: "\(name) is temporarily unavailable. Please try again in a few seconds.")
        }
        if msg.hasPrefix("{") || msg.contains("\"error\"") {
          if let extracted = ChatProviderHTTPError.message(from: msg) {
            return String(localized: "\(name) request failed: \(extracted)")
          }
          return String(localized: "\(name) request failed. Please try again.")
        }
        return msg
      case .fileError(let msg), .localModelFailed(let msg):
        return msg
      default:
        return String(localized: "Request failed. Please try again.")
      }
    }
    if let urlError = error as? URLError {
      switch urlError.code {
      case .notConnectedToInternet, .networkConnectionLost:
        return String(localized: "No internet connection. Please check your network and try again.")
      case .timedOut:
        return String(localized: "Request timed out. Please try again.")
      default:
        return String(localized: "Network error: \(urlError.localizedDescription)")
      }
    }
    return error.localizedDescription
  }

  static func chatProviderDisplayName(_ provider: ChatModelProvider) -> String {
    switch provider {
    case .gemini: return "Gemini"
    case .grok: return "Grok"
    case .openai: return "OpenAI"
    case .anthropic: return "Claude"
    case .customOpenAI: return String(localized: "Custom endpoint")
    case .openRouter: return "OpenRouter"
    case .chatGPTPlan: return String(localized: "ChatGPT plan")
    case .local: return String(localized: "Local LLM")
    case .localMLX: return String(localized: "On-device LLM")
    }
  }

}
