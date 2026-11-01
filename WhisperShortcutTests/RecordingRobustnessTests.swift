import Foundation
import Testing
@testable import WhisperShortcut_AppStore

@Suite("Recording robustness")
struct RecordingRobustnessTests {

  // MARK: - Salvage (sleep, device change, encode error)

  @Test("A file with audio bytes is delivered even when the recorder reports failure")
  func salvageUnsuccessfulFinish() {
    #expect(RecordingRobustness.shouldDeliver(fileSize: 4_096, finishedSuccessfully: false))
    #expect(RecordingRobustness.shouldDeliver(fileSize: 4_096, finishedSuccessfully: true))
  }

  @Test("A header-only or missing file is never delivered")
  func emptyFileNotSalvaged() {
    #expect(!RecordingRobustness.shouldDeliver(fileSize: 0, finishedSuccessfully: true))
    #expect(!RecordingRobustness.shouldDeliver(fileSize: 0, finishedSuccessfully: false))
    #expect(
      !RecordingRobustness.shouldDeliver(
        fileSize: RecordingRobustness.minimumSalvageableBytes - 1, finishedSuccessfully: false))
    #expect(
      RecordingRobustness.shouldDeliver(
        fileSize: RecordingRobustness.minimumSalvageableBytes, finishedSuccessfully: false))
  }

  @Test("Best salvage picks the largest usable file")
  func bestSalvagePicksLargest() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("salvage-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let small = dir.appendingPathComponent("small.wav")
    let large = dir.appendingPathComponent("large.wav")
    let empty = dir.appendingPathComponent("empty.wav")
    try Data(repeating: 1, count: 100).write(to: small)
    try Data(repeating: 2, count: 4_000).write(to: large)
    try Data().write(to: empty)

    #expect(RecordingRobustness.bestSalvage(urls: [small, empty, large]) == large)
    #expect(RecordingRobustness.bestSalvage(urls: [empty]) == nil)
    #expect(RecordingRobustness.bestSalvage(urls: []) == nil)
  }

  // MARK: - Sleep / wake

  @Test("Sleep during a take stops and salvages; sleep while idle does nothing")
  func sleepStopsATake() {
    #expect(
      RecordingRobustness.actionForInterruption(
        .willSleep, isRecording: true, recorderStillRunning: true) == .stopAndSalvage)
    #expect(
      RecordingRobustness.actionForInterruption(
        .willSleep, isRecording: false, recorderStillRunning: false) == .none)
  }

  @Test("Wake only salvages when we still think we are recording but the recorder is dead")
  func wakeSalvagesDeadRecorderOnly() {
    #expect(
      RecordingRobustness.actionForInterruption(
        .didWake, isRecording: true, recorderStillRunning: false) == .stopAndSalvage)
    #expect(
      RecordingRobustness.actionForInterruption(
        .didWake, isRecording: true, recorderStillRunning: true) == .none)
    #expect(
      RecordingRobustness.actionForInterruption(
        .didWake, isRecording: false, recorderStillRunning: false) == .none)
  }

  // MARK: - Crash leftovers

  @Test("Recording artifact names match the files we write")
  func artifactNames() {
    #expect(RecordingRobustness.isRecordingArtifact(fileName: "recording_1710000000.wav"))
    #expect(RecordingRobustness.isRecordingArtifact(fileName: "recording_1710000000_chunk0.wav"))
    #expect(RecordingRobustness.isRecordingArtifact(fileName: "recording_1710000000_merged.wav"))
    #expect(!RecordingRobustness.isRecordingArtifact(fileName: "notes.txt"))
    #expect(!RecordingRobustness.isRecordingArtifact(fileName: "chunk_0.wav"))
  }

  @Test("A leftover take is recovered; extras are deleted")
  func leftoverRecovered() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let keep = RecordingRobustness.Artifact(name: "recording_2.wav", size: 8_000, modified: now)
    let extra = RecordingRobustness.Artifact(name: "recording_1.wav", size: 200, modified: now)
    let action = DictationRecordingMarker.launchAction(
      payload: .init(pid: 42, mode: "transcription", discarded: false),
      candidates: [extra, keep],
      ownerIsAlive: false)
    #expect(action == .recover(keep: "recording_2.wav", delete: ["recording_1.wav"]))
  }

  @Test("A discarded take is deleted, never recovered")
  func discardedNotRecovered() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let file = RecordingRobustness.Artifact(name: "recording_1.wav", size: 8_000, modified: now)
    let action = DictationRecordingMarker.launchAction(
      payload: .init(pid: 42, mode: "transcription", discarded: true),
      candidates: [file],
      ownerIsAlive: false)
    #expect(action == .deleteLeftovers(["recording_1.wav"]))
  }

  @Test("Another live instance owns the leftover — leave it alone")
  func liveOwnerLeftAlone() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let file = RecordingRobustness.Artifact(name: "recording_1.wav", size: 8_000, modified: now)
    let action = DictationRecordingMarker.launchAction(
      payload: .init(pid: 42, mode: "transcription", discarded: false),
      candidates: [file],
      ownerIsAlive: true)
    #expect(action == .none)
  }

  @Test("Leftover files without a marker are still recovered")
  func leftoverWithoutMarker() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let file = RecordingRobustness.Artifact(name: "recording_1.wav", size: 8_000, modified: now)
    let action = DictationRecordingMarker.launchAction(
      payload: nil, candidates: [file], ownerIsAlive: false)
    #expect(action == .recover(keep: "recording_1.wav", delete: []))
  }

  @Test("Tiny leftovers are deleted rather than offered as a take")
  func tinyLeftoversDeleted() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let tiny = RecordingRobustness.Artifact(
      name: "recording_1.wav", size: 10, modified: now)
    let action = DictationRecordingMarker.launchAction(
      payload: nil, candidates: [tiny], ownerIsAlive: false)
    #expect(action == .deleteLeftovers(["recording_1.wav"]))
  }

  @Test("Owner liveness: other live pid counts, own pid and dead pid do not")
  func ownerIsAlive() {
    #expect(DictationRecordingMarker.ownerIsAlive(pid: 42, currentPid: 1, isAlive: { _ in true }))
    #expect(!DictationRecordingMarker.ownerIsAlive(pid: 42, currentPid: 1, isAlive: { _ in false }))
    #expect(!DictationRecordingMarker.ownerIsAlive(pid: 42, currentPid: 42, isAlive: { _ in true }))
  }

  @Test("A just-written file is not listed as a leftover")
  func quietIntervalSkipsFreshFiles() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("fresh-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("recording_now.wav")
    try Data(repeating: 1, count: 200).write(to: url)
    let now = Date()
    let listed = RecordingRobustness.listRecordingArtifacts(in: dir, now: now)
    #expect(listed.isEmpty)
    let later = now.addingTimeInterval(RecordingRobustness.leftoverQuietInterval + 1)
    let aged = RecordingRobustness.listRecordingArtifacts(in: dir, now: later)
    #expect(aged.map(\.name) == ["recording_now.wav"])
  }

  // MARK: - Disk

  @Test("Recording refuses to start when free space is below the reserve")
  func recordingRefusedWhenFull() throws {
    #expect(throws: DiskSpaceError.self) {
      try DiskSpace.requireForRecording(availableBytes: 5_000_000)
    }
    try DiskSpace.requireForRecording(availableBytes: 200_000_000)
    try DiskSpace.requireForRecording(availableBytes: nil)
  }

  @Test("Critical disk floor is below the start reserve")
  func criticalFloor() {
    #expect(DiskSpace.isCriticallyLow(availableBytes: 1_000_000))
    #expect(!DiskSpace.isCriticallyLow(availableBytes: 50_000_000))
    #expect(!DiskSpace.isCriticallyLow(availableBytes: nil))
    #expect(RecordingRobustness.criticalReserveMB < RecordingRobustness.recordingReserveMB)
  }

  @Test("Download require still uses the 1.2 margin and is injectable")
  func downloadRequireInjected() throws {
    #expect(throws: DiskSpaceError.self) {
      try DiskSpace.require(estimatedSizeMB: 100, availableBytes: 50_000_000)
    }
    try DiskSpace.require(estimatedSizeMB: 100, availableBytes: 200_000_000)
  }

  @Test("Cocoa and POSIX out-of-space errors are recognized")
  func outOfSpaceDetection() {
    let cocoa = NSError(
      domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError, userInfo: nil)
    let posix = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC), userInfo: nil)
    #expect(RecordingRobustness.isOutOfSpace(cocoa))
    #expect(RecordingRobustness.isOutOfSpace(posix))
    #expect(!RecordingRobustness.isOutOfSpace(NSError(domain: "x", code: 1)))
  }

  @Test("Recording disk-space error explains the recording, not a model download")
  func recordingDiskMessage() {
    let error = DiskSpaceError.insufficientForRecording(neededMB: 100, availableMB: 8)
    let text = error.errorDescription ?? ""
    #expect(text.contains("recording") || text.contains("100"))
    #expect(!text.contains("download"))
    let full = RecordingRobustness.diskFullError()
    #expect(full.code == RecordingRobustness.diskFullErrorCode)
    #expect((full.userInfo[NSLocalizedDescriptionKey] as? String)?.contains("disk") == true)
  }

  // MARK: - Long recordings

  @Test("Dictate chunks have a max duration so a monologue cannot grow without bound")
  func dictateMaxChunkDuration() {
    #expect(AppConstants.dictateChunkMaxDuration > AppConstants.dictateChunkMinDuration)
    #expect(AppConstants.dictateChunkMaxDuration <= AppConstants.chunkDurationSeconds + 0.01)
  }
}
