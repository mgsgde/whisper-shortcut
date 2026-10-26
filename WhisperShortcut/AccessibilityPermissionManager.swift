import AppKit
import ApplicationServices
import Foundation

/// Manages accessibility permissions and user guidance for WhisperShortcut
class AccessibilityPermissionManager {

  /// Checks if the app has accessibility permissions (pure check, never prompts).
  static func hasAccessibilityPermission() -> Bool {
    AXIsProcessTrusted()
  }

  /// Triggers the native macOS Accessibility prompt. This also pre-registers WhisperShortcut in
  /// the Accessibility list in System Settings, so the user only has to flip the switch instead of
  /// manually adding the app via "+". macOS won't re-show the prompt after a denial, so we record
  /// that it ran and fall back to a deep-link dialog on later attempts.
  @discardableResult
  static func requestAccessibilityPermission() -> Bool {
    UserDefaults.standard.set(true, forKey: UserDefaultsKeys.hasShownAccessibilityPrompt)
    return PermissionStatusChecker.requestAccessibilityAccess()
  }

  /// Shows a single, elegant dialog for accessibility permission
  static func showAccessibilityPermissionDialog() {
    // Double-check permission before showing dialog
    if hasAccessibilityPermission() {
      return
    }

    let alert = NSAlert()
    alert.messageText = "Enable Accessibility for Auto-Paste"
    alert.informativeText = """
      Auto-paste inserts dictated text at your cursor by simulating a ⌘V keystroke, which macOS allows only with Accessibility permission.

      Dictation works without this — your text is always copied to the clipboard, so you can paste it manually with ⌘V.

      To turn on auto-paste, click "Open System Settings". There:
      1. Go to Privacy & Security → Accessibility
      2. Enable WhisperShortcut

      Already listed and switched on, but still not working? macOS remembers an older copy of the app (common after switching between the App Store and GitHub versions). Remove WhisperShortcut from the list with the − button, then click "Open System Settings" here again: this copy is added back and you only flip the switch. Or click "Copy Reset Command" and run it in Terminal.
      """
    alert.alertStyle = .informational
    alert.addButton(withTitle: "Open System Settings")
    alert.addButton(withTitle: "Copy Reset Command")
    alert.addButton(withTitle: "Not Now")

    let response = alert.runModal()

    switch response {
    case .alertFirstButtonReturn:
      // Re-registers this exact binary if its entry is missing (after "−" or a tccutil reset),
      // so the user finds it in the list and only flips the switch. No-op when an entry exists.
      PermissionStatusChecker.requestAccessibilityAccess()
      PermissionStatusChecker.openSystemSettings(for: .accessibility)
    case .alertSecondButtonReturn:
      // Clears the stale TCC entry left behind by a differently-signed copy (App Store vs
      // GitHub build). The app cannot run tccutil itself; the user pastes it into Terminal.
      let pasteboard = NSPasteboard.general
      pasteboard.clearContents()
      // Bundle.main, not a literal: Debug builds run as ….whispershortcut.dev.
      let bundleID = Bundle.main.bundleIdentifier ?? "com.magnusgoedde.whispershortcut"
      pasteboard.setString("tccutil reset Accessibility \(bundleID)", forType: .string)
    default:
      break
    }
  }

  /// Marks that the user has used the prompt feature
  static func markPromptFeatureUsed() {
    UserDefaults.standard.set(true, forKey: UserDefaultsKeys.hasUsedPromptFeature)
  }

  /// The single Accessibility request rule, shared by the opt-in and use-time paths so both
  /// behave identically: the first time, fire the native prompt (which pre-registers the app
  /// in the Accessibility list so the user only flips a greyed switch); after a prior denial
  /// macOS suppresses the prompt, so deep-link into System Settings instead.
  private static func requestOrDeepLink() {
    if UserDefaults.standard.bool(forKey: UserDefaultsKeys.hasShownAccessibilityPrompt) {
      showAccessibilityPermissionDialog()
    } else {
      requestAccessibilityPermission()
    }
  }

  /// Requests Accessibility the moment the user opts into a feature that needs it (e.g. enabling
  /// auto-paste), so the system prompt appears now — not as an interruption on first use. No-op
  /// when already granted.
  static func requestAccessibilityAtOptIn() {
    guard !hasAccessibilityPermission() else { return }
    requestOrDeepLink()
  }

  /// Checks permission when user tries to use the prompt feature, prompting / deep-linking
  /// to System Settings if it's missing.
  static func checkPermissionForPromptUsage() -> Bool {
    // Mark that the user has tried the prompt feature (for future reference)
    markPromptFeatureUsed()

    if hasAccessibilityPermission() {
      return true
    }

    requestOrDeepLink()
    return false
  }
}
