import ApplicationServices

/// The character already in the field before Dictate Live's first piece.
///
/// One Accessibility read, 150 ms timeout. Anything that fails — including an app that does not
/// answer — is `.unknown`, and the first piece is spaced exactly as before. The character itself
/// is patient text and is never logged; `CaretContext.logKind` is the label that is.
enum FocusedTextContext {
  enum CaretContext: Equatable {
    case unknown
    case startOfText
    case character(Character)

    /// `unknown`, `start`, `letter`, `space`, `newline`, or `other`. Never the character.
    var logKind: String {
      switch self {
      case .unknown: return "unknown"
      case .startOfText: return "start"
      case .character(let character):
        if character.isLetter { return "letter" }
        if character == " " { return "space" }
        if character.isNewline { return "newline" }
        return "other"
      }
    }
  }

  /// Never throws. The system-wide element and the focused element both time out after 150 ms,
  /// so a hung app cannot stall the start of dictation.
  static func characterBeforeCaret() -> CaretContext {
    let systemWide = AXUIElementCreateSystemWide()
    AXUIElementSetMessagingTimeout(systemWide, 0.15)
    guard let element = focusedElement(from: systemWide) else { return .unknown }
    AXUIElementSetMessagingTimeout(element, 0.15)
    guard let range = selectedTextRange(of: element), range.location >= 0 else { return .unknown }
    if range.location == 0 { return .startOfText }
    let index = range.location - 1
    if let character = character(in: element, utf16Location: index) { return .character(character) }
    if let character = characterFromValue(of: element, utf16Location: index) { return .character(character) }
    return .unknown
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
    return cfRange(from: value)
  }

  /// One UTF-16 unit before the caret, via the parameterized range. Nil when the field does not
  /// support it, so the caller can fall back to the whole value.
  private static func character(in element: AXUIElement, utf16Location: CFIndex) -> Character? {
    guard utf16Location >= 0 else { return nil }
    var range = CFRange(location: utf16Location, length: 1)
    guard let parameter = AXValueCreate(.cfRange, &range) else { return nil }
    var raw: CFTypeRef?
    guard AXUIElementCopyParameterizedAttributeValue(
      element, kAXStringForRangeParameterizedAttribute as CFString, parameter, &raw) == .success,
      let raw, let text = raw as? String
    else { return nil }
    guard let character = text.first, text.dropFirst().isEmpty else { return nil }
    return character
  }

  /// The UTF-16 unit at `utf16Location` in `kAXValueAttribute`. A surrogate half is a failure.
  private static func characterFromValue(of element: AXUIElement, utf16Location: CFIndex) -> Character? {
    guard utf16Location >= 0, let value = copyAttribute(element, kAXValueAttribute), let text = value as? String
    else { return nil }
    let units = text.utf16
    guard utf16Location < units.count else { return nil }
    let unit = units[units.index(units.startIndex, offsetBy: utf16Location)]
    guard let scalar = Unicode.Scalar(unit) else { return nil }
    return Character(scalar)
  }

  private static func copyAttribute(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
    var raw: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success else { return nil }
    return raw
  }

  private static func cfRange(from value: CFTypeRef) -> CFRange? {
    guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    // The type id was just checked.
    // swiftlint:disable:next force_cast
    let axValue = value as! AXValue
    guard AXValueGetType(axValue) == .cfRange else { return nil }
    var range = CFRange()
    guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
    return range
  }
}
