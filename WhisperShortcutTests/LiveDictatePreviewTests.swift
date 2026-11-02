import Testing
@testable import WhisperShortcut_AppStore

/// Slice S1 of plans/active/live-dictate-preview.md: who gets the live text panel, and how
/// sliding-window hypotheses become committed + tentative text without repeated words.
@Suite("Live dictate preview")
struct LiveDictatePreviewTests {

  // MARK: - Setting and eligibility

  @Test("The option is off by default")
  func offByDefault() {
    #expect(SettingsDefaults.liveDictatePreview == false)
  }

  @Test("Available for a downloaded Parakeet only")
  func availableForDownloadedParakeet() {
    #expect(LiveDictatePreviewSetting.isLivePreviewAvailable(model: .parakeetUltra, downloaded: true))
    #expect(!LiveDictatePreviewSetting.isLivePreviewAvailable(model: .parakeetUltra, downloaded: false))
  }

  @Test("Never available for Whisper or any cloud model, downloaded or not")
  func unavailableForEveryOtherModel() {
    for model in TranscriptionModel.allCases where model.offlineModelType?.engine != .parakeet {
      for downloaded in [true, false] {
        #expect(
          !LiveDictatePreviewSetting.isLivePreviewAvailable(model: model, downloaded: downloaded),
          "\(model.rawValue) must not offer live text")
      }
    }
  }

  @Test("Starts only when the toggle is on and the model is available")
  func startDecision() {
    #expect(LiveDictatePreviewSetting.shouldStart(enabled: true, model: .parakeetUltra, downloaded: true))
    #expect(!LiveDictatePreviewSetting.shouldStart(enabled: false, model: .parakeetUltra, downloaded: true))
    #expect(!LiveDictatePreviewSetting.shouldStart(enabled: true, model: .parakeetUltra, downloaded: false))
    for model in TranscriptionModel.allCases where model.offlineModelType?.engine != .parakeet {
      #expect(!LiveDictatePreviewSetting.shouldStart(enabled: true, model: model, downloaded: true))
    }
  }

  // MARK: - Merger

  @Test("Unconfirmed windows extend the tentative tail")
  func unconfirmedWindowsAppend() {
    var merger = LiveTranscriptMerger()
    merger.ingest("Der Patient", isConfirmed: false)
    merger.ingest("klagt über Schmerzen", isConfirmed: false)
    #expect(merger.committedText == "")
    #expect(merger.tentativeText == "Der Patient klagt über Schmerzen")
  }

  @Test("A confirmed window commits the previous tail and becomes the new tail")
  func confirmedWindowPromotes() {
    var merger = LiveTranscriptMerger()
    merger.ingest("Der Patient", isConfirmed: false)
    merger.ingest("klagt über", isConfirmed: false)
    merger.ingest("Schmerzen im Knie.", isConfirmed: true)
    #expect(merger.committedText == "Der Patient klagt über")
    #expect(merger.tentativeText == "Schmerzen im Knie.")
    merger.ingest("Seit drei Tagen.", isConfirmed: true)
    #expect(merger.committedText == "Der Patient klagt über Schmerzen im Knie.")
    #expect(merger.tentativeText == "Seit drei Tagen.")
  }

  @Test("The re-decoded last word is not repeated, and the newer form wins")
  func reDecodedWordIsNotRepeated() {
    var merger = LiveTranscriptMerger()
    merger.ingest("Der Befund ist", isConfirmed: false)
    merger.ingest("ist unauffällig", isConfirmed: false)
    #expect(merger.tentativeText == "Der Befund ist unauffällig")

    // Case and punctuation do not hide the overlap; the newer punctuation is kept.
    merger.ingest("Unauffällig. Keine Schwellung", isConfirmed: false)
    #expect(merger.tentativeText == "Der Befund ist Unauffällig. Keine Schwellung")
  }

  @Test("An overlap of several words is removed once")
  func multiWordOverlap() {
    var merger = LiveTranscriptMerger()
    merger.ingest("Röntgen des rechten Kniegelenks", isConfirmed: false)
    merger.ingest("rechten Kniegelenks in zwei Ebenen", isConfirmed: false)
    #expect(merger.tentativeText == "Röntgen des rechten Kniegelenks in zwei Ebenen")
  }

  @Test("A cut-off last word is replaced by its longer re-decode")
  func cutOffWordIsReplaced() {
    var merger = LiveTranscriptMerger()
    merger.ingest("Der Pat", isConfirmed: false)
    merger.ingest("Patient wurde aufgenommen", isConfirmed: false)
    #expect(merger.tentativeText == "Der Patient wurde aufgenommen")
  }

  @Test("Overlap is removed before a confirmed window promotes the tail")
  func overlapBeforePromotion() {
    var merger = LiveTranscriptMerger()
    merger.ingest("Diagnose", isConfirmed: false)
    merger.ingest("Gonarthrose rechts", isConfirmed: true)
    // committed: "Diagnose", tentative: "Gonarthrose rechts"
    merger.ingest("rechts. Therapie", isConfirmed: true)
    #expect(merger.committedText == "Diagnose Gonarthrose")
    #expect(merger.tentativeText == "rechts. Therapie")
  }

  @Test("Retiring reaches into committed text when the tail is shorter than the overlap")
  func retireIntoCommitted() {
    var merger = LiveTranscriptMerger()
    merger.ingest("eins zwei", isConfirmed: false)
    merger.ingest("drei", isConfirmed: true)
    // committed: "eins zwei", tentative: "drei"
    merger.ingest("zwei drei vier", isConfirmed: false)
    #expect(merger.committedText == "eins")
    #expect(merger.tentativeText == "zwei drei vier")
  }

  @Test("Text without overlap is appended unchanged")
  func noFalseOverlap() {
    var merger = LiveTranscriptMerger()
    merger.ingest("Wir sehen uns", isConfirmed: false)
    merger.ingest("in Innsbruck", isConfirmed: false)
    #expect(merger.tentativeText == "Wir sehen uns in Innsbruck")
  }

  @Test("Empty windows change nothing but still confirm")
  func emptyWindows() {
    var merger = LiveTranscriptMerger()
    merger.ingest("", isConfirmed: false)
    #expect(merger.isEmpty)
    merger.ingest("Hallo", isConfirmed: false)
    merger.ingest("   ", isConfirmed: false)
    #expect(merger.tentativeText == "Hallo")
    merger.ingest("", isConfirmed: true)
    #expect(merger.committedText == "Hallo")
    #expect(merger.tentativeText == "")
  }

  @Test("Overlap is capped, so a phrase repeated long ago is kept")
  func overlapIsCapped() {
    let phrase = (1...LiveTranscriptMerger.maxOverlapWords + 1).map { "w\($0)" }
    // The whole phrase repeats, but only an overlap longer than the cap would match it.
    #expect(LiveTranscriptMerger.wordsToRetire(existingTail: phrase, incoming: phrase) == 0)
  }

  @Test("Pure punctuation never counts as overlap")
  func punctuationIsNotOverlap() {
    #expect(LiveTranscriptMerger.wordsToRetire(existingTail: ["Knie", "–"], incoming: ["–", "rechts"]) == 0)
  }
}
