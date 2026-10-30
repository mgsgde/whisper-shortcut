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
  /// refresh site in `refreshMenu(_:)` used to be linked by nothing but matching integer
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
    case copyLastTranscription = 117
    case recentTranscriptions = 118
    case sendFeedback = 119
    case transcribeCancelledRecording = 120
    case runAgainWithoutTemplate = 131
    case addToGlossary = 121
    case finishSetup = 122
    case finishSetupSeparator = 126
    case retryMeetingTranscription = 127
    case showMeetingAudio = 128
    case welcomeTour = 129
    case aiAppProposals = 130
  }

  /// Display time for the benign "No speech detected" info popup — long enough to read,
  /// far shorter than the persistent error-popup duration.
  private static let noSpeechInfoDuration: TimeInterval = 4
  /// At or below this peak a recording is digital zero, not a quiet room (quiet speech sits
  /// between −100 and the −45 dB silence gate).
  private static let digitalSilenceThresholdDb: Float = -100
  /// Shorter taps can end before the first meter sample, leaving the −160 dB initial peak.
  private static let digitalSilenceMinDurationMs = 2000

  // MARK: - Single Source of Truth
  private var appState: AppState = .idle {
    didSet {
      DebugLogger.logDebug("APPSTATE: \(oldValue) -> \(appState) (mainThread=\(Thread.isMainThread))")
      // Edges only: chunk-pipeline states move processing → processing and must not restart
      // the clock that `processingMs` on cancel/deadline signals reads (queue #8).
      let wasProcessing = oldValue.isNonTTSProcessing
      let isProcessing = appState.isNonTTSProcessing
      if isProcessing, !wasProcessing {
        ContextLogger.shared.noteProcessingStart()
      } else if wasProcessing, !isProcessing {
        ContextLogger.shared.noteProcessingStart(nil)
      }
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
  /// Live in the Send Feedback submenu, which `menu.item(withTag:)` does not search.
  private var reportDictationItem: NSMenuItem?
  private var reportDictationSeparator: NSMenuItem?
  private var blinkTimer: Timer?
  private var feedbackResetTask: Task<Void, Never>?

  // MARK: - Services (Injected Dependencies)
  private let audioRecorder: DictationAudioRecording
  private let speechService: SpeechService
  private let clipboardManager: ClipboardManager
  private let shortcuts: Shortcuts
  private let fnDictationToggle = FnDictationToggle()
  private let reviewPrompter: ReviewPrompter
  
  // MARK: - State Tracking (Prevent Race Conditions)

  /// One recording, from the shortcut press until its audio is handed to a `VoiceJob` (or
  /// discarded). Its fields used to be eight loose properties, and each start path reset a
  /// different subset of them — the quick-action fields only for a prompt outside a meeting — so a
  /// flag from one recording could carry into the next. A recording now starts from a fresh value
  /// (`beginAudioCapture`) and ends by dropping it (`audioRecorderDidFinishRecording`, the fail and
  /// cancel paths). Same shape as `VoiceJob` on the processing side (refactor ledger R52).
  private struct RecordingIntent {
    enum Target: Equatable {
      case mode(AppState.RecordingMode)
      case meetingSegment(MeetingSegment)
    }
    let target: Target
    /// False while mic permission is still pending. `.recording` / the meeting segment is entered
    /// only from `audioRecorderDidBeginRecording`, so a second shortcut press during the system
    /// prompt cannot strand the app (D6).
    var captureStarted = false
    /// Set when the user hits ✕ on the indicator (or discards an Fn dictation): the finished audio
    /// is thrown away instead of processed.
    var discardOnFinish = false
    /// Set by the first stop press (before the tail delay). Until the recorder delivers the audio a
    /// further press must not stop again: the recorder answers "nothing running", which used to
    /// reset the app to idle while the finished audio was still on its way, and the audio was then
    /// dropped silently.
    var stopRequested = false
    /// Set once per prompt recording so Escape, or stopping, does not bring the list back.
    var quickActionsOffered = false
    /// A repeating Return must not launch the quick action twice before the recording stops.
    var quickActionRan = false
    /// Quick-action instruction, held until the recording's file URL exists, then keyed by that
    /// URL (`finishedPromptInputs`) so a retry sends the same text.
    var quickActionInstruction: String?
    /// The quick action is an edit (fix, rewrite, shorten, format, translate), so with nothing
    /// selected there is nothing for it to act on.
    var isEditQuickAction = false
    /// Dictate Prompt: the selection captured for THIS recording (nil in screenshot-selection mode,
    /// where the selection lives in the screenshot). Set when the intent is created, so it can
    /// never be lost to the copy finishing after a short recording — the job awaits it.
    var promptSelection: DictatePromptSelectionCapture?
    /// Template whose shortcut started this Dictate Prompt recording. Nil for Dictate, a meeting
    /// segment, a screenshot-selection model, the generic Dictate Prompt shortcut, or when the
    /// template was not passed in. Resolved here so a later edit of the template cannot swap it.
    var boundTemplate: DictationTemplate?
    /// Tab switches the bound template off for this recording. The instructions are sent only
    /// while this stays true.
    var templateEnabled = true

    var pendingMode: AppState.RecordingMode? {
      if case .mode(let mode) = target, !captureStarted { return mode }
      return nil
    }
    var pendingSegment: MeetingSegment? {
      if case .meetingSegment(let segment) = target, !captureStarted { return segment }
      return nil
    }
  }
  private var recording: RecordingIntent?
  /// The mode a recording will enter once the recorder confirms capture; nil once it has.
  private var pendingRecordingMode: AppState.RecordingMode? { recording?.pendingMode }
  /// Same for a live-meeting segment: `beginMeetingSegment` waits until the recorder starts.
  private var pendingMeetingSegment: MeetingSegment? { recording?.pendingSegment }

  /// Per-recording streaming session (slice 2 of plans/active/streaming-dictate.md).
  /// Non-nil only while a Dictate recording on a cloud STT model (Gemini/OpenAI/xAI) is
  /// active/processing; prompt recordings, offline Whisper, and self-hosted endpoints
  /// leave it nil (single-shot path).
  private var dictateStreamingSession: DictateStreamingSession?
  /// The Dictate or Dictate Prompt job currently being processed, outside a live
  /// meeting. Cancelling cancels its task and clears this, which is how a late-arriving result (or
  /// a late cancellation tail) is recognised as belonging to a superseded job and dropped instead of
  /// being pasted out of idle or finishing a recording the user has started since. See `VoiceJob`.
  private var currentJob: VoiceJob?

  /// Creates the job for a finished recording, makes it current, and runs `work` on the main actor.
  private func startVoiceJob(
    mode: AppState.RecordingMode, audioURL: URL, _ work: @escaping @MainActor (VoiceJob) async -> Void
  ) {
    let job = VoiceJob(mode: mode, audioURL: audioURL)
    currentJob = job
    job.run { await work(job) }
  }

  /// True when `job` has been cancelled or replaced. Meeting segments pass nil: they are never
  /// superseded this way.
  private func isSuperseded(_ job: VoiceJob?) -> Bool {
    guard let job else { return false }
    return currentJob !== job
  }
  private var processedAudioURLs: Set<URL> = []
  /// What a finished Dictate Prompt recording ran with, keyed by its audio URL. Outlives the
  /// `RecordingIntent`: a retry sends the same quick-action text (and the silence precheck lets it
  /// through), edits the same selection instead of re-reading a pasteboard that has moved on,
  /// and applies the same template.
  private struct FinishedPromptInputs {
    var quickActionInstruction: String?
    var isEditQuickAction = false
    var selection: DictatePromptSelectionCapture?
    /// Template instructions captured with the recording, so a retry replaces the system prompt
    /// the same way the first attempt did.
    var templateInstruction: String?
    /// `displayName` of that template, for the replay menu item. Nil when no template was bound.
    var templateName: String?
  }
  private var finishedPromptInputs: [URL: FinishedPromptInputs] = [:]
  /// App Store build + local model only (no synthetic ⌘C there): the pasteboard `changeCount` the
  /// last Dictate Prompt took its clipboard decision on. Starts at launch, so whatever was on the
  /// pasteboard before the app started never counts as a selection.
  private var lastConsumedPromptClipboardChangeCount = NSPasteboard.general.changeCount

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
        self.appState = self.appState.showSuccess(String(localized: "Audio playback completed"))
      } else {
        // A dictation during playback already moved `appState` on, so no state change will
        // repaint the pill — without this the finished transport stays on screen at 100 %.
        self.updateRecordingIndicator()
      }
    },
    onFailure: { [weak self] error in
      guard let self else { return }
      self.finishReadAloudSession(cancelNetworkWork: false, transitionToIdle: false)
      self.presentError(
        shortTitle: SpeechErrorFormatter.shortStatusForUser(error),
        message: SpeechErrorFormatter.formatForUser(error), dismissProcessingFirst: false)
    },
    onBufferingChanged: { isBuffering in
      RecordingIndicatorManager.shared.updateBuffering(isBuffering)
    },
    onProgress: { position, duration, received in
      RecordingIndicatorManager.shared.updateProgress(position: position, duration: duration, received: received)
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
      try await NoSpeechContext.run(.liveMeetingChunk, audioURL: url) {
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
      }
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
    },
    onBacklogChanged: { [weak self] in
      guard let self, let menu = self.statusItem?.menu else { return }
      self.updateMeetingBacklogItems(menu)
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
      if meetingSegmentIsProcessing {
        return String(localized: "⏳ Processing — meeting still recording")
      }
      return segment == .dictation
        ? String(localized: "\(presentedState.icon) Dictating — meeting still recording")
        : String(localized: "\(presentedState.icon) Recording AI prompt — meeting still recording")
    }
    if meetingIsFinishing { return String(localized: "⏳ Finishing meeting — saving the last seconds…") }
    return appState.statusText
  }

  /// True when TTS is running in any phase: .ttsProcessing or chunked phases with TTS context. Derived from AppState only.
  private var isTTSRunning: Bool { appState.isTTSPipelineProcessing }

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
    // After setup, so a crash or force-quit cannot leave patient audio past the next launch.
    // `applicationWillTerminate` only runs on a normal quit.
    removeLeftoverTemplateRecordings()

    Task.detached(priority: .utility) {
      QuickActionStore.shared.refresh()
    }

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

    let finishSetupItem = createMenuItem(
      "Finish setup…", action: #selector(showWelcomeTour), tag: .finishSetup)
    menu.addItem(finishSetupItem)
    let finishSetupSeparator = NSMenuItem.separator()
    finishSetupSeparator.tag = MenuTag.finishSetupSeparator.rawValue
    menu.addItem(finishSetupSeparator)

    // Changes an AI app proposed over MCP; hidden while nothing waits.
    let proposalsItem = createMenuItem(
      "Review Changes from AI Apps…", action: #selector(showAIAppProposals), tag: .aiAppProposals)
    proposalsItem.isHidden = true
    menu.addItem(proposalsItem)

    // Central stop button — visible only when any operation is active
    let stopItem = createMenuItem("Stop", action: #selector(stopCurrentOperation), tag: .stop)
    menu.addItem(stopItem)
    let stopSeparator = NSMenuItem.separator()
    stopSeparator.tag = MenuTag.stopSeparator.rawValue
    menu.addItem(stopSeparator)

    // Recording actions with keyboard shortcuts. Read Aloud and Glossary are selection-based (⌘C needs
    // Accessibility) and absent from the App Store build.
    for row in Self.actionRows {
      menu.addItem(makeItem(row))
    }
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
    // Only present for a few minutes after a template shaped a dictation, so the same audio can
    // be run through the ordinary system prompt. Hidden until that copy exists.
    let runAgainItem = createMenuItem(
      "Run Again Without Template", action: #selector(runAgainWithoutTemplate),
      tag: .runAgainWithoutTemplate)
    runAgainItem.isHidden = true
    menu.addItem(runAgainItem)
    // Only present while a meeting has audio that failed to transcribe (e.g. recorded offline).
    // Holding ⌥ swaps it for the folder the audio is kept in.
    menu.addItem(
      createMenuItem(
        "Retry Meeting Transcription", action: #selector(retryMeetingTranscription),
        tag: .retryMeetingTranscription))
    let showMeetingAudioItem = createMenuItem(
      "Show Untranscribed Meeting Audio", action: #selector(showMeetingAudioInFinder),
      tag: .showMeetingAudio)
    showMeetingAudioItem.isAlternate = true
    showMeetingAudioItem.keyEquivalentModifierMask = .option
    menu.addItem(showMeetingAudioItem)

    menu.addItem(NSMenuItem.separator())

    // Chat window
    menu.addItem(makeItem(Self.chatRow))

    menu.addItem(NSMenuItem.separator())

    // Settings and quit.
    // Use a neutral selector and clear image explicitly to avoid AppKit
    // auto-decoration that can reserve an icon column for this row.
    let configureItem = makeItem(Self.settingsRow)
    configureItem.image = nil
    menu.addItem(configureItem)

    // Permanent way back into the tour once setup is done. While it is incomplete the
    // "Finish setup…" row at the top opens the same window, so this one hides then.
    menu.addItem(
      createMenuItem("Welcome Tour…", action: #selector(showWelcomeTour), tag: .welcomeTour))

    // Feedback sits next to Settings, the macOS convention for it, and offers all three channels
    // rather than WhatsApp alone — a user without WhatsApp otherwise has no obvious way to reach
    // the developer at all. A submenu keeps this to one row: the status menu is the app's
    // most-used surface, and three permanent contact rows in it would read as nagging.
    let feedbackItem = createMenuItem("Send Feedback", action: nil, tag: .sendFeedback)
    let feedbackMenu = NSMenu()
    // First, because a report about a concrete dictation is the one the developer can act on
    // without asking back. Hidden while there is no dictation to report.
    let reportItem = NSMenuItem(
      title: String(localized: "Report a Problem with Last Dictation…"),
      action: #selector(reportLastDictation), keyEquivalent: "")
    reportItem.target = self
    reportItem.toolTip = String(
      localized: "Send the last dictation with its model and version, after you check it")
    let reportSeparator = NSMenuItem.separator()
    feedbackMenu.addItem(reportItem)
    feedbackMenu.addItem(reportSeparator)
    reportDictationItem = reportItem
    reportDictationSeparator = reportSeparator
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
    _ title: LocalizedStringResource, action: Selector?, keyEquivalent: String = "", tag: MenuTag? = nil
  ) -> NSMenuItem {
    let item = NSMenuItem(title: String(localized: title), action: action, keyEquivalent: keyEquivalent)
    item.target = self
    item.tag = tag?.rawValue ?? 0
    return item
  }

  /// A row of the status menu that shows a configurable shortcut. `mode` is set for the rows whose
  /// title flips to `stopTitle` while `availability(mode) == .stop`.
  private struct ModeRow {
    let tag: MenuTag
    let title: LocalizedStringResource
    let stopTitle: LocalizedStringResource?
    let action: Selector
    let shortcut: KeyPath<ShortcutConfig, ShortcutDefinition>
    let mode: ModeAction?
  }

  /// Dictate … Glossary in menu order (same order as before the table existed).
  /// Chat and Settings are separate rows further down: Settings is titled "Settings…", and
  /// putting them here would move them above Copy Last Transcription.
  private static let actionRows: [ModeRow] = {
    var rows = [
      ModeRow(
        tag: .dictate, title: ShortcutAction.dictate.localizedTitle, stopTitle: "Stop Dictate",
        action: #selector(toggleTranscription), shortcut: ShortcutAction.dictate.keyPath,
        mode: .dictate),
      ModeRow(
        tag: .dictatePrompt, title: ShortcutAction.dictatePrompt.localizedTitle, stopTitle: "Stop Dictate Prompt",
        action: #selector(togglePrompting as (MenuBarController) -> () -> Void),
        shortcut: ShortcutAction.dictatePrompt.keyPath,
        mode: .dictatePrompt),
      ModeRow(
        tag: .screenshot, title: ShortcutAction.screenshot.localizedTitle, stopTitle: nil,
        action: #selector(takeScreenshot), shortcut: ShortcutAction.screenshot.keyPath, mode: nil),
    ]
    // `readAloudFromMenu` is compiled out of the App Store target, so a runtime
    // `isInThisBuild` check would not compile there. The condition is the same one.
    #if !APP_STORE
    rows.append(
      ModeRow(
        tag: .readAloud, title: ShortcutAction.readAloud.localizedTitle, stopTitle: "Stop Read Aloud",
        action: #selector(readAloudFromMenu), shortcut: ShortcutAction.readAloud.keyPath,
        mode: .readAloudSelection))
    #endif
    // Not a `ShortcutAction`: the assistant list never named Glossary. The menu title is
    // "Add Selection to Glossary", not "Add to Glossary".
    #if !APP_STORE
    rows.append(
      ModeRow(
        tag: .addToGlossary, title: "Add Selection to Glossary", stopTitle: nil,
        action: #selector(addSelectionToGlossary), shortcut: \.addToGlossary, mode: nil))
    #endif
    return rows
  }()

  private static let chatRow = ModeRow(
    tag: .chat, title: "Chat", stopTitle: nil,
    action: #selector(openChatWindow), shortcut: \.openChat, mode: nil)
  private static let settingsRow = ModeRow(
    tag: .settings, title: "Settings…", stopTitle: nil,
    action: #selector(openConfigurationPanel), shortcut: \.openSettings, mode: nil)

  private func makeItem(_ row: ModeRow) -> NSMenuItem {
    let item = NSMenuItem(title: String(localized: row.title), action: row.action, keyEquivalent: "")
    item.target = self
    item.tag = row.tag.rawValue
    let shortcut = currentConfig[keyPath: row.shortcut]
    if shortcut.isEnabled {
      let keyChar = StatusMenuTitle.keyEquivalentCharacter(for: shortcut.key)
      if !keyChar.isEmpty {
        item.keyEquivalent = keyChar
        item.keyEquivalentModifierMask = shortcut.modifiers
      }
    }
    item.title = StatusMenuTitle.render(
      base: String(localized: row.title), isEnabled: shortcut.isEnabled, keyEquivalent: item.keyEquivalent,
      display: shortcut.displayString)
    return item
  }

  @objc private func showWelcomeTour() {
    WelcomeWindowController.shared.show()
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
    RecordingIndicatorManager.shared.onTogglePause = { [weak self] in
      self?.toggleReadAloudPause()
    }
    RecordingIndicatorManager.shared.onCycleSpeed = { [weak self] in
      self?.cycleReadAloudSpeed()
    }
    RecordingIndicatorManager.shared.onSkip = { [weak self] seconds in
      self?.ttsPlayback.skip(by: seconds)
    }
    RecordingIndicatorManager.shared.onSeek = { [weak self] seconds in
      self?.ttsPlayback.seek(to: seconds)
    }
    RecordingIndicatorManager.shared.onQuickAction = { [weak self] index in
      self?.runQuickAction(at: index)
    }
    RecordingIndicatorManager.shared.onTemplateToggled = { [weak self] enabled in
      self?.recording?.templateEnabled = enabled
      DebugLogger.log("DICTATION-TEMPLATE: \(enabled ? "on" : "off") for this recording")
    }
    RecordingIndicatorManager.shared.onTypedPrompt = { [weak self] text in
      self?.runPromptInstruction(text, source: "typed")
    }
  }

  // MARK: - Recording Indicator

  /// Keeps the floating bottom-center pill in sync with `presentedState`. It shows the
  /// recording pill for Dictate / Dictate Prompt, and the compact processing spinner
  /// for both those flows (handed off from recording) and Read Aloud / TTS synthesis
  /// (summoned directly, since TTS has no recording phase). Once TTS hands off to
  /// playback the state is `.speaking` and the pill turns into the Read Aloud transport
  /// (stop / pause / speed) — a one-minute utterance is nothing the user should have to
  /// hunt through the menu bar to silence. On success (and every other state) it hides
  /// immediately — lingering UI would cover the user's work.
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
      dismissQuickActions()
      indicator.hide()
      return
    }
    switch presentedState {
    case .recording(.prompt) where activeMeetingSegment == nil:
      offerQuickActionsIfNeeded()
      indicator.showRecording(label: AppState.RecordingMode.prompt.pillLabel)
    case .recording(let mode) where mode != .liveMeeting:
      dismissQuickActions()
      indicator.showRecording(label: mode.pillLabel)
    case .processing(let mode):
      dismissQuickActions()
      // TTS has no recording phase, so summon the processing pill directly;
      // Dictate / Dictate Prompt already have it on screen from recording.
      // The meeting's stop drain is not summoned either — the menu bar and the meeting bar
      // report it, and a pill for it would appear over whatever the user turned to next.
      let summon = mode.isTTSContext
      indicator.showProcessing(summonIfNeeded: summon, label: mode.pillLabel)
    default:
      dismissQuickActions()
      // `.speaking` is the normal case here, but audio can also still be playing under a
      // later state: `.speaking` is not busy, so a dictation may start and finish while the
      // utterance runs on — the transport comes back once the pill is free again.
      if ttsPlayback.isPlaying {
        indicator.showSpeaking(isPaused: ttsPlayback.isPaused, speed: ReadAloudPreferences.speed)
        indicator.updateProgress(
          position: ttsPlayback.position, duration: ttsPlayback.duration, received: ttsPlayback.received)
      } else {
        indicator.hide()
      }
    }
  }

  /// ⏸ / ▶ on the Read Aloud pill.
  private func toggleReadAloudPause() {
    guard ttsPlayback.isPlaying else { return }
    if ttsPlayback.isPaused { ttsPlayback.resume() } else { ttsPlayback.pause() }
    updateRecordingIndicator()
  }

  /// Speed button on the Read Aloud pill: steps to the next rate and keeps it as the new
  /// Settings → Read Aloud default, so the choice sticks for the next utterance too.
  private func cycleReadAloudSpeed() {
    let next = ReadAloudPreferences.speed.next
    UserDefaults.standard.set(next.rawValue, forKey: UserDefaultsKeys.readAloudSpeed)
    ttsPlayback.setSpeed(next)
    updateRecordingIndicator()
  }

  /// ✕ on the indicator: discard an active recording, or cancel in-flight processing.
  private func handleIndicatorCancel() {
    if appState.isRecording || pendingRecordingMode != nil || pendingMeetingSegment != nil {
      dismissQuickActions()
      DebugLogger.log("AUDIO: Recording discarded via indicator ✕")
      RecordingIndicatorManager.shared.hide()
      if audioRecorder.stopRecording() {
        recording?.discardOnFinish = true
      } else {
        cancelPendingRecordingStart()
        if case .recording = appState { appState = appState.finish() }
        if activeMeetingSegment != nil { clearMeetingSegment() }
      }
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
    if ttsPlayback.isPlaying {
      DebugLogger.log("TTS: Read Aloud playback stopped via indicator ✕")
      finishReadAloudSession(cancelNetworkWork: !ttsPlayback.isStreamClosed)
      return
    }
    if case .processing(.prompting) = appState {
      cancelInFlightPrompt()
      return
    }
  }

  /// ✓ on the indicator: same as the stop shortcut — finish recording and process.
  private func handleIndicatorConfirm() {
    guard appState.isRecording else { return }
    DebugLogger.log("AUDIO: Stop via indicator ✓ / ↩")
    stopPromptOrRunTyped()
  }

  // MARK: - Dictate Prompt quick actions

  /// Shows the cached list once per prompt recording. A live-meeting segment never reaches
  /// this — `updateRecordingIndicator` only calls it when no meeting segment is active.
  private func offerQuickActionsIfNeeded() {
    guard recording?.quickActionsOffered == false else { return }
    recording?.quickActionsOffered = true
    let actions = QuickActionStore.shared.current()
    let templateName = recording?.boundTemplate?.displayName
    guard !actions.isEmpty || templateName != nil else {
      DebugLogger.log("QUICK-ACTIONS: No entries — list stays hidden")
      return
    }
    // No capture means screenshot-selection mode: the model reads the selection off the screen.
    guard let capture = recording?.promptSelection else {
      RecordingIndicatorManager.shared.showQuickActions(actions, context: .screenshot)
      DebugLogger.log("QUICK-ACTIONS: Showing \(actions.count) entries (screenshot selection)")
      return
    }
    RecordingIndicatorManager.shared.showQuickActions(
      actions, context: .reading, templateName: templateName)
    DebugLogger.log("QUICK-ACTIONS: Showing \(actions.count) entries")
    let fromClipboard = AppConstants.dictatePromptUsesScreenshotSelection
    Task { @MainActor [weak self] in
      let text = await capture.value()
      // A later recording has its own capture; this answer belongs to the one that asked.
      guard let self, self.recording?.promptSelection === capture else { return }
      RecordingIndicatorManager.shared.updateQuickActionContext(
        text.map { .selection(text: $0, fromClipboard: fromClipboard) } ?? .nothingSelected)
    }
  }

  private func dismissQuickActions() {
    RecordingIndicatorManager.shared.hideQuickActions()
  }

  /// ⌘2 again or ✓: text in the field runs as the instruction; an empty field stops the
  /// recording and the spoken instruction is used.
  private func stopPromptOrRunTyped() {
    let typed = RecordingIndicatorManager.shared.typedPrompt
    if !typed.isEmpty, recording?.quickActionRan == false {
      runPromptInstruction(typed, source: "typed")
      return
    }
    stopRecordingAfterTailDelay()
  }

  /// Stops the recording through the normal path and remembers the entry's text so
  /// `performPrompting` sends it instead of the audio.
  private func runQuickAction(at index: Int) {
    if !Thread.isMainThread {
      DispatchQueue.main.async { [weak self] in self?.runQuickAction(at: index) }
      return
    }
    let actions = RecordingIndicatorManager.shared.quickActions
    guard actions.indices.contains(index) else { return }
    runPromptInstruction(
      actions[index].text, source: "entry \(index + 1)",
      isEdit: actions[index].isEdit)
  }

  /// Shared by list entries and the "Type a prompt…" field: the text replaces the audio
  /// as the Dictate Prompt instruction.
  /// `isEdit`: a quick action that edits a selection. Free typed text never is — it may compose.
  private func runPromptInstruction(_ text: String, source: String, isEdit: Bool = false) {
    guard recording?.quickActionRan == false else { return }
    guard activeMeetingSegment == nil else { return }
    let recordingPrompt = appState.recordingMode == .prompt || pendingRecordingMode == .prompt
    guard recordingPrompt else { return }
    recording?.quickActionRan = true
    recording?.quickActionInstruction = text
    recording?.isEditQuickAction = isEdit
    DebugLogger.log("QUICK-ACTIONS: Running \(source) (\(text.count) chars)")
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
      selector: #selector(promptModelChanged),
      name: .promptModelChanged,
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
      selector: #selector(chatWindowVisibilityChanged(_:)),
      name: .chatWindowVisibilityChanged,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(onboardingStatusDidChange),
      name: .onboardingStatusDidChange,
      object: nil
    )

    // Installed rather than posted as a notification because the caller has to *await* it: the meeting
    // chat cuts the pending audio chunk and waits for its transcript before sending a question about
    // the last few seconds. No-ops when no meeting is recording.
    LiveMeetingTranscriptStore.shared.pendingAudioFlush = { [weak self] in
      await self?.liveMeeting.flushPendingAudio()
    }
  }

  @objc private func onboardingStatusDidChange() {
    if let menu = statusItem?.menu { refreshMenu(menu) }
    applyMissingSetupWarningIfNeeded()
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
      prepareModelInBackground(ModelManager.shared, offlineModelType, label: "offline", reason: "launch", downloadIfMissing: false)
    }

    MLXModelPaths.removeRetiredWeights()
    let selectedPrompt = PromptModel.loadPromptModel(
      forKey: UserDefaultsKeys.selectedPromptModel,
      default: SettingsDefaults.selectedPromptModel)
    if let mlxType = selectedPrompt.localMLXModelType {
      // Not when the key-less fallback picked it: a fresh install has no key yet, and pulling
      // 2.3 GB before the user has even said whether they will add one is not our call. The
      // onboarding's offline path downloads it on purpose; otherwise the first use offers it.
      let keylessFallback = ModelSelectionReconciler.keylessOfflineFallback(
        key: UserDefaultsKeys.selectedPromptModel, current: selectedPrompt) != nil
      prepareModelInBackground(
        LocalLLMModelManager.shared, mlxType, label: "MLX", reason: "launch",
        downloadIfMissing: !keylessFallback)
    }

    // Setup shortcuts
    shortcuts.setup()
    fnDictationToggle.setup()
  }

  // MARK: - UI Updates (Single Method!)
  private func updateUI() {
    updateMenuBarIcon()
    if let menu = statusItem?.menu { refreshMenu(menu) }
    applyMissingSetupWarningIfNeeded()
    updateBlinking()
  }

  private func updateMenuBarIcon() {
    guard let button = statusItem?.button else { return }
    applyCurrentAppearance(to: button)

    // Show detailed chunk progress in tooltip during processing
    if case .processing(.processingChunks(let statuses, _)) = presentedState {
      let active = statuses.filter { $0 == .active }.count
      let done = statuses.filter { $0 == .completed }.count
      button.toolTip = String(localized: "Transcribing [\(done)/\(statuses.count)] - \(active) active")
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
    applyDevBadge(to: button)
  }

  /// Local Debug builds carry an orange "DEV" tag next to the icon, so it is obvious at a glance
  /// which binary owns the hotkeys when the installed release could be running too. A sidecar
  /// (worktree build next to the user's instance, no hotkeys) shows a purple "TEST" instead.
  private func applyDevBadge(to button: NSStatusBarButton) {
    guard AppConstants.isDevBuild else { return }
    let title = NSMutableAttributedString(
      string: button.title,
      attributes: [.font: NSFont.menuBarFont(ofSize: 0)])
    let badgeFont = NSFont.systemFont(ofSize: 9, weight: .heavy)
    title.append(NSAttributedString(
      string: (button.title.isEmpty ? "" : " ") + (AppConstants.isSidecarInstance ? "TEST" : "DEV"),
      attributes: [
        .font: badgeFont,
        .foregroundColor: AppConstants.isSidecarInstance ? NSColor.systemPurple : NSColor.systemOrange,
        .kern: 0.6,
        .baselineOffset: 1,
      ]))
    button.attributedTitle = title
    button.imagePosition = button.image == nil ? .noImage : .imageLeading
  }

  /// Brings every state-dependent row of the status menu up to date. Runs on every `updateUI` and
  /// when the menu opens, so it is the one place that decides what the rows say.
  private func refreshMenu(_ menu: NSMenu) {
    // Update status
    menu.item(withTag: MenuTag.status.rawValue)?.title = presentedStatusText

    let needsOnboarding = WelcomeWindowController.needsCompletion
    menu.item(withTag: MenuTag.finishSetup.rawValue)?.isHidden = !needsOnboarding
    menu.item(withTag: MenuTag.finishSetupSeparator.rawValue)?.isHidden = !needsOnboarding
    let pendingProposals = MCPProposalStore.shared.pending.count
    if let proposalsItem = menu.item(withTag: MenuTag.aiAppProposals.rawValue) {
      proposalsItem.isHidden = pendingProposals == 0
      proposalsItem.title = pendingProposals > 1
        ? String(localized: "Review \(pendingProposals) Changes from AI Apps…")
        : String(localized: "Review Change from AI App…")
    }
    menu.item(withTag: MenuTag.welcomeTour.rawValue)?.isHidden = needsOnboarding

    // One decision for titles and the central Stop row (`ModeAvailabilityRules`). When a row
    // already reads "Stop Dictate" / "Stop Read Aloud", a second generic Stop row is the same
    // action twice; the generic one stays for processing (the row has flipped back to start) and
    // for a live meeting with no nested recording. `.readAloudSelection` counts in every build so
    // that, in the App Store build (no Read Aloud row), a playing Chat Read Aloud keeps its
    // current behaviour (central Stop hidden) — DRIFT F5, preserved.
    let input = availabilityInput()
    let modedRows = Self.actionRows.filter { $0.mode != nil }
    var stopRows = modedRows.compactMap(\.mode)
    if !stopRows.contains(.readAloudSelection) { stopRows.append(.readAloudSelection) }  // F5
    let showCentralStop = ModeAvailabilityRules.showsCentralStop(input, presentRows: stopRows)
    menu.item(withTag: MenuTag.stop.rawValue)?.isHidden = !showCentralStop
    menu.item(withTag: MenuTag.stopSeparator.rawValue)?.isHidden = !showCentralStop

    // Action rows are always clickable: with `autoenablesItems` on, AppKit re-enables every row
    // whose target answers its action, so a computed `isEnabled` never reached the user. A press
    // that cannot start answers with a popup (`presentBlocked`) or is ignored.
    for row in modedRows {
      guard let mode = row.mode, let item = menu.item(withTag: row.tag.rawValue) else { continue }
      let shortcut = currentConfig[keyPath: row.shortcut]
      let isStop = ModeAvailabilityRules.availability(mode, input) == .stop
      item.title = StatusMenuTitle.render(
        base: String(localized: isStop ? (row.stopTitle ?? row.title) : row.title),
        isEnabled: shortcut.isEnabled, keyEquivalent: item.keyEquivalent,
        display: shortcut.displayString)
    }

    updateTranscriptionHistoryItems(menu)
  }

  /// Swaps the menu-bar icon for ⚠️ when no API key (any provider) and no usable transcription is
  /// configured.
  private func applyMissingSetupWarningIfNeeded() {
    let canTranscribe = TranscriptionModel.loadSelected().hasRequiredCredential
    let hasAnyKey = ProviderCredentials.anyChatCredentialConfigured

    // Handle special case when no API key (any provider) and no usable transcription is configured.
    // Tested against `canTranscribe`, not just the offline model: a user whose only setup is
    // OpenRouter or a self-hosted endpoint can dictate perfectly well, and used to be told to
    // "add an API key" anyway.
    if !hasAnyKey && !canTranscribe, let button = statusItem?.button {
      button.image = nil
      button.title = "⚠️"
      applyDevBadge(to: button)
      button.toolTip = String(localized: "Add an API key or use an offline model - click to configure")
    }
  }

  /// Rebuilds the "Recent Transcriptions" submenu and hides both history rows while there is
  /// nothing to show. Rebuilt on every menu update rather than on record: the store is written
  /// from a background queue, and the menu is cheap to regenerate (at most five rows).
  private func updateTranscriptionHistoryItems(_ menu: NSMenu) {
    let entries = TranscriptionHistoryStore.shared.entries
    menu.item(withTag: MenuTag.copyLastTranscription.rawValue)?.isHidden = entries.isEmpty
    reportDictationItem?.isHidden = entries.isEmpty
    reportDictationSeparator?.isHidden = entries.isEmpty

    // Drops away once the retained file is gone (recovered, or replaced by a newer cancellation).
    let hasCancelled = cancelledRecordingURL.map {
      FileManager.default.fileExists(atPath: $0.path)
    } ?? false
    menu.item(withTag: MenuTag.transcribeCancelledRecording.rawValue)?.isHidden = !hasCancelled
    updateRunAgainWithoutTemplateItem(in: menu)

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

  /// Shows the retry row while meeting audio waits to be transcribed. Scans the backlog folder, so it
  /// runs on menu open and on backlog changes rather than on every `updateUI`.
  private func updateMeetingBacklogItems(_ menu: NSMenu) {
    let count = MeetingAudioBacklog.totalCount()
    let retrying = liveMeeting.isRetryingBacklog
    let retryItem = menu.item(withTag: MenuTag.retryMeetingTranscription.rawValue)
    let showItem = menu.item(withTag: MenuTag.showMeetingAudio.rawValue)
    retryItem?.isHidden = count == 0 && !retrying
    showItem?.isHidden = count == 0
    retryItem?.isEnabled = !retrying
    retryItem?.title =
      retrying
      ? String(localized: "Retrying Meeting Transcription…")
      : String(localized: "Retry Meeting Transcription (\(count) parts)", comment: "Menu item; plural variation on the number of parts")
    retryItem?.toolTip =
      String(localized: "Audio from a meeting that couldn't be transcribed (for example while offline) is kept on this Mac until it is.")
  }

  @objc private func retryMeetingTranscription() {
    DebugLogger.log("MEETING-BACKLOG: Retry requested from the status menu")
    Task { @MainActor in await liveMeeting.retryBacklog(announce: true) }
  }

  @objc private func showMeetingAudioInFinder() {
    let stems = MeetingAudioBacklog.stemsWithBacklog()
    let folders = stems.map { MeetingAudioBacklog.directory(stem: $0) }
    guard !folders.isEmpty else { return }
    NSWorkspace.shared.activateFileViewerSelecting(folders)
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
      appState = appState.showSuccess(String(localized: "Transcription copied — press ⌘V to paste"))
    }
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
    // The list and its text field leave with the decision to stop, handing keyboard focus
    // back during the tail. A quick action sets its instruction before calling this.
    dismissQuickActions()
    // A pending meeting segment is cancelled even though the meeting itself is recording.
    if pendingMeetingSegment != nil || (pendingRecordingMode != nil && !appState.isRecording) {
      cancelPendingRecordingStart()
      return
    }
    if recording?.stopRequested == true {
      DebugLogger.log("AUDIO: Stop ignored — the recording is already being finalized")
      return
    }
    recording?.stopRequested = true
    if audioRecorder.hasRecentlyBeenSilent {
      DebugLogger.logAudio("AUDIO: Skipping tail-capture delay — recent audio was silent")
      handleStopRecordingResult(audioRecorder.stopRecording())
      return
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + Constants.audioTailCaptureDelay) { [weak self] in
      guard let self else { return }
      // ✕ / Fn-discard during the tail already stopped the recorder and marked it for discarding;
      // a second stop would find nothing running and let the audio escape the discard.
      if self.recording?.discardOnFinish == true { return }
      self.handleStopRecordingResult(self.audioRecorder.stopRecording())
    }
  }

  /// Arms a recording start. `.recording` / the meeting segment is applied only once the
  /// recorder reports that capture actually began (permission granted + `record()` succeeded).
  private func beginAudioCapture(
    mode: AppState.RecordingMode,
    meetingSegment: MeetingSegment? = nil,
    promptSelection: DictatePromptSelectionCapture? = nil,
    template: DictationTemplate? = nil
  ) {
    if mode == .transcription || mode == .prompt {
      pasteTargetAtRecordStart = Self.pasteTarget(of: NSWorkspace.shared.frontmostApplication)
      ownTextWindowAtRecordStart = Self.ownFocusedTextWindowNumber()
    }
    recording = RecordingIntent(target: meetingSegment.map { .meetingSegment($0) } ?? .mode(mode))
    recording?.promptSelection = promptSelection
    if mode == .prompt, meetingSegment == nil,
       Self.selectedPromptModel().dictatePromptUsesScreenshotSelection == false,
       let template {
      recording?.boundTemplate = template
      DebugLogger.log("DICTATION-TEMPLATE: \(template.displayName) started from its shortcut")
    }
    audioRecorder.startRecording()
  }

  private func cancelPendingRecordingStart() {
    recording = nil
    clipboardManager.discardRestorePoint()
    _ = audioRecorder.stopRecording()
  }

  private func handleStopRecordingResult(_ didStop: Bool) {
    guard !didStop else { return }
    DebugLogger.log("AUDIO: stopRecording found nothing running")
    recording = nil
    clipboardManager.discardRestorePoint()
    if case .recording = appState {
      appState = appState.finish()
    }
    if activeMeetingSegment != nil, !meetingSegmentIsProcessing {
      clearMeetingSegment()
    }
  }

  private static func audioDurationMs(of url: URL) -> Int {
    // sampleRate <= 0 used to return 0; Int(inf) would trap.
    guard let seconds = try? AudioDuration.avAudioFileSeconds(url),
          seconds.isFinite, seconds >= 0 else {
      return 0
    }
    return Int((seconds * 1000).rounded())
  }

  /// Everything the availability rules read, gathered once per decision.
  private func availabilityInput() -> ModeAvailabilityInput {
    ModeAvailabilityInput(
      appState: appState,
      isLiveMeetingActive: isLiveMeetingActive,
      activeMeetingSegment: activeMeetingSegment,
      pendingMeetingSegment: pendingMeetingSegment,
      pendingRecordingMode: pendingRecordingMode,
      currentJobMode: currentJob?.mode,
      isTTSPlaying: ttsPlayback.isPlaying,
      isOfflineMode: OfflineMode.isEnabled,
      readAloudUsesSystemVoice: ReadAloudPreferences.model.provider == .system,
      hasTranscriptionCredential: TranscriptionModel.loadSelected().hasRequiredCredential,
      hasPromptCredential: Self.selectedPromptModel().hasRequiredCredentialForDictatePrompt,
      hasImprovementCredential: Self.selectedImprovementModel()
        .hasRequiredCredentialForDictatePrompt,
      hasReadAloudCredential: ReadAloudPreferences.model.hasRequiredCredential,
      hasMeetingCredential: TranscriptionModel.loadSelectedForMeeting().hasRequiredCredential)
  }

  private func availability(_ action: ModeAction) -> ModeAvailability {
    ModeAvailabilityRules.availability(action, availabilityInput())
  }

  private static func selectedPromptModel() -> PromptModel {
    PromptModel.loadPromptModel(
      forKey: UserDefaultsKeys.selectedPromptModel, default: SettingsDefaults.selectedPromptModel)
  }

  private static func selectedImprovementModel() -> PromptModel {
    PromptModel.loadPromptModel(
      forKey: UserDefaultsKeys.selectedImprovementModel,
      default: SettingsDefaults.selectedImprovementModel)
  }

  /// Shows the popup for a blocked press: the exact texts the handlers used before the decision
  /// moved into `ModeAvailabilityRules`.
  private func presentBlocked(_ reason: BlockReason) {
    switch reason {
    case .busy:
      PopupNotificationWindow.showInfo("Busy – wait for the current run to finish.", title: "Busy")
    case .missingCredential(.transcription):
      let model = TranscriptionModel.loadSelected()
      PopupNotificationWindow.showError(verbatim: model.apiKeyRequiredMessage, title: .verbatim(model.credentialRequiredTitle))
    case .missingCredential(.meeting):
      let model = TranscriptionModel.loadSelectedForMeeting()
      PopupNotificationWindow.showError(verbatim: model.apiKeyRequiredMessage, title: .verbatim(model.credentialRequiredTitle))
    case .missingCredential(.prompt):
      PopupNotificationWindow.showError(
        verbatim: Self.selectedPromptModel().apiKeyRequiredMessageForDictatePrompt, title: "API Key Required")
    case .missingCredential(.improvement):
      PopupNotificationWindow.showError(
        verbatim: Self.selectedImprovementModel().apiKeyRequiredMessageForDictatePrompt,
        title: "API Key Required")
    case .missingCredential(.readAloud):
      PopupNotificationWindow.showError(
        verbatim: ReadAloudPreferences.model.apiKeyRequiredMessage, title: "API Key Required")
    case .offlineModeReadAloud:
      PopupNotificationWindow.showError(verbatim: OfflineMode.blockedMessageForReadAloud, title: "Read Aloud")
    case .meetingWhileBusy:
      PopupNotificationWindow.showInfo(
        "Finish the current recording or Read Aloud first, then start the meeting again.",
        title: "Meeting Not Started", customDisplayDuration: 5)
    }
  }

  @objc private func toggleTranscription() {
    let isMeeting = isLiveMeetingActive
    switch availability(.dictate) {
    case .stop:
      if isMeeting { DebugLogger.log("MEETING-SEGMENT: Stopping dictation segment") }
      stopRecordingAfterTailDelay()
    case .ignored(.otherMeetingSegmentActive):
      DebugLogger.logWarning("MEETING-SEGMENT: Another segment already active, ignoring dictation")
    case .cancelProcessing:
      cancelInFlightTranscription()
    case .cancelPendingStart:
      stopRecordingAfterTailDelay()
    case .blocked(.busy):
      // A run in progress is not a credential problem: answering a press during it with "API key
      // required" sent users to Settings for nothing. Ignore the press and say why.
      DebugLogger.log("DICTATE: Shortcut ignored — a run is still in progress (\(appState))")
      presentBlocked(.busy)
    case .blocked(let reason):
      presentBlocked(reason)
    case .start:
      let selectedModel = TranscriptionModel.loadSelected()
      if isMeeting {
        DebugLogger.log("MEETING-SEGMENT: Starting dictation segment during meeting")
      } else {
        // A dictation started seconds after an unpasted one is the user telling us the last
        // transcript was wrong. Recorded here, at the press, because the restart *is* the verdict.
        // Live-meeting dictation segments deliberately skip this: speaking repeatedly into a
        // meeting is normal use, not a retry, and would drown the signal.
        ContextLogger.shared.noteDictationStart(autoPasteAvailable: Self.autoPasteAvailable)
      }
      ConnectionPrewarmer.prewarm(for: selectedModel)
      dictateStreamingSession = DictateStreamingSession.makeIfEligible(speechService: speechService)
      if isMeeting {
        beginAudioCapture(mode: .transcription, meetingSegment: .dictation)
      } else {
        beginAudioCapture(mode: .transcription)
      }
    case .ignored:
      break
    }
  }

  @objc internal func togglePrompting() {
    togglePrompting(template: nil)
  }

  /// `template` nil is the generic Dictate Prompt shortcut, which never applies a template.
  /// A template shortcut passes the template it starts; stopping (this shortcut or the generic
  /// one) ignores it and just ends the recording.
  private func togglePrompting(template: DictationTemplate?) {
    let isMeeting = isLiveMeetingActive
    switch availability(.dictatePrompt) {
    case .stop:
      if isMeeting {
        DebugLogger.log("MEETING-SEGMENT: Stopping prompt segment")
        stopRecordingAfterTailDelay()
      } else {
        stopPromptOrRunTyped()
      }
    case .ignored(.otherMeetingSegmentActive):
      DebugLogger.logWarning("MEETING-SEGMENT: Another segment already active, ignoring prompt")
    case .cancelProcessing:
      cancelInFlightPrompt()
    case .cancelPendingStart:
      stopRecordingAfterTailDelay()
    case .blocked(.busy):
      DebugLogger.log("PROMPT-MODE: Shortcut ignored — a run is still in progress (\(appState))")
      presentBlocked(.busy)
    case .blocked(let reason):
      presentBlocked(reason)
    case .start:
      let promptModel = Self.selectedPromptModel()
      let logPrefix = isMeeting ? "MEETING-SEGMENT" : "PROMPT-MODE"
      let preparation = prepareDictatePromptSelection(logPrefix: logPrefix, model: promptModel)
      guard preparation.ready else { return }
      if isMeeting { DebugLogger.log("MEETING-SEGMENT: Starting prompt segment during meeting") }
      ConnectionPrewarmer.prewarm(for: promptModel)
      discardStreamingSession()  // prompt recordings never stream
      if isMeeting {
        if template != nil {
          DebugLogger.log("DICTATION-TEMPLATE: ignored during a meeting")
        }
        beginAudioCapture(
          mode: .prompt, meetingSegment: .prompt, promptSelection: preparation.selection)
      } else {
        beginAudioCapture(
          mode: .prompt, promptSelection: preparation.selection, template: template)
      }
    case .ignored:
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

  /// `detail` for a cancel signal: the phase, how long processing had run, and — on the
  /// streaming path — how many chunk transcriptions were still in flight (queue #8).
  private func cancelSignalDetail() -> [String: String] {
    var detail = ["phase": appState.signalPhase]
    if let processingMs = ContextLogger.shared.processingElapsedMs() {
      detail["processingMs"] = "\(processingMs)"
    }
    if let session = dictateStreamingSession {
      detail["pendingChunks"] = "\(session.pendingChunkCount)"
    }
    return detail
  }

  private func cancelInFlightTranscription() {
    ContextLogger.shared.logSignal(
      .cancelledWhileProcessing, mode: InteractionMode.transcription.rawValue, detail: cancelSignalDetail())
    let job = currentJob
    discardStreamingSession()
    speechService.cancelTranscription()
    job?.cancel()
    // Keep the audio instead of deleting it: a cancel is one keystroke and can be an accident,
    // and the recording is the only copy of what the user said. "Transcribe Cancelled Recording"
    // in the status menu turns an unrecoverable loss into one extra click.
    // Only for dictation: a long Dictate Prompt instruction also runs through the chunked
    // transcription states, and re-transcribing it would paste the instruction as dictation.
    if job?.mode == .transcription {
      retainCancelledRecording(job?.audioURL)
    } else {
      cleanupAudioFile(at: job?.audioURL)
    }
    transitionToIdleAndCleanup(cleanupAudioURL: nil, clearChunkStatuses: true)
    if let job {
      currentJob = nil
      processedAudioURLs.remove(job.audioURL)
    }
  }

  /// The last cancelled dictation, kept on disk so it can still be transcribed. Only ever one:
  /// this is an undo affordance, not a history, and dictations can be tens of megabytes.
  private var cancelledRecordingURL: URL?
  /// Last Dictate Prompt recording that applied a template, so the status menu can send the same
  /// audio through the ordinary system prompt. Offline Mode is used for patient notes, so the
  /// copy lives only in `lastTemplateRecordingDirectory` for at most ten minutes and is deleted
  /// on quit. A crash skips that, so launch clears the folder too.
  private var lastTemplateRecording: (url: URL, templateName: String)?
  private var lastTemplateRecordingExpiry: DispatchWorkItem?
  private static let lastTemplateRecordingLifetime: TimeInterval = 10 * 60
  /// Patient audio from a template dictation. This folder is inside the app's container / Library,
  /// never iCloud- or Desktop-synced, so the recording does not leave the Mac through a synced
  /// temp or Desktop folder.
  private static var lastTemplateRecordingDirectory: URL {
    AppSupportPaths.whisperShortcutApplicationSupportURL()
      .appendingPathComponent("LastTemplateRecording", isDirectory: true)
  }

  private func retainCancelledRecording(_ url: URL?) {
    guard let url, FileManager.default.fileExists(atPath: url.path) else { return }
    // Replace any older retained recording so at most one is ever held. Point at the new one first:
    // `cleanupAudioFile` refuses to delete whatever `cancelledRecordingURL` names.
    let previous = cancelledRecordingURL
    cancelledRecordingURL = url
    if let previous, previous != url {
      cleanupAudioFile(at: previous)
    }
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
    appState = .processing(.transcribing)
    startVoiceJob(mode: .transcription, audioURL: url) { job in
      await self.performTranscription(audioURL: url, job: job)
    }
  }

  /// Copies the recording a template just shaped into the app data directory, replacing any previous
  /// copy, and shows "Run Again Without Template" until the ten-minute lifetime (or quit) deletes it.
  private func retainLastTemplateRecording(from audioURL: URL, templateName: String?) {
    let directory = Self.lastTemplateRecordingDirectory
    AppSupportPaths.ensureDirectoryExists(directory)
    let ext = audioURL.pathExtension
    var destination = directory.appendingPathComponent("recording")
    if !ext.isEmpty { destination.appendPathExtension(ext) }
    // Staging stays in the same unsynced folder: a crash between copy and replace must not leave
    // patient audio in the temp directory, and the launch sweep removes the staging file.
    let staging = directory
      .appendingPathComponent("staging-\(UUID().uuidString)")
      .appendingPathExtension(ext.isEmpty ? "tmp" : ext)
    do {
      try FileManager.default.copyItem(at: audioURL, to: staging)
      if FileManager.default.fileExists(atPath: destination.path) {
        _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging)
      } else {
        try FileManager.default.moveItem(at: staging, to: destination)
      }
    } catch {
      try? FileManager.default.removeItem(at: staging)
      DebugLogger.logError(error, context: "DICTATION-TEMPLATE: Could not keep the recording to run again")
      return
    }
    if let previous = lastTemplateRecording?.url, previous != destination {
      try? FileManager.default.removeItem(at: previous)
    }
    let trimmed = templateName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let name = trimmed.isEmpty ? String(localized: "Template") : trimmed
    lastTemplateRecording = (destination, name)
    scheduleLastTemplateRecordingExpiry()
    updateRunAgainWithoutTemplateVisibility()
  }

  private func scheduleLastTemplateRecordingExpiry() {
    lastTemplateRecordingExpiry?.cancel()
    let work = DispatchWorkItem { [weak self] in
      self?.expireLastTemplateRecording()
    }
    lastTemplateRecordingExpiry = work
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.lastTemplateRecordingLifetime, execute: work)
  }

  private func expireLastTemplateRecording() {
    discardLastTemplateRecording()
    updateRunAgainWithoutTemplateVisibility()
  }

  /// Deletes the replay copy and forgets it. Does not touch the menu; callers that should hide
  /// the item update visibility themselves. Also the quit path, where the menu is going away.
  /// A crash never reaches this, so launch removes whatever is still in the folder.
  private func discardLastTemplateRecording() {
    lastTemplateRecordingExpiry?.cancel()
    lastTemplateRecordingExpiry = nil
    if let url = lastTemplateRecording?.url {
      try? FileManager.default.removeItem(at: url)
    }
    lastTemplateRecording = nil
  }

  /// Clears every file in `lastTemplateRecordingDirectory`. Called once setup has finished, because
  /// `cleanup()` does not run after a crash or force-quit and patient audio must not sit there
  /// until some later quit. Logged only when a file was actually removed, and never with its path
  /// or name — those logs are not a place for a recording of a patient note.
  private func removeLeftoverTemplateRecordings() {
    let directory = Self.lastTemplateRecordingDirectory
    let fm = FileManager.default
    guard let contents = try? fm.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
    ) else { return }
    var removed = false
    for url in contents {
      if (try? fm.removeItem(at: url)) != nil {
        removed = true
      }
    }
    if removed {
      DebugLogger.log("DICTATION-TEMPLATE: removed a leftover template recording")
    }
  }

  private func updateRunAgainWithoutTemplateVisibility() {
    guard let menu = statusItem?.menu else { return }
    updateRunAgainWithoutTemplateItem(in: menu)
  }

  private func updateRunAgainWithoutTemplateItem(in menu: NSMenu) {
    guard let item = menu.item(withTag: MenuTag.runAgainWithoutTemplate.rawValue) else { return }
    let saved = lastTemplateRecording
    let exists = saved.map { FileManager.default.fileExists(atPath: $0.url.path) } ?? false
    item.isHidden = !exists
    if exists, let name = saved?.templateName {
      item.toolTip = String(
        localized: "Runs your last dictation again with your Dictate Prompt system prompt instead of “\(name)”. Select the formatted text first to replace it.")
    }
  }

  /// Sends the saved template recording through Dictate Prompt with no template and no selection,
  /// so the pasted result replaces whatever the user selected in the target app.
  @objc private func runAgainWithoutTemplate() {
    guard !appState.isBusy else {
      PopupNotificationWindow.showInfo(
        "Finish the current recording first, then try again.", title: "Busy")
      return
    }
    guard let saved = lastTemplateRecording,
          FileManager.default.fileExists(atPath: saved.url.path) else {
      discardLastTemplateRecording()
      updateRunAgainWithoutTemplateVisibility()
      return
    }
    // A second file, not the retained one: the audio job deletes its input when it finishes, and
    // that must not be the copy the menu still offers. Same unsynced folder — a practice note
    // must not pass through the temp directory. The name is a UUID so a log of the job's file
    // cannot carry the template name.
    let directory = Self.lastTemplateRecordingDirectory
    AppSupportPaths.ensureDirectoryExists(directory)
    let ext = saved.url.pathExtension
    var copy = directory.appendingPathComponent(UUID().uuidString)
    if !ext.isEmpty { copy.appendPathExtension(ext) }
    do {
      try FileManager.default.copyItem(at: saved.url, to: copy)
    } catch {
      DebugLogger.logError(error, context: "DICTATION-TEMPLATE: Could not copy the recording to run again")
      return
    }
    DebugLogger.log("DICTATION-TEMPLATE: Running the last template dictation again without its template")
    processedAudioURLs.insert(copy)
    appState = .processing(.prompting)
    startVoiceJob(mode: .prompt, audioURL: copy) { job in
      await self.performPrompting(audioURL: copy, job: job, selection: nil)
    }
  }

  /// Cancels a running Dictate Prompt. Reached from both the toggle shortcut and the Stop menu
  /// item, which is why it is a method rather than two copies.
  ///
  /// Passing the URL is what makes the cancellation stick: `transitionToIdleAndCleanup` drops
  /// `currentJob`, so a reply that is already in flight is recognised as stale by `runAudioJob` and
  /// dropped instead of being pasted into whatever the user has since focused. It also removes the
  /// recording.
  private func cancelInFlightPrompt() {
    ContextLogger.shared.logSignal(
      .cancelledWhileProcessing, mode: InteractionMode.prompt.rawValue, detail: cancelSignalDetail())
    let job = currentJob
    speechService.cancelPrompt()
    job?.cancel()
    transitionToIdleAndCleanup(cleanupAudioURL: job?.audioURL)
  }

  /// True when any transcription pipeline phase is active (single request or chunked).
  private var isTranscriptionProcessing: Bool { appState.isTranscriptionPipelineProcessing }

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
    switch availability(.liveMeeting) {
    case .blocked(.meetingWhileBusy):
      DebugLogger.logWarning("LIVE-MEETING: Cannot start - app is busy")
      presentBlocked(.meetingWhileBusy)
      return
    case .blocked(let reason):
      presentBlocked(reason)
      return
    case .stop:
      return  // callers already guard against a running meeting
    default:
      break
    }

    guard liveMeeting.start(resuming: resuming) else { return }
    appState = .recording(.liveMeeting)

    ChatWindowManager.shared.show(suppressFocusLossClose: true)
    // `show()` posts the visibility change, but the session had no recorder yet when it fired.
    liveMeeting.setFastChunking(ChatWindowManager.shared.isWindowOpen())
  }

  /// At launch: if the previous run died (or was quit by a script) while a meeting was recording,
  /// either pick the meeting up again or tell the user it stopped. See `LiveMeetingRecordingMarker`.
  func resumeInterruptedMeetingIfNeeded() {
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
      guard let self else { return }
      // A dev sidecar shares the container with the main build and must never take over its marker.
      if AppConstants.isSidecarInstance { return }
      let marker = LiveMeetingRecordingMarker.read()
      let transcriptExists = marker.map {
        FileManager.default.fileExists(
          atPath: MeetingListService.transcriptURL(forStem: $0.payload.stem).path)
      } ?? false
      let action = LiveMeetingRecordingMarker.launchAction(
        payload: marker?.payload, lastAlive: marker?.lastAlive, now: Date(),
        transcriptExists: transcriptExists)
      // A fresh heartbeat from a pid that is still running is another instance recording right
      // now, not a crash to recover. Only checked when fresh: after a restart the old pid may have
      // been reused by an unrelated process, and a stale marker must still be handled.
      if case .resume = action, let payload = marker?.payload,
         LiveMeetingRecordingMarker.ownerIsAlive(pid: payload.pid) {
        DebugLogger.log(
          "LIVE-MEETING-MARKER: Marker belongs to running process \(payload.pid), leaving it alone")
        return
      }
      // A fresh session writes its own marker, so the old one always goes.
      LiveMeetingRecordingMarker.clear()

      switch action {
      case .none:
        DebugLogger.log("LIVE-MEETING-MARKER: Nothing to recover at launch")
      case .resume(let stem):
        DebugLogger.log("LIVE-MEETING-MARKER: Resuming interrupted meeting \(stem)")
        if self.resumeMeeting(stem: stem) {
          PopupNotificationWindow.showInfo(
            "WhisperShortcut restarted while your meeting was being recorded, so it picked up where it left off. Only the few seconds of the restart itself are missing.",
            title: "Meeting Recording Resumed", customDisplayDuration: 8)
        } else {
          DebugLogger.logWarning("LIVE-MEETING-MARKER: Could not resume \(stem), notifying instead")
          self.showMeetingInterruptedNotice()
        }
      case .notifyInterrupted(let stem):
        DebugLogger.log("LIVE-MEETING-MARKER: Meeting \(stem) was interrupted, notifying")
        self.showMeetingInterruptedNotice()
      }
    }
  }

  private func showMeetingInterruptedNotice() {
    PopupNotificationWindow.showInfo(
      "WhisperShortcut was quit while your meeting was being recorded, so the recording stopped. The transcript up to that point is saved. To continue the meeting, open it and click Resume.",
      title: "Meeting Recording Interrupted", customDisplayDuration: 10)
  }

  /// Rehydrates the live store from disk (as the Resume button does) and restarts recording.
  /// Returns true when the meeting is recording afterwards.
  private func resumeMeeting(stem: String) -> Bool {
    guard !isLiveMeetingActive, !appState.isBusy else { return false }
    let transcriptURL = MeetingListService.transcriptURL(forStem: stem)
    let transcript = (try? String(contentsOf: transcriptURL, encoding: .utf8)) ?? ""
    let summary = (try? String(
      contentsOf: MeetingListService.summaryURL(transcriptFileURL: transcriptURL),
      encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    LiveMeetingTranscriptStore.shared.rehydrateForResume(
      stem: stem,
      chunks: LiveMeetingTranscriptStore.parseTranscript(transcript),
      summary: summary,
      notes: MeetingListService.shared.loadNotes(forStem: stem))
    startLiveMeeting(resuming: true)
    return isLiveMeetingActive
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

  @objc private func reportLastDictation() {
    guard let entry = TranscriptionHistoryStore.shared.mostRecent else {
      DebugLogger.logWarning("DICTATION-REPORT: Requested but history is empty")
      return
    }
    let details = DictationReport.body(
      entry: entry, glossaryTerms: speechService.glossaryTermsForReport(),
      offlineMode: OfflineMode.isEnabled)
    DictationReportWindowController.shared.show(details: details)
  }

  @objc private func rateApp() {
    NSWorkspace.shared.open(ReviewPrompter.writeReviewURL)
    DebugLogger.log("REVIEW: User opened App Store write-review page from menu")
  }

  @objc private func quitApp() {
    // A deliberate Quit must not auto-resume the meeting on the next launch.
    LiveMeetingRecordingMarker.markUserQuit()
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
    retryActionTitle: LocalizedStringResource = "Retry",
    dismissAction: (() -> Void)? = nil,
    topUpURL: URL? = nil,
    changesAppState: Bool = true
  ) {
    if dismissProcessingFirst {
      PopupNotificationWindow.dismissProcessing()
    }
    if changesAppState {
      appState = appState.showError(shortTitle)
    }
    PopupNotificationWindow.showError(verbatim: message ?? shortTitle, title: .verbatim(shortTitle), retryAction: retryAction, retryActionTitle: retryActionTitle, dismissAction: dismissAction, topUpURL: topUpURL)
  }

  private static func telemetryArea(for mode: AppState.RecordingMode) -> TelemetryArea {
    switch mode {
    case .transcription: return .dictation
    case .prompt: return .prompt
    case .liveMeeting: return .meeting
    }
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
  @MainActor
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
      TelemetryService.shared.failed(Self.telemetryArea(for: mode), error: error)

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
        case .transcription: operationName = String(localized: "Transcription")
        case .prompt: operationName = String(localized: "Prompt")
        case .liveMeeting: operationName = String(localized: "Live meeting")
        }
        shortTitle = String(localized: "\(operationName) Error", comment: "Popup title; the argument is the kind of operation that failed")
        errorMessage = SpeechErrorFormatter.formatForUser(error)
      }

      // Determine if error is retryable
      // Includes model-preparation failures: the audio is kept and Retry offered, but nothing
      // retries them automatically (that stays `TranscriptionError.isRetryable`).
      let isRetryable = error.offersManualRetry
      
      // Define retry action
      let isServerError = transcriptionError?.isServerOrUnavailable ?? false
      let retryAction: (() -> Void)? = isRetryable ? { [weak self] in
        guard let self = self else { return }
        Task { @MainActor in
          // Brief delay before retrying server errors to give the API time to recover
          if isServerError {
            DebugLogger.log("RETRY: Waiting 3s before retrying after server error...")
            try? await Task.sleep(nanoseconds: 3_000_000_000)
          }
          // The error popup can stay open for a long time. If the user has started a recording
          // (or another run) since, a retry must not stomp on it: the state machine would be
          // overwritten mid-recording. The audio stays on disk for a later attempt. The error
          // state itself (`.feedback`) is not busy, so a plain Retry click still works.
          guard !self.appState.isBusy else {
            DebugLogger.logWarning("RETRY: Ignored — another run is in progress (\(self.appState))")
            PopupNotificationWindow.showInfo(
              "Finish the current recording first, then try again.", title: "Busy")
            return
          }
          // `runAudioJob`'s catch tail drops the job after the popup is shown. A retry is a new
          // job, the same way `transcribeCancelledRecording` starts one.
          self.processedAudioURLs.insert(audioURL)
          DebugLogger.log("RETRY: Re-running \(mode) for \(audioURL.lastPathComponent)")
          switch mode {
          case .transcription:
            self.appState = .processing(.transcribing)
            self.startVoiceJob(mode: .transcription, audioURL: audioURL) { job in
              await self.performTranscription(audioURL: audioURL, job: job)
            }
          case .prompt:
            self.appState = .processing(.prompting)
            // Same selection as the first attempt; none on record means compose, never a fresh
            // pasteboard read.
            let inputs = self.finishedPromptInputs[audioURL]
            self.startVoiceJob(mode: .prompt, audioURL: audioURL) { job in
              await self.performPrompting(
                audioURL: audioURL, job: job, instruction: inputs?.quickActionInstruction,
                isEditQuickAction: inputs?.isEditQuickAction ?? false,
                templateInstruction: inputs?.templateInstruction,
                templateName: inputs?.templateName,
                selection: inputs?.selection)
            }
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
    /// True when the result carries a warning the popup has to show even though the pill already
    /// confirmed the paste (Dictate Prompt's word check). Read after `produce` returns.
    var resultNeedsPopup: () -> Bool = { false }
    /// Transcription dismisses the processing popup before presenting its result; prompting never did.
    var dismissesProcessingBeforeResult = false
    /// On cancellation transcription routes through `transitionToIdleAndCleanup` (which also
    /// dismisses the popup, clears chunk state, drops the URL and removes the file); prompting
    /// finishes the state machine and cleans the file itself.
    var cancelsViaTransitionToIdle = false

    /// The `InteractionLogEntry.mode` this job writes, so an outcome signal can point at the right
    /// row. Nil for modes that log no interaction (live meeting).
    var interactionLogMode: String? {
      switch mode {
      case .transcription: return InteractionMode.transcription.rawValue
      case .prompt: return InteractionMode.prompt.rawValue
      case .liveMeeting: return nil
      }
    }
  }

  /// The plain cancellation tail: finish the state machine, drop the URL, remove the file. Shared
  /// by the prompt pipeline, which handles a cancelled recording.
  /// Transcription does not use it — it routes through `transitionToIdleAndCleanup` instead, which
  /// additionally clears chunk state.
  @MainActor
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
  /// cancellation, staleness and failure. `afterCopy` runs after the clipboard write and
  /// auto-paste (logging and history), so it cannot delay the paste.
  @MainActor
  private func runAudioJob(
    _ spec: AudioJobSpec,
    audioURL: URL,
    job: VoiceJob?,
    produce: () async throws -> String,
    afterCopy: (String) async -> Void = { _ in }
  ) async {
    // Meeting segments run without a job: they can't be cancelled or superseded this way.
    let duringMeeting = job == nil
    do {
      let result = try await produce()

      // A shortcut press during processing cancels the job (the cancel paths drop `currentJob`),
      // but a result already in flight can still arrive afterwards — drop it instead of pasting a
      // cancelled result out of idle. Same staleness check as the error path below.
      let wasCancelled: Bool = await MainActor.run {
        if self.isSuperseded(job) {
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
      if spec.mode == .transcription, !duringMeeting {
        await self.recordDictatedWritingSample(result)
      }
      let didAutoPaste = await self.autoPasteIfEnabled(logMode: spec.interactionLogMode)
      await afterCopy(result)

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
          // dictation outside one shows nothing but the pasted text. A popup the result needs
          // (the Offline "Not in your dictation" warning) still shows during a meeting.
          if spec.resultNeedsPopup() || (!RecordingIndicatorManager.shared.isVisible && !duringMeeting) {
            spec.presentResult(result, modelInfo, nil)
          }
        } else {
          spec.presentResult(result, modelInfo, PasteTargetPolicy.copiedHint)
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
        if let job, self.currentJob === job {
          self.currentJob = nil
        }
        self.processedAudioURLs.remove(audioURL)
      }

      cleanupAudioFile(at: audioURL)
    } catch {
      // Nothing will be pasted, so drop the remembered clipboard — restoring it during some
      // later job would silently undo whatever the user copied in the meantime.
      await MainActor.run { self.clipboardManager.discardRestorePoint() }
      if Self.isCancellation(error) {
        if isSuperseded(job) {
          // The cancel path already reset the state machine and the popups. Touching `appState`
          // now could finish a recording the user started since; only this job's file is left.
          DebugLogger.log("CANCELLATION: \(spec.logLabel) task ended after its job was cancelled")
          processedAudioURLs.remove(audioURL)
          cleanupAudioFile(at: audioURL)
        } else if duringMeeting {
          DebugLogger.log("CANCELLATION: \(spec.logLabel) task was cancelled (\(type(of: error)))")
          await MainActor.run {
            self.clearMeetingSegment()
            self.processedAudioURLs.remove(audioURL)
          }
          cleanupAudioFile(at: audioURL)
        } else if spec.cancelsViaTransitionToIdle {
          DebugLogger.log("CANCELLATION: \(spec.logLabel) task was cancelled (\(type(of: error)))")
          // Also dismisses the popup, clears chunk state, drops the job and removes the file.
          await MainActor.run {
            self.transitionToIdleAndCleanup(cleanupAudioURL: audioURL, clearChunkStatuses: true)
          }
        } else {
          // Cancelled from inside SpeechService rather than by a cancel path: the job is over.
          if let job, currentJob === job { currentJob = nil }
          await cancelAudioJob(logLabel: spec.logLabel, error: error, audioURL: audioURL)
        }
        return
      }

      let isStale: Bool = await MainActor.run {
        if self.isSuperseded(job) {
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
        DebugLogger.logError("MEETING-SEGMENT: \(spec.logLabel) failed: \(error.logDescription)")
        await MainActor.run {
          self.clearMeetingSegment()
          self.processedAudioURLs.remove(audioURL)
          PopupNotificationWindow.showError(
            verbatim: SpeechErrorFormatter.formatForUser(error), title: .verbatim(spec.errorTitle))
        }
        cleanupAudioFile(at: audioURL)
      } else {
        await handleProcessingError(error: error, audioURL: audioURL, mode: spec.mode)
        await MainActor.run {
          self.chunkStatuses = []
          if let job, self.currentJob === job {
            self.currentJob = nil
          }
          self.processedAudioURLs.remove(audioURL)
        }
      }
    }
  }

  /// `job` is nil for a live-meeting segment.
  @MainActor
  private func performTranscription(audioURL: URL, job: VoiceJob?) async {
    let duringMeeting = job == nil
    // Capture the session but leave the property set: cancelInFlightTranscription must
    // still be able to cancel it while we await the chunk transcripts below. Cleared on
    // exit (identity-checked so a newer recording's session is never clobbered).
    let streamingSession: DictateStreamingSession? = await MainActor.run { self.dictateStreamingSession }
    let recordingPeakDb: Float = await MainActor.run { self.audioRecorder.lastPeakPowerDb }
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
      backendTag = transcriptionModelForCapture.offlineModelType?.engine == .parakeet ? "parakeet" : "whisper"
    } else if transcriptionModelForCapture.isOpenAI {
      backendTag = "openai"
    } else if transcriptionModelForCapture == .selfHostedTranscription {
      backendTag = "self-hosted"
    } else if transcriptionModelForCapture == .openRouterTranscription {
      backendTag = "openrouter"
    } else {
      backendTag = "gemini"
    }
    let captureTask: Task<String?, Never>? = duringMeeting ? nil : Task.detached {
      [audioURL, backendTag, model = transcriptionModelForCapture.rawValue] in
      ContextLogger.shared.captureDictationAudio(
        from: audioURL,
        backend: backendTag,
        transcriptionModel: model
      )
    }
    var pendingAudioRef: String?
    // Taken before transcription starts, so strips logged by this dictation (and not an earlier
    // one) can be attached to its history entry.
    let dictationStart = Date()
    var audioRefCommitted = false
    defer {
      if let ref = pendingAudioRef, !audioRefCommitted {
        ContextLogger.shared.deleteAudioSample(named: ref)
      }
    }
    let spec = AudioJobSpec(
      mode: .transcription,
      logLabel: "Transcription",
      errorTitle: String(localized: "Transcription Error"),
      modelInfo: { await self.speechService.getTranscriptionModelInfo() },
      copyResult: { self.clipboardManager.copyTranscriptionToClipboard(text: $0) },
      presentResult: { text, info, title in
        if let title {
          PopupNotificationWindow.showTranscriptionResponse(text, modelInfo: info, title: .verbatim(title))
        } else {
          PopupNotificationWindow.showTranscriptionResponse(text, modelInfo: info)
        }
      },
      successMessage: { $0 ? String(localized: "Transcription copied to clipboard") : PasteTargetPolicy.copiedHint },
      dismissesProcessingBeforeResult: true,
      cancelsViaTransitionToIdle: true)

    await runAudioJob(
      spec,
      audioURL: audioURL,
      job: job,
      produce: {
        let stopTime = CFAbsoluteTimeGetCurrent()
        let transcript: String
        if let streamed = try await streamingSession?.finalTranscript() {
          let waitMs = (CFAbsoluteTimeGetCurrent() - stopTime) * 1000
          DebugLogger.logSpeech(
            "SPEED: STREAMING-DICTATE: Transcript ready \(String(format: "%.0f", waitMs))ms after stop")
          transcript = streamed
        } else {
          // Single-shot: non-Gemini model, no rotation happened, or a chunk failed —
          // transcribe the merged WAV exactly as before streaming existed.
          transcript = try await NoSpeechContext.run(
            duringMeeting ? .meetingSegment : .dictation, audioURL: audioURL, peakDb: recordingPeakDb
          ) {
            try await self.speechService.transcribe(audioURL: audioURL, cancellable: !duringMeeting)
          }
        }
        // Offline engines write spoken "Doppelpunkt" / "neuer Absatz" out as words. Applied to the
        // whole transcript, after streamed chunks are joined, so a command at a chunk edge still
        // attaches to the word before it.
        return transcriptionModelForCapture.isOffline
          ? SpokenPunctuation.apply(to: transcript) : transcript
      },
      afterCopy: { result in
        // Recorded regardless of the interaction-logging toggle (that one gates *persistence*
        // inside the store) so "Copy Last Transcription" always works for the current session.
        let modelDisplayName = await self.speechService.getTranscriptionModelInfo()
        TranscriptionHistoryStore.shared.record(
          result, mode: "Dictation", transcriptionModel: transcriptionModelForCapture.rawValue,
          transcriptionModelName: modelDisplayName,
          glossaryEchoRemoved: self.speechService.glossaryEchoStrips(since: dictationStart))
        pendingAudioRef = await captureTask?.value
        audioRefCommitted = true
        ContextLogger.shared.logTranscription(
          result: result,
          model: modelDisplayName,
          audioRef: pendingAudioRef,
          transcriptionModel: transcriptionModelForCapture.rawValue
        )
      })
    if pendingAudioRef == nil {
      pendingAudioRef = await captureTask?.value
    }
  }

  /// `job` is nil for a live-meeting segment.
  @MainActor
  /// `selection` is the capture taken for this recording; nil means nothing was selected (or the
  /// selection is read from a screenshot), and the turn runs as compose.
  private func performPrompting(
    audioURL: URL,
    job: VoiceJob?,
    instruction: String? = nil,
    isEditQuickAction: Bool = false,
    templateInstruction: String? = nil,
    templateName: String? = nil,
    selection: DictatePromptSelectionCapture?
  ) async {
    // Words of the on-device reply the dictation does not contain (Offline Mode only). They
    // replace the result popup with a warning; the pasted text is never touched.
    var undictatedWords: [String] = []
    var spec = AudioJobSpec(
      mode: .prompt,
      logLabel: "Prompt",
      errorTitle: String(localized: "Dictate Prompt Error"),
      modelInfo: { self.speechService.getPromptModelInfo() },
      copyResult: { self.clipboardManager.copyToClipboard(text: $0) },
      presentResult: { text, info, title in
        if !undictatedWords.isEmpty {
          PopupNotificationWindow.showUndictatedWords(undictatedWords, pasteHint: title)
        } else if let title {
          PopupNotificationWindow.showPromptResponse(text, modelInfo: info, title: .verbatim(title))
        } else {
          PopupNotificationWindow.showPromptResponse(text, modelInfo: info)
        }
      },
      successMessage: { $0 ? String(localized: "AI response copied to clipboard") : PasteTargetPolicy.copiedHint })
    spec.resultNeedsPopup = { !undictatedWords.isEmpty }

    await runAudioJob(
      spec,
      audioURL: audioURL,
      job: job,
      produce: {
        // Bounded by the copy poll (≤ 0.5 s after the shortcut press), so in practice already
        // resolved by the time a recording has been spoken and stopped.
        let selectedText = await selection?.value()
        let result = try await self.speechService.executePrompt(
          audioURL: audioURL, mode: .togglePrompting, instruction: instruction,
          isEditQuickAction: isEditQuickAction, templateInstruction: templateInstruction,
          selectedText: selectedText)
        undictatedWords = self.speechService.lastPromptUnsupportedWords
        if self.speechService.lastPromptReplyTruncated {
          // The text is still pasted; the user just has to know its end may be missing.
          await MainActor.run { PopupNotificationWindow.showReplyTruncated() }
        }
        return result
      },
      afterCopy: { _ in
        // Keep the audio only when a template actually replaced the system prompt. A meeting
        // segment has no job, and a selection or a quick action keeps today's prompt.
        guard templateInstruction != nil, job != nil, self.speechService.lastPromptAppliedTemplate else {
          return
        }
        self.retainLastTemplateRecording(from: audioURL, templateName: templateName)
      })
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
        prepareModelInBackground(ModelManager.shared, offlineModelType, label: "offline", reason: "selection")
      }
    }
  }

  @objc private func promptModelChanged(_ notification: Notification) {
    guard let newModel = notification.object as? PromptModel,
          let mlxType = newModel.localMLXModelType
    else { return }
    prepareModelInBackground(LocalLLMModelManager.shared, mlxType, label: "MLX", reason: "selection")
  }

  /// Loads an offline model in the background, downloading it first only when asked to.
  ///
  /// `downloadIfMissing` is the difference between the two callers: choosing a model is a request
  /// for it, so that path fetches it; starting the app is not, so that path only warms what is
  /// already on disk. Failures are logged and not surfaced — nobody asked for this to happen right
  /// now, and the dictation path reports properly if the model is still missing when it matters.
  /// Downloads (if allowed) and loads an on-device model without blocking anything.
  ///
  /// Silent on purpose: the user did not ask for a multi-gigabyte download to start right now,
  /// and the dictation, Dictate Prompt and Chat paths all report progress properly when the
  /// model is still missing at the moment it actually matters. WhisperKit at launch passes
  /// `downloadIfMissing: false` for the same reason; MLX always fetches because both of its
  /// callers are a deliberate selection.
  private func prepareModelInBackground<M: DownloadableModel>(
    _ store: ModelStore<M>, _ type: M, label: String, reason: String, downloadIfMissing: Bool = true
  ) {
    Task { @MainActor in
      let alreadyThere = store.isModelAvailable(type)
      guard alreadyThere || downloadIfMissing else {
        DebugLogger.log(
          "MENU-BAR: \(type.displayName) is selected but not downloaded — leaving it that way "
            + "(\(reason)); the next dictation will offer to fetch it")
        return
      }
      DebugLogger.log(
        "MENU-BAR: Preparing \(label) model \(type.displayName) in background (\(reason), "
          + "\(alreadyThere ? "downloaded" : "needs download"))")
      do {
        try await store.ensureReady(type)
        DebugLogger.logSuccess("MENU-BAR: \(label) model \(type.displayName) ready")
      } catch is CancellationError {
        DebugLogger.log("MENU-BAR: \(label) prepare cancelled for \(type.displayName)")
      } catch {
        DebugLogger.logError(
          "MENU-BAR: Could not prepare \(label) \(type.displayName): \(error.localizedDescription)")
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
      if currentJob?.audioURL == url {
        currentJob = nil
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
    if let url {
      let forget = {
        _ = self.finishedPromptInputs.removeValue(forKey: url)
      }
      if Thread.isMainThread {
        forget()
      } else {
        DispatchQueue.main.async(execute: forget)
      }
    }
    guard let url = url, FileManager.default.fileExists(atPath: url.path) else { return }
    // The retained cancelled recording outlives its job on purpose (see `retainCancelledRecording`);
    // the cancelled job's own cleanup tail must not delete it. `cancelledRecordingURL` is main-only;
    // the off-main callers (live-meeting chunks) never hold that URL.
    if Thread.isMainThread, url == cancelledRecordingURL {
      DebugLogger.logDebug("Keeping retained cancelled recording: \(url.lastPathComponent)")
      return
    }
    do {
      try FileManager.default.removeItem(at: url)
      DebugLogger.logDebug("Cleaned up audio file: \(url.lastPathComponent)")
    } catch {
      DebugLogger.logWarning("Failed to clean up audio file \(url.lastPathComponent): \(error.logDescription)")
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
    switch availability(.readAloudChat) {
    case .stop:
      if isTTSRunning {
        finishReadAloudSession()
      } else {
        // With progressive playback, audio can already be playing while later chunks are still
        // being synthesized, so Stop has to kill the network work too — unless the stream is
        // already closed, in which case there is nothing left to cancel.
        finishReadAloudSession(cancelNetworkWork: !ttsPlayback.isStreamClosed)
      }
      return true
    case .ignored(.otherProcessing):
      DebugLogger.logWarning("READ-ALOUD: ignoring — another operation is processing")
      return true
    default:
      return false
    }
  }

  /// Drives the Read Aloud pipeline: sets app state, posts `ttsDidStart`, and runs the producer,
  /// which streams synthesized chunks back through the sink it is handed. Playback therefore starts
  /// on the first chunk instead of after the merge; the producer's returned `Data` is only used as
  /// a fallback for producers that never emit a chunk. The producer call runs inside
  /// `currentReadAloudTask` so a subsequent Stop trigger can cancel it mid-flight.
  /// - Parameter text: What is about to be spoken, before any Smart Rewrite; its length seeds the
  ///   scrubber's provisional total (`TTSPlaybackSession.begin(expectedCharacters:)`).
  private func beginReadAloudProcessing(
    text: String,
    producer: @escaping (_ onChunkReady: @escaping (Data, Int, Int) -> Void) async throws -> Data
  ) {
    appState = .processing(.ttsProcessing)
    NotificationCenter.default.post(name: .ttsDidStart, object: nil)
    TelemetryService.shared.started(.readAloud)
    let playbackGeneration = ttsPlayback.begin(expectedCharacters: text.count)

    currentReadAloudTask = Task { [weak self] in
      do {
        // `ChunkTTSService` invokes this on the main actor, in playback order.
        let audioData = try await producer({ [weak self] pcm, index, total in
          self?.ttsPlayback.enqueue(pcm, index: index, totalChunks: total, generation: playbackGeneration)
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
        DebugLogger.logError("READ-ALOUD-ERROR: \(error.logDescription)")
        TelemetryService.shared.failed(.readAloud, error: error)
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
    beginReadAloudProcessing(text: trimmedText) { [speechService] onChunkReady in
      try await speechService.readProseAloud(trimmedText, onChunkReady: onChunkReady)
    }
  }

  /// Ensures the permission Dictate Prompt needs for the current selection-capture mode is granted,
  /// and starts capturing this recording's selection. In screenshot-selection mode (App Store build)
  /// this gates on Screen Recording — the selection is read from a screenshot, so we abort before
  /// recording audio when it's missing — and returns no capture. Otherwise it gates on
  /// Accessibility and copies the selection via ⌘C. `ready` is false (after showing guidance) when
  /// the required permission is missing.
  ///
  /// The returned capture is the ONLY source of selected text for this recording: a selection
  /// counts only when the pasteboard demonstrably changed for it. Nothing selected → the capture
  /// resolves to nil and the turn runs as compose, instead of feeding the model whatever was copied
  /// last (in a practice: possibly the previous patient's note).
  private func prepareDictatePromptSelection(
    logPrefix: String, model: PromptModel
  ) -> (ready: Bool, selection: DictatePromptSelectionCapture?) {
    if model.dictatePromptSelectionPermission == .screenRecording {
      if PermissionStatusChecker.status(for: .screenRecording) != .granted {
        DebugLogger.logWarning("\(logPrefix): Screen Recording missing — Dictate Prompt needs it for the screenshot")
        Self.showScreenRecordingPermissionError()
        return (false, nil)
      }
      return (true, nil)
    }
    // A local model in the App Store build: the selection comes from the clipboard, but the
    // synthetic ⌘C is exactly the Accessibility permission this build exists to avoid. The user
    // copies first. The clipboard counts as a selection only if it changed since the last Dictate
    // Prompt took its decision (or since launch) and the change was not the app's own result copy
    // or restore — see `DictatePromptSelectionDecision.clipboardIsFreshSelection` for the residual
    // risk (a stale copy the user made by hand still looks fresh).
    if model.dictatePromptSelectionPermission == nil {
      let current = NSPasteboard.general.changeCount
      let fresh = DictatePromptSelectionDecision.clipboardIsFreshSelection(
        currentChangeCount: current,
        lastConsumedChangeCount: lastConsumedPromptClipboardChangeCount,
        lastOwnWriteChangeCount: clipboardManager.lastOwnWriteChangeCount)
      lastConsumedPromptClipboardChangeCount = current
      let text = fresh ? NSPasteboard.general.string(forType: .string) : nil
      let selection = DictatePromptSelectionCapture.resolved(text)
      DebugLogger.log(
        "\(logPrefix): Local model, no synthetic ⌘C in this build — "
          + (fresh ? "clipboard changed since the last run, using it as the selection"
            : "clipboard unchanged or our own write, running as compose"))
      return (true, selection)
    }
    if !AccessibilityPermissionManager.checkPermissionForPromptUsage() { return (false, nil) }
    // Snapshot before the synthetic ⌘C, not after: from here on the pasteboard holds the
    // user's selection, so a later snapshot would "restore" that instead of what they copied.
    captureClipboardRestorePointIfEnabled()
    let selection = DictatePromptSelectionCapture()
    let before = NSPasteboard.general.changeCount
    let copyStarted = Date()
    simulateCopy()
    // Polling `NSPasteboard.changeCount`: "nothing was copied" and "the app was slow to copy" are
    // otherwise indistinguishable. The capture is held strongly by this task, so it always
    // resolves within the deadline and a waiting job can never hang on it.
    Task { @MainActor in
      let deadline = copyStarted.addingTimeInterval(DictatePromptSelectionCapture.pollDeadline)
      while Date() < deadline {
        try? await Task.sleep(for: DictatePromptSelectionCapture.pollInterval)
        let after = NSPasteboard.general.changeCount
        let text = NSPasteboard.general.string(forType: .string)
        // A delayed clipboard restore from the previous paste also bumps the change count; that is
        // the old clipboard (maybe the previous patient's note), not what ⌘C just copied.
        if after == clipboardManager.lastOwnWriteChangeCount { continue }
        guard DictatePromptSelectionDecision.acceptsCopy(
          changeCountBefore: before, changeCountAfter: after, string: text)
        else { continue }
        selection.resolve(text)
        DebugLogger.log("\(logPrefix): Captured selection (\(text?.count ?? 0) chars)")
        return
      }
      selection.resolve(nil)
      DebugLogger.log("\(logPrefix): Nothing selected (⌘C copied nothing) — compose turn")
      // The decision stands. Keep watching only so a slow ⌘C shows up in the logs instead of
      // looking identical to "nothing was selected".
      let watchUntil = copyStarted.addingTimeInterval(DictatePromptSelectionCapture.lateCopyWatch)
      while Date() < watchUntil {
        try? await Task.sleep(for: DictatePromptSelectionCapture.pollInterval)
        let after = NSPasteboard.general.changeCount
        guard DictatePromptSelectionDecision.copyProducedSelection(
          changeCountBefore: before, changeCountAfter: after)
        else { continue }
        let elapsedMs = Int(Date().timeIntervalSince(copyStarted) * 1000)
        DebugLogger.logWarning(
          "\(logPrefix): ⌘C copy arrived late after \(elapsedMs) ms (deadline 500 ms) — treated as compose")
        return
      }
    }
    return (true, selection)
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
      self.clipboardManager.discardRestorePoint()
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
        "Select a single term — a name or a piece of jargon — not a sentence. The Glossary is a spelling reference, and a whole sentence in it makes every dictation worse.",
        title: "Not a Glossary Term")
      DebugLogger.log("GLOSSARY: Rejected selection of \(text.count) chars")
    case .budgetExceeded(let term):
      PopupNotificationWindow.showInfo(
        "Your Glossary is full — Whisper only reads the first ~224 tokens of it, so \"\(term)\" would never be used. Remove terms you no longer need in Settings → Dictate.",
        title: "Glossary Full")
    }
  }
  #endif

  /// Simulates Cmd+C to copy the current selection to the clipboard (virtual key 0x08 = 'C').
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
    // Same private source as simulateCopy: a still-held Fn/⌥ from the shortcut
    // must not turn ⌘V into ⌘⌥V ("Paste and Match Style") in the frontmost app.
    let source = CGEventSource(stateID: .privateState)
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

  /// The app that was frontmost when the current Dictate / Dictate Prompt recording started. Auto-paste
  /// goes there, not to whatever the user has switched to since.
  private var pasteTargetAtRecordStart: PasteTarget?

  /// The own window (e.g. Chat) whose text field had focus when that recording started, so a
  /// dictation into WhisperShortcut's own input can be pasted there too.
  private var ownTextWindowAtRecordStart: Int?

  /// Window number of this app's key window when it is active and an editable text view has focus.
  private static func ownFocusedTextWindowNumber() -> Int? {
    guard NSApp.isActive, let window = NSApp.keyWindow,
      let textView = window.firstResponder as? NSTextView, textView.isEditable
    else { return nil }
    return window.windowNumber
  }

  /// Stores a dictation as a Writing Style sample when it was meant for a known app (mail,
  /// messenger, work chat). Never logs the text.
  @MainActor
  private func recordDictatedWritingSample(_ text: String) {
    guard UserDefaults.standard.bool(forKey: UserDefaultsKeys.writingStyleEnabled) else { return }
    let context = WritingContextResolver.context(forBundleID: pasteTargetAtRecordStart?.bundleId)
    guard context != .defaultContext,
      let sample = WritingStyleStore.dictatedSample(text: text, context: context)
    else { return }
    let added = WritingStyleStore.shared.addSamples([sample])
    DebugLogger.log("WRITING-STYLE: dictated sample context=\(context.rawValue) added=\(added)")
  }

  private static func pasteTarget(of app: NSRunningApplication?) -> PasteTarget? {
    app.map { PasteTarget(pid: $0.processIdentifier, bundleId: $0.bundleIdentifier) }
  }

  private static var ownPasteTarget: PasteTarget {
    PasteTarget(
      pid: ProcessInfo.processInfo.processIdentifier, bundleId: Bundle.main.bundleIdentifier)
  }

  /// How long to wait for the recorded app to come to the front before giving up on pasting.
  private static let pasteActivationTimeout: TimeInterval = 0.4

  /// Brings `app` to the front and polls (10 ms) until it is frontmost or the timeout passes.
  @MainActor
  private func activateAndWaitForFront(_ app: NSRunningApplication) async -> Bool {
    app.activate()
    let deadline = Date().addingTimeInterval(Self.pasteActivationTimeout)
    while Date() < deadline {
      if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier {
        return true
      }
      try? await Task.sleep(for: .milliseconds(10))
    }
    return NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
  }

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

  /// Performs auto-paste if enabled in settings.
  /// - Returns: `true` when ⌘V was posted; `false` when the result stays on the clipboard for the
  ///   user to paste manually (App Store build, setting off, missing Accessibility permission, or
  ///   no safe target app: WhisperShortcut itself, or the recorded app would not come forward).
  @MainActor
  @discardableResult
  private func autoPasteIfEnabled(logMode: String?) async -> Bool {
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
      try? await Task.sleep(for: .milliseconds(50))

      // The result can arrive minutes after the recording started, with another app (or this one)
      // in front. ⌘V there replaces whatever that app has selected, so paste only into the app the
      // user dictated into; into our own windows only when it was the same focused text field.
      let recorded = pasteTargetAtRecordStart
      let frontApp = NSWorkspace.shared.frontmostApplication
      let ownTextWindow = Self.ownFocusedTextWindowNumber()
      var action = PasteTargetPolicy.action(
        frontmost: Self.pasteTarget(of: frontApp), recorded: recorded, own: Self.ownPasteTarget,
        ownTextFieldStillFocused: ownTextWindow != nil && ownTextWindow == ownTextWindowAtRecordStart)
      if action == .activateRecordedThenPaste {
        if let recorded,
          let app = NSRunningApplication(processIdentifier: recorded.pid),
          !app.isTerminated,
          await activateAndWaitForFront(app)
        {
          action = .pasteNow
        } else {
          action = .clipboardOnly
        }
      }
      guard action == .pasteNow else {
        DebugLogger.logWarning(
          "AUTO-PASTE: Not pasting — target app is not in front "
            + "(frontmost: \(frontApp?.bundleIdentifier ?? "none"), "
            + "recorded: \(recorded?.bundleId ?? "none")); result stays on the clipboard")
        // The user pastes this themselves, so the old clipboard must not be restored over it.
        clipboardManager.discardRestorePoint()
        return false
      }

      simulatePaste()
      // Log *where* the synthetic ⌘V went. Without the target and payload size on record, a report
      // of "my text was suddenly gone" is undiagnosable after the fact.
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
      return true
    }
    // Auto-paste is off: the result stays on the clipboard, so there is nothing to restore.
    clipboardManager.discardRestorePoint()
    return false
    #endif
  }

  func cleanup() {
    liveMeeting.preserveForTermination()
    discardLastTemplateRecording()
    stopBlinking()
    shortcuts.cleanup()
    audioRecorder.cleanup()
    statusItem = nil
    NotificationCenter.default.removeObserver(self)
  }

}

// MARK: - AudioRecorderDelegate (Clean State Transitions)
extension MenuBarController: AudioRecorderDelegate {
  func audioRecorderDidBeginRecording() {
    guard var intent = recording, !intent.captureStarted else { return }
    intent.captureStarted = true
    recording = intent
    switch intent.target {
    case .meetingSegment(let segment):
      beginMeetingSegment(segment)
    case .mode(let mode):
      appState = appState.startRecording(mode)
    }
  }

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

      // The recording is over: its intent goes with this audio and nowhere else, so nothing from it
      // can reach the next recording.
      // Only an intent whose capture started belongs to this audio. A new recording that is still
      // waiting for mic permission (possible when a double stop already returned the app to idle)
      // is not this recording's, and taking it would strand that recorder.
      let intent = self.recording?.captureStarted == true ? self.recording : nil
      if intent != nil { self.recording = nil }

      // Cancelled via the recording indicator's ✕ — discard the audio, don't process
      if intent?.discardOnFinish == true {
        DebugLogger.log("AUDIO: Discarding cancelled recording \(audioURL.lastPathComponent)")
        self.clipboardManager.discardRestorePoint()
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
        Task { @MainActor in
          switch segment {
          case .dictation:
            await self.performTranscription(audioURL: audioURL, job: nil)
          case .prompt:
            await self.performPrompting(
              audioURL: audioURL, job: nil, selection: intent?.promptSelection)
          }
        }
        return
      }

      // During a meeting `appState` belongs to the meeting, so unclaimed audio must not run the
      // standard finish path.
      guard case .recording(let recordingMode) = self.appState, recordingMode != .liveMeeting else {
        // The audio is the only copy of what the user said. Never drop it: a dictation is kept as
        // the recoverable cancelled recording ("Transcribe Cancelled Recording" in the status
        // menu); an instruction recording (prompt) would be pasted as dictation,
        // so that one is removed.
        self.discardStreamingSession()
        self.clipboardManager.discardRestorePoint()
        let isDictation: Bool = {
          guard let intent else { return true }
          if case .mode(.transcription) = intent.target { return true }
          return false
        }()
        if isDictation {
          DebugLogger.logWarning(
            "AUDIO: Recording \(audioURL.lastPathComponent) arrived while appState is \(self.appState) — kept as the cancelled recording")
          self.retainCancelledRecording(audioURL)
        } else {
          DebugLogger.logWarning(
            "AUDIO: Instruction recording \(audioURL.lastPathComponent) arrived while appState is \(self.appState) — discarded")
          self.cleanupAudioFile(at: audioURL)
        }
        return
      }

      var promptInputs = self.finishedPromptInputs[audioURL] ?? FinishedPromptInputs()
      if self.activeMeetingSegment == nil, let instruction = intent?.quickActionInstruction {
        promptInputs.quickActionInstruction = instruction
        promptInputs.isEditQuickAction = intent?.isEditQuickAction ?? false
      }
      if self.activeMeetingSegment == nil,
         let template = intent?.boundTemplate,
         intent?.templateEnabled == true,
         intent?.quickActionInstruction == nil {
        promptInputs.templateInstruction = template.instructions
        promptInputs.templateName = template.displayName
      }
      if let selection = intent?.promptSelection {
        promptInputs.selection = selection
      }
      if promptInputs.quickActionInstruction != nil || promptInputs.selection != nil
          || promptInputs.templateInstruction != nil {
        self.finishedPromptInputs[audioURL] = promptInputs
      }
      let quickActionInstruction = promptInputs.quickActionInstruction
      let promptSelection = promptInputs.selection

      // Recording safeguard: confirm above duration (same pattern as AccessibilityPermissionManager).
      // A quick action never sends the audio, so the cost warning does not apply.
      let threshold = ConfirmAboveDuration.loadFromUserDefaults()

      // The cost warning only makes sense when the run costs money: an offline / on-device model
      // has no API bill, and a modal on a long local dictation is just a hurdle.
      let runCostsMoney: Bool = {
        switch recordingMode {
        case .transcription:
          return !TranscriptionModel.loadSelected().isOffline
        case .prompt:
          let promptProvider = PromptModel.loadPromptModel(
            forKey: UserDefaultsKeys.selectedPromptModel, default: SettingsDefaults.selectedPromptModel
          ).provider
          let promptIsLocal = promptProvider == .local || promptProvider == .localMLX
          return !(promptIsLocal && TranscriptionModel.loadSelected().isOffline)
        case .liveMeeting:
          return true
        }
      }()

      if quickActionInstruction == nil,
         threshold != .never,
         runCostsMoney,
         let duration = self.speechService.getAudioDuration(url: audioURL),
         duration > threshold.rawValue
      {
        let mins = Int(duration) / 60
        let secs = Int(duration) % 60
        let timeStr = Duration.seconds(Int(duration)).formatted(.units(allowed: [.minutes, .seconds], width: .abbreviated))
        // Recording has finished; leave "Recording…" before the modal would be misleading.
        self.appState = self.appState.stopRecording()
        let alert = NSAlert()
        alert.messageText = String(localized: "Long recording")
        alert.informativeText = String(localized: "This recording is \(timeStr) long. Process anyway? (API usage may incur costs.)")
        alert.alertStyle = .informational
        alert.addButton(withTitle: String(localized: "Process", comment: "Alert button: go ahead and transcribe the long recording"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        let response = alert.runModal()
        if response != .alertFirstButtonReturn {
          DebugLogger.log("RECORDING-SAFEGUARD: User cancelled processing for long recording (\(timeStr))")
          self.discardStreamingSession()
          // Nothing will be pasted, so the remembered clipboard must not outlive this run.
          self.clipboardManager.discardRestorePoint()
          // Cancel is one click and a long recording is the only copy of what was said: keep it
          // recoverable ("Transcribe Cancelled Recording") instead of deleting it. Instruction
          // recordings would be pasted as dictation there, so those are still removed.
          if recordingMode == .transcription {
            self.retainCancelledRecording(audioURL)
          } else {
            self.cleanupAudioFile(at: audioURL)
          }
          self.appState = self.appState.finish()
          return
        }
      }

      // Mark this URL as processed to prevent duplicate processing
      self.processedAudioURLs.insert(audioURL)

      // Digital zero for a whole recording is never a quiet user: CoreAudio delivers all-zero
      // input when TCC denies the process (e.g. an app launched from a since-deleted worktree),
      // or the input device is dead. Surface it instead of the silent "didn't catch that" skip,
      // on every path — offline Whisper cannot transcribe zeros either (queue #11).
      if quickActionInstruction == nil,
        self.audioRecorder.lastPeakPowerDb <= Self.digitalSilenceThresholdDb,
        case let digitalSilenceDurationMs = Self.audioDurationMs(of: audioURL),
        digitalSilenceDurationMs >= Self.digitalSilenceMinDurationMs
      {
        let peakDb = String(format: "%.1f", self.audioRecorder.lastPeakPowerDb)
        DebugLogger.logWarning(
          "AUDIO: No input signal — peak \(peakDb) dB over \(digitalSilenceDurationMs) ms, microphone delivered digital silence")
        ContextLogger.shared.logNoInputSignal(
          peakDb: peakDb, durationMs: String(digitalSilenceDurationMs), logPrefix: "DICTATION")
        self.discardStreamingSession()
        self.clipboardManager.discardRestorePoint()
        self.processedAudioURLs.remove(audioURL)
        self.cleanupAudioFile(at: audioURL)
        self.appState = self.appState.stopRecording()
        self.appState = self.appState.finish()
        PopupNotificationWindow.showError(
          "Microphone delivered no audio — check System Settings ▸ Privacy ▸ Microphone or restart WhisperShortcut.",
          title: "No microphone input")
        return
      }

      if self.audioRecorder.lastRecordingWasSilent, quickActionInstruction == nil {
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
          let durationMs = Self.audioDurationMs(of: audioURL)
          ContextLogger.shared.logNoSpeechDetected(
            source: "localSilenceGate",
            peakDb: String(format: "%.1f", self.audioRecorder.lastPeakPowerDb),
            durationMs: String(durationMs),
            logPrefix: "DICTATION",
            origin: .dictation)
          self.discardStreamingSession()
          self.clipboardManager.discardRestorePoint()
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
      } else if quickActionInstruction != nil, self.audioRecorder.lastRecordingWasSilent {
        DebugLogger.log("AUDIO: Quick action — skipping silence precheck for \(audioURL.lastPathComponent)")
      }

      if !self.appState.isProcessing {
        self.appState = self.appState.stopRecording()
      }

      switch recordingMode {
      case .transcription:
        // No pre-emptive popup here any more: `ModelManager.ensureReady` reports what is
        // actually happening (downloading N%, preparing, transcribing) from inside the
        // transcription path, instead of one static "can take several minutes" line.
        self.startVoiceJob(mode: .transcription, audioURL: audioURL) { job in
          await self.performTranscription(audioURL: audioURL, job: job)
        }
      case .prompt:
        self.startVoiceJob(mode: .prompt, audioURL: audioURL) { job in
          await self.performPrompting(
            audioURL: audioURL, job: job, instruction: quickActionInstruction,
            isEditQuickAction: promptInputs.isEditQuickAction,
            templateInstruction: promptInputs.templateInstruction,
            templateName: promptInputs.templateName, selection: promptSelection)
        }
      case .liveMeeting:
        DebugLogger.logWarning("AUDIO: Unexpected liveMeeting recording in standard AudioRecorderDelegate")
        self.cleanupAudioFile(at: audioURL)
      }
    }
  }

  func audioRecorderDidFailWithError(_ error: Error) {
    // A meeting owns `appState`; a failed segment shows its popup only.
    let meetingOwnsState = isLiveMeetingActive
    recording = nil
    clipboardManager.discardRestorePoint()
    dismissQuickActions()
    let errorCode = (error as NSError).code
    let errorDomain = (error as NSError).domain
    DebugLogger.logDebug("audioRecorderDidFailWithError called - errorCode: \(errorCode), errorDomain: \(errorDomain), errorDescription: \(error.logDescription), appState: \(appState), isEmptyFileError: \(errorCode == 1004)")
    discardStreamingSession()
    if activeMeetingSegment != nil {
      DebugLogger.logWarning("MEETING-SEGMENT: Recording failed during meeting segment, clearing segment")
      clearMeetingSegment()
    }
    // Microphone permission denied/restricted: offer a direct jump to the Microphone
    // privacy pane instead of leaving the user with only "Contact Support".
    if errorDomain == "WhisperShortcut" && errorCode == 1001 {
      presentError(
        shortTitle: String(localized: "Microphone Access Needed"),
        message: "WhisperShortcut needs microphone access to record. Open System Settings ▸ Privacy & Security ▸ Microphone and enable WhisperShortcut.",
        dismissProcessingFirst: false,
        retryAction: { PermissionStatusChecker.openSystemSettings(for: .microphone) },
        retryActionTitle: "Open System Settings",
        changesAppState: !meetingOwnsState
      )
      return
    }
    presentError(shortTitle: String(localized: "Recording Error"), message: SpeechErrorFormatter.formatForUser(error), dismissProcessingFirst: false, changesAppState: !meetingOwnsState)
  }
}

// MARK: - ShortcutDelegate (Simple Forwarding)
extension MenuBarController: ShortcutDelegate {
  func toggleDictation() { toggleTranscription() }

  func toggleTemplatePrompting(id: UUID) {
    guard let template = DictationTemplateStore.template(id: id), template.isUsable else {
      DebugLogger.log("DICTATION-TEMPLATE: Shortcut ignored — template is missing or has no instructions")
      return
    }
    togglePrompting(template: template)
  }

  /// Whether a dictation recording is running — mirrors what `toggleTranscription` treats as
  /// active, including a parallel segment during a live meeting. Used by the Fn toggle.
  func isDictationRecordingActive() -> Bool {
    if pendingRecordingMode == .transcription || pendingMeetingSegment == .dictation { return true }
    if isLiveMeetingActive { return activeMeetingSegment == .dictation }
    return appState.recordingMode == .transcription
  }

  // togglePrompting is already implemented above
  // openSettings is already implemented above
  func openChat() { openChatWindowFromShortcut() }

  /// Mouse-down / mouse-up sample taken while `screencapture -i` is running.
  /// Written by the polling timer, read on main after the tool exits; the lock keeps it simple.
  private final class ScreenshotClickTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var downPoint: NSPoint?
    private var upPoint: NSPoint?

    func noteDown(_ point: NSPoint) {
      lock.lock()
      downPoint = point
      lock.unlock()
    }

    func noteUp(_ point: NSPoint) {
      lock.lock()
      upPoint = point
      lock.unlock()
    }

    func points() -> (down: NSPoint?, up: NSPoint?) {
      lock.lock()
      defer { lock.unlock() }
      return (downPoint, upPoint)
    }
  }

  @objc func takeScreenshot() {
    if !Thread.isMainThread {
      DispatchQueue.main.async { [weak self] in self?.takeScreenshot() }
      return
    }
    // Always capture to a temp PNG (not screencapture's own `-c`) so we get a definitive
    // success signal: a file means the capture worked, no file means it didn't. We then
    // copy the image to the clipboard ourselves and, when enabled, persist it to the
    // user-selected folder. Without this we can't tell a successful capture apart from a
    // silent failure — which is exactly what happens when Screen Recording permission is
    // missing: screencapture launches fine (no thrown error) but produces nothing.
    //
    // A click (mouse down + up, moved < 5 pt) makes `screencapture -i` exit with no file.
    // That captures the whole screen under the click, not a cancel. Esc still produces no
    // file and no click, and stays a cancel.
    let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("whispershortcut-\(UUID().uuidString).png")
    let saveToFolder = ScreenshotSaveLocation.isEnabled
    DebugLogger.logUI("📷 SCREENSHOT: Launching interactive capture (save=\(saveToFolder))")

    // Poll the button state instead of using a global event monitor: while screencapture's
    // overlay is up, macOS delivers the clicks to screencapture only, so a monitor never sees
    // them (verified 2026-10-10). `pressedMouseButtons` reads the hardware state and needs no
    // permission.
    let clicks = ScreenshotClickTracker()
    var sawDown = false
    let pollTimer = Timer(timeInterval: 0.01, repeats: true) { _ in
      let pressed = NSEvent.pressedMouseButtons & 1 != 0
      if pressed && !sawDown {
        sawDown = true
        clicks.noteDown(NSEvent.mouseLocation)
      } else if !pressed && sawDown {
        sawDown = false
        clicks.noteUp(NSEvent.mouseLocation)
      }
    }
    RunLoop.main.add(pollTimer, forMode: .common)

    DispatchQueue.global(qos: .userInitiated).async {
      let task = Process()
      task.launchPath = "/usr/sbin/screencapture"
      // -i interactive (drag rectangle / space-bar for window), -o no shadow on window grabs.
      task.arguments = ["-i", "-o", tempURL.path]
      var launchError: Error?
      do {
        try task.run()
        task.waitUntilExit()
      } catch {
        launchError = error
        DebugLogger.logError("SCREENSHOT: Failed to launch screencapture: \(error)")
      }

      DispatchQueue.main.async {
        pollTimer.invalidate()
        // screencapture exits on the release, which can beat the next timer tick.
        if sawDown && NSEvent.pressedMouseButtons & 1 == 0 {
          clicks.noteUp(NSEvent.mouseLocation)
        }
        if launchError != nil { return }

        guard FileManager.default.fileExists(atPath: tempURL.path),
          let data = try? Data(contentsOf: tempURL)
        else {
          // No file: the user cancelled, Screen Recording permission is missing, or they
          // clicked without dragging. Permission is checked first so a missing grant is
          // never treated as a click.
          if PermissionStatusChecker.status(for: .screenRecording) != .granted {
            DebugLogger.logWarning("SCREENSHOT: No capture file and no Screen Recording permission")
            Self.showScreenRecordingPermissionError()
            return
          }
          let sample = clicks.points()
          DebugLogger.log("SCREENSHOT: no file; click sample down=\(String(describing: sample.down)) up=\(String(describing: sample.up))")
          if let down = sample.down, let up = sample.up,
            hypot(up.x - down.x, up.y - down.y) < 5
          {
            DebugLogger.log("SCREENSHOT: click with no selection — capturing the whole screen")
            Self.captureWholeScreen(atCocoaPoint: up, saveToFolder: saveToFolder)
          } else {
            DebugLogger.log("SCREENSHOT: No capture file (selection cancelled)")
          }
          return
        }

        Self.deliverScreenshot(data, saveToFolder: saveToFolder)
        try? FileManager.default.removeItem(at: tempURL)
      }
    }
  }

  /// Captures the whole display that contains `point` (Cocoa coordinates) and delivers it like a
  /// dragged selection.
  private static func captureWholeScreen(atCocoaPoint point: NSPoint, saveToFolder: Bool) {
    guard let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }),
      let primary = NSScreen.screens.first
    else {
      DebugLogger.logWarning("SCREENSHOT: no screen contains the click at \(point)")
      return
    }
    // screencapture -R takes global points with a top-left origin on the primary display.
    let frame = screen.frame
    let rect = "\(Int(frame.minX)),\(Int(primary.frame.maxY - frame.maxY)),\(Int(frame.width)),\(Int(frame.height))"
    let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("whispershortcut-\(UUID().uuidString).png")
    DispatchQueue.global(qos: .userInitiated).async {
      let task = Process()
      task.launchPath = "/usr/sbin/screencapture"
      task.arguments = ["-R", rect, tempURL.path]
      do {
        try task.run()
        task.waitUntilExit()
      } catch {
        DebugLogger.logError("SCREENSHOT: Failed to launch screencapture: \(error)")
        return
      }
      guard let data = try? Data(contentsOf: tempURL) else {
        DebugLogger.logWarning("SCREENSHOT: whole-screen capture produced no file (rect \(rect))")
        return
      }
      DispatchQueue.main.async {
        DebugLogger.log("SCREENSHOT: whole screen captured (rect \(rect), \(data.count) bytes)")
        deliverScreenshot(data, saveToFolder: saveToFolder)
        try? FileManager.default.removeItem(at: tempURL)
      }
    }
  }

  /// Copies the PNG to the clipboard and, when enabled, writes it to the screenshot folder.
  private static func deliverScreenshot(_ pngData: Data, saveToFolder: Bool) {
    if let image = NSImage(data: pngData) {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.writeObjects([image])
    }
    if saveToFolder {
      ScreenshotSaveLocation.save(pngData)
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
    switch availability(.readAloudSelection) {
    case .ignored(.liveMeetingActive):
      DebugLogger.logWarning("READ-ALOUD-SHORTCUT: ignoring during live meeting")
      return
    case .ignored(.otherModeRecording):
      DebugLogger.logWarning("READ-ALOUD-SHORTCUT: ignoring while another recording is active")
      return
    case .blocked(let reason):
      presentBlocked(reason)
      return
    case .start:
      break
    default:
      return
    }
    guard AccessibilityPermissionManager.checkPermissionForPromptUsage() else { return }

    // A blind delay isn't enough: some apps respond to Cmd+C slower than others, and a fixed
    // wait either reads the stale clipboard (too short) or stalls Read Aloud (too long). Poll
    // `NSPasteboard.changeCount` instead — as soon as the frontmost app finishes writing the
    // copy, we read; if no change lands within the deadline, the selection didn't get copied
    // (no focus, no selection, or no accessibility permission for the app being copied from).
    // Snapshot before the synthetic ⌘C overwrites the user's clipboard (same setting and mechanism
    // as Dictate Prompt); `performReadSelectedTextAloud` puts it back once the selection is read.
    captureClipboardRestorePointIfEnabled()
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
              self.clipboardManager.discardRestorePoint()
              return
            }
            self.performReadSelectedTextAloud()
            return
          }
        }
        DebugLogger.logWarning("READ-ALOUD: Pasteboard never changed — Cmd+C did not land on a selection")
        self.clipboardManager.discardRestorePoint()
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
    if attemptReadAloudToggleOff() {
      clipboardManager.discardRestorePoint()
      return
    }
    let copiedText = clipboardManager.getCleanedClipboardText()
    // The selection is in hand: give the user their previous clipboard back (no paste follows, so
    // there is no receiving app to wait for).
    if clipboardManager.restorePendingSnapshot(afterForeignWriteAt: NSPasteboard.general.changeCount) {
      DebugLogger.log("READ-ALOUD: Restored the clipboard contents from before the selection copy")
    }
    guard let selectedText = copiedText,
          !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      DebugLogger.logWarning("READ-ALOUD: Pasteboard changed but text is empty after cleaning")
      showNoTextSelectedForReadAloud()
      return
    }
    beginReadAloudProcessing(text: selectedText) { [speechService] onChunkReady in
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
    RecordingIndicatorManager.shared.hide()
    if audioRecorder.stopRecording() {
      recording?.discardOnFinish = true
    } else {
      cancelPendingRecordingStart()
      if case .recording = appState { appState = appState.finish() }
    }
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

    // A live meeting owns `appState`; a chunked segment inside it must not overwrite it (R107).
    guard setChunkProcessingState(.processing(.splitting(context: context))) else { return }
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

  /// The one transition every per-chunk callback makes: record the chunk's status, move the
  /// state machine (only while still processing — see `setChunkProcessingState`), refresh the
  /// icon, and redraw the status grid in the popup. `popupSuffix` is an extra line under the
  /// grid; `logIfSkipped` is what to say when the transition was refused because playback
  /// already started.
  private func applyChunkStatus(
    _ status: ChunkStatus, at index: Int, popupSuffix: String? = nil, logIfSkipped: String? = nil
  ) -> Bool {
    chunkStatuses[index] = status
    let context = currentChunkContext
    guard setChunkProcessingState(
      .processing(.processingChunks(statuses: chunkStatuses, context: context)))
    else {
      if let logIfSkipped { DebugLogger.logDebug("CHUNK-PROGRESS: \(logIfSkipped)") }
      return false
    }
    updateMenuBarIcon()
    updateChunkPopup(context: context, popupSuffix: popupSuffix)
    return true
  }

  /// Popups only for pill-less flows, see `chunkingStarted`.
  private func updateChunkPopup(context: AppState.ProcessingMode.ChunkContext, popupSuffix: String? = nil) {
    guard showsChunkProgressPopups else { return }
    let statusGrid = generateStatusGrid()
    PopupNotificationWindow.updateProcessing(
      title: context == .tts ? "Synthesizing Speech" : "Processing Audio",
      verbatim: popupSuffix.map { "\(statusGrid)\n\($0)" } ?? statusGrid
    )
  }

  func chunkStarted(index: Int) {
    guard index >= 0 && index < chunkStatuses.count else { return }
    guard applyChunkStatus(.active, at: index) else { return }
    DebugLogger.log("CHUNK-PROGRESS: Chunk \(index) started processing")
  }

  func chunkProgressUpdated(completed: Int, total: Int) {
    // This is now a fallback/summary - individual states tracked via other callbacks
    updateMenuBarIcon()
    DebugLogger.log("CHUNK-PROGRESS: \(completed)/\(total) chunks complete")
  }

  func chunkCompleted(index: Int, text: String) {
    guard index >= 0 && index < chunkStatuses.count else { return }
    guard applyChunkStatus(
      .completed, at: index,
      logIfSkipped: "Chunk \(index) completed while already playing back")
    else { return }
    DebugLogger.log("CHUNK-PROGRESS: Chunk \(index) completed \(DebugLogger.redacted(text))")
  }

  func chunkFailed(index: Int, error: Error, willRetry: Bool) {
    guard index >= 0 && index < chunkStatuses.count else { return }

    if willRetry {
      // Keep as active (will be re-started via chunkStarted); only the popup changes.
      DebugLogger.logWarning("CHUNK-PROGRESS: Chunk \(index) failed, retrying...")
      updateChunkPopup(context: currentChunkContext, popupSuffix: String(localized: "Retrying chunk \(index + 1)..."))
      return
    }

    guard applyChunkStatus(.failed, at: index) else {
      DebugLogger.logError("CHUNK-PROGRESS: Chunk \(index) failed during playback: \(error.logDescription)")
      return
    }
    DebugLogger.logError("CHUNK-PROGRESS: Chunk \(index) failed: \(error.logDescription)")
    // Log to file (replaces CrashLogger)
    DebugLogger.logError(error, context: "Chunk \(index) transcription failed", state: appState)
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
        verbatim: isTTS ? String(localized: "Merging audio chunks...") : String(localized: "Merging transcription results...")
      )
    }

    DebugLogger.log("CHUNK-PROGRESS: Merging \(isTTS ? "audio chunks" : "transcripts")...")
  }
}

// MARK: - AI app proposals
extension MenuBarController {
  @objc func showAIAppProposals() {
    MCPProposalWindows.shared.showAll()
  }
}

// MARK: - NSMenuDelegate
extension MenuBarController: NSMenuDelegate {
  /// Fires a previously-armed review/support prompt when the user opens the menu (i.e. is
  /// focused on this app rather than the one they were dictating into). No-ops when nothing
  /// is pending.
  func menuWillOpen(_ menu: NSMenu) {
    ReviewPrompter.shared.showPendingPromptIfNeeded()
    // Titles, Stop row, onboarding and history rows are otherwise only refreshed on an `appState`
    // change, which leaves them stale right after launch.
    refreshMenu(menu)
    updateMeetingBacklogItems(menu)
  }

  /// The one-time usage statistics notice waits for the menu to close: a window opened while the
  /// menu is tracking would sit behind it. If the chosen item opened Settings or Chat, that
  /// window's own firing point gets there first and this call finds the notice already spent.
  func menuDidClose(_ menu: NSMenu) {
    DispatchQueue.main.async {
      UsageStatisticsNotice.shared.showIfDue()
    }
  }
}
