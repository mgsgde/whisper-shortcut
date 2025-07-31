import AppKit
import Foundation

class ClipboardManager {
  private let pasteboard = NSPasteboard.general

  func copyToClipboard(text: String) {
    // Format the text before copying
    let formattedText = formatTranscription(text)

    pasteboard.clearContents()
    pasteboard.setString(formattedText, forType: .string)

    let preview =
      formattedText.count > 50 ? String(formattedText.prefix(50)) + "..." : formattedText
    print("📋 Text copied to clipboard: \"\(preview)\"")
    print("   Full text length: \(formattedText.count) characters")
  }

  func getClipboardText() -> String? {
    return pasteboard.string(forType: .string)
  }

  func appendToClipboard(text: String, separator: String = "\n") {
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
    let punctuation: Set<Character> = [".", "!", "?", ":", ";"]
    if !formatted.isEmpty && !punctuation.contains(formatted.last!) {
      formatted += "."
    }

    return formatted
  }
}
