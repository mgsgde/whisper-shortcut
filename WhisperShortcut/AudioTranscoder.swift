import AVFoundation
import Foundation

/// Transcodes recorded PCM WAV audio to AAC for cloud upload. Recording stays uncompressed
/// WAV (local Whisper, AudioChunker, and Smart Improvement audio verification all expect
/// PCM); only the bytes sent over the network are compressed. A 24 kHz mono 16-bit WAV
/// shrinks roughly 10× (48 KB/s → ~4 KB/s at 32 kbps AAC), cutting upload time accordingly.
enum AudioTranscoder {

  /// MIME type for the transcoded payload. Gemini accepts the m4a container under
  /// `audio/aac` (verified against the live API).
  static let aacMimeType = "audio/aac"

  /// 32 kbps is transparent for mono speech and keeps a 45s chunk under ~200 KB.
  private static let aacBitRate = 32_000

  /// Returns the audio at `sourceURL` re-encoded as AAC (m4a) bytes for inline upload,
  /// or nil when the source isn't WAV or transcoding fails — callers then upload the
  /// original bytes unchanged.
  static func aacData(for sourceURL: URL) -> Data? {
    guard sourceURL.pathExtension.lowercased() == "wav" else { return nil }
    let startTime = CFAbsoluteTimeGetCurrent()
    let outputURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("upload_\(UUID().uuidString).m4a")
    defer { try? FileManager.default.removeItem(at: outputURL) }

    do {
      let source = try AVAudioFile(forReading: sourceURL)
      let settings: [String: Any] = [
        AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
        AVSampleRateKey: source.fileFormat.sampleRate,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: aacBitRate,
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
        DebugLogger.logWarning("AUDIO: AAC transcode failed — could not allocate PCM buffer")
        return nil
      }
      while source.framePosition < source.length {
        try source.read(into: buffer)
        guard buffer.frameLength > 0 else { break }
        try output.write(from: buffer)
      }

      let data = try Data(contentsOf: outputURL)
      guard !data.isEmpty else {
        DebugLogger.logWarning("AUDIO: AAC transcode produced empty file, uploading original WAV")
        return nil
      }
      let sourceSize =
        (try? FileManager.default.attributesOfItem(atPath: sourceURL.path)[.size] as? Int64) ?? 0
      let elapsedMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
      DebugLogger.logSpeech(
        "SPEED: AAC transcode \(sourceSize) → \(data.count) bytes in \(String(format: "%.0f", elapsedMs))ms"
      )
      return data
    } catch {
      DebugLogger.logWarning(
        "AUDIO: AAC transcode failed, uploading original WAV — \(error.localizedDescription)")
      return nil
    }
  }
}
