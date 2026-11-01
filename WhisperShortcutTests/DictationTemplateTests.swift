import AppKit
import Foundation
import HotKey
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

    let bindings = TemplateShortcuts.activeBindings(
      templates: templates, appConfig: config, pickerShortcut: nil)
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
      TemplateShortcuts.activeBindings(
        templates: [blocked], appConfig: disabledPrompt, pickerShortcut: nil).map(\.template.id)
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

    #expect(TemplateShortcuts.activeBindings(
      templates: templates, appConfig: config, pickerShortcut: nil).isEmpty)
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

    let bindings = TemplateShortcuts.activeBindings(
      templates: templates, appConfig: config, pickerShortcut: nil)
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

  @Test("The generic shortcut starts on the last-used template, and only lists a choice when there are two")
  func templatePickerStart() throws {
    let blank = DictationTemplate(name: "Blank", instructions: "  ")
    #expect(TemplatePicker.start(templates: [], lastUsedID: nil) == nil)
    #expect(TemplatePicker.start(templates: [blank], lastUsedID: nil) == nil)

    let only = DictationTemplate(name: "Only", instructions: "Write it")
    let one = try #require(TemplatePicker.start(templates: [blank, only], lastUsedID: nil))
    #expect(one.initial == only)
    #expect(one.choices.isEmpty)

    let first = DictationTemplate(name: "First", instructions: "One")
    let second = DictationTemplate(name: "Second", instructions: "Two")
    let third = DictationTemplate(name: "Third", instructions: "Three")
    let three = [first, second, third]
    let picked = try #require(TemplatePicker.start(templates: three, lastUsedID: second.id))
    #expect(picked.initial == second)
    #expect(picked.choices == three)

    let unknown = try #require(TemplatePicker.start(templates: three, lastUsedID: UUID()))
    #expect(unknown.initial == first)
    #expect(unknown.choices == three)
    let stale = try #require(TemplatePicker.start(templates: [blank, first, second], lastUsedID: blank.id))
    #expect(stale.initial == first)
    #expect(stale.choices == [first, second])
  }

  @Test("An app shortcut blocks the generic one; the generic one blocks a template on the same key")
  func pickerPrecedence() {
    let optionCommandT = ShortcutDefinition(key: .t, modifiers: [.option, .command])
    let template = DictationTemplate(
      name: "Praxis", instructions: "Format the note", shortcut: optionCommandT)
    let templates = [template]

    var blocked = ShortcutConfig.default
    blocked.startPrompting = optionCommandT
    #expect(!TemplateShortcuts.pickerIsActive(
      pickerShortcut: optionCommandT, templates: templates, appConfig: blocked))
    #expect(
      TemplateShortcuts.pickerOwner(
        pickerShortcut: optionCommandT, templates: templates, appConfig: blocked)
        == .app(String(localized: "Dictate Prompt")))

    let free = ShortcutConfig.default
    #expect(TemplateShortcuts.pickerIsActive(
      pickerShortcut: optionCommandT, templates: templates, appConfig: free))
    #expect(TemplateShortcuts.activeBindings(
      templates: templates, appConfig: free, pickerShortcut: optionCommandT).isEmpty)
    #expect(
      TemplateShortcuts.owner(
        of: template, in: templates, appConfig: free, pickerShortcut: optionCommandT) == .picker)
    #expect(
      TemplateShortcuts.activeBindings(
        templates: templates, appConfig: free, pickerShortcut: nil).map(\.template.id)
        == [template.id])
  }

  @Test("The generic shortcut and the last-used template round-trip; nil removes the shortcut")
  func pickerShortcutAndLastUsedRoundTrip() {
    restoringPickerDefaults {
      let shortcut = ShortcutDefinition(key: .t, modifiers: [.option, .command])
      let flag = NotificationFlag()
      let observer = NotificationCenter.default.addObserver(
        forName: .dictationTemplatesChanged, object: nil, queue: nil
      ) { _ in flag.posted = true }
      DictationTemplateStore.savePickerShortcut(shortcut)
      NotificationCenter.default.removeObserver(observer)
      #expect(flag.posted)
      #expect(DictationTemplateStore.loadPickerShortcut() == shortcut)

      flag.posted = false
      let again = NotificationCenter.default.addObserver(
        forName: .dictationTemplatesChanged, object: nil, queue: nil
      ) { _ in flag.posted = true }
      DictationTemplateStore.savePickerShortcut(nil)
      NotificationCenter.default.removeObserver(again)
      #expect(flag.posted)
      #expect(DictationTemplateStore.loadPickerShortcut() == nil)
      #expect(
        UserDefaults.standard.data(forKey: UserDefaultsKeys.dictationTemplatePickerShortcut) == nil)

      let id = UUID(uuidString: "7E3A1C2B-4D5E-4F60-8A71-92B3C4D5E6F7")!
      DictationTemplateStore.lastUsedTemplateID = id
      #expect(DictationTemplateStore.lastUsedTemplateID == id)
      DictationTemplateStore.lastUsedTemplateID = nil
      #expect(DictationTemplateStore.lastUsedTemplateID == nil)
    }
  }

  /// UserDefaults is process-wide; put the generic shortcut and the last-used id back.
  private func restoringPickerDefaults(_ body: () throws -> Void) rethrows {
    let shortcutKey = UserDefaultsKeys.dictationTemplatePickerShortcut
    let idKey = UserDefaultsKeys.dictationTemplateLastUsedID
    let shortcut = UserDefaults.standard.data(forKey: shortcutKey)
    let id = UserDefaults.standard.string(forKey: idKey)
    defer {
      if let shortcut {
        UserDefaults.standard.set(shortcut, forKey: shortcutKey)
      } else {
        UserDefaults.standard.removeObject(forKey: shortcutKey)
      }
      if let id {
        UserDefaults.standard.set(id, forKey: idKey)
      } else {
        UserDefaults.standard.removeObject(forKey: idKey)
      }
    }
    try body()
  }
}

/// The notification observer's closure cannot mutate a captured boolean.
private final class NotificationFlag: @unchecked Sendable {
  var posted = false
}
