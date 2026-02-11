import Cocoa
import Foundation
import HotKey
import SwiftUI
import AVFoundation

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
  
  // MARK: - State Tracking (Prevent Race Conditions)
  private var currentTranscriptionAudioURL: URL?
  private var processedAudioURLs: Set<URL> = []
  private var currentTTSAudioURL: URL?
  private var audioPlayer: AVAudioPlayer?
  private var audioEngine: AVAudioEngine?
  private var audioPlayerNode: AVAudioPlayerNode?
  private var timePitchNode: AVAudioUnitTimePitch?

  // MARK: - Configuration
  private var currentConfig: ShortcutConfig

  // MARK: - Chunk Progress Tracking
  private var chunkStatuses: [ChunkStatus] = []
  private var isProcessingTTS: Bool = false

  // MARK: - Live Meeting State
  private var liveMeetingRecorder: LiveMeetingRecorder?
  private var isLiveMeetingActive: Bool = false
  private var liveMeetingStopping: Bool = false
  private var liveMeetingTranscriptURL: URL?
  private var liveMeetingPendingChunks: Int = 0
  private var liveMeetingSessionStartTime: Date?
  private var liveMeetingSafeguardTimer: Timer?

  /// True when TTS is running in any phase: .ttsProcessing, or chunked phases (.splitting, .processingChunks, .merging) while isProcessingTTS is set.
  private var isTTSRunning: Bool {
    if case .processing(.ttsProcessing) = appState { return true }
    guard isProcessingTTS else { return false }
    switch appState {
    case .processing(.splitting), .processing(.merging): return true
    case .processing(.processingChunks): return true
    default: return false
    }
  }

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
        "Dictate", action: #selector(toggleTranscription),
        shortcut: currentConfig.startRecording, tag: 101))
    menu.addItem(
      createMenuItemWithShortcut(
        "Dictate Prompt", action: #selector(togglePrompting),
        shortcut: currentConfig.startPrompting, tag: 102))
    menu.addItem(
      createMenuItemWithShortcut(
        "Dictate Prompt & Read", action: #selector(readSelectedText),
        shortcut: currentConfig.readSelectedText, tag: 104))
    menu.addItem(
      createMenuItemWithShortcut(
        "Read Aloud", action: #selector(readAloud),
        shortcut: currentConfig.readAloud, tag: 105))

    menu.addItem(NSMenuItem.separator())

    // Live Meeting Transcription (no shortcut, menu-only)
    menu.addItem(
      createMenuItem("Transcribe Meeting", action: #selector(toggleLiveMeeting), tag: 107))
    menu.addItem(
      createMenuItem("Open Transcripts Folder", action: #selector(openTranscriptsFolder), tag: 108))

    menu.addItem(NSMenuItem.separator())

    // Conversation history management
    let historyCount = PromptConversationHistory.shared.totalTurnCount()
    let historyTitle = historyCount > 0
      ? "New Conversation (\(historyCount) messages)"
      : "New Conversation"
    let historyItem = createMenuItem(historyTitle, action: #selector(clearConversationHistory), tag: 106)
    historyItem.isEnabled = historyCount > 0
    menu.addItem(historyItem)

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
    let keyMap: [Key: String] = [
      .one: "1", .two: "2", .three: "3", .four: "4", .five: "5",
      .six: "6", .seven: "7", .eight: "8", .nine: "9", .zero: "0",
      .a: "a", .b: "b", .c: "c", .d: "d", .e: "e", .f: "f",
      .g: "g", .h: "h", .i: "i", .j: "j", .k: "k", .l: "l",
      .m: "m", .n: "n", .o: "o", .p: "p", .q: "q", .r: "r",
      .s: "s", .t: "t", .u: "u", .v: "v", .w: "w", .x: "x",
      .y: "y", .z: "z"
    ]
    return keyMap[key] ?? ""  // For function keys and special keys
  }

  private func setupDelegates() {
    audioRecorder.delegate = self
    shortcuts.delegate = self
    speechService.chunkProgressDelegate = self
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

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(rateLimitWaiting(_:)),
      name: .rateLimitWaiting,
      object: nil
    )

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(rateLimitResolved),
      name: .rateLimitResolved,
      object: nil
    )
  }

  private func loadModelConfiguration() {
    // Load saved model preference and set it on the transcription service
    let selectedModel = TranscriptionModel.loadSelected()
    speechService.setModel(selectedModel)

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

    // Show detailed chunk progress in tooltip during processing
    if case .processing(.processingChunks(let statuses)) = appState {
      let active = statuses.filter { $0 == .active }.count
      let done = statuses.filter { $0 == .completed }.count
      button.toolTip = "Transcribing [\(done)/\(statuses.count)] - \(active) active"
    } else {
      button.toolTip = appState.tooltip
    }
  }

  private func updateMenuItems() {
    guard let menu = statusItem?.menu else { return }

    let hasAPIKey = KeychainManager.shared.hasGoogleAPIKey()
    
    // Check for offline transcription models
    let selectedTranscriptionModel = TranscriptionModel.loadSelected()
    let hasOfflineTranscriptionModel = selectedTranscriptionModel.isOfflineModelAvailable()
    
    // Prompt mode always requires API key (no offline support)
    let hasOfflinePromptModel = false

    // Update status
    menu.item(withTag: 100)?.title = appState.statusText

    // Update action items based on current state
    updateMenuItem(
      menu, tag: 101,
      title: appState.recordingMode == .transcription
        ? "Stop Dictate" : "Dictate",
      enabled: appState.canStartTranscription(hasAPIKey: hasAPIKey, hasOfflineModel: hasOfflineTranscriptionModel)
        || appState.recordingMode == .transcription)

    updateMenuItem(
      menu, tag: 102,
      title: appState.recordingMode == .prompt ? "Stop Dictate Prompt" : "Dictate Prompt",
      enabled: appState.canStartPrompting(hasAPIKey: hasAPIKey, hasOfflineModel: hasOfflinePromptModel) 
        || appState.recordingMode == .prompt
    )
    
    updateMenuItem(
      menu, tag: 104,
      title: appState.recordingMode == .tts ? "Stop Dictate Prompt & Read" : "Dictate Prompt & Read",
      enabled: (hasAPIKey && !appState.isBusy) || appState.recordingMode == .tts
    )

    // Update conversation history item (title and enabled state reflect current count)
    let historyCount = PromptConversationHistory.shared.totalTurnCount()
    let historyTitle = historyCount > 0
      ? "New Conversation (\(historyCount) messages)"
      : "New Conversation"
    updateMenuItem(menu, tag: 106, title: historyTitle, enabled: historyCount > 0)

    // Update Live Meeting item
    let liveMeetingTitle = isLiveMeetingActive ? "Stop Transcribe Meeting" : "Transcribe Meeting"
    let liveMeetingEnabled = isLiveMeetingActive || (!appState.isBusy && hasAPIKey)
    updateMenuItem(menu, tag: 107, title: liveMeetingTitle, enabled: liveMeetingEnabled)

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
    // Check if currently processing transcription (incl. chunk phases for long audio) - if so, cancel it
    let isTranscriptionProcessing: Bool = {
      guard case .processing(let mode) = appState, !isProcessingTTS else { return false }
      switch mode {
      case .transcribing, .splitting, .processingChunks, .merging: return true
      case .prompting, .ttsProcessing: return false
      }
    }()
    if isTranscriptionProcessing {
      speechService.cancelTranscription()
      // Clean up the audio file immediately to prevent race conditions
      if let audioURL = currentTranscriptionAudioURL {
        cleanupAudioFile(at: audioURL)
        currentTranscriptionAudioURL = nil
        processedAudioURLs.remove(audioURL)
      }
      PopupNotificationWindow.dismissProcessing()
      appState = .idle
      // No notification shown - user initiated the cancellation
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
      let selectedModel = TranscriptionModel.loadSelected()
      let hasOfflineModel = selectedModel.isOfflineModelAvailable()
      
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
      // Clean up the audio file immediately to prevent race conditions
      // Note: For prompting, we don't track the URL separately, but we should still clean up
      // The processedAudioURLs set will prevent duplicate processing
      PopupNotificationWindow.dismissProcessing()
      appState = .idle
      // No notification shown - user initiated the cancellation
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

  @objc func clearConversationHistory() {
    PromptConversationHistory.shared.clearAll()
    DebugLogger.log("UI: Conversation history cleared by user")
    updateUI()
  }

  // MARK: - Live Meeting Transcription
  @objc func toggleLiveMeeting() {
    if isLiveMeetingActive {
      stopLiveMeeting()
    } else {
      startLiveMeeting()
    }
  }

  private func startLiveMeeting() {
    // Check API key
    guard KeychainManager.shared.hasGoogleAPIKey() else {
      PopupNotificationWindow.showError("API key required for live meeting transcription", title: "Missing API Key")
      return
    }

    // Check if busy with other operations
    guard !appState.isBusy else {
      DebugLogger.logWarning("LIVE-MEETING: Cannot start - app is busy")
      return
    }

    DebugLogger.log("LIVE-MEETING: Starting session")

    // Create transcript file
    do {
      liveMeetingTranscriptURL = try createTranscriptFile()
    } catch {
      DebugLogger.logError("LIVE-MEETING: Failed to create transcript file: \(error)")
      PopupNotificationWindow.showError("Failed to create transcript file", title: "Live Meeting Error")
      return
    }

    // Open transcript file with default app
    if let url = liveMeetingTranscriptURL {
      NSWorkspace.shared.open(url)
    }

    // Load chunk interval from settings
    let savedInterval = UserDefaults.standard.double(forKey: UserDefaultsKeys.liveMeetingChunkInterval)
    let chunkInterval: TimeInterval = savedInterval > 0 ? savedInterval : AppConstants.liveMeetingChunkIntervalDefault

    // Create and start recorder
    liveMeetingRecorder = LiveMeetingRecorder(chunkDuration: chunkInterval)
    liveMeetingRecorder?.delegate = self
    liveMeetingRecorder?.startSession()

    // Update state
    isLiveMeetingActive = true
    liveMeetingStopping = false
    liveMeetingPendingChunks = 0
    liveMeetingSessionStartTime = Date()
    appState = .recording(.liveMeeting)

    // Schedule duration safeguard if enabled
    let safeguardThreshold: MeetingSafeguardDuration
    if UserDefaults.standard.object(forKey: UserDefaultsKeys.liveMeetingSafeguardDurationSeconds) != nil,
       let t = MeetingSafeguardDuration(rawValue: UserDefaults.standard.double(forKey: UserDefaultsKeys.liveMeetingSafeguardDurationSeconds)) {
      safeguardThreshold = t
    } else {
      safeguardThreshold = SettingsDefaults.liveMeetingSafeguardDuration
    }
    if safeguardThreshold != .never {
      liveMeetingSafeguardTimer?.invalidate()
      liveMeetingSafeguardTimer = Timer.scheduledTimer(withTimeInterval: safeguardThreshold.rawValue, repeats: false) { [weak self] _ in
        self?.showLiveMeetingSafeguardAlert(thresholdMinutes: Int(safeguardThreshold.rawValue / 60))
      }
      if let timer = liveMeetingSafeguardTimer {
        RunLoop.main.add(timer, forMode: .common)
      }
      DebugLogger.log("LIVE-MEETING-SAFEGUARD: Reminder scheduled after \(Int(safeguardThreshold.rawValue / 60)) minutes")
    }

    DebugLogger.logSuccess("LIVE-MEETING: Session started")
  }

  private func showLiveMeetingSafeguardAlert(thresholdMinutes: Int) {
    liveMeetingSafeguardTimer?.invalidate()
    liveMeetingSafeguardTimer = nil

    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      if !self.isLiveMeetingActive {
        return
      }
      DebugLogger.log("LIVE-MEETING-SAFEGUARD: Showing duration prompt after \(thresholdMinutes) minutes")
      let alert = NSAlert()
      alert.messageText = "Long meeting"
      alert.informativeText = "This meeting has been transcribing for over \(thresholdMinutes) minutes. Stop or continue?"
      alert.alertStyle = .informational
      alert.addButton(withTitle: "Stop meeting")
      alert.addButton(withTitle: "Continue")
      let response = alert.runModal()
      if response == .alertFirstButtonReturn {
        DebugLogger.log("LIVE-MEETING-SAFEGUARD: User chose to stop meeting")
        self.stopLiveMeeting()
      } else {
        DebugLogger.log("LIVE-MEETING-SAFEGUARD: User chose to continue")
      }
    }
  }

  private func stopLiveMeeting() {
    DebugLogger.log("LIVE-MEETING: User requested stop")

    liveMeetingSafeguardTimer?.invalidate()
    liveMeetingSafeguardTimer = nil
    liveMeetingStopping = true
    liveMeetingRecorder?.stopSession()

    // If no pending chunks, finish immediately
    if liveMeetingPendingChunks == 0 {
      finishLiveMeetingSession()
    }
    // Otherwise, wait for pending chunks to complete (handled in delegate)
  }

  private func finishLiveMeetingSession() {
    DebugLogger.log("LIVE-MEETING: Session finished")

    liveMeetingSafeguardTimer?.invalidate()
    liveMeetingSafeguardTimer = nil
    isLiveMeetingActive = false
    liveMeetingStopping = false
    liveMeetingRecorder = nil
    liveMeetingPendingChunks = 0
    appState = .idle

    DebugLogger.logSuccess("LIVE-MEETING: Transcription saved")
  }

  @objc func openTranscriptsFolder() {
    let homeDir = FileManager.default.homeDirectoryForCurrentUser
    let transcriptsDir = homeDir
      .appendingPathComponent("Documents")
      .appendingPathComponent(AppConstants.liveMeetingTranscriptDirectory)
    
    // Create directory if it doesn't exist
    if !FileManager.default.fileExists(atPath: transcriptsDir.path) {
      do {
        try FileManager.default.createDirectory(at: transcriptsDir, withIntermediateDirectories: true)
      } catch {
        DebugLogger.logError("LIVE-MEETING: Failed to create transcripts folder: \(error)")
        return
      }
    }
    
    NSWorkspace.shared.open(transcriptsDir)
    DebugLogger.log("LIVE-MEETING: Opened transcripts folder")
  }

  private func createTranscriptFile() throws -> URL {
    // Use the real home directory Documents folder (not the sandbox container)
    // This ensures the file is accessible to external editors like Cursor
    let homeDir = FileManager.default.homeDirectoryForCurrentUser
    let documentsURL = homeDir.appendingPathComponent("Documents")
    let whisperShortcutDir = documentsURL.appendingPathComponent(AppConstants.liveMeetingTranscriptDirectory)

    // Create directory if it doesn't exist
    if !FileManager.default.fileExists(atPath: whisperShortcutDir.path) {
      try FileManager.default.createDirectory(at: whisperShortcutDir, withIntermediateDirectories: true)
    }

    // Create filename with timestamp
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd-HHmmss"
    let timestamp = formatter.string(from: Date())
    let filename = "Meeting-\(timestamp).txt"

    let fileURL = whisperShortcutDir.appendingPathComponent(filename)

    // Create empty file
    FileManager.default.createFile(atPath: fileURL.path, contents: nil)

    DebugLogger.log("LIVE-MEETING: Created transcript file at \(fileURL.path)")
    return fileURL
  }

  private func appendToTranscript(_ text: String, chunkStartTime: TimeInterval) {
    guard let url = liveMeetingTranscriptURL else { return }

    let showTimestamps = UserDefaults.standard.object(forKey: UserDefaultsKeys.liveMeetingShowTimestamps) != nil
      ? UserDefaults.standard.bool(forKey: UserDefaultsKeys.liveMeetingShowTimestamps)
      : AppConstants.liveMeetingShowTimestampsDefault

    var finalText = text.trimmingCharacters(in: .whitespacesAndNewlines)

    if showTimestamps {
      let timestamp = formatTimestamp(elapsedSeconds: chunkStartTime)
      finalText = "\(timestamp) \(finalText)"
    }

    // Add newlines for readability
    finalText = "\(finalText)\n\n"

    do {
      let handle = try FileHandle(forWritingTo: url)
      handle.seekToEndOfFile()
      if let data = finalText.data(using: .utf8) {
        handle.write(data)
      }
      try handle.close()
      DebugLogger.log("LIVE-MEETING: Appended chunk to transcript")
    } catch {
      DebugLogger.logError("LIVE-MEETING: Failed to append to transcript: \(error)")
    }
  }

  private func formatTimestamp(elapsedSeconds: TimeInterval) -> String {
    let minutes = Int(elapsedSeconds) / 60
    let seconds = Int(elapsedSeconds) % 60
    return String(format: "[%02d:%02d]", minutes, seconds)
  }
  
  @objc private func handleReadSelectedText() {
    let recordingModeStr = appState.recordingMode == .tts ? "tts" : String(describing: appState.recordingMode ?? .none)
    DebugLogger.logDebug("handleReadSelectedText called - appState: \(appState), recordingMode: \(recordingModeStr)")
    // Check if currently processing TTS (any phase: ttsProcessing, splitting, chunks, merging) - if so, cancel it
    if isTTSRunning {
      speechService.cancelTTS()
      stopTTSPlayback()
      isProcessingTTS = false
      PopupNotificationWindow.dismissProcessing()
      appState = .idle
      // No notification shown - user initiated the cancellation
      return
    }
    
    // Check if currently playing audio - if so, stop it
    if audioPlayer?.isPlaying == true || audioEngine?.isRunning == true {
      audioPlayer?.stop()
      audioPlayer = nil
      audioEngine?.stop()
      audioPlayerNode?.stop()
      audioEngine = nil
      audioPlayerNode = nil
      cleanupAudioFile(at: currentTTSAudioURL)
      currentTTSAudioURL = nil
      appState = .idle
      return
    }
    
    switch appState.recordingMode {
    case .tts:
      // Stop recording
      DebugLogger.logDebug("Stopping TTS recording (second press) - delay: \(Constants.audioTailCaptureDelay)")
      DispatchQueue.main.asyncAfter(deadline: .now() + Constants.audioTailCaptureDelay) { [weak self] in
        self?.audioRecorder.stopRecording()
      }
    case .none:
      // Check accessibility permission first
      if !AccessibilityPermissionManager.checkPermissionForPromptUsage() {
        return
      }

      // Start recording for voice command
      let hasAPIKey = KeychainManager.shared.hasGoogleAPIKey()
      if hasAPIKey {
        simulateCopyPaste()
        appState = appState.startRecording(.tts)
        DebugLogger.logDebug("Starting TTS recording - hasAPIKey: \(hasAPIKey)")
        audioRecorder.startRecording()
      } else {
        // No API key - try direct TTS without command
        performDirectTTS()
      }
    default:
      break
    }
  }
  
  private func performDirectTTS() {
    // Check if currently processing TTS (any phase: ttsProcessing, splitting, chunks, merging) - if so, cancel it
    if isTTSRunning {
      speechService.cancelTTS()
      stopTTSPlayback()
      isProcessingTTS = false
      PopupNotificationWindow.dismissProcessing()
      appState = .idle
      // No notification shown - user initiated the cancellation
      return
    }
    
    // Check if currently playing audio - if so, stop it
    if audioPlayer?.isPlaying == true || audioEngine?.isRunning == true {
      stopTTSPlayback()
      appState = .idle
      return
    }
    
    // Get selected text from clipboard
    guard let selectedText = clipboardManager.getCleanedClipboardText(),
          !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      PopupNotificationWindow.showError("No text selected", title: "TTS Error")
      return
    }
    
    appState = .processing(.ttsProcessing)
    isProcessingTTS = true
    
    Task {
      do {
        let audioData = try await speechService.readTextAloud(selectedText)
        UserContextLogger.shared.logReadAloud(text: selectedText, voice: nil)
        await MainActor.run {
          self.isProcessingTTS = false
          PopupNotificationWindow.dismissProcessing()
          self.playTTSAudio(audioData: audioData)
        }
      } catch is CancellationError {
        DebugLogger.log("CANCELLATION: TTS task was cancelled")
        await MainActor.run {
          self.isProcessingTTS = false
          PopupNotificationWindow.dismissProcessing()
          if self.appState != .idle { self.appState = .idle }
        }
      } catch {
        DebugLogger.logError("TTS-ERROR: Failed to generate speech: \(error.localizedDescription)")
        if let transcriptionError = error as? TranscriptionError {
          DebugLogger.logError("TTS-ERROR: TranscriptionError type: \(transcriptionError)")
        }
        await MainActor.run {
          self.isProcessingTTS = false
          PopupNotificationWindow.dismissProcessing()
          if self.appState != .idle {
            self.appState = self.appState.showError("TTS failed: \(error.localizedDescription)")
            PopupNotificationWindow.showError("Failed to generate speech: \(error.localizedDescription)", title: "TTS Error")
          }
        }
      }
    }
  }

  private func performTTSWithCommand(audioURL: URL) async {
    do {
      let fileSize = (try? FileManager.default.attributesOfItem(atPath: audioURL.path)[.size] as? Int64) ?? 0
      DebugLogger.logDebug("performTTSWithCommand started - audioURL: \(audioURL.lastPathComponent), fileSize: \(fileSize)")
      
      // Check if audio is likely empty before transcription
      let isEmpty = speechService.isAudioLikelyEmpty(at: audioURL)
      DebugLogger.logDebug("isAudioLikelyEmpty result - isEmpty: \(isEmpty)")
      if isEmpty {
        DebugLogger.log("TTS: Audio too short, skipping transcription, using direct TTS")
        // Clean up audio file
        cleanupAudioFile(at: audioURL)
        
        // Get selected text and proceed with direct TTS (same as empty command path)
        guard let selectedText = clipboardManager.getCleanedClipboardText(),
              !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
          await MainActor.run {
            self.appState = self.appState.showError("No text selected")
            PopupNotificationWindow.showError("No text selected", title: "TTS Error")
          }
          return
        }
        
        await MainActor.run {
          self.appState = .processing(.ttsProcessing)
          self.isProcessingTTS = true
        }
        
        let audioData = try await speechService.readTextAloud(selectedText)
        UserContextLogger.shared.logReadAloud(text: selectedText, voice: nil)
        await MainActor.run {
          self.isProcessingTTS = false
          PopupNotificationWindow.dismissProcessing()
          self.playTTSAudio(audioData: audioData)
        }
        return
      }

      // First, transcribe the audio to get the voice command
      let voiceCommand = try await speechService.transcribe(audioURL: audioURL)
      let trimmedCommand = voiceCommand.trimmingCharacters(in: .whitespacesAndNewlines)

      // Clean up transcription audio
      cleanupAudioFile(at: audioURL)

      // Get selected text from clipboard (may be nil for follow-up questions)
      let clipboardText = clipboardManager.getCleanedClipboardText()
      let selectedText = clipboardText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? clipboardText : nil
      let hasActiveHistory = PromptConversationHistory.shared.hasActiveHistory(for: .promptAndRead)

      DebugLogger.logDebug("TTS: selectedText=\(selectedText != nil ? "present (\(selectedText!.count) chars)" : "nil"), hasActiveHistory=\(hasActiveHistory), command=\(trimmedCommand.isEmpty ? "empty" : "present")")

      // Check if command is empty/null
      if trimmedCommand.isEmpty {
        // No command - direct TTS requires selected text
        guard let text = selectedText else {
          await MainActor.run {
            self.appState = self.appState.showError("No text selected")
            PopupNotificationWindow.showError("No text selected. Select text to read aloud, or speak a question for follow-up.", title: "Read Aloud")
          }
          return
        }

        DebugLogger.log("TTS: No voice command detected, using direct TTS")
        await MainActor.run {
          self.appState = .processing(.ttsProcessing)
          self.isProcessingTTS = true
        }

        let audioData = try await speechService.readTextAloud(text)
        UserContextLogger.shared.logReadAloud(text: text, voice: nil)
        await MainActor.run {
          self.isProcessingTTS = false
          PopupNotificationWindow.dismissProcessing()
          self.playTTSAudio(audioData: audioData)
        }
      } else {
        // Command exists - need either selected text OR active history for follow-up
        if selectedText == nil && !hasActiveHistory {
          await MainActor.run {
            self.appState = self.appState.showError("No text selected")
            PopupNotificationWindow.showError("No text selected and no conversation history. Select text first, then ask questions.", title: "Read Aloud")
          }
          return
        }

        if selectedText == nil {
          DebugLogger.log("TTS: Follow-up question (no new text, using conversation history)")
        }

        DebugLogger.log("TTS: Voice command detected: \(trimmedCommand)")
        await MainActor.run {
          self.appState = .processing(.prompting)
        }

        // Apply prompt mode: selected text (may be nil) + command
        let promptResult = try await speechService.executePromptWithText(textCommand: trimmedCommand, selectedText: selectedText, mode: .promptAndRead)

        // Now TTS the result using Prompt & Read voice
        await MainActor.run {
          self.appState = .processing(.ttsProcessing)
          self.isProcessingTTS = true
        }

        // Get Prompt & Read voice from UserDefaults
        let promptAndReadVoice = UserDefaults.standard.string(forKey: UserDefaultsKeys.selectedPromptAndReadVoice) ?? SettingsDefaults.selectedPromptAndReadVoice
        let audioData = try await speechService.readTextAloud(promptResult, voiceName: promptAndReadVoice)
        await MainActor.run {
          self.isProcessingTTS = false
          PopupNotificationWindow.dismissProcessing()
          self.playTTSAudio(audioData: audioData)
        }
      }
    } catch is CancellationError {
      DebugLogger.log("CANCELLATION: TTS task was cancelled")
      await MainActor.run {
        self.isProcessingTTS = false
        PopupNotificationWindow.dismissProcessing()
        if self.appState != .idle { self.appState = .idle }
      }
      cleanupAudioFile(at: audioURL)
    } catch {
      DebugLogger.logError("TTS-ERROR: Failed to process TTS request: \(error.localizedDescription)")
      if let transcriptionError = error as? TranscriptionError {
        DebugLogger.logError("TTS-ERROR: TranscriptionError type: \(transcriptionError)")
      }
      await MainActor.run {
        self.isProcessingTTS = false
        PopupNotificationWindow.dismissProcessing()
        if self.appState != .idle {
          self.appState = self.appState.showError("TTS failed: \(error.localizedDescription)")
          PopupNotificationWindow.showError("Failed to process: \(error.localizedDescription)", title: "TTS Error")
        }
      }
      cleanupAudioFile(at: audioURL)
    }
  }
  
  private func playTTSAudio(audioData: Data) {
    DebugLogger.log("TTS-PLAYBACK: Starting audio playback (data size: \(audioData.count) bytes)")

    // PCM format: 16-bit signed little-endian, 24kHz, mono
    let sampleRate: Double = 24000
    let channels: UInt32 = 1
    let bitsPerChannel: UInt32 = 16
    
    do {
      // Create audio format
      guard let audioFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: sampleRate,
        channels: channels,
        interleaved: false
      ) else {
        DebugLogger.logError("TTS-PLAYBACK: Failed to create audio format")
        throw NSError(domain: "TTS", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create audio format"])
      }
      
      // Calculate frame count
      let bytesPerFrame = Int(channels * (bitsPerChannel / 8))
      let frameCount = audioData.count / bytesPerFrame

      // Create PCM buffer
      guard let buffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: AVAudioFrameCount(frameCount)) else {
        DebugLogger.logError("TTS-PLAYBACK: Failed to create audio buffer")
        throw NSError(domain: "TTS", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to create audio buffer"])
      }
      
      buffer.frameLength = AVAudioFrameCount(frameCount)
      
      // Copy PCM data to buffer
      audioData.withUnsafeBytes { bytes in
        guard let baseAddress = bytes.baseAddress else { return }
        let int16Pointer = baseAddress.assumingMemoryBound(to: Int16.self)
        
        // Copy to buffer's channel data
        if let channelData = buffer.int16ChannelData {
          for i in 0..<frameCount {
            channelData[0][i] = int16Pointer[i]
          }
        }
      }

      // Stop any existing playback
      if let existingEngine = audioEngine {
        existingEngine.stop()
        audioEngine = nil
      }
      if let existingNode = audioPlayerNode {
        existingNode.stop()
        audioPlayerNode = nil
      }
      
      // Read playback rate from settings (clamp to valid range)
      let rate: Float
      if UserDefaults.standard.object(forKey: UserDefaultsKeys.readAloudPlaybackRate) != nil {
        let saved = UserDefaults.standard.float(forKey: UserDefaultsKeys.readAloudPlaybackRate)
        rate = min(max(saved, SettingsDefaults.readAloudPlaybackRateMin), SettingsDefaults.readAloudPlaybackRateMax)
      } else {
        rate = SettingsDefaults.readAloudPlaybackRate
      }

      // AVAudioUnitTimePitch does not accept Int16; use Float32 for rate != 1.0 to avoid crash on connect.
      let playbackBuffer: AVAudioPCMBuffer
      let playbackFormat: AVAudioFormat
      if rate != 1.0 {
        guard let floatFormat = AVAudioFormat(
          commonFormat: .pcmFormatFloat32,
          sampleRate: sampleRate,
          channels: channels,
          interleaved: false
        ) else {
          DebugLogger.logError("TTS-PLAYBACK: Failed to create Float32 format")
          throw NSError(domain: "TTS", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to create Float32 format"])
        }
        guard let floatBuffer = AVAudioPCMBuffer(pcmFormat: floatFormat, frameCapacity: AVAudioFrameCount(frameCount)) else {
          DebugLogger.logError("TTS-PLAYBACK: Failed to create Float32 buffer")
          throw NSError(domain: "TTS", code: 4, userInfo: [NSLocalizedDescriptionKey: "Failed to create Float32 buffer"])
        }
        floatBuffer.frameLength = AVAudioFrameCount(frameCount)
        audioData.withUnsafeBytes { bytes in
          guard let baseAddress = bytes.baseAddress else { return }
          let int16Pointer = baseAddress.assumingMemoryBound(to: Int16.self)
          if let floatChannelData = floatBuffer.floatChannelData {
            for i in 0..<frameCount {
              floatChannelData[0][i] = Float(int16Pointer[i]) / 32768.0
            }
          }
        }
        playbackBuffer = floatBuffer
        playbackFormat = floatFormat
      } else {
        playbackBuffer = buffer
        playbackFormat = buffer.format
      }

      // Create audio engine for playback; use TimePitch when rate != 1.0 (more reliable on macOS)
      let engine = AVAudioEngine()
      let playerNode = AVAudioPlayerNode()
      engine.attach(playerNode)

      if rate != 1.0 {
        let pitchNode = AVAudioUnitTimePitch()
        pitchNode.rate = rate
        pitchNode.pitch = 0  // no additional pitch shift
        engine.attach(pitchNode)
        engine.connect(playerNode, to: pitchNode, format: playbackFormat)
        engine.connect(pitchNode, to: engine.mainMixerNode, format: playbackFormat)
        self.timePitchNode = pitchNode
      } else {
        engine.connect(playerNode, to: engine.mainMixerNode, format: buffer.format)
        self.timePitchNode = nil
      }

      // Store references to prevent deallocation
      self.audioEngine = engine
      self.audioPlayerNode = playerNode

      try engine.start()

      // Schedule buffer for playback (use playbackBuffer: Float32 when rate != 1.0, else Int16)
      playerNode.scheduleBuffer(playbackBuffer) {
        DebugLogger.log("TTS-PLAYBACK: Playback completed")
        Task { @MainActor in
          self.audioPlayerNode?.stop()
          self.audioEngine?.stop()
          self.audioEngine = nil
          self.audioPlayerNode = nil
          self.timePitchNode = nil
          self.audioPlayer = nil
          self.currentTTSAudioURL = nil
          self.appState = self.appState.showSuccess("Audio playback completed")
          try? await Task.sleep(nanoseconds: 2_000_000_000) // 2.0 seconds
          if case .feedback = self.appState {
            self.appState = .idle
          }
        }
      }
      playerNode.play()
      DebugLogger.logSuccess("TTS-PLAYBACK: Playback started")
      appState = appState.showSuccess("Playing audio...")
      
    } catch {
      DebugLogger.logError("TTS-PLAYBACK: Failed to play audio: \(error.localizedDescription)")
      appState = appState.showError("Failed to play audio: \(error.localizedDescription)")
      currentTTSAudioURL = nil
      audioEngine = nil
      audioPlayerNode = nil
    }
  }

  @objc private func quitApp() {
    // Set flag to indicate user wants to quit completely
    UserDefaults.standard.set(true, forKey: UserDefaultsKeys.shouldTerminate)
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
      // Dismiss any processing popup before showing error
      PopupNotificationWindow.dismissProcessing()

      // Log error to file (replaces CrashLogger)
      DebugLogger.logError(error, context: "Processing error for \(mode)", state: self.appState)

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
          case .tts:
            await self.performTTSWithCommand(audioURL: audioURL)
          case .liveMeeting:
            // Live meeting chunks are handled separately, no retry needed here
            break
          }
        }
      } : nil
      
      // Define dismiss action (only for non-retryable errors)
      let dismissAction: (() -> Void)? = isRetryable ? nil : {
        self.cleanupAudioFile(at: audioURL)
      }
      
      // Set error state
      self.appState = self.appState.showError(errorMessage)
      
      // Show error popup notification with retry option if applicable
      PopupNotificationWindow.showError(errorMessage, title: shortTitle, retryAction: retryAction, dismissAction: dismissAction)
      
      // Clean up non-retryable errors immediately
      if !isRetryable {
        cleanupAudioFile(at: audioURL)
      }
    }
  }
  
  private func performTranscription(audioURL: URL) async {
    do {
      let result = try await speechService.transcribe(audioURL: audioURL)
      clipboardManager.copyToClipboard(text: result)
      UserContextLogger.shared.logTranscription(result: result, model: await speechService.getTranscriptionModelInfo())

      // Auto-paste if enabled
      await MainActor.run {
        self.autoPasteIfEnabled()
      }

      // Record successful operation for review prompt
      reviewPrompter.recordSuccessfulOperation(window: statusItem?.button?.window)

      // Get model info asynchronously before UI update
      let modelInfo = await self.speechService.getTranscriptionModelInfo()
      
      await MainActor.run {
        // Dismiss any processing popup before showing result
        PopupNotificationWindow.dismissProcessing()
        // Show popup notification with the transcription text and model info
        PopupNotificationWindow.showTranscriptionResponse(result, modelInfo: modelInfo)
        self.appState = self.appState.showSuccess("Transcription copied to clipboard")
        // Clear chunk statuses and tracking after successful completion
        self.chunkStatuses = []
        if self.currentTranscriptionAudioURL == audioURL {
          self.currentTranscriptionAudioURL = nil
        }
        self.processedAudioURLs.remove(audioURL)
      }
      
      // Cleanup on success
      cleanupAudioFile(at: audioURL)
    } catch is CancellationError {
      // Task was cancelled - just cleanup and return to idle
      DebugLogger.log("CANCELLATION: Transcription task was cancelled")
      await MainActor.run {
        // Dismiss any processing popup
        PopupNotificationWindow.dismissProcessing()
        self.appState = .idle
        // Clear chunk statuses and tracking on cancellation
        self.chunkStatuses = []
        if self.currentTranscriptionAudioURL == audioURL {
          self.currentTranscriptionAudioURL = nil
        }
        self.processedAudioURLs.remove(audioURL)
      }
      // Cleanup on cancellation
      cleanupAudioFile(at: audioURL)
    } catch {
      await handleProcessingError(error: error, audioURL: audioURL, mode: .transcription)
      // Clear chunk statuses and tracking on error (file will be cleaned up in handleProcessingError if needed)
      await MainActor.run {
        self.chunkStatuses = []
        if self.currentTranscriptionAudioURL == audioURL {
          self.currentTranscriptionAudioURL = nil
        }
        self.processedAudioURLs.remove(audioURL)
      }
    }
  }

  private func performPrompting(audioURL: URL) async {
    do {
      let result = try await speechService.executePrompt(audioURL: audioURL, mode: .togglePrompting)
      clipboardManager.copyToClipboard(text: result)

      // Auto-paste if enabled
      await MainActor.run {
        self.autoPasteIfEnabled()
      }

      // Record successful operation for review prompt
      reviewPrompter.recordSuccessfulOperation(window: statusItem?.button?.window)

      await MainActor.run {
        // Show popup notification with the response text and model info
        let modelInfo = self.speechService.getPromptModelInfo()
        PopupNotificationWindow.showPromptResponse(result, modelInfo: modelInfo)
        self.appState = self.appState.showSuccess("AI response copied to clipboard")
        // Clear tracking after successful completion
        self.processedAudioURLs.remove(audioURL)
      }
      
      // Cleanup on success
      cleanupAudioFile(at: audioURL)
    } catch is CancellationError {
      // Task was cancelled - just cleanup and return to idle
      DebugLogger.log("CANCELLATION: Prompt task was cancelled")
      await MainActor.run {
        self.appState = .idle
        // Clear tracking on cancellation
        self.processedAudioURLs.remove(audioURL)
      }
      // Cleanup on cancellation
      cleanupAudioFile(at: audioURL)
    } catch {
      await handleProcessingError(error: error, audioURL: audioURL, mode: .prompt)
      // Clear tracking on error (file will be cleaned up in handleProcessingError if needed)
      await MainActor.run {
        self.processedAudioURLs.remove(audioURL)
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

  @objc private func rateLimitWaiting(_ notification: Notification) {
    guard let waitTime = notification.userInfo?["waitTime"] as? TimeInterval else { return }
    let waitSeconds = Int(ceil(waitTime))
    DebugLogger.log("MENU-BAR: Rate limit detected, showing wait notification for \(waitSeconds)s")
    PopupNotificationWindow.showProcessing(
      "Rate limited by API. Automatically retrying in \(waitSeconds) seconds...",
      title: "⏳ Waiting for API"
    )
  }

  @objc private func rateLimitResolved() {
    DebugLogger.log("MENU-BAR: Rate limit wait complete, dismissing notification")
    PopupNotificationWindow.dismissProcessing()
  }

  // MARK: - Utility
  /// Safely removes an audio file, logging any errors
  private func cleanupAudioFile(at url: URL?) {
    guard let url = url else { return }
    do {
      try FileManager.default.removeItem(at: url)
      DebugLogger.logDebug("Cleaned up audio file: \(url.lastPathComponent)")
    } catch {
      DebugLogger.logWarning("Failed to clean up audio file \(url.lastPathComponent): \(error.localizedDescription)")
    }
  }
  
  /// Stops all TTS audio playback and cleans up resources
  private func stopTTSPlayback() {
    audioPlayer?.stop()
    audioPlayer = nil
    audioPlayerNode?.stop()
    audioEngine?.stop()
    audioEngine = nil
    audioPlayerNode = nil
    timePitchNode = nil
    cleanupAudioFile(at: currentTTSAudioURL)
    currentTTSAudioURL = nil
  }
  
  private func simulateCopyPaste() {
    // Use HID system state so Cmd+C is delivered to the frontmost app (the one with the selection)
    let source = CGEventSource(stateID: .hidSystemState)
    let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: true)
    let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: false)

    cmdDown?.flags = .maskCommand
    cmdUp?.flags = .maskCommand

    cmdDown?.post(tap: .cghidEventTap)
    cmdUp?.post(tap: .cghidEventTap)
  }

  /// Simulates Cmd+V paste keystroke to paste clipboard contents at cursor position
  private func simulatePaste() {
    // Use HID system state so Cmd+V is delivered to the frontmost app
    let source = CGEventSource(stateID: .hidSystemState)
    // Virtual key 0x09 is 'V'
    let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
    let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)

    cmdDown?.flags = .maskCommand
    cmdUp?.flags = .maskCommand

    cmdDown?.post(tap: .cghidEventTap)
    cmdUp?.post(tap: .cghidEventTap)
  }

  /// Performs auto-paste if enabled in settings
  private func autoPasteIfEnabled() {
    let autoPasteEnabled = UserDefaults.standard.bool(forKey: UserDefaultsKeys.autoPasteAfterDictation)
    if autoPasteEnabled {
      // Small delay to ensure clipboard is ready
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
        self?.simulatePaste()
        DebugLogger.log("AUTO-PASTE: Pasted transcription at cursor position")
      }
    }
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
    let fileSize = (try? FileManager.default.attributesOfItem(atPath: audioURL.path)[.size] as? Int64) ?? 0
    let recordingModeStr = appState.recordingMode == .tts ? "tts" : String(describing: appState.recordingMode ?? .none)
    DebugLogger.logDebug("audioRecorderDidFinishRecording called - audioURL: \(audioURL.lastPathComponent), fileSize: \(fileSize), appState: \(appState), recordingMode: \(recordingModeStr)")

    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      // Prevent processing the same audio file multiple times (race condition protection)
      guard !self.processedAudioURLs.contains(audioURL) else {
        DebugLogger.logWarning("AUDIO: Ignoring duplicate audioRecorderDidFinishRecording for \(audioURL.lastPathComponent)")
        return
      }

      guard case .recording(let recordingMode) = self.appState else {
        DebugLogger.logWarning("AUDIO: audioRecorderDidFinishRecording called but appState is not recording")
        return
      }

      // Recording safeguard: confirm above duration (same pattern as AccessibilityPermissionManager)
      let threshold: ConfirmAboveDuration
      if UserDefaults.standard.object(forKey: UserDefaultsKeys.confirmAboveDurationSeconds) != nil,
         let t = ConfirmAboveDuration(rawValue: UserDefaults.standard.double(forKey: UserDefaultsKeys.confirmAboveDurationSeconds))
      {
        threshold = t
      } else {
        threshold = SettingsDefaults.confirmAboveDuration
      }

      if threshold != .never,
         let duration = self.speechService.getAudioDuration(url: audioURL),
         duration > threshold.rawValue
      {
        let mins = Int(duration) / 60
        let secs = Int(duration) % 60
        let timeStr = secs > 0 ? "\(mins) min \(secs) s" : "\(mins) min"
        let alert = NSAlert()
        alert.messageText = "Long recording"
        alert.informativeText = "This recording is \(timeStr) long. Process anyway? (API usage may incur costs.)"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Process")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        if response != .alertFirstButtonReturn {
          DebugLogger.log("RECORDING-SAFEGUARD: User cancelled processing for long recording (\(timeStr))")
          self.cleanupAudioFile(at: audioURL)
          self.appState = .idle
          return
        }
      }

      // Mark this URL as processed to prevent duplicate processing
      self.processedAudioURLs.insert(audioURL)

      if recordingMode == .transcription {
        self.currentTranscriptionAudioURL = audioURL
      } else if recordingMode == .tts {
        self.currentTTSAudioURL = audioURL
      }

      self.appState = self.appState.stopRecording()

      Task {
        switch recordingMode {
        case .transcription:
          await self.performTranscription(audioURL: audioURL)
        case .prompt:
          await self.performPrompting(audioURL: audioURL)
        case .tts:
          await self.performTTSWithCommand(audioURL: audioURL)
        case .liveMeeting:
          // Live meeting uses its own recorder (LiveMeetingRecorder), not the standard AudioRecorder
          // This case should not be reached, but handle gracefully
          DebugLogger.logWarning("AUDIO: Unexpected liveMeeting recording in standard AudioRecorderDelegate")
          self.cleanupAudioFile(at: audioURL)
        }
      }
    }
  }

  func audioRecorderDidFailWithError(_ error: Error) {
    let errorCode = (error as NSError).code
    let errorDomain = (error as NSError).domain
    DebugLogger.logDebug("audioRecorderDidFailWithError called - errorCode: \(errorCode), errorDomain: \(errorDomain), errorDescription: \(error.localizedDescription), appState: \(appState), isEmptyFileError: \(errorCode == 1004)")
    appState = appState.showError("Recording failed: \(error.localizedDescription)")
  }
}

// MARK: - ShortcutDelegate (Simple Forwarding)
extension MenuBarController: ShortcutDelegate {
  func toggleDictation() { toggleTranscription() }
  // togglePrompting is already implemented above
  @objc func readSelectedText() { handleReadSelectedText() }
  @objc func readAloud() {
    // If TTS is running (synthesizing or chunked phases), cancel immediately without Cmd+C or delay
    if isTTSRunning {
      speechService.cancelTTS()
      stopTTSPlayback()
      isProcessingTTS = false
      PopupNotificationWindow.dismissProcessing()
      appState = .idle
      // No notification shown - user initiated the cancellation
      return
    }
    // If audio is playing, stop it
    if audioPlayer?.isPlaying == true || audioEngine?.isRunning == true {
      stopTTSPlayback()
      appState = .idle
      return
    }
    // Check accessibility permission first (required for simulateCopyPaste)
    if !AccessibilityPermissionManager.checkPermissionForPromptUsage() {
      return
    }
    // Defer copy + TTS to next run loop so hotkey handler returns first and the app with the selection keeps focus for Cmd+C
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.simulateCopyPaste()
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
        self?.performDirectTTS()
      }
    }
  }
  // openSettings is already implemented above
}

// MARK: - ChunkProgressDelegate (Chunked Transcription Progress)
extension MenuBarController: ChunkProgressDelegate {

  /// Generate status grid string for popup display
  /// Example: "1:● 2:◐ 3:◐ 4:○"
  private func generateStatusGrid() -> String {
    return chunkStatuses.enumerated().map { index, status in
      "\(index + 1):\(status.symbol)"
    }.joined(separator: " ")
  }

  func chunkingStarted(totalChunks: Int) {
    // Initialize all chunks as pending
    chunkStatuses = Array(repeating: .pending, count: totalChunks)

    // Check if this is TTS or transcription
    let isTTS = isProcessingTTS

    // Update app state to show splitting phase (but preserve TTS context)
    if isTTS {
      // For TTS, we'll use a custom approach - keep ttsProcessing but show splitting
      // Actually, let's use splitting but remember it's TTS via a different mechanism
      appState = .processing(.splitting)
    } else {
      appState = .processing(.splitting)
    }
    updateMenuBarIcon()

    // Show persistent processing popup with appropriate message
    if isTTS {
      PopupNotificationWindow.showProcessing(
        "Splitting text into \(totalChunks) chunks...",
        title: "Processing Long Text"
      )
    } else {
      PopupNotificationWindow.showProcessing(
        "Splitting audio into \(totalChunks) chunks...",
        title: "Processing Long Audio"
      )
    }

    DebugLogger.log("CHUNK-PROGRESS: Started chunking, \(totalChunks) total chunks (TTS: \(isTTS))")
  }

  func chunkStarted(index: Int) {
    guard index >= 0 && index < chunkStatuses.count else { return }

    // Mark chunk as active
    chunkStatuses[index] = .active

    // Update app state with new statuses
    appState = .processing(.processingChunks(statuses: chunkStatuses))
    updateMenuBarIcon()

    // Check if this is TTS or transcription
    let isTTS = isProcessingTTS

    // Update processing popup with status grid
    let statusGrid = generateStatusGrid()
    PopupNotificationWindow.updateProcessing(
      title: isTTS ? "Synthesizing Speech" : "Processing Audio",
      message: statusGrid
    )

    DebugLogger.log("CHUNK-PROGRESS: Chunk \(index) started processing")
  }

  func chunkProgressUpdated(completed: Int, total: Int) {
    // This is now a fallback/summary - individual states tracked via other callbacks
    updateMenuBarIcon()
    DebugLogger.log("CHUNK-PROGRESS: \(completed)/\(total) chunks complete")
  }

  func chunkCompleted(index: Int, text: String) {
    guard index >= 0 && index < chunkStatuses.count else { return }

    // Mark chunk as completed
    chunkStatuses[index] = .completed

    // Update app state
    appState = .processing(.processingChunks(statuses: chunkStatuses))
    updateMenuBarIcon()

    // Check if this is TTS or transcription
    let isTTS = isProcessingTTS

    // Update processing popup with status grid
    let statusGrid = generateStatusGrid()
    PopupNotificationWindow.updateProcessing(
      title: isTTS ? "Synthesizing Speech" : "Processing Audio",
      message: statusGrid
    )

    DebugLogger.log("CHUNK-PROGRESS: Chunk \(index) completed (\(text.prefix(50))...)")
  }

  func chunkFailed(index: Int, error: Error, willRetry: Bool) {
    guard index >= 0 && index < chunkStatuses.count else { return }

    if willRetry {
      // Keep as active (will be re-started via chunkStarted)
      DebugLogger.logWarning("CHUNK-PROGRESS: Chunk \(index) failed, retrying...")

      // Update popup to show retry status
      let statusGrid = generateStatusGrid()
      PopupNotificationWindow.updateProcessing(
        title: "Processing Audio",
        message: "\(statusGrid)\nRetrying chunk \(index + 1)..."
      )
    } else {
      // Mark as permanently failed
      chunkStatuses[index] = .failed

      // Update app state
      appState = .processing(.processingChunks(statuses: chunkStatuses))
      updateMenuBarIcon()

      // Update processing popup
      let statusGrid = generateStatusGrid()
      PopupNotificationWindow.updateProcessing(
        title: "Processing Audio",
        message: statusGrid
      )

      DebugLogger.logError("CHUNK-PROGRESS: Chunk \(index) failed: \(error.localizedDescription)")
      // Log to file (replaces CrashLogger)
      DebugLogger.logError(error, context: "Chunk \(index) transcription failed", state: appState)
    }
  }

  func mergingStarted() {
    // Clear chunk statuses (no longer needed for display)
    chunkStatuses = []

    // Check if this is TTS or transcription
    let isTTS = isProcessingTTS

    // Update app state to show merging phase
    appState = .processing(.merging)
    updateMenuBarIcon()

    // Update processing popup with appropriate message
    if isTTS {
      PopupNotificationWindow.updateProcessing(
        title: "Almost Done",
        message: "Merging audio chunks..."
      )
    } else {
      PopupNotificationWindow.updateProcessing(
        title: "Almost Done",
        message: "Merging transcription results..."
      )
    }

    DebugLogger.log("CHUNK-PROGRESS: Merging \(isTTS ? "audio chunks" : "transcripts")...")
  }
}

// MARK: - LiveMeetingRecorderDelegate
extension MenuBarController: LiveMeetingRecorderDelegate {
  func liveMeetingRecorder(didFinishChunk audioURL: URL, chunkIndex: Int, startTime: TimeInterval) {
    DebugLogger.log("LIVE-MEETING: Received chunk \(chunkIndex) at \(formatTimestamp(elapsedSeconds: startTime))")

    liveMeetingPendingChunks += 1

    Task {
      do {
        // Transcribe the chunk
        let text = try await speechService.transcribe(audioURL: audioURL)

        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmedText.isEmpty {
          DebugLogger.log("LIVE-MEETING: Chunk \(chunkIndex) skipped (silent)")
        } else {
          // Append to transcript on main thread
          await MainActor.run {
            self.appendToTranscript(trimmedText, chunkStartTime: startTime)
          }
        }

        // Cleanup audio file
        cleanupAudioFile(at: audioURL)

      } catch {
        DebugLogger.logError("LIVE-MEETING: Chunk \(chunkIndex) transcription failed: \(error)")
        // Don't abort the session - just log the error and continue
        cleanupAudioFile(at: audioURL)
      }

      await MainActor.run {
        self.liveMeetingPendingChunks -= 1

        // Check if session should end
        if self.liveMeetingStopping && self.liveMeetingPendingChunks == 0 {
          self.finishLiveMeetingSession()
        }
      }
    }
  }

  func liveMeetingRecorder(didFailWithError error: Error) {
    DebugLogger.logError("LIVE-MEETING: Recorder error: \(error)")

    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }

      // Don't abort immediately - just log the error
      // If it's a critical error, the recorder will stop on its own
      if !self.isLiveMeetingActive {
        return
      }

      // Show error but don't stop the session
      PopupNotificationWindow.showError("Recording error: \(error.localizedDescription)", title: "Live Meeting")
    }
  }
}
