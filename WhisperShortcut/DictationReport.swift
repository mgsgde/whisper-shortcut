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
    offlineMode: Bool
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

    if let removed = entry.glossaryEchoRemoved {
      let value = removed.isEmpty
        ? String(localized: "none")
        : removed.map { "\"\($0)\"" }.joined(separator: ", ")
      lines.append(String(localized: "Glossary echo removed: \(value)"))
    }

    let summary = glossarySummary(terms: glossaryTerms, text: entry.text)
    lines.append(String(localized: "Glossary: \(summary)"))
    lines.append(offlineMode
      ? String(localized: "Offline Mode: on")
      : String(localized: "Offline Mode: off"))
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
