import Testing
import Foundation
@testable import WhisperShortcut_AppStore

/// Session bookkeeping that needs no audio hardware: which chunks are accepted and how a session
/// that never produced audio ends.
@Suite("TTS playback session — lifecycle")
@MainActor
struct TTSPlaybackSessionTests {

  private final class Events {
    var started = 0
    var completed = 0
    var failures: [Error] = []
  }

  private func makeSession(_ events: Events) -> TTSPlaybackSession {
    TTSPlaybackSession(
      onPlaybackStarted: { events.started += 1 },
      onPlaybackCompleted: { events.completed += 1 },
      onFailure: { events.failures.append($0) },
      onBufferingChanged: { _ in },
      onProgress: { _, _, _ in })
  }

  @Test("A chunk from an earlier Read Aloud is dropped")
  func staleGenerationChunkIsDropped() {
    let events = Events()
    let session = makeSession(events)
    let stale = session.begin()
    _ = session.begin()
    session.enqueue(Data(count: 4800), index: 0, totalChunks: 1, generation: stale)
    #expect(!session.hasScheduledChunks)
    #expect(events.started == 0)
    #expect(events.failures.isEmpty)
  }

  @Test("An empty synthesis ends the session through the failure path")
  func emptySynthesisFails() {
    let events = Events()
    let session = makeSession(events)
    session.play(audioData: Data())
    #expect(events.failures.count == 1)
    #expect(events.failures.first is TTSPlaybackError)
    #expect(events.started == 0)
    #expect(events.completed == 0)
  }

  @Test("Closing a stream that never got audio fails exactly once")
  func closeWithoutAudioFailsOnce() {
    let events = Events()
    let session = makeSession(events)
    let id = session.begin()
    session.enqueue(Data(), index: 0, totalChunks: 1, generation: id)
    session.closeStream()
    session.closeStream()
    #expect(events.failures.count == 1)
  }

  @Test("Closing the stream after Stop does not report anything")
  func closeAfterStopIsSilent() {
    let events = Events()
    let session = makeSession(events)
    session.begin()
    session.stop()
    session.closeStream()
    #expect(events.failures.isEmpty)
    #expect(events.completed == 0)
  }

  @Test("An engine configuration change without a running playback is ignored")
  func configurationChangeWithoutPlayback() {
    let events = Events()
    let session = makeSession(events)
    session.begin()
    session.handleEngineConfigurationChange()
    #expect(events.completed == 0)
  }

  @Test("Refusing chunks before any audio is not a playback failure")
  func refusalBeforeAudioIsSilent() {
    let events = Events()
    let session = makeSession(events)
    session.begin()
    session.refuseFurtherChunks()
    session.refuseFurtherChunks()
    #expect(events.failures.isEmpty)
    #expect(events.completed == 0)
    #expect(!session.isPlaying)
    #expect(!session.isStreamClosed)
  }

  /// 100 ms of s16le silence at 24 kHz — long enough for the player to schedule it, short
  /// enough that a drain finishes inside the test.
  private static let silenceChunk = Data(count: 4800)

  @Test("A producer error after scheduled audio ends the session once the queue drains")
  func refusalAfterScheduledAudioCompletesWhenDrained() async {
    let events = Events()
    let session = makeSession(events)
    defer { session.stop() }
    let id = session.begin()
    session.enqueue(Self.silenceChunk, index: 0, totalChunks: 2, generation: id)
    session.enqueue(Self.silenceChunk, index: 1, totalChunks: 2, generation: id)
    #expect(events.failures.isEmpty)
    #expect(session.hasScheduledChunks)
    #expect(session.isPlaying)
    #expect(events.started == 1)
    #expect(events.completed == 0)

    // The producer threw after partial audio. Refuse twice: the error path and a late
    // cancel must not complete the session more than once.
    session.refuseFurtherChunks()
    session.refuseFurtherChunks()
    #expect(session.isStreamClosed)
    #expect(session.isPlaying)
    #expect(events.completed == 0)

    let deadline = ContinuousClock.now + .seconds(3)
    while session.isPlaying, ContinuousClock.now < deadline {
      try? await Task.sleep(for: .milliseconds(20))
    }
    #expect(!session.isPlaying)
    #expect(events.completed == 1)
    #expect(events.failures.isEmpty)
  }

  @Test("Refusing after the queue already drained ends the session silently, exactly once")
  func refusalAfterDrainedQueueIsSilent() async {
    let events = Events()
    let session = makeSession(events)
    defer { session.stop() }
    let id = session.begin()
    session.enqueue(Self.silenceChunk, index: 0, totalChunks: 2, generation: id)
    #expect(session.hasScheduledChunks)
    #expect(session.isPlaying)

    // Let the lone 100 ms buffer play out. The stream is still open, so the session stays up.
    try? await Task.sleep(for: .milliseconds(600))
    #expect(session.isPlaying)
    #expect(events.completed == 0)

    // The producer then fails. The refusal ends playback itself, and must not fire the
    // success callback (the owner posts `ttsDidStop` once and shows the error).
    #expect(session.refuseFurtherChunks())
    #expect(!session.isPlaying)
    #expect(events.completed == 0)
    #expect(events.failures.isEmpty)

    // A late cancel refuses again: nothing left to end.
    #expect(!session.refuseFurtherChunks())
    #expect(events.completed == 0)
  }

  @Test("Refusing while audio is still playing leaves the single completion to the drain")
  func refusalWhileStillPlayingCompletesOnceAfterDrain() async {
    let events = Events()
    let session = makeSession(events)
    defer { session.stop() }
    let id = session.begin()
    for index in 0..<3 {
      session.enqueue(Self.silenceChunk, index: index, totalChunks: 3, generation: id)
    }
    #expect(session.isPlaying)

    // Producer error mid-stream: the refusal must not end playback itself, so the owner has to
    // leave `ttsDidStop` to the completion callback that follows the drain.
    #expect(!session.refuseFurtherChunks())
    #expect(session.isPlaying)
    #expect(events.completed == 0)
    #expect(!MenuBarController.finishShouldPostStop(
      transitionPostedStop: false, playbackStillDraining: session.isPlaying))

    let deadline = ContinuousClock.now + .seconds(3)
    while session.isPlaying, ContinuousClock.now < deadline {
      try? await Task.sleep(for: .milliseconds(20))
    }
    #expect(events.completed == 1)
    #expect(!session.refuseFurtherChunks())
    #expect(events.completed == 1)
  }

  @Test("finish posts ttsDidStop only when nothing else will")
  func finishPostsStopOnlyWhenNothingElseWill() {
    #expect(MenuBarController.finishShouldPostStop(transitionPostedStop: false, playbackStillDraining: false))
    #expect(!MenuBarController.finishShouldPostStop(transitionPostedStop: true, playbackStillDraining: false))
    #expect(!MenuBarController.finishShouldPostStop(transitionPostedStop: false, playbackStillDraining: true))
  }
}
