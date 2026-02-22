import Cocoa
import SwiftUI

// MARK: - Constants
private enum Constants {
  static let settingsDelay: TimeInterval = 0.5
  static let defaultBundleID = "com.magnusgoedde.whispershortcut"
}

// Main App Delegate with full functionality
class FullAppDelegate: NSObject, NSApplicationDelegate {
  var menuBarController: MenuBarController?

  func applicationDidFinishLaunching(_ notification: Notification) {

    // Setup Edit menu for text editing commands
    setupEditMenu()

    // Initialize the full menu bar controller
    menuBarController = MenuBarController()

    // Accessibility permissions will be checked when user actually tries to use prompt features

    // Microphone permission will be requested automatically when recording starts

    // Restore Google Sign-In from Keychain, then decide whether to show settings
    Task {
      await DefaultGoogleAuthService.shared.restorePreviousSignInIfNeeded()
      await MainActor.run {
        if !GeminiCredentialProvider.shared.hasCredential() {
          DispatchQueue.main.asyncAfter(deadline: .now() + Constants.settingsDelay) {
            SettingsManager.shared.showSettings()
          }
        } else if KeychainManager.shared.hasGoogleAPIKey() {
          _ = KeychainManager.shared.getGoogleAPIKey()
        }
      }
      // Set Smart Improvement interval default only after credential is known: Never without Gemini, Every 7 days with.
      if UserDefaults.standard.object(forKey: UserDefaultsKeys.autoPromptImprovementIntervalDays) == nil {
        let interval: AutoImprovementInterval = GeminiCredentialProvider.shared.hasCredential() ? .days7 : .never
        UserDefaults.standard.set(interval.rawValue, forKey: UserDefaultsKeys.autoPromptImprovementIntervalDays)
      }
    }

    // Initialize interaction logging default if not set
    if UserDefaults.standard.object(forKey: UserDefaultsKeys.userContextLoggingEnabled) == nil {
      UserDefaults.standard.set(true, forKey: UserDefaultsKeys.userContextLoggingEnabled)
    }

  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    // CRITICAL: MenuBar apps should NEVER terminate when windows close
    return false
  }

  func applicationShouldTerminate(_ application: NSApplication) -> NSApplication.TerminateReply {
    // Check if user explicitly wants to quit completely
    let shouldTerminate = UserDefaults.standard.bool(forKey: UserDefaultsKeys.shouldTerminate)
    if shouldTerminate {
      UserDefaults.standard.set(false, forKey: UserDefaultsKeys.shouldTerminate)  // Reset flag
      return .terminateNow
    }

    // LSUIElement apps should continue running in background
    return .terminateCancel
  }

  func applicationWillTerminate(_ notification: Notification) {
    menuBarController?.cleanup()
  }

  func application(_ application: NSApplication, open urls: [URL]) {
    for url in urls {
      if DefaultGoogleAuthService.handle(url: url) { return }
    }
  }

  private func setupEditMenu() {
    // Create Edit menu with standard text editing commands
    let editMenu = NSMenu(title: "Edit")

    // Undo
    let undoItem = NSMenuItem(
      title: "Undo", action: NSSelectorFromString("undo:"), keyEquivalent: "z")
    undoItem.target = nil  // Will be handled by first responder
    editMenu.addItem(undoItem)

    // Redo
    let redoItem = NSMenuItem(
      title: "Redo", action: NSSelectorFromString("redo:"), keyEquivalent: "Z")
    redoItem.target = nil  // Will be handled by first responder
    editMenu.addItem(redoItem)

    editMenu.addItem(NSMenuItem.separator())

    // Cut
    let cutItem = NSMenuItem(title: "Cut", action: NSSelectorFromString("cut:"), keyEquivalent: "x")
    cutItem.target = nil  // Will be handled by first responder
    editMenu.addItem(cutItem)

    // Copy
    let copyItem = NSMenuItem(
      title: "Copy", action: NSSelectorFromString("copy:"), keyEquivalent: "c")
    copyItem.target = nil  // Will be handled by first responder
    editMenu.addItem(copyItem)

    // Paste
    let pasteItem = NSMenuItem(
      title: "Paste", action: NSSelectorFromString("paste:"), keyEquivalent: "v")
    pasteItem.target = nil  // Will be handled by first responder
    editMenu.addItem(pasteItem)

    // Delete
    let deleteItem = NSMenuItem(
      title: "Delete", action: NSSelectorFromString("delete:"), keyEquivalent: "")
    deleteItem.target = nil  // Will be handled by first responder
    editMenu.addItem(deleteItem)

    editMenu.addItem(NSMenuItem.separator())

    // Select All
    let selectAllItem = NSMenuItem(
      title: "Select All", action: NSSelectorFromString("selectAll:"), keyEquivalent: "a")
    selectAllItem.target = nil  // Will be handled by first responder
    editMenu.addItem(selectAllItem)

    // Add Edit menu to main menu
    let mainMenu = NSApp.mainMenu ?? NSMenu()
    mainMenu.addItem(NSMenuItem(title: "Edit", action: nil, keyEquivalent: ""))
    mainMenu.item(withTitle: "Edit")?.submenu = editMenu

    NSApp.mainMenu = mainMenu
  }
}

@main
class FullWhisperShortcut {
  static func main() {
    // Full implementation using all components

    // Check for multiple instances to prevent double menu bar icons
    let bundleID = Bundle.main.bundleIdentifier ?? Constants.defaultBundleID
    let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)

    if runningApps.count > 1 {

      exit(0)
    }

    // Create the NSApplication
    let app = NSApplication.shared
    // LSUIElement = true in Info.plist handles the menu bar app behavior

    // Create and run the full app
    let appDelegate = FullAppDelegate()
    app.delegate = appDelegate
    app.run()
  }
}
