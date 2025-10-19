import AppKit
import Foundation

class ClipboardManager {
  private let pasteboard = NSPasteboard.general

  // MARK: - Constants
  private enum Constants {
    static let maxPreviewLength = 50
    static let defaultSeparator = "\n"
    static let punctuation: Set<Character> = [".", "!", "?", ":", ";"]
    static let maxRepeatedChars = 3
    static let maxRepeatedNewlines = 2
  }

  func copyToClipboard(text: String) {
    // Format the text before copying
    let formattedText = formatTranscription(text)

    pasteboard.clearContents()
    pasteboard.setString(formattedText, forType: .string)

      _ =
      formattedText.count > Constants.maxPreviewLength
      ? String(formattedText.prefix(Constants.maxPreviewLength)) + "..."
      : formattedText

  }

  func getClipboardText() -> String? {
    return pasteboard.string(forType: .string)
  }

  func getCleanedClipboardText() -> String? {
    guard let text = getClipboardText() else { return nil }
    return cleanText(text)
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
