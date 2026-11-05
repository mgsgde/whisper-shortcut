import Foundation

/// Dictate Live into Chromium browsers: the renderer sometimes drops a synthesized ⌘V (the browser
/// process reads the pasteboard, the renderer never pastes), and nothing on our side can see that.
/// Plain Unicode key events reach the renderer every time, so these targets get the piece typed.
enum LiveTextTyping {
  enum Chunk: Equatable {
    case text(String)
    case newline
  }

  /// Most UTF-16 units of text per synthesized key event.
  static let maxUnitsPerChunk = 20

  private static let exactBundleIDs: Set<String> = [
    "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev",
    "com.google.Chrome.canary", "org.chromium.Chromium", "company.thebrowser.Browser",
    "com.vivaldi.Vivaldi",
  ]
  private static let bundleIDPrefixes = [
    "com.brave.Browser", "com.microsoft.edgemac", "com.operasoftware.Opera",
  ]

  static func isChromium(bundleID: String?) -> Bool {
    guard let bundleID else { return false }
    return exactBundleIDs.contains(bundleID) || bundleIDPrefixes.contains { bundleID.hasPrefix($0) }
  }

  /// Splits `text` into key-event sized pieces: text runs of at most 20 UTF-16 units that never
  /// cut a grapheme cluster (so never a surrogate pair), and one `.newline` per line break.
  static func chunks(_ text: String) -> [Chunk] {
    var result: [Chunk] = []
    var run = ""
    var runUnits = 0
    func flush() {
      if !run.isEmpty { result.append(.text(run)) }
      run = ""
      runUnits = 0
    }
    for character in text {
      if character == "\n" || character == "\r\n" || character == "\r" {
        flush()
        result.append(.newline)
        continue
      }
      let units = character.utf16.count
      if runUnits + units > maxUnitsPerChunk { flush() }
      run.append(character)
      runUnits += units
    }
    flush()
    return result
  }
}
