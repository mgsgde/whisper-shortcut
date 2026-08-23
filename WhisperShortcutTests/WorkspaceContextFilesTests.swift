import Foundation
import Testing

@testable import WhisperShortcut_AppStore

/// Pins the loading rules for the agent-context files (`AGENTS.md`, `CLAUDE.md`,
/// `.cursor/rules`, `.claude/rules`) that ride along in every chat request.
///
/// The expensive mistake this guards against is double loading: `.claude` is commonly a symlink
/// to `.cursor`, so the identical rule file is reachable under two paths and would otherwise be
/// billed twice in every single turn. The second guard is containment — a symlink that leaves the
/// shared folder must not be followed, or sharing one folder would silently share another.
@Suite("Workspace context files")
struct WorkspaceContextFilesTests {

  // MARK: - Helpers

  /// A throwaway directory tree standing in for a shared workspace folder.
  private struct Fixture {
    let root: URL
    let outside: URL

    init() throws {
      let base = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("wsctx-\(UUID().uuidString)")
      root = base.appendingPathComponent("workspace")
      outside = base.appendingPathComponent("outside")
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    }

    func write(_ relativePath: String, _ contents: String) throws {
      let url = root.appendingPathComponent(relativePath)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    func writeOutside(_ name: String, _ contents: String) throws -> URL {
      let url = outside.appendingPathComponent(name)
      try contents.write(to: url, atomically: true, encoding: .utf8)
      return url
    }

    func symlink(_ relativePath: String, to destination: URL) throws {
      let url = root.appendingPathComponent(relativePath)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try FileManager.default.createSymbolicLink(at: url, withDestinationURL: destination)
    }

    var asRoot: WorkspaceFolders.Root {
      WorkspaceFolders.Root(url: root, displayPath: root.path)
    }

    func cleanUp() {
      try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }
  }

  private static func occurrences(of needle: String, in haystack: String) -> Int {
    guard !needle.isEmpty else { return 0 }
    var count = 0
    var index = haystack.startIndex
    while let found = haystack.range(of: needle, range: index..<haystack.endIndex) {
      count += 1
      index = found.upperBound
    }
    return count
  }

  private static func block(_ fixture: Fixture) -> String {
    WorkspaceContextFiles.contextBlock(roots: [fixture.asRoot])
  }

  // MARK: - Loading

  @Test("Root conventions and rule directories are both loaded in full")
  func loadsRootFilesAndRules() throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    try fixture.write("CLAUDE.md", "PERSONALITY-MARKER")
    try fixture.write(".cursor/rules/index.mdc", "RULE-INDEX-MARKER")
    try fixture.write(".cursor/rules/tone.mdc", "RULE-TONE-MARKER")

    let block = Self.block(fixture)

    #expect(block.contains("PERSONALITY-MARKER"))
    #expect(block.contains("RULE-INDEX-MARKER"))
    #expect(block.contains("RULE-TONE-MARKER"))
  }

  @Test("Skills are loaded, and only their SKILL.md")
  func loadsSkillFiles() throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    try fixture.write("AGENTS.md", "ROOT-MARKER")
    try fixture.write(".agents/skills/link-notes/SKILL.md", "SKILL-BODY-MARKER")
    try fixture.write(".agents/skills/link-notes/reference.md", "SKILL-REFERENCE-MARKER")

    let block = Self.block(fixture)

    #expect(block.contains("SKILL-BODY-MARKER"))
    #expect(!block.contains("SKILL-REFERENCE-MARKER"))
  }

  @Test("The tool-neutral .agents directory is scanned like .cursor and .claude")
  func loadsAgentsDirectory() throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    try fixture.write(".agents/rules/tone.md", "AGENTS-RULE-MARKER")

    #expect(Self.block(fixture).contains("AGENTS-RULE-MARKER"))
  }

  @Test("A folder with no context files contributes nothing")
  func emptyWhenNoContextFiles() throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    try fixture.write("shopping-list.md", "milk")

    #expect(Self.block(fixture).isEmpty)
  }

  // MARK: - Deduplication

  @Test("A .claude/rules symlink to .cursor/rules does not load the same rule twice")
  func deduplicatesSymlinkedRuleDirectory() throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    try fixture.write(".cursor/rules/index.mdc", "SHARED-RULE-MARKER")
    try fixture.symlink(".claude/rules", to: fixture.root.appendingPathComponent(".cursor/rules"))

    let block = Self.block(fixture)

    #expect(block.contains("SHARED-RULE-MARKER"))
    #expect(Self.occurrences(of: "SHARED-RULE-MARKER", in: block) == 1)
  }

  @Test("A per-file symlink into .cursor is not loaded a second time")
  func deduplicatesSymlinkedRuleFile() throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    try fixture.write(".cursor/rules/index.mdc", "LINKED-RULE-MARKER")
    try fixture.symlink(
      ".claude/rules/index.mdc", to: fixture.root.appendingPathComponent(".cursor/rules/index.mdc"))

    #expect(Self.occurrences(of: "LINKED-RULE-MARKER", in: Self.block(fixture)) == 1)
  }

  @Test("A skill reachable through .agents, .cursor and .claude loads exactly once")
  func deduplicatesSkillAcrossAllThreeConventions() throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    try fixture.write(".agents/skills/elon/SKILL.md", "TRIPLE-LINKED-SKILL-MARKER")
    let skills = fixture.root.appendingPathComponent(".agents/skills")
    try fixture.symlink(".cursor/skills", to: skills)
    try fixture.symlink(".claude/skills", to: skills)

    #expect(Self.occurrences(of: "TRIPLE-LINKED-SKILL-MARKER", in: Self.block(fixture)) == 1)
  }

  @Test("A CLAUDE.md symlinked to AGENTS.md loads once")
  func deduplicatesSymlinkedRootFile() throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    try fixture.write("AGENTS.md", "SINGLE-ROOT-MARKER")
    try fixture.symlink("CLAUDE.md", to: fixture.root.appendingPathComponent("AGENTS.md"))

    #expect(Self.occurrences(of: "SINGLE-ROOT-MARKER", in: Self.block(fixture)) == 1)
  }

  @Test("Two identical files that are copies rather than symlinks load once")
  func deduplicatesIdenticalCopies() throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    try fixture.write("AGENTS.md", "COPIED-CONTEXT-MARKER")
    try fixture.write("CLAUDE.md", "COPIED-CONTEXT-MARKER")

    #expect(Self.occurrences(of: "COPIED-CONTEXT-MARKER", in: Self.block(fixture)) == 1)
  }

  @Test("Different files under .cursor and .claude are both loaded")
  func keepsDistinctFilesFromBothDirectories() throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    try fixture.write(".cursor/rules/index.mdc", "CURSOR-ONLY-MARKER")
    try fixture.write(".claude/rules/extra.md", "CLAUDE-ONLY-MARKER")

    let block = Self.block(fixture)

    #expect(block.contains("CURSOR-ONLY-MARKER"))
    #expect(block.contains("CLAUDE-ONLY-MARKER"))
  }

  // MARK: - Containment

  @Test("A symlink pointing outside the shared folder is not followed")
  func rejectsSymlinkEscapingTheRoot() throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let secret = try fixture.writeOutside("secret.md", "OUTSIDE-MARKER")
    try fixture.symlink("CLAUDE.md", to: secret)
    try fixture.write(".cursor/rules/index.mdc", "INSIDE-MARKER")

    let block = Self.block(fixture)

    #expect(!block.contains("OUTSIDE-MARKER"))
    #expect(block.contains("INSIDE-MARKER"))
  }
}
