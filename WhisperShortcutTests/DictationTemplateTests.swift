import Foundation
import Testing
@testable import WhisperShortcut_AppStore

/// Dictation templates replace the Dictate Prompt system prompt for one compose turn. With none
/// saved, Dictate Prompt is unchanged — these tests never write a prompt file except the
/// update-survival case, which checks a custom prompt is left byte-for-byte alone.
@Suite("Dictation templates", .serialized)
struct DictationTemplateTests {

  private let customPrompt = """
    Gliedere das Diktat in Anamnese, Befund und Therapie.
    Gesprochenes "Doppelpunkt" wird zu ":".
    """

  private func fileContent(sections: [SystemPromptSection: String]) -> String {
    SystemPromptSection.allCases.map { section in
      section.fileHeader + "\n\n" + (sections[section] ?? SystemPromptDefaultsHistory.currentDefault(for: section))
    }.joined(separator: "\n\n")
  }

  /// UserDefaults is process-wide; put back whatever this test found.
  private func restoringTemplates(_ body: () throws -> Void) rethrows {
    let key = UserDefaultsKeys.dictationTemplates
    let previous = UserDefaults.standard.data(forKey: key)
    defer {
      if let previous {
        UserDefaults.standard.set(previous, forKey: key)
      } else {
        UserDefaults.standard.removeObject(forKey: key)
      }
    }
    try body()
  }

  @Test("Bundle id match is case-insensitive, and the first usable template wins")
  func matchBundleAndUsable() {
    let unusableBlank = DictationTemplate(
      name: "Blank", instructions: "  ", appBundleIDs: ["com.practice.app"])
    let first = DictationTemplate(
      name: "First", instructions: "One", appBundleIDs: ["Com.Practice.App"])
    let second = DictationTemplate(
      name: "Second", instructions: "Two", appBundleIDs: ["com.practice.app"])
    let otherApp = DictationTemplate(
      name: "Other", instructions: "Three", appBundleIDs: ["com.other.app"])

    let templates = [unusableBlank, otherApp, first, second]
    #expect(DictationTemplateStore.match(
      in: templates, bundleID: "com.practice.app", windowTitle: nil)?.id == first.id)
    #expect(DictationTemplateStore.match(
      in: templates, bundleID: "COM.PRACTICE.APP", windowTitle: "anything")?.id == first.id)
    #expect(DictationTemplateStore.match(in: [unusableBlank], bundleID: "com.practice.app", windowTitle: nil) == nil)
    #expect(DictationTemplateStore.match(in: templates, bundleID: nil, windowTitle: "anything") == nil)
  }

  @Test("A template without apps matches every app, ignores keywords, and list order decides")
  func matchAllApps() {
    let everywhere = DictationTemplate(
      name: "All", instructions: "Format the note", windowTitleKeywords: ["Patientenakte"])
    let limited = DictationTemplate(
      name: "Limited", instructions: "Other", appBundleIDs: ["com.practice.app"])
    let blank = DictationTemplate(name: "Blank", instructions: " \n")

    #expect(DictationTemplateStore.match(
      in: [everywhere], bundleID: "com.any.app", windowTitle: nil)?.id == everywhere.id)
    #expect(DictationTemplateStore.match(
      in: [everywhere], bundleID: nil, windowTitle: nil)?.id == everywhere.id)
    #expect(DictationTemplateStore.match(
      in: [everywhere], bundleID: "com.any.app", windowTitle: "Inbox")?.id == everywhere.id)
    #expect(DictationTemplateStore.match(
      in: [limited, everywhere], bundleID: "com.practice.app", windowTitle: nil)?.id == limited.id)
    #expect(DictationTemplateStore.match(
      in: [everywhere, limited], bundleID: "com.practice.app", windowTitle: nil)?.id == everywhere.id)
    #expect(DictationTemplateStore.match(
      in: [limited, everywhere], bundleID: "com.other.app", windowTitle: nil)?.id == everywhere.id)
    #expect(DictationTemplateStore.match(
      in: [blank], bundleID: "com.any.app", windowTitle: nil) == nil)
    #expect(DictationTemplateStore.match(in: [blank], bundleID: nil, windowTitle: nil) == nil)
  }

  @Test("Keywords match by case-insensitive contains; a nil title fails a keyword list")
  func matchKeywords() {
    let web = DictationTemplate(
      instructions: "Format the note",
      appBundleIDs: ["com.google.Chrome"],
      windowTitleKeywords: ["  Patientenakte ", ""])
    let blanksOnly = DictationTemplate(
      instructions: "Format the note",
      appBundleIDs: ["com.apple.Safari"],
      windowTitleKeywords: ["  ", ""])

    #expect(DictationTemplateStore.match(
      in: [web], bundleID: "com.google.chrome", windowTitle: "Praxis — patientenakte")?.id == web.id)
    #expect(DictationTemplateStore.match(
      in: [web], bundleID: "com.google.chrome", windowTitle: "Inbox") == nil)
    #expect(DictationTemplateStore.match(
      in: [web], bundleID: "com.google.chrome", windowTitle: nil) == nil)
    #expect(DictationTemplateStore.match(
      in: [blanksOnly], bundleID: "com.apple.safari", windowTitle: nil)?.id == blanksOnly.id)
  }

  @Test("Load and save round-trip; a missing key or garbage is no templates")
  func loadAndSave() {
    restoringTemplates {
      UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.dictationTemplates)
      #expect(DictationTemplateStore.load() == [])

      UserDefaults.standard.set(Data("not-json".utf8), forKey: UserDefaultsKeys.dictationTemplates)
      #expect(DictationTemplateStore.load() == [])
      UserDefaults.standard.set(Data([0xFF, 0x00]), forKey: UserDefaultsKeys.dictationTemplates)
      #expect(DictationTemplateStore.load() == [])

      let id = UUID(uuidString: "7E3A1C2B-4D5E-4F60-8A71-92B3C4D5E6F7")!
      let json = """
        [{"id":"\(id.uuidString)","name":"Praxis","instructions":"Format the note","appBundleIDs":["com.practice.app"]}]
        """
      UserDefaults.standard.set(Data(json.utf8), forKey: UserDefaultsKeys.dictationTemplates)
      let legacy = DictationTemplateStore.load()
      #expect(legacy.count == 1)
      #expect(legacy[0].id == id)
      #expect(legacy[0].windowTitleKeywords == [])
      #expect(legacy[0].instructions == "Format the note")

      let saved = [
        DictationTemplate(
          name: "Praxis", instructions: customPrompt,
          appBundleIDs: ["com.practice.app"], windowTitleKeywords: ["Patientenakte"])
      ]
      DictationTemplateStore.save(saved)
      #expect(DictationTemplateStore.load() == saved)
    }
  }

  @Test("A template replaces the stored prompt; a blank one leaves it")
  func dictatePromptBase() {
    let stored = "Custom prompt the user wrote"
    let template = "Practice note format"
    #expect(SpeechService.dictatePromptBase(stored: stored, template: template) == template)
    #expect(SpeechService.dictatePromptBase(stored: stored, template: nil) == stored)
    #expect(SpeechService.dictatePromptBase(stored: stored, template: "") == stored)
    #expect(SpeechService.dictatePromptBase(stored: stored, template: "  \n") == stored)
    #expect(SpeechService.dictatePromptBase(stored: "  ", template: nil) == AppConstants.defaultPromptModeSystemPrompt)
    #expect(SpeechService.dictatePromptBase(stored: "", template: nil) == AppConstants.defaultPromptModeSystemPrompt)
    // Moving a system prompt into a template hands the model the identical base.
    #expect(
      SpeechService.dictatePromptBase(stored: "", template: customPrompt)
        == SpeechService.dictatePromptBase(stored: customPrompt, template: nil))
  }

  /// Regression: a custom prompt vanished after an update on 2026-10-19. A fresh store is the
  /// first launch after that update; its first read runs `liftUnchangedDefaultsOnce`. Saving a
  /// template list must not touch the prompt file.
  @Test("A custom Dictate Prompt survives an update while templates are saved")
  func customPromptSurvivesUpdateWithTemplates() throws {
    try restoringTemplates {
      let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("DictationTemplateTests-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: dir) }

      let fileURL = dir.appendingPathComponent(SystemPromptsStore.fileName)
      let original = fileContent(sections: [.promptMode: customPrompt])
      try original.write(to: fileURL, atomically: true, encoding: .utf8)
      let before = try Data(contentsOf: fileURL)

      DictationTemplateStore.save([
        DictationTemplate(
          name: "Praxis", instructions: customPrompt, appBundleIDs: ["com.practice.app"])
      ])

      let store = SystemPromptsStore(contextDirectoryURL: dir)
      let loaded = store.loadDictatePromptSystemPrompt()
      #expect(loaded == customPrompt)
      #expect(try Data(contentsOf: fileURL) == before)
      #expect(!FileManager.default.fileExists(atPath: store.backupFileURL.path))
      #expect(SpeechService.dictatePromptBase(stored: loaded, template: nil) == customPrompt)

      let second = SystemPromptsStore(contextDirectoryURL: dir)
      #expect(second.loadDictatePromptSystemPrompt() == customPrompt)
      #expect(try Data(contentsOf: fileURL) == before)
      #expect(!FileManager.default.fileExists(atPath: second.backupFileURL.path))
    }
  }
}
