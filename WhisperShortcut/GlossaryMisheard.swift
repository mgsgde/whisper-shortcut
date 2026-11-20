//
//  GlossaryMisheard.swift
//  WhisperShortcut
//
//  "Add Selection to Glossary" stores the correct spelling. With the offline engine that is not
//  enough: `ParakeetVocabularyGuard` only rewrites a heard span into a term at similarity >= 0.6,
//  so "Lasse" (0.57 to "Lasègue") stays "Lasse" until the glossary names it as a misheard form.
//  The last dictation (`TranscriptionHistoryStore.mostRecent`) tells us what was heard.
//

import Foundation

enum GlossaryMisheard {
  /// Below this the best word is not plausibly the same word heard wrong.
  static let minimumSimilarity = 0.5
  /// Older than this and the dictation is no longer what the user is correcting.
  static let maxAge: TimeInterval = 10 * 60

  /// The word of `dictation` that the single-word `correct` was most likely heard as, or nil.
  /// Same guards as `GlossaryFastLearner`: same first letter (folded), not an inflection of the
  /// term, and at least one of the two words unknown to the spell checker (`isKnownWord`), so two
  /// ordinary words are never paired. Also nil for a multi-word selection, a dictation older than
  /// `maxAge`, one that already contains `correct`, or when nothing reaches `minimumSimilarity`.
  /// The best word wins; trailing punctuation is stripped.
  static func misheardForm(
    correct: String, dictation: String, dictationDate: Date, now: Date = Date(),
    isKnownWord: (String) -> Bool
  ) -> String? {
    guard now.timeIntervalSince(dictationDate) <= maxAge else { return nil }
    let target = correct.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !target.isEmpty, !target.contains(where: \.isWhitespace) else { return nil }
    let foldedTarget = GlossaryDocument.fold(target)
    guard let first = foldedTarget.first else { return nil }
    if GlossaryDocument.fold(dictation).contains(foldedTarget) { return nil }

    var best: (word: String, score: Double)?
    for raw in dictation.split(whereSeparator: \.isWhitespace) {
      let word = raw.trimmingCharacters(in: .punctuationCharacters)
      let foldedWord = GlossaryDocument.fold(word)
      guard foldedWord.first == first, foldedWord != foldedTarget,
        !GlossaryFastLearner.isInflectionalVariant(foldedTarget, foldedWord)
      else { continue }
      let score = ParakeetVocabularyGuard.similarity(word, target)
      if score >= minimumSimilarity, score > (best?.score ?? -1) { best = (word, score) }
    }
    guard let best, !isKnownWord(best.word) || !isKnownWord(target) else { return nil }
    return best.word
  }

  /// `glossary` with `misheard` added to the single-term line that already holds `term`, or nil
  /// when that is not possible (term not on a line of its own, or the form is already listed).
  static func addingMisheard(_ misheard: String, for term: String, to glossary: String) -> String? {
    let key = GlossaryDocument.fold(term)
    var lines = glossary.components(separatedBy: "\n")
    guard let index = lines.firstIndex(where: { line in
      let entries = GlossaryDocument.parse(line).entries
      return entries.count == 1 && GlossaryDocument.fold(entries[0].term) == key
    }) else { return nil }
    let line = lines[index]
    let folded = GlossaryDocument.fold(misheard)
    if GlossaryDocument.rejectedSpellings(on: line).contains(where: { GlossaryDocument.fold($0) == folded }) {
      return nil
    }
    if GlossaryDocument.carriesAnnotation(line) {
      guard let close = line.lastIndex(of: ")"),
        line[line.index(after: close)...].allSatisfy(\.isWhitespace)
      else { return nil }
      lines[index] = String(line[..<close]) + ", \"\(misheard)\")"
    } else {
      lines[index] = line.trimmingCharacters(in: .whitespaces) + " (not \"\(misheard)\")"
    }
    return lines.joined(separator: "\n")
  }
}
