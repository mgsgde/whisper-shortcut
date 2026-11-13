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

  @Test func allowPersistsAcrossANewInstance() {
    let (suite, defaults) = isolatedDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let name = "google_calendar_create_event"
    let first = ChatToolAlwaysAllow(defaults: defaults)
    #expect(!first.contains(name))
    first.allow(name)
    #expect(first.contains(name))

    let second = ChatToolAlwaysAllow(defaults: defaults)
    #expect(second.contains(name))
    #expect(second.toolNames == [name])
  }

  @Test func allowOfAnIneligibleToolIsIgnored() {
    let (suite, defaults) = isolatedDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = ChatToolAlwaysAllow(defaults: defaults)
    for name in ["google_calendar_delete_event", "write_text_file", "open_url"] {
      store.allow(name)
      #expect(!store.contains(name), "\(name) must not be stored")
    }
    #expect(store.toolNames.isEmpty)

    let reloaded = ChatToolAlwaysAllow(defaults: defaults)
    #expect(reloaded.toolNames.isEmpty)
    #expect(defaults.stringArray(forKey: UserDefaultsKeys.chatAlwaysAllowedTools) == nil)
  }

  @Test func containsIsFalseForAnIneligibleNameWrittenIntoDefaults() {
    let (suite, defaults) = isolatedDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(
      ["google_calendar_delete_event", "write_text_file", "open_url", "google_tasks_create"],
      forKey: UserDefaultsKeys.chatAlwaysAllowedTools)
    let store = ChatToolAlwaysAllow(defaults: defaults)
    #expect(!store.contains("google_calendar_delete_event"))
    #expect(!store.contains("write_text_file"))
    #expect(!store.contains("open_url"))
    // An eligible name in the same array is still honoured.
    #expect(store.contains("google_tasks_create"))
  }

  @Test func revokeAndRevokeAllPersist() {
    let (suite, defaults) = isolatedDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let first = ChatToolAlwaysAllow(defaults: defaults)
    first.allow("google_calendar_create_event")
    first.allow("trello_create_card")
    first.revoke("google_calendar_create_event")

    let afterRevoke = ChatToolAlwaysAllow(defaults: defaults)
    #expect(!afterRevoke.contains("google_calendar_create_event"))
    #expect(afterRevoke.contains("trello_create_card"))

    afterRevoke.revokeAll()
    let afterAll = ChatToolAlwaysAllow(defaults: defaults)
    #expect(afterAll.toolNames.isEmpty)
    #expect(!afterAll.contains("trello_create_card"))
  }
}
