//
//  ChatToolAlwaysAllow.swift
//  WhisperShortcut
//

import Foundation

/// Tools the user allowed for good ("Always allow" on the approval card). Persisted in
/// UserDefaults; only names whose spec approval is `.persistent` are stored or honoured, so a
/// stale entry for a tool that later became per-call stops working on its own.
@MainActor
final class ChatToolAlwaysAllow: ObservableObject {
  static let shared = ChatToolAlwaysAllow()

  @Published private(set) var toolNames: Set<String>

  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    let stored = defaults.stringArray(forKey: UserDefaultsKeys.chatAlwaysAllowedTools) ?? []
    toolNames = Set(stored.filter(ChatToolRegistry.allowsPersistentApproval))
  }

  /// True only when the name is stored and still `.persistent`. A stale entry for a tool that
  /// later became per-call is ignored.
  func contains(_ name: String) -> Bool {
    toolNames.contains(name) && ChatToolRegistry.allowsPersistentApproval(name)
  }

  /// Remembers `name` for every future chat. No-op unless the tool's approval is `.persistent`.
  func allow(_ name: String) {
    guard ChatToolRegistry.allowsPersistentApproval(name) else { return }
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

  /// Short label for Settings. Unknown names, and tools with no phrase of their own, stay as the
  /// raw tool id. The phrase comes from the spec, already localized.
  static func displayName(for toolName: String) -> String {
    ChatToolSpec.named(toolName)?.displayName ?? toolName
  }
}
