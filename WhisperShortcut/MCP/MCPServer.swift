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

  var port: UInt16 {
    let stored = UserDefaults.standard.integer(forKey: UserDefaultsKeys.mcpServerPort)
    return (stored > 0 && stored <= Int(UInt16.max)) ? UInt16(stored) : Self.defaultPort
  }

  var endpointURL: String { "http://127.0.0.1:\(port)/mcp" }

  // MARK: - Token

  /// Cached after the first read: every request and every Settings redraw asks for it, and a
  /// failed Keychain write must not mint a different key on each call.
  private var cachedToken: String?

  /// nil only on a transient Keychain failure (`.failed`) — never mint/cache a replacement then,
  /// or a momentary glitch would silently invalidate the token every configured MCP client holds.
  func token() -> String? {
    stateLock.lock(); defer { stateLock.unlock() }
    if let cachedToken { return cachedToken }
    switch KeychainManager.shared.secretLookup(account: Self.tokenAccount) {
    case .found(let existing) where !existing.isEmpty:
      cachedToken = existing
      return existing
    case .found, .notFound:
      let fresh = makeAndStoreToken()
      cachedToken = fresh
      return fresh
    case .failed(let status):
      DebugLogger.logError("MCP-SERVER: Keychain read failed for the read token: status=\(status)")
      return nil
    }
  }

  func regenerateToken() {
    let fresh = makeAndStoreToken()
    stateLock.lock(); cachedToken = fresh; stateLock.unlock()
    DebugLogger.log("MCP-SERVER: Token regenerated")
    objectWillChange.send()
  }

  private var cachedWriteToken: String?

  /// Grants read and write. Created on first use, cached like the read token. nil only on a
  /// transient Keychain failure — see `token()`.
  func writeToken() -> String? {
    stateLock.lock(); defer { stateLock.unlock() }
    if let cachedWriteToken { return cachedWriteToken }
    switch KeychainManager.shared.secretLookup(account: Self.writeTokenAccount) {
    case .found(let existing) where !existing.isEmpty:
      cachedWriteToken = existing
      return existing
    case .found, .notFound:
      let fresh = makeAndStoreToken(account: Self.writeTokenAccount)
      cachedWriteToken = fresh
      return fresh
    case .failed(let status):
      DebugLogger.logError("MCP-SERVER: Keychain read failed for the write token: status=\(status)")
      return nil
    }
  }

  func regenerateWriteToken() {
    let fresh = makeAndStoreToken(account: Self.writeTokenAccount)
    stateLock.lock(); cachedWriteToken = fresh; stateLock.unlock()
    DebugLogger.log("MCP-SERVER: Write token regenerated")
    objectWillChange.send()
  }

  private func makeAndStoreToken(account: String = MCPServer.tokenAccount) -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    let token = bytes.map { String(format: "%02x", $0) }.joined()
    _ = KeychainManager.shared.saveSecret(token, account: account)
    return token
  }

  // MARK: - Lifecycle

  func startIfEnabled() {
    if isEnabled { start() }
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
      let requested = port
      do {
        let s = try LoopbackHTTPServer(
          port: requested,
          onFailure: { [weak self] reason in
            DispatchQueue.main.async {
              guard let self else { return }
              self.status = .failed(String(localized: "The local server stopped: \(reason). Turn it off and on again."))
              DebugLogger.log("MCP-SERVER: Accept loop stopped: \(reason)")
            }
          }
        ) { [weak self] request in
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
        server = s
        status = .running(port: s.port)
        DebugLogger.log("MCP-SERVER: Listening on 127.0.0.1:\(s.port)")
      } catch {
        let message: String
        if let e = error as? LoopbackHTTPServer.ServerError, e.errno == EADDRINUSE {
          message = String(localized: "Port \(requested) is in use by another app. Quit it or choose a different port.")
        } else {
          message = error.localizedDescription
        }
        status = .failed(message)
        DebugLogger.log("MCP-SERVER: Start failed: \(message)")
      }
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
  private static func meetingTitlesFromSessions() -> [String: String] {
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
    if Thread.isMainThread { return build() }
    return DispatchQueue.main.sync { build() }
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
      if host != "localhost" && host != "127.0.0.1" {
        return .json(["error": "forbidden origin"], status: 403)
      }
    }

    let supplied = request.header("authorization") ?? ""
    // Both comparisons always run, so timing does not reveal which token was close.
    let isWrite = constantTimeEqual(supplied, "Bearer \(writeToken)")
    let isRead = constantTimeEqual(supplied, "Bearer \(readToken)")
    guard isWrite || isRead else {
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

  private static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
    let x = Array(a.utf8), y = Array(b.utf8)
    var diff = x.count ^ y.count
    for i in 0..<max(x.count, y.count) {
      diff |= Int(i < x.count ? x[i] : 0) ^ Int(i < y.count ? y[i] : 0)
    }
    return diff == 0
  }
}
