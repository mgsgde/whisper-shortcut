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

  enum FnStartDecision: Equatable {
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

  static func fnStartDecision(mode: FnStartMode, unavailable: Unavailable?) -> FnStartDecision {
    switch mode {
    case .dictate: return .startDictate
    case .live:
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
/// - **Spacing:** one space between pieces, none at the very start, none after a line break, none
///   before a piece that starts with a line break (`SpokenPunctuation` turns "neuer Absatz" into
///   one) or with closing punctuation.
/// - **A period at a breath:** Parakeet punctuates each piece on its own, so a pause mid-sentence
///   can end a piece with "." although the sentence goes on. A piece's final period is therefore
///   held back and emitted with the next piece — dropped when that piece starts with a lowercase
///   letter (the sentence clearly continued), kept otherwise, and flushed by `finish()` at Stop.
///   Abbreviations ("z. B.", "Dr.", "ca.", numbers) are never held: only a period after a word of
///   five or more letters without inner dots is. German capitalises nouns, so a capital start is
///   weak evidence; the period is then kept, which is what not holding it would have done anyway.
///
/// Pure value type; unit-tested directly.
struct LiveChunkJoiner: Equatable {
  /// Everything handed out so far, held marks included once emitted.
  private(set) var inserted = ""
  private var heldPeriod = false

  /// The text to insert for `piece` (possibly empty).
  mutating func next(_ piece: String) -> String {
    var body = piece.trimmingCharacters(in: .whitespaces)
    guard !body.isEmpty else { return "" }

    var out = ""
    if heldPeriod {
      heldPeriod = false
      if !Self.startsWithLowercaseLetter(body) { out += "." }
    }
    let before = inserted + out
    if let last = before.last, !last.isNewline,
      let first = body.first, !first.isNewline, !Self.closingPunctuation.contains(first)
    {
      out += " "
    }
    if Self.holdsFinalPeriod(body) {
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

  static let closingPunctuation: Set<Character> = [",", ".", ";", ":", "!", "?", ")", "]", "»", "“"]

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
