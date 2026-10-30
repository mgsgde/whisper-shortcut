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
    case .space: return String(localized: "Space", comment: "Name of the space bar key in a shortcut")
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
    case .f13: return "F13"
    case .f14: return "F14"
    case .f15: return "F15"
    case .f16: return "F16"
    case .f17: return "F17"
    case .f18: return "F18"
    case .f19: return "F19"
    case .f20: return "F20"
    case .upArrow: return "↑"
    case .downArrow: return "↓"
    case .leftArrow: return "←"
    case .rightArrow: return "→"

    default: return "Key"
    }
  }

  /// Canonical name for the MCP shortcut JSON format (`MCPSettingsCatalog.shortcutDefinition`),
  /// chosen so `Key(string: key.mcpKeyName) == key` always round-trips through `HotKey.Key`'s own
  /// `init(string:)`. Digits and symbols use the token an AI app would naturally send (`"1"`,
  /// `"."`), not the spelled-out alias `init(string:)` also accepts (`"one"`, `"period"`).
  var mcpKeyName: String {
    switch self {
    case .a: return "a"
    case .b: return "b"
    case .c: return "c"
    case .d: return "d"
    case .e: return "e"
    case .f: return "f"
    case .g: return "g"
    case .h: return "h"
    case .i: return "i"
    case .j: return "j"
    case .k: return "k"
    case .l: return "l"
    case .m: return "m"
    case .n: return "n"
    case .o: return "o"
    case .p: return "p"
    case .q: return "q"
    case .r: return "r"
    case .s: return "s"
    case .t: return "t"
    case .u: return "u"
    case .v: return "v"
    case .w: return "w"
    case .x: return "x"
    case .y: return "y"
    case .z: return "z"
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
    case .period: return "."
    case .quote: return "\""
    case .rightBracket: return "]"
    case .semicolon: return ";"
    case .slash: return "/"
    case .backslash: return "\\"
    case .comma: return ","
    case .equal: return "="
    case .grave: return "`"
    case .leftBracket: return "["
    case .minus: return "-"
    case .section: return "section"
    case .space: return "space"
    case .tab: return "tab"
    case .return: return "return"
    case .command: return "command"
    case .rightCommand: return "rightcommand"
    case .option: return "option"
    case .rightOption: return "rightoption"
    case .control: return "control"
    case .rightControl: return "rightcontrol"
    case .shift: return "shift"
    case .rightShift: return "rightshift"
    case .function: return "function"
    case .capsLock: return "capslock"
    case .pageUp: return "pageup"
    case .pageDown: return "pagedown"
    case .home: return "home"
    case .end: return "end"
    case .upArrow: return "uparrow"
    case .rightArrow: return "rightarrow"
    case .downArrow: return "downarrow"
    case .leftArrow: return "leftarrow"
    case .f1: return "f1"
    case .f2: return "f2"
    case .f3: return "f3"
    case .f4: return "f4"
    case .f5: return "f5"
    case .f6: return "f6"
    case .f7: return "f7"
    case .f8: return "f8"
    case .f9: return "f9"
    case .f10: return "f10"
    case .f11: return "f11"
    case .f12: return "f12"
    case .f13: return "f13"
    case .f14: return "f14"
    case .f15: return "f15"
    case .f16: return "f16"
    case .f17: return "f17"
    case .f18: return "f18"
    case .f19: return "f19"
    case .f20: return "f20"
    case .keypad0: return "keypad0"
    case .keypad1: return "keypad1"
    case .keypad2: return "keypad2"
    case .keypad3: return "keypad3"
    case .keypad4: return "keypad4"
    case .keypad5: return "keypad5"
    case .keypad6: return "keypad6"
    case .keypad7: return "keypad7"
    case .keypad8: return "keypad8"
    case .keypad9: return "keypad9"
    case .keypadClear: return "keypadclear"
    case .keypadDecimal: return "keypaddecimal"
    case .keypadDivide: return "keypaddivide"
    case .keypadEnter: return "keypadenter"
    case .keypadEquals: return "keypadequals"
    case .keypadMinus: return "keypadminus"
    case .keypadMultiply: return "keypadmultiply"
    case .keypadPlus: return "keypadplus"
    case .escape: return "escape"
    case .delete: return "delete"
    case .forwardDelete: return "forwarddelete"
    case .help: return "help"
    case .volumeUp: return "volumeup"
    case .volumeDown: return "volumedown"
    case .mute: return "mute"
    default: return "a"
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
/// Persisted shortcut bindings. Each field maps to exactly one Carbon `HotKey` registered by
/// `Shortcuts.swift`; toggling on/off is handled inside the delegate, so there is no separate
/// "stop" binding. Previously this struct had `stopRecording` / `stopPrompting` / `toggleMeeting`
/// / `stopMeeting` siblings — they were never read after the toggle redesign and have been
/// dropped. Existing UserDefaults entries for those keys are left in place (harmless).
struct ShortcutConfig: Codable, Equatable {
  var startRecording: ShortcutDefinition
  var startPrompting: ShortcutDefinition
  var openSettings: ShortcutDefinition
  var openChat: ShortcutDefinition
  var screenshotCapture: ShortcutDefinition
  var readAloud: ShortcutDefinition
  /// Appends the current selection to the Glossary. Ships disabled: the key and modifiers are only
  /// the suggested binding, the user turns it on in Settings.
  var addToGlossary: ShortcutDefinition

  /// Defaults for new installs: ⌃⌥ + digit. ⌘1/⌘2/⌘3 switch tabs in every browser, Slack, VS Code
  /// and Finder, so a new user's first ⌘1 often switched a tab instead of dictating
  /// (improvement-plan-2026-09 O14). Chat keeps ⌥Space. Installs that ran an earlier version keep
  /// `legacyCommandDigit` — see the pin in `ShortcutConfigManager.loadConfiguration`.
  static let `default` = ShortcutConfig(
    startRecording: ShortcutDefinition(key: .one, modifiers: [.control, .option]),
    startPrompting: ShortcutDefinition(key: .two, modifiers: [.control, .option]),
    openSettings: ShortcutDefinition(key: .zero, modifiers: [.control, .option], isEnabled: true),
    openChat: ShortcutDefinition(key: .space, modifiers: [.option], isEnabled: true),
    screenshotCapture: ShortcutDefinition(key: .three, modifiers: [.control, .option], isEnabled: true),
    readAloud: ShortcutDefinition(key: .four, modifiers: [.control, .option], isEnabled: true),
    addToGlossary: ShortcutDefinition(key: .seven, modifiers: [.control, .option], isEnabled: false)
  )

  /// The ⌘-digit defaults every install before the ⌃⌥ switch was running on.
  static let legacyCommandDigit = ShortcutConfig(
    startRecording: ShortcutDefinition(key: .one, modifiers: [.command]),
    startPrompting: ShortcutDefinition(key: .two, modifiers: [.command]),
    openSettings: ShortcutDefinition(key: .zero, modifiers: [.command], isEnabled: true),
    openChat: ShortcutDefinition(key: .space, modifiers: [.option], isEnabled: true),
    screenshotCapture: ShortcutDefinition(key: .three, modifiers: [.command], isEnabled: true),
    readAloud: ShortcutDefinition(key: .four, modifiers: [.command], isEnabled: true),
    addToGlossary: ShortcutDefinition(key: .seven, modifiers: [.command], isEnabled: false)
  )
}

/// One shortcut-bound feature, and whether this build ships it.
///
/// The menu, Settings, onboarding and Chat each kept their own copy of this list. They had
/// already drifted: `assistantFacingRows` still told the App Store Chat that Read Aloud has a
/// shortcut, while the menu, the keyboard section and the onboarding Done step all hide it
/// there. Add to Glossary is not a case — the assistant list, the onboarding feature list,
/// the empty-state hints and the three onboarding recorders never included it, in any build.
/// The menu title "Add Selection to Glossary" and the Settings label "Add to Glossary:" stay
/// on those two surfaces, behind the same App Store exclusion.
enum ShortcutAction: CaseIterable {
  case dictate
  case dictatePrompt
  case screenshot
  case readAloud
  case chat
  case settings

  /// The name the assistant-facing list uses. A surface whose label differs on purpose
  /// (the menu's "Settings…", Settings' "Open Chat:") keeps that string locally.
  var title: String {
    switch self {
    case .dictate: return "Dictate"
    case .dictatePrompt: return "Dictate Prompt"
    case .screenshot: return "Screenshot"
    case .readAloud: return "Read Aloud"
    case .chat: return "Chat"
    case .settings: return "Settings"
    }
  }

  /// `title` for on-screen labels. `title` itself stays English because the assistant-facing
  /// list is model input, not UI.
  var localizedTitle: LocalizedStringResource {
    switch self {
    case .dictate: return "Dictate"
    case .dictatePrompt: return "Dictate Prompt"
    case .screenshot: return "Screenshot"
    case .readAloud: return "Read Aloud"
    case .chat: return "Chat"
    case .settings: return "Settings"
    }
  }

  var keyPath: KeyPath<ShortcutConfig, ShortcutDefinition> {
    switch self {
    case .dictate: return \.startRecording
    case .dictatePrompt: return \.startPrompting
    case .screenshot: return \.screenshotCapture
    case .readAloud: return \.readAloud
    case .chat: return \.openChat
    case .settings: return \.openSettings
    }
  }

  /// Read Aloud copies the selection with ⌘C, which needs Accessibility. The App Store build
  /// has no menu item and no hotkey for it, so nothing in that build may advertise the shortcut.
  var isInThisBuild: Bool {
    switch self {
    case .readAloud:
      #if APP_STORE
      return false
      #else
      return true
      #endif
    case .dictate, .dictatePrompt, .screenshot, .chat, .settings:
      return true
    }
  }
}

extension ShortcutConfig {
  /// Read Aloud copies the selection with ⌘C, which needs Accessibility. The App Store build
  /// has no menu item and no hotkey for it, so nothing in that build may advertise the shortcut
  /// (`ShortcutAction.readAloud.isInThisBuild`). Add to Glossary is hidden there the same way.
  /// Conflict checks walk every enabled slot, so a stored binding would be reported as already
  /// used for a combination the user cannot see or free. Those two come back disabled; the
  /// stored bindings are left as saved.
  static func availableInThisBuild(_ config: ShortcutConfig, isAppStore: Bool) -> ShortcutConfig {
    guard isAppStore else { return config }
    func disabled(_ definition: ShortcutDefinition) -> ShortcutDefinition {
      ShortcutDefinition(
        key: definition.key, modifiers: definition.modifiers,
        isEnabled: false, displayCharacter: definition.displayCharacter)
    }
    var available = config
    available.readAloud = disabled(config.readAloud)
    available.addToGlossary = disabled(config.addToGlossary)
    return available
  }

  /// The shortcuts both the online and the offline Chat tell the model about.
  ///
  /// `ShortcutAction.allCases` filtered to this build, in that order — the order this list
  /// had when it was written out by hand, minus Read Aloud in the App Store build. A disabled
  /// definition still renders as "Disabled" via `displayStringWithSeparator`.
  var assistantFacingRows: [(action: String, definition: ShortcutDefinition)] {
    ShortcutAction.allCases.filter(\.isInThisBuild).map { action in
      (action.title, self[keyPath: action.keyPath])
    }
  }
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
      return String(localized: "Disabled")
    }

    var parts: [String] = []

    if modifiers.contains(.command) { parts.append("⌘") }
    if modifiers.contains(.option) { parts.append("⌥") }
    if modifiers.contains(.control) { parts.append("⌃") }
    if modifiers.contains(.shift) { parts.append("⇧") }

    if let ch = displayCharacter, Self.isPrintableCharacter(ch) {
      parts.append(ch.uppercased())
    } else if let layoutChar = Self.layoutAwareCharacter(forCarbonKeyCode: key.carbonKeyCode),
      Self.isPrintableCharacter(layoutChar)
    {
      parts.append(layoutChar.uppercased())
    } else {
      parts.append(key.displayString)
    }

    return parts.joined(separator: separator)
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

  /// Whether a captured character is something we can actually show as the key's label.
  /// Non-typing keys report placeholders instead of glyphs: `charactersIgnoringModifiers`
  /// returns AppKit's private-use scalars for function keys (F17 → U+F712), and Space
  /// returns " ", which renders as an empty shortcut. Rejecting those makes
  /// `renderShortcut` fall back to `Key.displayString` ("F17", "Space").
  fileprivate static func isPrintableCharacter(_ text: String) -> Bool {
    guard !text.isEmpty else { return false }
    return text.unicodeScalars.allSatisfy { scalar in
      !CharacterSet.controlCharacters.contains(scalar)
        && !CharacterSet.whitespacesAndNewlines.contains(scalar)
        && !(0xE000...0xF8FF).contains(scalar.value)  // Unicode private use area
    }
  }

  // MARK: - Layout-aware character lookup
  /// Translates a Carbon virtual key code to the character produced by the
  /// user's *current* keyboard layout (no modifiers). Used as a fallback when a
  /// legacy stored shortcut has no `displayCharacter`. Returns `nil` for
  /// non-printable keys (arrows, function keys, etc.) — caller should fall back
  /// to `Key.displayString` in that case.
  /// Caches the keyboard layout, because HIToolbox refuses to be called off the main queue.
  ///
  /// `TISGetInputSourceProperty` does not merely dislike concurrency — it calls
  /// `dispatch_assert_queue` and traps when it is not on the main queue. From the CI crash
  /// report (`EXC_BREAKPOINT`/`SIGTRAP`, thread `com.apple.root.user-initiated-qos.cooperative`):
  ///
  ///     _dispatch_assert_queue_fail
  ///     dispatch_assert_queue
  ///     HIToolbox  islGetInputSourceListWithAdditions
  ///     HIToolbox  isValidateInputSourceRef
  ///     HIToolbox  TSMGetInputSourceProperty
  ///     ShortcutDefinition.layoutAwareCharacter(forCarbonKeyCode:)
  ///     ShortcutDefinition.displayString.getter
  ///
  /// The `NSLock` this replaces (v8.09) was the wrong half of the fix: serializing the calls
  /// removed the earlier `abort()` inside the input-source list, but a lock cannot put a
  /// cooperative thread on the main queue, so a rarer trap took its place. Same test, same
  /// symptom — the host dies and xcodebuild blames whichever test last completed.
  ///
  /// A cache rather than a `DispatchQueue.main.sync` hop, deliberately: this sits on a render
  /// path that SwiftUI touches for every menu item, and this app already has a main-thread
  /// watchdog and a history of hangs. Blocking the caller on main is how those start. The cache
  /// stays live because a layout switch posts
  /// `kTISNotifySelectedKeyboardInputSourceChanged`, which clears it.
  ///
  /// Off the main queue with a cold cache, this returns `nil` and the caller falls back to
  /// `Key.displayString` — an outcome the contract already allows — and warms the cache for the
  /// next render. In the app the first render is on the main thread, so that path is the
  /// exception rather than the rule.
  private static let layoutLock = NSLock()
  private static var cachedLayoutData: Data?
  private static var layoutObserverInstalled = false

  /// Must run on the main thread. Reads the live layout and refreshes the cache.
  ///
  /// Returns `nil` rather than asserting when called from anywhere else. `dispatchPrecondition`
  /// would be the conventional guard here and is deliberately not used: it traps, and adding a
  /// second trap to the render path whose only bug is a trap trades one crash for another.
  private static func refreshLayoutDataOnMain() -> Data? {
    guard Thread.isMainThread else { return nil }
    if !layoutObserverInstalled {
      layoutObserverInstalled = true
      // Distributed, not the local center: the input-source change is posted process-externally.
      DistributedNotificationCenter.default().addObserver(
        forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
        object: nil,
        queue: .main
      ) { _ in
        layoutLock.lock()
        cachedLayoutData = nil
        layoutLock.unlock()
      }
    }
    guard let inputSource = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
      let layoutDataPtr = TISGetInputSourceProperty(inputSource, kTISPropertyUnicodeKeyLayoutData)
    else {
      return nil
    }
    let data = Unmanaged<CFData>.fromOpaque(layoutDataPtr).takeUnretainedValue() as Data
    layoutLock.lock()
    cachedLayoutData = data
    layoutLock.unlock()
    return data
  }

  private static func currentLayoutData() -> Data? {
    layoutLock.lock()
    let cached = cachedLayoutData
    layoutLock.unlock()
    if let cached { return cached }

    if Thread.isMainThread { return refreshLayoutDataOnMain() }
    // Off the main queue we may not touch TIS at all. Warm the cache for the next render and let
    // this one fall back to `Key.displayString`.
    DispatchQueue.main.async { _ = refreshLayoutDataOnMain() }
    return nil
  }

  fileprivate static func layoutAwareCharacter(forCarbonKeyCode keyCode: UInt32) -> String? {
    guard let layoutData = currentLayoutData() else { return nil }

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
    static let startPromptingKey = "shortcut_start_prompting"
    static let openSettingsKey = "shortcut_open_settings"
    static let openChatKey = "shortcut_open_gemini"
    static let screenshotCaptureKey = "shortcut_screenshot_capture"
    static let readAloudKey = "shortcut_read_aloud"
    static let addToGlossaryKey = "shortcut_add_to_glossary"
  }

  private let userDefaults = UserDefaults.standard

  private init() {}

  // MARK: - Load/Save Configuration
  func loadConfiguration() -> ShortcutConfig {
    // Pin existing installs to the ⌘-digit shortcuts before the defaults below resolve to ⌃⌥.
    // Most users never saved a binding (unset = "use the default"), so without this every update
    // would silently move their muscle-memory shortcuts. "Existing" = an earlier version already
    // ran its shortcut migrations, or the user finished onboarding. A fresh install has neither and
    // gets the new defaults. Runs once.
    let ctrlOptionPinKey = "shortcut_defaults_ctrl_option_v1"
    if !userDefaults.bool(forKey: ctrlOptionPinKey) {
      let ranBefore = userDefaults.bool(forKey: "shortcut_settings_screenshot_swap_v1")
        || userDefaults.bool(forKey: UserDefaultsKeys.hasCompletedOnboarding)
      if ranBefore {
        let legacy = ShortcutConfig.legacyCommandDigit
        let pins: [(String, ShortcutDefinition)] = [
          (Constants.startRecordingKey, legacy.startRecording),
          (Constants.startPromptingKey, legacy.startPrompting),
          (Constants.openSettingsKey, legacy.openSettings),
          (Constants.openChatKey, legacy.openChat),
          (Constants.screenshotCaptureKey, legacy.screenshotCapture),
          (Constants.readAloudKey, legacy.readAloud),
          (Constants.addToGlossaryKey, legacy.addToGlossary),
        ]
        for (key, shortcut) in pins where loadShortcut(for: key) == nil {
          saveShortcut(shortcut, for: key)
        }
        DebugLogger.log("SHORTCUTS: existing install — unset shortcuts pinned to the ⌘-digit defaults")
      }
      userDefaults.set(true, forKey: ctrlOptionPinKey)
    }

    // One-time migration: swap ⌘3/⌘4 so Screenshot=⌘3, Settings=⌘4 —
    // but only for users who actually had the old default Settings=⌘3.
    // Custom Settings shortcuts are left untouched.
    let swapMigrationKey = "shortcut_settings_screenshot_swap_v1"
    if !userDefaults.bool(forKey: swapMigrationKey) {
      saveShortcut(ShortcutConfig.default.screenshotCapture, for: Constants.screenshotCaptureKey)
      resetSettingsIfStillOnOldDefault(oldKey: .three)
      userDefaults.set(true, forKey: swapMigrationKey)
    }

    // One-time migration: Read Aloud is restored on ⌘4 and Settings moves to ⌘5.
    // Only move Settings off ⌘4 for users who still had the previous ⌘4 default,
    // so custom Settings shortcuts (e.g. someone bound ⌘8) are preserved.
    let readAloudMigrationKey = "shortcut_read_aloud_v1"
    if !userDefaults.bool(forKey: readAloudMigrationKey) {
      resetSettingsIfStillOnOldDefault(oldKey: .four)
      if loadShortcut(for: Constants.readAloudKey) == nil {
        saveShortcut(ShortcutConfig.default.readAloud, for: Constants.readAloudKey)
      }
      userDefaults.set(true, forKey: readAloudMigrationKey)
    }

    // One-time migration: Settings default moves from ⌘5 to ⌘0.
    // Only migrate users who still had the previous ⌘5 default; custom bindings stay.
    let settingsZeroMigrationKey = "shortcut_settings_zero_v1"
    if !userDefaults.bool(forKey: settingsZeroMigrationKey) {
      resetSettingsIfStillOnOldDefault(oldKey: .five)
      userDefaults.set(true, forKey: settingsZeroMigrationKey)
    }

    let startRecording =
      loadShortcut(for: Constants.startRecordingKey) ?? ShortcutConfig.default.startRecording
    let startPrompting =
      loadShortcut(for: Constants.startPromptingKey) ?? ShortcutConfig.default.startPrompting
    let openSettings =
      loadShortcut(for: Constants.openSettingsKey) ?? ShortcutConfig.default.openSettings
    let openChat =
      loadShortcut(for: Constants.openChatKey) ?? ShortcutConfig.default.openChat
    let screenshotCapture =
      loadShortcut(for: Constants.screenshotCaptureKey) ?? ShortcutConfig.default.screenshotCapture
    let readAloud =
      loadShortcut(for: Constants.readAloudKey) ?? ShortcutConfig.default.readAloud
    let addToGlossary =
      loadShortcut(for: Constants.addToGlossaryKey) ?? ShortcutConfig.default.addToGlossary
    let loaded = ShortcutConfig(
      startRecording: startRecording,
      startPrompting: startPrompting,
      openSettings: openSettings,
      openChat: openChat,
      screenshotCapture: screenshotCapture,
      readAloud: readAloud,
      addToGlossary: addToGlossary
    )
    // Filter the value callers read. Writing the disabled flags back would clear a binding
    // the direct download still uses — both builds share these defaults.
    #if APP_STORE
    return ShortcutConfig.availableInThisBuild(loaded, isAppStore: true)
    #else
    return ShortcutConfig.availableInThisBuild(loaded, isAppStore: false)
    #endif
  }

  func saveConfiguration(_ config: ShortcutConfig) {
    saveShortcut(config.startRecording, for: Constants.startRecordingKey)
    saveShortcut(config.startPrompting, for: Constants.startPromptingKey)
    saveShortcut(config.openSettings, for: Constants.openSettingsKey)
    saveShortcut(config.openChat, for: Constants.openChatKey)
    saveShortcut(config.screenshotCapture, for: Constants.screenshotCaptureKey)
    saveShortcut(config.readAloud, for: Constants.readAloudKey)
    saveShortcut(config.addToGlossary, for: Constants.addToGlossaryKey)

    // Post notification for shortcut updates
    NotificationCenter.default.post(name: .shortcutsChanged, object: config)
  }

  // MARK: - Private Helper Methods
  /// Resets the Settings binding to the current default, but only when the user is still on a
  /// previously shipped default (`oldKey`+⌘) or has no binding — custom bindings are preserved.
  private func resetSettingsIfStillOnOldDefault(oldKey: Key) {
    let prior = loadShortcut(for: Constants.openSettingsKey)
    let onOldDefault = prior?.key == oldKey && prior?.modifiers == [.command]
    if prior == nil || onOldDefault {
      saveShortcut(ShortcutConfig.default.openSettings, for: Constants.openSettingsKey)
    }
  }

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
  /// Posted when the Dictate Prompt / Chat prompt model selection changes.
  static let promptModelChanged = Notification.Name("promptModelChanged")
  /// Posted when `ModelSelectionReconciler` rewrote persisted model selections (Offline Mode
  /// switched, an API key added), so views holding a copy reload it.
  static let modelSelectionsReconciled = Notification.Name("modelSelectionsReconciled")
  /// Posted when API is rate limited and waiting. userInfo contains "waitTime" (TimeInterval)
  static let rateLimitWaiting = Notification.Name("rateLimitWaiting")
  /// Posted when rate limit wait is complete
  static let rateLimitResolved = Notification.Name("rateLimitResolved")
  /// Posted when context file was updated (e.g. from Compare sheet) so General tab can reload
  static let contextFileDidUpdate = Notification.Name("contextFileDidUpdate")
  /// Posted when the chat memory file (UserContext/memory.md) changes, so the Settings editor reloads.
  static let chatMemoryDidUpdate = Notification.Name("chatMemoryDidUpdate")
  static let workspaceMapDidUpdate = Notification.Name("workspaceMapDidUpdate")
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
  /// Posted after a meeting's final summary is written to disk. userInfo: ["stem": String, "summary": String].
  static let chatMeetingSummaryReady = Notification.Name("chatMeetingSummaryReady")
  /// Posted by a consumer that wants the live notes brought up to date right now for the active
  /// meeting (the user just sent a chat message). MenuBarController forwards it to the session.
  static let liveMeetingNotesRefreshRequested = Notification.Name("liveMeetingNotesRefreshRequested")
  /// Posted when the chat window becomes visible or hidden. userInfo["visible"] = Bool. Drives the
  /// live meeting's chunk cadence — fast while someone is watching, configured otherwise.
  static let chatWindowVisibilityChanged = Notification.Name("chatWindowVisibilityChanged")
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
