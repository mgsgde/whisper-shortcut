import Foundation

/// Guards the chat stream against Gemini (and similar) loops that would otherwise
/// concatenate the same status sentence into one assistant bubble for minutes.
///
/// Pure string helpers — no view-model, no MainActor — so the merge and loop
/// rules can be unit-tested without standing up `ChatViewModel`.
enum ChatStreamLoopGuard {

  /// Shown in the bubble after a loop stop. Keep it short and non-scary.
  static let stopNotice = "Antwort gestoppt: das Modell hat sich wiederholt."

  static let repeatThreshold = 3
  /// Below this, a trailing n-gram is too short to count as a loop (avoids "yes yes yes").
  static let minNgramLength = 40
  /// Sentence units shorter than this don't trip the detector (avoids "ok. ok. ok.").
  static let minSentenceUnitLength = 12
  /// Cap n-gram unit length so per-token checks stay cheap on long replies.
  static let maxNgramUnitLength = 1024

  enum MergeKind: Equatable {
    /// True incremental SSE: `text` is `streamed + delta`.
    case appended
    /// Cumulative chunk: `text` is the longer of `streamed`/`delta` (prefix relationship).
    case replaced
    /// Duplicate trailing status sentence (or empty delta): `text` is unchanged `streamed`.
    case ignored
  }

  struct MergeOutcome: Equatable {
    var text: String
    var kind: MergeKind
  }

  /// Merge one stream `delta` into the accumulated `streamed` text.
  ///
  /// - Cumulative chunks (`delta` is a prefix/extension of `streamed`): replace
  ///   with the longer string instead of appending (`A` then `AB` → `AB`, not `AAB`).
  /// - In-place status: if the trimmed delta equals the last sentence already in
  ///   `streamed`, ignore it so a repeated status line doesn't grow the bubble.
  /// - Otherwise append (true incremental SSE).
  static func mergeDelta(streamed: String, delta: String) -> String {
    merge(streamed: streamed, delta: delta).text
  }

  static func merge(streamed: String, delta: String) -> MergeOutcome {
    if delta.isEmpty {
      return MergeOutcome(text: streamed, kind: .ignored)
    }

    let trimmedDelta = delta.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmedDelta.isEmpty, let last = lastSentence(streamed) {
      if canonicalizeSentence(last) == canonicalizeSentence(trimmedDelta) {
        return MergeOutcome(text: streamed, kind: .ignored)
      }
    }

    if delta.hasPrefix(streamed) {
      return MergeOutcome(text: delta, kind: .replaced)
    }
    if streamed.hasPrefix(delta) {
      return MergeOutcome(text: streamed, kind: .replaced)
    }
    return MergeOutcome(text: streamed + delta, kind: .appended)
  }

  /// True when the same sentence/phrase appears `repeatThreshold` times in a row
  /// at the end of `streamed`. Two copies is legal (a heading restated once);
  /// short tokens never trip it.
  static func isRepeatingLoop(_ streamed: String) -> Bool {
    let sentences = splitSentences(streamed).map(normalizeWhitespace).filter { !$0.isEmpty }
    if trailingSentenceUnitsRepeat(sentences, repeats: repeatThreshold) {
      return true
    }
    return hasTrailingNgramRepeat(
      streamed, minUnit: minNgramLength, repeats: repeatThreshold)
  }

  /// Consecutive in-place-status ignores also count as a loop: `merge` keeps a
  /// single copy, so `isRepeatingLoop` would never see 3 sentences in `streamed`,
  /// and the queued turn would wait forever.
  static func shouldStop(streamed: String, ignoredStreak: Int) -> Bool {
    ignoredStreak >= repeatThreshold || isRepeatingLoop(streamed)
  }

  /// Append the German stop line, without duplicating it.
  static func appendStopNotice(to text: String) -> String {
    if text.contains(stopNotice) { return text }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return stopNotice }
    return trimmed + "\n\n" + stopNotice
  }

  // MARK: - Internals

  static func splitSentences(_ text: String) -> [String] {
    var sentences: [String] = []
    var current = ""
    for ch in text {
      if ch == "." || ch == "!" || ch == "?" || ch == "\n" {
        let piece = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !piece.isEmpty { sentences.append(piece) }
        current = ""
      } else {
        current.append(ch)
      }
    }
    let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
    if !tail.isEmpty { sentences.append(tail) }
    return sentences
  }

  static func lastSentence(_ text: String) -> String? {
    splitSentences(text).last
  }

  static func normalizeWhitespace(_ text: String) -> String {
    text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
  }

  /// Strip surrounding whitespace and trailing `.` `!` `?` so "Foo." matches "Foo".
  static func canonicalizeSentence(_ text: String) -> String {
    var t = normalizeWhitespace(text)
    while let last = t.last, ".!?".contains(last) {
      t.removeLast()
      t = t.trimmingCharacters(in: .whitespaces)
    }
    return t
  }

  /// Last `repeats` consecutive units of 1...n/`repeats` sentences are identical
  /// (catches both "S. S. S." and the two-phrase "A. B. A. B. A. B." status loop).
  static func trailingSentenceUnitsRepeat(_ sentences: [String], repeats: Int) -> Bool {
    let n = sentences.count
    let maxUnit = n / repeats
    guard maxUnit >= 1 else { return false }
    for unit in 1...maxUnit {
      let start = n - unit * repeats
      let first = Array(sentences[start..<(start + unit)])
      let joinedLen = first.joined(separator: " ").count
      if joinedLen < minSentenceUnitLength { continue }
      var allMatch = true
      for r in 1..<repeats {
        let s = start + r * unit
        if Array(sentences[s..<(s + unit)]) != first {
          allMatch = false
          break
        }
      }
      if allMatch { return true }
    }
    return false
  }

  static func hasTrailingNgramRepeat(_ text: String, minUnit: Int, repeats: Int) -> Bool {
    let chars = Array(normalizeWhitespace(text))
    let n = chars.count
    let maxUnit = min(maxNgramUnitLength, n / repeats)
    guard maxUnit >= minUnit else { return false }
    for unitLen in minUnit...maxUnit {
      let start = n - unitLen * repeats
      let unit = chars[start..<(start + unitLen)]
      var allMatch = true
      for r in 1..<repeats {
        let s = start + r * unitLen
        if chars[s..<(s + unitLen)] != unit {
          allMatch = false
          break
        }
      }
      if allMatch { return true }
    }
    return false
  }
}
