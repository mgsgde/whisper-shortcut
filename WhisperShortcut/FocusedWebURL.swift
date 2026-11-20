import ApplicationServices
import Foundation

/// The URL of the browser tab the user is typing in.
///
/// One Accessibility walk from the focused element up to an `AXWebArea`, with the same 150 ms
/// messaging timeout as `FocusedTextContext`. The walk stops after 40 parents or about 0.3 s.
/// The URL is never logged. Any failure returns nil, and nothing here throws.
enum FocusedWebURL {
  private static let messagingTimeout: Float = 0.15
  private static let walkBudget: CFAbsoluteTime = 0.3
  private static let maxParentSteps = 40

  static func current() -> URL? {
    let deadline = CFAbsoluteTimeGetCurrent() + walkBudget
    let systemWide = AXUIElementCreateSystemWide()
    AXUIElementSetMessagingTimeout(systemWide, messagingTimeout)
    guard let focused = focusedElement(from: systemWide) else { return nil }
    AXUIElementSetMessagingTimeout(focused, messagingTimeout)
    if let url = url(of: focused) { return url }

    var element = focused
    for _ in 0..<maxParentSteps {
      guard CFAbsoluteTimeGetCurrent() < deadline else { return nil }
      guard let parent = parent(of: element) else { return nil }
      AXUIElementSetMessagingTimeout(parent, messagingTimeout)
      if role(of: parent) == "AXWebArea" {
        return url(of: parent)
      }
      element = parent
    }
    return nil
  }

  private static func focusedElement(from systemWide: AXUIElement) -> AXUIElement? {
    guard let value = copyAttribute(systemWide, kAXFocusedUIElementAttribute) else { return nil }
    guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    // The type id was just checked.
    // swiftlint:disable:next force_cast
    return (value as! AXUIElement)
  }

  private static func parent(of element: AXUIElement) -> AXUIElement? {
    guard let value = copyAttribute(element, kAXParentAttribute) else { return nil }
    guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    // The type id was just checked.
    // swiftlint:disable:next force_cast
    return (value as! AXUIElement)
  }

  private static func role(of element: AXUIElement) -> String? {
    copyAttribute(element, kAXRoleAttribute) as? String
  }

  /// `kAXURLAttribute` ("AXURL") is a CFURL. Nil for every other type.
  private static func url(of element: AXUIElement) -> URL? {
    guard let value = copyAttribute(element, kAXURLAttribute) else { return nil }
    if let url = value as? URL { return url }
    guard CFGetTypeID(value) == CFURLGetTypeID() else { return nil }
    // The type id was just checked.
    // swiftlint:disable:next force_cast
    return (value as! CFURL) as URL
  }

  private static func copyAttribute(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
    var raw: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success else { return nil }
    return raw
  }
}
