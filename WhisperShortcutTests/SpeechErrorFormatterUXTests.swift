import Foundation
import Testing
@testable import WhisperShortcut_AppStore

@Suite("Speech error formatter UX")
struct SpeechErrorFormatterUXTests {

  @Test("An invalid API key names Settings → Accounts")
  func invalidAPIKeyNamesAccounts() {
    let text = SpeechErrorFormatter.format(.invalidAPIKey)
    #expect(text.contains("Settings → Accounts"))
    #expect(!text.contains("Authentication Error"))
    #expect(SpeechErrorFormatter.shortStatus(.invalidAPIKey).contains("Invalid API Key"))
  }

  @Test("A rejected recording does not say malformed or parameters")
  func invalidRequestIsPlainLanguage() {
    let text = SpeechErrorFormatter.format(.invalidRequest)
    #expect(text.contains("Settings → Dictate"))
    #expect(!text.localizedCaseInsensitiveContains("malformed"))
    #expect(!text.localizedCaseInsensitiveContains("parameters"))
  }

  @Test("API access denied points at Accounts or Dictate")
  func permissionDeniedIsActionable() {
    let text = SpeechErrorFormatter.format(.permissionDenied)
    #expect(text.contains("Settings → Accounts"))
    #expect(text.contains("Settings → Dictate"))
    #expect(!text.contains("this resource"))
  }

  @Test("A missing model says so instead of Resource Not Found")
  func notFoundNamesTheModel() {
    let text = SpeechErrorFormatter.format(.notFound)
    #expect(text.contains("Settings → Dictate"))
    #expect(!text.contains("Resource Not Found"))
  }

  @Test("A network timeout does not dump the raw error")
  func timeoutHidesRawDetails() {
    let text = SpeechErrorFormatter.format(.networkError("NSURLErrorDomain Code=-1001"))
    #expect(text.contains("Request Timed Out") || text.contains("timed out") || text.contains("did not finish"))
    #expect(!text.contains("NSURLErrorDomain"))
    #expect(!text.contains("Error:"))
  }

  @Test("Technical dumps are not shown as the user message")
  func technicalDumpIsSanitized() {
    #expect(SpeechErrorFormatter.looksTechnical(#"{"error":{"message":"nope"}}"#))
    #expect(SpeechErrorFormatter.looksTechnical("Error Domain=NSURLErrorDomain Code=-1009"))
    #expect(!SpeechErrorFormatter.looksTechnical("Check your internet connection and try again."))
    let dumped = SpeechErrorFormatter.formatForUser(
      NSError(domain: "NSURLErrorDomain", code: -1009, userInfo: [
        NSLocalizedDescriptionKey: #"{"error":"internal"}"#
      ]))
    #expect(dumped == "An error occurred. Please try again.")
  }
}

@Suite("Chat error formatter UX")
struct ChatErrorFormatterUXTests {

  @Test("A raw JSON network dump is not shown")
  func jsonDumpIsHidden() {
    let text = ChatErrorFormatter.friendlyError(
      TranscriptionError.networkError("Error Domain=NSURLErrorDomain Code=-1009"),
      provider: .gemini)
    #expect(text == "Gemini request failed. Please try again.")
    #expect(!text.contains("Error Domain="))
  }
}

@Suite("AppState copy")
struct AppStateCopyTests {

  @Test("Menu-bar copy uses Dictate Prompt and Read Aloud, not jargon")
  func processingCopyUsesProductNames() {
    #expect(AppState.ProcessingMode.prompting.statusText.contains("Dictate Prompt"))
    #expect(AppState.ProcessingMode.prompting.tooltip.contains("Dictate Prompt"))
    #expect(AppState.ProcessingMode.ttsProcessing.statusText.contains("Read Aloud"))
    #expect(AppState.ProcessingMode.ttsProcessing.tooltip.contains("Read Aloud"))
    #expect(!AppState.ProcessingMode.prompting.statusText.contains("AI prompt"))
    #expect(!AppState.ProcessingMode.ttsProcessing.statusText.contains("text-to-speech"))
  }

  @Test("The idle tooltip says the menu opens, not that a click records")
  func idleTooltipDescribesTheMenu() {
    #expect(AppState.idle.tooltip.contains("menu"))
    #expect(!AppState.idle.tooltip.localizedCaseInsensitiveContains("click to record"))
  }
}
