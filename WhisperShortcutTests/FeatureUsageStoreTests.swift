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
    let key = dayKey(first)
    #expect(entries[.dictation] == FeatureUsageStore.Entry(count: 2, firstUsed: first, lastUsed: later, days: [key: 2]))
    #expect(entries[.chat] == FeatureUsageStore.Entry(count: 1, firstUsed: later, lastUsed: later, days: [key: 1]))
    #expect(entries.count == 2)
  }

  @Test("record counts distinct local days")
  func recordCountsDays() {
    let store = FeatureUsageStore(fileURL: tempFile())
    let first = Date(timeIntervalSince1970: 1_700_000_000)
    let sameDay = first.addingTimeInterval(90)
    let nextDay = Calendar.current.date(byAdding: .day, value: 1, to: first)!
    store.record(.dictation, at: first)
    store.record(.dictation, at: sameDay)
    store.record(.dictation, at: nextDay)
    let days = store.snapshot().entries[.dictation]?.days ?? [:]
    #expect(days[dayKey(first)] == 2)
    #expect(days[dayKey(nextDay)] == 1)
    #expect(dayKey(first) != dayKey(nextDay))
    #expect(days.count == 2)
  }

  @Test("record drops day keys older than 120 days and keeps the boundary")
  func prunesOldDays() {
    let store = FeatureUsageStore(fileURL: tempFile())
    let calendar = Calendar.current
    let today = Date(timeIntervalSince1970: 1_700_000_000)
    let boundary = calendar.date(byAdding: .day, value: -120, to: today)!
    let tooOld = calendar.date(byAdding: .day, value: -121, to: today)!
    store.record(.dictation, at: tooOld)
    store.record(.dictation, at: boundary)
    store.record(.dictation, at: today)
    let entry = store.snapshot().entries[.dictation]
    #expect(entry?.count == 3)
    #expect(entry?.days[dayKey(tooOld)] == nil)
    #expect(entry?.days[dayKey(boundary)] == 1)
    #expect(entry?.days[dayKey(today)] == 1)
    #expect(entry?.days.count == 2)
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
    #expect(snap.entries[.meeting] == FeatureUsageStore.Entry(
      count: 1, firstUsed: used, lastUsed: used, days: [dayKey(used): 1]))
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

  @Test("a file written before days existed decodes as an empty map")
  func decodesFileWithoutDays() throws {
    struct LegacyEntry: Codable {
      var count: Int
      var firstUsed: Date
      var lastUsed: Date
    }
    struct LegacyFile: Codable {
      var since: Date
      var entries: [String: LegacyEntry]
    }
    let url = tempFile()
    let created = Date(timeIntervalSince1970: 1_700_000_300)
    let used = created.addingTimeInterval(20)
    let raw = LegacyFile(
      since: created,
      entries: ["dictation": LegacyEntry(count: 4, firstUsed: used, lastUsed: used)]
    )
    let data = try JSONEncoder().encode(raw)
    let text = String(decoding: data, as: UTF8.self)
    #expect(!text.contains("days"))
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url)
    let store = FeatureUsageStore(fileURL: url, now: { Date(timeIntervalSince1970: 0) })
    let entry = store.snapshot().entries[.dictation]
    #expect(entry?.count == 4)
    #expect(entry?.firstUsed == used)
    #expect(entry?.lastUsed == used)
    #expect(entry?.days.isEmpty == true)
  }

  private func dayKey(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar.current
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = Calendar.current.timeZone
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: date)
  }

  private final class Clock: @unchecked Sendable {
    var date: Date
    init(_ date: Date) { self.date = date }
  }
}
