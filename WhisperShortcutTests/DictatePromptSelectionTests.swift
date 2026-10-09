import Foundation
import Testing

@testable import WhisperShortcut_AppStore

/// Dictate Prompt must never treat a stale clipboard as the selection: in a practice the leftover
/// can be the previous patient's note. These pin the decisions that keep it out.
@Suite("Dictate Prompt selection")
struct DictatePromptSelectionTests {

  @Test("The synthetic ⌘C counts only when the pasteboard changed")
  func copyCountsOnlyWhenPasteboardChanged() {
    #expect(DictatePromptSelectionDecision.copyProducedSelection(changeCountBefore: 41, changeCountAfter: 42))
    // Nothing selected: ⌘C copies nothing, the pasteboard keeps the old copy — not a selection.
    #expect(!DictatePromptSelectionDecision.copyProducedSelection(changeCountBefore: 41, changeCountAfter: 41))
  }

  @Test("App Store clipboard path: a copy the user just made is a selection")
  func freshUserCopyIsSelection() {
    #expect(DictatePromptSelectionDecision.clipboardIsFreshSelection(
      currentChangeCount: 12, lastConsumedChangeCount: 10, lastOwnWriteChangeCount: 11))
    #expect(DictatePromptSelectionDecision.clipboardIsFreshSelection(
      currentChangeCount: 12, lastConsumedChangeCount: 10, lastOwnWriteChangeCount: nil))
  }

  @Test("App Store clipboard path: an unchanged clipboard is not a selection")
  func unchangedClipboardIsNotSelection() {
    // The last run (or app launch) already took its decision on this exact pasteboard state.
    #expect(!DictatePromptSelectionDecision.clipboardIsFreshSelection(
      currentChangeCount: 10, lastConsumedChangeCount: 10, lastOwnWriteChangeCount: nil))
  }

  @Test("App Store clipboard path: the app's own result copy is not a selection")
  func ownWriteIsNotSelection() {
    #expect(!DictatePromptSelectionDecision.clipboardIsFreshSelection(
      currentChangeCount: 11, lastConsumedChangeCount: 10, lastOwnWriteChangeCount: 11))
  }

  @Test("Copied text is trimmed; whitespace-only counts as nothing")
  func selectionTextNormalised() {
    #expect(DictatePromptSelectionDecision.selectionText(from: "  Befund \n") == "Befund")
    #expect(DictatePromptSelectionDecision.selectionText(from: " \n\t") == nil)
    #expect(DictatePromptSelectionDecision.selectionText(from: nil) == nil)
  }

  @Test("A capture awaited before the copy finishes gets the copy's result")
  func captureResolvesWaiters() async {
    let capture = DictatePromptSelectionCapture()
    async let awaited = capture.value()
    try? await Task.sleep(for: .milliseconds(20))
    capture.resolve("  selected  ")
    #expect(await awaited == "selected")
    // First resolution wins: a late poll result cannot replace the decision.
    capture.resolve("other")
    #expect(await capture.value() == "selected")
  }

  @Test("A capture with nothing copied resolves to nil (compose)")
  func emptyCaptureIsCompose() async {
    #expect(await DictatePromptSelectionCapture.resolved(nil).value() == nil)
    #expect(await DictatePromptSelectionCapture.resolved("").value() == nil)
  }

  @Test("No selection and no screenshot is a compose turn; a screenshot run never is")
  func composeTurnDecision() {
    #expect(SpeechService.isComposeTurn(usesScreenshotSelection: false, selectedText: nil))
    #expect(!SpeechService.isComposeTurn(usesScreenshotSelection: false, selectedText: "Befund"))
    #expect(!SpeechService.isComposeTurn(usesScreenshotSelection: true, selectedText: nil))
  }

  @Test("A compose turn sends no earlier turns as history")
  func composeTurnHasNoHistory() {
    PromptConversationHistory.shared.append(
      mode: .togglePrompting, selectedText: "Previous patient's note",
      userInstruction: "shorten", modelResponse: "Short note")
    defer { PromptConversationHistory.shared.clear(mode: .togglePrompting) }
    #expect(SpeechService.promptHistoryContents(mode: .togglePrompting, isComposeTurn: true).isEmpty)
    #expect(!SpeechService.promptHistoryContents(mode: .togglePrompting, isComposeTurn: false).isEmpty)
  }

  @Test("The output rule tells the model what a compose turn means")
  func outputRuleCoversCompose() {
    #expect(AppConstants.promptModeOutputRule.contains("NO SELECTED TEXT"))
    #expect(AppConstants.dictatePromptComposeMarker.hasPrefix("NO SELECTED TEXT"))
  }
}
