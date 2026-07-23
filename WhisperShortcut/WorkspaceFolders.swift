import AppKit
import Foundation

/// Owns the user-selected "workspace" folders the chat is allowed to read from.
///
/// The app is sandboxed in *both* the Direct and App Store builds, so reading anything
/// outside the container requires a security-scoped bookmark obtained from a folder
/// picker. This type is the single place that creates, resolves and validates those
/// bookmarks, and the single gatekeeper deciding whether a model-supplied path is inside
/// one of them. `ScreenshotSaveLocation` does the same for its one *write* folder; this is
/// the multi-folder, read-only counterpart.
enum WorkspaceFolders {
  /// One configured root: the resolved URL plus the path shown in Settings. The two differ
  /// once a bookmark is resolved through a symlink or a moved folder, so keep both — the
  /// URL for I/O, the display path for the UI and for removing the entry again.
  struct Root {
    let url: URL
    let displayPath: String
  }

  enum AccessError: Error, LocalizedError {
    case noFolders
    case outsideWorkspace(path: String, roots: [String])

    var errorDescription: String? {
      switch self {
      case .noFolders:
        return
          "No workspace folders are configured. Open Settings → Chat → Workspace Folders and choose a folder to grant access."
      case .outsideWorkspace(let path, let roots):
        let list = roots.isEmpty ? "(none)" : roots.joined(separator: ", ")
        return
          "Path '\(path)' is outside the configured workspace folders. Accessible folders: \(list). Ask the user to add the folder in Settings → Chat → Workspace Folders."
      }
    }
  }

  private static let bookmarkKey = "bookmark"
  private static let pathKey = "path"

  static var hasFolders: Bool { !storedEntries.isEmpty }

  /// Paths as originally picked — cheap to read (no bookmark resolution) and therefore safe
  /// to call from SwiftUI body evaluation.
  static var displayPaths: [String] {
    storedEntries.compactMap { $0[pathKey] as? String }
  }

  // MARK: - Configuration

  /// Stores a security-scoped bookmark for a folder the user granted access to — via the
  /// Settings picker, `/folder`, or a drop onto the chat window.
  /// Re-adding an existing folder replaces its bookmark rather than duplicating the entry.
  ///
  /// The scope is opened around `bookmarkData`: a folder arriving from a drag-and-drop carries
  /// its sandbox extension on the URL itself, and creating the bookmark without claiming it
  /// first fails. Panel URLs are unaffected — the extra claim is a no-op there.
  @discardableResult
  static func addFolder(_ url: URL) -> Bool {
    let accessed = url.startAccessingSecurityScopedResource()
    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
    do {
      let bookmark = try url.bookmarkData(
        options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
      var entries = storedEntries.filter { ($0[pathKey] as? String) != url.path }
      entries.append([bookmarkKey: bookmark, pathKey: url.path])
      storedEntries = entries
      DebugLogger.log("WORKSPACE: Added folder \(url.path)")
      return true
    } catch {
      DebugLogger.logError(
        "WORKSPACE: Failed to bookmark folder \(url.path): \(error.localizedDescription)")
      return false
    }
  }

  static func removeFolder(displayPath: String) {
    storedEntries = storedEntries.filter { ($0[pathKey] as? String) != displayPath }
    // The map's notes about this folder describe files the chat can no longer reach; keeping them
    // would send the model after paths that now fail.
    WorkspaceMapStore.shared.forgetEntriesUnder(folderPath: displayPath)
    DebugLogger.log("WORKSPACE: Removed folder \(displayPath)")
  }

  // MARK: - Resolution

  /// Resolves every stored bookmark, refreshing stale ones and dropping dead ones.
  ///
  /// A bookmark that no longer resolves (folder deleted, or invalidated by a signing change)
  /// would fail on every single tool call, so it is removed here — exactly as
  /// `ScreenshotSaveLocation` does — and Settings then shows the folder as gone instead of
  /// every read returning the same opaque error.
  static func roots() -> [Root] {
    let entries = storedEntries
    var survivors: [[String: Any]] = []
    var resolved: [Root] = []

    for entry in entries {
      guard let bookmark = entry[bookmarkKey] as? Data,
        let path = entry[pathKey] as? String
      else { continue }

      var isStale = false
      guard
        let url = try? URL(
          resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil,
          bookmarkDataIsStale: &isStale)
      else {
        DebugLogger.logError("WORKSPACE: Dropping folder whose bookmark no longer resolves: \(path)")
        continue
      }

      var survivor = entry
      if isStale {
        let accessed = url.startAccessingSecurityScopedResource()
        if let refreshed = try? url.bookmarkData(
          options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
          survivor[bookmarkKey] = refreshed
        }
        if accessed { url.stopAccessingSecurityScopedResource() }
      }

      survivors.append(survivor)
      resolved.append(Root(url: url, displayPath: path))
    }

    if survivors.count != entries.count { storedEntries = survivors }
    return resolved
  }

  /// Maps a model-supplied path onto a configured root.
  ///
  /// Accepts absolute paths, `~`-relative paths, and paths relative to a root (either bare,
  /// or prefixed with the root's folder name so the model can address multiple roots
  /// unambiguously). Anything that lands outside every root is rejected — including escapes
  /// via `..` or via a symlink pointing out of the workspace, which is why both sides are
  /// symlink-resolved before being compared.
  static func locate(_ rawPath: String) throws -> (target: URL, root: Root) {
    let roots = roots()
    guard !roots.isEmpty else { throw AccessError.noFolders }

    let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
    for candidate in candidateURLs(for: trimmed, roots: roots) {
      if let root = roots.first(where: { contains(candidate, in: $0.url) }) {
        return (candidate.standardizedFileURL, root)
      }
    }
    throw AccessError.outsideWorkspace(path: rawPath, roots: roots.map { $0.displayPath })
  }

  /// Runs `body` with the root's security scope open. Every read must go through this: without
  /// an open scope the sandbox denies the `open(2)` even though the bookmark itself is valid.
  static func withAccess<T>(to root: Root, _ body: () throws -> T) rethrows -> T {
    let accessed = root.url.startAccessingSecurityScopedResource()
    defer { if accessed { root.url.stopAccessingSecurityScopedResource() } }
    return try body()
  }

  // MARK: - Private

  /// Every reading of a model-supplied path, most specific first. `locate` takes the first one
  /// that lands inside a root, so an absolute path always wins over a relative interpretation.
  private static func candidateURLs(for path: String, roots: [Root]) -> [URL] {
    guard !path.isEmpty else { return roots.map { $0.url } }

    let expanded = (path as NSString).expandingTildeInPath
    if expanded.hasPrefix("/") {
      return [URL(fileURLWithPath: expanded)]
    }

    var candidates: [URL] = []
    let components = expanded.split(separator: "/").map(String.init)
    for root in roots {
      // "MyProject/src/main.swift" where MyProject is the root's own folder name.
      if let first = components.first, first == root.url.lastPathComponent {
        let rest = components.dropFirst().joined(separator: "/")
        candidates.append(
          rest.isEmpty ? root.url : root.url.appendingPathComponent(rest))
      }
      // "src/main.swift" — plain relative to each root.
      candidates.append(root.url.appendingPathComponent(expanded))
    }
    return candidates
  }

  private static func contains(_ target: URL, in root: URL) -> Bool {
    let targetParts = target.standardizedFileURL.resolvingSymlinksInPath().pathComponents
    let rootParts = root.standardizedFileURL.resolvingSymlinksInPath().pathComponents
    guard targetParts.count >= rootParts.count else { return false }
    return Array(targetParts.prefix(rootParts.count)) == rootParts
  }

  private static var storedEntries: [[String: Any]] {
    get {
      UserDefaults.standard.array(forKey: UserDefaultsKeys.workspaceFolders) as? [[String: Any]]
        ?? []
    }
    set { UserDefaults.standard.set(newValue, forKey: UserDefaultsKeys.workspaceFolders) }
  }
}
