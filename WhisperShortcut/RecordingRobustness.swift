import Foundation

/// Shared policy for recording under hostile conditions: sleep, device changes, a full disk,
/// a crash mid-take, and a very long monologue. The decisions are pure so tests can pin them
/// without CoreAudio. Callers apply the result (deliver, stop, recover, refuse to start).
enum RecordingRobustness {

  /// 24 kHz × 16-bit × mono is about 2.88 MB per minute. 100 MB covers a long dictation plus
  /// the temporary merge file ChunkedDictateRecorder writes next to it.
  static let recordingReserveMB = 100

  /// Mid-recording floor. Below this the next write is likely to fail, so we stop and keep
  /// what we already have rather than wait for an encode error that may not deliver the file.
  static let criticalReserveMB = 20

  /// A WAV header is 44 bytes. Anything shorter cannot hold a sample and is not worth keeping.
  static let minimumSalvageableBytes: Int64 = 44

  /// Files we write for Dictate (and leftover chunks after a crash).
  static let recordingFilePrefix = "recording_"
  static let recordingFileExtension = "wav"

  /// How long after the last write a leftover file is treated as abandoned rather than "the
  /// current take just started". Launch recovery waits longer than this before scanning.
  static let leftoverQuietInterval: TimeInterval = 2

  // MARK: - Salvage (sleep, AirPods disconnect, encode error)

  /// Deliver the file when it has audio bytes, even if `AVAudioRecorder` reported failure.
  /// Sleep, an input-device change, and some encode errors finish with `successfully == false`
  /// but leave a closed, playable WAV of everything captured so far.
  static func shouldDeliver(fileSize: Int64, finishedSuccessfully: Bool) -> Bool {
    _ = finishedSuccessfully
    return fileSize >= minimumSalvageableBytes
  }

  static func fileSize(at url: URL) -> Int64 {
    ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0)
  }

  static func bestSalvage(urls: [URL]) -> URL? {
    urls
      .map { ($0, fileSize(at: $0)) }
      .filter { $0.1 >= minimumSalvageableBytes }
      .max(by: { $0.1 < $1.1 })?
      .0
  }

  // MARK: - Sleep / wake

  enum Interruption: Equatable {
    case willSleep
    case didWake
  }

  enum InterruptionAction: Equatable {
    case stopAndSalvage
    case none
  }

  /// Sleep: stop now so CoreAudio can close the WAV before the machine powers down.
  /// Wake: only act when we still think we are recording but the recorder has already died
  /// (the will-sleep stop never ran, or its finish callback was dropped).
  static func actionForInterruption(
    _ interruption: Interruption,
    isRecording: Bool,
    recorderStillRunning: Bool
  ) -> InterruptionAction {
    switch interruption {
    case .willSleep:
      return isRecording ? .stopAndSalvage : .none
    case .didWake:
      return isRecording && !recorderStillRunning ? .stopAndSalvage : .none
    }
  }

  // MARK: - Recording artifacts (crash leftovers)

  struct Artifact: Equatable {
    var name: String
    var size: Int64
    var modified: Date
  }

  static func isRecordingArtifact(fileName: String) -> Bool {
    let lower = fileName.lowercased()
    return lower.hasPrefix(recordingFilePrefix) && lower.hasSuffix(".\(recordingFileExtension)")
  }

  static func recordingsDirectory() -> URL {
    FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
  }

  static func makeRecordingURL(suffix: String = "") -> URL {
    recordingsDirectory().appendingPathComponent(
      "\(recordingFilePrefix)\(Date().timeIntervalSince1970)\(suffix).\(recordingFileExtension)")
  }

  static func listRecordingArtifacts(
    in directory: URL,
    now: Date = Date(),
    fileManager: FileManager = .default
  ) -> [Artifact] {
    let urls =
      (try? fileManager.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
        options: [.skipsHiddenFiles])) ?? []
    return urls.compactMap { url in
      guard isRecordingArtifact(fileName: url.lastPathComponent) else { return nil }
      let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
      let size = Int64(values?.fileSize ?? 0)
      let modified = values?.contentModificationDate ?? .distantPast
      if now.timeIntervalSince(modified) < leftoverQuietInterval { return nil }
      return Artifact(name: url.lastPathComponent, size: size, modified: modified)
    }
  }

  static func deleteArtifacts(
    named names: [String], in directory: URL, fileManager: FileManager = .default
  ) {
    for name in names {
      let url = directory.appendingPathComponent(name)
      try? fileManager.removeItem(at: url)
    }
  }

  // MARK: - Disk

  static func isOutOfSpace(_ error: Error) -> Bool {
    let ns = error as NSError
    if ns.domain == NSCocoaErrorDomain && ns.code == NSFileWriteOutOfSpaceError { return true }
    if ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOSPC) { return true }
    return false
  }

  static let diskFullErrorCode = 1005

  static func diskFullError() -> NSError {
    NSError(
      domain: "WhisperShortcut", code: diskFullErrorCode,
      userInfo: [
        NSLocalizedDescriptionKey: String(localized: "The disk is full, so recording stopped. What was captured so far was kept.")
      ])
  }
}
