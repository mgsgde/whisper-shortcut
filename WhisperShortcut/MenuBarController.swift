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
    button.toolTip = appState.tooltip
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
      // Clean up the audio file immediately to prevent race conditions
      if let audioURL = currentTranscriptionAudioURL {
        try? FileManager.default.removeItem(at: audioURL)
        currentTranscriptionAudioURL = nil
        processedAudioURLs.remove(audioURL)
      }
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
  
  @objc private func handleReadSelectedText() {
    // #region agent log
    let logData: [String: Any] = [
      "sessionId": "debug-session",
      "runId": "run1",
      "hypothesisId": "A",
      "location": "MenuBarController.swift:418",
      "message": "handleReadSelectedText called",
      "data": [
        "appState": "\(appState)",
        "recordingMode": appState.recordingMode == .tts ? "tts" : "\(appState.recordingMode)"
      ],
      "timestamp": Int64(Date().timeIntervalSince1970 * 1000)
    ]
    if let logFile = FileHandle(forWritingAtPath: "/Users/mgsgde/whisper-shortcut/.cursor/debug.log") {
      try? logFile.seekToEnd()
      try? logFile.write(Data((try? JSONSerialization.data(withJSONObject: logData)) ?? Data()))
      try? logFile.write(Data("\n".utf8))
      try? logFile.close()
    } else {
      try? (try? JSONSerialization.data(withJSONObject: logData))?.write(to: URL(fileURLWithPath: "/Users/mgsgde/whisper-shortcut/.cursor/debug.log"), options: .atomic)
    }
    // #endregion
    // Check if currently processing TTS - if so, cancel it
    if case .processing(.ttsProcessing) = appState {
      speechService.cancelTTS()
      audioPlayer?.stop()
      audioPlayer = nil
      audioEngine?.stop()
      audioPlayerNode?.stop()
      audioEngine = nil
      audioPlayerNode = nil
      if let audioURL = currentTTSAudioURL {
        try? FileManager.default.removeItem(at: audioURL)
        currentTTSAudioURL = nil
      }
      appState = .idle
      PopupNotificationWindow.showCancelled("TTS cancelled")
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
      if let audioURL = currentTTSAudioURL {
        try? FileManager.default.removeItem(at: audioURL)
        currentTTSAudioURL = nil
      }
      appState = .idle
      return
    }
    
    switch appState.recordingMode {
    case .tts:
      // Stop recording
      // #region agent log
      let logData3: [String: Any] = [
        "sessionId": "debug-session",
        "runId": "run1",
        "hypothesisId": "A",
        "location": "MenuBarController.swift:455",
        "message": "Stopping TTS recording (second press)",
        "data": ["delay": Constants.audioTailCaptureDelay],
        "timestamp": Int64(Date().timeIntervalSince1970 * 1000)
      ]
      if let logFile = FileHandle(forWritingAtPath: "/Users/mgsgde/whisper-shortcut/.cursor/debug.log") {
        try? logFile.seekToEnd()
        try? logFile.write(Data((try? JSONSerialization.data(withJSONObject: logData3)) ?? Data()))
        try? logFile.write(Data("\n".utf8))
        try? logFile.close()
      } else {
        try? (try? JSONSerialization.data(withJSONObject: logData3))?.write(to: URL(fileURLWithPath: "/Users/mgsgde/whisper-shortcut/.cursor/debug.log"), options: .atomic)
      }
      // #endregion
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
        // #region agent log
        let logData2: [String: Any] = [
          "sessionId": "debug-session",
          "runId": "run1",
          "hypothesisId": "A",
          "location": "MenuBarController.swift:469",
          "message": "Starting TTS recording",
          "data": ["hasAPIKey": hasAPIKey],
          "timestamp": Int64(Date().timeIntervalSince1970 * 1000)
        ]
        if let logFile = FileHandle(forWritingAtPath: "/Users/mgsgde/whisper-shortcut/.cursor/debug.log") {
          try? logFile.seekToEnd()
          try? logFile.write(Data((try? JSONSerialization.data(withJSONObject: logData2)) ?? Data()))
          try? logFile.write(Data("\n".utf8))
          try? logFile.close()
        } else {
          try? (try? JSONSerialization.data(withJSONObject: logData2))?.write(to: URL(fileURLWithPath: "/Users/mgsgde/whisper-shortcut/.cursor/debug.log"), options: .atomic)
        }
        // #endregion
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
    // Check if currently processing TTS - if so, cancel it
    if case .processing(.ttsProcessing) = appState {
      speechService.cancelTTS()
      audioPlayer?.stop()
      audioPlayer = nil
      audioEngine?.stop()
      audioPlayerNode?.stop()
      audioEngine = nil
      audioPlayerNode = nil
      if let audioURL = currentTTSAudioURL {
        try? FileManager.default.removeItem(at: audioURL)
        currentTTSAudioURL = nil
      }
      appState = .idle
      PopupNotificationWindow.showCancelled("TTS cancelled")
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
      if let audioURL = currentTTSAudioURL {
        try? FileManager.default.removeItem(at: audioURL)
        currentTTSAudioURL = nil
      }
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
    
    Task {
      do {
        let audioData = try await speechService.readTextAloud(selectedText)
        await MainActor.run {
          self.playTTSAudio(audioData: audioData)
        }
      } catch {
        DebugLogger.logError("TTS-ERROR: Failed to generate speech: \(error.localizedDescription)")
        if let transcriptionError = error as? TranscriptionError {
          DebugLogger.logError("TTS-ERROR: TranscriptionError type: \(transcriptionError)")
        }
        await MainActor.run {
          self.appState = self.appState.showError("TTS failed: \(error.localizedDescription)")
          PopupNotificationWindow.showError("Failed to generate speech: \(error.localizedDescription)", title: "TTS Error")
        }
      }
    }
  }
  
  private func performTTSWithCommand(audioURL: URL) async {
    do {
      // #region agent log
      let fileSize = (try? FileManager.default.attributesOfItem(atPath: audioURL.path)[.size] as? Int64) ?? 0
      let logData: [String: Any] = [
        "sessionId": "debug-session",
        "runId": "run1",
        "hypothesisId": "D",
        "location": "MenuBarController.swift:509",
        "message": "performTTSWithCommand started",
        "data": [
          "audioURL": audioURL.lastPathComponent,
          "fileSize": fileSize
        ],
        "timestamp": Int64(Date().timeIntervalSince1970 * 1000)
      ]
      if let logFile = FileHandle(forWritingAtPath: "/Users/mgsgde/whisper-shortcut/.cursor/debug.log") {
        try? logFile.seekToEnd()
        try? logFile.write(Data((try? JSONSerialization.data(withJSONObject: logData)) ?? Data()))
        try? logFile.write(Data("\n".utf8))
        try? logFile.close()
      } else {
        try? (try? JSONSerialization.data(withJSONObject: logData))?.write(to: URL(fileURLWithPath: "/Users/mgsgde/whisper-shortcut/.cursor/debug.log"), options: .atomic)
      }
      // #endregion
      // Check if audio is likely empty before transcription
      let isEmpty = speechService.isAudioLikelyEmpty(at: audioURL)
      // #region agent log
      let logData2: [String: Any] = [
        "sessionId": "debug-session",
        "runId": "run1",
        "hypothesisId": "D",
        "location": "MenuBarController.swift:512",
        "message": "isAudioLikelyEmpty result",
        "data": ["isEmpty": isEmpty],
        "timestamp": Int64(Date().timeIntervalSince1970 * 1000)
      ]
      if let logFile = FileHandle(forWritingAtPath: "/Users/mgsgde/whisper-shortcut/.cursor/debug.log") {
        try? logFile.seekToEnd()
        try? logFile.write(Data((try? JSONSerialization.data(withJSONObject: logData2)) ?? Data()))
        try? logFile.write(Data("\n".utf8))
        try? logFile.close()
      } else {
        try? (try? JSONSerialization.data(withJSONObject: logData2))?.write(to: URL(fileURLWithPath: "/Users/mgsgde/whisper-shortcut/.cursor/debug.log"), options: .atomic)
      }
      // #endregion
      if isEmpty {
        DebugLogger.log("TTS: Audio too short, skipping transcription, using direct TTS")
        // Clean up audio file
        try? FileManager.default.removeItem(at: audioURL)
        
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
        }
        
        let audioData = try await speechService.readTextAloud(selectedText)
        await MainActor.run {
          self.playTTSAudio(audioData: audioData)
        }
        return
      }
      
      // First, transcribe the audio to get the voice command
      let voiceCommand = try await speechService.transcribe(audioURL: audioURL)
      let trimmedCommand = voiceCommand.trimmingCharacters(in: .whitespacesAndNewlines)
      
      // Clean up transcription audio
      try? FileManager.default.removeItem(at: audioURL)
      
      // Get selected text from clipboard
      guard let selectedText = clipboardManager.getCleanedClipboardText(),
            !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        await MainActor.run {
          self.appState = self.appState.showError("No text selected")
          PopupNotificationWindow.showError("No text selected", title: "TTS Error")
        }
        return
      }
      
      // Check if command is empty/null
      if trimmedCommand.isEmpty {
        // No command - direct TTS
        DebugLogger.log("TTS: No voice command detected, using direct TTS")
        await MainActor.run {
          self.appState = .processing(.ttsProcessing)
        }
        
        let audioData = try await speechService.readTextAloud(selectedText)
        await MainActor.run {
          self.playTTSAudio(audioData: audioData)
        }
      } else {
        // Command exists - apply prompt mode first
        DebugLogger.log("TTS: Voice command detected: \(trimmedCommand)")
        await MainActor.run {
          self.appState = .processing(.prompting)
        }
        
        // Apply prompt mode: selected text + command (using text-based method)
        let promptResult = try await speechService.executePromptWithText(textCommand: trimmedCommand, selectedText: selectedText, mode: .promptAndRead)
        
        // Now TTS the result using Prompt & Read voice
        await MainActor.run {
          self.appState = .processing(.ttsProcessing)
        }
        
        // Get Prompt & Read voice from UserDefaults
        let promptAndReadVoice = UserDefaults.standard.string(forKey: UserDefaultsKeys.selectedPromptAndReadVoice) ?? SettingsDefaults.selectedPromptAndReadVoice
        let audioData = try await speechService.readTextAloud(promptResult, voiceName: promptAndReadVoice)
        await MainActor.run {
          self.playTTSAudio(audioData: audioData)
        }
      }
    } catch is CancellationError {
      DebugLogger.log("CANCELLATION: TTS task was cancelled")
      await MainActor.run {
        self.appState = .idle
      }
      try? FileManager.default.removeItem(at: audioURL)
    } catch {
      DebugLogger.logError("TTS-ERROR: Failed to process TTS request: \(error.localizedDescription)")
      if let transcriptionError = error as? TranscriptionError {
        DebugLogger.logError("TTS-ERROR: TranscriptionError type: \(transcriptionError)")
      }
      await MainActor.run {
        self.appState = self.appState.showError("TTS failed: \(error.localizedDescription)")
        PopupNotificationWindow.showError("Failed to process: \(error.localizedDescription)", title: "TTS Error")
      }
      try? FileManager.default.removeItem(at: audioURL)
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
      
      DebugLogger.log("TTS-PLAYBACK: Audio format created (sampleRate: \(sampleRate), channels: \(channels))")
      
      // Calculate frame count
      let bytesPerFrame = Int(channels * (bitsPerChannel / 8))
      let frameCount = audioData.count / bytesPerFrame
      
      DebugLogger.log("TTS-PLAYBACK: Calculated frame count: \(frameCount) (bytesPerFrame: \(bytesPerFrame))")
      
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
      
      DebugLogger.log("TTS-PLAYBACK: PCM data copied to buffer")
      
      // Stop any existing playback
      if let existingEngine = audioEngine {
        existingEngine.stop()
        audioEngine = nil
      }
      if let existingNode = audioPlayerNode {
        existingNode.stop()
        audioPlayerNode = nil
      }
      
      // Create audio engine for playback
      let engine = AVAudioEngine()
      let playerNode = AVAudioPlayerNode()
      
      engine.attach(playerNode)
      engine.connect(playerNode, to: engine.mainMixerNode, format: audioFormat)
      
      // Store references to prevent deallocation
      self.audioEngine = engine
      self.audioPlayerNode = playerNode
      
      DebugLogger.log("TTS-PLAYBACK: Audio engine configured, starting engine...")
      try engine.start()
      DebugLogger.log("TTS-PLAYBACK: Audio engine started successfully")
      
      // Schedule buffer for playback
      playerNode.scheduleBuffer(buffer) {
        DebugLogger.log("TTS-PLAYBACK: Buffer playback completed")
        DispatchQueue.main.async {
          engine.stop()
          self.audioEngine = nil
          self.audioPlayerNode = nil
          self.audioPlayer = nil
          self.currentTTSAudioURL = nil
          self.appState = self.appState.showSuccess("Audio playback completed")
          DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            if case .feedback = self.appState {
              self.appState = .idle
            }
          }
        }
      }
      
      DebugLogger.log("TTS-PLAYBACK: Buffer scheduled, starting playback...")
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
        // Clear tracking after successful completion
        if self.currentTranscriptionAudioURL == audioURL {
          self.currentTranscriptionAudioURL = nil
        }
        self.processedAudioURLs.remove(audioURL)
      }
      
      // Cleanup on success
      try? FileManager.default.removeItem(at: audioURL)
    } catch is CancellationError {
      // Task was cancelled - just cleanup and return to idle
      DebugLogger.log("CANCELLATION: Transcription task was cancelled")
      await MainActor.run {
        self.appState = .idle
        // Clear tracking on cancellation
        if self.currentTranscriptionAudioURL == audioURL {
          self.currentTranscriptionAudioURL = nil
        }
        self.processedAudioURLs.remove(audioURL)
      }
      // Cleanup on cancellation
      try? FileManager.default.removeItem(at: audioURL)
    } catch {
      await handleProcessingError(error: error, audioURL: audioURL, mode: .transcription)
      // Clear tracking on error (file will be cleaned up in handleProcessingError if needed)
      await MainActor.run {
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
      try? FileManager.default.removeItem(at: audioURL)
    } catch is CancellationError {
      // Task was cancelled - just cleanup and return to idle
      DebugLogger.log("CANCELLATION: Prompt task was cancelled")
      await MainActor.run {
        self.appState = .idle
        // Clear tracking on cancellation
        self.processedAudioURLs.remove(audioURL)
      }
      // Cleanup on cancellation
      try? FileManager.default.removeItem(at: audioURL)
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
    // #region agent log
    let fileSize = (try? FileManager.default.attributesOfItem(atPath: audioURL.path)[.size] as? Int64) ?? 0
    let logData: [String: Any] = [
      "sessionId": "debug-session",
      "runId": "run1",
      "hypothesisId": "C",
      "location": "MenuBarController.swift:944",
      "message": "audioRecorderDidFinishRecording called",
      "data": [
        "audioURL": audioURL.lastPathComponent,
        "fileSize": fileSize,
        "appState": "\(appState)",
        "recordingMode": appState.recordingMode == .tts ? "tts" : "\(appState.recordingMode)"
      ],
      "timestamp": Int64(Date().timeIntervalSince1970 * 1000)
    ]
    if let logFile = FileHandle(forWritingAtPath: "/Users/mgsgde/whisper-shortcut/.cursor/debug.log") {
      try? logFile.seekToEnd()
      try? logFile.write(Data((try? JSONSerialization.data(withJSONObject: logData)) ?? Data()))
      try? logFile.write(Data("\n".utf8))
      try? logFile.close()
    } else {
      try? (try? JSONSerialization.data(withJSONObject: logData))?.write(to: URL(fileURLWithPath: "/Users/mgsgde/whisper-shortcut/.cursor/debug.log"), options: .atomic)
    }
    // #endregion
    // Prevent processing the same audio file multiple times (race condition protection)
    guard !processedAudioURLs.contains(audioURL) else {
      DebugLogger.logWarning("AUDIO: Ignoring duplicate audioRecorderDidFinishRecording for \(audioURL.lastPathComponent)")
      return
    }
    
    // Simple state-based dispatch - no complex mode tracking needed!
    guard case .recording(let recordingMode) = appState else {
      DebugLogger.logWarning("AUDIO: audioRecorderDidFinishRecording called but appState is not recording")
      return
    }

    // Mark this URL as processed to prevent duplicate processing
    processedAudioURLs.insert(audioURL)
    
    // Track the audio URL for transcription cancellation
    if recordingMode == .transcription {
      currentTranscriptionAudioURL = audioURL
    } else if recordingMode == .tts {
      currentTTSAudioURL = audioURL
    }

    // Transition to processing
    appState = appState.stopRecording()

    // Execute appropriate async operation
    Task {
      switch recordingMode {
      case .transcription:
        await performTranscription(audioURL: audioURL)
      case .prompt:
        await performPrompting(audioURL: audioURL)
      case .tts:
        await performTTSWithCommand(audioURL: audioURL)
      }
    }
  }

  func audioRecorderDidFailWithError(_ error: Error) {
    // #region agent log
    let errorCode = (error as NSError).code
    let errorDomain = (error as NSError).domain
    let logData: [String: Any] = [
      "sessionId": "debug-session",
      "runId": "run1",
      "hypothesisId": "B",
      "location": "MenuBarController.swift:983",
      "message": "audioRecorderDidFailWithError called",
      "data": [
        "errorCode": errorCode,
        "errorDomain": errorDomain,
        "errorDescription": error.localizedDescription,
        "appState": "\(appState)",
        "isEmptyFileError": errorCode == 1004
      ],
      "timestamp": Int64(Date().timeIntervalSince1970 * 1000)
    ]
    if let logFile = FileHandle(forWritingAtPath: "/Users/mgsgde/whisper-shortcut/.cursor/debug.log") {
      try? logFile.seekToEnd()
      try? logFile.write(Data((try? JSONSerialization.data(withJSONObject: logData)) ?? Data()))
      try? logFile.write(Data("\n".utf8))
      try? logFile.close()
    } else {
      try? (try? JSONSerialization.data(withJSONObject: logData))?.write(to: URL(fileURLWithPath: "/Users/mgsgde/whisper-shortcut/.cursor/debug.log"), options: .atomic)
    }
    // #endregion
    appState = appState.showError("Recording failed: \(error.localizedDescription)")
  }
}

// MARK: - ShortcutDelegate (Simple Forwarding)
extension MenuBarController: ShortcutDelegate {
  func toggleDictation() { toggleTranscription() }
  // togglePrompting is already implemented above
  @objc func readSelectedText() { handleReadSelectedText() }
  @objc func readAloud() {
    // Copy selected text to clipboard first (same as handleReadSelectedText does)
    simulateCopyPaste()
    
    // Wait a bit for clipboard to update after Cmd+C, then read
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
      self?.performDirectTTS()
    }
  }
  // openSettings is already implemented above
}
