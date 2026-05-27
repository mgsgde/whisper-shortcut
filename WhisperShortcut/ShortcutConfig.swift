import AppKit
import Carbon
import Carbon.HIToolbox
import Foundation
import HotKey

// MARK: - Key Extensions
extension Key: @retroactive Codable {
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
    case .space: return "Space"
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
extension NSEvent.ModifierFlags: @retroactive Codable {
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
  var toggleMeeting: ShortcutDefinition
  var stopMeeting: ShortcutDefinition
  var openSettings: ShortcutDefinition
  var openChat: ShortcutDefinition
  var screenshotCapture: ShortcutDefinition
  var readAloud: ShortcutDefinition

  static let `default` = ShortcutConfig(
    startRecording: ShortcutDefinition(key: .one, modifiers: [.command]),
    stopRecording: ShortcutDefinition(key: .one, modifiers: [.command]),
    startPrompting: ShortcutDefinition(key: .two, modifiers: [.command]),
    stopPrompting: ShortcutDefinition(key: .two, modifiers: [.command]),
    toggleMeeting: ShortcutDefinition(key: .m, modifiers: [.command, .shift], isEnabled: true),
    stopMeeting: ShortcutDefinition(key: .m, modifiers: [.command, .shift], isEnabled: true),
    openSettings: ShortcutDefinition(key: .zero, modifiers: [.command], isEnabled: true),
    openChat: ShortcutDefinition(key: .space, modifiers: [.option], isEnabled: true),
    screenshotCapture: ShortcutDefinition(key: .three, modifiers: [.command], isEnabled: true),
    readAloud: ShortcutDefinition(key: .four, modifiers: [.command], isEnabled: true)
  )

}

struct ShortcutDefinition: Codable, Equatable, Hashable {
  let key: Key
  let modifiers: NSEvent.ModifierFlags
  let isEnabled: Bool
  /// User-visible character for the user's current keyboard layout, captured at
  /// record time from `event.charactersIgnoringModifiers`. Persisted so the UI
  /// shows e.g. "Z" on a German layout for the same carbon keycode that is "Y"
  /// on US. `nil` for legacy stored shortcuts (pre-recorder) — falls back to
  /// the layout-independent `key.displayString` in `renderShortcut(separator:)`.
  let displayCharacter: String?

  init(
    key: Key,
    modifiers: NSEvent.ModifierFlags,
    isEnabled: Bool = true,
    displayCharacter: String? = nil
  ) {
    self.key = key
    self.modifiers = modifiers
    self.isEnabled = isEnabled
    self.displayCharacter = displayCharacter
  }

  var displayString: String {
    renderShortcut(separator: "")
  }

  /// Same as `displayString`, but joins modifiers and the key with " + " so the
  /// keys read as a combination rather than one token (e.g. "⌘ + 1" instead of
  /// "⌘1"). Used in help/legend text where the menu-bar's compact glyph
  /// concatenation is harder to parse.
  var displayStringWithSeparator: String {
    renderShortcut(separator: " + ")
  }

  private func renderShortcut(separator: String) -> String {
    if !isEnabled {
      return "Disabled"
    }

    var parts: [String] = []

    if modifiers.contains(.command) { parts.append("⌘") }
    if modifiers.contains(.option) { parts.append("⌥") }
    if modifiers.contains(.control) { parts.append("⌃") }
    if modifiers.contains(.shift) { parts.append("⇧") }

    if let ch = displayCharacter, !ch.isEmpty {
      parts.append(ch.uppercased())
    } else if let layoutChar = Self.layoutAwareCharacter(forCarbonKeyCode: key.carbonKeyCode) {
      parts.append(layoutChar.uppercased())
    } else {
      parts.append(key.displayString)
    }

    return parts.joined(separator: separator)
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
    case displayCharacter
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    key = try container.decode(Key.self, forKey: .key)
    modifiers = try container.decode(NSEvent.ModifierFlags.self, forKey: .modifiers)
    isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    displayCharacter = try container.decodeIfPresent(String.self, forKey: .displayCharacter)
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(key, forKey: .key)
    try container.encode(modifiers, forKey: .modifiers)
    try container.encode(isEnabled, forKey: .isEnabled)
    try container.encodeIfPresent(displayCharacter, forKey: .displayCharacter)
  }

  // MARK: - Equatable Implementation
  /// Equality ignores `displayCharacter` — it's a UI hint, not part of identity.
  /// Two shortcuts with the same carbon keycode + modifiers + enabled state are
  /// the same shortcut regardless of which layout's letter was captured.
  static func == (lhs: ShortcutDefinition, rhs: ShortcutDefinition) -> Bool {
    return lhs.key == rhs.key && lhs.modifiers == rhs.modifiers && lhs.isEnabled == rhs.isEnabled
  }

  // MARK: - Hashable Implementation
  func hash(into hasher: inout Hasher) {
    hasher.combine(key.carbonKeyCode)
    hasher.combine(modifiers.rawValue)
    hasher.combine(isEnabled)
  }

  // MARK: - Layout-aware character lookup
  /// Translates a Carbon virtual key code to the character produced by the
  /// user's *current* keyboard layout (no modifiers). Used as a fallback when a
  /// legacy stored shortcut has no `displayCharacter`. Returns `nil` for
  /// non-printable keys (arrows, function keys, etc.) — caller should fall back
  /// to `Key.displayString` in that case.
  fileprivate static func layoutAwareCharacter(forCarbonKeyCode keyCode: UInt32) -> String? {
    guard let inputSource = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else {
      return nil
    }
    guard let layoutDataPtr = TISGetInputSourceProperty(inputSource, kTISPropertyUnicodeKeyLayoutData)
    else {
      return nil
    }
    let layoutData = Unmanaged<CFData>.fromOpaque(layoutDataPtr).takeUnretainedValue() as Data

    var deadKeyState: UInt32 = 0
    var actualLength = 0
    var chars = [UniChar](repeating: 0, count: 4)

    let status = layoutData.withUnsafeBytes { rawBuf -> OSStatus in
      guard let base = rawBuf.baseAddress else { return -1 }
      let layoutPtr = base.assumingMemoryBound(to: UCKeyboardLayout.self)
      return UCKeyTranslate(
        layoutPtr,
        UInt16(keyCode),
        UInt16(kUCKeyActionDisplay),
        0,  // modifiers (Carbon-style); 0 = no modifiers
        UInt32(LMGetKbdType()),
        UInt32(kUCKeyTranslateNoDeadKeysBit),
        &deadKeyState,
        chars.count,
        &actualLength,
        &chars
      )
    }
    guard status == noErr, actualLength > 0 else { return nil }
    let result = String(utf16CodeUnits: chars, count: actualLength)
    // Only return printable, non-whitespace single characters; otherwise let
    // the caller use Key.displayString (which handles arrows / F-keys / space).
    let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : result
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
    static let toggleMeetingKey = "shortcut_toggle_meeting"
    static let stopMeetingKey = "shortcut_stop_meeting"
    static let openSettingsKey = "shortcut_open_settings"
    static let openChatKey = "shortcut_open_gemini"
    static let screenshotCaptureKey = "shortcut_screenshot_capture"
    static let readAloudKey = "shortcut_read_aloud"
  }

  private let userDefaults = UserDefaults.standard

  private init() {}

  // MARK: - Load/Save Configuration
  func loadConfiguration() -> ShortcutConfig {
    // One-time migration: swap ⌘3/⌘4 so Screenshot=⌘3, Settings=⌘4 —
    // but only for users who actually had the old default Settings=⌘3.
    // Custom Settings shortcuts are left untouched.
    let swapMigrationKey = "shortcut_settings_screenshot_swap_v1"
    if !userDefaults.bool(forKey: swapMigrationKey) {
      saveShortcut(ShortcutConfig.default.screenshotCapture, for: Constants.screenshotCaptureKey)
      let priorSettings = loadShortcut(for: Constants.openSettingsKey)
      let hadDefaultSettingsShortcut =
        priorSettings?.key == .three && priorSettings?.modifiers == [.command]
      if priorSettings == nil || hadDefaultSettingsShortcut {
        saveShortcut(ShortcutConfig.default.openSettings, for: Constants.openSettingsKey)
      }
      userDefaults.set(true, forKey: swapMigrationKey)
    }

    // One-time migration: Read Aloud is restored on ⌘4 and Settings moves to ⌘5.
    // Only move Settings off ⌘4 for users who still had the previous ⌘4 default,
    // so custom Settings shortcuts (e.g. someone bound ⌘8) are preserved.
    let readAloudMigrationKey = "shortcut_read_aloud_v1"
    if !userDefaults.bool(forKey: readAloudMigrationKey) {
      let priorSettings = loadShortcut(for: Constants.openSettingsKey)
      let hadDefaultSettingsOnFour =
        priorSettings?.key == .four && priorSettings?.modifiers == [.command]
      if priorSettings == nil || hadDefaultSettingsOnFour {
        saveShortcut(ShortcutConfig.default.openSettings, for: Constants.openSettingsKey)
      }
      if loadShortcut(for: Constants.readAloudKey) == nil {
        saveShortcut(ShortcutConfig.default.readAloud, for: Constants.readAloudKey)
      }
      userDefaults.set(true, forKey: readAloudMigrationKey)
    }

    // One-time migration: Settings default moves from ⌘5 to ⌘0.
    // Only migrate users who still had the previous ⌘5 default; custom bindings stay.
    let settingsZeroMigrationKey = "shortcut_settings_zero_v1"
    if !userDefaults.bool(forKey: settingsZeroMigrationKey) {
      let priorSettings = loadShortcut(for: Constants.openSettingsKey)
      let hadDefaultSettingsOnFive =
        priorSettings?.key == .five && priorSettings?.modifiers == [.command]
      if priorSettings == nil || hadDefaultSettingsOnFive {
        saveShortcut(ShortcutConfig.default.openSettings, for: Constants.openSettingsKey)
      }
      userDefaults.set(true, forKey: settingsZeroMigrationKey)
    }

    let startRecording =
      loadShortcut(for: Constants.startRecordingKey) ?? ShortcutConfig.default.startRecording
    let stopRecording =
      loadShortcut(for: Constants.stopRecordingKey) ?? ShortcutConfig.default.stopRecording
    let startPrompting =
      loadShortcut(for: Constants.startPromptingKey) ?? ShortcutConfig.default.startPrompting
    let stopPrompting =
      loadShortcut(for: Constants.stopPromptingKey) ?? ShortcutConfig.default.stopPrompting
    let toggleMeeting =
      loadShortcut(for: Constants.toggleMeetingKey) ?? ShortcutConfig.default.toggleMeeting
    let stopMeeting =
      loadShortcut(for: Constants.stopMeetingKey) ?? ShortcutConfig.default.stopMeeting
    let openSettings =
      loadShortcut(for: Constants.openSettingsKey) ?? ShortcutConfig.default.openSettings
    let openChat =
      loadShortcut(for: Constants.openChatKey) ?? ShortcutConfig.default.openChat
    let screenshotCapture =
      loadShortcut(for: Constants.screenshotCaptureKey) ?? ShortcutConfig.default.screenshotCapture
    let readAloud =
      loadShortcut(for: Constants.readAloudKey) ?? ShortcutConfig.default.readAloud
    return ShortcutConfig(
      startRecording: startRecording,
      stopRecording: stopRecording,
      startPrompting: startPrompting,
      stopPrompting: stopPrompting,
      toggleMeeting: toggleMeeting,
      stopMeeting: stopMeeting,
      openSettings: openSettings,
      openChat: openChat,
      screenshotCapture: screenshotCapture,
      readAloud: readAloud
    )
  }

  func saveConfiguration(_ config: ShortcutConfig) {
    saveShortcut(config.startRecording, for: Constants.startRecordingKey)
    saveShortcut(config.stopRecording, for: Constants.stopRecordingKey)
    saveShortcut(config.startPrompting, for: Constants.startPromptingKey)
    saveShortcut(config.stopPrompting, for: Constants.stopPromptingKey)
    saveShortcut(config.toggleMeeting, for: Constants.toggleMeetingKey)
    saveShortcut(config.stopMeeting, for: Constants.stopMeetingKey)
    saveShortcut(config.openSettings, for: Constants.openSettingsKey)
    saveShortcut(config.openChat, for: Constants.openChatKey)
    saveShortcut(config.screenshotCapture, for: Constants.screenshotCaptureKey)
    saveShortcut(config.readAloud, for: Constants.readAloudKey)

    // Post notification for shortcut updates
    NotificationCenter.default.post(name: .shortcutsChanged, object: config)
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
}

// MARK: - Notification Extension
extension Notification.Name {
  static let shortcutsChanged = Notification.Name("shortcutsChanged")
  /// Posted by `ShortcutRecorderRow` when recording begins. `Shortcuts` tears
  /// down its Carbon `RegisterEventHotKey` registrations so the recorder's
  /// `NSEvent` local monitor can actually observe the keystroke — otherwise
  /// Carbon intercepts the event first and fires the global handler.
  static let shortcutRecordingStarted = Notification.Name("shortcutRecordingStarted")
  /// Posted when the recorder closes (success or cancel). `Shortcuts` recreates
  /// the HotKey instances from the current config.
  static let shortcutRecordingStopped = Notification.Name("shortcutRecordingStopped")
  static let modelChanged = Notification.Name("modelChanged")
  /// Posted when API is rate limited and waiting. userInfo contains "waitTime" (TimeInterval)
  static let rateLimitWaiting = Notification.Name("rateLimitWaiting")
  /// Posted when rate limit wait is complete
  static let rateLimitResolved = Notification.Name("rateLimitResolved")
  /// Posted when context file was updated (e.g. from Compare sheet) so General tab can reload
  static let contextFileDidUpdate = Notification.Name("contextFileDidUpdate")
  /// Posted when user chooses Chat → New Chat (menu or shortcut).
  static let chatNewChat = Notification.Name("chatNewChat")
  /// Posted when user chooses Chat → Capture Screenshot (menu or shortcut).
  static let chatCaptureScreenshot = Notification.Name("chatCaptureScreenshot")
  /// Posted when user chooses Chat → Clear Chat (menu or shortcut).
  static let chatClearChat = Notification.Name("chatClearChat")
  /// Posted when user presses Cmd+W in Gemini chat window (close current tab).
  static let chatCloseTab = Notification.Name("chatCloseTab")
  /// Posted when user presses Cmd+Shift+T in the chat window — reopens the most recently closed tab.
  static let chatReopenLastClosedTab = Notification.Name("chatReopenLastClosedTab")
  /// Posted when user presses Cmd+Up in Gemini chat window (scroll to top).
  static let chatScrollToTop = Notification.Name("chatScrollToTop")
  /// Posted when user presses Cmd+Down in Gemini chat window (scroll to bottom).
  static let chatScrollToBottom = Notification.Name("chatScrollToBottom")
  static let chatToggleSidebar = Notification.Name("chatToggleSidebar")
  /// Posted when the chat window is shown so the chat view can focus the message input field.
  static let chatFocusInput = Notification.Name("chatFocusInput")
  /// Posted to switch the chat window to Meeting view (e.g. when a live meeting starts).
  static let chatSwitchToMeeting = Notification.Name("chatSwitchToMeeting")
  /// Posted to switch the chat window to Chat view and resize to one third of the screen.
  static let chatSwitchToChat = Notification.Name("chatSwitchToChat")
  /// Posted to start a fresh live meeting. Clears any prior meeting state first.
  static let chatStartNewMeeting = Notification.Name("chatStartNewMeeting")
  /// Posted to resume a previously stopped live meeting (keeps prior chunks/stem).
  static let chatResumeMeeting = Notification.Name("chatResumeMeeting")
  /// Posted to stop the currently active live meeting.
  static let chatStopLiveMeeting = Notification.Name("chatStopLiveMeeting")
  /// Posted when user confirms "End Meeting" with an optional name. userInfo["meetingName"] = String (default or custom).
  static let chatEndMeetingWithName = Notification.Name("chatEndMeetingWithName")
  /// Posted when user taps Read Aloud under a chat reply. userInfo key: chatReadAloudTextKey (String).
  static let chatReadAloud = Notification.Name("chatReadAloud")
  /// Posted when user taps Stop on the Read Aloud button while TTS is active.
  static let chatReadAloudStop = Notification.Name("chatReadAloudStop")
  /// userInfo key for chatReadAloud notification; value is the reply text (String).
  static let chatReadAloudTextKey = "text"
  /// Posted when TTS synthesis or playback starts (so UI can show "Reading" / "Stop").
  static let ttsDidStart = Notification.Name("ttsDidStart")
  /// Posted when TTS stops (synthesis cancelled, playback stopped, or finished).
  static let ttsDidStop = Notification.Name("ttsDidStop")
}
