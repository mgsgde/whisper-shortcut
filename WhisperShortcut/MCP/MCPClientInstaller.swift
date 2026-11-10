import AppKit
import Foundation

/// AI clients the app can add itself to with one click.
enum MCPClient: String, CaseIterable {
  case claudeCode
  case claudeDesktop
  case codex

  var displayName: String {
    switch self {
    case .claudeCode: return "Claude Code"
    case .claudeDesktop: return "Claude Desktop"
    case .codex: return "Codex"
    }
  }

  /// Prefix of the `clientInfo.name` this client sends on `initialize`, for `MCPClientRegistry`.
  var registryPrefix: String {
    switch self {
    case .claudeCode: return "claude-code"
    case .claudeDesktop: return "claude-ai"
    case .codex: return "codex"
    }
  }

  /// The real home directory. `NSHomeDirectory()` points into the sandbox container.
  static var realHome: URL {
    if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
      return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
    }
    return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
  }

  var configFolder: URL {
    let home = MCPClient.realHome
    switch self {
    case .claudeCode: return home
    case .claudeDesktop:
      return home.appendingPathComponent("Library/Application Support/Claude", isDirectory: true)
    case .codex: return home.appendingPathComponent(".codex", isDirectory: true)
    }
  }

  var configFileName: String {
    switch self {
    case .claudeCode: return ".claude.json"
    case .claudeDesktop: return "claude_desktop_config.json"
    case .codex: return "config.toml"
    }
  }

  var restartHint: String {
    switch self {
    case .claudeCode: return String(localized: "Start a new Claude Code session.")
    case .claudeDesktop: return String(localized: "Quit and reopen Claude.")
    case .codex: return String(localized: "Start a new Codex session.")
    }
  }
}

enum MCPClientInstallerError: LocalizedError {
  case cancelled
  case wrongFolder(expected: String)
  case notAJSONObject(file: String)
  case runningFromTemporaryLocation
  case notUTF8(file: String)

  var errorDescription: String? {
    switch self {
    case .cancelled:
      return String(localized: "Cancelled.")
    case .wrongFolder(let expected):
      return String(localized: "Please choose the folder \(expected) and click Allow.")
    case .notAJSONObject(let file):
      return String(localized: "\(file) is not valid JSON, so it was left untouched. Fix or remove the file and try again.")
    case .notUTF8(let file):
      return String(localized: "\(file) is not valid UTF-8 text, so it was left untouched. Fix or remove the file and try again.")
    case .runningFromTemporaryLocation:
      return String(
        localized:
          "Move WhisperShortcut to your Applications folder first — it is running from a temporary location that macOS removes after quit, so Claude Desktop could not start it later."
      )
    }
  }
}

/// Which bearer token Connect wrote into a client's config.
enum MCPTokenKind: String {
  case read
  case write
}

enum MCPClientInstaller {

  // MARK: - Stale token repair (pure)

  /// New config bytes when `existing` holds our entry for `url` with a token that is neither
  /// `readToken` nor `writeToken`; nil when nothing should change (no entry, foreign url, current
  /// token, unparseable file).
  static func repairedConfig(
    client: MCPClient, existing: Data, serverName: String, url: String,
    readToken: String, writeToken: String, tokenKind: MCPTokenKind, executablePath: String
  ) -> Data? {
    let wanted = tokenKind == .read ? readToken : writeToken
    let valid = ["Bearer \(readToken)", "Bearer \(writeToken)"]
    switch client {
    case .claudeCode, .claudeDesktop:
      guard let root = try? JSONSerialization.jsonObject(with: existing) as? [String: Any],
        let servers = root["mcpServers"] as? [String: Any],
        let entry = servers[serverName] as? [String: Any]
      else { return nil }
      if client == .claudeCode {
        guard entry["url"] as? String == url else { return nil }
        let header = (entry["headers"] as? [String: Any])?["Authorization"] as? String
        if let header, valid.contains(header) { return nil }
        return try? mergeClaudeCode(existing: existing, serverName: serverName, url: url, token: wanted)
      }
      let env = entry["env"] as? [String: Any]
      guard env?[MCPStdioBridge.urlEnv] as? String == url else { return nil }
      if let auth = env?[MCPStdioBridge.authEnv] as? String, valid.contains(auth) { return nil }
      var command = executablePath
      if let existingCommand = entry["command"] as? String, FileManager.default.fileExists(atPath: existingCommand) {
        command = existingCommand
      }
      return try? mergeClaudeDesktop(
        existing: existing, serverName: serverName, url: url, token: wanted, executablePath: command)
    case .codex:
      guard let text = String(data: existing, encoding: .utf8),
        let table = codexTableBody(text, serverName: serverName)
      else { return nil }
      var tableURL: String?
      for line in table.split(whereSeparator: \.isNewline) {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("url"), let q1 = t.firstIndex(of: "\""), let q2 = t.lastIndex(of: "\""), q1 < q2 {
          tableURL = String(t[t.index(after: q1)..<q2])
        }
      }
      guard tableURL == url else { return nil }
      if valid.contains(where: { table.contains($0) }) { return nil }
      return Data(mergeCodex(existing: text, serverName: serverName, url: url, token: wanted).utf8)
    }
  }

  /// Lines of the `[mcp_servers.<name>]` table (plain or quoted name), without sub-tables. Nil when absent.
  private static func codexTableBody(_ text: String, serverName: String) -> String? {
    let headers = ["[mcp_servers.\(serverName)]", "[mcp_servers.\"\(serverName)\"]"]
    var inTable = false
    var found = false
    var body: [Substring] = []
    for line in text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
      let t = line.trimmingCharacters(in: .whitespaces)
      if t.hasPrefix("[") {
        inTable = headers.contains(t)
        if inTable { found = true }
        continue
      }
      if inTable { body.append(line) }
    }
    return found ? body.joined(separator: "\n") : nil
  }

  // MARK: - Stale token repair (impure)

  private static func bookmarkKey(_ client: MCPClient) -> String {
    UserDefaultsKeys.mcpClientFolderBookmarkPrefix + client.rawValue
  }

  private static func tokenKindKey(_ client: MCPClient) -> String {
    UserDefaultsKeys.mcpClientTokenKindPrefix + client.rawValue
  }

  private static func saveBookmark(for folder: URL, client: MCPClient, tokenKind: MCPTokenKind) {
    do {
      let data = try folder.bookmarkData(
        options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
      UserDefaults.standard.set(data, forKey: bookmarkKey(client))
      UserDefaults.standard.set(tokenKind.rawValue, forKey: tokenKindKey(client))
    } catch {
      DebugLogger.logError("MCP-INSTALL: could not save folder bookmark for \(client.displayName): \(error.localizedDescription)")
    }
  }

  private static func clearBookmark(for client: MCPClient) {
    UserDefaults.standard.removeObject(forKey: bookmarkKey(client))
    UserDefaults.standard.removeObject(forKey: tokenKindKey(client))
  }

  /// Rewrites stale tokens in configs of clients connected earlier (a stored folder bookmark).
  /// Silent: never shows UI, never adds an entry, errors are logged and skipped.
  @MainActor
  static func repairStaleTokens(url: String, readToken: String, writeToken: String, serverName: String) {
    let defaults = UserDefaults.standard
    guard (defaults.object(forKey: UserDefaultsKeys.mcpAutoRepairClientTokens) as? Bool ?? true) else { return }
    for client in MCPClient.allCases {
      guard let bookmark = defaults.data(forKey: bookmarkKey(client)) else { continue }
      do {
        var stale = false
        let folder = try URL(
          resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil,
          bookmarkDataIsStale: &stale)
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        let kind = MCPTokenKind(rawValue: defaults.string(forKey: tokenKindKey(client)) ?? "") ?? .read
        if stale { saveBookmark(for: folder, client: client, tokenKind: kind) }
        // The bookmark may be an ancestor of the config folder (a client that had not run yet).
        let file = client.configFolder.appendingPathComponent(client.configFileName)
        guard FileManager.default.fileExists(atPath: file.path) else { continue }
        let existing = try Data(contentsOf: file)
        guard let output = repairedConfig(
          client: client, existing: existing, serverName: serverName, url: url,
          readToken: readToken, writeToken: writeToken, tokenKind: kind,
          executablePath: (try? stableExecutablePath(Bundle.main.executablePath)) ?? "")
        else { continue }
        try writeConfigAtomically(output, to: file)
        DebugLogger.logSuccess("MCP-INSTALL: repaired stale token for \(client.displayName)")
      } catch {
        DebugLogger.logError("MCP-INSTALL: token repair for \(client.displayName) failed: \(error.localizedDescription)")
      }
    }
  }

  // MARK: - Pure merge functions

  static func mergeClaudeCode(existing: Data?, serverName: String, url: String, token: String) throws -> Data {
    let entry: [String: Any] = [
      "type": "http",
      "url": url,
      "headers": ["Authorization": "Bearer \(token)"],
    ]
    return try mergeJSON(existing: existing, serverName: serverName, entry: entry)
  }

  /// Claude Desktop only launches local MCP servers as stdio processes. This executable is the
  /// bridge: `--mcp-stdio` forwards stdin to the HTTP endpoint. The URL and bearer token travel
  /// in the environment, not on the command line.
  static func mergeClaudeDesktop(
    existing: Data?, serverName: String, url: String, token: String, executablePath: String
  ) throws -> Data {
    let entry: [String: Any] = [
      "command": executablePath,
      "args": [MCPStdioBridge.argument],
      "env": [
        MCPStdioBridge.urlEnv: url,
        MCPStdioBridge.authEnv: "Bearer \(token)",
      ],
    ]
    return try mergeJSON(existing: existing, serverName: serverName, entry: entry)
  }

  /// The executable Claude Desktop will launch later. Throws when there is none, or when it lives
  /// somewhere macOS removes after quit (App Translocation, a mounted disk image).
  static func stableExecutablePath(_ path: String?, homeDirectory: String = MCPClient.realHome.path) throws -> String {
    guard let path, !path.isEmpty else { throw MCPClientInstallerError.runningFromTemporaryLocation }
    switch AppBundleLocation.classify(bundlePath: path, homeDirectory: homeDirectory) {
    case .translocated, .diskImage: throw MCPClientInstallerError.runningFromTemporaryLocation
    case .applications, .elsewhere, .developerBuild: return path
    }
  }

  private static func mergeJSON(existing: Data?, serverName: String, entry: [String: Any]) throws -> Data {
    var root: [String: Any] = [:]
    if let existing, !existing.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) {
      guard let parsed = try? JSONSerialization.jsonObject(with: existing) as? [String: Any] else {
        throw MCPClientInstallerError.notAJSONObject(file: "The existing config file")
      }
      root = parsed
    }
    var servers = root["mcpServers"] as? [String: Any] ?? [:]
    servers[serverName] = entry
    root["mcpServers"] = servers
    var data = try JSONSerialization.data(
      withJSONObject: root, options: [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys])
    data.append(0x0A)
    return data
  }

  static func mergeCodex(existing: String?, serverName: String, url: String, token: String) -> String {
    let crlf = usesCRLF(existing)
    var text = droppingServerTables(existing: normalizingLineEndings(existing), serverName: serverName).text
    // Trim trailing blank lines left behind, then separate with exactly one blank line.
    while text.hasSuffix("\n\n") { text.removeLast() }
    if !text.isEmpty {
      if !text.hasSuffix("\n") { text += "\n" }
      text += "\n"
    }
    let header = "[mcp_servers.\(serverName)]"
    text += "\(header)\nurl = \"\(url)\"\nhttp_headers = { Authorization = \"Bearer \(token)\" }\n"
    return crlf ? text.replacingOccurrences(of: "\n", with: "\r\n") : text
  }

  /// The Codex config as text. Nil for a missing file; throws when the bytes are not UTF-8, so a
  /// file we cannot read is never replaced by only our table.
  static func codexText(from data: Data?, file: URL) throws -> String? {
    guard let data else { return nil }
    guard let text = String(data: data, encoding: .utf8) else {
      throw MCPClientInstallerError.notUTF8(file: (file.path as NSString).abbreviatingWithTildeInPath)
    }
    return text
  }

  private static func usesCRLF(_ text: String?) -> Bool {
    text?.contains("\r\n") == true
  }

  private static func normalizingLineEndings(_ text: String?) -> String? {
    text?.replacingOccurrences(of: "\r\n", with: "\n")
  }

  /// Removes `serverName` from a Claude Code or Claude Desktop config. Nil when there is nothing
  /// to remove. An empty `mcpServers` object is kept.
  static func removeJSON(existing: Data?, serverName: String) throws -> Data? {
    guard let existing, !existing.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) else {
      return nil
    }
    guard let parsed = try? JSONSerialization.jsonObject(with: existing) as? [String: Any] else {
      throw MCPClientInstallerError.notAJSONObject(file: "The existing config file")
    }
    guard var servers = parsed["mcpServers"] as? [String: Any], servers[serverName] != nil else {
      return nil
    }
    servers.removeValue(forKey: serverName)
    var root = parsed
    root["mcpServers"] = servers
    var data = try JSONSerialization.data(
      withJSONObject: root, options: [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys])
    data.append(0x0A)
    return data
  }

  /// Removes the `serverName` table and its sub-tables from a Codex config. Nil when no such
  /// table exists. Otherwise never two blank lines in a row, ending with one newline, or empty
  /// when nothing remains.
  static func removeCodex(existing: String?, serverName: String) -> String? {
    let crlf = usesCRLF(existing)
    let dropped = droppingServerTables(existing: normalizingLineEndings(existing), serverName: serverName)
    guard dropped.removed else { return nil }
    let collapsed = collapsingBlankLines(dropped.text)
    return crlf ? collapsed.replacingOccurrences(of: "\n", with: "\r\n") : collapsed
  }

  /// Drops `[mcp_servers.<name>]` and `[mcp_servers."<name>"]`, plus sub-tables of either form.
  private static func droppingServerTables(
    existing: String?, serverName: String
  ) -> (text: String, removed: Bool) {
    let header = "[mcp_servers.\(serverName)]"
    let quotedHeader = "[mcp_servers.\"\(serverName)\"]"
    let subPrefix = "[mcp_servers.\(serverName)."
    let quotedSubPrefix = "[mcp_servers.\"\(serverName)\"."
    let spaceAndCR = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\r"))
    var kept: [Substring] = []
    // Blank and comment lines seen while skipping our table. They may belong to the next table
    // (a comment directly above it), so they are emitted only if the next header is not ours.
    var pending: [Substring] = []
    var skipping = false
    var removed = false
    for line in (existing ?? "").split(separator: "\n", omittingEmptySubsequences: false) {
      let trimmed = line.trimmingCharacters(in: spaceAndCR)
      if trimmed.hasPrefix("[") {
        skipping = trimmed == header || trimmed == quotedHeader
          || trimmed.hasPrefix(subPrefix) || trimmed.hasPrefix(quotedSubPrefix)
        if skipping { removed = true } else { kept.append(contentsOf: pending) }
        pending.removeAll()
      } else if skipping, trimmed.isEmpty || trimmed.hasPrefix("#") {
        pending.append(line)
        continue
      } else if skipping {
        pending.removeAll()
      }
      if !skipping { kept.append(line) }
    }
    return (kept.joined(separator: "\n"), removed)
  }

  /// One blank line between sections, no leading or trailing blank lines, a single trailing
  /// newline. Empty when no content remains.
  private static func collapsingBlankLines(_ text: String) -> String {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    var collapsed: [String] = []
    var lastWasBlank = false
    for line in lines {
      let blank = line.trimmingCharacters(in: .whitespaces).isEmpty
      if blank {
        if lastWasBlank { continue }
        lastWasBlank = true
        collapsed.append("")
      } else {
        lastWasBlank = false
        collapsed.append(String(line))
      }
    }
    while collapsed.first?.isEmpty == true { collapsed.removeFirst() }
    while collapsed.last?.isEmpty == true { collapsed.removeLast() }
    if collapsed.isEmpty { return "" }
    return collapsed.joined(separator: "\n") + "\n"
  }

  // MARK: - Folder access and writing

  /// Asks for one-time access to `expected` and runs `body` inside the security scope.
  /// `MCPClientInstallerError.cancelled` means the user dismissed the panel.
  @MainActor
  private static func withFolderAccess<T>(
    expected: URL, message: String, _ body: () throws -> T
  ) throws -> T {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    panel.showsHiddenFiles = true
    panel.directoryURL = expected
    panel.prompt = String(localized: "Allow")
    panel.message = message

    guard panel.runModal() == .OK, let chosen = panel.url else {
      throw MCPClientInstallerError.cancelled
    }
    guard chosen.standardizedFileURL.path == expected.standardizedFileURL.path else {
      throw MCPClientInstallerError.wrongFolder(expected: expected.path)
    }

    let scoped = chosen.startAccessingSecurityScopedResource()
    defer { if scoped { chosen.stopAccessingSecurityScopedResource() } }
    return try body()
  }

  /// Replaces `file` with `output`. Copies the previous bytes to `<name>.whispershortcut-backup`
  /// (mode 0600) when the file already exists — that copy holds other apps' bearer tokens.
  /// `Data.write(.atomic)` replaces the inode, so an existing file gets its previous mode back
  /// and a new file is owner-only.
  /// A symlinked dotfile stays a symlink: the target is resolved first, and its mode, backup and
  /// replacement all belong to the target. The backup is written once and never overwritten, so it
  /// keeps the original file from before our first change.
  static func writeConfigAtomically(_ output: Data, to link: URL) throws {
    let fm = FileManager.default
    let file = link.resolvingSymlinksInPath()
    let existed = fm.fileExists(atPath: file.path)
    let originalPermissions: NSNumber? = existed
      ? (try fm.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)
      : nil
    if existed {
      let existingData = try Data(contentsOf: file)
      let backup = file.deletingLastPathComponent()
        .appendingPathComponent(file.lastPathComponent + ".whispershortcut-backup")
      if !fm.fileExists(atPath: backup.path) {
        try existingData.write(to: backup, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
      }
    }
    try output.write(to: file, options: .atomic)
    // A file we create is owner-only; an existing file gets its own mode back, never a looser one
    // read from anything but the real target.
    let permissions = originalPermissions ?? NSNumber(value: 0o600)
    try fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: file.path)
  }

  private static func logInstallFailure(_ error: Error, client: MCPClient) {
    if let installerError = error as? MCPClientInstallerError {
      switch installerError {
      case .cancelled, .wrongFolder:
        return
      case .notAJSONObject, .notUTF8, .runningFromTemporaryLocation:
        break
      }
    }
    DebugLogger.logError("MCP-INSTALL: \(client.displayName) failed: \(error.localizedDescription)")
  }

  // MARK: - Connect

  /// Asks for one-time folder access, merges the entry into the client's config and writes it.
  /// Returns the written file's URL. `MCPClientInstallerError.cancelled` means the user dismissed the panel.
  @MainActor
  static func connect(
    _ client: MCPClient, url: String, token: String, serverName: String, tokenKind: MCPTokenKind
  ) async -> Result<URL, Error> {
    let configFolder = client.configFolder
    // A client that never ran has no config folder yet (`~/.codex`), and a hidden folder that does
    // not exist can't be picked. Ask for the nearest folder that exists and create the rest inside it.
    var expected = configFolder
    while !FileManager.default.fileExists(atPath: expected.path), expected.pathComponents.count > 1 {
      expected = expected.deletingLastPathComponent()
    }
    let message =
      String(localized: "WhisperShortcut needs access to this folder once to add itself to \(client.displayName)'s settings. Click Allow.")
    do {
      let file = try withFolderAccess(expected: expected, message: message) { () -> URL in
        let fm = FileManager.default
        try fm.createDirectory(at: configFolder, withIntermediateDirectories: true)
        let file = configFolder.appendingPathComponent(client.configFileName)
        let existed = fm.fileExists(atPath: file.path)
        let existingData = existed ? try Data(contentsOf: file) : nil
        let output: Data
        switch client {
        case .claudeCode:
          output = try mergeClaudeCode(existing: existingData, serverName: serverName, url: url, token: token)
        case .claudeDesktop:
          output = try mergeClaudeDesktop(
            existing: existingData, serverName: serverName, url: url, token: token,
            executablePath: try stableExecutablePath(Bundle.main.executablePath))
        case .codex:
          let text = try codexText(from: existingData, file: file)
          output = Data(mergeCodex(existing: text, serverName: serverName, url: url, token: token).utf8)
        }
        try writeConfigAtomically(output, to: file)
        // Still inside the security scope: remember the folder so a later token change can be repaired.
        saveBookmark(for: expected, client: client, tokenKind: tokenKind)
        return file
      }
      DebugLogger.logSuccess("MCP-INSTALL: connected \(client.displayName) at \(file.path)")
      return .success(file)
    } catch {
      logInstallFailure(error, client: client)
      return .failure(error)
    }
  }

  /// Asks for one-time folder access and removes `serverName` from the client's config.
  /// `.success(false)` means there was nothing to remove. `.failure(MCPClientInstallerError.cancelled)`
  /// means the user dismissed the panel.
  @MainActor
  static func disconnect(_ client: MCPClient, serverName: String) async -> Result<Bool, Error> {
    let configFolder = client.configFolder
    guard FileManager.default.fileExists(atPath: configFolder.path) else {
      return .success(false)
    }
    let message =
      String(localized: "WhisperShortcut needs access to this folder once to remove itself from \(client.displayName)'s settings. Click Allow.")
    do {
      let removed = try withFolderAccess(expected: configFolder, message: message) { () -> Bool in
        let file = configFolder.appendingPathComponent(client.configFileName)
        guard FileManager.default.fileExists(atPath: file.path) else { return false }
        let existingData = try Data(contentsOf: file)
        let output: Data
        switch client {
        case .claudeCode, .claudeDesktop:
          guard let updated = try removeJSON(existing: existingData, serverName: serverName) else {
            return false
          }
          output = updated
        case .codex:
          let text = String(data: existingData, encoding: .utf8)
          guard let updated = removeCodex(existing: text, serverName: serverName) else {
            return false
          }
          output = Data(updated.utf8)
        }
        try writeConfigAtomically(output, to: file)
        DebugLogger.logSuccess("MCP-INSTALL: disconnected \(client.displayName) at \(file.path)")
        return true
      }
      clearBookmark(for: client)
      return .success(removed)
    } catch {
      logInstallFailure(error, client: client)
      return .failure(error)
    }
  }
}
