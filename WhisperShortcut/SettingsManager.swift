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
