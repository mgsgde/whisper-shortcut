import Foundation
import Testing

@testable import WhisperShortcut_AppStore

@Suite("Error log reopens after its file is deleted")
struct CachedWritableFileTests {

  @Test("A write after the file was deleted recreates it with the new line")
  func reopensAfterDelete() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let writer = ErrorFileWriter(logDirectory: dir, suppressWritesDuringTests: false)
    writer.write(message: "first-line")
    writer.waitForPendingWrites()

    let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
    let log = try #require(files.first { $0.lastPathComponent.hasPrefix("errors-") && $0.pathExtension == "log" })
    try FileManager.default.removeItem(at: log)
    #expect(!FileManager.default.fileExists(atPath: log.path))

    writer.write(message: "second-line")
    writer.waitForPendingWrites()

    #expect(FileManager.default.fileExists(atPath: log.path))
    let text = try String(contentsOf: log, encoding: .utf8)
    #expect(text.contains("second-line"))
    #expect(!text.contains("first-line"))
  }
}
