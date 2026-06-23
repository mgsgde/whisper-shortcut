import Cocoa

class SettingsManager {
  static let shared = SettingsManager()
  private var settingsWindowController: SettingsWindowController?

  private init() {}

  func showSettings() {
    if settingsWindowController == nil {
      settingsWindowController = SettingsWindowController()
    }

    // Use the new showWindow method that handles activation policy
    settingsWindowController?.showWindow()
  }
  
  /// Opens the Settings window and switches to the Privacy & Permissions tab — the single
  /// in-app hub for permission status and actions. Every permission-error path routes here so
  /// the user sees all permissions' status (and the Quit & Reopen affordance) in one place,
  /// instead of being deep-linked into a different macOS pane per feature.
  func showPrivacyPermissions() {
    showSettings()
    // Brief delay so the window + its SwiftUI hierarchy exist before we post the tab switch.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
      NotificationCenter.default.post(name: .openPrivacyPermissionsTab, object: nil)
    }
  }

  func toggleSettings() {
    if isSettingsWindowOpen() {
      closeSettings()
    } else {
      showSettings()
    }
  }
  
  func isSettingsWindowOpen() -> Bool {
    guard let window = settingsWindowController?.window else {
      return false
    }
    return window.isVisible
  }
  
  func closeSettings() {
    settingsWindowController?.window?.close()
  }

}
