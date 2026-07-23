import Foundation

/// Implements the chat's read-only file tools on top of `WorkspaceFolders`.
///
/// Every entry point is synchronous and free of actor isolation on purpose: `ChatToolRegistry`
/// is `@MainActor`, and directory walks over a large tree would otherwise block the main thread
/// and trip the hang watchdog. The registry hops onto a detached task before calling in here.
enum WorkspaceFileTools {
  /// Directories that are almost never what the user means and would otherwise dominate a
  /// search: dependency and build output trees.
  private static let prunedDirectories: Set<String> = [
    ".git", "node_modules", ".build", "build", "DerivedData", "Pods", ".venv", "venv",
    "__pycache__", ".next", "dist", "target", ".gradle", ".idea", ".cache",
  ]

  private static let maxReadBytes = 400_000
  private static let defaultReadBytes = 100_000
  private static let maxSearchVisits = 20_000

  // MARK: - list_workspace_folders

  static func listFolders() -> [String: Any] {
    let roots = WorkspaceFolders.roots()
    guard !roots.isEmpty else {
      return [
        "folders": [] as [Any],
        "count": 0,
        "hint":
          "No folders are shared yet. Tell the user to open Settings → Chat → Workspace Folders and pick a folder before you can read any files.",
      ]
    }
    let folders: [[String: Any]] = roots.map { root in
      ["name": root.url.lastPathComponent, "path": root.displayPath]
    }
    DebugLogger.logSuccess("WORKSPACE-TOOL: listed \(folders.count) workspace folder(s)")
    return ["folders": folders, "count": folders.count]
  }

  // MARK: - list_directory

  static func listDirectory(path: String, maxEntries: Int) -> [String: Any] {
    let limit = min(max(maxEntries, 1), 500)
    do {
      let (target, root) = try WorkspaceFolders.locate(path)
      return try WorkspaceFolders.withAccess(to: root) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory) else {
          return ["error": "No such directory: \(target.path)"]
        }
        guard isDirectory.boolValue else {
          return ["error": "Not a directory: \(target.path). Use read_text_file for files."]
        }

        let contents = try FileManager.default.contentsOfDirectory(
          at: target,
          includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
          options: [.skipsHiddenFiles])

        let sorted = contents.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        let entries: [[String: Any]] = sorted.prefix(limit).map { url in
          let values = try? url.resourceValues(forKeys: [
            .isDirectoryKey, .fileSizeKey, .contentModificationDateKey,
          ])
          var entry: [String: Any] = [
            "name": url.lastPathComponent,
            "type": (values?.isDirectory ?? false) ? "directory" : "file",
          ]
          if let size = values?.fileSize { entry["size_bytes"] = size }
          if let modified = values?.contentModificationDate {
            entry["modified"] = ISO8601DateFormatter().string(from: modified)
          }
          return entry
        }

        DebugLogger.logSuccess(
          "WORKSPACE-TOOL: listed \(entries.count)/\(contents.count) entries in \(target.path)")
        var result: [String: Any] = [
          "path": target.path, "entries": entries, "count": entries.count,
        ]
        if contents.count > entries.count {
          result["truncated"] = true
          result["total_entries"] = contents.count
        }
        return result
      }
    } catch {
      return errorResult(error, context: "list_directory \(path)")
    }
  }

  // MARK: - read_text_file

  static func readTextFile(path: String, maxBytes: Int) -> [String: Any] {
    let cap = min(max(maxBytes, 1_000), maxReadBytes)
    do {
      let (target, root) = try WorkspaceFolders.locate(path)
      return try WorkspaceFolders.withAccess(to: root) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory) else {
          return ["error": "No such file: \(target.path)"]
        }
        guard !isDirectory.boolValue else {
          return ["error": "\(target.path) is a directory. Use list_directory instead."]
        }

        let handle = try FileHandle(forReadingFrom: target)
        defer { try? handle.close() }
        // Read one byte past the cap so we can tell "exactly at the limit" from "truncated".
        let data = try handle.read(upToCount: cap + 1) ?? Data()
        let truncated = data.count > cap
        let payload = truncated ? data.prefix(cap) : data

        guard let text = decodeText(payload) else {
          return [
            "error":
              "\(target.lastPathComponent) is not a UTF-8 text file (binary content). Only text files can be read."
          ]
        }

        let totalBytes =
          (try? FileManager.default.attributesOfItem(atPath: target.path)[.size] as? Int) ?? nil

        DebugLogger.logSuccess(
          "WORKSPACE-TOOL: read \(payload.count) bytes from \(target.path) (truncated=\(truncated))")
        var result: [String: Any] = [
          "path": target.path, "content": text, "bytes_returned": payload.count,
        ]
        if let totalBytes { result["total_bytes"] = totalBytes }
        if truncated {
          result["truncated"] = true
          result["note"] =
            "Only the first \(cap) bytes are shown. Raise max_bytes (up to \(maxReadBytes)) if you need more."
        }
        return result
      }
    } catch {
      return errorResult(error, context: "read_text_file \(path)")
    }
  }

  // MARK: - search_files

  static func searchFiles(query: String, path: String?, searchContent: Bool, maxResults: Int)
    -> [String: Any] {
    let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedQuery.isEmpty else { return ["error": "Missing required argument: query"] }
    let limit = min(max(maxResults, 1), 100)

    let scopes: [(url: URL, root: WorkspaceFolders.Root)]
    do {
      if let path, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        let located = try WorkspaceFolders.locate(path)
        scopes = [(located.target, located.root)]
      } else {
        let roots = WorkspaceFolders.roots()
        guard !roots.isEmpty else { throw WorkspaceFolders.AccessError.noFolders }
        scopes = roots.map { ($0.url, $0) }
      }
    } catch {
      return errorResult(error, context: "search_files \(query)")
    }

    var matches: [[String: Any]] = []
    var visited = 0
    var hitVisitCap = false

    outer: for scope in scopes {
      let scopeResult: Bool = WorkspaceFolders.withAccess(to: scope.root) {
        guard
          let enumerator = FileManager.default.enumerator(
            at: scope.url,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles])
        else { return true }

        while let url = enumerator.nextObject() as? URL {
          if prunedDirectories.contains(url.lastPathComponent) {
            enumerator.skipDescendants()
            continue
          }
          let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
          if values?.isDirectory ?? false { continue }

          visited += 1
          if visited > maxSearchVisits {
            hitVisitCap = true
            return false
          }

          if let match = matchFile(
            url, query: trimmedQuery, searchContent: searchContent,
            fileSize: values?.fileSize ?? 0) {
            matches.append(match)
            if matches.count >= limit { return false }
          }
        }
        return true
      }
      if !scopeResult { break outer }
    }

    DebugLogger.logSuccess(
      "WORKSPACE-TOOL: search '\(trimmedQuery)' matched \(matches.count) file(s) after \(visited) visits")
    var result: [String: Any] = [
      "query": trimmedQuery, "matches": matches, "count": matches.count,
      "files_scanned": visited,
    ]
    if matches.count >= limit {
      result["truncated"] = true
      result["note"] = "Stopped at max_results=\(limit). Narrow the query or pass a path to scope it."
    } else if hitVisitCap {
      result["truncated"] = true
      result["note"] =
        "Stopped after scanning \(maxSearchVisits) files. Pass a path to search a smaller subtree."
    }
    return result
  }

  /// Returns a match entry for `url`, or nil. Filename matching is always applied; content
  /// matching additionally scans the head of text files so the model can find a phrase without
  /// reading every candidate in full.
  private static func matchFile(_ url: URL, query: String, searchContent: Bool, fileSize: Int)
    -> [String: Any]? {
    if url.lastPathComponent.localizedCaseInsensitiveContains(query) {
      return ["path": url.path, "name": url.lastPathComponent, "matched": "name"]
    }
    guard searchContent, fileSize > 0, fileSize <= defaultReadBytes else { return nil }
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    guard let data = try? handle.read(upToCount: defaultReadBytes),
      let text = decodeText(data),
      let range = text.range(of: query, options: .caseInsensitive)
    else { return nil }

    let line = text[text.startIndex..<range.lowerBound].split(
      separator: "\n", omittingEmptySubsequences: false
    ).count
    let snippetLine = text[range.lowerBound...].split(separator: "\n").first.map(String.init) ?? ""
    return [
      "path": url.path, "name": url.lastPathComponent, "matched": "content",
      "line": line, "snippet": String(snippetLine.prefix(200)),
    ]
  }

  // MARK: - Helpers

  /// Decodes text, falling back to Latin-1 for files that are readable but not valid UTF-8.
  /// A NUL byte in the payload means binary, and no encoding fallback should rescue it.
  private static func decodeText(_ data: Data) -> String? {
    guard !data.contains(0) else { return nil }
    if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
    return String(data: data, encoding: .isoLatin1)
  }

  private static func errorResult(_ error: Error, context: String) -> [String: Any] {
    let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    DebugLogger.logError("WORKSPACE-TOOL: \(context) failed: \(message)")
    return ["error": message]
  }
}
