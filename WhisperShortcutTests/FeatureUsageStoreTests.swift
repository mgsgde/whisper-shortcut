import Foundation
import Testing

@testable import WhisperShortcut_AppStore

@Suite("Feature usage store")
struct FeatureUsageStoreTests {

  private struct RawFile: Codable {
    var since: Date
    var entries: [String: FeatureUsageStore.Entry]
  }

  private func tempFile() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("feature-usage-\(UUID().uuidString)")
      .appendingPathComponent("feature-usage.json")
  }

  @Test("record counts uses and keeps the first and last dates")
  func recordCounts() {
    let store = FeatureUsageStore(fileURL: tempFile())
    let first = Date(timeIntervalSince1970: 1_700_000_000)
    let later = first.addingTimeInterval(90)
    store.record(.dictation, at: first)
    store.record(.dictation, at: later)
    store.record(.chat, at: later)
    let entries = store.snapshot().entries
    #expect(entries[.dictation] == FeatureUsageStore.Entry(count: 2, firstUsed: first, lastUsed: later))
    #expect(entries[.chat] == FeatureUsageStore.Entry(count: 1, firstUsed: later, lastUsed: later))
    #expect(entries.count == 2)
  }

  @Test("counts round-trip through the file")
  func persistenceRoundTrip() {
    let url = tempFile()
    let created = Date(timeIntervalSince1970: 1_700_000_100)
    let used = created.addingTimeInterval(5)
    let store = FeatureUsageStore(fileURL: url, now: { created })
    store.record(.meeting, at: used)
    store.flushForTesting()
    let reloaded = FeatureUsageStore(fileURL: url, now: { used.addingTimeInterval(1_000) })
    let snap = reloaded.snapshot()
    #expect(snap.since == created)
    #expect(snap.entries[.meeting] == FeatureUsageStore.Entry(count: 1, firstUsed: used, lastUsed: used))
  }

  @Test("reset clears entries, moves since, and rewrites the file")
  func reset() {
    let url = tempFile()
    let clock = Clock(Date(timeIntervalSince1970: 1_700_000_000))
    let store = FeatureUsageStore(fileURL: url, now: { clock.date })
    store.record(.chat, at: clock.date)
    store.flushForTesting()
    clock.date = clock.date.addingTimeInterval(3_600)
    store.reset()
    let snap = store.snapshot()
    #expect(snap.entries.isEmpty)
    #expect(snap.since == clock.date)
    let reloaded = FeatureUsageStore(fileURL: url, now: { Date(timeIntervalSince1970: 0) })
    let again = reloaded.snapshot()
    #expect(again.entries.isEmpty)
    #expect(again.since == clock.date)
    #expect(FileManager.default.fileExists(atPath: url.path))
  }

  @Test("an unknown key in the file is ignored")
  func unknownKeyIgnored() throws {
    let url = tempFile()
    let created = Date(timeIntervalSince1970: 1_700_000_200)
    let used = created.addingTimeInterval(10)
    let entry = FeatureUsageStore.Entry(count: 3, firstUsed: used, lastUsed: used)
    let raw = RawFile(
      since: created,
      entries: ["readAloud": entry, "notARealFeature": FeatureUsageStore.Entry(count: 9, firstUsed: used, lastUsed: used)]
    )
    let data = try JSONEncoder().encode(raw)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url)
    let store = FeatureUsageStore(fileURL: url, now: { Date(timeIntervalSince1970: 0) })
    let snap = store.snapshot()
    #expect(snap.since == created)
    #expect(snap.entries == [.readAloud: entry])
  }

  private final class Clock: @unchecked Sendable {
    var date: Date
    init(_ date: Date) { self.date = date }
  }
}
