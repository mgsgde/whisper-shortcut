import Foundation

/// Flags content words in a Dictate Prompt (⌘2) output that the dictation itself does not contain.
///
/// In a medical-practice setting the local LLM reorders a dictated note into sections
/// (Anamnese / Befund / Therapie). The risk is not bad wording but invented content, for example a
/// Therapie section that the model fills with plausible treatments nobody dictated. This check is a
/// deterministic word comparison between output and sources. It never edits the text; the caller
/// only shows the returned words as a warning.
///
/// It catches additions only. A removed negation ("kein Schwindel" → "Schwindel") is an omission, so
/// negations sit in the stopword list on purpose.
enum DictationFidelityCheck {

  /// Content words of `output` with no counterpart in any of `sources` (the transcript, plus the
  /// selected text when there is one). Deduplicated by normalized form, in order of first
  /// occurrence, original spelling from `output`.
  static func unsupportedWords(in output: String, sources: [String]) -> [String] {
    let sourceTokenLists = sources.map { tokens(in: $0).map { normalize($0) } }
    var sourceForms = Set<String>()
    var sourceStems = Set<String>()
    var compounds = Set<String>()
    var compoundStems = Set<String>()
    for list in sourceTokenLists {
      for form in list {
        sourceForms.insert(form)
        sourceStems.insert(stem(form))
      }
      // A dictated "Lenden Wirbelsäule" comes back as "Lendenwirbelsäule".
      for (first, second) in zip(list, list.dropFirst()) {
        let joined = first + second
        compounds.insert(joined)
        compoundStems.insert(stem(joined))
      }
    }

    var seen = Set<String>()
    var result: [String] = []
    for token in outputContentTokens(of: output) {
      let form = normalize(token)
      let supported =
        sourceForms.contains(form)
        || sourceStems.contains(stem(form))
        || compounds.contains(form)
        || compoundStems.contains(stem(form))
      if supported || !seen.insert(form).inserted { continue }
      result.append(token)
    }
    return result
  }

  // MARK: - Output tokens

  /// Markers the prompt itself tells the model to write. They are not content, so they go first.
  private static let markers = ["(nicht diktiert)", "[?]", "[Zuordnung prüfen]"]

  /// Section headings that may appear anywhere. "diagnose" is missing on purpose: an invented
  /// diagnosis has to be flagged.
  private static let headingWords: Set<String> = ["anamnese", "befund", "therapie", "verlauf"]

  /// Original-spelling tokens of `output` that count as content words: no markers, no heading
  /// lines, no heading words, no stopwords, no short noise.
  private static func outputContentTokens(of output: String) -> [String] {
    var text = output
    for marker in markers {
      text = text.replacingOccurrences(of: marker, with: " ", options: .caseInsensitive)
    }
    var result: [String] = []
    for line in text.components(separatedBy: .newlines) where !isHeadingLine(line) {
      for token in tokens(in: line) where isContent(token) {
        result.append(token)
      }
    }
    return result
  }

  /// A whole line that is a section heading, with or without Markdown decoration:
  /// "## Befund", "**Therapie:**", "Weitere Hinweise:". "Befund: Psoas rechts" is not one.
  private static func isHeadingLine(_ line: String) -> Bool {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    if trimmed.hasPrefix("#") { return true }
    let decoration = CharacterSet(charactersIn: "#*_ ")
    var core = trimmed
    while let first = core.unicodeScalars.first, decoration.contains(first) { core.removeFirst() }
    while let last = core.unicodeScalars.last, decoration.contains(last) { core.removeLast() }
    guard core.hasSuffix(":") else { return false }
    let words = core.dropLast().split(whereSeparator: { $0.isWhitespace })
    return (1...3).contains(words.count)
  }

  /// Splits on everything that is not a letter or digit, so "L4/L5" and "ISG-Blockade" fall apart
  /// into the parts a dictation would have spoken separately.
  private static func tokens(in text: String) -> [String] {
    text.precomposedStringWithCanonicalMapping
      .components(separatedBy: CharacterSet.alphanumerics.inverted)
      .filter { !$0.isEmpty }
  }

  /// Whether a raw token is worth checking at all.
  private static func isContent(_ token: String) -> Bool {
    let form = normalize(token)
    if headingWords.contains(form) { return false }
    if token.contains(where: { $0.isNumber }) { return true }
    if stopwords.contains(form) { return false }
    // Short words are noise ("zu", "bd"), but an uppercase "M" is an abbreviation someone added.
    if token.count < 3 { return token == token.uppercased() }
    return true
  }

  // MARK: - Normalization

  /// Lowercased, diacritics folded, ß as "ss", and number words as digits.
  private static func normalize(_ token: String) -> String {
    let folded = token
      .folding(
        options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "de_DE")
      )
      .replacingOccurrences(of: "ß", with: "ss")
    return numberWords[folded] ?? folded
  }

  /// Dictation says "fünf", the output writes "5" (and the other way round). Keys are already folded.
  private static let numberWords: [String: String] = [
    "null": "0", "eins": "1", "zwei": "2", "drei": "3", "vier": "4", "funf": "5", "sechs": "6",
    "sieben": "7", "acht": "8", "neun": "9", "zehn": "10", "elf": "11", "zwolf": "12",
    "dreizehn": "13", "vierzehn": "14", "funfzehn": "15", "sechzehn": "16", "siebzehn": "17",
    "achtzehn": "18", "neunzehn": "19", "zwanzig": "20", "dreissig": "30", "vierzig": "40",
    "funfzig": "50", "sechzig": "60", "siebzig": "70", "achtzig": "80", "neunzig": "90",
    "hundert": "100",
    "zero": "0", "one": "1", "two": "2", "three": "3", "four": "4", "five": "5", "six": "6",
    "seven": "7", "eight": "8", "nine": "9", "ten": "10", "eleven": "11", "twelve": "12",
    "thirteen": "13", "fourteen": "14", "fifteen": "15", "sixteen": "16", "seventeen": "17",
    "eighteen": "18", "nineteen": "19", "twenty": "20",
  ]

  /// Inflection suffixes, longest first, so "Schmerzen" matches "Schmerz" and "kraniosakraler"
  /// matches "kraniosakrale".
  private static let suffixes = ["ern", "em", "en", "er", "es", "e", "n", "s"]

  /// Normalized form without its longest inflection suffix, if at least 4 characters stay.
  private static func stem(_ form: String) -> String {
    for suffix in suffixes where form.hasSuffix(suffix) && form.count - suffix.count >= 4 {
      return String(form.dropLast(suffix.count))
    }
    return form
  }

  /// Function words, German and English. Folded form (no umlauts). "nicht"/"kein" are here because
  /// dropping a negation is an omission, which this check does not look for.
  private static let stopwords: Set<String> = [
    "und", "oder", "aber", "der", "die", "das", "des", "den", "dem", "ein", "eine", "einer",
    "eines", "einem", "einen", "mit", "im", "in", "am", "an", "auf", "bei", "bis", "zu", "zur",
    "zum", "von", "vom", "seit", "nach", "vor", "uber", "unter", "aus", "fur", "ohne", "gegen",
    "durch", "als", "wie", "so", "auch", "noch", "nur", "sehr", "ist", "sind", "war", "wird",
    "werden", "wurde", "hat", "haben", "er", "sie", "es", "ich", "wir", "ihr", "man", "sich",
    "nicht", "kein", "keine", "keinen", "keiner",
    "the", "a", "and", "or", "of", "to", "on", "at", "for", "with", "is", "are", "was", "be",
    "it", "this", "that",
  ]
}
