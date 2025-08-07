import Cocoa
import SwiftUI
import UserNotifications

class MenuBarController: NSObject {
  private var statusItem: NSStatusItem?
  private var isRecording = false
  private var audioRecorder: AudioRecorder?
  private var shortcuts: SimpleShortcuts?
  private var transcriptionService: TranscriptionService?
  private var clipboardManager: ClipboardManager?
  private var audioLevelTimer: Timer?

  private var currentConfig: ShortcutConfig
  private var blinkTimer: Timer?
  private var isBlinking = false

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

  // MARK: - Blinking Animation
  private func startBlinking() {
    stopBlinking()  // Stop any existing blinking

    isBlinking = true
    blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
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
    audioLevelTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
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

    // Update status to show transcribing
    self.showTranscribingStatus()

    // Start transcription
    transcriptionService?.transcribe(audioURL: audioURL) { [weak self] result in
      DispatchQueue.main.async {
        self?.handleTranscriptionResult(result)

        // Clean up the audio file after transcription
        do {
          try FileManager.default.removeItem(at: audioURL)
          print("✅ Cleaned up audio file after transcription")
        } catch {
          print("⚠️ Could not clean up audio file: \(error)")
        }
      }
    }
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

  private func handleTranscriptionResult(_ result: Result<String, Error>) {
    switch result {
    case .success(let transcription):
      print("Transcription result: \(transcription)")

      // Check if this is an error message (starts with ❌ or ⚠️)
      if transcription.hasPrefix("❌") || transcription.hasPrefix("⚠️")
        || transcription.hasPrefix("⏳")
      {
        print("Error message returned as transcription")
        // Copy error message to clipboard
        clipboardManager?.copyToClipboard(text: transcription)
        // Show error status temporarily - user sees ❌ in menu bar
        self.showTemporaryError()
      } else {
        print("Transcription successful")
        // Copy to clipboard
        clipboardManager?.copyToClipboard(text: transcription)
        // Show success status temporarily - user sees ✅ in menu bar
        self.showTemporarySuccess()
      }

    case .failure(let error):
      print("Unexpected transcription failure: \(error)")
      // This should not happen anymore, but handle it gracefully
      let errorMessage = """
        ❌ Unexpected error

        Error: \(error.localizedDescription)

        Please try again.
        """
      clipboardManager?.copyToClipboard(text: errorMessage)
      self.showTemporaryError()
    }
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
    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
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
      statusMenuItem.title = "❌ Transcription failed"
    }

    // Reset after 3 seconds
    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
      self.resetToReadyState()
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
  }
}
