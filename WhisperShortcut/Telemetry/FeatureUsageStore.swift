import Foundation

/// Per-feature usage counts for this Mac.
///
/// Independent of the telemetry switch and of Offline Mode: it is local bookkeeping that never
/// leaves the Mac. Opt-in pings carry their own `features` map; this file is not part of that send.
final class FeatureUsageStore: @unchecked Sendable {

  static let shared = FeatureUsageStore(
    fileURL: AppSupportPaths.whisperShortcutApplicationSupportURL()
      .appendingPathComponent("feature-usage.json")
  )

  struct Entry: Codable, Equatable {
    var count: Int
    var firstUsed: Date
    var lastUsed: Date
  }

  private struct File: Codable {
    var since: Date
    var entries: [String: Entry]
  }

  private let fileURL: URL
  private let now: () -> Date
  private let lock = NSLock()
  private let queue = DispatchQueue(label: "com.magnusgoedde.whispershortcut.feature-usage", qos: .utility)

  // All state below is guarded by `lock`.
  private var since: Date
  private var entries: [TelemetryFeature: Entry] = [:]
  private var loaded = false
  /// A write is already waiting on `queue`. Further `record` calls fold into it.
  private var writePending = false
  /// Bumped when a waiting write is superseded, so the late block does not overwrite a newer file.
  private var generation = 0

  private static let writeDelay: TimeInterval = 1

  private static let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }()

  /// `now` is the clock for `since` (creation and reset). `record`'s date is the use itself.
  init(fileURL: URL, now: @escaping () -> Date = Date.init) {
    self.fileURL = fileURL
    self.now = now
    self.since = now()
  }

  /// Counts one use. The file is written on `queue`, at most once a second while calls keep coming.
  func record(_ feature: TelemetryFeature, at date: Date = Date()) {
    lock.lock()
    loadIfNeeded()
    if var entry = entries[feature] {
      entry.count += 1
      entry.lastUsed = date
      entries[feature] = entry
    } else {
      entries[feature] = Entry(count: 1, firstUsed: date, lastUsed: date)
    }
    scheduleWriteLocked()
    lock.unlock()
  }

  func snapshot() -> (since: Date, entries: [TelemetryFeature: Entry]) {
    lock.lock()
    loadIfNeeded()
    let result = (since, entries)
    lock.unlock()
    return result
  }

  /// Clears the counts, sets `since` to now, and replaces the file.
  func reset() {
    lock.lock()
    loaded = true
    entries = [:]
    since = now()
    generation += 1
    writePending = false
    let payload = encodedLocked()
    lock.unlock()
    queue.sync {
      try? FileManager.default.removeItem(at: self.fileURL)
      self.writeAtomically(payload)
    }
  }

  /// Writes the current snapshot immediately. Tests read the file after this returns.
  func flushForTesting() {
    lock.lock()
    loadIfNeeded()
    generation += 1
    writePending = false
    let payload = encodedLocked()
    lock.unlock()
    queue.sync { self.writeAtomically(payload) }
  }

  // MARK: - Persistence

  /// Caller holds `lock`.
  private func scheduleWriteLocked() {
    guard !writePending else { return }
    writePending = true
    generation += 1
    let scheduled = generation
    queue.asyncAfter(deadline: .now() + Self.writeDelay) { [weak self] in
      self?.writeScheduled(scheduled)
    }
  }

  private func writeScheduled(_ generation: Int) {
    lock.lock()
    guard generation == self.generation, writePending else {
      lock.unlock()
      return
    }
    writePending = false
    let payload = encodedLocked()
    lock.unlock()
    writeAtomically(payload)
  }

  /// Caller holds `lock`. Unknown raw values are skipped; a key the app no longer knows is not an error.
  private func loadIfNeeded() {
    guard !loaded else { return }
    loaded = true
    guard let data = try? Data(contentsOf: fileURL),
      let file = try? JSONDecoder().decode(File.self, from: data)
    else { return }
    since = file.since
    var parsed: [TelemetryFeature: Entry] = [:]
    for (key, entry) in file.entries {
      guard let feature = TelemetryFeature(rawValue: key) else { continue }
      parsed[feature] = entry
    }
    entries = parsed
  }

  /// Caller holds `lock`.
  private func encodedLocked() -> Data? {
    let raw = Dictionary(uniqueKeysWithValues: entries.map { ($0.key.rawValue, $0.value) })
    return try? Self.encoder.encode(File(since: since, entries: raw))
  }

  private func writeAtomically(_ data: Data?) {
    guard let data else { return }
    do {
      try FileManager.default.createDirectory(
        at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      try data.write(to: fileURL, options: .atomic)
    } catch {
      DebugLogger.logWarning("FEATURE-USAGE: could not save counts: \(error.logDescription)")
    }
  }
}
