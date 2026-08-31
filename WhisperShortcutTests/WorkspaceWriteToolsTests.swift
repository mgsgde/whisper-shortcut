import Foundation
import Testing

@testable import WhisperShortcut_AppStore

/// Pins the safety contract of the chat's write tools.
///
/// Every test here is about something the user could otherwise lose without noticing: a file
/// silently replaced, the wrong one of several identical lines edited, a write landing in `.git`,
/// or a path escaping the folder they actually shared. The happy paths are cheap to add on top;
/// the refusals are the point.
@Suite("Workspace write tools", .serialized)
struct WorkspaceWriteToolsTests {

  // MARK: - Helpers

  private struct Fixture {
    let root: URL
    var backups: [String] = []
    private let previousWriteAccess: Bool

    init(writeEnabled: Bool = true) throws {
      root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("wswrite-\(UUID().uuidString)")
        .appendingPathComponent("workspace")
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      previousWriteAccess = WorkspaceWriteAccess.isEnabled
      WorkspaceWriteAccess.isEnabled = writeEnabled
    }

    func write(_ relativePath: String, _ contents: String) throws {
      let url = root.appendingPathComponent(relativePath)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    func read(_ relativePath: String) -> String? {
      try? String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    var scope: WorkspaceFolders.Scope {
      .explicit([WorkspaceFolders.Root(url: root, displayPath: root.path)])
    }

    /// Removes the temp tree and any backups the run produced, so the app's real backup folder
    /// does not accumulate test debris. Restores the write-access toggle so a test cannot leak
    /// "on" into the developer's running app.
    func cleanUp(backups: [String] = []) {
      WorkspaceWriteAccess.isEnabled = previousWriteAccess
      try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
      for path in backups { try? FileManager.default.removeItem(atPath: path) }
    }
  }

  private static func backupPath(_ result: [String: Any]) -> String? {
    result["previous_version_backed_up_to"] as? String
  }

  // MARK: - Creating

  @Test("A new file is created, with its parent directories")
  func createsFileAndParents() throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }

    let result = WorkspaceWriteTools.writeTextFile(
      path: "journal/2026/notes.md", content: "hello", overwrite: false, scope: fixture.scope)

    #expect(result["ok"] as? Bool == true)
    #expect(result["created"] as? Bool == true)
    #expect(fixture.read("journal/2026/notes.md") == "hello")
  }

  @Test("An existing file is never replaced without overwrite")
  func refusesSilentOverwrite() throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    try fixture.write("notes.md", "the user's text")

    let result = WorkspaceWriteTools.writeTextFile(
      path: "notes.md", content: "the model's text", overwrite: false, scope: fixture.scope)

    #expect(result["error"] != nil)
    #expect(fixture.read("notes.md") == "the user's text")
  }

  @Test("Overwriting keeps the previous content in a backup")
  func overwriteBacksUpPreviousContent() throws {
    let fixture = try Fixture()
    var backups: [String] = []
    defer { fixture.cleanUp(backups: backups) }
    try fixture.write("notes.md", "ORIGINAL-TEXT")

    let result = WorkspaceWriteTools.writeTextFile(
      path: "notes.md", content: "REPLACEMENT", overwrite: true, scope: fixture.scope)
    if let backup = Self.backupPath(result) { backups.append(backup) }

    #expect(result["ok"] as? Bool == true)
    #expect(fixture.read("notes.md") == "REPLACEMENT")
    let backup = try #require(Self.backupPath(result))
    #expect(try String(contentsOfFile: backup, encoding: .utf8) == "ORIGINAL-TEXT")
  }

  // MARK: - Appending

  @Test("Appending adds a separating newline and keeps what was there")
  func appendsWithSeparator() throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    try fixture.write("todo.md", "- first")

    let result = WorkspaceWriteTools.appendToFile(
      path: "todo.md", content: "- second", scope: fixture.scope)

    #expect(result["ok"] as? Bool == true)
    #expect(fixture.read("todo.md") == "- first\n- second")
  }

  @Test("Appending to a missing file creates it")
  func appendCreatesMissingFile() throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }

    let result = WorkspaceWriteTools.appendToFile(
      path: "new.md", content: "line", scope: fixture.scope)

    #expect(result["ok"] as? Bool == true)
    #expect(fixture.read("new.md") == "line")
  }

  // MARK: - Editing

  @Test("A unique match is replaced and the previous version backed up")
  func editsUniqueMatch() throws {
    let fixture = try Fixture()
    var backups: [String] = []
    defer { fixture.cleanUp(backups: backups) }
    try fixture.write("notes.md", "alpha\nbeta\ngamma")

    let result = WorkspaceWriteTools.editTextFile(
      path: "notes.md", find: "beta", replace: "BETA", replaceAll: false, scope: fixture.scope)
    if let backup = Self.backupPath(result) { backups.append(backup) }

    #expect(result["replacements"] as? Int == 1)
    #expect(fixture.read("notes.md") == "alpha\nBETA\ngamma")
    #expect(Self.backupPath(result) != nil)
  }

  @Test("Text that does not appear is an error, not a no-op success")
  func refusesMissingMatch() throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    try fixture.write("notes.md", "alpha")

    let result = WorkspaceWriteTools.editTextFile(
      path: "notes.md", find: "beta", replace: "BETA", replaceAll: false, scope: fixture.scope)

    #expect(result["error"] != nil)
    #expect(fixture.read("notes.md") == "alpha")
  }

  @Test("An ambiguous match is refused unless replace_all is set")
  func refusesAmbiguousMatch() throws {
    let fixture = try Fixture()
    var backups: [String] = []
    defer { fixture.cleanUp(backups: backups) }
    try fixture.write("notes.md", "todo\ntodo\ntodo")

    let refused = WorkspaceWriteTools.editTextFile(
      path: "notes.md", find: "todo", replace: "done", replaceAll: false, scope: fixture.scope)
    #expect(refused["error"] != nil)
    #expect(fixture.read("notes.md") == "todo\ntodo\ntodo")

    let allowed = WorkspaceWriteTools.editTextFile(
      path: "notes.md", find: "todo", replace: "done", replaceAll: true, scope: fixture.scope)
    if let backup = Self.backupPath(allowed) { backups.append(backup) }
    #expect(allowed["replacements"] as? Int == 3)
    #expect(fixture.read("notes.md") == "done\ndone\ndone")
  }

  @Test("Editing a file that does not exist points at write_text_file instead")
  func refusesEditingMissingFile() throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }

    let result = WorkspaceWriteTools.editTextFile(
      path: "nope.md", find: "a", replace: "b", replaceAll: false, scope: fixture.scope)

    #expect(result["error"] != nil)
  }

  // MARK: - Refusals

  @Test("Tooling directories are not writable")
  func refusesWritingIntoToolingDirectories() throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }

    for path in [".git/config", "node_modules/pkg/index.js", ".ssh/authorized_keys"] {
      let result = WorkspaceWriteTools.writeTextFile(
        path: path, content: "x", overwrite: true, scope: fixture.scope)
      #expect(result["error"] != nil, "expected \(path) to be refused")
      #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent(path).path))
    }
  }

  @Test("A path outside the shared folder is refused")
  func refusesEscapingPath() throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }

    let result = WorkspaceWriteTools.writeTextFile(
      path: "../escaped.md", content: "x", overwrite: true, scope: fixture.scope)

    #expect(result["error"] != nil)
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.root.deletingLastPathComponent().appendingPathComponent("escaped.md").path))
  }

  @Test("With no folder in scope, nothing can be written")
  func refusesWhenScopeIsOff() throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }

    let result = WorkspaceWriteTools.writeTextFile(
      path: "notes.md", content: "x", overwrite: true, scope: .off)

    #expect(result["error"] != nil)
    #expect(fixture.read("notes.md") == nil)
  }

  @Test("With file editing off, nothing can be written")
  func refusesWhenWriteAccessIsOff() throws {
    let fixture = try Fixture(writeEnabled: false)
    defer { fixture.cleanUp() }
    try fixture.write("notes.md", "the user's text")

    let result = WorkspaceWriteTools.writeTextFile(
      path: "notes.md", content: "x", overwrite: true, scope: fixture.scope)

    #expect(result["error"] != nil)
    #expect(fixture.read("notes.md") == "the user's text")
  }
}
