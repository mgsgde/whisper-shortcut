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
  var content: String
  let timestamp: Date
  var sources: [GroundingSource]
  var groundingSupports: [GroundingSupport]
  /// Image/file parts attached to this user message. Encoded as array; legacy single image decoded from attachedImageData/attachedFileMimeType/attachedFilename.
  var attachedImageParts: [AttachedImagePart]

  enum CodingKeys: String, CodingKey {
    case id, role, content, timestamp, sources, groundingSupports
    case attachedImageParts
    case attachedImageData, attachedFileMimeType, attachedFilename // legacy, decode only
  }

  init(
    id: UUID = UUID(),
    role: ChatRole,
    content: String,
    timestamp: Date = Date(),
    sources: [GroundingSource] = [],
    groundingSupports: [GroundingSupport] = [],
    attachedImageParts: [AttachedImagePart] = []
  ) {
    self.id = id
    self.role = role
    self.content = content
    self.timestamp = timestamp
    self.sources = sources
    self.groundingSupports = groundingSupports
    self.attachedImageParts = attachedImageParts
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
  }
}

struct ChatSession: Codable {
  var id: UUID
  var lastUpdated: Date
  var messages: [ChatMessage]
  var title: String?
  var archived: Bool
  var pinned: Bool
  var isMeeting: Bool

  init(id: UUID = UUID(), lastUpdated: Date = Date(), messages: [ChatMessage] = [], title: String? = nil, archived: Bool = false, pinned: Bool = false, isMeeting: Bool = false) {
    self.id = id
    self.lastUpdated = lastUpdated
    self.messages = messages
    self.title = title
    self.archived = archived
    self.pinned = pinned
    self.isMeeting = isMeeting
  }

  private enum CodingKeys: String, CodingKey {
    case id, lastUpdated, messages, title, archived, pinned, isMeeting
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(UUID.self, forKey: .id)
    lastUpdated = try c.decode(Date.self, forKey: .lastUpdated)
    messages = try c.decode([ChatMessage].self, forKey: .messages)
    title = try c.decodeIfPresent(String.self, forKey: .title)
    archived = try c.decodeIfPresent(Bool.self, forKey: .archived) ?? false
    pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
    isMeeting = try c.decodeIfPresent(Bool.self, forKey: .isMeeting) ?? false
  }
}

// MARK: - Multi-Session File Format

private struct SessionsFile: Codable {
  var currentSessionId: UUID
  var sessions: [ChatSession]
  /// Manual user ordering for the tab strip. When non-nil, ids in this list
  /// are honored first; sessions not present fall back to lastUpdated order
  /// and are appended after the manual block.
  var tabOrder: [UUID]?
}

// MARK: - Store

class GeminiChatSessionStore {
  static let shared = GeminiChatSessionStore()

  private let fileName: String
  private let legacyFileName = "gemini-chat-session.json"
  private let scope: String?
  /// Maximum number of sessions kept on disk. Oldest sessions (by lastUpdated) are pruned when exceeded.
  private static let maxSessionCount = 50
  /// Sessions older than this many days have their attached image binaries stripped from the in-memory
  /// cache to avoid holding screenshots for stale conversations indefinitely.
  private static let imageRetentionDays: Double = 7

  private var cachedFile: SessionsFile?
  private let diskWriteQueue = DispatchQueue(label: "com.whispershortcut.session.io", qos: .utility)
  /// Debounce disk writes: coalesce rapid saves into a single write after a short delay.
  private var pendingSave: SessionsFile?
  private var debounceWorkItem: DispatchWorkItem?
  private static let saveDebounceSeconds: Double = 2.0
  /// Maximum messages kept per session on disk. Older messages are trimmed.
  /// Matches `AppConstants.geminiChatFullHistoryMaxMessages` so trimming never
  /// drops turns that would still be sent on the next request.
  private static let maxMessagesPerSession = 400

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

    // Trim old messages from non-current sessions to keep file size manageable.
    file.sessions = file.sessions.map { session in
      guard session.messages.count > Self.maxMessagesPerSession else { return session }
      var trimmed = session
      trimmed.messages = Array(session.messages.suffix(Self.maxMessagesPerSession))
      return trimmed
    }

    cachedFile = file
    scheduleDiskWrite(file)
  }

  /// Debounced disk write: coalesces rapid saves into a single write after a short delay.
  private func scheduleDiskWrite(_ file: SessionsFile) {
    debounceWorkItem?.cancel()
    let url = fileURL
    let dir = appSupportDir
    let workItem = DispatchWorkItem { [weak self] in
      guard self != nil else { return }
      try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      if let data = try? JSONEncoder().encode(file) {
        try? data.write(to: url, options: .atomic)
      }
    }
    debounceWorkItem = workItem
    diskWriteQueue.asyncAfter(deadline: .now() + Self.saveDebounceSeconds, execute: workItem)
  }

  /// Forces an immediate disk write of the current cached state (e.g. before app termination).
  func flushToDisk() {
    debounceWorkItem?.cancel()
    guard let file = cachedFile else { return }
    let url = fileURL
    let dir = appSupportDir
    diskWriteQueue.sync {
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

  // MARK: - Multi-Session Helpers

  func session(by id: UUID) -> ChatSession? {
    loadFile().sessions.first { $0.id == id }
  }

  /// Sessions for the tab strip. Honors the user's manual `tabOrder` first
  /// (in declared order), then appends any sessions not present in the manual
  /// list sorted by lastUpdated descending. Sessions in `tabOrder` whose ids
  /// no longer exist are silently dropped.
  func recentSessions(limit: Int = 50) -> [ChatSession] {
    let file = loadFile()
    let active = file.sessions.filter { !$0.archived }
    let byId = Dictionary(uniqueKeysWithValues: active.map { ($0.id, $0) })
    var seenIds = Set<UUID>()
    let manual = (file.tabOrder ?? []).compactMap { id -> ChatSession? in
      guard let s = byId[id], seenIds.insert(id).inserted else { return nil }
      return s
    }
    let manualIds = seenIds
    let rest = active
      .filter { !manualIds.contains($0.id) }
      .sorted { $0.lastUpdated > $1.lastUpdated }
    return Array((manual + rest).prefix(limit))
  }

  /// Returns all archived sessions sorted by lastUpdated descending.
  func archivedSessions() -> [ChatSession] {
    loadFile().sessions.filter { $0.archived }.sorted { $0.lastUpdated > $1.lastUpdated }
  }

  /// Returns all sessions (active + archived) for sidebar display, sorted by lastUpdated descending.
  func allSessions() -> [ChatSession] {
    loadFile().sessions.sorted { $0.lastUpdated > $1.lastUpdated }
  }

  func pinSession(id: UUID) {
    var file = loadFile()
    guard let idx = file.sessions.firstIndex(where: { $0.id == id }) else { return }
    file.sessions[idx].pinned = true
    saveSessionsFile(file)
  }

  func unpinSession(id: UUID) {
    var file = loadFile()
    guard let idx = file.sessions.firstIndex(where: { $0.id == id }) else { return }
    file.sessions[idx].pinned = false
    saveSessionsFile(file)
  }

  func markSessionAsMeeting(id: UUID) {
    var file = loadFile()
    guard let idx = file.sessions.firstIndex(where: { $0.id == id }) else { return }
    file.sessions[idx].isMeeting = true
    saveSessionsFile(file)
  }

  /// Reorders the tab strip so that `id` ends up at `targetIndex` in the
  /// canonical `recentSessions(limit:)` order. Persists the new order under
  /// `tabOrder`. No-op if `id` is unknown.
  func moveSession(id: UUID, toIndex targetIndex: Int) {
    var file = loadFile()
    guard file.sessions.contains(where: { $0.id == id }) else { return }
    // Build the current effective order, then move.
    var order: [UUID] = recentSessions(limit: 999).map { $0.id }
    guard let from = order.firstIndex(of: id) else { return }
    let clamped = max(0, min(targetIndex, order.count - 1))
    if from == clamped { return }
    order.remove(at: from)
    order.insert(id, at: min(clamped, order.count))
    file.tabOrder = order
    saveSessionsFile(file)
  }

  /// Deletes the session with the given ID. If it was current, switches to
  /// the most-recently-updated remaining non-archived session (or creates a new empty one if none remain).
  func deleteSession(id: UUID) {
    var file = loadFile()
    file.sessions.removeAll { $0.id == id }
    file.tabOrder?.removeAll { $0 == id }
    if file.currentSessionId == id {
      switchToNextBestSession(in: &file)
    }
    saveSessionsFile(file)
  }

  /// Deletes all non-pinned sessions whose lastUpdated is strictly older than the given date.
  /// Returns the number of deleted sessions.
  @discardableResult
  func deleteOlderSessions(than date: Date) -> Int {
    var file = loadFile()
    let toDelete = file.sessions.filter { !$0.pinned && $0.lastUpdated < date }
    guard !toDelete.isEmpty else { return 0 }
    let deleteIds = Set(toDelete.map { $0.id })
    file.sessions.removeAll { deleteIds.contains($0.id) }
    file.tabOrder?.removeAll { deleteIds.contains($0) }
    if deleteIds.contains(file.currentSessionId) {
      switchToNextBestSession(in: &file)
    }
    saveSessionsFile(file)
    DebugLogger.log("GEMINI-CHAT: Deleted \(deleteIds.count) older session(s)")
    return deleteIds.count
  }

  /// Archives a session (sets archived = true). Removes from tab order.
  /// If it was the current session, switches to the next best non-archived session.
  func archiveSession(id: UUID) {
    var file = loadFile()
    guard let idx = file.sessions.firstIndex(where: { $0.id == id }),
          !file.sessions[idx].archived else { return }
    file.sessions[idx].archived = true
    file.tabOrder?.removeAll { $0 == id }
    if file.currentSessionId == id {
      switchToNextBestSession(in: &file)
    }
    saveSessionsFile(file)
  }

  /// Archives all non-archived sessions whose lastUpdated is strictly older than the given date.
  func archiveOlderSessions(than date: Date) {
    var file = loadFile()
    var archivedIds: [UUID] = []
    for i in file.sessions.indices {
      if !file.sessions[i].archived && file.sessions[i].lastUpdated < date {
        file.sessions[i].archived = true
        archivedIds.append(file.sessions[i].id)
      }
    }
    guard !archivedIds.isEmpty else { return }
    let archivedSet = Set(archivedIds)
    file.tabOrder?.removeAll { archivedSet.contains($0) }
    if archivedSet.contains(file.currentSessionId) {
      switchToNextBestSession(in: &file)
    }
    saveSessionsFile(file)
    DebugLogger.log("GEMINI-CHAT: Archived \(archivedIds.count) older session(s)")
  }

  /// Restores an archived session (sets archived = false). Appends to tab order if present.
  func restoreSession(id: UUID) {
    var file = loadFile()
    guard let idx = file.sessions.firstIndex(where: { $0.id == id }),
          file.sessions[idx].archived else { return }
    file.sessions[idx].archived = false
    if file.tabOrder != nil, !(file.tabOrder ?? []).contains(id) {
      file.tabOrder?.append(id)
    }
    saveSessionsFile(file)
  }

  /// Switches currentSessionId to the best non-archived session by recency, or creates a new one.
  private func switchToNextBestSession(in file: inout SessionsFile) {
    let next = file.sessions
      .filter { !$0.archived && $0.id != file.currentSessionId }
      .sorted { $0.lastUpdated > $1.lastUpdated }
      .first
    if let next = next {
      file.currentSessionId = next.id
    } else {
      let newSession = ChatSession()
      file.sessions.append(newSession)
      file.currentSessionId = newSession.id
    }
  }

  /// Switches to an existing session via tab click or sidebar click.
  /// Un-archives if needed so the session reappears in the tab bar.
  func switchToSession(id: UUID) {
    var file = loadFile()
    guard let idx = file.sessions.firstIndex(where: { $0.id == id }), id != file.currentSessionId else { return }
    if file.sessions[idx].archived {
      file.sessions[idx].archived = false
    }
    file.currentSessionId = id
    saveSessionsFile(file)
  }

  /// Creates a new empty session and sets it as current.
  func createNewSession() -> ChatSession {
    let newSession = ChatSession()
    var file = loadFile()
    // If the user has a manual tab order, snapshot the full current effective
    // order (manual block + lastUpdated rest) so the new tab can be appended
    // at the true right end, instead of slotting in between the manual block
    // and the lastUpdated-sorted rest.
    if file.tabOrder != nil {
      let manualIds = file.tabOrder ?? []
      let manualSet = Set(manualIds)
      let restIds = file.sessions
        .filter { !manualSet.contains($0.id) }
        .sorted { $0.lastUpdated > $1.lastUpdated }
        .map { $0.id }
      file.tabOrder = [newSession.id] + manualIds + restIds
    }
    file.sessions.insert(newSession, at: 0)
    file.currentSessionId = newSession.id
    saveSessionsFile(file)
    DebugLogger.log("GEMINI-CHAT: New session created \(newSession.id)")
    return newSession
  }
}
