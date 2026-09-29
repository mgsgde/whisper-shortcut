import Foundation

/// One tool call as the user sees it while a chat turn runs ("Searching Gmail for "invoice"…").
/// Live-only for now: the persisted counterpart is `ChatToolCallRecord` (plans/active/chat-tool-steps.md,
/// Slice 2 adds display fields there).
struct ChatToolStep: Identifiable, Equatable {
  enum Phase: Equatable {
    case awaitingApproval, running, done, failed, denied
  }

  let id: UUID
  let name: String
  let runningLabel: String
  let doneLabel: String
  var phase: Phase
  let startedAt: Date
  var finishedAt: Date?
  /// "3 results", or the error text for `.failed`.
  var resultSummary: String?

  var isActive: Bool { phase == .running || phase == .awaitingApproval }
}

/// Live tool steps of one in-flight turn. A separate `ObservableObject` for the same reason as
/// `StreamingBuffer`: step updates must re-render only the views that show them (the typing
/// indicator), never ripple through `ChatViewModel` into the transcript's `LazyVStack`
/// (plans/active/chat-freeze-investigation.md).
@MainActor
final class ToolStepsBuffer: ObservableObject {
  @Published private(set) var steps: [ChatToolStep] = []
  let turnStartedAt: Date

  init(turnStartedAt: Date = Date()) {
    self.turnStartedAt = turnStartedAt
  }

  var activeStep: ChatToolStep? { steps.last(where: \.isActive) }

  func step(_ id: UUID) -> ChatToolStep? { steps.first { $0.id == id } }

  @discardableResult
  func begin(name: String, args: [String: Any], phase: ChatToolStep.Phase = .running) -> UUID {
    let step = ChatToolStep(
      id: UUID(),
      name: name,
      runningLabel: ChatToolRegistry.stepLabel(name: name, args: args, done: false),
      doneLabel: ChatToolRegistry.stepLabel(name: name, args: args, done: true),
      phase: phase,
      startedAt: Date())
    steps.append(step)
    return step.id
  }

  func setPhase(_ id: UUID, _ phase: ChatToolStep.Phase) {
    guard let i = steps.firstIndex(where: { $0.id == id }), steps[i].phase != phase else { return }
    steps[i].phase = phase
  }

  func finish(_ id: UUID, phase: ChatToolStep.Phase, summary: String? = nil) {
    guard let i = steps.firstIndex(where: { $0.id == id }) else { return }
    steps[i].phase = phase
    steps[i].finishedAt = Date()
    steps[i].resultSummary = summary
  }

  /// Finishes the still-running step named `name`, if any (built-in web search has no call id).
  func finishActive(named name: String) {
    guard let step = steps.last(where: { $0.name == name && $0.isActive }) else { return }
    finish(step.id, phase: .done)
  }

  /// What the typing indicator says: the running step, numbered once the turn has several.
  var indicatorLabel: String? {
    guard let active = activeStep else { return nil }
    let label = active.phase == .awaitingApproval ? "Waiting for your approval…" : active.runningLabel
    return steps.count > 1 ? "Step \(steps.count) · \(label)" : label
  }
}

// MARK: - Inline approval

enum ToolApprovalDecision: Equatable {
  case allow, allowForChat, deny
}

/// A tool call waiting for the user's answer on the inline approval card. Exactly one per session
/// at a time: calls run sequentially, and the turn awaits the answer.
struct ToolApprovalRequest: Identifiable {
  let id: UUID
  let toolName: String
  /// What will happen, human-readable ("Create calendar event: Dentist").
  let summary: String
  let offersAllowForChat: Bool
  let continuation: CheckedContinuation<ToolApprovalDecision, Never>
}

// MARK: - Labels

extension ChatToolRegistry {
  /// Built-in provider web search (grounding). Not a declared tool; surfaced as a step so the
  /// indicator has one mechanism for everything the model does before it answers.
  static let webSearchStepName = "web_search"

  private enum StepObject {
    case quoted(String)    // "Searching Gmail for "invoice""
    case filename(String)  // "Reading notes.md"
    case plain(String)     // "Opening https://…"
  }

  private struct StepWording {
    let running: String
    let done: String
    var object: StepObject? = nil
    /// Noun for the result count ("3 results"); nil = no count.
    var countNoun: String? = nil
    /// Wording when the object argument is missing, where `running`/`done` would dangle
    /// ("Searching Gmail for…"). Nil = `running`/`done` read fine on their own.
    var bare: (running: String, done: String)? = nil
  }

  /// One entry per tool the chat declares. `ChatToolStepsTests` fails when a declared tool is
  /// missing here, so a new tool can't silently fall back to its raw id.
  private static let stepWordings: [String: StepWording] = [
    webSearchStepName: .init(running: "Searching the web", done: "Searched the web"),
    "read_clipboard": .init(running: "Reading the clipboard", done: "Read the clipboard"),
    "copy_to_clipboard": .init(running: "Copying to the clipboard", done: "Copied to the clipboard"),
    "open_url": .init(
      running: "Opening", done: "Opened", object: .plain("url"),
      bare: ("Opening a link", "Opened a link")),
    "remember_dictation_term": .init(
      running: "Saving dictation term", done: "Saved dictation term", object: .quoted("term")),
    "google_calendar_list_events": .init(
      running: "Checking your calendar", done: "Checked your calendar", countNoun: "events"),
    "google_calendar_create_event": .init(
      running: "Creating event", done: "Created event", object: .quoted("summary")),
    "google_calendar_update_event": .init(
      running: "Updating event", done: "Updated event", object: .quoted("summary")),
    "google_calendar_delete_event": .init(running: "Deleting event", done: "Deleted event"),
    "google_tasks_list_tasklists": .init(
      running: "Listing task lists", done: "Listed task lists", countNoun: "lists"),
    "google_tasks_list": .init(running: "Checking your tasks", done: "Checked your tasks", countNoun: "tasks"),
    "google_tasks_create": .init(running: "Creating task", done: "Created task", object: .quoted("title")),
    "google_tasks_update": .init(running: "Updating task", done: "Updated task", object: .quoted("title")),
    "google_tasks_complete": .init(running: "Completing task", done: "Completed task"),
    "google_tasks_delete": .init(running: "Deleting task", done: "Deleted task"),
    "gmail_search": .init(
      running: "Searching Gmail for", done: "Searched Gmail for", object: .quoted("query"),
      countNoun: "results", bare: ("Searching Gmail", "Searched Gmail")),
    "gmail_read": .init(running: "Reading an email", done: "Read an email"),
    "trello_list_boards": .init(
      running: "Listing Trello boards", done: "Listed Trello boards", countNoun: "boards"),
    "trello_list_lists": .init(
      running: "Listing Trello lists", done: "Listed Trello lists", countNoun: "lists"),
    "trello_list_cards": .init(
      running: "Checking Trello cards", done: "Checked Trello cards", countNoun: "cards"),
    "trello_create_card": .init(running: "Creating card", done: "Created card", object: .quoted("name")),
    "trello_move_card": .init(running: "Moving card", done: "Moved card"),
    "trello_update_card": .init(running: "Updating card", done: "Updated card", object: .quoted("name")),
    "trello_archive_card": .init(running: "Archiving card", done: "Archived card"),
    "list_whisper_shortcut_docs": .init(running: "Checking the app docs", done: "Checked the app docs"),
    "read_whisper_shortcut_doc": .init(running: "Reading the app docs", done: "Read the app docs"),
    "list_workspace_folders": .init(running: "Listing shared folders", done: "Listed shared folders"),
    "list_directory": .init(
      running: "Listing", done: "Listed", object: .filename("path"), countNoun: "entries",
      bare: ("Listing a folder", "Listed a folder")),
    "read_text_file": .init(
      running: "Reading", done: "Read", object: .filename("path"),
      bare: ("Reading a file", "Read a file")),
    "search_files": .init(
      running: "Searching files for", done: "Searched files for", object: .quoted("query"),
      countNoun: "matches", bare: ("Searching files", "Searched files")),
    "remember_file_location": .init(
      running: "Remembering where to find", done: "Remembered where to find", object: .filename("path"),
      bare: ("Remembering a file location", "Remembered a file location")),
    "forget_file_location": .init(running: "Forgetting a file location", done: "Forgot a file location"),
    "write_text_file": .init(
      running: "Writing", done: "Wrote", object: .filename("path"),
      bare: ("Writing a file", "Wrote a file")),
    "append_to_file": .init(
      running: "Appending to", done: "Appended to", object: .filename("path"),
      bare: ("Appending to a file", "Appended to a file")),
    "edit_text_file": .init(
      running: "Editing", done: "Edited", object: .filename("path"),
      bare: ("Editing a file", "Edited a file")),
    generateImageToolName: .init(running: "Generating an image", done: "Generated an image"),
    refineMeetingSummaryToolName: .init(
      running: "Refining the meeting summary", done: "Refined the meeting summary"),
    correctTranscriptTermToolName: .init(running: "Correcting the transcript", done: "Corrected the transcript"),
    updateInstructionsToolName: .init(
      running: "Updating app instructions", done: "Updated app instructions"),
    rememberAboutUserToolName: .init(running: "Saving to memory", done: "Saved to memory"),
    forgetAboutUserToolName: .init(running: "Removing from memory", done: "Removed from memory"),
  ]

  static func hasStepWording(_ name: String) -> Bool { stepWordings[name] != nil }

  /// Human label for a tool call. Running labels end in "…"; done labels don't carry the count
  /// (see `resultSummary`).
  static func stepLabel(name: String, args: [String: Any], done: Bool) -> String {
    // Reading the rules is the harmless first step the model is told to take; don't call it an update.
    if name == updateInstructionsToolName, (args["action"] as? String) == "read" {
      return done ? "Read app instructions" : "Reading app instructions…"
    }
    guard let wording = stepWordings[name] else {
      let readable = name.replacingOccurrences(of: "_", with: " ")
      return done ? "Ran \(readable)" : "Running \(readable)…"
    }
    var label = done ? wording.done : wording.running
    if let object = wording.object, let text = objectText(object, args: args) {
      label += " " + text
    } else if let bare = wording.bare {
      label = done ? bare.done : bare.running
    }
    return done ? label : label + "…"
  }

  private static func objectText(_ object: StepObject, args: [String: Any]) -> String? {
    func value(_ key: String) -> String? {
      guard let raw = (args[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty else { return nil }
      return raw
    }
    switch object {
    case .quoted(let key):
      return value(key).map { "\"\(truncated($0))\"" }
    case .filename(let key):
      return value(key).map { truncated((($0 as NSString).lastPathComponent)) }
    case .plain(let key):
      return value(key).map { truncated($0) }
    }
  }

  private static func truncated(_ s: String, limit: Int = 40) -> String {
    s.count > limit ? String(s.prefix(limit)) + "…" : s
  }

  /// Short outcome for a finished call: "3 results" for list-type tools, nil otherwise.
  static func resultSummary(name: String, response: [String: Any]) -> String? {
    guard let noun = stepWordings[name]?.countNoun, let count = resultCount(response) else { return nil }
    return "\(count) \(noun)"
  }

  /// Error text of a tool response, if the call failed.
  static func resultError(_ response: [String: Any]) -> String? {
    guard let error = response["error"] else { return nil }
    let text = (error as? String) ?? "\(error)"
    return truncated(text, limit: 120)
  }

  /// Item count of a list-type response: a well-known key first, else the only array present.
  /// Nil for errors and for responses with no (or several unnamed) arrays.
  static func resultCount(_ response: [String: Any]) -> Int? {
    guard response["error"] == nil else { return nil }
    let knownKeys = [
      "results", "messages", "events", "tasks", "tasklists", "items", "cards", "boards", "lists",
      "entries", "matches", "files",
    ]
    for key in knownKeys {
      if let array = response[key] as? [Any] { return array.count }
    }
    let arrays = response.values.compactMap { $0 as? [Any] }
    return arrays.count == 1 ? arrays[0].count : nil
  }
}
