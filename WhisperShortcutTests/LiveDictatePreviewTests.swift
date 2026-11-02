import Testing
@testable import WhisperShortcut_AppStore

/// Slice S1 of plans/active/live-dictate-preview.md: who gets the live text panel, how its text is
/// cut for display, and how the preview's drift from the pasted text is counted.
@Suite("Live dictate preview")
struct LiveDictatePreviewTests {

  // MARK: - Setting and eligibility

  @Test("The option is off by default")
  func offByDefault() {
    #expect(SettingsDefaults.liveDictatePreview == false)
  }

  @Test("Available for a downloaded Parakeet on Apple Silicon only")
  func availableForDownloadedParakeet() {
    #expect(
      LiveDictatePreviewSetting.isLivePreviewAvailable(model: .parakeetUltra, downloaded: true, appleSilicon: true))
    #expect(
      !LiveDictatePreviewSetting.isLivePreviewAvailable(model: .parakeetUltra, downloaded: false, appleSilicon: true))
    #expect(
      !LiveDictatePreviewSetting.isLivePreviewAvailable(model: .parakeetUltra, downloaded: true, appleSilicon: false))
  }

  @Test("Never available for Whisper or any cloud model, downloaded or not")
  func unavailableForEveryOtherModel() {
    for model in TranscriptionModel.allCases where model.offlineModelType?.engine != .parakeet {
      for downloaded in [true, false] {
        #expect(
          !LiveDictatePreviewSetting.isLivePreviewAvailable(
            model: model, downloaded: downloaded, appleSilicon: true),
          "\(model.rawValue) must not offer live text")
      }
    }
  }

  @Test("Starts only when the toggle is on and the model is available")
  func startDecision() {
    #expect(
      LiveDictatePreviewSetting.shouldStart(
        enabled: true, model: .parakeetUltra, downloaded: true, appleSilicon: true))
    #expect(
      !LiveDictatePreviewSetting.shouldStart(
        enabled: false, model: .parakeetUltra, downloaded: true, appleSilicon: true))
    #expect(
      !LiveDictatePreviewSetting.shouldStart(
        enabled: true, model: .parakeetUltra, downloaded: false, appleSilicon: true))
    for model in TranscriptionModel.allCases where model.offlineModelType?.engine != .parakeet {
      #expect(
        !LiveDictatePreviewSetting.shouldStart(enabled: true, model: model, downloaded: true, appleSilicon: true))
    }
  }

  // MARK: - Display tail

  @Test("Short text is shown whole, with whitespace tidied")
  func shortTextUnchanged() {
    let shown = LiveDictatePreviewText.displayTail(
      committed: "Der  Patient\nklagt", tentative: " über Schmerzen ", maxCharacters: 800)
    #expect(shown.committed == "Der Patient klagt")
    #expect(shown.tentative == "über Schmerzen")
  }

  @Test("Long text keeps its end, cut at a word boundary, tentative part whole")
  func longTextKeepsTheEnd() {
    let committed = (1...200).map { "Wort\($0)" }.joined(separator: " ")
    let shown = LiveDictatePreviewText.displayTail(
      committed: committed, tentative: "noch offen", maxCharacters: 100)
    #expect(shown.tentative == "noch offen")
    #expect(shown.committed.hasPrefix("…Wort"))
    #expect(shown.committed.hasSuffix("Wort200"))
    // At most one character over the budget: the ellipsis.
    #expect(shown.committed.count + 1 + shown.tentative.count <= 101)
    // Whole words only: every word after the ellipsis is a real one.
    let words = shown.committed.dropFirst().split(separator: " ")
    #expect(words.allSatisfy { $0.hasPrefix("Wort") && Int($0.dropFirst(4)) != nil })
  }

  @Test("A tentative part longer than the budget is cut too")
  func longTentativeIsCut() {
    let tentative = (1...100).map { "w\($0)" }.joined(separator: " ")
    let shown = LiveDictatePreviewText.displayTail(committed: "Anfang", tentative: tentative, maxCharacters: 50)
    #expect(shown.committed == "")
    #expect(shown.tentative.hasPrefix("…w"))
    #expect(shown.tentative.hasSuffix("w100"))
    #expect(shown.tentative.count <= 51)
  }

  @Test("Empty text stays empty")
  func emptyText() {
    let shown = LiveDictatePreviewText.displayTail(committed: "", tentative: "  ")
    #expect(shown.committed.isEmpty && shown.tentative.isEmpty)
  }

  // MARK: - Drift

  @Test("Identical text has no drift, ignoring case and punctuation")
  func noDrift() {
    let drift = LiveDictatePreviewText.drift(
      preview: "der patient klagt über schmerzen", final: "Der Patient klagt über Schmerzen.")
    #expect(drift.previewWords == 5)
    #expect(drift.finalWords == 5)
    #expect(drift.editDistance == 0)
  }

  @Test("Missing tail words and a changed word are counted")
  func countsEdits() {
    // The preview lacks the last words before Stop and heard one word differently.
    let drift = LiveDictatePreviewText.drift(
      preview: "Röntgen des rechten Knies", final: "Röntgen des rechten Kniegelenks in zwei Ebenen")
    #expect(drift.previewWords == 4)
    #expect(drift.finalWords == 7)
    #expect(drift.editDistance == 4)  // 1 substitution + 3 insertions
  }

  @Test("Word edit distance basics")
  func editDistanceBasics() {
    #expect(LiveDictatePreviewText.editDistance([], ["a", "b"]) == 2)
    #expect(LiveDictatePreviewText.editDistance(["a", "b"], []) == 2)
    #expect(LiveDictatePreviewText.editDistance(["a", "b", "c"], ["a", "c"]) == 1)
    #expect(LiveDictatePreviewText.editDistance(["die", "die"], ["die"]) == 1)
  }
}
