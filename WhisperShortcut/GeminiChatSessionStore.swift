import Foundation

// MARK: - Chat Models

enum ChatRole: String, Codable {
  case user
  case model
}

struct GroundingSource: Codable, Equatable, Identifiable {
  var id: String { uri }
  let uri: String
  let title: String
}

struct ChatMessage: Identifiable, Codable, Equatable {
  let id: UUID
  let role: ChatRole
  let content: String
  let timestamp: Date
  var sources: [GroundingSource]

  init(
    id: UUID = UUID(),
    role: ChatRole,
    content: String,
    timestamp: Date = Date(),
    sources: [GroundingSource] = []
  ) {
    self.id = id
    self.role = role
    self.content = content
    self.timestamp = timestamp
    self.sources = sources
  }
}

struct ChatSession: Codable {
  var id: UUID
  var lastUpdated: Date
  var messages: [ChatMessage]
  var title: String?

  init(id: UUID = UUID(), lastUpdated: Date = Date(), messages: [ChatMessage] = [], title: String? = nil) {
    self.id = id
    self.lastUpdated = lastUpdated
    self.messages = messages
    self.title = title
  }
}

// MARK: - Multi-Session File Format

private struct SessionsFile: Codable {
  var currentSessionId: UUID
  var sessions: [ChatSession]
  /// Session to return to when user triggers /back (set when creating a new chat).
  var previousSessionIdForBack: UUID?
}

// MARK: - Store

class GeminiChatSessionStore {
  static let shared = GeminiChatSessionStore()

  private let fileName = "gemini-sessions.json"
  private let legacyFileName = "gemini-chat-session.json"

  private init() {}

  private var fileURL: URL {
    AppSupportPaths.whisperShortcutApplicationSupportURL()
      .appendingPathComponent(fileName)
  }

  private var legacyFileURL: URL {
    AppSupportPaths.whisperShortcutApplicationSupportURL()
      .appendingPathComponent(legacyFileName)
  }

  private var appSupportDir: URL {
    AppSupportPaths.whisperShortcutApplicationSupportURL()
  }

  // MARK: - Load

  func load() -> ChatSession {
    let (currentId, sessions, _) = loadSessionsFile()
    guard let session = sessions.first(where: { $0.id == currentId }) else {
      return sessions.first ?? ChatSession()
    }
    return session
  }

  /// Returns (currentSessionId, sessions sorted by lastUpdated desc, previousSessionIdForBack).
  private func loadSessionsFile() -> (currentSessionId: UUID, sessions: [ChatSession], previousSessionIdForBack: UUID?) {
    // Migrate from legacy single-session file if present
    if FileManager.default.fileExists(atPath: legacyFileURL.path) {
      if let data = try? Data(contentsOf: legacyFileURL),
         let legacy = try? JSONDecoder().decode(ChatSession.self, from: data) {
        let file = SessionsFile(currentSessionId: legacy.id, sessions: [legacy], previousSessionIdForBack: nil)
        try? saveSessionsFile(file)
        try? FileManager.default.removeItem(at: legacyFileURL)
        return (legacy.id, [legacy], nil)
      }
    }

    guard let data = try? Data(contentsOf: fileURL),
          let file = try? JSONDecoder().decode(SessionsFile.self, from: data),
          !file.sessions.isEmpty
    else {
      let defaultSession = ChatSession()
      let file = SessionsFile(currentSessionId: defaultSession.id, sessions: [defaultSession], previousSessionIdForBack: nil)
      try? saveSessionsFile(file)
      return (defaultSession.id, [defaultSession], nil)
    }

    let sorted = file.sessions.sorted { $0.lastUpdated > $1.lastUpdated }
    return (file.currentSessionId, sorted, file.previousSessionIdForBack)
  }

  // MARK: - Save

  func save(_ session: ChatSession) {
    var (currentId, sessions, backId) = loadSessionsFile()
    if let idx = sessions.firstIndex(where: { $0.id == session.id }) {
      sessions[idx] = session
    } else {
      sessions.append(session)
      sessions.sort { $0.lastUpdated > $1.lastUpdated }
    }
    let file = SessionsFile(currentSessionId: currentId, sessions: sessions, previousSessionIdForBack: backId)
    try? saveSessionsFile(file)
  }

  private func saveSessionsFile(_ file: SessionsFile) throws {
    try FileManager.default.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
    let data = try JSONEncoder().encode(file)
    try data.write(to: fileURL, options: .atomic)
  }

  // MARK: - Multi-Session Helpers

  func session(by id: UUID) -> ChatSession? {
    let (_, sessions, _) = loadSessionsFile()
    return sessions.first { $0.id == id }
  }

  /// Sessions ordered by lastUpdated descending (most recent first).
  func recentSessions(limit: Int = 50) -> [ChatSession] {
    let (_, sessions, _) = loadSessionsFile()
    return Array(sessions.prefix(limit))
  }

  /// Id stored when user created a new chat; use for /back to return to the chat they left.
  func idForBack() -> UUID? {
    let (_, _, backId) = loadSessionsFile()
    return backId
  }

  /// Id of the session to switch to for "previous" (fallback: most recently updated, excluding current).
  func previousSessionId(current: UUID) -> UUID? {
    let sessions = recentSessions(limit: 10)
    return sessions.first { $0.id != current }?.id
  }

  /// - Parameter clearBack: when true (e.g. after /back), clear the stored "back" target.
  func setCurrentSession(id: UUID, clearBack: Bool = false) {
    var (_, sessions, backId) = loadSessionsFile()
    guard sessions.contains(where: { $0.id == id }) else { return }
    if clearBack { backId = nil }
    let file = SessionsFile(currentSessionId: id, sessions: sessions, previousSessionIdForBack: backId)
    try? saveSessionsFile(file)
  }

  /// Creates a new empty session, adds it to the store, and sets it as current. Stores current session id as "back" target.
  func createNewSession() -> ChatSession {
    let newSession = ChatSession()
    var (currentId, sessions, _) = loadSessionsFile()
    sessions.insert(newSession, at: 0)
    let file = SessionsFile(currentSessionId: newSession.id, sessions: sessions, previousSessionIdForBack: currentId)
    try? saveSessionsFile(file)
    DebugLogger.log("GEMINI-CHAT: New session created \(newSession.id), back target \(currentId)")
    return newSession
  }
}
