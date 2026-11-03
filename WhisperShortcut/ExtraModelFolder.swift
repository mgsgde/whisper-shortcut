import Foundation

/// An additional folder the user pointed the app at, so weights they already have on disk
/// (an LM Studio models folder, a Hugging Face cache, a shared drive) do not have to be
/// downloaded again. One folder, chosen with a picker — never an automatic disk scan: the
/// user says where to look and the app looks only there.
///
/// Read-only from the app's point of view. Downloads keep going to the app's own folder
/// (`ModelManager.rootDirectory`, `MLXModelPaths.hubDirectory`); nothing here is ever moved,
/// changed or deleted.
///
/// The bookmark handling is `ScreenshotSaveLocation`'s, with one addition: the security scope is
/// held open for the lifetime of the process once the folder resolves. The resolvers only *find*
/// a folder — the actual read happens much later, inside `WhisperKit(config)` and
/// `loadModel(from:)`, on paths that are not ours to wrap (the WhisperKit load site lives in
/// `LocalSpeechService`). A scope that is opened and closed around the existence check would be
/// closed again by the time the model is loaded, and the sandbox would deny the read.
enum ExtraModelFolder {
  // MARK: - Configuration

  static var hasFolder: Bool {
    UserDefaults.standard.data(forKey: UserDefaultsKeys.extraModelFolderBookmark) != nil
  }

  /// The path as picked, for display. Cheap (no bookmark resolution), so it is safe to read from
  /// SwiftUI body evaluation.
  static var displayPath: String {
    UserDefaults.standard.string(forKey: UserDefaultsKeys.extraModelFolderDisplayPath) ?? ""
  }

  /// Stores a security-scoped bookmark for the chosen folder plus its display path.
  @discardableResult
  static func setFolder(_ url: URL) -> Bool {
    do {
      let bookmark = try url.bookmarkData(
        options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
      UserDefaults.standard.set(bookmark, forKey: UserDefaultsKeys.extraModelFolderBookmark)
      UserDefaults.standard.set(url.path, forKey: UserDefaultsKeys.extraModelFolderDisplayPath)
      // A different folder: drop the old lease before claiming the new one, so the app does not
      // keep a grant on a folder the user no longer uses.
      releaseLease()
      retainAccess(to: url)
      DebugLogger.log("MODEL-FOLDER: Model folder set to \(url.path)")
      return true
    } catch {
      DebugLogger.logError(
        "MODEL-FOLDER: Failed to bookmark folder \(url.path): \(error.localizedDescription)")
      return false
    }
  }

  static func clear() {
    releaseLease()
    UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.extraModelFolderBookmark)
    UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.extraModelFolderDisplayPath)
    DebugLogger.log("MODEL-FOLDER: Model folder cleared")
  }

  // MARK: - Resolution

  /// Resolves the stored bookmark to a URL, refreshing it if stale, and holds the security scope
  /// open for the rest of the process. Returns nil if no folder is configured or resolution failed.
  static func resolveFolderURL() -> URL? {
    guard let bookmark = UserDefaults.standard.data(forKey: UserDefaultsKeys.extraModelFolderBookmark)
    else { return nil }
    var isStale = false
    do {
      let url = try URL(
        resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil,
        bookmarkDataIsStale: &isStale)
      if isStale {
        let accessed = url.startAccessingSecurityScopedResource()
        if let refreshed = try? url.bookmarkData(
          options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
          UserDefaults.standard.set(refreshed, forKey: UserDefaultsKeys.extraModelFolderBookmark)
        }
        if accessed { url.stopAccessingSecurityScopedResource() }
      }
      retainAccess(to: url)
      return url
    } catch {
      let path = displayPath
      if SecurityScopedBookmark.shouldDiscard(
        error: error as NSError, folderPath: path,
        volumeIsMounted: { FileManager.default.fileExists(atPath: $0) })
      {
        // Corrupt data, or the folder is really gone. Keeping it would make every model lookup
        // fail silently; clearing it lets Settings show the picker again.
        DebugLogger.logError(
          "MODEL-FOLDER: Model folder bookmark is unusable (\(error.localizedDescription)). Clearing it — the user must re-select the folder in Settings.")
        clear()
      } else {
        // An unmounted drive or an offline network share: keep the setting so it works again once
        // the folder is back. Models simply resolve to the app's own folder until then.
        DebugLogger.logWarning(
          "MODEL-FOLDER: Model folder is temporarily unavailable (\(error.localizedDescription)) — keeping the setting")
      }
      return nil
    }
  }

  /// Runs `body` with the folder's security scope open. The lease already holds it; this makes the
  /// read correct even if the lease could not be claimed (an unsandboxed test run, for instance).
  static func withAccess<T>(to folder: URL, _ body: () throws -> T) rethrows -> T {
    let accessed = folder.startAccessingSecurityScopedResource()
    defer { if accessed { folder.stopAccessingSecurityScopedResource() } }
    return try body()
  }

  // MARK: - WhisperKit lookup

  /// Every place a WhisperKit model may sit inside the user's folder, in the order they are tried:
  /// a flat copy first (what a user who dragged a folder over has), then a copied WhisperKit tree,
  /// then a Hugging Face cache layout.
  static func whisperCandidates(in folder: URL, variant: String) -> [URL] {
    let flat = [
      "openai_whisper-\(variant)",
      variant,
      "whisper-\(variant)",
    ].map { folder.appendingPathComponent($0) }
    let whisperKitTree = folder
      .appendingPathComponent("models/argmaxinc/whisperkit-coreml")
      .appendingPathComponent("openai_whisper-\(variant)")
    let huggingFaceCache = folder
      .appendingPathComponent("models/openai")
      .appendingPathComponent("whisper-\(variant)")
    return flat + [whisperKitTree, huggingFaceCache]
  }

  /// The first WhisperKit model folder that exists in the user's folder, or nil.
  ///
  /// Existence only — completeness stays `ModelManager.isModelAvailable`'s job, so a folder that
  /// is there but half-written still reports as not downloaded, exactly as in the app's own folder.
  static func whisperModelURL(for variant: String) -> URL? {
    guard let folder = resolveFolderURL() else { return nil }
    return withAccess(to: folder) {
      whisperCandidates(in: folder, variant: variant).first {
        FileManager.default.fileExists(atPath: $0.path)
      }
    }
  }

  // MARK: - MLX lookup

  /// Every repo root an MLX model may sit under in the user's folder, in the order they are tried:
  /// the repo id as one path component, then the same under `models/`, then the `org/repo` split
  /// (whose `snapshots/<hash>` children are checked by `mlxModelURL`).
  static func mlxRepoCandidates(in folder: URL, huggingFaceID: String) -> [URL] {
    let models = folder.appendingPathComponent("models")
    var candidates = [
      folder.appendingPathComponent(huggingFaceID),
      models.appendingPathComponent(huggingFaceID),
    ]
    let parts = huggingFaceID.split(separator: "/").map(String.init)
    if parts.count == 2 {
      let split = models.appendingPathComponent(parts[0]).appendingPathComponent(parts[1])
      if !candidates.contains(split) { candidates.append(split) }
    }
    return candidates
  }

  /// The first complete MLX repo (or Hub snapshot) in the user's folder, or nil. Completeness is
  /// `MLXModelPaths.hasRequiredFiles`, unchanged — a half-downloaded repo stays unavailable.
  static func mlxModelURL(for huggingFaceID: String) -> URL? {
    guard let folder = resolveFolderURL() else { return nil }
    return withAccess(to: folder) {
      for repo in mlxRepoCandidates(in: folder, huggingFaceID: huggingFaceID) {
        if MLXModelPaths.hasRequiredFiles(at: repo) { return repo }
        let snapshots = repo.appendingPathComponent("snapshots")
        guard let hashes = try? FileManager.default.contentsOfDirectory(atPath: snapshots.path)
        else { continue }
        for hash in hashes.sorted() {
          let snapshot = snapshots.appendingPathComponent(hash)
          if MLXModelPaths.hasRequiredFiles(at: snapshot) { return snapshot }
        }
      }
      return nil
    }
  }

  // MARK: - Process-lifetime scope lease

  private static let leaseLock = NSLock()
  /// The folder whose scope is currently open, so it is claimed once and released once.
  private static var leasedURL: URL?

  private static func retainAccess(to url: URL) {
    leaseLock.lock()
    defer { leaseLock.unlock() }
    if leasedURL?.path == url.path { return }
    if let previous = leasedURL { previous.stopAccessingSecurityScopedResource() }
    let accessed = url.startAccessingSecurityScopedResource()
    leasedURL = accessed ? url : nil
    DebugLogger.log(
      "MODEL-FOLDER: Security scope \(accessed ? "opened" : "not granted") for \(url.path)")
  }

  private static func releaseLease() {
    leaseLock.lock()
    defer { leaseLock.unlock() }
    leasedURL?.stopAccessingSecurityScopedResource()
    leasedURL = nil
  }
}
