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

  /// POSIX signal handlers held for the lifetime of the app. Without these, a
  /// default `pkill` / `kill` (which sends SIGTERM) terminates the process
  /// immediately and `applicationWillTerminate` never runs — meaning
  /// `ChatSessionStore.flushToDisk()` is skipped and recent chat edits are
  /// lost. Catching the signal and routing through `NSApp.terminate` gives us
  /// the same clean-shutdown path as a Cmd-Q quit.
  private var signalSources: [DispatchSourceSignal] = []

  func applicationDidFinishLaunching(_ notification: Notification) {
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    DebugLogger.log("APP-LIFECYCLE: launched pid=\(getpid()) version=\(version) build=\(build)")

    installTerminationSignalHandlers()

    // Prevent macOS from automatically terminating this menu bar app when
    // the system is under memory/storage pressure or cleaning container caches.
    ProcessInfo.processInfo.disableAutomaticTermination("WhisperShortcut is a persistent menu bar utility")

    // Setup Edit menu for text editing commands
    setupEditMenu()

    // Initialize the full menu bar controller
    menuBarController = MenuBarController()

    // Accessibility permissions will be checked when user actually tries to use prompt features

    // Microphone permission will be requested automatically when recording starts

    // Show settings if no credential configured
    Task {
      await MainActor.run {
        if !GeminiCredentialProvider.shared.hasCredential() {
          DispatchQueue.main.asyncAfter(deadline: .now() + Constants.settingsDelay) {
            SettingsManager.shared.showSettings()
          }
        }
      }
    }

    // Initialize interaction logging default if not set (default: enabled; user can disable in Settings)
    if UserDefaults.standard.object(forKey: UserDefaultsKeys.contextLoggingEnabled) == nil {
      UserDefaults.standard.set(true, forKey: UserDefaultsKeys.contextLoggingEnabled)
    }

    // Improve from usage auto-run: check if due and start daily timer
    Task { @MainActor in
      await ImproveFromUsageAutoRunCoordinator.shared.checkAndRunIfDue()
      ImproveFromUsageAutoRunCoordinator.shared.startDailyTimer()
    }

  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    // CRITICAL: MenuBar apps should NEVER terminate when windows close
    return false
  }

  func application(_ application: NSApplication, open urls: [URL]) {
    for url in urls {
      GoogleAccountOAuthService.shared.handleRedirect(url: url)
    }
  }

  func applicationShouldTerminate(_ application: NSApplication) -> NSApplication.TerminateReply {
    // Check if user explicitly wants to quit completely
    let shouldTerminate = UserDefaults.standard.bool(forKey: UserDefaultsKeys.shouldTerminate)
    if shouldTerminate {
      UserDefaults.standard.set(false, forKey: UserDefaultsKeys.shouldTerminate)  // Reset flag
      DebugLogger.log("APP-LIFECYCLE: applicationShouldTerminate -> terminateNow (shouldTerminate flag set)")
      return .terminateNow
    }

    // LSUIElement apps should continue running in background
    DebugLogger.log("APP-LIFECYCLE: applicationShouldTerminate -> terminateCancel (menu bar app stays alive)")
    return .terminateCancel
  }

  func applicationWillTerminate(_ notification: Notification) {
    DebugLogger.log("APP-LIFECYCLE: applicationWillTerminate pid=\(getpid())")
    // Flush debounced session data before terminating
    ChatSessionStore.shared.flushToDisk()
    menuBarController?.cleanup()
  }

  /// Catches SIGTERM / SIGINT / SIGHUP so we know *why* the process died and
  /// can flush session data before exiting. Without this, `pkill` (used by the
  /// rebuild script and any third-party tooling) terminates the app without
  /// running `applicationWillTerminate`.
  private func installTerminationSignalHandlers() {
    let toCatch: [(Int32, String)] = [
      (SIGTERM, "SIGTERM"),
      (SIGINT, "SIGINT"),
      (SIGHUP, "SIGHUP"),
    ]
    for (sig, name) in toCatch {
      // The default action for these signals is process termination. Ignore
      // the default so the dispatch source can deliver the signal to us.
      signal(sig, SIG_IGN)
      let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
      source.setEventHandler {
        DebugLogger.log("APP-LIFECYCLE: received \(name) (signal=\(sig)) — initiating clean shutdown")
        UserDefaults.standard.set(true, forKey: UserDefaultsKeys.shouldTerminate)
        // Synchronously persist the flag so a fast-following exit doesn't lose it
        // (irrelevant for the current path but cheap insurance).
        UserDefaults.standard.synchronize()
        // Route through NSApp so applicationWillTerminate runs and the chat
        // session store flushes. `nil` sender = signal handler, not a UI action.
        NSApp.terminate(nil)
      }
      source.resume()
      signalSources.append(source)
    }
    DebugLogger.log("APP-LIFECYCLE: termination signal handlers installed (SIGTERM, SIGINT, SIGHUP)")
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

    // Add Edit and Chat menus to main menu
    let mainMenu = NSApp.mainMenu ?? NSMenu()
    mainMenu.addItem(NSMenuItem(title: "Edit", action: nil, keyEquivalent: ""))
    mainMenu.item(withTitle: "Edit")?.submenu = editMenu

    let chatMenu = NSMenu(title: "Chat")
    let newChatItem = NSMenuItem(
      title: "New Chat",
      action: #selector(FullAppDelegate.chatNewChat(_:)),
      keyEquivalent: "n"
    )
    newChatItem.keyEquivalentModifierMask = [.command, .shift]
    newChatItem.target = self
    chatMenu.addItem(newChatItem)

    let screenshotItem = NSMenuItem(
      title: "Capture Screenshot",
      action: #selector(FullAppDelegate.chatCaptureScreenshot(_:)),
      keyEquivalent: "s"
    )
    screenshotItem.keyEquivalentModifierMask = [.command, .shift]
    screenshotItem.target = self
    chatMenu.addItem(screenshotItem)

    let clearChatItem = NSMenuItem(
      title: "Clear Chat",
      action: #selector(FullAppDelegate.chatClearChat(_:)),
      keyEquivalent: "k"
    )
    clearChatItem.keyEquivalentModifierMask = [.command, .shift]
    clearChatItem.target = self
    chatMenu.addItem(clearChatItem)

    mainMenu.addItem(NSMenuItem(title: "Chat", action: nil, keyEquivalent: ""))
    mainMenu.item(withTitle: "Chat")?.submenu = chatMenu

    NSApp.mainMenu = mainMenu
  }

  @objc func chatNewChat(_ sender: Any?) {
    NotificationCenter.default.post(name: .chatNewChat, object: nil)
  }

  @objc func chatCaptureScreenshot(_ sender: Any?) {
    NotificationCenter.default.post(name: .chatCaptureScreenshot, object: nil)
  }

  @objc func chatClearChat(_ sender: Any?) {
    NotificationCenter.default.post(name: .chatClearChat, object: nil)
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
      DebugLogger.log("APP-LIFECYCLE: another instance already running (count=\(runningApps.count)) — exiting pid=\(getpid())")
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
