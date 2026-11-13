import Foundation

/// Filters FluidAudio CTC vocabulary replacements before they rewrite a transcript.
///
/// The booster is allowed to correct a misspelt glossary term. It is not allowed to
/// delete a lab value sitting next to one ("HbA1c 7,2" → "HbA1c"), swap one glossary
/// drug for another ("Bisoprolol" → "Metoprolol"), or swallow a neighbouring drug
/// ("weiter Bisoprolol" → "Metoprolol"). Those showed up on clean speech in
/// `benchmarks/parakeet-glossary-casing` and are worse than leaving the misspelling.
enum ParakeetVocabularyGuard {
  struct Replacement: Equatable {
    let originalSpan: String
    let term: String
  }

  /// Accepted only if all of these hold:
  /// (a) every digit run in the span also occurs among the term's digit runs
  ///     ("B 12" → "B12" passes, "HbA1c 7,2" → "HbA1c" does not),
  /// (b) neither the whole span nor any single word of it (whitespace-split,
  ///     punctuation stripped, compared via `GlossaryDocument.fold`) is a glossary
  ///     term other than the replacement ("weiter Bisoprolol" → "Metoprolol" fails),
  /// (c) the span has no more words than the term plus one, unless it is the term spelled
  ///     out in pieces ("Vers Med V" → "VersMedV", "G d B" → "GdB", "A D L" → "ADL"),
  /// (d) spelling similarity: with whitespace and punctuation removed, the folded span and
  ///     folded term have a normalized Levenshtein similarity (1 - distance / max length) of
  ///     at least 0.6 ("erreicht" → "Merkzeichen" 0.55, "Ah" → "ADL" 0.33 fail;
  ///     "Metotrexat" → "Methotrexat" 0.91, "Vers Med V" → "VersMedV" 1.0 pass), and a
  ///     multi-word span that already contains the term as a word is not collapsed onto it
  ///     ("im ADL" → "ADL" would swallow "im"),
  /// (e) no word of the span is a spoken-punctuation command word
  ///     (`SpokenPunctuation.commandWords`): "Komma" is never rewritten into "Kizomba".
  /// (f) unless the folded span (punctuation stripped) equals the folded term, not every
  ///     whitespace-separated word of the span is an ordinary German word
  ///     (`GermanCommonWords`): "weiter" is never rewritten into "Seiter". A pure casing
  ///     fix still passes ("GDB" → "GdB"), and a span with any uncommon word still passes
  ///     ("Wir Belsäule" → "Wirbelsäule").
  /// (g) a single-word span that is only the first part of a hyphenated term is not rewritten
  ///     into the whole term: "Hüfte" → "Hüft-TEP" would add a "TEP" nobody said. The speaker
  ///     says the compound in pieces ("Hüft TEP", two words) when they mean it.
  static func accepts(_ replacement: Replacement, glossaryTerms: [String]) -> Bool {
    let original = replacement.originalSpan
    let term = replacement.term

    if isOnlyLeadingPartOfCompound(original, term: term) { return false }

    let termRuns = Set(digitRuns(term))
    if digitRuns(original).contains(where: { !termRuns.contains($0) }) { return false }

    let foldedTerm = GlossaryDocument.fold(term)
    let foldedOtherTerms = Set(
      glossaryTerms.map { GlossaryDocument.fold($0) }.filter { $0 != foldedTerm })
    if foldedOtherTerms.contains(GlossaryDocument.fold(original)) { return false }
    for word in original.split(whereSeparator: { $0.isWhitespace || $0.isNewline }) {
      let stripped = word.trimmingCharacters(in: .punctuationCharacters)
      if !stripped.isEmpty, foldedOtherTerms.contains(GlossaryDocument.fold(stripped)) {
        return false
      }
    }

    let spelledOut = squashed(original) == squashed(term)
    if !spelledOut, wordCount(original) > wordCount(term) + 1 { return false }

    if similarity(original, term) < minimumSimilarity { return false }
    if isLongRealWordWithOtherStart(original, term: term) { return false }
    let words = original.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
    if words.count > wordCount(term),
      words.contains(where: {
        GlossaryDocument.fold($0.trimmingCharacters(in: .punctuationCharacters)) == foldedTerm
      })
    {
      return false
    }

    for word in original.split(whereSeparator: { $0.isWhitespace || $0.isNewline }) {
      let stripped = GlossaryDocument.fold(word.trimmingCharacters(in: .punctuationCharacters))
      if SpokenPunctuation.commandWords.contains(stripped) { return false }
    }

    if GlossaryDocument.fold(strippingPunctuation(original)) != foldedTerm {
      let spanWords = original.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).compactMap {
        piece -> String? in
        let cleaned = strippingPunctuation(String(piece))
        return cleaned.isEmpty ? nil : cleaned
      }
      if !spanWords.isEmpty, spanWords.allSatisfy(GermanCommonWords.contains) { return false }
    }
    return true
  }

  private static let minimumSimilarity = 0.6

  /// (h) A single long word (>= 8 letters) is a real word of its own, not a misspelt term, unless
  /// it is nearly the term (similarity >= 0.85) or starts with the same three letters:
  /// "Psychotherapie" / "Physiotherapie" (0.71 / 0.79) are never rewritten into "Hypnotherapie",
  /// "Hypnoterapie" still is.
  private static func isLongRealWordWithOtherStart(_ span: String, term: String) -> Bool {
    guard wordCount(span) == 1 else { return false }
    let word = squashed(span)
    guard word.count >= 8 else { return false }
    if similarity(span, term) >= 0.85 { return false }
    return word.prefix(3) != squashed(term).prefix(3)
  }

  /// Short everyday words a short all-caps glossary term ("AN", "ES") would otherwise capitalise.
  private static let shortEverydayWords: Set<String> = [
    "an", "ab", "es", "da", "im", "au", "so", "um", "er", "ja", "zu", "in", "ob", "am",
  ]

  private static func isEverydayShortTerm(_ term: String) -> Bool {
    guard term.count <= 3 else { return false }
    let lower = term.lowercased()
    return shortEverydayWords.contains(lower) || GermanCommonWords.contains(lower)
      || SpokenPunctuation.functionWords.contains(lower)
  }

  /// True when `span` is one word that starts like (or is the start of) the first part of a
  /// hyphenated `term` and is not the whole term: "Hüfte" for "Hüft-TEP".
  private static func isOnlyLeadingPartOfCompound(_ span: String, term: String) -> Bool {
    let parts = term.split(separator: "-").map { GlossaryDocument.fold(String($0)) }
      .filter { !$0.isEmpty }
    guard parts.count >= 2, let head = parts.first, head.count >= 3 else { return false }
    guard wordCount(span) == 1 else { return false }
    let word = GlossaryDocument.fold(span.trimmingCharacters(in: .punctuationCharacters))
    guard !word.isEmpty, word != parts.joined() else { return false }
    return word.hasPrefix(head) || head.hasPrefix(word)
  }

  private static let trailingMarks: Set<Character> = [",", ".", "?", "!"]

  /// Normalized Levenshtein similarity of the folded strings, whitespace and punctuation removed.
  static func similarity(_ a: String, _ b: String) -> Double {
    let x = squashed(a)
    let y = squashed(b)
    let longest = max(x.count, y.count)
    if longest == 0 { return 1 }
    return 1 - Double(editDistance(x, y)) / Double(longest)
  }

  private static func squashed(_ text: String) -> [Character] {
    GlossaryDocument.fold(text).filter { !$0.isWhitespace && !$0.isPunctuation && !$0.isSymbol }
      .map { $0 }
  }

  private static func editDistance(_ a: [Character], _ b: [Character]) -> Int {
    if a.isEmpty { return b.count }
    if b.isEmpty { return a.count }
    var previous = Array(0...b.count)
    for i in 1...a.count {
      var current = [i] + Array(repeating: 0, count: b.count)
      for j in 1...b.count {
        let cost = a[i - 1] == b[j - 1] ? 0 : 1
        current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
      }
      previous = current
    }
    return previous[b.count]
  }

  /// (f) Restores the glossary's own casing for whole words that match a term only
  /// case-insensitively ("GDB" → "GdB"). Limited to single-token terms with an internal capital
  /// ("GdB", "VersMedV", "HbA1c") or written fully upper-case ("ADL", "ACE"), so an ordinary
  /// capitalised noun such as "Merkzeichen" is never forced into a different case. A match glued
  /// to a following letter is left alone; one glued to the end of a preceding word gets a space
  /// when it carries a capital mid-word ("GesamtgdB" → "Gesamt GdB", see
  /// `isGluedToPrecedingWord`). A match glued to a digit run ("GDB50", Parakeet writing "GdB 50"
  /// without the space) becomes the term, a space and the digits ("GdB 50"), unless the term
  /// itself ends in a digit ("B12" is not split from a following digit).
  static func restoreGlossaryCasing(in text: String, glossaryTerms: [String]) -> String {
    var result = text
    for term in glossaryTerms where hasDistinctiveCasing(term) && !isEverydayShortTerm(term) {
      let endsInDigit = term.last?.isNumber ?? false
      var searchStart = result.startIndex
      while searchStart < result.endIndex,
        let range = result.range(
          of: term, options: .caseInsensitive, range: searchStart..<result.endIndex)
      {
        let beforeOK = range.lowerBound == result.startIndex
          || !isWordCharacter(result[result.index(before: range.lowerBound)])
        let afterOK = range.upperBound == result.endIndex
          || !isWordCharacter(result[range.upperBound])
        let glueDigits = !afterOK && !endsInDigit && result[range.upperBound].isNumber
        let glueWord = !beforeOK && (afterOK || glueDigits)
          && isGluedToPrecedingWord(range, in: result)
        if (beforeOK || glueWord) && (afterOK || glueDigits)
          && (glueWord || glueDigits || result[range] != term)
        {
          let replacement = (glueWord ? " " : "") + term + (glueDigits ? " " : "")
          let offset = result.distance(from: result.startIndex, to: range.lowerBound)
          result.replaceSubrange(range, with: replacement)
          searchStart = result.index(result.startIndex, offsetBy: offset + replacement.count)
        } else {
          searchStart = range.upperBound
        }
      }
    }
    return result
  }

  /// True when the match at `range` ends a word it was glued onto by the model: "GesamtgdB50"
  /// (Parakeet for "Gesamt GdB 50"). Only a capital inside the matched letters makes it a term,
  /// which no German word has mid-word ("Radler" never yields "ADL"), and only after an ordinary
  /// capitalised word of at least three letters that has a lower-case letter ("GESAMTGDB" stays).
  private static func isGluedToPrecedingWord(_ range: Range<String.Index>, in text: String) -> Bool {
    guard text[range].contains(where: \.isUppercase) else { return false }
    var start = range.lowerBound
    while start > text.startIndex, text[text.index(before: start)].isLetter {
      start = text.index(before: start)
    }
    if start > text.startIndex, text[text.index(before: start)].isNumber { return false }
    let head = text[start..<range.lowerBound]
    return head.count >= 3 && head.first?.isUppercase == true && head.contains(where: \.isLowercase)
  }

  private static func hasDistinctiveCasing(_ term: String) -> Bool {
    guard term.count >= 2, !term.contains(where: \.isWhitespace) else { return false }
    let letters = term.filter(\.isLetter)
    guard !letters.isEmpty else { return false }
    if letters.allSatisfy(\.isUppercase) { return true }
    return letters.dropFirst().contains(where: \.isUppercase)
  }

  /// Applies only the accepted replacements to `original` (never FluidAudio's
  /// already-rewritten `rescored.text`). First occurrence of each span that is not
  /// glued to a letter or digit on either side, in order.
  static func apply(
    to original: String,
    replacements: [Replacement],
    glossaryTerms: [String]
  ) -> (text: String, accepted: Int, rejected: Int) {
    var text = original
    var accepted = 0
    var rejected = 0
    for replacement in replacements {
      guard accepts(replacement, glossaryTerms: glossaryTerms) else {
        rejected += 1
        continue
      }
      guard let range = firstBoundedRange(of: replacement.originalSpan, in: text) else {
        rejected += 1
        continue
      }
      // The marks at the end of the span stay: the term replaces the words, not the comma or
      // question mark behind them. Dropping one shifts the mark count against the token timings
      // (`ParakeetPunctuationTiming.filter`) and every mark of the text is lost to the fallback.
      var term = replacement.term
      for mark in replacement.originalSpan.reversed().prefix(while: { trailingMarks.contains($0) })
        .reversed() where term.last != mark
      {
        term.append(mark)
      }
      text.replaceSubrange(range, with: term)
      accepted += 1
    }
    return (text, accepted, rejected)
  }

  /// First match whose neighbouring characters are not letters or digits.
  private static func firstBoundedRange(of span: String, in text: String) -> Range<String.Index>? {
    guard !span.isEmpty else { return nil }
    var searchStart = text.startIndex
    while searchStart < text.endIndex,
      let range = text.range(of: span, range: searchStart..<text.endIndex)
    {
      let beforeOK = range.lowerBound == text.startIndex
        || !isWordCharacter(text[text.index(before: range.lowerBound)])
      let afterOK = range.upperBound == text.endIndex
        || !isWordCharacter(text[range.upperBound])
      if beforeOK && afterOK { return range }
      searchStart = text.index(after: range.lowerBound)
    }
    return nil
  }

  private static func isWordCharacter(_ character: Character) -> Bool {
    character.isLetter || character.isNumber
  }

  /// Maximal runs of digits, e.g. "HbA1c 7,2" → ["1", "7", "2"].
  private static func digitRuns(_ text: String) -> [String] {
    var runs: [String] = []
    var current = ""
    for character in text {
      if character.isNumber {
        current.append(character)
      } else if !current.isEmpty {
        runs.append(current)
        current = ""
      }
    }
    if !current.isEmpty { runs.append(current) }
    return runs
  }

  private static func wordCount(_ text: String) -> Int {
    text.split { $0.isWhitespace || $0.isNewline }.count
  }

  /// Punctuation removed, whitespace kept ("weiter," → "weiter", "G d B" stays three words).
  private static func strippingPunctuation(_ text: String) -> String {
    String(text.unicodeScalars.filter { !CharacterSet.punctuationCharacters.contains($0) })
  }
}
