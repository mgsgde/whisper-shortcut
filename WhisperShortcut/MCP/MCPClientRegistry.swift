import Foundation

/// An MCP client that has connected to the local server (an AI app's `initialize` call),
/// remembered so Settings can show e.g. "Claude Code connected with write access · 2 min ago".
struct MCPConnectedClient: Codable, Equatable, Identifiable {
  /// `clientInfo.name` as the client sent it, e.g. "claude-code".
  let name: String
  /// `clientInfo.version` as sent, "" if missing.
  var version: String
  /// "read" or "write".
  var access: String
  var lastConnected: Date

  var id: String { name }
}

/// Clients that connected to the local MCP server, most recently seen first. Persisted as JSON
/// under `UserDefaultsKeys.mcpConnectedClients` so Settings can show them without the server
/// needing to be running. Not a secret: only `clientInfo.name`/`version` and access level, never
/// request content.
final class MCPClientRegistry: ObservableObject {
  static let shared = MCPClientRegistry()

  static let maxClients = 10
  static let maxNameLength = 64

  /// Newest `lastConnected` first. Mutated and published on main.
  @Published private(set) var clients: [MCPConnectedClient] = []

  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    self.clients = Self.load(defaults)
  }

  private static func decoder() -> JSONDecoder {
    let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
  }

  private static func load(_ defaults: UserDefaults) -> [MCPConnectedClient] {
    guard let data = defaults.data(forKey: UserDefaultsKeys.mcpConnectedClients) else { return [] }
    return (try? decoder().decode([MCPConnectedClient].self, from: data)) ?? []
  }

  private func persist() {
    let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
    if let data = try? e.encode(clients) {
      defaults.set(data, forKey: UserDefaultsKeys.mcpConnectedClients)
    }
  }

  /// Upserts the client by name: updates version/access/lastConnected if it already exists,
  /// otherwise inserts it. Re-sorts newest first, keeps at most `maxClients` (drops the oldest),
  /// and persists. Callable from any thread.
  func record(name: String, version: String, access: MCPAccess, at date: Date = Date()) {
    let trimmedName = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxNameLength))
    guard !trimmedName.isEmpty else { return }
    let accessString = access == .write ? "write" : "read"

    func apply() {
      var updated = clients
      if let index = updated.firstIndex(where: { $0.name == trimmedName }) {
        updated[index].version = version
        updated[index].access = accessString
        updated[index].lastConnected = date
      } else {
        updated.append(
          MCPConnectedClient(name: trimmedName, version: version, access: accessString, lastConnected: date))
      }
      updated.sort { $0.lastConnected > $1.lastConnected }
      if updated.count > Self.maxClients { updated.removeLast(updated.count - Self.maxClients) }
      clients = updated
      persist()
    }

    if Thread.isMainThread {
      apply()
    } else {
      DispatchQueue.main.async { apply() }
    }
  }

  /// First client whose lowercased name has the given prefix (lowercased), e.g. "claude-code".
  func client(matching prefix: String) -> MCPConnectedClient? {
    let lowered = prefix.lowercased()
    return clients.first { $0.name.lowercased().hasPrefix(lowered) }
  }

  func forgetAll() {
    func apply() {
      clients = []
      persist()
    }
    if Thread.isMainThread {
      apply()
    } else {
      DispatchQueue.main.async { apply() }
    }
  }
}
