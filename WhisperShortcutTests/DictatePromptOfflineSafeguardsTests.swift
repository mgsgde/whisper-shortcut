import Testing
import Foundation
@testable import WhisperShortcut_AppStore

/// The app-side half of the Offline Mode Dictate Prompt safeguards: greedy decoding on the
/// on-device providers, and the warning that lists words the dictation does not contain.
/// The word check itself is pinned in `DictationFidelityCheckTests`.
@Suite("Dictate Prompt offline safeguards")
struct DictatePromptOfflineSafeguardsTests {

  @Test("Offline Mode decodes greedily; otherwise the model keeps its default temperature")
  func temperatureFollowsOfflineMode() {
    let offline = SpeechService.localPromptOptions(offlineMode: true)
    #expect(offline.temperature == 0)
    // Everything else stays the text-transform request it always was.
    #expect(offline.reusablePromptPrefix == ChatRequestOptions.textTransform.reusablePromptPrefix)
    #expect(offline.disableBuiltInTools == ChatRequestOptions.textTransform.disableBuiltInTools)

    #expect(SpeechService.localPromptOptions(offlineMode: false).temperature == nil)
  }

  @Test("The local server receives the temperature only when one is set")
  func localServerBodyCarriesTemperature() {
    let greedy = LocalLLMChatProvider.requestBody(
      model: "m", messages: [], stream: true, maxTokens: 10, temperature: 0)
    #expect(greedy["temperature"] as? Double == 0)

    let unset = LocalLLMChatProvider.requestBody(
      model: "m", messages: [], stream: true, maxTokens: 10)
    #expect(unset["temperature"] == nil)
  }

  @Test("Warning names the words and says the text was delivered unchanged")
  func warningMessage() {
    let pasted = PopupNotificationWindow.undictatedWordsMessage(
      ["Mobilisation", "Termin"], pasteHint: nil)
    #expect(pasted == "Mobilisation, Termin\nPasted unchanged. Check these words before you save the note.")

    let copied = PopupNotificationWindow.undictatedWordsMessage(
      ["Mobilisation"], pasteHint: "Copied — press ⌘V to paste")
    #expect(copied.contains("Copied unchanged — press ⌘V to paste."))
  }

  @Test("A long list is cut so the advice after it stays visible")
  func warningMessageCapsTheList() {
    let words = (1...11).map { "Wort\($0)" }
    let message = PopupNotificationWindow.undictatedWordsMessage(words, pasteHint: nil, limit: 8)
    #expect(message.hasPrefix("Wort1, Wort2, Wort3, Wort4, Wort5, Wort6, Wort7, Wort8 +3 more\n"))
    #expect(!message.contains("Wort9"))
  }
}
