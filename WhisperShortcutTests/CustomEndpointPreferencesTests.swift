import Testing
import Foundation
@testable import WhisperShortcut_AppStore

/// Pins the one-time fold of a legacy Dictate transcription URL into the shared custom endpoint,
/// and that Dictate Prompt treats that endpoint as a text-only model.
@Suite("Shared custom endpoint preferences")
struct CustomEndpointPreferencesTests {

  private typealias Prefs = CustomEndpointPreferences
  private typealias Plan = CustomEndpointPreferences.LegacyMigrationPlan

  private func plan(
    chatBaseURL: String? = nil,
    chatKey: String? = nil,
    transcriptionURL: String? = nil,
    transcriptionToken: String? = nil
  ) -> Plan? {
    Prefs.legacyMigrationPlan(
      chatBaseURL: chatBaseURL,
      chatKey: chatKey,
      transcriptionURL: transcriptionURL,
      transcriptionToken: transcriptionToken)
  }

  // MARK: - (a) nothing to migrate

  @Test("No transcription URL means nothing to do")
  func noTranscriptionURL() {
    for transcriptionURL: String? in [nil, "", "   "] {
      #expect(plan(chatBaseURL: "https://example.com/v1", transcriptionURL: transcriptionURL) == nil)
    }
  }

  // MARK: - (b) only a derivable /audio/transcriptions URL moves

  @Test(
    "A URL that is not {base}/audio/transcriptions stays an override",
    arguments: [
      "https://example.com",
      "https://example.com/",
      "https://example.com/asr",
      "https://example.com/v1",
      "https://example.com/audio/transcriptions/extra",
    ])
  func nonDerivableURLStays(transcriptionURL: String) {
    #expect(plan(transcriptionURL: transcriptionURL, transcriptionToken: "legacy") == nil)
  }

  // MARK: - (c) no chat base yet: adopt the derived base

  @Test("A derivable URL with no chat base becomes the shared base, and a trailing slash is stripped")
  func adoptsDerivedBase() {
    #expect(
      plan(transcriptionURL: "https://example.com/v1/audio/transcriptions/")
        == Plan(newChatBaseURL: "https://example.com/v1", newChatKey: nil, clearLegacyTranscription: true))
    #expect(
      plan(
        transcriptionURL: "  https://example.com/v1/audio/transcriptions  ",
        transcriptionToken: "  ")
        == Plan(newChatBaseURL: "https://example.com/v1", newChatKey: nil, clearLegacyTranscription: true))
  }

  @Test("A query string survives stripping /audio/transcriptions, including a trailing slash")
  func queryStringSurvives() {
    let expected = Plan(
      newChatBaseURL: "https://example.com/v1?api-version=x",
      newChatKey: "legacy-token",
      clearLegacyTranscription: true)
    #expect(
      plan(
        transcriptionURL: "https://example.com/v1/audio/transcriptions?api-version=x",
        transcriptionToken: "legacy-token")
        == expected)
    #expect(
      plan(
        transcriptionURL: "https://example.com/v1/audio/transcriptions/?api-version=x",
        transcriptionToken: "legacy-token")
        == expected)
  }

  @Test("An empty chat base is the same as none, and the legacy token is copied only when set")
  func emptyChatBaseAdoptsToken() {
    #expect(
      plan(chatBaseURL: "  ", transcriptionURL: "http://127.0.0.1:8080/v1/audio/transcriptions/")
        == Plan(newChatBaseURL: "http://127.0.0.1:8080/v1", newChatKey: nil, clearLegacyTranscription: true))
    #expect(
      plan(
        chatBaseURL: "",
        transcriptionURL: "http://127.0.0.1:8080/v1/audio/transcriptions",
        transcriptionToken: "sk-local")
        == Plan(newChatBaseURL: "http://127.0.0.1:8080/v1", newChatKey: "sk-local", clearLegacyTranscription: true))
  }

  // MARK: - (d) same base: clear the override, copy a key only when Chat has none

  @Test("The same base ignores scheme and host case and a trailing slash")
  func sameBaseClearsOverride() {
    let cleared = Plan(newChatBaseURL: nil, newChatKey: nil, clearLegacyTranscription: true)
    #expect(
      plan(
        chatBaseURL: "HTTPS://Example.COM/v1/",
        chatKey: "shared",
        transcriptionURL: "https://example.com/v1/audio/transcriptions",
        transcriptionToken: nil)
        == cleared)
    #expect(
      plan(
        chatBaseURL: "https://example.com/v1",
        chatKey: "shared",
        transcriptionURL: "https://example.com/v1/audio/transcriptions/",
        transcriptionToken: "shared")
        == cleared)
    #expect(
      plan(
        chatBaseURL: "https://example.com/v1?api-version=x",
        transcriptionURL: "https://example.com/v1/audio/transcriptions/?api-version=x")
        == cleared)
  }

  @Test("A matching base with no chat key adopts the legacy token")
  func sameBaseAdoptsMissingKey() {
    #expect(
      plan(
        chatBaseURL: "https://example.com/v1/",
        chatKey: "   ",
        transcriptionURL: "https://example.com/v1/audio/transcriptions",
        transcriptionToken: " legacy ")
        == Plan(newChatBaseURL: nil, newChatKey: "legacy", clearLegacyTranscription: true))
  }

  @Test("Two different keys on the same base keep the override")
  func differentKeysKeepOverride() {
    #expect(
      plan(
        chatBaseURL: "https://example.com/v1",
        chatKey: "chat-key",
        transcriptionURL: "https://example.com/v1/audio/transcriptions",
        transcriptionToken: "dictate-key")
        == nil)
  }

  // MARK: - (e) a different base keeps both

  @Test("A different host, path or query keeps the override")
  func differentBaseKeepsOverride() {
    let transcriptionURL = "https://example.com/v1/audio/transcriptions?api-version=x"
    #expect(plan(chatBaseURL: "https://other.example/v1", transcriptionURL: transcriptionURL) == nil)
    #expect(plan(chatBaseURL: "https://example.com/v1/extra", transcriptionURL: transcriptionURL) == nil)
    #expect(plan(chatBaseURL: "https://example.com/V1", transcriptionURL: "https://example.com/v1/audio/transcriptions") == nil)
    #expect(
      plan(chatBaseURL: "https://example.com/v1?api-version=y", transcriptionURL: transcriptionURL) == nil)
  }

  // MARK: - Dictate Prompt

  @Test("The custom endpoint can run Dictate Prompt and does not read a screenshot")
  func customEndpointIsTextOnlyDictatePrompt() {
    #expect(PromptModel.customOpenAIEndpoint.supportsDictatePrompt)
    #expect(PromptModel.customOpenAIEndpoint.dictatePromptUsesScreenshotSelection == false)
  }
}
