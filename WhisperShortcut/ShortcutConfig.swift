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
    case .return: return "↩"
    case .escape: return "⎋"
    case .delete: return "⌫"
    case .tab: return "⇥"
    case .space: return "Space"
    case .minus: return "-"
    case .equal: return "="
    case .leftBracket: return "["
    case .rightBracket: return "]"
    case .backslash: return "\\"
    case .semicolon: return ";"
    case .quote: return "'"
    case .grave: return "`"
    case .comma: return ","
    case .period: return "."
    case .slash: return "/"
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
    case .home: return "Home"
    case .pageUp: return "PgUp"
    case .pageDown: return "PgDn"
    case .end: return "End"
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

  static let `default` = ShortcutConfig(
    startRecording: ShortcutDefinition(key: .e, modifiers: [.command, .shift]),
    stopRecording: ShortcutDefinition(key: .e, modifiers: [.command])
  )
}

struct ShortcutDefinition: Codable, Equatable {
  let key: Key
  let modifiers: NSEvent.ModifierFlags

  init(key: Key, modifiers: NSEvent.ModifierFlags) {
    self.key = key
    self.modifiers = modifiers
  }

  var displayString: String {
    var parts: [String] = []

    if modifiers.contains(.command) { parts.append("⌘") }
    if modifiers.contains(.option) { parts.append("⌥") }
    if modifiers.contains(.control) { parts.append("⌃") }
    if modifiers.contains(.shift) { parts.append("⇧") }

    parts.append(key.displayString)

    return parts.joined()
  }

  var textDisplayString: String {
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
    let conflictKeys: [Key] = [.space, .tab, .escape, .return, .delete]
    return conflictKeys.contains(key) && modifiers.isEmpty
  }

  // MARK: - Codable Implementation
  enum CodingKeys: String, CodingKey {
    case key
    case modifiers
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    key = try container.decode(Key.self, forKey: .key)
    modifiers = try container.decode(NSEvent.ModifierFlags.self, forKey: .modifiers)
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(key, forKey: .key)
    try container.encode(modifiers, forKey: .modifiers)
  }

  // MARK: - Equatable Implementation
  static func == (lhs: ShortcutDefinition, rhs: ShortcutDefinition) -> Bool {
    return lhs.key == rhs.key && lhs.modifiers == rhs.modifiers
  }
}

// MARK: - Shortcut Configuration Manager
class ShortcutConfigManager {
  static let shared = ShortcutConfigManager()

  // MARK: - Constants
  private enum Constants {
    static let startRecordingKey = "shortcut_start_recording"
    static let stopRecordingKey = "shortcut_stop_recording"
  }
  
  private let userDefaults = UserDefaults.standard

  private init() {}

  // MARK: - Load/Save Configuration
  func loadConfiguration() -> ShortcutConfig {
    let startRecording =
      loadShortcut(for: Constants.startRecordingKey) ?? ShortcutConfig.default.startRecording
    let stopRecording = loadShortcut(for: Constants.stopRecordingKey) ?? ShortcutConfig.default.stopRecording

    return ShortcutConfig(startRecording: startRecording, stopRecording: stopRecording)
  }

  func saveConfiguration(_ config: ShortcutConfig) {
    saveShortcut(config.startRecording, for: Constants.startRecordingKey)
    saveShortcut(config.stopRecording, for: Constants.stopRecordingKey)

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

    print("🔍 Parsing shortcut: '\(string)' -> '\(cleanString)'")

    // Handle empty input
    if cleanString.isEmpty {
      print("❌ Empty shortcut string")
      return nil
    }

    // Parse text-based shortcuts like "command+option+r" or "ctrl shift t"
    let parts = cleanString.components(
      separatedBy: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "+")))

    print("🔍 Parts: \(parts)")
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
      case "space", " ": key = .space
      case "return", "enter", "↩": key = .return
      case "escape", "esc", "⎋": key = .escape
      case "tab", "⇥": key = .tab
      case "delete", "backspace", "⌫": key = .delete
      case "minus", "-": key = .minus
      case "equal", "=": key = .equal
      case "leftbracket", "[": key = .leftBracket
      case "rightbracket", "]": key = .rightBracket
      case "backslash", "\\": key = .backslash
      case "semicolon", ";": key = .semicolon
      case "quote", "'": key = .quote
      case "grave", "`": key = .grave
      case "comma", ",": key = .comma
      case "period", ".": key = .period
      case "slash", "/": key = .slash

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
      case "home": key = .home
      case "pageup", "pgup": key = .pageUp
      case "pagedown", "pgdn": key = .pageDown
      case "end": key = .end
      case "uparrow", "up", "↑": key = .upArrow
      case "downarrow", "down", "↓": key = .downArrow
      case "leftarrow", "left", "←": key = .leftArrow
      case "rightarrow", "right", "→": key = .rightArrow

      default:
        // Skip empty parts
        if !part.isEmpty {
          print("⚠️ Unknown shortcut part: '\(part)' in '\(string)'")
        }
      }
    }

    guard let key = key else {
      print("❌ No valid key found in shortcut: '\(string)'")
      return nil
    }

    print("✅ Parsed shortcut: '\(string)' -> \(key.displayString) with modifiers: \(modifiers)")
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
    if shortcut == currentConfig.startRecording || shortcut == currentConfig.stopRecording {
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
}
