import AppKit
import ApplicationServices
import Foundation

/// Manages accessibility permissions and user guidance for WhisperShortcut
class AccessibilityPermissionManager {

  /// Which feature is asking, so the dialog names that feature and why it needs Accessibility.
  enum AccessibilityPurpose {
    case autoPaste, dictateLive, dictatePrompt, glossary, readAloud, fnKey

    var featureName: String {
      switch self {
      case .autoPaste:
        // Catalog name of the feature is "Auto-paste" → "Automatisch einfügen".
        return String(localized: "Auto-Paste")
      case .dictateLive:
        return String(localized: "Dictate Live")
      case .dictatePrompt:
        return String(localized: "Dictate Prompt")
      case .glossary:
        return String(localized: "Add to Glossary")
      case .readAloud:
        return String(localized: "Read Aloud")
      case .fnKey:
        return String(localized: "Fn key dictation")
      }
    }

    var reason: String {
      switch self {
      case .autoPaste:
        return String(localized: "paste dictated text at your cursor")
      case .dictateLive:
        return String(localized: "type your words live into the app you are using")
      case .dictatePrompt, .readAloud:
        return String(localized: "read the text you selected")
      case .glossary:
        return String(localized: "read the word you selected")
      case .fnKey:
        return String(localized: "notice when you press the Fn key")
      }
    }
  }

  /// Checks if the app has accessibility permissions (pure check, never prompts).
  static func hasAccessibilityPermission() -> Bool {
    // Test profile only (`--accessibility`): every reader sees the same state as the screens.
    if let overridden = TestProfileOverrides.current.accessibility { return overridden == .granted }
    return AXIsProcessTrusted()
  }

  /// Triggers the native macOS Accessibility prompt. This also pre-registers WhisperShortcut in
  /// the Accessibility list in System Settings, so the user only has to flip the switch instead of
  /// manually adding the app via "+". macOS won't re-show the prompt after a denial. The flag
  /// records that this ran so a later attempt can follow with our own dialog; it does not decide
  /// whether macOS is asked — every attempt calls this, which re-lists the app after a reset or
  /// a build switch.
  @discardableResult
  static func requestAccessibilityPermission() -> Bool {
    UserDefaults.standard.set(true, forKey: UserDefaultsKeys.hasShownAccessibilityPrompt)
    return PermissionStatusChecker.requestAccessibilityAccess()
  }

  /// Re-lists the app (for example after a reset or a build switch), then explains why this
  /// feature needs Accessibility. No-op when already trusted.
  static func showAccessibilityPermissionDialog(for purpose: AccessibilityPurpose = .autoPaste) {
    _ = PermissionStatusChecker.requestAccessibilityAccess()
    if hasAccessibilityPermission() {
      return
    }

    let alert = NSAlert()
    alert.messageText = String(localized: "Allow Accessibility for \(purpose.featureName)")
    alert.informativeText = String(localized: """
      macOS needs this so WhisperShortcut can \(purpose.reason). Turn on WhisperShortcut in the list that opens.

      Already on but still not working? Turn it off and on again. If that doesn't help, select WhisperShortcut, remove it with −, and use the feature again.
      """)
    alert.alertStyle = .informational
    alert.addButton(withTitle: String(localized: "Open System Settings"))
    alert.addButton(withTitle: String(localized: "Not Now"))

    if alert.runModal() == .alertFirstButtonReturn {
      PermissionStatusChecker.openSystemSettings(for: .accessibility)
    }
  }

  /// Marks that the user has used the prompt feature
  static func markPromptFeatureUsed() {
    UserDefaults.standard.set(true, forKey: UserDefaultsKeys.hasUsedPromptFeature)
  }

  /// Always asks macOS first: that call is what lists the app, and macOS shows nothing after a
  /// prior denial. Our own dialog follows only when the prompt flag was already set before this
  /// call. The flag no longer decides whether macOS is asked.
  private static func requestOrDeepLink(purpose: AccessibilityPurpose) {
    let alreadyPrompted = UserDefaults.standard.bool(forKey: UserDefaultsKeys.hasShownAccessibilityPrompt)
    requestAccessibilityPermission()
    if alreadyPrompted {
      showAccessibilityPermissionDialog(for: purpose)
    }
  }

  /// Use-time path: no-op when Accessibility is already granted, otherwise the shared request rule.
  static func requestAtUseTime(for purpose: AccessibilityPurpose) {
    guard !hasAccessibilityPermission() else { return }
    requestOrDeepLink(purpose: purpose)
  }

  /// Requests Accessibility the moment the user opts into a feature that needs it (e.g. enabling
  /// auto-paste), so the system prompt appears now — not as an interruption on first use. No-op
  /// when already granted.
  static func requestAccessibilityAtOptIn(for purpose: AccessibilityPurpose = .autoPaste) {
    guard !hasAccessibilityPermission() else { return }
    requestOrDeepLink(purpose: purpose)
  }

  /// Same re-list rule as the dialog path, for the Privacy tab's "open Settings" button.
  /// Reads the prompt flag first, asks macOS, and opens the pane only when a prompt was already
  /// shown and access is still missing. The first native prompt has its own button, so the pane
  /// is not opened a second time.
  static func requestThenOpenAccessibilitySettings() {
    let alreadyPrompted = UserDefaults.standard.bool(forKey: UserDefaultsKeys.hasShownAccessibilityPrompt)
    requestAccessibilityPermission()
    if alreadyPrompted && !hasAccessibilityPermission() {
      PermissionStatusChecker.openSystemSettings(for: .accessibility)
    }
  }

  /// Checks permission when user tries to use a feature that reads the selection, prompting /
  /// deep-linking to System Settings if it's missing.
  static func checkPermissionForPromptUsage(for purpose: AccessibilityPurpose = .dictatePrompt) -> Bool {
    // Mark that the user has tried the prompt feature (for future reference)
    markPromptFeatureUsed()

    if hasAccessibilityPermission() {
      return true
    }

    requestOrDeepLink(purpose: purpose)
    return false
  }
}
