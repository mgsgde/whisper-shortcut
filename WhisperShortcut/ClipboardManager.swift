import AppKit
import Foundation

/// What the pasteboard held before the app overwrote it, so a paste can put it back.
/// Every item and representation is copied eagerly — `NSPasteboardItem`s belonging to the
/// general pasteboard are invalidated by the next `clearContents()`, so holding references
/// to them would restore nothing.
struct ClipboardSnapshot {
  fileprivate let items: [[NSPasteboard.PasteboardType: Data]]

  var isEmpty: Bool { items.allSatisfy { $0.isEmpty } }
}

class ClipboardManager {
  private let pasteboard: NSPasteboard

  init(pasteboard: NSPasteboard = .general) {
    self.pasteboard = pasteboard
  }

  /// Pasteboard contents captured before this job clobbered them. Set at the first write of
  /// a job (the synthetic ⌘C of Dictate Prompt, or the result copy) and consumed once the
  /// synthetic ⌘V has landed. Only used when "Restore clipboard" is on.
  private var pendingRestore: ClipboardSnapshot?
  /// `changeCount` immediately after the last `copyToClipboard` write. Restore is skipped
  /// if the pasteboard changed in the meantime (user ⌘C, another dictation).
  private var changeCountAfterLastWrite: Int = 0

  // MARK: - Constants
  private enum Constants {
    static let maxPreviewLength = 50
    static let defaultSeparator = "\n"
    static let punctuation: Set<Character> = [".", "!", "?", ":", ";"]
    static let maxRepeatedChars = 3
    static let maxRepeatedNewlines = 2
  }

  func copyToClipboard(text: String) {
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
    changeCountAfterLastWrite = pasteboard.changeCount
  }

  /// Copies dictation transcript text with capitalization and trailing punctuation.
  func copyTranscriptionToClipboard(text: String) {
    copyToClipboard(text: formatTranscription(text))
  }

  func getClipboardText() -> String? {
    return pasteboard.string(forType: .string)
  }

  func getCleanedClipboardText() -> String? {
    guard let text = getClipboardText() else { return nil }
    return cleanText(text)
  }

  // MARK: - Non-destructive paste

  /// Copies every item currently on the pasteboard, including non-text flavors, so it can be
  /// put back after auto-paste.
  func snapshot() -> ClipboardSnapshot {
    let items = (pasteboard.pasteboardItems ?? []).map { item in
      item.types.reduce(into: [NSPasteboard.PasteboardType: Data]()) { result, type in
        result[type] = item.data(forType: type)
      }
    }
    return ClipboardSnapshot(items: items)
  }

  /// Remembers the current contents for a later `restorePendingSnapshot()`, unless this job
  /// already captured a restore point (Dictate Prompt clobbers the pasteboard twice: once
  /// with the synthetic ⌘C, once with the result — only the first snapshot is the user's).
  func captureRestorePointIfNeeded() {
    guard pendingRestore == nil else { return }
    pendingRestore = snapshot()
  }

  /// Drops the remembered contents without restoring them. Called when a job ends without a
  /// paste, so a later job can never put back a clipboard from minutes ago.
  func discardRestorePoint() {
    pendingRestore = nil
    changeCountAfterLastWrite = 0
  }

  /// Writes the remembered contents back and clears the restore point. No-op when nothing was
  /// captured, or when the pasteboard was empty to begin with (restoring "empty" would just
  /// throw away the dictated text for no gain).
  /// - Returns: `true` when the pasteboard was actually restored.
  @discardableResult
  func restorePendingSnapshot() -> Bool {
    guard let snapshot = pendingRestore else { return false }
    pendingRestore = nil
    guard pasteboard.changeCount == changeCountAfterLastWrite else {
      DebugLogger.log("AUTO-PASTE: Skipping clipboard restore — pasteboard changed since write")
      return false
    }
    guard !snapshot.isEmpty else { return false }

    pasteboard.clearContents()
    let items: [NSPasteboardItem] = snapshot.items.compactMap { representations in
      guard !representations.isEmpty else { return nil }
      let item = NSPasteboardItem()
      for (type, data) in representations {
        item.setData(data, forType: type)
      }
      return item
    }
    guard !items.isEmpty else { return false }
    pasteboard.writeObjects(items)
    return true
  }

  func appendToClipboard(text: String, separator: String = Constants.defaultSeparator) {
    let currentText = getClipboardText() ?? ""
    let newText = currentText.isEmpty ? text : currentText + separator + text
    copyToClipboard(text: newText)
  }

  // Format transcription text for better readability
  func formatTranscription(_ text: String) -> String {
    // Basic formatting improvements
    var formatted = text.trimmingCharacters(in: .whitespacesAndNewlines)

    // Ensure first letter is capitalized
    if !formatted.isEmpty {
      formatted = formatted.prefix(1).uppercased() + formatted.dropFirst()
    }

    // Add period if missing and text doesn't end with punctuation
    if let lastChar = formatted.last, !Constants.punctuation.contains(lastChar) {
      formatted += "."
    }

    return formatted
  }

  // Clean text from clipboard (remove query params from URLs, excessive whitespace, repeated characters)
  func cleanText(_ text: String) -> String {
    var cleaned = text

    // 1. Remove query parameters from URLs
    cleaned = removeOrShortenURLs(cleaned)

    // 2. Remove multiple consecutive newlines (keep max 2)
    cleaned = removeExcessiveNewlines(cleaned)

    // 3. Remove repeated characters (e.g., "hellooooo" -> "hello")
    cleaned = removeRepeatedCharacters(cleaned)

    // 4. Trim whitespace
    cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

    return cleaned
  }

  // MARK: - Private Cleaning Helpers

  private func removeOrShortenURLs(_ text: String) -> String {
    // Regex pattern for URLs (http, https, www, etc.)
    let urlPattern = #"(?:https?://|www\.)[^\s]+"#
    
    guard let regex = try? NSRegularExpression(pattern: urlPattern, options: .caseInsensitive) else {
      return text
    }

    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    let matches = regex.matches(in: text, range: range)

    // Replace URLs from end to start to maintain indices
    var result = text
    for match in matches.reversed() {
      if let range = Range(match.range, in: result) {
        let url = String(result[range])
        // Remove query parameters from URL
        let cleaned = cleanURL(url)
        result.replaceSubrange(range, with: cleaned)
      }
    }

    return result
  }

  private func cleanURL(_ urlString: String) -> String {
    // Try to parse as URL
    guard let url = URL(string: urlString) else {
      // If parsing fails, just remove everything after '?'
      if let queryIndex = urlString.firstIndex(of: "?") {
        return String(urlString[..<queryIndex])
      }
      return urlString
    }

    // Build clean URL without query parameters and fragments
    var components = URLComponents()
    components.scheme = url.scheme
    components.host = url.host
    components.port = url.port
    components.path = url.path
    
    // Return the cleaned URL string, or original if construction fails
    return components.string ?? urlString
  }

  private func removeExcessiveNewlines(_ text: String) -> String {
    // Replace 3+ consecutive newlines with just 2
    let pattern = "\n{3,}"
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
      return text
    }

    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    let replacement = "\n\n"
    return regex.stringByReplacingMatches(
      in: text,
      range: range,
      withTemplate: replacement
    )
  }

  private func removeRepeatedCharacters(_ text: String) -> String {
    var result = ""
    var lastChar: Character?
    var repeatCount = 0

    for char in text {
      if char == lastChar {
        repeatCount += 1
        // Only add if under the limit
        if repeatCount < Constants.maxRepeatedChars {
          result.append(char)
        }
      } else {
        result.append(char)
        lastChar = char
        repeatCount = 0
      }
    }

    return result
  }
}
