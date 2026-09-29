import FluidAudio
import Foundation

// Offline speech-to-text bake-off: accuracy and post-Stop wait, per engine, on German practice
// dictation (synthetic, known text) and on the user's own recordings (cloud transcript as
// reference). See README.md next to Package.swift for how to run it and how to read it.
//
// Per-clip rows, transcripts included, go to --out (default under ~/Library/Caches, never into the
// repo: the real set is private dictation). stdout carries aggregates only.

setvbuf(stdout, nil, _IONBF, 0)

struct Options {
  var engines = [
    "whisper-turbo", "whisper-turbo+glossary",
    "parakeet-v3", "parakeet-ultra", "parakeet-redux", "parakeet-ultra+vocab",
    "apple", "apple+ctx",
  ]
  var realLimit = 60
  var skipReal = false
  var skipSynthetic = false
  var out = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Caches/whispershortcut-bench/local-asr")
    .appendingPathComponent(ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-"))
}

var options = Options()
var arguments = CommandLine.arguments.dropFirst()
while let argument = arguments.popFirst() {
  switch argument {
  case "--engines": options.engines = (arguments.popFirst() ?? "").split(separator: ",").map(String.init)
  case "--real-limit": options.realLimit = Int(arguments.popFirst() ?? "") ?? options.realLimit
  case "--skip-real": options.skipReal = true
  case "--skip-synthetic": options.skipSynthetic = true
  case "--out": options.out = URL(fileURLWithPath: arguments.popFirst() ?? ".")
  default:
    print("unknown argument \(argument)")
    exit(2)
  }
}

func makeEngine(_ name: String) -> Engine? {
  switch name {
  case "whisper-turbo": return WhisperEngine(variant: "large-v3-v20240930_turbo", useGlossary: false)
  case "whisper-turbo+glossary": return WhisperEngine(variant: "large-v3-v20240930_turbo", useGlossary: true)
  case "whisper-small": return WhisperEngine(variant: "small", useGlossary: false)
  case "whisper-base": return WhisperEngine(variant: "base", useGlossary: false)
  case "parakeet-v3": return ParakeetEngine(version: .v3, label: "v3", useVocabulary: false)
  case "parakeet-ultra": return ParakeetEngine(version: .ultra, label: "ultra", useVocabulary: false)
  case "parakeet-redux": return ParakeetEngine(version: .redux, label: "redux", useVocabulary: false)
  case "parakeet-ultra+vocab": return ParakeetEngine(version: .ultra, label: "ultra", useVocabulary: true)
  case "parakeet-v3+vocab": return ParakeetEngine(version: .v3, label: "v3", useVocabulary: true)
  case "apple":
    if #available(macOS 26.0, *) { return AppleSpeechEngine(useContext: false) }
    return nil
  case "apple+ctx":
    if #available(macOS 26.0, *) { return AppleSpeechEngine(useContext: true) }
    return nil
  default: return nil
  }
}

struct Row: Codable {
  let engine: String
  let dataset: String
  let clip: String
  let audioSeconds: Double
  let decodeSeconds: Double
  let refWords: Int
  let edits: Int
  let termsPresent: Int
  let termsHit: Int
  let error: String?
  let hypothesis: String
  let reference: String
}

func f(_ value: Double?, _ digits: Int = 2) -> String {
  guard let value else { return "—" }
  return String(format: "%.\(digits)f", value)
}

try FileManager.default.createDirectory(at: options.out, withIntermediateDirectories: true)
let audioDir = options.out.appendingPathComponent("synthetic-audio")
try FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)

let glossary = Datasets.glossary()
var clips: [Clip] = []
if !options.skipSynthetic { clips += try Datasets.synthetic(in: audioDir) }
if !options.skipReal { clips += try Datasets.real(limit: options.realLimit, glossaryTerms: glossary.terms) }

let host = ProcessInfo.processInfo
print("BENCH machine=\(machineName()) os=\(host.operatingSystemVersionString) ramGB=\(host.physicalMemory / 1_073_741_824)")
print("BENCH clips synthetic=\(clips.filter { $0.dataset == "synthetic" }.count) real=\(clips.filter { $0.dataset == "real" }.count) glossaryTerms=\(glossary.terms.count)")
print("BENCH out=\(options.out.path)")

func machineName() -> String {
  var size = 0
  sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
  var buffer = [CChar](repeating: 0, count: size)
  sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0)
  return String(cString: buffer)
}

let rowsURL = options.out.appendingPathComponent("rows.jsonl")
FileManager.default.createFile(atPath: rowsURL.path, contents: nil)
let rowsHandle = try FileHandle(forWritingTo: rowsURL)
let encoder = JSONEncoder()

struct EngineSummary {
  let name: String
  let loadSeconds: Double
  let firstDecodeSeconds: Double
  var rows: [Row]
}
var summaries: [EngineSummary] = []

/// Declared before the engine loop: globals in main.swift initialise in source order.
/// Buckets by audio length: the short ones are the post-Stop tail in streaming Dictate, where
/// Whisper's fixed per-call floor lives.
let buckets: [(String, ClosedRange<Double>)] = [
  ("<5s", 0...5), ("5–15s", 5...15), ("15–30s", 15...30), (">30s", 30...10_000),
]


for engineName in options.engines {
  guard let engine = makeEngine(engineName) else {
    print("BENCH skip engine=\(engineName) (unknown or unavailable on this OS)")
    continue
  }
  print("BENCH engine=\(engine.name) loading…")
  let clock = ContinuousClock()
  let loadStart = clock.now
  do {
    try await engine.load()
  } catch {
    print("BENCH engine=\(engine.name) load failed: \(error)")
    continue
  }
  let load = (clock.now - loadStart).seconds

  // The first decode after a load carries one-off costs (ANE/GPU graph specialisation, caches).
  // It is timed on its own and kept out of the per-clip numbers; Whisper's is ~3 s on an M1 Pro.
  var firstDecode = 0.0
  if let warm = clips.first(where: { $0.dataset == "synthetic" }) ?? clips.first {
    let start = clock.now
    _ = try? await engine.transcribe(warm, vocabulary: warm.terms, rawGlossary: glossary.raw)
    firstDecode = (clock.now - start).seconds
  }
  print("BENCH engine=\(engine.name) loadS=\(f(load)) firstDecodeS=\(f(firstDecode))")

  var rows: [Row] = []
  for clip in clips {
    let start = clock.now
    var hypothesis = ""
    var failure: String?
    do {
      hypothesis = try await engine.transcribe(clip, vocabulary: clip.terms, rawGlossary: glossary.raw)
    } catch {
      failure = "\(error)"
    }
    let decode = (clock.now - start).seconds
    let ref = Metrics.normalize(clip.reference)
    let edits = Metrics.editDistance(ref, Metrics.normalize(hypothesis))
    let terms = Metrics.termRecall(terms: clip.terms, reference: clip.reference, hypothesis: hypothesis)
    let row = Row(
      engine: engine.name, dataset: clip.dataset, clip: clip.id, audioSeconds: clip.seconds,
      decodeSeconds: decode, refWords: ref.count, edits: edits, termsPresent: terms.present,
      termsHit: terms.hit, error: failure, hypothesis: hypothesis, reference: clip.reference)
    rows.append(row)
    rowsHandle.write(try encoder.encode(row))
    rowsHandle.write("\n".data(using: .utf8)!)
  }
  await engine.unload()
  let summary = EngineSummary(name: engine.name, loadSeconds: load, firstDecodeSeconds: firstDecode, rows: rows)
  summaries.append(summary)
  printSummary([summary], header: false)
}
try rowsHandle.close()

extension Duration {
  var seconds: Double {
    let parts = components
    return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
  }
}

func summaryTable(_ list: [EngineSummary], header: Bool = true) -> [String] {
  var lines: [String] = []
  if header {
    lines.append("| engine | load s | 1st decode s | WER synth | WER real | terms synth | terms real | p50 <5s | p50 5–15s | p50 15–30s | p50 >30s | p90 all | errors |")
    lines.append("|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
  }
  for summary in list {
    func wer(_ dataset: String) -> String {
      let rows = summary.rows.filter { $0.dataset == dataset && $0.error == nil }
      let words = rows.map(\.refWords).reduce(0, +)
      guard words > 0 else { return "—" }
      return f(100 * Double(rows.map(\.edits).reduce(0, +)) / Double(words), 1) + " %"
    }
    func terms(_ dataset: String) -> String {
      let rows = summary.rows.filter { $0.dataset == dataset }
      let present = rows.map(\.termsPresent).reduce(0, +)
      guard present > 0 else { return "—" }
      return "\(rows.map(\.termsHit).reduce(0, +))/\(present)"
    }
    let ok = summary.rows.filter { $0.error == nil }
    let perBucket = buckets.map { _, range in
      f(Metrics.median(ok.filter { range.contains($0.audioSeconds) }.map(\.decodeSeconds)))
    }
    let failures = summary.rows.filter { $0.error != nil }.count
    lines.append(
      "| \(summary.name) | \(f(summary.loadSeconds)) | \(f(summary.firstDecodeSeconds)) | \(wer("synthetic")) | \(wer("real")) | "
        + "\(terms("synthetic")) | \(terms("real")) | " + perBucket.joined(separator: " | ")
        + " | \(f(Metrics.percentile(ok.map(\.decodeSeconds), 0.9))) | \(failures) |")
  }
  return lines
}

func printSummary(_ list: [EngineSummary], header: Bool = true) {
  print(summaryTable(list, header: header).map { "BENCH-SUMMARY \($0)" }.joined(separator: "\n"))
}

printSummary(summaries)
var markdown = "# Local ASR benchmark\n\n"
markdown += "- machine: \(machineName()), \(host.operatingSystemVersionString)\n"
markdown += "- clips: synthetic \(clips.filter { $0.dataset == "synthetic" }.count), real \(clips.filter { $0.dataset == "real" }.count)\n\n"
markdown += summaryTable(summaries).joined(separator: "\n") + "\n"
try markdown.write(to: options.out.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)
print("BENCH done — per-clip rows in \(rowsURL.path)")
