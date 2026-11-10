import Foundation

/// Dictate Live — text at the cursor while speaking, Dragon-style (plans/active/live-dictate-insert.md).
///
/// The recording is cut at speech pauses (`ChunkedDictateRecorder.RotationPolicy.live`), each piece
/// is decoded once with offline Parakeet and the Glossary, and pasted at the cursor. Append-only:
/// a piece that has been inserted is never touched again — rewriting text in another app (undo
/// stacks, moved cursors, apps that reject synthetic edits) is the fragile part this design avoids.
///
/// This file is the pure half: who may use it, how pieces are joined, how the result is compared
/// with a whole-file decode. `LiveDictationSession` runs a recording; `MenuBarController` wires it.
enum LiveDictation {
  /// Why Dictate Live cannot start, in the order the user would fix it.
  enum Unavailable: Equatable {
    case duringMeeting
    case intelMac
    case notParakeet
    case notDownloaded

    var message: String {
      switch self {
      case .duringMeeting:
        return String(localized: "Dictate Live is not available during a meeting.")
      case .intelMac:
        return String(localized: "Dictate Live requires a Mac with Apple silicon.")
      case .notParakeet:
        return String(
          localized: "Dictate Live works with the offline Parakeet Ultra model. Select it in Settings → Dictate.")
      case .notDownloaded:
        return String(localized: "Download Parakeet Ultra in Settings → Dictate to use Dictate Live.")
      }
    }
  }

  enum StartDecision: Equatable {
    case startDictate
    case startLive
    case refuse(Unavailable)
  }

  static var isAppleSilicon: Bool {
    #if arch(arm64)
    return true
    #else
    return false
    #endif
  }

  /// The last character of the previous live dictation, kept in memory so the next one can be
  /// spaced and cased when the caret cannot be read (the sandboxed app gets `.unknown` from
  /// Accessibility in every app). Never persisted, never logged; it is patient text.
  struct LastInsertion: Equatable {
    let character: Character
    let bundleId: String
    let at: Date

    /// Older than this, the user has most likely moved on.
    static let maxAge: TimeInterval = 600

    /// The memory for a finished dictation, or nil when nothing was inserted or the target is unknown.
    static func make(insertedText: String, bundleId: String?, now: Date) -> LastInsertion? {
      guard let last = insertedText.last, let bundleId, !bundleId.isEmpty else { return nil }
      return LastInsertion(character: last, bundleId: bundleId, at: now)
    }

    /// A readable caret always wins. Only `.unknown` falls back to the memory, and only for the
    /// same app, within `maxAge`.
    static func seed(
      caret: FocusedTextContext.CaretContext, last: LastInsertion?, frontmostBundle: String?, now: Date
    ) -> FocusedTextContext.CaretContext {
      guard case .unknown = caret, let last, let frontmostBundle, last.bundleId == frontmostBundle else {
        return caret
      }
      let age = now.timeIntervalSince(last.at)
      guard age >= 0, age < maxAge else { return caret }
      return .character(last.character)
    }
  }

  /// One decoded Dictate Live piece as normal offline Dictate finishes a transcript: standalone
  /// fillers dropped, model punctuation stripped in "Only when spoken" mode, then the spoken
  /// layout commands. Edge line breaks ("neuer Absatz" at the very end of a piece) are kept —
  /// `LiveChunkJoiner` relies on them to lay out the next piece without adding a space after.
  /// `timedMarks`: the piece's commas, periods, "?" and "!" were already filtered by token timing
  /// (`ParakeetPunctuationTiming`, done in the decode for "Only when spoken"). Strip then removes
  /// only semicolons; a "?" or "!" the timing kept stays. Without timings, model "?" and "!" are
  /// still dropped.
  static func finishPiece(_ text: String, mode: PunctuationMode, timedMarks: Bool = false) -> String {
    let withoutFillers = removingFillers(text)
    let source =
      mode == .spokenOnly
      ? SpokenPunctuation.stripModelPunctuation(from: withoutFillers, timedMarks: timedMarks)
      : withoutFillers
    return SpokenPunctuation.apply(
      to: source, mode: mode, keepsEdgeBreaks: true, timedMarks: timedMarks)
  }

  /// Parakeet writes fillers ("Mm-hmm", "Ähm") into the record. Whole word, case-insensitive, plus
  /// one comma, period or semicolon glued on, and the spaces around them. "Um", "ah", "aha",
  /// "achso" and "oh" stay — they are real German words. A piece of only fillers comes back "".
  private static func removingFillers(_ text: String) -> String {
    let text = leadingOhRegex.stringByReplacingMatches(
      in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
    let range = NSRange(text.startIndex..., in: text)
    guard fillerRegex.firstMatch(in: text, range: range) != nil else { return text }
    let replaced = fillerRegex.stringByReplacingMatches(in: text, range: range, withTemplate: " ")
    let collapsed = fillerSpaceRun.stringByReplacingMatches(
      in: replaced, range: NSRange(replaced.startIndex..., in: replaced), withTemplate: " ")
    return collapsed.trimmingCharacters(in: .whitespaces)
  }

  // Parakeet hears the breath before a lone spoken command as "Oh," ("Oh, Doppelpunkt." for a piece
  // that is only "Doppelpunkt"), which turned the colon into "Oh:". "Oh" stays a real word
  // everywhere else; it goes only at the start of a piece, right before a spoken colon.
  // swiftlint:disable:next force_try
  private static let leadingOhRegex = try! NSRegularExpression(
    pattern: #"^[ \t]*oh[,.]?[ \t]+(?=doppel[ \t-]?(?:punkt|gun)\b)"#,
    options: [.caseInsensitive])

  // "hmm" is two or more m's; "hm" is the single one. Longer forms come first so a word boundary
  // still decides, and "ähm" is not eaten as "äh".
  // swiftlint:disable:next force_try
  private static let fillerRegex = try! NSRegularExpression(
    pattern: #"[ \t]*\b(?:mm-hmm|mmhmm|m-hm|mhm|hm{2,}|hm|ähm|äh|öhm|ehm)\b[,.;]?[ \t]*"#,
    options: [.caseInsensitive])
  // swiftlint:disable:next force_try
  private static let fillerSpaceRun = try! NSRegularExpression(pattern: #"[ \t]{2,}"#)

  /// Nil when Dictate Live can start. Offline Parakeet only: it decodes a sentence in ~0.1 s, so a
  /// piece appears right after the pause; a cloud model would add a network round trip per piece.
  /// The model must already be on disk — a recording start must never trigger a 700 MB download.
  /// The Accessibility permission is checked separately, at the start, with its own dialog.
  static func unavailableReason(
    model: TranscriptionModel, downloaded: Bool, appleSilicon: Bool, duringMeeting: Bool
  ) -> Unavailable? {
    if duringMeeting { return .duringMeeting }
    if !appleSilicon { return .intelMac }
    guard model.isOffline, model.offlineModelType?.engine == .parakeet else { return .notParakeet }
    return downloaded ? nil : .notDownloaded
  }

  static func startDecision(mode: DictateMode, unavailable: Unavailable?) -> StartDecision {
    switch mode {
    case .dictate: return .startDictate
    case .live:
      // During a live meeting, Live is never offered — the meeting already owns a dedicated
      // dictation segment, so the Dictate mode falls back to recording that instead of refusing.
      if unavailable == .duringMeeting { return .startDictate }
      if let reason = unavailable { return .refuse(reason) }
      return .startLive
    }
  }

  // MARK: - Comparing with the whole-file decode

  /// Word-level difference between what was inserted piece by piece and a single-shot decode of
  /// the whole recording, as counts only — never the words (dictations are patient notes). This is
  /// the measurement behind the plan's accuracy falsifier. Case and surrounding punctuation are
  /// ignored, so a sentence mark moved at a seam does not count.
  static func drift(inserted: String, wholeFile: String) -> (insertedWords: Int, wholeFileWords: Int, editDistance: Int) {
    let a = words(inserted)
    let b = words(wholeFile)
    return (a.count, b.count, editDistance(a, b))
  }

  static func words(_ text: String) -> [String] {
    text.split(whereSeparator: \.isWhitespace)
      .map { $0.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.symbols)) }
      .filter { !$0.isEmpty }
  }

  /// Levenshtein distance over words, two rows of memory.
  static func editDistance(_ a: [String], _ b: [String]) -> Int {
    if a.isEmpty { return b.count }
    if b.isEmpty { return a.count }
    var previous = Array(0...b.count)
    var current = Array(repeating: 0, count: b.count + 1)
    for i in 1...a.count {
      current[0] = i
      for j in 1...b.count {
        let substitution = previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
        current[j] = min(previous[j] + 1, current[j - 1] + 1, substitution)
      }
      swap(&previous, &current)
    }
    return previous[b.count]
  }
}

/// Turns decoded pieces into the exact strings to insert, append-only.
///
/// - **Spacing:** one space between pieces, none at the very start. `seed` is the character already
///   before the caret: a letter takes that leading space ("Basistherapie" + "Ah" → " Ah"),
///   whitespace or a line break there does not, and an unknown caret keeps today's start. Also
///   none after a line break, none before a piece that starts with a line break
///   (`SpokenPunctuation` turns "neuer Absatz" into one) or with closing punctuation, none after
///   "(" (the piece ended on "Klammer auf"; the next word sits inside the parentheses), none on
///   either side of a slash ("Schrägstrich" said in one piece and the next word in another must
///   still read "L4/L5", not "L4/ L5" or "L4 /L5").
/// - **The same mark on both sides of a piece boundary** (".", ",", "?", "!", ";", ":"): Parakeet
///   writes it again at the start of the next breath. When the text so far ends with that mark
///   (trailing spaces aside), the leading copy is dropped, and one space after it too
///   ("ganz gut." + "." stays "ganz gut.", "Müller," + ", ganz lieben Dank").
/// - **A period at a breath:** Parakeet punctuates each piece on its own, so a pause mid-sentence
///   can end a piece with "." although the sentence goes on. A piece's final period is therefore
///   held back and emitted with the next piece — dropped when that piece starts with a lowercase
///   letter (the sentence clearly continued), kept otherwise, and flushed by `finish()` at Stop.
///   Abbreviations ("z. B.", "Dr.", "ca.", numbers) are never held: only a period after a word of
///   five or more letters without inner dots is. German capitalises nouns, so a capital start is
///   weak evidence; the period is then kept, which is what not holding it would have done anyway.
///   Never held at all when `holdsPeriods` is false (`PunctuationMode.spokenOnly`): every period
///   there was said on purpose, so there is nothing ambiguous to wait on.
/// - **A capital after a pause:** Parakeet capitalises the first word of every piece. With
///   `holdsPeriods` false, when the text so far — the seeded character plus `inserted` — is
///   non-empty and does not end (trailing spaces aside) in ". ! ? :", or a newline, that capital
///   is taken off a function word
///   (`SpokenPunctuation.lowercasingFunctionWord`). The sentence reads "klagt über"; after a
///   period that was actually said, "Ende. Über" stays. Nouns and verbs keep Parakeet's capital.
///
/// Pure value type; unit-tested directly.
struct LiveChunkJoiner: Equatable {
  /// Everything handed out so far, held marks included once emitted. The character `seed` read
  /// from the field is not included — it was already in the document.
  private(set) var inserted = ""
  private var heldPeriod = false
  /// One character already before the caret, or empty when the field starts there or the caret
  /// could not be read. Spacing and the spoken-only lower-case check see this plus `inserted`.
  private var precedingText = ""
  /// False in "Only when spoken" mode. The struct's other stored properties are private, so the
  /// synthesized memberwise init is file-private and `LiveChunkJoiner(holdsPeriods:)` cannot be
  /// called from another file — set this property on the instance after `LiveChunkJoiner()`.
  var holdsPeriods = true

  /// `.character` is the character already before the caret. Start-of-text and unknown leave the
  /// first piece unspaced, which is today's behaviour.
  mutating func seed(_ context: FocusedTextContext.CaretContext) {
    switch context {
    case .character(let character):
      precedingText = String(character)
    case .startOfText, .unknown:
      precedingText = ""
    }
  }

  /// The text to insert for `piece` (possibly empty).
  mutating func next(_ piece: String) -> String {
    var body = piece.trimmingCharacters(in: .whitespaces)
    guard !body.isEmpty else { return "" }

    // Across a piece boundary at most one blank line: "neuer Absatz" at the end of one piece and
    // "neue Zeile" at the start of the next must not stack up to three breaks.
    body = Self.limitingBreaks(body, after: precedingText + inserted)
    guard !body.isEmpty else { return "" }

    if !holdsPeriods {
      body = Self.lowercaseLeadingFunctionWord(body, after: precedingText + inserted)
    }

    var out = ""
    if heldPeriod {
      heldPeriod = false
      if !Self.startsWithLowercaseLetter(body) { out += "." }
    }
    // After the held period, so a period just emitted still counts as "already ends with '.'".
    body = Self.droppingDuplicateLeadingMark(body, after: precedingText + inserted + out)
    if body.isEmpty {
      guard !out.isEmpty else { return "" }
      inserted += out
      return out
    }
    let before = precedingText + inserted + out
    // Whitespace (a space or a line break already in the field, or a break this joiner wrote)
    // already separates the next piece, so it must not gain a second space. "(" neither: the next
    // word is inside the parentheses.
    if let last = before.last, !last.isWhitespace, last != "/", last != "(",
      let first = body.first, !first.isNewline, first != "/", !Self.closingPunctuation.contains(first)
    {
      out += " "
    }
    if holdsPeriods, Self.holdsFinalPeriod(body) {
      body.removeLast()
      heldPeriod = true
    }
    out += body
    inserted += out
    return out
  }

  /// At Stop: the period still held back, if any.
  mutating func finish() -> String {
    guard heldPeriod else { return "" }
    heldPeriod = false
    inserted += "."
    return "."
  }

  static let closingPunctuation: Set<Character> = [",", ".", ";", ":", "!", "?", ")", "]", "»", "“", "…"]

  private static let boundaryMarks: Set<Character> = [".", ",", "?", "!", ";", ":"]

  /// Drops a leading mark the text so far already ends with, and one space after that mark.
  private static func droppingDuplicateLeadingMark(_ body: String, after prior: String) -> String {
    guard let mark = body.first, boundaryMarks.contains(mark) else { return body }
    var end = prior
    while end.last == " " || end.last == "\t" { end.removeLast() }
    guard end.last == mark else { return body }
    var rest = body.dropFirst()
    if rest.first == " " { rest = rest.dropFirst() }
    return String(rest)
  }

  /// Caps the line breaks where `body` meets the text so far at two ("\n\n"): the breaks already at
  /// the end of `prior` count, and surplus ones at the start of `body` are dropped.
  private static func limitingBreaks(_ body: String, after prior: String) -> String {
    let lead = body.prefix(while: { $0.isNewline || $0 == " " || $0 == "\t" })
    let leadBreaks = lead.filter(\.isNewline).count
    guard leadBreaks > 0 else { return body }
    var priorBreaks = 0
    for character in prior.reversed() {
      if character.isNewline {
        priorBreaks += 1
      } else if character != " " && character != "\t" {
        break
      }
    }
    let allowed = max(0, 2 - priorBreaks)
    guard leadBreaks > allowed else { return body }
    return String(repeating: "\n", count: allowed) + body.dropFirst(lead.count)
  }

  /// Parakeet capitalises the first word after a pause. Mid-sentence, in spoken-only mode, that
  /// capital belongs only on a noun or a verb — see the struct comment. After a line break the
  /// last real mark decides: a comma (the salutation's, "Frau Müller,⏎Vielen Dank") makes the
  /// word lower-case again unless it may be a noun (`lowercasingAfterSalutationComma`); after
  /// ". ! ? :" or with no mark before, it stays capital.
  private static func lowercaseLeadingFunctionWord(_ body: String, after inserted: String) -> String {
    let prior = inserted.trimmingCharacters(in: .whitespaces)
    let lead = body.prefix(while: { $0.isNewline || $0 == " " || $0 == "\t" })
    let rest = body.dropFirst(lead.count)
    if lead.contains(where: \.isNewline) || prior.last?.isNewline == true {
      let beforeBreak = inserted.trimmingCharacters(in: .whitespacesAndNewlines).last
      guard beforeBreak == ",", !rest.isEmpty else { return body }
      let word = String(rest.prefix(while: \.isLetter))
      guard let lowered = SpokenPunctuation.lowercasingAfterSalutationComma(word) else { return body }
      return String(lead) + lowered + rest.dropFirst(word.count)
    }
    guard let last = prior.last, last != ".", last != "!", last != "?", last != ":"
    else { return body }
    let split = body.firstIndex(where: \.isWhitespace)
    let word = split.map { String(body[..<$0]) } ?? body
    guard let lowered = SpokenPunctuation.lowercasingFunctionWord(word) else { return body }
    guard let split else { return lowered }
    return lowered + body[split...]
  }

  static func startsWithLowercaseLetter(_ text: String) -> Bool {
    guard let first = text.first else { return false }
    return first.isLetter && first.isLowercase
  }

  static func holdsFinalPeriod(_ text: String) -> Bool {
    guard text.hasSuffix("."), !text.hasSuffix(".."),
      let lastWord = text.split(whereSeparator: \.isWhitespace).last
    else { return false }
    let word = lastWord.dropLast()
    guard !word.contains(".") else { return false }
    return word.filter(\.isLetter).count >= 5 && word.allSatisfy { $0.isLetter || $0 == "-" }
  }
}
