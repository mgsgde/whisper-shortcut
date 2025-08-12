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
}
