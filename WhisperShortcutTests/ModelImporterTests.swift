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

  /// A minimal MLX repo: config.json plus one weights file.
  private func writeMLXModel(at folder: URL) throws {
    let fm = FileManager.default
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: folder.appendingPathComponent("config.json"))
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

  @Test("An MLX model in a cache snapshot is found")
  func findsMLXInCacheSnapshot() throws {
    let root = try makeTempFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let snapshot = root
      .appendingPathComponent("models--mlx-community--Qwen3-4B-Instruct-2507-4bit")
      .appendingPathComponent("snapshots")
      .appendingPathComponent("deadbeef")
    try writeMLXModel(at: snapshot)

    let plans = ModelImporter.plans(in: root)
    #expect(plans.contains { $0.displayName == "Qwen3 4B Instruct" })
  }

  @Test("An LM Studio style org/repo folder is found")
  func findsLMStudioLayout() throws {
    let root = try makeTempFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeMLXModel(
      at: root.appendingPathComponent("mlx-community/Qwen3-4B-Instruct-2507-4bit"))

    let plans = ModelImporter.plans(in: root)
    #expect(plans.contains { $0.displayName == "Qwen3 4B Instruct" })
  }

  @Test("A folder with nothing usable yields no plans")
  func emptyFolderYieldsNothing() throws {
    let root = try makeTempFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(ModelImporter.plans(in: root).isEmpty)
  }

  // MARK: - Copy

  @Test("Importing a cache snapshot dereferences its symlinks")
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
    try Data("{}".utf8).write(to: blobs.appendingPathComponent("configblob"))
    try Data("weights".utf8).write(to: blobs.appendingPathComponent("weightsblob"))
    try fm.createSymbolicLink(
      atPath: snapshot.appendingPathComponent("config.json").path,
      withDestinationPath: "../../blobs/configblob")
    try fm.createSymbolicLink(
      atPath: snapshot.appendingPathComponent("model.safetensors").path,
      withDestinationPath: "../../blobs/weightsblob")

    let destination = root.appendingPathComponent("imported")
    let plan = ModelImportPlan(
      family: .mlx(.qwen34BInstruct2507),
      displayName: "Qwen3 4B Instruct",
      source: snapshot,
      destination: destination,
      byteCount: 9,
      willClone: true)

    try ModelImporter.perform(plan) { _ in }

    // The imported file must be a real file with the blob's content, not a dangling link.
    let imported = destination.appendingPathComponent("model.safetensors")
    let values = try imported.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
    #expect(values.isSymbolicLink != true)
    #expect(values.isRegularFile == true)
    #expect(try String(contentsOf: imported, encoding: .utf8) == "weights")
  }

  @Test("Importing into an occupied destination is refused")
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
      source: source, destination: destination, byteCount: 2, willClone: true)

    #expect(throws: ModelImportError.self) {
      try ModelImporter.perform(plan) { _ in }
    }
  }
}
