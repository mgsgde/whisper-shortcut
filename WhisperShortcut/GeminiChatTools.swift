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

enum GeminiChatToolRegistry {

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
      "description": "Lists upcoming events from the user's Google Calendar. Use when the user asks about their schedule, upcoming meetings, or calendar.",
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
      "description": "Creates a new event on the user's Google Calendar. Always confirm details with the user before calling this.",
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
        ] as [String: Any],
        "required": ["summary", "start_iso8601", "end_iso8601"],
      ],
    ],
  ]

  static let tasksFunctionDeclarations: [[String: Any]] = [
    [
      "name": "google_tasks_list",
      "description": "Lists the user's Google Tasks. Use when the user asks about their to-do list, tasks, or things to do.",
      "parameters": [
        "type": "object",
        "properties": [
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
      "description": "Creates a new Google Task. Use when the user asks to add a task, to-do, or reminder.",
      "parameters": [
        "type": "object",
        "properties": [
          "title": [
            "type": "string",
            "description": "Title of the task.",
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
        ] as [String: Any],
        "required": ["task_id"],
      ],
    ],
  ]

  static func allDeclarations(calendarConnected: Bool) -> [[String: Any]] {
    if calendarConnected {
      return functionDeclarations + calendarFunctionDeclarations + tasksFunctionDeclarations
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
      guard GoogleCalendarOAuthService.shared.isConnected else {
        return ["error": "Google Calendar is not connected. Connect it in Settings."]
      }
      let maxResults = args["max_results"] as? Int ?? 10
      let hoursAhead = args["hours_ahead"] as? Int ?? 168
      do {
        let events = try await GoogleCalendarAPIClient.shared.listUpcomingEvents(
          maxResults: maxResults, hoursAhead: hoursAhead)
        return ["events": events, "count": events.count]
      } catch {
        DebugLogger.logError("GEMINI-CHAT-TOOL: calendar list failed: \(error.localizedDescription)")
        return ["error": error.localizedDescription]
      }

    case "google_calendar_create_event":
      guard GoogleCalendarOAuthService.shared.isConnected else {
        return ["error": "Google Calendar is not connected. Connect it in Settings."]
      }
      guard let summary = args["summary"] as? String,
            let startISO = args["start_iso8601"] as? String,
            let endISO = args["end_iso8601"] as? String
      else {
        return ["error": "Missing required arguments: summary, start_iso8601, end_iso8601"]
      }
      let timeZone = args["time_zone"] as? String ?? TimeZone.current.identifier
      do {
        let result = try await GoogleCalendarAPIClient.shared.createEvent(
          summary: summary, startISO: startISO, endISO: endISO, timeZone: timeZone)
        return result
      } catch {
        DebugLogger.logError("GEMINI-CHAT-TOOL: calendar create failed: \(error.localizedDescription)")
        return ["error": error.localizedDescription]
      }

    case "google_tasks_list":
      guard GoogleCalendarOAuthService.shared.isConnected else {
        return ["error": "Google account is not connected. Connect it in Settings."]
      }
      let maxResults = args["max_results"] as? Int ?? 20
      let showCompleted = args["show_completed"] as? Bool ?? false
      do {
        let tasks = try await GoogleTasksAPIClient.shared.listTasks(
          maxResults: maxResults, showCompleted: showCompleted)
        return ["tasks": tasks, "count": tasks.count]
      } catch {
        DebugLogger.logError("GEMINI-CHAT-TOOL: tasks list failed: \(error.localizedDescription)")
        return ["error": error.localizedDescription]
      }

    case "google_tasks_create":
      guard GoogleCalendarOAuthService.shared.isConnected else {
        return ["error": "Google account is not connected. Connect it in Settings."]
      }
      guard let title = args["title"] as? String else {
        return ["error": "Missing required argument: title"]
      }
      let notes = args["notes"] as? String
      let due = args["due"] as? String
      do {
        let result = try await GoogleTasksAPIClient.shared.createTask(
          title: title, notes: notes, due: due)
        return result
      } catch {
        DebugLogger.logError("GEMINI-CHAT-TOOL: tasks create failed: \(error.localizedDescription)")
        return ["error": error.localizedDescription]
      }

    case "google_tasks_complete":
      guard GoogleCalendarOAuthService.shared.isConnected else {
        return ["error": "Google account is not connected. Connect it in Settings."]
      }
      guard let taskId = args["task_id"] as? String else {
        return ["error": "Missing required argument: task_id"]
      }
      do {
        let result = try await GoogleTasksAPIClient.shared.completeTask(taskId: taskId)
        return result
      } catch {
        DebugLogger.logError("GEMINI-CHAT-TOOL: tasks complete failed: \(error.localizedDescription)")
        return ["error": error.localizedDescription]
      }

    default:
      return ["error": "Unknown tool: \(name)"]
    }
  }
}
