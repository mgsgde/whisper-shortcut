import Foundation

/// Names from the focused text field, sent to GPT Transcribe as extra `keywords` (spelling hint
/// only). Design and measured result: `plans/active/dictate-field-hint.md`. The extractor is a
/// 1:1 port of `extract_terms` in `scripts/benchmark-field-hint.py`.
enum DictationFieldHint {
  /// Only the last N characters of the text before the caret are considered.
  static let maxContextChars = 1000
  static let maxTerms = 20

  /// Set around the transcribe call in `MenuBarController`, read in `SpeechService`.
  @TaskLocal static var current: [String]?

  private static let stopwords: Set<String> = Set(
    ("Hallo Hi Hey Danke Sehr Geehrter Geehrte Herr Frau Liebe Lieber Moin Wir Ich Die Der Das Ein "
      + "Eine Bitte Kurze Frage Grüße Viele The Can Thanks Diagnose Patient Ticket Angebot Firma "
      + "Termin").split(separator: " ").map { $0.lowercased() })
  private static let stripChars = CharacterSet(charactersIn: ".,:;!?()\"'")

  /// Terms from the text before the caret: only the last `maxContextChars` characters, at most
  /// `maxTerms` terms; when capping, the terms nearest the caret win (the last ones in order).
  static func terms(fromTextBeforeCaret text: String) -> [String] {
    let clipped = String(text.suffix(maxContextChars))
    let all = extractTerms(clipped)
    return Array(all.suffix(maxTerms))
  }

  private static func strip(_ s: String) -> String {
    s.trimmingCharacters(in: stripChars)
  }

  private static func isUpperStart(_ s: String) -> Bool {
    s.first?.isUppercase ?? false
  }

  private static func ok(_ t: String) -> Bool {
    t.count >= 3 && isUpperStart(t) && !stopwords.contains(t.lowercased())
  }

  /// Capitalised, at least 3 chars, not a sentence-capitalised function word. A sentence-initial
  /// token (first token, or after `. ! ? :`) only counts if it also appears capitalised elsewhere;
  /// a first token ending in ":" is a speaker label. Hyphenated compounds stay whole and their
  /// part before the first hyphen is added too. Deduped, in order of appearance.
  static func extractTerms(_ field: String) -> [String] {
    var toks: [(clean: String, isStart: Bool)] = []
    var start = true
    for (i, sub) in field.split(whereSeparator: \.isWhitespace).enumerated() {
      let raw = String(sub)
      let isStart = start && !(i == 0 && raw.hasSuffix(":"))
      toks.append((strip(raw), isStart))
      if let last = raw.last { start = ".!?:".contains(last) }
    }
    var elsewhere = Set<String>()
    for t in toks where !t.isStart && isUpperStart(t.clean) { elsewhere.insert(t.clean) }
    var terms: [String] = []
    for (clean, isStart) in toks {
      if !ok(clean) || (isStart && !elsewhere.contains(clean)) { continue }
      var candidates = [clean]
      if clean.contains("-"), let head = clean.split(separator: "-", omittingEmptySubsequences: false).first {
        candidates.append(String(head))
      }
      for t in candidates where ok(t) && !terms.contains(t) { terms.append(t) }
    }
    return terms
  }
}
