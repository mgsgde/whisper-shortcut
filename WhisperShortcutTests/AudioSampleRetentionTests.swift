import Foundation
import Testing

@testable import WhisperShortcut_AppStore

@Suite("Audio sample retention")
struct AudioSampleRetentionTests {

  @Test("Launch rotation deletes audio older than the retention window and keeps the rest")
  func rotationPrunesExpiredSamples() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory
      .appendingPathComponent("audio-retention-\(UUID().uuidString)", isDirectory: true)
    defer { try? fm.removeItem(at: root) }
    let samples = root.appendingPathComponent(ContextLogger.audioSamplesDirectoryName, isDirectory: true)
    try fm.createDirectory(at: samples, withIntermediateDirectories: true)

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let now = try #require(
      calendar.date(from: DateComponents(year: 2026, month: 6, day: 15, hour: 12)))
    let formatter = UserContextLog.makeFileNameDateFormatter(dateFormat: "yyyyMMdd'T'HHmmssSSS")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    let expired = now.addingTimeInterval(-Double(AppConstants.audioSampleRetentionDays + 1) * 86_400)
    let fresh = now.addingTimeInterval(-86_400)
    let expiredName = "\(formatter.string(from: expired))-AAAAAA.wav"
    let freshName = "\(formatter.string(from: fresh))-BBBBBB.wav"
    try Data("old".utf8).write(to: samples.appendingPathComponent(expiredName))
    try Data("new".utf8).write(to: samples.appendingPathComponent(freshName))
    try Data("keep".utf8).write(to: samples.appendingPathComponent("not-a-timestamp.wav"))

    ContextLogger.performMaintenance(
      in: root, now: now, rotationDays: 90, historyFileMaxLines: 500)

    #expect(!fm.fileExists(atPath: samples.appendingPathComponent(expiredName).path))
    #expect(fm.fileExists(atPath: samples.appendingPathComponent(freshName).path))
    #expect(fm.fileExists(atPath: samples.appendingPathComponent("not-a-timestamp.wav").path))
  }

  @Test("Clearing the pool, which turning learning off does, deletes every clip")
  func clearRemovesEverySample() throws {
    let fm = FileManager.default
    let samples = fm.temporaryDirectory
      .appendingPathComponent("audio-clear-\(UUID().uuidString)", isDirectory: true)
    defer { try? fm.removeItem(at: samples) }
    try fm.createDirectory(at: samples, withIntermediateDirectories: true)
    for name in ["20260601T120000000-AAAAAA.wav", "20260614T120000000-BBBBBB.wav"] {
      try Data("clip".utf8).write(to: samples.appendingPathComponent(name))
    }

    #expect(ContextLogger.audioSampleURLs(in: samples).count == 2)
    #expect(ContextLogger.clearAudioSamples(in: samples) == 2)
    #expect(ContextLogger.audioSampleURLs(in: samples).isEmpty)
    #expect(ContextLogger.clearAudioSamples(in: samples.appendingPathComponent("missing")) == 0)
  }
}
