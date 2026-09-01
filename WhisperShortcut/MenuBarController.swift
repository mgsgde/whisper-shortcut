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
    case copyLastTranscription = 117
    case recentTranscriptions = 118
    case sendFeedback = 119
    case transcribeCancelledRecording = 120
    case addToGlossary = 121
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
  /// Text the user had selected when Voice Feedback started, if any. Optional context: a spoken
  /// "the spelling of X is X" is transcribed identically on both sides and teaches nothing, so
  /// the selection is where a correct spelling can actually come from. Cleared after each run.
  private var voiceFeedbackSelection: String?
  private let shortcuts: Shortcuts
  private let fnDictationToggle = FnDictationToggle()
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
  /// Audio URL of the Dictate or Dictate Prompt job currently being processed, outside a live
  /// meeting. Cancelling clears it, which is how a late-arriving result is recognised as belonging
  /// to a superseded recording and dropped instead of being pasted out of idle.
  private var currentJobAudioURL: URL?
  private var processedAudioURLs: Set<URL> = []

  /// Owns Read Aloud playback: the audio graph, the chunk queue, and when an utterance is done.
  /// `appState` and `ttsDidStop` stay here — the session reports its lifecycle through these
  /// callbacks rather than mutating the app's source of truth (same contract as `LiveMeetingSession`).
  private lazy var ttsPlayback = TTSPlaybackSession(
    onPlaybackStarted: { [weak self] in
      guard let self else { return }
      PopupNotificationWindow.dismissProcessing()
      self.appState = .speaking
    },
    onPlaybackCompleted: { [weak self] in
      guard let self else { return }
      NotificationCenter.default.post(name: .ttsDidStop, object: nil)
      // Only flip to completion feedback while still `.speaking` — the user may have started a
      // recording during playback, whose state must not be clobbered. The feedback state
      // auto-resets to idle via the `appState` didSet.
      if case .speaking = self.appState {
        self.appState = self.appState.showSuccess("Audio playback completed")
      }
    },
    onFailure: { [weak self] error in
      guard let self else { return }
      self.finishReadAloudSession(cancelNetworkWork: false, transitionToIdle: false)
      self.presentError(
        shortTitle: SpeechErrorFormatter.shortStatusForUser(error),
        message: SpeechErrorFormatter.formatForUser(error), dismissProcessingFirst: false)
    })

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
        cancellable: false,
        // A meeting chunk is background bookkeeping, so it must not drive the foreground chunk
        // pipeline — the same rule streaming dictate chunks already follow. It was doing both
        // visible halves of that: raising a "Processing Audio" → "Merging transcription
        // results…" popup pair on every chunk rotation (every 12–60 s, ~40 times in a
        // 25-minute meeting), and clobbering `appState` with `.processing(.splitting)` on top
        // of the recording state each time.
        reportsProgress: false
      )
    },
    cleanUpAudioFile: { [weak self] url in self?.cleanupAudioFile(at: url) },
    appStateIsRecordingMeeting: { [weak self] in self?.appState.recordingMode == .liveMeeting },
    onStopping: { [weak self] in
      guard let self else { return }
      self.meetingIsFinishing = true
      self.updateUI()
    },
    onFinished: { [weak self] in
      guard let self else { return }
      self.meetingIsFinishing = false
      self.appState = self.appState.finish()
    })

  /// True when live meeting is active (recording or stopping with pending chunks).
  private var isLiveMeetingActive: Bool {
    appState.recordingMode == .liveMeeting || liveMeeting.isRecording
  }

  /// True between the stop request and the session actually finishing: the recorder has stopped but
  /// the last chunk is still being transcribed. `appState` is still `.recording(.liveMeeting)` in that
  /// window (the session owns when the meeting is over), so this is what keeps the menu bar honest.
  private var meetingIsFinishing = false

  // MARK: - Meeting Segment (parallel action during live meeting)
  private enum MeetingSegment {
    case dictation
    case prompt
  }
  /// When non-nil, an action is running in parallel with the live meeting.
  private var activeMeetingSegment: MeetingSegment?
  /// True once the active segment has stopped recording and its result is being produced. A segment
  /// deliberately leaves `appState` alone (the meeting owns it), so its phase is tracked here — it is
  /// what lets the menu bar show 🔴 while you speak and ⏳ while the text is on its way.
  private var meetingSegmentIsProcessing = false

  /// Starts a segment's lifecycle and repaints, so the icon and the pill show the dictation rather
  /// than the meeting underneath it. Repainting is explicit here because a segment never touches
  /// `appState`, and `appState`'s `didSet` is what normally drives the UI.
  private func beginMeetingSegment(_ segment: MeetingSegment) {
    activeMeetingSegment = segment
    meetingSegmentIsProcessing = false
    updateUI()
    updateRecordingIndicator()
  }

  /// Marks the segment as past its recording phase: the pill becomes a spinner, the icon becomes ⏳.
  private func markMeetingSegmentProcessing() {
    guard activeMeetingSegment != nil else { return }
    meetingSegmentIsProcessing = true
    updateUI()
    updateRecordingIndicator()
  }

  /// Ends the segment's lifecycle and repaints. Every exit path (delivered, cancelled, failed) has to
  /// clear both flags and refresh the UI; going through one method is what keeps them in step.
  private func clearMeetingSegment() {
    activeMeetingSegment = nil
    meetingSegmentIsProcessing = false
    updateUI()
    updateRecordingIndicator()
  }

  /// What the menu bar and the floating pill show. Normally `appState`, with two exceptions — both
  /// because a live meeting holds `appState` for its entire duration, which used to make everything
  /// happening *inside* the meeting invisible:
  ///
  /// - a Dictate / Dictate Prompt segment: you could be dictating with the icon still showing 📝 and
  ///   no pill at all, so nothing on screen said which of the two recordings the next Stop would end;
  /// - the stop drain: `appState` stays `.recording(.liveMeeting)` until the last chunk is
  ///   transcribed, so the menu bar claimed "recording" for seconds after the meeting was stopped.
  private var presentedState: AppState {
    if let segment = activeMeetingSegment {
      switch (segment, meetingSegmentIsProcessing) {
      case (.dictation, false): return .recording(.transcription)
      case (.dictation, true): return .processing(.transcribing)
      case (.prompt, false): return .recording(.prompt)
      case (.prompt, true): return .processing(.prompting)
      }
    }
    if meetingIsFinishing { return .processing(.transcribing) }
    return appState
  }

  /// Menu status row and tooltip. Spells out that the meeting keeps running underneath a segment —
  /// the icon alone would read as "the meeting stopped and I am dictating instead".
  private var presentedStatusText: String {
    if let segment = activeMeetingSegment {
      let what = segment == .dictation ? "Dictating" : "Recording AI prompt"
      return meetingSegmentIsProcessing
        ? "⏳ Processing — meeting still recording"
        : "\(presentedState.icon) \(what) — meeting still recording"
    }
    if meetingIsFinishing { return "⏳ Finishing meeting — saving the last seconds…" }
    return appState.statusText
  }

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
    // Selection-based like Read Aloud: copies via ⌘C, so it needs Accessibility and is absent
    // from the App Store build.
    #if !APP_STORE
    menu.addItem(
      createMenuItemWithShortcut(
        "Add Selection to Glossary", action: #selector(addSelectionToGlossary),
        shortcut: currentConfig.addToGlossary, tag: .addToGlossary))
    #endif
    menu.addItem(NSMenuItem.separator())

    // Recovering a dictation result. Both rows hide themselves while the history is empty, so a
    // fresh install doesn't show two dead entries.
    menu.addItem(
      createMenuItem(
        "Copy Last Transcription", action: #selector(copyLastTranscription),
        tag: .copyLastTranscription))
    let recentItem = createMenuItem(
      "Recent Transcriptions", action: nil, tag: .recentTranscriptions)
    recentItem.submenu = NSMenu()
    menu.addItem(recentItem)
    // Only present after a cancellation, so it reads as an undo for the action just taken
    // rather than a permanent row nobody has a use for.
    menu.addItem(
      createMenuItem(
        "Transcribe Cancelled Recording", action: #selector(transcribeCancelledRecording),
        tag: .transcribeCancelledRecording))

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

    // Feedback sits next to Settings, the macOS convention for it, and offers all three channels
    // rather than WhatsApp alone — a user without WhatsApp otherwise has no obvious way to reach
    // the developer at all. A submenu keeps this to one row: the status menu is the app's
    // most-used surface, and three permanent contact rows in it would read as nagging.
    let feedbackItem = createMenuItem("Send Feedback", action: nil, tag: .sendFeedback)
    let feedbackMenu = NSMenu()
    for channel in FeedbackLinks.Channel.allCases {
      let item = NSMenuItem(
        title: channel.menuTitle, action: #selector(sendFeedback(_:)), keyEquivalent: "")
      item.target = self
      item.representedObject = channel.rawValue
      item.toolTip = channel.helpText
      feedbackMenu.addItem(item)
    }
    feedbackItem.submenu = feedbackMenu
    menu.addItem(feedbackItem)

    menu.addItem(
      createMenuItem("Rate WhisperShortcut", action: #selector(rateApp), tag: .rate))
    menu.addItem(
      createMenuItem("Quit WhisperShortcut", action: #selector(quitApp), keyEquivalent: "q"))

    return menu
  }

  /// `action` is optional so submenu parents (which do nothing when clicked) share this path.
  private func createMenuItem(
    _ title: String, action: Selector?, keyEquivalent: String = "", tag: MenuTag? = nil
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
    fnDictationToggle.delegate = self
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

  /// Keeps the floating bottom-center pill in sync with `presentedState`. It shows the
  /// recording pill for Dictate / Dictate Prompt, and the compact processing spinner
  /// for both those flows (handed off from recording) and Read Aloud / TTS synthesis
  /// (summoned directly, since TTS has no recording phase). Once TTS hands off to
  /// playback the state is `.speaking`, so the pill hides — the audio itself is the
  /// feedback. On success (and every other state) it hides immediately — lingering UI
  /// would cover the user's work.
  ///
  /// The meeting itself stays pill-less: it runs for an hour, and a permanent pill over the user's
  /// work is not feedback but furniture. A Dictate / Dictate Prompt segment *inside* a meeting does
  /// show it, via `presentedState` — it is as short-lived as any other dictation, and it was the one
  /// recording in the app with no on-screen trace at all.
  private func updateRecordingIndicator() {
    let indicator = RecordingIndicatorManager.shared
    // A segment's transcription is deliberately non-cancellable (cancelling would reach into the
    // meeting's own chunk pipeline), and the processing pill's single control is "Cancel processing".
    // So the pill leaves with the recording phase rather than staying on screen as a dead button;
    // the menu bar reports the remaining wait.
    if activeMeetingSegment != nil, meetingSegmentIsProcessing {
      indicator.hide()
      return
    }
    switch presentedState {
    case .recording(.transcription), .recording(.prompt), .recording(.voiceFeedback):
      indicator.showRecording()
    case .processing(let mode):
      // TTS has no recording phase, so summon the processing pill directly;
      // Dictate / Dictate Prompt already have it on screen from recording.
      // The meeting's stop drain is not summoned either — the menu bar and the meeting bar
      // report it, and a pill for it would appear over whatever the user turned to next.
      let summon = mode.isTTSContext
      indicator.showProcessing(summonIfNeeded: summon)
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
      cancelInFlightPrompt()
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
      selector: #selector(refreshLiveMeetingNotesOnDemand),
      name: .liveMeetingNotesRefreshRequested,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(markMeetingMomentFromNotification),
      name: .liveMeetingMarkerRequested,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(chatWindowVisibilityChanged(_:)),
      name: .chatWindowVisibilityChanged,
      object: nil
    )

    // Installed rather than posted as a notification because the caller has to *await* it: the meeting
    // chat cuts the pending audio chunk and waits for its transcript before sending a question about
    // the last few seconds. No-ops when no meeting is recording.
    LiveMeetingTranscriptStore.shared.pendingAudioFlush = { [weak self] in
      await self?.liveMeeting.flushPendingAudio()
    }
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

    // Warm the selected offline model in the background so the first dictation does not wait for
    // the load. Deliberately does NOT download: deleting a model in Settings while it stays
    // selected is a legitimate way to reclaim gigabytes, and re-fetching it on the next launch
    // would make that impossible — the delete would silently undo itself.
    if selectedModel.isOffline, let offlineModelType = selectedModel.offlineModelType {
      prepareOfflineModelInBackground(offlineModelType, reason: "launch", downloadIfMissing: false)
    }

    // Setup shortcuts
    shortcuts.setup()
    fnDictationToggle.setup()
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
    if case .processing(.processingChunks(let statuses, _)) = presentedState {
      let active = statuses.filter { $0 == .active }.count
      let done = statuses.filter { $0 == .completed }.count
      button.toolTip = "Transcribing [\(done)/\(statuses.count)] - \(active) active"
    } else if activeMeetingSegment != nil || meetingIsFinishing {
      button.toolTip = presentedStatusText
    } else {
      button.toolTip = appState.tooltip
    }
  }

  /// Renders `presentedState` on the status item button: an SF Symbol template image
  /// when its `symbolName` is set (idle), otherwise the colored emoji from `icon`.
  private func applyCurrentAppearance(to button: NSStatusBarButton) {
    let state = presentedState
    if let symbolName = state.symbolName {
      // mic.fill's stand made it clip against the menu bar bezel intermittently at 15pt.
      // 14pt + scaleProportionallyDown lets AppKit fit any intrinsic image size into the bar.
      let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
      let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: state.tooltip)?
        .withSymbolConfiguration(config)
      image?.isTemplate = true
      button.image = image
      button.imageScaling = .scaleProportionallyDown
      button.title = ""
    } else {
      button.image = nil
      button.title = state.icon
    }
  }

  private func updateMenuItems() {
    guard let menu = statusItem?.menu else { return }

    let selectedTranscriptionModel = TranscriptionModel.loadSelected()
    let canTranscribe = selectedTranscriptionModel.hasRequiredCredential
    let canPrompt = PromptModel.loadPromptModel(
      forKey: UserDefaultsKeys.selectedPromptModel,
      default: SettingsDefaults.selectedPromptModel).hasRequiredCredential
    #if !APP_STORE
    let canReadAloud = ReadAloudPreferences.model.hasRequiredCredential
    #endif
    let hasAnyKey = ProviderCredentials.anyChatCredentialConfigured

    // Update status
    menu.item(withTag: MenuTag.status.rawValue)?.title = presentedStatusText

    // Show central Stop button only when something is active
    let isAnythingActive = appState.isBusy || isLiveMeetingActive
      || ttsPlayback.isPlaying
    // When the matching action already reads "Stop Dictate" / "Stop Read Aloud", a second
    // generic Stop row is the same action twice. Keep the generic Stop for processing
    // (the action item has flipped back to start) and for a live meeting with no nested
    // recording, where no action item covers "end this".
    let actionAlreadyStops =
      appState.recordingMode == .transcription
      || appState.recordingMode == .prompt
      || activeMeetingSegment == .dictation
      || activeMeetingSegment == .prompt
      || isTTSRunning || ttsPlayback.isPlaying
    let showCentralStop = isAnythingActive && !actionAlreadyStops
    menu.item(withTag: MenuTag.stop.rawValue)?.isHidden = !showCentralStop
    menu.item(withTag: MenuTag.stopSeparator.rawValue)?.isHidden = !showCentralStop

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
    let isReadAloudActive = isTTSRunning || ttsPlayback.isPlaying
    updateMenuItem(
      menu, tag: .readAloud,
      title: isReadAloudActive ? "Stop Read Aloud" : "Read Aloud",
      enabled: canReadAloud && (!appState.isBusy || isReadAloudActive)
    )
    #endif

    updateTranscriptionHistoryItems(menu)

    // Handle special case when no API key (any provider) and no usable transcription is configured.
    // Tested against `canTranscribe`, not just the offline model: a user whose only setup is
    // OpenRouter or a self-hosted endpoint can dictate perfectly well, and used to be told to
    // "add an API key" anyway.
    if !hasAnyKey && !canTranscribe, let button = statusItem?.button {
      button.image = nil
      button.title = "⚠️"
      button.toolTip = "Add an API key or use an offline model - click to configure"
    }
  }

  /// Rebuilds the "Recent Transcriptions" submenu and hides both history rows while there is
  /// nothing to show. Rebuilt on every menu update rather than on record: the store is written
  /// from a background queue, and the menu is cheap to regenerate (at most five rows).
  private func updateTranscriptionHistoryItems(_ menu: NSMenu) {
    let entries = TranscriptionHistoryStore.shared.entries
    menu.item(withTag: MenuTag.copyLastTranscription.rawValue)?.isHidden = entries.isEmpty

    // Drops away once the retained file is gone (recovered, or replaced by a newer cancellation).
    let hasCancelled = cancelledRecordingURL.map {
      FileManager.default.fileExists(atPath: $0.path)
    } ?? false
    menu.item(withTag: MenuTag.transcribeCancelledRecording.rawValue)?.isHidden = !hasCancelled

    guard let recentItem = menu.item(withTag: MenuTag.recentTranscriptions.rawValue) else { return }
    // A single entry is already covered by "Copy Last Transcription" — a submenu with one row
    // duplicating the row above it is noise.
    recentItem.isHidden = entries.count < 2
    guard !recentItem.isHidden else { return }

    let submenu = recentItem.submenu ?? NSMenu()
    submenu.removeAllItems()
    for (index, entry) in entries.enumerated() {
      let item = NSMenuItem(
        title: TranscriptionHistoryStore.menuTitle(for: entry),
        action: #selector(copyTranscriptionFromHistory(_:)), keyEquivalent: "")
      item.target = self
      // The index into the newest-first list, resolved on click against the store's current
      // contents — see `copyTranscriptionFromHistory`.
      item.tag = index
      item.toolTip = Self.historyTooltipFormatter.string(from: entry.ts)
      submenu.addItem(item)
    }
    recentItem.submenu = submenu
  }

  private static let historyTooltipFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .short
    formatter.timeStyle = .medium
    return formatter
  }()

  @objc private func copyLastTranscription() {
    guard let entry = TranscriptionHistoryStore.shared.mostRecent else {
      DebugLogger.logWarning("TRANSCRIPTION-HISTORY: Copy requested but history is empty")
      return
    }
    copyHistoryEntry(entry)
  }

  @objc private func copyTranscriptionFromHistory(_ sender: NSMenuItem) {
    // Resolve against the live list instead of capturing the text in the menu item: a dictation
    // that finished while the menu was open would otherwise copy a shifted entry.
    let entries = TranscriptionHistoryStore.shared.entries
    guard sender.tag >= 0, sender.tag < entries.count else {
      DebugLogger.logWarning("TRANSCRIPTION-HISTORY: Entry \(sender.tag) no longer exists")
      return
    }
    copyHistoryEntry(entries[sender.tag])
  }

  private func copyHistoryEntry(_ entry: TranscriptionHistoryStore.Entry) {
    clipboardManager.copyToClipboard(text: entry.text)
    DebugLogger.log("TRANSCRIPTION-HISTORY: Re-copied \(entry.text.count) chars from \(entry.ts)")
    // No auto-paste here on purpose. This action exists precisely because a paste went somewhere
    // unintended; putting it on the clipboard and letting the user place it is the whole point.
    // Only surface the pill from idle — a recording or playback in progress owns the menu bar and
    // must not be overwritten by a confirmation.
    if case .idle = appState {
      appState = appState.showSuccess("Transcription copied — press ⌘V to paste")
    }
  }

  private func updateMenuItem(_ menu: NSMenu, tag: MenuTag, title: String, enabled: Bool) {
    guard let item = menu.item(withTag: tag.rawValue) else { return }
    item.title = title
    item.isEnabled = enabled
  }

  private func updateBlinking() {
    if presentedState.shouldBlink {
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
        beginMeetingSegment(.dictation)
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
        // A dictation started seconds after an unpasted one is the user telling us the last
        // transcript was wrong. Recorded here, at the press, because the restart *is* the verdict.
        // Live-meeting dictation segments deliberately skip this: speaking repeatedly into a
        // meeting is normal use, not a retry, and would drown the signal.
        ContextLogger.shared.noteDictationStart(autoPasteAvailable: Self.autoPasteAvailable)
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
        beginMeetingSegment(.prompt)
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
      cancelInFlightPrompt()
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
      captureVoiceFeedbackSelection()
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
    if isTTSRunning || ttsPlayback.isPlaying {
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
      cancelInFlightPrompt()
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
    ContextLogger.shared.logSignal(
      .cancelledWhileProcessing, mode: "transcription", detail: ["phase": appState.signalPhase])
    discardStreamingSession()
    speechService.cancelTranscription()
    // Keep the audio instead of deleting it: a cancel is one keystroke and can be an accident,
    // and the recording is the only copy of what the user said. "Transcribe Cancelled Recording"
    // in the status menu turns an unrecoverable loss into one extra click.
    retainCancelledRecording(currentJobAudioURL)
    transitionToIdleAndCleanup(cleanupAudioURL: nil)
    if let url = currentJobAudioURL {
      currentJobAudioURL = nil
      processedAudioURLs.remove(url)
    }
  }

  /// The last cancelled dictation, kept on disk so it can still be transcribed. Only ever one:
  /// this is an undo affordance, not a history, and dictations can be tens of megabytes.
  private var cancelledRecordingURL: URL?

  private func retainCancelledRecording(_ url: URL?) {
    guard let url, FileManager.default.fileExists(atPath: url.path) else { return }
    // Replace any older retained recording so at most one is ever held.
    if let previous = cancelledRecordingURL, previous != url {
      cleanupAudioFile(at: previous)
    }
    cancelledRecordingURL = url
    let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
    DebugLogger.log(
      "CANCELLATION: Retained cancelled recording \(url.lastPathComponent) (\(size ?? 0) bytes) — recoverable from the status menu")
  }

  @objc private func transcribeCancelledRecording() {
    guard let url = cancelledRecordingURL else { return }
    guard FileManager.default.fileExists(atPath: url.path) else {
      DebugLogger.logWarning("CANCELLATION: Retained recording \(url.lastPathComponent) is gone")
      cancelledRecordingURL = nil
      return
    }
    guard case .idle = appState else {
      PopupNotificationWindow.showInfo(
        "Finish the current recording first, then try again.", title: "Busy")
      return
    }
    DebugLogger.log("CANCELLATION: Re-transcribing cancelled recording \(url.lastPathComponent)")
    // Hand ownership back to the normal pipeline, which deletes the file when it is done with it.
    cancelledRecordingURL = nil
    processedAudioURLs.insert(url)
    currentJobAudioURL = url
    appState = .processing(.transcribing)
    Task { await self.performTranscription(audioURL: url) }
  }

  /// Cancels a running Dictate Prompt. Reached from both the toggle shortcut and the Stop menu
  /// item, which is why it is a method rather than two copies.
  ///
  /// Passing the URL is what makes the cancellation stick: `transitionToIdleAndCleanup` clears
  /// `currentJobAudioURL`, so a reply that is already in flight is recognised as stale by
  /// `runAudioJob` and dropped instead of being pasted into whatever the user has since focused.
  /// It also removes the recording, which the previous no-argument call left on disk.
  private func cancelInFlightPrompt() {
    ContextLogger.shared.logSignal(
      .cancelledWhileProcessing, mode: "prompt", detail: ["phase": appState.signalPhase])
    speechService.cancelPrompt()
    transitionToIdleAndCleanup(cleanupAudioURL: currentJobAudioURL)
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
    // `show()` posts the visibility change, but the session had no recorder yet when it fired.
    liveMeeting.setFastChunking(ChatWindowManager.shared.isWindowOpen())
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

  /// Brings the live notes up to date immediately, forwarded to the session. Notes normally follow
  /// the transcript on their own; this fires when the user sends a chat message, so their turn sees
  /// the freshest note stream rather than one segment behind.
  @objc private func refreshLiveMeetingNotesOnDemand() {
    DispatchQueue.main.async { [weak self] in self?.liveMeeting.refreshLiveNotes(force: true) }
  }

  /// Marker hotkey handler. Flags the current moment of a running meeting; does nothing when no
  /// meeting is recording. No confirmation UI on purpose — the marker appears in the note stream
  /// itself, which is the same surface the user is already reading.
  @objc func markMeetingMoment() {
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      if !self.liveMeeting.addMarker(text: AppConstants.liveMeetingDefaultMarkerText) {
        DebugLogger.log("LIVE-MEETING-NOTES: Marker hotkey ignored — no meeting recording")
        return
      }
      // A marker means "what was just said matters", so cut the chunk it lands in: the flagged moment
      // reaches the transcript in seconds instead of at the next rotation. Fire-and-forget — nothing
      // here waits on it.
      Task { await self.liveMeeting.flushPendingAudio() }
    }
  }

  @objc private func markMeetingMomentFromNotification() {
    markMeetingMoment()
  }

  /// Chat window shown/hidden: switch the meeting's chunk cadence so the live view keeps up while
  /// someone is watching, and falls back to the configured (cheaper) interval when nobody is.
  @objc private func chatWindowVisibilityChanged(_ notification: Notification) {
    let visible = notification.userInfo?["visible"] as? Bool ?? false
    DispatchQueue.main.async { [weak self] in self?.liveMeeting.setFastChunking(visible) }
  }

  /// Opens the picked feedback channel, prefilled. No context to attach here — the user chose this
  /// from the menu rather than from a failure, so there is nothing specific to quote.
  @objc private func sendFeedback(_ sender: NSMenuItem) {
    guard let raw = sender.representedObject as? String,
          let channel = FeedbackLinks.Channel(rawValue: raw) else { return }
    FeedbackLinks.open(channel)
    DebugLogger.log("FEEDBACK: Opened \(channel.rawValue) from the status menu")
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

  /// Accidental hotkey taps and near-silent recordings are misses, not failures.
  private static func isBenignNoResult(_ error: TranscriptionError) -> Bool {
    switch error {
    case .noSpeechDetected, .textTooShort: return true
    default: return false
    }
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

      // Silence / too-short speech is a benign miss, not a failure. Logging it as ERROR
      // filled errors-*.log with `TranscriptionError error 21` (noSpeechDetected) on
      // accidental hotkey taps, and the persistent error popup plus clipboard overwrite
      // covered the user's work. Same presentation as the local silence precheck.
      if let transcriptionError = error as? TranscriptionError,
        Self.isBenignNoResult(transcriptionError)
      {
        DebugLogger.log("AUDIO: Benign no-result — \(transcriptionError)")
        self.cleanupAudioFile(at: audioURL)
        self.appState = self.appState.finish()
        PopupNotificationWindow.showInfo(
          "Nothing to transcribe. Check the microphone and try again.",
          title: "Didn't catch that",
          customDisplayDuration: Self.noSpeechInfoDuration
        )
        return
      }

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
  /// The `Bool` knobs record the remaining places where the two hand-written copies had drifted
  /// apart. Staleness is deliberately no longer one of them: both pipelines now drop a result that
  /// belongs to a superseded recording.
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
    /// On cancellation transcription routes through `transitionToIdleAndCleanup` (which also
    /// dismisses the popup, clears chunk state, drops the URL and removes the file); prompting
    /// finishes the state machine and cleans the file itself.
    var cancelsViaTransitionToIdle = false

    /// The `InteractionLogEntry.mode` this job writes, so an outcome signal can point at the right
    /// row. Nil for modes that log no interaction (live meeting, Voice Feedback).
    var interactionLogMode: String? {
      switch mode {
      case .transcription: return "transcription"
      case .prompt: return "prompt"
      case .liveMeeting, .voiceFeedback: return nil
      }
    }
  }

  /// The plain cancellation tail: finish the state machine, drop the URL, remove the file. Shared
  /// by the prompt pipeline and Voice Feedback, which handle a cancelled recording identically.
  /// Transcription does not use it — it routes through `transitionToIdleAndCleanup` instead, which
  /// additionally clears chunk state.
  private func cancelAudioJob(logLabel: String, error: Error, audioURL: URL) async {
    DebugLogger.log("CANCELLATION: \(logLabel) task was cancelled (\(type(of: error)))")
    await MainActor.run {
      self.chunkStatuses = []
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

      // A shortcut press during processing cancels the job (the cancel paths clear
      // `currentJobAudioURL`), but a result already in flight can still arrive afterwards — drop it
      // instead of pasting a cancelled result out of idle. Same staleness check as the error path
      // below. Meeting segments are exempt: they don't track a URL and can't be cancelled this way.
      let wasCancelled: Bool = await MainActor.run {
        if !duringMeeting, self.currentJobAudioURL != audioURL {
          DebugLogger.log(
            "CANCELLATION: Dropping \(spec.logLabel.lowercased()) result for cancelled recording \(audioURL.lastPathComponent)")
          self.processedAudioURLs.remove(audioURL)
          return true
        }
        return false
      }
      if wasCancelled { return }

      // Last chance to remember the user's clipboard before the result overwrites it. Dictate
      // Prompt already captured it before its synthetic ⌘C; this covers plain dictation.
      await MainActor.run { self.captureClipboardRestorePointIfEnabled() }
      spec.copyResult(result)
      await afterCopy(result)

      let didAutoPaste = await MainActor.run {
        self.autoPasteIfEnabled(logMode: spec.interactionLogMode)
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
          // `duringMeeting` is listed explicitly because a segment's pill leaves with its recording
          // phase (see `updateRecordingIndicator`), so by now it is gone — without this a dictation
          // inside a meeting would raise a result popup over the meeting view, while the identical
          // dictation outside one shows nothing but the pasted text.
          if !RecordingIndicatorManager.shared.isVisible && !duringMeeting {
            spec.presentResult(result, modelInfo, nil)
          }
        } else {
          spec.presentResult(result, modelInfo, "Copied — press ⌘V to paste")
        }
        if duringMeeting {
          self.clearMeetingSegment()
        } else {
          self.appState = self.appState.showSuccess(spec.successMessage(didAutoPaste))
        }
        // Clearing chunk progress is part of "this job is over", not a per-mode option: whichever
        // pipeline populated `chunkStatuses` (only long, chunked recordings do), leaving it set
        // would carry stale progress into whatever the user does next. A no-op when already empty.
        self.chunkStatuses = []
        if self.currentJobAudioURL == audioURL {
          self.currentJobAudioURL = nil
        }
        self.processedAudioURLs.remove(audioURL)
      }

      cleanupAudioFile(at: audioURL)
    } catch {
      // Nothing will be pasted, so drop the remembered clipboard — restoring it during some
      // later job would silently undo whatever the user copied in the meantime.
      await MainActor.run { self.clipboardManager.discardRestorePoint() }
      if Self.isCancellation(error) {
        if duringMeeting {
          DebugLogger.log("CANCELLATION: \(spec.logLabel) task was cancelled (\(type(of: error)))")
          await MainActor.run {
            self.clearMeetingSegment()
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

      let isStale: Bool = await MainActor.run {
        if !duringMeeting, self.currentJobAudioURL != audioURL {
          DebugLogger.log(
            "CANCELLATION: Ignoring \(spec.logLabel.lowercased()) error for stale audio URL \(audioURL.lastPathComponent)")
          self.processedAudioURLs.remove(audioURL)
          self.cleanupAudioFile(at: audioURL)
          return true
        }
        return false
      }
      if isStale { return }

      if duringMeeting {
        DebugLogger.logError("MEETING-SEGMENT: \(spec.logLabel) failed: \(error.localizedDescription)")
        await MainActor.run {
          self.clearMeetingSegment()
          self.processedAudioURLs.remove(audioURL)
          PopupNotificationWindow.showError(
            SpeechErrorFormatter.formatForUser(error), title: spec.errorTitle)
        }
        cleanupAudioFile(at: audioURL)
      } else {
        await handleProcessingError(error: error, audioURL: audioURL, mode: spec.mode)
        await MainActor.run {
          self.chunkStatuses = []
          if self.currentJobAudioURL == audioURL {
            self.currentJobAudioURL = nil
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
    } else if transcriptionModelForCapture == .openRouterTranscription {
      backendTag = "openrouter"
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
        // Recorded regardless of the interaction-logging toggle (that one gates *persistence*
        // inside the store) so "Copy Last Transcription" always works for the current session.
        TranscriptionHistoryStore.shared.record(result)
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

      let selection = await MainActor.run { () -> String? in
        let s = self.voiceFeedbackSelection
        self.voiceFeedbackSelection = nil  // one run, one selection
        return s
      }
      let proposal = try await voiceFeedbackService.proposeChange(
        instruction: trimmed, selectedText: selection)

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
        // A Voice Feedback instruction long enough to be chunked leaves progress behind when the
        // transcription fails before `mergingStarted` clears it; same tail as the other pipelines.
        self.chunkStatuses = []
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
      // Picking an offline model is the user saying they want to dictate with it. Downloading it
      // then and there is what every comparable app does; making them find a Download button in a
      // second section is how you end up dictating into a model that is not there.
      if newModel.isOffline, let offlineModelType = newModel.offlineModelType {
        prepareOfflineModelInBackground(offlineModelType, reason: "selection", downloadIfMissing: true)
      }
    }
  }

  /// Loads an offline model in the background, downloading it first only when asked to.
  ///
  /// `downloadIfMissing` is the difference between the two callers: choosing a model is a request
  /// for it, so that path fetches it; starting the app is not, so that path only warms what is
  /// already on disk. Failures are logged and not surfaced — nobody asked for this to happen right
  /// now, and the dictation path reports properly if the model is still missing when it matters.
  private func prepareOfflineModelInBackground(
    _ type: OfflineModelType, reason: String, downloadIfMissing: Bool
  ) {
    Task { @MainActor in
      let alreadyThere = ModelManager.shared.isModelAvailable(type)
      guard alreadyThere || downloadIfMissing else {
        DebugLogger.log(
          "MENU-BAR: \(type.displayName) is selected but not downloaded — leaving it that way "
            + "(\(reason)); the next dictation will offer to fetch it")
        return
      }
      DebugLogger.log(
        "MENU-BAR: Preparing offline model \(type.displayName) in background (\(reason), "
          + "\(alreadyThere ? "downloaded" : "needs download"))")
      do {
        try await ModelManager.shared.ensureReady(type)
        DebugLogger.logSuccess("MENU-BAR: Offline model \(type.displayName) ready")
      } catch {
        DebugLogger.logError(
          "MENU-BAR: Could not prepare \(type.displayName): \(error.localizedDescription)")
      }
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
    // A cancelled job never pastes, so any clipboard it remembered must not outlive it.
    clipboardManager.discardRestorePoint()
    if clearChunkStatuses {
      chunkStatuses = []
    }
    if let url = cleanupAudioURL {
      if currentJobAudioURL == url {
        currentJobAudioURL = nil
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
    // Whatever brought us here, this session is over: refuse chunks that are still in flight even
    // when playback itself isn't being torn down (the cancellation paths pass stopPlayback: false).
    ttsPlayback.refuseFurtherChunks()
    currentReadAloudTask?.cancel()
    if cancelNetworkWork {
      speechService.cancelTTS()
    }
    if stopPlayback {
      ttsPlayback.stop()
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
    if ttsPlayback.isPlaying {
      // With progressive playback, audio can already be playing while later chunks are still
      // being synthesized, so Stop has to kill the network work too — unless the stream is
      // already closed, in which case there is nothing left to cancel.
      finishReadAloudSession(cancelNetworkWork: !ttsPlayback.isStreamClosed)
      return true
    }
    if case .processing = appState {
      DebugLogger.logWarning("READ-ALOUD: ignoring — another operation is processing")
      return true
    }
    return false
  }

  /// Drives the Read Aloud pipeline: sets app state, posts `ttsDidStart`, and runs the producer,
  /// which streams synthesized chunks back through the sink it is handed. Playback therefore starts
  /// on the first chunk instead of after the merge; the producer's returned `Data` is only used as
  /// a fallback for producers that never emit a chunk. The producer call runs inside
  /// `currentReadAloudTask` so a subsequent Stop trigger can cancel it mid-flight.
  private func beginReadAloudProcessing(
    producer: @escaping (_ onChunkReady: @escaping (Data, Int, Int) -> Void) async throws -> Data
  ) {
    appState = .processing(.ttsProcessing)
    NotificationCenter.default.post(name: .ttsDidStart, object: nil)
    ttsPlayback.begin()

    currentReadAloudTask = Task { [weak self] in
      do {
        // `ChunkTTSService` invokes this on the main actor, in playback order.
        let audioData = try await producer({ [weak self] pcm, index, total in
          self?.ttsPlayback.enqueue(pcm, index: index, totalChunks: total)
        })
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
          if self.ttsPlayback.hasScheduledChunks {
            // Streaming path: audio is already playing. Just declare the stream finished so the
            // last buffer's completion can tear the session down.
            self.ttsPlayback.closeStream()
          } else {
            // No chunk ever arrived (a producer that doesn't stream). Play the merged result.
            self.ttsPlayback.play(audioData: audioData)
          }
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
    beginReadAloudProcessing { [speechService] onChunkReady in
      try await speechService.readProseAloud(trimmedText, onChunkReady: onChunkReady)
    }
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
    // Snapshot before the synthetic ⌘C, not after: from here on the pasteboard holds the
    // user's selection, so a later snapshot would "restore" that instead of what they copied.
    captureClipboardRestorePointIfEnabled()
    simulateCopy()
    return true
  }

  /// Best-effort snapshot of the current selection for Voice Feedback.
  ///
  /// Deliberately silent and non-blocking: Voice Feedback works perfectly well without a
  /// selection, so this never prompts for Accessibility permission and never shows an error when
  /// nothing is selected — unlike Read Aloud, where the selection IS the input. Polls
  /// `NSPasteboard.changeCount` rather than sleeping a fixed interval, because "nothing was
  /// copied" and "the app was slow to copy" are otherwise indistinguishable, and mistaking the
  /// first for the second would feed the user's unrelated clipboard to the model.
  private func captureVoiceFeedbackSelection() {
    voiceFeedbackSelection = nil
    guard AccessibilityPermissionManager.hasAccessibilityPermission() else {
      DebugLogger.log("VOICE-FEEDBACK: No Accessibility permission — proceeding without a selection")
      return
    }
    captureClipboardRestorePointIfEnabled()
    let before = NSPasteboard.general.changeCount
    simulateCopy()
    Task { @MainActor [weak self] in
      let deadline = Date().addingTimeInterval(0.5)
      while Date() < deadline {
        try? await Task.sleep(for: .milliseconds(15))
        guard NSPasteboard.general.changeCount != before else { continue }
        let text = NSPasteboard.general.string(forType: .string)?
          .trimmingCharacters(in: .whitespacesAndNewlines)
        if let text, !text.isEmpty {
          self?.voiceFeedbackSelection = text
          DebugLogger.log("VOICE-FEEDBACK: Captured selection (\(text.count) chars)")
        }
        return
      }
      DebugLogger.log("VOICE-FEEDBACK: No selection copied — proceeding with the spoken instruction only")
    }
  }

  #if !APP_STORE
  /// Appends whatever the user has selected to the Glossary.
  ///
  /// The deliberate non-feature here is intelligence: no model, no fuzzy matching against past
  /// transcripts, no diff window. The user has already decided what the correct spelling is by
  /// selecting it, so the app stores it verbatim. That is what makes this the one glossary path
  /// that still works in Offline Mode, where every model-driven learning route is switched off.
  @objc internal func addSelectionToGlossary() {
    guard AccessibilityPermissionManager.checkPermissionForPromptUsage() else { return }
    captureClipboardRestorePointIfEnabled()
    let before = NSPasteboard.general.changeCount
    simulateCopy()

    Task { @MainActor in
      let deadline = Date().addingTimeInterval(0.5)
      while Date() < deadline {
        try? await Task.sleep(for: .milliseconds(15))
        guard NSPasteboard.general.changeCount != before else { continue }
        let selection = NSPasteboard.general.string(forType: .string) ?? ""
        self.reportGlossaryAppend(SystemPromptsStore.shared.appendToWhisperGlossary(selection))
        _ = self.clipboardManager.restorePendingSnapshot()
        return
      }
      DebugLogger.log("GLOSSARY: Nothing copied — no selection to add")
      PopupNotificationWindow.showInfo(
        "Select the correctly spelled term first, then press the shortcut again.",
        title: "Nothing Selected")
    }
  }

  private func reportGlossaryAppend(_ result: SystemPromptsStore.GlossaryAppendResult) {
    switch result {
    case .added(let term):
      PopupNotificationWindow.showInfo("\"\(term)\" added to your Glossary.", title: "Glossary")
    case .duplicate(let term):
      PopupNotificationWindow.showInfo("\"\(term)\" is already in your Glossary.", title: "Glossary")
    case .notATerm(let text):
      PopupNotificationWindow.showInfo(
        "Select a single term — a name or a piece of jargon — not a sentence. The Glossary is a "
          + "spelling reference, and a whole sentence in it makes every dictation worse.",
        title: "Not a Glossary Term")
      DebugLogger.log("GLOSSARY: Rejected selection of \(text.count) chars")
    case .budgetExceeded(let term):
      PopupNotificationWindow.showInfo(
        "Your Glossary is full — Whisper only reads the first ~224 tokens of it, so \"\(term)\" "
          + "would never be used. Remove terms you no longer need in Settings → Dictate.",
        title: "Glossary Full")
    }
  }
  #endif

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

  /// Non-destructive paste: remembers the current clipboard so `autoPasteIfEnabled()` can put it
  /// back after the synthetic ⌘V. No-op unless the user turned the setting on.
  private func captureClipboardRestorePointIfEnabled() {
    guard Self.restoreClipboardEnabled else { return }
    clipboardManager.captureRestorePointIfNeeded()
  }

  private static var restoreClipboardEnabled: Bool {
    #if APP_STORE
    return false  // No auto-paste in the App Store build, so there is nothing to restore after.
    #else
    return UserDefaults.standard.object(forKey: UserDefaultsKeys.restoreClipboardAfterPaste) != nil
      ? UserDefaults.standard.bool(forKey: UserDefaultsKeys.restoreClipboardAfterPaste)
      : SettingsDefaults.restoreClipboardAfterPaste
    #endif
  }

  /// How long to wait after posting ⌘V before putting the old clipboard back. The receiving app
  /// reads the pasteboard asynchronously when it handles the keystroke, so restoring immediately
  /// would race it and paste the *old* contents. Generous enough for slow apps (Electron, remote
  /// desktops) while still feeling instant.
  private static let clipboardRestoreDelay: TimeInterval = 0.4

  /// Performs auto-paste if enabled in settings.
  /// - Returns: `true` when a paste keystroke was scheduled; `false` when the result stays on
  ///   the clipboard for the user to paste manually (App Store build, setting off, or missing
  ///   Accessibility permission).
  /// Whether this build and this user's settings can auto-paste at all.
  ///
  /// Separate from `autoPasteIfEnabled()` because outcome signals need to answer the same question
  /// *before* a job runs: without auto-paste there is no `pasted` signal, which changes how a
  /// `dictationRestart` has to be read.
  static var autoPasteAvailable: Bool {
    #if APP_STORE
    // Auto-paste synthesizes a ⌘V keystroke, which requires the Accessibility permission Apple
    // rejects under Guideline 2.4.5. The App Store build omits it; the result stays on the
    // clipboard for the user to paste manually.
    return false
    #else
    return UserDefaults.standard.object(forKey: UserDefaultsKeys.autoPasteAfterDictation) != nil
      ? UserDefaults.standard.bool(forKey: UserDefaultsKeys.autoPasteAfterDictation)
      : SettingsDefaults.autoPasteAfterDictation
    #endif
  }

  @discardableResult
  private func autoPasteIfEnabled(logMode: String?) -> Bool {
    #if APP_STORE
    return false
    #else
    if Self.autoPasteAvailable {
      guard AccessibilityPermissionManager.hasAccessibilityPermission() else {
        DebugLogger.logWarning("AUTO-PASTE: Skipped — accessibility permission not granted, showing permission dialog")
        AccessibilityPermissionManager.showAccessibilityPermissionDialog()
        // Nothing was pasted, so the result has to stay on the clipboard for the user's own ⌘V.
        clipboardManager.discardRestorePoint()
        return false
      }
      // Small delay to ensure clipboard is ready
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
        self?.simulatePaste()
        // Log *where* the synthetic ⌘V went. The app can be in the background for minutes
        // (long dictation while the user works elsewhere), so the receiving app is whatever
        // happens to be frontmost — and if it has a selection, ⌘V replaces it. Without the
        // target and payload size on record, a report of "my text was suddenly gone" is
        // undiagnosable after the fact.
        let target = NSWorkspace.shared.frontmostApplication
        let chars = NSPasteboard.general.string(forType: .string)?.count ?? 0
        DebugLogger.log(
          "AUTO-PASTE: Pasted \(chars) chars into "
            + "\(target?.localizedName ?? "unknown") "
            + "(\(target?.bundleIdentifier ?? "no bundle id"))")

        // The result reached the user's cursor: the strongest available "this worked" signal, and
        // the one that stops a following dictation from being counted as a retry.
        ContextLogger.shared.logSignal(
          .pasted,
          mode: logMode,
          detail: [
            "chars": String(chars),
            "targetBundleId": target?.bundleIdentifier ?? "unknown",
          ])

        // Non-destructive paste: give the receiving app time to read the pasteboard, then put
        // the user's previous clipboard back.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.clipboardRestoreDelay) { [weak self] in
          guard let self else { return }
          if self.clipboardManager.restorePendingSnapshot() {
            DebugLogger.log("AUTO-PASTE: Restored the clipboard contents from before dictation")
          }
        }
      }
      return true
    }
    // Auto-paste is off: the result stays on the clipboard, so there is nothing to restore.
    clipboardManager.discardRestorePoint()
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
        // Discarding a segment ends the segment, not the meeting: `appState` belongs to the meeting
        // here, and finishing it would strand a recorder that is still running.
        if self.activeMeetingSegment != nil {
          self.clearMeetingSegment()
        } else {
          self.appState = self.appState.finish()
        }
        return
      }

      // Meeting segment path: recording finished for a parallel action during live meeting
      if let segment = self.activeMeetingSegment {
        DebugLogger.log("MEETING-SEGMENT: Recording finished for segment \(segment), dispatching pipeline")
        self.processedAudioURLs.insert(audioURL)
        self.markMeetingSegmentProcessing()
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
            "Nothing to transcribe. Check the microphone and try again.",
            title: "Didn't catch that",
            customDisplayDuration: Self.noSpeechInfoDuration
          )
          return
        } else {
          DebugLogger.logWarning("AUDIO: Recording flagged silent, but proceeding with offline transcription")
        }
      }

      // Both pipelines that can be cancelled mid-processing track their audio URL, so a result
      // arriving after cancellation can be recognised as stale. Voice Feedback is excluded: it has
      // no clipboard/paste step, so a late result can't paste into the user's document.
      if recordingMode == .transcription || recordingMode == .prompt {
        self.currentJobAudioURL = audioURL
      }

      if !self.appState.isProcessing {
        self.appState = self.appState.stopRecording()
      }

      Task {
        switch recordingMode {
        case .transcription:
          // No pre-emptive popup here any more: `ModelManager.ensureReady` reports what is
          // actually happening (downloading N%, preparing, transcribing) from inside the
          // transcription path, instead of one static "can take several minutes" line.
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
      clearMeetingSegment()
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

  /// Whether a dictation recording is running — mirrors what `toggleTranscription` treats as
  /// active, including a parallel segment during a live meeting. Used by the Fn toggle.
  func isDictationRecordingActive() -> Bool {
    if isLiveMeetingActive { return activeMeetingSegment == .dictation }
    return appState.recordingMode == .transcription
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
    beginReadAloudProcessing { [speechService] onChunkReady in
      try await speechService.readSelectionAloud(selectedText, onChunkReady: onChunkReady)
    }
  }
  #endif
}

// MARK: - FnDictationToggleDelegate (Fn Key Dictation)
extension MenuBarController: FnDictationToggleDelegate {
  func fnDictationStart() -> Bool {
    // fn-down must never cancel in-flight work or stop a recording the user started
    // otherwise — it only ever begins a fresh dictation.
    guard !isTranscriptionProcessing, !isDictationRecordingActive() else { return false }
    toggleTranscription()
    return isDictationRecordingActive()
  }

  func fnDictationStop() {
    guard isDictationRecordingActive() else { return }
    toggleTranscription()
  }

  func fnDictationIsRecording() -> Bool {
    return isDictationRecordingActive()
  }

  // During a live meeting ⌘1 never cancels either — its meeting branch runs first — so fn
  // mirrors that and falls through to starting a dictation segment.
  func fnDictationIsProcessing() -> Bool {
    return !isLiveMeetingActive && isTranscriptionProcessing
  }

  func fnDictationCancelProcessing() {
    guard !isLiveMeetingActive, isTranscriptionProcessing else { return }
    DebugLogger.log("SHORTCUTS: Cancelling in-flight transcription via Fn")
    cancelInFlightTranscription()
  }

  func fnDictationDiscard() {
    guard isDictationRecordingActive() else { return }
    // During a live meeting the discard flag would strand the active segment (the discard
    // branch in audioRecorderDidFinishRecording runs before segment cleanup), so let an
    // accidental tap flow through the normal pipeline — a ~0.3s clip transcribes to nothing.
    if isLiveMeetingActive {
      toggleTranscription()
      return
    }
    DebugLogger.log("AUDIO: Discarding Fn dictation recording")
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

  /// Assigns a chunk-progress processing state, but only while the app is still in a processing
  /// phase. With progressive Read Aloud playback, chunks 2…N finish *after* chunk 1 started
  /// playing and `appState` moved to `.speaking`; a late `.processingChunks` assignment there
  /// would drag the menu bar back into a busy state and — worse — make `isTTSRunning` true again,
  /// so the next Stop press would take the "cancel synthesis" branch instead of stopping audio.
  private func setChunkProcessingState(_ state: AppState) -> Bool {
    guard case .processing = appState else { return false }
    appState = state
    return true
  }

  /// Whether the chunk pipeline may raise its progress popups at all.
  ///
  /// Two flows must never see them. The bottom-center pill already shows processing for
  /// pill-driven flows, so a popup on top is redundant feedback (same rule as the success popup
  /// in `performTranscription`). And a live meeting has no business raising progress UI at all —
  /// its chunks now pass `reportsProgress: false` so they never reach this delegate, and this
  /// clause keeps that true for any future caller that forgets, including the meeting-resume
  /// path. A dictation started *during* a meeting is unaffected: it shows the pill, so the first
  /// clause already suppressed its popups.
  private var showsChunkProgressPopups: Bool {
    !RecordingIndicatorManager.shared.isVisible && !isLiveMeetingActive
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
    if showsChunkProgressPopups {
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
    guard setChunkProcessingState(
      .processing(.processingChunks(statuses: chunkStatuses, context: context)))
    else { return }
    updateMenuBarIcon()

    let isTTS = context == .tts

    // Update processing popup with status grid (pill-less flows only, see chunkingStarted)
    if showsChunkProgressPopups {
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
    guard setChunkProcessingState(
      .processing(.processingChunks(statuses: chunkStatuses, context: context)))
    else {
      DebugLogger.logDebug("CHUNK-PROGRESS: Chunk \(index) completed while already playing back")
      return
    }
    updateMenuBarIcon()

    let isTTS = context == .tts

    // Update processing popup with status grid (pill-less flows only, see chunkingStarted)
    if showsChunkProgressPopups {
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
      if showsChunkProgressPopups {
        let statusGrid = generateStatusGrid()
        PopupNotificationWindow.updateProcessing(
          title: isTTS ? "Synthesizing Speech" : "Processing Audio",
          message: "\(statusGrid)\nRetrying chunk \(index + 1)..."
        )
      }
    } else {
      // Mark as permanently failed
      chunkStatuses[index] = .failed

      guard setChunkProcessingState(
        .processing(.processingChunks(statuses: chunkStatuses, context: context)))
      else {
        DebugLogger.logError("CHUNK-PROGRESS: Chunk \(index) failed during playback: \(error.localizedDescription)")
        return
      }
      updateMenuBarIcon()

      // Update processing popup (pill-less flows only, see chunkingStarted)
      if showsChunkProgressPopups {
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
    // Read Aloud reaches the merge step with audio already playing (the merged buffer is only a
    // fallback there), so this is a no-op in the common TTS case.
    guard setChunkProcessingState(.processing(.merging(context: context))) else { return }
    updateMenuBarIcon()

    let isTTS = context == .tts

    // Update processing popup with appropriate message (pill-less flows only, see chunkingStarted)
    if showsChunkProgressPopups {
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
    // The history rows are otherwise only refreshed on an `appState` change, which leaves them
    // stale right after launch (a persisted history exists but nothing has happened yet).
    updateTranscriptionHistoryItems(menu)
  }
}
