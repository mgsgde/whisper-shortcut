import Cocoa
import Foundation
import SwiftUI

class MenuBarController: NSObject {

  // MARK: - Constants
  private enum Constants {
    static let blinkInterval: TimeInterval = 0.5
    static let successDisplayTime: TimeInterval = 2.0
    static let errorDisplayTime: TimeInterval = 1.5
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
  private var audioPlaybackService: AudioPlaybackService?
  private var isVoicePlaying: Bool = false

  // MARK: - Configuration
  private var currentConfig: ShortcutConfig

  // MARK: - Animation
  private var blinkTimer: Timer?
  private var isBlinking = false

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

    // Toggle dictation item with configurable shortcut
    let toggleDictationItem = NSMenuItem(
      title: "Toggle Dictation", action: #selector(toggleDictationFromMenu),
      keyEquivalent: "")
    toggleDictationItem.keyEquivalentModifierMask = []
    toggleDictationItem.target = self
    toggleDictationItem.tag = 102  // Tag for updating shortcut
    menu.addItem(toggleDictationItem)

    // Toggle prompting item with configurable shortcut
    let togglePromptingItem = NSMenuItem(
      title: "Toggle Prompting", action: #selector(togglePromptingFromMenu),
      keyEquivalent: "")
    togglePromptingItem.keyEquivalentModifierMask = []
    togglePromptingItem.target = self
    togglePromptingItem.tag = 105  // Tag for updating shortcut
    menu.addItem(togglePromptingItem)

    // Toggle voice response item with configurable shortcut
    let toggleVoiceResponseItem = NSMenuItem(
      title: "Toggle Voice Response", action: #selector(toggleVoiceResponseFromMenu),
      keyEquivalent: "")
    toggleVoiceResponseItem.keyEquivalentModifierMask = []
    toggleVoiceResponseItem.target = self
    toggleVoiceResponseItem.tag = 109  // Tag for updating shortcut
    menu.addItem(toggleVoiceResponseItem)

    // Read selected text item with configurable shortcut
    let readSelectedTextItem = NSMenuItem(
      title: "Read Selected Text", action: #selector(readSelectedTextFromMenu),
      keyEquivalent: "")
    readSelectedTextItem.keyEquivalentModifierMask = []
    readSelectedTextItem.target = self
    readSelectedTextItem.tag = 110  // Tag for updating shortcut
    menu.addItem(readSelectedTextItem)

    menu.addItem(NSMenuItem.separator())

    // Settings item
    let settingsItem = NSMenuItem(
      title: "Settings...", action: #selector(openSettings), keyEquivalent: "")
    settingsItem.target = self
    menu.addItem(settingsItem)

    // Quit item - this will now properly quit the MenuBar app
    let quitItem = NSMenuItem(
      title: "Quit WhisperShortcut Completely", action: #selector(quitApp), keyEquivalent: "q")
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
    shortcuts?.delegate = self  // Set MenuBarController as delegate
    clipboardManager = ClipboardManager()
    speechService = SpeechService(clipboardManager: clipboardManager)
    audioPlaybackService = AudioPlaybackService.shared

    // Load saved model preference and set it on the transcription service
    if let savedModelString = UserDefaults.standard.string(forKey: "selectedTranscriptionModel"),
      let savedModel = TranscriptionModel(rawValue: savedModelString)
    {
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

    // Listen for voice playback status updates
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(voicePlaybackStarted),
      name: NSNotification.Name("VoicePlaybackStarted"),
      object: nil
    )

    // Listen for voice playback with text (for popup notification)
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(voicePlaybackStartedWithText(_:)),
      name: NSNotification.Name("VoicePlaybackStartedWithText"),
      object: nil
    )

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(voicePlaybackStopped),
      name: NSNotification.Name("VoicePlaybackStopped"),
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

    // Update toggle dictation menu item
    if let toggleDictationItem = menu.item(withTag: 102) {
      toggleDictationItem.isEnabled = appMode.canStartNewRecording && hasAPIKey
      toggleDictationItem.isHidden = false
      toggleDictationItem.title =
        appMode.isRecording && appMode.recordingType == .transcription
        ? "Stop Dictation"
        : "Start Dictation"
    }

    // Update toggle prompting menu item
    if let togglePromptingItem = menu.item(withTag: 105) {
      togglePromptingItem.isEnabled = appMode.canStartNewRecording && hasAPIKey
      togglePromptingItem.isHidden = false
      togglePromptingItem.title =
        appMode.isRecording && appMode.recordingType == .prompt
        ? "Stop Prompting"
        : "Start Prompting"
    }

    // Update toggle voice response menu item
    if let toggleVoiceResponseItem = menu.item(withTag: 109) {
      toggleVoiceResponseItem.isEnabled =
        (appMode.canStartNewRecording || isVoicePlaying) && hasAPIKey
      toggleVoiceResponseItem.isHidden = false
      toggleVoiceResponseItem.title =
        appMode.isRecording && appMode.recordingType == .voiceResponse
        ? "Stop Voice Response"
        : isVoicePlaying
          ? "Stop Voice Playback"
          : "Start Voice Response"
    }

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

  private func updateMenuShortcuts() {
    guard let menu = statusItem?.menu else { return }

    // Update toggle dictation shortcut
    if let toggleDictationItem = menu.item(withTag: 102) {
      if currentConfig.startRecording.isEnabled {
        toggleDictationItem.keyEquivalent = currentConfig.startRecording.key.displayString
          .lowercased()
        toggleDictationItem.keyEquivalentModifierMask = currentConfig.startRecording.modifiers
        toggleDictationItem.title =
          appMode.isRecording && appMode.recordingType == .transcription
          ? "Stop Dictation"
          : "Start Dictation"
      } else {
        toggleDictationItem.keyEquivalent = ""
        toggleDictationItem.keyEquivalentModifierMask = []
        toggleDictationItem.title = "Toggle Dictation (Disabled)"
      }
    }

    // Update toggle prompting shortcut
    if let togglePromptingItem = menu.item(withTag: 105) {
      if currentConfig.startPrompting.isEnabled {
        togglePromptingItem.keyEquivalent = currentConfig.startPrompting.key.displayString
          .lowercased()
        togglePromptingItem.keyEquivalentModifierMask = currentConfig.startPrompting.modifiers
        togglePromptingItem.title =
          appMode.isRecording && appMode.recordingType == .prompt
          ? "Stop Prompting"
          : "Start Prompting"
      } else {
        togglePromptingItem.keyEquivalent = ""
        togglePromptingItem.keyEquivalentModifierMask = []
        togglePromptingItem.title = "Toggle Prompting (Disabled)"
      }
    }

    // Update toggle voice response shortcut
    if let toggleVoiceResponseItem = menu.item(withTag: 109) {
      if currentConfig.startVoiceResponse.isEnabled {
        toggleVoiceResponseItem.keyEquivalent = currentConfig.startVoiceResponse.key.displayString
          .lowercased()
        toggleVoiceResponseItem.keyEquivalentModifierMask =
          currentConfig.startVoiceResponse.modifiers
        toggleVoiceResponseItem.title =
          appMode.isRecording && appMode.recordingType == .voiceResponse
          ? "Stop Voice Response"
          : isVoicePlaying
            ? "Stop Voice Playback"
            : "Start Voice Response"
      } else {
        toggleVoiceResponseItem.keyEquivalent = ""
        toggleVoiceResponseItem.keyEquivalentModifierMask = []
        toggleVoiceResponseItem.title = "Toggle Voice Response (Disabled)"
      }
    }

    // Update read selected text shortcut
    if let readSelectedTextItem = menu.item(withTag: 110) {
      if currentConfig.readClipboard.isEnabled {
        readSelectedTextItem.keyEquivalent = currentConfig.readClipboard.key.displayString
          .lowercased()
        readSelectedTextItem.keyEquivalentModifierMask = currentConfig.readClipboard.modifiers
        readSelectedTextItem.title = "Read Selected Text"
      } else {
        readSelectedTextItem.keyEquivalent = ""
        readSelectedTextItem.keyEquivalentModifierMask = []
        readSelectedTextItem.title = "Read Selected Text (Disabled)"
      }
    }

  }

  @objc private func toggleDictationFromMenu() {
    if appMode.isRecording && appMode.recordingType == .transcription {
      // Stop recording
      stopRecordingFromMenu()
    } else if appMode.canStartNewRecording {
      // Start recording
      startRecordingFromMenu()
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

  @objc private func togglePromptingFromMenu() {
    if appMode.isRecording && appMode.recordingType == .prompt {
      // Stop prompting
      stopPromptingFromMenu()
    } else if appMode.canStartNewRecording {
      // Start prompting
      startPromptingFromMenu()
    }
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

  @objc private func toggleVoiceResponseFromMenu() {
    if appMode.isRecording && appMode.recordingType == .voiceResponse {
      // Stop voice response
      stopVoiceResponseFromMenu()
    } else if isVoicePlaying {
      // Stop voice playback only
      audioPlaybackService?.stopPlayback()
      isVoicePlaying = false
      updateMenuState()
    } else if appMode.canStartNewRecording {
      // Start voice response
      startVoiceResponseFromMenu()
    }
  }

  @objc private func startVoiceResponseFromMenu() {
    guard !isRecording && !isVoiceResponse else { return }

    // Check accessibility permission first
    if !AccessibilityPermissionManager.checkPermissionForPromptUsage() {
      return
    }

    // Simulate Copy-Paste to capture selected text
    simulateCopyPaste()

    lastModeWasPrompting = false
    lastModeWasVoiceResponse = true
    isVoiceResponse = true
    updateMenuState()
    audioRecorder?.startRecording()
  }

  @objc private func stopVoiceResponseFromMenu() {
    guard isVoiceResponse else { return }

    isVoiceResponse = false
    updateMenuState()
    audioRecorder?.stopRecording()
  }

  @objc private func openSettings() {

    SettingsManager.shared.showSettings()
  }

  @objc private func quitApp() {
    // Set flag to indicate user wants to quit completely
    UserDefaults.standard.set(true, forKey: "shouldTerminate")

    // Terminate the app completely
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

  @objc private func voicePlaybackStarted() {
    DispatchQueue.main.async {
      self.isVoicePlaying = true
      self.updateMenuState()
    }
  }

  @objc private func voicePlaybackStartedWithText(_ notification: Notification) {
    DispatchQueue.main.async {
      // Extract the response text from the notification
      if let userInfo = notification.userInfo,
        let responseText = userInfo["responseText"] as? String
      {
        // Show popup notification synchronized with audio playback
        PopupNotificationWindow.showVoiceResponse(responseText)
      }
    }
  }

  @objc private func voicePlaybackStopped() {
    DispatchQueue.main.async {
      self.isVoicePlaying = false
      self.updateMenuState()
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
    stopBlinking()
    shortcuts?.cleanup()
    audioRecorder?.cleanup()
    statusItem = nil
    NotificationCenter.default.removeObserver(self)
  }
}

// MARK: - AudioRecorderDelegate
extension MenuBarController: AudioRecorderDelegate {
  func audioRecorderDidFinishRecording(audioURL: URL) {

    // Use tracked mode since states are reset immediately in stop functions
    let wasPrompting = lastModeWasPrompting
    let wasVoiceResponse = lastModeWasVoiceResponse

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
        DebugLogger.logWarning("VOICE-RESPONSE-MODE: Failed to clean up audio file: \(error)")
      }
    }
  }

  @MainActor
  private func handleVoiceResponseSuccess(_ response: String) -> Bool {
    // Note: PopupNotificationWindow was already shown before audio playback
    // Just show the traditional menu bar success indicator
    showTemporarySuccess()

    return true  // Clean up audio file
  }

  @MainActor
  private func handleVoiceResponseError(_ error: TranscriptionError) -> Bool {
    DebugLogger.logError("VOICE-RESPONSE-MODE: Voice response error: \(error)")

    let errorMessage = SpeechErrorFormatter.format(error)

    // Copy error message to clipboard for troubleshooting
    clipboardManager?.copyToClipboard(text: errorMessage)
    showTemporaryError()

    return true  // Clean up audio file
  }

  @MainActor
  private func handleTranscriptionSuccess(_ transcription: String) -> Bool {
    // Copy to clipboard
    clipboardManager?.copyToClipboard(text: transcription)

    // Show popup notification with the transcription text
    PopupNotificationWindow.showTranscriptionResponse(transcription)

    // Also show the traditional menu bar success indicator
    showTemporarySuccess()

    return true  // Clean up audio file
  }

  @MainActor
  private func handleTranscriptionError(_ error: TranscriptionError) -> Bool {
    DebugLogger.logError("Transcription error: \(error)")

    let errorMessage = SpeechErrorFormatter.format(error)

    // Copy error message to clipboard
    clipboardManager?.copyToClipboard(text: errorMessage)
    showTemporaryError()

    return true  // Clean up audio file
  }

  @MainActor
  private func handlePromptSuccess(_ response: String) -> Bool {
    // Copy response to clipboard
    clipboardManager?.copyToClipboard(text: response)

    // Show popup notification with the response text
    PopupNotificationWindow.showPromptResponse(response)

    // Also show the traditional menu bar success indicator
    showTemporaryPromptSuccess()

    return true  // Clean up audio file
  }

  @MainActor
  private func handlePromptError(_ error: TranscriptionError) -> Bool {

    DebugLogger.logError("Prompt execution error: \(error)")

    let errorMessage = SpeechErrorFormatter.format(error)

    // Copy error message to clipboard
    clipboardManager?.copyToClipboard(text: errorMessage)
    showTemporaryError()

    return true  // Clean up audio file
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
      } else if mode == "clipboard reading" {
        statusMenuItem.title = "📋 Reading clipboard..."
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
      statusMenuItem.title = "❌ Transcription failed"
    }

    // Reset after 3 seconds
    DispatchQueue.main.asyncAfter(deadline: .now() + Constants.errorDisplayTime) {

      self.appMode = .idle
      self.updateUI()
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

    // Update menu state to enable/disable appropriate items
    updateMenuState()
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

}

// MARK: - ShortcutDelegate Implementation
extension MenuBarController: ShortcutDelegate {
  func toggleDictation() {
    if appMode.isRecording && appMode.recordingType == .transcription {
      // Stop recording
      stopRecordingFromMenu()
    } else if appMode.canStartNewRecording {
      // Start recording
      startRecordingFromMenu()
    }
  }

  func togglePrompting() {
    if appMode.isRecording && appMode.recordingType == .prompt {
      // Stop prompting
      stopPromptingFromMenu()
    } else if appMode.canStartNewRecording {
      // Start prompting
      startPromptingFromMenu()
    }
  }

  func toggleVoiceResponse() {
    if appMode.isRecording && appMode.recordingType == .voiceResponse {
      // Stop voice response
      stopVoiceResponseFromMenu()
    } else if isVoicePlaying {
      // Stop voice playback only
      audioPlaybackService?.stopPlayback()
      isVoicePlaying = false
      updateMenuState()
    } else if appMode.canStartNewRecording {
      // Start voice response
      startVoiceResponseFromMenu()
    }
  }

  func readSelectedText() {

    // Prevent conflicts with ongoing recordings
    if appMode.isRecording {
      DebugLogger.logWarning(
        "READ-SELECTED-TEXT: Another recording is in progress, ignoring request")
      return
    }

    // Check accessibility permission first
    if !AccessibilityPermissionManager.checkPermissionForPromptUsage() {
      DebugLogger.logWarning("READ-SELECTED-TEXT: Accessibility permission required")
      return
    }

    Task {
      do {
        let _ = try await speechService?.readSelectedTextAsSpeech()
      } catch {
        DebugLogger.logError("READ-SELECTED-TEXT: Error reading selected text: \(error)")
      }
    }
  }

  @objc private func readSelectedTextFromMenu() {
    readSelectedText()
  }

}
