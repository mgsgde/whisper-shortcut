import AppKit
import ApplicationServices
import Foundation

/// Manages accessibility permissions and user guidance for WhisperShortcut
class AccessibilityPermissionManager {

  /// Checks if the app has accessibility permissions
  static func hasAccessibilityPermission() -> Bool {
    AXIsProcessTrusted()
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

  /// Checks permission when user tries to use prompt feature
  /// This is now the ONLY place where accessibility permission is requested
  static func checkPermissionForPromptUsage() -> Bool {
    // Mark that the user has tried the prompt feature (for future reference)
    markPromptFeatureUsed()

    let hasPermission = hasAccessibilityPermission()

    if !hasPermission {
      // Show dialog immediately when user actually needs the permission
      showAccessibilityPermissionDialog()
      return false
    }

    return true
  }
}
