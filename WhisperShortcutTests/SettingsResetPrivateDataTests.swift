import Foundation
import Testing

@testable import WhisperShortcut_AppStore

@Suite("Reset all private data")
struct SettingsResetPrivateDataTests {

  @Test("Reset deletes private files and leaves downloaded models")
  func resetRemovesPrivateDataOnly() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory
      .appendingPathComponent("reset-private-\(UUID().uuidString)", isDirectory: true)
    defer { try? fm.removeItem(at: root) }
    try fm.createDirectory(at: root, withIntermediateDirectories: true)

    let urls = SettingsViewModel.resetAllPrivateDataURLs(appSupport: root)
    let names = Set(urls.map(\.lastPathComponent))
    #expect(names.contains(MeetingAudioBacklog.directoryName))
    #expect(names.contains(TranscriptionHistoryStore.fileName))
    #expect(names.contains("raw-responses"))
    #expect(names.contains(TelemetryService.pendingFileName))
    #expect(names.contains(LiveMeetingRecordingMarker.fileName))
    #expect(names.contains(AppConstants.liveMeetingTranscriptDirectory))
    for kept in ["WhisperKit", "MLXModels", "FluidAudio"] {
      #expect(!urls.contains { $0.pathComponents.contains(kept) })
    }

    for url in urls { try materialize(url) }
    let keep = [
      root.appendingPathComponent("WhisperKit/models/m.bin"),
      root.appendingPathComponent("MLXModels/hub/w.bin"),
      root.appendingPathComponent("FluidAudio/Models/p.bin"),
    ]
    for url in keep { try materialize(url) }

    SettingsViewModel.removeResetAllPrivateData(appSupport: root)

    for url in urls {
      #expect(!fm.fileExists(atPath: url.path), "still present: \(url.lastPathComponent)")
    }
    for url in keep {
      #expect(fm.fileExists(atPath: url.path))
    }
  }

  private func materialize(_ url: URL) throws {
    let fm = FileManager.default
    if url.pathExtension.isEmpty {
      try fm.createDirectory(at: url, withIntermediateDirectories: true)
      try Data("x".utf8).write(to: url.appendingPathComponent("marker"))
    } else {
      try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data("x".utf8).write(to: url)
    }
  }
}
