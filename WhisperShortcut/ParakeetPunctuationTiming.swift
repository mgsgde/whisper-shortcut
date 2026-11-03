import Foundation

/// Tells a punctuation mark the speaker SAID from one Parakeet GUESSED, for
/// `PunctuationMode.spokenOnly`.
///
/// Parakeet writes a spoken "Komma" / "Punkt" as "," / "." itself, so the text alone cannot tell
/// those apart from the commas and periods it adds from intonation. The token timings can: a
/// spoken mark has speech time behind it (the speaker said a word and kept going or let the
/// recording run on), a guessed mark sits flush against the next word or against the end of the
/// audio. Measured with `LiveDictationPilotTests.punctuationTiming` over 6 voices and 228 marks:
///
/// - Mid-text ",": `gap to the next token >= 0.120 s` keeps 34 of 43 spoken and 0 of 34 guessed.
/// - Final ".": `audio tail after the mark >= 0.240 s` keeps 27 of 38 spoken and 1 of 72 guessed.
///
/// "?" and "!" are always guessed: a spoken "Fragezeichen" / "Ausrufezeichen" is applied by
/// `SpokenPunctuation.apply` from the words, never taken from the model's mark.
enum ParakeetPunctuationTiming {
  /// Mid-text mark ("," or "."): minimum silence to the next token for the mark to count as spoken.
  static let minGapToNextToken: TimeInterval = 0.120
  /// Final mark: minimum audio left after it. Stricter than the mid-text gap because a recording
  /// always runs a little past the last word.
  static let minTailAfterFinalMark: TimeInterval = 0.240

  /// One Parakeet token with its timing, as plain values (the caller maps FluidAudio's type).
  struct Token: Equatable {
    var text: String
    var start: TimeInterval
    var end: TimeInterval
  }

  /// The result of applying the rule to a text.
  struct Filtered: Equatable {
    var text: String
    var kept: Int
    var dropped: Int
  }

  private static let markCharacters: Set<Character> = [",", ".", "?", "!"]

  /// The token without SentencePiece's word marker and surrounding whitespace.
  private static func bare(_ token: Token) -> String {
    token.text.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\u{2581}")))
  }

  private static func startsWord(_ token: Token) -> Bool {
    guard let first = token.text.first else { return false }
    return first == "\u{2581}" || first.isWhitespace
  }

  /// Indexes of the tokens that are a mark at the end of a word. A "." or "," inside a number or
  /// an abbreviation token run ("3.5", "1,2") is part of the next word's pieces, not a mark.
  private static func markIndexes(_ tokens: [Token]) -> [Int] {
    tokens.indices.filter { index in
      let mark = bare(tokens[index])
      guard mark.count == 1, let character = mark.first, markCharacters.contains(character) else {
        return false
      }
      if index == tokens.count - 1 || startsWord(tokens[index + 1]) { return true }
      // Parakeet sometimes writes a spoken "Komma" glued to the next word ("50,Merkzeichen"):
      // the next token then continues without a word marker and starts with a letter.
      return character == "," && (bare(tokens[index + 1]).first?.isLetter ?? false)
    }
  }

  /// Puts the missing space after a comma glued to a letter (",Merkzeichen" → ", Merkzeichen").
  /// A comma before a digit ("3,5") is a decimal comma and stays. Applied to every Parakeet
  /// output, in every punctuation mode.
  static func spacingGluedCommas(_ text: String) -> String {
    text.replacingOccurrences(
      of: ",(?=\\p{L})", with: ", ", options: .regularExpression)
  }

  /// One verdict per mark token, in order: true = the speaker said it, false = Parakeet guessed it.
  static func spokenMarks(tokens: [Token], audioDuration: TimeInterval) -> [Bool] {
    markIndexes(tokens).map { index in
      let mark = bare(tokens[index])
      if mark == "?" || mark == "!" { return false }
      if index == tokens.count - 1 {
        return audioDuration - tokens[index].end >= minTailAfterFinalMark
      }
      return tokens[index + 1].start - tokens[index].end >= minGapToNextToken
    }
  }

  /// Removes the guessed marks from `text`. The n-th mark in the text (a mark character at the end
  /// of a word) is the n-th mark token. Nil when the counts differ, so the caller falls back.
  ///
  /// A dropped "." that was followed by a capitalised function word lowers that word again
  /// ("Hallo. Und weiter" → "Hallo und weiter"); nouns keep their capital. A mid-text "." after a
  /// number or a short abbreviation ("5. Lendenwirbel", "z. B.") is never dropped: Parakeet
  /// writes it without a pause and it is not a sentence end.
  static func filter(text: String, tokens: [Token], audioDuration: TimeInterval) -> Filtered? {
    let verdicts = spokenMarks(tokens: tokens, audioDuration: audioDuration)
    let characters = Array(text)
    var markPositions: [Int] = []
    var gluedCommas = Set<Int>()
    for (i, character) in characters.enumerated() where markCharacters.contains(character) {
      let endsWord = i + 1 == characters.count || characters[i + 1].isWhitespace
      let followsWord = i > 0 && !characters[i - 1].isWhitespace
      let glued = character == "," && i + 1 < characters.count && characters[i + 1].isLetter
      if (endsWord || glued) && followsWord {
        markPositions.append(i)
        if glued { gluedCommas.insert(i) }
      }
    }
    guard markPositions.count == verdicts.count else { return nil }

    var drop = Set<Int>()
    var kept = 0
    for (n, position) in markPositions.enumerated() {
      var spoken = verdicts[n]
      let isFinal = !characters[(position + 1)...].contains { !$0.isWhitespace }
      if !spoken, characters[position] == ".", !isFinal,
        isAbbreviationOrOrdinal(before: position, in: characters)
      {
        spoken = true
      }
      if spoken { kept += 1 } else { drop.insert(position) }
    }

    var result = ""
    var lowerNextWord = false
    var index = 0
    while index < characters.count {
      let character = characters[index]
      if drop.contains(index) {
        if gluedCommas.contains(index) { result.append(" ") }
        if character == "." || character == "?" || character == "!" { lowerNextWord = true }
        index += 1
        continue
      }
      if lowerNextWord, character.isLetter {
        var end = index
        while end < characters.count, characters[end].isLetter { end += 1 }
        let word = String(characters[index..<end])
        result += SpokenPunctuation.lowercasingFunctionWord(word) ?? word
        index = end
        lowerNextWord = false
        continue
      }
      if !character.isWhitespace { lowerNextWord = false }
      result.append(character)
      if gluedCommas.contains(index) { result.append(" ") }
      index += 1
    }
    // A dropped final mark leaves trailing spaces only if the text had them; keep the text as is.
    return Filtered(text: result, kept: kept, dropped: drop.count)
  }

  private static let abbreviations: Set<String> = [
    "usw", "bzw", "ca", "vgl", "dr", "nr", "evtl", "ggf", "inkl", "etc", "bspw", "ggfs", "max",
    "min", "mind", "ev", "sog", "od", "bez", "betr", "zzgl", "abs", "str",
  ]

  private static func isAbbreviationOrOrdinal(before position: Int, in characters: [Character]) -> Bool {
    var start = position
    while start > 0, characters[start - 1].isLetter || characters[start - 1].isNumber { start -= 1 }
    let word = String(characters[start..<position])
    guard !word.isEmpty else { return false }
    if word.allSatisfy(\.isNumber) { return true }
    if word.count == 1 { return true }
    return abbreviations.contains(word.lowercased())
  }
}
