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
        Glossary echo removed: "Joschka SumUp"
        Glossary: 3 terms. In this text: Joschka, SumUp
        Offline Mode: off
        """)
  }

  @Test("Old entry omits mode, model and echo lines")
  func oldEntry() {
    let entry = TranscriptionHistoryStore.Entry(ts: Date(), text: "Hallo")
    let body = DictationReport.body(entry: entry, glossaryTerms: ["Foo"], offlineMode: true)
    #expect(!body.contains("Mode: Dictation"))
    #expect(!body.contains("Transcription model"))
    #expect(!body.contains("Glossary echo"))
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
    #expect(body.contains("Glossary: empty"))
    #expect(body.contains("Glossary echo removed: none"))
    #expect(!body.contains("Template:"))
    #expect(!body.contains("Audio length:"))
    #expect(!body.contains("Prompt sent:"))
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
    #expect(shown.contains("Template: SOAP"))
    #expect(shown.contains("Audio length: 3.5 s"))
    #expect(shown.contains("Prompt sent: 120 chars, hash abc123def456"))
    #expect(shown.contains("App version at dictation: 9.9.9"))
    #expect(shown.contains("Settings changed since this dictation"))
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
}
