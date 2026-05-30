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
    alert.messageText = "Accessibility Permission Required"
    alert.informativeText = """
      The prompt feature requires accessibility permission to function properly.

      Without this permission, the app cannot capture selected text.

      Click "Open Settings" to grant this permission. In System Settings:
      1. Go to Privacy & Security → Accessibility
      2. Enable WhisperShortcut

      The prompt feature will not work until this permission is granted.
      """
    alert.alertStyle = .informational
    alert.addButton(withTitle: "Open Settings")
    alert.addButton(withTitle: "Not Now")

    let response = alert.runModal()

    if response == .alertFirstButtonReturn {
      PermissionStatusChecker.openSystemSettings(for: .accessibility)
    }
  }

  /// Marks that the user has used the prompt feature
  static func markPromptFeatureUsed() {
    UserDefaults.standard.set(true, forKey: UserDefaultsKeys.hasUsedPromptFeature)
  }

  /// Checks permission when user tries to use the prompt feature, prompting / deep-linking
  /// to System Settings if it's missing.
  static func checkPermissionForPromptUsage() -> Bool {
    // Mark that the user has tried the prompt feature (for future reference)
    markPromptFeatureUsed()

    if hasAccessibilityPermission() {
      return true
    }

    // First time the permission is needed: fire the native macOS prompt, which also pre-registers
    // WhisperShortcut in the Accessibility list (greyed-out) so the user only flips a switch.
    // After a prior denial macOS won't re-prompt, so fall back to our deep-link dialog.
    if UserDefaults.standard.bool(forKey: UserDefaultsKeys.hasShownAccessibilityPrompt) {
      showAccessibilityPermissionDialog()
    } else {
      requestAccessibilityPermission()
    }
    return false
  }
}
