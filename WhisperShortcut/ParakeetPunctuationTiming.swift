import Foundation

/// Tells a punctuation mark the speaker SAID from one Parakeet GUESSED, for
/// `PunctuationMode.spokenOnly`.
///
/// Parakeet writes a spoken "Komma" / "Punkt" / "Fragezeichen" / "Ausrufezeichen" as "," / "." /
/// "?" / "!" itself, so the text alone cannot tell those apart from the marks it adds from
/// intonation. The token timings can: a spoken mark has speech time behind it (the speaker said a
/// word and kept going or let the recording run on), a guessed mark sits flush against the next
/// word or against the end of the audio. Measured with `LiveDictationPilotTests.punctuationTiming`
/// over 6 voices and 228 marks:
///
/// - Mid-text ",": `gap to the next token >= 0.120 s` keeps 34 of 43 spoken and 0 of 34 guessed.
/// - Final ".": `audio tail after the mark >= 0.400 s`. Raised to 0.400 s on 2026-11-04 from
///   live-piece measurements: 21/23 spoken vs 0/42 guessed piece-end marks.
///
/// "?" and "!" use the same timing rule as "," and ".". Mid-text, the gap to the next token must
/// be at least `minGapToNextToken`; a final mark needs an audio tail of at least
/// `minTailAfterFinalMark`. A spoken "Fragezeichen" / "Ausrufezeichen" comes out of Parakeet as
/// "?" / "!" with that signature, so the model's mark is kept when the timing says it was spoken.
/// When no timings are available, `SpokenPunctuation.stripModelPunctuation` still drops the
/// model's "?" and "!". When timings exist but the marks cannot be matched to them (count
/// mismatch), `fallbackWithoutTiming` keeps the model's marks instead of dropping every comma.
enum ParakeetPunctuationTiming {
  /// Mid-text mark ("," "." "?" "!"): minimum silence to the next token for the mark to count as spoken.
  static let minGapToNextToken: TimeInterval = 0.120
  /// Mid-text "," directly after a digit token: shorter minimum gap (see `spokenMarks`).
  static let minGapAfterDigitComma: TimeInterval = 0.060
  /// Final mark ("," "." "?" "!"): minimum audio left after it. Stricter than the mid-text gap
  /// because a recording always runs a little past the last word. 0.400 s since 2026-11-04
  /// (was 0.240 s): on live pieces this keeps 21 of 23 spoken piece-end marks and 0 of 42 guessed.
  static let minTailAfterFinalMark: TimeInterval = 0.400

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

  /// The text when the marks cannot be matched to the tokens (`filter` returned nil). The model's
  /// commas, "?", "!" and periods stay: a spoken salutation comma or question mark is worse lost
  /// than a guessed comma kept, and the timing can no longer tell them apart. Only semicolons go
  /// (Parakeet never says one; a spoken "Semikolon" is converted later).
  static func fallbackWithoutTiming(_ text: String) -> String {
    SpokenPunctuation.stripModelPunctuation(from: spacingGluedCommas(text), timedMarks: true)
  }

  /// One verdict per mark token, in order: true = the speaker said it, false = Parakeet guessed it.
  /// "," "." "?" and "!" share one rule: a mark with a following token needs
  /// `minGapToNextToken` of silence before that token; the last mark needs `minTailAfterFinalMark`
  /// of audio after it.
  static func spokenMarks(tokens: [Token], audioDuration: TimeInterval) -> [Bool] {
    markIndexes(tokens).map { index in
      if index == tokens.count - 1 {
        return audioDuration - tokens[index].end >= minTailAfterFinalMark
      }
      let gap = tokens[index + 1].start - tokens[index].end
      // A comma the speaker says right after a number ("11,8 Komma Natrium") is glued in time to
      // the digit token; the pause shows up shorter. Commas after words keep the strict gap.
      if bare(tokens[index]) == ",", index > 0, bare(tokens[index - 1]).last?.isNumber == true {
        return gap >= minGapAfterDigitComma
      }
      return gap >= minGapToNextToken
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
