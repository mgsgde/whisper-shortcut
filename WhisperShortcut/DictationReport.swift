//
//  DictationReport.swift
//  WhisperShortcut
//
//  The body of a "problem with this dictation" report.
//

import Foundation

/// The text of a "problem with this dictation" report: what was pasted plus the facts that
/// otherwise cost a round-trip ("which version? which model?"). The wording follows the app
/// language, like the message the user sends. App version and macOS are appended later by
/// `FeedbackLinks.messageBody`, so they are not repeated here.
enum DictationReport {

  static func body(
    entry: TranscriptionHistoryStore.Entry,
    glossaryTerms: [String],
    offlineMode: Bool,
    currentConfigHash: String? = nil
  ) -> String {
    var lines = [String(localized: "Pasted text:"), entry.text, ""]

    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
    let dictated = formatter.string(from: entry.ts)
    lines.append(String(localized: "Dictated: \(dictated)"))

    if let mode = entry.mode { lines.append(String(localized: "Mode: \(mode)")) }

    let modelDescription: String?
    switch (entry.transcriptionModelName, entry.transcriptionModel) {
    case let (name?, raw?): modelDescription = "\(name) (\(raw))"
    case let (name?, nil): modelDescription = name
    case let (nil, raw?): modelDescription = raw
    case (nil, nil): modelDescription = nil
    }
    if let modelDescription {
      lines.append(String(localized: "Transcription model: \(modelDescription)"))
    }

    let summary = glossarySummary(terms: glossaryTerms, text: entry.text)
    lines.append(String(localized: "Glossary: \(summary)"))
    lines.append(offlineMode
      ? String(localized: "Offline Mode: on")
      : String(localized: "Offline Mode: off"))

    if let name = entry.templateName {
      lines.append(String(localized: "Template: \(name)"))
    }
    if let seconds = entry.audioDurationSeconds {
      let shown = String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), seconds)
      lines.append(String(localized: "Audio length: \(shown) s"))
    }
    if let version = entry.appVersion {
      lines.append(String(localized: "App version at dictation: \(version)"))
    }
    if let saved = entry.configHash, let current = currentConfigHash, saved != current {
      lines.append(String(localized: "Note: settings were changed after this dictation"))
    }
    if let raw = entry.rawOutput, raw != entry.text {
      lines.append(String(localized: "Model output before cleanup:"))
      lines.append(raw)
    }
    return lines.joined(separator: "\n")
  }

  /// Glossary-echo and prompt-hash lines. They go in the settings file, not the editable details.
  static func technicalLines(entry: TranscriptionHistoryStore.Entry) -> String {
    var lines: [String] = []
    if let removed = entry.glossaryEchoRemoved {
      let value = removed.isEmpty
        ? String(localized: "none")
        : removed.map { "\"\($0)\"" }.joined(separator: ", ")
      lines.append(String(localized: "Glossary echo removed: \(value)"))
    }
    if let chars = entry.promptChars, let hash = entry.promptHash {
      lines.append(String(localized: "Prompt sent: \(chars) chars, hash \(hash)"))
    }
    return lines.joined(separator: "\n")
  }

  /// Only terms that occur in the text are named: the rest of the glossary may hold private
  /// names that have nothing to do with the problem.
  private static func glossarySummary(terms: [String], text: String) -> String {
    guard !terms.isEmpty else { return String(localized: "empty") }
    let textWords = words(text)
    var seen = Set<String>()
    var present: [String] = []
    for term in terms {
      let termWords = words(term)
      guard !termWords.isEmpty, seen.insert(termWords.joined(separator: " ")).inserted,
        containsSequence(textWords, termWords)
      else { continue }
      present.append(term)
    }
    if present.isEmpty {
      return String(localized: "\(terms.count) terms. None in this text.")
    }
    let list = present.joined(separator: ", ")
    return String(localized: "\(terms.count) terms. In this text: \(list)")
  }

  private static func words(_ s: String) -> [String] {
    s.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map { GlossaryDocument.fold(String($0)) }
  }

  private static func containsSequence(_ haystack: [String], _ needle: [String]) -> Bool {
    guard needle.count <= haystack.count else { return false }
    for start in 0...(haystack.count - needle.count)
    where Array(haystack[start..<start + needle.count]) == needle {
      return true
    }
    return false
  }
}

/// Report bodies for recent dictations, the last Prompt answer and the last Read Aloud.
/// Plain English and not localized, because the developer reads them. Dictation history
/// contributes one candidate per entry (up to 10, every mode). Prompt and Read Aloud contribute
/// their latest result. App version and macOS are appended later by `FeedbackLinks.messageBody`.
enum ResultReport {

  enum Kind: String, Equatable {
    case dictation, prompt, readAloud, general
  }

  struct Candidate: Equatable {
    let id: String
    let kind: Kind
    let ts: Date
    let preview: String
    let details: String
    /// Glossary-echo and prompt-hash lines. Empty when this result has none.
    let technical: String
    /// Replaces the kind name in "Report Something Else". A template's own name.
    let menuLabel: String?
  }

  /// Newest first. One candidate per history entry (at most 10), plus the latest prompt and
  /// Read Aloud when those exist. A template entry is a dictation candidate. A general-feedback
  /// candidate is always last, so the list is never empty.
  static func candidates(
    dictations: [TranscriptionHistoryStore.Entry],
    glossaryTerms: [String],
    offlineMode: Bool,
    prompt: LastResultStore.PromptResult?,
    readAloud: LastResultStore.ReadAloudResult?,
    currentConfigHash: String? = nil
  ) -> [Candidate] {
    var list: [Candidate] = []
    for (index, entry) in dictations.prefix(10).enumerated() {
      list.append(Candidate(
        id: candidateID(kind: .dictation, ts: entry.ts, extra: "\(index)"),
        kind: .dictation,
        ts: entry.ts,
        preview: preview(entry.text),
        details: DictationReport.body(
          entry: entry, glossaryTerms: glossaryTerms, offlineMode: offlineMode,
          currentConfigHash: currentConfigHash),
        technical: DictationReport.technicalLines(entry: entry),
        menuLabel: entry.mode == "Template" ? entry.templateName : nil))
    }
    if let prompt {
      list.append(Candidate(
        id: candidateID(kind: .prompt, ts: prompt.ts, extra: ""),
        kind: .prompt,
        ts: prompt.ts,
        preview: preview(prompt.instruction),
        details: promptBody(prompt, offlineMode: offlineMode),
        technical: "",
        menuLabel: nil))
    }
    if let readAloud {
      list.append(Candidate(
        id: candidateID(kind: .readAloud, ts: readAloud.ts, extra: ""),
        kind: .readAloud,
        ts: readAloud.ts,
        preview: preview(readAloud.text),
        details: readAloudBody(readAloud),
        technical: "",
        menuLabel: nil))
    }
    return list.sorted { $0.ts > $1.ts } + [generalCandidate(offlineMode: offlineMode)]
  }

  /// Environment only: there is no dictation, prompt or reading to quote. Appended after the
  /// time sort so it stays last even though its timestamp is now.
  private static func generalCandidate(offlineMode: Bool) -> Candidate {
    let offline = offlineMode
      ? String(localized: "Offline Mode: on")
      : String(localized: "Offline Mode: off")
    return Candidate(
      id: "general",
      kind: .general,
      ts: Date(),
      preview: "",
      details: "\(FeedbackLinks.environmentBlock)\n\(offline)",
      technical: "",
      menuLabel: nil)
  }

  private static func candidateID(kind: Kind, ts: Date, extra: String) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    let stamp = formatter.string(from: ts)
    return extra.isEmpty ? "\(stamp)|\(kind.rawValue)" : "\(stamp)|\(kind.rawValue)|\(extra)"
  }

  static func promptBody(_ result: LastResultStore.PromptResult, offlineMode: Bool) -> String {
    var lines = ["Instruction:", result.instruction, ""]
    if let selected = result.selectedText,
      !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      lines.append("Selected text (excerpt):")
      lines.append(selected)
      lines.append("")
    }
    lines.append("Answer:")
    lines.append(result.response)
    lines.append("")
    lines.append("Answered: \(timestamp(result.ts))")
    lines.append("Mode: Prompt")
    if let model = result.model { lines.append("Model: \(model)") }
    if let provider = result.provider { lines.append("Provider: \(provider)") }
    lines.append("Screenshot: \(result.hadScreenshot ? "yes" : "no")")
    lines.append("Offline Mode: \(offlineMode ? "on" : "off")")
    return lines.joined(separator: "\n")
  }

  static func readAloudBody(_ result: LastResultStore.ReadAloudResult) -> String {
    var lines = [
      "Text read aloud:", result.text, "",
      "Read: \(timestamp(result.ts))",
      "Mode: Read Aloud",
    ]
    if let model = result.model { lines.append("Voice model: \(model)") }
    if let voice = result.voice { lines.append("Voice: \(voice)") }
    return lines.joined(separator: "\n")
  }

  /// First 40 characters, one line. Newlines become spaces; a longer line is cut and marked with "…".
  private static func preview(_ text: String) -> String {
    let singleLine = text
      .replacingOccurrences(of: "\r\n", with: " ")
      .replacingOccurrences(of: "\n", with: " ")
      .replacingOccurrences(of: "\r", with: " ")
    let limit = 40
    guard singleLine.count > limit else { return singleLine }
    return String(singleLine.prefix(limit)) + "…"
  }

  private static func timestamp(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
    return formatter.string(from: date)
  }
}
