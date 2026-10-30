//
//  DictationTemplates.swift
//  WhisperShortcut
//
//  A template is instructions for Dictate Prompt, bound to the apps they belong in (a practice's
//  note format in its practice software). With nothing selected, those instructions replace the
//  system prompt for that one turn; a selection or a typed instruction keeps today's prompt.
//

import AppKit

/// Instructions applied to what the user dictates with Dictate Prompt in specific apps (e.g. a
/// practice's note format in its practice software). Empty `appBundleIDs` never matches, so a
/// half-filled template cannot change a turn.
struct DictationTemplate: Codable, Equatable, Identifiable {
  var id = UUID()
  var name = ""
  /// Sent instead of the Dictate Prompt system prompt for that turn.
  var instructions = ""
  /// Bundle identifiers of the apps it applies in. Empty: never applied.
  var appBundleIDs: [String] = []
  /// Optional narrowing for web apps in a browser: the focused window's title must contain one of
  /// these (case-insensitive). Empty: any window of the app.
  var windowTitleKeywords: [String] = []

  /// Ready to apply: instructions are non-blank and at least one app is bound.
  var isUsable: Bool {
    !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !appBundleIDs.isEmpty
  }

  /// Name shown on the recording card. A blank name still has a label, so the card is never empty.
  var displayName: String {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? String(localized: "Template") : trimmed
  }

  init(
    id: UUID = UUID(),
    name: String = "",
    instructions: String = "",
    appBundleIDs: [String] = [],
    windowTitleKeywords: [String] = []
  ) {
    self.id = id
    self.name = name
    self.instructions = instructions
    self.appBundleIDs = appBundleIDs
    self.windowTitleKeywords = windowTitleKeywords
  }

  /// Missing keys keep the defaults above, so a list saved by an older build still loads after a
  /// field is added.
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
    name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
    instructions = try container.decodeIfPresent(String.self, forKey: .instructions) ?? ""
    appBundleIDs = try container.decodeIfPresent([String].self, forKey: .appBundleIDs) ?? []
    windowTitleKeywords = try container.decodeIfPresent([String].self, forKey: .windowTitleKeywords) ?? []
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(name, forKey: .name)
    try container.encode(instructions, forKey: .instructions)
    try container.encode(appBundleIDs, forKey: .appBundleIDs)
    try container.encode(windowTitleKeywords, forKey: .windowTitleKeywords)
  }

  private enum CodingKeys: String, CodingKey {
    case id, name, instructions, appBundleIDs, windowTitleKeywords
  }
}

/// Persists dictation templates in UserDefaults. Absent or undecodable data is no templates,
/// which is today's behaviour for everyone who has not saved one.
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
  }

  /// First usable template for this app and window. Bundle ids compare case-insensitively.
  /// Keywords narrow web apps in a browser: the window title must contain one (case-insensitive);
  /// blank keywords are ignored, and a nil title never satisfies a real keyword list.
  static func match(
    in templates: [DictationTemplate], bundleID: String?, windowTitle: String?
  ) -> DictationTemplate? {
    guard let bundleID else { return nil }
    return templates.first { template in
      guard template.isUsable else { return false }
      guard template.appBundleIDs.contains(where: {
        $0.caseInsensitiveCompare(bundleID) == .orderedSame
      }) else { return false }
      let keywords = template.windowTitleKeywords
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
      if keywords.isEmpty { return true }
      guard let windowTitle else { return false }
      return keywords.contains { windowTitle.range(of: $0, options: .caseInsensitive) != nil }
    }
  }

  /// The template for the frontmost app, or nil. Returns immediately when nothing is saved, so a
  /// user without templates pays nothing — no frontmost-app lookup and no Accessibility call.
  /// The window title is read only when a usable template for that app has keywords.
  static func current() -> DictationTemplate? {
    let templates = load()
    guard !templates.isEmpty else { return nil }
    let front = NSWorkspace.shared.frontmostApplication
    let bundleID = front?.bundleIdentifier
    let title = focusedWindowTitleIfNeeded(of: front, templates: templates, bundleID: bundleID)
    return match(in: templates, bundleID: bundleID, windowTitle: title)
  }

  /// Nil when this app needs no title, or when Accessibility cannot read the focused window.
  private static func focusedWindowTitleIfNeeded(
    of app: NSRunningApplication?, templates: [DictationTemplate], bundleID: String?
  ) -> String? {
    guard let app, let bundleID else { return nil }
    let needsTitle = templates.contains { template in
      guard template.isUsable else { return false }
      guard template.appBundleIDs.contains(where: {
        $0.caseInsensitiveCompare(bundleID) == .orderedSame
      }) else { return false }
      return template.windowTitleKeywords.contains {
        !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      }
    }
    guard needsTitle else { return nil }
    return focusedWindowTitle(pid: app.processIdentifier)
  }

  /// Focused window title via Accessibility. Nil on any failure — a missing title simply fails
  /// keyword matching, and templates without keywords never call this.
  private static func focusedWindowTitle(pid: pid_t) -> String? {
    let appElement = AXUIElementCreateApplication(pid)
    var windowValue: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
      appElement, kAXFocusedWindowAttribute as CFString, &windowValue) == .success,
      let windowValue, CFGetTypeID(windowValue) == AXUIElementGetTypeID()
    else { return nil }
    let window = windowValue as! AXUIElement
    var titleValue: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
      window, kAXTitleAttribute as CFString, &titleValue) == .success
    else { return nil }
    return titleValue as? String
  }
}
