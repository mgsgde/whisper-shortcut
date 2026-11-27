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

  @Test("Dictate Prompt lists the selection, the instruction and the front app")
  func promptContextLines() throws {
    let ts = Self.date("2026-10-27T16:27:41Z")
    let captured = TranscriptionHistoryStore.Entry(
      ts: ts, text: "Pasted answer", mode: "Dictate Prompt",
      transcriptionModel: "gemini-3.5-flash", transcriptionModelName: "Gemini",
      selectedText: "Hallo GU Anmeldung",
      selectionCaptured: true,
      userInstruction: "Korrigiere den ersten Satz",
      frontAppBundleId: "com.citrix.receiver")
    let body = DictationReport.body(entry: captured, glossaryTerms: [], offlineMode: false)
    let modeEnd = try #require(body.range(of: "Mode: Dictate Prompt"))
    let modelStart = try #require(body.range(of: "Transcription model:"))
    #expect(String(body[modeEnd.upperBound..<modelStart.lowerBound]) == """

      Selected text sent to the model:
      Hallo GU Anmeldung
      Spoken instruction:
      Korrigiere den ersten Satz
      Front app:
      com.citrix.receiver

      """)

    let noneCaptured = TranscriptionHistoryStore.Entry(
      ts: ts, text: "Pasted answer", mode: "Dictate Prompt", selectionCaptured: false)
    let noneBody = DictationReport.body(entry: noneCaptured, glossaryTerms: [], offlineMode: false)
    #expect(noneBody.contains("Selected text sent to the model: none"))
    #expect(!noneBody.contains("Spoken instruction:"))
    #expect(!noneBody.contains("Front app:"))

    let old = TranscriptionHistoryStore.Entry(
      ts: ts, text: "Pasted answer", mode: "Dictate Prompt")
    let oldBody = DictationReport.body(entry: old, glossaryTerms: [], offlineMode: false)
    #expect(!oldBody.contains("Selected text sent to the model:"))
    #expect(!oldBody.contains("Spoken instruction:"))
    #expect(!oldBody.contains("Front app:"))
    #expect(!oldBody.contains("Writing style:"))
    #expect(!oldBody.contains("Memory style rules:"))
    #expect(!oldBody.contains("none"))
  }

  @Test("Dictate Prompt names the writing-style block when it was recorded")
  func writingStyleLines() throws {
    let ts = Self.date("2026-10-27T16:27:41Z")
    let on = TranscriptionHistoryStore.Entry(
      ts: ts, text: "Pasted answer", mode: "Dictate Prompt",
      frontAppBundleId: "com.apple.mail",
      styleExamples: 3, styleContext: "email", memoryStyleRules: 2)
    let onBody = DictationReport.body(entry: on, glossaryTerms: [], offlineMode: false)
    let front = try #require(onBody.range(of: "Front app:\ncom.apple.mail"))
    let style = try #require(onBody.range(of: "Writing style: 3 examples (email)"))
    #expect(front.upperBound <= style.lowerBound)
    #expect(onBody.contains("Memory style rules: 2"))

    let off = TranscriptionHistoryStore.Entry(
      ts: ts, text: "Pasted answer", mode: "Dictate Prompt",
      styleExamples: 0, memoryStyleRules: 0)
    let offBody = DictationReport.body(entry: off, glossaryTerms: [], offlineMode: false)
    #expect(offBody.contains("Writing style: off"))
    #expect(!offBody.contains("examples"))
    #expect(!offBody.contains("Memory style rules:"))

    let unknown = TranscriptionHistoryStore.Entry(
      ts: ts, text: "Pasted answer", mode: "Dictate Prompt")
    let unknownBody = DictationReport.body(entry: unknown, glossaryTerms: [], offlineMode: false)
    #expect(!unknownBody.contains("Writing style:"))
    #expect(!unknownBody.contains("Memory style rules:"))
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
    #expect(list.count == 11)
    #expect(list.dropLast().allSatisfy { $0.kind == ResultReport.Kind.dictation })
    #expect(list.last?.id == "general")
    #expect(list.last?.kind == .general)
    #expect(Set(list.map { candidate in candidate.id }).count == 11)
    let times = list.dropLast().map { candidate in candidate.ts }
    #expect(times == times.sorted(by: >))
    #expect(list.first?.preview == "line 9")
    #expect(list.contains { $0.menuLabel == "SOAP" && $0.preview == "line 3" })
    #expect(list.contains { $0.menuLabel == nil })
  }

  @Test("A general feedback candidate is always last, including with no history")
  func generalCandidateIsLast() {
    let empty = ResultReport.candidates(
      dictations: [], glossaryTerms: [], offlineMode: true, prompt: nil, readAloud: nil)
    #expect(empty.count == 1)
    #expect(empty.last?.id == "general")
    #expect(empty.last?.kind == .general)
    #expect(empty.last?.preview.isEmpty == true)
    #expect(empty.last?.technical.isEmpty == true)
    #expect(empty.last?.menuLabel == nil)
    #expect(empty.last?.details.contains("App version:") == false)
    #expect(empty.last?.details.contains("macOS:") == false)
    #expect(empty.last?.details.contains("Offline Mode: on") == true)
    let file = DictationReportWindowController.fileText(
      context: empty.last?.details ?? "", technical: "", configuration: nil)
    let mailed = FeedbackLinks.messageBody(context: empty.last?.details)
    #expect(file == mailed)
    #expect(file.contains("macOS:"))
    #expect(file.contains(AppConstants.appVersion))
    #expect(
      file.components(separatedBy: "macOS:").count
        == FeedbackLinks.messageBody(context: "x").components(separatedBy: "macOS:").count)

    let entry = TranscriptionHistoryStore.Entry(
      ts: Date(timeIntervalSince1970: 1_700_000_000), text: "hello")
    let withHistory = ResultReport.candidates(
      dictations: [entry], glossaryTerms: [], offlineMode: false, prompt: nil, readAloud: nil)
    #expect(withHistory.count == 2)
    #expect(withHistory.last?.id == "general")
    #expect(withHistory.last?.kind == .general)
    #expect(withHistory.dropLast().allSatisfy { $0.kind == .dictation })
    #expect(withHistory.last?.details.contains("Offline Mode: off") == true)
  }

  @Test("ProblemReport startOnGeneral selects the general candidate from a stub provider")
  func problemReportStartOnGeneral() {
    let previous = ProblemReport.candidatesProvider
    defer { ProblemReport.candidatesProvider = previous }
    let newer = ResultReport.Candidate(
      id: "newer", kind: .dictation, ts: Date(timeIntervalSince1970: 1_700_000_000),
      preview: "line", details: "details", technical: "", menuLabel: nil)
    let general = ResultReport.Candidate(
      id: "general", kind: .general, ts: Date(), preview: "",
      details: "App version: test", technical: "", menuLabel: nil)
    ProblemReport.candidatesProvider = { [newer, general] }
    let candidates = ProblemReport.candidatesProvider?() ?? []
    #expect(ProblemReport.initialSelection(candidates: candidates, startOnGeneral: true) == "general")
    #expect(ProblemReport.initialSelection(candidates: candidates, startOnGeneral: false) == "newer")
    let prepared = ProblemReport.preparedCandidates(details: "Me: hi")
    #expect(prepared.first { $0.id == "general" }?.details.hasPrefix("Me: hi\n\n") == true)
    #expect(prepared.first { $0.id == "newer" }?.details == "details")
  }

  @Test("Chat tail is placed above the general candidate, and a blank tail changes nothing")
  func extraDetailsAboveGeneral() {
    let list = ResultReport.candidates(
      dictations: [], glossaryTerms: [], offlineMode: false, prompt: nil, readAloud: nil)
    let withTail = ResultReport.applyingExtraDetails("Me: the paste was empty", to: list)
    #expect(withTail.last?.details == "Me: the paste was empty\n\nOffline Mode: off")
    #expect(withTail.last?.details.contains("macOS:") == false)
    #expect(ResultReport.applyingExtraDetails("  \n", to: list).last?.details == list.last?.details)
  }

  @Test("The report file is the mail body, then technical lines, then the configuration")
  func reportFileCarriesTheMailFooterOnce() {
    let context = "Offline Mode: off"
    let technical = "Prompt sent: 12 chars, hash abc"
    let configuration = "Glossary: Ada"
    let file = DictationReportWindowController.fileText(
      context: context, technical: technical, configuration: configuration)
    let mailed = FeedbackLinks.messageBody(context: context)
    #expect(file.hasPrefix(mailed))
    #expect(file.hasSuffix("\(technical)\n\n\(configuration)"))
    #expect(
      file.components(separatedBy: "macOS:").count
        == mailed.components(separatedBy: "macOS:").count)
    #expect(
      file.components(separatedBy: "App version:").count
        == mailed.components(separatedBy: "App version:").count)
    let withoutConfiguration = DictationReportWindowController.fileText(
      context: context, technical: technical, configuration: nil)
    #expect(withoutConfiguration == "\(mailed)\n\n\(technical)")
    #expect(!withoutConfiguration.contains("Glossary: Ada"))
  }
}
