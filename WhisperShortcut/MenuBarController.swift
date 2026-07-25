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

  /// Identifies status-menu rows. `NSMenuItem.tag` is the only handle AppKit gives us for
  /// finding an item again after creation, so the creation site in `createMenu()` and the
  /// refresh site in `updateMenuItems()` used to be linked by nothing but matching integer
  /// literals. Naming them makes that link something the compiler checks.
  ///
  /// Raw values are the historical tags, kept as-is: they are persisted nowhere, but leaving
  /// them unchanged keeps this a pure rename.
  private enum MenuTag: Int {
    case status = 100
    case dictate = 101
    case dictatePrompt = 102
    case settings = 103
    case chat = 110
    case stop = 111
    case stopSeparator = 112
    case screenshot = 113
    case readAloud = 114
    case rate = 115
    case voiceFeedback = 116
  }

  /// Display time for the benign "No speech detected" info popup — long enough to read,
  /// far shorter than the persistent error-popup duration.
  private static let noSpeechInfoDuration: TimeInterval = 4

  // MARK: - Single Source of Truth
  private var appState: AppState = .idle {
    didSet {
      DebugLogger.logDebug("APPSTATE: \(oldValue) -> \(appState) (mainThread=\(Thread.isMainThread))")
      updateUI()
      updateRecordingIndicator()

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
  private let audioRecorder: DictationAudioRecording
  private let speechService: SpeechService
  private let clipboardManager: ClipboardManager
  private let voiceFeedbackService = VoiceFeedbackService()
  private let shortcuts: Shortcuts
  private let fnPushToTalk = FnPushToTalk()
  private let reviewPrompter: ReviewPrompter
  
  // MARK: - State Tracking (Prevent Race Conditions)
  /// Set when the user hits ✕ on the recording indicator: the next
  /// `audioRecorderDidFinishRecording` discards the audio instead of processing it.
  private var discardNextRecording = false

  /// Per-recording streaming session (slice 2 of plans/active/streaming-dictate.md).
  /// Non-nil only while a Dictate recording on a cloud STT model (Gemini/OpenAI/xAI) is
  /// active/processing; prompt recordings, offline Whisper, and self-hosted endpoints
  /// leave it nil (single-shot path).
  private var dictateStreamingSession: DictateStreamingSession?
  private var currentTranscriptionAudioURL: URL?
  private var processedAudioURLs: Set<URL> = []
  private var audioEngine: AVAudioEngine?
  private var audioPlayerNode: AVAudioPlayerNode?
  private var timePitchNode: AVAudioUnitTimePitch?

  // MARK: - Configuration
  private var currentConfig: ShortcutConfig

  // MARK: - Chunk Progress Tracking
  private var chunkStatuses: [ChunkStatus] = []

  // MARK: - Live Meeting
  /// Owns the whole live-meeting session: transcript file, chunk pipeline, rolling-summary policy.
  /// Created once and reused across meetings. `appState` stays here — the session reports its
  /// lifecycle through the callbacks below rather than mutating the app's source of truth.
  private lazy var liveMeeting = LiveMeetingSession(
    transcribeChunk: { [unowned self] url in
      try await self.speechService.transcribe(
        audioURL: url,
        preferredModel: TranscriptionModel.loadSelectedForMeeting(),
        promptOverride: AppConstants.liveMeetingDiarizationPrompt,
        cancellable: false
      )
    },
    cleanUpAudioFile: { [weak self] url in self?.cleanupAudioFile(at: url) },
    appStateIsRecordingMeeting: { [weak self] in self?.appState.recordingMode == .liveMeeting },
    onFinished: { [weak self] in
      guard let self else { return }
      self.appState = self.appState.finish()
    })

  /// True when live meeting is active (recording or stopping with pending chunks).
  private var isLiveMeetingActive: Bool {
    appState.recordingMode == .liveMeeting || liveMeeting.isRecording
  }

  // MARK: - Meeting Segment (parallel action during live meeting)
  private enum MeetingSegment {
    case dictation
    case prompt
  }
  /// When non-nil, an action is running in parallel with the live meeting.
  private var activeMeetingSegment: MeetingSegment?

  /// True when TTS is running in any phase: .ttsProcessing or chunked phases with TTS context. Derived from AppState only.
  private var isTTSRunning: Bool {
    if case .processing(let mode) = appState { return mode.isTTSContext }
    return false
  }

  init(
    audioRecorder: DictationAudioRecording = AppConstants.useChunkedDictateRecorder
      ? ChunkedDictateRecorder() : AudioRecorder(),
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
      ChatWindowManager.shared.preWarm()
    }
  }

  // MARK: - Setup
  private func setupMenuBar() {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    guard let statusItem = statusItem else { return }

    // Initial setup
    if let button = statusItem.button {
      applyCurrentAppearance(to: button)
      button.toolTip = appState.tooltip
    }

    // Create menu. The delegate fires pending review/support prompts on open (menuWillOpen).
    let menu = createMenu()
    menu.delegate = self
    statusItem.menu = menu
    updateUI()
  }

  private func createMenu() -> NSMenu {
    let menu = NSMenu()
    menu.showsStateColumn = false

    // Status item
    let statusMenuItem = NSMenuItem(title: appState.statusText, action: nil, keyEquivalent: "")
    statusMenuItem.tag = MenuTag.status.rawValue
    menu.addItem(statusMenuItem)

    menu.addItem(NSMenuItem.separator())

    // Central stop button — visible only when any operation is active
    let stopItem = createMenuItem("Stop", action: #selector(stopCurrentOperation), tag: .stop)
    menu.addItem(stopItem)
    let stopSeparator = NSMenuItem.separator()
    stopSeparator.tag = MenuTag.stopSeparator.rawValue
    menu.addItem(stopSeparator)

    // Recording actions with keyboard shortcuts
    menu.addItem(
      createMenuItemWithShortcut(
        "Dictate", action: #selector(toggleTranscription),
        shortcut: currentConfig.startRecording, tag: .dictate))
    menu.addItem(
      createMenuItemWithShortcut(
        "Dictate Prompt", action: #selector(togglePrompting),
        shortcut: currentConfig.startPrompting, tag: .dictatePrompt))
    menu.addItem(
      createMenuItemWithShortcut(
        "Screenshot", action: #selector(takeScreenshot),
        shortcut: currentConfig.screenshotCapture, tag: .screenshot))
    // Selection-based Read Aloud copies via ⌘C (Accessibility) — omitted from the App Store build.
    #if !APP_STORE
    menu.addItem(
      createMenuItemWithShortcut(
        "Read Aloud", action: #selector(readAloudFromMenu),
        shortcut: currentConfig.readAloud, tag: .readAloud))
    #endif
    // Ordered last so the shortcut digits read 1-2-3-4-5 down the menu.
    menu.addItem(
      createMenuItemWithShortcut(
        "Voice Feedback", action: #selector(toggleVoiceFeedback),
        shortcut: currentConfig.voiceFeedback, tag: .voiceFeedback))
    menu.addItem(NSMenuItem.separator())

    // Chat window
    menu.addItem(
      createMenuItemWithShortcut(
        "Chat", action: #selector(openChatWindow),
        shortcut: currentConfig.openChat, tag: .chat))

    menu.addItem(NSMenuItem.separator())

    // Settings and quit.
    // Use a neutral selector and clear image explicitly to avoid AppKit
    // auto-decoration that can reserve an icon column for this row.
    let configureItem = createMenuItemWithShortcut(
      "Settings…", action: #selector(openConfigurationPanel),
      shortcut: currentConfig.openSettings, tag: .settings)
    configureItem.image = nil
    menu.addItem(configureItem)
    menu.addItem(
      createMenuItem("Rate WhisperShortcut", action: #selector(rateApp), tag: .rate))
    menu.addItem(
      createMenuItem("Quit WhisperShortcut", action: #selector(quitApp), keyEquivalent: "q"))

    return menu
  }

  private func createMenuItem(
    _ title: String, action: Selector, keyEquivalent: String = "", tag: MenuTag? = nil
  ) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
    item.target = self
    item.tag = tag?.rawValue ?? 0
    return item
  }

  private func createMenuItemWithShortcut(
    _ title: String, action: Selector, shortcut: ShortcutDefinition, tag: MenuTag? = nil
  ) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
    item.target = self
    item.tag = tag?.rawValue ?? 0

    // Add keyboard shortcut display to the menu item
    if shortcut.isEnabled {
      // Set the actual key equivalent for single character keys
      let keyChar = getKeyEquivalentCharacter(for: shortcut.key)
      if !keyChar.isEmpty {
        item.keyEquivalent = keyChar
        item.keyEquivalentModifierMask = shortcut.modifiers
      } else {
        // For complex keys, append the shortcut to the title padded to a fixed
        // width so the shortcut glyphs align in a column across menu rows.
        let columnWidth = 26
        let paddedTitle =
          title.count < columnWidth
          ? title.padding(toLength: columnWidth, withPad: " ", startingAt: 0)
          : title + "  "
        item.title = "\(paddedTitle)\(shortcut.displayString)"
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
    fnPushToTalk.delegate = self
    speechService.chunkProgressDelegate = self

    // Floating recording indicator (bottom-center pill with live level bars)
    audioRecorder.onLevelSample = { dB in
      RecordingIndicatorManager.shared.updateLevel(dB: dB)
    }

    // Streaming Dictate: route rotated-out chunks into the per-recording session (nil for
    // prompt recordings and non-cloud STT models — the callbacks are then no-ops).
    if let chunkedRecorder = audioRecorder as? ChunkedDictateRecorder {
      chunkedRecorder.onChunkFinalized = { [weak self] url, index, isSilent in
        self?.dictateStreamingSession?.addChunk(url: url, index: index, isSilent: isSilent)
      }
      chunkedRecorder.onFinalChunk = { [weak self] url, index, isSilent in
        self?.dictateStreamingSession?.addFinalChunk(url: url, index: index, isSilent: isSilent)
      }
    }
    RecordingIndicatorManager.shared.onCancel = { [weak self] in
      self?.handleIndicatorCancel()
    }
    RecordingIndicatorManager.shared.onConfirm = { [weak self] in
      self?.handleIndicatorConfirm()
    }
  }

  // MARK: - Recording Indicator

  /// Keeps the floating bottom-center pill in sync with `appState`. It shows the
  /// recording pill for Dictate / Dictate Prompt, and the compact processing spinner
  /// for both those flows (handed off from recording) and Read Aloud / TTS synthesis
  /// (summoned directly, since TTS has no recording phase). Once TTS hands off to
  /// playback the state is `.speaking`, so the pill hides — the audio itself is the
  /// feedback. On success (and every other state) it hides immediately — lingering UI
  /// would cover the user's work. Live-meeting recording stays pill-less.
  private func updateRecordingIndicator() {
    let indicator = RecordingIndicatorManager.shared
    switch appState {
    case .recording(.transcription), .recording(.prompt), .recording(.voiceFeedback):
      indicator.showRecording()
    case .processing(let mode):
      // TTS has no recording phase, so summon the processing pill directly;
      // Dictate / Dictate Prompt already have it on screen from recording.
      indicator.showProcessing(summonIfNeeded: mode.isTTSContext)
    default:
      indicator.hide()
    }
  }

  /// ✕ on the indicator: discard an active recording, or cancel in-flight processing.
  private func handleIndicatorCancel() {
    if appState.isRecording {
      DebugLogger.log("AUDIO: Recording discarded via indicator ✕")
      discardNextRecording = true
      RecordingIndicatorManager.shared.hide()
      audioRecorder.stopRecording()
      return
    }
    if isTranscriptionProcessing {
      cancelInFlightTranscription()
      return
    }
    if isTTSRunning {
      DebugLogger.log("TTS: Read Aloud synthesis cancelled via indicator ✕")
      finishReadAloudSession()
      return
    }
    if case .processing(.prompting) = appState {
      speechService.cancelPrompt()
      transitionToIdleAndCleanup()
      return
    }
    if case .processing(.contextEditing) = appState {
      speechService.cancelTranscription()
      transitionToIdleAndCleanup()
    }
  }

  /// ✓ on the indicator: same as the stop shortcut — finish recording and process.
  private func handleIndicatorConfirm() {
    guard appState.isRecording else { return }
    stopRecordingAfterTailDelay()
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
      selector: #selector(startNewLiveMeeting),
      name: .chatStartNewMeeting,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(resumeLiveMeetingFromNotification),
      name: .chatResumeMeeting,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(stopLiveMeetingFromNotification),
      name: .chatStopLiveMeeting,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(endMeetingWithName(_:)),
      name: .chatEndMeetingWithName,
      object: nil
    )

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(chatReadAloudWithNotification(_:)),
      name: .chatReadAloud,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(chatReadAloudStopFromNotification),
      name: .chatReadAloudStop,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(refreshLiveMeetingSummaryOnDemand),
      name: .liveMeetingSummaryRefreshRequested,
      object: nil
    )
  }

  @objc private func chatReadAloudStopFromNotification() {
    DispatchQueue.main.async { [weak self] in
      // Stop-only callback: if nothing is playing we're already idle, so the false return
      // from the helper is a harmless no-op.
      _ = self?.attemptReadAloudToggleOff()
    }
  }

  @objc private func chatReadAloudWithNotification(_ notification: Notification) {
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      let text = (notification.userInfo?[Notification.Name.chatReadAloudTextKey] as? String)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      guard !text.isEmpty else { return }
      // `readAloud(_:)` runs the same toggle-off check internally, so we don't repeat it here.
      self.readAloud(text)
    }
  }

  @objc private func endMeetingWithName(_ notification: Notification) {
    let name = (notification.userInfo?["meetingName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    let discard = notification.userInfo?["discard"] as? Bool ?? false
    DispatchQueue.main.async { [weak self] in
      self?.liveMeeting.end(preferredName: name, discard: discard)
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
    fnPushToTalk.setup()
  }

  // MARK: - UI Updates (Single Method!)
  private func updateUI() {
    updateMenuBarIcon()
    updateMenuItems()
    updateBlinking()
  }

  private func updateMenuBarIcon() {
    guard let button = statusItem?.button else { return }
    applyCurrentAppearance(to: button)

    // Show detailed chunk progress in tooltip during processing
    if case .processing(.processingChunks(let statuses, _)) = appState {
      let active = statuses.filter { $0 == .active }.count
      let done = statuses.filter { $0 == .completed }.count
      button.toolTip = "Transcribing [\(done)/\(statuses.count)] - \(active) active"
    } else {
      button.toolTip = appState.tooltip
    }
  }

  /// Renders the current `appState` on the status item button: an SF Symbol template image
  /// when `appState.symbolName` is set (idle), otherwise the colored emoji from `appState.icon`.
  private func applyCurrentAppearance(to button: NSStatusBarButton) {
    if let symbolName = appState.symbolName {
      // mic.fill's stand made it clip against the menu bar bezel intermittently at 15pt.
      // 14pt + scaleProportionallyDown lets AppKit fit any intrinsic image size into the bar.
      let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
      let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: appState.tooltip)?
        .withSymbolConfiguration(config)
      image?.isTemplate = true
      button.image = image
      button.imageScaling = .scaleProportionallyDown
      button.title = ""
    } else {
      button.image = nil
      button.title = appState.icon
    }
  }

  private func updateMenuItems() {
    guard let menu = statusItem?.menu else { return }

    let selectedTranscriptionModel = TranscriptionModel.loadSelected()
    let hasOfflineTranscriptionModel = selectedTranscriptionModel.isOfflineModelAvailable()
    let canTranscribe = selectedTranscriptionModel.hasRequiredCredential
    let canPrompt = PromptModel.loadPromptModel(
      forKey: UserDefaultsKeys.selectedPromptModel,
      default: SettingsDefaults.selectedPromptModel).hasRequiredCredential
    #if !APP_STORE
    let canReadAloud = ReadAloudPreferences.model.hasRequiredCredential
    #endif
    let hasAnyKey = GeminiCredentialProvider.shared.hasCredential()
      || KeychainManager.shared.hasValidOpenAIAPIKey()
      || KeychainManager.shared.hasValidXAIAPIKey()
      || KeychainManager.shared.hasValidAnthropicAPIKey()

    // Update status
    menu.item(withTag: MenuTag.status.rawValue)?.title = appState.statusText

    // Show central Stop button only when something is active
    let isAnythingActive = appState.isBusy || isLiveMeetingActive
      || audioEngine?.isRunning == true
    menu.item(withTag: MenuTag.stop.rawValue)?.isHidden = !isAnythingActive
    menu.item(withTag: MenuTag.stopSeparator.rawValue)?.isHidden = !isAnythingActive

    // During a live meeting, all actions are available as parallel segments
    let meetingAllowsActions = isLiveMeetingActive && activeMeetingSegment == nil

    // Update action items based on current state
    updateMenuItem(
      menu, tag: .dictate,
      title: (appState.recordingMode == .transcription || activeMeetingSegment == .dictation)
        ? "Stop Dictate" : "Dictate",
      enabled: appState.canStartTranscription(hasAPIKey: canTranscribe, hasOfflineModel: false)
        || appState.recordingMode == .transcription
        || meetingAllowsActions && canTranscribe
        || activeMeetingSegment == .dictation)

    updateMenuItem(
      menu, tag: .dictatePrompt,
      title: (appState.recordingMode == .prompt || activeMeetingSegment == .prompt)
        ? "Stop Dictate Prompt" : "Dictate Prompt",
      enabled: appState.canStartPrompting(hasAPIKey: canPrompt, hasOfflineModel: false)
        || appState.recordingMode == .prompt
        || meetingAllowsActions && canPrompt
        || activeMeetingSegment == .prompt
    )

    // Read Aloud item: title toggles to Stop while a TTS phase is active or audio is playing.
    // Omitted from the App Store build, where the selection-based Read Aloud menu item is absent.
    #if !APP_STORE
    let isReadAloudActive = isTTSRunning || audioEngine?.isRunning == true
    updateMenuItem(
      menu, tag: .readAloud,
      title: isReadAloudActive ? "Stop Read Aloud" : "Read Aloud",
      enabled: canReadAloud && (!appState.isBusy || isReadAloudActive)
    )
    #endif

    // Handle special case when no API key (any provider) and no offline model is configured
    if !hasAnyKey && !hasOfflineTranscriptionModel, let button = statusItem?.button {
      button.image = nil
      button.title = "⚠️"
      button.toolTip = "Add an API key or use an offline model - click to configure"
    }
  }

  private func updateMenuItem(_ menu: NSMenu, tag: MenuTag, title: String, enabled: Bool) {
    guard let item = menu.item(withTag: tag.rawValue) else { return }
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
      button.alphaValue = button.alphaValue < 1.0 ? 1.0 : 0.35
    }
  }

  private func stopBlinking() {
    blinkTimer?.invalidate()
    blinkTimer = nil
    // Restore correct icon at full opacity
    if let button = statusItem?.button {
      button.alphaValue = 1.0
      applyCurrentAppearance(to: button)
    }
  }


  // MARK: - Actions (Simplified Logic)
  /// Stops the recorder after a short delay so the spoken tail (the last word or two before
  /// the shortcut fires) is captured instead of clipped. Used by every recording-stop path.
  /// Skips the delay entirely when the last ~400 ms of audio was below the silence threshold
  /// — there's no tail to catch, and the user gets the result that much sooner.
  private func stopRecordingAfterTailDelay() {
    if audioRecorder.hasRecentlyBeenSilent {
      DebugLogger.logAudio("AUDIO: Skipping tail-capture delay — recent audio was silent")
      audioRecorder.stopRecording()
      return
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + Constants.audioTailCaptureDelay) { [weak self] in
      self?.audioRecorder.stopRecording()
    }
  }

  @objc private func toggleTranscription() {
    // During live meeting: run dictation as a parallel segment
    if isLiveMeetingActive {
      if activeMeetingSegment == .dictation {
        DebugLogger.log("MEETING-SEGMENT: Stopping dictation segment")
        stopRecordingAfterTailDelay()
        return
      }
      if activeMeetingSegment != nil {
        DebugLogger.logWarning("MEETING-SEGMENT: Another segment already active, ignoring dictation")
        return
      }
      let selectedModel = TranscriptionModel.loadSelected()
      let hasOfflineModel = selectedModel.isOfflineModelAvailable()
      if selectedModel.hasRequiredCredential || hasOfflineModel {
        DebugLogger.log("MEETING-SEGMENT: Starting dictation segment during meeting")
        activeMeetingSegment = .dictation
        ConnectionPrewarmer.prewarm(for: selectedModel)
        dictateStreamingSession = DictateStreamingSession.makeIfEligible(speechService: speechService)
        audioRecorder.startRecording()
      } else {
        PopupNotificationWindow.showError(
          selectedModel.apiKeyRequiredMessage,
          title: selectedModel.credentialRequiredTitle
        )
      }
      return
    }

    // Check if currently processing transcription (incl. chunk phases for long audio) - if so, cancel it
    if isTranscriptionProcessing {
      cancelInFlightTranscription()
      return
    }
    
    switch appState.recordingMode {
    case .transcription:
      stopRecordingAfterTailDelay()
    case .none:
      let selectedModel = TranscriptionModel.loadSelected()
      let hasOfflineModel = selectedModel.isOfflineModelAvailable()

      if appState.canStartTranscription(hasAPIKey: selectedModel.hasRequiredCredential, hasOfflineModel: hasOfflineModel) {
        appState = appState.startRecording(.transcription)
        ConnectionPrewarmer.prewarm(for: selectedModel)
        dictateStreamingSession = DictateStreamingSession.makeIfEligible(speechService: speechService)
        audioRecorder.startRecording()
      } else {
        PopupNotificationWindow.showError(
          selectedModel.apiKeyRequiredMessage,
          title: selectedModel.credentialRequiredTitle
        )
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
        stopRecordingAfterTailDelay()
        return
      }
      if activeMeetingSegment != nil {
        DebugLogger.logWarning("MEETING-SEGMENT: Another segment already active, ignoring prompt")
        return
      }
      let promptModel = PromptModel.loadPromptModel(
        forKey: UserDefaultsKeys.selectedPromptModel, default: SettingsDefaults.selectedPromptModel)
      if promptModel.hasRequiredCredentialForDictatePrompt {
        if !prepareDictatePromptSelection(logPrefix: "MEETING-SEGMENT") { return }
        DebugLogger.log("MEETING-SEGMENT: Starting prompt segment during meeting")
        activeMeetingSegment = .prompt
        ConnectionPrewarmer.prewarm(for: promptModel)
        discardStreamingSession()  // prompt recordings never stream
        audioRecorder.startRecording()
      } else {
        PopupNotificationWindow.showError(promptModel.apiKeyRequiredMessageForDictatePrompt, title: "API Key Required")
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
      stopRecordingAfterTailDelay()
    case .none:
      let promptModel = PromptModel.loadPromptModel(
        forKey: UserDefaultsKeys.selectedPromptModel, default: SettingsDefaults.selectedPromptModel)
      if appState.canStartPrompting(hasAPIKey: promptModel.hasRequiredCredentialForDictatePrompt, hasOfflineModel: false) {
        if !prepareDictatePromptSelection(logPrefix: "PROMPT-MODE") { return }
        appState = appState.startRecording(.prompt)
        ConnectionPrewarmer.prewarm(for: promptModel)
        discardStreamingSession()  // prompt recordings never stream
        audioRecorder.startRecording()
      } else {
        PopupNotificationWindow.showError(promptModel.apiKeyRequiredMessageForDictatePrompt, title: "API Key Required")
      }
    default:
      break
    }
  }

  /// Voice Feedback: record a spoken instruction that edits the dictation context.
  /// Slice 1 transcribes the instruction and shows what was heard; Slice 2 turns it into a
  /// reviewable change to `system-prompts.md`.
  @objc internal func toggleVoiceFeedback() {
    // Voice Feedback is a standalone flow — not a live-meeting segment.
    if isLiveMeetingActive {
      DebugLogger.log("VOICE-FEEDBACK: Ignoring — live meeting active")
      return
    }

    // Cancel an in-flight context-editing pass.
    if case .processing(.contextEditing) = appState {
      speechService.cancelTranscription()
      transitionToIdleAndCleanup()
      return
    }

    switch appState.recordingMode {
    case .voiceFeedback:
      stopRecordingAfterTailDelay()
    case .none:
      // Two credentials are needed: the transcription model transcribes the spoken instruction,
      // then the improvement model turns it into a proposed change. Check both up front so the
      // user isn't told about a missing key only after speaking.
      let transcriptionModel = TranscriptionModel.loadSelected()
      let hasOfflineModel = transcriptionModel.isOfflineModelAvailable()
      guard appState.canStartTranscription(
        hasAPIKey: transcriptionModel.hasRequiredCredential, hasOfflineModel: hasOfflineModel)
      else {
        PopupNotificationWindow.showError(
          transcriptionModel.apiKeyRequiredMessage, title: transcriptionModel.credentialRequiredTitle)
        return
      }
      let improvementModel = PromptModel.loadPromptModel(
        forKey: UserDefaultsKeys.selectedImprovementModel,
        default: SettingsDefaults.selectedImprovementModel)
      guard improvementModel.hasRequiredCredentialForDictatePrompt else {
        PopupNotificationWindow.showError(
          improvementModel.apiKeyRequiredMessageForDictatePrompt, title: "API Key Required")
        return
      }
      appState = appState.startRecording(.voiceFeedback)
      ConnectionPrewarmer.prewarm(for: transcriptionModel)
      discardStreamingSession()  // voice feedback never streams
      audioRecorder.startRecording()
    default:
      break
    }
  }

  @objc private func stopCurrentOperation() {
    // Active meeting segment: stop the segment first, keep meeting running.
    // `activeMeetingSegment` stays set so the async `audioRecorderDidFinishRecording`
    // delegate routes the captured audio through the segment-processing path
    // (`performTranscription`/`performPrompting`) instead of falling through to the
    // .liveMeeting arm that drops the audio. `stopRecordingAfterTailDelay` preserves
    // the spoken tail, matching `toggleTranscription`/`togglePrompting`.
    if activeMeetingSegment != nil {
      DebugLogger.log("MEETING-SEGMENT: Stopping active segment via Stop button")
      stopRecordingAfterTailDelay()
      return
    }

    // Live meeting (no active segment)
    if isLiveMeetingActive { stopLiveMeeting(); return }

    // Read Aloud: TTS network work and/or local playback
    if isTTSRunning || audioEngine?.isRunning == true {
      finishReadAloudSession(cancelNetworkWork: isTTSRunning)
      return
    }

    // Transcription processing
    if isTranscriptionProcessing {
      cancelInFlightTranscription()
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
      stopRecordingAfterTailDelay()
    }
  }

  /// Cancels a running transcription (including chunk pipelines) and performs
  /// the shared cleanup transition.
  /// Cancels and drops the streaming session so no further chunk API calls run and a
  /// later recording can't accidentally consume stale transcripts.
  private func discardStreamingSession() {
    dictateStreamingSession?.cancel()
    dictateStreamingSession = nil
  }

  private func cancelInFlightTranscription() {
    discardStreamingSession()
    speechService.cancelTranscription()
    transitionToIdleAndCleanup(cleanupAudioURL: currentTranscriptionAudioURL)
  }

  /// True when any transcription pipeline phase is active (single request or chunked).
  private var isTranscriptionProcessing: Bool {
    guard case .processing(let mode) = appState, !mode.isTTSContext else { return false }
    switch mode {
    case .transcribing, .splitting, .processingChunks, .merging:
      return true
    case .prompting, .ttsProcessing, .contextEditing:
      return false
    }
  }

  @objc func openSettings() {
    SettingsManager.shared.toggleSettings()
  }

  @objc func openConfigurationPanel() {
    openSettings()
  }

  @objc func openChatWindow() {
    ChatWindowManager.shared.toggle()
  }

  /// Opens the chat window from the global shortcut. If the window is already open, closes it (same toggle behavior as the menu).
  private func openChatWindowFromShortcut() {
    if ChatWindowManager.shared.isWindowOpen() {
      ChatWindowManager.shared.close()
      return
    }
    ChatWindowManager.shared.show(suppressFocusLossClose: true)
  }

  // MARK: - Live Meeting Transcription
  /// Hotkey handler: picks the right action based on current state.
  /// In-window buttons should post the explicit notification (start/resume/stop) instead.
  @objc func toggleLiveMeeting() {
    if isLiveMeetingActive {
      stopLiveMeeting()
    } else if !LiveMeetingTranscriptStore.shared.chunks.isEmpty {
      startLiveMeeting(resuming: true)
    } else {
      startLiveMeeting(resuming: false)
    }
  }

  @objc private func startNewLiveMeeting() {
    guard !isLiveMeetingActive else {
      DebugLogger.logWarning("LIVE-MEETING: Ignoring start-new — meeting already active")
      return
    }
    startLiveMeeting(resuming: false)
  }

  @objc private func resumeLiveMeetingFromNotification() {
    guard !isLiveMeetingActive else {
      DebugLogger.logWarning("LIVE-MEETING: Ignoring resume — meeting already active")
      return
    }
    startLiveMeeting(resuming: true)
  }

  @objc private func stopLiveMeetingFromNotification() {
    guard isLiveMeetingActive else { return }
    stopLiveMeeting()
  }

  private func startLiveMeeting(resuming: Bool) {
    let meetingModel = TranscriptionModel.loadSelectedForMeeting()
    guard meetingModel.hasRequiredCredential else {
      PopupNotificationWindow.showError(
        meetingModel.apiKeyRequiredMessage,
        title: meetingModel.credentialRequiredTitle
      )
      return
    }

    // Check if busy with other operations
    guard !appState.isBusy else {
      DebugLogger.logWarning("LIVE-MEETING: Cannot start - app is busy")
      return
    }

    guard liveMeeting.start(resuming: resuming) else { return }
    appState = .recording(.liveMeeting)

    ChatWindowManager.shared.show(suppressFocusLossClose: true)
  }

  private func stopLiveMeeting() {
    liveMeeting.stop()
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

  /// On-demand rolling summary refresh, forwarded to the session. Called when a consumer actually
  /// needs an up-to-date live summary — the Summary tab is shown for the active meeting, or the
  /// user chats with it — rather than on a timer.
  @objc private func refreshLiveMeetingSummaryOnDemand() {
    DispatchQueue.main.async { [weak self] in self?.liveMeeting.refreshRollingSummary() }
  }

  @objc private func rateApp() {
    NSWorkspace.shared.open(ReviewPrompter.writeReviewURL)
    DebugLogger.log("REVIEW: User opened App Store write-review page from menu")
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
    retryActionTitle: String = "Retry",
    dismissAction: (() -> Void)? = nil,
    topUpURL: URL? = nil
  ) {
    if dismissProcessingFirst {
      PopupNotificationWindow.dismissProcessing()
    }
    appState = appState.showError(shortTitle)
    PopupNotificationWindow.showError(message ?? shortTitle, title: shortTitle, retryAction: retryAction, retryActionTitle: retryActionTitle, dismissAction: dismissAction, topUpURL: topUpURL)
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

      // "No speech detected" is a benign outcome, not a failure — present it exactly like
      // the local silence precheck: a brief info popup instead of the persistent error
      // popup, which sat on screen for the full error duration covering the user's work.
      if let transcriptionError = error as? TranscriptionError,
        case .noSpeechDetected = transcriptionError
      {
        self.cleanupAudioFile(at: audioURL)
        self.appState = self.appState.finish()
        PopupNotificationWindow.showInfo(
          "No speech was detected in your recording. Check that the right microphone is selected and speak clearly.",
          title: "No speech detected",
          customDisplayDuration: Self.noSpeechInfoDuration
        )
        return
      }

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
        case .voiceFeedback: operationName = "Voice Feedback"
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
          case .voiceFeedback:
            await self.performVoiceFeedback(audioURL: audioURL)
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
  
  // MARK: - Shared audio-job envelope

  /// Everything that differs between the two finished-recording pipelines. What surrounds them —
  /// cancellation detection, staleness, `processedAudioURLs` bookkeeping, the `duringMeeting` fork
  /// and the cleanup ordering — is identical and lives in `runAudioJob`.
  ///
  /// The `Bool` knobs record places where the two hand-written copies had already drifted apart.
  /// They are preserved exactly as found rather than normalised; each is `true` for transcription
  /// and `false` for prompting. Whether that divergence is intentional is a separate question from
  /// this refactor — the point here is that it is now visible in one place instead of buried in
  /// two 200-line copies.
  private struct AudioJobSpec {
    let mode: AppState.RecordingMode
    /// Used in the cancellation and meeting-segment failure log lines ("Transcription" / "Prompt").
    let logLabel: String
    /// Title of the error popup shown when the job fails during a live meeting.
    let errorTitle: String
    /// Model label rendered under the result popup.
    let modelInfo: () async -> String
    /// Writes the result to the clipboard. Transcription applies its own formatting first.
    let copyResult: (String) -> Void
    /// Shows the result popup. `title` is nil when auto-paste already delivered the text.
    let presentResult: (_ text: String, _ modelInfo: String, _ title: String?) -> Void
    /// Success-pill wording, selected by whether auto-paste ran.
    let successMessage: (_ didAutoPaste: Bool) -> String
    /// Transcription dismisses the processing popup before presenting its result; prompting never did.
    var dismissesProcessingBeforeResult = false
    /// Transcription owns `chunkStatuses` and `currentTranscriptionAudioURL`; prompting tracks neither.
    var clearsChunkState = false
    /// Transcription drops results and errors belonging to a superseded recording; prompting has no
    /// such guard, so a cancelled prompt's late result still reaches the clipboard.
    var guardsStaleAudioURL = false
    /// On cancellation transcription routes through `transitionToIdleAndCleanup` (which also
    /// dismisses the popup, clears chunk state, drops the URL and removes the file); prompting
    /// finishes the state machine and cleans the file itself.
    var cancelsViaTransitionToIdle = false
  }

  /// The plain cancellation tail: finish the state machine, drop the URL, remove the file. Shared
  /// by the prompt pipeline and Voice Feedback, which handle a cancelled recording identically.
  /// Transcription does not use it — it routes through `transitionToIdleAndCleanup` instead, which
  /// additionally clears chunk state.
  private func cancelAudioJob(logLabel: String, error: Error, audioURL: URL) async {
    DebugLogger.log("CANCELLATION: \(logLabel) task was cancelled (\(type(of: error)))")
    await MainActor.run {
      self.appState = self.appState.finish()
      self.processedAudioURLs.remove(audioURL)
    }
    cleanupAudioFile(at: audioURL)
  }

  /// Runs one finished recording: produce the text, deliver it, and clean up — or handle
  /// cancellation, staleness and failure. `afterCopy` runs between the clipboard write and
  /// auto-paste, the slot where transcription commits its audio sample and writes the log entry.
  private func runAudioJob(
    _ spec: AudioJobSpec,
    audioURL: URL,
    duringMeeting: Bool,
    produce: () async throws -> String,
    afterCopy: (String) async -> Void = { _ in }
  ) async {
    do {
      let result = try await produce()

      // A shortcut press during processing cancels the job (cancelInFlightTranscription clears
      // currentTranscriptionAudioURL), but a transcript already in flight can still arrive
      // afterwards — drop it instead of pasting a cancelled result out of idle. Same staleness
      // check as the error path below.
      if spec.guardsStaleAudioURL {
        let wasCancelled: Bool = await MainActor.run {
          if !duringMeeting, self.currentTranscriptionAudioURL != audioURL {
            DebugLogger.log(
              "CANCELLATION: Dropping transcript for cancelled recording \(audioURL.lastPathComponent)")
            self.processedAudioURLs.remove(audioURL)
            return true
          }
          return false
        }
        if wasCancelled { return }
      }

      spec.copyResult(result)
      await afterCopy(result)

      let didAutoPaste = await MainActor.run {
        self.autoPasteIfEnabled()
      }

      await MainActor.run { [weak self] in
        self?.reviewPrompter.recordSuccessfulOperation()
      }

      let modelInfo = await spec.modelInfo()

      await MainActor.run {
        if spec.dismissesProcessingBeforeResult {
          PopupNotificationWindow.dismissProcessing()
        }
        // When auto-paste ran, the pill fade-out is enough. When text stayed on the clipboard
        // (App Store build, or auto-paste off / no Accessibility), always show an explicit
        // ⌘V cue — otherwise users conclude dictation "did nothing" (text is in the clipboard).
        if didAutoPaste {
          if !RecordingIndicatorManager.shared.isVisible {
            spec.presentResult(result, modelInfo, nil)
          }
        } else {
          spec.presentResult(result, modelInfo, "Copied — press ⌘V to paste")
        }
        if duringMeeting {
          self.activeMeetingSegment = nil
        } else {
          self.appState = self.appState.showSuccess(spec.successMessage(didAutoPaste))
        }
        if spec.clearsChunkState {
          self.chunkStatuses = []
          if self.currentTranscriptionAudioURL == audioURL {
            self.currentTranscriptionAudioURL = nil
          }
        }
        self.processedAudioURLs.remove(audioURL)
      }

      cleanupAudioFile(at: audioURL)
    } catch {
      if Self.isCancellation(error) {
        if duringMeeting {
          DebugLogger.log("CANCELLATION: \(spec.logLabel) task was cancelled (\(type(of: error)))")
          await MainActor.run {
            self.activeMeetingSegment = nil
            self.processedAudioURLs.remove(audioURL)
          }
          cleanupAudioFile(at: audioURL)
        } else if spec.cancelsViaTransitionToIdle {
          DebugLogger.log("CANCELLATION: \(spec.logLabel) task was cancelled (\(type(of: error)))")
          // Also dismisses the popup, clears chunk state, drops the URL and removes the file.
          await MainActor.run {
            self.transitionToIdleAndCleanup(cleanupAudioURL: audioURL, clearChunkStatuses: true)
          }
        } else {
          await cancelAudioJob(logLabel: spec.logLabel, error: error, audioURL: audioURL)
        }
        return
      }

      if spec.guardsStaleAudioURL {
        let isStale: Bool = await MainActor.run {
          if !duringMeeting, self.currentTranscriptionAudioURL != audioURL {
            DebugLogger.log(
              "CANCELLATION: Ignoring \(spec.logLabel.lowercased()) error for stale audio URL \(audioURL.lastPathComponent)")
            self.processedAudioURLs.remove(audioURL)
            self.cleanupAudioFile(at: audioURL)
            return true
          }
          return false
        }
        if isStale { return }
      }

      if duringMeeting {
        DebugLogger.logError("MEETING-SEGMENT: \(spec.logLabel) failed: \(error.localizedDescription)")
        await MainActor.run {
          self.activeMeetingSegment = nil
          self.processedAudioURLs.remove(audioURL)
          PopupNotificationWindow.showError(
            SpeechErrorFormatter.formatForUser(error), title: spec.errorTitle)
        }
        cleanupAudioFile(at: audioURL)
      } else {
        await handleProcessingError(error: error, audioURL: audioURL, mode: spec.mode)
        await MainActor.run {
          if spec.clearsChunkState {
            self.chunkStatuses = []
            if self.currentTranscriptionAudioURL == audioURL {
              self.currentTranscriptionAudioURL = nil
            }
          }
          self.processedAudioURLs.remove(audioURL)
        }
      }
    }
  }

  private func performTranscription(audioURL: URL, duringMeeting: Bool = false) async {
    // Capture the session but leave the property set: cancelInFlightTranscription must
    // still be able to cancel it while we await the chunk transcripts below. Cleared on
    // exit (identity-checked so a newer recording's session is never clobbered).
    let streamingSession: DictateStreamingSession? = await MainActor.run { self.dictateStreamingSession }
    defer {
      Task { @MainActor [weak self] in
        guard let self else { return }
        if self.dictateStreamingSession === streamingSession {
          self.dictateStreamingSession = nil
        }
      }
    }

    // Snapshot the recording into the audio-sample pool up front, while the source WAV still
    // exists. Capturing after transcription raced a rapid subsequent recording's beginSession()/
    // cleanup(), which deletes the delivered chunk/merged file — ~2% of captures failed with
    // "no such file". We keep the snapshot only if we log a successful transcription below;
    // otherwise the defer discards it, so cancelled/failed dictations leave no orphan sample.
    let transcriptionModelForCapture = TranscriptionModel.loadSelected()
    let backendTag: String
    if transcriptionModelForCapture.isOffline {
      backendTag = "whisper"
    } else if transcriptionModelForCapture.isOpenAI {
      backendTag = "openai"
    } else if transcriptionModelForCapture == .selfHostedTranscription {
      backendTag = "self-hosted"
    } else {
      backendTag = "gemini"
    }
    let pendingAudioRef: String? = duringMeeting ? nil : ContextLogger.shared.captureDictationAudio(
      from: audioURL,
      backend: backendTag,
      transcriptionModel: transcriptionModelForCapture.rawValue
    )
    var audioRefCommitted = false
    defer {
      if let ref = pendingAudioRef, !audioRefCommitted {
        ContextLogger.shared.deleteAudioSample(named: ref)
      }
    }
    let spec = AudioJobSpec(
      mode: .transcription,
      logLabel: "Transcription",
      errorTitle: "Transcription Error",
      modelInfo: { await self.speechService.getTranscriptionModelInfo() },
      copyResult: { self.clipboardManager.copyTranscriptionToClipboard(text: $0) },
      presentResult: { text, info, title in
        if let title {
          PopupNotificationWindow.showTranscriptionResponse(text, modelInfo: info, title: title)
        } else {
          PopupNotificationWindow.showTranscriptionResponse(text, modelInfo: info)
        }
      },
      successMessage: { $0 ? "Transcription copied to clipboard" : "Copied — press ⌘V to paste" },
      dismissesProcessingBeforeResult: true,
      clearsChunkState: true,
      guardsStaleAudioURL: true,
      cancelsViaTransitionToIdle: true)

    await runAudioJob(
      spec,
      audioURL: audioURL,
      duringMeeting: duringMeeting,
      produce: {
        let stopTime = CFAbsoluteTimeGetCurrent()
        if let streamed = try await streamingSession?.finalTranscript() {
          let waitMs = (CFAbsoluteTimeGetCurrent() - stopTime) * 1000
          DebugLogger.logSpeech(
            "SPEED: STREAMING-DICTATE: Transcript ready \(String(format: "%.0f", waitMs))ms after stop")
          return streamed
        }
        // Single-shot: non-Gemini model, no rotation happened, or a chunk failed —
        // transcribe the merged WAV exactly as before streaming existed.
        return try await self.speechService.transcribe(
          audioURL: audioURL, cancellable: !duringMeeting)
      },
      afterCopy: { result in
        let modelDisplayName = await self.speechService.getTranscriptionModelInfo()
        // Commit the up-front audio snapshot (captured before the transcription await); the defer
        // now keeps it instead of discarding it.
        audioRefCommitted = true
        ContextLogger.shared.logTranscription(
          result: result,
          model: modelDisplayName,
          audioRef: pendingAudioRef,
          transcriptionModel: transcriptionModelForCapture.rawValue
        )
      })
  }

  private func performPrompting(audioURL: URL, duringMeeting: Bool = false) async {
    let spec = AudioJobSpec(
      mode: .prompt,
      logLabel: "Prompt",
      errorTitle: "Prompt Error",
      modelInfo: { self.speechService.getPromptModelInfo() },
      copyResult: { self.clipboardManager.copyToClipboard(text: $0) },
      presentResult: { text, info, title in
        if let title {
          PopupNotificationWindow.showPromptResponse(text, modelInfo: info, title: title)
        } else {
          PopupNotificationWindow.showPromptResponse(text, modelInfo: info)
        }
      },
      successMessage: { $0 ? "AI response copied to clipboard" : "Copied — press ⌘V to paste" })

    await runAudioJob(
      spec,
      audioURL: audioURL,
      duringMeeting: duringMeeting,
      produce: {
        try await self.speechService.executePrompt(audioURL: audioURL, mode: .togglePrompting)
      })
  }

  /// Voice Feedback pipeline: transcribe the spoken instruction, ask the improvement model to
  /// turn it into a proposed change to one `system-prompts.md` section, present that in the
  /// Smart Improvement review modal, and apply it on Accept.
  private func performVoiceFeedback(audioURL: URL) async {
    do {
      let instruction = try await speechService.transcribe(audioURL: audioURL)
      let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
      DebugLogger.log("VOICE-FEEDBACK: Heard instruction: \(trimmed)")

      guard !trimmed.isEmpty else {
        cleanupAudioFile(at: audioURL)
        await MainActor.run {
          PopupNotificationWindow.showInfo("No speech detected.", title: "Voice Feedback")
          self.appState = self.appState.finish()
          self.processedAudioURLs.remove(audioURL)
        }
        return
      }

      let proposal = try await voiceFeedbackService.proposeChange(instruction: trimmed)

      // The instruction text is captured; the audio is no longer needed.
      cleanupAudioFile(at: audioURL)
      await MainActor.run { self.processedAudioURLs.remove(audioURL) }

      guard proposal.shouldChange else {
        DebugLogger.log("VOICE-FEEDBACK: Model returned no_change")
        await MainActor.run {
          PopupNotificationWindow.showInfo(
            "No context change suggested from that feedback.", title: "Voice Feedback")
          self.appState = self.appState.finish()
        }
        return
      }

      let section = proposal.section
      let current = SystemPromptsStore.shared.loadSection(section) ?? ""

      // Reviewing is user time, not processing — drop the pill before the modal opens.
      await MainActor.run { self.appState = self.appState.finish() }

      let edited = await SmartImprovementReviewPanel.present(
        focusDisplayName: Self.voiceFeedbackFocusName(for: section),
        originalText: current,
        suggestedText: proposal.suggestion,
        rationale: proposal.rationale.isEmpty ? nil : proposal.rationale)

      await MainActor.run {
        guard let edited = edited,
          !edited.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
          DebugLogger.log("VOICE-FEEDBACK: Review cancelled — no change applied")
          return
        }
        SystemPromptsStore.shared.updateSection(section, content: edited)
        ContextLogger.shared.appendSystemPromptsHistory(
          section: section, previousLength: current.count, newLength: edited.count,
          content: edited, model: nil, source: "voice-feedback")
        DebugLogger.log("VOICE-FEEDBACK-CHANGE: Applied change to section \(section.rawValue)")
        self.appState = self.appState.showSuccess("Context updated")
      }
    } catch {
      if Self.isCancellation(error) {
        await cancelAudioJob(logLabel: "Voice feedback", error: error, audioURL: audioURL)
        return
      }
      await handleProcessingError(error: error, audioURL: audioURL, mode: .voiceFeedback)
      await MainActor.run {
        self.processedAudioURLs.remove(audioURL)
      }
    }
  }

  /// Human-readable section name for the Voice Feedback review modal title.
  private static func voiceFeedbackFocusName(for section: SystemPromptSection) -> String {
    switch section {
    case .dictation: return "Dictation"
    case .whisperGlossary: return "Whisper Glossary"
    case .promptMode: return "Dictate Prompt"
    case .chat: return "Chat"
    case .readAloudRewrite: return "Read Aloud"
    }
  }

  /// True if the error represents a user-initiated cancellation — Swift's `CancellationError`,
  /// `URLError(.cancelled)`, or the bridged `NSURLErrorCancelled`. Cancellation is a normal
  /// operation and must never surface as an error popup with "Contact Support".
  private static func isCancellation(_ error: Error) -> Bool {
    if error is CancellationError { return true }
    if let urlError = error as? URLError, urlError.code == .cancelled { return true }
    let nsError = error as NSError
    if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return true }
    return false
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
        // Recreate menu with updated shortcuts; keep the delegate so review prompts still fire.
        let menu = self.createMenu()
        menu.delegate = self
        self.statusItem?.menu = menu
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
    let wasTTS = isTTSRunning
    appState = appState.finish()
    if wasTTS {
      NotificationCenter.default.post(name: .ttsDidStop, object: nil)
    }
  }

  /// Safely removes an audio file, logging any errors. Already-gone files are a normal
  /// outcome (cancel and completion paths can both try to clean the same recording).
  private func cleanupAudioFile(at url: URL?) {
    guard let url = url, FileManager.default.fileExists(atPath: url.path) else { return }
    do {
      try FileManager.default.removeItem(at: url)
      DebugLogger.logDebug("Cleaned up audio file: \(url.lastPathComponent)")
    } catch {
      DebugLogger.logWarning("Failed to clean up audio file \(url.lastPathComponent): \(error.localizedDescription)")
    }
  }
  
  /// Token for the in-flight TTS playback. Stale `scheduleBuffer` completions check
  /// this against their captured token and no-op when the user has started a new playback.
  private var currentPlaybackToken: UUID?

  /// Tracks the outer Read Aloud pipeline (rewrite + TTS + playback handoff). `speechService.cancelTTS()`
  /// only aborts the inner TTS network call; cancelling this handle also kills the rewrite stage and
  /// stops a not-yet-started TTS from racing past a user-initiated Stop.
  private var currentReadAloudTask: Task<Void, Never>?

  /// Tears down an active Read Aloud session and posts `ttsDidStop` so chat/menu UI reset.
  private func finishReadAloudSession(
    cancelNetworkWork: Bool = true,
    stopPlayback: Bool = true,
    transitionToIdle: Bool = true
  ) {
    // Capture BEFORE `transitionToIdleAndCleanup` flips `appState` to idle. It only posts
    // `ttsDidStop` when leaving a TTS-synthesizing state (`isTTSRunning == true`); for the
    // audio-playing path the prior state is `.speaking` and it won't post on its own.
    let transitionWillPostStop = transitionToIdle && isTTSRunning
    currentReadAloudTask?.cancel()
    if cancelNetworkWork {
      speechService.cancelTTS()
    }
    if stopPlayback {
      stopTTSPlayback()
    }
    if transitionToIdle {
      transitionToIdleAndCleanup()
    }
    // Post `ttsDidStop` exactly once. Skip when `transitionToIdleAndCleanup` already did
    // (the synthesizing path); post explicitly otherwise — audio-playing toggle-off, or
    // in-task catch paths that skip the transition entirely.
    if !transitionWillPostStop {
      NotificationCenter.default.post(name: .ttsDidStop, object: nil)
    }
  }

  /// Handles the "Read Aloud is already busy — treat this trigger as Stop" cases. Returns true
  /// when the trigger was consumed as a stop (caller should `return`), false when the caller
  /// should proceed to start a new Read Aloud.
  private func attemptReadAloudToggleOff() -> Bool {
    if isTTSRunning {
      finishReadAloudSession()
      return true
    }
    if audioEngine?.isRunning == true {
      finishReadAloudSession(cancelNetworkWork: false)
      return true
    }
    if case .processing = appState {
      DebugLogger.logWarning("READ-ALOUD: ignoring — another operation is processing")
      return true
    }
    return false
  }

  /// Drives the Read Aloud pipeline: sets app state, posts `ttsDidStart`, awaits the producer
  /// (which may include the Smart Rewrite step), then either hands off to `playTTSAudio` or
  /// surfaces a formatted error. The producer call runs inside `currentReadAloudTask` so a
  /// subsequent Stop trigger can cancel it mid-flight.
  private func beginReadAloudProcessing(producer: @escaping () async throws -> Data) {
    appState = .processing(.ttsProcessing)
    NotificationCenter.default.post(name: .ttsDidStart, object: nil)

    currentReadAloudTask = Task { [weak self] in
      do {
        let audioData = try await producer()
        // Must check on the read-aloud task, not inside MainActor.run (different task context).
        guard !Task.isCancelled else {
          DebugLogger.log("CANCELLATION: Read Aloud producer finished after cancel — skipping playback")
          // attemptReadAloudToggleOff already flipped state to idle when Stop fired, but a late
          // `mergingStarted` callback may have re-entered a `.processing` state on top of that —
          // without this, the menu bar would stay busy until the next user action, blocking
          // every other shortcut.
          await MainActor.run { [weak self] in
            guard let self, self.isTTSRunning else { return }
            self.finishReadAloudSession(cancelNetworkWork: false, stopPlayback: false)
          }
          return
        }
        await MainActor.run { [weak self] in
          guard let self else { return }
          PopupNotificationWindow.dismissProcessing()
          self.playTTSAudio(audioData: audioData)
        }
      } catch {
        if Self.isCancellation(error) {
          DebugLogger.log("CANCELLATION: Read Aloud task was cancelled (\(type(of: error)))")
          await MainActor.run { [weak self] in
            guard let self, self.isTTSRunning else { return }
            self.finishReadAloudSession(cancelNetworkWork: false, stopPlayback: false)
          }
          return
        }
        DebugLogger.logError("READ-ALOUD-ERROR: \(error.localizedDescription)")
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
        await MainActor.run { [weak self] in
          self?.finishReadAloudSession(cancelNetworkWork: false, stopPlayback: false, transitionToIdle: false)
          self?.presentError(shortTitle: shortTitle, message: userMessage, dismissProcessingFirst: true)
        }
      }
      // Intentionally don't nil-out `currentReadAloudTask` here: the next `beginReadAloudProcessing`
      // call overwrites it, and `cancel()` on an already-finished Task is a no-op. Nilling it out
      // through an awaited main-actor hop would race against a fresh Read Aloud trigger that may
      // have already replaced this slot during the suspension.
    }
  }

  private func readAloud(_ text: String) {
    if attemptReadAloudToggleOff() { return }
    let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedText.isEmpty else { return }
    // Chat-reply path: the text is LLM-generated prose intended for human reading, so skip the
    // Smart Rewrite Gemini call. The global-selection path keeps the default (true) because a
    // selection can be code/markdown/log-output.
    beginReadAloudProcessing { [speechService] in
      try await speechService.readProseAloud(trimmedText)
    }
  }

  private func playTTSAudio(audioData: Data) {
    DebugLogger.log("TTS-PLAYBACK: Starting audio playback (data size: \(audioData.count) bytes)")

    let sampleRate: Double = 24000
    let channels: UInt32 = 1
    let bitsPerChannel: UInt32 = 16

    do {
      // Gemini TTS returns raw Int16 PCM (s16le, 24kHz, mono), but AVAudioUnitTimePitch
      // (and other AVAudioUnit effects) require non-interleaved Float32 on their bus —
      // connecting with an Int16 format raises an Objective-C NSException inside
      // `engine.connect(...)` that does NOT bridge to Swift's try/catch, leaving the
      // function silently abandoned and `appState` stuck on `.processing`. Convert up-front
      // so the entire graph speaks Float32, whether or not the speed node is inserted.
      guard let audioFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: sampleRate,
        channels: channels,
        interleaved: false
      ) else {
        DebugLogger.logError("TTS-PLAYBACK: Failed to create audio format")
        throw TTSPlaybackError.failedToCreateAudioFormat
      }

      let bytesPerFrame = Int(channels * (bitsPerChannel / 8))
      let frameCount = audioData.count / bytesPerFrame

      guard let buffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: AVAudioFrameCount(frameCount)) else {
        DebugLogger.logError("TTS-PLAYBACK: Failed to create audio buffer")
        throw TTSPlaybackError.failedToCreateBuffer
      }

      buffer.frameLength = AVAudioFrameCount(frameCount)
      let int16ToFloat = 1.0 / Float(Int16.max)
      audioData.withUnsafeBytes { bytes in
        guard let baseAddress = bytes.baseAddress else { return }
        let int16Pointer = baseAddress.assumingMemoryBound(to: Int16.self)
        if let channelData = buffer.floatChannelData {
          for i in 0..<frameCount {
            channelData[0][i] = Float(int16Pointer[i]) * int16ToFloat
          }
        }
      }

      if let existingEngine = audioEngine {
        existingEngine.stop()
        audioEngine = nil
      }
      if let existingNode = audioPlayerNode {
        existingNode.stop()
        audioPlayerNode = nil
      }

      let engine = AVAudioEngine()
      let playerNode = AVAudioPlayerNode()
      engine.attach(playerNode)

      // Insert a time-pitch node when the user has picked a non-1× rate so the audio
      // plays faster/slower without changing pitch. `rate` is a multiplier where
      // 1.0 = normal (the API range is 1/32 ... 32, so our 0.75–2.0 picker is safe).
      let configuredSpeed = ReadAloudPreferences.speed.rawValue
      if configuredSpeed != 1.0 {
        let timePitch = AVAudioUnitTimePitch()
        timePitch.rate = Float(configuredSpeed)
        engine.attach(timePitch)
        engine.connect(playerNode, to: timePitch, format: buffer.format)
        engine.connect(timePitch, to: engine.mainMixerNode, format: buffer.format)
        timePitchNode = timePitch
      } else {
        engine.connect(playerNode, to: engine.mainMixerNode, format: buffer.format)
        timePitchNode = nil
      }

      self.audioEngine = engine
      self.audioPlayerNode = playerNode
      let token = UUID()
      currentPlaybackToken = token

      try engine.start()

      playerNode.scheduleBuffer(buffer) {
        DebugLogger.log("TTS-PLAYBACK: Playback completed")
        Task { @MainActor in
          // Discard stale completions from a buffer the user already stopped or replaced.
          guard self.currentPlaybackToken == token else { return }
          self.currentPlaybackToken = nil
          NotificationCenter.default.post(name: .ttsDidStop, object: nil)
          self.audioPlayerNode?.stop()
          self.audioEngine?.stop()
          self.audioEngine = nil
          self.audioPlayerNode = nil
          self.timePitchNode = nil
          // Only flip to completion feedback while still `.speaking` — the user may have
          // started a recording during playback, whose state must not be clobbered.
          // The feedback state auto-resets to idle via the `appState` didSet.
          if case .speaking = self.appState {
            self.appState = self.appState.showSuccess("Audio playback completed")
          }
        }
      }
      playerNode.play()
      DebugLogger.logSuccess("TTS-PLAYBACK: Playback started")
      appState = .speaking

    } catch {
      DebugLogger.logError("TTS-PLAYBACK: Failed to play audio: \(error.localizedDescription)")
      finishReadAloudSession(cancelNetworkWork: false, transitionToIdle: false)
      presentError(shortTitle: SpeechErrorFormatter.shortStatusForUser(error), message: SpeechErrorFormatter.formatForUser(error), dismissProcessingFirst: false)
    }
  }

  /// Stops all TTS audio playback and cleans up resources
  private func stopTTSPlayback() {
    currentPlaybackToken = nil
    audioPlayerNode?.stop()
    audioEngine?.stop()
    audioEngine = nil
    audioPlayerNode = nil
    timePitchNode = nil
  }
  
  /// Simulates Cmd+C to copy the current selection to the clipboard (virtual key 0x08 = 'C').
  /// Ensures the permission Dictate Prompt needs for the current selection-capture mode is granted,
  /// preparing the selection as a side effect. In screenshot-selection mode (App Store build) this
  /// gates on Screen Recording — the selection is read from a screenshot, so we abort before
  /// recording audio when it's missing. Otherwise it gates on Accessibility and copies the selection
  /// via ⌘C. Returns false (after showing guidance) when the required permission is missing.
  private func prepareDictatePromptSelection(logPrefix: String) -> Bool {
    if AppConstants.dictatePromptUsesScreenshotSelection {
      if PermissionStatusChecker.status(for: .screenRecording) != .granted {
        DebugLogger.logWarning("\(logPrefix): Screen Recording missing — Dictate Prompt needs it for the screenshot")
        Self.showScreenRecordingPermissionError()
        return false
      }
      return true
    }
    if !AccessibilityPermissionManager.checkPermissionForPromptUsage() { return false }
    simulateCopy()
    return true
  }

  private func simulateCopy() {
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

  /// Performs auto-paste if enabled in settings.
  /// - Returns: `true` when a paste keystroke was scheduled; `false` when the result stays on
  ///   the clipboard for the user to paste manually (App Store build, setting off, or missing
  ///   Accessibility permission).
  @discardableResult
  private func autoPasteIfEnabled() -> Bool {
    #if APP_STORE
    // Auto-paste synthesizes a ⌘V keystroke, which requires the Accessibility permission Apple
    // rejects under Guideline 2.4.5. The App Store build omits it; the result stays on the
    // clipboard for the user to paste manually.
    return false
    #else
    let autoPasteEnabled = UserDefaults.standard.object(forKey: UserDefaultsKeys.autoPasteAfterDictation) != nil
      ? UserDefaults.standard.bool(forKey: UserDefaultsKeys.autoPasteAfterDictation)
      : SettingsDefaults.autoPasteAfterDictation
    if autoPasteEnabled {
      guard AccessibilityPermissionManager.hasAccessibilityPermission() else {
        DebugLogger.logWarning("AUTO-PASTE: Skipped — accessibility permission not granted, showing permission dialog")
        AccessibilityPermissionManager.showAccessibilityPermissionDialog()
        return false
      }
      // Small delay to ensure clipboard is ready
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
        self?.simulatePaste()
        DebugLogger.log("AUTO-PASTE: Pasted transcription at cursor position")
      }
      return true
    }
    return false
    #endif
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

      // Cancelled via the recording indicator's ✕ — discard the audio, don't process
      if self.discardNextRecording {
        self.discardNextRecording = false
        DebugLogger.log("AUDIO: Discarding cancelled recording \(audioURL.lastPathComponent)")
        self.discardStreamingSession()
        self.cleanupAudioFile(at: audioURL)
        self.appState = self.appState.finish()
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
        // Recording has finished; leave "Recording…" before the modal would be misleading.
        self.appState = self.appState.stopRecording()
        let alert = NSAlert()
        alert.messageText = "Long recording"
        alert.informativeText = "This recording is \(timeStr) long. Process anyway? (API usage may incur costs.)"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Process")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        if response != .alertFirstButtonReturn {
          DebugLogger.log("RECORDING-SAFEGUARD: User cancelled processing for long recording (\(timeStr))")
          self.discardStreamingSession()
          self.cleanupAudioFile(at: audioURL)
          self.appState = self.appState.finish()
          return
        }
      }

      // Mark this URL as processed to prevent duplicate processing
      self.processedAudioURLs.insert(audioURL)

      if self.audioRecorder.lastRecordingWasSilent {
        // Only gate cloud-backed paths — offline Whisper has no API cost to protect against,
        // and gating silently has caused real recordings to be dropped on low-gain mics.
        let usesCloudAPI: Bool = {
          switch recordingMode {
          case .transcription: return !TranscriptionModel.loadSelected().isOffline
          case .prompt, .liveMeeting, .voiceFeedback: return true
          }
        }()

        if usesCloudAPI {
          DebugLogger.log("AUDIO: Skipping API call — recording was silent")
          self.discardStreamingSession()
          // Mirror the explicit-remove pattern used by every other early-return path; without
          // this line the URL stayed in `processedAudioURLs` forever for each silent recording.
          self.processedAudioURLs.remove(audioURL)
          self.cleanupAudioFile(at: audioURL)
          self.appState = self.appState.stopRecording()
          self.appState = self.appState.finish()
          PopupNotificationWindow.showInfo(
            "Your recording sounded silent. Check that the right microphone is selected and speak a bit louder.",
            title: "No speech detected",
            customDisplayDuration: Self.noSpeechInfoDuration
          )
          return
        } else {
          DebugLogger.logWarning("AUDIO: Recording flagged silent, but proceeding with offline transcription")
        }
      }

      if recordingMode == .transcription {
        self.currentTranscriptionAudioURL = audioURL
      }

      if !self.appState.isProcessing {
        self.appState = self.appState.stopRecording()
      }

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
        case .voiceFeedback:
          await self.performVoiceFeedback(audioURL: audioURL)
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
    discardNextRecording = false
    discardStreamingSession()
    if activeMeetingSegment != nil {
      DebugLogger.logWarning("MEETING-SEGMENT: Recording failed during meeting segment, clearing segment")
      activeMeetingSegment = nil
    }
    // Microphone permission denied/restricted: offer a direct jump to the Microphone
    // privacy pane instead of leaving the user with only "Contact Support".
    if errorDomain == "WhisperShortcut" && errorCode == 1001 {
      presentError(
        shortTitle: "Microphone Access Needed",
        message: "WhisperShortcut needs microphone access to record. Open System Settings ▸ Privacy & Security ▸ Microphone and enable WhisperShortcut.",
        dismissProcessingFirst: false,
        retryAction: { PermissionStatusChecker.openSystemSettings(for: .microphone) },
        retryActionTitle: "Open Settings"
      )
      return
    }
    presentError(shortTitle: "Recording Error", message: SpeechErrorFormatter.formatForUser(error), dismissProcessingFirst: false)
  }
}

// MARK: - ShortcutDelegate (Simple Forwarding)
extension MenuBarController: ShortcutDelegate {
  func toggleDictation() { toggleTranscription() }

  // Push-to-talk state queries: mirror what toggleTranscription/togglePrompting
  // treat as an active recording, including parallel segments during a live meeting.
  func isDictationRecordingActive() -> Bool {
    if isLiveMeetingActive { return activeMeetingSegment == .dictation }
    return appState.recordingMode == .transcription
  }

  func isPromptRecordingActive() -> Bool {
    if isLiveMeetingActive { return activeMeetingSegment == .prompt }
    return appState.recordingMode == .prompt
  }

  func isVoiceFeedbackRecordingActive() -> Bool {
    return appState.recordingMode == .voiceFeedback
  }

  // togglePrompting is already implemented above
  // openSettings is already implemented above
  func openChat() { openChatWindowFromShortcut() }

  @objc func takeScreenshot() {
    // Always capture to a temp PNG (not screencapture's own `-c`) so we get a definitive
    // success signal: a file means the capture worked, no file means it didn't. We then
    // copy the image to the clipboard ourselves and, when enabled, persist it to the
    // user-selected folder. Without this we can't tell a successful capture apart from a
    // silent failure — which is exactly what happens when Screen Recording permission is
    // missing: screencapture launches fine (no thrown error) but produces nothing.
    let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("whispershortcut-\(UUID().uuidString).png")
    let saveToFolder = ScreenshotSaveLocation.isEnabled
    DebugLogger.logUI("📷 SCREENSHOT: Launching interactive capture (save=\(saveToFolder))")
    DispatchQueue.global(qos: .userInitiated).async {
      let task = Process()
      task.launchPath = "/usr/sbin/screencapture"
      // -i interactive (drag rectangle / space-bar for window), -o no shadow on window grabs.
      task.arguments = ["-i", "-o", tempURL.path]
      do {
        try task.run()
        task.waitUntilExit()
      } catch {
        DebugLogger.logError("SCREENSHOT: Failed to launch screencapture: \(error)")
        return
      }

      guard FileManager.default.fileExists(atPath: tempURL.path),
        let data = try? Data(contentsOf: tempURL)
      else {
        // No file: either the user cancelled the selection, or Screen Recording permission
        // is missing (screencapture then produces nothing). PermissionStatusChecker lets us
        // tell the two apart so we only nag when permission is the real problem.
        DispatchQueue.main.async {
          if PermissionStatusChecker.status(for: .screenRecording) != .granted {
            DebugLogger.logWarning("SCREENSHOT: No capture file and no Screen Recording permission")
            Self.showScreenRecordingPermissionError()
          } else {
            DebugLogger.log("SCREENSHOT: No capture file (selection cancelled)")
          }
        }
        return
      }

      DispatchQueue.main.async {
        if let image = NSImage(data: data) {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.writeObjects([image])
        }
        if saveToFolder {
          ScreenshotSaveLocation.save(data)
        }
        try? FileManager.default.removeItem(at: tempURL)
      }
    }
  }

  /// Surfaces the missing Screen Recording permission to the user. The global screenshot
  /// shortcut otherwise fails silently. Triggers the native consent prompt the first time
  /// (which registers the app in System Settings and offers a direct "Open System Settings"
  /// button) and always shows a popup so there is visible feedback afterwards too.
  private static func showScreenRecordingPermissionError() {
    PermissionStatusChecker.requestScreenRecordingAccess()
    PopupNotificationWindow.showError(
      "WhisperShortcut needs Screen Recording permission to capture screenshots. Review it in Privacy & Permissions — then quit and reopen WhisperShortcut for the change to take effect.",
      title: "Screen Recording Permission Needed",
      retryAction: {
        SettingsManager.shared.showPrivacyPermissions()
      },
      retryActionTitle: "Review Permissions"
    )
  }

  // Selection-based Read Aloud (HotKey + menu item + everything it needs) copies via ⌘C, which
  // requires Accessibility. The App Store build omits the menu item, the hotkey wiring, and the
  // settings row — so these entry points have no caller there. Compile them out too rather than
  // keep an unreachable error-popup branch.
  #if !APP_STORE
  /// HotKey entry point: copies the user's selection, then runs Read Aloud on it. Pressing the
  /// shortcut again while a TTS phase is running cancels playback (mirrors the chat read-aloud
  /// stop semantics).
  func readAloud() { triggerReadSelectedTextAloud() }

  /// Menu-item entry point: AppKit requires `@objc` for menu selectors. Same behavior as the
  /// HotKey path.
  @objc func readAloudFromMenu() { triggerReadSelectedTextAloud() }

  private func triggerReadSelectedTextAloud() {
    if attemptReadAloudToggleOff() { return }
    if isLiveMeetingActive {
      DebugLogger.logWarning("READ-ALOUD-SHORTCUT: ignoring during live meeting")
      return
    }
    let readAloudModel = ReadAloudPreferences.model
    guard readAloudModel.hasRequiredCredential else {
      PopupNotificationWindow.showError(
        readAloudModel.apiKeyRequiredMessage,
        title: "API Key Required"
      )
      return
    }
    guard AccessibilityPermissionManager.checkPermissionForPromptUsage() else { return }

    // A blind delay isn't enough: some apps respond to Cmd+C slower than others, and a fixed
    // wait either reads the stale clipboard (too short) or stalls Read Aloud (too long). Poll
    // `NSPasteboard.changeCount` instead — as soon as the frontmost app finishes writing the
    // copy, we read; if no change lands within the deadline, the selection didn't get copied
    // (no focus, no selection, or no accessibility permission for the app being copied from).
    let beforeChangeCount = NSPasteboard.general.changeCount
    DebugLogger.log("READ-ALOUD: Posting synthetic Cmd+C; before changeCount = \(beforeChangeCount)")
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      self.simulateCopy()
      Task { @MainActor [weak self] in
        guard let self else { return }
        let start = Date()
        let deadline = start.addingTimeInterval(0.5)
        while Date() < deadline {
          try? await Task.sleep(for: .milliseconds(15))
          if NSPasteboard.general.changeCount != beforeChangeCount {
            let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)
            DebugLogger.log("READ-ALOUD: Pasteboard changed after \(elapsedMs) ms")
            // The user may have triggered another operation during the poll window; only
            // proceed if we're still idle.
            guard case .idle = self.appState else {
              DebugLogger.logWarning("READ-ALOUD: Poll completed but state is no longer idle — abandoning")
              return
            }
            self.performReadSelectedTextAloud()
            return
          }
        }
        DebugLogger.logWarning("READ-ALOUD: Pasteboard never changed — Cmd+C did not land on a selection")
        guard case .idle = self.appState else {
          DebugLogger.logWarning("READ-ALOUD: Poll timed out but state is no longer idle — skipping info popup")
          return
        }
        showNoTextSelectedForReadAloud()
      }
    }
  }

  /// Brief info popup shown when Read Aloud finds no selection. Not an error state (no
  /// "Contact Support" button) — pressing the shortcut without selecting text is normal.
  private func showNoTextSelectedForReadAloud() {
    PopupNotificationWindow.showInfo(
      "No text selected. Highlight text first, then press the Read Aloud shortcut.",
      title: "Read Aloud"
    )
  }

  private func performReadSelectedTextAloud() {
    // Re-check toggle-off: between the poll-window dispatch and now, the user may have
    // pressed the shortcut again, which would otherwise double-fire `beginReadAloudProcessing`
    // and orphan the first task.
    if attemptReadAloudToggleOff() { return }
    guard let selectedText = clipboardManager.getCleanedClipboardText(),
          !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      DebugLogger.logWarning("READ-ALOUD: Pasteboard changed but text is empty after cleaning")
      showNoTextSelectedForReadAloud()
      return
    }
    beginReadAloudProcessing { [speechService] in
      try await speechService.readSelectionAloud(selectedText)
    }
  }
  #endif
}

// MARK: - FnPushToTalkDelegate (Hold Fn to Dictate)
extension MenuBarController: FnPushToTalkDelegate {
  func fnPushToTalkStart() -> Bool {
    // fn-down must never cancel in-flight work or stop a recording the user started
    // otherwise — it only ever begins a fresh dictation.
    guard !isTranscriptionProcessing, !isDictationRecordingActive() else { return false }
    toggleTranscription()
    return isDictationRecordingActive()
  }

  func fnPushToTalkFinish() {
    guard isDictationRecordingActive() else { return }
    toggleTranscription()
  }

  func fnPushToTalkIsRecording() -> Bool {
    return isDictationRecordingActive()
  }

  // During a live meeting ⌘1 never cancels either — its meeting branch runs first — so fn
  // mirrors that and falls through to starting a dictation segment.
  func fnPushToTalkIsProcessing() -> Bool {
    return !isLiveMeetingActive && isTranscriptionProcessing
  }

  func fnPushToTalkCancelProcessing() {
    guard !isLiveMeetingActive, isTranscriptionProcessing else { return }
    DebugLogger.log("SHORTCUTS: Cancelling in-flight transcription via Fn")
    cancelInFlightTranscription()
  }

  func fnPushToTalkDiscard() {
    guard isDictationRecordingActive() else { return }
    // During a live meeting the discard flag would strand the active segment (the discard
    // branch in audioRecorderDidFinishRecording runs before segment cleanup), so let an
    // accidental tap flow through the normal pipeline — a ~0.3s clip transcribes to nothing.
    if isLiveMeetingActive {
      toggleTranscription()
      return
    }
    DebugLogger.log("AUDIO: Discarding Fn push-to-talk recording")
    discardNextRecording = true
    RecordingIndicatorManager.shared.hide()
    audioRecorder.stopRecording()
  }
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

  /// Chunk context (`tts` / `transcription`) of the in-flight processing state. Falls back to
  /// `.transcription` when not in `.processing` — only reached if a delegate callback lands
  /// after teardown, where the safe default keeps captions readable.
  private var currentChunkContext: AppState.ProcessingMode.ChunkContext {
    if case .processing(let mode) = appState { return mode.chunkContext }
    return .transcription
  }

  func chunkingStarted(totalChunks: Int) {
    // Initialize all chunks as pending
    chunkStatuses = Array(repeating: .pending, count: totalChunks)

    // Derive TTS vs transcription from current appState (we're still in .ttsProcessing or .transcribing)
    let context = currentChunkContext
    let isTTS = context == .tts

    appState = .processing(.splitting(context: context))
    updateMenuBarIcon()

    // The bottom-center pill already shows processing for pill-driven flows — chunk
    // popups on top would be redundant feedback (same rule as the success popup in
    // performTranscription). Popups remain for pill-less flows like TTS chunking.
    if !RecordingIndicatorManager.shared.isVisible {
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
    }

    DebugLogger.log("CHUNK-PROGRESS: Started chunking, \(totalChunks) total chunks (TTS: \(isTTS))")
  }

  func chunkStarted(index: Int) {
    guard index >= 0 && index < chunkStatuses.count else { return }

    // Mark chunk as active
    chunkStatuses[index] = .active

    let context = currentChunkContext
    appState = .processing(.processingChunks(statuses: chunkStatuses, context: context))
    updateMenuBarIcon()

    let isTTS = context == .tts

    // Update processing popup with status grid (pill-less flows only, see chunkingStarted)
    if !RecordingIndicatorManager.shared.isVisible {
      let statusGrid = generateStatusGrid()
      PopupNotificationWindow.updateProcessing(
        title: isTTS ? "Synthesizing Speech" : "Processing Audio",
        message: statusGrid
      )
    }

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

    let context = currentChunkContext
    appState = .processing(.processingChunks(statuses: chunkStatuses, context: context))
    updateMenuBarIcon()

    let isTTS = context == .tts

    // Update processing popup with status grid (pill-less flows only, see chunkingStarted)
    if !RecordingIndicatorManager.shared.isVisible {
      let statusGrid = generateStatusGrid()
      PopupNotificationWindow.updateProcessing(
        title: isTTS ? "Synthesizing Speech" : "Processing Audio",
        message: statusGrid
      )
    }

    DebugLogger.log("CHUNK-PROGRESS: Chunk \(index) completed (\(text.prefix(50))...)")
  }

  func chunkFailed(index: Int, error: Error, willRetry: Bool) {
    guard index >= 0 && index < chunkStatuses.count else { return }
    let context = currentChunkContext
    let isTTS = context == .tts

    if willRetry {
      // Keep as active (will be re-started via chunkStarted)
      DebugLogger.logWarning("CHUNK-PROGRESS: Chunk \(index) failed, retrying...")

      // Update popup to show retry status (pill-less flows only, see chunkingStarted)
      if !RecordingIndicatorManager.shared.isVisible {
        let statusGrid = generateStatusGrid()
        PopupNotificationWindow.updateProcessing(
          title: isTTS ? "Synthesizing Speech" : "Processing Audio",
          message: "\(statusGrid)\nRetrying chunk \(index + 1)..."
        )
      }
    } else {
      // Mark as permanently failed
      chunkStatuses[index] = .failed

      appState = .processing(.processingChunks(statuses: chunkStatuses, context: context))
      updateMenuBarIcon()

      // Update processing popup (pill-less flows only, see chunkingStarted)
      if !RecordingIndicatorManager.shared.isVisible {
        let statusGrid = generateStatusGrid()
        PopupNotificationWindow.updateProcessing(
          title: isTTS ? "Synthesizing Speech" : "Processing Audio",
          message: statusGrid
        )
      }

      DebugLogger.logError("CHUNK-PROGRESS: Chunk \(index) failed: \(error.localizedDescription)")
      // Log to file (replaces CrashLogger)
      DebugLogger.logError(error, context: "Chunk \(index) transcription failed", state: appState)
    }
  }

  func mergingStarted() {
    // Clear chunk statuses (no longer needed for display)
    chunkStatuses = []

    let context = currentChunkContext
    appState = .processing(.merging(context: context))
    updateMenuBarIcon()

    let isTTS = context == .tts

    // Update processing popup with appropriate message (pill-less flows only, see chunkingStarted)
    if !RecordingIndicatorManager.shared.isVisible {
      PopupNotificationWindow.updateProcessing(
        title: "Almost Done",
        message: isTTS ? "Merging audio chunks..." : "Merging transcription results..."
      )
    }

    DebugLogger.log("CHUNK-PROGRESS: Merging \(isTTS ? "audio chunks" : "transcripts")...")
  }
}

// MARK: - NSMenuDelegate
extension MenuBarController: NSMenuDelegate {
  /// Fires a previously-armed review/support prompt when the user opens the menu (i.e. is
  /// focused on this app rather than the one they were dictating into). No-ops when nothing
  /// is pending.
  func menuWillOpen(_ menu: NSMenu) {
    ReviewPrompter.shared.showPendingPromptIfNeeded()
  }
}
