import Cocoa
import Foundation
import HotKey
import SwiftUI

class MenuBarController: NSObject {

  // MARK: - Constants
  private enum Constants {
    static let audioTailCaptureDelay: TimeInterval = 0.2  // Delay to capture audio tail and prevent cut-off sentences
  }

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
  
  // MARK: - Debug Testing
  private var shouldSimulateErrorOnNextRecording: TranscriptionError?

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
    
    // Debug: Test Retry functionality (simulate timeout error)
    // Available in all builds, but only shown if debug mode is enabled
    if UserDefaults.standard.bool(forKey: "enableDebugTestMenu") {
      menu.addItem(
        createMenuItem("🧪 Next Recording → Timeout Error", action: #selector(enableTimeoutSimulation), keyEquivalent: ""))
      menu.addItem(
        createMenuItem("🧪 Next Recording → Network Error", action: #selector(enableNetworkErrorSimulation), keyEquivalent: ""))
      if shouldSimulateErrorOnNextRecording != nil {
        let statusItem = NSMenuItem(title: "✅ Error simulation enabled", action: nil, keyEquivalent: "")
        statusItem.isEnabled = false  // Make it non-clickable
        menu.addItem(statusItem)
        menu.addItem(
          createMenuItem("   (Click to disable)", action: #selector(disableErrorSimulation), keyEquivalent: ""))
      }
      menu.addItem(NSMenuItem.separator())
    }

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
    let selectedModel: TranscriptionModel
    if let savedModelString = UserDefaults.standard.string(forKey: "selectedTranscriptionModel"),
      let savedModel = TranscriptionModel(rawValue: savedModelString)
    {
      selectedModel = savedModel
      speechService.setModel(savedModel)
    } else {
      // Set default model from SettingsDefaults
      selectedModel = SettingsDefaults.selectedTranscriptionModel
      speechService.setModel(SettingsDefaults.selectedTranscriptionModel)
    }

    // Pre-initialize offline models in the background if available
    if selectedModel.isOffline,
       let offlineModelType = selectedModel.offlineModelType,
       ModelManager.shared.isModelAvailable(offlineModelType) {
      DebugLogger.log("MENU-BAR: Pre-loading offline model \(offlineModelType.displayName) in background")
      Task {
        do {
          try await LocalSpeechService.shared.initializeModel(offlineModelType)
          DebugLogger.logSuccess("MENU-BAR: Successfully pre-loaded offline model \(offlineModelType.displayName)")
        } catch {
          DebugLogger.logError("MENU-BAR: Failed to pre-load offline model \(offlineModelType.displayName): \(error.localizedDescription)")
        }
      }
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
    
    // Check for offline transcription models
    let selectedTranscriptionModel = TranscriptionModel(
      rawValue: UserDefaults.standard.string(forKey: "selectedTranscriptionModel") 
        ?? SettingsDefaults.selectedTranscriptionModel.rawValue
    ) ?? SettingsDefaults.selectedTranscriptionModel
    
    let hasOfflineTranscriptionModel = selectedTranscriptionModel.isOffline && 
      ModelManager.shared.isModelAvailable(selectedTranscriptionModel.offlineModelType ?? .whisperBase)
    
    // Prompt mode always requires API key (no offline support)
    let hasOfflinePromptModel = false

    // Update status
    menu.item(withTag: 100)?.title = appState.statusText

    // Update action items based on current state
    updateMenuItem(
      menu, tag: 101,
      title: appState.recordingMode == .transcription
        ? "Stop Transcription" : "Start Transcription",
      enabled: appState.canStartTranscription(hasAPIKey: hasAPIKey, hasOfflineModel: hasOfflineTranscriptionModel)
        || appState.recordingMode == .transcription)

    updateMenuItem(
      menu, tag: 102,
      title: appState.recordingMode == .prompt ? "Stop Prompting" : "Start Prompting",
      enabled: appState.canStartPrompting(hasAPIKey: hasAPIKey, hasOfflineModel: hasOfflinePromptModel) 
        || appState.recordingMode == .prompt
    )

    // Handle special case when no API key and no offline model is configured
    if !hasAPIKey && !hasOfflineTranscriptionModel && !hasOfflinePromptModel, let button = statusItem?.button {
      button.title = "⚠️"
      button.toolTip = "API key or offline model required - click to configure"
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
      // Add delay to capture audio tail and prevent cut-off sentences
      DispatchQueue.main.asyncAfter(deadline: .now() + Constants.audioTailCaptureDelay) { [weak self] in
        self?.audioRecorder.stopRecording()
      }
    case .none:
      let hasAPIKey = KeychainManager.shared.hasGoogleAPIKey()
      let selectedModel = TranscriptionModel(
        rawValue: UserDefaults.standard.string(forKey: "selectedTranscriptionModel") 
          ?? SettingsDefaults.selectedTranscriptionModel.rawValue
      ) ?? SettingsDefaults.selectedTranscriptionModel
      let hasOfflineModel = selectedModel.isOffline && 
        ModelManager.shared.isModelAvailable(selectedModel.offlineModelType ?? .whisperBase)
      
      if appState.canStartTranscription(hasAPIKey: hasAPIKey, hasOfflineModel: hasOfflineModel) {
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
      // Add delay to capture audio tail and prevent cut-off sentences
      DispatchQueue.main.asyncAfter(deadline: .now() + Constants.audioTailCaptureDelay) { [weak self] in
        self?.audioRecorder.stopRecording()
      }
    case .none:
      // Prompt mode always requires API key (no offline support yet)
      let hasAPIKey = KeychainManager.shared.hasGoogleAPIKey()
      
      if appState.canStartPrompting(hasAPIKey: hasAPIKey, hasOfflineModel: false) {
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
  
  // MARK: - Debug Testing
  @objc private func enableTimeoutSimulation() {
    shouldSimulateErrorOnNextRecording = .requestTimeout
    DebugLogger.log("DEBUG: Enabled timeout error simulation for next recording")
    updateUI()  // Update menu to show status
    PopupNotificationWindow.showTranscriptionResponse("Timeout error will be simulated on next recording", modelInfo: "Debug Mode")
  }
  
  @objc private func enableNetworkErrorSimulation() {
    shouldSimulateErrorOnNextRecording = .networkError("The request timed out.")
    DebugLogger.log("DEBUG: Enabled network error simulation for next recording")
    updateUI()  // Update menu to show status
    PopupNotificationWindow.showTranscriptionResponse("Network error will be simulated on next recording", modelInfo: "Debug Mode")
  }
  
  @objc private func disableErrorSimulation() {
    shouldSimulateErrorOnNextRecording = nil
    DebugLogger.log("DEBUG: Disabled error simulation")
    updateUI()  // Update menu to hide status
  }
  
  /// Performs prompting but simulates a specific error for testing
  private func performPromptingWithSimulatedError(audioURL: URL, error: TranscriptionError) async {
    // Set processing state
    await MainActor.run {
      appState = .processing(.prompting)
    }
    
    // Wait a moment to simulate processing
    try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
    
    // Now throw the simulated error using unified error handler
    await handleProcessingError(error: error, audioURL: audioURL, mode: .prompt)
  }
  
  /// Performs transcription but simulates a specific error for testing
  private func performTranscriptionWithSimulatedError(audioURL: URL, error: TranscriptionError) async {
    // Set processing state
    await MainActor.run {
      appState = .processing(.transcribing)
    }
    
    // Wait a moment to simulate processing
    try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
    
    // Now throw the simulated error using unified error handler
    await handleProcessingError(error: error, audioURL: audioURL, mode: .transcription)
  }

  @objc private func quitApp() {
    // Set flag to indicate user wants to quit completely
    UserDefaults.standard.set(true, forKey: "shouldTerminate")
    // Terminate the app completely
    NSApplication.shared.terminate(nil)
  }

  // MARK: - Async Operations (Clean & Simple)
  
  /// Unified error handler for processing errors (transcription/prompting)
  /// - Parameters:
  ///   - error: The error that occurred
  ///   - audioURL: The URL of the audio file being processed
  ///   - mode: The recording mode (.transcription or .prompt)
  private func handleProcessingError(error: Error, audioURL: URL, mode: AppState.RecordingMode) async {
    await MainActor.run {
      var errorMessage: String
      let shortTitle: String
      let transcriptionError: TranscriptionError?

      if let error = error as? TranscriptionError {
        transcriptionError = error
        let formattedMessage = SpeechErrorFormatter.format(error)
        shortTitle = SpeechErrorFormatter.shortStatus(error)
        
        // Remove the title/header from the formatted message if it contains the shortTitle
        // This prevents showing the title twice (once in titleLabel, once in text)
        let trimmedFormatted = formattedMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        let titleToRemove = shortTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Check if the formatted message starts with the title (after trimming whitespace)
        if trimmedFormatted.hasPrefix(titleToRemove) {
          // Find the position after the title
          let titleLength = titleToRemove.count
          let afterTitle = trimmedFormatted.dropFirst(titleLength)
          
          // Skip any whitespace and newlines after the title, then get the rest
          errorMessage = String(afterTitle).trimmingCharacters(in: .whitespacesAndNewlines)
          
          // If we ended up with nothing, fall back to the original
          if errorMessage.isEmpty {
            errorMessage = formattedMessage.trimmingCharacters(in: .whitespacesAndNewlines)
          }
        } else {
          errorMessage = formattedMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        }
      } else {
        transcriptionError = nil
        let operationName = mode == .transcription ? "Transcription" : "Prompt"
        errorMessage = "\(operationName) failed: \(error.localizedDescription)"
        shortTitle = "\(operationName) Error"
      }

      // Copy error message to clipboard
      self.clipboardManager.copyToClipboard(text: errorMessage)

      // Determine if error is retryable
      let isRetryable = transcriptionError?.isRetryable ?? false
      
      // Define retry action
      let retryAction: (() -> Void)? = isRetryable ? { [weak self] in
        guard let self = self else { return }
        Task {
          switch mode {
          case .transcription:
            await self.performTranscription(audioURL: audioURL)
          case .prompt:
            await self.performPrompting(audioURL: audioURL)
          }
        }
      } : nil
      
      // Define dismiss action (only for non-retryable errors)
      let dismissAction: (() -> Void)? = isRetryable ? nil : {
        try? FileManager.default.removeItem(at: audioURL)
      }
      
      // Set error state
      self.appState = self.appState.showError(errorMessage)
      
      // Show error popup notification with retry option if applicable
      PopupNotificationWindow.showError(errorMessage, title: shortTitle, retryAction: retryAction, dismissAction: dismissAction)
      
      // Clean up non-retryable errors immediately
      if !isRetryable {
        try? FileManager.default.removeItem(at: audioURL)
      }
    }
  }
  
  private func performTranscription(audioURL: URL) async {
    // Check if we should simulate an error for debugging
    if let simulatedError = shouldSimulateErrorOnNextRecording {
      shouldSimulateErrorOnNextRecording = nil  // Reset after use
      DebugLogger.log("DEBUG: Simulating error for testing: \(simulatedError)")
      await performTranscriptionWithSimulatedError(audioURL: audioURL, error: simulatedError)
      updateUI()  // Update menu to remove simulation status
      return
    }
    
    do {
      let result = try await speechService.transcribe(audioURL: audioURL)
      clipboardManager.copyToClipboard(text: result)
      
      // Record successful operation for review prompt
      reviewPrompter.recordSuccessfulOperation(window: statusItem?.button?.window)

      // Get model info asynchronously before UI update
      let modelInfo = await self.speechService.getTranscriptionModelInfo()
      
      await MainActor.run {
        // Show popup notification with the transcription text and model info
        PopupNotificationWindow.showTranscriptionResponse(result, modelInfo: modelInfo)
        self.appState = self.appState.showSuccess("Transcription copied to clipboard")
      }
      
      // Cleanup on success
      try? FileManager.default.removeItem(at: audioURL)
    } catch is CancellationError {
      // Task was cancelled - just cleanup and return to idle
      DebugLogger.log("CANCELLATION: Transcription task was cancelled")
      await MainActor.run {
        self.appState = .idle
      }
      // Cleanup on cancellation
      try? FileManager.default.removeItem(at: audioURL)
    } catch {
      await handleProcessingError(error: error, audioURL: audioURL, mode: .transcription)
    }
  }

  private func performPrompting(audioURL: URL) async {
    // Check if we should simulate an error for debugging
    if let simulatedError = shouldSimulateErrorOnNextRecording {
      shouldSimulateErrorOnNextRecording = nil  // Reset after use
      DebugLogger.log("DEBUG: Simulating error for testing: \(simulatedError)")
      await performPromptingWithSimulatedError(audioURL: audioURL, error: simulatedError)
      updateUI()  // Update menu to remove simulation status
      return
    }
    
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
      
      // Cleanup on success
      try? FileManager.default.removeItem(at: audioURL)
    } catch is CancellationError {
      // Task was cancelled - just cleanup and return to idle
      DebugLogger.log("CANCELLATION: Prompt task was cancelled")
      await MainActor.run {
        self.appState = .idle
      }
      // Cleanup on cancellation
      try? FileManager.default.removeItem(at: audioURL)
    } catch {
      await handleProcessingError(error: error, audioURL: audioURL, mode: .prompt)
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
