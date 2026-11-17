import Testing
@testable import WhisperShortcut_AppStore

@Suite("Quick-action ↩ decision")
struct QuickActionReturnTests {

  private func decide(
    visible: Bool = true, templateBound: Bool = false, pickerCount: Int = 0, pickerIndex: Int = 0,
    typed: String = "", selected: Int? = nil, actionCount: Int = 3
  ) -> QuickActionReturn {
    RecordingIndicatorModel.returnAction(
      isVisible: visible, templateBound: templateBound, pickerChoiceCount: pickerCount,
      pickerIndex: pickerIndex, typedPrompt: typed, selectedIndex: selected, actionCount: actionCount)
  }

  @Test("A card that is not up leaves ↩ alone, whatever else is set")
  func hiddenCardIsNotHandled() {
    #expect(decide(visible: false) == .notHandled)
    #expect(decide(visible: false, templateBound: true, pickerCount: 2, typed: "x", selected: 1) == .notHandled)
  }

  @Test("An open template picker takes the highlighted template")
  func pickerChoosesTemplate() {
    #expect(decide(templateBound: true, pickerCount: 3, pickerIndex: 2) == .chooseTemplate(2))
    #expect(decide(templateBound: true, pickerCount: 2, pickerIndex: 0, typed: "x", selected: 1) == .chooseTemplate(0))
  }

  @Test("A bound template with no picker stops, even over typed text or a highlighted entry")
  func boundTemplateStops() {
    #expect(decide(templateBound: true) == .stopAndProcess)
    #expect(decide(templateBound: true, typed: "x", selected: 1) == .stopAndProcess)
  }

  @Test("Typed text runs first, and a lone space or newline is not an instruction")
  func typedTextWins() {
    #expect(decide(typed: "shorter") == .runTyped)
    #expect(decide(typed: "shorter", selected: 1) == .runTyped)
    #expect(decide(typed: "  \n ") == .stopAndProcess)
    #expect(decide(typed: " ", selected: 2) == .runAction(2))
  }

  @Test("A highlighted entry runs; none (or out of range) stops")
  func highlightedEntryRuns() {
    #expect(decide(selected: 0) == .runAction(0))
    #expect(decide(selected: 2) == .runAction(2))
    #expect(decide(selected: nil) == .stopAndProcess)
    #expect(decide(selected: 3) == .stopAndProcess)
    #expect(decide(selected: -1) == .stopAndProcess)
    #expect(decide(selected: 0, actionCount: 0) == .stopAndProcess)
  }
}
