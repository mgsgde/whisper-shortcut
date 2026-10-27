import Foundation

/// Meeting audio that could not be transcribed yet, kept on disk until a retry succeeds.
///
/// A live meeting used to delete every chunk's audio once its transcription call returned —
/// whether it returned text or an error. Recording a meeting offline therefore threw the whole
/// meeting away chunk by chunk, and only the part spoken after the network came back survived.
/// Failed chunks now move here instead, one folder per meeting stem, and are spliced into the
/// transcript at their original timestamps when a retry (automatic at meeting end, or from the
/// status menu) gets them through.
///
/// Layout: `MeetingAudio/<meeting stem>/chunk-<start in ms, zero-padded>.wav`. The start time lives
/// in the filename so the folder needs no index file that could drift from what is on disk.
enum MeetingAudioBacklog {

  struct Item: Equatable {
    let url: URL
    /// Elapsed seconds from meeting start — the timestamp the chunk gets in the transcript.
    let startTime: TimeInterval
  }

  static let directoryName = "MeetingAudio"

  static var rootURL: URL {
    AppSupportPaths.whisperShortcutApplicationSupportURL().appendingPathComponent(directoryName)
  }

  static func directory(stem: String) -> URL {
    rootURL.appendingPathComponent(stem, isDirectory: true)
  }

  static func filename(startTime: TimeInterval) -> String {
    String(format: "chunk-%010d.wav", Int((startTime * 1000).rounded()))
  }

  /// Inverse of `filename(startTime:)`; nil for anything that is not a backlog chunk.
  static func startTime(fromFilename name: String) -> TimeInterval? {
    guard name.hasPrefix("chunk-"), name.hasSuffix(".wav") else { return nil }
    let digits = name.dropFirst("chunk-".count).dropLast(".wav".count)
    guard !digits.isEmpty, let ms = Int(digits) else { return nil }
    return TimeInterval(ms) / 1000
  }

  /// Moves a chunk that failed to transcribe into the backlog. Returns false when the move failed;
  /// the caller then still owns `audioURL`.
  @discardableResult
  static func retain(_ audioURL: URL, stem: String, startTime: TimeInterval) -> Bool {
    let dir = directory(stem: stem)
    let target = dir.appendingPathComponent(filename(startTime: startTime))
    do {
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      if FileManager.default.fileExists(atPath: target.path) {
        try FileManager.default.removeItem(at: target)
      }
      try FileManager.default.moveItem(at: audioURL, to: target)
      DebugLogger.log("MEETING-BACKLOG: Kept untranscribed chunk \(target.lastPathComponent) for \(stem)")
      return true
    } catch {
      DebugLogger.logError("MEETING-BACKLOG: Failed to keep chunk for \(stem): \(error.localizedDescription)")
      return false
    }
  }

  /// The meeting's backlog, oldest first.
  static func items(stem: String) -> [Item] {
    let files = (try? FileManager.default.contentsOfDirectory(
      at: directory(stem: stem), includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
    return files.compactMap { url in
      startTime(fromFilename: url.lastPathComponent).map { Item(url: url, startTime: $0) }
    }.sorted { $0.startTime < $1.startTime }
  }

  /// Every meeting stem that still has untranscribed audio, oldest meeting first (stems start with
  /// a sortable timestamp).
  static func stemsWithBacklog() -> [String] {
    let dirs = (try? FileManager.default.contentsOfDirectory(
      at: rootURL, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
    return dirs.map(\.lastPathComponent).filter { !items(stem: $0).isEmpty }.sorted()
  }

  static func totalCount() -> Int {
    stemsWithBacklog().reduce(0) { $0 + items(stem: $1).count }
  }

  /// Follows a meeting rename so its backlog still matches the transcript's stem.
  static func rename(stem oldStem: String, to newStem: String) {
    let old = directory(stem: oldStem)
    guard FileManager.default.fileExists(atPath: old.path) else { return }
    let new = directory(stem: newStem)
    try? FileManager.default.removeItem(at: new)
    do {
      try FileManager.default.moveItem(at: old, to: new)
    } catch {
      DebugLogger.logError("MEETING-BACKLOG: Failed to move backlog \(oldStem) → \(newStem): \(error.localizedDescription)")
    }
  }

  static func remove(stem: String) {
    try? FileManager.default.removeItem(at: directory(stem: stem))
  }

  /// Removes the meeting's folder once its last chunk is gone, so `stemsWithBacklog` stays cheap.
  static func removeIfEmpty(stem: String) {
    if items(stem: stem).isEmpty { remove(stem: stem) }
  }

  /// Splices recovered chunks into a transcript in timestamp order. Pure so the ordering rule can be
  /// tested without touching disk.
  static func merge(_ recovered: [LiveMeetingChunk], into existing: [LiveMeetingChunk])
    -> [LiveMeetingChunk]
  {
    // Stable on equal timestamps: a recovered chunk goes before an existing one that shares its
    // second, since the recovered audio started at or before it.
    (recovered.map { (0, $0) } + existing.map { (1, $0) })
      .enumerated()
      .sorted { a, b in
        if a.element.1.startTime != b.element.1.startTime {
          return a.element.1.startTime < b.element.1.startTime
        }
        if a.element.0 != b.element.0 { return a.element.0 < b.element.0 }
        return a.offset < b.offset
      }
      .map { $0.element.1 }
  }
}
