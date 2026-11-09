//
//  ModelImporter.swift
//  WhisperShortcut
//
//  One-time import of model weights the user already has on disk.
//
//  Why an import and not a permanent folder reference: reading models from a folder outside the
//  app container for good means a security-scoped bookmark, stale paths after a move, and a
//  sandbox surface that has to be guarded on every access. After an import the model is a normal
//  model — Delete, completeness checks and updates work exactly as they do for a download.
//
//  Two details make the difference between a working import and a broken one:
//
//  - A Hugging Face cache stores snapshot files as *relative symlinks* into `../../blobs/<hash>`
//    (and, since huggingface_hub 1.32, a repo blob may itself link into a shared blob store at
//    the cache root). `FileManager.copyItem` copies those links as links, so a naive copy of a
//    snapshot folder produces a model whose files are all dangling. Every file is therefore
//    copied through `resolvingSymlinksInPath()`.
//  - On APFS, copying a file on the same volume is a clone (copy-on-write): instant and without
//    extra blocks. Across volumes it is a real copy of every byte. The plan says which one it
//    will be, so the UI can promise the right thing.
//

import Foundation

/// One model the importer found in a folder the user picked.
struct ModelImportPlan: Identifiable {
  enum Family {
    case whisper(OfflineModelType)
    case mlx(LocalLLMModelType)
    case qwen3(Qwen3ModelType)
  }

  let id = UUID()
  let family: Family
  /// What the row in the confirmation sheet calls it.
  let displayName: String
  /// The folder that holds the model's files (a snapshot directory for a cache, the repo folder
  /// for a plain checkout).
  let source: URL
  /// Where the files go inside the app container.
  let destination: URL
  /// Bytes that will be written when the copy is not a clone.
  let byteCount: Int64
  /// True when source and destination sit on the same volume, so APFS clones instead of copying.
  let willClone: Bool

  var sizeLabel: String {
    ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
  }
}

enum ModelImportError: LocalizedError {
  case nothingFound
  case copyFailed(String)
  case notEnoughSpace(needed: String, available: String)
  case destinationExists(String)

  var errorDescription: String? {
    switch self {
    case .nothingFound:
      return String(
        localized:
          "No model this app can use was found in that folder. Pick the folder that holds your LM Studio models or your Hugging Face cache."
      )
    case .copyFailed(let message):
      return String(localized: "The model could not be imported: \(message)")
    case .notEnoughSpace(let needed, let available):
      return String(
        localized:
          "Not enough disk space to import this model. About \(needed) is needed, but only \(available) is free."
      )
    case .destinationExists(let name):
      return String(localized: "\(name) is already downloaded. Delete it first if you want to replace it.")
    }
  }
}

enum ModelImporter {

  // MARK: - Discovery

  /// Every model this app can use that sits in `folder`, in catalogue order.
  ///
  /// The folder may be an LM Studio models directory, a Hugging Face cache root, or any folder
  /// that contains one of them — the search looks at the folder itself and one level down, which
  /// covers `~/.lmstudio/models/<publisher>/<repo>` and `~/.cache/huggingface/hub`.
  static func plans(in folder: URL) -> [ModelImportPlan] {
    let roots = searchRoots(for: folder)
    var plans: [ModelImportPlan] = []

    for type in OfflineModelType.allCases where type.engine == .whisperKit {
      if let plan = whisperPlan(for: type, in: roots) { plans.append(plan) }
    }
    for type in LocalLLMModelType.allCases {
      if let plan = mlxPlan(for: type, in: roots) { plans.append(plan) }
    }
    for type in Qwen3ModelType.allCases where type.isOfferable {
      if let plan = qwen3Plan(for: type, in: roots) { plans.append(plan) }
    }
    return plans
  }

  /// The picked folder plus its immediate children, so both "I picked the cache root" and
  /// "I picked the folder that contains my models" work.
  private static func searchRoots(for folder: URL) -> [URL] {
    var roots = [folder]
    if let children = try? FileManager.default.contentsOfDirectory(
      at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
      roots.append(contentsOf: children.filter { url in
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
      })
    }
    return roots
  }

  // MARK: - Whisper

  private static func whisperPlan(
    for type: OfflineModelType, in roots: [URL]
  ) -> ModelImportPlan? {
    guard let variant = type.whisperKitModelName else { return nil }
    let folderName = "openai_whisper-\(variant)"

    for root in roots {
      // A real Hugging Face cache: models--argmaxinc--whisperkit-coreml/snapshots/<hash>/<folder>
      let snapshots = root
        .appendingPathComponent("models--argmaxinc--whisperkit-coreml")
        .appendingPathComponent("snapshots")
      if let hashes = try? FileManager.default.contentsOfDirectory(atPath: snapshots.path) {
        for hash in hashes.sorted() {
          let candidate = snapshots.appendingPathComponent(hash).appendingPathComponent(folderName)
          if ModelManager.incompleteComponent(at: candidate) == nil {
            return plan(
              family: .whisper(type), displayName: type.displayName, source: candidate,
              destination: whisperDestination(for: type))
          }
        }
      }
      // A plain copy: the folder itself, or one level down (a copied WhisperKit tree).
      for candidate in [
        root.appendingPathComponent(folderName),
        root.appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(folderName)"),
      ] where ModelManager.incompleteComponent(at: candidate) == nil {
        return plan(
          family: .whisper(type), displayName: type.displayName, source: candidate,
          destination: whisperDestination(for: type))
      }
    }
    return nil
  }

  private static func whisperDestination(for type: OfflineModelType) -> URL {
    ModelManager.shared.rootDirectory
      .appendingPathComponent("models")
      .appendingPathComponent("argmaxinc")
      .appendingPathComponent("whisperkit-coreml")
      .appendingPathComponent("openai_whisper-\(type.whisperKitModelName ?? type.rawValue)")
  }

  // MARK: - MLX and Qwen3

  private static func mlxPlan(
    for type: LocalLLMModelType, in roots: [URL]
  ) -> ModelImportPlan? {
    guard let source = hubSource(for: type.huggingFaceID, in: roots) else { return nil }
    return plan(
      family: .mlx(type), displayName: type.displayName, source: source,
      destination: MLXModelPaths.hubDirectory
        .appendingPathComponent("models")
        .appendingPathComponent(type.huggingFaceID))
  }

  private static func qwen3Plan(
    for type: Qwen3ModelType, in roots: [URL]
  ) -> ModelImportPlan? {
    guard let source = hubSource(for: type.huggingFaceID, in: roots) else { return nil }
    return plan(
      family: .qwen3(type), displayName: type.displayName, source: source,
      destination: Qwen3ModelManager.shared.rootDirectory
        .appendingPathComponent("models")
        .appendingPathComponent(type.huggingFaceID))
  }

  /// The folder holding a Hub repo's files: a cache snapshot, or a plain `<org>/<repo>` checkout.
  private static func hubSource(for huggingFaceID: String, in roots: [URL]) -> URL? {
    let cacheFolder = "models--" + huggingFaceID.replacingOccurrences(of: "/", with: "--")
    let parts = huggingFaceID.split(separator: "/").map(String.init)

    for root in roots {
      // Cache layout: models--<org>--<repo>/snapshots/<hash>
      let snapshots = root.appendingPathComponent(cacheFolder).appendingPathComponent("snapshots")
      if let hashes = try? FileManager.default.contentsOfDirectory(atPath: snapshots.path) {
        for hash in hashes.sorted() {
          let candidate = snapshots.appendingPathComponent(hash)
          if hasHubFiles(at: candidate) { return candidate }
        }
      }
      // Plain checkout: <org>/<repo>, or models/<org>/<repo>.
      var plain = [root.appendingPathComponent(huggingFaceID)]
      if parts.count == 2 {
        plain.append(root.appendingPathComponent(parts[0]).appendingPathComponent(parts[1]))
      }
      plain.append(root.appendingPathComponent("models").appendingPathComponent(huggingFaceID))
      for candidate in plain where hasHubFiles(at: candidate) { return candidate }
    }
    return nil
  }

  /// `config.json` plus at least one weights file — the same bar the loaders use, so an
  /// interrupted download in the user's folder is not offered as an import.
  private static func hasHubFiles(at directory: URL) -> Bool {
    let fm = FileManager.default
    guard fm.fileExists(atPath: directory.appendingPathComponent("config.json").path) else {
      return false
    }
    guard let contents = try? fm.contentsOfDirectory(atPath: directory.path) else { return false }
    return contents.contains { $0.hasSuffix(".safetensors") || $0.hasSuffix(".bin") }
  }

  // MARK: - Plan construction

  private static func plan(
    family: ModelImportPlan.Family, displayName: String, source: URL, destination: URL
  ) -> ModelImportPlan {
    ModelImportPlan(
      family: family,
      displayName: displayName,
      source: source,
      destination: destination,
      byteCount: byteCount(at: source),
      willClone: sameVolume(source, destination.deletingLastPathComponent()))
  }

  /// Sum of the real file sizes, following symlinks — a cache snapshot's links are tiny, the
  /// blobs they point at are the gigabytes.
  private static func byteCount(at directory: URL) -> Int64 {
    let fm = FileManager.default
    guard let enumerator = fm.enumerator(
      at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
    else { return 0 }
    var total: Int64 = 0
    for case let url as URL in enumerator {
      let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
      guard values?.isRegularFile == true else { continue }
      total += Int64(values?.fileSize ?? 0)
    }
    return total
  }

  /// Whether a copy between these two directories stays on one volume, i.e. clones on APFS.
  private static func sameVolume(_ a: URL, _ b: URL) -> Bool {
    let keys: Set<URLResourceKey> = [.volumeIdentifierKey]
    guard let left = try? a.resourceValues(forKeys: keys).volumeIdentifier,
      let right = try? b.resourceValues(forKeys: keys).volumeIdentifier
    else { return false }
    return String(describing: left) == String(describing: right)
  }

  // MARK: - Import

  /// Copies one plan into the app container. Reports 0…1 by bytes written.
  ///
  /// The copy is written to a sibling temporary folder first and moved into place at the end, so
  /// an interrupted import never leaves a half-written model that `isModelAvailable` might
  /// mistake for a complete one.
  static func perform(_ plan: ModelImportPlan, onProgress: (Double) -> Void) throws {
    let fm = FileManager.default
    let destination = plan.destination

    guard !fm.fileExists(atPath: destination.path) else {
      throw ModelImportError.destinationExists(plan.displayName)
    }

    let parent = destination.deletingLastPathComponent()
    try fm.createDirectory(at: parent, withIntermediateDirectories: true)

    // A clone needs no free space; a real copy does.
    if !plan.willClone {
      let needed = Int64(Double(plan.byteCount) * DiskSpace.downloadMargin)
      if let available = try? parent.resourceValues(
        forKeys: [.volumeAvailableCapacityForImportantUsageKey]
      ).volumeAvailableCapacityForImportantUsage, available < needed {
        throw ModelImportError.notEnoughSpace(
          needed: ByteCountFormatter.string(fromByteCount: needed, countStyle: .file),
          available: ByteCountFormatter.string(fromByteCount: available, countStyle: .file))
      }
    }

    let staging = parent.appendingPathComponent(".import-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: staging) }

    var written: Int64 = 0
    let total = max(plan.byteCount, 1)
    do {
      try copyDereferencing(plan.source, to: staging) { bytes in
        written += bytes
        onProgress(min(1, Double(written) / Double(total)))
      }
      try fm.moveItem(at: staging, to: destination)
    } catch let error as ModelImportError {
      throw error
    } catch {
      throw ModelImportError.copyFailed(error.localizedDescription)
    }
    onProgress(1)
    DebugLogger.log(
      "MODEL-IMPORT: imported \(plan.displayName) from \(plan.source.path) "
        + "(\(plan.sizeLabel), \(plan.willClone ? "cloned" : "copied"))")
  }

  /// Recursive copy that follows symlinks, so a Hugging Face snapshot arrives as real files.
  private static func copyDereferencing(
    _ from: URL, to: URL, onBytes: (Int64) -> Void
  ) throws {
    let fm = FileManager.default
    let values = try from.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])

    if values.isSymbolicLink == true {
      // Follow the link (possibly a chain into a shared blob store) and copy the bytes.
      let resolved = from.resolvingSymlinksInPath()
      let resolvedValues = try resolved.resourceValues(forKeys: [.isDirectoryKey])
      if resolvedValues.isDirectory == true {
        try copyDereferencing(resolved, to: to, onBytes: onBytes)
      } else {
        try fm.copyItem(at: resolved, to: to)
        onBytes(Int64((try? resolved.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0))
      }
      return
    }

    if values.isDirectory == true {
      try fm.createDirectory(at: to, withIntermediateDirectories: true)
      for child in try fm.contentsOfDirectory(at: from, includingPropertiesForKeys: nil) {
        try copyDereferencing(
          child, to: to.appendingPathComponent(child.lastPathComponent), onBytes: onBytes)
      }
      return
    }

    try fm.copyItem(at: from, to: to)
    onBytes(Int64((try? from.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0))
  }

  // MARK: - Post-import

  /// Whisper's tokenizer is not part of the CoreML repo — it lives in `openai/whisper-<variant>`
  /// and WhisperKit fetches it on first load. An imported model therefore needs one network
  /// round-trip before it can load offline; this does it right after the import.
  static func finishWhisperImport(_ type: OfflineModelType) async throws {
    guard let path = ModelManager.shared.resolveModelPath(for: type) else { return }
    try await ModelManager.prefetchTokenizer(for: type, modelFolder: path)
  }
}
