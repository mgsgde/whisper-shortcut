import AppKit
import Foundation

// MARK: - Gemini Chat Tools (Function Calling)
//
// Small registry of local "agent" tools that Gemini can invoke via function calls.
// Each tool has:
//   - a declaration (name + JSONSchema-ish parameters) that is sent to Gemini,
//   - an `execute(args:)` handler that runs locally and returns a dict payload
//     which is then round-tripped back to Gemini as a `functionResponse` turn.
//
// Tools are deliberately conservative: no arbitrary shell execution, no file
// writes. Every action is either a read (clipboard) or an explicit UI effect
// (clipboard write, open URL) that the user can immediately see.

enum GeminiChatToolRegistry {

  /// Function declarations in Gemini's Tool format, ready to embed under
  /// `tools: [{ function_declarations: [...] }]`.
  static let functionDeclarations: [[String: Any]] = [
    [
      "name": "read_clipboard",
      "description": "Reads the current contents of the user's system clipboard as plain text. Use this when the user refers to 'my clipboard', 'what I just copied', or similar.",
      "parameters": [
        "type": "object",
        "properties": [:] as [String: Any],
      ],
    ],
    [
      "name": "copy_to_clipboard",
      "description": "Writes plain text to the user's system clipboard, overwriting its current contents. Use this when the user asks to 'copy', 'put it in my clipboard', or similar.",
      "parameters": [
        "type": "object",
        "properties": [
          "text": [
            "type": "string",
            "description": "The plain text to place on the clipboard.",
          ],
        ],
        "required": ["text"],
      ],
    ],
    [
      "name": "open_url",
      "description": "Opens a URL in the user's default web browser. Use this when the user asks to 'open', 'visit', or 'go to' a website.",
      "parameters": [
        "type": "object",
        "properties": [
          "url": [
            "type": "string",
            "description": "Absolute http/https URL to open.",
          ],
        ],
        "required": ["url"],
      ],
    ],
  ]

  /// Executes a named tool with the given args and returns a dict to embed in
  /// the `functionResponse.response` field. Unknown tools return an error payload.
  @MainActor
  static func execute(name: String, args: [String: Any]) -> [String: Any] {
    DebugLogger.log("GEMINI-CHAT-TOOL: execute name=\(name)")
    switch name {
    case "read_clipboard":
      let text = NSPasteboard.general.string(forType: .string) ?? ""
      return ["text": text]

    case "copy_to_clipboard":
      guard let text = args["text"] as? String else {
        return ["error": "Missing required argument: text"]
      }
      let pb = NSPasteboard.general
      pb.clearContents()
      pb.setString(text, forType: .string)
      return ["ok": true, "bytes": text.utf8.count]

    case "open_url":
      guard let urlString = args["url"] as? String,
            let url = URL(string: urlString),
            let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https"
      else {
        return ["error": "Invalid or non-http(s) URL"]
      }
      NSWorkspace.shared.open(url)
      return ["ok": true, "url": urlString]

    default:
      return ["error": "Unknown tool: \(name)"]
    }
  }
}
