import Foundation

/// Effective on/off and permission state for the features `get_configuration` points an AI app at.
struct MCPFeatureState {
  var autoPaste: Bool
  var accessibility: Bool
  var frontWindowFallback: Bool
  var fieldTextContext: Bool
  var screenRecording: Bool
  var interactionsShared: Bool
}

/// Features that are switched off, or on but silent because a macOS permission is missing.
/// One dictionary per such feature, in a fixed order; empty when everything works.
enum MCPFeatureHints {
  static func build(_ s: MCPFeatureState) -> [[String: Any]] {
    [autoPaste(s), frontWindow(s), recentInteractions(s)].compactMap { $0 }
  }

  private static func hint(
    id: String, title: String, state: String, benefit: String, howToEnable: String
  ) -> [String: Any] {
    [
      "id": id,
      "title": title,
      "state": state,
      "benefit": benefit,
      "how_to_enable": howToEnable,
    ]
  }

  private static func autoPaste(_ s: MCPFeatureState) -> [String: Any]? {
    let id = "clipboard.auto_paste"
    let title = "Auto-paste after dictation"
    let benefit =
      "Dictated text lands at the cursor by itself instead of only on the clipboard, so the user does not have to press Cmd+V after every dictation."
    if s.autoPaste && s.accessibility { return nil }
    if s.autoPaste {
      return hint(
        id: id, title: title, state: "on_but_permission_missing", benefit: benefit,
        howToEnable:
          "Auto-paste is on but cannot paste without Accessibility. The user grants it in WhisperShortcut Settings → Permissions.")
    }
    if s.accessibility {
      return hint(
        id: id, title: title, state: "off", benefit: benefit,
        howToEnable: "Ask the user, then update_settings clipboard.auto_paste = true.")
    }
    return hint(
      id: id, title: title, state: "off_permission_missing", benefit: benefit,
      howToEnable:
        "The user grants Accessibility in WhisperShortcut Settings → Permissions (only they can), then you or they turn on clipboard.auto_paste.")
  }

  private static func frontWindow(_ s: MCPFeatureState) -> [String: Any]? {
    let id = "dictate_prompt.screenshot_context"
    let title = "Front window picture"
    let benefit =
      "When the focused field is empty, short or unreadable, Dictate Prompt also sees a picture of the front window (never the whole screen), so it understands what the user is replying to or editing."
    if s.frontWindowFallback && s.screenRecording { return nil }
    if s.frontWindowFallback {
      return hint(
        id: id, title: title, state: "on_but_permission_missing", benefit: benefit,
        howToEnable:
          "The setting is on but does nothing without Screen Recording. The user grants it in WhisperShortcut Settings → Permissions.")
    }
    if s.screenRecording {
      return hint(
        id: id, title: title, state: "off", benefit: benefit,
        howToEnable:
          "Propose update_settings dictate_prompt.screenshot_context = true; the user accepts it in WhisperShortcut.")
    }
    return hint(
      id: id, title: title, state: "off_permission_missing", benefit: benefit,
      howToEnable:
        "The user grants Screen Recording in WhisperShortcut Settings → Permissions, then turns on Front window picture in the Dictate Prompt settings.")
  }

  private static func recentInteractions(_ s: MCPFeatureState) -> [String: Any]? {
    guard !s.interactionsShared else { return nil }
    return hint(
      id: "recent_interactions",
      title: "AI apps may read recent dictations",
      state: "off",
      benefit: "Lets you read the user's recent dictations and errors, so tuning fixes real mistakes instead of guesses.",
      howToEnable:
        "The user turns on \"Save usage data\" and \"AI apps may read my recent dictations\" in WhisperShortcut Settings.")
  }
}
