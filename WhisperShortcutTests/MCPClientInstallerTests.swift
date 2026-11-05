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
        existing: Data("not json".utf8), serverName: name, url: url, token: token,
        executablePath: "/Applications/WhisperShortcut.app/Contents/MacOS/WhisperShortcut")
    }
  }

  @Test("Claude Desktop: entry runs this app as the stdio bridge")
  func claudeDesktopShape() throws {
    let executable = "/Applications/WhisperShortcut.app/Contents/MacOS/WhisperShortcut"
    let existing = #"{"mcpServers": {"other": {"command": "x"}}, "theme": "dark"}"#
    let out = try MCPClientInstaller.mergeClaudeDesktop(
      existing: Data(existing.utf8), serverName: name, url: url, token: token, executablePath: executable)
    let root = try object(out)
    #expect(root["theme"] as? String == "dark")
    let servers = try #require(root["mcpServers"] as? [String: Any])
    #expect(servers["other"] != nil)
    let entry = try #require(servers[name] as? [String: Any])
    #expect(entry["command"] as? String == executable)
    #expect(entry["args"] as? [String] == ["--mcp-stdio"])
    let env = try #require(entry["env"] as? [String: String])
    #expect(env["WHISPERSHORTCUT_MCP_URL"] == url)
    #expect(env["WHISPERSHORTCUT_MCP_AUTH"] == "Bearer tok123")
    #expect(String(decoding: out, as: UTF8.self).contains("http://127.0.0.1:47823/mcp"))
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

  @Test("Codex: a quoted server table is dropped, leaving exactly one whisper-shortcut table")
  func codexQuotedHeader() {
    let existing = """
      model = "gpt"

      [mcp_servers."whisper-shortcut"]
      url = "old"

      [mcp_servers."whisper-shortcut".env]
      A = "b"

      [mcp_servers.other]
      command = "x"

      """
    let out = MCPClientInstaller.mergeCodex(existing: existing, serverName: name, url: url, token: token)
    #expect(!out.contains("old"))
    #expect(!out.contains("A = \"b\""))
    #expect(!out.contains("[mcp_servers.\"whisper-shortcut\"]"))
    #expect(out.contains("[mcp_servers.other]\ncommand = \"x\"\n"))
    #expect(out.hasSuffix(codexBlock))
    #expect(out.components(separatedBy: "whisper-shortcut").count == 2)
  }

  @Test("removeJSON: drops our entry and keeps other servers and top-level keys")
  func removeJSONKeepsOthers() throws {
    let existing = """
      {"numStartups": 7, "projects": {"/a": {"x": 1}},
       "mcpServers": {"other": {"command": "foo", "url": "http://127.0.0.1/x"},
                      "whisper-shortcut": {"url": "old"}}}
      """
    let out = try #require(
      try MCPClientInstaller.removeJSON(existing: Data(existing.utf8), serverName: name))
    let root = try object(out)
    #expect(root["numStartups"] as? Int == 7)
    #expect((root["projects"] as? [String: Any])?["/a"] != nil)
    let servers = try #require(root["mcpServers"] as? [String: Any])
    #expect(servers[name] == nil)
    let other = try #require(servers["other"] as? [String: Any])
    #expect(other["command"] as? String == "foo")
    #expect(other["url"] as? String == "http://127.0.0.1/x")
    let text = String(decoding: out, as: UTF8.self)
    #expect(text.contains("http://127.0.0.1/x"))
    #expect(text.hasSuffix("\n"))
  }

  @Test("removeJSON: an absent entry, or no mcpServers, removes nothing")
  func removeJSONAbsent() throws {
    let otherOnly = #"{"mcpServers": {"other": {"command": "foo"}}, "theme": "dark"}"#
    #expect(try MCPClientInstaller.removeJSON(existing: Data(otherOnly.utf8), serverName: name) == nil)
    #expect(try MCPClientInstaller.removeJSON(existing: Data(#"{"theme": "dark"}"#.utf8), serverName: name) == nil)
  }

  @Test("removeJSON: nil and blank input remove nothing")
  func removeJSONBlank() throws {
    #expect(try MCPClientInstaller.removeJSON(existing: nil, serverName: name) == nil)
    #expect(try MCPClientInstaller.removeJSON(existing: Data(), serverName: name) == nil)
    #expect(try MCPClientInstaller.removeJSON(existing: Data("  \n\t".utf8), serverName: name) == nil)
  }

  @Test("removeJSON: non-object JSON is refused")
  func removeJSONNonObject() {
    #expect(throws: (any Error).self) {
      try MCPClientInstaller.removeJSON(existing: Data("[1,2]".utf8), serverName: name)
    }
    #expect(throws: (any Error).self) {
      try MCPClientInstaller.removeJSON(existing: Data("not json".utf8), serverName: name)
    }
  }

  @Test("removeJSON: dropping the last server leaves an empty mcpServers object")
  func removeJSONLastEntry() throws {
    let existing = #"{"theme": "dark", "mcpServers": {"whisper-shortcut": {"url": "old"}}}"#
    let out = try #require(
      try MCPClientInstaller.removeJSON(existing: Data(existing.utf8), serverName: name))
    let root = try object(out)
    let servers = try #require(root["mcpServers"] as? [String: Any])
    #expect(servers.isEmpty)
    #expect(root["theme"] as? String == "dark")
    let expectedRoot: [String: Any] = ["mcpServers": [String: Any](), "theme": "dark"]
    var expected = try JSONSerialization.data(
      withJSONObject: expectedRoot, options: [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys])
    expected.append(0x0A)
    #expect(out == expected)
  }

  @Test("removeCodex: table and sub-table go, other tables stay, no double blank lines")
  func removeCodexTables() {
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
    let expected = """
      model = "gpt"

      [mcp_servers.after]
      command = "y"

      [profiles.x]
      k = 1

      """
    let out = MCPClientInstaller.removeCodex(existing: existing, serverName: name)
    #expect(out == expected)
    #expect(out?.contains("\n\n\n") == false)
    #expect(out?.hasSuffix("\n") == true)
    #expect(out?.hasSuffix("\n\n") == false)

    let atEnd = """
      model = "gpt"

      [mcp_servers.other]
      command = "x"

      [mcp_servers.whisper-shortcut]
      url = "old"
      """
    #expect(
      MCPClientInstaller.removeCodex(existing: atEnd, serverName: name)
        == "model = \"gpt\"\n\n[mcp_servers.other]\ncommand = \"x\"\n")
  }

  @Test("removeCodex: a quoted server table and its sub-table are dropped")
  func removeCodexQuotedHeader() {
    let existing = """
      model = "gpt"

      [mcp_servers."whisper-shortcut"]
      url = "old"

      [mcp_servers."whisper-shortcut".env]
      A = "b"

      [mcp_servers.other]
      command = "x"
      """
    let expected = """
      model = "gpt"

      [mcp_servers.other]
      command = "x"

      """
    #expect(MCPClientInstaller.removeCodex(existing: existing, serverName: name) == expected)
  }

  @Test("removeCodex: no matching table returns nil; only our table returns empty")
  func removeCodexAbsentOrOnlyOurs() {
    #expect(MCPClientInstaller.removeCodex(existing: nil, serverName: name) == nil)
    #expect(MCPClientInstaller.removeCodex(existing: "", serverName: name) == nil)
    let other = "model = \"gpt\"\n\n[mcp_servers.other]\ncommand = \"x\"\n"
    #expect(MCPClientInstaller.removeCodex(existing: other, serverName: name) == nil)
    let only = """
      [mcp_servers.whisper-shortcut]
      url = "old"

      [mcp_servers.whisper-shortcut.env]
      A = "b"
      """
    #expect(MCPClientInstaller.removeCodex(existing: only, serverName: name) == "")
  }
}
