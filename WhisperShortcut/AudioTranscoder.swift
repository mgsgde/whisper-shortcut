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

  /// Returns the audio at `sourceURL` re-encoded as FLAC bytes for inline upload,
  /// or nil when the source isn't WAV or transcoding fails — callers then upload the
  /// original bytes unchanged.
  static func flacData(for sourceURL: URL) -> Data? {
    guard sourceURL.pathExtension.lowercased() == "wav" else { return nil }
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
        try source.read(into: buffer)
        guard buffer.frameLength > 0 else { break }
        try output.write(from: buffer)
      }
      // AVAudioFile only finalizes the m4a container (moov atom) on close. Reading the
      // bytes before closing yields a file audio decoders reject — Gemini 3.1 then answers
      // "please provide the audio" instead of transcribing.
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
    } catch {
      DebugLogger.logWarning(
        "AUDIO: FLAC transcode failed, uploading original WAV — \(error.localizedDescription)")
      return nil
    }
  }

  /// FLAC bytes labelled `compressedLabel` when transcoding succeeds, otherwise the file's own
  /// bytes labelled by `mimeForExtension` of the lowercased path extension.
  /// Gemini passes `flacMimeType` (the default) and its MIME table; OpenRouter passes
  /// `"flac"` and `openRouterAudioFormat` — those vocabularies stay separate.
  static func payload(
    for url: URL,
    compressedLabel: String = flacMimeType,
    mimeForExtension: (String) -> String
  ) throws -> (data: Data, mime: String) {
    if let flacData = flacData(for: url) {
      return (flacData, compressedLabel)
    }
    let data = try Data(contentsOf: url)
    return (data, mimeForExtension(url.pathExtension.lowercased()))
  }
}
