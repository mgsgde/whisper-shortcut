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

  static func allDeclarations(calendarConnected: Bool) -> [[String: Any]] {
    if calendarConnected {
      return functionDeclarations + calendarFunctionDeclarations + tasksFunctionDeclarations + gmailFunctionDeclarations
    }
    return functionDeclarations
  }

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
      guard GoogleAccountOAuthService.shared.isConnected else {
        return ["error": "Google is not connected. Connect it in Settings or use /connect-google."]
      }
      let maxResults = args["max_results"] as? Int ?? 10
      let hoursAhead = args["hours_ahead"] as? Int ?? 168
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
      guard GoogleAccountOAuthService.shared.isConnected else {
        return ["error": "Google is not connected. Connect it in Settings or use /connect-google."]
      }
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
      guard GoogleAccountOAuthService.shared.isConnected else {
        return ["error": "Google is not connected. Connect it in Settings or use /connect-google."]
      }
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
      guard GoogleAccountOAuthService.shared.isConnected else {
        return ["error": "Google account is not connected. Connect it in Settings."]
      }
      do {
        let lists = try await GoogleTasksAPIClient.shared.listTaskLists()
        return ["task_lists": lists, "count": lists.count]
      } catch {
        DebugLogger.logError("GEMINI-CHAT-TOOL: tasks list_tasklists failed: \(error.localizedDescription)")
        return ["error": error.localizedDescription]
      }

    case "google_tasks_list":
      guard GoogleAccountOAuthService.shared.isConnected else {
        return ["error": "Google account is not connected. Connect it in Settings."]
      }
      let taskListId = args["task_list_id"] as? String ?? "@default"
      let maxResults = args["max_results"] as? Int ?? 20
      let showCompleted = args["show_completed"] as? Bool ?? false
      do {
        let tasks = try await GoogleTasksAPIClient.shared.listTasks(
          taskListId: taskListId, maxResults: maxResults, showCompleted: showCompleted)
        return ["tasks": tasks, "count": tasks.count]
      } catch {
        DebugLogger.logError("GEMINI-CHAT-TOOL: tasks list failed: \(error.localizedDescription)")
        return ["error": error.localizedDescription]
      }

    case "google_tasks_create":
      guard GoogleAccountOAuthService.shared.isConnected else {
        return ["error": "Google account is not connected. Connect it in Settings."]
      }
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
      guard GoogleAccountOAuthService.shared.isConnected else {
        return ["error": "Google account is not connected. Connect it in Settings."]
      }
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
      guard GoogleAccountOAuthService.shared.isConnected else {
        return ["error": "Google account is not connected. Connect it in Settings."]
      }
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
      guard GoogleAccountOAuthService.shared.isConnected else {
        return ["error": "Google account is not connected. Connect it in Settings."]
      }
      let query = args["query"] as? String ?? ""
      let maxResults = args["max_results"] as? Int ?? 10
      do {
        let messages = try await GmailAPIClient.shared.searchMessages(
          query: query, maxResults: maxResults)
        return ["emails": messages, "count": messages.count]
      } catch {
        DebugLogger.logError("GEMINI-CHAT-TOOL: gmail search failed: \(error.localizedDescription)")
        return ["error": error.localizedDescription]
      }

    case "gmail_read":
      guard GoogleAccountOAuthService.shared.isConnected else {
        return ["error": "Google account is not connected. Connect it in Settings."]
      }
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

    default:
      return ["error": "Unknown tool: \(name)"]
    }
  }
}
