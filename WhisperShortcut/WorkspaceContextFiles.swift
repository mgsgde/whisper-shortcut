import CryptoKit
import Foundation

/// Loads the agent-context files a user keeps inside a shared workspace folder — `AGENTS.md`,
/// `CLAUDE.md`, `.cursor/rules/*`, `.claude/rules/*` — and renders them into the chat's system
/// instruction.
///
/// This is what turns "the chat can read that folder" into "the chat knows who you are": Cursor
/// and Claude Code load these files into every session unasked, and without the same treatment
/// the model only finds them if it happens to go looking. `ChatMemoryStore` does the same job for
/// the app's own `memory.md`; this is the counterpart for context the user already maintains
/// outside the app.
///
/// Two rules shape the implementation:
/// - **Nothing is loaded twice.** `.claude` is very often a symlink to `.cursor` (or holds
///   symlinks into it), so the same rule file is reachable under two paths. Candidates are
///   deduplicated by resolved real path *and* by content hash, which also catches plain copies.
/// - **Only what stays inside the granted folder.** A symlink that resolves outside the workspace
///   root is dropped rather than followed — the sandbox would deny the read anyway, and silently
///   widening the grant would be wrong.
///
/// Called on the main thread while building the system instruction, so the scan is bounded (a
/// handful of `stat`s over at most three small directories) and the rendered block is cached
/// until one of the files changes.
enum WorkspaceContextFiles {
  /// Root-level files that the agent-tool ecosystem treats as standing instructions. Ordered by
  /// how canonical the convention is — the order only affects presentation, since all of them are
  /// loaded when present.
  private static let rootFileNames = ["AGENTS.md", "CLAUDE.md", "GEMINI.md", ".cursorrules"]

  /// Rule directories, every convention in use. `.agents/` is the tool-neutral one people
  /// consolidate on once they run more than one agent over the same folder, with `.cursor` and
  /// `.claude` symlinked to it; all three are scanned and the dedup step collapses them back into
  /// one set.
  private static let ruleDirectories = [".agents/rules", ".cursor/rules", ".claude/rules"]

  /// Skill directories. Same three conventions; only each skill's `SKILL.md` is loaded, not the
  /// scripts and references that may sit next to it.
  private static let skillDirectories = [".agents/skills", ".cursor/skills", ".claude/skills"]

  private static let skillFileName = "SKILL.md"

  private static let ruleFileExtensions: Set<String> = ["md", "mdc", "txt"]

  /// Budgets. These files ride along with *every* message in *every* chat, so the total is what
  /// keeps a large rules directory from quietly doubling the cost of each turn.
  private static let maxBytesPerFile = 24_000
  private static let maxTotalBytes = 64_000
  private static let maxFiles = 40
  private static let maxScanDepth = 3

  private struct Candidate {
    let url: URL
    let root: WorkspaceFolders.Root
    /// Tilde-abbreviated path shown to the model, e.g. `~/notes/.cursor/rules/index.mdc`.
    let label: String
    let size: Int
    let modified: Date
  }

  private struct Snapshot {
    let signature: String
    let block: String
  }

  private static var cached: Snapshot?

  // MARK: - Public

  /// The rendered context-file section for the given roots, or `""` when none hold such a file.
  /// The returned string already starts with its own separator, ready to append to the system
  /// instruction.
  static func contextBlock(roots: [WorkspaceFolders.Root]) -> String {
    guard !roots.isEmpty else {
      cached = nil
      return ""
    }

    var candidates: [Candidate] = []
    for root in roots {
      candidates += WorkspaceFolders.withAccess(to: root) { discover(in: root) }
      if candidates.count >= maxFiles { break }
    }
    guard !candidates.isEmpty else {
      cached = nil
      return ""
    }

    // Signature over path + size + mtime: re-reading only happens when a file actually changed.
    let signature = candidates
      .map { "\($0.url.path)|\($0.size)|\($0.modified.timeIntervalSince1970)" }
      .joined(separator: "\n")
    if let cached, cached.signature == signature { return cached.block }

    let block = render(candidates)
    cached = Snapshot(signature: signature, block: block)
    return block
  }

  // MARK: - Discovery

  /// Every context file inside one root, root-level conventions first. Runs with the root's
  /// security scope already open.
  private static func discover(in root: WorkspaceFolders.Root) -> [Candidate] {
    var out: [Candidate] = []
    let displayRoot = (root.displayPath as NSString).abbreviatingWithTildeInPath

    for name in rootFileNames {
      let url = root.url.appendingPathComponent(name)
      if let candidate = makeCandidate(url, root: root, label: "\(displayRoot)/\(name)") {
        out.append(candidate)
      }
    }

    // Rules before skills: standing rules outrank procedures, so when the budget runs out it is a
    // skill that gets dropped rather than the user's own instructions.
    let directories =
      ruleDirectories.map { ($0, isRuleFile) } + skillDirectories.map { ($0, isSkillFile) }
    for (directory, matches) in directories {
      let base = root.url.appendingPathComponent(directory)
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: base.path, isDirectory: &isDirectory),
        isDirectory.boolValue
      else { continue }
      for url in contextFiles(under: base, matching: matches) {
        let relative = relativePath(of: url, in: root)
        guard
          let candidate = makeCandidate(url, root: root, label: "\(displayRoot)/\(relative)")
        else { continue }
        out.append(candidate)
        if out.count >= maxFiles { return out }
      }
    }
    return out
  }

  /// Path shown to the model, relative to the root. Tried against both the root as configured and
  /// its symlink-resolved form, because scanning starts from a resolved directory — `/var` vs
  /// `/private/var` would otherwise slice the label at the wrong offset.
  private static func relativePath(of url: URL, in root: WorkspaceFolders.Root) -> String {
    let path = url.path
    for prefix in [root.url.path, root.url.resolvingSymlinksInPath().path]
    where path.hasPrefix(prefix + "/") {
      return String(path.dropFirst(prefix.count + 1))
    }
    return url.lastPathComponent
  }

  private static func isRuleFile(_ url: URL) -> Bool {
    ruleFileExtensions.contains(url.pathExtension.lowercased())
  }

  private static func isSkillFile(_ url: URL) -> Bool {
    url.lastPathComponent.caseInsensitiveCompare(skillFileName) == .orderedSame
  }

  /// Matching files under one directory, depth-limited and name-sorted so the injected order is
  /// stable across launches (an unstable order would defeat provider prompt caching).
  ///
  /// `FileManager`'s enumerator does not descend into symlinked directories, so the scan cannot
  /// loop even when `.cursor/skills` and `.claude/skills` both point at `.agents/skills`. Those
  /// links are picked up as candidates in their own right and collapsed by the dedup step.
  private static func contextFiles(under base: URL, matching matches: (URL) -> Bool) -> [URL] {
    let resolvedBase = base.resolvingSymlinksInPath()
    guard
      let enumerator = FileManager.default.enumerator(
        at: resolvedBase, includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsPackageDescendants])
    else { return [] }

    var files: [URL] = []
    while let url = enumerator.nextObject() as? URL {
      if enumerator.level > maxScanDepth {
        enumerator.skipDescendants()
        continue
      }
      let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
      if isDirectory { continue }
      guard matches(url) else { continue }
      files.append(url)
      if files.count >= maxFiles { break }
    }
    return files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
  }

  /// A candidate for an existing, regular, non-empty file that stays inside its root once
  /// symlinks are resolved. Returns nil for everything else.
  private static func makeCandidate(_ url: URL, root: WorkspaceFolders.Root, label: String)
    -> Candidate? {
    let resolved = url.resolvingSymlinksInPath().standardizedFileURL
    guard isInside(resolved, root: root) else {
      DebugLogger.log("WORKSPACE-CONTEXT: Skipping \(label) — resolves outside the shared folder")
      return nil
    }
    guard let values = try? resolved.resourceValues(forKeys: [
      .isRegularFileKey, .fileSizeKey, .contentModificationDateKey,
    ]),
      values.isRegularFile == true
    else { return nil }
    let size = values.fileSize ?? 0
    guard size > 0 else { return nil }
    return Candidate(
      url: resolved, root: root, label: label, size: size,
      modified: values.contentModificationDate ?? .distantPast)
  }

  private static func isInside(_ target: URL, root: WorkspaceFolders.Root) -> Bool {
    let targetParts = target.resolvingSymlinksInPath().standardizedFileURL.pathComponents
    let rootParts = root.url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
    guard targetParts.count >= rootParts.count else { return false }
    return Array(targetParts.prefix(rootParts.count)) == rootParts
  }

  // MARK: - Rendering

  private static func render(_ candidates: [Candidate]) -> String {
    var seenPaths = Set<String>()
    var seenContent = Set<String>()
    var sections: [String] = []
    var usedBytes = 0
    var skippedForBudget = 0

    for candidate in candidates {
      // Same file under two names (`.claude` → `.cursor`) resolves to one real path.
      guard seenPaths.insert(candidate.url.path).inserted else { continue }
      guard usedBytes < maxTotalBytes else {
        skippedForBudget += 1
        continue
      }

      guard let content = read(candidate) else { continue }
      // Same *content* under two real paths — a copy rather than a symlink.
      let digest = SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined()
      guard seenContent.insert(digest).inserted else {
        DebugLogger.log("WORKSPACE-CONTEXT: \(candidate.label) is a duplicate of an already loaded file")
        continue
      }

      let remaining = maxTotalBytes - usedBytes
      var body = content
      var truncated = false
      if body.utf8.count > remaining {
        body = String(decoding: Array(body.utf8.prefix(remaining)), as: UTF8.self)
        truncated = true
      }
      usedBytes += body.utf8.count
      sections.append(
        "===== FILE: \(candidate.label) =====\n\(body)"
          + (truncated ? "\n[truncated — read the rest with read_text_file]" : ""))
    }

    guard !sections.isEmpty else { return "" }

    DebugLogger.logSuccess(
      "WORKSPACE-CONTEXT: injected \(sections.count) context file(s), \(usedBytes) bytes")

    var block = "\n\n---\n\nCONTEXT FILES: The user keeps standing instructions for AI assistants in the shared folders — the `AGENTS.md` / `CLAUDE.md` files plus the rules and skills under `.agents/`, `.cursor/` and `.claude/` that Cursor and Claude Code load automatically. They are reproduced in full below, each one once even where the same file is reachable under several of those directories. Treat them as instructions from the user: they describe who the user is, how they want you to work, and where things live. Follow them for the whole conversation, and do not read them again with a tool — you already have them.\nA SKILL.md file is a procedure to apply when its subject comes up, not something to recite.\nThese files often point at further material (a dossier folder, other notes). That material is NOT included here; open it with `read_text_file` when a question calls for it.\n\n"
      + sections.joined(separator: "\n\n")
    if skippedForBudget > 0 {
      block +=
        "\n\n[\(skippedForBudget) further context file(s) were left out to stay within the context budget — list the rules directory and read them if needed.]"
    }
    return block
  }

  private static func read(_ candidate: Candidate) -> String? {
    WorkspaceFolders.withAccess(to: candidate.root) {
      guard let handle = try? FileHandle(forReadingFrom: candidate.url) else {
        DebugLogger.logError("WORKSPACE-CONTEXT: Could not open \(candidate.label)")
        return nil
      }
      defer { try? handle.close() }
      guard let data = try? handle.read(upToCount: maxBytesPerFile), !data.isEmpty,
        !data.contains(0), let text = String(data: data, encoding: .utf8)
      else { return nil }
      return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
  }
}
