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
//  A Hugging Face cache stores snapshot files as *relative symlinks* into `../../blobs/<hash>`
//  (and, since huggingface_hub 1.32, a repo blob may itself link into a shared blob store at the
//  cache root). `FileManager.copyItem` copies those links as links, so a naive copy of a snapshot
//  folder produces a model whose files are all dangling. Every file is therefore copied through
//  `resolvingSymlinksInPath()`.
//

import Foundation

/// One model the importer found in a folder the user picked.
struct ModelImportPlan: Identifiable {
  enum Family {
    case whisper(OfflineModelType)
    case mlx(LocalLLMModelType)
    case qwen3(Qwen3ModelType)

    /// Which call site may offer this plan — each Settings section only imports its own family.
    var group: ModelImportGroup {
      switch self {
      case .whisper: return .speechToText
      case .mlx: return .chat
      case .qwen3(let type): return type == .asr ? .speechToText : .readAloud
      }
    }
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
  /// Bytes that will be copied, real file sizes with symlinks resolved.
  let byteCount: Int64
  /// For a Whisper plan only: a local `openai/whisper-<variant>` tokenizer snapshot found next to
  /// the weights, so the import can copy it in instead of needing the network afterwards.
  var whisperTokenizerSource: URL?

  init(
    family: Family, displayName: String, source: URL, destination: URL, byteCount: Int64,
    whisperTokenizerSource: URL? = nil
  ) {
    self.family = family
    self.displayName = displayName
    self.source = source
    self.destination = destination
    self.byteCount = byteCount
    self.whisperTokenizerSource = whisperTokenizerSource
  }

  var sizeLabel: String {
    ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
  }
}

/// Which Settings section may offer a plan — Speech to Text imports Whisper and Qwen3-ASR, the
/// chat/offline-LLM sections import MLX chat models, Read Aloud imports Qwen3 TTS.
enum ModelImportGroup {
  case speechToText
  case chat
  case readAloud
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

  /// Free space must cover the resolved size plus this margin, same idea as `DiskSpace` but a
  /// smaller margin: an import's size is measured exactly, a download's is only estimated.
  private static let spaceMargin = 1.1

  // MARK: - Discovery

  /// Every model this app can use that sits in `folder`, in catalogue order. Models already fully
  /// on disk are left out — importing them again would just be a slower way to see what the
  /// download list already shows.
  ///
  /// The folder may be an LM Studio models directory, a Hugging Face cache root, or any folder
  /// that contains one of them — the search looks at the folder itself and one level down, which
  /// covers `~/.lmstudio/models/<publisher>/<repo>` and `~/.cache/huggingface/hub`.
  static func plans(in folder: URL) -> [ModelImportPlan] {
    let roots = searchRoots(for: folder)
    var plans: [ModelImportPlan] = []

    for type in OfflineModelType.offerable where type.engine == .whisperKit {
      guard !isComplete(at: whisperDestination(for: type), family: .whisper(type)) else { continue }
      if let plan = whisperPlan(for: type, in: roots) { plans.append(plan) }
    }
    for type in LocalLLMModelType.allCases where type.isOfferable {
      guard !isComplete(at: mlxDestination(for: type), family: .mlx(type)) else { continue }
      if let plan = mlxPlan(for: type, in: roots) { plans.append(plan) }
    }
    for type in Qwen3ModelType.allCases where type.isOfferable {
      guard !isComplete(at: qwen3Destination(for: type), family: .qwen3(type)) else { continue }
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

  /// Whether `directory` already holds a complete model for `family` — the same bar the loader
  /// uses, so a half-written folder is never treated as "already have it".
  private static func isComplete(at directory: URL, family: ModelImportPlan.Family) -> Bool {
    switch family {
    case .whisper:
      return FileManager.default.fileExists(atPath: directory.path)
        && ModelManager.incompleteComponent(at: directory) == nil
    case .mlx:
      return MLXModelPaths.layout.hasRequiredFiles(at: directory)
    case .qwen3:
      return Qwen3ModelManager.shared.layout.hasRequiredFiles(at: directory)
    }
  }

  // MARK: - Whisper

  /// A WhisperKit model in the user's folder, or nil. Tried in this order per root: a real
  /// Hugging Face cache snapshot, then a plain folder, then a copied WhisperKit tree.
  ///
  /// Completeness is `ModelManager.incompleteComponent` — the same check the loader runs — so a
  /// half-written copy in the user's folder is never offered as an import.
  private static func whisperPlan(
    for type: OfflineModelType, in roots: [URL]
  ) -> ModelImportPlan? {
    guard let variant = type.whisperKitModelName else { return nil }
    let folderName = "openai_whisper-\(variant)"

    for root in roots {
      // A real Hugging Face cache: models--argmaxinc--whisperkit-coreml/snapshots/<hash>/<folder>
      let repoFolder = root.appendingPathComponent("models--argmaxinc--whisperkit-coreml")
      let snapshots = repoFolder.appendingPathComponent("snapshots")
      if let hashes = try? FileManager.default.contentsOfDirectory(atPath: snapshots.path) {
        for hash in preferredOrder(in: repoFolder, among: hashes) {
          let candidate = snapshots.appendingPathComponent(hash).appendingPathComponent(folderName)
          if ModelManager.incompleteComponent(at: candidate) == nil {
            return plan(
              family: .whisper(type), displayName: type.displayName, source: candidate,
              destination: whisperDestination(for: type),
              whisperTokenizerSource: whisperTokenizerSource(for: type, in: roots))
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
          destination: whisperDestination(for: type),
          whisperTokenizerSource: whisperTokenizerSource(for: type, in: roots))
      }
    }
    return nil
  }

  /// Where an imported Whisper model goes: the same `models/argmaxinc/whisperkit-coreml/…`
  /// layout a download produces, so `resolveModelPath` finds it without a special case.
  private static func whisperDestination(for type: OfflineModelType) -> URL {
    ModelManager.shared.rootDirectory
      .appendingPathComponent("models")
      .appendingPathComponent("argmaxinc")
      .appendingPathComponent("whisperkit-coreml")
      .appendingPathComponent("openai_whisper-\(type.whisperKitModelName ?? type.rawValue)")
  }

  /// A local `openai/whisper-<variant>` tokenizer cache snapshot in the same folder tree, if any
  /// — lets the import copy the tokenizer in instead of needing the network afterwards.
  private static func whisperTokenizerSource(for type: OfflineModelType, in roots: [URL]) -> URL? {
    guard let variant = ModelManager.tokenizerVariant(for: type) else { return nil }
    let repoName = "models--openai--" + ModelManager.tokenizerRepoName(for: variant)
    for root in roots {
      let repoFolder = root.appendingPathComponent(repoName)
      let snapshots = repoFolder.appendingPathComponent("snapshots")
      guard let hashes = try? FileManager.default.contentsOfDirectory(atPath: snapshots.path) else {
        continue
      }
      for hash in preferredOrder(in: repoFolder, among: hashes) {
        let candidate = snapshots.appendingPathComponent(hash)
        if FileManager.default.fileExists(
          atPath: candidate.appendingPathComponent("tokenizer.json").path) {
          return candidate
        }
      }
    }
    return nil
  }

  // MARK: - MLX and Qwen3

  private static func mlxDestination(for type: LocalLLMModelType) -> URL {
    MLXModelPaths.hubDirectory
      .appendingPathComponent("models")
      .appendingPathComponent(type.huggingFaceID)
  }

  private static func qwen3Destination(for type: Qwen3ModelType) -> URL {
    Qwen3ModelManager.shared.rootDirectory
      .appendingPathComponent("models")
      .appendingPathComponent(type.huggingFaceID)
  }

  /// An MLX chat model in the user's folder, or nil.
  private static func mlxPlan(
    for type: LocalLLMModelType, in roots: [URL]
  ) -> ModelImportPlan? {
    guard let source = hubSource(
      for: type.huggingFaceID, in: roots, hasRequiredFiles: MLXModelPaths.layout.hasRequiredFiles)
    else { return nil }
    return plan(
      family: .mlx(type), displayName: type.displayName, source: source,
      destination: mlxDestination(for: type))
  }

  /// A Qwen3 audio model in the user's folder, or nil. Only offered models are searched, so a
  /// 16 GB Mac does not get an import row for a checkpoint it cannot run.
  private static func qwen3Plan(
    for type: Qwen3ModelType, in roots: [URL]
  ) -> ModelImportPlan? {
    guard let source = hubSource(
      for: type.huggingFaceID, in: roots,
      hasRequiredFiles: Qwen3ModelManager.shared.layout.hasRequiredFiles)
    else { return nil }
    return plan(
      family: .qwen3(type), displayName: type.displayName, source: source,
      destination: qwen3Destination(for: type))
  }

  /// The folder holding a Hub repo's files: a cache snapshot, or a plain `<org>/<repo>` checkout.
  /// `hasRequiredFiles` is the loader's own completeness check, so a half-downloaded repo in the
  /// user's folder is never offered as an import.
  private static func hubSource(
    for huggingFaceID: String, in roots: [URL], hasRequiredFiles: (URL) -> Bool
  ) -> URL? {
    let cacheFolder = "models--" + huggingFaceID.replacingOccurrences(of: "/", with: "--")

    for root in roots {
      // Cache layout: models--<org>--<repo>/snapshots/<hash>
      let repoFolder = root.appendingPathComponent(cacheFolder)
      let snapshots = repoFolder.appendingPathComponent("snapshots")
      if let hashes = try? FileManager.default.contentsOfDirectory(atPath: snapshots.path) {
        for hash in preferredOrder(in: repoFolder, among: hashes) {
          let candidate = snapshots.appendingPathComponent(hash)
          if hasRequiredFiles(candidate) { return candidate }
        }
      }
      // Plain checkout: <org>/<repo>, or models/<org>/<repo> (LM Studio's layout).
      for candidate in [
        root.appendingPathComponent(huggingFaceID),
        root.appendingPathComponent("models").appendingPathComponent(huggingFaceID),
      ] where hasRequiredFiles(candidate) { return candidate }
    }
    return nil
  }

  /// Orders a repo's snapshot hashes to try: the one `refs/main` names first — Hub keeps it
  /// pointed at the default revision — then every other snapshot, newest-modified first. Plain
  /// lexicographic order (`sorted()`) could land on an older, stale snapshot when a repo has more
  /// than one.
  private static func preferredOrder(in repoFolder: URL, among hashes: [String]) -> [String] {
    let pinned = (try? String(contentsOf: repoFolder.appendingPathComponent("refs/main"), encoding: .utf8))?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let snapshots = repoFolder.appendingPathComponent("snapshots")
    let rest = hashes.filter { $0 != pinned }.sorted { a, b in
      modificationDate(of: snapshots.appendingPathComponent(a))
        > modificationDate(of: snapshots.appendingPathComponent(b))
    }
    guard let pinned, hashes.contains(pinned) else { return rest }
    return [pinned] + rest
  }

  private static func modificationDate(of url: URL) -> Date {
    (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
      ?? .distantPast
  }

  // MARK: - Plan construction

  private static func plan(
    family: ModelImportPlan.Family, displayName: String, source: URL, destination: URL,
    whisperTokenizerSource: URL? = nil
  ) -> ModelImportPlan {
    ModelImportPlan(
      family: family,
      displayName: displayName,
      source: source,
      destination: destination,
      byteCount: byteCount(at: source),
      whisperTokenizerSource: whisperTokenizerSource)
  }

  /// Sum of the real file sizes, following symlinks — a cache snapshot's links are tiny, the
  /// blobs they point at are the gigabytes. Internal (not `private`) so tests can check it against
  /// a known fixture instead of hand-writing an expected byte count.
  static func byteCount(at directory: URL) -> Int64 {
    let fm = FileManager.default
    guard let enumerator = fm.enumerator(
      at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey])
    else { return 0 }
    var total: Int64 = 0
    for case let url as URL in enumerator {
      let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
      if values?.isDirectory == true { continue }
      let resolved = values?.isSymbolicLink == true ? url.resolvingSymlinksInPath() : url
      total += Int64((try? resolved.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }
    return total
  }

  // MARK: - Import

  /// Copies one plan into the app container. Reports 0…1 by bytes written.
  ///
  /// The copy is written to a sibling temporary folder first and moved into place at the end, so
  /// an interrupted import never leaves a half-written model that `isModelAvailable` might mistake
  /// for a complete one. If the destination already holds a partial download (not a complete
  /// model), the import replaces it instead of refusing.
  static func perform(_ plan: ModelImportPlan, onProgress: (Double) -> Void) throws {
    let fm = FileManager.default
    let destination = plan.destination
    let parent = destination.deletingLastPathComponent()

    // A previous import that crashed or was force-quit mid-copy can leave its staging folder
    // behind; clear it before starting a new one.
    removeStaleStaging(in: parent)

    let destinationOccupied = fm.fileExists(atPath: destination.path)
    if destinationOccupied && isComplete(at: destination, family: plan.family) {
      throw ModelImportError.destinationExists(plan.displayName)
    }

    try fm.createDirectory(at: parent, withIntermediateDirectories: true)

    let needed = Int64(Double(plan.byteCount) * spaceMargin)
    let volumeRoot = firstExistingAncestor(of: destination)
    if let available = try? volumeRoot.resourceValues(
      forKeys: [.volumeAvailableCapacityForImportantUsageKey]
    ).volumeAvailableCapacityForImportantUsage, available < needed {
      throw ModelImportError.notEnoughSpace(
        needed: ByteCountFormatter.string(fromByteCount: needed, countStyle: .file),
        available: ByteCountFormatter.string(fromByteCount: available, countStyle: .file))
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
      if destinationOccupied {
        let aside = parent.appendingPathComponent(".import-old-\(UUID().uuidString)")
        try fm.moveItem(at: destination, to: aside)
        do {
          try fm.moveItem(at: staging, to: destination)
        } catch {
          try? fm.moveItem(at: aside, to: destination)
          throw error
        }
        try? fm.removeItem(at: aside)
      } else {
        try fm.moveItem(at: staging, to: destination)
      }
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as ModelImportError {
      throw error
    } catch {
      throw ModelImportError.copyFailed(error.localizedDescription)
    }
    onProgress(1)
    DebugLogger.log(
      "MODEL-IMPORT: imported \(plan.displayName) from \(plan.source.path) (\(plan.sizeLabel))")
  }

  /// Removes `.import-*` staging (and swapped-aside) folders left in `parent` by a previous
  /// import that never finished.
  private static func removeStaleStaging(in parent: URL) {
    guard let entries = try? FileManager.default.contentsOfDirectory(atPath: parent.path) else {
      return
    }
    for entry in entries where entry.hasPrefix(".import-") {
      try? FileManager.default.removeItem(at: parent.appendingPathComponent(entry))
    }
  }

  /// The nearest ancestor of `url` that exists on disk, for the free-space check — a nested
  /// destination's immediate parent may not have been created yet.
  private static func firstExistingAncestor(of url: URL) -> URL {
    var candidate = url
    while !FileManager.default.fileExists(atPath: candidate.path) {
      let next = candidate.deletingLastPathComponent()
      if next.path == candidate.path { return candidate }
      candidate = next
    }
    return candidate
  }

  /// Recursive copy that follows symlinks, so a Hugging Face snapshot arrives as real files.
  /// Checked for cancellation per file/directory, so a multi-gigabyte copy stops promptly.
  private static func copyDereferencing(
    _ from: URL, to: URL, onBytes: (Int64) -> Void
  ) throws {
    if Task.isCancelled { throw CancellationError() }
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
  /// and WhisperKit fetches it on first load. This finishes an import by either copying in a
  /// tokenizer snapshot found next to the weights, or — only if there is none — fetching it over
  /// the network. Never throws: a failed network fetch just leaves the model needing one more
  /// network round-trip, which the caller detects via `ModelManager.isModelAvailable` and the
  /// row's own Download action resolves later.
  static func finishWhisperImport(_ plan: ModelImportPlan) async {
    guard case .whisper(let type) = plan.family,
      let destinationPath = ModelManager.shared.resolveModelPath(for: type)
    else { return }

    if let tokenizerSource = plan.whisperTokenizerSource,
      let bundled = ModelManager.bundledTokenizerFolder(for: type, modelFolder: destinationPath) {
      do {
        try copyDereferencing(tokenizerSource, to: bundled) { _ in }
        DebugLogger.log("MODEL-IMPORT: copied tokenizer for \(type.displayName) from \(tokenizerSource.path)")
        return
      } catch {
        DebugLogger.logWarning(
          "MODEL-IMPORT: tokenizer copy failed (\(error.localizedDescription)), trying the network")
      }
    }

    do {
      try await ModelManager.prefetchTokenizer(for: type, modelFolder: destinationPath)
    } catch {
      DebugLogger.logWarning(
        "MODEL-IMPORT: tokenizer prefetch failed, \(type.displayName) needs the network once: \(error.localizedDescription)")
    }
  }
}
