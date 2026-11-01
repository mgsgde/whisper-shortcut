import Foundation
import Testing

@testable import WhisperShortcut_AppStore

@Suite("Cached error-log handle after Delete context data")
struct CachedWritableFileTests {

  @Test("A handle is invalid once its file is deleted underneath it")
  func deletedFileIsNoLongerOnDisk() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let file = dir.appendingPathComponent("errors-2026-11-01.log")
    #expect(FileManager.default.createFile(atPath: file.path, contents: Data("old\n".utf8)))
    #expect(CachedWritableFile.isStillOnDisk(path: file.path))

    try FileManager.default.removeItem(at: file)
    #expect(!CachedWritableFile.isStillOnDisk(path: file.path))

    #expect(FileManager.default.createFile(atPath: file.path, contents: Data("new\n".utf8)))
    #expect(CachedWritableFile.isStillOnDisk(path: file.path))
    let text = try String(contentsOf: file, encoding: .utf8)
    #expect(text == "new\n")
  }
}
