import Cocoa
import SwiftUI
import UserNotifications

class MenuBarController: NSObject {
  
  // MARK: - Constants
  private enum Constants {
    static let blinkInterval: TimeInterval = 0.5
    static let audioLevelUpdateInterval: TimeInterval = 0.1
    static let successDisplayTime: TimeInterval = 2.0
    static let errorDisplayTime: TimeInterval = 3.0
    static let transcribingDisplayTime: TimeInterval = 1.0
  }
  
  // MARK: - UI Components
  private var statusItem: NSStatusItem?
  private var isRecording = false
  private var audioRecorder: AudioRecorder?
  private var shortcuts: SimpleShortcuts?
  private var transcriptionService: TranscriptionService?
  private var clipboardManager: ClipboardManager?
  private var audioLevelTimer: Timer?

  // MARK: - Configuration
  private var currentConfig: ShortcutConfig
  
  // MARK: - Animation
  private var blinkTimer: Timer?
  private var isBlinking = false

  // MARK: - Retry Functionality
  private var lastAudioURL: URL?
  private var lastError: String?
  private var canRetry = false

  override init() {
    // Load current shortcut configuration
    currentConfig = ShortcutConfigManager.shared.loadConfiguration()

    super.init()
    setupMenuBar()
    setupComponents()
  }

  private func setupMenuBar() {
    // Create status item in menu bar
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    guard let statusItem = statusItem else {
      print("Failed to create status item")
      return
    }

    // Set menu bar icon - force emoji as more reliable
    if let button = statusItem.button {
      // Use emoji directly - more reliable than SF Symbols
      button.title = "🎙️"
      button.image = nil
      button.imagePosition = .noImage
      button.toolTip = "WhisperShortcut - Click to record audio"

      // Ensure button is visible
      button.needsDisplay = true
    }

    // Create menu
    let menu = NSMenu()

    // Recording status item
    let statusMenuItem = NSMenuItem(title: "Ready to record", action: nil, keyEquivalent: "")
    statusMenuItem.tag = 100  // Tag for easy identification
    menu.addItem(statusMenuItem)

    menu.addItem(NSMenuItem.separator())

    // Retry item (initially hidden)
    let retryItem = NSMenuItem(
      title: "🔄 Retry Transcription", action: #selector(retryTranscription), keyEquivalent: "")
    retryItem.target = self
    retryItem.tag = 104  // Tag for retry item
    retryItem.isHidden = true
    menu.addItem(retryItem)

    menu.addItem(NSMenuItem.separator())

    // Start recording item with configurable shortcut
    let startItem = NSMenuItem(
      title: "Start Recording", action: #selector(startRecordingFromMenu), keyEquivalent: "")
    startItem.keyEquivalentModifierMask = []
    startItem.target = self
    startItem.tag = 102  // Tag for updating shortcut
    menu.addItem(startItem)

    // Stop recording item with configurable shortcut
    let stopItem = NSMenuItem(
      title: "Stop & Transcribe", action: #selector(stopRecordingFromMenu), keyEquivalent: "")
    stopItem.keyEquivalentModifierMask = []
    stopItem.target = self
    stopItem.tag = 103  // Tag for updating shortcut
    menu.addItem(stopItem)

    menu.addItem(NSMenuItem.separator())

    // Settings item
    let settingsItem = NSMenuItem(
      title: "Settings...", action: #selector(openSettings), keyEquivalent: "")
    settingsItem.target = self
    menu.addItem(settingsItem)

    // Quit item
    let quitItem = NSMenuItem(
      title: "Quit WhisperShortcut", action: #selector(quitApp), keyEquivalent: "q")
    quitItem.target = self
    menu.addItem(quitItem)

    statusItem.menu = menu

    // Initially disable stop recording and update shortcuts
    updateMenuState()
    updateMenuShortcuts()
  }

  private func setupComponents() {
    audioRecorder = AudioRecorder()
    shortcuts = SimpleShortcuts()
    transcriptionService = TranscriptionService()
    clipboardManager = ClipboardManager()

    // Load saved model preference and set it on the transcription service
    if let savedModelString = UserDefaults.standard.string(forKey: "selectedTranscriptionModel"),
      let savedModel = TranscriptionModel(rawValue: savedModelString)
    {
      transcriptionService?.setModel(savedModel)
    } else {
      // Set default model to GPT-4o Transcribe
      transcriptionService?.setModel(.gpt4oTranscribe)
    }

    // Setup simple shortcuts
    shortcuts?.delegate = self
    shortcuts?.setup()

    // Setup audio recorder delegate
    audioRecorder?.delegate = self

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

  private func updateMenuState() {
    guard let menu = statusItem?.menu else { return }

    // Check if API key is configured
    let hasAPIKey = KeychainManager.shared.hasAPIKey()

    // Update status text
    if let statusMenuItem = menu.item(withTag: 100) {
      if isRecording {
        statusMenuItem.title = "🔴 Recording..."
      } else {
        statusMenuItem.title = "Ready to record"
      }
    }

    // Update stop button state
    if let stopMenuItem = menu.item(withTag: 101) {
      stopMenuItem.isEnabled = isRecording
    }

    // Update retry menu item
    updateRetryMenuItem()

    // Update icon - always use emoji for reliability
    if let button = statusItem?.button {
      if isRecording {
        button.title = "🔴"
        button.toolTip = "Recording... Click to stop"
      } else if hasAPIKey {
        button.title = "🎙️"
        button.toolTip = "WhisperShortcut - Click to record"
      } else {
        button.title = "⚠️"
        button.toolTip = "API key required - click to configure"
      }
      button.image = nil
      button.imagePosition = .noImage

      // Force refresh
      button.needsDisplay = true
    }
  }

  private func updateRetryMenuItem() {
    print("🔄 updateRetryMenuItem called - canRetry: \(canRetry)")

    guard let menu = statusItem?.menu else {
      print("❌ No menu found")
      return
    }

    guard let retryMenuItem = menu.item(withTag: 104) else {
      print("❌ No retry menu item found with tag 104")
      return
    }

    print("🔄 Setting retry menu item hidden: \(!canRetry)")
    retryMenuItem.isHidden = !canRetry

    if canRetry {
      // Show specific error type in retry menu if available
      if let error = lastError {
        let (_, _, errorType) = TranscriptionService.parseTranscriptionResult(error)
        if let type = errorType {
          retryMenuItem.title = "🔄 Retry Transcription (\(type.title))"
          print("🔄 Set retry menu title to: Retry Transcription (\(type.title))")
        } else {
          retryMenuItem.title = "🔄 Retry Transcription"
          print("🔄 Set retry menu title to: Retry Transcription")
        }
      } else {
        retryMenuItem.title = "🔄 Retry Transcription"
        print("🔄 Set retry menu title to: Retry Transcription")
      }
    } else {
      print("🔄 Retry menu item hidden")
    }
  }

  private func updateMenuShortcuts() {
    guard let menu = statusItem?.menu else { return }

    // Update start recording shortcut
    if let startItem = menu.item(withTag: 102) {
      startItem.keyEquivalent = currentConfig.startRecording.key.displayString.lowercased()
      startItem.keyEquivalentModifierMask = currentConfig.startRecording.modifiers
    }

    // Update stop recording shortcut
    if let stopItem = menu.item(withTag: 103) {
      stopItem.keyEquivalent = currentConfig.stopRecording.key.displayString.lowercased()
      stopItem.keyEquivalentModifierMask = currentConfig.stopRecording.modifiers
    }
  }

  @objc private func startRecordingFromMenu() {
    guard !isRecording else { return }

    print("Starting recording...")
    isRecording = true
    updateMenuState()
    audioRecorder?.startRecording()
  }

  @objc private func stopRecordingFromMenu() {
    guard isRecording else { return }

    print("Stopping recording...")
    isRecording = false
    updateMenuState()

    audioRecorder?.stopRecording()
  }

  @objc private func openSettings() {
    print("Opening settings...")
    SettingsManager.shared.showSettings()
  }

  @objc private func quitApp() {
    NSApplication.shared.terminate(nil)
  }

  @objc private func retryTranscription() {
    guard canRetry, let audioURL = lastAudioURL else {
      print("❌ Cannot retry - no audio file available")
      return
    }

    print("🔄 Retrying transcription...")

    // Reset retry state
    canRetry = false
    updateRetryMenuItem()

    // Show transcribing status
    showTranscribingStatus()

    // Start transcription with the same audio file
    Task {
      await performTranscription(audioURL: audioURL)
    }
  }

  @objc private func apiKeyUpdated() {
    // Update menu state when API key changes
    DispatchQueue.main.async {
      self.updateMenuState()
    }
  }

  @objc private func shortcutsChanged(_ notification: Notification) {
    if let newConfig = notification.object as? ShortcutConfig {
      currentConfig = newConfig
      DispatchQueue.main.async {
        self.updateMenuShortcuts()
      }
    }
  }

  @objc private func modelChanged(_ notification: Notification) {
    print("🔄 Model changed, updating transcription service...")
    if let newModel = notification.object as? TranscriptionModel {
      transcriptionService?.setModel(newModel)
      print("✅ Model updated to: \(newModel.displayName)")
    }
  }

  // MARK: - Blinking Animation
  private func startBlinking() {
    stopBlinking()  // Stop any existing blinking

    isBlinking = true
    blinkTimer = Timer.scheduledTimer(withTimeInterval: Constants.blinkInterval, repeats: true) { [weak self] _ in
      self?.toggleBlinkState()
    }
  }

  private func stopBlinking() {
    blinkTimer?.invalidate()
    blinkTimer = nil
    isBlinking = false

    // Ensure button is visible when stopping
    if let button = statusItem?.button {
      button.title = "⏳"
      button.toolTip = "Transcribing audio... Please wait"
    }
  }

  private func toggleBlinkState() {
    guard isBlinking, let button = statusItem?.button else { return }

    // Toggle between loading icon and empty space for blinking effect
    if button.title == "⏳" {
      button.title = " "
      button.toolTip = "Transcribing audio... Please wait"
    } else {
      button.title = "⏳"
      button.toolTip = "Transcribing audio... Please wait"
    }
  }

  func cleanup() {
    shortcuts?.cleanup()
    audioRecorder?.cleanup()
    stopBlinking()
    statusItem = nil
    NotificationCenter.default.removeObserver(self)
  }
}

// MARK: - ShortcutDelegate
extension MenuBarController: ShortcutDelegate {
  func startRecording() {
    print("🎙️ Starting recording via shortcut...")
    isRecording = true
    updateMenuState()
    audioRecorder?.startRecording()

    // Start monitoring audio levels
    startAudioLevelMonitoring()
  }

  func stopRecording() {
    guard isRecording else { return }
    print("⏹️ Stopping recording via shortcut...")
    isRecording = false
    updateMenuState()
    stopAudioLevelMonitoring()
    audioRecorder?.stopRecording()
  }

  private func startAudioLevelMonitoring() {
    // Monitor audio levels every 0.5 seconds during recording
    audioLevelTimer = Timer.scheduledTimer(withTimeInterval: Constants.audioLevelUpdateInterval, repeats: true) { [weak self] _ in
      if let levels = self?.audioRecorder?.getAudioLevels() {
        print("🎤 Audio levels - Average: \(levels.average)dB, Peak: \(levels.peak)dB")

        // If levels are very low (below -50dB), warn about potential issues
        if levels.average < -50 && levels.peak < -40 {
          print("⚠️ Warning: Very low audio levels detected - check microphone input")
        }
      }
    }
  }

  private func stopAudioLevelMonitoring() {
    audioLevelTimer?.invalidate()
    audioLevelTimer = nil
  }
}

// MARK: - AudioRecorderDelegate
extension MenuBarController: AudioRecorderDelegate {
  func audioRecorderDidFinishRecording(audioURL: URL) {
    print("Audio recording finished, starting transcription...")

    // Store the audio URL for potential retry
    lastAudioURL = audioURL
    canRetry = false
    lastError = nil

    // Update status to show transcribing
    self.showTranscribingStatus()

    // Start transcription
    Task {
      await performTranscription(audioURL: audioURL)
    }
  }

  private func performTranscription(audioURL: URL) async {
    let shouldCleanup: Bool

    do {
      let transcription = try await transcriptionService?.transcribe(audioURL: audioURL) ?? ""
      shouldCleanup = await handleTranscriptionSuccess(transcription)
    } catch let error as TranscriptionError {
      shouldCleanup = await handleTranscriptionError(error)
    } catch {
      // Handle unexpected errors
      let transcriptionError = TranscriptionError.networkError(error.localizedDescription)
      shouldCleanup = await handleTranscriptionError(transcriptionError)
    }

    // Clean up audio file if appropriate
    if shouldCleanup {
      do {
        try FileManager.default.removeItem(at: audioURL)
        print("✅ Cleaned up audio file after transcription")
      } catch {
        print("⚠️ Could not clean up audio file: \(error)")
      }
    } else {
      print("🔄 Keeping audio file for potential retry")
    }
  }

  @MainActor
  private func handleTranscriptionSuccess(_ transcription: String) -> Bool {
    print("✅ Transcription successful: \(transcription)")

    // Clear retry state on success
    canRetry = false
    lastError = nil
    lastAudioURL = nil
    updateRetryMenuItem()

    // Copy to clipboard
    clipboardManager?.copyToClipboard(text: transcription)
    showTemporarySuccess()

    return true  // Clean up audio file
  }

  @MainActor
  private func handleTranscriptionError(_ error: TranscriptionError) -> Bool {
    print("❌ Transcription error: \(error)")

    let errorMessage = TranscriptionErrorFormatter.format(error)

    // Store error for retry functionality
    lastError = errorMessage

    if error.isRetryable && lastAudioURL != nil {
      canRetry = true
      updateRetryMenuItem()
      print("🔄 Error is retryable - showing retry option")
    }

    // Copy error message to clipboard
    clipboardManager?.copyToClipboard(text: errorMessage)
    showTemporaryError()

    return !error.isRetryable  // Clean up if not retryable
  }

  private func showTranscribingStatus() {
    // Start blinking transcribing indicator in menu bar
    startBlinking()

    // Update menu status
    if let menu = statusItem?.menu,
      let statusMenuItem = menu.item(withTag: 100)
    {
      statusMenuItem.title = "⏳ Transcribing..."
    }
  }

  func audioRecorderDidFailWithError(_ error: Error) {
    print("Audio recording failed: \(error)")
    isRecording = false
    updateMenuState()

    // Error is visible in menu bar - no notification needed
  }

  private func showTemporarySuccess() {
    // Stop blinking and show success indicator in menu bar
    stopBlinking()

    if let button = statusItem?.button {
      button.title = "✅"
      button.toolTip = "Transcription complete - text copied to clipboard"

      // Force immediate redraw to ensure visibility on all screens
      button.needsDisplay = true
      button.window?.displayIfNeeded()

      // Also force the status item to update
      statusItem?.button?.needsDisplay = true
    }

    // Update menu status
    if let menu = statusItem?.menu,
      let statusMenuItem = menu.item(withTag: 100)
    {
      statusMenuItem.title = "✅ Text copied to clipboard"
    }

    // Reset after 3 seconds
    DispatchQueue.main.asyncAfter(deadline: .now() + Constants.successDisplayTime) {
      self.resetToReadyState()
    }
  }

  private func showTemporaryError() {
    // Stop blinking and show error indicator in menu bar
    stopBlinking()

    if let button = statusItem?.button {
      button.title = "❌"
      button.toolTip = "Transcription failed - check your connection and API key"
    }

    // Update menu status
    if let menu = statusItem?.menu,
      let statusMenuItem = menu.item(withTag: 100)
    {
      if canRetry {
        statusMenuItem.title = "❌ Transcription failed - Retry available"
      } else {
        statusMenuItem.title = "❌ Transcription failed"
      }
    }

    // Only reset after 3 seconds if retry is not available
    if !canRetry {
      DispatchQueue.main.asyncAfter(deadline: .now() + Constants.errorDisplayTime) {
        self.resetToReadyState()
      }
    }
  }

  private func resetToReadyState() {
    // Reset to normal state
    if let button = statusItem?.button {
      button.title = "🎙️"
      button.toolTip = "WhisperShortcut - Click to record audio"
    }

    // Reset menu status
    if let menu = statusItem?.menu,
      let statusMenuItem = menu.item(withTag: 100)
    {
      statusMenuItem.title = "Ready to record"
    }

    // Clear retry state
    canRetry = false
    lastError = nil
    lastAudioURL = nil
    updateRetryMenuItem()
  }
}
