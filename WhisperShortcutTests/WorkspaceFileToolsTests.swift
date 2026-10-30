import Foundation
import Testing

@testable import WhisperShortcut_AppStore

/// Pins the read-side boundary: credential stores stay closed even when named explicitly or
/// reached through a symlink, while a build directory the caller named is still readable.
@Suite("Workspace read tools", .serialized)
struct WorkspaceFileToolsTests {

  private struct Fixture {
    let root: URL

    init() throws {
      root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("wsread-\(UUID().uuidString)")
        .appendingPathComponent("workspace")
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func write(_ relativePath: String, _ contents: String) throws {
      let url = root.appendingPathComponent(relativePath)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    var scope: WorkspaceFolders.Scope {
      .explicit([WorkspaceFolders.Root(url: root, displayPath: root.path)])
    }

    func cleanUp() {
      try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }
  }

  @Test("Reading a file under .ssh is refused")
  func refusesReadingSSHKey() throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    try fixture.write(".ssh/id_rsa", "SECRET-KEY")

    let result = WorkspaceFileTools.readTextFile(
      path: ".ssh/id_rsa", maxBytes: 10_000, scope: fixture.scope)

    let error = try #require(result["error"] as? String)
    #expect(error.contains(".ssh"))
    #expect(error.contains("holds credentials"))
    #expect(result["content"] == nil)
  }

  @Test("Listing .aws is refused")
  func refusesListingAWS() throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    try fixture.write(".aws/credentials", "SECRET")

    let result = WorkspaceFileTools.listDirectory(
      path: ".aws", maxEntries: 50, scope: fixture.scope)

    let error = try #require(result["error"] as? String)
    #expect(error.contains(".aws"))
    #expect(error.contains("holds credentials"))
    #expect(result["entries"] == nil)
  }

  @Test("A build directory named explicitly is still readable")
  func readsNodeModulesWhenNamed() throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    try fixture.write("node_modules/x.txt", "build-output")

    let result = WorkspaceFileTools.readTextFile(
      path: "node_modules/x.txt", maxBytes: 10_000, scope: fixture.scope)

    #expect(result["error"] == nil)
    #expect(result["content"] as? String == "build-output")
  }

  @Test("A symlink into .ssh is refused")
  func refusesSymlinkIntoSSH() throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    try fixture.write(".ssh/id_rsa", "SECRET-KEY")
    try FileManager.default.createSymbolicLink(
      at: fixture.root.appendingPathComponent("link"),
      withDestinationURL: fixture.root.appendingPathComponent(".ssh"))

    let result = WorkspaceFileTools.readTextFile(
      path: "link/id_rsa", maxBytes: 10_000, scope: fixture.scope)

    let error = try #require(result["error"] as? String)
    #expect(error.contains(".ssh"))
    #expect(error.contains("holds credentials"))
    #expect(result["content"] == nil)
  }

  @Test("Searching a credential folder is refused")
  func refusesSearchingSSH() throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    try fixture.write(".ssh/id_rsa", "SECRET-KEY")

    let result = WorkspaceFileTools.searchFiles(
      query: "SECRET", path: ".ssh", searchContent: true, maxResults: 10, scope: fixture.scope)

    let error = try #require(result["error"] as? String)
    #expect(error.contains("holds credentials"))
    #expect(result["matches"] == nil)
  }

  @Test("Search does not follow a symlink out of the shared folder")
  func searchSkipsSymlinkOutsideRoot() throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let outside = fixture.root.deletingLastPathComponent().appendingPathComponent("outside.txt")
    try "NEEDLE".write(to: outside, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: outside) }
    try FileManager.default.createSymbolicLink(
      at: fixture.root.appendingPathComponent("escape.txt"),
      withDestinationURL: outside)
    try fixture.write("notes.txt", "ordinary")

    let result = WorkspaceFileTools.searchFiles(
      query: "NEEDLE", path: nil, searchContent: true, maxResults: 10, scope: fixture.scope)

    #expect(result["error"] == nil)
    let matches = result["matches"] as? [[String: Any]] ?? []
    #expect(matches.isEmpty)
  }
}
