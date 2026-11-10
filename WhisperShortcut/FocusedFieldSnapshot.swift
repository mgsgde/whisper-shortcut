import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Text already in the focused field when Dictate Prompt's shortcut was pressed.
///
/// Read once, off the main thread, with the same 150 ms Accessibility timeout as
/// `FocusedTextContext`. The text is context for the model and is never logged.
struct FocusedFieldSnapshot: Equatable, Sendable {
  let appName: String?
  /// At most 3000 characters, cut at the start (the end, nearest the caret, is kept).
  let textBeforeCaret: String
  /// At most 1000 characters, cut at the end (the start, nearest the caret, is kept).
  let textAfterCaret: String

  var totalCount: Int { textBeforeCaret.count + textAfterCaret.count }

  static let beforeLimit = 3000
  static let afterLimit = 1000

  /// Password managers. Their window is not a fallback image either.
  static let excludedBundleIDs: Set<String> = [
    "com.1password.1password",
    "com.agilebits.onepassword7",
    "com.bitwarden.desktop",
    "com.apple.keychainaccess",
    "com.apple.Passwords",
    "org.keepassxc.keepassxc",
    "com.dashlane.Dashlane",
    "me.proton.pass.electron",
    "com.markmcguill.strongbox.mac",
    "in.sinew.Enpass-Desktop",
    "com.hicknhacksoftware.MacPass",
  ]

  static func isExcluded(bundleID: String?) -> Bool {
    guard let bundleID else { return false }
    return excludedBundleIDs.contains(bundleID)
  }

  /// The frontmost app is a password manager. `SpeechService` has no AppKit import, so the
  /// bundle-id read stays here.
  static var frontmostIsExcluded: Bool {
    isExcluded(bundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
  }

  /// Keeps the `beforeLimit` characters nearest the caret and the `afterLimit` characters
  /// nearest the caret.
  static func clip(before: String, after: String) -> (before: String, after: String) {
    let clippedBefore = before.count > beforeLimit ? String(before.suffix(beforeLimit)) : before
    let clippedAfter = after.count > afterLimit ? String(after.prefix(afterLimit)) : after
    return (clippedBefore, clippedAfter)
  }

  /// Splits `text` at a UTF-16 caret. No location, an out-of-range location, or a location that
  /// falls inside a surrogate pair: the whole text counts as before the caret.
  static func splitAtCaret(text: String, utf16Location: Int?) -> (before: String, after: String) {
    guard let utf16Location, utf16Location >= 0 else { return (text, "") }
    let units = text.utf16
    guard utf16Location <= units.count else { return (text, "") }
    let unitIndex = units.index(units.startIndex, offsetBy: utf16Location)
    guard let index = unitIndex.samePosition(in: text) else { return (text, "") }
    return (String(text[..<index]), String(text[index...]))
  }

  /// The focused field, or nil when it cannot be read. Never throws. Safe off the main thread.
  static func read() -> FocusedFieldSnapshot? {
    readResult().snapshot
  }

  /// Same read as `read()`, plus why it failed and whether a window image is still allowed.
  /// A password field or password manager is not an image fallback.
  static func readResult() -> ReadResult {
    let frontmost = NSWorkspace.shared.frontmostApplication
    let bundleID = frontmost?.bundleIdentifier
    if let bundleID, let ownBundleID = Bundle.main.bundleIdentifier, bundleID == ownBundleID {
      return ReadResult(snapshot: nil, bundleID: bundleID, reason: "own app", allowsWindowImage: true)
    }
    if isExcluded(bundleID: bundleID) {
      return ReadResult(snapshot: nil, bundleID: bundleID, reason: "password manager", allowsWindowImage: false)
    }
    if IsSecureEventInputEnabled() {
      return ReadResult(snapshot: nil, bundleID: bundleID, reason: "secure input", allowsWindowImage: false)
    }

    let systemWide = AXUIElementCreateSystemWide()
    AXUIElementSetMessagingTimeout(systemWide, 0.15)
    guard let element = focusedElement(from: systemWide) else {
      return ReadResult(snapshot: nil, bundleID: bundleID, reason: "no focused element", allowsWindowImage: true)
    }
    AXUIElementSetMessagingTimeout(element, 0.15)
    if copyAttribute(element, kAXSubroleAttribute) as? String == kAXSecureTextFieldSubrole as String {
      return ReadResult(snapshot: nil, bundleID: bundleID, reason: "secure field", allowsWindowImage: false)
    }
    guard let value = copyAttribute(element, kAXValueAttribute), let text = value as? String else {
      return ReadResult(snapshot: nil, bundleID: bundleID, reason: "value not text", allowsWindowImage: true)
    }

    let caret: Int? = {
      guard let range = selectedTextRange(of: element), range.location >= 0 else { return nil }
      return range.location
    }()
    let split = splitAtCaret(text: text, utf16Location: caret)
    let clipped = clip(before: split.before, after: split.after)
    return ReadResult(
      snapshot: FocusedFieldSnapshot(
        appName: frontmost?.localizedName,
        textBeforeCaret: clipped.before,
        textAfterCaret: clipped.after),
      bundleID: bundleID,
      reason: "field",
      allowsWindowImage: true)
  }

  struct ReadResult: Sendable {
    let snapshot: FocusedFieldSnapshot?
    let bundleID: String?
    let reason: String
    /// False for a password field, secure input, or a password manager. Those are not an image fallback.
    let allowsWindowImage: Bool
  }

  private static func focusedElement(from systemWide: AXUIElement) -> AXUIElement? {
    guard let value = copyAttribute(systemWide, kAXFocusedUIElementAttribute) else { return nil }
    guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    // The type id was just checked.
    // swiftlint:disable:next force_cast
    return (value as! AXUIElement)
  }

  private static func selectedTextRange(of element: AXUIElement) -> CFRange? {
    guard let value = copyAttribute(element, kAXSelectedTextRangeAttribute) else { return nil }
    guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    // The type id was just checked.
    // swiftlint:disable:next force_cast
    let axValue = value as! AXValue
    guard AXValueGetType(axValue) == .cfRange else { return nil }
    var range = CFRange()
    guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
    return range
  }

  private static func copyAttribute(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
    var raw: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success else { return nil }
    return raw
  }
}

/// Whether a Dictate Prompt compose turn still needs a picture of the front window, and the
/// text block that replaces that picture when the field already has text.
enum PromptScreenContextDecision {
  static let minimumFieldChars = 200

  /// True only for a compose turn that is not a template, with the setting on, a model that
  /// accepts images, and a field that is missing or shorter than `minimumFieldChars`.
  static func wantsWindowImage(
    isComposeTurn: Bool,
    field: FocusedFieldSnapshot?,
    settingEnabled: Bool,
    modelAcceptsImages: Bool,
    isTemplate: Bool
  ) -> Bool {
    guard isComposeTurn, !isTemplate, settingEnabled, modelAcceptsImages else { return false }
    if let field, field.totalCount >= minimumFieldChars { return false }
    return true
  }

  /// The field as the payload may see it: nil unless the user opted in to sending field text.
  static func effectiveField(_ field: FocusedFieldSnapshot?, fieldTextEnabled: Bool) -> FocusedFieldSnapshot? {
    fieldTextEnabled ? field : nil
  }

  /// Context block for a compose turn whose field has text. Nil on a template turn (a template
  /// writes a fixed format from what was spoken; the field must not leak into it), an edit turn,
  /// with no field, or when the field is empty.
  /// Also nil when the user has not opted in to sending field text (`fieldTextEnabled`).
  static func fieldBlock(
    _ field: FocusedFieldSnapshot?, isComposeTurn: Bool, isTemplate: Bool, fieldTextEnabled: Bool
  ) -> String? {
    guard fieldTextEnabled, !isTemplate, isComposeTurn, let field, field.totalCount > 0 else { return nil }
    let trimmed = field.appName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let app = trimmed.isEmpty ? "unknown" : trimmed
    return "TEXT FIELD THE RESULT WILL BE INSERTED INTO (app: \(app)). Context only: match its language, tone and names, and continue or answer it. Do not repeat it. [CURSOR] marks where the result goes:\n\(field.textBeforeCaret)[CURSOR]\(field.textAfterCaret)"
  }
}
