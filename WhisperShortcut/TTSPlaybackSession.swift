import AVFoundation
import Foundation

/// Owns one Read Aloud playback end to end: the audio graph, the chunk queue, and the bookkeeping
/// that decides when an utterance is finished.
///
/// This used to be four loose `tts*` fields plus the `AVAudioEngine` trio on `MenuBarController` —
/// a scheduled/drained counter pair, a "stream closed" flag and an "accepting chunks" flag that
/// every begin / enqueue / close / stop / cancel path had to reset in exactly the right combination,
/// inside a class that also draws menus, drives the clipboard and holds `appState`. Playback is not
/// a menu concern, and the counters govern correctness: whether the *last* buffer tears the session
/// down, and whether a chunk whose synthesis landed after a Stop is allowed to start talking again.
/// Same reasoning, and the same shape, as `LiveMeetingSession`.
///
/// What deliberately stays outside: `appState` and the `ttsDidStop` notification. Those belong to
/// the owner, which learns about the lifecycle through the callbacks below.
final class TTSPlaybackSession {

  // MARK: - Collaborators

  /// The first buffer has been scheduled and the node is playing. The owner moves to `.speaking`.
  private let onPlaybackStarted: () -> Void
  /// The stream was closed and every scheduled buffer has played. The engine is already torn down.
  private let onPlaybackCompleted: () -> Void
  /// Scheduling failed (format/buffer/engine). The owner ends the Read Aloud session and reports it.
  private let onFailure: (Error) -> Void

  init(
    onPlaybackStarted: @escaping () -> Void,
    onPlaybackCompleted: @escaping () -> Void,
    onFailure: @escaping (Error) -> Void
  ) {
    self.onPlaybackStarted = onPlaybackStarted
    self.onPlaybackCompleted = onPlaybackCompleted
    self.onFailure = onFailure
  }

  // MARK: - Audio format

  /// Raw PCM format every TTS provider returns: s16le, 24 kHz, mono.
  private static let sampleRate: Double = 24000
  private static let channels: UInt32 = 1
  private static let bitsPerChannel: UInt32 = 16

  // MARK: - Playback state

  private var audioEngine: AVAudioEngine?
  private var audioPlayerNode: AVAudioPlayerNode?
  private var timePitchNode: AVAudioUnitTimePitch?

  /// Token for the in-flight playback. Stale `scheduleBuffer` completions check this against their
  /// captured token and no-op when the user has started a new playback.
  private var currentPlaybackToken: UUID?

  /// Buffers handed to the player node so far, and how many of them have finished playing.
  /// Playback is over when the synthesis side has closed the stream *and* these are equal —
  /// a count comparison rather than "the last chunk finished", because a failed chunk means the
  /// final index may never arrive.
  private var scheduledChunkCount = 0
  private var drainedChunkCount = 0
  /// Set when no further chunks will be enqueued (synthesis finished, failed, or was cancelled).
  private var streamClosed = false
  /// Whether late-arriving chunks may still be scheduled. Cleared by Stop and by stream close, so
  /// a chunk whose synthesis landed after the user cancelled cannot spin up a fresh engine and
  /// start talking out of an idle state.
  private var acceptingChunks = false

  // MARK: - Queries used by the owner

  /// True while audio is actually coming out of the speakers.
  var isPlaying: Bool { audioEngine?.isRunning == true }
  /// True once synthesis declared itself finished — Stop then has no network work left to cancel.
  var isStreamClosed: Bool { streamClosed }
  /// True once at least one chunk was scheduled, i.e. the streaming path is in use.
  var hasScheduledChunks: Bool { scheduledChunkCount > 0 }

  // MARK: - Lifecycle

  /// Resets the per-session chunk bookkeeping. Called before the first chunk of a Read Aloud.
  func begin() {
    scheduledChunkCount = 0
    drainedChunkCount = 0
    streamClosed = false
    acceptingChunks = true
  }

  /// Plays one fully synthesized utterance. Kept as the non-streaming entry point: single-chunk
  /// syntheses and any future caller that already holds the complete audio land here.
  func play(audioData: Data) {
    begin()
    enqueue(audioData, index: 0, totalChunks: 1)
    closeStream()
  }

  /// Schedules one synthesized chunk for playback, starting the engine (and the owner's speaking
  /// state) on the first one. Chunks arrive in playback order — `ChunkTTSService` holds back
  /// out-of-order completions — so appending them to the player node's queue is all the ordering
  /// needed.
  ///
  /// Being faster than realtime is what makes this work: synthesis runs at roughly 0.6× the audio
  /// duration it produces, so the queue stays ahead of the playhead. If it ever doesn't, the node
  /// drains and the next chunk starts a beat late; a logged gap, not a broken playback.
  func enqueue(_ pcm: Data, index: Int, totalChunks: Int) {
    guard acceptingChunks else {
      DebugLogger.log("TTS-PLAYBACK: Dropping chunk \(index) — Read Aloud session already ended")
      return
    }
    guard !pcm.isEmpty else {
      DebugLogger.logWarning("TTS-PLAYBACK: Chunk \(index) was empty — nothing to schedule")
      return
    }
    do {
      let buffer = try Self.makeBuffer(from: pcm)
      let isFirstChunk = scheduledChunkCount == 0
      if isFirstChunk {
        try startEngine(format: buffer.format)
      }
      guard let playerNode = audioPlayerNode, let token = currentPlaybackToken else {
        DebugLogger.logWarning("TTS-PLAYBACK: Chunk \(index) arrived without an active player — dropping")
        return
      }

      scheduledChunkCount += 1
      playerNode.scheduleBuffer(buffer) { [weak self] in
        Task { @MainActor in
          guard let self, self.currentPlaybackToken == token else { return }
          self.drainedChunkCount += 1
          DebugLogger.logDebug(
            "TTS-PLAYBACK: Chunk \(index) finished (\(self.drainedChunkCount)/\(self.scheduledChunkCount) drained)")
          self.completeIfDrained(token: token)
        }
      }

      if isFirstChunk {
        playerNode.play()
        onPlaybackStarted()
        DebugLogger.logSuccess(
          "TTS-PLAYBACK: Playback started on chunk 1/\(totalChunks) (\(pcm.count) bytes) — remaining chunks stream in behind it")
      } else {
        DebugLogger.log("TTS-PLAYBACK: Queued chunk \(index + 1)/\(totalChunks) (\(pcm.count) bytes)")
      }
    } catch {
      DebugLogger.logError("TTS-PLAYBACK: Failed to play audio: \(error.localizedDescription)")
      onFailure(error)
    }
  }

  /// Declares that no further chunks are coming. Playback teardown waits for this: without it a
  /// gap between two chunks (queue drained before the next one arrived) would be indistinguishable
  /// from the end of the utterance and cut the rest off.
  func closeStream() {
    streamClosed = true
    acceptingChunks = false
    guard let token = currentPlaybackToken else { return }
    completeIfDrained(token: token)
  }

  /// Refuses chunks that are still in flight without tearing playback down. Used by the cancel
  /// paths that leave the audio alone but must stop new work from reviving the session.
  func refuseFurtherChunks() {
    acceptingChunks = false
  }

  /// Stops all TTS audio playback and cleans up resources.
  func stop() {
    currentPlaybackToken = nil
    acceptingChunks = false
    audioPlayerNode?.stop()
    audioEngine?.stop()
    audioEngine = nil
    audioPlayerNode = nil
    timePitchNode = nil
  }

  /// Ends the session once the stream is closed and every scheduled buffer has played.
  private func completeIfDrained(token: UUID) {
    guard currentPlaybackToken == token,
          streamClosed,
          scheduledChunkCount > 0,
          drainedChunkCount >= scheduledChunkCount
    else { return }

    DebugLogger.log("TTS-PLAYBACK: Playback completed (\(scheduledChunkCount) chunks)")
    currentPlaybackToken = nil
    audioPlayerNode?.stop()
    audioEngine?.stop()
    audioEngine = nil
    audioPlayerNode = nil
    timePitchNode = nil
    onPlaybackCompleted()
  }

  // MARK: - Audio graph

  /// Converts raw s16le PCM into the Float32 buffer the playback graph expects.
  ///
  /// Providers return Int16 PCM, but AVAudioUnitTimePitch (and other AVAudioUnit effects) require
  /// non-interleaved Float32 on their bus — connecting with an Int16 format raises an
  /// Objective-C NSException inside `engine.connect(...)` that does NOT bridge to Swift's
  /// try/catch, leaving the function silently abandoned and the owner's state stuck on
  /// `.processing`. Converting up-front makes the entire graph speak Float32, whether or not the
  /// speed node is inserted.
  private static func makeBuffer(from audioData: Data) throws -> AVAudioPCMBuffer {
    guard let audioFormat = AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: sampleRate,
      channels: channels,
      interleaved: false
    ) else {
      DebugLogger.logError("TTS-PLAYBACK: Failed to create audio format")
      throw TTSPlaybackError.failedToCreateAudioFormat
    }

    let bytesPerFrame = Int(channels * (bitsPerChannel / 8))
    let frameCount = audioData.count / bytesPerFrame

    guard frameCount > 0, let buffer = AVAudioPCMBuffer(
      pcmFormat: audioFormat, frameCapacity: AVAudioFrameCount(frameCount)
    ) else {
      DebugLogger.logError("TTS-PLAYBACK: Failed to create audio buffer")
      throw TTSPlaybackError.failedToCreateBuffer
    }

    buffer.frameLength = AVAudioFrameCount(frameCount)
    let int16ToFloat = 1.0 / Float(Int16.max)
    audioData.withUnsafeBytes { bytes in
      guard let baseAddress = bytes.baseAddress else { return }
      let int16Pointer = baseAddress.assumingMemoryBound(to: Int16.self)
      if let channelData = buffer.floatChannelData {
        for i in 0..<frameCount {
          channelData[0][i] = Float(int16Pointer[i]) * int16ToFloat
        }
      }
    }
    return buffer
  }

  /// Tears down any previous engine and builds a fresh one for this playback session.
  private func startEngine(format: AVAudioFormat) throws {
    if let existingEngine = audioEngine {
      existingEngine.stop()
      audioEngine = nil
    }
    if let existingNode = audioPlayerNode {
      existingNode.stop()
      audioPlayerNode = nil
    }

    let engine = AVAudioEngine()
    let playerNode = AVAudioPlayerNode()
    engine.attach(playerNode)

    // Insert a time-pitch node when the user has picked a non-1× rate so the audio
    // plays faster/slower without changing pitch. `rate` is a multiplier where
    // 1.0 = normal (the API range is 1/32 ... 32, so our 0.75–2.0 picker is safe).
    let configuredSpeed = ReadAloudPreferences.speed.rawValue
    if configuredSpeed != 1.0 {
      let timePitch = AVAudioUnitTimePitch()
      timePitch.rate = Float(configuredSpeed)
      engine.attach(timePitch)
      engine.connect(playerNode, to: timePitch, format: format)
      engine.connect(timePitch, to: engine.mainMixerNode, format: format)
      timePitchNode = timePitch
    } else {
      engine.connect(playerNode, to: engine.mainMixerNode, format: format)
      timePitchNode = nil
    }

    self.audioEngine = engine
    self.audioPlayerNode = playerNode
    currentPlaybackToken = UUID()

    try engine.start()
  }
}
