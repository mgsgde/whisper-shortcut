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

  @Test("Claude Desktop: a missing, translocated or disk-image executable is refused")
  func desktopRefusesTemporaryExecutable() throws {
    let home = "/Users/anna"
    let ok = "/Applications/WhisperShortcut.app/Contents/MacOS/WhisperShortcut"
    #expect(try MCPClientInstaller.stableExecutablePath(ok, homeDirectory: home) == ok)
    for bad in [
      nil, "",
      "/private/var/folders/ab/T/AppTranslocation/UUID/d/WhisperShortcut.app/Contents/MacOS/WhisperShortcut",
      "/Volumes/WhisperShortcut/WhisperShortcut.app/Contents/MacOS/WhisperShortcut",
    ] as [String?] {
      #expect(throws: MCPClientInstallerError.self) {
        try MCPClientInstaller.stableExecutablePath(bad, homeDirectory: home)
      }
    }
    #expect(MCPClientInstallerError.runningFromTemporaryLocation.errorDescription?.hasPrefix("Move WhisperShortcut to your Applications folder first") == true)
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

  // MARK: - Hardening (R197)

  private func tempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("mcp-installer-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  private func mode(_ url: URL) throws -> Int {
    let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
    return (attrs[.posixPermissions] as? NSNumber)?.intValue ?? -1
  }

  @Test("Writing through a symlink keeps the link, edits the target and keeps the target's mode")
  func writeThroughSymlink() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let target = dir.appendingPathComponent("real-config.toml")
    let link = dir.appendingPathComponent("config.toml")
    try Data("old".utf8).write(to: target)
    try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: target.path)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

    try MCPClientInstaller.writeConfigAtomically(Data("new".utf8), to: link)

    #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil)
    #expect(try String(contentsOf: target, encoding: .utf8) == "new")
    #expect(try mode(target) == 0o640)
    // The backup sits next to the target and is owner-only.
    let backup = dir.appendingPathComponent("real-config.toml.whispershortcut-backup")
    #expect(try String(contentsOf: backup, encoding: .utf8) == "old")
    #expect(try mode(backup) == 0o600)
  }

  @Test("A file we create is owner-only")
  func newFileIsOwnerOnly() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("fresh.json")
    try MCPClientInstaller.writeConfigAtomically(Data("{}".utf8), to: file)
    #expect(try mode(file) == 0o600)
  }

  @Test("The backup keeps the original across repeated writes")
  func backupWrittenOnce() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("config.toml")
    try Data("original".utf8).write(to: file)
    try MCPClientInstaller.writeConfigAtomically(Data("second".utf8), to: file)
    try MCPClientInstaller.writeConfigAtomically(Data("third".utf8), to: file)
    let backup = dir.appendingPathComponent("config.toml.whispershortcut-backup")
    #expect(try String(contentsOf: backup, encoding: .utf8) == "original")
    #expect(try String(contentsOf: file, encoding: .utf8) == "third")
  }

  @Test("Codex with CRLF line endings: the old table is replaced and CRLF is kept")
  func codexCRLF() {
    let existing = "model = \"gpt\"\r\n\r\n[mcp_servers.whisper-shortcut]\r\nurl = \"old\"\r\n\r\n[mcp_servers.other]\r\ncommand = \"x\"\r\n"
    let out = MCPClientInstaller.mergeCodex(existing: existing, serverName: name, url: url, token: token)
    #expect(!out.contains("old"))
    #expect(out.components(separatedBy: "[mcp_servers.whisper-shortcut]").count == 2)
    #expect(out.contains("[mcp_servers.other]\r\ncommand = \"x\"\r\n"))
    // Every newline is CRLF.
    #expect(!out.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
    let removed = MCPClientInstaller.removeCodex(existing: existing, serverName: name)
    #expect(removed == "model = \"gpt\"\r\n\r\n[mcp_servers.other]\r\ncommand = \"x\"\r\n")
  }

  @Test("Codex: a comment directly above the next table survives; comments inside ours go")
  func codexKeepsCommentAboveNextTable() {
    let existing = """
      [mcp_servers.whisper-shortcut]
      # our own note
      url = "old"

      # about the other server
      [mcp_servers.other]
      command = "x"

      """
    let removed = MCPClientInstaller.removeCodex(existing: existing, serverName: name)
    #expect(removed == "# about the other server\n[mcp_servers.other]\ncommand = \"x\"\n")
    let merged = MCPClientInstaller.mergeCodex(existing: existing, serverName: name, url: url, token: token)
    #expect(merged.contains("# about the other server\n[mcp_servers.other]"))
    #expect(!merged.contains("our own note"))
  }

  @Test("Codex: a config that is not UTF-8 is refused, not replaced")
  func codexNotUTF8() throws {
    let file = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/config.toml")
    #expect(try MCPClientInstaller.codexText(from: nil, file: file) == nil)
    #expect(try MCPClientInstaller.codexText(from: Data("a = 1".utf8), file: file) == "a = 1")
    #expect(throws: MCPClientInstallerError.self) {
      try MCPClientInstaller.codexText(from: Data([0xFF, 0xFE, 0x00, 0xD8]), file: file)
    }
    do {
      _ = try MCPClientInstaller.codexText(from: Data([0xFF, 0xFE, 0x00, 0xD8]), file: file)
      Issue.record("expected notUTF8")
    } catch {
      #expect((error.localizedDescription).contains("~/.codex/config.toml"))
    }
  }

  // MARK: - repairedConfig

  private let readTok = "readTok"
  private let writeTok = "writeTok"

  private func repair(
    _ client: MCPClient, _ data: Data, url customURL: String? = nil, kind: MCPTokenKind = .write,
    exe: String = "/new/exe"
  ) -> Data? {
    MCPClientInstaller.repairedConfig(
      client: client, existing: data, serverName: name, url: customURL ?? url,
      readToken: readTok, writeToken: writeTok, tokenKind: kind, executablePath: exe)
  }

  private func codeConfig(token: String, url customURL: String? = nil, extra: Bool = true) throws -> Data {
    var existing: Data? = nil
    if extra { existing = Data(#"{"theme":"dark","mcpServers":{"other":{"url":"x"}}}"#.utf8) }
    return try MCPClientInstaller.mergeClaudeCode(
      existing: existing, serverName: name, url: customURL ?? url, token: token)
  }

  @Test("Repair: stale Claude Code token is rewritten with the write token, other keys kept")
  func repairStaleClaudeCode() throws {
    let out = try #require(repair(.claudeCode, try codeConfig(token: "old")))
    let root = try object(out)
    #expect(root["theme"] as? String == "dark")
    let servers = try #require(root["mcpServers"] as? [String: Any])
    #expect(servers["other"] != nil)
    let entry = try #require(servers[name] as? [String: Any])
    #expect((entry["headers"] as? [String: String])?["Authorization"] == "Bearer writeTok")
  }

  @Test("Repair: read kind writes the read token")
  func repairReadKind() throws {
    let out = try #require(repair(.claudeCode, try codeConfig(token: "old"), kind: .read))
    #expect(String(decoding: out, as: UTF8.self).contains("Bearer readTok"))
  }

  @Test("Repair: a token equal to the read or write token is left alone")
  func repairCurrentToken() throws {
    #expect(repair(.claudeCode, try codeConfig(token: readTok)) == nil)
    #expect(repair(.claudeCode, try codeConfig(token: writeTok)) == nil)
  }

  @Test("Repair: no entry for our server name means nothing to do")
  func repairNoEntry() throws {
    #expect(repair(.claudeCode, Data(#"{"mcpServers":{"other":{"url":"x"}}}"#.utf8)) == nil)
    #expect(repair(.claudeCode, Data("{}".utf8)) == nil)
    #expect(repair(.codex, Data("[mcp_servers.other]\nurl = \"x\"\n".utf8)) == nil)
  }

  @Test("Repair: an entry pointing at another url is left alone")
  func repairForeignURL() throws {
    #expect(repair(.claudeCode, try codeConfig(token: "old", url: "http://127.0.0.1:9999/mcp")) == nil)
  }

  @Test("Repair: invalid JSON is never touched")
  func repairInvalidJSON() {
    #expect(repair(.claudeCode, Data("{ not json".utf8)) == nil)
    #expect(repair(.claudeDesktop, Data("{ not json".utf8)) == nil)
  }

  @Test("Repair: Claude Desktop keeps an existing command and falls back to the current executable")
  func repairDesktopCommand() throws {
    func config(command: String) throws -> Data {
      try MCPClientInstaller.mergeClaudeDesktop(
        existing: nil, serverName: name, url: url, token: "old", executablePath: command)
    }
    func command(_ data: Data) throws -> String? {
      let servers = try #require(try object(data)["mcpServers"] as? [String: Any])
      return (servers[name] as? [String: Any])?["command"] as? String
    }
    let kept = try #require(repair(.claudeDesktop, try config(command: "/bin/sh")))
    #expect(try command(kept) == "/bin/sh")
    #expect(String(decoding: kept, as: UTF8.self).contains("Bearer writeTok"))
    let replaced = try #require(repair(.claudeDesktop, try config(command: "/does/not/exist")))
    #expect(try command(replaced) == "/new/exe")
    #expect(repair(.claudeDesktop, try MCPClientInstaller.mergeClaudeDesktop(
      existing: nil, serverName: name, url: url, token: readTok, executablePath: "/bin/sh")) == nil)
  }

  @Test("Repair: stale Codex token is rewritten, foreign url and current token are not")
  func repairCodex() throws {
    let stale = MCPClientInstaller.mergeCodex(
      existing: "model = \"x\"\n", serverName: name, url: url, token: "old")
    let out = try #require(repair(.codex, Data(stale.utf8)))
    let text = String(decoding: out, as: UTF8.self)
    #expect(text.contains("model = \"x\""))
    #expect(text.contains("Bearer writeTok"))
    #expect(!text.contains("Bearer old"))
    #expect(repair(.codex, Data(stale.utf8), url: "http://127.0.0.1:1/mcp") == nil)
    let current = MCPClientInstaller.mergeCodex(existing: nil, serverName: name, url: url, token: readTok)
    #expect(repair(.codex, Data(current.utf8)) == nil)
  }
}
