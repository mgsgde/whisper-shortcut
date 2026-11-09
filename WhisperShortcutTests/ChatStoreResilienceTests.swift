import Foundation
import Testing
@testable import WhisperShortcut_AppStore

/// R216: one bad field or one unreadable file must never cost the user their chat history.
@MainActor
@Suite("Chat store resilience")
struct ChatStoreResilienceTests {

  private static func paths(_ label: String) -> (scope: String, url: URL) {
    let scope = "resilience-\(label)-\(UUID().uuidString)"
    let url = AppSupportPaths.whisperShortcutApplicationSupportURL()
      .appendingPathComponent("gemini-sessions-\(scope).json")
    return (scope, url)
  }

  private static func corruptBackups(for scope: String) -> [URL] {
    let dir = AppSupportPaths.whisperShortcutApplicationSupportURL()
    let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    return names
      .filter { $0.hasPrefix("gemini-sessions-\(scope).corrupt-") }
      .map { dir.appendingPathComponent($0) }
  }

  @Test("an unknown thinking level decodes as .default")
  func unknownThinkingLevel() throws {
    let level = try JSONDecoder().decode(ThinkingLevel.self, from: Data("\"ultra\"".utf8))
    #expect(level == .default)
    #expect(try JSONDecoder().decode(ThinkingLevel.self, from: Data("\"high\"".utf8)) == .high)
  }

  @Test("one undecodable session is skipped, the others survive, the original is backed up")
  func badSessionSkipped() throws {
    let (scope, url) = Self.paths("lenient")
    defer {
      try? FileManager.default.removeItem(at: url)
      Self.corruptBackups(for: scope).forEach { try? FileManager.default.removeItem(at: $0) }
    }
    let good1 = ChatSession(messages: [ChatMessage(role: .user, content: "one")])
    let good2 = ChatSession(messages: [ChatMessage(role: .user, content: "two")])
    let bad = ChatSession(messages: [ChatMessage(role: .user, content: "bad")])
    let enc = JSONEncoder()
    func obj(_ s: ChatSession) throws -> [String: Any] {
      try JSONSerialization.jsonObject(with: enc.encode(s)) as! [String: Any]
    }
    var badObj = try obj(bad)
    badObj["messages"] = "not an array"
    let root: [String: Any] = [
      "currentSessionId": good1.id.uuidString,
      "sessions": [try obj(good1), badObj, try obj(good2)],
    ]
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: root).write(to: url)

    let store = ChatSessionStore(scope: scope)
    #expect(store.session(by: good1.id) != nil)
    #expect(store.session(by: good2.id) != nil)
    #expect(store.session(by: bad.id) == nil)
    #expect(Self.corruptBackups(for: scope).count == 1)
  }

  @Test("an unreadable file is never overwritten by a default session")
  func unreadableFileKept() throws {
    let (scope, url) = Self.paths("unreadable")
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
      try? FileManager.default.removeItem(at: url)
    }
    let original = Data("{\"keep\":\"me\"}".utf8)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try original.write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)

    let store = ChatSessionStore(scope: scope)
    var session = store.load()
    session.messages = [ChatMessage(role: .user, content: "would overwrite")]
    store.save(session)
    store.flushToDisk()

    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
    #expect(try Data(contentsOf: url) == original)
  }
}
