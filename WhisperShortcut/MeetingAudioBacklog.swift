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

  /// Transcript folder `finish()` writes and, after a rename, the file `Meeting-<ts>-Name.txt`.
  static func meetingsDirectory() -> URL {
    AppSupportPaths.whisperShortcutApplicationSupportURL()
      .appendingPathComponent(AppConstants.liveMeetingTranscriptDirectory)
  }

  /// Follows a `finish()` rename (`Meeting-<ts>` → `Meeting-<ts>-Name`) so a late retry does
  /// not recreate the original stem as a fragment meeting.
  ///
  /// If `stem.txt` still exists, the meeting was not renamed (or this *is* the new name).
  /// Otherwise the longest `stem-*.txt` in `meetingsDirectory` is the renamed file.
  static func resolvedStem(_ stem: String, meetingsDirectory: URL? = nil) -> String {
    let dir = meetingsDirectory ?? Self.meetingsDirectory()
    let own = dir.appendingPathComponent("\(stem).txt")
    if FileManager.default.fileExists(atPath: own.path) { return stem }
    let files = (try? FileManager.default.contentsOfDirectory(
      at: dir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
    let successors = files
      .filter { $0.pathExtension == "txt" }
      .map { $0.deletingPathExtension().lastPathComponent }
      .filter { $0.hasPrefix(stem + "-") }
      .sorted { $0.count > $1.count }
    return successors.first ?? stem
  }

  /// Every backlog folder that belongs to `resolved` — the renamed stem itself plus any
  /// pre-rename folder still holding late-failed chunks.
  static func sourceStems(forResolved resolved: String, meetingsDirectory: URL? = nil) -> [String] {
    let dir = meetingsDirectory ?? Self.meetingsDirectory()
    var stems: Set<String> = [resolved]
    for candidate in stemsWithBacklog() {
      if resolvedStem(candidate, meetingsDirectory: dir) == resolved {
        stems.insert(candidate)
      }
    }
    return stems.sorted()
  }

  /// Splices recovered chunks into the resolved transcript (follows a rename) and returns
  /// that stem. Pure I/O helper so a retry can be tested without a live session.
  @discardableResult
  static func spliceRecovered(
    _ chunks: [LiveMeetingChunk],
    recordedStem: String,
    meetingsDirectory: URL
  ) throws -> String {
    let resolved = resolvedStem(recordedStem, meetingsDirectory: meetingsDirectory)
    let url = meetingsDirectory.appendingPathComponent("\(resolved).txt")
    let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    let merged = merge(chunks, into: LiveMeetingTranscriptStore.parseTranscript(existing))
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try transcriptText(merged).write(to: url, atomically: true, encoding: .utf8)
    return resolved
  }

  /// Moves a chunk that failed to transcribe into the backlog. Returns false when the move failed;
  /// the caller then still owns `audioURL`.
  @discardableResult
  static func retain(_ audioURL: URL, stem: String, startTime: TimeInterval) -> Bool {
    let resolved = resolvedStem(stem)
    let dir = directory(stem: resolved)
    let target = dir.appendingPathComponent(filename(startTime: startTime))
    do {
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      if FileManager.default.fileExists(atPath: target.path) {
        try FileManager.default.removeItem(at: target)
      }
      try FileManager.default.moveItem(at: audioURL, to: target)
      DebugLogger.log(
        "MEETING-BACKLOG: Kept untranscribed chunk \(target.lastPathComponent) for \(resolved)"
          + (resolved == stem ? "" : " (followed rename from \(stem))"))
      return true
    } catch {
      DebugLogger.logError("MEETING-BACKLOG: Failed to keep chunk for \(resolved): \(error.logDescription)")
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
      DebugLogger.logError("MEETING-BACKLOG: Failed to move backlog \(oldStem) → \(newStem): \(error.logDescription)")
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

  /// Renders chunks in the transcript file format `appendToTranscript` writes.
  static func transcriptText(_ chunks: [LiveMeetingChunk]) -> String {
    chunks.map { "\($0.timestampString) \($0.text)\n\n" }.joined()
  }
}
