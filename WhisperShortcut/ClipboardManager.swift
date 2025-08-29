import AppKit
import Foundation

class ClipboardManager {
  private let pasteboard = NSPasteboard.general

  // MARK: - Constants
  private enum Constants {
    static let maxPreviewLength = 50
    static let defaultSeparator = "\n"
    static let punctuation: Set<Character> = [".", "!", "?", ":", ";"]
  }

  func copyToClipboard(text: String) {
    // Format the text before copying
    let formattedText = formatTranscription(text)

    pasteboard.clearContents()
    pasteboard.setString(formattedText, forType: .string)

    let preview =
      formattedText.count > Constants.maxPreviewLength
      ? String(formattedText.prefix(Constants.maxPreviewLength)) + "..."
      : formattedText

  }

  func getClipboardText() -> String? {
    return pasteboard.string(forType: .string)
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
    if !formatted.isEmpty && !Constants.punctuation.contains(formatted.last!) {
      formatted += "."
    }

    return formatted
  }
}
