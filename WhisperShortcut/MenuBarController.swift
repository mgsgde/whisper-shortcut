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

  // MARK: - Live Meeting State
  private var liveMeetingRecorder: LiveMeetingRecorder?
  private var liveMeetingStopping: Bool = false
  /// Latched true once `finishLiveMeetingSession` has run; used to drop late chunk deliveries
  /// from AVAudioRecorder that arrive after the post-processing Task started.
  private var liveMeetingFinalized: Bool = false
  /// Set to true on stop; cleared when the recorder delivers its final chunk. Gates
  /// `finishLiveMeetingSession` so post-processing can't start before the last audio arrives.
  private var liveMeetingAwaitingFinalChunk: Bool = false
  private var liveMeetingTranscriptURL: URL?
  private var liveMeetingPendingChunks: Int = 0
  private var liveMeetingSafeguardTimer: Timer?
  /// ID of the last chunk included in the rolling summary. Robust against chunk trimming.
  private var liveMeetingLastSummarizedChunkID: UUID? = nil
  /// When non-nil, finishLiveMeetingSession will rename the transcript file to this stem (or timestamp-suffix) before ending.
  private var liveMeetingPreferredName: String?
  /// Set to true after showing rate-limit popup once this session so we don't spam.
  private var liveMeetingDidShowRateLimitAlert: Bool = false
  /// Consecutive rolling-summary failures (e.g. sustained Gemini 503). Reset to 0 on any success.
  private var liveMeetingConsecutiveSummaryFailures: Int = 0
  /// True once the rolling-summary circuit-breaker has tripped: we stop scheduling further
  /// rolling updates for this session (the final summary is still attempted at end). Prevents
  /// hammering an unavailable model dozens of times during one meeting.
  private var liveMeetingSummaryCircuitOpen: Bool = false
  /// Set to true after showing the "summary unavailable" popup once this session so we don't spam.
  private var liveMeetingDidShowSummaryFailureAlert: Bool = false
  /// Consecutive rolling-summary failures before the circuit-breaker opens and we notify the user.
  private let liveMeetingSummaryFailureThreshold = 3
  /// Single-flight guard: true while a rolling-summary API call is in flight. A summary update can
  /// take 60–100s+ on a long meeting, but chunks arrive every ~45s — without this guard each
  /// threshold fired a fresh overlapping call, piling up concurrent requests that raced on
  /// `liveMeetingLastSummarizedChunkID`. When set, an on-demand refresh request is dropped: the
  /// in-flight call will already fold in every chunk accumulated so far.
  private var liveMeetingSummaryUpdateInFlight: Bool = false
  /// Bumped on every session start. A rolling-summary Task captures the generation it launched under
  /// so a straggler from a previous meeting (its API call can outlive a stop+restart) no-ops instead
  /// of clearing the in-flight flag — or writing summary/chunk state — for the newer session.
  private var liveMeetingSessionGeneration = 0
  /// When true, finishLiveMeetingSession will delete the transcript instead of saving.
  private var liveMeetingDiscard: Bool = false

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
        "Dictate Prompt", action: #selector(togglePrompting),
        shortcut: currentConfig.startPrompting, tag: 102))
    menu.addItem(
      createMenuItemWithShortcut(
        "Screenshot", action: #selector(takeScreenshot),
        shortcut: currentConfig.screenshotCapture, tag: 113))
    // Selection-based Read Aloud copies via ⌘C (Accessibility) — omitted from the App Store build.
    #if !APP_STORE
    menu.addItem(
      createMenuItemWithShortcut(
        "Read Aloud", action: #selector(readAloudFromMenu),
        shortcut: currentConfig.readAloud, tag: 114))
    #endif
    menu.addItem(NSMenuItem.separator())

    // Chat window
    menu.addItem(
      createMenuItemWithShortcut(
        "Chat", action: #selector(openChatWindow),
        shortcut: currentConfig.openChat, tag: 110))

    menu.addItem(NSMenuItem.separator())

    // Settings and quit.
    // Use a neutral selector and clear image explicitly to avoid AppKit
    // auto-decoration that can reserve an icon column for this row.
    let configureItem = createMenuItemWithShortcut(
      "Configure", action: #selector(openConfigurationPanel),
      shortcut: currentConfig.openSettings, tag: 103)
    configureItem.image = nil
    menu.addItem(configureItem)
    menu.addItem(
      createMenuItem("Rate WhisperShortcut", action: #selector(rateApp), tag: 115))
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
    case .recording(.transcription), .recording(.prompt):
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
      self?.liveMeetingPreferredName = name
      self?.liveMeetingDiscard = discard
      self?.stopLiveMeeting()
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

    // Update status
    menu.item(withTag: 100)?.title = appState.statusText

    // Show central Stop button only when something is active
    let isAnythingActive = appState.isBusy || isLiveMeetingActive
      || audioEngine?.isRunning == true
    menu.item(withTag: 111)?.isHidden = !isAnythingActive
    menu.item(withTag: 112)?.isHidden = !isAnythingActive

    // During a live meeting, all actions are available as parallel segments
    let meetingAllowsActions = isLiveMeetingActive && activeMeetingSegment == nil

    // Update action items based on current state
    updateMenuItem(
      menu, tag: 101,
      title: (appState.recordingMode == .transcription || activeMeetingSegment == .dictation)
        ? "Stop Dictate" : "Dictate",
      enabled: appState.canStartTranscription(hasAPIKey: canTranscribe, hasOfflineModel: false)
        || appState.recordingMode == .transcription
        || meetingAllowsActions && canTranscribe
        || activeMeetingSegment == .dictation)

    updateMenuItem(
      menu, tag: 102,
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
      menu, tag: 114,
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
          title: "API Key Required"
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
          title: "API Key Required"
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
    case .prompting, .ttsProcessing:
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
        title: "API Key Required"
      )
      return
    }

    // Check if busy with other operations
    guard !appState.isBusy else {
      DebugLogger.logWarning("LIVE-MEETING: Cannot start - app is busy")
      return
    }

    DebugLogger.log("LIVE-MEETING: Starting session (resuming=\(resuming))")

    // For a fresh meeting, clear any retained state from a previous (finished) meeting
    // so a new stem is generated and the chat sink doesn't reattach to the old session.
    if !resuming {
      LiveMeetingTranscriptStore.shared.clearForNewMeeting()
    }

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
    let chunkInterval: TimeInterval = savedInterval > 0 ? savedInterval : SettingsDefaults.liveMeetingChunkInterval.rawValue

    // Compute resume offset so new chunks continue from where the previous recording
    // left off, keeping transcript timestamps monotonic.
    let existingChunks = LiveMeetingTranscriptStore.shared.chunks
    let resumeOffset: TimeInterval
    if let last = existingChunks.last {
      // Buffer past the last chunk's start so labels don't collide.
      resumeOffset = last.startTime + max(1, chunkInterval)
    } else {
      resumeOffset = 0
    }

    // Create and start recorder
    liveMeetingRecorder = LiveMeetingRecorder(maxChunkDuration: chunkInterval)
    liveMeetingRecorder?.delegate = self
    liveMeetingRecorder?.startSession(resumeTimeOffset: resumeOffset)

    // Update state
    liveMeetingStopping = false
    liveMeetingFinalized = false
    liveMeetingAwaitingFinalChunk = false
    liveMeetingPendingChunks = 0
    liveMeetingDidShowRateLimitAlert = false
    liveMeetingConsecutiveSummaryFailures = 0
    liveMeetingSummaryCircuitOpen = false
    liveMeetingDidShowSummaryFailureAlert = false
    liveMeetingSummaryUpdateInFlight = false
    liveMeetingSessionGeneration += 1
    appState = .recording(.liveMeeting)
    if resuming && !existingChunks.isEmpty {
      LiveMeetingTranscriptStore.shared.resumeSession()
      // Preserve existing summarized state; if nil it falls back to "from start" which is safe.
    } else {
      LiveMeetingTranscriptStore.shared.startSession()
      liveMeetingLastSummarizedChunkID = nil
    }

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

    ChatWindowManager.shared.show(suppressFocusLossClose: true)

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
    // AVAudioRecorder delivers its final chunk async via audioRecorderDidFinishRecording,
    // so wait for it before finalizing (prevents a race where post-processing rewrites
    // the transcript file while a late chunk is still being appended).
    liveMeetingAwaitingFinalChunk = true
    liveMeetingRecorder?.stopSession()

    // Safety net: if the final chunk never arrives within 30s, finish anyway so the UI
    // doesn't get stuck in "stopping" forever.
    DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
      guard let self = self else { return }
      if self.liveMeetingStopping && !self.liveMeetingFinalized {
        DebugLogger.logWarning("LIVE-MEETING: Final chunk timeout; finishing session anyway")
        self.liveMeetingAwaitingFinalChunk = false
        self.liveMeetingPendingChunks = 0
        self.finishLiveMeetingSession()
      }
    }
  }

  private func finishLiveMeetingSession() {
    guard !liveMeetingFinalized else {
      DebugLogger.log("LIVE-MEETING: finishLiveMeetingSession ignored (already finalized)")
      return
    }
    liveMeetingFinalized = true

    let discard = liveMeetingDiscard
    DebugLogger.log("LIVE-MEETING: Session finished (discard=\(discard))")

    if discard {
      if let url = liveMeetingTranscriptURL {
        try? FileManager.default.removeItem(at: url)
        let summaryURL = url.deletingPathExtension().appendingPathExtension("summary.md")
        try? FileManager.default.removeItem(at: summaryURL)
        DebugLogger.log("LIVE-MEETING: Discarded transcript and summary files")
      }
      liveMeetingTranscriptURL = nil
      LiveMeetingTranscriptStore.shared.clearForNewMeeting()
      MeetingListService.shared.refresh()
    } else {
      if let url = liveMeetingTranscriptURL, let preferred = liveMeetingPreferredName, !preferred.isEmpty {
        let currentStem = url.deletingPathExtension().lastPathComponent
        if preferred != currentStem {
          renameTranscriptFile(from: url, preferredName: preferred, currentStem: currentStem)
        }
      }
      LiveMeetingTranscriptStore.shared.endSession()
    }

    // Capture URL for the post-processing Task before we clear it.
    let transcriptURLForPostProcessing: URL? = discard ? nil : liveMeetingTranscriptURL

    liveMeetingPreferredName = nil
    liveMeetingSafeguardTimer?.invalidate()
    liveMeetingSafeguardTimer = nil
    liveMeetingStopping = false
    liveMeetingAwaitingFinalChunk = false
    liveMeetingDiscard = false
    liveMeetingRecorder = nil
    liveMeetingPendingChunks = 0
    liveMeetingTranscriptURL = nil
    liveMeetingLastSummarizedChunkID = nil
    appState = appState.finish()

    if let transcriptURL = transcriptURLForPostProcessing {
      let chunksSnapshot = LiveMeetingTranscriptStore.shared.chunks
      Task {
        let transcriptText = chunksSnapshot.map { "\($0.timestampString) \($0.text)" }.joined(separator: "\n\n")
        guard !transcriptText.isEmpty else { return }
        let model = PromptModel.loadSelectedMeetingSummary()
        guard model.hasRequiredCredential else {
          DebugLogger.logWarning("LIVE-MEETING: No credential for \(model.rawValue) — skipping post-processing")
          return
        }

        // Post-processing: consolidate speaker labels across the full transcript. Skip it when the
        // transcript has at most one distinct speaker — there is nothing to reconcile, and the pass
        // echoes the whole transcript back as (paid) output. When it runs, route to the provider's
        // cheapest model: relabeling is mechanical and doesn't need the summary model's quality.
        var finalTranscript = transcriptText
        if MeetingListService.distinctSpeakerCount(in: transcriptText) >= 2 {
          do {
            let consolidated = try await MeetingListService.consolidateSpeakerLabels(
              transcript: transcriptText, model: model.speakerConsolidationModel)
            let trimmed = consolidated.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
              finalTranscript = trimmed
              if let data = trimmed.data(using: .utf8) {
                try data.write(to: transcriptURL, options: .atomic)
              }
              await MainActor.run {
                MeetingListService.shared.invalidateCache(for: nil)
              }
              DebugLogger.log("LIVE-MEETING: Speaker labels consolidated and transcript rewritten")
            }
          } catch {
            DebugLogger.logWarning("LIVE-MEETING: Speaker consolidation failed (using raw transcript): \(error.localizedDescription)")
          }
        } else {
          DebugLogger.log("LIVE-MEETING: Skipping speaker consolidation (<2 distinct speakers)")
        }

        // Generate summary from the (possibly consolidated) transcript
        var textForSummary = finalTranscript
        if textForSummary.count > MeetingListService.meetingContextMaxChars {
          textForSummary = String(textForSummary.suffix(MeetingListService.meetingContextMaxChars))
        }
        do {
          let summary = try await MeetingListService.generateSummaryText(transcript: textForSummary, model: model)
          let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
          if !trimmed.isEmpty {
            MeetingListService.shared.saveSummary(trimmed, transcriptFileURL: transcriptURL)
            DebugLogger.log("LIVE-MEETING: Summary saved to .summary.md")
            // Push the fresh summary to the chat sidebar so it can derive a meeting title live
            // (ChatView subscribes to .chatMeetingSummaryReady; without this it relies on the
            // slower backfill recovery path).
            let stem = transcriptURL.deletingPathExtension().lastPathComponent
            await MainActor.run {
              NotificationCenter.default.post(
                name: .chatMeetingSummaryReady, object: nil,
                userInfo: ["stem": stem, "summary": trimmed])
            }
          }
        } catch {
          DebugLogger.logError("LIVE-MEETING: Generate summary failed: \(error.localizedDescription)")
          // Don't lose the summary silently: the transcript is saved, so tell the user it can be
          // regenerated from the meeting library (the recovery path handles a transient outage).
          await MainActor.run {
            PopupNotificationWindow.showError(
              "The meeting transcript was saved, but the summary couldn't be generated (the summary model is unavailable). You can regenerate it from the meeting library when the service is back.",
              title: "Live Meeting – Summary Failed"
            )
          }
        }
      }
    }

    DebugLogger.logSuccess("LIVE-MEETING: Session cleanup complete")
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

    // If the store has no stem yet (e.g. first-ever meeting via global shortcut),
    // generate one and publish it so subsequent reads pick the SAME stem.
    let stem: String
    if let existing = LiveMeetingTranscriptStore.shared.currentMeetingFilenameStem {
      stem = existing
    } else {
      stem = LiveMeetingTranscriptStore.generateStem()
      LiveMeetingTranscriptStore.shared.currentMeetingFilenameStem = stem
    }
    let filename = "\(stem).txt"

    let fileURL = meetingsDir.appendingPathComponent(filename)

    // Only create (and thereby truncate) when no file exists yet. On resume the stem is
    // unchanged, so an unconditional createFile(contents: nil) would WIPE the existing
    // transcript; keeping the file lets appendToTranscript continue after the old content.
    if !FileManager.default.fileExists(atPath: fileURL.path) {
      FileManager.default.createFile(atPath: fileURL.path, contents: nil)
      DebugLogger.log("LIVE-MEETING: Created transcript file at \(fileURL.path)")
    } else {
      DebugLogger.log("LIVE-MEETING: Reusing existing transcript file at \(fileURL.path)")
    }
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

  /// On-demand rolling summary refresh. Called when a consumer actually needs an up-to-date live
  /// summary — the Summary tab is shown for the active meeting, or the user chats with it — rather
  /// than on a timer. This folds every transcript chunk accumulated since the last summary into one
  /// call, so cost is proportional to how often the user looks, not to meeting length. The
  /// end-of-meeting summary in finishLiveMeetingSession is regenerated from the full transcript and
  /// does not depend on this.
  @objc private func refreshLiveMeetingSummaryOnDemand() {
    DispatchQueue.main.async { [weak self] in self?.refreshRollingSummaryNow() }
  }

  private func refreshRollingSummaryNow() {
    // Only meaningful while a meeting is actively recording (the live store owns the current stem).
    guard case .recording(.liveMeeting) = appState else { return }

    // Circuit-breaker: after repeated failures (e.g. a sustained model outage) we stop firing
    // rolling updates for the rest of the session instead of retrying for an hour. The
    // end-of-meeting summary is still attempted once in finishLiveMeetingSession.
    guard !liveMeetingSummaryCircuitOpen else { return }

    // Single-flight: if a previous update is still running (they can take 60–100s+), don't launch a
    // second concurrent call. The in-flight call already folds in every chunk accumulated so far, and
    // the next on-demand request will pick up anything newer.
    guard !liveMeetingSummaryUpdateInFlight else {
      DebugLogger.log("LIVE-MEETING-SUMMARY: previous update still in flight — skipping on-demand refresh")
      return
    }

    let store = LiveMeetingTranscriptStore.shared
    let result = store.chunkTexts(afterID: liveMeetingLastSummarizedChunkID)
    guard !result.text.isEmpty, let newLastID = result.lastID else { return }

    let currentSummary = store.summary
    let newText = result.text
    let previousLastID = liveMeetingLastSummarizedChunkID
    liveMeetingLastSummarizedChunkID = newLastID
    liveMeetingSummaryUpdateInFlight = true
    let generation = liveMeetingSessionGeneration

    Task {
      await runRollingSummaryUpdate(
        currentSummary: currentSummary,
        newText: newText,
        previousLastID: previousLastID,
        generation: generation
      )
      await MainActor.run {
        // Ignore a straggler from a previous session — clearing the flag here would defeat the
        // single-flight guard for the meeting that's now running.
        guard generation == self.liveMeetingSessionGeneration else { return }
        self.liveMeetingSummaryUpdateInFlight = false
      }
    }
  }

  /// Merges new transcript into the rolling summary (via the selected model's provider) and updates the store. Call from a Task.
  private func runRollingSummaryUpdate(currentSummary: String, newText: String, previousLastID: UUID?, generation: Int) async {
    let model = PromptModel.loadSelectedMeetingSummary()
    guard model.hasRequiredCredential else {
      DebugLogger.logWarning("LIVE-MEETING-SUMMARY: No credential for \(model.rawValue) — skipping rolling summary update")
      return
    }
    do {
      let updated = try await MeetingListService.updateRollingSummary(
        currentSummary: currentSummary, newText: newText, model: model)
      await MainActor.run {
        // A straggler from a previous session must not write into the current meeting's state.
        guard generation == self.liveMeetingSessionGeneration else { return }
        let trimmed = updated.trimmingCharacters(in: .whitespacesAndNewlines)
        LiveMeetingTranscriptStore.shared.updateSummary(trimmed)
        if let url = self.liveMeetingTranscriptURL, !trimmed.isEmpty {
          MeetingListService.shared.saveSummary(trimmed, transcriptFileURL: url)
        }
        self.liveMeetingConsecutiveSummaryFailures = 0
        DebugLogger.log("LIVE-MEETING-SUMMARY: Rolling summary updated (\(updated.count) chars)")
      }
    } catch {
      DebugLogger.logError("LIVE-MEETING-SUMMARY: Update failed: \(error.localizedDescription)")
      await MainActor.run {
        guard generation == self.liveMeetingSessionGeneration else { return }
        // Roll back so the next attempt re-summarizes the same range.
        self.liveMeetingLastSummarizedChunkID = previousLastID
        self.liveMeetingConsecutiveSummaryFailures += 1
        // Trip the circuit-breaker after sustained failures: stop hammering the model for the
        // rest of the session and tell the user once (the final summary is still attempted at end).
        if self.liveMeetingConsecutiveSummaryFailures >= self.liveMeetingSummaryFailureThreshold
          && !self.liveMeetingSummaryCircuitOpen {
          self.liveMeetingSummaryCircuitOpen = true
          DebugLogger.logWarning(
            "LIVE-MEETING-SUMMARY: circuit-breaker tripped after \(self.liveMeetingConsecutiveSummaryFailures) consecutive failures — pausing live summary for this session")
          if !self.liveMeetingDidShowSummaryFailureAlert {
            self.liveMeetingDidShowSummaryFailureAlert = true
            PopupNotificationWindow.showError(
              "The live summary couldn't be updated (the summary model is unavailable). Recording continues normally; a summary will be generated when the meeting ends.",
              title: "Live Meeting – Summary Paused"
            )
          }
        }
      }
    }
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
    do {
      let result: String
      let stopTime = CFAbsoluteTimeGetCurrent()
      if let streamed = try await streamingSession?.finalTranscript() {
        result = streamed
        let waitMs = (CFAbsoluteTimeGetCurrent() - stopTime) * 1000
        DebugLogger.logSpeech(
          "SPEED: STREAMING-DICTATE: Transcript ready \(String(format: "%.0f", waitMs))ms after stop")
      } else {
        // Single-shot: non-Gemini model, no rotation happened, or a chunk failed —
        // transcribe the merged WAV exactly as before streaming existed.
        result = try await speechService.transcribe(audioURL: audioURL, cancellable: !duringMeeting)
      }

      // A shortcut press during processing cancels the job (cancelInFlightTranscription
      // clears currentTranscriptionAudioURL), but a transcript already in flight can still
      // arrive afterwards — drop it instead of pasting a cancelled result out of idle.
      // Same staleness check as the error path below.
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

      clipboardManager.copyTranscriptionToClipboard(text: result)

      let transcriptionModel = TranscriptionModel.loadSelected()
      let modelDisplayName = await speechService.getTranscriptionModelInfo()
      let backendTag: String
      if transcriptionModel.isOffline {
        backendTag = "whisper"
      } else if transcriptionModel.isOpenAI {
        backendTag = "openai"
      } else if transcriptionModel == .selfHostedTranscription {
        backendTag = "self-hosted"
      } else {
        backendTag = "gemini"
      }
      // Only persist audio for single-shot dictation, never for Live Meeting chunks.
      let audioRef: String? = duringMeeting ? nil : ContextLogger.shared.captureDictationAudio(
        from: audioURL,
        backend: backendTag,
        transcriptionModel: transcriptionModel.rawValue
      )
      ContextLogger.shared.logTranscription(
        result: result,
        model: modelDisplayName,
        audioRef: audioRef,
        transcriptionModel: transcriptionModel.rawValue
      )

      await MainActor.run {
        self.autoPasteIfEnabled()
      }

      await MainActor.run { [weak self] in
        self?.reviewPrompter.recordSuccessfulOperation()
      }

      let modelInfo = await self.speechService.getTranscriptionModelInfo()
      
      await MainActor.run {
        PopupNotificationWindow.dismissProcessing()
        // The recording indicator pill already flashes success for pill-driven flows —
        // a text popup on top of that would be redundant feedback.
        if !RecordingIndicatorManager.shared.isVisible {
          PopupNotificationWindow.showTranscriptionResponse(result, modelInfo: modelInfo)
        }
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
    } catch {
      if Self.isCancellation(error) {
        DebugLogger.log("CANCELLATION: Transcription task was cancelled (\(type(of: error)))")
        await MainActor.run {
          if duringMeeting {
            self.activeMeetingSegment = nil
            self.processedAudioURLs.remove(audioURL)
          } else {
            self.transitionToIdleAndCleanup(cleanupAudioURL: audioURL, clearChunkStatuses: true)
          }
        }
        if duringMeeting { cleanupAudioFile(at: audioURL) }
        return
      }
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

      await MainActor.run { [weak self] in
        self?.reviewPrompter.recordSuccessfulOperation()
      }

      await MainActor.run {
        let modelInfo = self.speechService.getPromptModelInfo()
        // Same redundancy rule as transcription: the pill's success flash suffices.
        if !RecordingIndicatorManager.shared.isVisible {
          PopupNotificationWindow.showPromptResponse(result, modelInfo: modelInfo)
        }
        if duringMeeting {
          self.activeMeetingSegment = nil
        } else {
          self.appState = self.appState.showSuccess("AI response copied to clipboard")
        }
        self.processedAudioURLs.remove(audioURL)
      }
      
      cleanupAudioFile(at: audioURL)
    } catch {
      if Self.isCancellation(error) {
        DebugLogger.log("CANCELLATION: Prompt task was cancelled (\(type(of: error)))")
        await MainActor.run {
          if duringMeeting {
            self.activeMeetingSegment = nil
          } else {
            self.appState = self.appState.finish()
          }
          self.processedAudioURLs.remove(audioURL)
        }
        cleanupAudioFile(at: audioURL)
        return
      }
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

  /// Performs auto-paste if enabled in settings
  private func autoPasteIfEnabled() {
    #if APP_STORE
    // Auto-paste synthesizes a ⌘V keystroke, which requires the Accessibility permission Apple
    // rejects under Guideline 2.4.5. The App Store build omits it; the result stays on the
    // clipboard for the user to paste manually.
    return
    #else
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
          case .prompt, .liveMeeting: return true
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

// MARK: - LiveMeetingRecorderDelegate
extension MenuBarController: LiveMeetingRecorderDelegate {
  func liveMeetingRecorder(didFinishChunk audioURL: URL, chunkIndex: Int, startTime: TimeInterval, isSilent: Bool, isFinal: Bool) {
    DebugLogger.log("LIVE-MEETING: Received chunk \(chunkIndex) at \(formatTimestamp(elapsedSeconds: startTime))\(isSilent ? " (silent)" : "")\(isFinal ? " (final)" : "")")

    // Drop late deliveries that arrive after the session was finalized.
    if liveMeetingFinalized {
      DebugLogger.logWarning("LIVE-MEETING: Dropping late chunk \(chunkIndex) (session already finalized)")
      cleanupAudioFile(at: audioURL)
      return
    }

    if isFinal {
      liveMeetingAwaitingFinalChunk = false
    }

    if isSilent {
      DebugLogger.log("LIVE-MEETING: Chunk \(chunkIndex) skipped (silent audio)")
      cleanupAudioFile(at: audioURL)
      maybeFinishAfterChunkCompletion()
      return
    }

    liveMeetingPendingChunks += 1

    Task {

      do {
        let text = try await speechService.transcribe(
          audioURL: audioURL,
          preferredModel: TranscriptionModel.loadSelectedForMeeting(),
          promptOverride: AppConstants.liveMeetingDiarizationPrompt,
          cancellable: false
        )

        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmedText.isEmpty {
          DebugLogger.log("LIVE-MEETING: Chunk \(chunkIndex) skipped (silent)")
        } else {
          await MainActor.run {
            self.appendToTranscript(trimmedText, chunkStartTime: startTime)
            // No rolling-summary call here: the live summary is refreshed on demand (Summary tab
            // shown / live meeting chatted), so we don't pay for updates nobody looks at.
          }
        }

        cleanupAudioFile(at: audioURL)

      } catch TranscriptionError.noSpeechDetected {
        DebugLogger.log("LIVE-MEETING: Chunk \(chunkIndex) skipped (no speech detected)")
        cleanupAudioFile(at: audioURL)
      } catch {
        DebugLogger.logError("LIVE-MEETING: Chunk \(chunkIndex) transcription failed: \(error)")
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
        self.maybeFinishAfterChunkCompletion()
      }
    }
  }

  /// Called whenever a chunk's pending work completes. Finalizes the session once
  /// the user has requested stop, all pending chunks have completed, and the
  /// recorder has delivered its final chunk (tracked via `liveMeetingAwaitingFinalChunk`).
  private func maybeFinishAfterChunkCompletion() {
    guard liveMeetingStopping else { return }
    guard liveMeetingPendingChunks == 0 else { return }
    guard !liveMeetingAwaitingFinalChunk else { return }
    finishLiveMeetingSession()
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

      // Microphone permission denied/restricted: offer a direct jump to the Microphone
      // privacy pane instead of leaving the user with only "Contact Support".
      let nsError = error as NSError
      if nsError.domain == "LiveMeetingRecorder" && nsError.code == 2001 {
        PopupNotificationWindow.showError(
          "WhisperShortcut needs microphone access to record. Open System Settings ▸ Privacy & Security ▸ Microphone and enable WhisperShortcut.",
          title: "Microphone Access Needed",
          retryAction: { PermissionStatusChecker.openSystemSettings(for: .microphone) },
          retryActionTitle: "Open Settings"
        )
        return
      }

      // Show error but don't stop the session
      PopupNotificationWindow.showError(SpeechErrorFormatter.formatForUser(error), title: "Live Meeting")
    }
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
