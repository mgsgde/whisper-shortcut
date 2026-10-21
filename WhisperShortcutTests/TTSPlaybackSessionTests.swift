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

  @Test("begin() hands out a new generation every time")
  func generationIncrements() {
    let session = makeSession(Events())
    let first = session.begin()
    let second = session.begin()
    #expect(second == first + 1)
    #expect(session.generation == second)
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
}
