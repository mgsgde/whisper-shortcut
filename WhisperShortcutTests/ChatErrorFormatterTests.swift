import Testing
import Foundation
@testable import WhisperShortcut_AppStore

/// User-facing chat error strings.
///
/// These lived on `ChatViewModel` and had never been tested. Pulling `ChatErrorFormatter` out
/// (R40) is what made them reachable without standing up the view model.
@Suite("Chat error formatter")
struct ChatErrorFormatterTests {

  @Test("An invalid API key names Settings")
  func invalidAPIKey() {
    let text = ChatErrorFormatter.friendlyError(TranscriptionError.invalidAPIKey, provider: .gemini)
    #expect(text == "Invalid API key. Please check your API key in Settings.")
  }

  @Test("A mapped provider HTTP 503 is the temporary-unavailable message")
  func mappedServerError() {
    let error = ChatProviderHTTPError.map(provider: "Gemini", status: 503, body: "unavailable")
    let text = ChatErrorFormatter.friendlyError(error, provider: .gemini)
    #expect(text == "Gemini is temporarily unavailable. Please try again in a few seconds.")
  }

  @Test("A lost connection is a network message, not the URL error text")
  func urlErrorNotConnected() {
    let text = ChatErrorFormatter.friendlyError(
      URLError(.notConnectedToInternet), provider: .openai)
    #expect(text == "No internet connection. Please check your network and try again.")
  }

  @Test("Every ChatModelProvider case has its display name")
  func providerDisplayNames() {
    for provider in ChatModelProvider.allCases {
      #expect(ChatErrorFormatter.chatProviderDisplayName(provider) == expectedName(provider))
    }
  }

  /// Compile-fails if a `ChatModelProvider` case is added without a name here.
  private func expectedName(_ provider: ChatModelProvider) -> String {
    switch provider {
    case .gemini: return "Gemini"
    case .grok: return "Grok"
    case .openai: return "OpenAI"
    case .anthropic: return "Claude"
    case .customOpenAI: return "Custom endpoint"
    case .local: return "Local LLM"
    case .localMLX: return "On-device LLM"
    }
  }
}
