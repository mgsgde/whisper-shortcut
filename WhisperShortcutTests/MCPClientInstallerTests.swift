import Foundation
import Testing

@testable import WhisperShortcut_AppStore

/// The installer edits config files that belong to other apps. Merging must add our entry and
/// leave everything else alone, and must refuse to touch a file it cannot parse.
@Suite("MCP client installer")
struct MCPClientInstallerTests {

  private let name = "whisper-shortcut"
  private let url = "http://127.0.0.1:47823/mcp"
  private let token = "tok123"

  private func object(_ data: Data) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  @Test("Claude Code: nil and empty input produce a fresh config")
  func claudeCodeFresh() throws {
    for existing in [nil, Data(), Data("  \n".utf8)] as [Data?] {
      let out = try MCPClientInstaller.mergeClaudeCode(existing: existing, serverName: name, url: url, token: token)
      let servers = try #require(try object(out)["mcpServers"] as? [String: Any])
      let entry = try #require(servers[name] as? [String: Any])
      #expect(entry["type"] as? String == "http")
      #expect(entry["url"] as? String == url)
      #expect((entry["headers"] as? [String: String])?["Authorization"] == "Bearer tok123")
      #expect(String(decoding: out, as: UTF8.self).hasSuffix("\n"))
      // Slashes in the URL must not be escaped.
      #expect(String(decoding: out, as: UTF8.self).contains("http://127.0.0.1:47823/mcp"))
    }
  }

  @Test("Claude Code: other keys and other servers survive; an older entry is replaced")
  func claudeCodeKeepsOthers() throws {
    let existing = """
      {"numStartups": 7, "projects": {"/a": {"x": 1}},
       "mcpServers": {"other": {"command": "foo"}, "whisper-shortcut": {"url": "old"}}}
      """
    let out = try MCPClientInstaller.mergeClaudeCode(
      existing: Data(existing.utf8), serverName: name, url: url, token: token)
    let root = try object(out)
    #expect(root["numStartups"] as? Int == 7)
    #expect((root["projects"] as? [String: Any])?["/a"] != nil)
    let servers = try #require(root["mcpServers"] as? [String: Any])
    #expect((servers["other"] as? [String: Any])?["command"] as? String == "foo")
    let entry = try #require(servers[name] as? [String: Any])
    #expect(entry["url"] as? String == url)
  }

  @Test("Non-object JSON is never overwritten")
  func nonObjectThrows() {
    #expect(throws: (any Error).self) {
      try MCPClientInstaller.mergeClaudeCode(existing: Data("[1,2]".utf8), serverName: name, url: url, token: token)
    }
    #expect(throws: (any Error).self) {
      try MCPClientInstaller.mergeClaudeDesktop(
        existing: Data("not json".utf8), serverName: name, url: url, token: token, mcpRemotePackage: "mcp-remote")
    }
  }

  @Test("Claude Desktop: entry uses npx mcp-remote with the literal AUTH_HEADER placeholder")
  func claudeDesktopShape() throws {
    let existing = #"{"mcpServers": {"other": {"command": "x"}}, "theme": "dark"}"#
    let out = try MCPClientInstaller.mergeClaudeDesktop(
      existing: Data(existing.utf8), serverName: name, url: url, token: token, mcpRemotePackage: "mcp-remote@0.1.0")
    let root = try object(out)
    #expect(root["theme"] as? String == "dark")
    let servers = try #require(root["mcpServers"] as? [String: Any])
    #expect(servers["other"] != nil)
    let entry = try #require(servers[name] as? [String: Any])
    #expect(entry["command"] as? String == "npx")
    #expect(
      entry["args"] as? [String] == ["-y", "mcp-remote@0.1.0", url, "--header", "Authorization:${AUTH_HEADER}"])
    #expect((entry["env"] as? [String: String])?["AUTH_HEADER"] == "Bearer tok123")
  }

  private var codexBlock: String {
    "[mcp_servers.whisper-shortcut]\nurl = \"\(url)\"\nhttp_headers = { Authorization = \"Bearer tok123\" }\n"
  }

  @Test("Codex: append to nil and empty")
  func codexEmpty() {
    #expect(MCPClientInstaller.mergeCodex(existing: nil, serverName: name, url: url, token: token) == codexBlock)
    #expect(MCPClientInstaller.mergeCodex(existing: "", serverName: name, url: url, token: token) == codexBlock)
  }

  @Test("Codex: append after other tables, content unchanged")
  func codexAppend() {
    let existing = "model = \"gpt\"\n\n[mcp_servers.other]\ncommand = \"x\"\n"
    let out = MCPClientInstaller.mergeCodex(existing: existing, serverName: name, url: url, token: token)
    #expect(out == existing + "\n" + codexBlock)
  }

  @Test("Codex: replaces the table and its subtable, keeps what follows")
  func codexReplace() {
    let existing = """
      model = "gpt"

      [mcp_servers.whisper-shortcut]
      url = "old"

      [mcp_servers.whisper-shortcut.env]
      A = "b"

      [mcp_servers.after]
      command = "y"

      [profiles.x]
      k = 1

      """
    let out = MCPClientInstaller.mergeCodex(existing: existing, serverName: name, url: url, token: token)
    #expect(!out.contains("old"))
    #expect(!out.contains("A = \"b\""))
    #expect(out.contains("[mcp_servers.after]\ncommand = \"y\"\n\n[profiles.x]\nk = 1\n"))
    #expect(out.hasPrefix("model = \"gpt\"\n"))
    #expect(out.hasSuffix(codexBlock))
    #expect(out.components(separatedBy: "[mcp_servers.whisper-shortcut]").count == 2)
  }
}
