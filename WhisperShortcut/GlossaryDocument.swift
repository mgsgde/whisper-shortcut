//
//  GlossaryDocument.swift
//  WhisperShortcut
//
//  One parse of the Whisper Glossary. Learning, the transcription prompt, the scorecard
//  and the fast learner each used to keep a copy of the annotation regex, and the copies
//  drifted: two `Terms:` prefixes, a 3-word cap beside a 5-word cap, and a fold that
//  followed the user's locale. Readers still render their own output (a prompt line, a
//  hit count, a rewritten glossary); they no longer decide what a line means.
//

import Foundation

struct GlossaryDocument: Equatable {

  struct Entry: Equatable {
    let term: String
    let rejectedSpellings: [String]
  }

  let entries: [Entry]

  /// Longest term that is still vocabulary rather than a phrase. Append used to allow 5
  /// while the transcription prompt dropped anything over 3, so a 4- or 5-word term the
  /// user added never reached the model. `SystemPromptsStore.maxTermWords` is this value.
  static let maxTermWords = 5

  /// Case- and diacritic-insensitive key ("Gödde" == "godde"). The locale is POSIX on
  /// purpose: `.current` folds "I" to "ı" for a Turkish user and to "i" for everyone else,
  /// so the same glossary matched on one machine and not another.
  static func fold(_ s: String) -> String {
    s.folding(
      options: [.diacriticInsensitive, .caseInsensitive],
      locale: Locale(identifier: "en_US_POSIX"))
  }

  /// True when `term` is short enough to condition transcription. Longer phrases stay in
  /// `entries` — the user wrote them — but are not reference vocabulary.
  static func withinWordCap(_ term: String) -> Bool {
    !term.isEmpty && term.split(separator: " ").count <= maxTermWords
  }

  static func parse(_ text: String) -> GlossaryDocument {
    var entries: [Entry] = []
    for line in text.components(separatedBy: .newlines) {
      if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
      let rejected = rejectedSpellings(on: line)
      let body = strippingAnnotations(from: line).replacingOccurrences(
        of: termsPrefixPattern,
        with: "",
        options: [.regularExpression, .caseInsensitive])
      for raw in body.components(separatedBy: ",") {
        let term = raw.trimmingCharacters(in: .whitespaces)
        if term.isEmpty { continue }
        entries.append(Entry(term: term, rejectedSpellings: rejected))
      }
    }
    return GlossaryDocument(entries: entries)
  }

  /// Rejected spellings on one line, in order. An annotation with no term beside it
  /// still counts: the prompt must not offer that spelling as vocabulary.
  static func rejectedSpellings(on line: String) -> [String] {
    var forms: [String] = []
    var cursor = Substring(line)
    while let range = cursor.range(
      of: annotationPattern, options: [.regularExpression, .caseInsensitive])
    {
      var inner = String(cursor[range])
      if let prefix = inner.range(
        of: annotationInnerPrefix, options: [.regularExpression, .caseInsensitive])
      {
        inner.removeSubrange(prefix)
      }
      if inner.hasSuffix(")") { inner.removeLast() }
      for form in inner.components(separatedBy: ",") {
        let cleaned = form.trimmingCharacters(in: trimSet)
        if !cleaned.isEmpty { forms.append(cleaned) }
      }
      cursor = cursor[range.upperBound...]
    }
    return forms
  }

  /// The line with annotations and a leading `Terms:` label removed. The prompt renders
  /// one tie-breaker per line, so `A, B (not "C")` stays the single correct form "A, B"
  /// rather than two entries.
  static func lineTermText(_ line: String) -> String {
    strippingAnnotations(from: line)
      .replacingOccurrences(
        of: termsPrefixPattern,
        with: "",
        options: [.regularExpression, .caseInsensitive])
      .trimmingCharacters(in: .whitespaces)
  }

  /// The leading `Terms:` label, including the whitespace after it, or "" when the line
  /// has none. The fast learner keeps this text when it drops a list member; a second
  /// prefix regex (`^Terms:` without the leading spaces) used to miss an indented label
  /// and treat "Terms" as part of the first term.
  static func termsLabel(on line: String) -> String {
    guard let range = line.range(
      of: termsPrefixPattern, options: [.regularExpression, .caseInsensitive])
    else { return "" }
    return String(line[range])
  }

  /// True when the line carries a complete `(not …)` / `(nicht …)` group. The fast learner
  /// leaves those lines alone — the wrong spelling in them is filtered at prompt time.
  static func carriesAnnotation(_ line: String) -> Bool {
    line.range(of: annotationPattern, options: [.regularExpression, .caseInsensitive]) != nil
  }

  /// Ranges of `(not …)` / `(nicht …)` groups. Majority-casing must not rewrite the
  /// mishearing inside them; a second copy of the pattern is how that protection drifted.
  static func annotationRanges(in text: String) -> [Range<String.Index>] {
    var ranges: [Range<String.Index>] = []
    var cursor = text.startIndex
    while cursor < text.endIndex,
          let range = text.range(
            of: annotationPattern,
            options: [.regularExpression, .caseInsensitive],
            range: cursor..<text.endIndex)
    {
      ranges.append(range)
      cursor = range.upperBound
    }
    return ranges
  }

  // MARK: - Private

  /// The one annotation shape. `\s*` before it is only for stripping, so the term does
  /// not keep the space that separated it from the parenthetical.
  private static let annotationPattern = #"\((?:not|nicht)\s+[^)]*\)"#
  private static let annotationStripPattern = #"\s*"# + annotationPattern
  private static let annotationInnerPrefix = #"^\((?:not|nicht)\s+"#
  /// `^\s*` so an indented `Terms:` is a label. `^Terms:` left that line's first term as "Terms: …".
  private static let termsPrefixPattern = #"^\s*Terms:\s*"#
  private static let trimSet = CharacterSet(charactersIn: " \"'")

  private static func strippingAnnotations(from line: String) -> String {
    line.replacingOccurrences(
      of: annotationStripPattern,
      with: "",
      options: [.regularExpression, .caseInsensitive])
  }
}
