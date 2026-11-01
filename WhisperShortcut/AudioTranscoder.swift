import AVFoundation
import Foundation

/// Transcodes recorded PCM WAV audio to lossless FLAC for cloud upload. Recording stays
/// uncompressed WAV (local Whisper, AudioChunker, and Smart Improvement audio verification
/// all expect PCM); only the bytes sent over the network are compressed. A 24 kHz mono
/// 16-bit WAV shrinks to roughly half its size as FLAC.
/// AAC 32 kbps was used until 2026-10 and was dropped because an A/B test on real
/// dictations showed it changed words on Gemini (WAV vs FLAC was word-identical).
enum AudioTranscoder {

  /// MIME type for the transcoded payload.
  static let flacMimeType = "audio/flac"

  private static let cacheLock = NSLock()
  /// In-flight or completed encodes keyed by the source WAV. Consumed by `flacData(for:)`.
  private static var prefetchTasks: [URL: Prefetch] = [:]

  private struct Prefetch {
    let id: UUID
    let task: Task<Data?, Never>
  }

  /// Starts a FLAC encode on a background task so it can run while the stop path does
  /// duration / silence / state-machine work. A later `flacData(for:)` joins this task
  /// instead of encoding again. No-op for non-WAV sources.
  static func prefetch(for sourceURL: URL) {
    guard sourceURL.pathExtension.lowercased() == "wav" else { return }
    cacheLock.lock()
    defer { cacheLock.unlock() }
    guard prefetchTasks[sourceURL] == nil else { return }
    prefetchTasks[sourceURL] = Prefetch(
      id: UUID(),
      task: Task.detached(priority: .userInitiated) { encodeFlac(sourceURL) })
  }

  /// Drops a prefetch so a discarded recording does not keep encoded bytes around.
  static func discardPrefetch(for sourceURL: URL) {
    cacheLock.lock()
    let prefetch = prefetchTasks.removeValue(forKey: sourceURL)
    cacheLock.unlock()
    prefetch?.task.cancel()
  }

  /// Returns the audio at `sourceURL` re-encoded as FLAC bytes for inline upload,
  /// or nil when the source isn't WAV or transcoding fails — callers then upload the
  /// original bytes unchanged. Joins an in-flight `prefetch(for:)` when one exists.
  static func flacData(for sourceURL: URL) async -> Data? {
    guard sourceURL.pathExtension.lowercased() == "wav" else { return nil }
    let prefetch: Prefetch
    cacheLock.lock()
    if let existing = prefetchTasks[sourceURL] {
      prefetch = existing
      cacheLock.unlock()
    } else {
      prefetch = Prefetch(
        id: UUID(),
        task: Task.detached(priority: .userInitiated) { encodeFlac(sourceURL) })
      prefetchTasks[sourceURL] = prefetch
      cacheLock.unlock()
    }
    let data = await prefetch.task.value
    cacheLock.lock()
    if prefetchTasks[sourceURL]?.id == prefetch.id {
      prefetchTasks[sourceURL] = nil
    }
    cacheLock.unlock()
    return data
  }

  /// FLAC bytes labelled `compressedLabel` when transcoding succeeds, otherwise the file's own
  /// bytes labelled by `mimeForExtension` of the lowercased path extension.
  /// Gemini passes `flacMimeType` (the default) and its MIME table; OpenRouter passes
  /// `"flac"` and `openRouterAudioFormat` — those vocabularies stay separate.
  static func payload(
    for url: URL,
    compressedLabel: String = flacMimeType,
    mimeForExtension: (String) -> String
  ) async throws -> (data: Data, mime: String) {
    if let flacData = await flacData(for: url) {
      return (flacData, compressedLabel)
    }
    let data = try Data(contentsOf: url)
    return (data, mimeForExtension(url.pathExtension.lowercased()))
  }

  // MARK: - Encode

  private static func encodeFlac(_ sourceURL: URL) -> Data? {
    let startTime = CFAbsoluteTimeGetCurrent()
    let outputURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("upload_\(UUID().uuidString).flac")
    defer { try? FileManager.default.removeItem(at: outputURL) }

    do {
      let source = try AVAudioFile(forReading: sourceURL)
      let settings: [String: Any] = [
        AVFormatIDKey: Int(kAudioFormatFLAC),
        AVSampleRateKey: source.fileFormat.sampleRate,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
      ]
      let output = try AVAudioFile(
        forWriting: outputURL,
        settings: settings,
        commonFormat: source.processingFormat.commonFormat,
        interleaved: source.processingFormat.isInterleaved
      )
      guard
        let buffer = AVAudioPCMBuffer(
          pcmFormat: source.processingFormat, frameCapacity: 65_536)
      else {
        DebugLogger.logWarning("AUDIO: FLAC transcode failed — could not allocate PCM buffer")
        return nil
      }
      while source.framePosition < source.length {
        try Task.checkCancellation()
        try source.read(into: buffer)
        guard buffer.frameLength > 0 else { break }
        try output.write(from: buffer)
      }
      // AVAudioFile only finalizes the container on close. Reading the bytes before
      // closing yields a file audio decoders reject.
      output.close()

      let data = try Data(contentsOf: outputURL)
      guard !data.isEmpty else {
        DebugLogger.logWarning("AUDIO: FLAC transcode produced empty file, uploading original WAV")
        return nil
      }
      let sourceSize =
        (try? FileManager.default.attributesOfItem(atPath: sourceURL.path)[.size] as? Int64) ?? 0
      let elapsedMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
      DebugLogger.logSpeech(
        "SPEED: FLAC transcode \(sourceSize) → \(data.count) bytes in \(String(format: "%.0f", elapsedMs))ms"
      )
      return data
    } catch is CancellationError {
      return nil
    } catch {
      DebugLogger.logWarning(
        "AUDIO: FLAC transcode failed, uploading original WAV — \(error.localizedDescription)")
      return nil
    }
  }
}
