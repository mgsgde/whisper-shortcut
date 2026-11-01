import AppKit
import Foundation

/// A single hit from searching chats and meeting transcripts.
struct ChatSearchResult: Identifiable {
  enum Kind { case chat, meeting }
  let id: UUID
  let kind: Kind
  /// Session to open on tap. Nil for an orphan meeting transcript whose session was pruned.
  let sessionId: UUID?
  /// Transcript file, used to reveal an orphan meeting in Finder.
  let meetingURL: URL?
  let title: String
  let snippet: String
  let date: Date
  let score: Int
  var isMeeting: Bool { kind == .meeting }
}

/// Searching chats and meeting transcripts.
///
/// Lifted out of `ChatViewModel` as the first slice of R3. It earns its own type rather than an
/// extension because it turned out to need nothing from the view model except the session store —
/// no streaming state, no current session, no publishing. That also makes it the first part of the
/// chat surface that can be tested without standing up a view model.
enum ChatSearch {

  private static let maxResults = 50
  /// Per-session haystack reused while `lastUpdated` is unchanged.
  @MainActor
  private static var haystackCache: [UUID: (updated: Date, haystack: String, parts: [String])] = [:]

  /// Searches every chat session (title + message text) and meeting transcript (.txt content),
  /// returning results ranked by relevance (term-occurrence score) then recency. Multi-word
  /// queries use AND semantics. A blank query returns an empty list.
  /// `@MainActor` because the session store and `displayTitle` are — this ran on the main actor
  /// inside the view model too. The pure `score` / `snippet` helpers below stay nonisolated so the
  /// ranking rules can be tested without a main-actor hop.
  @MainActor
  static func run(_ rawQuery: String, store: ChatSessionStore) -> [ChatSearchResult] {
    let terms = rawQuery.lowercased()
      .split(whereSeparator: { $0.isWhitespace })
      .map(String.init)
    guard !terms.isEmpty else { return [] }

    let meetingService = MeetingListService.shared
    meetingService.refresh()
    let meetingsByStem = Dictionary(
      meetingService.meetings.map { ($0.meetingId, $0) },
      uniquingKeysWith: { first, _ in first })

    var results: [ChatSearchResult] = []
    var coveredStems = Set<String>()
    let sessions = store.allSessions()

    for session in sessions {
      let title = ChatViewModel.displayTitle(for: session)
      let cached = haystackCache[session.id]
      let parts: [String]
      let haystack: String
      if let cached, cached.updated == session.lastUpdated {
        parts = cached.parts
        haystack = cached.haystack
      } else {
        var built: [String] = []
        if let t = session.title { built.append(t) }
        // Index the visible text. The raw wrappers (`<typed_by_user>`, `<pasted_content>`)
        // made "user", "typed", "pasted", and "content" match every chat.
        built.append(contentsOf: session.messages.map { searchableText(of: $0.content) })
        if session.isMeeting, let stem = session.meetingStem, let meeting = meetingsByStem[stem] {
          built.append(meetingService.chunks(for: meeting).map { $0.text }.joined(separator: "\n"))
        }
        parts = built
        haystack = parts.joined(separator: "\n").lowercased()
        haystackCache[session.id] = (updated: session.lastUpdated, haystack: haystack, parts: parts)
      }

      var meetingURL: URL? = nil
      if session.isMeeting, let stem = session.meetingStem, let meeting = meetingsByStem[stem] {
        coveredStems.insert(stem)
        meetingURL = meeting.url
      }

      guard terms.allSatisfy({ haystack.contains($0) }) else { continue }

      results.append(ChatSearchResult(
        id: session.id,
        kind: session.isMeeting ? .meeting : .chat,
        sessionId: session.id,
        meetingURL: meetingURL,
        title: title,
        snippet: snippet(from: parts, terms: terms, fallback: title),
        date: session.lastUpdated,
        score: score(haystack: haystack, title: title.lowercased(), terms: terms)))
    }

    let liveIds = Set(sessions.map(\.id))
    haystackCache = haystackCache.filter { liveIds.contains($0.key) }

    // Orphan transcripts: file exists but its session was pruned from the 50-session cap.
    for meeting in meetingService.meetings where !coveredStems.contains(meeting.meetingId) {
      let transcript = meetingService.chunks(for: meeting).map { $0.text }.joined(separator: "\n")
      let haystack = (meeting.displayLabel + "\n" + transcript).lowercased()
      guard terms.allSatisfy({ haystack.contains($0) }) else { continue }
      results.append(ChatSearchResult(
        id: UUID(),
        kind: .meeting,
        sessionId: nil,
        meetingURL: meeting.url,
        title: meeting.displayLabel,
        snippet: snippet(from: [transcript], terms: terms, fallback: meeting.displayLabel),
        date: meeting.date,
        score: score(haystack: haystack, title: meeting.displayLabel.lowercased(), terms: terms)))
    }

    results.sort { $0.score != $1.score ? $0.score > $1.score : $0.date > $1.date }
    return Array(results.prefix(maxResults))
  }

  /// Text that should be matched and shown in snippets.
  ///
  /// User messages are stored with the wrappers `parseUserMessagePastedXML` strips for display
  /// (`<typed_by_user>`, `<pasted_content>`, `<pasted_selection>`, `<quoted_from_meeting>`).
  /// The tags themselves are not part of what the user wrote, so they are removed before
  /// indexing. The parser only keeps leading paste blocks plus one trailing typed block;
  /// deleting the tags keeps a typed block that sits before a paste searchable as well.
  static func searchableText(of content: String) -> String {
    var text = GeminiAPIClient.stripImageMarkers(content)
    let parsed = parseUserMessagePastedXML(text)
    var pieces = parsed.sections.map(\.body)
    if !parsed.userText.isEmpty { pieces.append(parsed.userText) }
    let fromParser = pieces.joined(separator: "\n")
    let wrappers = [
      "<typed_by_user>", "</typed_by_user>",
      "<pasted_content>", "</pasted_content>",
      "<pasted_selection>", "</pasted_selection>",
      "<quoted_from_meeting>", "</quoted_from_meeting>",
    ]
    for tag in wrappers {
      text = text.replacingOccurrences(of: tag, with: "\n")
    }
    let parserTrimmed = fromParser.trimmingCharacters(in: .whitespacesAndNewlines)
    let strippedTrimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    // The parser drops a typed block that precedes a paste, and leaves wrappers it does not
    // know (`<quoted_from_meeting>`) in `userText`. Tag-stripping keeps those words and still
    // removes the tags. When the parser already returned just the visible text, use that.
    let parserKeptTags = wrappers.contains { fromParser.contains($0) }
    if parserKeptTags || strippedTrimmed.count > parserTrimmed.count { return text }
    return fromParser.isEmpty ? text : fromParser
  }

  /// Relevance score: total term occurrences across the (lowercased) haystack, plus a bonus
  /// for each term that also appears in the (lowercased) title.
  static func score(haystack: String, title: String, terms: [String]) -> Int {
    var score = 0
    for term in terms {
      var idx = haystack.startIndex
      while let r = haystack.range(of: term, range: idx..<haystack.endIndex) {
        score += 1
        idx = r.upperBound
      }
      if title.contains(term) { score += 5 }
    }
    return score
  }

  /// Builds a one-line snippet centered on the first matching term, with ellipses for elided context.
  static func snippet(from parts: [String], terms: [String], fallback: String) -> String {
    let flat = parts.joined(separator: " • ")
      .replacingOccurrences(of: "\n", with: " ")
      .replacingOccurrences(of: "\r", with: " ")
    var hit: Range<String.Index>? = nil
    for term in terms {
      if let r = flat.range(of: term, options: .caseInsensitive),
         hit == nil || r.lowerBound < hit!.lowerBound {
        hit = r
      }
    }
    guard let match = hit else {
      return String(fallback.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
    }
    let start = flat.index(match.lowerBound, offsetBy: -40, limitedBy: flat.startIndex) ?? flat.startIndex
    let end = flat.index(match.lowerBound, offsetBy: 80, limitedBy: flat.endIndex) ?? flat.endIndex
    var s = String(flat[start..<end]).trimmingCharacters(in: .whitespaces)
    if start != flat.startIndex { s = "…" + s }
    if end != flat.endIndex { s += "…" }
    return s
  }
}
