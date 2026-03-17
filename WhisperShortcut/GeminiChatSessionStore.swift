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

/// One image or file attachment (screenshot or picked file). Stored as Base64 in session file.
struct AttachedImagePart: Codable, Equatable {
  var data: Data
  var mimeType: String?
  var filename: String?

  enum CodingKeys: String, CodingKey {
    case dataBase64, mimeType, filename
  }

  init(data: Data, mimeType: String? = nil, filename: String? = nil) {
    self.data = data
    self.mimeType = mimeType
    self.filename = filename
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let base64 = try c.decode(String.self, forKey: .dataBase64)
    guard let data = Data(base64Encoded: base64) else {
      throw DecodingError.dataCorruptedError(forKey: .dataBase64, in: c, debugDescription: "Invalid base64")
    }
    self.data = data
    self.mimeType = try c.decodeIfPresent(String.self, forKey: .mimeType)
    self.filename = try c.decodeIfPresent(String.self, forKey: .filename)
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(data.base64EncodedString(), forKey: .dataBase64)
    try c.encodeIfPresent(mimeType, forKey: .mimeType)
    try c.encodeIfPresent(filename, forKey: .filename)
  }
}

struct ChatMessage: Identifiable, Codable, Equatable {
  let id: UUID
  let role: ChatRole
  let content: String
  let timestamp: Date
  var sources: [GroundingSource]
  var groundingSupports: [GroundingSupport]
  /// Image/file parts attached to this user message. Encoded as array; legacy single image decoded from attachedImageData/attachedFileMimeType/attachedFilename.
  var attachedImageParts: [AttachedImagePart]
  /// True once this message has been distilled into `ChatSession.sessionMemory`.
  var includedInMemory: Bool

  enum CodingKeys: String, CodingKey {
    case id, role, content, timestamp, sources, groundingSupports
    case attachedImageParts
    case includedInMemory
    case attachedImageData, attachedFileMimeType, attachedFilename // legacy, decode only
  }

  init(
    id: UUID = UUID(),
    role: ChatRole,
    content: String,
    timestamp: Date = Date(),
    sources: [GroundingSource] = [],
    groundingSupports: [GroundingSupport] = [],
    attachedImageParts: [AttachedImagePart] = [],
    includedInMemory: Bool = false
  ) {
    self.id = id
    self.role = role
    self.content = content
    self.timestamp = timestamp
    self.sources = sources
    self.groundingSupports = groundingSupports
    self.attachedImageParts = attachedImageParts
    self.includedInMemory = includedInMemory
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(UUID.self, forKey: .id)
    role = try c.decode(ChatRole.self, forKey: .role)
    content = try c.decode(String.self, forKey: .content)
    timestamp = try c.decode(Date.self, forKey: .timestamp)
    sources = try c.decode([GroundingSource].self, forKey: .sources)
    groundingSupports = try c.decodeIfPresent([GroundingSupport].self, forKey: .groundingSupports) ?? []
    if let parts = try c.decodeIfPresent([AttachedImagePart].self, forKey: .attachedImageParts) {
      attachedImageParts = parts
    } else if let base64 = try c.decodeIfPresent(String.self, forKey: .attachedImageData), let data = Data(base64Encoded: base64) {
      let mime = try c.decodeIfPresent(String.self, forKey: .attachedFileMimeType)
      let filename = try c.decodeIfPresent(String.self, forKey: .attachedFilename)
      attachedImageParts = [AttachedImagePart(data: data, mimeType: mime, filename: filename)]
    } else {
      attachedImageParts = []
    }
    includedInMemory = try c.decodeIfPresent(Bool.self, forKey: .includedInMemory) ?? false
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(id, forKey: .id)
    try c.encode(role, forKey: .role)
    try c.encode(content, forKey: .content)
    try c.encode(timestamp, forKey: .timestamp)
    try c.encode(sources, forKey: .sources)
    try c.encode(groundingSupports, forKey: .groundingSupports)
    try c.encode(attachedImageParts, forKey: .attachedImageParts)
    try c.encode(includedInMemory, forKey: .includedInMemory)
  }
}

struct ChatSession: Codable {
  var id: UUID
  var lastUpdated: Date
  var messages: [ChatMessage]
  var title: String?
  /// Compact rolling summary of distilled facts from this session. Injected into every system instruction.
  var sessionMemory: String?

  init(id: UUID = UUID(), lastUpdated: Date = Date(), messages: [ChatMessage] = [], title: String? = nil, sessionMemory: String? = nil) {
    self.id = id
    self.lastUpdated = lastUpdated
    self.messages = messages
    self.title = title
    self.sessionMemory = sessionMemory
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

  private let fileName: String
  private let legacyFileName = "gemini-chat-session.json"
  private let scope: String?
  private static let navStackLimit = 20
  /// Maximum number of sessions kept on disk. Oldest sessions (by lastUpdated) are pruned when exceeded.
  private static let maxSessionCount = 100
  /// Sessions older than this many days have their attached image binaries stripped from the in-memory
  /// cache to avoid holding screenshots for stale conversations indefinitely.
  private static let imageRetentionDays: Double = 7

  private var cachedFile: SessionsFile?
  private let diskWriteQueue = DispatchQueue(label: "com.whispershortcut.session.io", qos: .utility)

  init(scope: String? = nil) {
    self.scope = scope
    if let scope = scope {
      self.fileName = "gemini-sessions-\(scope).json"
    } else {
      self.fileName = "gemini-sessions.json"
    }
  }

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

    // Migrate from legacy single-session file (only for default/unscoped store)
    if scope == nil,
       FileManager.default.fileExists(atPath: legacyFileURL.path),
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
    var file = file

    // Prune oldest sessions when the cap is exceeded, keeping the current session safe.
    if file.sessions.count > Self.maxSessionCount {
      let sorted = file.sessions.sorted { $0.lastUpdated > $1.lastUpdated }
      let kept = Set(sorted.prefix(Self.maxSessionCount).map { $0.id })
      let removed = file.sessions.filter { !kept.contains($0.id) }.map { $0.id }
      file.sessions.removeAll { !kept.contains($0.id) }
      file.navBackStack.removeAll { removed.contains($0) }
      file.navForwardStack.removeAll { removed.contains($0) }
      DebugLogger.log("GEMINI-CHAT: Pruned \(removed.count) old session(s) to stay within \(Self.maxSessionCount) limit")
    }

    // Strip image binaries from sessions older than imageRetentionDays before caching in memory.
    // The current session always keeps its images for display.
    let cutoff = Date().addingTimeInterval(-Self.imageRetentionDays * 86400)
    file.sessions = file.sessions.map { session in
      guard session.id != file.currentSessionId, session.lastUpdated < cutoff else { return session }
      var stripped = session
      stripped.messages = session.messages.map { msg in
        guard !msg.attachedImageParts.isEmpty else { return msg }
        var m = msg
        m.attachedImageParts = []
        return m
      }
      return stripped
    }

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

  /// Deletes the session with the given ID. Removes it from nav stacks. If it was current, switches to
  /// the most-recently-updated remaining session (or creates a new empty one if none remain).
  func deleteSession(id: UUID) {
    var file = loadFile()
    file.sessions.removeAll { $0.id == id }
    file.navBackStack.removeAll { $0 == id }
    file.navForwardStack.removeAll { $0 == id }
    if file.currentSessionId == id {
      let next = file.sessions.sorted { $0.lastUpdated > $1.lastUpdated }.first
      if let next = next {
        file.currentSessionId = next.id
      } else {
        let newSession = ChatSession()
        file.sessions = [newSession]
        file.currentSessionId = newSession.id
      }
    }
    saveSessionsFile(file)
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
