import Foundation

/// Gemini sometimes writes its reasoning into the visible answer between `start_thought` and
/// `end_thought`. Nonisolated so both the MainActor chat and the speech service can call it.
nonisolated enum LeakedThoughtStrip {
  /// Drops a leaked reasoning block (`start_thought` … `end_thought`), content included.
  /// An `end_thought` with no opener drops the prefix; an unclosed `start_thought` drops the tail
  /// (still streaming, or truncated). Leading spaces and newlines are trimmed.
  static func strip(_ text: String) -> String {
    var cleaned = text
    let startMarker = "start_thought"
    let endMarker = "end_thought"
    while true {
      if let start = cleaned.range(of: startMarker) {
        if let end = cleaned.range(of: endMarker, range: start.upperBound..<cleaned.endIndex) {
          cleaned.removeSubrange(start.lowerBound..<end.upperBound)
        } else {
          cleaned.removeSubrange(start.lowerBound..<cleaned.endIndex)
          // Drop the spaces that sat before the removed tail (newlines stay).
          while cleaned.last == " " { cleaned.removeLast() }
          continue
        }
      } else if let end = cleaned.range(of: endMarker) {
        cleaned.removeSubrange(cleaned.startIndex..<end.upperBound)
      } else {
        break
      }
    }
    // The markers normally sit at the very start; drop the whitespace they leave behind there.
    // Leading whitespace is never meaningful in an answer, so this is safe.
    while let first = cleaned.first, first == " " || first == "\n" { cleaned.removeFirst() }
    return cleaned
  }
}

/// Gemini sometimes returns its Dictate Prompt plan as visible text: its own response part, or
/// glued onto the answer with no space. Nonisolated so the speech service can call it.
nonisolated enum LeakedPlanningStrip {
  /// English planning labels. A line matches only when the label is followed by ":".
  private static let labels = [
    "Notice from the audio",
    "User voice style",
    "Voice style",
    "Check prompt constraints",
    "Check constraints",
    "Constraints",
    "Formatting",
    "Details",
    "Content",
    "Plan",
    "Draft",
    "Instruction",
    "Selected text",
    "Task",
  ]

  private static let gluePunctuation: Set<Character> = [".", "!", "?", ":", ")"]

  /// True when the first non-empty line is an English planning header.
  /// "The user " is case-sensitive. Labels are case-insensitive and may have text after the colon.
  static func looksLikePlanning(_ text: String) -> Bool {
    guard let line = firstNonEmptyTrimmedLine(in: text) else { return false }
    if line.hasPrefix("The user ") { return true }
    return isLabelLine(line)
  }

  /// Drops a leaked planning block from non-thought text parts, in order.
  /// Separate planning parts are dropped whole. A plan glued to the answer is cut at the glue
  /// point. Text we cannot separate is returned unchanged.
  static func strip(parts: [String]) -> String {
    let joined = parts.joined()
    if parts.count >= 2, looksLikePlanning(parts[0]) {
      guard let start = parts.indices.dropFirst().first(where: { !looksLikePlanning(parts[$0]) }) else {
        return joined
      }
      let kept = parts[start...].joined()
      logIfDropped(from: joined, to: kept, parts: parts)
      return kept
    }
    guard looksLikePlanning(joined), let cut = gluedAnswerStart(in: joined) else { return joined }
    let kept = String(joined[cut...])
    logIfDropped(from: joined, to: kept, parts: parts)
    return kept
  }

  private static func isLabelLine(_ trimmedLine: some StringProtocol) -> Bool {
    let lower = trimmedLine.lowercased()
    for label in labels where lower.hasPrefix(label.lowercased() + ":") {
      return true
    }
    return false
  }

  private static func firstNonEmptyTrimmedLine(in text: String) -> String? {
    var lineStart = text.startIndex
    while true {
      let lineEnd = text[lineStart...].firstIndex(of: "\n") ?? text.endIndex
      let trimmed = text[lineStart..<lineEnd].trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty { return String(trimmed) }
      if lineEnd == text.endIndex { return nil }
      lineStart = text.index(after: lineEnd)
    }
  }

  /// Start of the last planning header line: a known label line, or the first non-empty line
  /// when it starts with "The user ".
  private static func lastPlanningLineStart(in text: String) -> String.Index? {
    var anchor: String.Index?
    var isFirstNonEmpty = true
    var lineStart = text.startIndex
    while true {
      let lineEnd = text[lineStart...].firstIndex(of: "\n") ?? text.endIndex
      let trimmed = text[lineStart..<lineEnd].trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty {
        if isLabelLine(trimmed) || (isFirstNonEmpty && trimmed.hasPrefix("The user ")) {
          anchor = lineStart
        }
        isFirstNonEmpty = false
      }
      if lineEnd == text.endIndex { break }
      lineStart = text.index(after: lineEnd)
    }
    return anchor
  }

  /// Index of the uppercase letter that starts the answer, where punctuation is glued to it.
  private static func gluedAnswerStart(in text: String) -> String.Index? {
    guard let anchor = lastPlanningLineStart(in: text) else { return nil }
    var index = anchor
    while index < text.endIndex {
      let next = text.index(after: index)
      if next < text.endIndex, gluePunctuation.contains(text[index]), text[next].isUppercase {
        return next
      }
      index = next
    }
    return nil
  }

  private static func logIfDropped(from original: String, to kept: String, parts: [String]) {
    let droppedChars = original.count - kept.count
    guard droppedChars > 0 else { return }
    DebugLogger.logWarning("PROMPT-LEAK: dropped planning block (\(droppedChars) chars, parts=\(parts.count))")
  }
}
