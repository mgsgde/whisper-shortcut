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
    [
      "name": "remember_dictation_term",
      "description":
        "Permanently teaches WhisperShortcut's dictation (speech-to-text) the correct spelling of a name, brand, or technical term by adding it to the user's transcription glossary; every future dictation is conditioned with that glossary. Call this whenever the user corrects how a dictated word was transcribed or defines vocabulary for dictation (e.g. 'When I say Grog I mean Grok', 'My name is spelled Gödde, not Göde', 'Learn the term Nebius'). Nothing is saved without this call — never claim dictation will improve unless you called it. For spelling corrections use THIS tool, not remember_about_user (which stores personal facts, not dictation vocabulary).",
      "parameters": [
        "type": "object",
        "properties": [
          "term": [
            "type": "string",
            "description":
              "The correct spelling exactly as it should appear in transcriptions (e.g. 'Grok', 'Magnus Gödde', 'WhisperShortcut').",
          ],
          "misheard_as": [
            "type": "string",
            "description":
              "How dictation currently mis-writes the term, if the user mentioned it (e.g. 'Grog', 'Göde'). Helps the transcription model avoid that specific error.",
          ],
        ] as [String: Any],
        "required": ["term"],
      ],
    ],
  ]

  /// Name of the image-generation tool; ChatView intercepts this one in `executeToolCalls`
  /// (it needs chat-session context — the user's attached images — and routes the resulting
  /// image into the UI instead of back through the model).
  static let generateImageToolName = "generate_image"

  /// Image generation/editing ("Nano Banana"). Declared only when a Gemini credential exists,
  /// since the backend always renders via the Gemini image model — regardless of which
  /// provider's chat model calls the tool.
  static let imageFunctionDeclarations: [[String: Any]] = [
    [
      "name": generateImageToolName,
      "description":
        "Generates a new image, or edits/annotates an image the user attached, using a dedicated image-generation model. Use whenever the user asks to draw, create, render, visualize, edit, or annotate a picture, map, diagram, or illustration. The finished image is automatically displayed in the chat. NEVER attempt to draw with ASCII art or code blocks — call this tool instead.",
      "parameters": [
        "type": "object",
        "properties": [
          "prompt": [
            "type": "string",
            "description":
              "Detailed instruction for the image model, in the user's language. For edits, describe precisely what to change or add (e.g. 'Add a red location pin at the corner of X and Y street on this map'). Include all relevant context from the conversation — the image model sees ONLY this prompt (plus the attached image, if requested).",
          ],
          "use_attached_image": [
            "type": "boolean",
            "description":
              "Set true to edit/annotate the image(s) the user most recently attached in this conversation (screenshot, photo). Omit or set false to generate a fresh image from the prompt alone.",
          ],
        ] as [String: Any],
        "required": ["prompt"],
      ],
    ]
  ]

  /// Names of the meeting-editing tools; ChatView intercepts these in `executeToolCalls`
  /// (they need session context — which meeting tab is open — and write the meeting's
  /// transcript/summary files rather than routing a result back through the model).
  static let refineMeetingSummaryToolName = "refine_meeting_summary"
  static let correctTranscriptTermToolName = "correct_transcript_term"

  /// Meeting-editing tools. Declared only when the current chat is a meeting tab, so regular
  /// chats never see them. Both operate on the meeting this tab is viewing.
  static let meetingFunctionDeclarations: [[String: Any]] = [
    [
      "name": refineMeetingSummaryToolName,
      "description":
        "Refines or rewrites the summary of THIS meeting based on the user's instruction (e.g. 'focus more on decisions', 'add an action items section', 'make it shorter', 'you misunderstood X, fix it'). Regenerates the summary from the full transcript with the instruction applied, saves it, and updates the Summary tab. Use ONLY when the user asks to change, refine, correct, reformat, or regenerate the meeting summary — NOT for answering questions about the meeting.",
      "parameters": [
        "type": "object",
        "properties": [
          "instruction": [
            "type": "string",
            "description":
              "What to change about the summary, in the user's own words (e.g. 'Focus on decisions and add action items', 'Shorten to the 5 most important points', 'You misunderstood the lockup schedule — correct it').",
          ]
        ] as [String: Any],
        "required": ["instruction"],
      ],
    ],
    [
      "name": correctTranscriptTermToolName,
      "description":
        "Corrects a misrecognized word or proper name throughout THIS meeting's transcript by replacing every exact occurrence of one string with another (e.g. transcription wrote 'Park Depot' but it should be 'ParkDepot'). This is a literal find-and-replace on the transcript text — it does NOT rewrite, rephrase, or summarize the transcript, so the record stays faithful. Use only for fixing transcription errors of names, terms, and acronyms. Confirm the exact spelling with the user if unsure.",
      "parameters": [
        "type": "object",
        "properties": [
          "from": [
            "type": "string",
            "description": "The exact text as it currently (wrongly) appears in the transcript.",
          ],
          "to": [
            "type": "string",
            "description": "The corrected text to replace it with.",
          ],
          "regenerate_summary": [
            "type": "boolean",
            "description":
              "Set true to also regenerate the summary afterwards so it uses the corrected term (recommended when the term also appears in the summary). Default false.",
          ],
        ] as [String: Any],
        "required": ["from", "to"],
      ],
    ],
  ]

  /// Names of the chat-memory tools; ChatView intercepts these in `executeToolCalls`
  /// (they write the local memory file and reload the UI rather than routing back through the model).
  static let rememberAboutUserToolName = "remember_about_user"
  static let forgetAboutUserToolName = "forget_about_user"

  /// Persistent user-memory tools. Always available in chat. The model uses these to remember durable
  /// facts about the user across sessions; the memory is injected into every chat system prompt.
  static let memoryFunctionDeclarations: [[String: Any]] = [
    [
      "name": rememberAboutUserToolName,
      "description":
        "Saves a durable fact about the USER to persistent memory so you remember it in future, separate conversations (e.g. their name, role, employer, language preference, recurring projects, or a stable answer-style preference like 'prefers concise answers'). Call this ONLY when the user shares something lasting and worth remembering long-term, or explicitly asks you to remember it. Do NOT store one-off task details, transient context already visible in this conversation, sensitive data the user did not ask you to keep, or things you merely inferred without confidence. Keep each fact to one short, self-contained sentence.",
      "parameters": [
        "type": "object",
        "properties": [
          "fact": [
            "type": "string",
            "description":
              "A single durable fact about the user, phrased as one short standalone sentence (e.g. 'The user is a German-speaking iOS developer.', 'The user prefers concise answers without preamble.').",
          ]
        ] as [String: Any],
        "required": ["fact"],
      ],
    ],
    [
      "name": forgetAboutUserToolName,
      "description":
        "Removes previously remembered facts about the user from persistent memory. Use when the user asks you to forget something, or says a remembered fact is wrong or outdated. Removes every stored fact containing the given text (case-insensitive).",
      "parameters": [
        "type": "object",
        "properties": [
          "matching": [
            "type": "string",
            "description":
              "Text identifying which fact(s) to forget — every stored fact containing this substring is removed (e.g. 'employer', 'concise answers').",
          ]
        ] as [String: Any],
        "required": ["matching"],
      ],
    ],
  ]

  static let calendarFunctionDeclarations: [[String: Any]] = [
    [
      "name": "google_calendar_list_events",
      "description": "Lists calendar events (meetings, appointments) from Google Calendar. By default lists upcoming events starting from now; events that already started or ended are NOT included unless you pass hours_back. Use ONLY for scheduled events with specific start/end times. Do NOT use for tasks or to-dos — use google_tasks_list instead.",
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
          "hours_back": [
            "type": "integer",
            "description": "How many hours into the past to look (default 0). Set this (e.g. 12 or 24) when the user refers to an event earlier today or in the past — for example to delete, rename, or reschedule an event that already started or ended.",
          ],
        ] as [String: Any],
      ],
    ],
    [
      "name": "google_calendar_create_event",
      "description": "Creates a new calendar event (meeting, appointment) on Google Calendar. Supports recurring events (e.g. yearly birthdays, weekly standups) via the recurrence parameter, and all-day events via all_day. Do NOT use for tasks or to-dos — use google_tasks_create instead. Always confirm details with the user before calling this.",
      "parameters": [
        "type": "object",
        "properties": [
          "summary": [
            "type": "string",
            "description": "Title/summary of the event.",
          ],
          "start_iso8601": [
            "type": "string",
            "description": "Start time in ISO 8601 format (e.g. 2026-04-22T15:00:00+02:00). For all-day events, a date like 2026-07-09 is sufficient.",
          ],
          "end_iso8601": [
            "type": "string",
            "description": "End time in ISO 8601 format (e.g. 2026-04-22T15:30:00+02:00). For a single all-day event you may pass the same date as the start; it is treated as a full day.",
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
          "all_day": [
            "type": "boolean",
            "description": "Set true for an all-day event (no specific time), such as a birthday, holiday, or full-day off. Defaults to false.",
          ],
          "recurrence": [
            "type": "array",
            "items": ["type": "string"] as [String: Any],
            "description": "Optional RFC-5545 recurrence rules to make the event repeat. Each entry is an RRULE string. Examples: yearly birthday → [\"RRULE:FREQ=YEARLY\"]; every weekday → [\"RRULE:FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR\"]; weekly for 10 occurrences → [\"RRULE:FREQ=WEEKLY;COUNT=10\"]; monthly until a date → [\"RRULE:FREQ=MONTHLY;UNTIL=20271231T000000Z\"]. Omit for a one-time event.",
          ],
        ] as [String: Any],
        "required": ["summary", "start_iso8601", "end_iso8601"],
      ],
    ],
    [
      "name": "google_calendar_update_event",
      "description": "Updates an existing calendar event IN PLACE by its event_id. PREFER this over deleting and re-creating whenever you need to change the time, title, location, or description of an event that already exists — updating never produces duplicates. Only the fields you pass are changed; omitted fields stay as they are. Use the event_id exactly as returned by a previous list/create call (verbatim) — never base64-encode, shorten, or otherwise transform it.",
      "parameters": [
        "type": "object",
        "properties": [
          "event_id": [
            "type": "string",
            "description": "The exact ID of the event to update, copied verbatim from a previous google_calendar_list_events or google_calendar_create_event result.",
          ],
          "summary": [
            "type": "string",
            "description": "New title/summary (omit to keep unchanged).",
          ],
          "start_iso8601": [
            "type": "string",
            "description": "New start time in ISO 8601 (e.g. 2026-04-22T15:00:00+02:00). Omit to keep unchanged.",
          ],
          "end_iso8601": [
            "type": "string",
            "description": "New end time in ISO 8601 (e.g. 2026-04-22T15:30:00+02:00). Omit to keep unchanged.",
          ],
          "time_zone": [
            "type": "string",
            "description": "IANA time zone identifier (e.g. Europe/Berlin). Defaults to the user's local time zone if omitted.",
          ],
          "location": [
            "type": "string",
            "description": "New location (omit to keep unchanged).",
          ],
          "description": [
            "type": "string",
            "description": "New description/notes (omit to keep unchanged).",
          ],
          "all_day": [
            "type": "boolean",
            "description": "Set true to make this an all-day event (only meaningful when you also pass new start/end). Omit to leave the event's timing type unchanged.",
          ],
          "recurrence": [
            "type": "array",
            "items": ["type": "string"] as [String: Any],
            "description": "RFC-5545 recurrence rules to make the event repeat, e.g. [\"RRULE:FREQ=YEARLY\"] for a yearly birthday or [\"RRULE:FREQ=WEEKLY;BYDAY=MO\"] for every Monday. Pass an empty array to remove recurrence (make it one-time). Omit to leave recurrence unchanged.",
          ],
        ] as [String: Any],
        "required": ["event_id"],
      ],
    ],
    [
      "name": "google_calendar_delete_event",
      "description": "Deletes a calendar event by its event_id (from google_calendar_list_events results). To CHANGE an existing event (time, title, etc.), use google_calendar_update_event instead — do NOT delete and re-create, which leaves duplicates if the delete fails. Use the event_id exactly as returned (verbatim); never base64-encode or otherwise transform it. Always confirm with the user before deleting.",
      "parameters": [
        "type": "object",
        "properties": [
          "event_id": [
            "type": "string",
            "description": "The ID of the event to delete, copied verbatim from a google_calendar_list_events result.",
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

  static func allDeclarations(
    calendarConnected: Bool, trelloConnected: Bool, imageGenerationAvailable: Bool,
    meetingContext: Bool
  ) -> [[String: Any]] {
    var decls = functionDeclarations + appDocsFunctionDeclarations + memoryFunctionDeclarations
    if imageGenerationAvailable {
      decls += imageFunctionDeclarations
    }
    if calendarConnected {
      decls += calendarFunctionDeclarations + tasksFunctionDeclarations + gmailFunctionDeclarations
    }
    if trelloConnected {
      decls += trelloFunctionDeclarations
    }
    if meetingContext {
      decls += meetingFunctionDeclarations
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

  // Internal (not private): ChatView's generate_image interception reuses it for its args.
  static func boolArgument(_ args: [String: Any], _ key: String, default defaultValue: Bool) -> Bool {
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
    "error": "Google is not connected. Open Settings → Chat to connect."
  ]

  private static let trelloNotConnectedError: [String: Any] = [
    "error": "Trello is not connected. Open Settings → Chat to connect."
  ]

  /// Wraps a Google Tasks error with an actionable retry hint. When the failure looks like an
  /// unknown/invalid task list (the model guessed a `task_list_id` instead of listing first), tell
  /// it to call google_tasks_list_tasklists and retry — so it self-corrects in one round instead
  /// of re-guessing (observed: repeated 400/404 rounds on Grok turns).
  private static func tasksErrorWithHint(_ error: Error, taskListId: String) -> String {
    let message = error.localizedDescription
    let lowered = message.lowercased()
    let looksLikeBadList = lowered.contains("not found") || lowered.contains("invalid")
    if looksLikeBadList && taskListId != "@default" {
      return "\(message) The task_list_id '\(taskListId)' may be invalid — call google_tasks_list_tasklists to get valid list IDs, then retry with one of those (or omit task_list_id to use the default list)."
    }
    return message
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

    case "remember_dictation_term":
      guard let rawTerm = args["term"] as? String,
            case let term = rawTerm.trimmingCharacters(in: .whitespacesAndNewlines),
            !term.isEmpty
      else {
        return ["error": "Missing required argument: term"]
      }
      let misheardAs = (args["misheard_as"] as? String)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
      return GlossaryFastLearner.shared.rememberTerm(
        term, misheardAs: (misheardAs?.isEmpty ?? true) ? nil : misheardAs)

    case "google_calendar_list_events":
      guard GoogleAccountOAuthService.shared.isConnected else { return googleNotConnectedError }
      let maxResults = intArgument(args, "max_results", default: 10)
      let hoursAhead = intArgument(args, "hours_ahead", default: 168)
      let hoursBack = intArgument(args, "hours_back", default: 0)
      do {
        let events = try await GoogleCalendarAPIClient.shared.listEvents(
          maxResults: maxResults, hoursAhead: hoursAhead, hoursBack: hoursBack)
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
      let allDay = args["all_day"] as? Bool ?? false
      let recurrence = args["recurrence"] as? [String]
      do {
        let result = try await GoogleCalendarAPIClient.shared.createEvent(
          summary: summary, startISO: startISO, endISO: endISO, timeZone: timeZone,
          location: location, description: description,
          recurrence: recurrence, allDay: allDay)
        DebugLogger.logSuccess("GEMINI-CHAT-TOOL: calendar create ok, id=\(result["event_id"] ?? "?")")
        return result
      } catch {
        DebugLogger.logError("GEMINI-CHAT-TOOL: calendar create failed: \(error.localizedDescription)")
        return ["error": error.localizedDescription]
      }

    case "google_calendar_update_event":
      guard GoogleAccountOAuthService.shared.isConnected else { return googleNotConnectedError }
      guard let eventId = args["event_id"] as? String else {
        return ["error": "Missing required argument: event_id"]
      }
      do {
        let result = try await GoogleCalendarAPIClient.shared.updateEvent(
          eventId: eventId,
          summary: args["summary"] as? String,
          startISO: args["start_iso8601"] as? String,
          endISO: args["end_iso8601"] as? String,
          timeZone: args["time_zone"] as? String,
          location: args["location"] as? String,
          description: args["description"] as? String,
          recurrence: args["recurrence"] as? [String],
          allDay: args["all_day"] as? Bool ?? false)
        DebugLogger.logSuccess("GEMINI-CHAT-TOOL: calendar update ok, id=\(result["event_id"] ?? "?")")
        return result
      } catch {
        DebugLogger.logError("GEMINI-CHAT-TOOL: calendar update failed: \(error.localizedDescription)")
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
        return ["error": tasksErrorWithHint(error, taskListId: taskListId)]
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
