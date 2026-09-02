import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

// MARK: - Streaming Buffer

/// Holds the in-flight content for one streaming assistant bubble, separate from the
/// `messages` array. Token writes go here, not into `ChatViewModel.messages`, so a fast
/// stream doesn't trigger a per-token `LazyVStack` diff (which historically wedged the main
/// thread and produced the scroll-anchor-reset flicker on send). Only the bubble that
/// observes this buffer re-renders per token; the rest of the conversation list is untouched.
///
/// Hosts its own length-adaptive throttle (see `flushIntervalNs`) so consumers don't need to
/// coordinate one — repeated
/// `enqueueUpdate` calls within the flush window collapse to a single commit of the most
/// recent state. Terminal callers use `cancelPending` before committing the final content
/// into the message itself, so stale flushes can't fire afterwards.
@MainActor
final class StreamingBuffer: ObservableObject {
  @Published private(set) var content: String = ""
  private var pendingContent: String?
  private var flushTask: Task<Void, Never>?
  // Each flush mutates `content`, which grows the streaming bubble's height. The structural fix
  // for the resulting freeze lives in `messageList`: the streaming bubble is rendered OUTSIDE the
  // `.scrollTargetLayout()` LazyVStack, so its growth no longer forces a lazy placement pass or a
  // `.scrollPosition(id:)` anchor re-resolution over the history (the two hot frames that wedged the
  // main thread ≥4s — hang-20260619-151328.txt at 30fps, hang-20260701-134623.txt at ~8fps, and
  // hang-20260703-093924.txt post-throttle). This throttle is now only a secondary guard against
  // spending too much of a frame budget re-parsing/re-rendering markdown on a fast stream, so it
  // still scales the interval with accumulated length: snappy while short, slower once long.
  private static func flushIntervalNs(forLength length: Int) -> UInt64 {
    switch length {
    case ..<4_000:  return 125_000_000  // ~8fps   — short reply, stays snappy
    case ..<12_000: return 250_000_000  // ~4fps
    default:        return 400_000_000  // ~2.5fps — long reply, sweep is heavy
    }
  }

  func enqueueUpdate(_ newContent: String) {
    pendingContent = newContent
    guard flushTask == nil else { return }
    let interval = Self.flushIntervalNs(forLength: newContent.count)
    flushTask = Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: interval)
      if Task.isCancelled { return }
      self?.flushPending()
    }
  }

  private func flushPending() {
    flushTask = nil
    guard let pending = pendingContent else { return }
    pendingContent = nil
    content = pending
  }

  /// Cancels any pending throttled update and applies `newContent` immediately. Use for
  /// state that must be visible synchronously (e.g. an image-marker fold replacing the
  /// streamed-text prefix).
  func setContentImmediate(_ newContent: String) {
    cancelPending()
    content = newContent
  }

  /// Drops any queued flush without applying it. Terminal callers (finalization,
  /// cancellation) commit content into the message itself afterwards — a stale pending
  /// flush would overwrite that final state with intermediate token text.
  func cancelPending() {
    flushTask?.cancel()
    flushTask = nil
    pendingContent = nil
  }

  deinit {
    flushTask?.cancel()
  }
}

// MARK: - ViewModel

@MainActor
class ChatViewModel: ObservableObject {
  @Published var messages: [ChatMessage] = []
  /// Send before mutating the visible message list so `ChatView` clears its local
  /// `.scrollPosition` binding. Signal, not state — emitted via `PassthroughSubject` and
  /// consumed by `.onReceive` in the view.
  ///
  /// With a non-nil anchor id, every mutation of `messages` makes the lazy list re-anchor by
  /// resolving that id during layout (`LazySubviewPlacements.makeIDPlacementContextIfNeeded`).
  /// In long sessions that layout pass can fail to converge and wedge the main thread at
  /// 100% CPU inside a single transaction (observed 2026-06-04: app froze right after
  /// CHAT-SEND; a `sample` showed every frame resolving the scrollPosition matchingID).
  /// Clearing the binding removes the id-anchoring work entirely: the scroll offset is
  /// preserved by the ScrollView's default behavior and the persisted reading position
  /// (`scrollAnchors`) is untouched — it repopulates on the next user scroll.
  let scrollAnchorClearSignal = PassthroughSubject<Void, Never>()
  @Published var inputText: String = ""
  @Published private(set) var sendingSessionIds: Set<UUID> = []
  /// True when the currently visible session has an in-flight request.
  var isSending: Bool { sendingSessionIds.contains(session.id) }
  @Published var errorMessage: String? = nil
  /// Last send failure for the visible session (also persisted on `ChatSession.lastSendError`
  /// so a background-tab failure is still visible after the user switches back).
  @Published var lastSendError: String? = nil
  /// Transient non-error confirmation (e.g. "Chat copied"). Auto-dismissed after a short delay.
  @Published var noticeMessage: String? = nil
  private var noticeDismissTask: Task<Void, Never>? = nil
  @Published var pendingScreenshots: [Data] = []
  @Published var screenshotCaptureInProgress: Bool = false
  @Published var pendingFileAttachments: [PendingFile] = []
  @Published var pastedBlocks: [PastedBlock] = []
  @Published var messageQueue: [QueuedChatMessage] = []

  struct PendingFile {
    let data: Data
    let mimeType: String
    let filename: String
  }

  struct PastedBlock: Identifiable {
    enum Kind: Equatable {
      /// Large Cmd+V paste in the composer.
      case largePaste
      /// Text captured via Chat shortcut (front-app selection).
      case shortcutSelection
      /// A line the user picked out of the meeting notes or transcript to ask about.
      case meetingQuote
    }

    let id: UUID
    let content: String
    let kind: Kind

    init(id: UUID = UUID(), content: String, kind: Kind = .largePaste) {
      self.id = id
      self.content = content
      self.kind = kind
    }

    var lineCount: Int { content.components(separatedBy: .newlines).filter { !$0.isEmpty }.count }
  }

  struct QueuedChatMessage: Identifiable {
    let id: UUID = UUID()
    /// Session the message was typed in — it is sent there even if the user
    /// switches tabs before the queue drains.
    let sessionId: UUID
    let content: String
    let attachedParts: [AttachedImagePart]

    /// User-visible text, strips internal XML wrapper tags used for API context.
    var displayContent: String {
      let typedOpen = "<typed_by_user>", typedClose = "</typed_by_user>"
      if let r1 = content.range(of: typedOpen),
         let r2 = content.range(of: typedClose),
         r1.upperBound <= r2.lowerBound {
        return String(content[r1.upperBound..<r2.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
      }
      let hasSelection = content.contains("<pasted_selection>")
      let hasPaste = content.contains("<pasted_content>")
      let hasQuote = content.contains("<quoted_from_meeting>")
      if hasSelection, hasPaste { return "[Selection] [Pasted content]" }
      if hasSelection { return "[Selection]" }
      if hasPaste { return "[Pasted content]" }
      if hasQuote { return "[Quote]" }
      return content
    }
  }

  static let pasteThresholdLines = 30
  static let pasteThresholdChars = 1500

  func addPastedBlock(_ text: String, kind: PastedBlock.Kind = .largePaste) {
    pastedBlocks.append(PastedBlock(content: text, kind: kind))
  }

  func removePastedBlock(id: UUID) {
    pastedBlocks.removeAll { $0.id == id }
  }

  @Published private(set) var recentSessions: [ChatSession] = []
  @Published private(set) var allSessionsList: [ChatSession] = []
  @Published private(set) var currentSessionId: UUID = UUID()
  @Published private(set) var isMeetingActive: Bool = false
  /// True between the stop request and the meeting actually being finished (its last chunk still has
  /// to be transcribed). The bar says "Finishing…" for those seconds instead of "Recording".
  @Published private(set) var isMeetingFinishing: Bool = false
  @Published private(set) var meetingSessionId: UUID? = nil
  var isCurrentSessionMeeting: Bool { session.isMeeting }
  var isCurrentSessionTheActiveMeeting: Bool { isMeetingActive && meetingSessionId == session.id }
  /// True when the meeting this tab is showing is the one currently being wrapped up.
  var isCurrentSessionFinishingMeeting: Bool { isMeetingFinishing && isCurrentSessionTheActiveMeeting }
  private var meetingCancellable: AnyCancellable?
  private var meetingFinishingCancellable: AnyCancellable?
  private var summaryCancellable: AnyCancellable?
  /// Meeting stems we've already attempted to backfill a title for this app run, so a missing or
  /// failed summary doesn't trigger a fresh API call every time the meeting is viewed.
  private var attemptedMeetingTitleStems: Set<String> = []
  /// Meeting stems we've already attempted to recover a missing summary for this app run, so opening
  /// the Summary tab repeatedly doesn't re-fire generation when the transcript truly has no summary.
  private var attemptedMeetingSummaryStems: Set<String> = []
  /// Invalidation tick — intentionally never read. `recoverMeetingSummaryIfNeeded` bumps it after
  /// writing a fresh `.summary.md` so SwiftUI re-evaluates `meetingSummaryView`, which then re-reads
  /// `endedMeetingSummary` from disk. Disk is the source of truth and the file is tiny.
  @Published private(set) var summaryRevision: UInt = 0
  /// True while a missing meeting summary is being regenerated, so the Notes tab can show progress.
  @Published private(set) var isRecoveringMeetingSummary: Bool = false
  /// Disk-read notes of the ended meeting currently being viewed. See `meetingNotesForDisplay`.
  private var endedNotesCache: (stem: String, notes: [LiveMeetingNote])?

  /// In-memory ring buffer of recently closed sessions for Cmd+Shift+T undo.
  /// Only sessions that had at least one message are stored — empty tabs are
  /// considered disposable and not worth restoring.
  private var recentlyClosedSessions: [ChatSession] = []
  private static let recentlyClosedCapacity = 10

  private var session: ChatSession
  private let store: ChatSessionStore
  private let apiClient = GeminiAPIClient()

  /// In-flight send tasks keyed by session ID — multiple sessions can be sending simultaneously.
  private var sendTasks: [UUID: Task<Void, Never>] = [:]

  /// Sessions whose in-flight send the *user* cancelled, with the number of queued messages that
  /// Stop dropped along with it. Set by `cancelSend`, consumed once by the `CancellationError`
  /// handler. Absence there means the watchdog cancelled instead — see `OutcomeSignal.chatStopped`.
  private var userCancelledSessions: [UUID: Int] = [:]

  /// Live streaming bubbles keyed by their placeholder message id. Per-token updates write into
  /// `buffer.content` (a separate `ObservableObject`), not into `messages`, so a fast stream
  /// only re-renders the one bubble that observes its buffer — no `LazyVStack` diff, no
  /// session/messages `@Published` ripple. Not `@Published`: every attach/detach is paired with
  /// a `messages` mutation in the same MainActor sync window, so SwiftUI re-reads the dict on
  /// that re-render — a second emission here would be redundant.
  private(set) var streamingBuffers: [UUID: StreamingBuffer] = [:]

  /// Returns true if the given session has an in-flight request (for tab spinner).
  func isSendingSession(_ id: UUID) -> Bool { sendingSessionIds.contains(id) }
  /// Maximum length for auto-generated session title from first user message.
  private static let maxSessionTitleLength = 50
  /// Commands are slash-only (e.g. /new); do not use hotkeys/shortcuts for command actions.
  private static let newChatCommand = "/new"
  static let screenshotCommand = "/screenshot"
  private static let attachCommand = "/attach"
  private static let folderCommand = "/folder"
  private static let settingsCommand = "/settings"
  private static let pinCommand = "/pin"
  private static let unpinCommand = "/unpin"
  private static let modelCommand = "/model"
  private static let meetingCommand = "/meeting"
  private static let copyCommand = "/copy"
  private static let feedbackCommand = "/feedback"
  static let thinkCommand = "/think"
  static let xHandlesCommand = "/x"
  static let workspaceCommand = "/workspace"

  /// Slash commands that take an inline argument (e.g. `/model 3.1 flash`, `/think high`).
  /// The autocomplete completes them inline instead of dispatching, and the composer strips
  /// the whole line (not just the token) so multi-word args leave no residue. Single source so
  /// the three call sites in `ChatInputAreaView` can't drift.
  static let argumentCommands: Set<String> = [
    modelCommand, thinkCommand, xHandlesCommand, workspaceCommand,
  ]

  /// Model-switch slash commands, generated from `PromptModel` so adding a model auto-adds its
  /// alias. Grouped by provider: the provider-default alias (`/gemini`, `/grok`, `/gpt`) first,
  /// then each of that provider's *non-default* chat models by its `shortAlias`
  /// (`/gemini35flash`, `/gemini35flashlite`, …); the default model is reached via the bare
  /// provider command.
  /// Single source for autocomplete, tab-completion, `knownSlashCommands`, dispatch, and the
  /// system-prompt command list — so none can drift. `/openai` is NOT here: it's a silent,
  /// dispatch-only alias for `/gpt` (see `modelCommandLookup`).
  static let modelCommands: [(command: String, model: PromptModel, description: String)] = {
    var out: [(command: String, model: PromptModel, description: String)] = []
    for provider in ChatModelProvider.allCases {
      let def = provider.defaultChatModel
      out.append(("/\(provider.commandAlias)", def, "Switch to \(def.displayName)"))
      // Skip the per-model alias for the provider's default — the bare `/gemini` etc. already
      // targets it, so generating `/gemini35flash` too would be a redundant duplicate command.
      for model in PromptModel.chatModels where model.provider == provider && model != def {
        out.append(("/\(model.shortAlias)", model, "Switch to \(model.displayName)"))
      }
    }
    return out
  }()

  /// Maps every model-switch command (lowercased) to its target model, including the silent
  /// `/openai` alias for `/gpt`. Drives the generic model-switch dispatch in `sendMessage`.
  static let modelCommandLookup: [String: PromptModel] = {
    var dict = Dictionary(uniqueKeysWithValues: modelCommands.map { ($0.command, $0.model) })
    dict["/openai"] = ChatModelProvider.openai.defaultChatModel // silent alias for /gpt
    dict["/anthropic"] = ChatModelProvider.anthropic.defaultChatModel // silent alias for /claude
    return dict
  }()

  /// Non-model commands shown before / after the model-switch block. Kept separate so the model
  /// block can be re-sorted by recency for display without disturbing these fixed slots.
  static let commandsBeforeModels: [(command: String, description: String)] = [
    ("/new", "Start a new chat (previous chat stays in history)"),
    ("/screenshot", "Add a screenshot to your next message (can add multiple)"),
    ("/attach", "Open the file picker to attach files (PDF, images, text)"),
    ("/folder", "Share a folder so the chat can list, read, and search files in it"),
    ("/workspace", "Limit this chat to one shared folder, e.g. /workspace notes (`all` = every folder, `off` = none)"),
    ("/model", "Switch chat model (e.g. /model 3.1 flash lite)"),
  ]
  static let commandsAfterModels: [(command: String, description: String)] = [
    ("/think", "Set reasoning depth for this chat: minimal | low | medium | high | default"),
    ("/x", "Grok only: limit X search to these accounts, e.g. /x @karpathy @simonw (`/x off` = all of X)"),
    ("/settings", "Open Settings"),
    ("/pin", "Toggle whether the window stays open when losing focus"),
    ("/unpin", "Make the window close when losing focus"),
    ("/meeting", "Start or stop live meeting recording"),
    ("/copy", "Copy the entire chat history to clipboard as Markdown"),
    ("/feedback", "Message the developer, with the end of this chat attached"),
  ]

  /// All slash commands in canonical (provider-grouped) order. Used where order is irrelevant —
  /// `knownSlashCommands` (a set) and the system-prompt command list. The on-screen autocomplete
  /// uses `commandSuggestionsForDisplay`, which re-sorts the model block by recency.
  static let commandSuggestions: [(command: String, description: String)] =
    commandsBeforeModels + modelCommands.map { ($0.command, $0.description) } + commandsAfterModels

  /// Model-switch commands for display, ordered most-recently-used first (see `recordModelUse`).
  /// The currently active model is pulled out of the recency sort and appended last, labelled
  /// "Current model" — so the top row is the most-recently-used *other* model (one Enter away
  /// from toggling back), while the list still shows the complete lineup: a model missing from
  /// the suggestions reads as "the app dropped it", which it never is. Never-used models keep
  /// the canonical provider-grouped order at the bottom.
  func recentlyOrderedModelCommands() -> [(command: String, description: String)] {
    let recency = Self.loadModelRecency()
    let current = PromptModel.loadSelectedChatModel()
    let rank: (PromptModel) -> Int = { recency.firstIndex(of: $0.rawValue) ?? Int.max }
    let others = Self.modelCommands
      .filter { $0.model != current }
      .enumerated()
      .sorted { a, b in
        let ra = rank(a.element.model), rb = rank(b.element.model)
        return ra != rb ? ra < rb : a.offset < b.offset
      }
      .map { ($0.element.command, $0.element.description) }
    guard let currentEntry = Self.modelCommands.first(where: { $0.model == current }) else {
      return others
    }
    return others + [(currentEntry.command, "Current model — \(current.displayName)")]
  }

  /// Commands to show in UI: fixed commands around a recency-sorted model block (and excludes
  /// /new in single-chat mode).
  var commandSuggestionsForDisplay: [(command: String, description: String)] {
    var list = Self.commandsBeforeModels + recentlyOrderedModelCommands() + Self.commandsAfterModels
    if singleChatOnly {
      list = list.filter { $0.command != "/new" }
    }
    return list
  }

  /// When non-nil, this provider supplies extra context (e.g. meeting summary + recent transcript) appended to the system instruction. Used by the Meeting Chat window.
  private let meetingContextProvider: (() -> String?)?
  /// When true, exactly one chat per meeting: no tabs, no /new, no "New chat" button.
  let singleChatOnly: Bool

  init(meetingContextProvider: (() -> String?)? = nil, store: ChatSessionStore = .shared, singleChatOnly: Bool = false) {
    self.meetingContextProvider = meetingContextProvider
    self.store = store
    self.singleChatOnly = singleChatOnly
    session = store.load()
    currentSessionId = session.id
    messages = session.messages
    lastSendError = session.lastSendError
    recentSessions = store.recentSessions(limit: 20)
    allSessionsList = store.allSessions()
    loadScrollAnchors()
    isMeetingActive = LiveMeetingTranscriptStore.shared.isSessionActive
    isMeetingFinishing = LiveMeetingTranscriptStore.shared.isFinishing
    meetingFinishingCancellable = LiveMeetingTranscriptStore.shared.$isFinishing
      .receive(on: DispatchQueue.main)
      .sink { [weak self] in self?.isMeetingFinishing = $0 }
    meetingCancellable = LiveMeetingTranscriptStore.shared.$isSessionActive
      .receive(on: DispatchQueue.main)
      .sink { [weak self] active in
        guard let self else { return }
        self.isMeetingActive = active
        if active && self.meetingSessionId == nil {
          // Prefer reattaching to an existing ChatSession already associated with the
          // current meeting's stem (e.g. on resume), so we don't repurpose whichever
          // chat the user happens to be viewing.
          let stem = LiveMeetingTranscriptStore.shared.currentMeetingFilenameStem
          if let stem, let existing = self.store.allSessions().first(where: { $0.isMeeting && $0.meetingStem == stem }) {
            self.meetingSessionId = existing.id
            if self.session.id == existing.id {
              self.session.isMeeting = true
              self.session.meetingStem = stem
            }
            self.refreshRecentSessions()
          } else {
            self.meetingSessionId = self.session.id
            self.markCurrentSessionAsMeeting()
          }
        } else if !active {
          self.meetingSessionId = nil
        }
      }

    // When a meeting's final summary is ready, title its chat from that summary.
    // Only the main sidebar view model handles this (not the meeting window's).
    if !singleChatOnly {
      summaryCancellable = NotificationCenter.default.publisher(for: .chatMeetingSummaryReady)
        .receive(on: DispatchQueue.main)
        .sink { [weak self] note in
          guard let self,
                let stem = note.userInfo?["stem"] as? String,
                let summary = note.userInfo?["summary"] as? String else { return }
          Task {
            // No title-empty precheck here — `generateMeetingTitle` already early-returns when the
            // title is non-empty, and `generateAndApplyTitle` re-checks post-network before writing.
            guard let targetId = self.store.allSessions().first(where: { $0.isMeeting && $0.meetingStem == stem })?.id else { return }
            await self.generateMeetingTitle(targetId: targetId, summary: summary)
          }
        }
    }

    backfillMeetingTitleIfNeeded()
    if let notice = store.consumeCorruptionNotice() {
      errorMessage = notice
    }
  }

  func createNewSession() {
    // Reuse the current tab if it is already an empty "New chat" — avoids
    // spawning a row of identical empty tabs when the user hits Cmd+N
    // repeatedly. The user's composer draft is global and unaffected.
    if session.messages.isEmpty && (session.title?.isEmpty ?? true) && !session.isMeeting {
      DebugLogger.log("GEMINI-CHAT: Cmd+N reused empty current tab \(session.id)")
      return
    }
    let newSession = store.createNewSession()
    session = newSession
    currentSessionId = newSession.id
    messages = []
    errorMessage = nil
    lastSendError = nil
    inputText = ""
    pendingScreenshots = []
    refreshRecentSessions()
    DebugLogger.log("GEMINI-CHAT: Switched to new chat")
  }

  private func switchToCurrentStoreSession() {
    session = store.load()
    currentSessionId = session.id
    messages = session.messages
    errorMessage = nil
    lastSendError = session.lastSendError
    pendingScreenshots = []
    refreshRecentSessions()
    backfillMeetingTitleIfNeeded()
  }

  /// Maximum number of screenshots that can be attached to one message.
  private static let maxPendingScreenshots = 10

  /// Injected by the view so the VM can respect the in-composer screenshot count
  /// when the inline composer already holds the attachments (legacy `pendingScreenshots`
  /// is drained into the composer by the view).
  var composerScreenshotCountProvider: () -> Int = { 0 }

  /// Injected by the view so the VM can respect the in-composer file count.
  var composerFileCountProvider: () -> Int = { 0 }

  /// Sends a message whose content and attachments were already assembled by the inline
  /// composer in document order. Slash commands are filtered out upstream by
  /// `submitComposer`, so this path only sees real chat content; it either dispatches via
  /// `performSend` or appends to the FIFO queue drained by `processNextQueued`.
  func sendComposed(finalContent: String, attachedParts: [AttachedImagePart]) async {
    let hasContent = !finalContent.isEmpty || !attachedParts.isEmpty
    guard hasContent else { return }

    errorMessage = nil
    // FIFO: a message sent while the model is still answering waits its turn instead of
    // killing the running request. The queue is also checked directly because `performSend`
    // marks the session as sending synchronously but the next drain can still be one
    // MainActor hop away — without it a fast second Enter could overtake a queued message.
    if isSending || messageQueue.contains(where: { $0.sessionId == session.id }) {
      messageQueue.append(
        QueuedChatMessage(
          sessionId: session.id, content: finalContent, attachedParts: attachedParts))
      DebugLogger.log("GEMINI-CHAT: Queued composed message, queue size: \(messageQueue.count)")
      return
    }
    performSend(content: finalContent, attachedParts: attachedParts)
  }

  /// Re-sends the user message identified by `id`: the message and everything after it
  /// (the model's response) are removed from the session, then the same content and
  /// attachments are dispatched as a fresh send. Only offered on the last user message,
  /// so nothing the user still cares about gets truncated.
  func retryMessage(id: UUID) {
    guard !isSending else {
      showNotice("Wait for the current response to finish (or press Stop).")
      return
    }
    guard !messageQueue.contains(where: { $0.sessionId == session.id }) else {
      showNotice("Retry is unavailable while queued messages are pending. Remove them first.")
      return
    }
    let sessionId = session.id
    guard let index = session.messages.firstIndex(where: { $0.id == id }),
          session.messages[index].role == .user else { return }
    let original = session.messages[index]
    var target = session
    target.messages.removeSubrange(index...)
    target.lastUpdated = Date()
    target.lastSendError = nil
    store.save(target)
    scrollAnchorClearSignal.send()
    session = target
    messages = target.messages
    errorMessage = nil
    lastSendError = nil
    DebugLogger.log(
      "CHAT: Retry message (contentLen=\(original.content.count), attachments=\(original.attachedImageParts.count)) session=\(sessionId)")
    // Emitted before the re-send, while `refTs` still points at the answer being rejected: once
    // `performSend` logs the replacement turn, the marker moves on.
    ContextLogger.shared.logSignal(
      .chatRetry, mode: "geminiChat", detail: ["model": Self.openChatModel.rawValue])
    performSend(content: original.content, attachedParts: original.attachedImageParts)
  }

  func captureScreenshot() async {
    guard !screenshotCaptureInProgress else { return }
    let totalCount = pendingScreenshots.count + composerScreenshotCountProvider()
    if totalCount >= Self.maxPendingScreenshots {
      errorMessage = "Maximum number of screenshots reached (\(Self.maxPendingScreenshots))."
      return
    }
    screenshotCaptureInProgress = true
    errorMessage = nil
    DebugLogger.log("GEMINI-CHAT: Starting screen capture (window will hide briefly)")
    let data = await ChatWindowManager.shared.captureScreenExcludingChatWindow()
    screenshotCaptureInProgress = false
    if let data = data {
      pendingScreenshots.append(data)
      DebugLogger.log("GEMINI-CHAT: Screenshot \(pendingScreenshots.count) attached to next message")
      if ScreenshotSaveLocation.isEnabled {
        ScreenshotSaveLocation.save(data)
      }
    } else {
      errorMessage = "Screen capture failed. Opening Privacy & Permissions..."
      DebugLogger.logWarning("GEMINI-CHAT: Screen capture returned nil, opening Privacy & Permissions")
      SettingsManager.shared.showPrivacyPermissions()
    }
  }

  func removePendingScreenshot(at index: Int) {
    guard index >= 0, index < pendingScreenshots.count else { return }
    pendingScreenshots.remove(at: index)
  }

  func clearPendingScreenshots() {
    pendingScreenshots = []
  }

  func clearPendingFiles() {
    pendingFileAttachments = []
  }

  /// Clears typed text, paste blocks, and file attachments. Pending screenshots are kept.
  func resetPendingComposerContent() {
    pastedBlocks = []
    pendingFileAttachments = []
    inputText = ""
  }

  /// Maximum number of file attachments (images, PDFs, etc.) per message. Self-imposed, not a
  /// provider limit — Gemini/OpenAI/xAI all accept far more per request (hundreds+). Kept at 10 to
  /// match `maxPendingScreenshots` and to bound request size / token cost.
  private static let maxFileAttachments = 10

  func attachFile() {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false
    panel.allowedContentTypes = [.pdf, .png, .jpeg, .gif, .webP, .plainText]
    panel.message = "Select files to attach to your next message"
    // C2: reopen wherever we last attached from; first time fall back to the screenshot folder.
    if let lastPath = UserDefaults.standard.string(forKey: UserDefaultsKeys.lastAttachDirectoryPath) {
      panel.directoryURL = URL(fileURLWithPath: lastPath)
    } else if let screenshotFolder = ScreenshotSaveLocation.resolveFolderURL() {
      panel.directoryURL = screenshotFolder
    }
    guard panel.runModal() == .OK else { return }

    if let attachedDir = panel.urls.first?.deletingLastPathComponent().path {
      UserDefaults.standard.set(attachedDir, forKey: UserDefaultsKeys.lastAttachDirectoryPath)
    }

    let currentFileCount = pendingFileAttachments.count + composerFileCountProvider()
    let remaining = Self.maxFileAttachments - currentFileCount
    if remaining <= 0 {
      errorMessage = "Maximum number of file attachments reached (\(Self.maxFileAttachments))."
      return
    }

    let urls = Array(panel.urls.prefix(remaining))
    if panel.urls.count > remaining {
      errorMessage = "Only \(remaining) of \(panel.urls.count) files attached (limit: \(Self.maxFileAttachments))."
    }

    var failedNames: [String] = []
    var oversizedNames: [String] = []
    for url in urls {
      let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
      if size > AppConstants.maxFileSizeBytes {
        oversizedNames.append(url.lastPathComponent)
        continue
      }
      guard let data = try? Data(contentsOf: url) else {
        failedNames.append(url.lastPathComponent)
        continue
      }
      if data.count > AppConstants.maxFileSizeBytes {
        oversizedNames.append(url.lastPathComponent)
        continue
      }
      let mimeType = Self.mimeType(for: url)
      pendingFileAttachments.append(PendingFile(data: data, mimeType: mimeType, filename: url.lastPathComponent))
      DebugLogger.log("GEMINI-CHAT: File attached: \(url.lastPathComponent) (\(mimeType), \(data.count) bytes)")
    }
    if !oversizedNames.isEmpty {
      errorMessage = Self.attachmentTooLargeMessage(filenames: oversizedNames)
    }
    if !failedNames.isEmpty {
      errorMessage = "Could not read: \(failedNames.joined(separator: ", "))"
    }
  }

  static func attachmentTooLargeMessage(filenames: [String]) -> String {
    let names = filenames.map { "\"\($0)\"" }.joined(separator: ", ")
    let verb = filenames.count == 1 ? "is" : "are"
    return "\(names) \(verb) larger than \(AppConstants.maxFileSizeDisplay) and \(filenames.count == 1 ? "wasn't" : "weren't") attached."
  }

  // MARK: - Workspace folders

  /// Shares folders with the chat from inside the chat, via `/folder` or the toolbar button.
  ///
  /// Picking here is what actually grants the sandboxed app access — the panel hands back a
  /// security-scoped bookmark. Settings → Chat lists and removes them; this is the in-the-moment
  /// grant, because "let me read that folder" is a thought the user has *while* chatting.
  func shareFolder() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = true
    panel.prompt = "Share"
    panel.message = "Choose folders the chat may read"
    guard panel.runModal() == .OK else { return }
    addWorkspaceFolders(panel.urls)
  }

  /// Adds folders dropped onto the chat window. A drop is a user-intent gesture, so macOS grants
  /// the sandbox access to the dropped URL exactly as it does for an open panel — which is what
  /// makes the bookmark below valid. Non-directories are ignored: dropping a *file* into a chat
  /// means "attach this", not "share its folder", and silently widening access would be wrong.
  func addWorkspaceFolders(_ urls: [URL]) {
    var added: [String] = []
    var failed: [String] = []
    for url in urls {
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
        isDirectory.boolValue
      else { continue }
      if WorkspaceFolders.addFolder(url) {
        added.append(url.lastPathComponent)
      } else {
        failed.append(url.lastPathComponent)
      }
    }

    if !failed.isEmpty {
      errorMessage = "Could not share: \(failed.joined(separator: ", "))"
    }
    guard !added.isEmpty else { return }

    let names = added.map { "`\($0)`" }.joined(separator: ", ")
    let all = WorkspaceFolders.displayPaths.map { ($0 as NSString).abbreviatingWithTildeInPath }
    appendModelMessage(
      "Shared \(names) with this chat. I can now list, read, and search files in: "
        + all.map { "`\($0)`" }.joined(separator: ", ")
        + "\n\nManage or remove folders in Settings → Chat → Workspace Folders.")
  }

  private static func mimeType(for url: URL) -> String {
    UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
      ?? "application/octet-stream"
  }

  func togglePin() {
    let closeOnFocusLoss = UserDefaults.standard.object(forKey: UserDefaultsKeys.chatCloseOnFocusLoss) as? Bool
      ?? SettingsDefaults.chatCloseOnFocusLoss
    let newValue = !closeOnFocusLoss
    UserDefaults.standard.set(newValue, forKey: UserDefaultsKeys.chatCloseOnFocusLoss)
    let nowPinned = !newValue
    DebugLogger.log("GEMINI-CHAT: /pin — window is now \(nowPinned ? "pinned (stays open)" : "unpinned (closes on focus loss)")")
    showNotice(nowPinned
      ? "Window pinned — it stays open when it loses focus."
      : "Window unpinned — it closes when it loses focus.")
  }

  func unpin() {
    UserDefaults.standard.set(true, forKey: UserDefaultsKeys.chatCloseOnFocusLoss)
    DebugLogger.log("GEMINI-CHAT: /unpin — window is now unpinned (closes on focus loss)")
    showNotice("Window unpinned — it closes when it loses focus.")
  }

  /// Stops the currently visible session: cancels the in-flight request *and* drops
  /// everything still queued for it. Without dropping the queue, Stop would look like a
  /// no-op — the next queued message would start streaming the moment the current one dies.
  func cancelSend() {
    let sid = session.id
    let dropped = messageQueue.filter { $0.sessionId == sid }.count
    messageQueue.removeAll { $0.sessionId == sid }
    if dropped > 0 {
      DebugLogger.log("GEMINI-CHAT: Stop — dropped \(dropped) queued message(s) for this chat")
    }
    // Record that *this* cancellation came from the user before triggering it. The watchdog
    // cancels the very same task through `StallCancellationRegistry`, and by the time
    // `CancellationError` is caught the two are indistinguishable — so the verdict has to be
    // stamped here, at the only place that knows a human pressed Stop.
    userCancelledSessions[sid] = dropped
    sendTasks[sid]?.cancel()
  }

  /// Copies the given session's full message history to the clipboard as Markdown.
  /// Empty sessions and missing-session lookups produce a notice but no clipboard write.
  func copyChatToClipboard(sessionId: UUID) {
    guard let target = store.session(by: sessionId) else {
      showNotice("Chat not found.")
      return
    }
    guard !target.messages.isEmpty else {
      showNotice("Chat is empty — nothing to copy.")
      return
    }
    let markdown = Self.renderChatAsMarkdown(target)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(markdown, forType: .string)
    showNotice("Chat copied to clipboard (\(target.messages.count) messages).")
    DebugLogger.log("GEMINI-CHAT: Copied chat (\(target.messages.count) messages, \(markdown.count) chars) to clipboard")
  }

  /// `/feedback` — opens WhatsApp with the tail of this chat already quoted.
  ///
  /// This is the lowest-friction report the app can offer: the user is already typing sentences
  /// about their problem here, so the alternative is asking them to describe it a second time
  /// somewhere else. The transcript is *prefilled*, not sent — WhatsApp opens with the text
  /// visible and the user presses send, so nothing from their chat leaves the machine unseen.
  func sendFeedbackFromChat() {
    let excerpt = recentTranscriptForFeedback()
    let context = excerpt.isEmpty
      ? nil
      : "Here is the end of my chat for context:\n\n\(excerpt)"
    guard FeedbackLinks.open(.whatsApp, context: context) else {
      showNotice("Couldn't open WhatsApp — use Settings → About for the other contact options.")
      return
    }
    showNotice(
      excerpt.isEmpty
        ? "Opened WhatsApp. Edit the message before sending."
        : "Opened WhatsApp with the end of this chat attached. Edit before sending.")
  }

  /// The last few turns of this chat, oldest first, clamped to what a URL can carry.
  private func recentTranscriptForFeedback() -> String {
    let recent = messages.suffix(6)
    guard !recent.isEmpty else { return "" }
    let rendered = recent.map { message -> String in
      let who = message.role == .user ? "Me" : "Assistant"
      // One line per turn: a pasted multi-line reply makes the WhatsApp draft unreadable.
      let body = message.content
        .replacingOccurrences(of: "\n", with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      return "\(who): \(FeedbackLinks.truncated(body, limit: 300))"
    }.joined(separator: "\n")
    return FeedbackLinks.truncated(rendered, limit: 1200)
  }

  private func showNotice(_ text: String) {
    noticeMessage = text
    noticeDismissTask?.cancel()
    noticeDismissTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 2_500_000_000)
      guard !Task.isCancelled else { return }
      self?.noticeMessage = nil
    }
  }

  private static func renderChatAsMarkdown(_ s: ChatSession) -> String {
    let df = ISO8601DateFormatter()
    df.formatOptions = [.withInternetDateTime]
    var lines: [String] = []
    let trimmedTitle = s.title?.trimmingCharacters(in: .whitespaces) ?? ""
    let title = trimmedTitle.isEmpty ? "Chat" : trimmedTitle
    lines.append("# \(title)")
    lines.append("_\(df.string(from: s.lastUpdated))_")
    lines.append("")
    for msg in s.messages {
      let header = msg.role == .user ? "## User" : "## Assistant"
      lines.append(header)
      let attachmentNote = msg.attachedImageParts.isEmpty
        ? ""
        : msg.attachedImageParts
            .map { part -> String in
              let name = part.filename ?? "unnamed"
              let mt = part.mimeType ?? ""
              let kind: String
              if mt.hasPrefix("image/") { kind = "image" }
              else if mt == "application/pdf" { kind = "PDF" }
              else if mt.isEmpty { kind = "file" }
              else { kind = mt }
              return "_[attachment: \(name) (\(kind))]_"
            }
            .joined(separator: "\n") + "\n\n"
      // Strip ⟦GEMINI_IMG:…⟧ markers — without this, copying a chat that contains a
      // generated image dumps multi-MB base64 onto the clipboard.
      lines.append(attachmentNote + GeminiAPIClient.stripImageMarkers(msg.content))
      lines.append("")
    }
    return lines.joined(separator: "\n")
  }

  // MARK: - Send helpers & Queue

  /// Core send: appends the user message, calls the API, and drains the next queued message on completion.
  /// Gemini 3.x models occasionally leak their raw reasoning-channel delimiter tokens
  /// (`start_thought` / `end_thought`) into the visible answer instead of routing them to a
  /// separate thought part — see the thinkingLevel fix in `PromptModel.geminiThinkingConfig`.
  /// This is a belt-and-suspenders strip so the user never sees them even if Gemini regresses.
  /// Runs on the *cumulative* streamed text, so a token split across stream chunks is still caught.
  /// Harmless for OpenAI/Grok, which never emit these tokens.
  static func stripLeakedThoughtTokens(_ text: String) -> String {
    var cleaned = text
    for marker in ["start_thought", "end_thought"] {
      cleaned = cleaned.replacingOccurrences(of: marker, with: "")
    }
    // The markers normally sit at the very start; drop the whitespace they leave behind there.
    // Leading whitespace is never meaningful in a chat answer, so this is safe.
    while let first = cleaned.first, first == " " || first == "\n" { cleaned.removeFirst() }
    return cleaned
  }

  private func performSend(
    content: String, attachedParts: [AttachedImagePart], toSessionId: UUID? = nil
  ) {
    let sessionId = toSessionId ?? session.id
    // Marked *before* the Task so `isSending` is true the instant this returns. The Task body
    // starts one MainActor hop later; a message sent inside that window would otherwise skip
    // the queue and be dispatched concurrently, out of order.
    sendingSessionIds.insert(sessionId)
    let task = Task {
      // Freeze-relevant state snapshot: a hang during send/stream wedges the main thread and
      // silences later logs, so capture the conditions here while we still can. The watchdog
      // (MainThreadWatchdog) then samples the stack if the main thread stops responding.
      let sessionMsgCount = (sessionId == session.id ? messages.count : (store.session(by: sessionId)?.messages.count ?? -1))
      let attachedBytes = attachedParts.reduce(0) { $0 + $1.data.count }
      DebugLogger.log(
        "CHAT-SEND: start session=\(sessionId) msgs=\(sessionMsgCount) contentChars=\(content.count) "
        + "attachedImages=\(attachedParts.count) attachedBytes=\(attachedBytes) "
        + "inFlightSessions=\(sendingSessionIds.count) queued=\(messageQueue.count)")
      // Breadcrumb for the watchdog: if the main thread wedges during the stream/render, the
      // captured hang file is tagged with this instead of just a SwiftUI stack.
      MainThreadWatchdog.shared.note("chat-send streaming session=\(sessionId) msgs=\(sessionMsgCount)")
      defer {
        DebugLogger.log("CHAT-SEND: teardown session=\(sessionId)")
        MainThreadWatchdog.shared.note("idle")
        sendingSessionIds.remove(sessionId)
        sendTasks.removeValue(forKey: sessionId)
        StallCancellationRegistry.shared.unregister(sessionId)
        // `ChatViewModel` is `@MainActor`, so this Task inherits MainActor — no explicit hop needed.
        self.processNextQueued()
      }
      let selectedModel = Self.openChatModel
      guard validateCredential(for: selectedModel) else { return }

      let provider = LLMProviderFactory.provider(for: selectedModel)
      let model = selectedModel.rawValue

      let userMsg = ChatMessage(role: .user, content: content, attachedImageParts: attachedParts)
      appendMessage(userMsg, toSessionId: sessionId)
      var currentContents = buildContents(forSessionId: sessionId)
      // A send can target a background session (the user switched chats mid-stream), so per-session
      // knobs come from that session, not whichever one is on screen.
      let sendingSession = sessionId == session.id ? session : store.session(by: sessionId)
      let thinkingLevel = sendingSession?.thinkingLevel ?? .default
      let xHandles = sendingSession.map(effectiveXHandles(for:)) ?? XSearchHandles.defaultHandles
      let placeholderId = UUID()
      // Reply accumulation is split in two so the per-token work below never re-scans marker
      // bytes: `markerPrefix` holds finalized content including ⟦GEMINI_IMG:…⟧ markers
      // (multi-MB base64), `streamed` only the model text since the last marker fold. The
      // displayed/persisted reply is always `markerPrefix + streamed`.
      var markerPrefix = ""
      var streamed = ""
      // Gemini 3.x can leak `start_thought`/`end_thought` into the visible answer, but only ever
      // in its opening region (see `stripLeakedThoughtTokens`). Once the reply has grown past that
      // zone we stop re-scanning the whole accumulated string on every token — that scan was O(N)
      // per token (O(N²) over the reply) on the MainActor. Reset when `streamed` restarts after an
      // image-marker fold, since fresh narration begins there.
      var thoughtStripSettled = false
      // Consecutive in-place-status ignores (same trailing sentence, not appended).
      // Three of these must stop the stream even though `streamed` stayed at one copy.
      var duplicateStatusStreak = 0
      var loopDeltaIndex = 0
      persistLastSendError(nil, sessionId: sessionId)
      do {
        let placeholder = ChatMessage(id: placeholderId, role: .model, content: "")
        appendMessage(placeholder, toSessionId: sessionId)
        let streamingBuffer = self.attachStreamingBuffer(for: placeholderId)

        // Asking about a live meeting: the newest audio is still inside the recorder, so cut it and
        // wait (briefly) for its transcript before the request goes out. Without this the model is
        // shown a transcript that stops up to a full chunk before the question — exactly the moment
        // the user is asking about. Deliberately after the placeholder: the question and the thinking
        // indicator are already on screen, so the wait reads as the model working, not as a freeze.
        // Keyed on `sessionId`, not the on-screen session: a send can target a background tab.
        if isMeetingActive, meetingSessionId == sessionId {
          await LiveMeetingTranscriptStore.shared.flushPendingAudio()
          // Now that the last segment exists, let the note stream cover it too.
          NotificationCenter.default.post(name: .liveMeetingNotesRefreshRequested, object: nil)
        }

        var finalSources: [GroundingSource] = []
        var finalSupports: [GroundingSupport] = []
        var truncatedFinish = false
        let tools = buildToolDeclarations(for: sendingSession)
        // 8 was too tight for batch work: "move every dateless task to today" spends two rounds
        // discovering the list and then one per task, because the model emits its edits one call at
        // a time even though they are independent. Hitting the cap mid-batch leaves the user's data
        // half-changed with no summary, which is far worse than a few extra round trips.
        let maxToolRounds = 16
        let useGrounding = selectedModel.supportsGrounding
        var toolLoopExhausted = false
        // Counts the tool calls executed this turn. Lets us tell an empty final turn that
        // *followed* tool work (model searched, found nothing relevant, returned no summary) apart
        // from a model that just said nothing — the two warrant different fallback copy — and lets
        // the exhaustion copy say how much work actually ran.
        var executedToolCalls = 0

        toolLoop: for round in 0..<(maxToolRounds + 1) {
          // Final round: strip every tool so the model is forced to synthesize an answer from
          // what it already gathered, instead of firing yet another tool call we'd discard. Without
          // this, a model that keeps searching (e.g. re-querying Gmail with reworded terms) ends the
          // loop on an unanswered batch of function calls and the user is shown nothing.
          let isFinalRound = (round == maxToolRounds)
          var pendingCalls: [(name: String, args: [String: Any], thoughtSignature: String?)] = []
          // Narration the model emits in THIS round; echoed back in the model turn that carries
          // the round's function calls so the re-sent history is faithful (see executeToolCalls).
          var roundText = ""
          let stream = provider.sendChatStream(
            model: model,
            contents: currentContents,
            systemInstruction: self.buildSystemInstruction(for: sendingSession),
            tools: isFinalRound ? [] : tools,
            options: ChatRequestOptions(
              useGrounding: useGrounding,
              thinkingLevel: thinkingLevel,
              disableBuiltInTools: isFinalRound,
              // Stable per-session key → provider prompt-cache hits across turns
              // (OpenAI prompt_cache_key, Grok x-grok-conv-id). Gemini ignores it.
              cacheKey: sessionId.uuidString,
              xHandles: xHandles))
          for try await event in stream {
            try Task.checkCancellation()
            switch event {
            case .textDelta(let delta):
              roundText = ChatStreamLoopGuard.mergeDelta(streamed: roundText, delta: delta)
              let merge = ChatStreamLoopGuard.merge(streamed: streamed, delta: delta)
              streamed = merge.text
              let trimmedDelta = delta.trimmingCharacters(in: .whitespacesAndNewlines)
              if merge.kind == .ignored, !trimmedDelta.isEmpty {
                duplicateStatusStreak += 1
              } else if merge.kind != .ignored {
                duplicateStatusStreak = 0
              }
              // Only strip while still in the marker zone. Once stripped, `streamed` never
              // re-acquires a start-anchored marker (deltas append at the end), so re-scanning
              // the whole string every subsequent token is pure waste.
              if !thoughtStripSettled {
                streamed = Self.stripLeakedThoughtTokens(streamed)
                if streamed.utf8.count > 512 { thoughtStripSettled = true }
              }
              streamingBuffer.enqueueUpdate(markerPrefix + streamed)
              loopDeltaIndex += 1
              // Gemini can repeat the same status sentence for minutes. Stop only this
              // stream so the good prefix is kept. Do NOT call `cancelSend()` — that
              // also drops the session queue, which would discard the "1 queued" turn.
              // Breaking `toolLoop` releases the AsyncThrowingStream iterator; Gemini's
              // `onTermination` cancels the URLSession task the same way a consumer stop
              // does, then we finalize the partial normally (queue still drains).
              if ChatStreamLoopGuard.shouldStop(
                streamed: streamed, ignoredStreak: duplicateStatusStreak, deltaIndex: loopDeltaIndex
              ) {
                DebugLogger.logWarning(
                  "CHAT: stream loop detected — stopping this reply without dropping the queue (chars=\(streamed.count))")
                streamed = ChatStreamLoopGuard.appendStopNotice(to: streamed)
                streamingBuffer.setContentImmediate(markerPrefix + streamed)
                break toolLoop
              }
            case .functionCall(let name, let args, let thoughtSignature):
              pendingCalls.append((name, args, thoughtSignature))
            case .finished(let sources, let supports, let finishReason):
              finalSources = sources
              finalSupports = supports
              if Self.isTruncatedFinishReason(finishReason) { truncatedFinish = true }
            }
          }
          if pendingCalls.isEmpty { break toolLoop }
          // Tools were already disabled this round, yet the model still emitted only function
          // calls and no usable text — nothing left to try, so surface the exhaustion.
          if isFinalRound {
            DebugLogger.logWarning(
              "CHAT: tool loop exceeded \(maxToolRounds) rounds after \(executedToolCalls) call(s) — stopping (final round wanted \(pendingCalls.map(\.name).joined(separator: ", ")))")
            toolLoopExhausted = true
            break toolLoop
          }
          executedToolCalls += pendingCalls.count
          let (turns, imageMarkers) = try await executeToolCalls(
            pendingCalls, narration: Self.stripLeakedThoughtTokens(roundText), sessionId: sessionId)
          // Generated images go straight into the streaming bubble: the image shows up the
          // moment the tool finishes, and the model's follow-up narration streams below it.
          // The marker becomes part of the persisted message content (rendered inline);
          // buildContents strips it again before re-sending history.
          if !imageMarkers.isEmpty {
            let joined = imageMarkers.joined(separator: "\n\n")
            // Trailing break: the model's follow-up narration streams directly after the
            // marker block, and a glued `…⟧Text` paragraph wouldn't render as an image.
            let current = markerPrefix + streamed
            markerPrefix = (current.isEmpty ? joined : current + "\n\n" + joined) + "\n\n"
            streamed = ""
            thoughtStripSettled = false
            duplicateStatusStreak = 0
            loopDeltaIndex = 0
            streamingBuffer.setContentImmediate(markerPrefix)
          }
          currentContents.append(contentsOf: turns)
        }

        // A cancelled turn must never reach the fallback copy below: cancelling the task makes
        // the provider's `AsyncThrowingStream` *finish* rather than throw, so the loop above
        // exits normally with an empty reply and the turn would be persisted as "(no response)".
        // This check routes cancellation to the `CancellationError` handler instead.
        try Task.checkCancellation()

        // Make sure the user sees *something* if the model produced no text.
        // This happens e.g. when the tool loop exhausts mid-batch (lots of
        // function calls, no narration) — the assistant bubble would otherwise
        // be empty, hiding the failure.
        // Final belt-and-suspenders strip: streaming now stops re-scanning past the marker zone
        // (see `thoughtStripSettled`), so a marker leaking later would otherwise reach the saved
        // message. One strip here restores the "user never sees them" guarantee at O(N)-once cost.
        var reply = Self.stripLeakedThoughtTokens(markerPrefix + streamed)
        if reply.isEmpty {
          if toolLoopExhausted {
            // Say what actually happened: the model kept working and hit the round cap. The old
            // copy claimed nothing was found, which reads as a failure even though every one of
            // those calls ran — a create/delete batch had already changed the user's data.
            let calls = executedToolCalls == 1 ? "1 tool call" : "\(executedToolCalls) tool calls"
            reply = "_I hit the tool-call round limit after \(calls) and stopped before writing an answer. Anything I already did has taken effect — ask me to recap it, or narrow the request so it needs fewer steps._"
          } else if executedToolCalls > 0 {
            // The model ran tools (e.g. gmail_search) but then ended its turn
            // with no summary — typically because the results were empty or
            // unrelated. A bare "(no response)" hides that; say what happened.
            DebugLogger.logWarning("CHAT: empty final turn after tool calls — surfacing no-results fallback")
            reply = "_I looked into this with the available tools but didn't find anything relevant to summarize. Try narrowing the request — e.g. name a specific sender, subject, or date range._"
          } else {
            reply = "_(no response)_"
          }
        }
        if truncatedFinish {
          let note = "_Reply was truncated._"
          if reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            reply = note
          } else if !reply.contains("Reply was truncated") {
            reply = reply + "\n\n" + note
          }
        }

        // Final swap: streaming bubble (no sources) -> finalized message WITH grounding
        // sources. This one-shot content change is the layout-heaviest moment of a send;
        // if the next render wedges the main thread, "final UI update committed" will be
        // absent from the log while "finalizing" is the last line — pinpointing the hang.
        DebugLogger.log("CHAT-SEND: finalizing message sources=\(finalSources.count) supports=\(finalSupports.count) contentLen=\(reply.count) session=\(sessionId)")
        MainThreadWatchdog.shared.note("chat-send finalizing contentLen=\(reply.count) sources=\(finalSources.count)")
        self.detachStreamingBuffer(for: placeholderId)
        self.updateStreamingMessage(
          id: placeholderId, sessionId: sessionId,
          content: reply, sources: finalSources, supports: finalSupports)
        DebugLogger.log("CHAT-SEND: final UI update committed session=\(sessionId)")
        let result = (text: reply, sources: finalSources, supports: finalSupports)
        // Strip generated-image markers (multi-MB base64) before the interaction log.
        let strippedReply = GeminiAPIClient.stripImageMarkers(result.text)
        DebugRawResponses.saveIfEnabled(content: strippedReply, model: model)
        ContextLogger.shared.logChat(
          userMessage: content,
          modelResponse: strippedReply,
          model: model)
        // Typed chat text is ground-truth spelling: unknown proper nouns that sound like a
        // differently spelled recent transcript word go straight into the Whisper Glossary.
        GlossaryFastLearner.shared.learnFromTypedText(content)
        // Title once, after the first real user→model exchange. Counting user messages (rather
        // than total messages) keeps this working when the chat opens with a local command reply
        // such as "Model set to Grok 4.3." from `/grok`, which would otherwise push the total past 2.
        if let s = store.session(by: sessionId), !s.isMeeting,
           s.messages.filter({ $0.role == .user }).count == 1 {
          Task { await generateAITitle(sessionId: sessionId) }
        }
        ReviewPrompter.shared.recordSuccessfulOperation()
        self.persistLastSendError(nil, sessionId: sessionId)
      } catch is CancellationError {
        let partialChars = markerPrefix.count + streamed.count
        let droppedByUser = self.userCancelledSessions.removeValue(forKey: sessionId)
        DebugLogger.log("CHAT: Send cancelled (partialChars=\(partialChars))")
        ContextLogger.shared.logSignal(
          .chatStopped,
          mode: "geminiChat",
          detail: [
            "reason": droppedByUser != nil ? "user" : "stall",
            "partialChars": String(partialChars),
            "dropped": String(droppedByUser ?? 0),
          ])
        self.commitPartialOrRemove(
          placeholderId: placeholderId, sessionId: sessionId,
          partial: Self.stripLeakedThoughtTokens(markerPrefix + streamed))
      } catch {
        self.commitPartialOrRemove(
          placeholderId: placeholderId, sessionId: sessionId,
          partial: Self.stripLeakedThoughtTokens(markerPrefix + streamed))
        let friendly = self.friendlyError(error, provider: selectedModel.provider)
        self.persistLastSendError(friendly, sessionId: sessionId)
        if sessionId == session.id { errorMessage = friendly }
        DebugLogger.logError("CHAT: \(error.localizedDescription)")
      }
    }
    sendTasks[sessionId] = task
    // Also expose the task to the watchdog so a main-thread stall during streaming can cancel it
    // (see StallCancellationRegistry). Unregistered in the task's `defer` above.
    StallCancellationRegistry.shared.register(sessionId, task: task)
  }

  private func validateCredential(for model: PromptModel) -> Bool {
    guard model.provider.hasCredential else {
      errorMessage = model.provider.credentialRequiredMessage
      return false
    }
    return true
  }

  /// Tool declarations for a specific chat session. A send can target a background tab, so
  /// meeting/workspace gates must follow that session — not whichever one is on screen.
  private func buildToolDeclarations(for target: ChatSession? = nil) -> [LLMToolDeclaration] {
    let s = target ?? session
    let calendarConnected = GoogleAccountOAuthService.shared.isConnected
    let trelloConnected = TrelloOAuthService.shared.isConnected
    // Image generation renders via the Gemini image model regardless of the chat model,
    // so the tool is offered exactly when a Gemini credential exists.
    let imageGenerationAvailable = GeminiCredentialProvider.shared.hasCredential()
    return ChatToolRegistry.allDeclarations(
      calendarConnected: calendarConnected,
      trelloConnected: trelloConnected,
      imageGenerationAvailable: imageGenerationAvailable,
      meetingContext: s.isMeeting,
      workspaceAvailable: !WorkspaceFolders.displayPaths(scope: workspaceScope(for: s)).isEmpty,
      workspaceWritable: WorkspaceWriteAccess.isEnabled
    ).compactMap { decl in
      guard let name = decl["name"] as? String,
            let desc = decl["description"] as? String,
            let params = decl["parameters"] as? [String: Any] else { return nil }
      return LLMToolDeclaration(name: name, description: desc, parameters: params)
    }
  }

  private func executeToolCalls(
    _ calls: [(name: String, args: [String: Any], thoughtSignature: String?)],
    narration: String,
    sessionId: UUID
  ) async throws -> (turns: [[String: Any]], imageMarkers: [String]) {
    var callParts: [[String: Any]] = calls.map { call in
      var part: [String: Any] = ["functionCall": ["name": call.name, "args": call.args]]
      if let sig = call.thoughtSignature { part["thoughtSignature"] = sig }
      return part
    }
    // Echo the narration the model emitted alongside the calls: the function-calling contract
    // (Gemini docs; the Responses/Chat Completions converters mirror it) expects the model turn
    // re-sent as received. Without it the model can't see what it already told the user
    // mid-loop and may repeat itself across rounds.
    if !narration.isEmpty {
      callParts.insert(["text": narration], at: 0)
    }
    var responseParts: [[String: Any]] = []
    // ⟦GEMINI_IMG:…⟧ markers produced by generate_image. They go straight into the chat
    // bubble (via performSend), NOT back through the model — the functionResponse only
    // carries a short status, so megabytes of base64 never enter the model's context.
    var imageMarkers: [String] = []
    let context = makeToolContext(sessionId: sessionId)
    for call in calls {
      try Task.checkCancellation()
      if ChatToolRegistry.requiresUserApproval(call.name) {
        let summary = ChatToolRegistry.approvalSummary(name: call.name, args: call.args)
        let allowed = await confirmToolCall(name: call.name, summary: summary)
        if !allowed {
          DebugLogger.log("CHAT-TOOL-DENIED: \(call.name)")
          responseParts.append([
            "functionResponse": [
              "name": call.name,
              "response": ["error": "The user denied this \(call.name) call."],
            ]
          ])
          continue
        }
      }
      DebugLogger.log("CHAT-TOOL-CALL: \(call.name) args=\(Self.compactDescription(call.args))")
      let outcome = await ChatToolRegistry.execute(
        name: call.name, args: call.args, context: context)
      imageMarkers.append(contentsOf: outcome.imageMarkers)
      DebugLogger.log("CHAT-TOOL-RESULT: \(call.name) -> \(Self.compactDescription(outcome.response))")
      responseParts.append(["functionResponse": ["name": call.name, "response": outcome.response]])
    }
    DebugLogger.log("CHAT: executed \(calls.count) tool call(s), continuing stream")
    let turns: [[String: Any]] = [
      ["role": "model", "parts": callParts],
      ["role": "user", "parts": responseParts],
    ]
    return (turns, imageMarkers)
  }

  /// Per-turn confirmation for mutating tools. Nothing is remembered.
  @MainActor
  private func confirmToolCall(name: String, summary: String) async -> Bool {
    let alert = NSAlert()
    alert.messageText = "Allow \(name)?"
    alert.informativeText = summary
    alert.alertStyle = .informational
    alert.addButton(withTitle: "Allow")
    alert.addButton(withTitle: "Deny")
    return alert.runModal() == .alertFirstButtonReturn
  }

  /// Registers this session's tool handlers with the registry. Each one needs state the registry
  /// can't reach — the session's attached images, its meeting files on disk, its `@Published`
  /// properties — so it lives here; the registry still owns dispatch.
  @MainActor
  private func makeToolContext(sessionId: UUID) -> ChatToolContext {
    // Same background-session rule as `/x` and thinkingLevel: scope follows the sending chat.
    let target = sessionId == session.id ? session : (store.session(by: sessionId) ?? session)
    return ChatToolContext(
      workspaceScope: workspaceScope(for: target),
      sessionHandlers: [
      ChatToolRegistry.generateImageToolName: { [weak self] args in
        guard let self else { return ChatToolOutcome(response: [:]) }
        let outcome = await self.executeGenerateImageTool(args: args, sessionId: sessionId)
        return ChatToolOutcome(response: outcome.response, imageMarkers: outcome.markers)
      },
      ChatToolRegistry.refineMeetingSummaryToolName: { [weak self] args in
        guard let self else { return ChatToolOutcome(response: [:]) }
        return ChatToolOutcome(response: await self.executeRefineMeetingSummaryTool(args: args))
      },
      ChatToolRegistry.correctTranscriptTermToolName: { [weak self] args in
        guard let self else { return ChatToolOutcome(response: [:]) }
        return ChatToolOutcome(response: await self.executeCorrectTranscriptTermTool(args: args))
      },
      ChatToolRegistry.rememberAboutUserToolName: { [weak self] args in
        guard let self else { return ChatToolOutcome(response: [:]) }
        return ChatToolOutcome(response: self.executeRememberAboutUserTool(args: args))
      },
      ChatToolRegistry.forgetAboutUserToolName: { [weak self] args in
        guard let self else { return ChatToolOutcome(response: [:]) }
        return ChatToolOutcome(response: self.executeForgetAboutUserTool(args: args))
      },
    ])
  }

  /// Executes the `generate_image` tool: builds a one-turn request for the Gemini image model
  /// (optionally including the user's most recently attached images for editing), runs it, and
  /// splits the result into UI-bound image markers and a short, model-bound status payload.
  private func executeGenerateImageTool(
    args: [String: Any],
    sessionId: UUID
  ) async -> (response: [String: Any], markers: [String]) {
    guard let prompt = (args["prompt"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
          !prompt.isEmpty else {
      return (["error": "Missing required argument: prompt"], [])
    }
    var parts: [[String: Any]] = []
    if ChatToolRegistry.boolArgument(args, "use_attached_image", default: false) {
      // attachedImageParts can also hold PDFs/text files; the image model only accepts images.
      let attached = (store.session(by: sessionId)?
        .messages.last(where: { $0.role == .user && !$0.attachedImageParts.isEmpty })?
        .attachedImageParts ?? [])
        .filter { ($0.mimeType ?? "image/png").hasPrefix("image/") }
      if attached.isEmpty {
        return (["error": "No attached image found in this conversation. Generate from the prompt alone (use_attached_image=false) or ask the user to attach one."], [])
      }
      parts = attached.map { part in
        ["inline_data": ["mime_type": part.mimeType ?? "image/png", "data": part.data.base64EncodedString()]]
      }
    }
    parts.append(["text": prompt])
    do {
      let text = try await GeminiChatProvider.shared.generateImage(
        contents: [["role": "user", "parts": parts]])
      let (markers, narration) = Self.splitGeneratedImageMarkers(text)
      guard !markers.isEmpty else {
        // Image model replied with text only (refusal/clarification) — relay that to the model.
        return (["status": "no_image_returned", "image_model_reply": String(narration.prefix(500))], [])
      }
      var response: [String: Any] = [
        "status": "success",
        "detail":
          "The generated image is already displayed to the user in the chat. Briefly confirm what was created — do not attempt to reproduce, link, or re-describe the image in detail.",
      ]
      if !narration.isEmpty { response["image_model_note"] = String(narration.prefix(300)) }
      return (response, markers)
    } catch {
      DebugLogger.logError("CHAT-TOOL: generate_image failed: \(error.localizedDescription)")
      return (["error": error.localizedDescription], [])
    }
  }

  /// Splits content into its ⟦GEMINI_IMG:…⟧ markers and the remaining (non-image) text.
  static func splitGeneratedImageMarkers(_ content: String) -> (markers: [String], text: String) {
    guard GeminiAPIClient.containsImageMarker(in: content) else {
      return ([], content.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    var markers: [String] = []
    var text = ""
    GeminiAPIClient.walkImageMarkers(
      content,
      onText: { text += $0 },
      onMarker: { markers.append(String($0)) },
      // Unterminated marker (shouldn't happen) — keep the remainder as text.
      onUnterminatedMarker: { text += $0 }
    )
    return (markers, text.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  /// Compact, length-capped JSON string for logging tool-call args/results
  /// without flooding the log. Lets us see exactly what the model passed and
  /// got back (e.g. the precise event_id), which plain name-only logging hid.
  private static func compactDescription(_ value: [String: Any], maxLength: Int = 600) -> String {
    let raw: String
    if let data = try? JSONSerialization.data(withJSONObject: value),
       let json = String(data: data, encoding: .utf8) {
      raw = json
    } else {
      raw = String(describing: value)
    }
    return raw.count > maxLength ? String(raw.prefix(maxLength)) + "…(\(raw.count) chars)" : raw
  }

  /// Auto-processes the next queued message once the current one finishes.
  /// Sends into the session the message was queued for — NOT the currently
  /// visible one, which may have changed while the previous send ran.
  private func processNextQueued() {
    guard let next = messageQueue.first, !isSendingSession(next.sessionId) else { return }
    messageQueue.removeFirst()
    DebugLogger.log("GEMINI-CHAT: Processing next queued message, \(messageQueue.count) remaining")
    performSend(content: next.content, attachedParts: next.attachedParts, toSessionId: next.sessionId)
  }

  /// Removes a queued message by ID (called from the pending bubble's delete button).
  func removeQueuedMessage(id: UUID) {
    messageQueue.removeAll { $0.id == id }
  }

  /// Dispatches a slash command. Callers (`submitComposer`, `handleTabComplete`)
  /// pre-filter so this method only sees recognized commands; regular chat
  /// content goes through `sendComposed`.
  func sendMessage(userInput: String? = nil) async {
    let raw = (userInput ?? inputText).trimmingCharacters(in: .whitespacesAndNewlines)
    let lower = raw.lowercased()
    guard !raw.isEmpty else { return }

    // /model command (switch chat model with fuzzy matching)
    if lower == Self.modelCommand || lower.hasPrefix(Self.modelCommand + " ") {
      inputText = ""
      let arg = lower == Self.modelCommand
        ? ""
        : String(lower.dropFirst(Self.modelCommand.count + 1)).trimmingCharacters(in: .whitespaces)
      handleModelCommand(argument: arg)
      return
    }

    if lower == Self.meetingCommand {
      inputText = ""
      handleMeetingButtonTap()
      return
    }

    // /think command (set per-session reasoning depth, persisted across restarts)
    if lower == Self.thinkCommand || lower.hasPrefix(Self.thinkCommand + " ") {
      inputText = ""
      let arg = lower == Self.thinkCommand
        ? ""
        : String(lower.dropFirst(Self.thinkCommand.count + 1)).trimmingCharacters(in: .whitespaces)
      handleThinkCommand(argument: arg)
      return
    }

    // /x command (restrict Grok's X search to specific accounts, per session)
    if lower == Self.xHandlesCommand || lower.hasPrefix(Self.xHandlesCommand + " ") {
      inputText = ""
      let arg = lower == Self.xHandlesCommand
        ? ""
        : String(lower.dropFirst(Self.xHandlesCommand.count + 1)).trimmingCharacters(in: .whitespaces)
      handleXHandlesCommand(argument: arg)
      return
    }

    // /workspace command (narrow this chat to a subset of the shared folders)
    if lower == Self.workspaceCommand || lower.hasPrefix(Self.workspaceCommand + " ") {
      inputText = ""
      let arg = lower == Self.workspaceCommand
        ? ""
        : String(lower.dropFirst(Self.workspaceCommand.count + 1)).trimmingCharacters(in: .whitespaces)
      handleWorkspaceCommand(argument: arg)
      return
    }

    // Model-switch commands (provider-default aliases /gemini /grok /gpt, the per-model short
    // aliases /gemini35flash /gemini35flashlite …, and the silent /openai alias). Generated from PromptModel,
    // so this one lookup covers every model without per-command branches.
    if let model = Self.modelCommandLookup[lower] {
      inputText = ""
      switchToModel(model)
      return
    }

    if lower == Self.newChatCommand || lower == Self.screenshotCommand
        || lower == Self.attachCommand || lower == Self.folderCommand
        || lower == Self.settingsCommand || lower == Self.pinCommand || lower == Self.unpinCommand
        || lower == Self.copyCommand || lower == Self.feedbackCommand {
      inputText = ""
      if lower == Self.newChatCommand {
        if singleChatOnly {
          appendModelMessage("`/new` is unavailable in this window because it is bound to a single chat session.")
        } else {
          createNewSession()
        }
      }
      else if lower == Self.attachCommand { attachFile() }
      else if lower == Self.folderCommand { shareFolder() }
      else if lower == Self.settingsCommand { SettingsManager.shared.showSettings() }
      else if lower == Self.pinCommand { togglePin() }
      else if lower == Self.unpinCommand { unpin() }
      else if lower == Self.copyCommand { copyChatToClipboard(sessionId: session.id) }
      else if lower == Self.feedbackCommand { sendFeedbackFromChat() }
      else { await captureScreenshot() }
      return
    }
  }

  func clearMessages() {
    messages = []
    session.messages = []
    session.lastUpdated = Date()
    store.save(session)
    refreshRecentSessions()
    DebugLogger.log("GEMINI-CHAT: Cleared current chat messages")
  }

  // MARK: - Private

  /// Returns user-visible content for the session tab title (typed text, else first pasted/selection body).
  static func contentForSessionTitle(_ rawContent: String) -> String {
    let parsed = parseUserMessagePastedXML(rawContent)
    if !parsed.userText.isEmpty { return parsed.userText }
    if let first = parsed.sections.first { return first.body }
    return rawContent.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Extracts a clean title from an LLM title response: the first non-empty line, stripped of
  /// surrounding whitespace and quote characters.
  static func cleanTitleResponse(_ raw: String) -> String {
    raw
      .components(separatedBy: .newlines)
      .map {
        $0.trimmingCharacters(in: .whitespaces)
          .replacingOccurrences(of: "\"", with: "")
          .replacingOccurrences(of: "'", with: "")
      }
      .first { !$0.isEmpty } ?? ""
  }

  /// The first-message fallback title a meeting may have been wrongly stamped with before we stopped
  /// titling meetings from chat messages (see `appendMessage`). Mirrors that old logic exactly so we
  /// can recognise — and discard — such a stale title and let the summary-based titler run. Returns
  /// nil when there's no first user message to derive one from.
  static func meetingFirstMessageFallbackTitle(for session: ChatSession) -> String? {
    guard let firstContent = session.messages.first(where: { $0.role == .user })?.content else { return nil }
    let oneLine = contentForSessionTitle(firstContent)
      .replacingOccurrences(of: "\n", with: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !oneLine.isEmpty else { return nil }
    var title = String(oneLine.prefix(maxSessionTitleLength))
    if oneLine.count > maxSessionTitleLength { title += "…" }
    return title
  }

  /// True when a meeting row has no *real* (summary-derived or manually renamed) title yet — i.e.
  /// it's empty or still the stale first-message fallback. Only such titles are safe to (re)generate;
  /// a manual rename never equals the fallback, so it's preserved.
  static func meetingTitleNeedsGeneration(_ session: ChatSession) -> Bool {
    guard session.isMeeting else { return false }
    guard let title = session.title, !title.isEmpty else { return true }
    return title == meetingFirstMessageFallbackTitle(for: session)
  }

  /// Builds the system instruction: current date, base chat prompt, plus optional meeting context (summary + recent transcript).
  /// Pass the sending session when a background tab is the target — workspace/meeting gates follow that chat.
  private func buildSystemInstruction(for target: ChatSession? = nil) -> [String: Any] {
    let s = target ?? session
    var text = SystemPromptsStore.shared.loadChatSystemPrompt()
    let formatter = DateFormatter()
    formatter.dateFormat = "EEEE, MMMM d, yyyy"
    formatter.locale = Locale(identifier: "en_US")
    text = "Today's date: \(formatter.string(from: Date())).\n\n\(text)"
    let commandsList = commandSuggestionsForDisplay
      .map { "- `\($0.command)` — \($0.description)" }
      .joined(separator: "\n")
    text += "\n\nAvailable slash commands in this chat:\n\(commandsList)"
    // Inject meeting context whenever the current chat is a meeting tab:
    // - live or just-ended (live store still owns this stem): live notes + the FULL transcript;
    // - past meeting (live store empty or moved on): summary + full transcript from disk.
    // Regular chats stay free of meeting content.
    let meetingContext: String? = {
      if let provided = meetingContextProvider?() { return provided }
      guard s.isMeeting, let stem = s.meetingStem else { return nil }
      if LiveMeetingTranscriptStore.shared.currentMeetingFilenameStem == stem {
        let live = LiveMeetingTranscriptStore.shared.meetingContextForChat()
        if !live.isEmpty { return live }
      }
      return buildEndedMeetingContext()
    }()
    if let extra = meetingContext, !extra.isEmpty {
      text = "\(text)\n\n---\n\n\(extra)"
    }
    // Persistent user memory (UserContext/memory.md): durable facts the user told us across sessions.
    // Injected into every chat request; empty when the user has no memory (then nothing is added).
    let memory = ChatMemoryStore.shared.loadMemory()
    if !memory.isEmpty {
      text += "\n\n---\n\nPersistent memory — durable facts you have remembered about the user. Use them to personalize answers; do not repeat them back verbatim unless relevant.\n\(memory)"
    }
    // Shared folders + what we've learned about them. The folder list is injected directly rather
    // than left to `list_workspace_folders`: it is one line per folder and always accurate, and
    // spending a whole tool round just to learn "which folders exist" delays every file answer.
    // Mirrors the gating in buildToolDeclarations.
    let workspaceScope = workspaceScope(for: s)
    let sharedFolders = WorkspaceFolders.displayPaths(scope: workspaceScope)
    if !sharedFolders.isEmpty {
      let list = sharedFolders
        .map { "- `\(($0 as NSString).abbreviatingWithTildeInPath)`" }
        .joined(separator: "\n")
      text += "\n\n---\n\nFILES: The user has shared these folders on their Mac with you:\n\(list)\nYou can read them with `list_directory`, `read_text_file`, and `search_files` — read-only, and nothing outside these folders is reachable. When the user refers to their own notes, documents, or projects, look there instead of saying you have no access."
      let map = WorkspaceMapStore.shared.loadMap()
      if !map.isEmpty {
        text += "\n\nWhat you have learned about where things live:\n\(map)\nTreat this as a starting point, not gospel — verify with a tool call before relying on it, and call `remember_file_location` to correct an entry that turns out to be wrong."
      }
      text += "\n\nWhenever you discover something durable about the layout of these folders (what a directory holds, how its files are named), call `remember_file_location` so future conversations start there instead of searching again. Record directories and stable collections, not one-off files. Use `forget_file_location` for entries that are wrong or outdated."
      // AGENTS.md / CLAUDE.md / .cursor/rules — the user's own agent instructions, loaded in full
      // exactly as Cursor and Claude Code load them. Injected rather than left to a tool call: a
      // folder is shared *because* its context should shape every answer, and a model that has to
      // decide to go read the rules first will often simply not.
      if WorkspaceWriteAccess.isEnabled {
        text += "\n\nYou can also CHANGE files in these folders: `write_text_file` creates one, `append_to_file` adds to the end of one, `edit_text_file` replaces an exact piece of text. Reach for `append_to_file` and `edit_text_file` before `write_text_file` with overwrite — they cannot lose text the user wrote. Read a file before editing it, and say plainly what you changed. There is no delete and no rename tool; if the user wants a file removed, tell them to do it in Finder."
      } else {
        text += "\n\nYou can only READ these folders. If the user asks you to write, edit, or save something into them, say that file editing is off and that they can turn it on in Settings → Chat → Workspace Folders. Never claim to have written a file."
      }
      text += WorkspaceContextFiles.contextBlock(roots: WorkspaceFolders.roots(scope: workspaceScope))
    }
    if GoogleAccountOAuthService.shared.isConnected {
      text += "\n\nIMPORTANT — you are CONNECTED to the user's own Google account with LIVE access to their Calendar, Tasks, and Gmail through the tools below. When the user asks anything about their email, inbox, messages, calendar, schedule, events, meetings, appointments, tasks, to-dos, or reminders, you MUST call the relevant tool to fetch the real data BEFORE answering — on the very first turn, without waiting to be asked again. NEVER reply that you lack access, cannot see their inbox/calendar, or that they should paste/forward/attach the content: you have direct access, so use it. You have three distinct Google integrations:\n1. **Google Calendar** (scheduled events with start/end times): google_calendar_list_events, google_calendar_create_event, google_calendar_delete_event\n2. **Google Tasks** (to-do items, reminders): google_tasks_list_tasklists, google_tasks_list, google_tasks_create, google_tasks_update, google_tasks_complete, google_tasks_delete\n3. **Gmail** (read-only email access): gmail_search, gmail_read\nWhen the user says 'task', 'to-do', or 'reminder', ALWAYS use google_tasks_* tools. Only use google_calendar_* when the user explicitly asks for a calendar event, meeting, or appointment with a specific time.\nThe user has multiple task lists. Call google_tasks_list_tasklists first to discover available lists and their IDs, then pass the correct task_list_id to other google_tasks_* tools.\nTo CHANGE an existing task (due date, title, notes, status) always call google_tasks_update — never delete and re-create it.\nWhen an instruction affects several items (e.g. re-dating five tasks), emit ALL the independent calls together in ONE turn instead of one call per turn — the number of tool rounds per answer is limited, and one-at-a-time editing runs out of rounds before the batch is finished.\nFor Gmail: use gmail_search to find emails (supports Gmail query syntax like 'is:unread', 'from:user@example.com', 'newer_than:2d'). Use gmail_read to get the full body of a specific email. Gmail access is read-only.\nUse the user's local time zone (\(TimeZone.current.identifier)) when creating calendar events. Always confirm details before creating, deleting, or modifying events and tasks."
    }
    // Mirrors the gating in buildToolDeclarations: the tool exists iff a Gemini credential does.
    if GeminiCredentialProvider.shared.hasCredential() {
      text += "\n\nIMAGE GENERATION: You can create and edit real images via the `generate_image` tool. When the user asks you to draw, create, render, visualize, edit, or annotate an image, ALWAYS call generate_image — never approximate with ASCII art, SVG, or code blocks. To annotate or edit an image the user attached, pass use_attached_image=true with a precise instruction. The finished image appears in the chat automatically."
    }
    text += "\n\nMEMORY: Use `remember_about_user` to save durable facts the user shares or asks you to keep, and `forget_about_user` to drop ones that are wrong or outdated (the tool descriptions spell out what qualifies). Acknowledge briefly what changed — never dump the whole memory back."
    text += "\n\nCHANGING THE APP'S BEHAVIOR: The user can reconfigure WhisperShortcut by asking you, instead of opening Settings. Route each kind of request to the right tool: a lasting rule for how Dictate Prompt should rewrite text → `update_app_instructions` (section 'dictate_prompt'); the correct spelling of a name or term for dictation → `remember_dictation_term`; a durable fact about the user → `remember_about_user`. With `update_app_instructions` ALWAYS read first and then replace or remove a conflicting rule instead of appending a contradictory second one — two rules that fight each other degrade the mode in ways the user cannot trace back. Never claim you changed the app's behavior unless the tool call succeeded."
    // Mirrors buildToolDeclarations' meetingContext gating.
    if s.isMeeting {
      text += "\n\nMEETING EDITING: This chat is attached to a meeting. When the user asks to change, refine, reformat, shorten, or correct the meeting SUMMARY, call `refine_meeting_summary` with their instruction — do not just reply with a rewritten summary in chat. When the user points out a misrecognized name or term in the TRANSCRIPT (e.g. 'it's ParkDepot, not Park Depot'), call `correct_transcript_term` with the exact wrong and corrected spelling — this is a literal find-and-replace that keeps the transcript faithful; never rewrite or paraphrase the transcript yourself."
    }
    return ["parts": [["text": text]]]
  }

  /// Current chat model with migration applied. Falls back to the default for audio-only
  /// models (`supportsTextChat == false`) since they can't power a text chat request.
  static var openChatModel: PromptModel {
    PromptModel.loadSelectedChatModel()
  }

  /// Display name for the current chat model (e.g. "Gemini 3 Flash") for the nav bar.
  var openChatModelDisplayName: String {
    Self.openChatModel.displayName
  }

  /// Updates an existing model message in-place (used during streaming).
  /// Refreshes the UI during streaming; persists only when requested to avoid
  /// running full session-store normalization on every token.
  private func updateStreamingMessage(
    id: UUID, sessionId: UUID, content: String,
    sources: [GroundingSource], supports: [GroundingSupport], persist: Bool = true
  ) {
    let isCurrentSession = sessionId == session.id
    var target: ChatSession
    if isCurrentSession {
      target = session
    } else {
      guard let s = store.session(by: sessionId) else { return }
      target = s
    }
    let idx: Int
    if let last = target.messages.indices.last, target.messages[last].id == id {
      idx = last
    } else if let found = target.messages.firstIndex(where: { $0.id == id }) {
      idx = found
    } else {
      return
    }
    target.messages[idx].content = content
    target.messages[idx].sources = sources
    target.messages[idx].groundingSupports = supports
    target.lastUpdated = Date()
    if persist {
      store.save(target)
    }
    if isCurrentSession {
      scrollAnchorClearSignal.send()
      session = target
      messages = target.messages
    }
  }

  /// Terminal path for a stream that ended before a clean finalization (cancelled or threw).
  /// Detaches the streaming buffer and either commits the partial text into the message or
  /// removes the placeholder entirely. The partial only ever lived in the streaming buffer,
  /// never in `messages`; committing it now keeps the kept text visible (and persisted across
  /// a quit-after-Stop) instead of snapping to empty when the bubble swaps to its
  /// non-streaming render path. An empty partial leaves nothing worth showing, so the
  /// placeholder is removed rather than persisted as an empty assistant turn.
  private func commitPartialOrRemove(
    placeholderId: UUID, sessionId: UUID, partial: String
  ) {
    detachStreamingBuffer(for: placeholderId)
    if partial.isEmpty {
      removeMessage(id: placeholderId, fromSessionId: sessionId)
    } else {
      updateStreamingMessage(
        id: placeholderId, sessionId: sessionId,
        content: partial, sources: [], supports: [])
    }
  }

  /// Persists a send failure on the session so a background tab still shows a failed-turn row.
  private func persistLastSendError(_ message: String?, sessionId: UUID) {
    let isCurrent = sessionId == session.id
    var target: ChatSession
    if isCurrent {
      target = session
    } else if let stored = store.session(by: sessionId) {
      target = stored
    } else {
      return
    }
    guard target.lastSendError != message else {
      if isCurrent { lastSendError = message }
      return
    }
    target.lastSendError = message
    store.save(target)
    if isCurrent {
      session = target
      lastSendError = message
    }
  }

  /// `nonisolated`: a pure predicate over the provider's finish reason, with no view-model state
  /// behind it. Inheriting `ChatViewModel`'s `@MainActor` isolation only made it uncallable from
  /// the synchronous test context.
  nonisolated static func isTruncatedFinishReason(_ reason: String?) -> Bool {
    guard let reason else { return false }
    let lower = reason.lowercased()
    return lower == "length" || lower == "max_tokens" || lower.contains("max_token")
      || lower == "incomplete"
  }

  /// Registers a streaming buffer for `messageId` so the bubble for that message can observe it.
  /// Returns the new buffer (the same instance stays for the lifetime of the stream — replacing
  /// the dict entry every token would defeat the @Published-only-on-add/remove guarantee).
  @discardableResult
  private func attachStreamingBuffer(for messageId: UUID) -> StreamingBuffer {
    let buffer = StreamingBuffer()
    streamingBuffers[messageId] = buffer
    // Positive marker for freeze verification: while attached, the bubble renders outside the
    // LazyVStack (see `messageList`), so per-token growth can't relayout the history.
    DebugLogger.logUI("CHAT-LIST: streaming bubble detached from lazy list id=\(messageId)")
    return buffer
  }

  /// Removes the buffer for `messageId`. Idempotent; safe to call multiple times.
  private func detachStreamingBuffer(for messageId: UUID) {
    streamingBuffers[messageId]?.cancelPending()
    streamingBuffers.removeValue(forKey: messageId)
  }

  /// Appends a message to the session identified by `sessionId`.
  /// If that session is currently visible, also updates the in-memory UI state.
  private func appendMessage(_ message: ChatMessage, toSessionId sessionId: UUID) {
    let isCurrentSession = sessionId == session.id

    var target: ChatSession
    if isCurrentSession {
      target = session
    } else {
      guard let s = store.session(by: sessionId) else { return }
      target = s
    }

    // Meetings are titled from their summary (`generateMeetingTitle`), never from a chat message —
    // and that summary path only fires while the title is still empty. So we must NOT stamp a
    // first-message fallback onto a meeting, or it would permanently block the summary-based title
    // and leave the row showing whatever the user happened to ask first.
    let isFirstUserMessage = message.role == .user && target.messages.isEmpty && !target.isMeeting
    target.messages.append(message)
    target.lastUpdated = Date()
    if isFirstUserMessage {
      let contentForTitle = Self.contentForSessionTitle(message.content)
      let oneLine = contentForTitle.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
      target.title = String(oneLine.prefix(Self.maxSessionTitleLength))
      if oneLine.count > Self.maxSessionTitleLength { target.title? += "…" }
    }
    store.save(target)

    if isCurrentSession {
      DebugLogger.logUI(
        "CHAT-LIST: append role=\(message.role) count=\(target.messages.count) session=\(sessionId)")
      // Deliberately NOT sending `scrollAnchorClearSignal` here: an append leaves every
      // existing message id intact, so SwiftUI's anchor lookup is trivial — no wedge risk.
      // Clearing the anchor mid-append was the source of the empty-list flash on Send,
      // where the ScrollView briefly untethered and the LazyVStack dropped its rendered
      // children. The wedge fix is still applied on `removeMessage`, `updateStreamingMessage`,
      // and `retryMessage` — paths where the anchored id may disappear or change.
      session = target
      messages = target.messages
    }
    refreshRecentSessions()
  }

  private func removeMessage(id: UUID, fromSessionId sessionId: UUID) {
    let isCurrentSession = sessionId == session.id
    var target: ChatSession
    if isCurrentSession {
      target = session
    } else {
      guard let s = store.session(by: sessionId) else { return }
      target = s
    }
    target.messages.removeAll { $0.id == id }
    store.save(target)
    if isCurrentSession {
      scrollAnchorClearSignal.send()
      session = target
      messages = target.messages
    }
  }

  private func generateAITitle(sessionId: UUID) async {
    // Find the first real user message and its model reply. Indices are not assumed to be 0/1:
    // a chat may open with a local command reply (e.g. "Model set to Grok 4.3." from `/grok`).
    guard let target = store.session(by: sessionId),
          let userIdx = target.messages.firstIndex(where: { $0.role == .user }),
          let replyIdx = target.messages[(userIdx + 1)...].firstIndex(where: { $0.role == .model })
    else { return }
    let userText = String(target.messages[userIdx].content.prefix(400))
    // Strip image markers first — otherwise an image-led reply feeds base64 to the title model.
    let modelText = String(GeminiAPIClient.stripImageMarkers(target.messages[replyIdx].content).prefix(400))
    let prompt = """
      Give this conversation a short title (2–3 words) that captures its core topic. \
      Begin with a single emoji that fits the topic, then one space, then the words. \
      Reply with only the title on a single line — no quotes, no trailing punctuation, no explanation. \
      Example: 📊 Quarterly Revenue

      User: \(userText)
      Assistant: \(modelText)
      """
    // overwriteExisting: replaces the first-message fallback title set in appendMessage.
    await generateAndApplyTitle(targetId: sessionId, prompt: prompt, overwriteExisting: true, logLabel: "AI")
  }

  /// Generates a short title via the title model and applies it to `targetId`. With
  /// `overwriteExisting` false the title is only set while the session is still untitled, so a
  /// manual rename (or a competing generator) is never clobbered. Shared by the chat and
  /// meeting title paths so the model id, length cap, and UI sync stay in one place.
  private func generateAndApplyTitle(targetId: UUID, prompt: String, overwriteExisting: Bool, logLabel: String) async {
    guard let credential = await GeminiCredentialProvider.shared.getCredential() else { return }
    do {
      // Structured output: the model must return {"title": "..."} — no free-text parsing or
      // stray quotes/markdown to strip. `cleanTitleResponse` stays as a light safety net.
      let titleSchema: [String: Any] = [
        "type": "object",
        "properties": [
          "title": [
            "type": "string",
            "description": "A short title capturing the core topic: a single leading emoji, then one space, then 2–4 words. No quotes, no trailing punctuation, no explanation. Example: 📊 Quarterly Revenue",
          ] as [String: Any],
        ] as [String: Any],
        "required": ["title"],
      ]
      let obj = try await MeetingListService.withRetry(label: "TITLE-\(logLabel.uppercased())") {
        try await apiClient.generateStructured(
          model: TranscriptionModel.gemini31FlashLite.rawValue,
          contents: [["role": "user", "parts": [["text": prompt]]]],
          systemInstruction: nil,
          schema: titleSchema,
          credential: credential)
      }
      let title = Self.cleanTitleResponse((obj["title"] as? String) ?? "")
      guard !title.isEmpty else { return }
      guard var updated = store.session(by: targetId) else { return }
      // A stale meeting first-message fallback counts as "untitled" here: it must yield to the
      // summary-based title even under `overwriteExisting: false` (which only guards manual renames).
      let isStaleMeetingFallback =
        updated.isMeeting && updated.title == Self.meetingFirstMessageFallbackTitle(for: updated)
      if !overwriteExisting, !(updated.title?.isEmpty ?? true), !isStaleMeetingFallback { return }
      updated.title = String(title.prefix(Self.maxSessionTitleLength))
      store.save(updated)
      if updated.id == session.id { session.title = updated.title }
      refreshRecentSessions()
      DebugLogger.log("GEMINI-CHAT: \(logLabel) title generated for \(targetId): \(title)")
    } catch {
      DebugLogger.log("GEMINI-CHAT: \(logLabel) title generation failed: \(error.localizedDescription)")
    }
  }

  /// Recovers a meeting title that the live `.chatMeetingSummaryReady` notification missed (e.g. no
  /// chat window was open when the summary finished). If the current session is an untitled meeting
  /// whose summary is already on disk, generate the title now — at most once per stem per app run so
  /// a missing or failed summary doesn't re-fire an API call on every view.
  private func backfillMeetingTitleIfNeeded() {
    guard !singleChatOnly,
          session.isMeeting,
          Self.meetingTitleNeedsGeneration(session),
          let stem = session.meetingStem,
          !attemptedMeetingTitleStems.contains(stem),
          let summary = loadMeetingSummaryFromDisk(),
          !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return }
    attemptedMeetingTitleStems.insert(stem)
    titleOpenMeetingFromSummary(summary)
  }

  /// Titles `self.session` from `summary`. Used by the backfill and recovery paths to avoid the
  /// `allSessions()` stem match used by the live `.chatMeetingSummaryReady` path, which can miss
  /// the just-opened session and leave the meeting stuck on its first-message fallback title.
  /// The save here is a safety net: ensure the session row exists in the store before the async
  /// title generator reads it via `store.session(by:)`. Both callers gate on an empty in-memory
  /// title, so we're persisting an untitled row.
  private func titleOpenMeetingFromSummary(_ summary: String) {
    let targetId = session.id
    store.save(session)
    Task { await generateMeetingTitle(targetId: targetId, summary: summary) }
  }

  /// Titles a meeting chat (by session id) from its summary, unless it's already titled.
  private func generateMeetingTitle(targetId: UUID, summary: String) async {
    guard let target = store.session(by: targetId), Self.meetingTitleNeedsGeneration(target) else { return }
    let summaryText = summary.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !summaryText.isEmpty else { return }
    let prompt = """
      Give this meeting a short title (2–4 words) that captures its main topic. \
      Begin with a single emoji that fits the topic, then one space, then the words. \
      Reply with only the title on a single line — no quotes, no trailing punctuation, no explanation. \
      Example: 🤝 Vendor Negotiation

      Meeting summary:
      \(String(summaryText.prefix(1200)))
      """
    await generateAndApplyTitle(targetId: targetId, prompt: prompt, overwriteExisting: false, logLabel: "Meeting")
  }

  // MARK: - Local model messages (slash commands)

  /// Appends a model message directly to the chat (used for local command responses).
  @MainActor
  private func appendModelMessage(_ content: String) {
    let msg = ChatMessage(role: .model, content: content)
    messages.append(msg)
    session.messages = messages
    store.save(session)
  }

  /// Handles the /model command. Resolves the fuzzy argument to a PromptModel
  /// and either applies it (writes UserDefaults like the Settings picker) or
  /// posts a model message explaining the situation. Subscription mode never
  /// changes the selection.
  @MainActor
  private func handleModelCommand(argument: String) {
    let current = Self.openChatModel
    let outcome = ChatModelCommandResolver.resolve(
      argument: argument,
      currentSelection: current
    )
    switch outcome {
    case .usage(let cur):
      appendModelMessage(
        "Current model: **\(cur.displayName)**. Example: `/model 3.1 flash lite` or `/model 3.7 flash`."
      )
    case .applied(let model):
      switchToModel(model)
    case .ambiguous(let candidates):
      let list = candidates.map { "• **\($0.displayName)**" }.joined(separator: "\n")
      appendModelMessage("Multiple matches. Be more specific:\n\(list)")
    case .noMatch(let query):
      appendModelMessage("No model matched \"\(query)\". Try a version and variant, e.g. `3.1 flash lite` or `3.7 flash`.")
    }
    DebugLogger.log("GEMINI-CHAT: /model argument=\(argument) outcome=\(outcome)")
  }

  /// Persists the selected chat model and posts a confirmation message. The `model` is
  /// expected to be already migrated (callers come from `ChatModelCommandResolver` or
  /// `ChatModelProvider.X.defaultChatModel`, both of which yield current cases).
  private func switchToModel(_ model: PromptModel) {
    UserDefaults.standard.set(model.rawValue, forKey: UserDefaultsKeys.selectedChatModel)
    Self.recordModelUse(model)
    NotificationCenter.default.post(name: .promptModelChanged, object: model)
    appendModelMessage("Model set to **\(model.displayName)**.")
    DebugLogger.log("GEMINI-CHAT: switchToModel \(model.displayName)")
  }

  /// Handles the /think command. Sets this session's reasoning depth (persisted across restarts)
  /// and posts a confirmation. Bare `/think` reports the current level and usage. The level maps
  /// per provider in each `LLMChatProvider` (see `ThinkingLevel`).
  @MainActor
  private func handleThinkCommand(argument: String) {
    let valid = "minimal | low | medium | high | default"
    guard !argument.isEmpty else {
      appendModelMessage(
        "Reasoning depth for this chat: **\(session.thinkingLevel.rawValue)**. Set with `/think <level>` — \(valid)."
      )
      return
    }
    guard let level = ThinkingLevel(rawValue: argument) else {
      appendModelMessage("Unknown reasoning depth \"\(argument)\". Use one of: \(valid).")
      return
    }
    session.thinkingLevel = level  // persisted by appendModelMessage's store.save(session)
    let note = level == .default
      ? "Reasoning depth reset to the model's **default** for this chat."
      : "Reasoning depth set to **\(level.rawValue)** for this chat. Higher = more thorough but slower and pricier."
    appendModelMessage(note)
    DebugLogger.log("GEMINI-CHAT: /think level=\(level.rawValue) session=\(session.id)")
  }

  /// Handles the `/x` command. Restricts Grok's `x_search` to specific accounts for this chat
  /// (persisted across restarts), layered over the Settings → Chat default.
  ///
  /// `allowed_x_handles` is a hard filter on xAI's side, so the confirmations say "only" rather
  /// than "prefer" — a user who reads it as a ranking hint would blame the model for missing
  /// posts the filter never let it see. Bare `/x` reports the effective list; `/x off` searches
  /// all of X even when a default is configured.
  @MainActor
  private func handleXHandlesCommand(argument: String) {
    let usage = "Set with `/x @karpathy @simonw`, clear with `/x off`."
    guard !argument.isEmpty else {
      let effective = effectiveXHandles(for: session)
      let state = effective.isEmpty
        ? "X search covers **all of X** in this chat."
        : "X search in this chat is limited to **\(XSearchHandles.describe(effective))**."
      appendModelMessage("\(state) \(usage)")
      return
    }
    if ["off", "all", "clear", "none", "reset"].contains(argument) {
      session.xHandles = []  // explicit empty beats a non-empty Settings default
      appendModelMessage("X search now covers **all of X** in this chat.")
      DebugLogger.log("GEMINI-CHAT: /x cleared session=\(session.id)")
      return
    }
    let (handles, droppedOverCap) = XSearchHandles.parse(argument)
    guard !handles.isEmpty else {
      appendModelMessage("No usable X handles in \"\(argument)\". \(usage)")
      return
    }
    session.xHandles = handles  // persisted by appendModelMessage's store.save(session)
    var note =
      "Grok will now search **only** \(XSearchHandles.describe(handles)) on X in this chat — posts from anyone else stay invisible to it. \(usage)"
    if droppedOverCap > 0 {
      note += "\n\nxAI accepts at most \(XSearchHandles.maxHandles) accounts, so the last \(droppedOverCap) were dropped."
    }
    appendModelMessage(note)
    DebugLogger.log("GEMINI-CHAT: /x handles=\(handles.count) dropped=\(droppedOverCap) session=\(session.id)")
  }

  /// The X handles a send should actually use: the session's own list when `/x` has set one,
  /// otherwise the Settings → Chat default. `[]` from `/x off` is a real value, not "unset",
  /// which is why this is an optional check rather than an `isEmpty` fallback.
  private func effectiveXHandles(for session: ChatSession) -> [String] {
    session.xHandles ?? XSearchHandles.defaultHandles
  }

  /// The folders this chat may read. `nil` = every shared folder; `[]` = none. A selection that
  /// no longer matches anything (the folder was removed in Settings) resolves to no folders
  /// rather than silently falling back to all of them.
  private func workspaceScope(for session: ChatSession) -> WorkspaceFolders.Scope {
    guard let selected = session.workspaceFolders else { return .all }
    return selected.isEmpty ? .off : .only(selected)
  }

  /// `/workspace` narrows this chat to a subset of the folders the user already shared. It cannot
  /// grant a new one: macOS only hands a sandboxed app a folder through a real user gesture, so
  /// adding stays with `/folder` and drag-and-drop. Narrowing matters because a shared home
  /// directory makes every search slower and pulls in context from projects the chat was not
  /// asked about.
  @MainActor
  private func handleWorkspaceCommand(argument: String) {
    let shared = WorkspaceFolders.displayPaths
    let abbreviate: (String) -> String = { ($0 as NSString).abbreviatingWithTildeInPath }
    guard !shared.isEmpty else {
      appendModelMessage(
        "No folders are shared yet. Use `/folder`, or drop a folder onto this window, to grant access — macOS only allows that through the picker or a drop.")
      return
    }
    let list = shared.map { "- `\(abbreviate($0))`" }.joined(separator: "\n")
    let usage =
      "Narrow with `/workspace <name>`, restore every folder with `/workspace all`, or drop file access entirely with `/workspace off`.\n\nShared folders:\n\(list)"

    guard !argument.isEmpty else {
      let active = WorkspaceFolders.displayPaths(scope: workspaceScope(for: session))
      let state: String
      if active.isEmpty {
        state = session.workspaceFolders?.isEmpty == false
          ? "This chat is pinned to a folder that is no longer shared, so it currently has **no file access**."
          : "File access is **off** in this chat."
      } else if active.count == shared.count {
        state = "This chat can use **all \(shared.count) shared folders**."
      } else {
        state = "This chat is limited to **\(active.map(abbreviate).joined(separator: ", "))**."
      }
      appendModelMessage("\(state)\n\n\(usage)")
      return
    }

    if ["all", "every", "clear", "reset"].contains(argument) {
      session.workspaceFolders = nil
      appendModelMessage("This chat can use **all \(shared.count) shared folders** again.")
      DebugLogger.log("GEMINI-CHAT: /workspace all session=\(session.id)")
      return
    }
    if ["off", "none", "no"].contains(argument) {
      session.workspaceFolders = []
      appendModelMessage(
        "File access is **off** for this chat — no folders, and no context files from them. Turn it back on with `/workspace all`.")
      DebugLogger.log("GEMINI-CHAT: /workspace off session=\(session.id)")
      return
    }

    let needle = argument.lowercased()
    let matches = shared.filter { path in
      if needle == "~" || needle == "home" { return path == NSHomeDirectory() }
      return (path as NSString).lastPathComponent.lowercased().contains(needle)
        || abbreviate(path).lowercased().contains(needle)
    }
    guard !matches.isEmpty else {
      appendModelMessage("No shared folder matches \"\(argument)\".\n\n\(usage)")
      return
    }
    session.workspaceFolders = matches
    let named = matches.map { "**\(abbreviate($0))**" }.joined(separator: ", ")
    appendModelMessage(
      matches.count == shared.count
        ? "That matches every shared folder, so this chat still uses all of them."
        : "This chat now uses \(named) only — its files and its context files. `/workspace all` restores the rest.")
    DebugLogger.log("GEMINI-CHAT: /workspace matched=\(matches.count) session=\(session.id)")
  }

  /// Recently-used chat models, most recent first (PromptModel rawValues). See `chatModelRecency`.
  static func loadModelRecency() -> [String] {
    UserDefaults.standard.stringArray(forKey: UserDefaultsKeys.chatModelRecency) ?? []
  }

  /// Records `model` as the most recently used chat model, moving it to the front of the recency
  /// list. Capped at the number of chat models so the list can't grow unbounded.
  static func recordModelUse(_ model: PromptModel) {
    var recency = loadModelRecency().filter { $0 != model.rawValue }
    recency.insert(model.rawValue, at: 0)
    UserDefaults.standard.set(Array(recency.prefix(PromptModel.chatModels.count)), forKey: UserDefaultsKeys.chatModelRecency)
  }

  // MARK: - Scroll Position Persistence

  /// Per-session id of the message pinned to the top of the chat scroll view. Survives window
  /// hide/show, tab switches, and relaunch. Keyed by session UUID; pruned to live sessions on load.
  private var scrollAnchors: [UUID: UUID] = [:]

  private func loadScrollAnchors() {
    let raw = UserDefaults.standard.dictionary(forKey: UserDefaultsKeys.chatScrollAnchors) as? [String: String] ?? [:]
    let liveIds = Set(store.allSessions().map(\.id))
    scrollAnchors = raw.reduce(into: [:]) { acc, pair in
      guard let sessionId = UUID(uuidString: pair.key),
            let messageId = UUID(uuidString: pair.value),
            liveIds.contains(sessionId) else { return }
      acc[sessionId] = messageId
    }
  }

  /// The saved top message for `sessionId`, if any.
  func scrollAnchor(for sessionId: UUID) -> UUID? { scrollAnchors[sessionId] }

  /// Stores (or clears, when `messageId` is nil) the top message for `sessionId`.
  func setScrollAnchor(_ messageId: UUID?, for sessionId: UUID) {
    guard scrollAnchors[sessionId] != messageId else { return }
    scrollAnchors[sessionId] = messageId
    let raw = Dictionary(uniqueKeysWithValues: scrollAnchors.map { ($0.key.uuidString, $0.value.uuidString) })
    UserDefaults.standard.set(raw, forKey: UserDefaultsKeys.chatScrollAnchors)
  }

  // MARK: - Tab navigation

  private func refreshRecentSessions() {
    recentSessions = store.recentSessions(limit: 20)
    allSessionsList = store.allSessions()
  }

  /// Returns the sessions to display as tabs, ensuring the current session is always included.
  func visibleTabs(maxCount: Int) -> [ChatSession] {
    var tabs = Array(recentSessions.prefix(maxCount))
    if !tabs.contains(where: { $0.id == currentSessionId }) {
      let current = recentSessions.first { $0.id == currentSessionId } ?? session
      if tabs.isEmpty { tabs = [current] } else { tabs[tabs.count - 1] = current }
    }
    return tabs
  }

  func switchToSession(id: UUID) {
    DebugLogger.log("SIDEBAR: switchToSession id=\(id) current=\(session.id) same=\(id == session.id)")
    guard id != session.id else { return }
    store.switchToSession(id: id)
    switchToCurrentStoreSession()
    DebugLogger.log("SIDEBAR: switchToSession done → now on \(session.id)")
  }

  func closeTab(id: UUID) {
    rememberClosed(id: id)
    store.archiveSession(id: id)
    if id == session.id {
      switchToCurrentStoreSession()
    } else {
      refreshRecentSessions()
    }
    DebugLogger.log("GEMINI-CHAT: Closed (archived) tab \(id)")
  }

  /// Pushes a session onto the recently-closed ring buffer if it has any
  /// content worth restoring.
  private func rememberClosed(id: UUID) {
    guard let s = store.session(by: id), !s.messages.isEmpty else { return }
    recentlyClosedSessions.append(s)
    if recentlyClosedSessions.count > Self.recentlyClosedCapacity {
      recentlyClosedSessions.removeFirst(recentlyClosedSessions.count - Self.recentlyClosedCapacity)
    }
  }

  /// Restores the most recently closed tab and switches to it. No-op if the
  /// undo buffer is empty.
  func reopenLastClosedTab() {
    guard let s = recentlyClosedSessions.popLast() else {
      DebugLogger.log("GEMINI-CHAT: reopenLastClosedTab — buffer empty")
      return
    }
    store.save(s)
    store.switchToSession(id: s.id)
    switchToCurrentStoreSession()
    DebugLogger.log("GEMINI-CHAT: Reopened closed tab \(s.id)")
  }

  // MARK: - Pin / Unpin

  func pinSession(id: UUID) {
    store.pinSession(id: id)
    refreshRecentSessions()
    DebugLogger.log("SIDEBAR: Pinned session \(id)")
  }

  func unpinSession(id: UUID) {
    store.unpinSession(id: id)
    refreshRecentSessions()
    DebugLogger.log("SIDEBAR: Unpinned session \(id)")
  }

  // MARK: - Search

  /// Forwards to `ChatSearch`, which owns the ranking and snippeting. The view model keeps the
  /// entry point because the sidebar calls it through `@ObservedObject`.
  func search(_ rawQuery: String) -> [ChatSearchResult] {
    ChatSearch.run(rawQuery, store: store)
  }

  /// Reveals a meeting transcript file in Finder (fallback for orphan transcripts with no session).
  func revealMeetingInFinder(url: URL) {
    NSWorkspace.shared.activateFileViewerSelecting([url])
  }

  /// Canonical display title for a session row (sidebar + search results).
  static func displayTitle(for session: ChatSession) -> String {
    // Meetings stay "Meeting" until their summary-based title is generated, so the row never shows
    // whatever question the user happened to ask first — including legacy sessions still carrying a
    // stale first-message fallback title (which the backfill/summary path will replace shortly).
    if meetingTitleNeedsGeneration(session) { return "Meeting" }
    if let t = session.title, !t.isEmpty {
      let stripped = unwrapUserMessageTypedByUser(t)
      let base = stripped.isEmpty ? t : stripped
      return base.replacingOccurrences(of: "\n", with: " ")
    }
    if session.isMeeting { return "Meeting" }
    if let firstContent = session.messages.first(where: { $0.role == .user })?.content {
      let cleaned = contentForSessionTitle(firstContent)
      if !cleaned.isEmpty {
        return String(cleaned.prefix(60)).replacingOccurrences(of: "\n", with: " ")
      }
    }
    return "New chat"
  }

  /// Translates a meeting-button tap into the right intent based on current session state:
  /// stop the active meeting, resume a finished meeting, or start a fresh one.
  func handleMeetingButtonTap() {
    if isCurrentSessionTheActiveMeeting || isMeetingActive {
      // Starting and resuming announce themselves (the bar turns red, the window comes up). Stopping
      // does not: it has to drain the last chunk first, so without a word here a typed `/meeting`
      // looks like it was swallowed. Only the non-obvious action gets a notice.
      if isMeetingFinishing {
        showNotice("Already stopping — saving the last seconds of audio.")
        return
      }
      showNotice("Stopping the meeting — transcribing the last seconds…")
      NotificationCenter.default.post(name: .chatStopLiveMeeting, object: nil)
    } else if isCurrentSessionMeeting {
      requestResumeMeeting()
    } else {
      NotificationCenter.default.post(name: .chatStartNewMeeting, object: nil)
    }
  }

  /// Resumes the currently-viewed (ended) meeting. Rehydrates the live store from this
  /// meeting's on-disk transcript + summary FIRST, so recording continues the same file,
  /// the prior transcript stays visible, and new chunks' timestamps stay monotonic.
  /// Guarded: never runs while another meeting is recording (that would clobber its store).
  func requestResumeMeeting() {
    guard !isMeetingActive else { return }
    if let stem = session.meetingStem {
      let transcript = loadMeetingTranscriptFromDisk() ?? ""
      let summary = loadMeetingSummaryFromDisk() ?? ""
      LiveMeetingTranscriptStore.shared.rehydrateForResume(
        stem: stem,
        chunks: LiveMeetingTranscriptStore.parseTranscript(transcript),
        summary: summary.trimmingCharacters(in: .whitespacesAndNewlines),
        notes: MeetingListService.shared.loadNotes(forStem: stem))
    }
    NotificationCenter.default.post(name: .chatResumeMeeting, object: nil)
  }

  private func markCurrentSessionAsMeeting() {
    let stem = LiveMeetingTranscriptStore.shared.currentMeetingFilenameStem
    session.isMeeting = true
    session.meetingStem = stem
    store.markSessionAsMeeting(id: session.id, stem: stem)
    refreshRecentSessions()
  }

  var currentMeetingStem: String? { session.meetingStem }

  func loadMeetingTranscriptFromDisk() -> String? {
    guard let stem = session.meetingStem else { return nil }
    let url = AppSupportPaths.whisperShortcutApplicationSupportURL()
      .appendingPathComponent(AppConstants.liveMeetingTranscriptDirectory)
      .appendingPathComponent("\(stem).txt")
    return try? String(contentsOf: url, encoding: .utf8)
  }

  func loadMeetingSummaryFromDisk() -> String? {
    guard let stem = session.meetingStem else { return nil }
    let url = AppSupportPaths.whisperShortcutApplicationSupportURL()
      .appendingPathComponent(AppConstants.liveMeetingTranscriptDirectory)
      .appendingPathComponent("\(stem).summary.md")
    return try? String(contentsOf: url, encoding: .utf8)
  }

  /// Summary to show for an ended (non-live) meeting. Reads from disk on every evaluation; the
  /// recovery path bumps `summaryRevision` after writing the file so SwiftUI re-renders.
  var endedMeetingSummary: String? {
    guard let disk = loadMeetingSummaryFromDisk()?.trimmingCharacters(in: .whitespacesAndNewlines),
          !disk.isEmpty else { return nil }
    return disk
  }

  /// Builds a chat-system meeting context string from the on-disk summary + transcript of the
  /// current meeting tab. Used when the live store no longer owns this meeting's stem (e.g. user
  /// reopens a past meeting, or a new live meeting started). Transcript is suffix-capped to
  /// `MeetingListService.meetingContextMaxChars` to bound request size.
  private func buildEndedMeetingContext() -> String? {
    let summaryDisk = loadMeetingSummaryFromDisk()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let transcriptDisk = loadMeetingTranscriptFromDisk()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if summaryDisk.isEmpty && transcriptDisk.isEmpty { return nil }
    var parts: [String] = []
    if !summaryDisk.isEmpty {
      parts.append("Meeting summary:\n\(summaryDisk)")
    }
    if !transcriptDisk.isEmpty {
      let capped = transcriptDisk.count > MeetingListService.meetingContextMaxChars
        ? String(transcriptDisk.suffix(MeetingListService.meetingContextMaxChars))
        : transcriptDisk
      parts.append("Meeting transcript:\n\(capped)")
    }
    return "Use the following meeting context to answer the user's questions.\n\n" + parts.joined(separator: "\n\n")
  }

  // MARK: - Meeting notes, quoting, and quick actions

  /// Notes to show for the meeting this tab is viewing. The live store belongs to whichever meeting
  /// is recording *right now*, so a tab that isn't that meeting reads its own notes from disk —
  /// without this guard every meeting tab would show the running meeting's notes.
  var meetingNotesForDisplay: [LiveMeetingNote] {
    if isCurrentSessionTheActiveMeeting {
      return LiveMeetingTranscriptStore.shared.liveNotes
    }
    guard let stem = session.meetingStem else { return [] }
    // The chat stream reads this on every layout pass, so an ended meeting's notes are read from
    // disk once per stem instead of once per frame. They cannot change while the meeting is over.
    if let cached = endedNotesCache, cached.stem == stem { return cached.notes }
    let notes = MeetingListService.shared.loadNotes(forStem: stem)
    endedNotesCache = (stem, notes)
    return notes
  }

  /// One line describing exactly what the model can see, shown above the composer.
  ///
  /// The chat's knowledge of a meeting used to be invisible — you could not tell whether asking
  /// about something from 40 minutes ago would work. Now that it always gets the full transcript,
  /// saying so is what makes the feature usable.
  var meetingContextDescription: String? {
    guard session.isMeeting else { return nil }
    if isCurrentSessionTheActiveMeeting {
      let store = LiveMeetingTranscriptStore.shared
      guard !store.chunks.isEmpty else { return "Listening — nothing transcribed yet." }
      let minutes = max(1, Int(store.elapsedSeconds / 60))
      let noteCount = store.liveNotes.count
      let notes = noteCount == 1 ? "1 note" : "\(noteCount) notes"
      return "Chat sees the full transcript · \(minutes) min so far · \(notes)"
    }
    let hasTranscript = !(loadMeetingTranscriptFromDisk() ?? "").isEmpty
    guard hasTranscript else { return nil }
    return endedMeetingSummary == nil
      ? "Chat sees the full transcript of this meeting."
      : "Chat sees the summary and full transcript of this meeting."
  }

  /// Puts a line from the notes or transcript into the composer as a quote chip, so the user can
  /// ask about that exact moment instead of paraphrasing it.
  func quoteInComposer(_ text: String) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    addPastedBlock(trimmed, kind: .meetingQuote)
    NotificationCenter.default.post(name: .chatFocusInput, object: nil)
  }

  /// The one-tap questions offered above the composer in a meeting. Each is a full prompt: during a
  /// meeting there is no time to phrase one, and these four cover nearly every mid-meeting ask.
  static let meetingQuickActions: [(label: String, prompt: String)] = [
    (
      "Catch me up",
      "Catch me up on this meeting: what has been discussed so far and what do I need to know right now? Five bullets at most."
    ),
    (
      "Action items",
      "List every action item mentioned so far, with who owns it and any deadline. Only what the transcript actually supports — say so if there are none."
    ),
    (
      "Open questions",
      "Which questions have been raised in this meeting but not answered yet?"
    ),
    (
      "Decisions",
      "What has been decided so far in this meeting? Quote the timestamp for each decision."
    ),
  ]

  func sendQuickAction(_ prompt: String) {
    Task { await sendComposed(finalContent: prompt, attachedParts: []) }
  }

  /// Copies this meeting's raw transcript. The transcript is a thing to paste elsewhere, not a
  /// thing to read in the app, so it gets a button rather than a tab.
  func copyMeetingTranscript() {
    let text: String = {
      if isCurrentSessionTheActiveMeeting {
        return LiveMeetingTranscriptStore.shared.fullTranscriptText()
      }
      return (loadMeetingTranscriptFromDisk() ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }()
    guard !text.isEmpty else {
      showNotice("No transcript yet")
      return
    }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    showNotice("Transcript copied")
  }

  /// Reveals the transcript file in Finder — the escape hatch for actually reading the raw record.
  func revealMeetingTranscript() {
    guard let stem = session.meetingStem else { return }
    let url = MeetingListService.transcriptURL(forStem: stem)
    guard FileManager.default.fileExists(atPath: url.path) else {
      showNotice("No transcript file yet")
      return
    }
    NSWorkspace.shared.activateFileViewerSelecting([url])
  }

  /// Recovers a meeting summary that failed to generate at meeting-end (e.g. a transient Gemini 503
  /// left the meeting with a transcript but no `.summary.md`). Runs when the Summary tab is shown for
  /// an ENDED meeting whose summary is missing but whose transcript exists. Regenerates at most once
  /// per stem per app run; on success, also writes a title via `titleOpenMeetingFromSummary`.
  /// Gated to the main sidebar (`!singleChatOnly`) so the floating Meeting Chat doesn't race the
  /// main VM on title writes for the same session.
  func recoverMeetingSummaryIfNeeded() {
    guard !singleChatOnly,
          session.isMeeting,
          !isCurrentSessionTheActiveMeeting,
          !isRecoveringMeetingSummary,
          let stem = session.meetingStem,
          !attemptedMeetingSummaryStems.contains(stem)
    else { return }
    // Already have a summary (on disk or just recovered)? Nothing to do.
    guard endedMeetingSummary?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true else { return }
    // Need a transcript to summarize.
    let transcript = loadMeetingTranscriptFromDisk()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !transcript.isEmpty else { return }

    attemptedMeetingSummaryStems.insert(stem)
    isRecoveringMeetingSummary = true
    DebugLogger.log("GEMINI-CHAT: Recovering missing meeting summary for \(stem)")
    Task { [weak self] in
      let summary = await MeetingListService.shared.generateAndSaveSummary(forStem: stem)
      guard let self else { return }
      self.isRecoveringMeetingSummary = false
      let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else {
        DebugLogger.logWarning("GEMINI-CHAT: Meeting summary recovery produced no text for \(stem)")
        return
      }
      // `generateAndSaveSummary` wrote the file; bump revision so the Summary tab re-reads it.
      self.summaryRevision &+= 1
      DebugLogger.logSuccess("GEMINI-CHAT: Recovered meeting summary for \(stem)")
      // Title write here is intentionally NOT recorded in `attemptedMeetingTitleStems`: if the title
      // call fails (e.g. transient Gemini 503), `backfillMeetingTitleIfNeeded` gets one more shot
      // next time this meeting is viewed. Recovery is rare, so granting a single title retry is cheap.
      if self.session.meetingStem == stem, (self.session.title?.isEmpty ?? true) {
        self.titleOpenMeetingFromSummary(trimmed)
      }
    }
  }

  // MARK: - Meeting editing tools (refine summary / correct transcript term)

  /// Full transcript text for the current meeting tab, read from disk (the ended-meeting record).
  private func currentMeetingTranscriptText() -> String {
    (loadMeetingTranscriptFromDisk() ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// URL of the current meeting's transcript file (`{stem}.txt`).
  private func meetingTranscriptURL(stem: String) -> URL {
    AppSupportPaths.whisperShortcutApplicationSupportURL()
      .appendingPathComponent(AppConstants.liveMeetingTranscriptDirectory)
      .appendingPathComponent("\(stem).txt")
  }

  /// Backs the `refine_meeting_summary` chat tool. Regenerates this meeting's summary from its full
  /// transcript with the user's instruction applied, saves it to disk, and refreshes the Summary tab.
  /// Only for ended meetings — editing while recording would race the rolling-summary updater.
  func executeRefineMeetingSummaryTool(args: [String: Any]) async -> [String: Any] {
    guard let instruction = (args["instruction"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
          !instruction.isEmpty else {
      return ["error": "Missing required argument: instruction"]
    }
    guard session.isMeeting, let stem = session.meetingStem else {
      return ["error": "This chat is not a meeting, so there is no summary to refine."]
    }
    if isCurrentSessionTheActiveMeeting {
      return ["error": "The summary can be refined after the meeting has ended. Stop the recording first, then ask again."]
    }
    let model = PromptModel.loadSelectedMeetingSummary()
    guard model.hasRequiredCredential else {
      return ["error": "No API credential for the meeting-summary model (\(model.rawValue)). Add it in Settings."]
    }
    var transcript = currentMeetingTranscriptText()
    guard !transcript.isEmpty else {
      return ["error": "This meeting has no transcript to base a summary on."]
    }
    if transcript.count > MeetingListService.meetingContextMaxChars {
      transcript = String(transcript.suffix(MeetingListService.meetingContextMaxChars))
    }
    let currentSummary = (loadMeetingSummaryFromDisk() ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    do {
      let refined = try await MeetingListService.refineSummaryText(
        currentSummary: currentSummary, transcript: transcript, instruction: instruction, model: model)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard !refined.isEmpty else {
        return ["error": "The model returned an empty summary. Try rephrasing the instruction."]
      }
      MeetingListService.shared.saveSummary(refined, transcriptFileURL: meetingTranscriptURL(stem: stem))
      summaryRevision &+= 1
      DebugLogger.logSuccess("GEMINI-CHAT: Refined meeting summary for \(stem)")
      return ["ok": true,
              "detail": "The meeting summary has been updated and is now shown in the Summary tab. Briefly confirm what changed in one sentence — do NOT paste the full summary back."]
    } catch {
      DebugLogger.logError("GEMINI-CHAT: Refine summary failed: \(error.localizedDescription)")
      return ["error": "Failed to refine summary: \(error.localizedDescription)"]
    }
  }

  /// Backs the `correct_transcript_term` chat tool. Literal find-and-replace of `from`→`to` across the
  /// on-disk transcript (no LLM rewrite, so the record stays faithful). Only for ended meetings.
  func executeCorrectTranscriptTermTool(args: [String: Any]) async -> [String: Any] {
    guard let from = args["from"] as? String, !from.isEmpty else {
      return ["error": "Missing required argument: from"]
    }
    guard let to = args["to"] as? String else {
      return ["error": "Missing required argument: to"]
    }
    guard from != to else {
      return ["error": "'from' and 'to' are identical — nothing to change."]
    }
    guard session.isMeeting, let stem = session.meetingStem else {
      return ["error": "This chat is not a meeting, so there is no transcript to correct."]
    }
    if isCurrentSessionTheActiveMeeting {
      return ["error": "The transcript can be corrected after the meeting has ended. Stop the recording first, then ask again."]
    }
    let url = meetingTranscriptURL(stem: stem)
    guard let diskText = try? String(contentsOf: url, encoding: .utf8) else {
      return ["error": "Could not read the meeting transcript file."]
    }
    let occurrences = diskText.components(separatedBy: from).count - 1
    guard occurrences > 0 else {
      return ["error": "The text \"\(from)\" was not found in the transcript. Check the exact spelling."]
    }
    let updated = diskText.replacingOccurrences(of: from, with: to)
    do {
      try updated.write(to: url, atomically: true, encoding: .utf8)
    } catch {
      DebugLogger.logError("GEMINI-CHAT: Write corrected transcript failed: \(error.localizedDescription)")
      return ["error": "Failed to write the corrected transcript: \(error.localizedDescription)"]
    }
    MeetingListService.shared.invalidateCache(for: url)
    summaryRevision &+= 1
    DebugLogger.logSuccess("GEMINI-CHAT: Corrected transcript term in \(stem) (\(occurrences) occurrence(s))")

    var result: [String: Any] = [
      "ok": true,
      "replacements": occurrences,
      "detail": "Replaced \"\(from)\" with \"\(to)\" in \(occurrences) place(s) in the transcript. Briefly confirm to the user.",
    ]
    if ChatToolRegistry.boolArgument(args, "regenerate_summary", default: false) {
      let summaryResult = await executeRefineMeetingSummaryTool(args: [
        "instruction":
          "The transcript term \"\(from)\" was corrected to \"\(to)\". Update the summary to use the corrected term consistently; keep everything else unchanged."
      ])
      result["summary_updated"] = summaryResult["ok"] != nil
    }
    return result
  }

  // MARK: - Memory tools (remember / forget durable user facts)

  /// Backs the `remember_about_user` chat tool. Appends one durable fact to persistent memory
  /// (UserContext/memory.md), deduped. Synchronous — the file is tiny and writes are local.
  func executeRememberAboutUserTool(args: [String: Any]) -> [String: Any] {
    guard let fact = (args["fact"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
          !fact.isEmpty else {
      return ["error": "Missing required argument: fact"]
    }
    let added = ChatMemoryStore.shared.addFact(fact)
    if added {
      return ["ok": true, "remembered": fact,
              "detail": "Saved to persistent memory. Briefly confirm in one sentence; do not list the rest of the memory."]
    }
    return ["ok": true, "remembered": fact, "duplicate": true,
            "detail": "This fact was already remembered — nothing changed. Acknowledge briefly."]
  }

  /// Backs the `forget_about_user` chat tool. Removes every stored fact containing the given text.
  func executeForgetAboutUserTool(args: [String: Any]) -> [String: Any] {
    guard let matching = (args["matching"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
          !matching.isEmpty else {
      return ["error": "Missing required argument: matching"]
    }
    let removed = ChatMemoryStore.shared.removeFacts(matching: matching)
    guard removed > 0 else {
      return ["ok": true, "removed": 0,
              "detail": "No remembered fact matched \"\(matching)\". Tell the user there was nothing to forget."]
    }
    return ["ok": true, "removed": removed,
            "detail": "Forgot \(removed) fact(s). Confirm briefly."]
  }

  // MARK: - Archive / Restore / Delete

  func archiveSession(id: UUID) {
    let wasActive = id == session.id
    DebugLogger.log("SIDEBAR: archiveSession id=\(id) wasActive=\(wasActive) currentSession=\(session.id)")
    store.archiveSession(id: id)
    if wasActive {
      DebugLogger.log("SIDEBAR: archiveSession → switchToCurrentStoreSession")
      switchToCurrentStoreSession()
    } else {
      refreshRecentSessions()
    }
    DebugLogger.log("SIDEBAR: archiveSession done. recentSessions=\(recentSessions.count) currentSession=\(session.id)")
  }

  func archiveOlderSessions(than date: Date) {
    store.archiveOlderSessions(than: date)
    if store.load().id != session.id { switchToCurrentStoreSession() }
    else { refreshRecentSessions() }
    DebugLogger.log("SIDEBAR: Archived chats older than \(date)")
  }

  func archiveOlderMeetings(than date: Date) {
    store.archiveOlderMeetings(than: date)
    if store.load().id != session.id { switchToCurrentStoreSession() }
    else { refreshRecentSessions() }
    DebugLogger.log("SIDEBAR: Archived meetings older than \(date)")
  }

  func archiveOtherSessions(except keepId: UUID) {
    store.archiveOtherSessions(except: keepId)
    if store.load().id != session.id { switchToCurrentStoreSession() }
    else { refreshRecentSessions() }
    DebugLogger.log("SIDEBAR: Archived other chats except \(keepId)")
  }

  func archiveOtherMeetings(except keepId: UUID) {
    var skipIds: Set<UUID> = []
    if isMeetingActive, let activeId = meetingSessionId { skipIds.insert(activeId) }
    store.archiveOtherMeetings(except: keepId, skipIds: skipIds)
    if store.load().id != session.id { switchToCurrentStoreSession() }
    else { refreshRecentSessions() }
    DebugLogger.log("SIDEBAR: Archived other meetings except \(keepId)")
  }

  func restoreSession(id: UUID) {
    DebugLogger.log("SIDEBAR: restoreSession id=\(id) currentSession=\(session.id)")
    store.restoreSession(id: id)
    refreshRecentSessions()
    DebugLogger.log("SIDEBAR: restoreSession done. recentSessions=\(recentSessions.count)")
  }

  func deleteSessionPermanently(id: UUID) {
    // If the deleted session owns the active live meeting, stop the recording first
    // so we don't leave a zombie recorder writing to disk for a session that no
    // longer exists in the UI.
    if isMeetingActive && meetingSessionId == id {
      DebugLogger.log("SIDEBAR: Deleting active meeting session — stopping recorder first")
      NotificationCenter.default.post(name: .chatStopLiveMeeting, object: nil)
      meetingSessionId = nil
    }
    store.deleteSession(id: id)
    if id == session.id { switchToCurrentStoreSession() }
    else { refreshRecentSessions() }
    DebugLogger.log("SIDEBAR: Permanently deleted session \(id)")
  }

  /// Drag-reorders the tab strip so the session with `id` lands at `targetIndex`.
  func moveTab(id: UUID, toIndex targetIndex: Int) {
    store.moveSession(id: id, toIndex: targetIndex)
    refreshRecentSessions()
    DebugLogger.log("GEMINI-CHAT: Moved tab \(id) → index \(targetIndex)")
  }

  /// Renames the given session. Empty/whitespace-only titles clear the title
  /// (so the tab falls back to "New chat" / the auto-title path).
  func renameSession(id: UUID, to newTitle: String) {
    guard var target = store.session(by: id) else { return }
    let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    target.title = trimmed.isEmpty ? nil : String(trimmed.prefix(Self.maxSessionTitleLength))
    store.save(target)
    if id == session.id { session.title = target.title }
    refreshRecentSessions()
    DebugLogger.log("GEMINI-CHAT: Renamed tab \(id) → \(target.title ?? "<nil>")")
  }

  /// Close every tab except `keepId`. The kept tab becomes the active one.
  func closeOtherTabs(keep keepId: UUID) {
    let toClose = recentSessions.map { $0.id }.filter { $0 != keepId }
    for id in toClose { rememberClosed(id: id); store.deleteSession(id: id) }
    if session.id != keepId {
      store.switchToSession(id: keepId)
      switchToCurrentStoreSession()
    } else {
      refreshRecentSessions()
    }
    DebugLogger.log("GEMINI-CHAT: Closed \(toClose.count) other tab(s), kept \(keepId)")
  }

  /// Close every tab to the right of `anchorId` in the current visible order.
  func closeTabsToTheRight(of anchorId: UUID) {
    guard let anchorIdx = recentSessions.firstIndex(where: { $0.id == anchorId }) else { return }
    let toClose = recentSessions.suffix(from: anchorIdx + 1).map { $0.id }
    if toClose.isEmpty { return }
    let activeWillBeClosed = toClose.contains(session.id)
    for id in toClose { rememberClosed(id: id); store.deleteSession(id: id) }
    if activeWillBeClosed {
      store.switchToSession(id: anchorId)
      switchToCurrentStoreSession()
    } else {
      refreshRecentSessions()
    }
    DebugLogger.log("GEMINI-CHAT: Closed \(toClose.count) tab(s) right of \(anchorId)")
  }

  private func buildContents(forSessionId sessionId: UUID) -> [[String: Any]] {
    // Queued sends can target a session that is no longer the visible one,
    // so the history must come from the target session — not `messages`.
    let history = sessionId == session.id
      ? messages
      : (store.session(by: sessionId)?.messages ?? [])
    // Send the full conversation history. Gemini 2.x has a 1M–2M token context window,
    // so truncation is only a safeguard against pathological sessions.
    let maxMessages = AppConstants.chatFullHistoryMaxMessages
    let toSend = history.count > maxMessages
      ? Array(history.suffix(maxMessages))
      : history
    logImagePayloadMeasurement(toSend)
    // A YouTube link is only a link to every provider except Gemini, which can watch the video
    // when it arrives as a `file_data` part (its `url_context` tool refuses YouTube). Resolve
    // which messages get a video part before mapping: the budget is per request and counts from
    // the newest message backwards, so a session full of links doesn't send a dozen videos.
    let isGemini = Self.openChatModel.provider == .gemini
    let videoLinksByMessage = isGemini ? youTubeLinksToAttach(in: toSend) : [:]
    // Every other provider is blind to the link but perfectly willing to describe the video from
    // search results — the failure this feature exists to fix. Tell the newest linking turn so the
    // model says it cannot watch the video instead of confabulating it.
    let unwatchableLinkMessageID: UUID? = isGemini
      ? nil
      : toSend.last { $0.role == .user && !YouTubeVideoLink.detect(in: $0.content).isEmpty }?.id
    // Re-send each user message's attached images on every turn, not just the
    // final one. Otherwise an image is visible to the model only on the turn it
    // was attached and is stripped to text afterwards — so a follow-up like
    // "look at the screenshot" sees no image at all. All providers (Gemini,
    // OpenAI, Grok) convert inline_data on any message, so this is safe.
    return toSend.map { msg in
      // Assistant turns that generated an image carry a ⟦GEMINI_IMG:…⟧ marker with the full
      // base64 inline. Strip it to a short placeholder before re-sending as history: the blob
      // would otherwise bloat every subsequent request and is useless to the model as text.
      let text = msg.role == .model
        ? GeminiAPIClient.stripImageMarkers(msg.content)
        : msg.content
      let videoLinks = videoLinksByMessage[msg.id] ?? []
      if msg.id == unwatchableLinkMessageID {
        var parts: [[String: Any]] = msg.attachedImageParts.map { part in
          ["inline_data": ["mime_type": part.mimeType ?? "image/png", "data": part.data.base64EncodedString()]]
        }
        if !text.isEmpty { parts.append(["text": text]) }
        parts.append(["text":
          "[System note: the message above contains a YouTube link. You cannot watch YouTube videos — "
          + "in this app only Gemini models can. Do not describe the video's contents as if you had seen "
          + "it. Say plainly that you cannot open the video with this model, offer what you can find about "
          + "it from other sources, and mention that switching to a Gemini model lets it be analysed.]"])
        return ["role": msg.role.rawValue, "parts": parts]
      }
      if msg.role == .user && (!msg.attachedImageParts.isEmpty || !videoLinks.isEmpty) {
        var parts: [[String: Any]] = msg.attachedImageParts.map { part in
          ["inline_data": ["mime_type": part.mimeType ?? "image/png", "data": part.data.base64EncodedString()]]
        }
        // Video part first, its note right after: the note explains the clip window, and a model
        // reads it as a caption for the media directly above it.
        for link in videoLinks {
          parts.append(link.geminiVideoPart)
          parts.append(["text": link.geminiContextNote])
        }
        if !text.isEmpty {
          parts.append(["text": text])
        }
        return ["role": msg.role.rawValue, "parts": parts]
      }
      return ["role": msg.role.rawValue, "parts": [["text": text]]]
    }
  }

  /// Which YouTube links get attached as video parts, keyed by message id.
  ///
  /// Videos are the most expensive thing this app can put in a request (~90 tokens per second of
  /// video, re-sent on every follow-up turn), so the budget is small and spent newest-first: the
  /// video the user is currently asking about always wins over one from ten turns ago.
  private func youTubeLinksToAttach(in messages: [ChatMessage]) -> [UUID: [YouTubeVideoLink]] {
    var result: [UUID: [YouTubeVideoLink]] = [:]
    var seenVideoIDs = Set<String>()
    var budget = YouTubeVideoLink.maxVideosPerRequest
    for msg in messages.reversed() where msg.role == .user {
      guard budget > 0 else { break }
      for link in YouTubeVideoLink.detect(in: msg.content) {
        guard budget > 0 else { break }
        // The same video re-posted in a later turn is already attached (with that turn's
        // timestamp) — sending it twice just doubles the token bill.
        guard seenVideoIDs.insert(link.videoID).inserted else { continue }
        result[msg.id, default: []].append(link)
        budget -= 1
      }
    }
    if !result.isEmpty {
      let attached = result.values.flatMap { $0 }
      DebugLogger.log(
        "CHAT-YOUTUBE: attaching \(attached.count) video part(s): "
        + attached.map { link in
          link.shouldClipUpFront
            ? "\(link.videoID)@\(YouTubeVideoLink.formatTimestamp(link.clipRange.start))+\(YouTubeVideoLink.clipWindowSeconds)s"
            : "\(link.videoID)/full"
        }.joined(separator: ", "))
    }
    return result
  }

  /// Measures the image payload re-sent on this turn (images are sent in full on *every*
  /// turn — see `buildContents`). Logs the total plus the portion carried by user turns
  /// older than the last `AppConstants.chatRecentImageTurns` turns: that `savablePerTurn`
  /// figure is what an "images only for the recent N turns" policy would drop from each
  /// request, and is the number to watch before deciding whether the cap is worth it.
  /// Pure measurement — it changes nothing about what gets sent.
  private func logImagePayloadMeasurement(_ toSend: [ChatMessage]) {
    let userTurnIdx = toSend.indices.filter { toSend[$0].role == .user }
    guard !userTurnIdx.isEmpty else { return }
    let window = AppConstants.chatRecentImageTurns
    let recentTurns = Set(userTurnIdx.suffix(window))

    var imgTurns = 0, images = 0, bytes = 0
    var staleTurns = 0, staleImages = 0, staleBytes = 0
    for i in userTurnIdx {
      let parts = toSend[i].attachedImageParts
      guard !parts.isEmpty else { continue }
      let turnBytes = parts.reduce(0) { $0 + $1.data.count }
      imgTurns += 1; images += parts.count; bytes += turnBytes
      if !recentTurns.contains(i) {
        staleTurns += 1; staleImages += parts.count; staleBytes += turnBytes
      }
    }
    guard images > 0 else { return }

    // Decoded bytes; the base64 wire payload is ~4/3 of this.
    func mb(_ b: Int) -> String { String(format: "%.1fMB", Double(b) / 1_048_576) }
    DebugLogger.logNetwork(
      "CHAT-IMG-MEASURE: msgsSent=\(toSend.count) imgTurns=\(imgTurns) images=\(images) "
        + "imgBytes=\(mb(bytes)) wire≈\(mb(bytes * 4 / 3)) | window=\(window)turns "
        + "staleTurns=\(staleTurns) staleImages=\(staleImages) savablePerTurn=\(mb(staleBytes))")
  }

  private func friendlyError(_ error: Error, provider: ChatModelProvider) -> String {
    let name = Self.chatProviderDisplayName(provider)
    if let te = error as? TranscriptionError {
      switch te {
      case .invalidAPIKey, .incorrectAPIKey:
        return "Invalid API key. Please check your API key in Settings."
      case .rateLimited:
        return "Rate limit reached. Please wait a moment and try again."
      case .quotaExceeded:
        return "API quota exceeded. Please try again later."
      case .serverError, .serviceUnavailable:
        return "\(name) is temporarily unavailable. Please try again in a few seconds."
      case .networkError(let msg):
        let lower = msg.lowercased()
        if lower.contains("503") || lower.contains("unavailable")
          || lower.contains("502") || lower.contains("504") || lower.contains("500") {
          return "\(name) is temporarily unavailable. Please try again in a few seconds."
        }
        if msg.hasPrefix("{") || msg.contains("\"error\"") {
          if let extracted = ChatProviderHTTPError.message(from: msg) {
            return "\(name) request failed: \(extracted)"
          }
          return "\(name) request failed. Please try again."
        }
        return msg
      case .fileError(let msg):
        return msg
      default:
        return "Request failed. Please try again."
      }
    }
    if let urlError = error as? URLError {
      switch urlError.code {
      case .notConnectedToInternet, .networkConnectionLost:
        return "No internet connection. Please check your network and try again."
      case .timedOut:
        return "Request timed out. Please try again."
      default:
        return "Network error: \(urlError.localizedDescription)"
      }
    }
    return error.localizedDescription
  }

  static func chatProviderDisplayName(_ provider: ChatModelProvider) -> String {
    switch provider {
    case .gemini: return "Gemini"
    case .grok: return "Grok"
    case .openai: return "OpenAI"
    case .anthropic: return "Claude"
    case .customOpenAI: return "Custom endpoint"
    case .local: return "Local LLM"
    case .localMLX: return "On-device LLM"
    }
  }
}

// MARK: - Tab drag & drop

/// SwiftUI DropDelegate that resolves the dragged session id (carried as a
/// plain text string) and forwards it to a callback once the drop is performed.
private struct TabDropDelegate: DropDelegate {
  let targetIndex: Int
  let onDrop: (String) -> Void

  func validateDrop(info: DropInfo) -> Bool {
    info.hasItemsConforming(to: [.text])
  }

  func performDrop(info: DropInfo) -> Bool {
    guard let provider = info.itemProviders(for: [.text]).first else { return false }
    provider.loadItem(forTypeIdentifier: "public.text", options: nil) { item, _ in
      let str: String? = {
        if let data = item as? Data { return String(data: data, encoding: .utf8) }
        if let s = item as? String { return s }
        if let ns = item as? NSString { return ns as String }
        return nil
      }()
      guard let id = str?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else { return }
      DispatchQueue.main.async { onDrop(id) }
    }
    return true
  }
}

// MARK: - Main View

/// Holds scroll callbacks so Cmd+Up/Down can scroll the message list from anywhere (e.g. when the text field is focused).
private final class ChatScrollActions {
  var scrollToTop: (() -> Void)?
  var scrollToBottom: (() -> Void)?
}

/// PreferenceKey that propagates the measured height of the hidden Text used to size the input field.
private struct InputTextHeightKey: PreferenceKey {
  static var defaultValue: CGFloat = 0
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = max(value, nextValue())
  }
}

struct ChatView: View {
  @StateObject private var viewModel: ChatViewModel
  /// The running meeting's transcript and notes. Observed (not just read) so a note landing during
  /// the meeting actually redraws the note stream — this view shows it live, in the chat itself.
  @ObservedObject private var liveStore = LiveMeetingTranscriptStore.shared
  /// Image data to show in the full-size preview sheet (from pending screenshot or from a sent message thumbnail).
  @State private var previewImageData: Data? = nil
  @State private var scrollActions = ChatScrollActions()
  /// Local `.scrollPosition` binding only — not on the view model so per-frame scroll updates
  /// do not `@Published`-refresh the whole chat. Cleared on `scrollAnchorClearSignal` emissions.
  @State private var scrollPositionID: UUID? = nil
  @State private var scrollAnchorPersistTask: Task<Void, Never>? = nil
  /// Suppresses persisting the scroll anchor while we re-apply it programmatically (during a
  /// tab switch), so the transient reset-to-top doesn't clobber the saved position before we
  /// restore it.
  @State private var suppressAnchorSave: Bool = false
  @State private var hoveredTabId: UUID? = nil
  /// Note the pointer is over, so only that row shows its "Ask" affordance.
  @State private var hoveredNoteId: UUID? = nil
  /// Session id currently being renamed via the context-menu alert.
  @State private var renamingTabId: UUID? = nil
  @State private var renameDraft: String = ""
  /// When true, create a new chat session on first appear (e.g. for the meeting window so it opens with a fresh chat).
  @State private var createNewSessionOnAppear: Bool
  @State private var hasTriggeredNewSessionOnAppear: Bool = false
  @AppStorage(UserDefaultsKeys.chatSidebarVisible) private var sidebarVisible: Bool = true
  @State private var meetingTab: MeetingTab = .chat
  /// True while a folder is being dragged over the window, so the drop target is visible.
  @State private var isFolderDropTargeted: Bool = false

  /// Two surfaces, not three. The raw transcript used to be a tab of its own, but nobody reads a
  /// transcript — it gets pasted somewhere else, which is what the Copy button in the bar is for.
  /// What is left is the notes (the readable record) and the chat, and the chat now shows the notes
  /// inline anyway, so switching is a choice about density rather than about missing information.
  private enum MeetingTab: String, CaseIterable {
    case chat = "Chat"
    case notes = "Notes"
  }

  // MARK: - Folder drop

  /// Resolves dropped items to URLs and hands the directories among them to the view model.
  /// Returns true whenever the drop carried file URLs at all — returning false would make the
  /// item snap back, which reads as "broken" even when the user simply dropped a file.
  private func handleFolderDrop(_ providers: [NSItemProvider]) -> Bool {
    let fileProviders = providers.filter {
      $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
    }
    guard !fileProviders.isEmpty else { return false }
    Task { @MainActor in
      var urls: [URL] = []
      for provider in fileProviders {
        if let url = await Self.loadFileURL(from: provider) { urls.append(url) }
      }
      viewModel.addWorkspaceFolders(urls)
    }
    return true
  }

  private static func loadFileURL(from provider: NSItemProvider) async -> URL? {
    await withCheckedContinuation { continuation in
      _ = provider.loadObject(ofClass: URL.self) { url, _ in
        continuation.resume(returning: url)
      }
    }
  }

  private var folderDropOverlay: some View {
    ZStack {
      ChatTheme.windowBackground.opacity(0.85)
      VStack(spacing: 10) {
        Image(systemName: "folder.badge.plus")
          .font(.system(size: 40))
          .foregroundColor(.accentColor)
        Text("Drop a folder to share it with the chat")
          .font(.headline)
        Text("The chat can then list, read, and search files inside it.")
          .font(.caption)
          .foregroundColor(ChatTheme.secondaryText)
      }
    }
    .overlay(
      RoundedRectangle(cornerRadius: 12)
        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
        .padding(8)
    )
    .allowsHitTesting(false)
  }

  init(meetingContextProvider: (() -> String?)? = nil, createNewSessionOnAppear: Bool = false, store: ChatSessionStore = .shared, singleChatOnly: Bool = false) {
    _viewModel = StateObject(wrappedValue: ChatViewModel(meetingContextProvider: meetingContextProvider, store: store, singleChatOnly: singleChatOnly))
    _createNewSessionOnAppear = State(initialValue: createNewSessionOnAppear)
  }

  var body: some View {
    HStack(spacing: 0) {
      if sidebarVisible && !viewModel.singleChatOnly {
        ChatSidebar(viewModel: viewModel, sidebarVisible: $sidebarVisible)
        Divider()
      }

      GeometryReader { geometry in
        VStack(spacing: 0) {
          if !viewModel.singleChatOnly && !sidebarVisible {
            tabStripHeader(containerWidth: geometry.size.width)
            Divider()
          }
          if viewModel.isCurrentSessionTheActiveMeeting || viewModel.isCurrentSessionMeeting {
            meetingRecordingBar
          }
          // The switcher is hidden while the meeting runs (see `meetingRecordingBar`), so a tab left
          // on Notes from an earlier meeting must not keep the chat hidden behind it.
          if viewModel.isCurrentSessionMeeting && meetingTab == .notes
            && !viewModel.isCurrentSessionTheActiveMeeting {
            meetingNotesView
          } else {
            messageList(scrollActions: scrollActions)
              .overlay(alignment: .bottom) {
                LinearGradient(
                  colors: [ChatTheme.windowBackground.opacity(0), ChatTheme.windowBackground],
                  startPoint: .top, endPoint: .bottom
                )
                .frame(height: 24)
                .allowsHitTesting(false)
              }
            if let error = viewModel.errorMessage {
              errorBanner(error)
            }
            if let notice = viewModel.noticeMessage {
              noticeBanner(notice)
            }
            ChatInputAreaView(viewModel: viewModel, onTapScreenshotThumbnail: { data in
              previewImageData = data
            })
          }
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(ChatTheme.windowBackground)
    // Dropping a folder anywhere in the window shares it — the macOS-native counterpart to
    // /folder. The drop gesture itself is what grants the sandbox access to the folder.
    .onDrop(of: [.fileURL], isTargeted: $isFolderDropTargeted) { providers in
      handleFolderDrop(providers)
    }
    .overlay {
      if isFolderDropTargeted { folderDropOverlay }
    }
    .background(
      Button(viewModel.isCurrentSessionMeeting ? "Archive current meeting" : "Archive current chat") {
        viewModel.archiveSession(id: viewModel.currentSessionId)
      }
      .keyboardShortcut(.delete, modifiers: .command)
      .opacity(0)
      .allowsHitTesting(false)
      .frame(width: 0, height: 0)
    )
    .sheet(isPresented: Binding(
      get: { previewImageData != nil },
      set: { if !$0 { previewImageData = nil } }
    )) {
      if let data = previewImageData, let nsImage = NSImage(data: data) {
        screenshotPreviewSheet(image: nsImage, onDone: { previewImageData = nil })
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: .chatNewChat)) { _ in
      if !viewModel.singleChatOnly { viewModel.createNewSession() }
    }
    .onReceive(NotificationCenter.default.publisher(for: .chatCaptureScreenshot)) { _ in
      Task { await viewModel.captureScreenshot() }
    }
    .onReceive(NotificationCenter.default.publisher(for: .chatClearChat)) { _ in
      viewModel.clearMessages()
    }
    .onReceive(NotificationCenter.default.publisher(for: .chatCloseTab)) { _ in
      viewModel.closeTab(id: viewModel.currentSessionId)
    }
    .onReceive(NotificationCenter.default.publisher(for: .chatReopenLastClosedTab)) { _ in
      viewModel.reopenLastClosedTab()
    }
    .alert("Rename Tab", isPresented: Binding(
      get: { renamingTabId != nil },
      set: { if !$0 { renamingTabId = nil } }
    )) {
      TextField("Tab title", text: $renameDraft)
      Button("Save") {
        if let id = renamingTabId { viewModel.renameSession(id: id, to: renameDraft) }
        renamingTabId = nil
      }
      Button("Cancel", role: .cancel) { renamingTabId = nil }
    }
    .onReceive(NotificationCenter.default.publisher(for: .chatToggleSidebar)) { _ in
      withAnimation(.easeInOut(duration: 0.2)) { sidebarVisible.toggle() }
    }
    .onReceive(NotificationCenter.default.publisher(for: .chatScrollToTop)) { _ in
      scrollActions.scrollToTop?()
    }
    .onReceive(NotificationCenter.default.publisher(for: .chatScrollToBottom)) { _ in
      scrollActions.scrollToBottom?()
    }
    .onAppear {
      if createNewSessionOnAppear, !hasTriggeredNewSessionOnAppear {
        viewModel.createNewSession()
        hasTriggeredNewSessionOnAppear = true
      }
    }
  }

  // MARK: - Tab Strip Header

  /// Keeps the active session tab visible in the horizontal tab strip.
  private func scrollTabStripToActiveSession(using proxy: ScrollViewProxy) {
    withAnimation {
      proxy.scrollTo(viewModel.currentSessionId, anchor: .center)
    }
  }

  private func tabStripHeader(containerWidth: CGFloat) -> some View {
    let iconWidth: CGFloat = 40
    let fixedTabWidth: CGFloat = 160
    let allSessions = viewModel.visibleTabs(maxCount: 999)

    return HStack(spacing: 0) {
      Button(action: { withAnimation(.easeInOut(duration: 0.2)) { sidebarVisible.toggle() } }) {
        Image(systemName: "sidebar.left")
          .font(.system(size: 12, weight: .medium))
          .foregroundColor(ChatTheme.primaryText)
          .frame(width: iconWidth, height: 52)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help("Toggle sidebar")
      .accessibilityLabel("Toggle sidebar")

      ScrollViewReader { proxy in
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 0) {
            ForEach(Array(allSessions.enumerated()), id: \.element.id) { index, session in
              sessionTab(session: session, width: fixedTabWidth)
                .id(session.id)
                .onDrag {
                  NSItemProvider(object: session.id.uuidString as NSString)
                }
                .onDrop(
                  of: [.text],
                  delegate: TabDropDelegate(
                    targetIndex: index,
                    onDrop: { droppedIdString in
                      guard let droppedId = UUID(uuidString: droppedIdString) else { return }
                      viewModel.moveTab(id: droppedId, toIndex: index)
                    }
                  )
                )
            }
          }
        }
        .onChange(of: viewModel.currentSessionId) { _ in
          // Keep the active tab visible after a switch (e.g. via reopen).
          scrollTabStripToActiveSession(using: proxy)
          meetingTab = .chat
        }
        .onChange(of: containerWidth) { _ in
          // Window resize can reset/clamp scroll; re-anchor to the active tab.
          scrollTabStripToActiveSession(using: proxy)
        }
      }

    }
    .frame(height: 52)
  }

  private func sessionTab(session: ChatSession, width: CGFloat) -> some View {
    let isActive = session.id == viewModel.currentSessionId
    let isProcessing = viewModel.isSendingSession(session.id)
    let title = ChatViewModel.displayTitle(for: session)

    return Button(action: { viewModel.switchToSession(id: session.id) }) {
      HStack(spacing: 5) {
        if isProcessing {
          ProgressView().controlSize(.mini).frame(width: 12, height: 12)
        }
        Text(title)
          .font(.caption)
          .lineLimit(2)
          .multilineTextAlignment(.center)
      }
      .padding(.horizontal, 10)
      .frame(width: width, height: 52)
      .background(isActive ? ChatTheme.controlBackground : Color.clear)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .foregroundColor(isActive ? ChatTheme.primaryText : ChatTheme.secondaryText)
    .overlay(alignment: .bottom) {
      if isActive {
        Rectangle().fill(Color.accentColor).frame(height: 2)
      }
    }
    .overlay(alignment: .trailing) {
      Rectangle()
        .fill(ChatTheme.primaryText.opacity(0.1))
        .frame(width: 1)
    }
    .overlay(alignment: .topTrailing) {
      if hoveredTabId == session.id {
        Button(action: { viewModel.closeTab(id: session.id) }) {
          Image(systemName: "xmark")
            .font(.system(size: 7, weight: .bold))
            .foregroundColor(ChatTheme.secondaryText)
            .frame(width: 13, height: 13)
            .background(ChatTheme.controlBackground)
            .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .padding(3)
        .help("Close tab")
        .accessibilityLabel("Close tab")
      }
    }
    .onHover { isHovered in hoveredTabId = isHovered ? session.id : nil }
    .background(NativeTooltip(text: title))
    .pointerCursorOnHover()
    .contextMenu {
      Button("Rename…") {
        renameDraft = session.title ?? ""
        renamingTabId = session.id
      }
      Button("Copy Chat") { viewModel.copyChatToClipboard(sessionId: session.id) }
      Divider()
      Button("Close Tab") { viewModel.closeTab(id: session.id) }
      Button("Close Other Tabs") { viewModel.closeOtherTabs(keep: session.id) }
      Button("Close Tabs to the Right") { viewModel.closeTabsToTheRight(of: session.id) }
    }
  }

  // MARK: - Message List

  /// One entry of a meeting chat's stream: either a chat message or a live note taken from the
  /// room. Regular chats only ever produce `.message`.
  private enum MeetingStreamItem: Identifiable {
    case message(ChatMessage)
    case note(LiveMeetingNote)

    var id: UUID {
      switch self {
      case .message(let m): return m.id
      case .note(let n): return n.id
      }
    }
  }

  /// The chat stream, with the meeting's live notes woven in at the moment they were said.
  ///
  /// This is the point of the whole meeting view: you should be able to see what is being discussed
  /// in the same column where you type, instead of switching to a transcript tab and back. Notes
  /// are placed by when they happened (meeting start + elapsed offset), so a question you asked at
  /// minute 12 sits between the notes for minute 11 and minute 13.
  private var meetingStreamItems: [MeetingStreamItem] {
    let messages = viewModel.messages
    guard viewModel.isCurrentSessionMeeting else { return messages.map { .message($0) } }
    let notes = viewModel.meetingNotesForDisplay
    guard !notes.isEmpty,
          let meetingStart = viewModel.currentMeetingStem.flatMap(MeetingListService.date(fromStem:))
    else { return messages.map { .message($0) } }

    var result: [MeetingStreamItem] = []
    result.reserveCapacity(messages.count + notes.count)
    var noteIndex = 0
    for message in messages {
      while noteIndex < notes.count,
            meetingStart.addingTimeInterval(notes[noteIndex].startTime) <= message.timestamp {
        result.append(.note(notes[noteIndex]))
        noteIndex += 1
      }
      result.append(.message(message))
    }
    while noteIndex < notes.count {
      result.append(.note(notes[noteIndex]))
      noteIndex += 1
    }
    return result
  }

  private func messageList(scrollActions: ChatScrollActions) -> some View {
    let lastUserMessageId = viewModel.messages.last(where: { $0.role == .user })?.id
    // The actively streaming bubble is rendered OUTSIDE the LazyVStack (as a plain sibling
    // below it) so its per-flush height growth cannot trigger a lazy placement pass or a
    // scroll-anchor re-resolution over the whole history. Those two together were the freeze:
    // a growing bubble inside `.scrollTargetLayout()` under `.scrollPosition(id:)` wedged the
    // main thread in one non-returning layout transaction (hang-20260701-134623 =
    // ScrollStateRequestTransform.findClosestSubview; hang-20260703-093924 =
    // LazyVStack.placeSubviews — two hot frames of the same storm). `StreamingBuffer` already
    // isolates render/diff invalidation, but a child's *height* change propagates to its
    // container regardless of observation scoping, so isolation alone couldn't stop the relayout.
    // Detached only when the streaming placeholder is the last message (it always is on the send
    // path; retry truncates the tail before re-sending); any other case renders inline as before.
    let detachedStreaming: (message: ChatMessage, buffer: StreamingBuffer)? = {
      guard let last = viewModel.messages.last,
            let buffer = viewModel.streamingBuffers[last.id] else { return nil }
      return (last, buffer)
    }()
    return ScrollViewReader { proxy in
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          LazyVStack(alignment: .leading, spacing: 20) {
            Color.clear.frame(height: 1).id("listTop")
            if viewModel.messages.isEmpty && !viewModel.isSending {
              emptyStateCommandHints
            }
            ForEach(meetingStreamItems) { item in
              switch item {
              case .note(let note):
                inlineNoteBlock(note)
                  .id(note.id)
              case .message(let message):
                if message.id != detachedStreaming?.message.id {
                  MessageBubbleView(
                    message: message,
                    // Non-streaming bubbles only: the streaming placeholder is rendered
                    // below, outside this lazy list, so per-token growth can't relayout it.
                    streamingBuffer: viewModel.streamingBuffers[message.id],
                    onTapAttachedImage: { previewImageData = $0 },
                    onRetry: message.id == lastUserMessageId
                      ? { viewModel.retryMessage(id: message.id) } : nil)
                    .id(message.id)
                }
              }
            }
          }
          .scrollTargetLayout()

          // Detached streaming bubble: a plain leaf whose height growth only extends the
          // scroll content downward — no lazy placement, no anchor re-resolution. Keeps its
          // `.id` so `proxy.scrollTo(lastId)` still works and it re-enters the lazy list
          // seamlessly at finalize (detach + updateStreamingMessage run in one MainActor step).
          if let detached = detachedStreaming {
            MessageBubbleView(
              message: detached.message,
              streamingBuffer: detached.buffer,
              onTapAttachedImage: { previewImageData = $0 })
              .id(detached.message.id)
          }

          if let err = viewModel.lastSendError, !viewModel.isSending {
            FailedTurnRow(message: err) {
              if let id = lastUserMessageId {
                viewModel.retryMessage(id: id)
              }
            }
            .id("failedTurn")
          }

          ForEach(viewModel.messageQueue.filter { $0.sessionId == viewModel.currentSessionId }) { queued in
            HStack(alignment: .top, spacing: 6) {
              Spacer()
              VStack(alignment: .trailing, spacing: 4) {
                Button(action: { viewModel.removeQueuedMessage(id: queued.id) }) {
                  Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundColor(ChatTheme.secondaryText)
                }
                .buttonStyle(.plain)
                .help("Remove from queue")
                .accessibilityLabel("Remove from queue")
                Text(queued.displayContent)
                  .font(.system(size: 14))
                  .foregroundColor(ChatTheme.secondaryText)
                  .padding(.horizontal, 12)
                  .padding(.vertical, 8)
                  .background(ChatTheme.controlBackground)
                  .clipShape(RoundedRectangle(cornerRadius: 12))
                  .lineLimit(4)
                  .truncationMode(.tail)
                  .frame(maxWidth: 320, alignment: .trailing)
              }
            }
          }
          Color.clear.frame(height: 1).id("listBottom")
        }
        // Readable line length (measure): ~660 px keeps prose near the 50–75-character
        // sweet spot at the 16-pt body font; 720 ran ~90 chars and hurt readability.
        .frame(maxWidth: 660)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .padding(.bottom, 28)
      }
      .scrollPosition(id: $scrollPositionID, anchor: .top)
      // Typing indicator lives OUTSIDE the LazyVStack as a floating overlay so its
      // 60fps TimelineView clock invalidates only its own subtree, not the whole
      // message list. Inside the list it forced a full LazyVStack/GeometryReader
      // re-layout every frame, which could wedge the main thread when a large
      // grounded reply was finalized (sources appended in one shot). See TypingIndicatorView.
      .overlay(alignment: .bottom) {
        if viewModel.isSending {
          // Constrain to the same centered 660px column + 24px gutter as the message
          // list so the dots align with the conversation text instead of pinning to the
          // pane's far-left edge in a wide window.
          TypingIndicatorView()
            .frame(maxWidth: 660, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 24)
            .padding(.bottom, 12)
            .allowsHitTesting(false)
        }
      }
      .onAppear {
        scrollActions.scrollToTop = { scrollToTop(proxy: proxy) }
        scrollActions.scrollToBottom = { scrollToBottom(proxy: proxy) }
        // Restore this session's saved reading position, or scroll to the latest messages if there
        // is none. We never auto-scroll when new messages arrive — the user stays where they are.
        restoreSavedScroll(proxy: proxy)
      }
      .task {
        // Layout is not ready on first frame; re-apply once so the restored position sticks.
        try? await Task.sleep(for: .milliseconds(400))
        restoreSavedScroll(proxy: proxy)
      }
      .onChange(of: scrollPositionID) { _, newValue in
        scheduleScrollAnchorPersist(newValue)
      }
      .onReceive(viewModel.scrollAnchorClearSignal) { _ in
        scrollPositionID = nil
      }
      .onChange(of: viewModel.currentSessionId) { _, _ in
        // Switching tabs swaps the whole message list; restore the new session's position after
        // the swap settles so scrollPosition's own reset doesn't fight us.
        suppressAnchorSave = true
        DispatchQueue.main.async {
          restoreSavedScroll(proxy: proxy)
          suppressAnchorSave = false
        }
      }
      .focusable()
      .focusEffectDisabled()
      .onKeyPress { keyPress in
        guard keyPress.modifiers.contains(.command) else { return .ignored }
        switch keyPress.key {
        case .upArrow:
          scrollActions.scrollToTop?()
          return .handled
        case .downArrow:
          scrollActions.scrollToBottom?()
          return .handled
        default:
          return .ignored
        }
      }
    }
  }

  /// A live note as it appears between chat bubbles: set apart from the conversation by a left rule
  /// and muted styling, so it reads as "the room", not as something you or the model said.
  private func inlineNoteBlock(_ note: LiveMeetingNote) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Rectangle()
        .fill(note.isMarker ? Color.orange.opacity(0.7) : ChatTheme.secondaryText.opacity(0.25))
        .frame(width: 2)
      noteRow(note, hovered: hoveredNoteId == note.id)
    }
    .padding(.vertical, 2)
    .contentShape(Rectangle())
    .onHover { inside in hoveredNoteId = inside ? note.id : nil }
  }

  private var emptyStateCommandHints: some View {
    let config = ShortcutConfigManager.shared.loadConfiguration()
    let shortcuts: [(shortcut: String, description: String)] = [
      (config.startRecording.displayStringWithSeparator, "Dictate"),
      (config.startPrompting.displayStringWithSeparator, "Dictate Prompt"),
      (config.openChat.displayStringWithSeparator, "Chat"),
      (config.openSettings.displayStringWithSeparator, "Settings"),
    ]
    var starters: [(command: String, title: String, icon: String)] = [
      ("/screenshot", "Screenshot", "camera.viewfinder"),
      ("/folder", "Share folder", "folder"),
      ("/meeting", "Start meeting", "record.circle"),
      ("/settings", "Settings", "gear"),
    ]
    if viewModel.singleChatOnly {
      starters = starters.filter { $0.command != "/meeting" }
    }
    return VStack(alignment: .leading, spacing: 22) {
      VStack(alignment: .leading, spacing: 6) {
        Text("Ask anything")
          .font(.title2)
          .fontWeight(.semibold)
          .foregroundColor(ChatTheme.primaryText)
        Text("Type a message, or press / for commands.")
          .font(.callout)
          .foregroundColor(ChatTheme.secondaryText)
      }

      HStack(spacing: 8) {
        ForEach(starters, id: \.command) { item in
          Button {
            Task { await viewModel.sendMessage(userInput: item.command) }
          } label: {
            Label(item.title, systemImage: item.icon)
              .font(.callout)
              .foregroundColor(ChatTheme.primaryText)
              .padding(.horizontal, 10)
              .padding(.vertical, 7)
              .background(ChatTheme.controlBackground)
              .clipShape(RoundedRectangle(cornerRadius: 8))
          }
          .buttonStyle(.plain)
          .help(item.command)
          .pointerCursorOnHover()
          .accessibilityLabel(item.title)
        }
      }

      VStack(alignment: .leading, spacing: 8) {
        Text("Shortcuts")
          .font(.caption)
          .fontWeight(.semibold)
          .foregroundColor(ChatTheme.secondaryText)
        VStack(alignment: .leading, spacing: 6) {
          ForEach(shortcuts, id: \.shortcut) { item in
            HStack(spacing: 10) {
              Text(item.shortcut)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(ChatTheme.primaryText)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(ChatTheme.controlBackground)
                .clipShape(RoundedRectangle(cornerRadius: 4))
              Text(item.description)
                .font(.callout)
                .foregroundColor(ChatTheme.secondaryText)
            }
          }
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.top, 24)
  }

  private func scrollToTop(proxy: ScrollViewProxy) {
    withAnimation(.easeOut(duration: 0.2)) {
      proxy.scrollTo("listTop", anchor: .top)
    }
  }

  private func scrollToBottom(proxy: ScrollViewProxy) {
    withAnimation(.easeOut(duration: 0.2)) {
      if let lastId = viewModel.messages.last?.id {
        proxy.scrollTo(lastId, anchor: .bottom)
      } else {
        proxy.scrollTo("listBottom", anchor: .bottom)
      }
    }
  }

  /// Restores the session's saved top message, or scrolls to the latest messages when there is
  /// none (or the saved message no longer exists). Sets the `scrollPosition` binding and nudges
  /// the proxy so the position holds across the list recreation a resize/screen-move causes.
  private func restoreSavedScroll(proxy: ScrollViewProxy) {
    let sessionId = viewModel.currentSessionId
    if let saved = viewModel.scrollAnchor(for: sessionId),
       viewModel.messages.contains(where: { $0.id == saved }) {
      DebugLogger.logUI("CHAT-SCROLL: restoring saved anchor \(saved.uuidString) session=\(sessionId)")
      scrollPositionID = saved
      proxy.scrollTo(saved, anchor: .top)
    } else {
      scrollPositionID = nil
      scrollToBottom(proxy: proxy)
    }
  }

  /// Debounces UserDefaults persistence while scrolling so per-frame `scrollPosition` updates
  /// do not write on every layout pass.
  private func scheduleScrollAnchorPersist(_ messageId: UUID?) {
    guard !suppressAnchorSave else { return }
    scrollAnchorPersistTask?.cancel()
    scrollAnchorPersistTask = Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(250))
      guard !Task.isCancelled else { return }
      saveScrollAnchorIfValid(messageId)
    }
  }

  /// Persists the current top message as the session's reading position. Ignores nil and ids that
  /// aren't in the current session (transient values during a tab swap).
  private func saveScrollAnchorIfValid(_ messageId: UUID?) {
    guard let messageId, viewModel.messages.contains(where: { $0.id == messageId }) else { return }
    viewModel.setScrollAnchor(messageId, for: viewModel.currentSessionId)
  }

  // MARK: - Error Banner

  private var meetingRecordingBar: some View {
    let isFinishing = viewModel.isCurrentSessionFinishingMeeting
    let isRecording = viewModel.isCurrentSessionTheActiveMeeting && !isFinishing
    return VStack(spacing: 0) {
      HStack(spacing: 0) {
        // Three states, not two. Stopping a meeting has to drain the last chunk through a
        // transcription round trip, and a bar that keeps saying "Recording" through it made the stop
        // look like it had failed — the one moment where the user is waiting for confirmation.
        HStack(spacing: 6) {
          if isFinishing {
            ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 7, height: 7)
          } else {
            Circle()
              .fill(isRecording ? Color.red : ChatTheme.secondaryText.opacity(0.4))
              .frame(width: 7, height: 7)
          }
          Text(isFinishing ? "Finishing…" : (isRecording ? "Recording" : "Ended"))
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(ChatTheme.secondaryText)
        }
        .frame(width: 90, alignment: .leading)
        .help(isFinishing ? "Transcribing the last seconds of audio before saving the meeting" : "")

        // While the meeting runs, the notes stream inline in the chat, so a switcher to a second
        // surface holding the same notes is a choice between identical content. It comes back when
        // the meeting has ended, where Notes carries the summary the chat does not show.
        if !viewModel.isCurrentSessionTheActiveMeeting {
          HStack(spacing: 2) {
            ForEach(MeetingTab.allCases, id: \.self) { tab in
              Button(action: { meetingTab = tab }) {
                Text(tab.rawValue)
                  .font(.system(size: 12, weight: meetingTab == tab ? .semibold : .regular))
                  .foregroundColor(meetingTab == tab ? ChatTheme.primaryText : ChatTheme.secondaryText)
                  .padding(.horizontal, 12)
                  .padding(.vertical, 5)
                  .background(meetingTab == tab ? ChatTheme.windowBackground : Color.clear)
                  .cornerRadius(4)
                  .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
            }
          }
        }

        Spacer()

        // The transcript is a thing you paste elsewhere, not a thing you read here — so it gets a
        // button and a Finder escape hatch instead of a tab of its own.
        Button(action: { viewModel.copyMeetingTranscript() }) {
          HStack(spacing: 4) {
            Image(systemName: "doc.on.doc").font(.system(size: 10))
            Text("Copy transcript").font(.system(size: 11))
          }
          .foregroundColor(ChatTheme.secondaryText)
          .padding(.horizontal, 8)
          .padding(.vertical, 3)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Copy the full transcript of this meeting to the clipboard")
        .accessibilityLabel("Copy transcript")
        .pointerCursorOnHover()
        .contextMenu {
          Button("Show Transcript File in Finder") { viewModel.revealMeetingTranscript() }
        }

        // Stopping is not instant, so the button reports the wait instead of inviting a second press:
        // pressing Stop again does nothing, and a control that looks live but isn't reads as broken.
        Button(action: {
          if isRecording {
            NotificationCenter.default.post(name: .chatStopLiveMeeting, object: nil)
          } else if !isFinishing {
            // Rehydrate this meeting's transcript/notes before resuming (see requestResumeMeeting).
            viewModel.requestResumeMeeting()
          }
        }) {
          Text(isFinishing ? "Stopping…" : (isRecording ? "Stop" : "Resume"))
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(isRecording ? .white : ChatTheme.primaryText)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(isRecording ? Color.red.opacity(0.85) : Color.clear)
            .cornerRadius(4)
            .overlay(isRecording ? nil : RoundedRectangle(cornerRadius: 4).stroke(ChatTheme.secondaryText.opacity(0.3), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(isFinishing)
        .opacity(isFinishing ? 0.5 : 1)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
      Divider()
    }
    .background(ChatTheme.topBarBackground)
    // Recovery used to depend on the user opening the Summary tab. Chat is the default tab, so a
    // meeting whose summary failed to generate could sit there forever without anyone asking for
    // it again; the bar is shown for every meeting, so this is the earliest reliable trigger.
    .onAppear { viewModel.recoverMeetingSummaryIfNeeded() }
  }

  /// One live note (or marker) as it appears both in the Notes tab and inline in the chat stream.
  /// Hovering reveals "Ask" — the shortest path from "that bullet is interesting" to a question
  /// about it, without retyping what was said.
  private func noteRow(_ note: LiveMeetingNote, hovered: Bool) -> some View {
    HStack(alignment: .top, spacing: 8) {
      Text(note.isMarker ? "★" : note.timestampString)
        .font(.system(size: 12, weight: .medium, design: .monospaced))
        .foregroundColor(note.isMarker ? .orange : ChatTheme.secondaryText)
        .frame(minWidth: 46, alignment: .leading)

      VStack(alignment: .leading, spacing: 4) {
        ForEach(Array(note.bullets.enumerated()), id: \.offset) { _, bullet in
          HStack(alignment: .top, spacing: 6) {
            Text("•")
              .font(.system(size: 13))
              .foregroundColor(ChatTheme.secondaryText)
            Text(bullet)
              .font(.system(size: 13))
              .foregroundColor(ChatTheme.primaryText)
              .fixedSize(horizontal: false, vertical: true)
              .textSelection(.enabled)
          }
        }
      }

      Spacer(minLength: 4)

      Button(action: {
        viewModel.quoteInComposer("\(note.timestampString) \(note.bullets.joined(separator: " "))")
      }) {
        Text("Ask")
          .font(.system(size: 10, weight: .medium))
          .foregroundColor(ChatTheme.secondaryText)
          .padding(.horizontal, 6)
          .padding(.vertical, 2)
          .overlay(
            RoundedRectangle(cornerRadius: 4)
              .stroke(ChatTheme.secondaryText.opacity(0.3), lineWidth: 1))
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .opacity(hovered ? 1 : 0)
      .help("Quote this note in the composer and ask about it")
      .accessibilityLabel("Ask about this note")
      .pointerCursorOnHover()
    }
  }

  /// The Notes tab: the live note stream while a meeting runs, the final summary once it ended.
  /// The transcript is deliberately not here — see `MeetingTab`.
  private var meetingNotesView: some View {
    let isLive = viewModel.isCurrentSessionTheActiveMeeting
    let notes = viewModel.meetingNotesForDisplay
    let summary = isLive ? nil : viewModel.endedMeetingSummary
    return ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        if let summary, !summary.isEmpty {
          Text(summary)
            .font(.system(size: 14))
            .foregroundColor(ChatTheme.primaryText)
            .textSelection(.enabled)
          if !notes.isEmpty {
            Divider().padding(.vertical, 8)
            Text("Live notes")
              .font(.system(size: 11, weight: .semibold))
              .foregroundColor(ChatTheme.secondaryText)
          }
        } else if viewModel.isRecoveringMeetingSummary {
          HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Generating summary…")
              .font(.system(size: 14))
              .foregroundColor(ChatTheme.secondaryText)
          }
          .padding(.top, 40)
          .frame(maxWidth: .infinity)
        }

        if !notes.isEmpty {
          LazyVStack(alignment: .leading, spacing: 10) {
            ForEach(notes) { note in
              noteRow(note, hovered: hoveredNoteId == note.id)
                .contentShape(Rectangle())
                .onHover { inside in hoveredNoteId = inside ? note.id : nil }
            }
          }
        } else if summary == nil && !viewModel.isRecoveringMeetingSummary {
          Text(isLive ? "Listening — notes appear as the meeting goes on." : "No notes for this meeting.")
            .font(.system(size: 14))
            .foregroundColor(ChatTheme.secondaryText)
            .padding(.top, 40)
            .frame(maxWidth: .infinity)
        }
      }
      .padding(16)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(ChatTheme.windowBackground)
    .onAppear {
      viewModel.recoverMeetingSummaryIfNeeded()
    }
  }

  /// Transient strip above the composer. Error and notice differ only in icon and tint,
  /// so they share one implementation.
  private func banner(
    _ message: String,
    icon: String,
    background: Color,
    dismiss: @escaping () -> Void
  ) -> some View {
    HStack(spacing: 8) {
      Image(systemName: icon)
        .foregroundColor(.white)
        .font(.footnote)
      Text(message)
        .font(.footnote)
        .foregroundColor(.white)
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
      Spacer()
      Button(action: dismiss) {
        Image(systemName: "xmark")
          .font(.footnote.bold())
          .foregroundColor(.white.opacity(0.8))
      }
      .buttonStyle(.plain)
      .help("Dismiss")
      .accessibilityLabel("Dismiss")
      .pointerCursorOnHover()
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(background)
  }

  private func noticeBanner(_ message: String) -> some View {
    banner(
      message,
      icon: "checkmark.circle.fill",
      background: Color.green.opacity(0.75),
      dismiss: { viewModel.noticeMessage = nil })
  }

  private func errorBanner(_ message: String) -> some View {
    banner(
      message,
      icon: "exclamationmark.triangle.fill",
      background: Color.red.opacity(0.85),
      dismiss: { viewModel.errorMessage = nil })
  }

  private func screenshotPreviewSheet(image: NSImage, onDone: @escaping () -> Void) -> some View {
    VStack(spacing: 0) {
      HStack {
        Spacer()
        Button("Done", action: onDone)
        .keyboardShortcut(.defaultAction)
        .pointerCursorOnHover()
        .padding()
      }
      Image(nsImage: image)
        .resizable()
        .scaledToFit()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ChatTheme.windowBackground)
    }
    .frame(minWidth: 800, minHeight: 600)
    .frame(idealWidth: 1000, idealHeight: 700)
  }
}

// MARK: - Input Area (isolated to avoid full-view re-renders on each keystroke)

/// Standalone view that owns the input text state. Typing only invalidates this subtree,
/// not the parent's message list, header, or other heavy views.
struct ChatInputAreaView: View {
  @ObservedObject var viewModel: ChatViewModel
  var onTapScreenshotThumbnail: (Data) -> Void
  /// Observed so the "what the chat can see" line keeps counting up while the meeting runs.
  @ObservedObject private var liveStore = LiveMeetingTranscriptStore.shared

  @StateObject private var composer = GeminiComposerController()
  /// Highlighted row in the slash-command suggestion overlay (↑/↓ navigation, Enter/Tab to select).
  /// Reset to 0 whenever the typed slash word changes (see `body`'s `onChange`).
  @State private var selectedSuggestionIndex = 0
  @AppStorage(UserDefaultsKeys.chatCloseOnFocusLoss) private var closeOnFocusLoss: Bool = SettingsDefaults.chatCloseOnFocusLoss
  @AppStorage(UserDefaultsKeys.selectedChatModel) private var selectedChatModelRaw: String = SettingsDefaults.selectedChatModel.rawValue

  private static let inputMinHeight: CGFloat = 32
  private static let inputMaxHeight: CGFloat = 160

  /// One slash-command button in the row below the composer (/attach, /folder, /screenshot,
  /// /new, /meeting). They differ only in icon, label, tint and enablement, so they share
  /// one definition — the visible label doubles as the VoiceOver name.
  @ViewBuilder
  private func composerToolbarButton(
    icon: String,
    label: String,
    help: String,
    tint: Color = ChatTheme.secondaryText,
    isDisabled: Bool = false,
    showsProgress: Bool = false,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Group {
        if showsProgress {
          ProgressView().controlSize(.mini).frame(width: 12, height: 12)
        } else {
          Image(systemName: icon).font(.system(size: 13))
        }
      }
      .foregroundColor(tint)
      .frame(width: 28, height: 28)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(isDisabled)
    .help(help)
    .accessibilityLabel(label)
    .pointerCursorOnHover()
  }

  private var inputHeight: CGFloat {
    min(Self.inputMaxHeight, max(Self.inputMinHeight, composer.measuredHeight))
  }

  // Last whitespace-separated word at end of plain text — for slash-command detection.
  private var lastWord: String {
    let trimmed = composer.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.components(separatedBy: .whitespacesAndNewlines).last(where: { !$0.isEmpty }) ?? ""
  }

  // True when the composer has anything to send
  private var hasContent: Bool { !composer.isEmpty }

  /// Current chat model for display (with migration); syncs with UserDefaults via @AppStorage.
  /// Audio-only models (e.g. `openaiGPT4oAudio`) fall back to the default since they can't
  /// power text chat; superseded models resolve to their replacement so the label always
  /// matches an entry in the picker.
  private var resolvedOpenGeminiModel: PromptModel {
    let migratedRaw = PromptModel.migrateLegacyPromptRawValue(selectedChatModelRaw)
    let resolved = PromptModel(rawValue: migratedRaw)
      .map { PromptModel.migrateIfDeprecated($0) }
      ?? SettingsDefaults.selectedChatModel
    if let replacement = resolved.chatReplacement { return replacement }
    return resolved.supportsTextChat ? resolved : SettingsDefaults.selectedChatModel
  }


  var body: some View {
    VStack(spacing: 0) {
      commandSuggestionsOverlay
      inputBar
    }
    // Re-home the highlight whenever the typed slash word changes, so filtering the
    // suggestion list never leaves the selection pointing at a now-hidden row. Prefer an
    // exact command match so typing a full command (e.g. "/gpt5", "/gpt") + Enter dispatches
    // *that* command, not the recency-top prefix sibling. No exact match (e.g. bare "/") →
    // top row, preserving the one-Enter recency toggle. ↑/↓ override this afterward.
    .onChange(of: lastWord) {
      let list = filteredCommandSuggestions
      let typed = lastWord.lowercased()
      selectedSuggestionIndex = list.firstIndex { $0.command.lowercased() == typed } ?? 0
    }
    .onAppear {
      viewModel.composerScreenshotCountProvider = { [weak composer] in composer?.screenshotCount ?? 0 }
      viewModel.composerFileCountProvider = { [weak composer] in composer?.fileAttachmentCount ?? 0 }
    }
    .onReceive(NotificationCenter.default.publisher(for: .chatFocusInput)) { _ in
      Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(50))
        composer.focus()
      }
    }
    // Note: composer state intentionally persists across tab switches and
    // new-chat creation — the typed text and attached screenshots/selection
    // belong to the user's in-progress draft, not to any particular session.
    // Drain VM-side staging fields (populated by /screenshot, attachFile button, etc.)
    // into the inline composer document, then clear the VM fields.
    .onChange(of: viewModel.pendingScreenshots) { newValue in
      guard !newValue.isEmpty else { return }
      for data in newValue { composer.insertScreenshot(data) }
      viewModel.pendingScreenshots = []
    }
    .onChange(of: viewModel.pendingFileAttachments.count) { _ in
      guard !viewModel.pendingFileAttachments.isEmpty else { return }
      for f in viewModel.pendingFileAttachments {
        composer.insertFile(data: f.data, mimeType: f.mimeType, filename: f.filename)
      }
      viewModel.pendingFileAttachments = []
    }
    .onChange(of: viewModel.pastedBlocks.count) { _ in
      guard !viewModel.pastedBlocks.isEmpty else { return }
      for block in viewModel.pastedBlocks {
        composer.insertPastedBlock(text: block.content, kind: block.kind)
      }
      viewModel.pastedBlocks = []
    }
  }

  /// Slash commands recognized by `submitComposer`. Derived from the canonical
  /// `commandSuggestions` list so the autocomplete and the dispatcher can never
  /// drift. Argument-taking commands (`/model`, `/think`) are excluded because they
  /// complete inline and dispatch separately (see `ChatViewModel.argumentCommands`).
  private static let knownSlashCommands: Set<String> =
    Set(ChatViewModel.commandSuggestions.map(\.command).filter { !ChatViewModel.argumentCommands.contains($0) })
      .union(ChatViewModel.modelCommandLookup.keys) // adds the silent /openai alias (not in commandSuggestions)

  /// Slash-command suggestions matching the word the caret sits on (empty unless that
  /// word starts with "/"). Single source for the overlay's rows and for ↑/↓ navigation,
  /// Tab, and Enter selection, so the highlighted row and the dispatched command always agree.
  private var filteredCommandSuggestions: [(command: String, description: String)] {
    guard lastWord.hasPrefix("/") else { return [] }
    let prefix = lastWord.lowercased()
    let matches = viewModel.commandSuggestionsForDisplay.filter { $0.command.lowercased().hasPrefix(prefix) }
    // Bare "/" used to dump every model slug. Keep actions + provider aliases
    // (`/gemini`, `/gpt`, `/claude`…); require 3+ characters before listing per-model IDs.
    guard prefix.count < 3 else { return matches }
    let providerAliases = Set(ChatModelProvider.allCases.map { "/\($0.commandAlias)" })
    let actionCommands = Set(
      (ChatViewModel.commandsBeforeModels + ChatViewModel.commandsAfterModels).map(\.command)
    )
    return matches.filter { actionCommands.contains($0.command) || providerAliases.contains($0.command) }
  }

  /// The command for the currently highlighted suggestion row, or nil when the overlay isn't
  /// showing. `selectedSuggestionIndex` is clamped here so a stale index can never crash.
  private func highlightedSuggestionCommand() -> String? {
    let list = filteredCommandSuggestions
    guard !list.isEmpty else { return nil }
    return list[max(0, min(selectedSuggestionIndex, list.count - 1))].command
  }

  /// Moves the suggestion highlight by `delta` (wrapping top↔bottom). Returns true only when the
  /// overlay is showing — that's the signal the composer uses to decide whether ↑/↓ should drive
  /// the menu (true) or fall through to normal caret movement (false).
  private func moveSuggestionSelection(by delta: Int) -> Bool {
    let count = filteredCommandSuggestions.count
    guard count > 0 else { return false }
    selectedSuggestionIndex = ((selectedSuggestionIndex + delta) % count + count) % count
    return true
  }

  /// Applies a chosen suggestion: argument-taking commands complete inline (so the user can type
  /// the argument); every other command strips the slash token and dispatches. Shared by Tab and Enter.
  private func selectCommand(_ command: String) {
    composer.removeTrailingWord()
    if ChatViewModel.argumentCommands.contains(command) {
      composer.textView?.insertText(command + " ", replacementRange: NSRange(location: NSNotFound, length: 0))
    } else {
      Task { await viewModel.sendMessage(userInput: command) }
    }
    selectedSuggestionIndex = 0
  }

  /// Sends the current composer contents. When the suggestion overlay is showing, Enter selects
  /// the highlighted command instead. Otherwise recognized slash commands strip just the slash
  /// token (preserving any other attachments / text) and dispatch through the legacy `sendMessage`;
  /// everything else is sent in document order.
  private func submitComposer() {
    if let command = highlightedSuggestionCommand() {
      // A command typed out in full dispatches on Enter even while the overlay still shows it.
      // Completing "/workspace" to "/workspace " appends a space and nothing else, which reads as
      // "the command is broken" — and every argument command's bare form is a real status query.
      // Prefix matches still complete inline, so "/mo" ⏎ becomes "/model " as before.
      let typedInFull =
        ChatViewModel.argumentCommands.contains(command) && lastWord.lowercased() == command
      if !typedInFull {
        selectCommand(command)
        return
      }
    }
    let output = composer.serialize()
    let typed = output.typedText
    let lower = typed.lowercased()
    let isArgumentCommand = ChatViewModel.argumentCommands.contains { lower == $0 || lower.hasPrefix($0 + " ") }
    let isRecognizedSlashCommand =
      Self.knownSlashCommands.contains(lower) || isArgumentCommand
    if isRecognizedSlashCommand {
      if isArgumentCommand {
        // Strip the entire command line so multi-token args (e.g.
        // "/model 3.1 flash lite") don't leave residue in the composer.
        composer.removeTrailingPlainText(suffix: typed)
      } else {
        composer.removeTrailingWord()
      }
      Task { await viewModel.sendMessage(userInput: typed) }
      return
    }
    composer.clearAll()
    Task {
      await viewModel.sendComposed(
        finalContent: output.finalContent,
        attachedParts: output.attachedParts)
    }
  }

  /// Tab key in composer: complete/dispatch the highlighted suggestion without clearing the
  /// rest of the composer.
  private func handleTabComplete() -> Bool {
    guard let command = highlightedSuggestionCommand() else { return false }
    selectCommand(command)
    return true
  }

  // MARK: - Command autocomplete

  private var commandSuggestionsOverlay: some View {
    Group {
      if lastWord.hasPrefix("/") {
        let suggestions = filteredCommandSuggestions
        if !suggestions.isEmpty {
          let highlight = max(0, min(selectedSuggestionIndex, suggestions.count - 1))
          ScrollViewReader { proxy in
            ScrollView {
              VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(suggestions.enumerated()), id: \.element.command) { index, item in
                  HStack(alignment: .top, spacing: 8) {
                    Text(item.command)
                      .font(.system(.body, design: .monospaced))
                      .fontWeight(.medium)
                      .foregroundColor(ChatTheme.primaryText)
                    Text(item.description)
                      .font(.caption)
                      .foregroundColor(ChatTheme.secondaryText)
                      .lineLimit(2)
                  }
                  .frame(maxWidth: .infinity, alignment: .leading)
                  .padding(.horizontal, 12)
                  .padding(.vertical, 8)
                  .background(
                    RoundedRectangle(cornerRadius: 6)
                      .fill(index == highlight ? ChatTheme.primaryText.opacity(0.10) : Color.clear)
                  )
                  .padding(.horizontal, 4)
                  .contentShape(Rectangle())
                  .onTapGesture { selectCommand(item.command) }
                  .id(item.command)
                }
              }
              .padding(.vertical, 6)
            }
            .frame(maxHeight: 260)
            // Keep the highlighted row visible as ↑/↓ moves through a long list.
            .onChange(of: selectedSuggestionIndex) { _ in
              let i = max(0, min(selectedSuggestionIndex, suggestions.count - 1))
              withAnimation(.easeOut(duration: 0.1)) {
                proxy.scrollTo(suggestions[i].command, anchor: .center)
              }
            }
          }
          // Was `.allowsHitTesting(false)` — that also swallowed scroll gestures, so a list
          // longer than 260pt couldn't be scrolled with trackpad/wheel (only ↑/↓ auto-scroll
          // worked). The overlay sits ABOVE the composer in a VStack (no overlap), and rows are
          // now tap-to-select, so enabling hit testing is safe and makes the popup scrollable.
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(ChatTheme.controlBackground)
          .overlay(
            RoundedRectangle(cornerRadius: 8)
              .strokeBorder(ChatTheme.primaryText.opacity(ChatTheme.borderOpacity), lineWidth: 1)
          )
          .clipShape(RoundedRectangle(cornerRadius: 8))
          .frame(maxWidth: 720)
          .frame(maxWidth: .infinity, alignment: .center)
          .padding(.horizontal, 24)
          .padding(.bottom, 4)
        }
      }
    }
  }

  // MARK: - Input Bar (Claude-style: composer on top, toolbar below)

  /// Meeting-only strip above the composer: one-tap questions, and one line saying exactly what the
  /// model can see. Both exist because a meeting chat is used under time pressure — there is no
  /// moment to phrase "summarise what I missed", and no way to guess how far back the chat can look.
  @ViewBuilder
  private var meetingComposerStrip: some View {
    if viewModel.isCurrentSessionMeeting {
      VStack(alignment: .leading, spacing: 6) {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 6) {
            ForEach(ChatViewModel.meetingQuickActions, id: \.label) { action in
              Button(action: { viewModel.sendQuickAction(action.prompt) }) {
                Text(action.label)
                  .font(.system(size: 11))
                  .foregroundColor(ChatTheme.primaryText)
                  .padding(.horizontal, 10)
                  .padding(.vertical, 4)
                  .background(
                    Capsule().fill(ChatTheme.controlBackground))
                  .contentShape(Capsule())
              }
              .buttonStyle(.plain)
              .disabled(viewModel.isSending)
              .opacity(viewModel.isSending ? 0.5 : 1)
              .pointerCursorOnHover()
            }
          }
        }

        if let description = viewModel.meetingContextDescription {
          Text(description)
            .font(.system(size: 10))
            .foregroundColor(ChatTheme.secondaryText)
        }
      }
      .padding(.horizontal, 10)
      .padding(.top, 8)
    }
  }

  private var inputBar: some View {
    VStack(spacing: 0) {
      meetingComposerStrip

      // Composer: NSTextView with inline screenshot/paste/file attachments.
      ChatComposerTextView(
        controller: composer,
        placeholder: "Message \(resolvedOpenGeminiModel.displayName)…",
        onSubmit: { submitComposer() },
        onCancel: {
          if viewModel.isSending { viewModel.cancelSend() }
        },
        onTabComplete: { handleTabComplete() },
        onMoveSelection: { delta in moveSuggestionSelection(by: delta) },
        onClickScreenshot: { data in onTapScreenshotThumbnail(data) },
        onAttachmentRejected: { viewModel.errorMessage = $0 }
      )
      .frame(height: inputHeight)

      // Toolbar row below composer: action buttons left, model selector + send right
      HStack(spacing: 4) {
        composerToolbarButton(
          icon: "paperclip",
          label: "/attach",
          help: "Attach a file (PDF, image, …) to your next message.",
          isDisabled: viewModel.isSending,
          action: { viewModel.attachFile() })

        composerToolbarButton(
          icon: "folder",
          label: "/folder",
          help: "Share a folder so the chat can list, read, and search files in it. You can also drop a folder onto this window.",
          isDisabled: viewModel.isSending,
          action: { viewModel.shareFolder() })

        composerToolbarButton(
          icon: "camera.viewfinder",
          label: "/screenshot",
          help: "Capture screen without this window; image will be attached to your next message.",
          tint: viewModel.screenshotCaptureInProgress ? ChatTheme.secondaryText.opacity(0.6) : ChatTheme.secondaryText,
          isDisabled: viewModel.screenshotCaptureInProgress || viewModel.isSending,
          showsProgress: viewModel.screenshotCaptureInProgress,
          action: { Task { await viewModel.captureScreenshot() } })

        if !viewModel.singleChatOnly {
          composerToolbarButton(
            icon: "square.and.pencil",
            label: "/new",
            help: "Start a new chat (previous chat stays in history)",
            action: { viewModel.createNewSession() })
        }

        composerToolbarButton(
          icon: "record.circle",
          label: "/meeting",
          help: viewModel.isMeetingActive ? "Stop the current meeting recording" : "Start a new live meeting recording",
          tint: viewModel.isMeetingActive ? .red : ChatTheme.secondaryText,
          action: { viewModel.handleMeetingButtonTap() })

        Spacer()

        Menu {
          ForEach(PromptModel.chatModels, id: \.self) { model in
            Button(action: {
              selectedChatModelRaw = model.rawValue
              ChatViewModel.recordModelUse(model) // keep autocomplete recency in sync with the picker
              NotificationCenter.default.post(name: .promptModelChanged, object: model)
            }) {
              Text(model.displayName)
            }
          }
        } label: {
          HStack(spacing: 4) {
            Image(systemName: "cpu").font(.caption)
            Text(resolvedOpenGeminiModel.displayName).font(.caption)
          }
          .foregroundColor(ChatTheme.secondaryText)
          .padding(.horizontal, 8)
          .padding(.vertical, 5)
          .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Select model")

        // Queue count indicator (current session's queue only)
        let queuedHere = viewModel.messageQueue.filter { $0.sessionId == viewModel.currentSessionId }.count
        if viewModel.isSending && queuedHere > 0 {
          Text("\(queuedHere) queued")
            .font(.caption2)
            .foregroundColor(ChatTheme.secondaryText)
        }

        // Send / Stop button
        Button(action: {
          if viewModel.isSending {
            viewModel.cancelSend()
          } else {
            submitComposer()
          }
        }) {
          Group {
            if viewModel.isSending {
              Image(systemName: "stop.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(ChatTheme.primaryText)
            } else {
              Image(systemName: "arrow.up")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(hasContent ? ChatTheme.windowBackground : ChatTheme.secondaryText.opacity(0.5))
            }
          }
          .frame(width: 30, height: 30)
          .background(
            RoundedRectangle(cornerRadius: 8)
              .fill(viewModel.isSending ? Color.red.opacity(0.8) : (hasContent ? ChatTheme.primaryText : ChatTheme.controlBackground))
          )
        }
        .buttonStyle(.plain)
        .disabled(!hasContent && !viewModel.isSending)
        .help(viewModel.isSending ? "Stop sending (/stop)" : "Send message")
        .accessibilityLabel(viewModel.isSending ? "Stop sending" : "Send message")
        .pointerCursorOnHover()
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 6)
    }
    .frame(maxWidth: 720)
    // Composer fill matches the conversation pane (#0C1117); the 1px stroke keeps it delineated.
    .background(ChatTheme.windowBackground)
    .clipShape(RoundedRectangle(cornerRadius: 14))
    .overlay(
      RoundedRectangle(cornerRadius: 14)
        .strokeBorder(ChatTheme.primaryText.opacity(ChatTheme.borderOpacity), lineWidth: 1)
    )
    .frame(maxWidth: .infinity, alignment: .center)
    .padding(.horizontal, 24)
    .padding(.top, 10)
    .padding(.bottom, 14)
    .contentShape(Rectangle())
    .onTapGesture {
      composer.focus()
    }
  }



}

// MARK: - Native macOS tooltip shim

/// Sets toolTip directly on the underlying NSView — works reliably where SwiftUI's .help() does not.
private struct NativeTooltip: NSViewRepresentable {
  let text: String
  func makeNSView(context: Context) -> NSView { NSView() }
  func updateNSView(_ nsView: NSView, context: Context) { nsView.toolTip = text }
}

// MARK: - Input scrollbar auto-hide (macOS)

/// Finds the NSScrollView backing the TextEditor (sibling in the view hierarchy) and sets autohidesScrollers
/// so the scrollbar only appears when content overflows.
private struct ChatInputScrollViewAutohideAnchor: NSViewRepresentable {
  func makeNSView(context: Context) -> NSView {
    let v = NSView()
    v.frame = .zero
    return v
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    guard !context.coordinator.didConfigure else { return }
    DispatchQueue.main.async {
      guard !context.coordinator.didConfigure else { return }
      if let scroll = Self.findSiblingScrollView(from: nsView) {
        scroll.autohidesScrollers = true
        context.coordinator.didConfigure = true
      }
    }
  }

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  final class Coordinator {
    var didConfigure = false
  }

  private static func findSiblingScrollView(from view: NSView) -> NSScrollView? {
    guard let parent = view.superview else { return nil }
    for subview in parent.subviews where subview !== view {
      if let scroll = findScrollViewInTree(subview) { return scroll }
    }
    return nil
  }

  private static func findScrollViewInTree(_ view: NSView) -> NSScrollView? {
    if let scroll = view as? NSScrollView { return scroll }
    for sub in view.subviews {
      if let scroll = findScrollViewInTree(sub) { return scroll }
    }
    return nil
  }
}


// MARK: - Flow Layout (wrapping)

/// Lays out subviews left-to-right and wraps to the next line when horizontal space is insufficient.
/// Uses a bounded default width when proposal is unspecified so the layout never reports unbounded size.
private struct FlowLayout: Layout {
  var horizontalSpacing: CGFloat = 10
  var verticalSpacing: CGFloat = 6
  /// Fallback width when proposal has no finite width (avoids destabilizing parent layout).
  private static let defaultMaxWidth: CGFloat = 500

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let maxWidth: CGFloat
    if let w = proposal.width, w.isFinite, w > 0 {
      maxWidth = w
    } else {
      maxWidth = Self.defaultMaxWidth
    }
    var x: CGFloat = 0
    var y: CGFloat = 0
    var rowHeight: CGFloat = 0
    var totalWidth: CGFloat = 0
    for subview in subviews {
      let size = subview.sizeThatFits(.unspecified)
      let itemWidth = min(size.width, maxWidth)
      if x + itemWidth > maxWidth, x > 0 {
        x = 0
        y += rowHeight + verticalSpacing
        rowHeight = 0
      }
      rowHeight = max(rowHeight, size.height)
      x += itemWidth + horizontalSpacing
      totalWidth = max(totalWidth, x - horizontalSpacing)
    }
    return CGSize(width: min(totalWidth, maxWidth), height: y + rowHeight)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    let maxWidth = bounds.width
    guard maxWidth > 0 else { return }
    var x = bounds.minX
    var y = bounds.minY
    var rowHeight: CGFloat = 0
    for subview in subviews {
      let size = subview.sizeThatFits(.unspecified)
      let itemWidth = min(size.width, maxWidth)
      if x - bounds.minX + itemWidth > maxWidth, x > bounds.minX {
        x = bounds.minX
        y += rowHeight + verticalSpacing
        rowHeight = 0
      }
      subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(width: itemWidth, height: size.height))
      rowHeight = max(rowHeight, size.height)
      x += itemWidth + horizontalSpacing
    }
  }
}


// MARK: - Model Reply View

/// One prose region, or a non-text block (tables/code/images stay separate so layout stays correct).
private enum ModelReplyRenderSegment {
  case prose(AttributedString)
  case table(ParsedTable)
  case codeBlock(String, String?)
  case image(NSImage)
}

/// Boxes parsed reply segments so they can be stored in an NSCache (class-only values).
private final class ModelReplySegmentBox {
  let segments: [ModelReplyRenderSegment]
  init(_ segments: [ModelReplyRenderSegment]) { self.segments = segments }
}


/// Renders a prose `AttributedString` in a read-only `NSTextView` so the text stays selectable AND
/// markdown links stay clickable (with a pointing-hand cursor). SwiftUI's `Text` can do one or the
/// other but not both: `.textSelection(.enabled)` makes its overlay swallow link clicks. AppKit's
/// text view handles selection and links natively, sidestepping that limitation.
private struct SelectableProseText: NSViewRepresentable {
  private let nsAttributed: NSAttributedString
  /// true = wrap to the proposed width (prose); false = keep natural line lengths
  /// (code inside a horizontal scroller).
  private let wraps: Bool
  /// true = report the natural text width when it fits the proposal, so short user
  /// bubbles hug their content instead of stretching to the bubble's max width.
  private let hugsContentWidth: Bool

  init(attributed: AttributedString) {
    self.nsAttributed = ModelReplyView.makeProseNSAttributedString(attributed)
    self.wraps = true
    self.hugsContentWidth = false
  }

  /// Uniform-font plain text (user messages, fenced code blocks).
  init(plain: String, font: NSFont, color: NSColor, kern: CGFloat = 0,
       wraps: Bool = true, hugsContentWidth: Bool = false) {
    var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
    if kern != 0 { attrs[.kern] = kern }
    self.nsAttributed = NSAttributedString(string: plain, attributes: attrs)
    self.wraps = wraps
    self.hugsContentWidth = hugsContentWidth
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> NSTextView {
    // Build an explicit TextKit 1 stack. `NSTextView()`'s default initializer opts into TextKit 2,
    // whose viewport-based layout misplaces or blanks glyphs when a LazyVStack recycles the view on
    // scroll (text drifting to the far-right window edge or vanishing entirely). TextKit 1 lays the
    // whole document out up front, so a reused view always redraws at the correct position.
    let textContainer = NSTextContainer(
      size: NSSize(width: wraps ? 0 : .greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
    textContainer.lineFragmentPadding = 0
    textContainer.widthTracksTextView = wraps
    let layoutManager = NSLayoutManager()
    layoutManager.addTextContainer(textContainer)
    let textStorage = NSTextStorage()
    textStorage.addLayoutManager(layoutManager)

    let tv = NSTextView(frame: .zero, textContainer: textContainer)
    tv.isEditable = false
    tv.isSelectable = true
    tv.drawsBackground = false
    tv.backgroundColor = .clear
    tv.textContainerInset = .zero
    tv.isVerticallyResizable = true
    tv.isHorizontallyResizable = false
    tv.autoresizingMask = [.width]
    // Match the previous SwiftUI look: blue link, no underline, hand cursor on hover.
    tv.linkTextAttributes = [
      .foregroundColor: NSColor.linkColor,
      .cursor: NSCursor.pointingHand,
      .underlineStyle: 0,
    ]
    tv.delegate = context.coordinator
    tv.textStorage?.setAttributedString(nsAttributed)
    return tv
  }

  func updateNSView(_ tv: NSTextView, context: Context) {
    // SwiftUI may hand a recycled NSTextView to a struct with a different wrap mode.
    if let container = tv.textContainer, container.widthTracksTextView != wraps {
      container.widthTracksTextView = wraps
      container.size = NSSize(
        width: wraps ? tv.frame.width : .greatestFiniteMagnitude,
        height: .greatestFiniteMagnitude)
    }
    if tv.textStorage?.isEqual(to: nsAttributed) != true {
      tv.textStorage?.setAttributedString(nsAttributed)
    }
  }

  func sizeThatFits(_ proposal: ProposedViewSize, nsView tv: NSTextView, context: Context) -> CGSize? {
    if !wraps {
      return Self.cachedNaturalSize(for: nsAttributed)
    }
    guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
    if hugsContentWidth {
      let natural = Self.cachedNaturalSize(for: nsAttributed)
      if natural.width <= width { return natural }
    }
    let height = Self.cachedHeight(for: nsAttributed, width: width)
    return CGSize(width: width, height: height)
  }

  private static let proseHeightCache = NSCache<NSString, NSNumber>()
  private static let naturalSizeCache = NSCache<NSString, NSValue>()

  /// Size of the text laid out without any wrapping (widest line × total height).
  private static func cachedNaturalSize(for ns: NSAttributedString) -> CGSize {
    let key = cacheKey(ns: ns, width: 0)
    if let boxed = naturalSizeCache.object(forKey: key) {
      return boxed.sizeValue
    }
    let size = measuredSize(ns, width: .greatestFiniteMagnitude)
    naturalSizeCache.setObject(NSValue(size: size), forKey: key)
    return size
  }

  private static func cachedHeight(for ns: NSAttributedString, width: CGFloat) -> CGFloat {
    let key = cacheKey(ns: ns, width: width)
    if let boxed = proseHeightCache.object(forKey: key) {
      return CGFloat(boxed.doubleValue)
    }
    let height = measuredHeight(ns, width: width)
    proseHeightCache.setObject(NSNumber(value: height), forKey: key)
    return height
  }

  private static func cacheKey(ns: NSAttributedString, width: CGFloat) -> NSString {
    // `NSAttributedString.hash` covers the characters only, so the key must also fold in
    // the font runs: the same text as a 20-pt heading vs. 16-pt body would otherwise share
    // a key and return a stale (wrong) height.
    var hasher = Hasher()
    hasher.combine(Int(width.rounded()))
    hasher.combine(ns.string)
    ns.enumerateAttribute(.font, in: NSRange(location: 0, length: ns.length)) { value, range, _ in
      hasher.combine(range.location)
      if let font = value as? NSFont {
        hasher.combine(font.fontName)
        hasher.combine(font.pointSize)
      }
    }
    return String(hasher.finalize()) as NSString
  }

  private static func measuredHeight(_ ns: NSAttributedString, width: CGFloat) -> CGFloat {
    measuredSize(ns, width: width).height
  }

  private static func measuredSize(_ ns: NSAttributedString, width: CGFloat) -> CGSize {
    let textStorage = NSTextStorage(attributedString: ns)
    let textContainer = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
    textContainer.lineFragmentPadding = 0
    let layoutManager = NSLayoutManager()
    layoutManager.addTextContainer(textContainer)
    textStorage.addLayoutManager(layoutManager)
    layoutManager.ensureLayout(for: textContainer)
    let used = layoutManager.usedRect(for: textContainer)
    return CGSize(width: ceil(used.width), height: ceil(used.height))
  }

  final class Coordinator: NSObject, NSTextViewDelegate {
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
      let url: URL? = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
      guard let url else { return false }
      NSWorkspace.shared.open(url)
      return true
    }
  }
}

private struct ModelReplyView: View {
  let content: String
  let sources: [GroundingSource]
  let groundingSupports: [GroundingSupport]
  /// While true (message still streaming), prose renders as lightweight SwiftUI `Text`.
  /// The self-sizing NSTextView (SelectableProseText) does a full layout pass on every
  /// `updateNSView`; doing that per streamed token wedges the main thread, so we defer it
  /// until the message is final. See MessageBubbleView call site.
  var isStreaming: Bool = false

  /// Markdown parsing (`ReplyBlockBuilder.buildBlocks` + mergedSegments) is expensive and would otherwise run on
  /// every SwiftUI render of every assistant message — so switching chats re-parses the whole
  /// conversation synchronously on the main thread. Memoize by content + grounding so repeated
  /// renders and chat switches reuse the parsed result.
  private static let segmentCache = NSCache<NSString, ModelReplySegmentBox>()

  private static func cachedSegments(
    content: String, sources: [GroundingSource], groundingSupports: [GroundingSupport],
    store: Bool
  ) -> [ModelReplyRenderSegment] {
    var hasher = Hasher()
    hasher.combine(content)
    for s in sources {
      hasher.combine(s.uri)
      hasher.combine(s.title)
    }
    for g in groundingSupports {
      hasher.combine(g.startIndex)
      hasher.combine(g.endIndex)
      hasher.combine(g.groundingChunkIndices)
    }
    let key = String(hasher.finalize()) as NSString
    if let box = segmentCache.object(forKey: key) {
      return box.segments
    }
    let blocks = ReplyBlockBuilder.buildBlocks(
      content: content, sources: sources, groundingSupports: groundingSupports)
    let segments = mergedSegments(from: blocks)
    // During streaming each flush produces a new `content` string, so caching would fill the cache
    // with throwaway keys that are never re-read (the final finalized render caches for real).
    if store {
      segmentCache.setObject(ModelReplySegmentBox(segments), forKey: key)
    }
    return segments
  }

  var body: some View {
    let segments = Self.cachedSegments(
      content: content, sources: sources, groundingSupports: groundingSupports, store: !isStreaming)
    return VStack(alignment: .leading, spacing: 18) {
      ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
        switch segment {
        case .prose(let attrStr):
          if isStreaming {
            // Lightweight, fast to re-render every token. Loses clickable links while
            // streaming, but links matter only on the finished, readable message.
            Text(attrStr)
              .font(ChatTheme.bodyFont(size: ChatTheme.bodyFontSize))
              .lineSpacing(ChatTheme.bodyLineSpacing)
              .tracking(ChatTheme.bodyTracking)
              .foregroundColor(ChatTheme.primaryText)
          } else {
            SelectableProseText(attributed: attrStr)
          }
        case .table(let parsed):
          MarkdownTableView(headers: parsed.headers, rows: parsed.rows)
        case .codeBlock(let code, let language):
          CodeBlockView(code: code, language: language)
        case .image(let image):
          Image(nsImage: image)
            .resizable()
            .scaledToFit()
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
      }
    }
    // DELIBERATELY no SwiftUI `.textSelection(.enabled)` here. That modifier installs macOS's
    // `SelectionOverlay`, which loops forever in `setFont:` / `_invalidateEffectiveFont` (a 100% CPU
    // main-thread hang) whenever the selectable `Text` carries per-run markdown fonts — e.g. a
    // streaming reply full of bold/headings, most reliably tipped over by switching chats mid-stream.
    // Prose selection is provided instead by `SelectableProseText` (a real NSTextView that is immune
    // to this bug); tables and still-streaming text are simply not selectable, an acceptable trade for
    // removing the entire hang class from the reply view. See `citationMarker` for the related case.
    .padding(.horizontal, 16)
    .padding(.vertical, 14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .fixedSize(horizontal: false, vertical: true)
    .contentShape(Rectangle())
    .environment(\.openURL, OpenURLAction { url in
      NSWorkspace.shared.open(url)
      return .handled
    })
  }

  /// Whether the block opens with heading typography (used for a thin rule before the heading).
  /// Heuristic: chat headings use bold/semibold from `MarkdownParsing.fontForHeadingLevel`; bold-only body
  /// paragraphs are rare but could show a divider—acceptable tradeoff without storing heading metadata on blocks.
  private static func isHeadingBlock(_ attr: AttributedString) -> Bool {
    guard let firstRun = attr.runs.first else { return false }
    if let font = firstRun.font {
      let desc = String(describing: font)
      return desc.contains("bold") || desc.contains("semibold")
    }
    return false
  }

  /// Horizontal rule line (same characters as `MarkdownParsing.separatorLineContent`) before a heading.
  private static func appendHeadingRuleLine(to prose: inout AttributedString) {
    var dashes = AttributedString(MarkdownParsing.separatorLineContent)
    dashes.font = .system(size: 10, weight: .light)
    dashes[ProseFontHint.self] = ProseFontMetrics(size: 10, weight: NSFont.Weight.light.rawValue)
    dashes.foregroundColor = ChatTheme.primaryText.opacity(0.14)
    prose.append(dashes)
  }

  /// Translates a prose `AttributedString` (built for SwiftUI) into an `NSAttributedString` for the
  /// selectable text view. SwiftUI fonts/colors do not bridge to AppKit, so we rebuild each run's
  /// `NSFont`/`NSColor` from the attributes we can still read: the `ProseFontHint` (headings, rule
  /// line), the markdown `inlinePresentationIntent` (bold/italic/code/strikethrough), the SwiftUI
  /// `foregroundColor`, and the `link` URL. Body runs fall back to the 16-pt system font / soft white.
  static func makeProseNSAttributedString(_ attr: AttributedString) -> NSAttributedString {
    let baseSize: CGFloat = ChatTheme.bodyFontSize
    let defaultColor = NSColor(ChatTheme.primaryText)
    let result = NSMutableAttributedString()

    for run in attr.runs {
      let text = String(attr[run.range].characters)
      if text.isEmpty { continue }

      var size = baseSize
      var weight: NSFont.Weight = ChatTheme.bodyRegularNSWeight
      if let hint = run[ProseFontHint.self] {
        size = hint.size
        weight = NSFont.Weight(hint.weight)
      }

      let intent = run.inlinePresentationIntent ?? []
      var traits: NSFontDescriptor.SymbolicTraits = []
      if intent.contains(.stronglyEmphasized) { weight = .bold; traits.insert(.bold) }
      if intent.contains(.emphasized) { traits.insert(.italic) }

      let font: NSFont
      if intent.contains(.code) {
        font = NSFont.monospacedSystemFont(ofSize: size, weight: weight)
      } else {
        font = ChatTheme.bodyNSFont(size: size, weight: weight, traits: traits)
      }

      var attrs: [NSAttributedString.Key: Any] = [.font: font]
      if let url = run.link {
        attrs[.link] = url  // .foregroundColor is supplied by the view's linkTextAttributes
      } else if let color = run.foregroundColor {
        attrs[.foregroundColor] = NSColor(color)
      } else {
        attrs[.foregroundColor] = defaultColor
      }
      if intent.contains(.strikethrough) {
        attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
      }

      result.append(NSAttributedString(string: text, attributes: attrs))
    }

    // Match SwiftUI `.lineSpacing` and `.tracking` (kern) over the whole prose.
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineSpacing = ChatTheme.bodyLineSpacing
    result.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: result.length))
    result.addAttribute(.kern, value: ChatTheme.bodyTracking, range: NSRange(location: 0, length: result.length))

    // Bullet paragraphs get extra spacing between items plus a hanging indent so wrapped
    // continuation lines align under the text, not under the "• " marker. Applied only to
    // lines that begin with the bullet glyph, leaving prose paragraph rhythm untouched.
    let bulletParagraph = NSMutableParagraphStyle()
    bulletParagraph.lineSpacing = ChatTheme.bodyLineSpacing
    bulletParagraph.paragraphSpacing = 6
    bulletParagraph.headIndent = 16

    // Paragraphs are separated by a blank line ("\n\n"). At the full body line height that
    // blank line is a large, airy gap; cap its height so inter-paragraph spacing reads as a
    // tight, deliberate break instead. Applied to the blank paragraph's enclosing range (the
    // bare newline) since its own substring range is zero-length.
    let blankParagraph = NSMutableParagraphStyle()
    blankParagraph.lineSpacing = 0
    blankParagraph.maximumLineHeight = 10
    blankParagraph.minimumLineHeight = 10

    let full = result.string as NSString
    full.enumerateSubstrings(in: NSRange(location: 0, length: full.length), options: .byParagraphs) { substring, range, enclosingRange, _ in
      guard let substring else { return }
      if substring.hasPrefix("• ") {
        result.addAttribute(.paragraphStyle, value: bulletParagraph, range: range)
      } else if substring.isEmpty {
        result.addAttribute(.paragraphStyle, value: blankParagraph, range: enclosingRange)
      }
    }
    return result
  }

  /// Merges consecutive `.text`, `.bulletList`, and `.separator` blocks into one `AttributedString` so
  /// `textSelection` can span multiple paragraphs. Tables, fenced code, and images stay as separate views.
  private static func mergedSegments(from blocks: [ReplyContentBlock]) -> [ModelReplyRenderSegment] {
    var segments: [ModelReplyRenderSegment] = []
    var prose = AttributedString()
    var hasProse = false

    func flushProse() {
      guard hasProse, prose.startIndex != prose.endIndex else {
        prose = AttributedString()
        hasProse = false
        return
      }
      segments.append(.prose(prose))
      prose = AttributedString()
      hasProse = false
    }

    for block in blocks {
      switch block {
      case .table(let parsed):
        flushProse()
        segments.append(.table(parsed))
      case .codeBlock(let code, let language):
        flushProse()
        segments.append(.codeBlock(code, language))
      case .image(let image):
        flushProse()
        segments.append(.image(image))
      case .separator:
        if hasProse {
          prose.append(AttributedString("\n\n"))
        }
        var lineAttr = AttributedString(MarkdownParsing.separatorLineContent)
        lineAttr.foregroundColor = ChatTheme.primaryText.opacity(0.4)
        prose.append(lineAttr)
        hasProse = true
      case .bulletList(let items):
        if hasProse {
          prose.append(AttributedString("\n\n"))
        }
        for (itemIndex, item) in items.enumerated() {
          if itemIndex > 0 {
            prose.append(AttributedString("\n"))
          }
          var bullet = AttributedString("• ")
          bullet.font = .system(size: ChatTheme.bodyFontSize, weight: .regular)
          bullet.foregroundColor = ChatTheme.primaryText.opacity(0.5)
          prose.append(bullet)
          prose.append(item)
        }
        hasProse = true
      case .text(let attrStr):
        let heading = isHeadingBlock(attrStr)
        if hasProse {
          prose.append(AttributedString("\n\n"))
          if heading {
            appendHeadingRuleLine(to: &prose)
            prose.append(AttributedString("\n\n"))
          }
        } else if heading, !segments.isEmpty {
          appendHeadingRuleLine(to: &prose)
          prose.append(AttributedString("\n\n"))
        }
        prose.append(attrStr)
        hasProse = true
      }
    }
    flushProse()
    return segments
  }


}

// MARK: - Code Block View

private struct CodeBlockView: View {
  let code: String
  let language: String?
  @State private var copied = false

  /// Languages whose fenced blocks are prose, not code — models often wrap email drafts or
  /// notes in ```markdown/```text fences. Prose must soft-wrap; clipping it behind an
  /// indicator-less horizontal scroller silently hides the end of every line.
  private static let proseLanguages: Set<String> = ["markdown", "md", "text", "txt", "plaintext", "plain"]

  private var wrapsLines: Bool {
    guard let language else { return false }
    return Self.proseLanguages.contains(language.lowercased())
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Header with language label and copy button
      HStack {
        Text(language ?? "code")
          .font(.system(size: 12, weight: .medium))
          .foregroundColor(ChatTheme.primaryText.opacity(0.5))
        Spacer()
        Button(action: {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(code, forType: .string)
          copied = true
          DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
        }) {
          HStack(spacing: 4) {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
              .font(.system(size: 11))
            Text(copied ? "Copied" : "Copy")
              .font(.system(size: 11))
          }
          .foregroundColor(ChatTheme.primaryText.opacity(0.5))
        }
        .buttonStyle(.plain)
        .onHover { inside in
          if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 8)
      .background(Color.black.opacity(0.15))

      // Code content: prose blocks wrap like normal text; real code keeps its
      // line structure and scrolls horizontally (with a visible indicator).
      // Rendered in a selectable NSTextView (never SwiftUI `.textSelection` — see
      // the SelectionOverlay hang notes on ModelReplyView).
      if wrapsLines {
        SelectableProseText(
          plain: code,
          font: .monospacedSystemFont(ofSize: 13, weight: .regular),
          color: NSColor(ChatTheme.primaryText.opacity(0.9)))
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(14)
      } else {
        ScrollView(.horizontal, showsIndicators: true) {
          SelectableProseText(
            plain: code,
            font: .monospacedSystemFont(ofSize: 13, weight: .regular),
            color: NSColor(ChatTheme.primaryText.opacity(0.9)),
            wraps: false)
            .padding(14)
        }
      }
    }
    .background(Color.black.opacity(0.25))
    .clipShape(RoundedRectangle(cornerRadius: 8))
  }
}

// MARK: - Copy Reply Button (under model replies)

private struct CopyReplyButtonView: View {
  /// Resolved on click, not per render — for image-bearing replies the marker strip
  /// rebuilds a multi-MB string, which must not run on every streaming re-render.
  let text: () -> String

  var body: some View {
    MessageActionButton(
      systemImage: "doc.on.doc",
      help: "Copy this reply to the clipboard"
    ) {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(text(), forType: .string)
    }
  }
}

// MARK: - Download Image Button (under model replies that contain an image)

/// Saves the first generated image in a reply to disk via a save panel.
private struct DownloadImageButtonView: View {
  /// Resolved on click, not per render — decoding the marker rebuilds a multi-MB Data blob.
  let image: () -> (data: Data, mimeType: String)?

  var body: some View {
    MessageActionButton(
      systemImage: "square.and.arrow.down",
      help: "Download this image",
      action: saveImage
    )
  }

  private func saveImage() {
    guard let image = image() else { return }
    let ext = Self.fileExtension(for: image.mimeType)
    let panel = NSSavePanel()
    if let contentType = UTType(filenameExtension: ext) {
      panel.allowedContentTypes = [contentType]
    }
    panel.nameFieldStringValue = "generated-image.\(ext)"
    panel.message = "Save the generated image"
    if let lastPath = UserDefaults.standard.string(forKey: UserDefaultsKeys.lastAttachDirectoryPath) {
      panel.directoryURL = URL(fileURLWithPath: lastPath)
    } else if let screenshotFolder = ScreenshotSaveLocation.resolveFolderURL() {
      panel.directoryURL = screenshotFolder
    }
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      try image.data.write(to: url)
      UserDefaults.standard.set(url.deletingLastPathComponent().path, forKey: UserDefaultsKeys.lastAttachDirectoryPath)
    } catch {
      DebugLogger.logError("GEMINI-CHAT: Failed to save generated image: \(error.localizedDescription)")
    }
  }

  private static func fileExtension(for mimeType: String) -> String {
    switch mimeType.lowercased() {
    case "image/jpeg", "image/jpg": return "jpg"
    case "image/webp": return "webp"
    case "image/gif": return "gif"
    case "image/heic": return "heic"
    default: return "png"
    }
  }
}

// MARK: - Failed turn (background-tab error)

private struct FailedTurnRow: View {
  let message: String
  let onRetry: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(message)
        .font(.system(size: 14))
        .foregroundColor(ChatTheme.secondaryText)
        .fixedSize(horizontal: false, vertical: true)
      RetryButtonView(action: onRetry)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 12)
        .fill(Color.red.opacity(0.12))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 12)
        .strokeBorder(Color.red.opacity(0.35), lineWidth: 1)
    )
  }
}

// MARK: - Retry Button (under the last user message)

/// Re-sends the message (same text and attachments) and regenerates the response.
private struct RetryButtonView: View {
  let action: () -> Void

  var body: some View {
    MessageActionButton(
      systemImage: "arrow.clockwise",
      help: "Send this message again and regenerate the response",
      accessibilityText: "Retry this message",
      action: action
    )
  }
}

// MARK: - Read Aloud Button (under model replies)

private struct ReadAloudButtonView: View {
  /// Resolved on click, not per render — see `CopyReplyButtonView.text`.
  let text: () -> String
  @State private var isTTSActive = false

  var body: some View {
    MessageActionButton(
      systemImage: isTTSActive ? "stop.fill" : "speaker.wave.2",
      isActive: isTTSActive,
      help: isTTSActive ? "Click to stop" : "Read this reply aloud",
      accessibilityText: isTTSActive ? "Reading aloud; click to stop" : "Read this reply aloud"
    ) {
      if isTTSActive {
        NotificationCenter.default.post(name: .chatReadAloudStop, object: nil)
      } else {
        NotificationCenter.default.post(
          name: .chatReadAloud,
          object: nil,
          userInfo: [Notification.Name.chatReadAloudTextKey: text()]
        )
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: .ttsDidStart)) { _ in
      isTTSActive = true
    }
    .onReceive(NotificationCenter.default.publisher(for: .ttsDidStop)) { _ in
      isTTSActive = false
    }
  }
}

// MARK: - User message XML (pasted blocks + typed)

struct UserMessagePastedSection: Equatable {
  let body: String
  /// True when wrapped as `<pasted_selection>` (shortcut selection); false for `<pasted_content>`.
  let isSelection: Bool
}

func unwrapUserMessageTypedByUser(_ s: String) -> String {
  let open = "<typed_by_user>"
  let close = "</typed_by_user>"
  guard let r1 = s.range(of: open), let r2 = s.range(of: close), r1.upperBound <= r2.lowerBound else {
    return s
  }
  return String(s[r1.upperBound..<r2.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Strips leading `<pasted_content>` / `<pasted_selection>` blocks in order, then unwraps `<typed_by_user>`.
func parseUserMessagePastedXML(_ content: String) -> (sections: [UserMessagePastedSection], userText: String) {
  var remaining = content.trimmingCharacters(in: .whitespacesAndNewlines)
  var sections: [UserMessagePastedSection] = []
  let pasteOpen = "<pasted_content>"
  let pasteClose = "</pasted_content>"
  let selOpen = "<pasted_selection>"
  let selClose = "</pasted_selection>"
  while true {
    let rangePaste = remaining.range(of: pasteOpen)
    let rangeSel = remaining.range(of: selOpen)
    let usePasteBlock: Bool?
    if let rp = rangePaste, let rs = rangeSel {
      usePasteBlock = rp.lowerBound <= rs.lowerBound
    } else if rangePaste != nil {
      usePasteBlock = true
    } else if rangeSel != nil {
      usePasteBlock = false
    } else {
      usePasteBlock = nil
    }
    guard let takePaste = usePasteBlock else { break }
    if takePaste {
      guard let r1 = remaining.range(of: pasteOpen),
            let r2 = remaining.range(of: pasteClose),
            r1.upperBound <= r2.lowerBound else { break }
      let body = String(remaining[r1.upperBound..<r2.lowerBound])
      sections.append(UserMessagePastedSection(body: body, isSelection: false))
      remaining = String(remaining[r2.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    } else {
      guard let r1 = remaining.range(of: selOpen),
            let r2 = remaining.range(of: selClose),
            r1.upperBound <= r2.lowerBound else { break }
      let body = String(remaining[r1.upperBound..<r2.lowerBound])
      sections.append(UserMessagePastedSection(body: body, isSelection: true))
      remaining = String(remaining[r2.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
  }
  let userText = unwrapUserMessageTypedByUser(remaining)
  return (sections, userText)
}

// MARK: - Message Bubble

/// Renders a streaming assistant bubble whose content is read live from a `StreamingBuffer`.
/// Crucially, the `@ObservedObject` lives here, not on `MessageBubbleView` — so per-token
/// writes only invalidate this small subtree, not the whole bubble or list. `fallback` carries
/// any sources/supports already committed to the message (during a normal stream both are empty
/// until finalization).
private struct StreamingModelReplyView: View {
  @ObservedObject var buffer: StreamingBuffer
  let fallback: ChatMessage

  var body: some View {
    ModelReplyView(
      content: buffer.content,
      sources: fallback.sources,
      groundingSupports: fallback.groundingSupports,
      isStreaming: true)
  }
}

private struct MessageBubbleView: View {
  let message: ChatMessage
  /// Non-nil while this bubble is still streaming — drives content from a separate
  /// `ObservableObject` so per-token writes don't @Published-ripple through the parent and
  /// don't force a `LazyVStack` diff. See `StreamingBuffer` doc.
  var streamingBuffer: StreamingBuffer? = nil
  var onTapAttachedImage: ((Data) -> Void)? = nil
  /// Non-nil only on the last user message: re-sends it and regenerates the response.
  var onRetry: (() -> Void)? = nil

  var isUser: Bool { message.role == .user }

  var body: some View {
    VStack(alignment: isUser ? .trailing : .leading, spacing: 2) {
      bubbleContent
      if !message.sources.isEmpty {
        sourcesView
      }
      if isUser {
        userCopyButtonRow
      } else {
        assistantCopyButtonRow
      }
    }
    // Inner frame constrains bubble width; outer fills the row so alignment spans full width.
    .frame(maxWidth: isUser ? 520 : .infinity, alignment: isUser ? .trailing : .leading)
    .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
  }

  /// Whether an attachment can be shown in the full-size preview sheet (`NSImage(data:)`-decodable).
  private func isPreviewableImage(_ part: AttachedImagePart) -> Bool {
    if let mime = part.mimeType { return mime.hasPrefix("image/") }
    return NSImage(data: part.data) != nil
  }

  /// One attachment filename row. Image parts are tappable and open the same preview sheet used
  /// for pending/thumbnail screenshots (via `onTapAttachedImage`); non-image parts stay static.
  @ViewBuilder
  private func attachedPartLabel(_ part: AttachedImagePart) -> some View {
    let name = part.filename ?? "attachment"
    let previewable = isPreviewableImage(part)
    if previewable, let onTap = onTapAttachedImage {
      Button {
        onTap(part.data)
      } label: {
        Text(name)
          .font(.caption)
          .foregroundColor(ChatTheme.primaryText.opacity(0.6))
          .underline()
      }
      .buttonStyle(.plain)
      .onHover { inside in
        if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
      }
    } else {
      Text(name)
        .font(.caption)
        .foregroundColor(ChatTheme.primaryText.opacity(0.6))
    }
  }

  @ViewBuilder
  private var bubbleContent: some View {
    if isUser {
      VStack(alignment: .trailing, spacing: 6) {
        let parsed = parseUserMessagePastedXML(message.content)
        ForEach(Array(parsed.sections.enumerated()), id: \.offset) { _, sec in
          let lines = sec.body.components(separatedBy: .newlines).filter { !$0.isEmpty }.count
          let title = sec.isSelection ? "\(lines) lines from selection" : "\(lines) lines pasted"
          let icon = sec.isSelection ? "text.cursor" : "doc.plaintext"
          Label(title, systemImage: icon)
            .font(.caption)
            .foregroundColor(ChatTheme.primaryText.opacity(0.7))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.white.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        if !parsed.userText.isEmpty {
          // Selectable NSTextView, DELIBERATELY not SwiftUI `.textSelection(.enabled)` —
          // even on a single uniform-font Text, macOS's SelectionOverlay can enter a
          // self-sustaining setFont:/_invalidateEffectiveFont loop once streaming layout
          // churn kicks it off (hang-20260704-205531: 97% CPU, survived send cancellation).
          // Invariant: no SwiftUI .textSelection anywhere in the chat transcript.
          SelectableProseText(
            plain: parsed.userText,
            font: ChatTheme.bodyNSFont(size: ChatTheme.bodyFontSize, weight: ChatTheme.bodyRegularNSWeight),
            color: NSColor(ChatTheme.primaryText),
            kern: ChatTheme.bodyTracking,
            hugsContentWidth: true)
        }
        if !message.attachedImageParts.isEmpty {
          VStack(alignment: .trailing, spacing: 4) {
            ForEach(Array(message.attachedImageParts.enumerated()), id: \.offset) { _, part in
              attachedPartLabel(part)
            }
          }
        }
      }
      .padding(.horizontal, 16)
      // Matches the assistant bubble's vertical inset so the two columns share a rhythm.
      .padding(.vertical, 14)
      .contentShape(Rectangle())
      .background(
        RoundedRectangle(cornerRadius: 14)
          .fill(ChatTheme.userBubbleBackground)
      )
      // Bubble fill matches the composer/pane (#0C1117); a 1px stroke keeps it delineated.
      .overlay(
        RoundedRectangle(cornerRadius: 14)
          .strokeBorder(ChatTheme.primaryText.opacity(ChatTheme.borderOpacity), lineWidth: 1)
      )
      .onHover { inside in
        if inside {
          NSCursor.iBeam.push()
        } else {
          NSCursor.pop()
        }
      }
    } else if let buffer = streamingBuffer {
      StreamingModelReplyView(buffer: buffer, fallback: message)
    } else {
      ModelReplyView(
        content: message.content,
        sources: message.sources,
        groundingSupports: message.groundingSupports,
        isStreaming: false)
    }
  }

  /// Retry (last user message only) and Copy. Copy joins pasted/selection blocks plus
  /// the typed text, in display order; it is hidden for attachment-only messages.
  private var userCopyButtonRow: some View {
    let parsed = parseUserMessagePastedXML(message.content)
    var parts = parsed.sections.map { $0.body.trimmingCharacters(in: .whitespacesAndNewlines) }
    parts.append(parsed.userText.trimmingCharacters(in: .whitespacesAndNewlines))
    let text = parts.filter { !$0.isEmpty }.joined(separator: "\n\n")
    return Group {
      if !text.isEmpty || onRetry != nil {
        HStack(spacing: 2) {
          if let onRetry {
            RetryButtonView(action: onRetry)
          }
          if !text.isEmpty {
            CopyReplyButtonView(text: { text })
          }
        }
        .padding(.top, 4)
      }
    }
  }

  /// Read Aloud and Copy action row for assistant replies; hidden when content is empty.
  /// Visibility uses only cheap scans; the multi-MB marker strip runs once per click inside
  /// the buttons, not on every render of a streaming bubble.
  private var assistantCopyButtonRow: some View {
    let hasMarker = GeminiAPIClient.containsImageMarker(in: message.content)
    let visible = hasMarker
      || !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    return Group {
      if visible {
        HStack(spacing: 2) {
          // Empty placeholder for TTS so an image-led reply doesn't read "generated image"
          // out loud; the read-aloud handler ignores empty text.
          ReadAloudButtonView(text: {
            GeminiAPIClient.stripImageMarkers(message.content, placeholder: "")
          })
          CopyReplyButtonView(text: { GeminiAPIClient.stripImageMarkers(message.content) })
          if hasMarker {
            DownloadImageButtonView(image: { GeminiAPIClient.firstImageMarker(in: message.content) })
          }
        }
        .padding(.top, 6)
      }
    }
  }

  /// Sources with wrapping: [1] Title1  [2] Title2  … flow onto multiple lines when horizontal space is limited.
  private var sourcesView: some View {
    FlowLayout(horizontalSpacing: 10, verticalSpacing: 6) {
      ForEach(Array(message.sources.enumerated()), id: \.element.id) { index, source in
        if let url = URL(string: source.uri) {
          Link(destination: url) {
            HStack(spacing: 4) {
              Text("[\(index + 1)]")
                .font(.caption)
                .fontWeight(.medium)
              Text(source.title)
                .font(.caption)
            }
            .foregroundColor(.accentColor)
          }
          .pointerCursorOnHover()
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 12)
    .padding(.top, 6)
  }
}

// MARK: - Typing Indicator

private struct TypingIndicatorView: View {
  // Drive the pulse from a single TimelineView clock and derive each dot's
  // scale from (time + index offset). Avoids per-dot @State + repeatForever
  // + scaleEffect inside a ScrollView, which on AppKit can occasionally leave
  // a sublayer mispositioned for a frame (causing a stray dot above the pill).
  private static let period: TimeInterval = 1.0
  private static let stagger: TimeInterval = 0.15
  private static let minScale: CGFloat = 0.4
  private static let maxScale: CGFloat = 1.0

  private func scale(at time: TimeInterval, index: Int) -> CGFloat {
    let phase = ((time - Double(index) * Self.stagger).truncatingRemainder(dividingBy: Self.period) + Self.period)
      .truncatingRemainder(dividingBy: Self.period) / Self.period
    // 0…1 → ease-in-out via cosine, mapped to [minScale, maxScale]
    let eased = (1 - cos(phase * 2 * .pi)) / 2
    return Self.minScale + (Self.maxScale - Self.minScale) * eased
  }

  var body: some View {
    TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: false)) { context in
      let t = context.date.timeIntervalSinceReferenceDate
      HStack(spacing: 4) {
        ForEach(0..<3, id: \.self) { i in
          Circle()
            .fill(ChatTheme.secondaryText)
            .frame(width: 7, height: 7)
            .scaleEffect(scale(at: t, index: i), anchor: .center)
        }
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 10)
      .compositingGroup()
      .background(
        RoundedRectangle(cornerRadius: 14)
          .fill(ChatTheme.controlBackground)
      )
      .clipShape(RoundedRectangle(cornerRadius: 14))
    }
  }
}
