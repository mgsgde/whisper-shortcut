//
//  GlossaryLearning.swift
//  WhisperShortcut
//
//  The Whisper Glossary is free text the user asserts by hand (and via the chat tool or an AI
//  app). Smart Improvement used to let a model rewrite that whole text, so an accepted
//  suggestion deleted annotated corrections; that feature is gone (2026-11-02). Every automatic
//  edit goes through `mergeAdditively`, which only appends.
//

import Foundation

enum GlossaryLearning {

  /// Case- and diacritic-insensitive key shared with glossary dedupe ("Gödde" == "godde").
  /// `GlossaryDocument.fold` is POSIX, so this no longer follows the user's locale.
  static func fold(_ s: String) -> String {
    GlossaryDocument.fold(s)
  }

  /// One entry per term on a glossary line. Rejected spellings from every `(not …)` /
  /// `(nicht …)` group on that line attach to each of its terms — a line is normally one
  /// term, but `Terms: A, B` is several and they share the line's rejections.
  /// Parsing lives in `GlossaryDocument`; this is the tuple shape callers already use.
  static func entries(in glossary: String) -> [(term: String, rejected: [String])] {
    GlossaryDocument.parse(glossary).entries.map { (term: $0.term, rejected: $0.rejectedSpellings) }
  }

  /// `Term (not "A", "B")` — the only annotated shape this module writes, so a suggestion
  /// that arrived with `(nicht …)` or odd spacing is stored the way the prompt parser reads.
  static func annotatedLine(term: String, rejected: [String]) -> String {
    let quoted = rejected.map { "\"\($0)\"" }.joined(separator: ", ")
    return "\(term) (not \(quoted))"
  }

  /// The only way an automatic writer (chat tool, AI app) may change the glossary. `current` is kept verbatim
  /// (trailing whitespace of the whole text aside) because those lines are user-asserted;
  /// `suggestion` may only contribute terms and rejected spellings that are not already there.
  static func mergeAdditively(current: String, suggestion: String) -> String {
    let base = trimmingTrailingWhitespaceAndNewlines(current)
    let currentEntries = entries(in: base)
    var knownTerms = Set<String>()
    var knownRejected = Set<String>()
    for entry in currentEntries {
      let foldedTerm = fold(entry.term)
      if !foldedTerm.isEmpty { knownTerms.insert(foldedTerm) }
      for rejected in entry.rejected {
        let folded = fold(rejected)
        if !folded.isEmpty { knownRejected.insert(folded) }
      }
    }
    let known = knownTerms.union(knownRejected)

    struct Addition {
      var term: String
      var rejected: [String]
    }
    var additions: [Addition] = []
    var indexByFold: [String: Int] = [:]
    var addedRejected = Set<String>()

    func alreadyQueued(_ folded: String) -> Bool {
      indexByFold[folded] != nil || addedRejected.contains(folded)
    }

    /// First spelling of each folded form wins; drop the term itself, known terms, and
    /// anything this merge has already queued. `dropRejected` is on for a term the glossary
    /// already asserts — repeating `Vianco` under `Wianco` teaches nothing.
    func freshRejected(_ forms: [String], termFold: String, dropRejected: Bool) -> [String] {
      var seen = Set<String>()
      var kept: [String] = []
      for form in forms {
        let folded = fold(form)
        if folded.isEmpty || folded == termFold { continue }
        if !seen.insert(folded).inserted { continue }
        if knownTerms.contains(folded) || alreadyQueued(folded) { continue }
        if dropRejected && knownRejected.contains(folded) { continue }
        kept.append(form)
      }
      return kept
    }

    func queue(term: String, rejected: [String]) {
      let folded = fold(term)
      if let index = indexByFold[folded] {
        var existing = Set(additions[index].rejected.map { fold($0) })
        for form in rejected where existing.insert(fold(form)).inserted {
          additions[index].rejected.append(form)
          addedRejected.insert(fold(form))
        }
        return
      }
      indexByFold[folded] = additions.count
      additions.append(Addition(term: term, rejected: rejected))
      for form in rejected { addedRejected.insert(fold(form)) }
    }

    for rawLine in suggestion.components(separatedBy: .newlines) {
      if rawLine.trimmingCharacters(in: .whitespaces).isEmpty { continue }
      let lineEntries = entries(in: rawLine)
      let annotated = lineEntries.contains { !$0.rejected.isEmpty }
      if annotated {
        for entry in lineEntries {
          let termFold = fold(entry.term)
          if termFold.isEmpty { continue }
          if knownTerms.contains(termFold) {
            let newRejected = freshRejected(entry.rejected, termFold: termFold, dropRejected: true)
            if newRejected.isEmpty { continue }
            queue(term: entry.term, rejected: newRejected)
          } else if known.contains(termFold) || addedRejected.contains(termFold) {
            // A spelling the user already marked wrong must not come back as the "correct" term.
            continue
          } else if indexByFold[termFold] != nil {
            let extra = freshRejected(entry.rejected, termFold: termFold, dropRejected: false)
            if extra.isEmpty { continue }
            queue(term: entry.term, rejected: extra)
          } else {
            let kept = freshRejected(entry.rejected, termFold: termFold, dropRejected: false)
            queue(term: entry.term, rejected: kept)
          }
        }
      } else {
        for entry in lineEntries {
          let term = entry.term
          if !GlossaryDocument.withinWordCap(term) { continue }
          let termFold = fold(term)
          if termFold.isEmpty || known.contains(termFold) || alreadyQueued(termFold) { continue }
          queue(term: term, rejected: [])
        }
      }
    }

    if additions.isEmpty { return base }
    let rendered = additions.map { addition in
      addition.rejected.isEmpty ? addition.term : annotatedLine(term: addition.term, rejected: addition.rejected)
    }
    if base.isEmpty { return rendered.joined(separator: "\n") }
    return base + "\n" + rendered.joined(separator: "\n")
  }

  /// The chat tool often hand back a lowercase term. Lines already in
  /// `current` stay byte-for-byte — those are the user's spelling — and tokens inside a
  /// `(not …)` / `(nicht …)` group stay too, because that group is the mishearing, not the term.
  /// Everywhere else, a letter-token whose folded form shows up at least three times is rewritten
  /// to the corpus's majority spelling when the two differ only by case or diacritics.
  static func applyingMajorityCasing(
    to text: String,
    keepingLinesOf current: String,
    transcripts: [String]
  ) -> String {
    var counts: [String: [String: Int]] = [:]
    var totals: [String: Int] = [:]
    for transcript in transcripts {
      for tokenSub in transcript.split(whereSeparator: { !$0.isLetter }) {
        let token = String(tokenSub)
        let folded = fold(token)
        if folded.isEmpty { continue }
        totals[folded, default: 0] += 1
        counts[folded, default: [:]][token, default: 0] += 1
      }
    }
    var majority: [String: String] = [:]
    for (folded, total) in totals where total >= 3 {
      if let spelling = majoritySpelling(in: counts[folded] ?? [:]) {
        majority[folded] = spelling
      }
    }

    let protected = Set(current.components(separatedBy: .newlines))
    return text.components(separatedBy: .newlines).map { line in
      protected.contains(line) ? line : recasing(line, majority: majority)
    }.joined(separator: "\n")
  }

  // MARK: - Private

  private static func trimmingTrailingWhitespaceAndNewlines(_ text: String) -> String {
    var end = text.endIndex
    while end > text.startIndex {
      let previous = text.index(before: end)
      if text[previous].isWhitespace || text[previous].isNewline {
        end = previous
      } else {
        break
      }
    }
    return String(text[..<end])
  }

  /// Highest count wins; a tie keeps the lexicographically smaller spelling so the choice
  /// does not depend on dictionary order.
  private static func majoritySpelling(in counts: [String: Int]) -> String? {
    counts.max { lhs, rhs in
      if lhs.value != rhs.value { return lhs.value < rhs.value }
      return lhs.key > rhs.key
    }?.key
  }

  private static func recasing(_ line: String, majority: [String: String]) -> String {
    let protected = GlossaryDocument.annotationRanges(in: line)

    var output = ""
    var index = line.startIndex
    while index < line.endIndex {
      if let range = protected.first(where: { $0.contains(index) }) {
        output += line[range]
        index = range.upperBound
        continue
      }
      if line[index].isLetter {
        var end = index
        while end < line.endIndex, line[end].isLetter, !protected.contains(where: { $0.contains(end) }) {
          end = line.index(after: end)
        }
        let token = String(line[index..<end])
        let folded = fold(token)
        if let spelled = majority[folded], fold(spelled) == folded, spelled != token {
          output += spelled
        } else {
          output += token
        }
        index = end
      } else {
        output.append(line[index])
        index = line.index(after: index)
      }
    }
    return output
  }
}
