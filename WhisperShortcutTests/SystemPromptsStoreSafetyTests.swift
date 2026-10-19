import Testing
import Foundation
@testable import WhisperShortcut_AppStore

/// Guards the "a custom system prompt never vanishes silently" contract of `SystemPromptsStore`:
/// an existing file is never replaced by defaults, a write that changes a customized section keeps
/// the previous file as `.bak`, and an unreadable file (what macOS App Data protection produces —
/// simulated here with POSIX permissions) is left untouched while the store reports why.
@Suite("System prompts store safety", .serialized)
struct SystemPromptsStoreSafetyTests {

  private let customPrompt = """
    Gliedere das Diktat in Anamnese, Befund und Therapie.
    Gesprochenes "Doppelpunkt" wird zu ":".
    """

  private func makeDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("SystemPromptsStoreSafetyTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  private func fileContent(sections: [SystemPromptSection: String]) -> String {
    SystemPromptSection.allCases.map { section in
      section.fileHeader + "\n\n" + (sections[section] ?? SystemPromptDefaultsHistory.currentDefault(for: section))
    }.joined(separator: "\n\n")
  }

  private func read(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

  @Test("A missing file is created with the defaults")
  func missingFileIsCreated() throws {
    let dir = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = SystemPromptsStore(contextDirectoryURL: dir)
    #expect(store.loadSection(.chat) == AppConstants.defaultChatSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines))
    #expect(FileManager.default.fileExists(atPath: store.systemPromptsFileURL.path))
    #expect(store.unreadableReason == nil)
  }

  @Test("An existing custom file is read as is, never replaced by defaults")
  func existingCustomFileSurvives() throws {
    let dir = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = SystemPromptsStore(contextDirectoryURL: dir)
    let original = fileContent(sections: [.promptMode: customPrompt])
    try original.write(to: store.systemPromptsFileURL, atomically: true, encoding: .utf8)

    #expect(store.loadSection(.promptMode) == customPrompt)
    #expect(store.loadDictatePromptSystemPrompt() == customPrompt)
    #expect(read(store.systemPromptsFileURL)?.contains(customPrompt) == true)
    #expect(!FileManager.default.fileExists(atPath: store.backupFileURL.path), "reading must not write a backup")
  }

  @Test("Changing a customized section keeps the previous file as .bak")
  func customizedChangeWritesBackup() throws {
    let dir = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = SystemPromptsStore(contextDirectoryURL: dir)
    let original = fileContent(sections: [.promptMode: customPrompt])
    try original.write(to: store.systemPromptsFileURL, atomically: true, encoding: .utf8)

    #expect(store.updateSection(.promptMode, content: AppConstants.defaultPromptModeSystemPrompt))
    #expect(read(store.backupFileURL)?.contains(customPrompt) == true, "the custom prompt must survive in the backup")
    #expect(store.loadSection(.promptMode) == AppConstants.defaultPromptModeSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  @Test("Customizing a section that still holds the default writes no backup")
  func defaultChangeWritesNoBackup() throws {
    let dir = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = SystemPromptsStore(contextDirectoryURL: dir)
    _ = store.loadSection(.promptMode)  // creates the default file

    #expect(store.updateSection(.promptMode, content: customPrompt))
    #expect(!FileManager.default.fileExists(atPath: store.backupFileURL.path))
    #expect(store.loadSection(.promptMode) == customPrompt)
  }

  @Test("A file that exists but cannot be read is reported, not overwritten")
  func unreadableFileIsLeftAlone() throws {
    let dir = try makeDirectory()
    let store = SystemPromptsStore(contextDirectoryURL: dir)
    let url = store.systemPromptsFileURL
    let original = fileContent(sections: [.promptMode: customPrompt])
    try original.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
      try? FileManager.default.removeItem(at: dir)
    }

    #expect(store.loadSection(.promptMode) == nil)
    #expect(store.unreadableReason?.contains("EACCES") == true, "got \(store.unreadableReason ?? "nil")")
    #expect(store.loadDictatePromptSystemPrompt() == AppConstants.defaultPromptModeSystemPrompt, "runtime falls back for now")
    #expect(!store.updateSection(.promptMode, content: "something else"), "writes are refused")
    #expect(!store.saveFullContent("=== Dictate Prompt ===\n\nsomething else"))

    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
    #expect(read(url) == original, "the file must be byte-for-byte unchanged")
    #expect(store.loadSection(.promptMode) == customPrompt)
    #expect(store.unreadableReason == nil, "readable again clears the error")
  }

  @Test("A directory that cannot be entered (the App Data case) is unreadable, not missing")
  func unenterableDirectoryIsNotMissing() throws {
    let dir = try makeDirectory()
    let store = SystemPromptsStore(contextDirectoryURL: dir)
    let original = fileContent(sections: [.promptMode: customPrompt])
    try original.write(to: store.systemPromptsFileURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: dir.path)
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
      try? FileManager.default.removeItem(at: dir)
    }

    // `fileExists` says false here — which is exactly how the old code concluded "missing" and migrated.
    #expect(!FileManager.default.fileExists(atPath: store.systemPromptsFileURL.path))
    #expect(store.readFile() != .missing)
    #expect(store.loadSection(.promptMode) == nil)
    #expect(store.unreadableReason != nil)

    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
    #expect(read(store.systemPromptsFileURL) == original)
  }

  @Test("The startup summary describes sections without their content")
  func describeHasNoContent() {
    let custom = SystemPromptsStore.describe(customPrompt, for: .promptMode)
    #expect(custom == "custom (\(customPrompt.count) chars)")
    #expect(!custom.contains("Anamnese"))
    #expect(SystemPromptsStore.describe(AppConstants.defaultChatSystemPrompt, for: .chat).hasPrefix("default ("))
    #expect(SystemPromptsStore.describe("", for: .whisperGlossary) == "empty")
    #expect(SystemPromptsStore.describe(nil, for: .chat) == "missing")
  }

  @Test("An autosave burst keeps the original prompt in .bak, not the half-typed text")
  func autosaveBurstKeepsOriginalBackup() throws {
    let dir = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = SystemPromptsStore(contextDirectoryURL: dir)
    try fileContent(sections: [.promptMode: customPrompt])
      .write(to: store.systemPromptsFileURL, atomically: true, encoding: .utf8)

    #expect(store.updateSection(.promptMode, content: "Half-typed replacement"))
    #expect(store.updateSection(.promptMode, content: "Half-typed replacement, more"))
    #expect(read(store.backupFileURL)?.contains(customPrompt) == true, "the original must survive the second autosave")
  }
}
