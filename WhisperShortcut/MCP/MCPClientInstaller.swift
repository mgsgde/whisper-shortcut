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

  var errorDescription: String? {
    switch self {
    case .cancelled:
      return String(localized: "Cancelled.")
    case .wrongFolder(let expected):
      return String(localized: "Please choose the folder \(expected) and click Allow.")
    case .notAJSONObject(let file):
      return String(localized: "\(file) is not valid JSON, so it was left untouched. Fix or remove the file and try again.")
    }
  }
}

enum MCPClientInstaller {

  // MARK: - Pure merge functions

  static func mergeClaudeCode(existing: Data?, serverName: String, url: String, token: String) throws -> Data {
    let entry: [String: Any] = [
      "type": "http",
      "url": url,
      "headers": ["Authorization": "Bearer \(token)"],
    ]
    return try mergeJSON(existing: existing, serverName: serverName, entry: entry)
  }

  static func mergeClaudeDesktop(
    existing: Data?, serverName: String, url: String, token: String, mcpRemotePackage: String
  ) throws -> Data {
    let entry: [String: Any] = [
      "command": "npx",
      "args": ["-y", mcpRemotePackage, url, "--header", "Authorization:${AUTH_HEADER}"],
      "env": ["AUTH_HEADER": "Bearer \(token)"],
    ]
    return try mergeJSON(existing: existing, serverName: serverName, entry: entry)
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
    let header = "[mcp_servers.\(serverName)]"
    let subPrefix = "[mcp_servers.\(serverName)."
    var kept: [Substring] = []
    var skipping = false
    for line in (existing ?? "").split(separator: "\n", omittingEmptySubsequences: false) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("[") {
        skipping = (trimmed == header || trimmed.hasPrefix(subPrefix))
      }
      if !skipping { kept.append(line) }
    }
    var text = kept.joined(separator: "\n")
    // Trim trailing blank lines left behind, then separate with exactly one blank line.
    while text.hasSuffix("\n\n") { text.removeLast() }
    if !text.isEmpty {
      if !text.hasSuffix("\n") { text += "\n" }
      text += "\n"
    }
    text += "\(header)\nurl = \"\(url)\"\nhttp_headers = { Authorization = \"Bearer \(token)\" }\n"
    return text
  }

  // MARK: - Connect

  /// Asks for one-time folder access, merges the entry into the client's config and writes it.
  /// Returns the written file's URL. `MCPClientInstallerError.cancelled` means the user dismissed the panel.
  @MainActor
  static func connect(
    _ client: MCPClient, url: String, token: String, mcpRemotePackage: String, serverName: String
  ) async -> Result<URL, Error> {
    let configFolder = client.configFolder
    // A client that never ran has no config folder yet (`~/.codex`), and a hidden folder that does
    // not exist can't be picked. Ask for the nearest folder that exists and create the rest inside it.
    var expected = configFolder
    while !FileManager.default.fileExists(atPath: expected.path), expected.pathComponents.count > 1 {
      expected = expected.deletingLastPathComponent()
    }
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    panel.showsHiddenFiles = true
    panel.directoryURL = expected
    panel.prompt = String(localized: "Allow")
    panel.message =
      String(localized: "WhisperShortcut needs access to this folder once to add itself to \(client.displayName)'s settings. Click Allow.")

    guard panel.runModal() == .OK, let chosen = panel.url else {
      return .failure(MCPClientInstallerError.cancelled)
    }
    guard chosen.standardizedFileURL.path == expected.standardizedFileURL.path else {
      return .failure(MCPClientInstallerError.wrongFolder(expected: expected.path))
    }

    let scoped = chosen.startAccessingSecurityScopedResource()
    defer { if scoped { chosen.stopAccessingSecurityScopedResource() } }

    do {
      let fm = FileManager.default
      try fm.createDirectory(at: configFolder, withIntermediateDirectories: true)
      let file = configFolder.appendingPathComponent(client.configFileName)
      let existed = fm.fileExists(atPath: file.path)
      let existingData = existed ? try Data(contentsOf: file) : nil

      if let existingData {
        let backup = configFolder.appendingPathComponent(client.configFileName + ".whispershortcut-backup")
        try existingData.write(to: backup, options: .atomic)
      }

      let output: Data
      switch client {
      case .claudeCode:
        output = try mergeClaudeCode(existing: existingData, serverName: serverName, url: url, token: token)
      case .claudeDesktop:
        output = try mergeClaudeDesktop(
          existing: existingData, serverName: serverName, url: url, token: token,
          mcpRemotePackage: mcpRemotePackage)
      case .codex:
        let text = existingData.flatMap { String(data: $0, encoding: .utf8) }
        output = Data(mergeCodex(existing: text, serverName: serverName, url: url, token: token).utf8)
      }
      try output.write(to: file, options: .atomic)
      DebugLogger.logSuccess("MCP-INSTALL: connected \(client.displayName) at \(file.path)")
      return .success(file)
    } catch {
      DebugLogger.logError("MCP-INSTALL: \(client.displayName) failed: \(error.localizedDescription)")
      return .failure(error)
    }
  }
}
