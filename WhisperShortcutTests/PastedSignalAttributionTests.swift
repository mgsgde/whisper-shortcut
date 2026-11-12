import Foundation
import Testing

@testable import WhisperShortcut_AppStore

/// `runAudioJob` logs the interaction first and `pasted` second. These tests replay that order on
/// the shared logger (which writes to a temp directory under the test host).
@Suite("Pasted signal attribution", .serialized)
struct PastedSignalAttributionTests {

  private let mode = InteractionMode.transcription.rawValue

  private func flush() async {
    await withCheckedContinuation { continuation in
      ContextLogger.shared.performAfterInteractionWrites { continuation.resume() }
    }
  }

  private func interactionTimestamps() -> [String] {
    UserContextLog.decodeLines(
      ContextLogger.shared.interactionLogFiles(lastDays: 2), as: InteractionLogEntry.self
    ).filter { $0.mode == mode }.map(\.ts)
  }

  private func signals(_ kind: OutcomeSignal) -> [SignalLogEntry] {
    UserContextLog.decodeLines(
      ContextLogger.shared.signalLogFiles(lastDays: 2), as: SignalLogEntry.self
    ).filter { $0.kind == kind.rawValue }
  }

  @Test("the test host never writes into the real UserContext directory")
  func testsUseTempDirectory() {
    let real = AppSupportPaths.whisperShortcutApplicationSupportURL().appendingPathComponent("UserContext")
    #expect(ContextLogger.shared.directoryURL.standardizedFileURL != real.standardizedFileURL)
  }

  @Test("pasted logged after its interaction references that interaction, with no phantom restart")
  func pastedReferencesPastedInteraction() async throws {
    try #require(ContextLoggingPreference.isEnabled)
    let logger = ContextLogger.shared
    let restartsBefore = signals(.dictationRestart).count
    let pastedBefore = signals(.pasted).count

    logger.logTranscription(result: "first", model: "test")
    // Distinct timestamps (millisecond resolution).
    try await Task.sleep(for: .milliseconds(20))
    logger.logTranscription(result: "second", model: "test")
    logger.logSignal(.pasted, mode: mode, detail: ["chars": "6", "targetBundleId": "test"])
    logger.noteDictationStart(autoPasteAvailable: true)
    await flush()

    let stamps = interactionTimestamps()
    let second = try #require(stamps.last)
    let newPasted = signals(.pasted).dropFirst(pastedBefore)
    #expect(newPasted.count == 1)
    #expect(newPasted.first?.refTs == second)
    #expect(signals(.dictationRestart).count == restartsBefore)
  }

  @Test("an unpasted dictation followed by a quick restart is flagged against that dictation")
  func unpastedRestartReferencesInteraction() async throws {
    try #require(ContextLoggingPreference.isEnabled)
    let logger = ContextLogger.shared
    let restartsBefore = signals(.dictationRestart).count

    logger.logTranscription(result: "unpasted", model: "test")
    logger.noteDictationStart(autoPasteAvailable: true)
    await flush()

    let latest = try #require(interactionTimestamps().last)
    let newRestarts = signals(.dictationRestart).dropFirst(restartsBefore)
    #expect(newRestarts.count == 1)
    #expect(newRestarts.first?.refTs == latest)
  }

  @Test("a dictation row carries the processing latency it was given")
  func transcriptionRowCarriesLatency() async throws {
    try #require(ContextLoggingPreference.isEnabled)
    ContextLogger.shared.logTranscription(result: "timed", model: "test", latencyMs: 1234)
    await flush()
    let rows = UserContextLog.decodeLines(
      ContextLogger.shared.interactionLogFiles(lastDays: 2), as: InteractionLogEntry.self)
    #expect(rows.last?.latencyMs == 1234)
  }
}
