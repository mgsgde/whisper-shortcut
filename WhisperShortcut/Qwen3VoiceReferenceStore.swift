//
//  Qwen3VoiceReferenceStore.swift
//  WhisperShortcut
//
//  Disk cache for VoiceDesign speaker references.
//
//  VoiceDesign samples a *new* voice from the description on every call, so two calls with the
//  same persona produce two different speakers. `Qwen3TTSService` fixes that by feeding a
//  reference clip (audio + its transcript) back into every sentence via the model's ICL path.
//  This store makes that reference survive the session: the first Read Aloud with a persona
//  creates its reference once, and every later Read Aloud — tomorrow, next month — reuses the
//  exact same voice.
//
//  One JSON file per persona under Application Support/Qwen3VoiceReferences/. Deleting the file
//  is the whole "reset the voice" operation; the next Read Aloud generates and stores a new one.
//

import Foundation

enum Qwen3VoiceReferenceStore {

  /// The calibration sentence recorded as a persona's reference. It is spoken once per persona
  /// and never shown to the user, so it only has to be short, easy to synthesize and free of
  /// anything that could bias the voice (no numbers, no foreign words, no exclamations).
  /// The transcript must match the audio exactly — the ICL path aligns them.
  static func calibrationText(for language: String) -> String {
    switch language {
    case "English":
      return "Hello, this is a short reference recording so that the voice stays the "
        + "same for every sentence that follows."
    default:
      return "Guten Tag, dies ist eine kurze Referenzaufnahme, damit die Stimme für "
        + "alle folgenden Sätze gleich bleibt."
    }
  }

  private static var directory: URL {
    let url = AppSupportPaths.whisperShortcutApplicationSupportURL()
      .appendingPathComponent("Qwen3VoiceReferences")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private static func fileURL(for personaID: String) -> URL {
    directory.appendingPathComponent("reference-\(personaID).json")
  }

  /// The cached reference for a persona, or nil when none exists yet.
  ///
  /// - Returns: mono Float samples at `sampleRate` plus the transcript the model must see
  ///   alongside them.
  static func reference(for personaID: String) -> (samples: [Float], sampleRate: Int, text: String)? {
    let url = fileURL(for: personaID)
    guard let data = try? Data(contentsOf: url),
      let decoded = try? JSONDecoder().decode(ReferenceFile.self, from: data),
      decoded.version == 1 || decoded.version == 2
    else { return nil }
    guard let raw = Data(base64Encoded: decoded.samples), raw.count % MemoryLayout<Float>.size == 0
    else { return nil }
    // loadUnaligned: the base64-decoded buffer has no alignment guarantee, and plain `load`
    // requires natural alignment.
    let floats = raw.withUnsafeBytes { buffer -> [Float] in
      guard !buffer.isEmpty else { return [] }
      return (0..<raw.count / MemoryLayout<Float>.size).map {
        buffer.loadUnaligned(fromByteOffset: $0 * MemoryLayout<Float>.size, as: Float.self)
      }
    }
    guard floats.count > 0 else { return nil }
    return (floats, decoded.sampleRate, decoded.text)
  }

  /// Whether a persona already has its voice frozen on disk. Drives the Settings row's
  /// "reset" button visibility.
  static func hasReference(for personaID: String) -> Bool {
    FileManager.default.fileExists(atPath: fileURL(for: personaID).path)
  }

  /// Whether the persona's voice came from a file the user supplied rather than from a
  /// generation. A user clip is never replaced by a calibration run, and Settings offers
  /// "Remove reference" instead of "New voice" for it.
  static func isUserProvided(for personaID: String) -> Bool {
    guard let data = try? Data(contentsOf: fileURL(for: personaID)),
      let decoded = try? JSONDecoder().decode(ReferenceFile.self, from: data)
    else { return false }
    return decoded.source == ReferenceSource.userProvided.rawValue
  }

  /// Stores a persona's voice. `samples` must be the mono Float waveform of `text`. Failures
  /// (disk full, unwritable directory) are logged, not thrown — the caller's fallback is
  /// per-run voice pinning, which the next Read Aloud retries as a fresh calibration.
  static func store(
    samples: [Float], sampleRate: Int, text: String, for personaID: String,
    source: ReferenceSource = .generated
  ) {
    let raw = samples.withUnsafeBufferPointer { Data(buffer: $0) }
    let file = ReferenceFile(
      version: 2, sampleRate: sampleRate, text: text, samples: raw.base64EncodedString(),
      source: source.rawValue)
    guard let data = try? JSONEncoder().encode(file) else { return }
    do {
      try data.write(to: fileURL(for: personaID), options: .atomic)
      DebugLogger.log(
        "QWEN3-TTS: stored \(source.rawValue) voice reference for \(personaID) "
          + "(\(samples.count) samples)")
    } catch {
      DebugLogger.logWarning("QWEN3-TTS: could not store voice reference for \(personaID): \(error)")
    }
  }

  /// Discards a persona's frozen voice. The next Read Aloud generates a new one.
  static func removeReference(for personaID: String) {
    try? FileManager.default.removeItem(at: fileURL(for: personaID))
    DebugLogger.log("QWEN3-TTS: removed voice reference for \(personaID)")
  }

  /// On-disk shape. `samples` is base64 of little-endian Float32 mono audio.
  ///
  /// `source` was added in version 2 and is optional on read, so a version-1 file written before
  /// it existed still loads (and counts as generated). `version` stays 1 for those files; the
  /// decoder accepts both.
  private struct ReferenceFile: Codable {
    let version: Int
    let sampleRate: Int
    let text: String
    let samples: String
    var source: String?

    init(version: Int, sampleRate: Int, text: String, samples: String, source: String?) {
      self.version = version
      self.sampleRate = sampleRate
      self.text = text
      self.samples = samples
      self.source = source
    }
  }
}

/// Where a persona's frozen voice came from.
enum ReferenceSource: String {
  /// Generated by the app from the persona's description (the calibration sentence).
  case generated
  /// Imported from an audio file the user supplied; the transcript was transcribed locally.
  case userProvided = "user-provided"
}
