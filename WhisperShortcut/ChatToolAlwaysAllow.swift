//
//  ChatToolAlwaysAllow.swift
//  WhisperShortcut
//

import Foundation

/// Tools the user allowed for good ("Always allow" on the approval card). Persisted in
/// UserDefaults; only names eligible for chat-wide approval are ever stored or honoured, so a
/// stale entry for a tool that later became gated stops working on its own.
@MainActor
final class ChatToolAlwaysAllow: ObservableObject {
  static let shared = ChatToolAlwaysAllow()

  @Published private(set) var toolNames: Set<String>

  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    let stored = defaults.stringArray(forKey: UserDefaultsKeys.chatAlwaysAllowedTools) ?? []
    toolNames = Set(stored.filter(ChatToolRegistry.allowsChatWideApproval))
  }

  /// True only when the name is stored and still eligible. A stale entry for a tool that later
  /// became gated is ignored.
  func contains(_ name: String) -> Bool {
    toolNames.contains(name) && ChatToolRegistry.allowsChatWideApproval(name)
  }

  /// Remembers `name` for every future chat. No-op unless the tool may be approved chat-wide.
  func allow(_ name: String) {
    guard ChatToolRegistry.allowsChatWideApproval(name) else { return }
    toolNames.insert(name)
    persist()
  }

  func revoke(_ name: String) {
    toolNames.remove(name)
    persist()
  }

  func revokeAll() {
    toolNames.removeAll()
    persist()
  }

  private func persist() {
    defaults.set(toolNames.sorted(), forKey: UserDefaultsKeys.chatAlwaysAllowedTools)
  }

  /// Short label for Settings. Unknown names stay as the raw tool id.
  static func displayName(for toolName: String) -> String {
    switch toolName {
    case "google_calendar_create_event":
      return String(localized: "Create calendar events")
    case "google_calendar_update_event":
      return String(localized: "Change calendar events")
    case "google_tasks_create":
      return String(localized: "Create tasks")
    case "google_tasks_update":
      return String(localized: "Change tasks")
    case "google_tasks_complete":
      return String(localized: "Complete tasks")
    case "trello_create_card":
      return String(localized: "Create Trello cards")
    case "trello_move_card":
      return String(localized: "Move Trello cards")
    case "trello_update_card":
      return String(localized: "Change Trello cards")
    default:
      return toolName
    }
  }
}
