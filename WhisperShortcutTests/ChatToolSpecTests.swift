import Testing
import Foundation
@testable import WhisperShortcut_AppStore

/// The policy table against the predicates it replaced.
///
/// `legacy…` is the old hand-written code, copied here before it was deleted. A tool may
/// differ only when it is named in `lostBlanketApproval`: those three write to Trello boards
/// other people can see, so a yes no longer covers the rest of the chat or later chats.
@MainActor
@Suite("Chat tool spec")
struct ChatToolSpecTests {

  /// Was chat-wide and persistent. Now per-call: a shared board must not take a blanket yes.
  private static let lostBlanketApproval: Set<String> = [
    "trello_create_card",
    "trello_move_card",
    "trello_update_card",
  ]

  /// Own calendar and task list. Reversible, and nobody else sees the write.
  private static let ownAccountWrites = [
    "google_calendar_create_event",
    "google_calendar_update_event",
    "google_tasks_create",
    "google_tasks_update",
    "google_tasks_complete",
  ]

  private static let argProbes: [[String: Any]] = [
    [:],
    ["action": "read"],
    ["action": "write"],
    ["action": "set"],
    ["action": "append"],
    ["action": "replace"],
    ["action": "remove"],
    ["action": "review"],
    ["action": "dismiss"],
  ]

  private static let declarationGroups: [(ChatToolSpec.Group, [[String: Any]])] = [
    (.core, ChatToolRegistry.functionDeclarations),
    (.appDocs, ChatToolRegistry.appDocsFunctionDeclarations),
    (.memory, ChatToolRegistry.memoryFunctionDeclarations),
    (.instructions, ChatToolRegistry.instructionsFunctionDeclarations),
    (.usageLog, ChatToolRegistry.usageLogFunctionDeclarations),
    (.appSettings, [AppSettingsChatTool.declaration]),
    (.workspace, ChatToolRegistry.workspaceFunctionDeclarations),
    (.workspaceWrite, ChatToolRegistry.workspaceWriteFunctionDeclarations),
    (.image, ChatToolRegistry.imageFunctionDeclarations),
    (.calendar, ChatToolRegistry.calendarFunctionDeclarations),
    (.tasks, ChatToolRegistry.tasksFunctionDeclarations),
    (.gmail, ChatToolRegistry.gmailFunctionDeclarations),
    (.mailConnect, ChatToolRegistry.mailConnectFunctionDeclarations),
    (.mail, ChatToolRegistry.mailFunctionDeclarations),
    (.trello, ChatToolRegistry.trelloFunctionDeclarations),
    (.meeting, ChatToolRegistry.meetingFunctionDeclarations),
  ]

  private static var declaredNames: [String] {
    declarationGroups.flatMap { _, decls in decls.compactMap { $0["name"] as? String } }
  }

  @Test func everyDeclarationHasExactlyOneSpec() {
    var declared: [String] = []
    for (group, decls) in Self.declarationGroups {
      let names = decls.compactMap { $0["name"] as? String }
      #expect(names.count == decls.count, "\(group) has a declaration without a name")
      let specNames = Set(ChatToolSpec.all.filter { $0.group == group }.map(\.name))
      #expect(Set(names) == specNames, "\(group): declarations \(Set(names).symmetricDifference(specNames))")
      declared += names
    }
    #expect(declared.count == Set(declared).count, "a tool name is declared twice")
    let specNames = ChatToolSpec.all.map(\.name)
    #expect(specNames.count == Set(specNames).count, "a tool name has two specs")
    #expect(Set(declared) == Set(specNames))
    #expect(!specNames.isEmpty)
  }

  @Test func approvalMatchesTheOldPredicatesExceptExternalWrites() {
    let names = Self.declaredNames
    #expect(Self.lostBlanketApproval.isSubset(of: Set(names)))
    var differed: [String] = []
    for name in names {
      for args in Self.argProbes {
        let newNeeds = ChatToolRegistry.requiresUserApproval(name, args: args)
        let oldNeeds = Self.legacyRequiresUserApproval(name, args: args)
        #expect(newNeeds == oldNeeds, "\(name) args \(args)")
      }
      let oldWide = Self.legacyAllowsChatWideApproval(name)
      let newWide = ChatToolRegistry.allowsChatWideApproval(name)
      let newPersistent = ChatToolRegistry.allowsPersistentApproval(name)
      if oldWide != newWide || oldWide != newPersistent {
        differed.append(name)
        #expect(Self.lostBlanketApproval.contains(name), "\(name) changed and is not in the list")
        #expect(oldWide)
        #expect(!newWide, "\(name) must not be allowable for the chat")
        #expect(!newPersistent, "\(name) must not be always-allowable")
        #expect(ChatToolSpec.named(name)?.approval == .perCall, "\(name)")
        #expect(ChatToolRegistry.requiresUserApproval(name))
      } else {
        #expect(!Self.lostBlanketApproval.contains(name), "\(name) is listed but did not change")
      }
    }
    #expect(Set(differed) == Self.lostBlanketApproval, "differed: \(differed)")
  }

  @Test func ownAccountWritesAllowChatWideAndPersistentApproval() {
    for name in Self.ownAccountWrites {
      #expect(ChatToolRegistry.allowsChatWideApproval(name), "\(name)")
      #expect(ChatToolRegistry.allowsPersistentApproval(name), "\(name)")
      #expect(ChatToolSpec.named(name)?.approval == .persistent, "\(name)")
    }
    for name in Self.lostBlanketApproval {
      #expect(!ChatToolRegistry.allowsChatWideApproval(name), "\(name)")
      #expect(!ChatToolRegistry.allowsPersistentApproval(name), "\(name)")
      #expect(ChatToolSpec.named(name)?.approval == .perCall, "\(name)")
    }
  }

  @Test func storedAlwaysAllowForTrelloCreateCardIsIgnoredOnLoad() {
    let suite = "ChatToolSpecTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(["trello_create_card"], forKey: UserDefaultsKeys.chatAlwaysAllowedTools)
    let store = ChatToolAlwaysAllow(defaults: defaults)
    #expect(!store.contains("trello_create_card"))
    #expect(store.toolNames.isEmpty)
  }

  @Test func cacheDictateAndLabelsMatchTheOldTables() {
    let names = Set(Self.declaredNames)
    #expect(Self.legacyCacheable.isSubset(of: names))
    #expect(Self.legacyDictateEligible.isSubset(of: names))
    for name in names {
      #expect(ChatToolTurnMemo.isCacheableTool(name) == Self.legacyCacheable.contains(name), "cache \(name)")
      #expect(ChatToolAlwaysAllow.displayName(for: name) == Self.legacyDisplayName(for: name), "label \(name)")
    }
    #expect(DictatePromptAgent.readOnlyToolNames == Self.legacyDictateEligible)
    // Read-only IMAP tools are cacheable. They were missing from an earlier table; the spec keeps them.
    for name in ["mail_search", "mail_read", "mail_list_accounts"] {
      #expect(ChatToolSpec.named(name)?.cacheable == true, "\(name) cacheable")
      #expect(ChatToolSpec.named(name)?.dictateEligible == false, "\(name) dictate")
    }
  }

  // MARK: - Legacy predicates (the tables this spec replaced)

  private static func legacyRequiresUserApproval(_ name: String, args: [String: Any] = [:]) -> Bool {
    switch name {
    case "open_url",
         "google_calendar_create_event", "google_calendar_update_event", "google_calendar_delete_event",
         "google_tasks_create", "google_tasks_update", "google_tasks_complete", "google_tasks_delete",
         "trello_create_card", "trello_move_card", "trello_update_card", "trello_archive_card",
         ChatToolRegistry.rememberAboutUserToolName, "remember_file_location", "remember_dictation_term",
         ChatToolRegistry.forgetAboutUserToolName, "forget_file_location",
         "write_text_file", "append_to_file", "edit_text_file":
      return true
    case ChatToolRegistry.updateInstructionsToolName:
      return (args["action"] as? String) != "read"
    case AppSettingsChatTool.name:
      return (args["action"] as? String) == "set"
    default:
      return false
    }
  }

  private static func legacyAllowsChatWideApproval(_ name: String) -> Bool {
    switch name {
    case ChatToolRegistry.rememberAboutUserToolName, "remember_file_location", "remember_dictation_term",
         ChatToolRegistry.forgetAboutUserToolName, "forget_file_location",
         ChatToolRegistry.updateInstructionsToolName, AppSettingsChatTool.name, "open_url",
         "write_text_file", "append_to_file", "edit_text_file",
         "google_calendar_delete_event", "google_tasks_delete", "trello_archive_card":
      return false
    default:
      return legacyRequiresUserApproval(name, args: ["action": "write"])
    }
  }

  private static let legacyCacheable: Set<String> = [
    "search_files",
    "list_directory",
    "read_text_file",
    "list_workspace_folders",
    "list_whisper_shortcut_docs",
    "read_whisper_shortcut_doc",
    "read_clipboard",
    ChatToolRegistry.readConfigHistoryToolName,
    ChatToolRegistry.readRecentInteractionsToolName,
    "gmail_search",
    "gmail_read",
    "mail_search",
    "mail_read",
    "mail_list_accounts",
    "google_calendar_list_events",
    "google_tasks_list",
    "google_tasks_list_tasklists",
    "trello_list_boards",
    "trello_list_lists",
    "trello_list_cards",
  ]

  private static let legacyDictateEligible: Set<String> = [
    "google_calendar_list_events", "google_tasks_list_tasklists", "google_tasks_list",
    "gmail_search", "gmail_read",
    "trello_list_boards", "trello_list_lists", "trello_list_cards",
    "list_workspace_folders", "list_directory", "read_text_file", "search_files",
  ]

  private static func legacyDisplayName(for toolName: String) -> String {
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
