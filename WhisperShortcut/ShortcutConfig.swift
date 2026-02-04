import AppKit
import Foundation
import HotKey

// MARK: - Key Extensions
extension Key: Codable {
  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    let rawValue = try container.decode(UInt16.self)
    // Use carbonKeyCode initializer which takes UInt32
    self = Key(carbonKeyCode: UInt32(rawValue)) ?? .a
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    // Encode the carbon key code
    try container.encode(UInt16(carbonKeyCode))
  }

  var displayString: String {
    switch self {
    case .a: return "A"
    case .b: return "B"
    case .c: return "C"
    case .d: return "D"
    case .e: return "E"
    case .f: return "F"
    case .g: return "G"
    case .h: return "H"
    case .i: return "I"
    case .j: return "J"
    case .k: return "K"
    case .l: return "L"
    case .m: return "M"
    case .n: return "N"
    case .o: return "O"
    case .p: return "P"
    case .q: return "Q"
    case .r: return "R"
    case .s: return "S"
    case .t: return "T"
    case .u: return "U"
    case .v: return "V"
    case .w: return "W"
    case .x: return "X"
    case .y: return "Y"
    case .z: return "Z"
    case .zero: return "0"
    case .one: return "1"
    case .two: return "2"
    case .three: return "3"
    case .four: return "4"
    case .five: return "5"
    case .six: return "6"
    case .seven: return "7"
    case .eight: return "8"
    case .nine: return "9"
    case .escape: return "⎋"
    case .comma: return ","
    case .period: return "."
    case .f1: return "F1"
    case .f2: return "F2"
    case .f3: return "F3"
    case .f4: return "F4"
    case .f5: return "F5"
    case .f6: return "F6"
    case .f7: return "F7"
    case .f8: return "F8"
    case .f9: return "F9"
    case .f10: return "F10"
    case .f11: return "F11"
    case .f12: return "F12"
    case .upArrow: return "↑"
    case .downArrow: return "↓"
    case .leftArrow: return "←"
    case .rightArrow: return "→"

    default: return "Key"
    }
  }
}

// MARK: - NSEvent.ModifierFlags Extensions
extension NSEvent.ModifierFlags: Codable {
  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    let rawValue = try container.decode(UInt.self)
    self = NSEvent.ModifierFlags(rawValue: rawValue)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

// MARK: - Shortcut Configuration Models
struct ShortcutConfig: Codable {
  var startRecording: ShortcutDefinition
  var stopRecording: ShortcutDefinition
  var startPrompting: ShortcutDefinition
  var stopPrompting: ShortcutDefinition
  var readSelectedText: ShortcutDefinition
  var readAloud: ShortcutDefinition
  var openSettings: ShortcutDefinition

  static let `default` = ShortcutConfig(
    startRecording: ShortcutDefinition(key: .one, modifiers: [.command]),
    stopRecording: ShortcutDefinition(key: .one, modifiers: [.command]),
    startPrompting: ShortcutDefinition(key: .two, modifiers: [.command]),
    stopPrompting: ShortcutDefinition(key: .two, modifiers: [.command]),
    readSelectedText: ShortcutDefinition(key: .three, modifiers: [.command], isEnabled: true),
    readAloud: ShortcutDefinition(key: .four, modifiers: [.command], isEnabled: true),
    openSettings: ShortcutDefinition(key: .five, modifiers: [.command], isEnabled: true)
  )
}

struct ShortcutDefinition: Codable, Equatable, Hashable {
  let key: Key
  let modifiers: NSEvent.ModifierFlags
  let isEnabled: Bool

  init(key: Key, modifiers: NSEvent.ModifierFlags, isEnabled: Bool = true) {
    self.key = key
    self.modifiers = modifiers
    self.isEnabled = isEnabled
  }

  var displayString: String {
    if !isEnabled {
      return "Disabled"
    }

    var parts: [String] = []

    if modifiers.contains(.command) { parts.append("⌘") }
    if modifiers.contains(.option) { parts.append("⌥") }
    if modifiers.contains(.control) { parts.append("⌃") }
    if modifiers.contains(.shift) { parts.append("⇧") }

    parts.append(key.displayString)

    return parts.joined()
  }

  var textDisplayString: String {
    if !isEnabled {
      return "Disabled"
    }

    var parts: [String] = []

    if modifiers.contains(.command) { parts.append("command") }
    if modifiers.contains(.option) { parts.append("option") }
    if modifiers.contains(.control) { parts.append("control") }
    if modifiers.contains(.shift) { parts.append("shift") }

    parts.append(key.displayString.lowercased())

    return parts.joined(separator: "+")
  }

  var isConflicting: Bool {
    // Check for common conflicts
    let conflictKeys: [Key] = [.escape]
    return conflictKeys.contains(key) && modifiers.isEmpty
  }

  // MARK: - Codable Implementation
  enum CodingKeys: String, CodingKey {
    case key
    case modifiers
    case isEnabled
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    key = try container.decode(Key.self, forKey: .key)
    modifiers = try container.decode(NSEvent.ModifierFlags.self, forKey: .modifiers)
    isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(key, forKey: .key)
    try container.encode(modifiers, forKey: .modifiers)
    try container.encode(isEnabled, forKey: .isEnabled)
  }

  // MARK: - Equatable Implementation
  static func == (lhs: ShortcutDefinition, rhs: ShortcutDefinition) -> Bool {
    return lhs.key == rhs.key && lhs.modifiers == rhs.modifiers && lhs.isEnabled == rhs.isEnabled
  }

  // MARK: - Hashable Implementation
  func hash(into hasher: inout Hasher) {
    hasher.combine(key.carbonKeyCode)
    hasher.combine(modifiers.rawValue)
    hasher.combine(isEnabled)
  }
}

// MARK: - Shortcut Configuration Manager
class ShortcutConfigManager {
  static let shared = ShortcutConfigManager()

  // MARK: - Constants
  private enum Constants {
    static let startRecordingKey = "shortcut_start_recording"
    static let stopRecordingKey = "shortcut_stop_recording"
    static let startPromptingKey = "shortcut_start_prompting"
    static let stopPromptingKey = "shortcut_stop_prompting"
    static let readSelectedTextKey = "shortcut_read_selected_text"
    static let readAloudKey = "shortcut_read_aloud"
    static let openSettingsKey = "shortcut_open_settings"
  }

  private let userDefaults = UserDefaults.standard

  private init() {}

  // MARK: - Load/Save Configuration
  func loadConfiguration() -> ShortcutConfig {
    let startRecording =
      loadShortcut(for: Constants.startRecordingKey) ?? ShortcutConfig.default.startRecording
    let stopRecording =
      loadShortcut(for: Constants.stopRecordingKey) ?? ShortcutConfig.default.stopRecording
    let startPrompting =
      loadShortcut(for: Constants.startPromptingKey) ?? ShortcutConfig.default.startPrompting
    let stopPrompting =
      loadShortcut(for: Constants.stopPromptingKey) ?? ShortcutConfig.default.stopPrompting
    let readSelectedText =
      loadShortcut(for: Constants.readSelectedTextKey) ?? ShortcutConfig.default.readSelectedText
    let readAloud =
      loadShortcut(for: Constants.readAloudKey) ?? ShortcutConfig.default.readAloud
    let openSettings =
      loadShortcut(for: Constants.openSettingsKey) ?? ShortcutConfig.default.openSettings
    return ShortcutConfig(
      startRecording: startRecording,
      stopRecording: stopRecording,
      startPrompting: startPrompting,
      stopPrompting: stopPrompting,
      readSelectedText: readSelectedText,
      readAloud: readAloud,
      openSettings: openSettings
    )
  }

  func saveConfiguration(_ config: ShortcutConfig) {
    saveShortcut(config.startRecording, for: Constants.startRecordingKey)
    saveShortcut(config.stopRecording, for: Constants.stopRecordingKey)
    saveShortcut(config.startPrompting, for: Constants.startPromptingKey)
    saveShortcut(config.stopPrompting, for: Constants.stopPromptingKey)
    saveShortcut(config.readSelectedText, for: Constants.readSelectedTextKey)
    saveShortcut(config.readAloud, for: Constants.readAloudKey)
    saveShortcut(config.openSettings, for: Constants.openSettingsKey)

    // Post notification for shortcut updates
    NotificationCenter.default.post(name: .shortcutsChanged, object: config)
  }

  func resetToDefaults() {
    let defaultConfig = ShortcutConfig.default
    saveConfiguration(defaultConfig)
  }

  // MARK: - Private Helper Methods
  private func loadShortcut(for key: String) -> ShortcutDefinition? {
    guard let data = userDefaults.data(forKey: key),
      let shortcut = try? JSONDecoder().decode(ShortcutDefinition.self, from: data)
    else {
      return nil
    }
    return shortcut
  }

  private func saveShortcut(_ shortcut: ShortcutDefinition, for key: String) {
    if let data = try? JSONEncoder().encode(shortcut) {
      userDefaults.set(data, forKey: key)
    }
  }

  // MARK: - String-based parsing (for UI)
  static func parseShortcut(from string: String) -> ShortcutDefinition? {
    let cleanString = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

    // Handle empty input
    if cleanString.isEmpty {

      return nil
    }

    // Parse text-based shortcuts like "command+option+r" or "ctrl shift t"
    let parts = cleanString.components(
      separatedBy: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "+")))

    var modifiers: NSEvent.ModifierFlags = []
    var key: Key?

    for part in parts {
      switch part {
      // Modifiers
      case "command", "cmd", "⌘":
        modifiers.insert(.command)
      case "option", "alt", "⌥":
        modifiers.insert(.option)
      case "control", "ctrl", "⌃":
        modifiers.insert(.control)
      case "shift", "⇧":
        modifiers.insert(.shift)

      // Letters
      case "a": key = .a
      case "b": key = .b
      case "c": key = .c
      case "d": key = .d
      case "e": key = .e
      case "f": key = .f
      case "g": key = .g
      case "h": key = .h
      case "i": key = .i
      case "j": key = .j
      case "k": key = .k
      case "l": key = .l
      case "m": key = .m
      case "n": key = .n
      case "o": key = .o
      case "p": key = .p
      case "q": key = .q
      case "r": key = .r
      case "s": key = .s
      case "t": key = .t
      case "u": key = .u
      case "v": key = .v
      case "w": key = .w
      case "x": key = .x
      case "y": key = .y
      case "z": key = .z

      // Numbers
      case "0": key = .zero
      case "1": key = .one
      case "2": key = .two
      case "3": key = .three
      case "4": key = .four
      case "5": key = .five
      case "6": key = .six
      case "7": key = .seven
      case "8": key = .eight
      case "9": key = .nine

      // Special keys
      case "escape", "esc", "⎋": key = .escape
      case "comma", ",": key = .comma
      case "period", ".": key = .period

      // Function keys
      case "f1": key = .f1
      case "f2": key = .f2
      case "f3": key = .f3
      case "f4": key = .f4
      case "f5": key = .f5
      case "f6": key = .f6
      case "f7": key = .f7
      case "f8": key = .f8
      case "f9": key = .f9
      case "f10": key = .f10
      case "f11": key = .f11
      case "f12": key = .f12

      // Navigation keys
      case "uparrow", "up", "↑": key = .upArrow
      case "downarrow", "down", "↓": key = .downArrow
      case "leftarrow", "left", "←": key = .leftArrow
      case "rightarrow", "right", "→": key = .rightArrow

      default:
        // Skip empty parts
        if !part.isEmpty {

        }
      }
    }

    guard let key = key else {

      return nil
    }

    return ShortcutDefinition(key: key, modifiers: modifiers)
  }

  // MARK: - Validation
  func validateShortcut(_ shortcut: ShortcutDefinition) -> ShortcutValidationResult {
    // Check for conflicts with system shortcuts
    if shortcut.isConflicting {
      return .conflict("This shortcut conflicts with system shortcuts")
    }

    // Check for duplicate shortcuts
    let currentConfig = loadConfiguration()
    if shortcut == currentConfig.startRecording || shortcut == currentConfig.stopRecording
      || shortcut == currentConfig.startPrompting || shortcut == currentConfig.stopPrompting
      || shortcut == currentConfig.readSelectedText || shortcut == currentConfig.readAloud
      || shortcut == currentConfig.openSettings
    {
      return .duplicate("This shortcut is already in use")
    }

    return .valid
  }
}

// MARK: - Validation Result
enum ShortcutValidationResult {
  case valid
  case conflict(String)
  case duplicate(String)

  var isValid: Bool {
    switch self {
    case .valid:
      return true
    case .conflict, .duplicate:
      return false
    }
  }

  var errorMessage: String? {
    switch self {
    case .valid:
      return nil
    case .conflict(let message), .duplicate(let message):
      return message
    }
  }
}

// MARK: - Notification Extension
extension Notification.Name {
  static let shortcutsChanged = Notification.Name("shortcutsChanged")
  static let modelChanged = Notification.Name("modelChanged")
  /// Posted when API is rate limited and waiting. userInfo contains "waitTime" (TimeInterval)
  static let rateLimitWaiting = Notification.Name("rateLimitWaiting")
  /// Posted when rate limit wait is complete
  static let rateLimitResolved = Notification.Name("rateLimitResolved")
}
