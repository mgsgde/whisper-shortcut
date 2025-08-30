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

  // MARK: - Application Mode (Single Source of Truth)
  private var appMode: AppMode = .idle {
    didSet {
      updateUI()
    }
  }

  // MARK: - Visual State (Independent of Business Logic)
  private enum VisualState {
    case normal  // Show normal AppMode-based icon
    case success(String)  // Show success icon with message
    case error(String)  // Show error icon with message

    var overridesAppMode: Bool {
      switch self {
      case .normal: return false
      case .success, .error: return true
      }
    }

    var icon: String {
      switch self {
      case .normal: return ""  // Use AppMode icon
      case .success: return "✅"
      case .error: return "❌"
      }
    }

    var statusText: String {
      switch self {
      case .normal: return ""  // Use AppMode status
      case .success(let message): return "✅ \(message)"
      case .error(let message): return "❌ \(message)"
      }
    }
  }

  private var visualState: VisualState = .normal {
    didSet {

      updateUI()
    }
  }

  private var audioRecorder: AudioRecorder?
  private var shortcuts: Shortcuts?
  private var speechService: SpeechService?
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

  // Note: Mode tracking is now handled by AppMode enum

  // MARK: - Computed Properties for Backward Compatibility
  // These provide the old boolean interface while using the new AppMode internally
  private var isRecording: Bool {
    get { appMode.isRecording && appMode.recordingType == .transcription }
    set {
      if newValue {
        lastModeWasPrompting = false
        lastModeWasVoiceResponse = false
        appMode = appMode.startRecording(type: .transcription)
      } else if appMode.recordingType == .transcription {
        appMode = appMode.stopRecording()
      }
    }
  }

  private var isPrompting: Bool {
    get { appMode.isRecording && appMode.recordingType == .prompt }
    set {
      if newValue {
        lastModeWasPrompting = true
        lastModeWasVoiceResponse = false
        appMode = appMode.startRecording(type: .prompt)
      } else if appMode.recordingType == .prompt {
        appMode = appMode.stopRecording()
      }
    }
  }

  private var isVoiceResponse: Bool {
    get { appMode.isRecording && appMode.recordingType == .voiceResponse }
    set {
      if newValue {
        lastModeWasPrompting = false
        lastModeWasVoiceResponse = true
        appMode = appMode.startRecording(type: .voiceResponse)
      } else if appMode.recordingType == .voiceResponse {
        appMode = appMode.stopRecording()
      }
    }
  }

  // For backward compatibility, we need to track the last mode separately
  // since the AppMode enum doesn't preserve this information during transitions
  private var lastModeWasPrompting: Bool = false
  private var lastModeWasVoiceResponse: Bool = false

  // MARK: - UI Update Methods
  private func updateUI() {
    updateMenuBarIcon()
    updateMenuState()
    updateBlinkingState()
  }

  private func updateMenuBarIcon() {
    guard let button = statusItem?.button else { return }
    let oldTitle = button.title

    // Visual state overrides AppMode when active
    let newTitle: String
    let tooltip: String

    if visualState.overridesAppMode {
      newTitle = visualState.icon
      tooltip = visualState.statusText
    } else {
      newTitle = appMode.icon
      tooltip = appMode.tooltip
    }

    button.title = newTitle
    button.toolTip = tooltip

  }

  private func updateBlinkingState() {
    if appMode.shouldBlink {
      startBlinking()
    } else {
      stopBlinking()
    }
  }

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
      title: "🔄 Retry Transcription", action: #selector(retryLastOperation), keyEquivalent: "")
    retryItem.target = self
    retryItem.tag = 104  // Tag for retry item
    retryItem.isHidden = true
    menu.addItem(retryItem)

    menu.addItem(NSMenuItem.separator())

    // Dictation section header
    let dictationHeader = NSMenuItem(title: "Speech to Text", action: nil, keyEquivalent: "")
    dictationHeader.isEnabled = false
    dictationHeader.tag = 101
    menu.addItem(dictationHeader)

    // Start recording item with configurable shortcut
    let startItem = NSMenuItem(
      title: "Dictate", action: #selector(startRecordingFromMenu),
      keyEquivalent: "")
    startItem.keyEquivalentModifierMask = []
    startItem.target = self
    startItem.tag = 102  // Tag for updating shortcut
    menu.addItem(startItem)

    // Stop recording item with configurable shortcut
    let stopItem = NSMenuItem(
      title: "Stop & Copy to Clipboard", action: #selector(stopRecordingFromMenu), keyEquivalent: ""
    )
    stopItem.keyEquivalentModifierMask = []
    stopItem.target = self
    stopItem.tag = 103  // Tag for updating shortcut
    menu.addItem(stopItem)

    menu.addItem(NSMenuItem.separator())

    // Prompt section header
    let promptHeader = NSMenuItem(title: "Speech to Prompt", action: nil, keyEquivalent: "")
    promptHeader.isEnabled = false
    promptHeader.tag = 104
    menu.addItem(promptHeader)

    // Start prompting item with configurable shortcut
    let startPromptItem = NSMenuItem(
      title: "Dictate Prompt", action: #selector(startPromptingFromMenu),
      keyEquivalent: "")
    startPromptItem.keyEquivalentModifierMask = []
    startPromptItem.target = self
    startPromptItem.tag = 105  // Tag for updating shortcut
    menu.addItem(startPromptItem)

    // Stop prompting item with configurable shortcut
    let stopPromptItem = NSMenuItem(
      title: "Stop & Copy to Clipboard", action: #selector(stopPromptingFromMenu),
      keyEquivalent: "")
    stopPromptItem.keyEquivalentModifierMask = []
    stopPromptItem.target = self
    stopPromptItem.tag = 106  // Tag for updating shortcut
    menu.addItem(stopPromptItem)

    menu.addItem(NSMenuItem.separator())

    // Voice Response section header
    let voiceResponseHeader = NSMenuItem(
      title: "Speech to Prompt with Voice Response", action: nil, keyEquivalent: "")
    voiceResponseHeader.isEnabled = false
    voiceResponseHeader.tag = 108
    menu.addItem(voiceResponseHeader)

    // Start voice response item with configurable shortcut
    let startVoiceResponseItem = NSMenuItem(
      title: "Dictate Prompt", action: #selector(startVoiceResponseFromMenu),
      keyEquivalent: "")
    startVoiceResponseItem.keyEquivalentModifierMask = []
    startVoiceResponseItem.target = self
    startVoiceResponseItem.tag = 109  // Tag for updating shortcut
    menu.addItem(startVoiceResponseItem)

    // Stop voice response item with configurable shortcut
    let stopVoiceResponseItem = NSMenuItem(
      title: "Stop & Speak Response", action: #selector(stopVoiceResponseFromMenu),
      keyEquivalent: "")
    stopVoiceResponseItem.keyEquivalentModifierMask = []
    stopVoiceResponseItem.target = self
    stopVoiceResponseItem.tag = 110  // Tag for updating shortcut
    menu.addItem(stopVoiceResponseItem)

    menu.addItem(NSMenuItem.separator())

    // Open ChatGPT item with configurable shortcut
    let openChatGPTItem = NSMenuItem(
      title: "Open ChatGPT", action: #selector(openChatGPTFromMenu), keyEquivalent: "")
    openChatGPTItem.keyEquivalentModifierMask = []
    openChatGPTItem.target = self
    openChatGPTItem.tag = 107  // Tag for updating shortcut
    menu.addItem(openChatGPTItem)

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
    shortcuts = Shortcuts()
    clipboardManager = ClipboardManager()
    speechService = SpeechService(clipboardManager: clipboardManager)

    // Load saved model preference and set it on the transcription service
    if let savedModelString = UserDefaults.standard.string(forKey: "selectedTranscriptionModel"),
      let savedModel = TranscriptionModel(rawValue: savedModelString)
    {
      NSLog(
        "🎯 MENU-CONTROLLER: Loading saved transcription model: \(savedModel.displayName) (\(savedModel.rawValue))"
      )
      speechService?.setModel(savedModel)
    } else {
      // Set default model to GPT-4o Transcribe

      speechService?.setModel(.gpt4oTranscribe)
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

    // Listen for voice response status updates
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(voiceResponseReadyToSpeak),
      name: NSNotification.Name("VoiceResponseReadyToSpeak"),
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

    // Update status text based on current mode (with visual state override)
    if let statusMenuItem = menu.item(withTag: 100) {
      let oldStatus = statusMenuItem.title

      // Visual state overrides AppMode when active
      let newStatus: String
      if visualState.overridesAppMode {
        newStatus = visualState.statusText
      } else {
        newStatus = appMode.statusText
      }

      statusMenuItem.title = newStatus
      statusMenuItem.isHidden = false  // Always show status

    }

    // Update recording menu items
    if let startRecordingItem = menu.item(withTag: 102) {
      startRecordingItem.isEnabled = appMode.shouldEnableStartRecording(hasAPIKey: hasAPIKey)
      startRecordingItem.isHidden = appMode.isBusy && !startRecordingItem.isEnabled
      startRecordingItem.title = "Dictate"
    }

    if let stopRecordingItem = menu.item(withTag: 103) {
      stopRecordingItem.isEnabled = appMode.shouldEnableStopRecording
      stopRecordingItem.isHidden = appMode.isBusy && !stopRecordingItem.isEnabled
      stopRecordingItem.title = "Stop & Copy to Clipboard"
    }

    // Update prompting menu items
    if let startPromptingItem = menu.item(withTag: 105) {
      startPromptingItem.isEnabled = appMode.shouldEnableStartPrompting(hasAPIKey: hasAPIKey)
      startPromptingItem.isHidden = appMode.isBusy && !startPromptingItem.isEnabled
      startPromptingItem.title = "Dictate Prompt"
    }

    if let stopPromptingItem = menu.item(withTag: 106) {
      stopPromptingItem.isEnabled = appMode.shouldEnableStopPrompting
      stopPromptingItem.isHidden = appMode.isBusy && !stopPromptingItem.isEnabled
      stopPromptingItem.title = "Stop & Copy to Clipboard"
    }

    // Update voice response menu items
    if let startVoiceResponseItem = menu.item(withTag: 109) {
      startVoiceResponseItem.isEnabled = appMode.shouldEnableStartVoiceResponse(
        hasAPIKey: hasAPIKey)
      startVoiceResponseItem.isHidden = appMode.isBusy && !startVoiceResponseItem.isEnabled
      startVoiceResponseItem.title = "Dictate Prompt"
    }

    if let stopVoiceResponseItem = menu.item(withTag: 110) {
      stopVoiceResponseItem.isEnabled = appMode.shouldEnableStopVoiceResponse
      stopVoiceResponseItem.isHidden = appMode.isBusy && !stopVoiceResponseItem.isEnabled
      stopVoiceResponseItem.title = "Stop & Speak Response"
    }

    // Update retry menu item
    updateRetryMenuItem()

    // Icon is now handled by updateMenuBarIcon() which is called from updateUI()
    // Handle special case when no API key is configured
    if !hasAPIKey, let button = statusItem?.button {
      button.title = "⚠️"
      button.toolTip = "API key required - click to configure"
      button.image = nil
      button.imagePosition = .noImage
      button.needsDisplay = true
    }
  }

  private func updateRetryMenuItem() {

    guard let menu = statusItem?.menu else {

      return
    }

    guard let retryMenuItem = menu.item(withTag: 104) else {

      return
    }

    retryMenuItem.isHidden = !canRetry

    if canRetry {
      // Determine the operation type based on last mode
      let operationType = lastModeWasPrompting ? "Prompt" : "Transcription"

      // Show specific error type in retry menu if available
      if let error = lastError {
        let (_, _, errorType) = SpeechService.parseTranscriptionResult(error)
        if let type = errorType {
          retryMenuItem.title = "🔄 Retry \(operationType) (\(type.title))"

        } else {
          retryMenuItem.title = "🔄 Retry \(operationType)"
        }
      } else {
        retryMenuItem.title = "🔄 Retry \(operationType)"
      }
    } else {
    }
  }

  private func updateMenuShortcuts() {
    guard let menu = statusItem?.menu else { return }

    // Update start recording shortcut
    if let startItem = menu.item(withTag: 102) {
      if currentConfig.startRecording.isEnabled {
        startItem.keyEquivalent = currentConfig.startRecording.key.displayString.lowercased()
        startItem.keyEquivalentModifierMask = currentConfig.startRecording.modifiers
        startItem.title = "Dictate"
      } else {
        startItem.keyEquivalent = ""
        startItem.keyEquivalentModifierMask = []
        startItem.title = "Dictate (Disabled)"
      }
    }

    // Update stop recording shortcut
    if let stopItem = menu.item(withTag: 103) {
      if currentConfig.stopRecording.isEnabled {
        stopItem.keyEquivalent = currentConfig.stopRecording.key.displayString.lowercased()
        stopItem.keyEquivalentModifierMask = currentConfig.stopRecording.modifiers
        stopItem.title = "Stop & Copy to Clipboard"
      } else {
        stopItem.keyEquivalent = ""
        stopItem.keyEquivalentModifierMask = []
        stopItem.title = "Stop & Copy to Clipboard (Disabled)"
      }
    }

    // Update start prompting shortcut
    if let startPromptItem = menu.item(withTag: 105) {
      if currentConfig.startPrompting.isEnabled {
        startPromptItem.keyEquivalent = currentConfig.startPrompting.key.displayString.lowercased()
        startPromptItem.keyEquivalentModifierMask = currentConfig.startPrompting.modifiers
        startPromptItem.title = "Dictate Prompt"
      } else {
        startPromptItem.keyEquivalent = ""
        startPromptItem.keyEquivalentModifierMask = []
        startPromptItem.title = "Dictate Prompt (Disabled)"
      }
    }

    // Update stop prompting shortcut
    if let stopPromptItem = menu.item(withTag: 106) {
      if currentConfig.stopPrompting.isEnabled {
        stopPromptItem.keyEquivalent = currentConfig.stopPrompting.key.displayString.lowercased()
        stopPromptItem.keyEquivalentModifierMask = currentConfig.stopPrompting.modifiers
        stopPromptItem.title = "Stop & Copy to Clipboard"
      } else {
        stopPromptItem.keyEquivalent = ""
        stopPromptItem.keyEquivalentModifierMask = []
        stopPromptItem.title = "Stop & Copy to Clipboard (Disabled)"
      }
    }

    // Update start voice response shortcut
    if let startVoiceResponseItem = menu.item(withTag: 109) {
      if currentConfig.startVoiceResponse.isEnabled {
        startVoiceResponseItem.keyEquivalent = currentConfig.startVoiceResponse.key.displayString
          .lowercased()
        startVoiceResponseItem.keyEquivalentModifierMask =
          currentConfig.startVoiceResponse.modifiers
        startVoiceResponseItem.title = "Dictate Prompt"
      } else {
        startVoiceResponseItem.keyEquivalent = ""
        startVoiceResponseItem.keyEquivalentModifierMask = []
        startVoiceResponseItem.title = "Dictate Prompt (Disabled)"
      }
    }

    // Update stop voice response shortcut
    if let stopVoiceResponseItem = menu.item(withTag: 110) {
      if currentConfig.stopVoiceResponse.isEnabled {
        stopVoiceResponseItem.keyEquivalent = currentConfig.stopVoiceResponse.key.displayString
          .lowercased()
        stopVoiceResponseItem.keyEquivalentModifierMask = currentConfig.stopVoiceResponse.modifiers
        stopVoiceResponseItem.title = "Stop & Speak Response"
      } else {
        stopVoiceResponseItem.keyEquivalent = ""
        stopVoiceResponseItem.keyEquivalentModifierMask = []
        stopVoiceResponseItem.title = "Stop & Speak Response (Disabled)"
      }
    }

    // Update open ChatGPT shortcut
    if let openChatGPTItem = menu.item(withTag: 107) {
      if currentConfig.openChatGPT.isEnabled {
        openChatGPTItem.keyEquivalent = currentConfig.openChatGPT.key.displayString.lowercased()
        openChatGPTItem.keyEquivalentModifierMask = currentConfig.openChatGPT.modifiers
        openChatGPTItem.title = "Open ChatGPT"
      } else {
        openChatGPTItem.keyEquivalent = ""
        openChatGPTItem.keyEquivalentModifierMask = []
        openChatGPTItem.title = "Open ChatGPT (Disabled)"
      }
    }
  }

  @objc private func startRecordingFromMenu() {
    guard !isRecording else { return }

    isRecording = true
    updateMenuState()
    audioRecorder?.startRecording()
  }

  @objc private func stopRecordingFromMenu() {
    guard isRecording else { return }

    // Don't reset isRecording here - it will be used in audioRecorderDidFinishRecording
    updateMenuState()
    audioRecorder?.stopRecording()

  }

  @objc private func startPromptingFromMenu() {
    guard !isPrompting && !isRecording else {

      return
    }

    // Check accessibility permission first
    if !AccessibilityPermissionManager.checkPermissionForPromptUsage() {

      return
    }

    // Simulate Copy-Paste to capture selected text
    simulateCopyPaste()

    isPrompting = true
    updateMenuState()
    audioRecorder?.startRecording()
  }

  @objc private func stopPromptingFromMenu() {
    guard isPrompting else {

      return
    }

    // Don't reset isPrompting here - it will be used in audioRecorderDidFinishRecording
    updateMenuState()
    audioRecorder?.stopRecording()

  }

  @objc private func startVoiceResponseFromMenu() {
    guard !isRecording && !isVoiceResponse else { return }

    // Check accessibility permission first
    if !AccessibilityPermissionManager.checkPermissionForPromptUsage() {
      NSLog("⚠️ VOICE-RESPONSE-MODE: No accessibility permission")
      return
    }

    // Simulate Copy-Paste to capture selected text
    simulateCopyPaste()

    lastModeWasPrompting = false
    lastModeWasVoiceResponse = true
    isVoiceResponse = true
    updateMenuState()
    startAudioLevelMonitoring()
    audioRecorder?.startRecording()
  }

  @objc private func stopVoiceResponseFromMenu() {
    guard isVoiceResponse else { return }

    isVoiceResponse = false
    updateMenuState()
    stopAudioLevelMonitoring()
    audioRecorder?.stopRecording()
  }

  @objc private func openChatGPTFromMenu() {

    openChatGPTApp()
  }

  private func openChatGPTApp() {
    // First, try to open the ChatGPT desktop app if installed
    let chatGPTAppPath = "/Applications/ChatGPT.app"
    let chatGPTAppURL = URL(fileURLWithPath: chatGPTAppPath)

    if FileManager.default.fileExists(atPath: chatGPTAppPath) {
      let runningApp = NSWorkspace.shared.openApplication(
        at: chatGPTAppURL, configuration: NSWorkspace.OpenConfiguration())
      if runningApp != nil {

        return
      } else {

      }
    } else {

    }

    // Fallback: try to open ChatGPT in the default browser
    let chatGPTURL = URL(string: "https://chat.openai.com")!

    if NSWorkspace.shared.open(chatGPTURL) {

    } else {

      // Final fallback: try to open in Safari specifically
      let safariURL = URL(string: "https://chat.openai.com")!
      let safariAppURL = URL(fileURLWithPath: "/Applications/Safari.app")
      let runningApp = NSWorkspace.shared.open(
        [safariURL], withApplicationAt: safariAppURL, configuration: NSWorkspace.OpenConfiguration()
      )
      if runningApp != nil {

      } else {

      }
    }
  }

  @objc private func openSettings() {

    SettingsManager.shared.showSettings()
  }

  @objc private func quitApp() {
    NSApplication.shared.terminate(nil)
  }

  @objc private func retryLastOperation() {
    guard canRetry, let audioURL = lastAudioURL else {

      return
    }

    let operationType =
      lastModeWasVoiceResponse
      ? "voice response" : (lastModeWasPrompting ? "prompt execution" : "transcription")

    // Reset retry state
    canRetry = false
    updateRetryMenuItem()

    // Show appropriate processing status
    if lastModeWasVoiceResponse {
      showProcessingStatus(mode: "voice response")
    } else if lastModeWasPrompting {
      showProcessingStatus(mode: "prompt")
    } else {
      showTranscribingStatus()
    }

    // Start the appropriate operation with the same audio file
    Task {
      if lastModeWasVoiceResponse {
        await performVoiceResponseExecution(audioURL: audioURL)
      } else if lastModeWasPrompting {
        await performPromptExecution(audioURL: audioURL)
      } else {
        await performTranscription(audioURL: audioURL)
      }
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

    if let newModel = notification.object as? TranscriptionModel {
      speechService?.setModel(newModel)

    }
  }

  @objc private func voiceResponseReadyToSpeak() {
    DispatchQueue.main.async {
      self.showSpeakingStatus()
    }
  }

  // MARK: - Blinking Animation
  private func startBlinking() {
    stopBlinking()  // Stop any existing blinking

    isBlinking = true
    blinkTimer = Timer.scheduledTimer(withTimeInterval: Constants.blinkInterval, repeats: true) {
      [weak self] _ in
      self?.toggleBlinkState()
    }
  }

  private func stopBlinking() {
    blinkTimer?.invalidate()
    blinkTimer = nil
    isBlinking = false

    // Note: Don't override the icon here - let the AppMode system handle it
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
    stopAudioLevelMonitoring()
    stopBlinking()
    shortcuts?.cleanup()
    audioRecorder?.cleanup()
    statusItem = nil
    NotificationCenter.default.removeObserver(self)
  }
}

// MARK: - ShortcutDelegate
extension MenuBarController: ShortcutDelegate {
  func startRecording() {
    // Comprehensive state check - no new recordings if ANYTHING is active
    guard appMode == .idle else {
      NSLog("🚫 RECORDING-BLOCKED: Cannot start recording - app not idle (current: \(appMode))")
      return
    }

    NSLog("🎙️ RECORDING-START: Starting transcription recording")
    NSLog(
      "🎙️ RECORDING-START: Using transcription model: \(speechService?.getCurrentModel().displayName ?? "Unknown")"
    )
    lastModeWasPrompting = false
    lastModeWasVoiceResponse = false
    isRecording = true
    updateMenuState()
    audioRecorder?.startRecording()
    startAudioLevelMonitoring()
  }

  func stopRecording() {
    guard isRecording else { return }

    isRecording = false
    updateMenuState()
    stopAudioLevelMonitoring()
    audioRecorder?.stopRecording()
  }

  func startPrompting() {
    // Comprehensive state check - no new recordings if ANYTHING is active
    guard appMode == .idle else {
      NSLog("🚫 PROMPTING-BLOCKED: Cannot start prompting - app not idle (current: \(appMode))")
      return
    }

    // Check accessibility permission first
    if !AccessibilityPermissionManager.checkPermissionForPromptUsage() {
      NSLog("🚫 PROMPTING-BLOCKED: No accessibility permission")
      return
    }

    NSLog("🤖 PROMPTING-START: Starting prompt recording")

    // Simulate Copy-Paste to capture selected text
    simulateCopyPaste()

    lastModeWasPrompting = true
    lastModeWasVoiceResponse = false
    isPrompting = true
    updateMenuState()
    audioRecorder?.startRecording()
    startAudioLevelMonitoring()
  }

  private func simulateCopyPaste() {
    // Simulate Cmd+C to copy selected text
    let source = CGEventSource(stateID: .combinedSessionState)

    // Create Cmd+C event
    let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: true)  // C key
    let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: false)

    // Add Command modifier
    cmdDown?.flags = .maskCommand
    cmdUp?.flags = .maskCommand

    // Post the events
    cmdDown?.post(tap: .cghidEventTap)
    cmdUp?.post(tap: .cghidEventTap)

  }

  func stopPrompting() {
    guard isPrompting else { return }

    isPrompting = false
    updateMenuState()
    stopAudioLevelMonitoring()
    audioRecorder?.stopRecording()
  }

  func startVoiceResponse() {
    // Comprehensive state check - no new recordings if ANYTHING is active
    guard appMode == .idle else {
      NSLog(
        "🚫 VOICE-RESPONSE-BLOCKED: Cannot start voice response - app not idle (current: \(appMode))"
      )
      return
    }

    // Check accessibility permission first
    if !AccessibilityPermissionManager.checkPermissionForPromptUsage() {
      NSLog("🚫 VOICE-RESPONSE-BLOCKED: No accessibility permission")
      return
    }

    // Simulate Copy-Paste to capture selected text
    simulateCopyPaste()

    NSLog("🔊 VOICE-RESPONSE-START: Starting voice response recording")

    lastModeWasPrompting = false
    lastModeWasVoiceResponse = true
    isVoiceResponse = true
    updateMenuState()
    startAudioLevelMonitoring()
    audioRecorder?.startRecording()
  }

  func stopVoiceResponse() {
    guard isVoiceResponse else { return }

    isVoiceResponse = false
    updateMenuState()
    stopAudioLevelMonitoring()
    audioRecorder?.stopRecording()
  }

  func openChatGPT() {
    openChatGPTApp()
  }

  private func startAudioLevelMonitoring() {
    // Monitor audio levels every 0.5 seconds during recording
    audioLevelTimer = Timer.scheduledTimer(
      withTimeInterval: Constants.audioLevelUpdateInterval, repeats: true
    ) { [weak self] _ in
      if let levels = self?.audioRecorder?.getAudioLevels() {

        // If levels are very low (below -50dB), warn about potential issues
        if levels.average < -50 && levels.peak < -40 {

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
    NSLog(
      "🎙️ AUDIO-RECORDER: Recording finished, processing audio file: \(audioURL.lastPathComponent)")

    // Store the audio URL for potential retry
    lastAudioURL = audioURL
    canRetry = false
    lastError = nil

    // Use tracked mode since states are reset immediately in stop functions
    let wasPrompting = lastModeWasPrompting
    let wasVoiceResponse = lastModeWasVoiceResponse

    NSLog(
      "🎙️ AUDIO-RECORDER: Mode detection - wasPrompting: \(wasPrompting), wasVoiceResponse: \(wasVoiceResponse)"
    )

    // Determine which mode we were in and process accordingly
    if wasVoiceResponse {

      showProcessingStatus(mode: "voice response")

      // Start voice response execution
      Task {
        await performVoiceResponseExecution(audioURL: audioURL)
      }
    } else if wasPrompting {

      showProcessingStatus(mode: "prompt")

      // Start prompt execution
      Task {
        await performPromptExecution(audioURL: audioURL)
      }
    } else {

      showProcessingStatus(mode: "transcription")

      // Start transcription
      Task {
        await performTranscription(audioURL: audioURL)
      }
    }
  }

  private func performTranscription(audioURL: URL) async {
    let shouldCleanup: Bool

    do {
      let transcription = try await speechService?.transcribe(audioURL: audioURL) ?? ""
      shouldCleanup = await handleTranscriptionSuccess(transcription)
    } catch let error as TranscriptionError {
      shouldCleanup = await handleTranscriptionError(error)
    } catch {
      // Handle unexpected errors
      let transcriptionError = TranscriptionError.networkError(error.localizedDescription)
      shouldCleanup = await handleTranscriptionError(transcriptionError)
    }

    // Note: appMode will be reset to .idle by the success/error display timeout

    // Clean up audio file if appropriate
    if shouldCleanup {
      do {
        try FileManager.default.removeItem(at: audioURL)

      } catch {
      }
    } else {
    }
  }

  private func performPromptExecution(audioURL: URL) async {
    let shouldCleanup: Bool

    do {
      let response = try await speechService?.executePrompt(audioURL: audioURL) ?? ""
      shouldCleanup = await handlePromptSuccess(response)
    } catch let error as TranscriptionError {
      shouldCleanup = await handlePromptError(error)
    } catch {
      // Handle unexpected errors
      let transcriptionError = TranscriptionError.networkError(error.localizedDescription)
      shouldCleanup = await handlePromptError(transcriptionError)
    }

    // Note: appMode will be reset to .idle by the success/error display timeout

    // Clean up audio file if appropriate
    if shouldCleanup {
      do {
        try FileManager.default.removeItem(at: audioURL)

      } catch {
      }
    } else {
    }
  }

  private func performVoiceResponseExecution(audioURL: URL) async {
    let shouldCleanup: Bool

    do {

      let response =
        try await speechService?.executePromptWithVoiceResponse(audioURL: audioURL) ?? ""
      shouldCleanup = await handleVoiceResponseSuccess(response)
    } catch let error as TranscriptionError {
      shouldCleanup = await handleVoiceResponseError(error)
    } catch {
      // Handle unexpected errors
      let transcriptionError = TranscriptionError.networkError(error.localizedDescription)
      shouldCleanup = await handleVoiceResponseError(transcriptionError)
    }

    // Note: appMode will be reset to .idle by the success/error display timeout

    // Clean up audio file if appropriate
    if shouldCleanup {
      // Clean up audio file
      do {
        try FileManager.default.removeItem(at: audioURL)

      } catch {
        NSLog("⚠️ VOICE-RESPONSE-MODE: Failed to clean up audio file: \(error)")
      }
    }
  }

  @MainActor
  private func handleVoiceResponseSuccess(_ response: String) -> Bool {

    // Clear retry state on success
    canRetry = false
    lastError = nil
    lastAudioURL = nil
    updateRetryMenuItem()

    showTemporarySuccess()

    return true  // Clean up audio file
  }

  @MainActor
  private func handleVoiceResponseError(_ error: TranscriptionError) -> Bool {
    NSLog("❌ VOICE-RESPONSE-MODE: Voice response error: \(error)")

    let errorMessage = SpeechErrorFormatter.format(error)

    // Store error for retry functionality
    lastError = errorMessage

    if error.isRetryable && lastAudioURL != nil {
      canRetry = true
      updateRetryMenuItem()
    }

    // Copy error message to clipboard for troubleshooting
    clipboardManager?.copyToClipboard(text: errorMessage)
    showTemporaryError()

    return !error.isRetryable  // Clean up if not retryable
  }

  @MainActor
  private func handleTranscriptionSuccess(_ transcription: String) -> Bool {
    NSLog("✅ Transcription successful: \(transcription)")

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
    NSLog("❌ Transcription error: \(error)")

    let errorMessage = SpeechErrorFormatter.format(error)

    // Store error for retry functionality
    lastError = errorMessage

    if error.isRetryable && lastAudioURL != nil {
      canRetry = true
      updateRetryMenuItem()

    }

    // Copy error message to clipboard
    clipboardManager?.copyToClipboard(text: errorMessage)
    showTemporaryError()

    return !error.isRetryable  // Clean up if not retryable
  }

  @MainActor
  private func handlePromptSuccess(_ response: String) -> Bool {
    NSLog("✅ Prompt execution successful: \(response)")

    // Clear retry state on success
    canRetry = false
    lastError = nil
    lastAudioURL = nil
    updateRetryMenuItem()

    // Copy response to clipboard
    clipboardManager?.copyToClipboard(text: response)
    showTemporaryPromptSuccess()

    return true  // Clean up audio file
  }

  @MainActor
  private func handlePromptError(_ error: TranscriptionError) -> Bool {

    NSLog("❌ Prompt execution error: \(error)")

    let errorMessage = SpeechErrorFormatter.format(error)

    // Store error for retry functionality
    lastError = errorMessage

    if error.isRetryable && lastAudioURL != nil {
      canRetry = true
      updateRetryMenuItem()

    }

    // Copy error message to clipboard

    clipboardManager?.copyToClipboard(text: errorMessage)
    showTemporaryError()

    return !error.isRetryable  // Clean up if not retryable
  }

  private func showProcessingStatus(mode: String) {
    // Start blinking indicator in menu bar
    startBlinking()

    // Update menu status
    if let menu = statusItem?.menu,
      let statusMenuItem = menu.item(withTag: 100)
    {
      if mode == "prompt" {
        statusMenuItem.title = "🤖 Processing prompt..."
      } else if mode == "voice response" {
        statusMenuItem.title = "🔊 Processing voice response..."
      } else {
        statusMenuItem.title = "⏳ Transcribing..."
      }
    }
  }

  private func showTranscribingStatus() {
    showProcessingStatus(mode: "transcription")
  }

  private func showSpeakingStatus() {
    // Stop blinking - we're no longer processing
    stopBlinking()

    // Update menu bar icon to speaker
    if let button = statusItem?.button {
      button.title = "🔈"
      button.toolTip = "Playing voice response..."
    }

    // Update menu status
    if let menu = statusItem?.menu,
      let statusMenuItem = menu.item(withTag: 100)
    {
      statusMenuItem.title = "🔈 Playing response..."
    }
  }

  func audioRecorderDidFailWithError(_ error: Error) {

    isRecording = false
    updateMenuState()

    // Error is visible in menu bar - no notification needed
  }

  private func showTemporarySuccess() {
    // Stop blinking and show success indicator
    stopBlinking()

    // Set visual state (independent of AppMode)
    visualState = .success("Text copied to clipboard")

    // Business logic: immediately return to idle (allows new recordings)
    appMode = .idle

    // Reset visual state after 3 seconds
    DispatchQueue.main.asyncAfter(deadline: .now() + Constants.successDisplayTime) {

      self.visualState = .normal
    }
  }

  private func showTemporaryPromptSuccess() {
    // Stop blinking and show success indicator in menu bar
    stopBlinking()

    if let button = statusItem?.button {
      button.title = "🤖"
      button.toolTip = "Prompt execution complete - response copied to clipboard"

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
      statusMenuItem.title = "🤖 AI response copied to clipboard"
    }

    // Reset after 3 seconds - but don't trigger AppMode change immediately
    DispatchQueue.main.asyncAfter(deadline: .now() + Constants.successDisplayTime) {

      self.appMode = .idle
      self.updateUI()
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

        self.appMode = .idle
        self.updateUI()
      }
    }
  }

  private func resetToReadyState() {
    // CRITICAL: Only reset if nothing is currently active
    guard !isRecording && !isPrompting else {

      return
    }

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

    // Update menu state to enable/disable appropriate items
    updateMenuState()
  }
}
