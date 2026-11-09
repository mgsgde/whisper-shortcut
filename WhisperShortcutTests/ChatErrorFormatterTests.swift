import Testing
import Foundation
@testable import WhisperShortcut_AppStore

/// User-facing chat error strings.
///
/// These lived on `ChatViewModel` and had never been tested. Pulling `ChatErrorFormatter` out
/// (R40) is what made them reachable without standing up the view model.
@Suite("Chat error formatter")
struct ChatErrorFormatterTests {

  struct FriendlyCase: Sendable {
    enum Kind: Sendable { case invalidAPIKey, gemini503, notConnected }
    let note: String
    let kind: Kind
    let provider: ChatModelProvider
    let expected: String
  }

  @Test("Friendly chat errors name the failure, not the raw transport text", arguments: [
    FriendlyCase(
      note: "invalid API key names Settings",
      kind: .invalidAPIKey, provider: .gemini,
      expected: "Invalid API key. Please check your API key in Settings."),
    FriendlyCase(
      note: "mapped provider HTTP 503",
      kind: .gemini503, provider: .gemini,
      expected: "Gemini is temporarily unavailable. Please try again in a few seconds."),
    FriendlyCase(
      note: "lost connection is a network message",
      kind: .notConnected, provider: .openai,
      expected: "No internet connection. Please check your network and try again."),
  ])
  func friendlyError(_ row: FriendlyCase) {
    let error: Error
    switch row.kind {
    case .invalidAPIKey:
      error = TranscriptionError.invalidAPIKey
    case .gemini503:
      error = ChatProviderHTTPError.map(provider: "Gemini", status: 503, body: "unavailable")
    case .notConnected:
      error = URLError(.notConnectedToInternet)
    }
    #expect(ChatErrorFormatter.friendlyError(error, provider: row.provider) == row.expected, "\(row.note)")
  }
}
