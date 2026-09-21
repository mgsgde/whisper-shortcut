import Foundation
import Testing
@testable import WhisperShortcut_AppStore

/// Pins the completeness check that used to treat a Hub-created empty `.mlmodelc`
/// directory as a downloaded model. `findFile(named:in:)` matched a directory by
/// name anywhere in the tree; WhisperKit then failed at load with "Unable to load
/// model … Compile the model with Xcode".
@Suite("WhisperKit model completeness")
struct ModelManagerCompletenessTests {

  private func makeRoot() -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("ModelManagerCompletenessTests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  /// Writes a compiled-model layout under `root/<name>/`. Nested paths like
  /// `weights/weight.bin` get their parent directories created. `emptyFile`, when
  /// set, is created at size 0 instead of a dummy byte.
  @discardableResult
  private func writeComponent(
    _ name: String,
    at root: URL,
    files: [String] = ["coremldata.bin", "model.mil", "weights/weight.bin"],
    emptyFile: String? = nil
  ) -> URL {
    let fileManager = FileManager.default
    let component = root.appendingPathComponent(name)
    try? fileManager.createDirectory(at: component, withIntermediateDirectories: true)
    for file in files {
      let url = file.split(separator: "/").reduce(component) {
        $0.appendingPathComponent(String($1))
      }
      try? fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      let data = (file == emptyFile) ? Data() : Data("x".utf8)
      fileManager.createFile(atPath: url.path, contents: data)
    }
    return component
  }

  private func writeRequiredComponents(at root: URL) {
    writeComponent("AudioEncoder.mlmodelc", at: root)
    writeComponent("TextDecoder.mlmodelc", at: root)
    writeComponent("MelSpectrogram.mlmodelc", at: root)
  }

  @Test("Three complete required components with no Prefill are available")
  func completeRequiredWithoutPrefill() {
    let root = makeRoot()
    writeRequiredComponents(at: root)
    #expect(ModelManager.incompleteComponent(at: root) == nil)
  }

  @Test("An empty MelSpectrogram.mlmodelc directory is the 09-03 incomplete-download signature")
  func emptyMelSpectrogramDirectoryIsIncomplete() {
    let root = makeRoot()
    writeComponent("AudioEncoder.mlmodelc", at: root)
    writeComponent("TextDecoder.mlmodelc", at: root)
    try? FileManager.default.createDirectory(
      at: root.appendingPathComponent("MelSpectrogram.mlmodelc"),
      withIntermediateDirectories: true)
    #expect(
      ModelManager.incompleteComponent(at: root)
        == "MelSpectrogram.mlmodelc/coremldata.bin")
  }

  @Test("A component missing weights/weight.bin is incomplete")
  func missingWeightsFile() {
    let root = makeRoot()
    writeComponent("AudioEncoder.mlmodelc", at: root, files: ["coremldata.bin", "model.mil"])
    writeComponent("TextDecoder.mlmodelc", at: root)
    writeComponent("MelSpectrogram.mlmodelc", at: root)
    #expect(
      ModelManager.incompleteComponent(at: root)
        == "AudioEncoder.mlmodelc/weights/weight.bin")
  }

  @Test("A zero-byte weights/weight.bin is not complete")
  func zeroByteWeightsFileIsIncomplete() {
    let root = makeRoot()
    writeComponent("AudioEncoder.mlmodelc", at: root, emptyFile: "weights/weight.bin")
    writeComponent("TextDecoder.mlmodelc", at: root)
    writeComponent("MelSpectrogram.mlmodelc", at: root)
    #expect(
      ModelManager.incompleteComponent(at: root)
        == "AudioEncoder.mlmodelc/weights/weight.bin")
  }

  @Test("Prefill is optional when absent, complete when whole, and the 08-31 case when empty")
  func prefillOptionalUnlessHalfWritten() {
    let fileManager = FileManager.default

    let absent = makeRoot()
    writeRequiredComponents(at: absent)
    #expect(ModelManager.incompleteComponent(at: absent) == nil)

    let complete = makeRoot()
    writeRequiredComponents(at: complete)
    writeComponent("TextDecoderContextPrefill.mlmodelc", at: complete)
    #expect(ModelManager.incompleteComponent(at: complete) == nil)

    let emptyPrefill = makeRoot()
    writeRequiredComponents(at: emptyPrefill)
    try? fileManager.createDirectory(
      at: emptyPrefill.appendingPathComponent("TextDecoderContextPrefill.mlmodelc"),
      withIntermediateDirectories: true)
    #expect(
      ModelManager.incompleteComponent(at: emptyPrefill)
        == "TextDecoderContextPrefill.mlmodelc/coremldata.bin")
  }

  @Test("A complete nested component does not satisfy the direct-child rule")
  func nestedComponentIsNotAMatch() {
    let root = makeRoot()
    writeComponent("TextDecoder.mlmodelc", at: root)
    writeComponent("MelSpectrogram.mlmodelc", at: root)
    writeComponent("AudioEncoder.mlmodelc", at: root.appendingPathComponent("sub"))
    #expect(
      ModelManager.incompleteComponent(at: root)
        == "AudioEncoder.mlmodelc/coremldata.bin")
  }

  @Test("A missing modelPath returns the first required component's first file")
  func missingModelPathIsNeverComplete() {
    let missing = FileManager.default.temporaryDirectory
      .appendingPathComponent("ModelManagerCompletenessTests-missing-\(UUID().uuidString)")
    #expect(ModelManager.incompleteComponent(at: missing) == "AudioEncoder.mlmodelc/coremldata.bin")
  }
}
