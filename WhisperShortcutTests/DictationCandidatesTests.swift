import Testing
import Foundation
@testable import WhisperShortcut_AppStore

@Suite("Dictation candidates (/improve review)")
struct DictationCandidatesTests {

  // MARK: - Helpers

  static let base = Date(timeIntervalSince1970: 1_800_000_000)

  static func stamp(_ offset: TimeInterval) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    f.timeZone = TimeZone(identifier: "UTC")
    return f.string(from: base.addingTimeInterval(offset))
  }

  static func entry(
    _ offset: TimeInterval, mode: String = "transcription", result: String? = nil,
    instruction: String? = nil, app: String? = nil
  ) -> InteractionLogEntry {
    InteractionLogEntry(
      ts: stamp(offset), mode: mode, model: nil, result: result, selectedText: nil,
      userInstruction: instruction, modelResponse: nil, text: nil, voice: nil,
      transcriptionModel: nil, hadScreenshot: nil, latencyMs: nil, provider: nil, loadMs: nil,
      context: InteractionContext(appName: app))
  }

  static func transcripts(_ texts: [String]) -> [InteractionLogEntry] {
    texts.enumerated().map { entry(TimeInterval($0.offset * 60), result: $0.element) }
  }

  static let stubUnknown: Set<String> = [
    "zorvex", "grogbot", "lauffer", "bianko", "grokbot", "cromwel",
  ]
  static func stubKnown(_ word: String) -> Bool {
    !stubUnknown.contains(GlossaryDocument.fold(word))
  }

  static let vectorRows = [
    "Frau Dr. Läufer hat angerufen.",
    "Ich habe Frau Dr. Läufer geschrieben.",
    "Warum wird Läufer immer falsch geschrieben?",
    "Wir nutzen Cloud Code für das Projekt.",
    "Cloud Code ist gut.",
    "Grogbot startet nicht.",
    "Die Seite lädt nicht.",
    "Die Seite ist neu.",
    "Termin mit Zorvex am Montag.",
    "Zorvex hat abgesagt.",
    "Zorvex kommt später.",
  ]
  static let vectorGlossary = "Terms: Läuffer, Grok Bot (not \"Grogbot\")"
  static let vectorHistory = [
    DictationCandidates.HistoryRow(
      ts: stamp(-3600), section: "whisper_glossary", added: [], removed: ["Seiter (not \"Seite\")"])
  ]

  static func glossaryRow(_ offset: TimeInterval, added: String) -> DictationCandidates.HistoryRow {
    DictationCandidates.HistoryRow(ts: stamp(offset), section: "whisper_glossary", added: [added], removed: [])
  }

  static func run(
    _ entries: [InteractionLogEntry], signals: [SignalLogEntry] = [], glossary: String = "",
    history: [DictationCandidates.HistoryRow] = [], apps: [String] = [], known: @escaping (String) -> Bool = { _ in true }
  ) -> [DictationCandidates.Candidate] {
    DictationCandidates.compute(
      entries: entries, signals: signals, glossary: glossary, history: history,
      appNames: apps, isKnownWord: known, now: base)
  }

  // MARK: - Shared vectors

  @Test("Shared vectors: exact order and fields")
  func sharedVectors() {
    let result = Self.run(
      Self.transcripts(Self.vectorRows), glossary: Self.vectorGlossary,
      history: Self.vectorHistory, known: Self.stubKnown)
    #expect(result.map(\.heard) == ["Läufer", "Cloud Code", "Zorvex"])
    #expect(result.map(\.source) == [.selfComplaint, .soundsLikeKnown, .unknownRecurring])
    #expect(result.map(\.suggested) == ["Läuffer", "Claude Code", nil])
    #expect(result.map(\.count) == [3, 2, 3])
    #expect(result.map(\.alsoHeard) == [[], [], []])
    // row_ids: newest first, the ts of the rows containing the spelling.
    #expect(result[0].rowIds == [Self.stamp(120), Self.stamp(60), Self.stamp(0)])
    #expect(result[1].rowIds == [Self.stamp(240), Self.stamp(180)])
    #expect(result[2].rowIds == [Self.stamp(600), Self.stamp(540), Self.stamp(480)])
    #expect(!result.contains { $0.heard == "Grogbot" })
    #expect(!result.contains { $0.heard == "Seite" })
    let json = result[2].json
    #expect(json["suggested"] is NSNull)
    #expect(json["source"] as? String == "unknown_recurring")
    #expect(json["count"] as? Int == 3)
    #expect((json["row_ids"] as? [String])?.count == 3)
    #expect((json["also_heard"] as? [String]) == [])
  }

  @Test("A line removed in config history keeps a word out")
  func removedSetDrops() {
    let rows = ["Zorvex ruft an.", "Zorvex schreibt.", "Zorvex kommt."]
    let with = Self.run(Self.transcripts(rows), known: Self.stubKnown)
    #expect(with.map(\.heard) == ["Zorvex"])
    let without = Self.run(Self.transcripts(rows), history: [DictationCandidates.HistoryRow(
        ts: Self.stamp(-60), section: "whisper_glossary", added: [], removed: ["Zorvex, Foo"])],
      known: Self.stubKnown)
    #expect(without.isEmpty)
  }

  @Test("A glossary rejected spelling is already handled")
  func rejectedSpellingDrops() {
    let rows = ["Zorvex ruft an.", "Zorvex schreibt.", "Zorvex kommt."]
    let result = Self.run(
      Self.transcripts(rows), glossary: "Zorvax (not \"Zorvex\")", known: Self.stubKnown)
    #expect(result.isEmpty)
  }

  @Test("retry_diff: a dictationRestart pair exposes the changed name")
  func retryDiff() {
    let entries = [
      Self.entry(0, result: "Ruf Cromwel an."),
      Self.entry(30, result: "Ruf Cromwell an."),
    ]
    let signal = SignalLogEntry(
      ts: Self.stamp(10), kind: "dictationRestart", refTs: Self.stamp(0), mode: "transcription",
      gapMs: 10_000, detail: nil)
    let result = Self.run(entries, signals: [signal], known: Self.stubKnown)
    #expect(result.count == 1)
    #expect(result[0].heard == "Cromwel")
    #expect(result[0].suggested == "Cromwell")
    #expect(result[0].source == .retryDiff)
    #expect(Self.run(entries, known: Self.stubKnown).isEmpty)
  }

  @Test("typed_correction from typed chat text; none for a copy of a dictation")
  func typedCorrection() {
    let dictated = [
      Self.entry(0, result: "Schick es an Cromwel."),
      Self.entry(60, result: "Cromwel hat geantwortet."),
    ]
    let typedRow = Self.entry(
      3600, mode: "geminiChat", instruction: "<typed_by_user>Mail an Cromwell schreiben</typed_by_user>")
    let hit = Self.run(dictated + [typedRow], known: Self.stubKnown)
    #expect(hit.count == 1)
    #expect(hit[0].heard == "Cromwel")
    #expect(hit[0].suggested == "Cromwell")
    #expect(hit[0].source == .typedCorrection)

    // The same words, but a copy of a transcription 30 s earlier: no typed text at all.
    let copyDictation = Self.entry(3590, result: "Mail an Cromwell schreiben")
    let copy = Self.entry(
      3620, mode: "geminiChat", instruction: "<pasted_content>Mail an Cromwell schreiben</pasted_content>")
    let none = Self.run(dictated + [copyDictation, copy], known: Self.stubKnown)
    #expect(!none.contains { $0.source == .typedCorrection })
  }

  @Test("At most five candidates, best first")
  func capOfFive() {
    var rows: [String] = []
    for name in ["Aldric", "Borvik", "Corvex", "Dunmar", "Eskand", "Falrik", "Gorvan"] {
      for _ in 0..<3 { rows.append("\(name) ruft an.") }
    }
    let result = Self.run(Self.transcripts(rows), known: { _ in false })
    #expect(result.count == 5)
    #expect(result.map(\.heard) == ["Aldric", "Borvik", "Corvex", "Dunmar", "Eskand"])
  }

  @Test("Vector B: a rejected spelling still dictated after its annotation")
  func vectorB() {
    let rows = Self.transcripts(["Grogbot startet nicht.", "Der Grogbot hängt."])
    let glossary = "Grok Bot (not \"Grogbot\")"
    let result = Self.run(
      rows, glossary: glossary, history: [Self.glossaryRow(-30, added: glossary)], known: Self.stubKnown)
    #expect(result.map(\.heard) == ["Grogbot"])
    #expect(result.map(\.source) == [.glossaryNotWorking])
    #expect(result.map(\.suggested) == ["Grok Bot"])
    #expect(result.map(\.count) == [2])
    let late = Self.run(
      rows, glossary: glossary, history: [Self.glossaryRow(100, added: glossary)], known: Self.stubKnown)
    #expect(late.isEmpty)
  }

  @Test("Vector C: the same word on both sides of a correction")
  func vectorC() {
    let rows = Self.transcripts(["Das ist Bianko, nicht Bianko, merk dir das."])
    let result = Self.run(rows, known: Self.stubKnown)
    #expect(result.map(\.heard) == ["Bianko"])
    #expect(result.map(\.source) == [.selfComplaint])
    #expect(result.map(\.suggested) == [nil])
    #expect(result.map(\.count) == [1])
  }

  @Test("A suggestion that differs only in case, spacing or punctuation is dropped")
  func compactEqualSuggestionDropped() {
    #expect(DictationCandidates.compact("sabaki dance") == DictationCandidates.compact("sabaki.dance"))
    #expect(DictationCandidates.compact("Datev") == DictationCandidates.compact("DATEV"))
    let rows = Self.transcripts(["Sabakidance ist falsch geschrieben."])
    let result = Self.run(
      rows, glossary: "sabaki.dance",
      known: { GlossaryDocument.fold($0) != "sabakidance" })
    #expect(result.isEmpty)
  }

  @Test("A known single-token heard is never a sounds_like_known candidate")
  func knownSingleTokenHeardDropped() {
    let rows = Self.transcripts(["Das braucht Zeit.", "Er braucht Hilfe."])
    let result = Self.run(rows, glossary: "Parakeet", known: Self.stubKnown)
    #expect(result.isEmpty)
    // Control: the same shape with an unknown heard word stays.
    let control = Self.run(
      Self.transcripts(["Zorvex ruft an.", "Zorvex schreibt."]), glossary: "Zorvax", known: Self.stubKnown)
    #expect(control.map(\.heard) == ["Zorvex"])
    #expect(control.map(\.suggested) == ["Zorvax"])
  }

  @Test("A suggestion the user removed in config history is dropped")
  func removedSuggestionDropped() {
    let rows = Self.transcripts(["Zorvex ruft an.", "Zorvex schreibt."])
    let history = [DictationCandidates.HistoryRow(
      ts: Self.stamp(-3600), section: "whisper_glossary", added: [], removed: ["Zorvax"])]
    let result = Self.run(rows, glossary: "Zorvax", history: history, known: Self.stubKnown)
    #expect(result.isEmpty)
  }

  @Test("A group is unknown when an unknown spelling has two rows, although the top spelling is known")
  func unknownSpellingFallback() {
    let rows = Self.transcripts(Array(repeating: "AutoMagic läuft.", count: 4)
      + Array(repeating: "Automagic läuft.", count: 2))
    let result = Self.run(rows, known: { $0 != "Automagic" })
    #expect(result.map(\.heard) == ["AutoMagic"])
    #expect(result.map(\.source) == [.unknownRecurring])
    #expect(result.map(\.count) == [6])
  }

  @Test("A spelling group holding a rejected spelling is dropped")
  func variantGroupWithRejectedSpelling() {
    let rows = Self.transcripts(["Grokbot geht.", "Grogbot geht.", "Grokbot läuft."])
    let result = Self.run(rows, glossary: "Grok Bot (not \"Grogbot\")", known: Self.stubKnown)
    #expect(!result.contains { $0.heard == "Grokbot" })
  }

  @Test("Kölner Phonetik")
  func cologne() {
    #expect(DictationCandidates.cologne("Claude") == DictationCandidates.cologne("Cloud"))
    #expect(DictationCandidates.cologne("Müller-Lüdenscheidt") == "65752682")
    #expect(DictationCandidates.cologne("Läufer") == DictationCandidates.cologne("Läuffer"))
  }

  // MARK: - Review wiring

  @Test("review carries dictation_candidates only when usage data is on")
  func reviewKey() {
    let f = SettingsAdvisorTests.Fixture()
    f.setAllGood()
    let stub: () -> [[String: Any]] = { [["heard": "Zorvex"]] }
    func review(_ f: SettingsAdvisorTests.Fixture) -> [String: Any] {
      AppSettingsChatTool.execute(
        args: ["action": "review"], catalog: f.catalog, deps: f.deps,
        suppressions: f.suppressions, candidates: stub)
    }
    let on = review(f)
    #expect(on["usage_data"] as? String == "on")
    #expect((on["dictation_candidates"] as? [[String: Any]])?.count == 1)

    f.defaults.set(false, forKey: UserDefaultsKeys.contextLoggingEnabled)
    let off = review(f)
    #expect(off["usage_data"] as? String == "off")
    #expect(off["dictation_candidates"] == nil)
  }
}
