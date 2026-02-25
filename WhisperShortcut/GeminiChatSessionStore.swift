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

  init(id: UUID = UUID(), lastUpdated: Date = Date(), messages: [ChatMessage] = []) {
    self.id = id
    self.lastUpdated = lastUpdated
    self.messages = messages
  }
}

// MARK: - Store

class GeminiChatSessionStore {
  static let shared = GeminiChatSessionStore()

  private let fileName = "gemini-chat-session.json"

  private init() {}

  private var fileURL: URL {
    AppSupportPaths.whisperShortcutApplicationSupportURL()
      .appendingPathComponent(fileName)
  }

  func load() -> ChatSession {
    guard let data = try? Data(contentsOf: fileURL),
      let session = try? JSONDecoder().decode(ChatSession.self, from: data)
    else {
      return ChatSession()
    }
    return session
  }

  func save(_ session: ChatSession) {
    let dir = AppSupportPaths.whisperShortcutApplicationSupportURL()
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    if let data = try? JSONEncoder().encode(session) {
      try? data.write(to: fileURL, options: .atomic)
    }
  }
}
