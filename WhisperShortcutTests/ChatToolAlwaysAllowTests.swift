import Testing
import Foundation
@testable import WhisperShortcut_AppStore

/// Persistent "Always allow" for chat tools that may be approved for a whole chat.
@MainActor
@Suite("Chat tool always allow")
struct ChatToolAlwaysAllowTests {

  private func isolatedDefaults() -> (suite: String, defaults: UserDefaults) {
    let suite = "ChatToolAlwaysAllowTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return (suite, defaults)
  }

  /// External writes used to be persistable. They are per-call now, so "Always allow" stores nothing.
  private static let externalWrites = [
    "google_calendar_create_event", "google_calendar_update_event",
    "google_tasks_create", "google_tasks_update", "google_tasks_complete",
    "trello_create_card", "trello_move_card", "trello_update_card",
    "google_calendar_delete_event", "google_tasks_delete", "trello_archive_card",
    "write_text_file", "open_url",
  ]

  @Test func allowOfAnExternalWriteIsIgnored() {
    let (suite, defaults) = isolatedDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = ChatToolAlwaysAllow(defaults: defaults)
    for name in Self.externalWrites {
      store.allow(name)
      #expect(!store.contains(name), "\(name) must not be stored")
    }
    #expect(store.toolNames.isEmpty)
    #expect(!ChatToolSpec.all.contains { $0.approval == .persistent || $0.approval == .chatWide })

    let reloaded = ChatToolAlwaysAllow(defaults: defaults)
    #expect(reloaded.toolNames.isEmpty)
    #expect(defaults.stringArray(forKey: UserDefaultsKeys.chatAlwaysAllowedTools) == nil)
  }

  @Test func staleExternalWriteInDefaultsIsIgnored() {
    let (suite, defaults) = isolatedDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(Self.externalWrites, forKey: UserDefaultsKeys.chatAlwaysAllowedTools)
    let store = ChatToolAlwaysAllow(defaults: defaults)
    for name in Self.externalWrites {
      #expect(!store.contains(name), "\(name)")
    }
    #expect(store.toolNames.isEmpty)

    store.revokeAll()
    let reloaded = ChatToolAlwaysAllow(defaults: defaults)
    #expect(reloaded.toolNames.isEmpty)
    #expect(defaults.stringArray(forKey: UserDefaultsKeys.chatAlwaysAllowedTools)?.isEmpty == true)
  }

  @Test func settingsLabelComesFromTheSpec() {
    #expect(ChatToolAlwaysAllow.displayName(for: "google_calendar_create_event")
      == String(localized: "Create calendar events"))
    #expect(ChatToolAlwaysAllow.displayName(for: "trello_update_card")
      == String(localized: "Change Trello cards"))
    #expect(ChatToolAlwaysAllow.displayName(for: "no_such_tool") == "no_such_tool")
    #expect(ChatToolAlwaysAllow.displayName(for: "gmail_read") == "gmail_read")
  }
}
