//
//  ModelImporterTests.swift
//  WhisperShortcutTests
//
//  The importer has two jobs that are easy to get wrong and silent when they are:
//  finding a model in the folder the user picked, and copying a Hugging Face snapshot so the
//  files are real instead of dangling symlinks. Both are pinned here.
//

import Foundation
import Testing

@testable import WhisperShortcut_AppStore

@Suite("ModelImporter")
struct ModelImporterTests {

  private func makeTempFolder() throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("importer-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  /// Roots pointing at fresh temp folders instead of the real app container — discovery must
  /// never depend on, or be thrown off by, whatever is actually downloaded on this Mac.
  private func makeImportRoots() throws -> ModelImportRoots {
    let base = try makeTempFolder()
    return ModelImportRoots(
      whisper: base.appendingPathComponent("whisper"),
      mlxHub: base.appendingPathComponent("mlx"),
      qwen3: base.appendingPathComponent("qwen3"))
  }

  /// A minimal complete WhisperKit model folder: the three required compiled components, each
  /// with the three files `incompleteComponent` checks.
  private func writeWhisperModel(at folder: URL) throws {
    let fm = FileManager.default
    for component in ["AudioEncoder.mlmodelc", "TextDecoder.mlmodelc", "MelSpectrogram.mlmodelc"] {
      let componentURL = folder.appendingPathComponent(component)
      try fm.createDirectory(
        at: componentURL.appendingPathComponent("weights"), withIntermediateDirectories: true)
      for file in ["coremldata.bin", "model.mil"] {
        try Data("x".utf8).write(to: componentURL.appendingPathComponent(file))
      }
      try Data("x".utf8).write(to: componentURL.appendingPathComponent("weights/weight.bin"))
    }
  }

  /// A minimal MLX repo: everything `MLXModelPaths.layout.hasRequiredFiles` checks —
  /// `config.json`, `tokenizer.json`, and one weights file.
  private func writeMLXModel(at folder: URL) throws {
    let fm = FileManager.default
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: folder.appendingPathComponent("config.json"))
    try Data("{}".utf8).write(to: folder.appendingPathComponent("tokenizer.json"))
    try Data("w".utf8).write(to: folder.appendingPathComponent("model.safetensors"))
  }

  // MARK: - Discovery

  @Test("A plain WhisperKit folder is found")
  func findsPlainWhisperFolder() throws {
    let root = try makeTempFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeWhisperModel(at: root.appendingPathComponent("openai_whisper-tiny"))

    let plans = ModelImporter.plans(in: root)
    #expect(plans.contains { $0.displayName == "Whisper Tiny" })
  }

  @Test("A Whisper model inside a Hugging Face cache snapshot is found")
  func findsWhisperInCacheSnapshot() throws {
    let root = try makeTempFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let snapshot = root
      .appendingPathComponent("models--argmaxinc--whisperkit-coreml")
      .appendingPathComponent("snapshots")
      .appendingPathComponent("abc123")
      .appendingPathComponent("openai_whisper-tiny")
    try writeWhisperModel(at: snapshot)

    let plans = ModelImporter.plans(in: root)
    #expect(plans.contains { $0.displayName == "Whisper Tiny" })
  }

  @Test("A Whisper import plan finds a local tokenizer snapshot next to the weights")
  func findsWhisperTokenizerInSameFolder() throws {
    let root = try makeTempFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeWhisperModel(at: root.appendingPathComponent("openai_whisper-tiny"))

    // A synthetic Hugging Face cache for the tokenizer repo, in the same picked folder.
    let tokenizerSnapshot = root
      .appendingPathComponent("models--openai--whisper-tiny")
      .appendingPathComponent("snapshots/abc123")
    try FileManager.default.createDirectory(
      at: tokenizerSnapshot, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: tokenizerSnapshot.appendingPathComponent("tokenizer.json"))

    let plans = ModelImporter.plans(in: root)
    guard let plan = plans.first(where: { $0.displayName == "Whisper Tiny" }) else {
      Issue.record("Whisper Tiny plan not found")
      return
    }
    // Compare `.path`, not the URLs themselves — `appendingPathComponent` can add a trailing
    // slash once the directory exists on disk, which would fail a direct URL `==`.
    #expect(plan.whisperTokenizerSource?.path == tokenizerSnapshot.path)
  }

  @Test("An incomplete Whisper folder is not offered")
  func ignoresIncompleteWhisperFolder() throws {
    let root = try makeTempFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    // Only one of the three required components.
    let folder = root.appendingPathComponent("openai_whisper-tiny")
    try FileManager.default.createDirectory(
      at: folder.appendingPathComponent("AudioEncoder.mlmodelc/weights"),
      withIntermediateDirectories: true)

    #expect(!ModelImporter.plans(in: root).contains { $0.displayName == "Whisper Tiny" })
  }

  // The discovery tests below exercise MLX coverage with `Qwen3 4B Instruct`
  // (`LocalLLMModelType.qwen34BInstruct2507`, offerable on any Mac — its
  // `minimumPhysicalMemoryGB` is 0, so it is never filtered out by `isOfferable` whether the
  // test runs on an 8 GB or a 16 GB machine) and inject temp-folder `ModelImportRoots`, so
  // discovery never reads the real app container: what Magnus actually has downloaded on his own
  // Mac must not change what a test expects to find.

  @Test("A model in a Hugging Face cache snapshot is found")
  func findsModelInCacheSnapshot() throws {
    let root = try makeTempFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let snapshot = root
      .appendingPathComponent("models--mlx-community--Qwen3-4B-Instruct-2507-4bit")
      .appendingPathComponent("snapshots")
      .appendingPathComponent("deadbeef")
    try writeMLXModel(at: snapshot)

    let plans = ModelImporter.plans(in: root, roots: try makeImportRoots())
    #expect(plans.contains { $0.displayName == "Qwen3 4B Instruct" })
  }

  @Test("An LM Studio style org/repo folder is found")
  func findsLMStudioLayout() throws {
    let root = try makeTempFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeMLXModel(
      at: root.appendingPathComponent("mlx-community/Qwen3-4B-Instruct-2507-4bit"))

    let plans = ModelImporter.plans(in: root, roots: try makeImportRoots())
    #expect(plans.contains { $0.displayName == "Qwen3 4B Instruct" })
  }

  @Test("A model missing a shard its index names is not offered")
  func ignoresShardedModelMissingAShard() throws {
    let root = try makeTempFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = root
      .appendingPathComponent("models--mlx-community--Qwen3-4B-Instruct-2507-4bit")
      .appendingPathComponent("snapshots/abc123")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: folder.appendingPathComponent("config.json"))
    // Shard 1 of 2 present, shard 2 missing — a download cancelled mid-way.
    try Data("w".utf8).write(to: folder.appendingPathComponent("model-00001-of-00002.safetensors"))
    let index: [String: Any] = [
      "weight_map": [
        "a": "model-00001-of-00002.safetensors",
        "b": "model-00002-of-00002.safetensors",
      ]
    ]
    try JSONSerialization.data(withJSONObject: index)
      .write(to: folder.appendingPathComponent("model.safetensors.index.json"))

    #expect(!ModelImporter.plans(in: root, roots: try makeImportRoots())
      .contains { $0.displayName == "Qwen3 4B Instruct" })
  }

  @Test("Discovery skips a model already complete at its destination")
  func discoverySkipsAlreadyCompleteModel() throws {
    let root = try makeTempFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let roots = try makeImportRoots()

    // The picked folder has a perfectly importable model...
    try writeMLXModel(
      at: root
        .appendingPathComponent("models--mlx-community--Qwen3-4B-Instruct-2507-4bit")
        .appendingPathComponent("snapshots/abc123"))

    // ...but the destination this import would land in already has a complete model of its
    // own (e.g. downloaded earlier through the app), so importing again would be pointless.
    let destination = roots.mlxHub
      .appendingPathComponent("models")
      .appendingPathComponent(LocalLLMModelType.qwen34BInstruct2507.huggingFaceID)
    try writeMLXModel(at: destination)

    let plans = ModelImporter.plans(in: root, roots: roots)
    #expect(!plans.contains { $0.displayName == "Qwen3 4B Instruct" })
  }

  @Test("A folder with nothing usable yields no plans")
  func emptyFolderYieldsNothing() throws {
    let root = try makeTempFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(ModelImporter.plans(in: root).isEmpty)
  }

  // MARK: - Copy

  @Test("Importing a cache snapshot dereferences its symlinks, and byteCount is the real blob size")
  func importDereferencesSymlinks() throws {
    let fm = FileManager.default
    let root = try makeTempFolder()
    defer { try? fm.removeItem(at: root) }

    // A cache-shaped tree: blobs/ holds the bytes, snapshots/<hash>/ links to them.
    let repo = root.appendingPathComponent("models--mlx-community--Qwen3-4B-Instruct-2507-4bit")
    let blobs = repo.appendingPathComponent("blobs")
    let snapshot = repo.appendingPathComponent("snapshots/abc123")
    try fm.createDirectory(at: blobs, withIntermediateDirectories: true)
    try fm.createDirectory(at: snapshot, withIntermediateDirectories: true)
    let configBytes = Data("{}".utf8)
    let weightsBytes = Data("weights".utf8)
    try configBytes.write(to: blobs.appendingPathComponent("configblob"))
    try weightsBytes.write(to: blobs.appendingPathComponent("weightsblob"))
    try fm.createSymbolicLink(
      atPath: snapshot.appendingPathComponent("config.json").path,
      withDestinationPath: "../../blobs/configblob")
    try fm.createSymbolicLink(
      atPath: snapshot.appendingPathComponent("model.safetensors").path,
      withDestinationPath: "../../blobs/weightsblob")

    // The real byte count, not a hand-written number — a symlinked snapshot's own files are tiny;
    // the blobs they resolve to are the actual size.
    let byteCount = ModelImporter.byteCount(at: snapshot)
    #expect(byteCount == Int64(configBytes.count + weightsBytes.count))

    let destination = root.appendingPathComponent("imported")
    let plan = ModelImportPlan(
      family: .mlx(.qwen34BInstruct2507),
      displayName: "Qwen3 4B Instruct",
      source: snapshot,
      destination: destination,
      byteCount: byteCount)

    try ModelImporter.perform(plan) { _ in }

    // The imported file must be a real file with the blob's content, not a dangling link.
    let imported = destination.appendingPathComponent("model.safetensors")
    let values = try imported.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
    #expect(values.isSymbolicLink != true)
    #expect(values.isRegularFile == true)
    #expect(try String(contentsOf: imported, encoding: .utf8) == "weights")
  }

  @Test("Importing into a complete destination is refused")
  func refusesOccupiedDestination() throws {
    let fm = FileManager.default
    let root = try makeTempFolder()
    defer { try? fm.removeItem(at: root) }
    let source = root.appendingPathComponent("source")
    try writeMLXModel(at: source)
    let destination = root.appendingPathComponent("destination")
    try writeMLXModel(at: destination)

    let plan = ModelImportPlan(
      family: .mlx(.qwen34BInstruct2507), displayName: "Qwen3 4B Instruct",
      source: source, destination: destination, byteCount: 2)

    #expect(throws: ModelImportError.self) {
      try ModelImporter.perform(plan) { _ in }
    }
  }

  @Test("Importing over a partial destination replaces it instead of refusing")
  func replacesIncompleteDestination() throws {
    let fm = FileManager.default
    let root = try makeTempFolder()
    defer { try? fm.removeItem(at: root) }
    let source = root.appendingPathComponent("source")
    try writeMLXModel(at: source)

    // A partial download sits at the destination already: config.json but no tokenizer.json, so
    // `MLXModelPaths.layout.hasRequiredFiles` does not consider it complete.
    let destination = root.appendingPathComponent("destination")
    try fm.createDirectory(at: destination, withIntermediateDirectories: true)
    try Data("partial".utf8).write(to: destination.appendingPathComponent("config.json"))

    let plan = ModelImportPlan(
      family: .mlx(.qwen34BInstruct2507), displayName: "Qwen3 4B Instruct",
      source: source, destination: destination, byteCount: ModelImporter.byteCount(at: source))

    try ModelImporter.perform(plan) { _ in }

    #expect(fm.fileExists(atPath: destination.appendingPathComponent("tokenizer.json").path))
    #expect(try String(contentsOf: destination.appendingPathComponent("config.json"), encoding: .utf8) == "{}")
  }
}
