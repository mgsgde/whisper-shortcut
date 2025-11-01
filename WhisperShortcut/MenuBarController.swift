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
  private let audioPlaybackService: AudioPlaybackService
  private let shortcuts: Shortcuts

  // MARK: - Configuration
  private var currentConfig: ShortcutConfig

  init(
    audioRecorder: AudioRecorder = AudioRecorder(),
    speechService: SpeechService? = nil,
    clipboardManager: ClipboardManager = ClipboardManager(),
    audioPlaybackService: AudioPlaybackService = AudioPlaybackService.shared,
    shortcuts: Shortcuts = Shortcuts()
  ) {
    self.audioRecorder = audioRecorder
    self.clipboardManager = clipboardManager
    self.audioPlaybackService = audioPlaybackService
    self.shortcuts = shortcuts
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
    menu.addItem(
      createMenuItemWithShortcut(
        "Toggle Voice Response", action: #selector(toggleVoiceResponse),
        shortcut: currentConfig.startVoiceResponse, tag: 103))
    menu.addItem(
      createMenuItemWithShortcut(
        "Read Selected Text", action: #selector(readSelectedText),
        shortcut: currentConfig.readClipboard, tag: 104))

    menu.addItem(NSMenuItem.separator())

    // Settings, history and quit
    menu.addItem(createMenuItem("Settings...", action: #selector(openSettings)))
    menu.addItem(createMenuItem("View History...", action: #selector(openHistory)))
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
    let notifications = [
      ("VoicePlaybackStarted", #selector(handleVoicePlaybackStarted)),
      ("VoicePlaybackStopped", #selector(handleVoicePlaybackStopped)),
      ("ReadSelectedTextPlaybackStarted", #selector(handleTextPlaybackStarted)),
      ("ReadSelectedTextPlaybackStopped", #selector(handleTextPlaybackStopped)),
      ("VoiceResponseReadyToSpeak", #selector(voiceResponseReadyToSpeak)),
      ("VoicePlaybackStartedWithText", #selector(voicePlaybackStartedWithText(_:))),
      ("ReadSelectedTextReadyToSpeak", #selector(readSelectedTextReadyToSpeak(_:))),
    ]

    for (name, selector) in notifications {
      NotificationCenter.default.addObserver(
        self, selector: selector, name: NSNotification.Name(name), object: nil)
    }

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
      // Set default model to GPT-4o Transcribe
      speechService.setModel(.gpt4oTranscribe)
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

    let hasAPIKey = KeychainManager.shared.hasAPIKey()

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

    updateMenuItem(
      menu, tag: 103,
      title: getVoiceResponseTitle(),
      enabled: appState.canStartVoiceResponse(hasAPIKey: hasAPIKey)
        || appState.recordingMode == .voiceResponse || appState.playbackMode == .voiceResponse)

    updateMenuItem(
      menu, tag: 104,
      title: appState.playbackMode == .readingText ? "Stop Reading" : "Read Selected Text",
      enabled: appState.canStartTextReading(hasAPIKey: hasAPIKey)
        || appState.playbackMode == .readingText)

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

  private func getVoiceResponseTitle() -> String {
    if appState.recordingMode == .voiceResponse {
      return "Stop Voice Response"
    } else if appState.playbackMode == .voiceResponse {
      return "Stop Voice Playback"
    } else {
      return "Start Voice Response"
    }
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
      if appState.canStartTranscription(hasAPIKey: KeychainManager.shared.hasAPIKey()) {
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
      if appState.canStartPrompting(hasAPIKey: KeychainManager.shared.hasAPIKey()) {
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

  @objc internal func toggleVoiceResponse() {
    // Cancel if currently processing voice response or preparing TTS
    if case .processing(let mode) = appState, 
       mode == .voiceResponding || mode == .preparingTTS {
      speechService.cancelVoiceResponse()
      appState = .idle
      PopupNotificationWindow.showCancelled("Voice response cancelled")
      return
    }
    
    if appState.recordingMode == .voiceResponse {
      audioRecorder.stopRecording()
    } else if appState.playbackMode == .voiceResponse {
      audioPlaybackService.stopPlayback()
    } else if appState.canStartVoiceResponse(hasAPIKey: KeychainManager.shared.hasAPIKey()) {
      // Check accessibility permission first
      if !AccessibilityPermissionManager.checkPermissionForPromptUsage() {
        return
      }
      simulateCopyPaste()
      appState = appState.startRecording(.voiceResponse)
      audioRecorder.startRecording()
    }
  }

  @objc internal func readSelectedText() {
    if appState.playbackMode == .readingText {
      audioPlaybackService.stopPlayback()
    } else if appState.canStartTextReading(hasAPIKey: KeychainManager.shared.hasAPIKey()) {
      // Check accessibility permission first
      if !AccessibilityPermissionManager.checkPermissionForPromptUsage() {
        return
      }
      Task {
        await performTextReading()
      }
    }
  }

  @objc private func openSettings() {
    SettingsManager.shared.showSettings()
  }

  @objc private func openHistory() {
    // Export recent history to temp file and open it
    if let historyURL = HistoryLogger.shared.exportRecentToTempFile() {
      NSWorkspace.shared.open(historyURL)
      
    } else {
      DebugLogger.logError("❌ Failed to export history file")
    }
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

  private func performVoiceResponse(audioURL: URL) async {
    do {
      // Keep processing(voiceResponding) state for blinking - don't change to preparingTTS
      _ = try await speechService.executePromptWithVoiceResponse(audioURL: audioURL)
      // Voice Response Mode - no clipboard copy to maintain Voice-First approach

      // State will be updated to playback by notification handlers
    } catch is CancellationError {
      // Task was cancelled - just cleanup and return to idle
      DebugLogger.log("CANCELLATION: Voice response task was cancelled")
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
          errorMessage = "Voice response failed: \(error.localizedDescription)"
          shortTitle = "Voice Response Error"
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

  private func performTextReading() async {
    do {
      // Keep processing(preparingTTS) state for blinking - this is correct for read mode
      appState = appState.startTTSPreparation()
      _ = try await speechService.readSelectedTextAsSpeech()

      // State will be updated to playback by notification handlers
    } catch {
      await MainActor.run {
        let errorMessage: String
        let shortTitle: String

        if let transcriptionError = error as? TranscriptionError {
          errorMessage = SpeechErrorFormatter.format(transcriptionError)
          shortTitle = SpeechErrorFormatter.shortStatus(transcriptionError)
        } else {
          errorMessage = "Text reading failed: \(error.localizedDescription)"
          shortTitle = "Text Reading Error"
        }

        // Show error popup notification
        PopupNotificationWindow.showError(errorMessage, title: shortTitle)

        self.appState = self.appState.showError(errorMessage)
      }
    }
  }

  // MARK: - Notification Handlers (Simple State Updates)
  @objc private func handleVoicePlaybackStarted() {
    appState = appState.startPlayback(.voiceResponse)
  }

  @objc private func handleVoicePlaybackStopped() {
    appState = appState.stopPlayback()
  }

  @objc private func handleTextPlaybackStarted() {
    appState = appState.startPlayback(.readingText)
  }

  @objc private func handleTextPlaybackStopped() {
    appState = appState.stopPlayback()
  }

  // MARK: - TTS Ready Handlers (Keep Processing State for Blinking)
  @objc private func voiceResponseReadyToSpeak() {
    // TTS is ready but keep processing state with blinking until actual playback starts
    
    // DO NOT change state here - let VoicePlaybackStarted handle the transition
  }

  @objc private func voicePlaybackStartedWithText(_ notification: Notification) {
    DispatchQueue.main.async {
      // Extract the response text from the notification
      if let userInfo = notification.userInfo,
        let responseText = userInfo["responseText"] as? String
      {
        // Show popup notification synchronized with audio playback
        let modelInfo = self.speechService.getVoiceResponseModelInfo()
        PopupNotificationWindow.showVoiceResponse(responseText, modelInfo: modelInfo)
      }
    }
  }

  @objc private func readSelectedTextReadyToSpeak(_ notification: Notification) {
    DispatchQueue.main.async {
      // Extract the text from the notification
      if let userInfo = notification.userInfo,
        let selectedText = userInfo["selectedText"] as? String
      {
        // Show popup notification with the text that will be read
        PopupNotificationWindow.showReadingText(selectedText)

        // DO NOT change state here - keep processing state for blinking
        // Let ReadSelectedTextPlaybackStarted handle the transition to playback
      }
    }
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
      case .voiceResponse:
        await performVoiceResponse(audioURL: audioURL)
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
  // togglePrompting, toggleVoiceResponse, and readSelectedText are already implemented above
}
