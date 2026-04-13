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
      feedbackResetTask?.cancel()
      if case .feedback(let feedbackMode) = appState {
        feedbackResetTask = Task { [weak self] in
          try? await Task.sleep(nanoseconds: UInt64(feedbackMode.duration * 1_000_000_000))
          await MainActor.run {
            guard let self, case .feedback = self.appState else { return }
            self.appState = self.appState.finish()
          }
        }
      }
    }
  }

  // MARK: - UI Components
  private var statusItem: NSStatusItem?
  private var blinkTimer: Timer?
  private var feedbackResetTask: Task<Void, Never>?

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

  // MARK: - Live Meeting State
  private var liveMeetingRecorder: LiveMeetingRecorder?
  private var liveMeetingStopping: Bool = false
  private var liveMeetingTranscriptURL: URL?
  private var liveMeetingPendingChunks: Int = 0
  private var liveMeetingSessionStartTime: Date?
  private var liveMeetingSafeguardTimer: Timer?
  /// Number of transcript chunks already included in the rolling summary. Used to trigger summary every N chunks.
  private var liveMeetingChunksSummarized: Int = 0
  /// When non-nil, finishLiveMeetingSession will rename the transcript file to this stem (or timestamp-suffix) before ending.
  private var liveMeetingPreferredName: String?
  /// Set to true after showing rate-limit popup once this session so we don't spam.
  private var liveMeetingDidShowRateLimitAlert: Bool = false

  /// True when live meeting is active (recording or stopping with pending chunks).
  private var isLiveMeetingActive: Bool {
    appState.recordingMode == .liveMeeting || liveMeetingRecorder != nil
  }

  // MARK: - Meeting Segment (parallel action during live meeting)
  private enum MeetingSegment {
    case dictation
    case prompt
  }
  /// When non-nil, an action is running in parallel with the live meeting.
  private var activeMeetingSegment: MeetingSegment?

  /// Bumped when the Gemini shortcut closes the window or starts a new open; stale prefill tasks bail out before `show()` / notification.
  private var geminiShortcutOpenGeneration: UInt64 = 0

  /// True when TTS is running in any phase: .ttsProcessing or chunked phases with TTS context. Derived from AppState only.
  private var isTTSRunning: Bool {
    if case .processing(let mode) = appState { return mode.isTTSContext }
    return false
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

    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
      GeminiWindowManager.shared.preWarm()
    }
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

    // Central stop button — visible only when any operation is active
    let stopItem = createMenuItem("Stop", action: #selector(stopCurrentOperation), tag: 111)
    menu.addItem(stopItem)
    let stopSeparator = NSMenuItem.separator()
    stopSeparator.tag = 112
    menu.addItem(stopSeparator)

    // Recording actions with keyboard shortcuts
    menu.addItem(
      createMenuItemWithShortcut(
        "Dictate", action: #selector(toggleTranscription),
        shortcut: currentConfig.startRecording, tag: 101))
    menu.addItem(
      createMenuItemWithShortcut(
        "Prompt Mode", action: #selector(togglePrompting),
        shortcut: currentConfig.startPrompting, tag: 102))
    menu.addItem(NSMenuItem.separator())

    // Meeting and Gemini windows
    menu.addItem(
      createMenuItemWithShortcut(
        "Open Meeting", action: #selector(openMeetingWindow),
        shortcut: currentConfig.openMeeting, tag: 113))

    menu.addItem(
      createMenuItemWithShortcut(
        "Open Gemini", action: #selector(openGeminiWindow),
        shortcut: currentConfig.openGemini, tag: 110))


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
      .y: "y", .z: "z",
      .space: " "
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

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(geminiReadAloudWithNotification(_:)),
      name: .geminiReadAloud,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(geminiReadAloudStopFromNotification),
      name: .geminiReadAloudStop,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(toggleLiveMeeting),
      name: .geminiToggleLiveMeeting,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(endMeetingWithName(_:)),
      name: .geminiEndMeetingWithName,
      object: nil
    )
  }

  @objc private func endMeetingWithName(_ notification: Notification) {
    let name = (notification.userInfo?["meetingName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    DispatchQueue.main.async { [weak self] in
      self?.liveMeetingPreferredName = name
      self?.stopLiveMeeting()
    }
  }

  @objc private func geminiReadAloudStopFromNotification() {
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      if self.isTTSRunning {
        self.speechService.cancelTTS()
        self.stopTTSPlayback()
        self.transitionToIdleAndCleanup()
      } else if self.audioPlayer?.isPlaying == true || self.audioEngine?.isRunning == true {
        self.stopTTSPlayback()
        self.appState = self.appState.finish()
        NotificationCenter.default.post(name: .ttsDidStop, object: nil)
      }
    }
  }

  @objc private func geminiReadAloudWithNotification(_ notification: Notification) {
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      let text = (notification.userInfo?[Notification.Name.geminiReadAloudTextKey] as? String)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      guard !text.isEmpty else { return }
      if self.isTTSRunning {
        self.speechService.cancelTTS()
        self.stopTTSPlayback()
        self.transitionToIdleAndCleanup()
        return
      }
      if self.audioPlayer?.isPlaying == true || self.audioEngine?.isRunning == true {
        self.stopTTSPlayback()
        self.appState = self.appState.finish()
        return
      }
      self.performTTSWithText(text)
    }
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
    if case .processing(.processingChunks(let statuses, _)) = appState {
      let active = statuses.filter { $0 == .active }.count
      let done = statuses.filter { $0 == .completed }.count
      button.toolTip = "Transcribing [\(done)/\(statuses.count)] - \(active) active"
    } else {
      button.toolTip = appState.tooltip
    }
  }

  private func updateMenuItems() {
    guard let menu = statusItem?.menu else { return }

    let hasCredential = GeminiCredentialProvider.shared.hasCredential()

    // Check for offline transcription models
    let selectedTranscriptionModel = TranscriptionModel.loadSelected()
    let hasOfflineTranscriptionModel = selectedTranscriptionModel.isOfflineModelAvailable()
    
    // Prompt mode always requires API key (no offline support)
    let hasOfflinePromptModel = false

    // Update status
    menu.item(withTag: 100)?.title = appState.statusText

    // Show central Stop button only when something is active
    let isAnythingActive = appState.isBusy || isLiveMeetingActive
      || audioPlayer?.isPlaying == true || audioEngine?.isRunning == true
    menu.item(withTag: 111)?.isHidden = !isAnythingActive
    menu.item(withTag: 112)?.isHidden = !isAnythingActive

    // During a live meeting, all actions are available as parallel segments
    let meetingAllowsActions = isLiveMeetingActive && activeMeetingSegment == nil

    // Update action items based on current state
    updateMenuItem(
      menu, tag: 101,
      title: (appState.recordingMode == .transcription || activeMeetingSegment == .dictation)
        ? "Stop Dictate" : "Dictate",
      enabled: appState.canStartTranscription(hasAPIKey: hasCredential, hasOfflineModel: hasOfflineTranscriptionModel)
        || appState.recordingMode == .transcription
        || meetingAllowsActions && (hasCredential || hasOfflineTranscriptionModel)
        || activeMeetingSegment == .dictation)

    updateMenuItem(
      menu, tag: 102,
      title: (appState.recordingMode == .prompt || activeMeetingSegment == .prompt)
        ? "Stop Prompt Mode" : "Prompt Mode",
      enabled: appState.canStartPrompting(hasAPIKey: hasCredential, hasOfflineModel: hasOfflinePromptModel)
        || appState.recordingMode == .prompt
        || meetingAllowsActions && hasCredential
        || activeMeetingSegment == .prompt
    )
    
    updateMenuItem(menu, tag: 111, title: "Open Meeting", enabled: hasCredential)

    // Handle special case when no credential and no offline model is configured
    if !hasCredential && !hasOfflineTranscriptionModel && !hasOfflinePromptModel, let button = statusItem?.button {
      button.title = "⚠️"
      button.toolTip = "Sign in with Google or add an API key, or use an offline model - click to configure"
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
    // During live meeting: run dictation as a parallel segment
    if isLiveMeetingActive {
      if activeMeetingSegment == .dictation {
        DebugLogger.log("MEETING-SEGMENT: Stopping dictation segment")
        DispatchQueue.main.asyncAfter(deadline: .now() + Constants.audioTailCaptureDelay) { [weak self] in
          self?.audioRecorder.stopRecording()
        }
        return
      }
      if activeMeetingSegment != nil {
        DebugLogger.logWarning("MEETING-SEGMENT: Another segment already active, ignoring dictation")
        return
      }
      let hasCredential = GeminiCredentialProvider.shared.hasCredential()
      let selectedModel = TranscriptionModel.loadSelected()
      let hasOfflineModel = selectedModel.isOfflineModelAvailable()
      if hasCredential || hasOfflineModel {
        #if SUBSCRIPTION_ENABLED
        if DefaultGoogleAuthService.shared.isSignedIn() {
          Task { [weak self] in
            guard let self = self else { return }
            let active = await BackendAPIClient.fetchSubscriptionStatus(idTokenProvider: { await DefaultGoogleAuthService.shared.getIDToken() })
            await MainActor.run {
              if active != true {
                PopupNotificationWindow.showError(
                  "You need an active subscription to use dictation. Subscribe at whispershortcut.com or add an API key in Settings (General tab).",
                  title: "Subscription Required",
                  topUpURL: URL(string: "https://whispershortcut.com/subscription")
                )
                return
              }
              DebugLogger.log("MEETING-SEGMENT: Starting dictation segment during meeting")
              self.activeMeetingSegment = .dictation
              self.audioRecorder.startRecording()
            }
          }
          return
        }
        #endif
        DebugLogger.log("MEETING-SEGMENT: Starting dictation segment during meeting")
        activeMeetingSegment = .dictation
        audioRecorder.startRecording()
      } else {
        #if SUBSCRIPTION_ENABLED
        PopupNotificationWindow.showError(
          "Sign in with Google or add an API key in Settings (General tab) to use dictation. For offline use, download a Whisper model in Speech-to-Text settings.",
          title: "Sign In or API Key Required",
          signInAction: { Task { try? await DefaultGoogleAuthService.shared.signIn() } }
        )
        #else
        PopupNotificationWindow.showError(
          "Add your Gemini API key in Settings (General tab) to use dictation. For offline use, download a Whisper model in Speech-to-Text settings.",
          title: "API Key Required"
        )
        #endif
      }
      return
    }

    // Check if currently processing transcription (incl. chunk phases for long audio) - if so, cancel it
    let isTranscriptionProcessing: Bool = {
      guard case .processing(let mode) = appState, !mode.isTTSContext else { return false }
      switch mode {
      case .transcribing, .splitting, .processingChunks, .merging: return true
      case .prompting, .ttsProcessing: return false
      }
    }()
    if isTranscriptionProcessing {
      speechService.cancelTranscription()
      transitionToIdleAndCleanup(cleanupAudioURL: currentTranscriptionAudioURL)
      return
    }
    
    switch appState.recordingMode {
    case .transcription:
      DispatchQueue.main.asyncAfter(deadline: .now() + Constants.audioTailCaptureDelay) { [weak self] in
        self?.audioRecorder.stopRecording()
      }
    case .none:
      let hasCredential = GeminiCredentialProvider.shared.hasCredential()
      let selectedModel = TranscriptionModel.loadSelected()
      let hasOfflineModel = selectedModel.isOfflineModelAvailable()

      if appState.canStartTranscription(hasAPIKey: hasCredential, hasOfflineModel: hasOfflineModel) {
        #if SUBSCRIPTION_ENABLED
        if DefaultGoogleAuthService.shared.isSignedIn() {
          Task { [weak self] in
            guard let self = self else { return }
            let active = await BackendAPIClient.fetchSubscriptionStatus(idTokenProvider: { await DefaultGoogleAuthService.shared.getIDToken() })
            await MainActor.run {
              if active != true {
                PopupNotificationWindow.showError(
                  "You need an active subscription to use dictation. Subscribe at whispershortcut.com or add an API key in Settings (General tab).",
                  title: "Subscription Required",
                  topUpURL: URL(string: "https://whispershortcut.com/subscription")
                )
                return
              }
              self.appState = self.appState.startRecording(.transcription)
              self.audioRecorder.startRecording()
            }
          }
          return
        }
        #endif
        appState = appState.startRecording(.transcription)
        audioRecorder.startRecording()
      } else {
        #if SUBSCRIPTION_ENABLED
        PopupNotificationWindow.showError(
          "Sign in with Google or add an API key in Settings (General tab) to use dictation. For offline use, download a Whisper model in Speech-to-Text settings.",
          title: "Sign In or API Key Required",
          signInAction: { Task { try? await DefaultGoogleAuthService.shared.signIn() } }
        )
        #else
        PopupNotificationWindow.showError(
          "Add your Gemini API key in Settings (General tab) to use dictation. For offline use, download a Whisper model in Speech-to-Text settings.",
          title: "API Key Required"
        )
        #endif
      }
    default:
      break
    }
  }

  @objc internal func togglePrompting() {
    // During live meeting: run prompt as a parallel segment
    if isLiveMeetingActive {
      if activeMeetingSegment == .prompt {
        DebugLogger.log("MEETING-SEGMENT: Stopping prompt segment")
        DispatchQueue.main.asyncAfter(deadline: .now() + Constants.audioTailCaptureDelay) { [weak self] in
          self?.audioRecorder.stopRecording()
        }
        return
      }
      if activeMeetingSegment != nil {
        DebugLogger.logWarning("MEETING-SEGMENT: Another segment already active, ignoring prompt")
        return
      }
      let hasCredential = GeminiCredentialProvider.shared.hasCredential()
      if hasCredential {
        if !AccessibilityPermissionManager.checkPermissionForPromptUsage() { return }
        #if SUBSCRIPTION_ENABLED
        if DefaultGoogleAuthService.shared.isSignedIn() {
          Task { [weak self] in
            guard let self = self else { return }
            let active = await BackendAPIClient.fetchSubscriptionStatus(idTokenProvider: { await DefaultGoogleAuthService.shared.getIDToken() })
            await MainActor.run {
              if active != true {
                PopupNotificationWindow.showError(
                  "You need an active subscription to use prompt mode. Subscribe at whispershortcut.com or add an API key in Settings (General tab).",
                  title: "Subscription Required",
                  topUpURL: URL(string: "https://whispershortcut.com/subscription")
                )
                return
              }
              DebugLogger.log("MEETING-SEGMENT: Starting prompt segment during meeting")
              self.simulateCopyPaste()
              self.activeMeetingSegment = .prompt
              self.audioRecorder.startRecording()
            }
          }
          return
        }
        #endif
        DebugLogger.log("MEETING-SEGMENT: Starting prompt segment during meeting")
        simulateCopyPaste()
        activeMeetingSegment = .prompt
        audioRecorder.startRecording()
      }
      return
    }

    // Check if currently processing prompt - if so, cancel it
    if case .processing(.prompting) = appState {
      speechService.cancelPrompt()
      transitionToIdleAndCleanup()
      return
    }
    
    switch appState.recordingMode {
    case .prompt:
      DispatchQueue.main.asyncAfter(deadline: .now() + Constants.audioTailCaptureDelay) { [weak self] in
        self?.audioRecorder.stopRecording()
      }
    case .none:
      let hasCredential = GeminiCredentialProvider.shared.hasCredential()

      if appState.canStartPrompting(hasAPIKey: hasCredential, hasOfflineModel: false) {
        if !AccessibilityPermissionManager.checkPermissionForPromptUsage() {
          return
        }
        #if SUBSCRIPTION_ENABLED
        if DefaultGoogleAuthService.shared.isSignedIn() {
          Task { [weak self] in
            guard let self = self else { return }
            let active = await BackendAPIClient.fetchSubscriptionStatus(idTokenProvider: { await DefaultGoogleAuthService.shared.getIDToken() })
            await MainActor.run {
              if active != true {
                PopupNotificationWindow.showError(
                  "You need an active subscription to use prompt mode. Subscribe at whispershortcut.com or add an API key in Settings (General tab).",
                  title: "Subscription Required",
                  topUpURL: URL(string: "https://whispershortcut.com/subscription")
                )
                return
              }
              self.simulateCopyPaste()
              self.appState = self.appState.startRecording(.prompt)
              self.audioRecorder.startRecording()
            }
          }
          return
        }
        #endif
        simulateCopyPaste()
        appState = appState.startRecording(.prompt)
        audioRecorder.startRecording()
      }
    default:
      break
    }
  }

  @objc private func stopCurrentOperation() {
    // Active meeting segment: stop the segment first, keep meeting running
    if activeMeetingSegment != nil {
      DebugLogger.log("MEETING-SEGMENT: Stopping active segment via Stop button")
      audioRecorder.stopRecording()
      activeMeetingSegment = nil
      return
    }

    // Live meeting (no active segment)
    if isLiveMeetingActive { stopLiveMeeting(); return }

    // TTS processing
    if isTTSRunning {
      speechService.cancelTTS()
      stopTTSPlayback()
      transitionToIdleAndCleanup()
      return
    }

    // TTS audio playback
    if audioPlayer?.isPlaying == true || audioEngine?.isRunning == true {
      stopTTSPlayback()
      appState = appState.finish()
      return
    }

    // Transcription processing
    let isTranscriptionProcessing: Bool = {
      guard case .processing(let mode) = appState, !mode.isTTSContext else { return false }
      switch mode {
      case .transcribing, .splitting, .processingChunks, .merging: return true
      default: return false
      }
    }()
    if isTranscriptionProcessing {
      speechService.cancelTranscription()
      transitionToIdleAndCleanup(cleanupAudioURL: currentTranscriptionAudioURL)
      return
    }

    // Prompt processing
    if case .processing(.prompting) = appState {
      speechService.cancelPrompt()
      transitionToIdleAndCleanup()
      return
    }

    // Recording states — stop the recorder (audio tail delay like the individual toggles)
    if appState.isRecording {
      DispatchQueue.main.asyncAfter(deadline: .now() + Constants.audioTailCaptureDelay) { [weak self] in
        self?.audioRecorder.stopRecording()
      }
    }
  }

  @objc func openSettings() {
    SettingsManager.shared.toggleSettings()
  }

  @objc func openGeminiWindow() {
    GeminiWindowManager.shared.toggle()
  }

  /// Opens the Gemini window from the global shortcut: copy selection from the frontmost app when possible, then prefill the composer.
  /// If the window is already open, closes it (same toggle behavior as the menu).
  private func openGeminiWindowFromShortcut() {
    if GeminiWindowManager.shared.isWindowOpen() {
      geminiShortcutOpenGeneration &+= 1
      GeminiWindowManager.shared.close()
      return
    }

    geminiShortcutOpenGeneration &+= 1
    let generation = geminiShortcutOpenGeneration

    if AccessibilityPermissionManager.hasAccessibilityPermission() {
      // Track the pasteboard via changeCount, not string equality. The old
      // comparison had two race-free failure modes that both skipped prefill:
      //   1. The selection text equaled the existing clipboard content
      //      (common — e.g. re-copying the same snippet) → string "unchanged"
      //      even though Cmd+C landed.
      //   2. Slow/Electron apps hadn't written the pasteboard within the
      //      fixed 100 ms wait → stale read returned the old value.
      // changeCount increments on every write regardless of content, so
      // polling it is race-free; we give the front app up to 300 ms to land.
      let beforeChangeCount = NSPasteboard.general.changeCount
      simulateCopyPaste()
      Task { @MainActor [weak self] in
        guard let self else { return }
        var newText: String? = nil
        let deadline = Date().addingTimeInterval(0.30)
        while Date() < deadline {
          try? await Task.sleep(for: .milliseconds(15))
          guard generation == self.geminiShortcutOpenGeneration else { return }
          if NSPasteboard.general.changeCount != beforeChangeCount {
            newText = self.clipboardManager.getCleanedClipboardText()
            break
          }
        }
        let afterFull = newText ?? ""
        let afterTrimmed = afterFull.trimmingCharacters(in: .whitespacesAndNewlines)
        let didLand = !afterTrimmed.isEmpty
        // Buffer prefill text before showing so GeminiInputAreaView can pick it up
        // in onAppear if the notification arrives before SwiftUI has subscribed.
        if didLand {
          GeminiWindowManager.shared.pendingPrefillText = afterFull
        }
        GeminiWindowManager.shared.show(suppressFocusLossClose: true)
        // Also post notification for the warm-window case (view already subscribed).
        try? await Task.sleep(for: .milliseconds(120))
        guard generation == self.geminiShortcutOpenGeneration else { return }
        if didLand {
          NotificationCenter.default.post(
            name: .geminiPrefillComposer,
            object: nil,
            userInfo: [Notification.Name.geminiPrefillComposerTextKey: afterFull]
          )
        }
      }
    } else {
      _ = AccessibilityPermissionManager.checkPermissionForPromptUsage()
      GeminiWindowManager.shared.show(suppressFocusLossClose: true)
    }
  }

  @objc func openMeetingWindow() {
    MeetingWindowManager.shared.toggle()
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
    guard GeminiCredentialProvider.shared.hasCredential() else {
      #if SUBSCRIPTION_ENABLED
      PopupNotificationWindow.showError(
        "Sign in with Google or add an API key in Settings (General tab) to use live meeting transcription.",
        title: "Sign In or API Key Required",
        signInAction: { Task { try? await DefaultGoogleAuthService.shared.signIn() } }
      )
      #else
      PopupNotificationWindow.showError(
        "Add your Gemini API key in Settings (General tab) to use live meeting transcription.",
        title: "API Key Required"
      )
      #endif
      return
    }

    // Check if busy with other operations
    guard !appState.isBusy else {
      DebugLogger.logWarning("LIVE-MEETING: Cannot start - app is busy")
      return
    }

    DebugLogger.log("LIVE-MEETING: Starting session")

    // Create transcript file (stem is pre-generated by LiveMeetingTranscriptStore)
    do {
      liveMeetingTranscriptURL = try createTranscriptFile()
    } catch {
      DebugLogger.logError("LIVE-MEETING: Failed to create transcript file: \(error)")
      PopupNotificationWindow.showError("Failed to create transcript file", title: "Live Meeting Error")
      return
    }

    // Transcript is shown in the app's Meeting view; do not open the .txt file in an external app.

    // Load chunk interval from settings
    let savedInterval = UserDefaults.standard.double(forKey: UserDefaultsKeys.liveMeetingChunkInterval)
    let chunkInterval: TimeInterval = savedInterval > 0 ? savedInterval : AppConstants.liveMeetingChunkIntervalDefault

    // Create and start recorder
    liveMeetingRecorder = LiveMeetingRecorder(chunkDuration: chunkInterval)
    liveMeetingRecorder?.delegate = self
    liveMeetingRecorder?.startSession()

    // Update state
    liveMeetingStopping = false
    liveMeetingPendingChunks = 0
    liveMeetingSessionStartTime = Date()
    liveMeetingDidShowRateLimitAlert = false
    appState = .recording(.liveMeeting)
    LiveMeetingTranscriptStore.shared.startSession()
    liveMeetingChunksSummarized = 0

    // Schedule duration safeguard if enabled
    let safeguardThreshold = MeetingSafeguardDuration.loadFromUserDefaults()
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

    MeetingWindowManager.shared.show()

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

    if let url = liveMeetingTranscriptURL, let preferred = liveMeetingPreferredName, !preferred.isEmpty {
      let currentStem = url.deletingPathExtension().lastPathComponent
      if preferred != currentStem {
        renameTranscriptFile(from: url, preferredName: preferred, currentStem: currentStem)
      }
      liveMeetingPreferredName = nil
    }

    liveMeetingSafeguardTimer?.invalidate()
    liveMeetingSafeguardTimer = nil
    liveMeetingStopping = false
    liveMeetingRecorder = nil
    liveMeetingPendingChunks = 0
    appState = appState.finish()
    LiveMeetingTranscriptStore.shared.endSession()

    if let transcriptURL = liveMeetingTranscriptURL {
      let store = LiveMeetingTranscriptStore.shared
      let chunksSnapshot = store.chunks
      Task {
        let transcriptText = chunksSnapshot.map { "\($0.timestampString) \($0.text)" }.joined(separator: "\n\n")
        guard !transcriptText.isEmpty else { return }
        guard let credential = await GeminiCredentialProvider.shared.getCredential() else { return }
        var text = transcriptText
        if text.count > MeetingListService.contextMaxChars {
          text = String(text.suffix(MeetingListService.contextMaxChars))
        }
        let model = credential.isOAuth
          ? SubscriptionModelsConfigService.effectiveMeetingSummaryModel().rawValue
          : PromptModel.loadSelectedMeetingSummary().rawValue
        do {
          let summary = try await GeminiAPIClient().generateMeetingSummary(transcript: text, model: model, credential: credential)
          let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
          if !trimmed.isEmpty {
            MeetingListService.shared.saveSummary(trimmed, transcriptFileURL: transcriptURL)
            DebugLogger.log("LIVE-MEETING: Summary saved to .summary.md")
          }
        } catch {
          DebugLogger.logError("LIVE-MEETING: Generate summary failed: \(error.localizedDescription)")
        }
      }
    }

    DebugLogger.logSuccess("LIVE-MEETING: Transcription saved")
  }

  /// Renames the transcript file to include the user's preferred name. Keeps timestamp prefix for parsing.
  private func renameTranscriptFile(from url: URL, preferredName: String, currentStem: String) {
    let timestampPrefix = "Meeting-"
    guard currentStem.hasPrefix(timestampPrefix) else { return }
    let sanitized = preferredName
      .replacingOccurrences(of: "/", with: "-")
      .replacingOccurrences(of: "\\", with: "-")
      .replacingOccurrences(of: ":", with: "-")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !sanitized.isEmpty else { return }
    let newStem = "\(currentStem)-\(sanitized)"
    let dir = url.deletingLastPathComponent()
    let newURL = dir.appendingPathComponent("\(newStem).txt")
    do {
      if FileManager.default.fileExists(atPath: newURL.path) {
        try FileManager.default.removeItem(at: newURL)
      }
      try FileManager.default.moveItem(at: url, to: newURL)
      liveMeetingTranscriptURL = newURL
      MeetingListService.shared.invalidateCache(for: nil)
      DispatchQueue.main.async {
        LiveMeetingTranscriptStore.shared.currentMeetingFilenameStem = newStem
        LiveMeetingTranscriptStore.shared.preferredMeetingName = sanitized
      }
      DebugLogger.log("LIVE-MEETING: Renamed transcript to \(newStem).txt")
    } catch {
      DebugLogger.logError("LIVE-MEETING: Failed to rename transcript: \(error.localizedDescription)")
    }
  }

  @objc func openTranscriptsFolder() {
    let transcriptsDir = AppSupportPaths.whisperShortcutApplicationSupportURL()
      .appendingPathComponent(AppConstants.liveMeetingTranscriptDirectory)
    
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
    let meetingsDir = AppSupportPaths.whisperShortcutApplicationSupportURL()
      .appendingPathComponent(AppConstants.liveMeetingTranscriptDirectory)

    if !FileManager.default.fileExists(atPath: meetingsDir.path) {
      try FileManager.default.createDirectory(at: meetingsDir, withIntermediateDirectories: true)
    }

    let stem = LiveMeetingTranscriptStore.shared.currentMeetingFilenameStem
               ?? LiveMeetingTranscriptStore.generateStem()
    let filename = "\(stem).txt"

    let fileURL = meetingsDir.appendingPathComponent(filename)

    FileManager.default.createFile(atPath: fileURL.path, contents: nil)

    DebugLogger.log("LIVE-MEETING: Created transcript file at \(fileURL.path)")
    return fileURL
  }

  private func appendToTranscript(_ text: String, chunkStartTime: TimeInterval) {
    guard let url = liveMeetingTranscriptURL else { return }

    var finalText = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let timestamp = formatTimestamp(elapsedSeconds: chunkStartTime)
    finalText = "\(timestamp) \(finalText)"
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

    let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmedText.isEmpty {
      LiveMeetingTranscriptStore.shared.appendChunk(startTime: chunkStartTime, text: trimmedText)
    }
  }

  private func formatTimestamp(elapsedSeconds: TimeInterval) -> String {
    let minutes = Int(elapsedSeconds) / 60
    let seconds = Int(elapsedSeconds) % 60
    return String(format: "[%02d:%02d]", minutes, seconds)
  }

  /// If at least 4 new chunks since last summary, kick off a rolling summary update (async).
  private func triggerRollingSummaryUpdateIfNeeded() {
    let store = LiveMeetingTranscriptStore.shared
    let count = store.chunks.count
    let threshold = 4
    guard count - liveMeetingChunksSummarized >= threshold else { return }

    let fromIndex = liveMeetingChunksSummarized
    liveMeetingChunksSummarized = count
    let currentSummary = store.summary
    let newText = store.chunkTexts(fromIndex: fromIndex)
    guard !newText.isEmpty else { return }

    Task {
      await runRollingSummaryUpdate(currentSummary: currentSummary, newText: newText)
    }
  }

  /// Calls Gemini to merge new transcript into the rolling summary and updates the store. Call from a Task.
  private func runRollingSummaryUpdate(currentSummary: String, newText: String) async {
    guard let credential = await GeminiCredentialProvider.shared.getCredential() else { return }
    let model = credential.isOAuth
      ? SubscriptionModelsConfigService.effectiveMeetingSummaryModel().rawValue
      : PromptModel.loadSelectedMeetingSummary().rawValue
    do {
      let updated = try await GeminiAPIClient().updateRollingSummary(
        model: model,
        currentSummary: currentSummary,
        newTranscriptText: newText,
        credential: credential
      )
      await MainActor.run {
        let trimmed = updated.trimmingCharacters(in: .whitespacesAndNewlines)
        LiveMeetingTranscriptStore.shared.updateSummary(trimmed)
        if let url = self.liveMeetingTranscriptURL, !trimmed.isEmpty {
          MeetingListService.shared.saveSummary(trimmed, transcriptFileURL: url)
        }
        DebugLogger.log("LIVE-MEETING-SUMMARY: Rolling summary updated (\(updated.count) chars)")
      }
    } catch {
      DebugLogger.logError("LIVE-MEETING-SUMMARY: Update failed: \(error.localizedDescription)")
      await MainActor.run {
        liveMeetingChunksSummarized = max(0, liveMeetingChunksSummarized - 4)
      }
    }
  }

  private func performTTSWithText(_ text: String, duringMeeting: Bool = false) {
    if !duringMeeting {
      if isTTSRunning {
        speechService.cancelTTS()
        stopTTSPlayback()
        transitionToIdleAndCleanup()
        return
      }
      if audioPlayer?.isPlaying == true || audioEngine?.isRunning == true {
        stopTTSPlayback()
        appState = appState.finish()
        return
      }
    }
    let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedText.isEmpty else {
      if duringMeeting { activeMeetingSegment = nil }
      return
    }

    if !duringMeeting {
      appState = .processing(.ttsProcessing)
    }
    NotificationCenter.default.post(name: .ttsDidStart, object: nil)

    Task {
      do {
        let audioData = try await speechService.readTextAloud(trimmedText)
        ContextLogger.shared.logReadAloud(text: trimmedText, voice: nil)
        await MainActor.run {
          PopupNotificationWindow.dismissProcessing()
          self.playTTSAudio(audioData: audioData)
          if duringMeeting { self.activeMeetingSegment = nil }
        }
      } catch is CancellationError {
        DebugLogger.log("CANCELLATION: TTS task was cancelled")
        await MainActor.run {
          if duringMeeting {
            self.activeMeetingSegment = nil
          } else {
            self.transitionToIdleAndCleanup()
          }
        }
      } catch {
        DebugLogger.logError("TTS-ERROR: Failed to generate speech: \(error.localizedDescription)")
        if let transcriptionError = error as? TranscriptionError {
          DebugLogger.logError("TTS-ERROR: TranscriptionError type: \(transcriptionError)")
        }
        let userMessage: String
        let shortTitle: String
        if let chunkedError = error as? ChunkedTTSError,
           case .allChunksFailed(let errors) = chunkedError,
           let firstError = errors.first?.error as? TranscriptionError {
          userMessage = SpeechErrorFormatter.format(firstError)
          shortTitle = SpeechErrorFormatter.shortStatus(firstError)
        } else if let transcriptionError = error as? TranscriptionError {
          userMessage = SpeechErrorFormatter.format(transcriptionError)
          shortTitle = SpeechErrorFormatter.shortStatus(transcriptionError)
        } else {
          userMessage = SpeechErrorFormatter.formatForUser(error)
          shortTitle = SpeechErrorFormatter.shortStatusForUser(error)
        }
        await MainActor.run {
          if duringMeeting { self.activeMeetingSegment = nil }
          self.presentError(shortTitle: shortTitle, message: userMessage, dismissProcessingFirst: !duringMeeting)
        }
      }
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
        throw TTSPlaybackError.failedToCreateAudioFormat
      }
      
      // Calculate frame count
      let bytesPerFrame = Int(channels * (bitsPerChannel / 8))
      let frameCount = audioData.count / bytesPerFrame

      // Create PCM buffer
      guard let buffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: AVAudioFrameCount(frameCount)) else {
        DebugLogger.logError("TTS-PLAYBACK: Failed to create audio buffer")
        throw TTSPlaybackError.failedToCreateBuffer
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
      let rate = SettingsDefaults.clampedReadAloudPlaybackRate()

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
          throw TTSPlaybackError.failedToCreateFloatFormat
        }
        guard let floatBuffer = AVAudioPCMBuffer(pcmFormat: floatFormat, frameCapacity: AVAudioFrameCount(frameCount)) else {
          DebugLogger.logError("TTS-PLAYBACK: Failed to create Float32 buffer")
          throw TTSPlaybackError.failedToCreateFloatBuffer
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
          NotificationCenter.default.post(name: .ttsDidStop, object: nil)
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
            self.appState = self.appState.finish()
          }
        }
      }
      playerNode.play()
      DebugLogger.logSuccess("TTS-PLAYBACK: Playback started")
      appState = appState.showSuccess("Playing audio...")
      
    } catch {
      DebugLogger.logError("TTS-PLAYBACK: Failed to play audio: \(error.localizedDescription)")
      presentError(shortTitle: SpeechErrorFormatter.shortStatusForUser(error), message: SpeechErrorFormatter.formatForUser(error), dismissProcessingFirst: false)
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

  /// Presents an error in app state and popup (and optionally dismisses processing popup first).
  private func presentError(
    shortTitle: String,
    message: String? = nil,
    dismissProcessingFirst: Bool = true,
    retryAction: (() -> Void)? = nil,
    dismissAction: (() -> Void)? = nil,
    topUpURL: URL? = nil
  ) {
    if dismissProcessingFirst {
      PopupNotificationWindow.dismissProcessing()
    }
    appState = appState.showError(shortTitle)
    PopupNotificationWindow.showError(message ?? shortTitle, title: shortTitle, retryAction: retryAction, dismissAction: dismissAction, topUpURL: topUpURL)
  }

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

      let (shortTitle, errorMessage): (String, String)
      let transcriptionError: TranscriptionError?

      if let error = error as? TranscriptionError {
        transcriptionError = error
        let pair = SpeechErrorFormatter.titleAndBodyForPopup(error)
        shortTitle = pair.shortTitle
        errorMessage = pair.body
      } else {
        transcriptionError = nil
        let operationName: String
        switch mode {
        case .transcription: operationName = "Transcription"
        case .prompt: operationName = "Prompt"
        case .liveMeeting: operationName = "Live meeting"
        }
        shortTitle = "\(operationName) Error"
        errorMessage = SpeechErrorFormatter.formatForUser(error)
      }

      // Copy error message to clipboard
      self.clipboardManager.copyToClipboard(text: errorMessage)

      // Determine if error is retryable
      let isRetryable = transcriptionError?.isRetryable ?? false
      
      // Define retry action
      let isServerError = transcriptionError?.isServerOrUnavailable ?? false
      let retryAction: (() -> Void)? = isRetryable ? { [weak self] in
        guard let self = self else { return }
        Task {
          // Brief delay before retrying server errors to give the API time to recover
          if isServerError {
            DebugLogger.log("RETRY: Waiting 3s before retrying after server error...")
            try? await Task.sleep(nanoseconds: 3_000_000_000)
          }
          switch mode {
          case .transcription:
            await self.performTranscription(audioURL: audioURL)
          case .prompt:
            await self.performPrompting(audioURL: audioURL)
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
      
      // Present error (state + popup with optional retry/dismiss/Top up); processing already dismissed above
      let url = transcriptionError?.topUpURL
      self.presentError(shortTitle: shortTitle, message: errorMessage, dismissProcessingFirst: false, retryAction: retryAction, dismissAction: dismissAction, topUpURL: url)
      
      // Clean up non-retryable errors immediately
      if !isRetryable {
        cleanupAudioFile(at: audioURL)
      }
    }
  }
  
  private func performTranscription(audioURL: URL, duringMeeting: Bool = false) async {
    do {
      let result = try await speechService.transcribe(audioURL: audioURL)
      clipboardManager.copyToClipboard(text: result)
      ContextLogger.shared.logTranscription(result: result, model: await speechService.getTranscriptionModelInfo())

      await MainActor.run {
        self.autoPasteIfEnabled()
      }

      reviewPrompter.recordSuccessfulOperation(window: statusItem?.button?.window)

      let modelInfo = await self.speechService.getTranscriptionModelInfo()
      
      await MainActor.run {
        PopupNotificationWindow.dismissProcessing()
        PopupNotificationWindow.showTranscriptionResponse(result, modelInfo: modelInfo)
        if duringMeeting {
          self.activeMeetingSegment = nil
        } else {
          self.appState = self.appState.showSuccess("Transcription copied to clipboard")
        }
        self.chunkStatuses = []
        if self.currentTranscriptionAudioURL == audioURL {
          self.currentTranscriptionAudioURL = nil
        }
        self.processedAudioURLs.remove(audioURL)
      }
      
      cleanupAudioFile(at: audioURL)
    } catch is CancellationError {
      DebugLogger.log("CANCELLATION: Transcription task was cancelled")
      await MainActor.run {
        if duringMeeting {
          self.activeMeetingSegment = nil
          self.processedAudioURLs.remove(audioURL)
        } else {
          self.transitionToIdleAndCleanup(cleanupAudioURL: audioURL, clearChunkStatuses: true)
        }
      }
      if duringMeeting { cleanupAudioFile(at: audioURL) }
    } catch {
      let isStale: Bool = await MainActor.run {
        if !duringMeeting, self.currentTranscriptionAudioURL != audioURL {
          DebugLogger.log("CANCELLATION: Ignoring transcription error for stale audio URL \(audioURL.lastPathComponent)")
          self.processedAudioURLs.remove(audioURL)
          self.cleanupAudioFile(at: audioURL)
          return true
        }
        return false
      }
      if isStale { return }
      if duringMeeting {
        DebugLogger.logError("MEETING-SEGMENT: Transcription failed: \(error.localizedDescription)")
        await MainActor.run {
          self.activeMeetingSegment = nil
          self.processedAudioURLs.remove(audioURL)
          PopupNotificationWindow.showError(SpeechErrorFormatter.formatForUser(error), title: "Transcription Error")
        }
        cleanupAudioFile(at: audioURL)
      } else {
        await handleProcessingError(error: error, audioURL: audioURL, mode: .transcription)
        await MainActor.run {
          self.chunkStatuses = []
          if self.currentTranscriptionAudioURL == audioURL {
            self.currentTranscriptionAudioURL = nil
          }
          self.processedAudioURLs.remove(audioURL)
        }
      }
    }
  }

  private func performPrompting(audioURL: URL, duringMeeting: Bool = false) async {
    do {
      let result = try await speechService.executePrompt(audioURL: audioURL, mode: .togglePrompting)
      clipboardManager.copyToClipboard(text: result)

      await MainActor.run {
        self.autoPasteIfEnabled()
      }

      reviewPrompter.recordSuccessfulOperation(window: statusItem?.button?.window)

      await MainActor.run {
        let modelInfo = self.speechService.getPromptModelInfo()
        PopupNotificationWindow.showPromptResponse(result, modelInfo: modelInfo)
        if duringMeeting {
          self.activeMeetingSegment = nil
        } else {
          self.appState = self.appState.showSuccess("AI response copied to clipboard")
        }
        self.processedAudioURLs.remove(audioURL)
      }
      
      cleanupAudioFile(at: audioURL)
    } catch is CancellationError {
      DebugLogger.log("CANCELLATION: Prompt task was cancelled")
      await MainActor.run {
        if duringMeeting {
          self.activeMeetingSegment = nil
        } else {
          self.appState = self.appState.finish()
        }
        self.processedAudioURLs.remove(audioURL)
      }
      cleanupAudioFile(at: audioURL)
    } catch {
      if duringMeeting {
        DebugLogger.logError("MEETING-SEGMENT: Prompt failed: \(error.localizedDescription)")
        await MainActor.run {
          self.activeMeetingSegment = nil
          self.processedAudioURLs.remove(audioURL)
          PopupNotificationWindow.showError(SpeechErrorFormatter.formatForUser(error), title: "Prompt Error")
        }
        cleanupAudioFile(at: audioURL)
      } else {
        await handleProcessingError(error: error, audioURL: audioURL, mode: .prompt)
        await MainActor.run {
          self.processedAudioURLs.remove(audioURL)
        }
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

  /// Dismisses processing popup, optionally cleans up one audio URL and chunk statuses, then transitions to idle.
  private func transitionToIdleAndCleanup(cleanupAudioURL: URL? = nil, clearChunkStatuses: Bool = false) {
    PopupNotificationWindow.dismissProcessing()
    if clearChunkStatuses {
      chunkStatuses = []
    }
    if let url = cleanupAudioURL {
      if currentTranscriptionAudioURL == url {
        currentTranscriptionAudioURL = nil
      }
      cleanupAudioFile(at: url)
      processedAudioURLs.remove(url)
    }
    appState = appState.finish()
    NotificationCenter.default.post(name: .ttsDidStop, object: nil)
  }

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
    // Use a private event source so modifier keys physically held (e.g. Option from the
    // global shortcut) do not leak into the synthetic Cmd+C and turn it into Cmd+Option+C.
    let source = CGEventSource(stateID: .privateState)
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
    let autoPasteEnabled = UserDefaults.standard.object(forKey: UserDefaultsKeys.autoPasteAfterDictation) != nil
      ? UserDefaults.standard.bool(forKey: UserDefaultsKeys.autoPasteAfterDictation)
      : SettingsDefaults.autoPasteAfterDictation
    if autoPasteEnabled {
      guard AccessibilityPermissionManager.hasAccessibilityPermission() else {
        DebugLogger.logWarning("AUTO-PASTE: Skipped — accessibility permission not granted, showing permission dialog")
        AccessibilityPermissionManager.showAccessibilityPermissionDialog()
        return
      }
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
    let recordingModeStr = String(describing: appState.recordingMode ?? .none)
    DebugLogger.logDebug("audioRecorderDidFinishRecording called - audioURL: \(audioURL.lastPathComponent), fileSize: \(fileSize), appState: \(appState), recordingMode: \(recordingModeStr)")

    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      // Prevent processing the same audio file multiple times (race condition protection)
      guard !self.processedAudioURLs.contains(audioURL) else {
        DebugLogger.logWarning("AUDIO: Ignoring duplicate audioRecorderDidFinishRecording for \(audioURL.lastPathComponent)")
        return
      }

      // Meeting segment path: recording finished for a parallel action during live meeting
      if let segment = self.activeMeetingSegment {
        DebugLogger.log("MEETING-SEGMENT: Recording finished for segment \(segment), dispatching pipeline")
        self.processedAudioURLs.insert(audioURL)
        Task {
          switch segment {
          case .dictation:
            await self.performTranscription(audioURL: audioURL, duringMeeting: true)
          case .prompt:
            await self.performPrompting(audioURL: audioURL, duringMeeting: true)
          }
        }
        return
      }

      guard case .recording(let recordingMode) = self.appState else {
        DebugLogger.logWarning("AUDIO: audioRecorderDidFinishRecording called but appState is not recording")
        return
      }

      // Recording safeguard: confirm above duration (same pattern as AccessibilityPermissionManager)
      let threshold = ConfirmAboveDuration.loadFromUserDefaults()

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
          self.appState = self.appState.finish()
          return
        }
      }

      // Mark this URL as processed to prevent duplicate processing
      self.processedAudioURLs.insert(audioURL)

      if recordingMode == .transcription {
        self.currentTranscriptionAudioURL = audioURL
      }

      self.appState = self.appState.stopRecording()

      Task {
        switch recordingMode {
        case .transcription:
          let model = TranscriptionModel.loadSelected()
          if model.isOffline, await !LocalSpeechService.shared.isReady() {
            await MainActor.run {
              PopupNotificationWindow.showProcessing(
                "Initializing \(model.displayName)... The first time can take several minutes.",
                title: "Loading Whisper Model"
              )
            }
          }
          await self.performTranscription(audioURL: audioURL)
        case .prompt:
          await self.performPrompting(audioURL: audioURL)
        case .liveMeeting:
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
    if activeMeetingSegment != nil {
      DebugLogger.logWarning("MEETING-SEGMENT: Recording failed during meeting segment, clearing segment")
      activeMeetingSegment = nil
    }
    presentError(shortTitle: "Recording Error", message: SpeechErrorFormatter.formatForUser(error), dismissProcessingFirst: false)
  }
}

// MARK: - ShortcutDelegate (Simple Forwarding)
extension MenuBarController: ShortcutDelegate {
  func toggleDictation() { toggleTranscription() }
  // togglePrompting is already implemented above
  // openSettings is already implemented above
  func openGemini() { openGeminiWindowFromShortcut() }
  func openMeeting() { openMeetingWindow() }
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

    // Derive TTS vs transcription from current appState (we're still in .ttsProcessing or .transcribing)
    let isTTS: Bool = { if case .processing(let mode) = appState { return mode.isTTSContext } else { return false } }()
    let context: AppState.ProcessingMode.ChunkContext = isTTS ? .tts : .transcription

    appState = .processing(.splitting(context: context))
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

    let context: AppState.ProcessingMode.ChunkContext = { if case .processing(let mode) = appState { return mode.chunkContext } else { return .transcription } }()
    appState = .processing(.processingChunks(statuses: chunkStatuses, context: context))
    updateMenuBarIcon()

    let isTTS = context == .tts

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

    let context: AppState.ProcessingMode.ChunkContext = { if case .processing(let mode) = appState { return mode.chunkContext } else { return .transcription } }()
    appState = .processing(.processingChunks(statuses: chunkStatuses, context: context))
    updateMenuBarIcon()

    let isTTS = context == .tts

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

      let context: AppState.ProcessingMode.ChunkContext = { if case .processing(let mode) = appState { return mode.chunkContext } else { return .transcription } }()
      appState = .processing(.processingChunks(statuses: chunkStatuses, context: context))
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

    let context: AppState.ProcessingMode.ChunkContext = { if case .processing(let mode) = appState { return mode.chunkContext } else { return .transcription } }()
    appState = .processing(.merging(context: context))
    updateMenuBarIcon()

    let isTTS = context == .tts

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
        // Transcribe the chunk using the meeting-specific model (or Dictate model if not set)
        let text = try await speechService.transcribe(audioURL: audioURL, preferredModel: TranscriptionModel.loadSelectedForMeeting())

        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmedText.isEmpty {
          DebugLogger.log("LIVE-MEETING: Chunk \(chunkIndex) skipped (silent)")
        } else {
          // Append to transcript on main thread and maybe trigger rolling summary
          await MainActor.run {
            self.appendToTranscript(trimmedText, chunkStartTime: startTime)
            self.triggerRollingSummaryUpdateIfNeeded()
          }
        }

        // Cleanup audio file
        cleanupAudioFile(at: audioURL)

      } catch {
        DebugLogger.logError("LIVE-MEETING: Chunk \(chunkIndex) transcription failed: \(error)")
        // Show user once when quota/rate limit is hit so they know why chunks are missing
        let isRateLimitOrQuota: Bool = {
          if let te = error as? TranscriptionError {
            switch te { case .rateLimited, .quotaExceeded: return true; default: return false }
          }
          return false
        }()
        if isRateLimitOrQuota {
          await MainActor.run {
            if !self.liveMeetingDidShowRateLimitAlert {
              self.liveMeetingDidShowRateLimitAlert = true
              PopupNotificationWindow.showError(
                SpeechErrorFormatter.formatForUser(error),
                title: "Live Meeting – Quota Reached"
              )
            }
          }
        }
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
      PopupNotificationWindow.showError(SpeechErrorFormatter.formatForUser(error), title: "Live Meeting")
    }
  }
}
