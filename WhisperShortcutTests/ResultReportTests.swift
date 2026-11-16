import Foundation
import Testing
@testable import WhisperShortcut_AppStore

@Suite("Result report bodies")
struct ResultReportTests {

  private static func date(_ iso: String) -> Date {
    ISO8601DateFormatter().date(from: iso)!
  }

  private static func localString(_ d: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
    return f.string(from: d)
  }

  @Test("Prompt body lists every field")
  func promptBodyFull() {
    let ts = Self.date("2026-10-27T16:27:41Z")
    let result = LastResultStore.PromptResult(
      ts: ts, instruction: "make this shorter", selectedText: "A long note about the visit",
      response: "A short note.", model: "gemini-3.5-flash", provider: "Gemini", hadScreenshot: true)
    let body = ResultReport.promptBody(result, offlineMode: false)
    #expect(
      body == """
        Instruction:
        make this shorter

        Selected text (excerpt):
        A long note about the visit

        Answer:
        A short note.

        Answered: \(Self.localString(ts))
        Mode: Prompt
        Model: gemini-3.5-flash
        Provider: Gemini
        Screenshot: yes
        Offline Mode: off
        """)
  }

  @Test("Prompt body omits a missing selection and nil model or provider")
  func promptBodyOmitsNil() {
    let ts = Self.date("2026-10-27T16:27:41Z")
    let result = LastResultStore.PromptResult(
      ts: ts, instruction: "write a reply", selectedText: nil, response: "Friday works.",
      model: nil, provider: nil, hadScreenshot: false)
    let body = ResultReport.promptBody(result, offlineMode: true)
    #expect(!body.contains("Selected text"))
    #expect(!body.contains("Model:"))
    #expect(!body.contains("Provider:"))
    #expect(
      body == """
        Instruction:
        write a reply

        Answer:
        Friday works.

        Answered: \(Self.localString(ts))
        Mode: Prompt
        Screenshot: no
        Offline Mode: on
        """)
  }

  @Test("Read Aloud body lists the text, time, model and voice")
  func readAloudBody() {
    let ts = Self.date("2026-11-02T09:15:00Z")
    let result = LastResultStore.ReadAloudResult(
      ts: ts, text: "Please read this sentence.", model: "gemini-2.5-flash-preview-tts", voice: "Kore")
    let body = ResultReport.readAloudBody(result)
    #expect(
      body == """
        Text read aloud:
        Please read this sentence.

        Read: \(Self.localString(ts))
        Mode: Read Aloud
        Voice model: gemini-2.5-flash-preview-tts
        Voice: Kore
        """)
  }

  @Test("Candidates are newest first, drop nils, and flatten a cut preview")
  func candidates() {
    let oldest = Self.date("2026-10-27T16:00:00Z")
    let middle = Self.date("2026-10-27T16:10:00Z")
    let newest = Self.date("2026-10-27T16:20:00Z")
    let dictation = TranscriptionHistoryStore.Entry(ts: oldest, text: "hello\nworld")
    let spoken = "ab\n" + String(repeating: "c", count: 50)
    let prompt = LastResultStore.PromptResult(
      ts: newest, instruction: "shorten", selectedText: nil, response: "Done",
      model: "m", provider: "p", hadScreenshot: false)
    let readAloud = LastResultStore.ReadAloudResult(ts: middle, text: spoken, model: "v", voice: "Kore")

    let all = ResultReport.candidates(
      dictation: dictation, glossaryTerms: [], offlineMode: false,
      prompt: prompt, readAloud: readAloud)
    #expect(all.map(\.kind) == [.prompt, .readAloud, .dictation])
    #expect(all.map(\.ts) == [newest, middle, oldest])
    #expect(all[2].preview == "hello world")
    #expect(all[2].details == DictationReport.body(entry: dictation, glossaryTerms: [], offlineMode: false))
    let expectedPreview = "ab " + String(repeating: "c", count: 37) + "…"
    #expect(all[1].preview == expectedPreview)
    #expect(all[1].preview.count == 41)

    let withoutReadAloud = ResultReport.candidates(
      dictation: nil, glossaryTerms: [], offlineMode: false, prompt: prompt, readAloud: nil)
    #expect(withoutReadAloud.map(\.kind) == [.prompt])
  }

  @Test("LastResultStore caps excerpts and ignores empty text")
  func storeCaps() {
    let store = LastResultStore()
    let long = String(repeating: "a", count: 2_500)
    let ts = Date()
    store.recordPrompt(.init(
      ts: ts, instruction: "instr", selectedText: long, response: long,
      model: "m", provider: "p", hadScreenshot: false))
    #expect(store.lastPrompt?.selectedText?.count == 601)
    #expect(store.lastPrompt?.selectedText?.hasSuffix("…") == true)
    #expect(store.lastPrompt?.selectedText?.hasPrefix(String(repeating: "a", count: 600)) == true)
    #expect(store.lastPrompt?.response.count == 2_001)
    #expect(store.lastPrompt?.response.hasSuffix("…") == true)

    let exact = String(repeating: "b", count: 600)
    store.recordPrompt(.init(
      ts: ts, instruction: "instr", selectedText: exact, response: "ok",
      model: nil, provider: nil, hadScreenshot: true))
    #expect(store.lastPrompt?.selectedText == exact)

    store.recordPrompt(.init(
      ts: ts, instruction: "ignored", selectedText: "secret", response: " \n\t ",
      model: nil, provider: nil, hadScreenshot: false))
    #expect(store.lastPrompt?.instruction == "instr")
    #expect(store.lastPrompt?.response == "ok")

    store.recordReadAloud(.init(ts: ts, text: long, model: "voice-model", voice: "Kore"))
    #expect(store.lastReadAloud?.text.count == 2_001)
    #expect(store.lastReadAloud?.text.hasSuffix("…") == true)
    store.recordReadAloud(.init(ts: ts, text: "   ", model: nil, voice: nil))
    #expect(store.lastReadAloud?.text.count == 2_001)

    store.clear()
    #expect(store.lastPrompt == nil)
    #expect(store.lastReadAloud == nil)
  }
}
