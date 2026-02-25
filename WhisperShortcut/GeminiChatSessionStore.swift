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
    let (currentId, sessions) = loadSessionsFile()
    guard let session = sessions.first(where: { $0.id == currentId }) else {
      return sessions.first ?? ChatSession()
    }
    return session
  }

  /// Returns (currentSessionId, sessions sorted by lastUpdated desc).
  private func loadSessionsFile() -> (currentSessionId: UUID, sessions: [ChatSession]) {
    // Migrate from legacy single-session file if present
    if FileManager.default.fileExists(atPath: legacyFileURL.path) {
      if let data = try? Data(contentsOf: legacyFileURL),
         let legacy = try? JSONDecoder().decode(ChatSession.self, from: data) {
        let file = SessionsFile(currentSessionId: legacy.id, sessions: [legacy])
        try? saveSessionsFile(file)
        try? FileManager.default.removeItem(at: legacyFileURL)
        return (legacy.id, [legacy])
      }
    }

    guard let data = try? Data(contentsOf: fileURL),
          let file = try? JSONDecoder().decode(SessionsFile.self, from: data),
          !file.sessions.isEmpty
    else {
      let defaultSession = ChatSession()
      let file = SessionsFile(currentSessionId: defaultSession.id, sessions: [defaultSession])
      try? saveSessionsFile(file)
      return (defaultSession.id, [defaultSession])
    }

    let sorted = file.sessions.sorted { $0.lastUpdated > $1.lastUpdated }
    return (file.currentSessionId, sorted)
  }

  // MARK: - Save

  func save(_ session: ChatSession) {
    var (currentId, sessions) = loadSessionsFile()
    if let idx = sessions.firstIndex(where: { $0.id == session.id }) {
      sessions[idx] = session
    } else {
      sessions.append(session)
      sessions.sort { $0.lastUpdated > $1.lastUpdated }
    }
    let file = SessionsFile(currentSessionId: currentId, sessions: sessions)
    try? saveSessionsFile(file)
  }

  private func saveSessionsFile(_ file: SessionsFile) throws {
    try FileManager.default.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
    let data = try JSONEncoder().encode(file)
    try data.write(to: fileURL, options: .atomic)
  }

  // MARK: - Multi-Session Helpers

  func session(by id: UUID) -> ChatSession? {
    let (_, sessions) = loadSessionsFile()
    return sessions.first { $0.id == id }
  }

  /// Sessions ordered by lastUpdated descending (most recent first).
  func recentSessions(limit: Int = 50) -> [ChatSession] {
    let (_, sessions) = loadSessionsFile()
    return Array(sessions.prefix(limit))
  }

  /// Id of the session to switch to for "previous" (most recently updated, excluding current).
  func previousSessionId(current: UUID) -> UUID? {
    let sessions = recentSessions(limit: 10)
    return sessions.first { $0.id != current }?.id
  }

  func setCurrentSession(id: UUID) {
    let (_, sessions) = loadSessionsFile()
    guard sessions.contains(where: { $0.id == id }) else { return }
    let file = SessionsFile(currentSessionId: id, sessions: sessions)
    try? saveSessionsFile(file)
  }

  /// Creates a new empty session, adds it to the store, and sets it as current. Returns the new session.
  func createNewSession() -> ChatSession {
    let newSession = ChatSession()
    var (_, sessions) = loadSessionsFile()
    sessions.insert(newSession, at: 0)
    let file = SessionsFile(currentSessionId: newSession.id, sessions: sessions)
    try? saveSessionsFile(file)
    DebugLogger.log("GEMINI-CHAT: New session created \(newSession.id)")
    return newSession
  }
}
