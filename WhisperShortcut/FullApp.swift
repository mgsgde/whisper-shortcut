import Cocoa
import Foundation

// Main App Delegate with full functionality
class FullAppDelegate: NSObject, NSApplicationDelegate {
  var menuBarController: MenuBarController?

  func applicationDidFinishLaunching(_ notification: Notification) {
    print("🚀 Full WhisperShortcut launched successfully")

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
