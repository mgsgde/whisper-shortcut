import Combine
import Foundation
import Security

/// Local MCP server (Streamable HTTP, JSON responses only) that exposes meeting transcripts and the
/// configuration to Claude Code / Claude Desktop. Off by default. Two bearer tokens in the Keychain:
/// the read token (meetings + configuration) and the write token (also lets the client change the
/// configuration, within the access level the user chose in Settings).
final class MCPServer: ObservableObject {
  static let shared = MCPServer()
  static let defaultPort: UInt16 = 47823
  /// Ports past the default a second macOS user may try when 47823 is already taken.
  static let fallbackPortCount: UInt16 = 16
  private static let tokenAccount = "mcp-server-token"
  private static let writeTokenAccount = "mcp-server-write-token"

  enum Status: Equatable {
    case stopped
    case running(port: UInt16)
    case failed(String)
  }

  /// Always mutated on main.
  @Published private(set) var status: Status = .stopped

  private var server: LoopbackHTTPServer?
  private let stateLock = NSLock()
  private var liveActive = false
  private var liveStem: String?
  private var cancellables = Set<AnyCancellable>()
  private var observing = false

  var isEnabled: Bool {
    get { UserDefaults.standard.bool(forKey: UserDefaultsKeys.mcpServerEnabled) }
    set {
      UserDefaults.standard.set(newValue, forKey: UserDefaultsKeys.mcpServerEnabled)
      if newValue { start() } else { stop() }
    }
  }

  /// The port clients should use. While running, the port actually bound; otherwise the first
  /// candidate (an override, the sticky fallback, or the default).
  var port: UInt16 {
    if case .running(let bound) = status { return bound }
    return Self.candidatePorts(
      override: UserDefaults.standard.integer(forKey: UserDefaultsKeys.mcpServerPort),
      sticky: UserDefaults.standard.integer(forKey: UserDefaultsKeys.mcpServerBoundPort),
      fallbackEnabled: UserDefaults.standard.object(forKey: UserDefaultsKeys.mcpPortFallbackEnabled) as? Bool ?? true
    ).first ?? Self.defaultPort
  }

  /// Ports to try, in order. An explicit override is used alone. With fallback disabled, only the
  /// default. Otherwise the sticky port first when it lies in the default window, then the default,
  /// then the next `fallbackPortCount` ports. Duplicates are dropped; order is kept.
  static func candidatePorts(override: Int, sticky: Int, fallbackEnabled: Bool) -> [UInt16] {
    if (1...65535).contains(override) { return [UInt16(override)] }
    if !fallbackEnabled { return [defaultPort] }
    let first = Int(defaultPort)
    let last = first + Int(fallbackPortCount)
    var ports: [UInt16] = []
    if (first...last).contains(sticky) { ports.append(UInt16(sticky)) }
    for value in first...last {
      let candidate = UInt16(value)
      if !ports.contains(candidate) { ports.append(candidate) }
    }
    return ports
  }

  var endpointURL: String { "http://127.0.0.1:\(port)/mcp" }

  // MARK: - Token

  /// Cached after the first read: every request and every Settings redraw asks for it, and a
  /// failed Keychain write must not mint a different key on each call.
  private var cachedToken: String?
  private var cachedWriteToken: String?
  /// Accounts whose latest `saveSecret` returned false. `saveSecret` still keeps that value in
  /// its session cache, so the next lookup must not be treated as a token that was stored.
  private var unpersistedAccounts = Set<String>()
  /// One client-config repair after this process starts serving the other build's shared token.
  private var didScheduleAdoptedTokenRepair = false

  /// nil when the Keychain cannot be read or the new token could not be stored. Never cache a
  /// token that was not saved — a later request would hand clients a key that disappears on restart.
  func token() -> String? {
    stateLock.lock()
    if let cachedToken {
      stateLock.unlock()
      return cachedToken
    }
    let (fresh, shouldRepair) = loadOrCreateToken(account: Self.tokenAccount, label: "read token")
    if let fresh { cachedToken = fresh }
    stateLock.unlock()
    // After the lock: repair reads both tokens, and it must not run while this lock is held.
    if shouldRepair { repairClientTokens() }
    return fresh
  }

  func regenerateToken() {
    guard let fresh = makeAndStoreToken() else {
      stateLock.lock()
      if cachedToken == nil { unpersistedAccounts.insert(Self.tokenAccount) }
      stateLock.unlock()
      return
    }
    stateLock.lock()
    unpersistedAccounts.remove(Self.tokenAccount)
    cachedToken = fresh
    stateLock.unlock()
    DebugLogger.log("MCP-SERVER: Token regenerated")
    objectWillChange.send()
    repairClientTokens()
  }

  /// Grants read and write. Created on first use, cached like the read token. nil when the
  /// Keychain cannot be read or the new token could not be stored — see `token()`.
  func writeToken() -> String? {
    stateLock.lock()
    if let cachedWriteToken {
      stateLock.unlock()
      return cachedWriteToken
    }
    let (fresh, shouldRepair) = loadOrCreateToken(account: Self.writeTokenAccount, label: "write token")
    if let fresh { cachedWriteToken = fresh }
    stateLock.unlock()
    if shouldRepair { repairClientTokens() }
    return fresh
  }

  func regenerateWriteToken() {
    guard let fresh = makeAndStoreToken(account: Self.writeTokenAccount) else {
      stateLock.lock()
      if cachedWriteToken == nil { unpersistedAccounts.insert(Self.writeTokenAccount) }
      stateLock.unlock()
      return
    }
    stateLock.lock()
    unpersistedAccounts.remove(Self.writeTokenAccount)
    cachedWriteToken = fresh
    stateLock.unlock()
    DebugLogger.log("MCP-SERVER: Write token regenerated")
    objectWillChange.send()
    repairClientTokens()
  }

  /// Rewrites a stale token or a previous loopback URL in client configs that already hold our
  /// entry, once the server is running. Silent: no UI, never adds an entry to a client that has none.
  private func repairClientTokens() {
    Task { @MainActor [weak self] in
      guard let self, case .running = self.status,
        let read = self.token(), let write = self.writeToken()
      else { return }
      MCPClientInstaller.repairStaleTokens(
        url: self.endpointURL, readToken: read, writeToken: write,
        serverName: AIAppsSettingsTab.serverName)
    }
  }

  /// Caller holds `stateLock`. Returns a token only when it is already stored or was just saved.
  /// The caller caches that value; nil is not cached. `shouldRepair` is true once per process,
  /// when this load adopted the other build's shared token and the local copy differed.
  private func loadOrCreateToken(account: String, label: String) -> (String?, shouldRepair: Bool) {
    // A failed `saveSecret` still caches the value for the session. That cache must not be
    // handed out as a token that disappears on restart. Checked before `load`, which would
    // otherwise promote the cached value into the shared group.
    if unpersistedAccounts.contains(account) {
      if case .found(let existing) = KeychainManager.shared.secretLookup(account: account), !existing.isEmpty {
        return (nil, false)
      }
    }

    let store = makeTokenStore()
    guard let fresh = store.load(account: account) else {
      if let status = store.lastReadFailureStatus {
        DebugLogger.logError("MCP-SERVER: Keychain read failed for the \(label): status=\(status)")
        return (nil, false)
      }
      unpersistedAccounts.insert(account)
      return (nil, false)
    }
    unpersistedAccounts.remove(account)
    let shouldRepair = store.adoptedSharedToken && !didScheduleAdoptedTokenRepair
    if shouldRepair { didScheduleAdoptedTokenRepair = true }
    return (fresh, shouldRepair)
  }

  private func makeTokenStore() -> MCPSharedTokenStore {
    MCPSharedTokenStore(
      keychain: SystemMCPTokenKeychain(),
      sharedGroup: MCPSharedTokenStore.sharedAccessGroup())
  }

  /// nil when random bytes could not be drawn or neither keychain accepted the write. The value
  /// is not cached by the caller in that case.
  private func makeAndStoreToken(account: String = MCPServer.tokenAccount) -> String? {
    guard let token = MCPSharedTokenStore.generateToken() else { return nil }
    guard makeTokenStore().store(token, account: account) else {
      DebugLogger.logError("MCP-SERVER: Could not store the token in the Keychain (account \(account))")
      return nil
    }
    return token
  }

  // MARK: - Lifecycle

  func startIfEnabled() {
    if isEnabled { start() }
  }

  /// Like `startIfEnabled`, but leaves a server that is already listening alone: `start()` stops
  /// and rebinds, which drops connected clients. Main thread, like `status`.
  func startIfEnabledAndNotRunning() {
    if case .running = status { return }
    startIfEnabled()
  }

  private func start() {
    // Also reached from the `isEnabled` setter: a sidecar must never take the user's MCP port.
    guard !AppConstants.isSidecarInstance else {
      DebugLogger.log("MCP-SERVER: Not starting — sidecar instance")
      return
    }
    runOnMain { [self] in
      if OfflineMode.isEnabled {
        stopLocked()
        status = .failed("Off while Offline Mode is on. Turn Offline Mode off, then switch this on again.")
        DebugLogger.log("MCP-SERVER: Not starting — Offline Mode is on")
        return
      }
      observeLiveMeeting()
      if server != nil { stopLocked() }
      let dispatcher = MCPDispatcher(
        meetingTools: MCPMeetingTools(
          meetingsDirectory: Self.meetingsDirectory(),
          liveStem: { [weak self] in self?.currentLiveStem() },
          meetingTitles: { Self.meetingTitlesFromSessions() }),
        configTools: MCPConfigTools(env: .live))
      let defaults = UserDefaults.standard
      let override = defaults.integer(forKey: UserDefaultsKeys.mcpServerPort)
      let candidates = Self.candidatePorts(
        override: override,
        sticky: defaults.integer(forKey: UserDefaultsKeys.mcpServerBoundPort),
        fallbackEnabled: defaults.object(forKey: UserDefaultsKeys.mcpPortFallbackEnabled) as? Bool ?? true)
      let onFailure: (String) -> Void = { [weak self] reason in
        DispatchQueue.main.async {
          guard let self else { return }
          self.status = .failed(String(localized: "The local server stopped: \(reason). Turn it off and on again."))
          DebugLogger.log("MCP-SERVER: Accept loop stopped: \(reason)")
        }
      }
      let handler: (HTTPRequest) -> HTTPResponse = { [weak self] request in
        guard let self else { return .empty(503) }
        // Offline Mode promises nothing leaves this Mac; an AI app reading transcripts would send
        // them to its provider. Checked per request so turning the mode on takes effect at once.
        if OfflineMode.isEnabled { return .empty(503) }
        guard let readToken = self.token(), let writeToken = self.writeToken() else {
          DebugLogger.logError("MCP-SERVER: Keychain unavailable, refusing request")
          return HTTPResponse.json(["error": "keychain unavailable"], status: 503)
        }
        return Self.handle(
          request, readToken: readToken, writeToken: writeToken, dispatcher: dispatcher)
      }
      for candidate in candidates {
        do {
          let s = try LoopbackHTTPServer(port: candidate, onFailure: onFailure, handler: handler)
          server = s
          let bound = s.port
          if bound == Self.defaultPort || (1...65535).contains(override) {
            defaults.removeObject(forKey: UserDefaultsKeys.mcpServerBoundPort)
          } else {
            defaults.set(Int(bound), forKey: UserDefaultsKeys.mcpServerBoundPort)
            DebugLogger.log("MCP-SERVER: Default port taken (other macOS user?), using \(bound)")
          }
          status = .running(port: bound)
          DebugLogger.log("MCP-SERVER: Listening on 127.0.0.1:\(bound)")
          repairClientTokens()
          return
        } catch {
          if let e = error as? LoopbackHTTPServer.ServerError, e.errno == EADDRINUSE {
            DebugLogger.log("MCP-SERVER: Port \(candidate) in use, trying next")
            continue
          }
          let message = error.localizedDescription
          status = .failed(message)
          DebugLogger.log("MCP-SERVER: Start failed: \(message)")
          return
        }
      }
      let first = candidates.first ?? Self.defaultPort
      let message = String(localized: "Port \(first) is in use by another app. Quit it or choose a different port.")
      status = .failed(message)
      DebugLogger.log("MCP-SERVER: Start failed: \(message)")
    }
  }

  func stop() {
    runOnMain { [self] in
      let wasRunning = server != nil
      stopLocked()
      status = .stopped
      if wasRunning { DebugLogger.log("MCP-SERVER: Stopped") }
    }
  }

  private func stopLocked() {
    server?.stop()
    server = nil
  }

  private func runOnMain(_ block: @escaping () -> Void) {
    if Thread.isMainThread { block() } else { DispatchQueue.main.async(execute: block) }
  }

  // MARK: - Live meeting state

  private func observeLiveMeeting() {
    guard !observing else { return }
    observing = true
    let store = LiveMeetingTranscriptStore.shared
    updateLive(active: store.isSessionActive, stem: store.currentMeetingFilenameStem)
    // @Published emits in willSet, so use the emitted value rather than reading the store back.
    store.$isSessionActive
      .sink { [weak self] active in
        guard let self else { return }
        self.stateLock.lock(); self.liveActive = active; self.stateLock.unlock()
      }
      .store(in: &cancellables)
    store.$currentMeetingFilenameStem
      .sink { [weak self] stem in
        guard let self else { return }
        self.stateLock.lock(); self.liveStem = stem; self.stateLock.unlock()
      }
      .store(in: &cancellables)
  }

  private func updateLive(active: Bool, stem: String?) {
    stateLock.lock(); liveActive = active; liveStem = stem; stateLock.unlock()
  }

  private func currentLiveStem() -> String? {
    stateLock.lock(); defer { stateLock.unlock() }
    return liveActive ? liveStem : nil
  }

  /// Session titles by meeting stem; ChatSessionStore is @MainActor but requests arrive off-main, so hop to main.
  static func meetingTitlesFromSessions(timeout: TimeInterval = MCPMain.mainWaitTimeout) -> [String: String] {
    func build() -> [String: String] {
      MainActor.assumeIsolated {
        var map: [String: String] = [:]
        // allSessions() is newest first, so the first title per stem wins.
        for s in ChatSessionStore.shared.allSessions() {
          guard let stem = s.meetingStem, map[stem] == nil else { continue }
          let t = (s.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
          if !t.isEmpty { map[stem] = t }
        }
        return map
      }
    }
    // A modal dialog stalls the main queue; fall back to the titles in the transcript files.
    return MCPMain.runBounded(timeout: timeout, build) ?? [:]
  }

  static func meetingsDirectory() -> URL {
    AppSupportPaths.whisperShortcutApplicationSupportURL()
      .appendingPathComponent(AppConstants.liveMeetingTranscriptDirectory)
  }

  // MARK: - Request handling (pure)

  static func handle(
    _ request: HTTPRequest, readToken: String, writeToken: String, dispatcher: MCPDispatcher
  ) -> HTTPResponse {
    guard request.path == "/mcp" else { return .json(["error": "not found"], status: 404) }

    if let origin = request.header("origin") {
      let host = URL(string: origin)?.host ?? ""
      // `URL.host` for `http://[::1]:1` is `::1` on current Foundation and `[::1]` on some versions.
      if !isLoopbackOriginHost(host) {
        return .json(["error": "forbidden origin"], status: 403)
      }
    }

    let supplied = request.header("authorization") ?? ""
    // Both comparisons always run, so timing does not reveal which token was close.
    let isWrite = constantTimeEqual(supplied, "Bearer \(writeToken)")
    let isRead = constantTimeEqual(supplied, "Bearer \(readToken)")
    guard isWrite || isRead else {
      noteRejectedBearer(supplied)
      return HTTPResponse(
        status: 401, headers: ["WWW-Authenticate": "Bearer"],
        body: Data(#"{"error":"unauthorized"}"#.utf8))
    }

    guard request.method == "POST" else {
      return HTTPResponse(status: 405, headers: ["Allow": "POST"], body: Data(#"{"error":"method not allowed"}"#.utf8))
    }

    guard let parsed = try? JSONSerialization.jsonObject(with: request.body, options: [.fragmentsAllowed]) else {
      return .json(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"] as [String: Any]])
    }

    let access: MCPAccess = isWrite ? .write : .read
    if let batch = parsed as? [Any] {
      let responses = batch.compactMap { dispatcher.dispatch($0, access: access) }
      if responses.isEmpty { return .empty(202) }
      return .json(responses)
    }
    guard let response = dispatcher.dispatch(parsed, access: access) else { return .empty(202) }
    return .json(response)
  }

  static func isLoopbackOriginHost(_ host: String) -> Bool {
    host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
  }

  private static let bearerRejectLogLock = NSLock()
  private static var bearerRejectLoggedAt = Date.distantPast

  /// A supplied bearer matched neither token. At most once a minute: the 401 itself is unchanged.
  private static func noteRejectedBearer(_ supplied: String) {
    let scheme = "bearer "
    guard supplied.lowercased().hasPrefix(scheme), !supplied.dropFirst(scheme.count).isEmpty else { return }
    bearerRejectLogLock.lock()
    let now = Date()
    let shouldLog = now.timeIntervalSince(bearerRejectLoggedAt) >= 60
    if shouldLog { bearerRejectLoggedAt = now }
    bearerRejectLogLock.unlock()
    guard shouldLog else { return }
    DebugLogger.logWarning(
      "MCP-SERVER: Rejected a bearer token that matches neither the read nor the write token. If two WhisperShortcut builds are installed, the client may hold the other build's token; reconnect it in Settings > AI Apps."
    )
  }

  private static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
    let x = Array(a.utf8), y = Array(b.utf8)
    var diff = x.count ^ y.count
    for i in 0..<max(x.count, y.count) {
      diff |= Int(i < x.count ? x[i] : 0) ^ Int(i < y.count ? y[i] : 0)
    }
    return diff == 0
  }
}
