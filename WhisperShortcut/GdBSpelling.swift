import Foundation

/// Parakeet writes the GdB token several ways ("EinzelgdB30", "Einzel GDB 20", "GDB10",
/// "GesamtgdB", "eine Einzelgdb"). One spelling: "Einzel-GdB", "Gesamt-GdB", or "GdB", and a
/// number glued on gains a space ("GdB10" → "GdB 10", "Einzel-GdB30" → "Einzel-GdB 30").
///
/// Whole tokens only. "gdb" inside "einzelgdb" is that token; a different word that merely
/// contains the letters ("AbGdB", "Hausgdbau") is left alone. Case-insensitive.
///
/// Runs before `GermanNumberWords.digitizingQuantities`. That rule looks for the token "gdb"
/// case-insensitively, and it splits on anything that is not a letter, so "Einzel-GdB" still
/// exposes "GdB".
enum GdBSpelling {

  /// `text` with those tokens rewritten. Text without one comes back unchanged.
  static func normalize(_ text: String) -> String {
    let full = NSRange(text.startIndex..., in: text)
    let matches = regex.matches(in: text, range: full)
    guard !matches.isEmpty else { return text }
    var out = ""
    var cursor = text.startIndex
    for match in matches {
      guard let span = Range(match.range, in: text) else { continue }
      out += text[cursor..<span.lowerBound]
      let token: String
      if let kindRange = Range(match.range(at: 1), in: text) {
        token = text[kindRange].lowercased() == "gesamt" ? "Gesamt-GdB" : "Einzel-GdB"
      } else {
        token = "GdB"
      }
      if let digitRange = Range(match.range(at: 2), in: text) {
        out += token + " " + text[digitRange]
      } else {
        out += token
      }
      cursor = span.upperBound
    }
    out += text[cursor...]
    return out
  }

  // "einzel" / "gesamt" with an optional hyphen or space, or a bare "gdb", then digits glued on.
  // swiftlint:disable:next force_try
  private static let regex = try! NSRegularExpression(
    pattern: #"\b(?:(einzel|gesamt)[ \-]?)?gdb(\d+)?\b"#,
    options: [.caseInsensitive])
}
