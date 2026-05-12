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

enum ChatToolRegistry {

  /// Base function declarations (always available).
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

  static let calendarFunctionDeclarations: [[String: Any]] = [
    [
      "name": "google_calendar_list_events",
      "description": "Lists upcoming calendar events (meetings, appointments) from Google Calendar. Use ONLY for scheduled events with specific start/end times. Do NOT use for tasks or to-dos — use google_tasks_list instead.",
      "parameters": [
        "type": "object",
        "properties": [
          "max_results": [
            "type": "integer",
            "description": "Maximum number of events to return (1-50, default 10).",
          ],
          "hours_ahead": [
            "type": "integer",
            "description": "How many hours ahead to look (default 168 = 1 week).",
          ],
        ] as [String: Any],
      ],
    ],
    [
      "name": "google_calendar_create_event",
      "description": "Creates a new calendar event (meeting, appointment) with a specific start and end time on Google Calendar. Do NOT use for tasks or to-dos — use google_tasks_create instead. Always confirm details with the user before calling this.",
      "parameters": [
        "type": "object",
        "properties": [
          "summary": [
            "type": "string",
            "description": "Title/summary of the event.",
          ],
          "start_iso8601": [
            "type": "string",
            "description": "Start time in ISO 8601 format (e.g. 2026-04-22T15:00:00+02:00).",
          ],
          "end_iso8601": [
            "type": "string",
            "description": "End time in ISO 8601 format (e.g. 2026-04-22T15:30:00+02:00).",
          ],
          "time_zone": [
            "type": "string",
            "description": "IANA time zone identifier (e.g. Europe/Berlin). Defaults to the user's local time zone if omitted.",
          ],
          "location": [
            "type": "string",
            "description": "Location or address of the event (e.g. 'Kaiserstraße 231-233, 76133 Karlsruhe').",
          ],
          "description": [
            "type": "string",
            "description": "Detailed description or notes for the event (e.g. links, agenda, instructions).",
          ],
        ] as [String: Any],
        "required": ["summary", "start_iso8601", "end_iso8601"],
      ],
    ],
    [
      "name": "google_calendar_delete_event",
      "description": "Deletes a calendar event by its event_id (from google_calendar_list_events results). Always confirm with the user before deleting.",
      "parameters": [
        "type": "object",
        "properties": [
          "event_id": [
            "type": "string",
            "description": "The ID of the event to delete (from google_calendar_list_events results).",
          ],
        ] as [String: Any],
        "required": ["event_id"],
      ],
    ],
  ]

  static let tasksFunctionDeclarations: [[String: Any]] = [
    [
      "name": "google_tasks_list_tasklists",
      "description": "Lists all of the user's Google Tasks lists (e.g. 'Todos', 'backlog', 'waiting'). Call this first to discover available lists and their IDs before operating on a specific list.",
      "parameters": [
        "type": "object",
        "properties": [:] as [String: Any],
      ],
    ],
    [
      "name": "google_tasks_list",
      "description": "Lists the user's Google Tasks (to-do items) from a specific list. Use when the user asks about tasks, to-dos, reminders, or things to do. Do NOT use for calendar events or meetings — use google_calendar_list_events instead. Call google_tasks_list_tasklists first if you need to find the right list.",
      "parameters": [
        "type": "object",
        "properties": [
          "task_list_id": [
            "type": "string",
            "description": "ID of the task list to query (from google_tasks_list_tasklists). Defaults to the primary list if omitted.",
          ],
          "max_results": [
            "type": "integer",
            "description": "Maximum number of tasks to return (1-100, default 20).",
          ],
          "show_completed": [
            "type": "boolean",
            "description": "Whether to include completed tasks (default false).",
          ],
        ] as [String: Any],
      ],
    ],
    [
      "name": "google_tasks_create",
      "description": "Creates a new Google Task (to-do item, not a calendar event). Use when the user asks to add a task, to-do, or reminder. Do NOT use for calendar events or meetings — use google_calendar_create_event instead.",
      "parameters": [
        "type": "object",
        "properties": [
          "title": [
            "type": "string",
            "description": "Title of the task.",
          ],
          "task_list_id": [
            "type": "string",
            "description": "ID of the task list to add to (from google_tasks_list_tasklists). Defaults to the primary list if omitted.",
          ],
          "notes": [
            "type": "string",
            "description": "Optional notes or details for the task.",
          ],
          "due": [
            "type": "string",
            "description": "Optional due date in ISO 8601 format (e.g. 2026-04-23T00:00:00Z).",
          ],
        ] as [String: Any],
        "required": ["title"],
      ],
    ],
    [
      "name": "google_tasks_complete",
      "description": "Marks a Google Task as completed. Requires the task_id from google_tasks_list.",
      "parameters": [
        "type": "object",
        "properties": [
          "task_id": [
            "type": "string",
            "description": "The ID of the task to complete (from google_tasks_list results).",
          ],
          "task_list_id": [
            "type": "string",
            "description": "ID of the task list containing the task. Defaults to the primary list if omitted.",
          ],
        ] as [String: Any],
        "required": ["task_id"],
      ],
    ],
    [
      "name": "google_tasks_delete",
      "description": "Deletes a Google Task permanently. Requires the task_id from google_tasks_list. Always confirm with the user before deleting.",
      "parameters": [
        "type": "object",
        "properties": [
          "task_id": [
            "type": "string",
            "description": "The ID of the task to delete (from google_tasks_list results).",
          ],
          "task_list_id": [
            "type": "string",
            "description": "ID of the task list containing the task. Defaults to the primary list if omitted.",
          ],
        ] as [String: Any],
        "required": ["task_id"],
      ],
    ],
  ]

  static let gmailFunctionDeclarations: [[String: Any]] = [
    [
      "name": "gmail_search",
      "description": "Searches the user's Gmail inbox. Returns a list of matching emails with sender, subject, date, and snippet. Use when the user asks about emails, messages, or inbox contents. Supports Gmail search syntax (e.g. 'from:alice', 'is:unread', 'subject:invoice', 'newer_than:2d').",
      "parameters": [
        "type": "object",
        "properties": [
          "query": [
            "type": "string",
            "description": "Gmail search query (e.g. 'is:unread', 'from:boss@company.com', 'subject:meeting newer_than:7d'). Defaults to recent emails if empty.",
          ],
          "max_results": [
            "type": "integer",
            "description": "Maximum number of emails to return (1-50, default 10).",
          ],
        ] as [String: Any],
      ],
    ],
    [
      "name": "gmail_read",
      "description": "Reads the full content of a specific email by its message_id (from gmail_search results). Returns subject, from, to, date, and the full body text.",
      "parameters": [
        "type": "object",
        "properties": [
          "message_id": [
            "type": "string",
            "description": "The message ID to read (from gmail_search results).",
          ],
        ] as [String: Any],
        "required": ["message_id"],
      ],
    ],
  ]

  static let trelloFunctionDeclarations: [[String: Any]] = [
    [
      "name": "trello_list_boards",
      "description": "Lists the user's open Trello boards. Use this first to discover available boards and their IDs before operating on a specific board.",
      "parameters": [
        "type": "object",
        "properties": [:] as [String: Any],
      ],
    ],
    [
      "name": "trello_list_lists",
      "description": "Lists the open lists (columns) on a Trello board. Use this to discover list IDs before creating or moving cards. Call trello_list_boards first to find the board_id.",
      "parameters": [
        "type": "object",
        "properties": [
          "board_id": [
            "type": "string",
            "description": "The Trello board ID (from trello_list_boards results).",
          ],
        ] as [String: Any],
        "required": ["board_id"],
      ],
    ],
    [
      "name": "trello_list_cards",
      "description": "Lists cards in a specific list or across an entire board. Provide either list_id or board_id.",
      "parameters": [
        "type": "object",
        "properties": [
          "list_id": [
            "type": "string",
            "description": "The Trello list ID (from trello_list_lists). Preferred when known.",
          ],
          "board_id": [
            "type": "string",
            "description": "The Trello board ID. Used only when list_id is not provided — returns all cards on the board.",
          ],
          "max_results": [
            "type": "integer",
            "description": "Maximum number of cards to return (1-100, default 50).",
          ],
        ] as [String: Any],
      ],
    ],
    [
      "name": "trello_create_card",
      "description": "Creates a new Trello card in the given list. REQUIRED: You MUST call trello_list_lists in the current conversation FIRST and use one of the list_id values it returned. Never guess, invent, or recall a list_id from memory — Trello list IDs are 24-char hex strings that you cannot derive. If unsure, call trello_list_boards then trello_list_lists. Confirm the list with the user before bulk-creating many cards.",
      "parameters": [
        "type": "object",
        "properties": [
          "list_id": [
            "type": "string",
            "description": "The Trello list ID. MUST be a value returned by trello_list_lists earlier in THIS conversation. Do NOT guess or fabricate.",
          ],
          "name": [
            "type": "string",
            "description": "Title of the card.",
          ],
          "description": [
            "type": "string",
            "description": "Optional description (markdown allowed).",
          ],
          "due": [
            "type": "string",
            "description": "Optional due date in ISO 8601 format (e.g. 2026-04-23T18:00:00Z).",
          ],
        ] as [String: Any],
        "required": ["list_id", "name"],
      ],
    ],
    [
      "name": "trello_move_card",
      "description": "Moves a Trello card to a different list (e.g. from 'To do' to 'Doing'). REQUIRED: Both card_id and list_id MUST come from earlier trello_list_cards / trello_list_lists calls in THIS conversation — never guess or fabricate Trello IDs.",
      "parameters": [
        "type": "object",
        "properties": [
          "card_id": [
            "type": "string",
            "description": "The card ID to move. MUST be a value returned by trello_list_cards earlier in this conversation.",
          ],
          "list_id": [
            "type": "string",
            "description": "The destination list ID. MUST be a value returned by trello_list_lists earlier in this conversation.",
          ],
        ] as [String: Any],
        "required": ["card_id", "list_id"],
      ],
    ],
    [
      "name": "trello_update_card",
      "description": "Updates fields of an existing Trello card. REQUIRED: card_id MUST be a value returned by trello_list_cards earlier in THIS conversation — never guess. At least one of name, description, or due must be provided.",
      "parameters": [
        "type": "object",
        "properties": [
          "card_id": [
            "type": "string",
            "description": "The card ID to update. MUST be a value returned by trello_list_cards earlier in this conversation.",
          ],
          "name": [
            "type": "string",
            "description": "New title for the card.",
          ],
          "description": [
            "type": "string",
            "description": "New description for the card (markdown allowed).",
          ],
          "due": [
            "type": "string",
            "description": "New due date in ISO 8601 format, or empty string to clear it.",
          ],
        ] as [String: Any],
        "required": ["card_id"],
      ],
    ],
    [
      "name": "trello_archive_card",
      "description": "Archives a Trello card (Trello's equivalent of 'complete' — the card is reversibly closed). REQUIRED: card_id MUST be a value returned by trello_list_cards earlier in THIS conversation — never guess. Always confirm with the user before archiving.",
      "parameters": [
        "type": "object",
        "properties": [
          "card_id": [
            "type": "string",
            "description": "The card ID to archive. MUST be a value returned by trello_list_cards earlier in this conversation.",
          ],
        ] as [String: Any],
        "required": ["card_id"],
      ],
    ],
  ]

  // MARK: - WhisperShortcut Self-Documentation Tools
  //
  // Lets the chat answer "meta" questions about WhisperShortcut itself
  // (features, settings, shortcuts, data storage, etc.) by reading curated
  // markdown docs that are mirrored from the repo into the app bundle by
  // scripts/rebuild-and-restart.sh (see WhisperShortcut/Docs/).

  /// Manifest of user-facing markdown docs bundled with the app.
  /// Filenames must match files in WhisperShortcut/Docs/.
  /// Keep descriptions short and stable; the model reads the full doc body via
  /// `read_whisper_shortcut_doc`, so the description only needs to disambiguate which file
  /// to read.
  private static let availableDocs:
    [(name: String, title: String, description: String, filename: String)] = [
      (
        name: "readme",
        title: "README — Project Overview",
        description:
          "App overview, features, system requirements, install, and BYOK API key setup.",
        filename: "README.md"
      ),
      (
        name: "data-directories",
        title: "Data Directories",
        description:
          "Where WhisperShortcut stores app data on macOS (settings, logs, prompts, sessions, recordings).",
        filename: "data-directories.md"
      ),
    ]

  static let appDocsFunctionDeclarations: [[String: Any]] = [
    [
      "name": "list_whisper_shortcut_docs",
      "description":
        "Lists the documentation bundled with WhisperShortcut so you can answer questions about the app itself — its features, shortcuts, supported models, settings, data storage, requirements, installation, etc. ALWAYS call this first when the user asks 'How does WhisperShortcut work?', 'What can this app do?', 'How do I configure X?', 'Where are my recordings stored?', or any similar self-referential question. Returns {docs: [{name, title, description}], app_version, build_number}.",
      "parameters": [
        "type": "object",
        "properties": [:] as [String: Any],
      ],
    ],
    [
      "name": "read_whisper_shortcut_doc",
      "description":
        "Returns the full markdown content of one WhisperShortcut documentation file listed by list_whisper_shortcut_docs. Use this to ground detailed answers about how WhisperShortcut works in its actual bundled documentation rather than guessing. Returns {name, title, content}.",
      "parameters": [
        "type": "object",
        "properties": [
          "name": [
            "type": "string",
            "description":
              "The doc identifier as returned by list_whisper_shortcut_docs (e.g. 'readme', 'data-directories').",
          ],
        ] as [String: Any],
        "required": ["name"],
      ],
    ],
  ]

  static func allDeclarations(calendarConnected: Bool, trelloConnected: Bool) -> [[String: Any]] {
    var decls = functionDeclarations + appDocsFunctionDeclarations
    if calendarConnected {
      decls += calendarFunctionDeclarations + tasksFunctionDeclarations + gmailFunctionDeclarations
    }
    if trelloConnected {
      decls += trelloFunctionDeclarations
    }
    return decls
  }

  private static func intArgument(_ args: [String: Any], _ key: String, default defaultValue: Int) -> Int {
    if let value = args[key] as? Int { return value }
    if let value = args[key] as? Double { return Int(value) }
    if let value = args[key] as? NSNumber { return value.intValue }
    if let value = args[key] as? String, let parsed = Int(value) { return parsed }
    return defaultValue
  }

  private static func boolArgument(_ args: [String: Any], _ key: String, default defaultValue: Bool) -> Bool {
    if let value = args[key] as? Bool { return value }
    if let value = args[key] as? NSNumber { return value.boolValue }
    if let value = args[key] as? String {
      switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
      case "true", "yes", "1": return true
      case "false", "no", "0": return false
      default: break
      }
    }
    return defaultValue
  }

  private static let googleNotConnectedError: [String: Any] = [
    "error": "Google is not connected. Connect it in Settings or use /connect-google."
  ]

  private static let trelloNotConnectedError: [String: Any] = [
    "error": "Trello is not connected. Connect it in Settings or use /connect-trello."
  ]

  @MainActor
  static func execute(name: String, args: [String: Any]) async -> [String: Any] {
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

    case "google_calendar_list_events":
      guard GoogleAccountOAuthService.shared.isConnected else { return googleNotConnectedError }
      let maxResults = intArgument(args, "max_results", default: 10)
      let hoursAhead = intArgument(args, "hours_ahead", default: 168)
      do {
        let events = try await GoogleCalendarAPIClient.shared.listUpcomingEvents(
          maxResults: maxResults, hoursAhead: hoursAhead)
        DebugLogger.logSuccess("GEMINI-CHAT-TOOL: calendar list returned \(events.count) events")
        return ["events": events, "count": events.count]
      } catch {
        DebugLogger.logError("GEMINI-CHAT-TOOL: calendar list failed: \(error.localizedDescription)")
        return ["error": error.localizedDescription]
      }

    case "google_calendar_create_event":
      guard GoogleAccountOAuthService.shared.isConnected else { return googleNotConnectedError }
      guard let summary = args["summary"] as? String,
            let startISO = args["start_iso8601"] as? String,
            let endISO = args["end_iso8601"] as? String
      else {
        return ["error": "Missing required arguments: summary, start_iso8601, end_iso8601"]
      }
      let timeZone = args["time_zone"] as? String ?? TimeZone.current.identifier
      let location = args["location"] as? String
      let description = args["description"] as? String
      do {
        let result = try await GoogleCalendarAPIClient.shared.createEvent(
          summary: summary, startISO: startISO, endISO: endISO, timeZone: timeZone,
          location: location, description: description)
        DebugLogger.logSuccess("GEMINI-CHAT-TOOL: calendar create ok, id=\(result["event_id"] ?? "?")")
        return result
      } catch {
        DebugLogger.logError("GEMINI-CHAT-TOOL: calendar create failed: \(error.localizedDescription)")
        return ["error": error.localizedDescription]
      }

    case "google_calendar_delete_event":
      guard GoogleAccountOAuthService.shared.isConnected else { return googleNotConnectedError }
      guard let eventId = args["event_id"] as? String else {
        return ["error": "Missing required argument: event_id"]
      }
      do {
        let result = try await GoogleCalendarAPIClient.shared.deleteEvent(eventId: eventId)
        return result
      } catch {
        DebugLogger.logError("GEMINI-CHAT-TOOL: calendar delete failed: \(error.localizedDescription)")
        return ["error": error.localizedDescription]
      }

    case "google_tasks_list_tasklists":
      guard GoogleAccountOAuthService.shared.isConnected else { return googleNotConnectedError }
      do {
        let lists = try await GoogleTasksAPIClient.shared.listTaskLists()
        return ["task_lists": lists, "count": lists.count]
      } catch {
        DebugLogger.logError("GEMINI-CHAT-TOOL: tasks list_tasklists failed: \(error.localizedDescription)")
        return ["error": error.localizedDescription]
      }

    case "google_tasks_list":
      guard GoogleAccountOAuthService.shared.isConnected else { return googleNotConnectedError }
      let taskListId = args["task_list_id"] as? String ?? "@default"
      let maxResults = intArgument(args, "max_results", default: 20)
      let showCompleted = boolArgument(args, "show_completed", default: false)
      do {
        let tasks = try await GoogleTasksAPIClient.shared.listTasks(
          taskListId: taskListId, maxResults: maxResults, showCompleted: showCompleted)
        return ["tasks": tasks, "count": tasks.count]
      } catch {
        DebugLogger.logError("GEMINI-CHAT-TOOL: tasks list failed: \(error.localizedDescription)")
        return ["error": error.localizedDescription]
      }

    case "google_tasks_create":
      guard GoogleAccountOAuthService.shared.isConnected else { return googleNotConnectedError }
      guard let title = args["title"] as? String else {
        return ["error": "Missing required argument: title"]
      }
      let taskListId = args["task_list_id"] as? String ?? "@default"
      let notes = args["notes"] as? String
      let due = args["due"] as? String
      do {
        let result = try await GoogleTasksAPIClient.shared.createTask(
          title: title, notes: notes, due: due, taskListId: taskListId)
        return result
      } catch {
        DebugLogger.logError("GEMINI-CHAT-TOOL: tasks create failed: \(error.localizedDescription)")
        return ["error": error.localizedDescription]
      }

    case "google_tasks_complete":
      guard GoogleAccountOAuthService.shared.isConnected else { return googleNotConnectedError }
      guard let taskId = args["task_id"] as? String else {
        return ["error": "Missing required argument: task_id"]
      }
      let taskListId = args["task_list_id"] as? String ?? "@default"
      do {
        let result = try await GoogleTasksAPIClient.shared.completeTask(
          taskId: taskId, taskListId: taskListId)
        return result
      } catch {
        DebugLogger.logError("GEMINI-CHAT-TOOL: tasks complete failed: \(error.localizedDescription)")
        return ["error": error.localizedDescription]
      }

    case "google_tasks_delete":
      guard GoogleAccountOAuthService.shared.isConnected else { return googleNotConnectedError }
      guard let taskId = args["task_id"] as? String else {
        return ["error": "Missing required argument: task_id"]
      }
      let taskListId = args["task_list_id"] as? String ?? "@default"
      do {
        let result = try await GoogleTasksAPIClient.shared.deleteTask(
          taskId: taskId, taskListId: taskListId)
        return result
      } catch {
        DebugLogger.logError("GEMINI-CHAT-TOOL: tasks delete failed: \(error.localizedDescription)")
        return ["error": error.localizedDescription]
      }

    case "gmail_search":
      guard GoogleAccountOAuthService.shared.isConnected else { return googleNotConnectedError }
      let query = args["query"] as? String ?? ""
      let maxResults = intArgument(args, "max_results", default: 10)
      do {
        let messages = try await GmailAPIClient.shared.searchMessages(
          query: query, maxResults: maxResults)
        return ["emails": messages, "count": messages.count]
      } catch {
        DebugLogger.logError("GEMINI-CHAT-TOOL: gmail search failed: \(error.localizedDescription)")
        return ["error": error.localizedDescription]
      }

    case "gmail_read":
      guard GoogleAccountOAuthService.shared.isConnected else { return googleNotConnectedError }
      guard let messageId = args["message_id"] as? String else {
        return ["error": "Missing required argument: message_id"]
      }
      do {
        let message = try await GmailAPIClient.shared.readMessage(messageId: messageId)
        return message
      } catch {
        DebugLogger.logError("GEMINI-CHAT-TOOL: gmail read failed: \(error.localizedDescription)")
        return ["error": error.localizedDescription]
      }

    case "trello_list_boards":
      guard TrelloOAuthService.shared.isConnected else { return trelloNotConnectedError }
      do {
        let boards = try await TrelloAPIClient.shared.listBoards()
        return ["boards": boards, "count": boards.count]
      } catch {
        DebugLogger.logError("GEMINI-CHAT-TOOL: trello list_boards failed: \(error.localizedDescription)")
        return ["error": error.localizedDescription]
      }

    case "trello_list_lists":
      guard TrelloOAuthService.shared.isConnected else { return trelloNotConnectedError }
      guard let boardId = args["board_id"] as? String else {
        return ["error": "Missing required argument: board_id"]
      }
      do {
        let lists = try await TrelloAPIClient.shared.listLists(boardId: boardId)
        return ["lists": lists, "count": lists.count]
      } catch {
        DebugLogger.logError("GEMINI-CHAT-TOOL: trello list_lists failed: \(error.localizedDescription)")
        return ["error": error.localizedDescription]
      }

    case "trello_list_cards":
      guard TrelloOAuthService.shared.isConnected else { return trelloNotConnectedError }
      let listId = args["list_id"] as? String
      let boardId = args["board_id"] as? String
      let maxResults = intArgument(args, "max_results", default: 50)
      guard listId != nil || boardId != nil else {
        return ["error": "Missing argument: either list_id or board_id is required"]
      }
      do {
        let cards = try await TrelloAPIClient.shared.listCards(
          listId: listId, boardId: boardId, maxResults: maxResults)
        return ["cards": cards, "count": cards.count]
      } catch {
        DebugLogger.logError("GEMINI-CHAT-TOOL: trello list_cards failed: \(error.localizedDescription)")
        return ["error": error.localizedDescription]
      }

    case "trello_create_card":
      guard TrelloOAuthService.shared.isConnected else { return trelloNotConnectedError }
      guard let listId = args["list_id"] as? String,
            let cardName = args["name"] as? String
      else {
        return ["error": "Missing required arguments: list_id, name"]
      }
      let description = args["description"] as? String
      let due = args["due"] as? String
      do {
        let result = try await TrelloAPIClient.shared.createCard(
          listId: listId, name: cardName, description: description, due: due)
        return result
      } catch {
        DebugLogger.logError("GEMINI-CHAT-TOOL: trello create_card failed: \(error.localizedDescription)")
        return ["error": error.localizedDescription]
      }

    case "trello_move_card":
      guard TrelloOAuthService.shared.isConnected else { return trelloNotConnectedError }
      guard let cardId = args["card_id"] as? String,
            let listId = args["list_id"] as? String
      else {
        return ["error": "Missing required arguments: card_id, list_id"]
      }
      do {
        let result = try await TrelloAPIClient.shared.moveCard(cardId: cardId, listId: listId)
        return result
      } catch {
        DebugLogger.logError("GEMINI-CHAT-TOOL: trello move_card failed: \(error.localizedDescription)")
        return ["error": error.localizedDescription]
      }

    case "trello_update_card":
      guard TrelloOAuthService.shared.isConnected else { return trelloNotConnectedError }
      guard let cardId = args["card_id"] as? String else {
        return ["error": "Missing required argument: card_id"]
      }
      let cardName = args["name"] as? String
      let description = args["description"] as? String
      let due = args["due"] as? String
      if cardName == nil && description == nil && due == nil {
        return ["error": "At least one of name, description, or due is required"]
      }
      do {
        let result = try await TrelloAPIClient.shared.updateCard(
          cardId: cardId, name: cardName, description: description, due: due)
        return result
      } catch {
        DebugLogger.logError("GEMINI-CHAT-TOOL: trello update_card failed: \(error.localizedDescription)")
        return ["error": error.localizedDescription]
      }

    case "trello_archive_card":
      guard TrelloOAuthService.shared.isConnected else { return trelloNotConnectedError }
      guard let cardId = args["card_id"] as? String else {
        return ["error": "Missing required argument: card_id"]
      }
      do {
        let result = try await TrelloAPIClient.shared.archiveCard(cardId: cardId)
        return result
      } catch {
        DebugLogger.logError("GEMINI-CHAT-TOOL: trello archive_card failed: \(error.localizedDescription)")
        return ["error": error.localizedDescription]
      }

    case "list_whisper_shortcut_docs":
      let docsList: [[String: Any]] = availableDocs.map { doc in
        ["name": doc.name, "title": doc.title, "description": doc.description]
      }
      DebugLogger.logSuccess("GEMINI-CHAT-TOOL: listed \(docsList.count) bundled docs")
      return [
        "docs": docsList,
        "app_version": AppConstants.appVersion,
        "build_number": AppConstants.appBuildNumber,
      ]

    case "read_whisper_shortcut_doc":
      guard let docName = args["name"] as? String else {
        return ["error": "Missing required argument: name"]
      }
      guard let doc = availableDocs.first(where: { $0.name == docName }) else {
        let validNames = availableDocs.map { $0.name }.joined(separator: ", ")
        return ["error": "Unknown doc '\(docName)'. Available: \(validNames)"]
      }
      let base = (doc.filename as NSString).deletingPathExtension
      let ext = (doc.filename as NSString).pathExtension
      let url =
        Bundle.main.url(forResource: base, withExtension: ext, subdirectory: "Docs")
        ?? Bundle.main.url(forResource: base, withExtension: ext)
      guard let url, let content = try? String(contentsOf: url, encoding: .utf8) else {
        DebugLogger.logError(
          "GEMINI-CHAT-TOOL: doc '\(docName)' missing from bundle (\(doc.filename))")
        return ["error": "Doc '\(docName)' is not bundled with this build of WhisperShortcut."]
      }
      DebugLogger.logSuccess(
        "GEMINI-CHAT-TOOL: returned doc '\(docName)' (\(content.utf8.count) bytes)")
      return ["name": doc.name, "title": doc.title, "content": content]

    default:
      return ["error": "Unknown tool: \(name)"]
    }
  }
}
