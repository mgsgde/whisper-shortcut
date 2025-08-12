import Cocoa
import Foundation
import SwiftUI

// Main App Delegate with full functionality
class FullAppDelegate: NSObject, NSApplicationDelegate {
  var menuBarController: MenuBarController?

  func applicationDidFinishLaunching(_ notification: Notification) {
    print("🚀 Full WhisperShortcut launched successfully")

    // Setup Edit menu for text editing commands
    setupEditMenu()

    // Initialize the full menu bar controller
    menuBarController = MenuBarController()

    print("✅ Full app components initialized:")
    print("   • Menu bar controller")
    print("   • Audio recorder")
    print("   • Global shortcuts")
    print("   • Transcription service")
    print("   • Clipboard manager")
    print("")
    print("📋 Usage:")
    print("   • ⌘⌥R: Start recording")
    print("   • ⌘R: Stop recording & transcribe")
    print("   • Right-click menu bar icon for more options")
    print("")

    // Microphone permission will be requested automatically when recording starts

    // Check Keychain status and API key configuration
    // (removed: KeychainManager.shared.checkKeychainStatus())

    // First check if API key exists without triggering a prompt
    if KeychainManager.shared.hasAPIKey() {
      print("✅ API key is configured in Keychain - ready to use!")
      // Now read the key (this will cache it and avoid future prompts)
      _ = KeychainManager.shared.getAPIKey()
    } else {
      print("⚠️  No API key configured - opening Settings with Skip option...")
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        SettingsManager.shared.showSettings()
      }
    }
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  func applicationWillTerminate(_ notification: Notification) {
    menuBarController?.cleanup()
    print("👋 WhisperShortcut terminated")
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
    print("🎙️ WhisperShortcut (Full Version) Starting...")

    // Check for multiple instances to prevent double menu bar icons
    let bundleID = Bundle.main.bundleIdentifier ?? "com.transcription.app"
    let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)

    if runningApps.count > 1 {
      print("⚠️ Another instance of WhisperShortcut is already running")
      print("   Terminating this instance to prevent duplicate menu bar icons")
      exit(0)
    }

    // Create the NSApplication
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)  // Menu bar only app

    // Create and run the full app
    let appDelegate = FullAppDelegate()
    app.delegate = appDelegate
    app.run()
  }
}
