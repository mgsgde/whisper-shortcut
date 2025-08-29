import AppKit
import ApplicationServices
import Foundation

/// Manages accessibility permissions and user guidance for WhisperShortcut
class AccessibilityPermissionManager {

  /// Checks if the app has accessibility permissions
  static func hasAccessibilityPermission() -> Bool {
    let hasPermission = AXIsProcessTrusted()
    NSLog("🔐 ACCESSIBILITY: Permission check - hasPermission: \(hasPermission)")
    return hasPermission
  }

  /// Shows a single, elegant dialog for accessibility permission
  static func showAccessibilityPermissionDialog() {
    // Double-check permission before showing dialog
    if hasAccessibilityPermission() {
      NSLog("🔐 ACCESSIBILITY: Already have permission, skipping dialog")
      return
    }

    NSLog("🔐 ACCESSIBILITY: Showing permission dialog")

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
    NSLog(
      "🔐 ACCESSIBILITY: Dialog response: \(response == .alertFirstButtonReturn ? "Open Settings" : "Not Now")"
    )

    if response == .alertFirstButtonReturn {
      openAccessibilitySettings()
    }
  }

  /// Opens System Settings to the Accessibility section (no additional dialogs)
  private static func openAccessibilitySettings() {
    NSLog("🔐 ACCESSIBILITY: Opening System Settings")

    // Try the modern URL first (macOS 13+)
    if let url = URL(
      string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    {
      NSWorkspace.shared.open(url)
      NSLog("🔐 ACCESSIBILITY: Opened modern System Settings URL")
    } else {
      // Fallback for older systems
      NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Preferences.app"))
      NSLog("🔐 ACCESSIBILITY: Opened legacy System Preferences")
    }
  }

  /// Checks permission only at app startup if prompt feature was used before
  static func checkAndRequestPermissionIfNeeded() {
    let hasUsedPrompt = UserDefaults.standard.bool(forKey: "hasUsedPromptFeature")
    NSLog("🔐 ACCESSIBILITY: Startup check - hasUsedPrompt: \(hasUsedPrompt)")

    // Only check if user has used prompt features before
    guard hasUsedPrompt else {
      NSLog("🔐 ACCESSIBILITY: User hasn't used prompt feature yet, skipping startup check")
      return
    }

    let hasPermission = hasAccessibilityPermission()
    NSLog("🔐 ACCESSIBILITY: Startup check - hasPermission: \(hasPermission)")

    if !hasPermission {
      NSLog("🔐 ACCESSIBILITY: Missing permission, showing dialog after delay")
      DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
        showAccessibilityPermissionDialog()
      }
    }
  }

  /// Marks that the user has used the prompt feature
  static func markPromptFeatureUsed() {
    UserDefaults.standard.set(true, forKey: "hasUsedPromptFeature")
    NSLog("🔐 ACCESSIBILITY: Marked prompt feature as used")
  }

  /// Checks permission when user tries to use prompt feature
  static func checkPermissionForPromptUsage() -> Bool {
    markPromptFeatureUsed()

    let hasPermission = hasAccessibilityPermission()
    NSLog("🔐 ACCESSIBILITY: Prompt usage check - hasPermission: \(hasPermission)")

    if !hasPermission {
      NSLog("🔐 ACCESSIBILITY: No permission for prompt usage, showing dialog")
      showAccessibilityPermissionDialog()
      return false
    }

    return true
  }
}
