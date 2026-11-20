import Foundation
import Testing
@testable import WhisperShortcut_AppStore

@Suite("Dictation report body")
struct DictationReportTests {

  private static func date(_ iso: String) -> Date {
    ISO8601DateFormatter().date(from: iso)!
  }

  private static func localString(_ d: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
    return f.string(from: d)
  }

  @Test("Full entry produces the exact body")
  func fullEntry() {
    let ts = Self.date("2026-10-27T16:27:41Z")
    let entry = TranscriptionHistoryStore.Entry(
      ts: ts, text: "Hallo Joschka, wir nutzen SumUp.", mode: "Dictation",
      transcriptionModel: "gemini-3.5-flash-lite", transcriptionModelName: "Gemini 3.5 Flash Lite",
      glossaryEchoRemoved: ["Joschka SumUp"])
    let body = DictationReport.body(
      entry: entry, glossaryTerms: ["Joschka", "SumUp", "Private Name"], offlineMode: false)
    #expect(
      body == """
        Pasted text:
        Hallo Joschka, wir nutzen SumUp.

        Dictated: \(Self.localString(ts))
        Mode: Dictation
        Transcription model: Gemini 3.5 Flash Lite (gemini-3.5-flash-lite)
        Glossary: 3 terms. In this text: Joschka, SumUp
        Offline Mode: off
        """)
    #expect(DictationReport.technicalLines(entry: entry) == "Glossary echo removed: \"Joschka SumUp\"")
    #expect(!body.contains("Glossary echo removed"))
  }

  @Test("Old entry omits mode, model and echo lines")
  func oldEntry() {
    let entry = TranscriptionHistoryStore.Entry(ts: Date(), text: "Hallo")
    let body = DictationReport.body(entry: entry, glossaryTerms: ["Foo"], offlineMode: true)
    #expect(!body.contains("Mode: Dictation"))
    #expect(!body.contains("Transcription model"))
    #expect(!body.contains("Glossary echo"))
    #expect(DictationReport.technicalLines(entry: entry).isEmpty)
    #expect(body.contains("Glossary: 1 terms. None in this text."))
    #expect(body.hasSuffix("Offline Mode: on"))
  }

  @Test("Terms are matched case- and diacritic-insensitively, multi-word as a sequence")
  func termDetection() {
    let entry = TranscriptionHistoryStore.Entry(
      ts: Date(), text: "joschka schrieb Herrn MULLER wegen Claude Code, nicht Claude.")
    let body = DictationReport.body(
      entry: entry, glossaryTerms: ["Joschka", "Müller", "Claude Code", "Code Claude", "Secret"],
      offlineMode: false)
    #expect(body.contains("Glossary: 5 terms. In this text: Joschka, Müller, Claude Code"))
    #expect(!body.contains("Secret"))
  }

  @Test("Empty glossary and empty echo list")
  func emptyCases() {
    let entry = TranscriptionHistoryStore.Entry(
      ts: Date(), text: "Hallo", glossaryEchoRemoved: [])
    let body = DictationReport.body(entry: entry, glossaryTerms: [], offlineMode: false)
    let technical = DictationReport.technicalLines(entry: entry)
    #expect(body.contains("Glossary: empty"))
    #expect(technical == "Glossary echo removed: none")
    #expect(!body.contains("Glossary echo"))
    #expect(!body.contains("Template:"))
    #expect(!body.contains("Audio length:"))
    #expect(!body.contains("Prompt sent:"))
    #expect(!technical.contains("Prompt sent:"))
    #expect(!body.contains("App version at dictation:"))
    #expect(!body.contains("Settings changed"))
    #expect(!body.contains("Model output before cleanup:"))
  }

  @Test("New lines appear only for the fields that are present")
  func traceLines() {
    let present = TranscriptionHistoryStore.Entry(
      ts: Date(), text: "Lumbarroll", mode: "Template",
      rawOutput: "Lumbarroll\nA firm foam roll for the lower back.",
      audioDurationSeconds: 3.5, templateName: "SOAP",
      promptChars: 120, promptHash: "abc123def456",
      configHash: "111111111111", appVersion: "9.9.9")
    let shown = DictationReport.body(
      entry: present, glossaryTerms: [], offlineMode: false,
      currentConfigHash: "222222222222")
    let technical = DictationReport.technicalLines(entry: present)
    #expect(shown.contains("Template: SOAP"))
    #expect(shown.contains("Audio length: 3.5 s"))
    #expect(!shown.contains("Prompt sent:"))
    #expect(technical == "Prompt sent: 120 chars, hash abc123def456")
    #expect(shown.contains("App version at dictation: 9.9.9"))
    #expect(shown.contains("Note: settings were changed after this dictation"))
    #expect(shown.contains("Model output before cleanup:"))
    #expect(shown.contains("Lumbarroll\nA firm foam roll for the lower back."))

    let sameHash = DictationReport.body(
      entry: present, glossaryTerms: [], offlineMode: false,
      currentConfigHash: "111111111111")
    #expect(!sameHash.contains("Settings changed"))

    let unchanged = TranscriptionHistoryStore.Entry(
      ts: Date(), text: "Lumbarroll", rawOutput: "Lumbarroll",
      configHash: "111111111111")
    let hidden = DictationReport.body(
      entry: unchanged, glossaryTerms: [], offlineMode: false, currentConfigHash: nil)
    #expect(!hidden.contains("Model output before cleanup:"))
    #expect(!hidden.contains("Settings changed"))
    #expect(!hidden.contains("Template:"))
  }

  @Test("Ten history entries become ten dictation candidates, newest first, with unique ids")
  func tenDictationCandidates() {
    var entries: [TranscriptionHistoryStore.Entry] = []
    for index in 0..<10 {
      let mode = index == 3 ? "Template" : "Dictation"
      let name: String? = index == 3 ? "SOAP" : nil
      entries.append(TranscriptionHistoryStore.Entry(
        ts: Date(timeIntervalSince1970: TimeInterval(1_700_000_000 + index)),
        text: "line \(index)",
        mode: mode,
        templateName: name))
    }
    let list = ResultReport.candidates(
      dictations: entries, glossaryTerms: [], offlineMode: false, prompt: nil, readAloud: nil)
    let kinds = list.map { candidate in candidate.kind }
    #expect(list.count == 10)
    #expect(kinds.allSatisfy { $0 == ResultReport.Kind.dictation })
    #expect(Set(list.map { candidate in candidate.id }).count == 10)
    let times = list.map { candidate in candidate.ts }
    #expect(times == times.sorted(by: >))
    #expect(list.first?.preview == "line 9")
    #expect(list.contains { $0.menuLabel == "SOAP" && $0.preview == "line 3" })
    #expect(list.contains { $0.menuLabel == nil })
  }
}
