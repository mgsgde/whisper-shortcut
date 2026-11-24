import Foundation

/// One row of chat-tool policy. Every declaration `ChatToolRegistry` can offer has exactly one
/// row here; approval, turn-cache, Dictate Prompt eligibility and the Settings label are read
/// from this table. Adding a tool means adding a row. Nothing else defaults a new tool into
/// "allow for this chat" or "always allow".
///
/// Chat-wide and persistent approval are only for a tool whose effects stay in the user's own
/// account and can be undone. Writes that other people can see (Trello boards, shared files,
/// mail) are `.perCall`.
struct ChatToolSpec {
  /// `none` runs immediately. `perCall` asks every time. `chatWide` may be allowed for the rest
  /// of this chat. `persistent` may also be remembered across chats (`ChatToolAlwaysAllow`).
  enum Approval: Equatable {
    case none, perCall, chatWide, persistent
  }

  /// Which declaration array the tool belongs to. The spec test pairs each case with that array.
  enum Group: Equatable {
    case core, appDocs, memory, instructions, usageLog, appSettings
    case workspace, workspaceWrite, image
    case calendar, tasks, gmail
    case mailConnect, mail
    case trello, meeting
  }

  let name: String
  let group: Group
  let approval: Approval
  let cacheable: Bool
  let dictateEligible: Bool
  /// Settings label. A `String(localized:)` phrase, or the raw tool id when the tool has none.
  let displayName: String
  /// When set, a call needs the approval card only if this returns true. `approval` still
  /// decides how far a card that does appear may be widened. Nil means every call follows
  /// `approval` (`.none` runs, anything else asks).
  let requiresApproval: (([String: Any]) -> Bool)?

  init(
    name: String,
    group: Group,
    approval: Approval,
    cacheable: Bool,
    dictateEligible: Bool,
    displayName: String? = nil,
    requiresApproval: (([String: Any]) -> Bool)? = nil
  ) {
    self.name = name
    self.group = group
    self.approval = approval
    self.cacheable = cacheable
    self.dictateEligible = dictateEligible
    self.displayName = displayName ?? name
    self.requiresApproval = requiresApproval
  }

  static func named(_ name: String) -> ChatToolSpec? {
    byName[name]
  }

  private static let byName: [String: ChatToolSpec] = {
    var map: [String: ChatToolSpec] = [:]
    for spec in all { map[spec.name] = spec }
    return map
  }()

  static let all: [ChatToolSpec] = [
    ChatToolSpec(name: "read_clipboard", group: .core, approval: .none, cacheable: true, dictateEligible: false),
    ChatToolSpec(name: "copy_to_clipboard", group: .core, approval: .none, cacheable: false, dictateEligible: false),
    ChatToolSpec(name: "open_url", group: .core, approval: .perCall, cacheable: false, dictateEligible: false),
    ChatToolSpec(name: "remember_dictation_term", group: .core, approval: .perCall, cacheable: false, dictateEligible: false),

    ChatToolSpec(name: "list_whisper_shortcut_docs", group: .appDocs, approval: .none, cacheable: true, dictateEligible: false),
    ChatToolSpec(name: "read_whisper_shortcut_doc", group: .appDocs, approval: .none, cacheable: true, dictateEligible: false),

    ChatToolSpec(name: ChatToolRegistry.rememberAboutUserToolName, group: .memory, approval: .perCall, cacheable: false, dictateEligible: false),
    ChatToolSpec(name: ChatToolRegistry.forgetAboutUserToolName, group: .memory, approval: .perCall, cacheable: false, dictateEligible: false),

    ChatToolSpec(
      name: ChatToolRegistry.updateInstructionsToolName, group: .instructions, approval: .perCall,
      cacheable: false, dictateEligible: false,
      requiresApproval: { (args: [String: Any]) in (args["action"] as? String) != "read" }),
    ChatToolSpec(name: ChatToolRegistry.readConfigHistoryToolName, group: .instructions, approval: .none, cacheable: true, dictateEligible: false),

    ChatToolSpec(name: ChatToolRegistry.readRecentInteractionsToolName, group: .usageLog, approval: .none, cacheable: true, dictateEligible: false),

    ChatToolSpec(
      name: AppSettingsChatTool.name, group: .appSettings, approval: .perCall,
      cacheable: false, dictateEligible: false,
      requiresApproval: { (args: [String: Any]) in (args["action"] as? String) == "set" }),

    ChatToolSpec(name: "list_workspace_folders", group: .workspace, approval: .none, cacheable: true, dictateEligible: true),
    ChatToolSpec(name: "list_directory", group: .workspace, approval: .none, cacheable: true, dictateEligible: true),
    ChatToolSpec(name: "read_text_file", group: .workspace, approval: .none, cacheable: true, dictateEligible: true),
    ChatToolSpec(name: "search_files", group: .workspace, approval: .none, cacheable: true, dictateEligible: true),
    ChatToolSpec(name: "remember_file_location", group: .workspace, approval: .perCall, cacheable: false, dictateEligible: false),
    ChatToolSpec(name: "forget_file_location", group: .workspace, approval: .perCall, cacheable: false, dictateEligible: false),

    ChatToolSpec(name: "write_text_file", group: .workspaceWrite, approval: .perCall, cacheable: false, dictateEligible: false),
    ChatToolSpec(name: "append_to_file", group: .workspaceWrite, approval: .perCall, cacheable: false, dictateEligible: false),
    ChatToolSpec(name: "edit_text_file", group: .workspaceWrite, approval: .perCall, cacheable: false, dictateEligible: false),

    ChatToolSpec(name: ChatToolRegistry.generateImageToolName, group: .image, approval: .none, cacheable: false, dictateEligible: false),

    ChatToolSpec(name: "google_calendar_list_events", group: .calendar, approval: .none, cacheable: true, dictateEligible: true),
    ChatToolSpec(
      name: "google_calendar_create_event", group: .calendar, approval: .persistent,
      cacheable: false, dictateEligible: false, displayName: String(localized: "Create calendar events")),
    ChatToolSpec(
      name: "google_calendar_update_event", group: .calendar, approval: .persistent,
      cacheable: false, dictateEligible: false, displayName: String(localized: "Change calendar events")),
    ChatToolSpec(name: "google_calendar_delete_event", group: .calendar, approval: .perCall, cacheable: false, dictateEligible: false),

    ChatToolSpec(name: "google_tasks_list_tasklists", group: .tasks, approval: .none, cacheable: true, dictateEligible: true),
    ChatToolSpec(name: "google_tasks_list", group: .tasks, approval: .none, cacheable: true, dictateEligible: true),
    ChatToolSpec(
      name: "google_tasks_create", group: .tasks, approval: .persistent,
      cacheable: false, dictateEligible: false, displayName: String(localized: "Create tasks")),
    ChatToolSpec(
      name: "google_tasks_update", group: .tasks, approval: .persistent,
      cacheable: false, dictateEligible: false, displayName: String(localized: "Change tasks")),
    ChatToolSpec(
      name: "google_tasks_complete", group: .tasks, approval: .persistent,
      cacheable: false, dictateEligible: false, displayName: String(localized: "Complete tasks")),
    ChatToolSpec(name: "google_tasks_delete", group: .tasks, approval: .perCall, cacheable: false, dictateEligible: false),

    ChatToolSpec(name: "gmail_search", group: .gmail, approval: .none, cacheable: true, dictateEligible: true),
    ChatToolSpec(name: "gmail_read", group: .gmail, approval: .none, cacheable: true, dictateEligible: true),

    ChatToolSpec(name: ChatToolRegistry.connectMailAccountToolName, group: .mailConnect, approval: .none, cacheable: false, dictateEligible: false),

    // IMAP reads stay chat-only. Dictate Prompt has no account to pick and never offered them.
    ChatToolSpec(name: "mail_list_accounts", group: .mail, approval: .none, cacheable: true, dictateEligible: false),
    ChatToolSpec(name: "mail_search", group: .mail, approval: .none, cacheable: true, dictateEligible: false),
    ChatToolSpec(name: "mail_read", group: .mail, approval: .none, cacheable: true, dictateEligible: false),

    ChatToolSpec(name: "trello_list_boards", group: .trello, approval: .none, cacheable: true, dictateEligible: true),
    ChatToolSpec(name: "trello_list_lists", group: .trello, approval: .none, cacheable: true, dictateEligible: true),
    ChatToolSpec(name: "trello_list_cards", group: .trello, approval: .none, cacheable: true, dictateEligible: true),
    // Boards are often shared, so a write other people can see stays per-call.
    ChatToolSpec(
      name: "trello_create_card", group: .trello, approval: .perCall,
      cacheable: false, dictateEligible: false, displayName: String(localized: "Create Trello cards")),
    ChatToolSpec(
      name: "trello_move_card", group: .trello, approval: .perCall,
      cacheable: false, dictateEligible: false, displayName: String(localized: "Move Trello cards")),
    ChatToolSpec(
      name: "trello_update_card", group: .trello, approval: .perCall,
      cacheable: false, dictateEligible: false, displayName: String(localized: "Change Trello cards")),
    ChatToolSpec(name: "trello_archive_card", group: .trello, approval: .perCall, cacheable: false, dictateEligible: false),

    ChatToolSpec(name: ChatToolRegistry.refineMeetingSummaryToolName, group: .meeting, approval: .none, cacheable: false, dictateEligible: false),
    ChatToolSpec(name: ChatToolRegistry.correctTranscriptTermToolName, group: .meeting, approval: .none, cacheable: false, dictateEligible: false),
  ]
}
