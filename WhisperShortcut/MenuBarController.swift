import Cocoa
import Foundation
import HotKey
import SwiftUI

class MenuBarController: NSObject {

  // MARK: - Single Source of Truth
  private var appState: AppState = .idle {
    didSet {
      
      updateUI()

      // Auto-reset feedback states after their duration
      if case .feedback(let feedbackMode) = appState {
        DispatchQueue.main.asyncAfter(deadline: .now() + feedbackMode.duration) {
          if case .feedback = self.appState {  // Only reset if still in feedback state
            self.appState = .idle
          }
        }
      }
    }
  }

  // MARK: - UI Components
  private var statusItem: NSStatusItem?
  private var blinkTimer: Timer?

  // MARK: - Services (Injected Dependencies)
  private let audioRecorder: AudioRecorder
  private let speechService: SpeechService
  private let clipboardManager: ClipboardManager
  private let shortcuts: Shortcuts
  private let reviewPrompter: ReviewPrompter

  // MARK: - Configuration
  private var currentConfig: ShortcutConfig

  init(
    audioRecorder: AudioRecorder = AudioRecorder(),
    speechService: SpeechService? = nil,
    clipboardManager: ClipboardManager = ClipboardManager(),
    shortcuts: Shortcuts = Shortcuts()
  ) {
    self.audioRecorder = audioRecorder
    self.clipboardManager = clipboardManager
    self.shortcuts = shortcuts
    self.reviewPrompter = ReviewPrompter.shared
    self.currentConfig = ShortcutConfigManager.shared.loadConfiguration()

    // Initialize speech service with clipboard manager
    self.speechService = speechService ?? SpeechService(clipboardManager: clipboardManager)

    super.init()

    setupMenuBar()
    setupDelegates()
    setupNotifications()
    loadModelConfiguration()
  }

  // MARK: - Setup
  private func setupMenuBar() {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    guard let statusItem = statusItem else { return }

    // Initial setup
    if let button = statusItem.button {
      button.title = appState.icon
      button.toolTip = appState.tooltip
    }

    // Create menu
    statusItem.menu = createMenu()
    updateUI()
  }

  private func createMenu() -> NSMenu {
    let menu = NSMenu()

    // Status item
    let statusMenuItem = NSMenuItem(title: appState.statusText, action: nil, keyEquivalent: "")
    statusMenuItem.tag = 100
    menu.addItem(statusMenuItem)

    menu.addItem(NSMenuItem.separator())

    // Recording actions with keyboard shortcuts
    menu.addItem(
      createMenuItemWithShortcut(
        "Toggle Transcription", action: #selector(toggleTranscription),
        shortcut: currentConfig.startRecording, tag: 101))
    menu.addItem(
      createMenuItemWithShortcut(
        "Toggle Prompting", action: #selector(togglePrompting),
        shortcut: currentConfig.startPrompting, tag: 102))

    menu.addItem(NSMenuItem.separator())

    // Settings and quit
    menu.addItem(
      createMenuItemWithShortcut(
        "Settings...", action: #selector(openSettings),
        shortcut: currentConfig.openSettings, tag: 103))
    menu.addItem(
      createMenuItem("Quit WhisperShortcut", action: #selector(quitApp), keyEquivalent: "q"))

    return menu
  }

  private func createMenuItem(
    _ title: String, action: Selector, keyEquivalent: String = "", tag: Int = 0
  ) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
    item.target = self
    item.tag = tag
    return item
  }

  private func createMenuItemWithShortcut(
    _ title: String, action: Selector, shortcut: ShortcutDefinition, tag: Int = 0
  ) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
    item.target = self
    item.tag = tag

    // Add keyboard shortcut display to the menu item
    if shortcut.isEnabled {
      // Set the actual key equivalent for single character keys
      let keyChar = getKeyEquivalentCharacter(for: shortcut.key)
      if !keyChar.isEmpty {
        item.keyEquivalent = keyChar
        item.keyEquivalentModifierMask = shortcut.modifiers
      } else {
        // For complex keys, show in title with proper spacing
        item.title = "\(title)                    \(shortcut.displayString)"
      }
    }

    return item
  }

  private func getKeyEquivalentCharacter(for key: Key) -> String {
    switch key {
    case .one: return "1"
    case .two: return "2"
    case .three: return "3"
    case .four: return "4"
    case .five: return "5"
    case .six: return "6"
    case .seven: return "7"
    case .eight: return "8"
    case .nine: return "9"
    case .zero: return "0"
    case .a: return "a"
    case .b: return "b"
    case .c: return "c"
    case .d: return "d"
    case .e: return "e"
    case .f: return "f"
    case .g: return "g"
    case .h: return "h"
    case .i: return "i"
    case .j: return "j"
    case .k: return "k"
    case .l: return "l"
    case .m: return "m"
    case .n: return "n"
    case .o: return "o"
    case .p: return "p"
    case .q: return "q"
    case .r: return "r"
    case .s: return "s"
    case .t: return "t"
    case .u: return "u"
    case .v: return "v"
    case .w: return "w"
    case .x: return "x"
    case .y: return "y"
    case .z: return "z"
    default: return ""  // For function keys and special keys
    }
  }

  private func setupDelegates() {
    audioRecorder.delegate = self
    shortcuts.delegate = self
  }

  private func setupNotifications() {
    // Listen for API key updates and shortcut changes
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(apiKeyUpdated),
      name: UserDefaults.didChangeNotification,
      object: nil
    )

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(shortcutsChanged),
      name: .shortcutsChanged,
      object: nil
    )

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(modelChanged),
      name: .modelChanged,
      object: nil
    )
  }

  private func loadModelConfiguration() {
    // Load saved model preference and set it on the transcription service
    if let savedModelString = UserDefaults.standard.string(forKey: "selectedTranscriptionModel"),
      let savedModel = TranscriptionModel(rawValue: savedModelString)
    {
      speechService.setModel(savedModel)
    } else {
      // Set default model from SettingsDefaults
      speechService.setModel(SettingsDefaults.selectedTranscriptionModel)
    }

    // Setup shortcuts
    shortcuts.setup()
  }

  // MARK: - UI Updates (Single Method!)
  private func updateUI() {
    updateMenuBarIcon()
    updateMenuItems()
    updateBlinking()
  }

  private func updateMenuBarIcon() {
    guard let button = statusItem?.button else { return }
    button.title = appState.icon
    button.toolTip = appState.tooltip
  }

  private func updateMenuItems() {
    guard let menu = statusItem?.menu else { return }

    let hasAPIKey = KeychainManager.shared.hasGoogleAPIKey()

    // Update status
    menu.item(withTag: 100)?.title = appState.statusText

    // Update action items based on current state
    updateMenuItem(
      menu, tag: 101,
      title: appState.recordingMode == .transcription
        ? "Stop Transcription" : "Start Transcription",
      enabled: appState.canStartTranscription(hasAPIKey: hasAPIKey)
        || appState.recordingMode == .transcription)

    updateMenuItem(
      menu, tag: 102,
      title: appState.recordingMode == .prompt ? "Stop Prompting" : "Start Prompting",
      enabled: appState.canStartPrompting(hasAPIKey: hasAPIKey) || appState.recordingMode == .prompt
    )

    // Handle special case when no API key is configured
    if !hasAPIKey, let button = statusItem?.button {
      button.title = "⚠️"
      button.toolTip = "API key required - click to configure"
    }
  }

  private func updateMenuItem(_ menu: NSMenu, tag: Int, title: String, enabled: Bool) {
    guard let item = menu.item(withTag: tag) else { return }
    item.title = title
    item.isEnabled = enabled
  }

  private func updateBlinking() {
    if appState.shouldBlink {
      startBlinking()
    } else {
      stopBlinking()
    }
  }

  // MARK: - Blinking Animation (Simplified)
  private func startBlinking() {
    stopBlinking()
    blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
      guard let self = self, let button = self.statusItem?.button else { return }
      button.title = button.title == self.appState.icon ? " " : self.appState.icon
    }
  }

  private func stopBlinking() {
    blinkTimer?.invalidate()
    blinkTimer = nil
    // Restore correct icon
    statusItem?.button?.title = appState.icon
  }

  // MARK: - Actions (Simplified Logic)
  @objc private func toggleTranscription() {
    // Check if currently processing transcription - if so, cancel it
    if case .processing(.transcribing) = appState {
      speechService.cancelTranscription()
      appState = .idle
      PopupNotificationWindow.showCancelled("Transcription cancelled")
      return
    }
    
    switch appState.recordingMode {
    case .transcription:
      audioRecorder.stopRecording()
    case .none:
      if appState.canStartTranscription(hasAPIKey: KeychainManager.shared.hasGoogleAPIKey()) {
        appState = appState.startRecording(.transcription)
        audioRecorder.startRecording()
      }
    default:
      break  // Other recording modes active
    }
  }

  @objc internal func togglePrompting() {
    // Check if currently processing prompt - if so, cancel it
    if case .processing(.prompting) = appState {
      speechService.cancelPrompt()
      appState = .idle
      PopupNotificationWindow.showCancelled("Prompt cancelled")
      return
    }
    
    switch appState.recordingMode {
    case .prompt:
      audioRecorder.stopRecording()
    case .none:
      if appState.canStartPrompting(hasAPIKey: KeychainManager.shared.hasGoogleAPIKey()) {
        // Check accessibility permission first
        if !AccessibilityPermissionManager.checkPermissionForPromptUsage() {
          return
        }
        simulateCopyPaste()
        appState = appState.startRecording(.prompt)
        audioRecorder.startRecording()
      }
    default:
      break
    }
  }

  @objc func openSettings() {
    SettingsManager.shared.toggleSettings()
  }

  @objc private func quitApp() {
    // Set flag to indicate user wants to quit completely
    UserDefaults.standard.set(true, forKey: "shouldTerminate")
    // Terminate the app completely
    NSApplication.shared.terminate(nil)
  }

  // MARK: - Async Operations (Clean & Simple)
  private func performTranscription(audioURL: URL) async {
    do {
      let result = try await speechService.transcribe(audioURL: audioURL)
      clipboardManager.copyToClipboard(text: result)
      
      // Record successful operation for review prompt
      reviewPrompter.recordSuccessfulOperation(window: statusItem?.button?.window)

      await MainActor.run {
        // Show popup notification with the transcription text and model info
        let modelInfo = self.speechService.getTranscriptionModelInfo()
        PopupNotificationWindow.showTranscriptionResponse(result, modelInfo: modelInfo)
        self.appState = self.appState.showSuccess("Transcription copied to clipboard")
      }
    } catch is CancellationError {
      // Task was cancelled - just cleanup and return to idle
      DebugLogger.log("CANCELLATION: Transcription task was cancelled")
      await MainActor.run {
        self.appState = .idle
      }
    } catch {
      await MainActor.run {
        let errorMessage: String
        let shortTitle: String

        if let transcriptionError = error as? TranscriptionError {
          errorMessage = SpeechErrorFormatter.format(transcriptionError)
          shortTitle = SpeechErrorFormatter.shortStatus(transcriptionError)
        } else {
          errorMessage = "Transcription failed: \(error.localizedDescription)"
          shortTitle = "Transcription Error"
        }

        // Copy error message to clipboard
        self.clipboardManager.copyToClipboard(text: errorMessage)

        // Show error popup notification
        PopupNotificationWindow.showError(errorMessage, title: shortTitle)

        self.appState = self.appState.showError(errorMessage)
      }
    }

    // Cleanup
    try? FileManager.default.removeItem(at: audioURL)
  }

  private func performPrompting(audioURL: URL) async {
    do {
      let result = try await speechService.executePrompt(audioURL: audioURL)
      clipboardManager.copyToClipboard(text: result)
      
      // Record successful operation for review prompt
      reviewPrompter.recordSuccessfulOperation(window: statusItem?.button?.window)

      await MainActor.run {
        // Show popup notification with the response text and model info
        let modelInfo = self.speechService.getPromptModelInfo()
        PopupNotificationWindow.showPromptResponse(result, modelInfo: modelInfo)
        self.appState = self.appState.showSuccess("AI response copied to clipboard")
      }
    } catch is CancellationError {
      // Task was cancelled - just cleanup and return to idle
      DebugLogger.log("CANCELLATION: Prompt task was cancelled")
      await MainActor.run {
        self.appState = .idle
      }
    } catch {
      await MainActor.run {
        let errorMessage: String
        let shortTitle: String

        if let transcriptionError = error as? TranscriptionError {
          errorMessage = SpeechErrorFormatter.format(transcriptionError)
          shortTitle = SpeechErrorFormatter.shortStatus(transcriptionError)
        } else {
          errorMessage = "Prompt failed: \(error.localizedDescription)"
          shortTitle = "Prompt Error"
        }

        // Copy error message to clipboard
        self.clipboardManager.copyToClipboard(text: errorMessage)

        // Show error popup notification
        PopupNotificationWindow.showError(errorMessage, title: shortTitle)

        self.appState = self.appState.showError(errorMessage)
      }
    }

    try? FileManager.default.removeItem(at: audioURL)
  }



  @objc private func apiKeyUpdated() {
    // Update menu state when API key changes
    DispatchQueue.main.async {
      self.updateUI()
    }
  }

  @objc private func shortcutsChanged(_ notification: Notification) {
    if let newConfig = notification.object as? ShortcutConfig {
      currentConfig = newConfig
      DispatchQueue.main.async {
        // Recreate menu with updated shortcuts
        self.statusItem?.menu = self.createMenu()
        self.updateUI()
      }
    }
  }

  @objc private func modelChanged(_ notification: Notification) {
    if let newModel = notification.object as? TranscriptionModel {
      speechService.setModel(newModel)
    }
  }

  // MARK: - Utility
  private func simulateCopyPaste() {
    let source = CGEventSource(stateID: .combinedSessionState)
    let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: true)
    let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: false)

    cmdDown?.flags = .maskCommand
    cmdUp?.flags = .maskCommand

    cmdDown?.post(tap: .cghidEventTap)
    cmdUp?.post(tap: .cghidEventTap)
  }

  func cleanup() {
    stopBlinking()
    shortcuts.cleanup()
    audioRecorder.cleanup()
    statusItem = nil
    NotificationCenter.default.removeObserver(self)
  }

}

// MARK: - AudioRecorderDelegate (Clean State Transitions)
extension MenuBarController: AudioRecorderDelegate {
  func audioRecorderDidFinishRecording(audioURL: URL) {
    // Simple state-based dispatch - no complex mode tracking needed!
    guard case .recording(let recordingMode) = appState else { return }

    // Transition to processing
    appState = appState.stopRecording()

    // Execute appropriate async operation
    Task {
      switch recordingMode {
      case .transcription:
        await performTranscription(audioURL: audioURL)
      case .prompt:
        await performPrompting(audioURL: audioURL)
      }
    }
  }

  func audioRecorderDidFailWithError(_ error: Error) {
    appState = appState.showError("Recording failed: \(error.localizedDescription)")
  }
}

// MARK: - ShortcutDelegate (Simple Forwarding)
extension MenuBarController: ShortcutDelegate {
  func toggleDictation() { toggleTranscription() }
  // togglePrompting is already implemented above
  // openSettings is already implemented above
}
