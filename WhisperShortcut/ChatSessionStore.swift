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

  /// Label for a source whose provider gives no usable title (annotation titles are often just the
  /// citation number): the URL host minus a leading "www.", which is how Gemini titles its sources.
  static func displayTitle(for urlString: String) -> String {
    guard let host = URL(string: urlString)?.host, !host.isEmpty else { return urlString }
    return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
  }
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
  /// App-side reply to a local slash command ("Model set to …"). Shown as a muted system line and
  /// never sent to the model as history, so the model doesn't read it as something it said itself.
  var isLocalNotice: Bool
  /// Tool calls the model made while writing this (assistant) message, replayed as context on
  /// later turns so IDs and results are not lost. See `ChatToolHistory`.
  var toolCalls: [ChatToolCallRecord]
  /// Name of the user command (without slash) that produced this user message, if any.
  var commandName: String?

  enum CodingKeys: String, CodingKey {
    case id, role, content, timestamp, sources, groundingSupports
    case attachedImageParts, toolCalls
    case isLocalNotice, commandName
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
    isLocalNotice: Bool = false,
    toolCalls: [ChatToolCallRecord] = [],
    commandName: String? = nil
  ) {
    self.id = id
    self.role = role
    self.content = content
    self.timestamp = timestamp
    self.sources = sources
    self.groundingSupports = groundingSupports
    self.attachedImageParts = attachedImageParts
    self.isLocalNotice = isLocalNotice
    self.toolCalls = toolCalls
    self.commandName = commandName
  }

  /// A model turn written when a reply was interrupted before any text, attachment, or tool
  /// call was saved. Gemini rejects a later request that still contains that turn
  /// (`{"role":"model","parts":[{"text":""}]}`). Local notices are not placeholders.
  var isEmptyAssistantPlaceholder: Bool {
    role == .model
      && !isLocalNotice
      && toolCalls.isEmpty
      && attachedImageParts.isEmpty
      && content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
    isLocalNotice = try c.decodeIfPresent(Bool.self, forKey: .isLocalNotice) ?? false
    toolCalls = try c.decodeIfPresent([ChatToolCallRecord].self, forKey: .toolCalls) ?? []
    commandName = try c.decodeIfPresent(String.self, forKey: .commandName)
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
    if isLocalNotice { try c.encode(true, forKey: .isLocalNotice) }
    if !toolCalls.isEmpty { try c.encode(toolCalls, forKey: .toolCalls) }
    try c.encodeIfPresent(commandName, forKey: .commandName)
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
  var meetingStem: String?
  /// Per-session reasoning intensity set via `/think`. `.default` keeps each model's built-in
  /// thinking config; other levels override it per provider. Persisted so it survives restarts.
  var thinkingLevel: ThinkingLevel
  /// Per-session narrowing of the shared workspace folders, set via `/workspace`.
  /// `nil` = every shared folder (the default); `[]` = no file access and no context files in
  /// this chat; a non-empty list = only those display paths. The nil-vs-empty distinction
  /// matters because `/workspace off` has to beat the global default.
  var workspaceFolders: [String]?
  /// Last send failure for this session, shown as a failed-turn row even if the user
  /// switched tabs before the error arrived. Cleared on the next successful send or retry.
  var lastSendError: String?

  init(id: UUID = UUID(), lastUpdated: Date = Date(), messages: [ChatMessage] = [], title: String? = nil, archived: Bool = false, pinned: Bool = false, isMeeting: Bool = false, meetingStem: String? = nil, thinkingLevel: ThinkingLevel = .default, workspaceFolders: [String]? = nil, lastSendError: String? = nil) {
    self.id = id
    self.lastUpdated = lastUpdated
    self.messages = messages
    self.title = title
    self.archived = archived
    self.pinned = pinned
    self.isMeeting = isMeeting
    self.meetingStem = meetingStem
    self.thinkingLevel = thinkingLevel
    self.workspaceFolders = workspaceFolders
    self.lastSendError = lastSendError
  }

  private enum CodingKeys: String, CodingKey {
    case id, lastUpdated, messages, title, archived, pinned, isMeeting, meetingStem, thinkingLevel
    case workspaceFolders, lastSendError
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
    meetingStem = try c.decodeIfPresent(String.self, forKey: .meetingStem)
    thinkingLevel = try c.decodeIfPresent(ThinkingLevel.self, forKey: .thinkingLevel) ?? .default
    // Absent (every chat written before `/workspace` existed) stays nil = all shared folders.
    workspaceFolders = try c.decodeIfPresent([String].self, forKey: .workspaceFolders)
    lastSendError = try c.decodeIfPresent(String.self, forKey: .lastSendError)
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(id, forKey: .id)
    try c.encode(lastUpdated, forKey: .lastUpdated)
    try c.encode(messages, forKey: .messages)
    try c.encodeIfPresent(title, forKey: .title)
    try c.encode(archived, forKey: .archived)
    try c.encode(pinned, forKey: .pinned)
    try c.encode(isMeeting, forKey: .isMeeting)
    try c.encodeIfPresent(meetingStem, forKey: .meetingStem)
    try c.encode(thinkingLevel, forKey: .thinkingLevel)
    try c.encodeIfPresent(workspaceFolders, forKey: .workspaceFolders)
    try c.encodeIfPresent(lastSendError, forKey: .lastSendError)
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

/// Decodes the sessions file element by element so one undecodable session does not hide the
/// others (R216). `session` is nil for an element that failed to decode.
private struct LenientSessionElement: Decodable {
  let session: ChatSession?
  init(from decoder: Decoder) throws {
    session = try? ChatSession(from: decoder)
  }
}

private struct LenientSessionsFile: Decodable {
  var currentSessionId: UUID
  var sessions: [LenientSessionElement]
  var tabOrder: [UUID]?
}

// MARK: - Store

@MainActor
class ChatSessionStore {
  static let shared = ChatSessionStore()
  /// Set when the sessions file failed to decode; ChatView shows it once then clears it.
  static var lastCorruptionNotice: String?

  /// Returns and clears a one-shot notice from a corrupt sessions-file recovery.
  func consumeCorruptionNotice() -> String? {
    let notice = ChatSessionStore.lastCorruptionNotice
    ChatSessionStore.lastCorruptionNotice = nil
    return notice
  }

  private let fileName: String
  private let legacyFileName = "gemini-chat-session.json"
  private let scope: String?
  /// Maximum number of sessions kept on disk. Oldest sessions (by lastUpdated) are pruned when exceeded.
  private static let maxSessionCount = 50
  /// Sessions older than this many days have their attached image binaries stripped from the in-memory
  /// cache to avoid holding screenshots for stale conversations indefinitely.
  private static let imageRetentionDays: Double = 7
  /// Archived (non-pinned) sessions whose lastUpdated is older than this many days are permanently deleted.
  private static let archivedRetentionDays: Double = 30

  private var cachedFile: SessionsFile?
  /// Set when the sessions file exists but could not be read (permissions, I/O). Nothing is written
  /// for the rest of this launch so a transient read error never replaces the user's history with
  /// an empty default session (R216).
  private var writesDisabled = false
  private let diskWriteQueue = DispatchQueue(label: "com.whispershortcut.session.io", qos: .utility)
  /// Debounce disk writes: coalesce rapid saves into a single write after a short delay.
  private var debounceWorkItem: DispatchWorkItem?
  private static let saveDebounceSeconds: Double = 2.0
  /// Maximum messages kept per session on disk. Older messages are trimmed.
  /// Matches `AppConstants.chatFullHistoryMaxMessages` so trimming never
  /// drops turns that would still be sent on the next request.
  private static let maxMessagesPerSession = 400
  /// Skip image-strip / message-trim on sessions whose `lastUpdated` hasn't changed
  /// since the last pass, unless they have now aged past the image-retention cutoff.
  private var lastNormalized: [UUID: (updated: Date, imagesStripped: Bool)] = [:]

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

    let data: Data?
    if FileManager.default.fileExists(atPath: fileURL.path) {
      do {
        data = try Data(contentsOf: fileURL)
      } catch {
        // Present but unreadable: not the same as "missing". Keep the file untouched.
        DebugLogger.logError(
          "GEMINI-CHAT: Sessions file exists but could not be read, persistence disabled for this launch: \(error.logDescription)")
        writesDisabled = true
        let defaultSession = ChatSession()
        let file = SessionsFile(currentSessionId: defaultSession.id, sessions: [defaultSession])
        cachedFile = file
        return file
      }
    } else {
      data = nil
    }

    if let data {
      do {
        let lenient = try JSONDecoder().decode(LenientSessionsFile.self, from: data)
        let decoded = lenient.sessions.compactMap(\.session)
        let skipped = lenient.sessions.count - decoded.count
        if skipped > 0 {
          backUpSessionsFile(reason: "\(skipped) session(s) could not be decoded")
        }
        var file = SessionsFile(
          currentSessionId: lenient.currentSessionId, sessions: decoded, tabOrder: lenient.tabOrder)
        if !file.sessions.isEmpty {
          if !file.sessions.contains(where: { $0.id == file.currentSessionId }),
             let first = file.sessions.first {
            file.currentSessionId = first.id
          }
          // A quit or crash mid-stream persists the empty model placeholder `performSend`
          // appends before the first token. Drop it on load so the next Gemini request
          // is not rejected for an empty model turn. In-flight placeholders are not
          // stripped on save — that would remove the bubble while the reply is streaming.
          let droppedPlaceholders = dropEmptyAssistantPlaceholders(&file)
          if purgeExpiredArchivedSessions(&file) || droppedPlaceholders || skipped > 0 {
            saveSessionsFile(file)
            return cachedFile ?? file
          }
          cachedFile = file
          return file
        }
      } catch {
        let backupName = backUpSessionsFile(reason: error.localizedDescription, move: true)
        ChatSessionStore.lastCorruptionNotice =
          String(localized: "Chat history could not be read and was set aside as \(backupName). A new empty chat was started.")
      }
    }

    let defaultSession = ChatSession()
    let file = SessionsFile(currentSessionId: defaultSession.id, sessions: [defaultSession])
    saveSessionsFile(file)
    return file
  }

  /// Keeps the on-disk sessions file under a `.corrupt-<stamp>.json` name. Copies by default (the
  /// file is rewritten right after without the bad sessions); `move` is for a file that is wholly
  /// unusable. Returns the backup file name.
  @discardableResult
  private func backUpSessionsFile(reason: String, move: Bool = false) -> String {
    let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
    let backupName = fileName.replacingOccurrences(of: ".json", with: ".corrupt-\(stamp).json")
    let backupURL = appSupportDir.appendingPathComponent(backupName)
    if move {
      try? FileManager.default.moveItem(at: fileURL, to: backupURL)
    } else {
      try? FileManager.default.copyItem(at: fileURL, to: backupURL)
      ChatSessionStore.lastCorruptionNotice =
        String(localized: "Some chats could not be read and were left out. The original file was kept as \(backupName).")
    }
    DebugLogger.logError("GEMINI-CHAT: Sessions file backed up to \(backupName): \(reason)")
    return backupName
  }

  /// Permanently deletes archived, non-pinned, non-meeting sessions whose lastUpdated is older than
  /// `archivedRetentionDays`. The current session is never removed. Returns true if any were deleted.
  @discardableResult
  private func purgeExpiredArchivedSessions(_ file: inout SessionsFile) -> Bool {
    let cutoff = Date().addingTimeInterval(-Self.archivedRetentionDays * 86400)
    let expired = file.sessions.filter {
      $0.archived && !$0.pinned && !$0.isMeeting && $0.id != file.currentSessionId && $0.lastUpdated < cutoff
    }
    guard !expired.isEmpty else { return false }
    let expiredIds = Set(expired.map { $0.id })
    file.sessions.removeAll { expiredIds.contains($0.id) }
    file.tabOrder?.removeAll { expiredIds.contains($0) }
    DebugLogger.log("GEMINI-CHAT: Auto-deleted \(expiredIds.count) archived session(s) older than \(Int(Self.archivedRetentionDays)) days")
    return true
  }

  /// Removes empty non-notice model messages left by a quit mid-reply. Returns true if any
  /// session changed.
  private func dropEmptyAssistantPlaceholders(_ file: inout SessionsFile) -> Bool {
    var removed = 0
    for index in file.sessions.indices {
      let original = file.sessions[index].messages
      let kept = original.filter { !$0.isEmptyAssistantPlaceholder }
      guard kept.count != original.count else { continue }
      file.sessions[index].messages = kept
      removed += original.count - kept.count
    }
    guard removed > 0 else { return false }
    DebugLogger.log("GEMINI-CHAT: Dropped \(removed) empty assistant placeholder(s) left by a quit mid-reply")
    return true
  }

  private func saveSessionsFile(_ file: SessionsFile) {
    var file = file

    // Meetings, pinned chats, and the current session are never pruned, so they must not
    // consume the budget either: the cap counts only the sessions that pruning may delete.
    // Sharing one cap with the exempt rows starved ordinary chats — once the exempt set alone
    // reached the cap there were zero slots left, and every unpinned chat was deleted on the
    // very next save (Cmd+N wiped the chat you had just been reading).
    let exemptIds = Set(
      file.sessions
        .filter { $0.isMeeting || $0.pinned || $0.id == file.currentSessionId }
        .map { $0.id })
    let prunable = file.sessions.filter { !exemptIds.contains($0.id) }
    if prunable.count > Self.maxSessionCount {
      let keptPrunable = Set(
        prunable
          .sorted { $0.lastUpdated > $1.lastUpdated }
          .prefix(Self.maxSessionCount)
          .map { $0.id })
      let removedIds = Set(prunable.map { $0.id }).subtracting(keptPrunable)
      file.sessions.removeAll { removedIds.contains($0.id) }
      file.tabOrder?.removeAll { removedIds.contains($0) }
      DebugLogger.log(
        "GEMINI-CHAT: Pruned \(removedIds.count) old session(s) to stay within \(Self.maxSessionCount) prunable limit")
    }

    purgeExpiredArchivedSessions(&file)

    // Strip image binaries from sessions older than imageRetentionDays before caching in memory.
    // This covers both attached image parts and generated-image markers embedded in message text.
    // The current session always keeps its images for display. Unchanged sessions are skipped.
    let cutoff = Date().addingTimeInterval(-Self.imageRetentionDays * 86400)
    file.sessions = file.sessions.map { session in
      let needsAgeStrip = session.id != file.currentSessionId && session.lastUpdated < cutoff
      let needsTrim = session.messages.count > Self.maxMessagesPerSession
      let prev = lastNormalized[session.id]
      if prev?.updated == session.lastUpdated,
         (prev?.imagesStripped == true || !needsAgeStrip),
         !needsTrim {
        return session
      }
      var result = session
      if needsAgeStrip {
        result.messages = session.messages.map { msg in
          let contentWithoutMarkers = GeminiAPIClient.stripImageMarkers(msg.content)
          let needsAttachmentStrip = !msg.attachedImageParts.isEmpty
          let needsContentStrip = contentWithoutMarkers != msg.content
          guard needsAttachmentStrip || needsContentStrip else { return msg }
          var m = msg
          if needsAttachmentStrip { m.attachedImageParts = [] }
          if needsContentStrip { m.content = contentWithoutMarkers }
          return m
        }
      }
      if result.messages.count > Self.maxMessagesPerSession {
        result.messages = Array(result.messages.suffix(Self.maxMessagesPerSession))
      }
      lastNormalized[session.id] = (updated: result.lastUpdated, imagesStripped: needsAgeStrip)
      return result
    }
    let liveIds = Set(file.sessions.map(\.id))
    lastNormalized = lastNormalized.filter { liveIds.contains($0.key) }

    cachedFile = file
    guard !writesDisabled else { return }
    scheduleDiskWrite(file)
  }

  /// Encodes and atomically writes `file`. Must run on `diskWriteQueue` so debounced and
  /// flush writes never interleave (an in-flight stale write landing after a newer one).
  private func writeNow(_ file: SessionsFile, label: String) {
    do {
      try FileManager.default.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
      let data = try JSONEncoder().encode(file)
      try data.write(to: fileURL, options: .atomic)
    } catch {
      DebugLogger.logError("GEMINI-CHAT: \(label) failed: \(error.logDescription)")
    }
  }

  /// Debounced disk write: coalesces rapid saves into a single write after a short delay.
  private func scheduleDiskWrite(_ file: SessionsFile) {
    debounceWorkItem?.cancel()
    let workItem = DispatchWorkItem { [self] in
      writeNow(file, label: "Disk write")
    }
    debounceWorkItem = workItem
    diskWriteQueue.asyncAfter(deadline: .now() + Self.saveDebounceSeconds, execute: workItem)
  }

  /// Forces an immediate disk write of the current cached state (e.g. before app termination).
  /// Only called from `applicationWillTerminate`, which is MainActor (NSApplicationDelegate),
  /// so this is an ordinary member. The write runs via `diskWriteQueue.sync` so it serializes
  /// behind a debounced write that may already be executing — `cancel()` can't stop a running
  /// work item, and its stale snapshot must not land after this fresh one. (Don't replace the
  /// sync with `DispatchQueue.main.sync` anywhere in this path — an earlier `nonisolated`
  /// version did and deadlocked on every quit.)
  func flushToDisk() {
    guard let file = cachedFile, !writesDisabled else { return }
    debounceWorkItem?.cancel()
    diskWriteQueue.sync { writeNow(file, label: "Flush to disk") }
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

  func markSessionAsMeeting(id: UUID, stem: String? = nil) {
    var file = loadFile()
    guard let idx = file.sessions.firstIndex(where: { $0.id == id }) else { return }
    file.sessions[idx].isMeeting = true
    if let stem { file.sessions[idx].meetingStem = stem }
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

  func deleteAllSessions() {
    let fm = FileManager.default
    try? fm.removeItem(at: fileURL)
    try? fm.removeItem(at: legacyFileURL)
    cachedFile = nil
    lastNormalized = [:]
    DebugLogger.log("GEMINI-CHAT: Deleted all sessions")
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

  /// Archives all non-archived, non-pinned, non-meeting sessions whose lastUpdated is strictly older than the given date.
  func archiveOlderSessions(than date: Date) {
    archiveBulk(label: "older chat") { session in
      !session.archived && !session.pinned && !session.isMeeting && session.lastUpdated < date
    }
  }

  /// Archives all non-archived, non-pinned meetings whose meeting date (or lastUpdated) is strictly older than the given date.
  func archiveOlderMeetings(than date: Date) {
    archiveBulk(label: "older meeting") { session in
      session.isMeeting && !session.archived && !session.pinned && Self.meetingSortDate(session) < date
    }
  }

  /// Archives all non-archived, non-pinned chats except `keepId`.
  func archiveOtherSessions(except keepId: UUID) {
    archiveBulk(label: "other chat") { session in
      !session.isMeeting && session.id != keepId && !session.archived && !session.pinned
    }
  }

  /// Archives all non-archived, non-pinned meetings except `keepId` and any ids in `skipIds`.
  func archiveOtherMeetings(except keepId: UUID, skipIds: Set<UUID> = []) {
    archiveBulk(label: "other meeting") { session in
      session.isMeeting && session.id != keepId && !skipIds.contains(session.id)
        && !session.archived && !session.pinned
    }
  }

  private static func meetingSortDate(_ session: ChatSession) -> Date {
    session.meetingStem.flatMap(MeetingListService.date(fromStem:)) ?? session.lastUpdated
  }

  private func archiveBulk(label: String, include: (ChatSession) -> Bool) {
    var file = loadFile()
    var archivedIds: [UUID] = []
    for i in file.sessions.indices where include(file.sessions[i]) {
      file.sessions[i].archived = true
      archivedIds.append(file.sessions[i].id)
    }
    guard !archivedIds.isEmpty else { return }
    let archivedSet = Set(archivedIds)
    file.tabOrder?.removeAll { archivedSet.contains($0) }
    if archivedSet.contains(file.currentSessionId) {
      switchToNextBestSession(in: &file)
    }
    saveSessionsFile(file)
    DebugLogger.log("GEMINI-CHAT: Archived \(archivedIds.count) \(label)(s)")
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
