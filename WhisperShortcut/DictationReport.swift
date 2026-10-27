//
//  DictationReport.swift
//  WhisperShortcut
//
//  The body of a "problem with this dictation" report.
//

import Foundation

/// The text of a "problem with this dictation" report: what was pasted plus the facts that
/// otherwise cost a round-trip ("which version? which model?"). Plain English and not localized,
/// because the developer reads it. App version and macOS are appended later by
/// `FeedbackLinks.messageBody`, so they are not repeated here.
enum DictationReport {

  static func body(
    entry: TranscriptionHistoryStore.Entry,
    glossaryTerms: [String],
    offlineMode: Bool
  ) -> String {
    var lines = ["Pasted text:", entry.text, ""]

    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
    lines.append("Dictated: \(formatter.string(from: entry.ts))")

    if let mode = entry.mode { lines.append("Mode: \(mode)") }

    switch (entry.transcriptionModelName, entry.transcriptionModel) {
    case let (name?, raw?): lines.append("Transcription model: \(name) (\(raw))")
    case let (name?, nil): lines.append("Transcription model: \(name)")
    case let (nil, raw?): lines.append("Transcription model: \(raw)")
    case (nil, nil): break
    }

    if let removed = entry.glossaryEchoRemoved {
      let value = removed.isEmpty ? "none" : removed.map { "\"\($0)\"" }.joined(separator: ", ")
      lines.append("Glossary echo removed: \(value)")
    }

    lines.append("Glossary: \(glossarySummary(terms: glossaryTerms, text: entry.text))")
    lines.append("Offline Mode: \(offlineMode ? "on" : "off")")
    return lines.joined(separator: "\n")
  }

  /// Only terms that occur in the text are named: the rest of the glossary may hold private
  /// names that have nothing to do with the problem.
  private static func glossarySummary(terms: [String], text: String) -> String {
    guard !terms.isEmpty else { return "empty" }
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
    let count = "\(terms.count) terms"
    return present.isEmpty
      ? "\(count). None in this text." : "\(count). In this text: \(present.joined(separator: ", "))"
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
