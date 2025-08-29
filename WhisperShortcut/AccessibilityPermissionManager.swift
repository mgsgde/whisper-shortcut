import AppKit
import ApplicationServices
import Foundation

/// Manages accessibility permissions and user guidance for WhisperShortcut
class AccessibilityPermissionManager {

  /// Checks if the app has accessibility permissions
  static func hasAccessibilityPermission() -> Bool {
    let hasPermission = AXIsProcessTrusted()
    return hasPermission
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
      openAccessibilitySettings()
    }
  }

  /// Opens System Settings to the Accessibility section (no additional dialogs)
  private static func openAccessibilitySettings() {
    // Try the modern URL first (macOS 13+)
    if let url = URL(
      string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    {
      NSWorkspace.shared.open(url)
    } else {
      // Fallback for older systems
      NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Preferences.app"))
    }
  }

  /// Checks permission only at app startup if prompt feature was used before
  static func checkAndRequestPermissionIfNeeded() {
    let hasUsedPrompt = UserDefaults.standard.bool(forKey: "hasUsedPromptFeature")

    // Only check if user has used prompt features before
    guard hasUsedPrompt else {
      return
    }

    let hasPermission = hasAccessibilityPermission()

    if !hasPermission {
      DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
        showAccessibilityPermissionDialog()
      }
    }
  }

  /// Marks that the user has used the prompt feature
  static func markPromptFeatureUsed() {
    UserDefaults.standard.set(true, forKey: "hasUsedPromptFeature")
  }

  /// Checks permission when user tries to use prompt feature
  static func checkPermissionForPromptUsage() -> Bool {
    markPromptFeatureUsed()

    let hasPermission = hasAccessibilityPermission()

    if !hasPermission {
      showAccessibilityPermissionDialog()
      return false
    }

    return true
  }
}
