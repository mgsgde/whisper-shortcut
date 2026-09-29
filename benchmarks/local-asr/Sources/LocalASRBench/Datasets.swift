import AVFoundation
import Foundation

struct Clip {
  let id: String
  let dataset: String
  let url: URL
  let seconds: Double
  let reference: String
  /// Terms scored for recall and handed to the engines that take a vocabulary.
  let terms: [String]
}

enum Datasets {
  static func duration(of url: URL) throws -> Double {
    let file = try AVAudioFile(forReading: url)
    return Double(file.length) / file.fileFormat.sampleRate
  }

  // MARK: - Synthetic: known text, German practice dictation

  /// Same material as `OfflineWhisperBenchmarkTests`, minus spelled-out numbers: every engine
  /// writes "130" for "einhundertdreißig", and that would be scored as an error against all of them.
  static let medicalSentences = [
    "Der Patient klagt seit drei Tagen über ziehende Beschwerden im rechten Oberbauch.",
    "Die körperliche Untersuchung zeigt einen weichen Bauch ohne Abwehrspannung.",
    "Der Blutdruck ist normal, der Puls ist regelmäßig.",
    "Im Labor sind die Entzündungswerte leicht erhöht, das Blutbild ist unauffällig.",
    "Die Sonographie des Abdomens ergibt keinen Hinweis auf Gallensteine.",
    "Wir vereinbaren eine Kontrolle in zwei Wochen und besprechen die Befunde erneut.",
    "Der Patient nimmt weiterhin Ramipril einmal täglich ein.",
  ]

  static let osteopathy = """
    Die Patientin kommt mit akuter Lumbalgie nach einer Hebebewegung. \
    Palpation zeigt eine deutliche Faszieneinschränkung im Bereich des Sacrum und der Halswirbelsäule. \
    Verdacht auf Blockade des Iliosakralgelenks. \
    Behandlung osteopathisch mit Fokus auf myofasziale Techniken und craniosacrale Impulse. \
    Triggerpunkte paravertebral links.
    """

  static let practiceTerms = [
    "Lumbalgie", "Faszieneinschränkung", "Sacrum", "Halswirbelsäule", "Iliosakralgelenk",
    "osteopathisch", "myofasziale", "craniosacrale", "Triggerpunkte", "paravertebral",
    "Abwehrspannung", "Sonographie", "Abdomens", "Ramipril", "Entzündungswerte",
  ]

  static func synthetic(in dir: URL) throws -> [Clip] {
    var specs: [(String, String)] = medicalSentences.enumerated().map { ("med-\($0.offset)", $0.element) }
    specs.append(("osteopathy", osteopathy))
    specs.append(("med-five", medicalSentences.prefix(5).joined(separator: " ")))
    specs.append(("med-long", (medicalSentences + medicalSentences).joined(separator: " ")))

    return try specs.map { id, text in
      let url = dir.appendingPathComponent("\(id).wav")
      try say(text, to: url)
      return Clip(
        id: id, dataset: "synthetic", url: url, seconds: try duration(of: url),
        reference: text, terms: practiceTerms)
    }
  }

  /// 16 kHz mono PCM, the recorder's format. Fixed voice so runs on different Macs compare.
  static func say(_ text: String, to url: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    process.arguments = ["-v", "Anna", "-o", url.path, "--data-format=LEI16@16000", text]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw NSError(domain: "bench", code: 1, userInfo: [NSLocalizedDescriptionKey: "`say` failed"])
    }
  }

  // MARK: - Real: the user's retained recordings, cloud transcript as reference

  static var userContextDir: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Containers/com.magnusgoedde.whispershortcut/Data/Library/Application Support/WhisperShortcut/UserContext")
  }

  /// Recordings Smart Improvement kept, paired with the transcript the cloud model produced for
  /// them at the time. That transcript is not ground truth — it is GPT-4o Transcribe — so the
  /// score is "distance from the cloud model the user was happy enough with", which is the bar an
  /// offline replacement has to clear anyway.
  ///
  /// `limit` clips are picked evenly across the duration range so short and long dictations are
  /// both represented.
  static func real(limit: Int, maxSeconds: Double, glossaryTerms: [String]) throws -> [Clip] {
    let samplesDir = userContextDir.appendingPathComponent("audio-samples")
    let wavs = Set(try FileManager.default.contentsOfDirectory(atPath: samplesDir.path).filter { $0.hasSuffix(".wav") })

    var references: [String: String] = [:]
    let logs = try FileManager.default.contentsOfDirectory(atPath: userContextDir.path)
      .filter { $0.hasPrefix("interactions-") && $0.hasSuffix(".jsonl") }
    for log in logs {
      guard let content = try? String(contentsOf: userContextDir.appendingPathComponent(log), encoding: .utf8)
      else { continue }
      for line in content.split(separator: "\n") {
        guard let data = line.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let ref = object["audioRef"] as? String, wavs.contains(ref),
          (object["mode"] as? String) == "transcription",
          let result = object["result"] as? String, !result.isEmpty
        else { continue }
        references[ref] = result
      }
    }

    var candidates: [Clip] = []
    for (name, reference) in references {
      let url = samplesDir.appendingPathComponent(name)
      guard let seconds = try? duration(of: url), seconds >= 1.0 else { continue }
      // A reference with fewer than three words gives WER in steps of 33 % — noise, not signal.
      guard Metrics.normalize(reference).count >= 3 else { continue }
      candidates.append(Clip(
        id: String(name.dropLast(4)), dataset: "real", url: url, seconds: seconds,
        reference: reference, terms: glossaryTerms))
    }
    candidates.sort { $0.seconds < $1.seconds }
    var picked = candidates
    if candidates.count > limit, limit > 1 {
      let step = Double(candidates.count - 1) / Double(limit - 1)
      picked = (0..<limit).map { candidates[Int((Double($0) * step).rounded())] }
    }
    // Rounding can land two picks on one clip. The length cap applies after picking so that
    // raising it never changes which of the shorter clips are in the set: an 11-minute recording
    // is a meeting, not a dictation, and on 2026-09-29 Whisper+glossary sat on one until killed.
    var seen = Set<String>()
    return picked.filter { $0.seconds <= maxSeconds && seen.insert($0.id).inserted }
  }

  /// The user's Whisper Glossary section from system-prompts.md, split into terms.
  /// Returns the raw section too: the Whisper arm conditions on that text as the app does.
  static func glossary() -> (raw: String, terms: [String]) {
    let url = userContextDir.appendingPathComponent("system-prompts.md")
    guard let content = try? String(contentsOf: url, encoding: .utf8) else { return ("", []) }
    var inSection = false
    var lines: [String] = []
    for line in content.components(separatedBy: "\n") {
      if line.hasPrefix("=== ") {
        inSection = line.hasPrefix("=== Whisper Glossary")
        continue
      }
      if inSection { lines.append(line) }
    }
    let raw = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    let body = raw.replacingOccurrences(of: "Terms:", with: "")
    let terms = body.components(separatedBy: CharacterSet(charactersIn: ",\n"))
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    return (raw, terms)
  }
}
