import AppKit
import Foundation
import Testing
@testable import WhisperShortcut_AppStore

/// Dictation templates replace the Dictate Prompt system prompt for one compose turn, started by
/// the template's own shortcut. With none saved, Dictate Prompt is unchanged — these tests never
/// write a prompt file except the update-survival case, which checks a custom prompt is left
/// byte-for-byte alone.
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

  /// A binding on the same key as `source`, with the modifiers and enabled flag under test.
  /// Built from `ShortcutConfig.default` so the test does not invent a key the app does not use.
  private func binding(
    like source: ShortcutDefinition, modifiers: NSEvent.ModifierFlags, enabled: Bool = true
  ) -> ShortcutDefinition {
    ShortcutDefinition(key: source.key, modifiers: modifiers, isEnabled: enabled)
  }

  @Test("Active bindings skip an empty, disabled, or taken shortcut, and the first duplicate wins")
  func activeBindingsAndOwners() {
    var config = ShortcutConfig.default
    let commandTwo = binding(like: config.startPrompting, modifiers: [.command])
    config.startPrompting = commandTwo
    let commandOne = binding(like: config.startRecording, modifiers: [.command])

    let noShortcut = DictationTemplate(name: "None", instructions: "Write it")
    let disabled = DictationTemplate(
      name: "Off", instructions: "Write it",
      shortcut: binding(like: config.openChat, modifiers: [.command, .shift], enabled: false))
    let blank = DictationTemplate(name: "Blank", instructions: "  ", shortcut: commandOne)
    let blocked = DictationTemplate(name: "Blocked", instructions: "Write it", shortcut: commandTwo)
    let first = DictationTemplate(name: "First", instructions: "One", shortcut: commandOne)
    let second = DictationTemplate(name: "Second", instructions: "Two", shortcut: commandOne)
    let templates = [noShortcut, disabled, blank, blocked, first, second]

    let bindings = TemplateShortcuts.activeBindings(templates: templates, appConfig: config)
    #expect(bindings.map(\.template.id) == [first.id])
    #expect(bindings.first?.shortcut == commandOne)

    #expect(
      TemplateShortcuts.owner(of: blocked, in: templates, appConfig: config)
        == .app(String(localized: "Dictate Prompt")))
    #expect(
      TemplateShortcuts.owner(of: second, in: templates, appConfig: config)
        == .template(name: first.displayName))
    #expect(TemplateShortcuts.owner(of: first, in: templates, appConfig: config) == nil)
    #expect(TemplateShortcuts.owner(of: disabled, in: templates, appConfig: config) == nil)
    #expect(TemplateShortcuts.owner(of: noShortcut, in: templates, appConfig: config) == nil)

    // A disabled app slot does not own its combination, so the template may use it.
    var disabledPrompt = ShortcutConfig.default
    disabledPrompt.startPrompting = binding(like: disabledPrompt.startPrompting, modifiers: [.command], enabled: false)
    #expect(
      TemplateShortcuts.activeBindings(templates: [blocked], appConfig: disabledPrompt).map(\.template.id)
        == [blocked.id])
    #expect(TemplateShortcuts.owner(of: blocked, in: [blocked], appConfig: disabledPrompt) == nil)

    #expect(
      TemplateShortcuts.owner(
        key: commandOne.key, modifiers: commandOne.modifiers, templates: [first, second],
        excludingTemplateID: first.id, appConfig: config) == .template(name: second.displayName))
    #expect(
      TemplateShortcuts.owner(
        key: commandOne.key, modifiers: commandOne.modifiers, templates: [first],
        excludingTemplateID: first.id, appConfig: config) == nil)
    #expect(
      TemplateShortcuts.owner(
        key: commandTwo.key, modifiers: commandTwo.modifiers, templates: [blocked],
        excludingTemplateID: blocked.id, appConfig: config)
        == .app(String(localized: "Dictate Prompt")))
  }

  /// A practice records its note template on ⌘2, which legacy installs already give to Dictate
  /// Prompt. Reassign frees Screenshot's ⌘3, Dictate Prompt moves there, and only then does the
  /// template own ⌘2. Shortcut fields are `let`, so each step is a new value.
  @Test("Practice setup: Dictate Prompt moved to ⌘3, then the template takes ⌘2")
  func practiceSetupMovesDictatePromptThenTemplateTakesCommandTwo() {
    var config = ShortcutConfig.legacyCommandDigit
    let commandTwo = binding(like: config.startPrompting, modifiers: config.startPrompting.modifiers)
    let template = DictationTemplate(
      name: "Praxis", instructions: "Format the note", shortcut: commandTwo)
    let templates = [template]

    #expect(TemplateShortcuts.activeBindings(templates: templates, appConfig: config).isEmpty)
    #expect(
      TemplateShortcuts.owner(of: template, in: templates, appConfig: config)
        == .app(String(localized: "Dictate Prompt")))

    let screenshot = config.screenshotCapture
    config.screenshotCapture = ShortcutDefinition(
      key: screenshot.key, modifiers: screenshot.modifiers, isEnabled: false,
      displayCharacter: screenshot.displayCharacter)
    config.startPrompting = ShortcutDefinition(
      key: screenshot.key, modifiers: screenshot.modifiers, isEnabled: true,
      displayCharacter: screenshot.displayCharacter)

    let bindings = TemplateShortcuts.activeBindings(templates: templates, appConfig: config)
    #expect(bindings.map(\.template.id) == [template.id])
    #expect(bindings.first?.shortcut == commandTwo)
    #expect(TemplateShortcuts.owner(of: template, in: templates, appConfig: config) == nil)

    let moved = config.startPrompting
    let ownerOfMoved = TemplateShortcuts.owner(
      key: moved.key, modifiers: moved.modifiers, templates: templates,
      excludingTemplateID: nil, appConfig: config)
    #expect(ownerOfMoved == .app(String(localized: "Dictate Prompt")))
    if case .template = ownerOfMoved {
      Issue.record("Dictate Prompt's shortcut appeared as a template owner")
    }
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
        [{"id":"\(id.uuidString)","name":"Praxis","instructions":"Format the note","appBundleIDs":["com.practice.app"],"windowTitleKeywords":["Patientenakte"]}]
        """
      UserDefaults.standard.set(Data(json.utf8), forKey: UserDefaultsKeys.dictationTemplates)
      let legacy = DictationTemplateStore.load()
      #expect(legacy.count == 1)
      #expect(legacy[0].id == id)
      #expect(legacy[0].shortcut == nil)
      #expect(legacy[0].instructions == "Format the note")

      let saved = [
        DictationTemplate(
          name: "Praxis", instructions: customPrompt,
          shortcut: binding(like: ShortcutConfig.default.openSettings, modifiers: [.command, .option]))
      ]
      let flag = NotificationFlag()
      let observer = NotificationCenter.default.addObserver(
        forName: .dictationTemplatesChanged, object: nil, queue: nil
      ) { _ in flag.posted = true }
      DictationTemplateStore.save(saved)
      NotificationCenter.default.removeObserver(observer)
      #expect(flag.posted)
      #expect(DictationTemplateStore.load() == saved)
      #expect(DictationTemplateStore.template(id: saved[0].id) == saved[0])
      #expect(DictationTemplateStore.template(id: UUID()) == nil)
    }
  }

  @Test("A shortcut round-trips, and legacy app or window keys still decode")
  func shortcutCodable() throws {
    let shortcut = binding(like: ShortcutConfig.default.startRecording, modifiers: [.command, .option])
    let original = DictationTemplate(name: "Praxis", instructions: "Format the note", shortcut: shortcut)
    let data = try JSONEncoder().encode(original)
    let text = String(decoding: data, as: UTF8.self)
    #expect(!text.contains("appBundleIDs"))
    #expect(!text.contains("windowTitleKeywords"))
    let decoded = try JSONDecoder().decode(DictationTemplate.self, from: data)
    #expect(decoded == original)
    #expect(decoded.shortcut == shortcut)

    let id = UUID(uuidString: "7E3A1C2B-4D5E-4F60-8A71-92B3C4D5E6F7")!
    let legacy = """
      {"id":"\(id.uuidString)","name":"Praxis","instructions":"Format the note","appBundleIDs":["com.practice.app"],"windowTitleKeywords":["Patientenakte"]}
      """.data(using: .utf8)!
    let fromLegacy = try JSONDecoder().decode(DictationTemplate.self, from: legacy)
    #expect(fromLegacy.id == id)
    #expect(fromLegacy.name == "Praxis")
    #expect(fromLegacy.instructions == "Format the note")
    #expect(fromLegacy.shortcut == nil)

    let withoutShortcut = """
      {"id":"\(id.uuidString)","name":"Praxis","instructions":"Format the note"}
      """.data(using: .utf8)!
    let fromMissing = try JSONDecoder().decode(DictationTemplate.self, from: withoutShortcut)
    #expect(fromMissing.id == id)
    #expect(fromMissing.shortcut == nil)
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
        DictationTemplate(name: "Praxis", instructions: customPrompt)
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

/// The notification observer's closure cannot mutate a captured boolean.
private final class NotificationFlag: @unchecked Sendable {
  var posted = false
}
