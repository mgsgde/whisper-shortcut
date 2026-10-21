import Foundation

/// A small file that says "a live meeting is recording right now".
///
/// Why it exists: on 2026-10-20 an update script sent the running app a Quit Apple Event, the app
/// quit mid-meeting, and after the relaunch nothing told anyone the meeting was no longer being
/// recorded — the last eight minutes were never captured. The marker survives the process, so the
/// next launch can resume the meeting (restart was brief) or tell the user it stopped. The dev
/// scripts read the same file (`scripts/meeting-guard.sh`) to refuse to kill a recording app.
///
/// Lifecycle: written when a session starts, touched on every chunk (heartbeat), cleared when the
/// meeting ends. A deliberate Quit from our own menu sets `userQuit`, so that is never auto-resumed.
enum LiveMeetingRecordingMarker {

  struct Payload: Codable, Equatable {
    var stem: String
    var pid: Int32
    var userQuit: Bool
  }

  /// How long after the last heartbeat a restart still counts as "the same meeting, briefly
  /// interrupted" and is resumed automatically instead of only reported.
  static let resumeWindow: TimeInterval = 10 * 60

  enum LaunchAction: Equatable {
    case none
    case resume(stem: String)
    case notifyInterrupted(stem: String)
  }

  private static var fileURL: URL {
    AppSupportPaths.whisperShortcutApplicationSupportURL()
      .appendingPathComponent("live-meeting-recording.json")
  }

  // MARK: - Decision (pure, unit-tested)

  /// What the app should do at launch given a leftover marker. A missing transcript means there is
  /// nothing to resume or point the user to (the meeting was discarded or never wrote a chunk).
  static func launchAction(
    payload: Payload?, lastAlive: Date?, now: Date, transcriptExists: Bool
  ) -> LaunchAction {
    guard let payload, !payload.userQuit, transcriptExists else { return .none }
    guard let lastAlive else { return .notifyInterrupted(stem: payload.stem) }
    return now.timeIntervalSince(lastAlive) <= resumeWindow
      ? .resume(stem: payload.stem) : .notifyInterrupted(stem: payload.stem)
  }

  /// True when the process that wrote the marker is still running. `isAlive` is injectable for tests.
  /// Our own pid never counts as another owner.
  static func ownerIsAlive(
    pid: Int32, currentPid: Int32 = getpid(), isAlive: (Int32) -> Bool = { kill($0, 0) == 0 }
  ) -> Bool {
    pid != currentPid && isAlive(pid)
  }

  // MARK: - File access

  static func write(stem: String) {
    write(Payload(stem: stem, pid: getpid(), userQuit: false))
    DebugLogger.log("LIVE-MEETING-MARKER: Wrote marker for \(stem) (pid \(getpid()))")
  }

  /// Heartbeat: bumps the modification date so a later launch knows when the app was last alive.
  static func touch() {
    try? FileManager.default.setAttributes(
      [.modificationDate: Date()], ofItemAtPath: fileURL.path)
  }

  /// Records that the user chose Quit from our own menu; the next launch must not resume.
  static func markUserQuit() {
    guard var payload = read()?.payload else { return }
    payload.userQuit = true
    write(payload)
    DebugLogger.log("LIVE-MEETING-MARKER: Marked user quit for \(payload.stem)")
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
      DebugLogger.logError("LIVE-MEETING-MARKER: Failed to write marker: \(error.localizedDescription)")
    }
  }
}
