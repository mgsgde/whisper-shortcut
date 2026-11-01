import Foundation

/// A small file that says "a Dictate / Dictate Prompt take is on disk right now".
///
/// Live meetings already have `LiveMeetingRecordingMarker`. Dictation did not: a crash, a force
/// quit, or a sleep that killed the process left `recording_*.wav` in Documents with no way back
/// except "Transcribe Cancelled Recording", which is in-memory and dies with the process.
///
/// Lifecycle: written when capture begins, marked discarded when the user hits ✕, cleared when
/// the file is deleted after a successful run (or after the user recovers it). Launch recovery
/// scans leftover WAVs and, unless the take was discarded or another instance owns the marker,
/// keeps the largest one as the cancelled recording.
enum DictationRecordingMarker {

  struct Payload: Codable, Equatable {
    var pid: Int32
    /// `transcription` or `prompt`. Recovery always offers "Transcribe Cancelled Recording"
    /// (the existing menu item); the mode is kept so logs can tell the two apart.
    var mode: String
    var discarded: Bool
  }

  enum LaunchAction: Equatable {
    case none
    /// Keep this file; delete the other leftover artifacts so they do not pile up.
    case recover(keep: String, delete: [String])
    case deleteLeftovers([String])
  }

  private static var fileURL: URL {
    AppSupportPaths.whisperShortcutApplicationSupportURL()
      .appendingPathComponent("dictation-recording.json")
  }

  // MARK: - Decision (pure, unit-tested)

  /// What launch should do with leftover `recording_*.wav` files and an optional marker.
  static func launchAction(
    payload: Payload?,
    candidates: [RecordingRobustness.Artifact],
    ownerIsAlive: Bool
  ) -> LaunchAction {
    if ownerIsAlive { return .none }
    let salvageable = candidates.filter { $0.size >= RecordingRobustness.minimumSalvageableBytes }
    let names = candidates.map(\.name)
    if payload?.discarded == true {
      return names.isEmpty ? .none : .deleteLeftovers(names)
    }
    guard let keep = salvageable.max(by: { lhs, rhs in
      if lhs.size != rhs.size { return lhs.size < rhs.size }
      return lhs.modified < rhs.modified
    }) else {
      return names.isEmpty ? .none : .deleteLeftovers(names)
    }
    let delete = names.filter { $0 != keep.name }
    return .recover(keep: keep.name, delete: delete)
  }

  /// True when the process that wrote the marker is still running. `isAlive` is injectable.
  /// Our own pid never counts as another owner (same rule as the meeting marker).
  static func ownerIsAlive(
    pid: Int32, currentPid: Int32 = getpid(), isAlive: (Int32) -> Bool = { kill($0, 0) == 0 }
  ) -> Bool {
    pid != currentPid && isAlive(pid)
  }

  // MARK: - File access

  static func write(mode: String, discarded: Bool = false) {
    write(Payload(pid: getpid(), mode: mode, discarded: discarded))
    DebugLogger.log("DICTATION-MARKER: Wrote marker mode=\(mode) discarded=\(discarded) pid=\(getpid())")
  }

  static func markDiscarded() {
    guard var payload = read()?.payload else { return }
    payload.discarded = true
    write(payload)
    DebugLogger.log("DICTATION-MARKER: Marked discarded for pid \(payload.pid)")
  }

  static func clear() {
    try? FileManager.default.removeItem(at: fileURL)
  }

  static func read() -> (payload: Payload, lastAlive: Date)? {
    guard let data = try? Data(contentsOf: fileURL),
      let payload = try? JSONDecoder().decode(Payload.self, from: data)
    else { return nil }
    let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
    let lastAlive = (attributes?[.modificationDate] as? Date) ?? .distantPast
    return (payload, lastAlive)
  }

  private static func write(_ payload: Payload) {
    do {
      try FileManager.default.createDirectory(
        at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      let data = try JSONEncoder().encode(payload)
      try data.write(to: fileURL, options: .atomic)
    } catch {
      DebugLogger.logError("DICTATION-MARKER: Failed to write marker: \(error.logDescription)")
    }
  }
}
