import AVFoundation
import Foundation

/// Owns one Read Aloud playback end to end: the audio graph, the chunk queue, and the bookkeeping
/// that decides when an utterance is finished. A starved flag tracks a drained queue while
/// synthesis is still delivering, so the next chunk can re-anchor the playhead instead of
/// letting the node's sample time run ahead through the gap.
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
  /// Flipped to true when the player's queue ran dry while synthesis is still delivering (a gap
  /// between chunks), back to false when the next chunk is scheduled. Drives the pill's spinner.
  private let onBufferingChanged: (Bool) -> Void
  /// Ten times a second while the graph is up: playhead and the audio received so far, in seconds
  /// of source audio (independent of the playback rate). Drives the pill's scrubber.
  private let onProgress: (_ position: TimeInterval, _ duration: TimeInterval) -> Void

  init(
    onPlaybackStarted: @escaping () -> Void,
    onPlaybackCompleted: @escaping () -> Void,
    onFailure: @escaping (Error) -> Void,
    onBufferingChanged: @escaping (Bool) -> Void,
    onProgress: @escaping (_ position: TimeInterval, _ duration: TimeInterval) -> Void
  ) {
    self.onPlaybackStarted = onPlaybackStarted
    self.onPlaybackCompleted = onPlaybackCompleted
    self.onFailure = onFailure
    self.onBufferingChanged = onBufferingChanged
    self.onProgress = onProgress
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

  /// Every chunk received so far, in playback order, kept for the whole session so the user can
  /// seek back into audio the player node has already consumed. A minute of 24 kHz mono Float32
  /// is under 6 MB — cheap for what it buys.
  private var receivedChunks: [AVAudioPCMBuffer] = []
  /// Total frames in `receivedChunks`; the scrubber's (growing) upper bound.
  private var totalFrames: AVAudioFramePosition = 0

  /// Buffers handed to the player node in the current *segment*, and how many of them have
  /// finished playing. A segment is what one `play()` covers: everything from the first chunk
  /// (or from the seek target) to the end of the received audio, plus chunks queued behind it
  /// afterwards. Playback is over when the synthesis side has closed the stream *and* these are
  /// equal — a count comparison rather than "the last chunk finished", because a failed chunk means
  /// the final index may never arrive. A seek starts a new segment and resets both.
  private var scheduledChunkCount = 0
  private var drainedChunkCount = 0
  /// Bumped by every seek so a completion handler from the previous segment's queue (which
  /// `playerNode.stop()` fires immediately) cannot be counted against the new one.
  private var segmentGeneration = 0
  /// Source frame at which the current segment's `play()` started. Playhead = this + the player's
  /// own sample time (the player node advances at the rate the time-pitch unit pulls from it, so
  /// its sample time is source frames regardless of the playback speed).
  private var segmentStartFrame: AVAudioFramePosition = 0
  /// Playhead captured on pause — the player node reports no render time while paused.
  private var pausedAtFrame: AVAudioFramePosition?
  private var progressTimer: Timer?
  /// Set when no further chunks will be enqueued (synthesis finished, failed, or was cancelled).
  private var streamClosed = false
  /// Whether late-arriving chunks may still be scheduled. Cleared by Stop and by stream close, so
  /// a chunk whose synthesis landed after the user cancelled cannot spin up a fresh engine and
  /// start talking out of an idle state.
  private var acceptingChunks = false
  /// Queue ran dry while the stream is still open. Set immediately so `enqueue` can re-anchor;
  /// the pill spinner waits on `bufferingDebounce`.
  private var isStarved = false
  private var starvedSince: Date?
  private var bufferingReported = false
  private var bufferingDebounce: Timer?

  // MARK: - Queries used by the owner

  /// True while a playback session holds the audio graph — including while paused, since the
  /// session is still the thing on screen that Stop must tear down.
  var isPlaying: Bool { audioEngine?.isRunning == true }
  /// True while the user has paused playback from the pill. Cleared by resume, stop and teardown.
  private(set) var isPaused = false
  /// True once synthesis declared itself finished — Stop then has no network work left to cancel.
  var isStreamClosed: Bool { streamClosed }
  /// True once at least one chunk was scheduled, i.e. the streaming path is in use.
  var hasScheduledChunks: Bool { !receivedChunks.isEmpty }
  /// Seconds of source audio received so far.
  var duration: TimeInterval { Double(totalFrames) / Self.sampleRate }
  /// Playhead in seconds of source audio.
  var position: TimeInterval { Double(currentFrame) / Self.sampleRate }

  // MARK: - Lifecycle

  /// Resets the per-session chunk bookkeeping. Called before the first chunk of a Read Aloud.
  func begin() {
    receivedChunks = []
    totalFrames = 0
    scheduledChunkCount = 0
    drainedChunkCount = 0
    segmentGeneration = 0
    segmentStartFrame = 0
    pausedAtFrame = nil
    streamClosed = false
    acceptingChunks = true
    bufferingDebounce?.invalidate()
    bufferingDebounce = nil
    isStarved = false
    starvedSince = nil
    bufferingReported = false
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
  /// What keeps the queue ahead of the playhead is the chunk-size ramp (`TextChunker`,
  /// `AppConstants.ttsChunkGrowthFactor`): all chunks start synthesizing at once, and each chunk's
  /// audio is long enough to cover the next one's synthesis up to 2× playback speed. Synthesis
  /// being faster than realtime at 1× is not enough on its own — at 1.5× a 120-char opener could
  /// not cover a 500-char follower (7.5 s of silence, 2026-09-18). The streaming providers
  /// (OpenAI, Gemini via `streamGenerateContent`) start emitting within ~1–3 s, so the opener
  /// itself lands early. If the queue drains anyway, the buffering spinner shows until the next
  /// chunk arrives (`onBufferingChanged`); a logged gap, not a broken playback.
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
      let isFirstChunk = receivedChunks.isEmpty
      if isFirstChunk {
        try startEngine(format: buffer.format)
      }
      guard let playerNode = audioPlayerNode else {
        DebugLogger.logWarning("TTS-PLAYBACK: Chunk \(index) arrived without an active player — dropping")
        return
      }
      receivedChunks.append(buffer)
      totalFrames += AVAudioFramePosition(buffer.frameLength)
      if isStarved {
        // AVAudioPlayerNode's sample time keeps advancing while its queue is empty, so
        // currentFrame = segmentStartFrame + sampleTime would run ahead of the true source
        // position by the length of the gap for the rest of playback. seek(to:) starts a
        // fresh segment anchored at the new chunk, flushes nothing (the queue is empty)
        // and respects a paused state.
        let resumeAt = Double(totalFrames - AVAudioFramePosition(buffer.frameLength)) / Self.sampleRate
        let gap = starvedSince.map { Date().timeIntervalSince($0) } ?? 0
        let unclamped = audioPlayerNode.flatMap { node in
          node.lastRenderTime.flatMap { node.playerTime(forNodeTime: $0) }
        }.map { segmentStartFrame + $0.sampleTime }
        let driftFrames = unclamped.map { $0 - (totalFrames - AVAudioFramePosition(buffer.frameLength)) }
        let line = "TTS-PLAYBACK: Resumed after \(String(format: "%.1f", gap)) s buffering gap — chunk \(index + 1)/\(totalChunks) re-anchored at \(formatSeconds(resumeAt)) (node sample time had advanced \(driftFrames.map(String.init) ?? "n/a") frames past received audio)"
        if bufferingReported { DebugLogger.logWarning(line) } else { DebugLogger.logDebug(line) }
        seek(to: resumeAt)
      } else {
        schedule(buffer, on: playerNode)
      }

      if isFirstChunk {
        playerNode.play()
        startProgressTimer()
        onPlaybackStarted()
        DebugLogger.logSuccess(
          "TTS-PLAYBACK: Playback started on chunk 1/\(totalChunks) (\(pcm.count) bytes) — remaining chunks stream in behind it")
      } else if !isStarved {
        // Debug level: a streaming provider delivers a chunk as dozens of half-second slices.
        // After a re-anchor `seek` has already cleared `isStarved`, so this stays on the
        // non-starved append path only.
        DebugLogger.logDebug("TTS-PLAYBACK: Queued chunk \(index + 1)/\(totalChunks) (\(pcm.count) bytes)")
      }
    } catch {
      DebugLogger.logError("TTS-PLAYBACK: Failed to play audio: \(error.localizedDescription)")
      onFailure(error)
    }
  }

  /// Appends one buffer to the player node's queue for the current segment and counts it drained
  /// when it has played through (or when a seek's `stop()` flushes it — hence the generation check).
  private func schedule(_ buffer: AVAudioPCMBuffer, on playerNode: AVAudioPlayerNode) {
    guard let token = currentPlaybackToken else { return }
    let generation = segmentGeneration
    scheduledChunkCount += 1
    playerNode.scheduleBuffer(buffer) { [weak self] in
      Task { @MainActor in
        guard let self, self.currentPlaybackToken == token, self.segmentGeneration == generation
        else { return }
        self.drainedChunkCount += 1
        DebugLogger.logDebug(
          "TTS-PLAYBACK: Buffer finished (\(self.drainedChunkCount)/\(self.scheduledChunkCount) drained)")
        self.noteQueueDrainedIfStarved()
        self.completeIfDrained(token: token)
      }
    }
  }

  /// Leaves the starved state. Tells the pill only if it was told about the gap in the first place.
  private func clearStarvation() {
    bufferingDebounce?.invalidate()
    bufferingDebounce = nil
    isStarved = false
    starvedSince = nil
    if bufferingReported { bufferingReported = false; onBufferingChanged(false) }
  }

  /// Detects a drained queue while the stream is still open — a gap between chunks the user can
  /// hear. The flags are set immediately so `enqueue`'s re-anchor can react to `isStarved`; the
  /// pill's spinner and the warning log wait 300 ms behind `bufferingDebounce` so a streaming
  /// provider's quarter/half-second slices arriving a few ms late don't flicker the pill.
  private func noteQueueDrainedIfStarved() {
    guard !streamClosed, acceptingChunks, drainedChunkCount >= scheduledChunkCount, !isStarved else { return }
    isStarved = true
    starvedSince = Date()
    // A streaming provider's quarter/half-second slices can arrive a few ms late and drain the
    // queue for an instant. That is not a gap the user hears: the flags are set right away (so
    // the re-anchor in `enqueue` happens), but the warning and the pill's spinner wait 300 ms.
    bufferingDebounce?.invalidate()
    let timer = Timer(timeInterval: 0.3, repeats: false) { [weak self] _ in
      guard let self, self.isStarved else { return }
      self.bufferingReported = true
      DebugLogger.logWarning("TTS-PLAYBACK: Queue drained at \(self.formatSeconds(self.position)) with the stream still open — waiting for the next chunk")
      self.onBufferingChanged(true)
    }
    RunLoop.main.add(timer, forMode: .common)
    bufferingDebounce = timer
  }

  /// Declares that no further chunks are coming. Playback teardown waits for this: without it a
  /// gap between two chunks (queue drained before the next one arrived) would be indistinguishable
  /// from the end of the utterance and cut the rest off.
  func closeStream() {
    clearStarvation()
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

  // MARK: - Transport controls (driven by the pill)

  /// Pauses the player node in place. The engine keeps running so later chunks can still be
  /// scheduled behind the paused playhead, and `scheduleBuffer` completions simply wait.
  func pause() {
    guard isPlaying, !isPaused, let playerNode = audioPlayerNode else { return }
    pausedAtFrame = currentFrame
    playerNode.pause()
    isPaused = true
    DebugLogger.log("TTS-PLAYBACK: Paused at \(formatSeconds(position))")
  }

  func resume() {
    guard isPlaying, isPaused, let playerNode = audioPlayerNode else { return }
    isPaused = false
    pausedAtFrame = nil
    playerNode.play()
    DebugLogger.log("TTS-PLAYBACK: Resumed")
  }

  /// Moves the playhead to `seconds` of source audio (clamped to what has been received) and
  /// starts a new segment from there: the player's queue is flushed and refilled with the tail of
  /// the received audio, so seeking backwards replays consumed buffers and seeking forwards skips
  /// queued ones. Chunks that arrive later append behind the new segment as usual. Paused playback
  /// stays paused — the segment is queued but not started until `resume()`.
  func seek(to seconds: TimeInterval) {
    guard isPlaying, let playerNode = audioPlayerNode, !receivedChunks.isEmpty else { return }
    let targetFrame = max(0, min(totalFrames - 1, AVAudioFramePosition(seconds * Self.sampleRate)))

    segmentGeneration += 1
    scheduledChunkCount = 0
    drainedChunkCount = 0
    playerNode.stop()  // flushes the queue; resets the node's sample time to 0 on the next play()
    segmentStartFrame = targetFrame

    var chunkStart: AVAudioFramePosition = 0
    for chunk in receivedChunks {
      let chunkEnd = chunkStart + AVAudioFramePosition(chunk.frameLength)
      defer { chunkStart = chunkEnd }
      guard chunkEnd > targetFrame else { continue }
      if chunkStart >= targetFrame {
        schedule(chunk, on: playerNode)
      } else if let tail = Self.tail(of: chunk, from: AVAudioFrameCount(targetFrame - chunkStart)) {
        schedule(tail, on: playerNode)
      }
    }

    if isPaused {
      pausedAtFrame = targetFrame
    } else {
      playerNode.play()
    }
    DebugLogger.log("TTS-PLAYBACK: Seeked to \(formatSeconds(position)) / \(formatSeconds(duration))")
    onProgress(position, duration)
    clearStarvation()
  }

  /// `seek(to:)` relative to the current playhead — the pill's ±10 s buttons.
  func skip(by seconds: TimeInterval) {
    seek(to: position + seconds)
  }

  /// Source frame the playhead is at right now.
  private var currentFrame: AVAudioFramePosition {
    if let pausedAtFrame { return pausedAtFrame }
    guard let playerNode = audioPlayerNode,
          let nodeTime = playerNode.lastRenderTime,
          let playerTime = playerNode.playerTime(forNodeTime: nodeTime)
    else { return segmentStartFrame }
    return min(totalFrames, segmentStartFrame + playerTime.sampleTime)
  }

  private func startProgressTimer() {
    progressTimer?.invalidate()
    let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
      guard let self, self.isPlaying else { return }
      self.onProgress(self.position, self.duration)
    }
    RunLoop.main.add(timer, forMode: .common)
    progressTimer = timer
  }

  private func formatSeconds(_ seconds: TimeInterval) -> String {
    String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
  }

  /// Applies a new rate to the running graph. The time-pitch node is always in the chain (see
  /// `startEngine`), so this takes effect immediately, mid-buffer, without a rebuild.
  func setSpeed(_ speed: ReadAloudSpeed) {
    timePitchNode?.rate = Float(speed.rawValue)
    DebugLogger.log("TTS-PLAYBACK: Speed set to \(speed.displayName)")
  }

  /// Stops all TTS audio playback and cleans up resources.
  func stop() {
    clearStarvation()
    currentPlaybackToken = nil
    acceptingChunks = false
    tearDownGraph()
  }

  private func tearDownGraph() {
    progressTimer?.invalidate()
    progressTimer = nil
    bufferingDebounce?.invalidate()
    bufferingDebounce = nil
    isStarved = false
    starvedSince = nil
    bufferingReported = false
    isPaused = false
    pausedAtFrame = nil
    audioPlayerNode?.stop()
    audioEngine?.stop()
    audioEngine = nil
    audioPlayerNode = nil
    timePitchNode = nil
    receivedChunks = []
  }

  /// Ends the session once the stream is closed and every scheduled buffer has played.
  private func completeIfDrained(token: UUID) {
    guard currentPlaybackToken == token,
          streamClosed,
          scheduledChunkCount > 0,
          drainedChunkCount >= scheduledChunkCount
    else { return }

    DebugLogger.log("TTS-PLAYBACK: Playback completed (\(formatSeconds(duration)))")
    currentPlaybackToken = nil
    tearDownGraph()
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

  /// Copies `buffer` from `offset` to its end into a fresh buffer — the partial first chunk of a
  /// seek segment. Nil when nothing remains.
  private static func tail(of buffer: AVAudioPCMBuffer, from offset: AVAudioFrameCount) -> AVAudioPCMBuffer? {
    guard offset < buffer.frameLength,
          let source = buffer.floatChannelData,
          let tail = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength - offset),
          let destination = tail.floatChannelData
    else { return nil }
    let frames = Int(buffer.frameLength - offset)
    for channel in 0..<Int(buffer.format.channelCount) {
      destination[channel].update(from: source[channel] + Int(offset), count: frames)
    }
    tail.frameLength = AVAudioFrameCount(frames)
    return tail
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

    // The time-pitch node is always in the chain, even at 1×, so the pill can change the rate
    // mid-playback (`setSpeed`) without rebuilding the graph. `rate` is a multiplier where
    // 1.0 = normal (the API range is 1/32 ... 32, so our 0.75–2.0 picker is safe); at exactly
    // 1.0 the unit passes audio through unchanged.
    let timePitch = AVAudioUnitTimePitch()
    timePitch.rate = Float(ReadAloudPreferences.speed.rawValue)
    engine.attach(timePitch)
    engine.connect(playerNode, to: timePitch, format: format)
    engine.connect(timePitch, to: engine.mainMixerNode, format: format)
    timePitchNode = timePitch

    self.audioEngine = engine
    self.audioPlayerNode = playerNode
    isPaused = false
    pausedAtFrame = nil
    currentPlaybackToken = UUID()

    try engine.start()
  }
}
