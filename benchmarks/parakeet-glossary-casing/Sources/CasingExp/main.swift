import FluidAudio
import Foundation

// args: <dir with *.wav> ; prints JSON lines {file, arm, text}
let dir = URL(fileURLWithPath: CommandLine.arguments[1])
let terms = try String(contentsOf: dir.appendingPathComponent("terms.txt"), encoding: .utf8)
  .split(separator: "\n").map(String.init).filter { !$0.isEmpty }
let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
  .filter { $0.pathExtension == "wav" }.sorted { $0.lastPathComponent < $1.lastPathComponent }

let models = try await AsrModels.downloadAndLoad(version: .ultra)
let manager = AsrManager(config: .default)
try await manager.loadModels(models)
let ctc = try await CtcModels.downloadAndLoad(variant: .ctc110m)
let session = try await VocabularyBoostingSession(
  vocabulary: CustomVocabularyContext(terms: terms.map { CustomVocabularyTerm(text: $0) }), ctcModels: ctc)
let converter = AudioConverter()

for file in files {
  let samples = try converter.resampleAudioFile(file)
  for (langName, lang) in [("auto", nil as Language?), ("de", Language.german)] {
    var state = TdtDecoderState.make(decoderLayers: AsrModelVersion.ultra.decoderLayers)
    let r = try await manager.transcribe(samples, decoderState: &state, language: lang)
    let boosted = await session.rescore(text: r.text, tokenTimings: r.tokenTimings ?? [], audioSamples: samples)?.text ?? r.text
    for (arm, text) in [("\(langName)", r.text), ("\(langName)+glossar", boosted)] {
      let obj = ["file": file.lastPathComponent, "arm": arm, "text": text]
      print(String(data: try JSONSerialization.data(withJSONObject: obj), encoding: .utf8)!)
    }
  }
}
