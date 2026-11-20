import Foundation
import Testing

@testable import WhisperShortcut_AppStore

@Suite("HubSnapshotOrder")
struct HubSnapshotOrderTests {
  /// Repo folder with snapshots a (oldest), b, c (newest) and an optional `refs/main`.
  private func makeRepo(refsMain: String?) throws -> URL {
    let repo = FileManager.default.temporaryDirectory
      .appendingPathComponent("hub-order-\(UUID().uuidString)")
    let snapshots = repo.appendingPathComponent("snapshots")
    let base = Date(timeIntervalSince1970: 1_700_000_000)
    for (offset, name) in [(0.0, "a"), (100.0, "b"), (200.0, "c")] {
      let dir = snapshots.appendingPathComponent(name)
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      try FileManager.default.setAttributes(
        [.modificationDate: base.addingTimeInterval(offset)], ofItemAtPath: dir.path)
    }
    if let refsMain {
      let refs = repo.appendingPathComponent("refs")
      try FileManager.default.createDirectory(at: refs, withIntermediateDirectories: true)
      try (refsMain + "\n").write(
        to: refs.appendingPathComponent("main"), atomically: true, encoding: .utf8)
    }
    return repo
  }

  @Test func refsMainFirstThenNewest() throws {
    let repo = try makeRepo(refsMain: "b")
    defer { try? FileManager.default.removeItem(at: repo) }
    #expect(HubSnapshotOrder.preferred(in: repo, among: ["a", "b", "c"]) == ["b", "c", "a"])
  }

  @Test func withoutRefsMainNewestFirst() throws {
    let repo = try makeRepo(refsMain: nil)
    defer { try? FileManager.default.removeItem(at: repo) }
    #expect(HubSnapshotOrder.preferred(in: repo, among: ["a", "b", "c"]) == ["c", "b", "a"])
  }

  @Test func refsMainNamingMissingHashIsIgnored() throws {
    let repo = try makeRepo(refsMain: "zzz")
    defer { try? FileManager.default.removeItem(at: repo) }
    #expect(HubSnapshotOrder.preferred(in: repo, among: ["a", "b", "c"]) == ["c", "b", "a"])
  }
}
