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
