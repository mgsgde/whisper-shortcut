//
//  DictationTemplates.swift
//  WhisperShortcut
//
//  A template is instructions for Dictate Prompt (a practice's note format, say) with its own
//  global shortcut. Pressing it starts one Dictate Prompt recording that uses those instructions
//  instead of the system prompt. Text selected in the target app keeps today's prompt. The
//  generic Dictate Prompt shortcut never applies a template.
//

import AppKit
import HotKey

extension Notification.Name {
  /// Posted after the template list is saved, so global shortcuts can be registered again
  /// without Settings knowing about `Shortcuts`.
  static let dictationTemplatesChanged = Notification.Name("dictationTemplatesChanged")
}

/// Instructions for one Dictate Prompt recording, started by the template's own shortcut.
/// With nothing selected, those instructions replace the system prompt for that recording.
/// A selection keeps today's prompt: the template is never applied to selected text.
/// `shortcut` nil means the template is saved but nothing starts it.
struct DictationTemplate: Codable, Equatable, Identifiable {
  var id = UUID()
  var name = ""
  /// Sent instead of the Dictate Prompt system prompt for that recording.
  var instructions = ""
  /// Its own global shortcut. Nil: the template exists, but no key starts it.
  var shortcut: ShortcutDefinition?

  /// Ready to apply: instructions are non-blank.
  var isUsable: Bool {
    !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  /// Name shown on the recording card and in a shortcut conflict. A blank name still has a
  /// label, so neither surface is empty.
  var displayName: String {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? String(localized: "Template") : trimmed
  }

  init(
    id: UUID = UUID(),
    name: String = "",
    instructions: String = "",
    shortcut: ShortcutDefinition? = nil
  ) {
    self.id = id
    self.name = name
    self.instructions = instructions
    self.shortcut = shortcut
  }

  /// Missing keys keep the defaults above, so a list saved by an older build still loads after a
  /// field is added. Keys this build no longer stores (an app or window binding) are ignored.
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
    name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
    instructions = try container.decodeIfPresent(String.self, forKey: .instructions) ?? ""
    shortcut = try container.decodeIfPresent(ShortcutDefinition.self, forKey: .shortcut)
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(name, forKey: .name)
    try container.encode(instructions, forKey: .instructions)
    try container.encodeIfPresent(shortcut, forKey: .shortcut)
  }

  private enum CodingKeys: String, CodingKey {
    case id, name, instructions, shortcut
  }
}

/// Persists dictation templates in UserDefaults and tells shortcut registration when the list
/// changes. Absent or undecodable data is no templates, which is today's behaviour for everyone
/// who has not saved one.
enum DictationTemplateStore {
  /// Missing or undecodable data is no templates: today's behaviour, and a corrupt value cannot
  /// wedge Dictate Prompt.
  static func load() -> [DictationTemplate] {
    guard let data = UserDefaults.standard.data(forKey: UserDefaultsKeys.dictationTemplates) else {
      return []
    }
    return (try? JSONDecoder().decode([DictationTemplate].self, from: data)) ?? []
  }

  static func save(_ templates: [DictationTemplate]) {
    guard let data = try? JSONEncoder().encode(templates) else { return }
    UserDefaults.standard.set(data, forKey: UserDefaultsKeys.dictationTemplates)
    NotificationCenter.default.post(name: .dictationTemplatesChanged, object: nil)
  }

  /// The saved template with this id, if the list still has it. Shortcut registration holds only
  /// the id, so a press after the template was deleted finds nothing and does not start.
  static func template(id: UUID) -> DictationTemplate? {
    load().first { $0.id == id }
  }
}

/// Who already owns a template's key combination.
enum TemplateShortcutOwner: Equatable {
  /// An app shortcut, named as Settings → Keyboard Shortcuts names it (localized).
  case app(String)
  /// An earlier template in the list. The name is `displayName`, so a blank name still reads
  /// as "Template" in the conflict Settings shows.
  case template(name: String)
}

/// Which template shortcuts get registered. An app shortcut always wins over a template, and an
/// earlier template over a later one, so a duplicate never fires two actions; Settings shows the
/// loser as a conflict instead.
enum TemplateShortcuts {
  /// Usable templates with an enabled shortcut that no enabled app shortcut and no earlier
  /// template uses.
  static func activeBindings(
    templates: [DictationTemplate], appConfig: ShortcutConfig
  ) -> [(template: DictationTemplate, shortcut: ShortcutDefinition)] {
    templates.compactMap { template in
      guard template.isUsable, let shortcut = template.shortcut, shortcut.isEnabled else { return nil }
      guard owner(of: template, in: templates, appConfig: appConfig) == nil else { return nil }
      return (template, shortcut)
    }
  }

  /// Owner of `template.shortcut`'s combination other than the template itself, or nil when free
  /// (also nil when it has no enabled shortcut). Considers enabled app shortcuts first, then
  /// templates BEFORE it in `templates` (by order in the list; a template counts only when it is
  /// usable and its shortcut is enabled).
  static func owner(
    of template: DictationTemplate, in templates: [DictationTemplate], appConfig: ShortcutConfig
  ) -> TemplateShortcutOwner? {
    guard let shortcut = template.shortcut, shortcut.isEnabled else { return nil }
    if let app = appOwner(key: shortcut.key, modifiers: shortcut.modifiers, appConfig: appConfig) {
      return app
    }
    guard let index = templates.firstIndex(where: { $0.id == template.id }) else { return nil }
    return templateOwner(key: shortcut.key, modifiers: shortcut.modifiers, in: templates[..<index])
  }

  /// Owner of an arbitrary combination among app shortcuts and ALL usable templates with an
  /// enabled shortcut except `excludingTemplateID` — used by the recorder before saving a new key.
  static func owner(
    key: Key, modifiers: NSEvent.ModifierFlags, templates: [DictationTemplate],
    excludingTemplateID: UUID?, appConfig: ShortcutConfig
  ) -> TemplateShortcutOwner? {
    if let app = appOwner(key: key, modifiers: modifiers, appConfig: appConfig) {
      return app
    }
    let others = templates.filter { $0.id != excludingTemplateID }
    return templateOwner(key: key, modifiers: modifiers, in: others)
  }

  /// Enabled app shortcuts in this build, in the order Settings lists them. A slot the build
  /// hides (Read Aloud and Add to Glossary in the App Store build) is turned off first, so a
  /// combination the user cannot see or free never blocks a template.
  private static func appOwner(
    key: Key, modifiers: NSEvent.ModifierFlags, appConfig: ShortcutConfig
  ) -> TemplateShortcutOwner? {
    #if APP_STORE
    let isAppStore = true
    #else
    let isAppStore = false
    #endif
    let config = ShortcutConfig.availableInThisBuild(appConfig, isAppStore: isAppStore)
    let slots: [(String, ShortcutDefinition)] = [
      (String(localized: "Dictate"), config.startRecording),
      (String(localized: "Dictate Prompt"), config.startPrompting),
      (String(localized: "Screenshot"), config.screenshotCapture),
      (String(localized: "Read Aloud"), config.readAloud),
      (String(localized: "Add to Glossary"), config.addToGlossary),
      (String(localized: "Chat"), config.openChat),
      (String(localized: "Settings"), config.openSettings),
    ]
    for (name, shortcut) in slots {
      guard shortcut.isEnabled, shortcut.key == key, shortcut.modifiers == modifiers else { continue }
      return .app(name)
    }
    return nil
  }

  private static func templateOwner<S: Sequence>(
    key: Key, modifiers: NSEvent.ModifierFlags, in templates: S
  ) -> TemplateShortcutOwner? where S.Element == DictationTemplate {
    for template in templates {
      guard template.isUsable, let shortcut = template.shortcut, shortcut.isEnabled,
            shortcut.key == key, shortcut.modifiers == modifiers else { continue }
      return .template(name: template.displayName)
    }
    return nil
  }
}
