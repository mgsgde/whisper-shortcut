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
//  The direct build can read `~/.cache/huggingface` and `~/.lmstudio/models` (a home-relative
//  read exception). The App Store build cannot, so those checks fail there. Any other folder is
//  invisible until the user picks it in Import from folder. Those picks are stored as app-scoped
//  bookmarks and opened only around the scan and the copy. A bookmark that does not resolve —
//  an unmounted volume, for example — is skipped for that scan and kept.
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

/// Where each family's models live, so a destination can be computed without going through the
/// live singletons. Production always uses `.live`; tests pass temp-folder roots so discovery
/// never reads (or is thrown off by) the real app container — a model Magnus happens to already
/// have downloaded on his own Mac must not change what a test expects to find.
struct ModelImportRoots {
  let whisper: URL
  let mlxHub: URL
  let qwen3: URL

  static var live: ModelImportRoots {
    ModelImportRoots(
      whisper: ModelManager.shared.rootDirectory,
      mlxHub: MLXModelPaths.hubDirectory,
      qwen3: Qwen3ModelManager.shared.rootDirectory)
  }
}

enum ModelImportError: LocalizedError {
  case nothingFound
  case copyFailed(String)
  case notEnoughSpace(needed: String, available: String)
  case destinationExists(String)
  case downloadInProgress(String)

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
    case .downloadInProgress(let name):
      return String(
        localized:
          "\(name) is already being downloaded. Wait for it to finish, or cancel it, before importing."
      )
    }
  }
}

/// What the stores say about a model before a copy starts.
///
/// Settings passes `.live`, which reads `isModelAvailable` (legacy folders and Hub
/// `snapshots/<hash>` included) and `downloadingModels`. The default `.unchecked` does not
/// touch the stores, so a test that copies into a temp folder is not refused because this Mac
/// already has the model.
struct ModelImportPreconditions {
  var isDownloading: Bool
  var isModelAvailable: Bool

  static let unchecked = ModelImportPreconditions(isDownloading: false, isModelAvailable: false)

  @MainActor
  static func live(for family: ModelImportPlan.Family) -> ModelImportPreconditions {
    switch family {
    case .whisper(let type):
      return ModelImportPreconditions(
        isDownloading: ModelManager.shared.downloadingModels.contains(type),
        isModelAvailable: ModelManager.shared.isModelAvailable(type))
    case .mlx(let type):
      return ModelImportPreconditions(
        isDownloading: LocalLLMModelManager.shared.downloadingModels.contains(type),
        isModelAvailable: LocalLLMModelManager.shared.isModelAvailable(type))
    case .qwen3(let type):
      return ModelImportPreconditions(
        isDownloading: Qwen3ModelManager.shared.downloadingModels.contains(type),
        isModelAvailable: Qwen3ModelManager.shared.isModelAvailable(type))
    }
  }
}

enum ModelImporter {

  /// Free space must cover the resolved size plus this margin, same idea as `DiskSpace` but a
  /// smaller margin: an import's size is measured exactly, a download's is only estimated.
  private static let spaceMargin = 1.1

  // MARK: - Existing-weights discovery

  /// `[Data]` security-scoped bookmarks of folders the user picked for import. At most five.
  static let folderBookmarksDefaultsKey = "modelImportFolderBookmarks"

  private static let maxFolderBookmarks = 5
  private static let bookmarkLock = NSLock()

  /// Stores a security-scoped bookmark for a folder the user picked. Dedupes by the path the
  /// bookmark resolves to and keeps at most five, dropping the oldest. Returns false when the
  /// bookmark could not be created; the folder is then invisible to the next scan.
  ///
  /// The scope is opened around `bookmarkData`: a panel URL already carries access (the extra
  /// claim is balanced and does not revoke it), and creating the bookmark without claiming the
  /// URL fails for any folder that arrived another way.
  @discardableResult
  static func saveFolderBookmark(_ url: URL) -> Bool {
    let accessed = url.startAccessingSecurityScopedResource()
    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
    let bookmark: Data
    do {
      bookmark = try url.bookmarkData(
        options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    } catch {
      DebugLogger.logError(
        "MODEL-IMPORT: could not bookmark \(url.path): \(error.logDescription)")
      return false
    }

    bookmarkLock.lock()
    defer { bookmarkLock.unlock() }
    let path = resolvedBookmarkURL(bookmark)?.standardizedFileURL.path ?? url.standardizedFileURL.path
    var bookmarks = storedBookmarks().filter { existing in
      resolvedBookmarkURL(existing)?.standardizedFileURL.path != path
    }
    bookmarks.append(bookmark)
    if bookmarks.count > maxFolderBookmarks {
      bookmarks.removeFirst(bookmarks.count - maxFolderBookmarks)
    }
    UserDefaults.standard.set(bookmarks, forKey: folderBookmarksDefaultsKey)
    DebugLogger.log("MODEL-IMPORT: bookmarked import folder \(path)")
    return true
  }

  /// Folders a Download click scans for weights the user already has.
  ///
  /// Bookmarked folders come first: each is resolved without UI and without mounting, a stale
  /// bookmark is refreshed, and one that does not resolve is skipped for this scan and kept.
  /// The Hugging Face hub cache and the LM Studio models directory are appended when this
  /// process can read them. The direct build's entitlement makes those two readable; the App
  /// Store build cannot, so they are skipped there. Resolving a bookmark does not grant file
  /// access: `existingWeightsPlan` starts it on these URLs for the scan and stops it before
  /// returning, and the copy calls `startAccessingSearchFolders()` again.
  static var searchFolders: [URL] {
    bookmarkLock.lock()
    defer { bookmarkLock.unlock() }
    var seen = Set<String>()
    var folders: [URL] = []
    for url in resolvedBookmarkedFolders() + readableDefaultCacheFolders() {
      guard seen.insert(url.standardizedFileURL.path).inserted else { continue }
      folders.append(url)
    }
    return folders
  }

  /// Starts security-scoped access for the bookmarked folders in `searchFolders`. Stop every
  /// returned URL when the scan or the copy finishes. Readable default caches are not
  /// security-scoped, so they are not included: access there needs no claim.
  static func startAccessingSearchFolders() -> [URL] {
    searchFolders.filter { $0.startAccessingSecurityScopedResource() }
  }

  static func stopAccessingSearchFolders(_ urls: [URL]) {
    for url in urls { url.stopAccessingSecurityScopedResource() }
  }

  /// An import plan for exactly `model` from the bookmarked folders and any readable default
  /// cache, or nil when the user does not already have it. This is what the Download button asks
  /// about before starting a multi-gigabyte download the user may not need. Cheap (a handful of
  /// stat calls on the expected snapshot paths, no byte counting until a plan is built) but not
  /// free — call it off the main thread.
  static func existingWeightsPlan<M: DownloadableModel>(for model: M) -> ModelImportPlan? {
    let folders = searchFolders
    guard !folders.isEmpty else { return nil }
    // Same URL objects the scan reads. Access is stopped before returning so a bookmark is not
    // held open across the alert; the copy claims it again.
    let accessed = folders.filter { $0.startAccessingSecurityScopedResource() }
    defer { stopAccessingSearchFolders(accessed) }
    let roots = folders.flatMap { searchRoots(for: $0) }
    let live = ModelImportRoots.live
    switch model {
    case let type as OfflineModelType:
      guard type.engine == .whisperKit else { return nil }
      let destination = ModelManager.importDestination(for: type, under: live.whisper)
      guard !isComplete(at: destination, family: .whisper(type)) else { return nil }
      return whisperPlan(
        for: type, in: roots, destination: destination)
    case let type as LocalLLMModelType:
      let destination = HubSnapshotLayout.importDestination(
        for: type.huggingFaceID, under: live.mlxHub)
      guard !isComplete(at: destination, family: .mlx(type)) else { return nil }
      return mlxPlan(for: type, in: roots, destination: destination)
    case let type as Qwen3ModelType:
      let destination = HubSnapshotLayout.importDestination(
        for: type.huggingFaceID, under: live.qwen3)
      guard !isComplete(at: destination, family: .qwen3(type)) else { return nil }
      return qwen3Plan(for: type, in: roots, destination: destination)
    default:
      return nil
    }
  }

  /// Caller holds `bookmarkLock`.
  private static func storedBookmarks() -> [Data] {
    UserDefaults.standard.array(forKey: folderBookmarksDefaultsKey) as? [Data] ?? []
  }

  private static func resolvedBookmarkURL(_ data: Data) -> URL? {
    var stale = false
    return resolvedBookmarkURL(data, stale: &stale)
  }

  private static func resolvedBookmarkURL(_ data: Data, stale: inout Bool) -> URL? {
    // No UI and no mounting: a missing volume must not pop a dialog or spin a disk. The
    // caller skips that bookmark for this scan and leaves the data stored.
    try? URL(
      resolvingBookmarkData: data,
      options: [.withSecurityScope, .withoutUI, .withoutMounting],
      relativeTo: nil,
      bookmarkDataIsStale: &stale)
  }

  /// Caller holds `bookmarkLock`. Refreshes stale bookmarks and drops a second bookmark that
  /// resolves to a path already kept. A bookmark that does not resolve is kept and skipped:
  /// the volume may only be unmounted.
  private static func resolvedBookmarkedFolders() -> [URL] {
    let stored = storedBookmarks()
    var kept: [Data] = []
    var urls: [URL] = []
    var seen = Set<String>()
    var changed = false
    for bookmark in stored {
      var stale = false
      guard let url = resolvedBookmarkURL(bookmark, stale: &stale) else {
        kept.append(bookmark)
        DebugLogger.log("MODEL-IMPORT: skipping an import-folder bookmark that did not resolve")
        continue
      }
      let path = url.standardizedFileURL.path
      guard seen.insert(path).inserted else {
        changed = true
        continue
      }
      var current = bookmark
      if stale {
        let accessed = url.startAccessingSecurityScopedResource()
        if let refreshed = try? url.bookmarkData(
          options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
          current = refreshed
          changed = true
        }
        if accessed { url.stopAccessingSecurityScopedResource() }
      }
      kept.append(current)
      urls.append(url)
    }
    if changed {
      UserDefaults.standard.set(kept, forKey: folderBookmarksDefaultsKey)
    }
    return urls
  }

  /// The folder a Download alert should name: the chosen search folder that contains `source`
  /// (a bookmark, or a readable default cache), not the snapshot directory inside it.
  /// A path under the real home is shown with a tilde. `abbreviatingWithTildeInPath` uses the
  /// process home, which is the container in a sandbox, so a real-home path that the API leaves
  /// absolute is abbreviated against `AppConstants.realHomeDirectory`. Anything else is named
  /// by its last path component.
  static func existingFolderLabel(containing source: URL) -> String {
    let sourcePath = source.standardizedFileURL.path
    let match = searchFolders
      .map(\.standardizedFileURL.path)
      .filter { folder in
        sourcePath == folder || sourcePath.hasPrefix(folder + "/")
      }
      .max(by: { $0.count < $1.count })
    let path = match ?? source.deletingLastPathComponent().standardizedFileURL.path
    return abbreviatedFolderPath(path)
  }

  private static func abbreviatedFolderPath(_ path: String) -> String {
    let abbreviated = (path as NSString).abbreviatingWithTildeInPath
    if abbreviated.hasPrefix("~") { return abbreviated }
    let home = AppConstants.realHomeDirectory
    if path == home { return "~" }
    if path.hasPrefix(home + "/") {
      return "~" + path.dropFirst(home.count)
    }
    return (path as NSString).lastPathComponent
  }

  /// Hugging Face hub cache and LM Studio models, included only when this process can read
  /// them. The direct build's home-relative entitlement makes these readable; the App Store
  /// build cannot, so both checks fail and only bookmarked folders remain.
  private static func readableDefaultCacheFolders() -> [URL] {
    let home = AppConstants.realHomeDirectory
    return ["/.cache/huggingface/hub", "/.lmstudio/models"].compactMap { suffix in
      let path = home + suffix
      guard FileManager.default.isReadableFile(atPath: path) else { return nil }
      return URL(fileURLWithPath: path, isDirectory: true)
    }
  }

  // MARK: - Discovery

  /// Every model this app can use that sits in `folder`, in catalogue order. Models already fully
  /// on disk are left out — importing them again would just be a slower way to see what the
  /// download list already shows.
  ///
  /// The folder may be an LM Studio models directory, a Hugging Face cache root, or any folder
  /// that contains one of them — the search looks at the folder itself and one level down, which
  /// covers `~/.lmstudio/models/<publisher>/<repo>` and `~/.cache/huggingface/hub`.
  static func plans(in folder: URL, roots importRoots: ModelImportRoots = .live) -> [ModelImportPlan] {
    let searchedRoots = searchRoots(for: folder)
    var plans: [ModelImportPlan] = []

    for type in OfflineModelType.offerable where type.engine == .whisperKit {
      let destination = ModelManager.importDestination(for: type, under: importRoots.whisper)
      guard !isComplete(at: destination, family: .whisper(type)) else { continue }
      if let plan = whisperPlan(for: type, in: searchedRoots, destination: destination) {
        plans.append(plan)
      }
    }
    for type in LocalLLMModelType.allCases where type.isOfferable {
      let destination = HubSnapshotLayout.importDestination(
        for: type.huggingFaceID, under: importRoots.mlxHub)
      guard !isComplete(at: destination, family: .mlx(type)) else { continue }
      if let plan = mlxPlan(for: type, in: searchedRoots, destination: destination) {
        plans.append(plan)
      }
    }
    for type in Qwen3ModelType.allCases where type.isOfferable {
      let destination = HubSnapshotLayout.importDestination(
        for: type.huggingFaceID, under: importRoots.qwen3)
      guard !isComplete(at: destination, family: .qwen3(type)) else { continue }
      if let plan = qwen3Plan(for: type, in: searchedRoots, destination: destination) {
        plans.append(plan)
      }
    }
    return plans
  }

  /// The picked folder plus its immediate children, so both "I picked the cache root" and
  /// "I picked the folder that contains my models" work.
  ///
  /// `~/.cache/huggingface/hub` is one of those children when the pick is the cache root, so
  /// `hub/models--*` is already reached. `isDirectoryKey` is false for a symlink, and a `hub`
  /// that is only a link would be skipped — add it when it exists and is not already listed.
  private static func searchRoots(for folder: URL) -> [URL] {
    var roots = [folder]
    if let children = try? FileManager.default.contentsOfDirectory(
      at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
      roots.append(contentsOf: children.filter { url in
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
      })
    }
    let hub = folder.appendingPathComponent("hub", isDirectory: true)
    var hubIsDirectory: ObjCBool = false
    if FileManager.default.fileExists(atPath: hub.path, isDirectory: &hubIsDirectory),
      hubIsDirectory.boolValue,
      !roots.contains(where: { $0.standardizedFileURL.path == hub.standardizedFileURL.path }) {
      roots.append(hub)
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
    for type: OfflineModelType, in roots: [URL], destination: URL
  ) -> ModelImportPlan? {
    guard let variant = type.whisperKitModelName else { return nil }
    let folderName = "openai_whisper-\(variant)"

    for root in roots {
      // A real Hugging Face cache: models--argmaxinc--whisperkit-coreml/snapshots/<hash>/<folder>
      let repoFolder = root.appendingPathComponent("models--argmaxinc--whisperkit-coreml")
      let snapshots = repoFolder.appendingPathComponent("snapshots")
      if let hashes = try? FileManager.default.contentsOfDirectory(atPath: snapshots.path) {
        for hash in HubSnapshotOrder.preferred(in: repoFolder, among: hashes) {
          let candidate = snapshots.appendingPathComponent(hash).appendingPathComponent(folderName)
          if ModelManager.incompleteComponent(at: candidate) == nil {
            return plan(
              family: .whisper(type), displayName: type.displayName, source: candidate,
              destination: destination,
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
          destination: destination,
          whisperTokenizerSource: whisperTokenizerSource(for: type, in: roots))
      }
    }
    return nil
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
      for hash in HubSnapshotOrder.preferred(in: repoFolder, among: hashes) {
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

  /// An MLX chat model in the user's folder, or nil.
  private static func mlxPlan(
    for type: LocalLLMModelType, in roots: [URL], destination: URL
  ) -> ModelImportPlan? {
    guard let source = hubSource(
      for: type.huggingFaceID, in: roots, hasRequiredFiles: MLXModelPaths.layout.hasRequiredFiles)
    else { return nil }
    return plan(
      family: .mlx(type), displayName: type.displayName, source: source, destination: destination)
  }

  /// A Qwen3 audio model in the user's folder, or nil. Only offered models are searched, so a
  /// 16 GB Mac does not get an import row for a checkpoint it cannot run.
  private static func qwen3Plan(
    for type: Qwen3ModelType, in roots: [URL], destination: URL
  ) -> ModelImportPlan? {
    guard let source = hubSource(
      for: type.huggingFaceID, in: roots,
      hasRequiredFiles: Qwen3ModelManager.shared.layout.hasRequiredFiles)
    else { return nil }
    return plan(
      family: .qwen3(type), displayName: type.displayName, source: source, destination: destination)
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
        for hash in HubSnapshotOrder.preferred(in: repoFolder, among: hashes) {
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

  private static func modificationDate(of url: URL) -> Date {
    HubSnapshotOrder.modificationDate(of: url)
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
  /// for a complete one. A model the store already has — including a legacy folder or a Hub
  /// snapshot that is not this destination — is refused. Only an occupied but incomplete
  /// destination is replaced.
  static func perform(
    _ plan: ModelImportPlan,
    preconditions: ModelImportPreconditions = .unchecked,
    onProgress: (Double) -> Void
  ) throws {
    if preconditions.isDownloading {
      throw ModelImportError.downloadInProgress(plan.displayName)
    }
    if preconditions.isModelAvailable {
      throw ModelImportError.destinationExists(plan.displayName)
    }

    let fm = FileManager.default
    let destination = plan.destination
    let parent = destination.deletingLastPathComponent()

    // A previous import that crashed or was force-quit mid-copy can leave its staging folder
    // behind; clear it before starting a new one. A folder another import is still writing is
    // left alone.
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
    // Register before the folder exists, so a second import's cleanup cannot delete it once
    // the copy has been running long enough for the folder to look old.
    beginStaging(staging)
    defer {
      endStaging(staging)
      try? fm.removeItem(at: staging)
    }

    var written: Int64 = 0
    let total = max(plan.byteCount, 1)
    do {
      try copyDereferencing(plan.source, to: staging) { bytes in
        written += bytes
        onProgress(min(1, Double(written) / Double(total)))
      }
      if destinationOccupied {
        let aside = parent.appendingPathComponent(".import-old-\(UUID().uuidString)")
        // The move keeps the partial download's modification date, which can be hours old.
        // Register it so a concurrent cleanup does not delete the copy we would roll back to.
        beginStaging(aside)
        defer { endStaging(aside) }
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

  /// How long an `.import-*` folder may sit before a later import treats it as abandoned.
  /// A copy still in progress is tracked in `activeStagingPaths` and is never removed, however
  /// old its modification date has become.
  static let staleStagingMaxAge: TimeInterval = 60 * 60

  private static let stagingLock = NSLock()
  private static var activeStagingPaths: Set<String> = []

  /// Path key for the active-staging set. Symlinks in `/var` → `/private/var` must match on
  /// both the register side and the directory listing.
  static func stagingKey(_ url: URL) -> String {
    url.resolvingSymlinksInPath().path
  }

  /// Registers `url` so `removeStaleStaging` will not delete it. Call before creating the folder.
  static func beginStaging(_ url: URL) {
    stagingLock.lock()
    activeStagingPaths.insert(stagingKey(url))
    stagingLock.unlock()
  }

  static func endStaging(_ url: URL) {
    stagingLock.lock()
    activeStagingPaths.remove(stagingKey(url))
    stagingLock.unlock()
  }

  private static func activeStagingSnapshot() -> Set<String> {
    stagingLock.lock()
    defer { stagingLock.unlock() }
    return activeStagingPaths
  }

  /// Removes abandoned `.import-*` folders in `parent`. Skips any folder `beginStaging` has
  /// registered, and any other folder newer than `staleStagingMaxAge`. MLX imports share one
  /// parent (`hub/models`), so a second import must not delete the first import's staging.
  static func removeStaleStaging(in parent: URL, now: Date = Date()) {
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: parent.path) else {
      return
    }
    let active = activeStagingSnapshot()
    let cutoff = now.addingTimeInterval(-staleStagingMaxAge)
    for name in names where name.hasPrefix(".import-") {
      let url = parent.appendingPathComponent(name)
      if active.contains(stagingKey(url)) { continue }
      guard modificationDate(of: url) < cutoff else { continue }
      try? FileManager.default.removeItem(at: url)
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
