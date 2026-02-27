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

/// Maps a character range in the reply text to grounding chunk indices (1:1 with sources).
struct GroundingSupport: Codable, Equatable {
  let startIndex: Int
  let endIndex: Int
  let groundingChunkIndices: [Int]
}

struct ChatMessage: Identifiable, Codable, Equatable {
  let id: UUID
  let role: ChatRole
  let content: String
  let timestamp: Date
  var sources: [GroundingSource]
  var groundingSupports: [GroundingSupport]
  /// PNG (or other) image data attached to this user message (e.g. screenshot). Stored as Base64 in session file.
  var attachedImageData: Data?

  enum CodingKeys: String, CodingKey {
    case id, role, content, timestamp, sources, groundingSupports, attachedImageData
  }

  init(
    id: UUID = UUID(),
    role: ChatRole,
    content: String,
    timestamp: Date = Date(),
    sources: [GroundingSource] = [],
    groundingSupports: [GroundingSupport] = [],
    attachedImageData: Data? = nil
  ) {
    self.id = id
    self.role = role
    self.content = content
    self.timestamp = timestamp
    self.sources = sources
    self.groundingSupports = groundingSupports
    self.attachedImageData = attachedImageData
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(UUID.self, forKey: .id)
    role = try c.decode(ChatRole.self, forKey: .role)
    content = try c.decode(String.self, forKey: .content)
    timestamp = try c.decode(Date.self, forKey: .timestamp)
    sources = try c.decode([GroundingSource].self, forKey: .sources)
    groundingSupports = try c.decodeIfPresent([GroundingSupport].self, forKey: .groundingSupports) ?? []
    if let base64 = try c.decodeIfPresent(String.self, forKey: .attachedImageData), let data = Data(base64Encoded: base64) {
      attachedImageData = data
    } else {
      attachedImageData = nil
    }
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(id, forKey: .id)
    try c.encode(role, forKey: .role)
    try c.encode(content, forKey: .content)
    try c.encode(timestamp, forKey: .timestamp)
    try c.encode(sources, forKey: .sources)
    try c.encode(groundingSupports, forKey: .groundingSupports)
    if let data = attachedImageData {
      try c.encode(data.base64EncodedString(), forKey: .attachedImageData)
    }
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
  /// Back/forward navigation stacks. Back: oldest→newest (pop last to go back).
  /// Forward: oldest→newest (pop last to go forward).
  var navBackStack: [UUID]
  var navForwardStack: [UUID]

  private enum CodingKeys: String, CodingKey {
    case currentSessionId, sessions, navBackStack, navForwardStack
    // Legacy key — only decoded, never encoded (migration).
    case previousSessionIdForBack
  }

  init(currentSessionId: UUID, sessions: [ChatSession], navBackStack: [UUID] = [], navForwardStack: [UUID] = []) {
    self.currentSessionId = currentSessionId
    self.sessions = sessions
    self.navBackStack = navBackStack
    self.navForwardStack = navForwardStack
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    currentSessionId = try c.decode(UUID.self, forKey: .currentSessionId)
    sessions = try c.decode([ChatSession].self, forKey: .sessions)
    if let stack = try c.decodeIfPresent([UUID].self, forKey: .navBackStack) {
      navBackStack = stack
    } else if let legacyId = try c.decodeIfPresent(UUID.self, forKey: .previousSessionIdForBack) {
      navBackStack = [legacyId]
    } else {
      navBackStack = []
    }
    navForwardStack = try c.decodeIfPresent([UUID].self, forKey: .navForwardStack) ?? []
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(currentSessionId, forKey: .currentSessionId)
    try c.encode(sessions, forKey: .sessions)
    try c.encode(navBackStack, forKey: .navBackStack)
    try c.encode(navForwardStack, forKey: .navForwardStack)
    // previousSessionIdForBack intentionally omitted — legacy field replaced by stacks.
  }
}

// MARK: - Store

class GeminiChatSessionStore {
  static let shared = GeminiChatSessionStore()

  private let fileName = "gemini-sessions.json"
  private let legacyFileName = "gemini-chat-session.json"
  private static let navStackLimit = 20

  private var cachedFile: SessionsFile?
  private let diskWriteQueue = DispatchQueue(label: "com.whispershortcut.session.io", qos: .utility)

  private init() {}

  private var fileURL: URL {
    AppSupportPaths.whisperShortcutApplicationSupportURL().appendingPathComponent(fileName)
  }
  private var legacyFileURL: URL {
    AppSupportPaths.whisperShortcutApplicationSupportURL().appendingPathComponent(legacyFileName)
  }
  private var appSupportDir: URL {
    AppSupportPaths.whisperShortcutApplicationSupportURL()
  }

  // MARK: - Private file access

  private func loadFile() -> SessionsFile {
    if let cached = cachedFile { return cached }

    // Migrate from legacy single-session file
    if FileManager.default.fileExists(atPath: legacyFileURL.path),
       let data = try? Data(contentsOf: legacyFileURL),
       let legacy = try? JSONDecoder().decode(ChatSession.self, from: data) {
      let file = SessionsFile(currentSessionId: legacy.id, sessions: [legacy])
      saveSessionsFile(file)
      try? FileManager.default.removeItem(at: legacyFileURL)
      return file
    }

    if let data = try? Data(contentsOf: fileURL),
       let file = try? JSONDecoder().decode(SessionsFile.self, from: data),
       !file.sessions.isEmpty {
      cachedFile = file
      return file
    }

    let defaultSession = ChatSession()
    let file = SessionsFile(currentSessionId: defaultSession.id, sessions: [defaultSession])
    saveSessionsFile(file)
    return file
  }

  private func saveSessionsFile(_ file: SessionsFile) {
    cachedFile = file
    let url = fileURL
    let dir = appSupportDir
    diskWriteQueue.async {
      try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      if let data = try? JSONEncoder().encode(file) {
        try? data.write(to: url, options: .atomic)
      }
    }
  }

  // MARK: - Load / Save

  func load() -> ChatSession {
    let file = loadFile()
    return file.sessions.first(where: { $0.id == file.currentSessionId })
      ?? file.sessions.first ?? ChatSession()
  }

  func save(_ session: ChatSession) {
    var file = loadFile()
    if let idx = file.sessions.firstIndex(where: { $0.id == session.id }) {
      file.sessions[idx] = session
    } else {
      file.sessions.append(session)
    }
    saveSessionsFile(file)
  }

  // MARK: - Navigation

  func canGoBack() -> Bool { !loadFile().navBackStack.isEmpty }
  func canGoForward() -> Bool { !loadFile().navForwardStack.isEmpty }

  /// Navigates back. Updates stacks and currentSessionId; returns the new current session ID, or nil if at the start.
  func navigateBack() -> UUID? {
    var file = loadFile()
    guard !file.navBackStack.isEmpty else { return nil }
    let targetId = file.navBackStack.removeLast()
    file.navForwardStack.append(file.currentSessionId)
    if file.navForwardStack.count > Self.navStackLimit { file.navForwardStack.removeFirst() }
    file.currentSessionId = targetId
    saveSessionsFile(file)
    return targetId
  }

  /// Navigates forward. Updates stacks and currentSessionId; returns the new current session ID, or nil if at the end.
  func navigateForward() -> UUID? {
    var file = loadFile()
    guard !file.navForwardStack.isEmpty else { return nil }
    let targetId = file.navForwardStack.removeLast()
    file.navBackStack.append(file.currentSessionId)
    if file.navBackStack.count > Self.navStackLimit { file.navBackStack.removeFirst() }
    file.currentSessionId = targetId
    saveSessionsFile(file)
    return targetId
  }

  // MARK: - Multi-Session Helpers

  func session(by id: UUID) -> ChatSession? {
    loadFile().sessions.first { $0.id == id }
  }

  /// Sessions ordered by lastUpdated descending (most recent first).
  func recentSessions(limit: Int = 50) -> [ChatSession] {
    Array(loadFile().sessions.sorted { $0.lastUpdated > $1.lastUpdated }.prefix(limit))
  }

  /// Switches to an existing session via tab click, pushing current to back stack and clearing forward stack.
  func switchToSession(id: UUID) {
    var file = loadFile()
    guard file.sessions.contains(where: { $0.id == id }), id != file.currentSessionId else { return }
    file.navBackStack.append(file.currentSessionId)
    if file.navBackStack.count > Self.navStackLimit { file.navBackStack.removeFirst() }
    file.navForwardStack = []
    file.currentSessionId = id
    saveSessionsFile(file)
  }

  /// Creates a new empty session, pushes current to back stack, clears forward stack, sets as current.
  func createNewSession() -> ChatSession {
    let newSession = ChatSession()
    var file = loadFile()
    file.navBackStack.append(file.currentSessionId)
    if file.navBackStack.count > Self.navStackLimit { file.navBackStack.removeFirst() }
    file.navForwardStack = []
    file.sessions.insert(newSession, at: 0)
    file.currentSessionId = newSession.id
    saveSessionsFile(file)
    DebugLogger.log("GEMINI-CHAT: New session created \(newSession.id)")
    return newSession
  }
}
