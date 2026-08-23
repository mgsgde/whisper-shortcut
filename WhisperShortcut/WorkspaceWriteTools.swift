import Foundation

/// The write half of the chat's workspace file tools.
///
/// Deliberately separate from `WorkspaceFileTools`: reading a shared folder is recoverable and
/// writing to it is not, so the two have different gates (`WorkspaceWriteAccess`), different
/// safety rules, and no shared entry point that could accidentally grant one while checking the
/// other.
///
/// What is *not* here is as deliberate as what is: there is no delete and no move tool. A model
/// that misreads an instruction can rewrite a paragraph — the user still has the file, the backup,
/// and usually git. A model that deletes the wrong file leaves nothing to notice.
///
/// Three rules apply to every write:
/// - **Inside a shared folder, always.** Paths go through `WorkspaceFolders.locate`, which rejects
///   anything outside the roots this chat may use, including `..` and symlink escapes.
/// - **Never into machinery.** `.git`, `node_modules`, credential directories and the rest of the
///   pruned set are refused: those are not the user's notes, and a write there breaks tools the
///   user relies on.
/// - **Nothing is lost silently.** Overwriting or editing an existing file first copies the old
///   content into the app's backup directory.
enum WorkspaceWriteTools {
  /// Cap on a single write. Large enough for any note, small enough that a runaway generation
  /// cannot fill a disk.
  private static let maxWriteBytes = 1_000_000

  /// How long superseded content is kept before `pruneBackups` drops it.
  private static let backupRetentionDays = 30

  // MARK: - write_text_file

  static func writeTextFile(
    path: String, content: String, overwrite: Bool, scope: WorkspaceFolders.Scope = .all
  ) -> [String: Any] {
    guard content.utf8.count <= maxWriteBytes else {
      return ["error": "Content is \(content.utf8.count) bytes; the limit for one write is \(maxWriteBytes)."]
    }
    do {
      let (target, root) = try locateForWriting(path, scope: scope)
      return WorkspaceFolders.withAccess(to: root) {
        let exists = FileManager.default.fileExists(atPath: target.path)
        if exists && !overwrite {
          return [
            "error":
              "\(target.lastPathComponent) already exists. Call again with overwrite=true to replace it, or use edit_text_file to change part of it."
          ]
        }
        var backup: String?
        if exists {
          backup = backUp(target)
          guard backup != nil else {
            return ["error": "Could not back up \(target.lastPathComponent); nothing was written."]
          }
        }
        do {
          try writeUTF8(content, to: target)
        } catch {
          return ["error": "Write failed: \(error.localizedDescription)"]
        }
        DebugLogger.logSuccess(
          "WORKSPACE-WRITE: wrote \(content.utf8.count) bytes to \(target.path) (replaced=\(exists))")
        var result: [String: Any] = [
          "ok": true, "path": target.path, "bytes_written": content.utf8.count,
          "created": !exists,
        ]
        if let backup { result["previous_version_backed_up_to"] = backup }
        return result
      }
    } catch {
      return errorResult(error, context: "write_text_file \(path)")
    }
  }

  // MARK: - append_to_file

  static func appendToFile(path: String, content: String, scope: WorkspaceFolders.Scope = .all)
    -> [String: Any] {
    guard content.utf8.count <= maxWriteBytes else {
      return ["error": "Content is \(content.utf8.count) bytes; the limit for one write is \(maxWriteBytes)."]
    }
    do {
      let (target, root) = try locateForWriting(path, scope: scope)
      return WorkspaceFolders.withAccess(to: root) {
        // Appending is additive, so it needs no backup: nothing that was there is gone.
        guard let existing = readExisting(target) else {
          return ["error": "\(target.lastPathComponent) exists but is not UTF-8 text."]
        }
        let separator = existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n"
        let combined = existing + separator + content
        guard combined.utf8.count <= maxWriteBytes else {
          return [
            "error":
              "Appending would make the file \(combined.utf8.count) bytes; the limit is \(maxWriteBytes)."
          ]
        }
        do {
          try writeUTF8(combined, to: target)
        } catch {
          return ["error": "Append failed: \(error.localizedDescription)"]
        }
        DebugLogger.logSuccess(
          "WORKSPACE-WRITE: appended \(content.utf8.count) bytes to \(target.path)")
        return [
          "ok": true, "path": target.path, "bytes_appended": content.utf8.count,
          "total_bytes": combined.utf8.count,
        ]
      }
    } catch {
      return errorResult(error, context: "append_to_file \(path)")
    }
  }

  // MARK: - edit_text_file

  /// Exact-string replacement, the same contract coding agents use: the text to replace must
  /// appear, and must appear exactly once unless `replaceAll` is set. Ambiguity is an error rather
  /// than a guess, because "the model edited the wrong one of three identical lines" is the
  /// failure mode that costs the user a paragraph without telling them.
  static func editTextFile(
    path: String, find: String, replace: String, replaceAll: Bool,
    scope: WorkspaceFolders.Scope = .all
  ) -> [String: Any] {
    guard !find.isEmpty else { return ["error": "`find` must not be empty."] }
    do {
      let (target, root) = try locateForWriting(path, scope: scope)
      return WorkspaceFolders.withAccess(to: root) {
        guard FileManager.default.fileExists(atPath: target.path) else {
          return ["error": "No such file: \(target.path). Use write_text_file to create it."]
        }
        guard let original = readExisting(target) else {
          return ["error": "\(target.lastPathComponent) is not a UTF-8 text file."]
        }
        let occurrences = original.components(separatedBy: find).count - 1
        guard occurrences > 0 else {
          return [
            "error":
              "That exact text does not appear in \(target.lastPathComponent). Read the file again and match it character for character, including indentation."
          ]
        }
        guard occurrences == 1 || replaceAll else {
          return [
            "error":
              "That text appears \(occurrences) times in \(target.lastPathComponent). Include enough surrounding text to make it unique, or pass replace_all=true."
          ]
        }
        guard let backup = backUp(target) else {
          return ["error": "Could not back up \(target.lastPathComponent); nothing was changed."]
        }
        let updated = original.replacingOccurrences(of: find, with: replace)
        guard updated.utf8.count <= maxWriteBytes else {
          return [
            "error":
              "The edited file would be \(updated.utf8.count) bytes; the limit is \(maxWriteBytes)."
          ]
        }
        do {
          try writeUTF8(updated, to: target)
        } catch {
          return ["error": "Edit failed: \(error.localizedDescription)"]
        }
        DebugLogger.logSuccess(
          "WORKSPACE-WRITE: edited \(target.path) (\(occurrences) replacement(s))")
        return [
          "ok": true, "path": target.path, "replacements": occurrences,
          "total_bytes": updated.utf8.count,
          "previous_version_backed_up_to": backup,
        ]
      }
    } catch {
      return errorResult(error, context: "edit_text_file \(path)")
    }
  }

  // MARK: - Backups

  /// Where superseded content goes. Inside the app container, not the user's folder: a backup file
  /// dropped next to a note would show up in the user's own searches and syncs.
  static var backupDirectory: URL {
    AppSupportPaths.whisperShortcutApplicationSupportURL()
      .appendingPathComponent("WorkspaceBackups", isDirectory: true)
  }

  /// Copies the current content aside, returning the backup path. A write proceeds only if this
  /// succeeded, so there is always a way back from an edit the user did not want.
  private static func backUp(_ target: URL) -> String? {
    let stamp = ISO8601DateFormatter.backupStamp.string(from: Date())
    // The timestamp is only second-precise, and a batch of edits easily produces two backups of
    // same-named files inside one second. A random suffix keeps them from colliding — losing the
    // older backup to the newer one would defeat the point of taking it.
    let unique = UUID().uuidString.prefix(8)
    let directory = backupDirectory
    let destination = directory.appendingPathComponent(
      "\(stamp)-\(unique)-\(target.lastPathComponent)")
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try FileManager.default.copyItem(at: target, to: destination)
      pruneBackups()
      return destination.path
    } catch {
      DebugLogger.logError("WORKSPACE-WRITE: Backup of \(target.path) failed: \(error.localizedDescription)")
      return nil
    }
  }

  /// Drops backups older than the retention window. Cheap enough to run on every backup, and it
  /// keeps the directory from growing without bound for a heavy user.
  private static func pruneBackups() {
    let cutoff = Date().addingTimeInterval(-Double(backupRetentionDays) * 86_400)
    guard
      let entries = try? FileManager.default.contentsOfDirectory(
        at: backupDirectory, includingPropertiesForKeys: [.contentModificationDateKey])
    else { return }
    for entry in entries {
      let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
        .contentModificationDate
      if let modified, modified < cutoff {
        try? FileManager.default.removeItem(at: entry)
      }
    }
  }

  // MARK: - Helpers

  /// Resolves a model-supplied path for writing: inside a shared folder this chat may use, and not
  /// inside a directory that exists for tooling rather than for the user. Also re-checks the write
  /// toggle so a hallucinated tool name or mid-turn disable cannot bypass declaration gating.
  private static func locateForWriting(_ path: String, scope: WorkspaceFolders.Scope) throws
    -> (target: URL, root: WorkspaceFolders.Root) {
    guard WorkspaceWriteAccess.isEnabled else {
      throw WriteError.writeAccessDisabled
    }
    let located = try WorkspaceFolders.locate(path, scope: scope)
    let rootComponentCount = located.root.url.standardizedFileURL.pathComponents.count
    let inside = located.target.standardizedFileURL.pathComponents.dropFirst(rootComponentCount)
    for (index, component) in inside.enumerated() {
      // The last component is the file being written; everything before it is a directory.
      let isDirectory = index < inside.count - 1
      if WorkspaceFileTools.isPruned(name: component, isDirectory: isDirectory) {
        throw WriteError.protectedLocation(component: component)
      }
    }
    return located
  }

  private static func writeUTF8(_ content: String, to target: URL) throws {
    try FileManager.default.createDirectory(
      at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    try content.write(to: target, atomically: true, encoding: .utf8)
  }

  private static func readExisting(_ url: URL) -> String? {
    guard FileManager.default.fileExists(atPath: url.path) else { return "" }
    guard let data = try? Data(contentsOf: url), !data.contains(0) else { return nil }
    return String(data: data, encoding: .utf8)
  }

  enum WriteError: Error, LocalizedError {
    case protectedLocation(component: String)
    case writeAccessDisabled

    var errorDescription: String? {
      switch self {
      case .protectedLocation(let component):
        return
          "`\(component)` is managed by tooling (version control, dependencies, or credentials) and cannot be written to. Write to the user's own files instead."
      case .writeAccessDisabled:
        return
          "File editing is off. Turn it on in Settings → Chat → Workspace Folders."
      }
    }
  }

  private static func errorResult(_ error: Error, context: String) -> [String: Any] {
    let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    DebugLogger.logError("WORKSPACE-WRITE: \(context) failed: \(message)")
    return ["error": message]
  }
}

extension ISO8601DateFormatter {
  /// Filename-safe timestamp for backup names — colons are legal on APFS but confuse everything
  /// that later has to type the path.
  fileprivate static let backupStamp: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withYear, .withMonth, .withDay, .withTime]
    formatter.timeZone = .current
    return formatter
  }()
}

/// Whether the chat may write to the shared folders at all.
///
/// Off by default: a folder shared before this existed was shared for reading, and gaining write
/// access without the user saying so would be a change they never agreed to. The tools are not
/// declared to the model while this is off, so it cannot try and fail — it simply has no way to
/// write.
enum WorkspaceWriteAccess {
  static var isEnabled: Bool {
    get { UserDefaults.standard.bool(forKey: UserDefaultsKeys.chatWorkspaceWriteEnabled) }
    set {
      UserDefaults.standard.set(newValue, forKey: UserDefaultsKeys.chatWorkspaceWriteEnabled)
      DebugLogger.log("WORKSPACE-WRITE: access \(newValue ? "enabled" : "disabled")")
    }
  }
}
