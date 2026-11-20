import Foundation
import Testing
@testable import WhisperShortcut_AppStore

@Suite("Transcription history")
struct TranscriptionHistoryStoreTests {

  @Test("An old file without the new fields still decodes")
  func oldEntryDecodes() throws {
    let json = """
      [{"ts":"2026-10-27T16:27:41Z","text":"Hallo","mode":"Dictation"}]
      """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let entries = try decoder.decode([TranscriptionHistoryStore.Entry].self, from: Data(json.utf8))
    #expect(entries.count == 1)
    #expect(entries[0].text == "Hallo")
    #expect(entries[0].mode == "Dictation")
    #expect(entries[0].rawOutput == nil)
    #expect(entries[0].audioDurationSeconds == nil)
    #expect(entries[0].templateName == nil)
    #expect(entries[0].templateID == nil)
    #expect(entries[0].promptChars == nil)
    #expect(entries[0].promptHash == nil)
    #expect(entries[0].configHash == nil)
    #expect(entries[0].appVersion == nil)
  }

  @Test("The store keeps 10 and the menu shows 5")
  func capacity() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("history-cap-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = TranscriptionHistoryStore(
      fileURL: dir.appendingPathComponent(TranscriptionHistoryStore.fileName))
    for index in 0..<11 {
      store.record("line \(index)")
    }
    store.waitForPendingWrites()
    #expect(store.entries.count == 10)
    #expect(store.entries.first?.text == "line 10")
    #expect(!store.entries.contains { $0.text == "line 0" })
    #expect(TranscriptionHistoryStore.menuEntries == 5)
    #expect(Array(store.entries.prefix(TranscriptionHistoryStore.menuEntries)).count == 5)
  }
}

@Suite("Report config fingerprint")
struct ReportConfigFingerprintTests {

  private func makeStore() throws -> (URL, SystemPromptsStore) {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("fingerprint-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let store = SystemPromptsStore(contextDirectoryURL: dir)
    _ = store.loadSection(.whisperGlossary)
    return (dir, store)
  }

  @Test("Stable for the same input, and it changes with the glossary or a template")
  func changesWhenConfigurationChanges() throws {
    let (dir, store) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    let note = DictationTemplate(id: firstID, name: "Note", instructions: "Write a note.")
    let letter = DictationTemplate(id: secondID, name: "Letter", instructions: "Write a letter.")

    let forward = ReportConfigFingerprint.current(store: store, templates: [note, letter])
    let again = ReportConfigFingerprint.current(store: store, templates: [note, letter])
    let reversed = ReportConfigFingerprint.current(store: store, templates: [letter, note])
    #expect(forward == again)
    #expect(forward == reversed)
    #expect(forward.count == 12)
    let hexDigits = CharacterSet(charactersIn: "0123456789abcdef")
    #expect(forward.unicodeScalars.allSatisfy { hexDigits.contains($0) })

    #expect(store.updateSection(.whisperGlossary, content: "Lumbarroll: a foam roll", source: .settings))
    let afterGlossary = ReportConfigFingerprint.current(store: store, templates: [note, letter])
    #expect(afterGlossary != forward)

    let edited = DictationTemplate(id: firstID, name: "Note", instructions: "Write a longer note.")
    let afterTemplate = ReportConfigFingerprint.current(store: store, templates: [edited, letter])
    #expect(afterTemplate != afterGlossary)
  }
}

@Suite("Request traces")
struct RequestTraceTests {

  @Test("requestTraces keeps only traces at or after the date, oldest first")
  func filtersByDate() {
    let service = SpeechService()
    let since = Date(timeIntervalSince1970: 1_500)
    service.noteRequestTrace(
      rawOutput: "before", audioDurationSeconds: 1, prompt: "old-prompt",
      date: Date(timeIntervalSince1970: 1_000))
    service.noteRequestTrace(
      rawOutput: "first", audioDurationSeconds: 1.5, prompt: "the-prompt", date: since)
    service.noteRequestTrace(
      rawOutput: "second", audioDurationSeconds: 2.25, prompt: "later-prompt",
      date: since.addingTimeInterval(5))
    let traces = service.requestTraces(since: since)
    #expect(traces.map(\.rawOutput) == ["first", "second"])

    let joined = service.recordedTrace(since: since)
    #expect(joined.rawOutput == "first\nsecond")
    #expect(joined.audioDurationSeconds == 3.75)
    #expect(joined.promptChars == "the-prompt".count)
    #expect(joined.promptHash == ReportConfigFingerprint.shortHash("the-prompt"))
    #expect(joined.promptHash?.count == 12)
  }
}
