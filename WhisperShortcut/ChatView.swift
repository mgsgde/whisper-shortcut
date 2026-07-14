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
  /// Sessions whose in-flight request is being superseded by a new user message.
  /// The cancel handler uses this to discard the partial assistant placeholder
  /// entirely (otherwise partial text would persist between the old user message
  /// and the replacement, polluting the next request's history).
  private var supersedingSessionIds: Set<UUID> = []
  /// True when the currently visible session has an in-flight request.
  var isSending: Bool { sendingSessionIds.contains(session.id) }
  @Published var errorMessage: String? = nil
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
      if hasSelection, hasPaste { return "[Selection] [Pasted content]" }
      if hasSelection { return "[Selection]" }
      if hasPaste { return "[Pasted content]" }
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
  @Published private(set) var meetingSessionId: UUID? = nil
  var isCurrentSessionMeeting: Bool { session.isMeeting }
  var isCurrentSessionTheActiveMeeting: Bool { isMeetingActive && meetingSessionId == session.id }
  private var meetingCancellable: AnyCancellable?
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
  /// True while a missing meeting summary is being regenerated, so the Summary tab can show progress.
  @Published private(set) var isRecoveringMeetingSummary: Bool = false

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
  private static let settingsCommand = "/settings"
  private static let pinCommand = "/pin"
  private static let unpinCommand = "/unpin"
  private static let modelCommand = "/model"
  private static let meetingCommand = "/meeting"
  private static let copyCommand = "/copy"
  static let thinkCommand = "/think"

  /// Slash commands that take an inline argument (e.g. `/model 3.1 flash`, `/think high`).
  /// The autocomplete completes them inline instead of dispatching, and the composer strips
  /// the whole line (not just the token) so multi-word args leave no residue. Single source so
  /// the three call sites in `ChatInputAreaView` can't drift.
  static let argumentCommands: Set<String> = [modelCommand, thinkCommand]

  /// Model-switch slash commands, generated from `PromptModel` so adding a model auto-adds its
  /// alias. Grouped by provider: the provider-default alias (`/gemini`, `/grok`, `/gpt`) first,
  /// then each of that provider's *non-default* chat models by its `shortAlias` (`/gemini3flash`,
  /// `/gemini25pro`, `/grok4`, …); the default model is reached via the bare provider command.
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
    return dict
  }()

  /// Non-model commands shown before / after the model-switch block. Kept separate so the model
  /// block can be re-sorted by recency for display without disturbing these fixed slots.
  static let commandsBeforeModels: [(command: String, description: String)] = [
    ("/new", "Start a new chat (previous chat stays in history)"),
    ("/screenshot", "Add a screenshot to your next message (can add multiple)"),
    ("/attach", "Open the file picker to attach files (PDF, images, text)"),
    ("/model", "Switch chat model (e.g. /model 3.1 flash lite)"),
  ]
  static let commandsAfterModels: [(command: String, description: String)] = [
    ("/think", "Set reasoning depth for this chat: minimal | low | medium | high | default"),
    ("/settings", "Open Settings"),
    ("/pin", "Toggle whether the window stays open when losing focus"),
    ("/unpin", "Make the window close when losing focus"),
    ("/meeting", "Start or stop live meeting recording"),
    ("/copy", "Copy the entire chat history to clipboard as Markdown"),
  ]

  /// All slash commands in canonical (provider-grouped) order. Used where order is irrelevant —
  /// `knownSlashCommands` (a set) and the system-prompt command list. The on-screen autocomplete
  /// uses `commandSuggestionsForDisplay`, which re-sorts the model block by recency.
  static let commandSuggestions: [(command: String, description: String)] =
    commandsBeforeModels + modelCommands.map { ($0.command, $0.description) } + commandsAfterModels

  /// Model-switch commands for display, ordered most-recently-used first (see `recordModelUse`).
  /// The currently active model is omitted entirely — re-selecting it is a no-op — so the top row
  /// is the most-recently-used *other* model (one Enter away from toggling back). Never-used models
  /// keep the canonical provider-grouped order at the bottom.
  func recentlyOrderedModelCommands() -> [(command: String, description: String)] {
    let recency = Self.loadModelRecency()
    let current = PromptModel.loadSelectedChatModel()
    let rank: (PromptModel) -> Int = { recency.firstIndex(of: $0.rawValue) ?? Int.max }
    return Self.modelCommands
      .filter { $0.model != current }
      .enumerated()
      .sorted { a, b in
        let ra = rank(a.element.model), rb = rank(b.element.model)
        return ra != rb ? ra < rb : a.offset < b.offset
      }
      .map { ($0.element.command, $0.element.description) }
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
    recentSessions = store.recentSessions(limit: 20)
    allSessionsList = store.allSessions()
    loadScrollAnchors()
    isMeetingActive = LiveMeetingTranscriptStore.shared.isSessionActive
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
  /// `submitComposer`, so this path only sees real chat content; it queues /
  /// supersedes / dispatches via `performSend`.
  func sendComposed(finalContent: String, attachedParts: [AttachedImagePart]) async {
    let hasContent = !finalContent.isEmpty || !attachedParts.isEmpty
    guard hasContent else { return }

    // On-demand live summary: when the user chats with the meeting that's recording right now,
    // request a rolling-summary refresh so later turns carry meeting content older than the last
    // 5 minutes of transcript. The refresh is async (single-flight), so it benefits the next turn;
    // this turn still gets the recent transcript plus whatever summary already exists.
    if isCurrentSessionTheActiveMeeting {
      NotificationCenter.default.post(name: .liveMeetingSummaryRefreshRequested, object: nil)
    }

    errorMessage = nil
    if isSending {
      supersedeInFlight(
        with: QueuedChatMessage(
          sessionId: session.id, content: finalContent, attachedParts: attachedParts))
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
    store.save(target)
    scrollAnchorClearSignal.send()
    session = target
    messages = target.messages
    errorMessage = nil
    DebugLogger.log(
      "CHAT: Retry message (contentLen=\(original.content.count), attachments=\(original.attachedImageParts.count)) session=\(sessionId)")
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
    for url in urls {
      guard let data = try? Data(contentsOf: url) else {
        failedNames.append(url.lastPathComponent)
        continue
      }
      let mimeType = Self.mimeType(for: url)
      pendingFileAttachments.append(PendingFile(data: data, mimeType: mimeType, filename: url.lastPathComponent))
      DebugLogger.log("GEMINI-CHAT: File attached: \(url.lastPathComponent) (\(mimeType), \(data.count) bytes)")
    }
    if !failedNames.isEmpty {
      errorMessage = "Could not read: \(failedNames.joined(separator: ", "))"
    }
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
  }

  func unpin() {
    UserDefaults.standard.set(true, forKey: UserDefaultsKeys.chatCloseOnFocusLoss)
    DebugLogger.log("GEMINI-CHAT: /unpin — window is now unpinned (closes on focus loss)")
  }

  /// Cancels the in-flight send request for the currently visible session.
  func cancelSend() {
    sendTasks[session.id]?.cancel()
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

  /// Cancels the in-flight send and queues `replacement` to run as soon as the
  /// cancellation propagates. The old user message stays in history; the partial
  /// assistant placeholder is dropped so the next request sees a clean turn order.
  private func supersedeInFlight(with replacement: QueuedChatMessage) {
    let sid = session.id
    DebugLogger.log("GEMINI-CHAT: Superseding in-flight request with new message")
    supersedingSessionIds.insert(sid)
    messageQueue.insert(replacement, at: 0)
    sendTasks[sid]?.cancel()
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
    let task = Task {
      sendingSessionIds.insert(sessionId)
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
        supersedingSessionIds.remove(sessionId)
        sendTasks.removeValue(forKey: sessionId)
        StallCancellationRegistry.shared.unregister(sessionId)
        // `ChatViewModel` is `@MainActor`, so this Task inherits MainActor — no explicit hop needed.
        self.processNextQueued()
      }
      let selectedModel = Self.openChatModel
      guard await validateCredential(for: selectedModel) else { return }

      let provider = LLMProviderFactory.provider(for: selectedModel)
      let model = selectedModel.rawValue

      let userMsg = ChatMessage(role: .user, content: content, attachedImageParts: attachedParts)
      appendMessage(userMsg, toSessionId: sessionId)
      var currentContents = buildContents(forSessionId: sessionId)
      let thinkingLevel = sessionId == session.id
        ? session.thinkingLevel
        : (store.session(by: sessionId)?.thinkingLevel ?? .default)
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
      do {
        let placeholder = ChatMessage(id: placeholderId, role: .model, content: "")
        appendMessage(placeholder, toSessionId: sessionId)
        let streamingBuffer = self.attachStreamingBuffer(for: placeholderId)

        var finalSources: [GroundingSource] = []
        var finalSupports: [GroundingSupport] = []
        let tools = buildToolDeclarations()
        let maxToolRounds = 8
        let useGrounding = selectedModel.supportsGrounding
        var toolLoopExhausted = false
        // True once any tool call has executed this turn. Lets us tell an
        // empty final turn that *followed* tool work (model searched, found
        // nothing relevant, returned no summary) apart from a model that just
        // said nothing — the two warrant different fallback copy.
        var executedAnyTools = false

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
            systemInstruction: self.buildSystemInstruction(),
            tools: isFinalRound ? [] : tools,
            useGrounding: useGrounding,
            thinkingLevel: thinkingLevel,
            disableBuiltInTools: isFinalRound,
            // Stable per-session key → provider prompt-cache hits across turns
            // (OpenAI prompt_cache_key, Grok x-grok-conv-id). Gemini ignores it.
            cacheKey: sessionId.uuidString)
          for try await event in stream {
            try Task.checkCancellation()
            switch event {
            case .textDelta(let delta):
              roundText += delta
              streamed += delta
              // Only strip while still in the marker zone. Once stripped, `streamed` never
              // re-acquires a start-anchored marker (deltas append at the end), so re-scanning
              // the whole string every subsequent token is pure waste.
              if !thoughtStripSettled {
                streamed = Self.stripLeakedThoughtTokens(streamed)
                if streamed.utf8.count > 512 { thoughtStripSettled = true }
              }
              streamingBuffer.enqueueUpdate(markerPrefix + streamed)
            case .functionCall(let name, let args, let thoughtSignature):
              pendingCalls.append((name, args, thoughtSignature))
            case .finished(let sources, let supports, _):
              finalSources = sources
              finalSupports = supports
            }
          }
          if pendingCalls.isEmpty { break toolLoop }
          // Tools were already disabled this round, yet the model still emitted only function
          // calls and no usable text — nothing left to try, so surface the exhaustion.
          if isFinalRound {
            DebugLogger.logWarning("CHAT: tool loop exceeded \(maxToolRounds) rounds — stopping")
            toolLoopExhausted = true
            break toolLoop
          }
          executedAnyTools = true
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
            streamingBuffer.setContentImmediate(markerPrefix)
          }
          currentContents.append(contentsOf: turns)
        }

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
            reply = "_I ran out of tool-call rounds before I could finish. Try narrowing the request — e.g. name a specific sender, subject, or date range._"
          } else if executedAnyTools {
            // The model ran tools (e.g. gmail_search) but then ended its turn
            // with no summary — typically because the results were empty or
            // unrelated. A bare "(no response)" hides that; say what happened.
            DebugLogger.logWarning("CHAT: empty final turn after tool calls — surfacing no-results fallback")
            reply = "_I looked into this with the available tools but didn't find anything relevant to summarize. Try narrowing the request — e.g. name a specific sender, subject, or date range._"
          } else {
            reply = "_(no response)_"
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
      } catch is CancellationError {
        let superseded = self.supersedingSessionIds.contains(sessionId)
        DebugLogger.log("CHAT: Send cancelled (superseded=\(superseded))")
        self.commitPartialOrRemove(
          placeholderId: placeholderId, sessionId: sessionId,
          partial: Self.stripLeakedThoughtTokens(markerPrefix + streamed), forceRemove: superseded)
      } catch {
        self.commitPartialOrRemove(
          placeholderId: placeholderId, sessionId: sessionId,
          partial: Self.stripLeakedThoughtTokens(markerPrefix + streamed), forceRemove: false)
        if sessionId == session.id { errorMessage = friendlyError(error) }
        DebugLogger.logError("CHAT: \(error.localizedDescription)")
      }
    }
    sendTasks[sessionId] = task
    // Also expose the task to the watchdog so a main-thread stall during streaming can cancel it
    // (see StallCancellationRegistry). Unregistered in the task's `defer` above.
    StallCancellationRegistry.shared.register(sessionId, task: task)
  }

  private func validateCredential(for model: PromptModel) async -> Bool {
    switch model.provider {
    case .grok:
      guard KeychainManager.shared.hasValidXAIAPIKey() else {
        errorMessage = "Add your xAI API key in Settings to use Grok models."
        return false
      }
    case .openai:
      guard KeychainManager.shared.hasValidOpenAIAPIKey() else {
        errorMessage = "Add your OpenAI API key in Settings to use OpenAI models."
        return false
      }
    case .customOpenAI:
      guard OpenAIChatPreferences.isConfigured else {
        errorMessage = "Configure your custom endpoint URL and API key in Settings → Chat, then select Custom endpoint as the chat model."
        return false
      }
    case .gemini:
      guard await GeminiCredentialProvider.shared.getCredential() != nil else {
        errorMessage = "Add your Google API key in Settings or sign in with Google to use Chat."
        return false
      }
    case .local:
      // Local server needs no API key; reachability surfaces at request time.
      break
    }
    return true
  }

  private func buildToolDeclarations() -> [LLMToolDeclaration] {
    let calendarConnected = GoogleAccountOAuthService.shared.isConnected
    let trelloConnected = TrelloOAuthService.shared.isConnected
    // Image generation renders via the Gemini image model regardless of the chat model,
    // so the tool is offered exactly when a Gemini credential exists.
    let imageGenerationAvailable = GeminiCredentialProvider.shared.hasCredential()
    return ChatToolRegistry.allDeclarations(
      calendarConnected: calendarConnected,
      trelloConnected: trelloConnected,
      imageGenerationAvailable: imageGenerationAvailable,
      meetingContext: session.isMeeting
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
    for call in calls {
      try Task.checkCancellation()
      DebugLogger.log("CHAT-TOOL-CALL: \(call.name) args=\(Self.compactDescription(call.args))")
      let result: [String: Any]
      if call.name == ChatToolRegistry.generateImageToolName {
        // Intercepted here (not in ChatToolRegistry): needs the session's attached images
        // and must hand the generated image to the UI rather than into the tool response.
        let outcome = await executeGenerateImageTool(args: call.args, sessionId: sessionId)
        result = outcome.response
        imageMarkers.append(contentsOf: outcome.markers)
      } else if call.name == ChatToolRegistry.refineMeetingSummaryToolName {
        // Intercepted here: operates on THIS chat's meeting files (transcript/summary on disk).
        result = await executeRefineMeetingSummaryTool(args: call.args)
      } else if call.name == ChatToolRegistry.correctTranscriptTermToolName {
        result = await executeCorrectTranscriptTermTool(args: call.args)
      } else if call.name == ChatToolRegistry.rememberAboutUserToolName {
        result = executeRememberAboutUserTool(args: call.args)
      } else if call.name == ChatToolRegistry.forgetAboutUserToolName {
        result = executeForgetAboutUserTool(args: call.args)
      } else {
        result = await ChatToolRegistry.execute(name: call.name, args: call.args)
      }
      DebugLogger.log("CHAT-TOOL-RESULT: \(call.name) -> \(Self.compactDescription(result))")
      responseParts.append(["functionResponse": ["name": call.name, "response": result]])
    }
    DebugLogger.log("CHAT: executed \(calls.count) tool call(s), continuing stream")
    let turns: [[String: Any]] = [
      ["role": "model", "parts": callParts],
      ["role": "user", "parts": responseParts],
    ]
    return (turns, imageMarkers)
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

    // Model-switch commands (provider-default aliases /gemini /grok /gpt, the per-model short
    // aliases /gemini3flash /gemini25pro /grok4 …, and the silent /openai alias). Generated from PromptModel,
    // so this one lookup covers every model without per-command branches.
    if let model = Self.modelCommandLookup[lower] {
      inputText = ""
      switchToModel(model)
      return
    }

    if lower == Self.newChatCommand || lower == Self.screenshotCommand
        || lower == Self.attachCommand
        || lower == Self.settingsCommand || lower == Self.pinCommand || lower == Self.unpinCommand
        || lower == Self.copyCommand {
      inputText = ""
      if lower == Self.newChatCommand {
        if singleChatOnly {
          appendModelMessage("`/new` is unavailable in this window because it is bound to a single chat session.")
        } else {
          createNewSession()
        }
      }
      else if lower == Self.attachCommand { attachFile() }
      else if lower == Self.settingsCommand { SettingsManager.shared.showSettings() }
      else if lower == Self.pinCommand { togglePin() }
      else if lower == Self.unpinCommand { unpin() }
      else if lower == Self.copyCommand { copyChatToClipboard(sessionId: session.id) }
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
  private func buildSystemInstruction() -> [String: Any] {
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
    // - live or just-ended (live store still owns this stem): rolling summary + last 5 min;
    // - past meeting (live store empty or moved on): summary + full transcript from disk.
    // Regular chats stay free of meeting content.
    let meetingContext: String? = {
      if let provided = meetingContextProvider?() { return provided }
      guard session.isMeeting, let stem = session.meetingStem else { return nil }
      if LiveMeetingTranscriptStore.shared.currentMeetingFilenameStem == stem {
        let live = LiveMeetingTranscriptStore.shared.meetingContextForChat(lastMinutes: 5)
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
    if GoogleAccountOAuthService.shared.isConnected {
      text += "\n\nIMPORTANT — you are CONNECTED to the user's own Google account with LIVE access to their Calendar, Tasks, and Gmail through the tools below. When the user asks anything about their email, inbox, messages, calendar, schedule, events, meetings, appointments, tasks, to-dos, or reminders, you MUST call the relevant tool to fetch the real data BEFORE answering — on the very first turn, without waiting to be asked again. NEVER reply that you lack access, cannot see their inbox/calendar, or that they should paste/forward/attach the content: you have direct access, so use it. You have three distinct Google integrations:\n1. **Google Calendar** (scheduled events with start/end times): google_calendar_list_events, google_calendar_create_event, google_calendar_delete_event\n2. **Google Tasks** (to-do items, reminders): google_tasks_list_tasklists, google_tasks_list, google_tasks_create, google_tasks_complete, google_tasks_delete\n3. **Gmail** (read-only email access): gmail_search, gmail_read\nWhen the user says 'task', 'to-do', or 'reminder', ALWAYS use google_tasks_* tools. Only use google_calendar_* when the user explicitly asks for a calendar event, meeting, or appointment with a specific time.\nThe user has multiple task lists. Call google_tasks_list_tasklists first to discover available lists and their IDs, then pass the correct task_list_id to other google_tasks_* tools.\nFor Gmail: use gmail_search to find emails (supports Gmail query syntax like 'is:unread', 'from:user@example.com', 'newer_than:2d'). Use gmail_read to get the full body of a specific email. Gmail access is read-only.\nUse the user's local time zone (\(TimeZone.current.identifier)) when creating calendar events. Always confirm details before creating, deleting, or modifying events and tasks."
    }
    // Mirrors the gating in buildToolDeclarations: the tool exists iff a Gemini credential does.
    if GeminiCredentialProvider.shared.hasCredential() {
      text += "\n\nIMAGE GENERATION: You can create and edit real images via the `generate_image` tool. When the user asks you to draw, create, render, visualize, edit, or annotate an image, ALWAYS call generate_image — never approximate with ASCII art, SVG, or code blocks. To annotate or edit an image the user attached, pass use_attached_image=true with a precise instruction. The finished image appears in the chat automatically."
    }
    text += "\n\nMEMORY: Use `remember_about_user` to save durable facts the user shares or asks you to keep, and `forget_about_user` to drop ones that are wrong or outdated (the tool descriptions spell out what qualifies). Acknowledge briefly what changed — never dump the whole memory back."
    // Mirrors buildToolDeclarations' meetingContext gating.
    if session.isMeeting {
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
  /// non-streaming render path. `forceRemove` is set on the cancel-superseded path so the
  /// partial doesn't pollute the history of the replacement request.
  private func commitPartialOrRemove(
    placeholderId: UUID, sessionId: UUID, partial: String, forceRemove: Bool
  ) {
    detachStreamingBuffer(for: placeholderId)
    if partial.isEmpty || forceRemove {
      removeMessage(id: placeholderId, fromSessionId: sessionId)
    } else {
      updateStreamingMessage(
        id: placeholderId, sessionId: sessionId,
        content: partial, sources: [], supports: [])
    }
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
        "Current model: **\(cur.displayName)**. Example: `/model 3.1 flash lite` or `/model 2.5 pro`."
      )
    case .applied(let model):
      switchToModel(model)
    case .ambiguous(let candidates):
      let list = candidates.map { "• **\($0.displayName)**" }.joined(separator: "\n")
      appendModelMessage("Multiple matches. Be more specific:\n\(list)")
    case .noMatch(let query):
      appendModelMessage("No model matched \"\(query)\". Try a version and variant, e.g. `3.1 flash lite` or `2.5 pro`.")
    }
    DebugLogger.log("GEMINI-CHAT: /model argument=\(argument) outcome=\(outcome)")
  }

  /// Persists the selected chat model and posts a confirmation message. The `model` is
  /// expected to be already migrated (callers come from `ChatModelCommandResolver` or
  /// `ChatModelProvider.X.defaultChatModel`, both of which yield current cases).
  private func switchToModel(_ model: PromptModel) {
    UserDefaults.standard.set(model.rawValue, forKey: UserDefaultsKeys.selectedChatModel)
    Self.recordModelUse(model)
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

  /// A single hit from searching chats and meeting transcripts.
  struct ChatSearchResult: Identifiable {
    enum Kind { case chat, meeting }
    let id: UUID
    let kind: Kind
    /// Session to open on tap. Nil for an orphan meeting transcript whose session was pruned.
    let sessionId: UUID?
    /// Transcript file, used to reveal an orphan meeting in Finder.
    let meetingURL: URL?
    let title: String
    let snippet: String
    let date: Date
    let score: Int
    var isMeeting: Bool { kind == .meeting }
  }

  private static let maxSearchResults = 50

  /// Searches every chat session (title + message text) and meeting transcript (.txt content),
  /// returning results ranked by relevance (term-occurrence score) then recency. Multi-word
  /// queries use AND semantics. A blank query returns an empty list.
  func search(_ rawQuery: String) -> [ChatSearchResult] {
    let terms = rawQuery.lowercased()
      .split(whereSeparator: { $0.isWhitespace })
      .map(String.init)
    guard !terms.isEmpty else { return [] }

    let meetingService = MeetingListService.shared
    meetingService.refresh()
    let meetingsByStem = Dictionary(
      meetingService.meetings.map { ($0.meetingId, $0) },
      uniquingKeysWith: { first, _ in first })

    var results: [ChatSearchResult] = []
    var coveredStems = Set<String>()

    for session in store.allSessions() {
      var parts: [String] = []
      if let t = session.title { parts.append(t) }
      parts.append(contentsOf: session.messages.map { GeminiAPIClient.stripImageMarkers($0.content) })

      var meetingURL: URL? = nil
      if session.isMeeting, let stem = session.meetingStem, let meeting = meetingsByStem[stem] {
        coveredStems.insert(stem)
        meetingURL = meeting.url
        parts.append(meetingService.chunks(for: meeting).map { $0.text }.joined(separator: "\n"))
      }

      let haystack = parts.joined(separator: "\n").lowercased()
      guard terms.allSatisfy({ haystack.contains($0) }) else { continue }

      let title = Self.displayTitle(for: session)
      results.append(ChatSearchResult(
        id: session.id,
        kind: session.isMeeting ? .meeting : .chat,
        sessionId: session.id,
        meetingURL: meetingURL,
        title: title,
        snippet: Self.searchSnippet(from: parts, terms: terms, fallback: title),
        date: session.lastUpdated,
        score: Self.searchScore(haystack: haystack, title: title.lowercased(), terms: terms)))
    }

    // Orphan transcripts: file exists but its session was pruned from the 50-session cap.
    for meeting in meetingService.meetings where !coveredStems.contains(meeting.meetingId) {
      let transcript = meetingService.chunks(for: meeting).map { $0.text }.joined(separator: "\n")
      let haystack = (meeting.displayLabel + "\n" + transcript).lowercased()
      guard terms.allSatisfy({ haystack.contains($0) }) else { continue }
      results.append(ChatSearchResult(
        id: UUID(),
        kind: .meeting,
        sessionId: nil,
        meetingURL: meeting.url,
        title: meeting.displayLabel,
        snippet: Self.searchSnippet(from: [transcript], terms: terms, fallback: meeting.displayLabel),
        date: meeting.date,
        score: Self.searchScore(haystack: haystack, title: meeting.displayLabel.lowercased(), terms: terms)))
    }

    results.sort { $0.score != $1.score ? $0.score > $1.score : $0.date > $1.date }
    return Array(results.prefix(Self.maxSearchResults))
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

  /// Relevance score: total term occurrences across the (lowercased) haystack, plus a bonus
  /// for each term that also appears in the (lowercased) title.
  private static func searchScore(haystack: String, title: String, terms: [String]) -> Int {
    var score = 0
    for term in terms {
      var idx = haystack.startIndex
      while let r = haystack.range(of: term, range: idx..<haystack.endIndex) {
        score += 1
        idx = r.upperBound
      }
      if title.contains(term) { score += 5 }
    }
    return score
  }

  /// Builds a one-line snippet centered on the first matching term, with ellipses for elided context.
  private static func searchSnippet(from parts: [String], terms: [String], fallback: String) -> String {
    let flat = parts.joined(separator: " • ")
      .replacingOccurrences(of: "\n", with: " ")
      .replacingOccurrences(of: "\r", with: " ")
    var hit: Range<String.Index>? = nil
    for term in terms {
      if let r = flat.range(of: term, options: .caseInsensitive),
         hit == nil || r.lowerBound < hit!.lowerBound {
        hit = r
      }
    }
    guard let match = hit else {
      return String(fallback.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
    }
    let start = flat.index(match.lowerBound, offsetBy: -40, limitedBy: flat.startIndex) ?? flat.startIndex
    let end = flat.index(match.lowerBound, offsetBy: 80, limitedBy: flat.endIndex) ?? flat.endIndex
    var s = String(flat[start..<end]).trimmingCharacters(in: .whitespaces)
    if start != flat.startIndex { s = "…" + s }
    if end != flat.endIndex { s += "…" }
    return s
  }

  /// Translates a meeting-button tap into the right intent based on current session state:
  /// stop the active meeting, resume a finished meeting, or start a fresh one.
  func handleMeetingButtonTap() {
    if isCurrentSessionTheActiveMeeting {
      NotificationCenter.default.post(name: .chatStopLiveMeeting, object: nil)
    } else if isMeetingActive {
      // A meeting is running on a different session; treat as stop request
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
        summary: summary.trimmingCharacters(in: .whitespacesAndNewlines))
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
      if msg.role == .user && !msg.attachedImageParts.isEmpty {
        var parts: [[String: Any]] = msg.attachedImageParts.map { part in
          ["inline_data": ["mime_type": part.mimeType ?? "image/png", "data": part.data.base64EncodedString()]]
        }
        if !text.isEmpty {
          parts.append(["text": text])
        }
        return ["role": msg.role.rawValue, "parts": parts]
      }
      return ["role": msg.role.rawValue, "parts": [["text": text]]]
    }
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

  private func friendlyError(_ error: Error) -> String {
    if let te = error as? TranscriptionError {
      switch te {
      case .invalidAPIKey, .incorrectAPIKey:
        return "Invalid API key. Please check your API key in Settings."
      case .rateLimited:
        return "Rate limit reached. Please wait a moment and try again."
      case .quotaExceeded:
        return "API quota exceeded. Please try again later."
      case .networkError(let msg):
        // Hide raw JSON for transient Gemini outages.
        let lower = msg.lowercased()
        if lower.contains("503") || lower.contains("unavailable") {
          return "Gemini is temporarily unavailable. Please try again in a few seconds."
        }
        if lower.contains("502") || lower.contains("504") {
          return "Gemini server error. Please try again in a few seconds."
        }
        // Provider-specific, already user-actionable messages are shown verbatim.
        if msg.hasPrefix("xAI ") || msg.hasPrefix("No xAI") {
          return msg
        }
        return "Network error: \(msg)"
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
  /// Session id currently being renamed via the context-menu alert.
  @State private var renamingTabId: UUID? = nil
  @State private var renameDraft: String = ""
  /// When true, create a new chat session on first appear (e.g. for the meeting window so it opens with a fresh chat).
  @State private var createNewSessionOnAppear: Bool
  @State private var hasTriggeredNewSessionOnAppear: Bool = false
  @AppStorage(UserDefaultsKeys.chatSidebarVisible) private var sidebarVisible: Bool = true
  @State private var meetingTab: MeetingTab = .chat

  private enum MeetingTab: String, CaseIterable {
    case chat = "Chat"
    case transcript = "Transcript"
    case summary = "Summary"
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
          if viewModel.isCurrentSessionMeeting && meetingTab == .transcript {
            meetingTranscriptView
          } else if viewModel.isCurrentSessionMeeting && meetingTab == .summary {
            meetingSummaryView
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
            ForEach(viewModel.messages) { message in
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

  private var emptyStateCommandHints: some View {
    let suggestions = viewModel.commandSuggestionsForDisplay
    let config = ShortcutConfigManager.shared.loadConfiguration()
    let shortcuts: [(shortcut: String, description: String)] = [
      (config.startRecording.displayStringWithSeparator, "Speech-to-Text"),
      (config.startPrompting.displayStringWithSeparator, "Speech-to-Prompt"),
      (config.openChat.displayStringWithSeparator, "Chat"),
      (config.openSettings.displayStringWithSeparator, "Settings"),
      (config.screenshotCapture.displayStringWithSeparator, "Screenshot to Clipboard"),
    ]
    return VStack(alignment: .leading, spacing: 20) {
      VStack(alignment: .leading, spacing: 12) {
        Text("Commands")
          .font(.headline)
          .fontWeight(.semibold)
          .foregroundColor(ChatTheme.secondaryText)
        VStack(alignment: .leading, spacing: 8) {
          ForEach(suggestions, id: \.command) { item in
            Text("\(item.command) — \(item.description)")
              .font(.system(size: 15))
              .foregroundColor(ChatTheme.secondaryText)
          }
        }
      }
      Divider()
        .opacity(0.5)
      VStack(alignment: .leading, spacing: 12) {
        Text("Keyboard Shortcuts")
          .font(.headline)
          .fontWeight(.semibold)
          .foregroundColor(ChatTheme.secondaryText)
        VStack(alignment: .leading, spacing: 8) {
          ForEach(shortcuts, id: \.shortcut) { item in
            Text("\(item.shortcut)  \(item.description)")
              .font(.system(size: 15))
              .foregroundColor(ChatTheme.secondaryText)
          }
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, 16)
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
        proxy.scrollTo(viewModel.isSending ? "typing" : "listBottom", anchor: .bottom)
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
    let isRecording = viewModel.isCurrentSessionTheActiveMeeting
    return VStack(spacing: 0) {
      HStack(spacing: 0) {
        HStack(spacing: 6) {
          Circle()
            .fill(isRecording ? Color.red : ChatTheme.secondaryText.opacity(0.4))
            .frame(width: 7, height: 7)
          Text(isRecording ? "Recording" : "Ended")
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(ChatTheme.secondaryText)
        }
        .frame(width: 80, alignment: .leading)

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

        Spacer()

        Button(action: {
          if isRecording {
            NotificationCenter.default.post(name: .chatStopLiveMeeting, object: nil)
          } else {
            // Rehydrate this meeting's transcript/summary before resuming (see requestResumeMeeting).
            viewModel.requestResumeMeeting()
          }
        }) {
          Text(isRecording ? "Stop" : "Resume")
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(isRecording ? .white : ChatTheme.primaryText)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(isRecording ? Color.red.opacity(0.85) : Color.clear)
            .cornerRadius(4)
            .overlay(isRecording ? nil : RoundedRectangle(cornerRadius: 4).stroke(ChatTheme.secondaryText.opacity(0.3), lineWidth: 1))
        }
        .buttonStyle(.plain)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
      Divider()
    }
    .background(ChatTheme.topBarBackground)
  }

  private var meetingTranscriptView: some View {
    // The live store is a singleton owned by whichever meeting is recording right now.
    // Only show its chunks when THIS tab is that active meeting; otherwise read the
    // selected session's own transcript from disk. Without this guard every meeting tab
    // displayed the currently-recording meeting's transcript.
    let liveChunks = viewModel.isCurrentSessionTheActiveMeeting
      ? LiveMeetingTranscriptStore.shared.chunks : []
    let diskText = liveChunks.isEmpty ? viewModel.loadMeetingTranscriptFromDisk() : nil
    return ScrollView {
      LazyVStack(alignment: .leading, spacing: 8) {
        if !liveChunks.isEmpty {
          ForEach(liveChunks) { chunk in
            HStack(alignment: .top, spacing: 8) {
              Text(chunk.timestampString)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(ChatTheme.secondaryText)
              Text(chunk.text)
                .font(.system(size: 14))
                .foregroundColor(ChatTheme.primaryText)
                .textSelection(.enabled)
            }
          }
        } else if let text = diskText, !text.isEmpty {
          Text(text)
            .font(.system(size: 14))
            .foregroundColor(ChatTheme.primaryText)
            .textSelection(.enabled)
        } else {
          Text("No transcript yet.")
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
  }

  private var meetingSummaryView: some View {
    // `LiveMeetingTranscriptStore.shared.summary` is the singleton's *current* rolling summary —
    // it belongs to whichever meeting is recording right now, not necessarily the one this tab is
    // viewing. Only show it when this tab IS the active meeting; otherwise fall through to the
    // disk-backed ended-meeting summary (the recovery path writes to disk too).
    let liveSummary = LiveMeetingTranscriptStore.shared.summary
    let text: String? = viewModel.isCurrentSessionTheActiveMeeting && !liveSummary.isEmpty
      ? liveSummary
      : viewModel.endedMeetingSummary
    return ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        if let text, !text.isEmpty {
          Text(text)
            .font(.system(size: 14))
            .foregroundColor(ChatTheme.primaryText)
            .textSelection(.enabled)
        } else if viewModel.isRecoveringMeetingSummary {
          HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Generating summary…")
              .font(.system(size: 14))
              .foregroundColor(ChatTheme.secondaryText)
          }
          .padding(.top, 40)
          .frame(maxWidth: .infinity)
        } else {
          Text("No summary yet.")
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
      // On-demand live summary: only pay for a rolling-summary update when the user actually opens
      // the Summary tab of the meeting that's recording right now. MenuBarController folds every
      // chunk since the last update into one call (single-flight, so rapid re-opens are cheap).
      if viewModel.isCurrentSessionTheActiveMeeting {
        NotificationCenter.default.post(name: .liveMeetingSummaryRefreshRequested, object: nil)
      }
    }
  }

  private func noticeBanner(_ message: String) -> some View {
    HStack(spacing: 8) {
      Image(systemName: "checkmark.circle.fill")
        .foregroundColor(.white)
        .font(.footnote)
      Text(message)
        .font(.footnote)
        .foregroundColor(.white)
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
      Spacer()
      Button(action: { viewModel.noticeMessage = nil }) {
        Image(systemName: "xmark")
          .font(.footnote.bold())
          .foregroundColor(.white.opacity(0.8))
      }
      .buttonStyle(.plain)
      .pointerCursorOnHover()
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(Color.green.opacity(0.75))
  }

  private func errorBanner(_ message: String) -> some View {
    HStack(spacing: 8) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundColor(.white)
        .font(.footnote)
      Text(message)
        .font(.footnote)
        .foregroundColor(.white)
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
      Spacer()
      Button(action: { viewModel.errorMessage = nil }) {
        Image(systemName: "xmark")
          .font(.footnote.bold())
          .foregroundColor(.white.opacity(0.8))
      }
      .buttonStyle(.plain)
      .pointerCursorOnHover()
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(Color.red.opacity(0.85))
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

  @StateObject private var composer = GeminiComposerController()
  /// Highlighted row in the slash-command suggestion overlay (↑/↓ navigation, Enter/Tab to select).
  /// Reset to 0 whenever the typed slash word changes (see `body`'s `onChange`).
  @State private var selectedSuggestionIndex = 0
  @AppStorage(UserDefaultsKeys.chatCloseOnFocusLoss) private var closeOnFocusLoss: Bool = SettingsDefaults.chatCloseOnFocusLoss
  @AppStorage(UserDefaultsKeys.selectedChatModel) private var selectedChatModelRaw: String = SettingsDefaults.selectedChatModel.rawValue

  private static let inputMinHeight: CGFloat = 32
  private static let inputMaxHeight: CGFloat = 160

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
  /// power text chat.
  private var resolvedOpenGeminiModel: PromptModel {
    let migratedRaw = PromptModel.migrateLegacyPromptRawValue(selectedChatModelRaw)
    let resolved = PromptModel(rawValue: migratedRaw)
      .map { PromptModel.migrateIfDeprecated($0) }
      ?? SettingsDefaults.selectedChatModel
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
    return viewModel.commandSuggestionsForDisplay.filter { $0.command.lowercased().hasPrefix(prefix) }
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
      selectCommand(command)
      return
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

  private var inputBar: some View {
    VStack(spacing: 0) {
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
        onClickScreenshot: { data in onTapScreenshotThumbnail(data) }
      )
      .frame(height: inputHeight)

      // Toolbar row below composer: action buttons left, model selector + send right
      HStack(spacing: 4) {
        Button(action: { viewModel.attachFile() }) {
          HStack(spacing: 4) {
            Image(systemName: "paperclip").font(.caption)
            Text("/attach").font(.caption)
          }
          .foregroundColor(ChatTheme.secondaryText)
          .padding(.horizontal, 8)
          .padding(.vertical, 5)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(viewModel.isSending)
        .help("Attach a file (PDF, image, …) to your next message.")
        .pointerCursorOnHover()

        Button(action: { Task { await viewModel.captureScreenshot() } }) {
          HStack(spacing: 4) {
            if viewModel.screenshotCaptureInProgress {
              ProgressView().controlSize(.mini).frame(width: 10, height: 10)
            } else {
              Image(systemName: "camera.viewfinder").font(.caption)
            }
            Text("/screenshot").font(.caption)
          }
          .foregroundColor(viewModel.screenshotCaptureInProgress ? ChatTheme.secondaryText.opacity(0.6) : ChatTheme.secondaryText)
          .padding(.horizontal, 8)
          .padding(.vertical, 5)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(viewModel.screenshotCaptureInProgress || viewModel.isSending)
        .help("Capture screen without this window; image will be attached to your next message.")
        .pointerCursorOnHover()

        if !viewModel.singleChatOnly {
          Button(action: { viewModel.createNewSession() }) {
            HStack(spacing: 4) {
              Image(systemName: "square.and.pencil").font(.caption)
              Text("/new").font(.caption)
            }
            .foregroundColor(ChatTheme.secondaryText)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .help("Start a new chat (previous chat stays in history)")
          .pointerCursorOnHover()
        }

        Button(action: {
          viewModel.handleMeetingButtonTap()
        }) {
          HStack(spacing: 4) {
            Image(systemName: "record.circle")
              .font(.caption)
              .foregroundColor(viewModel.isMeetingActive ? .red : ChatTheme.secondaryText)
            Text("/meeting")
              .font(.caption)
          }
          .foregroundColor(viewModel.isMeetingActive ? .red : ChatTheme.secondaryText)
          .padding(.horizontal, 8)
          .padding(.vertical, 5)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(viewModel.isMeetingActive ? "Stop the current meeting recording" : "Start a new live meeting recording")
        .pointerCursorOnHover()

        Spacer()

        Menu {
          ForEach(PromptModel.chatModels, id: \.self) { model in
            Button(action: {
              selectedChatModelRaw = model.rawValue
              ChatViewModel.recordModelUse(model) // keep autocomplete recency in sync with the picker
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

// MARK: - Paragraphs with citations at end

/// One paragraph with its character range and grounding chunk indices (for citations at end of paragraph).
private struct ParagraphWithCitations {
  let text: String
  let chunkIndices: [Int]
}

private enum ParagraphCitationBuilder {
  /// Splits content by "\n\n" and assigns to each paragraph all chunk indices from supports whose segment overlaps that paragraph. Citations are then rendered at the end of each paragraph.
  static func buildParagraphs(content: String, supports: [GroundingSupport], sourcesCount: Int) -> [ParagraphWithCitations] {
    let parts = content.components(separatedBy: "\n\n")
    var paragraphs: [ParagraphWithCitations] = []
    var startOffset = 0
    for part in parts {
      let endOffset = startOffset + part.count
      let indices = chunkIndicesForRange(start: startOffset, end: endOffset, supports: supports, sourcesCount: sourcesCount)
      paragraphs.append(ParagraphWithCitations(text: part, chunkIndices: indices))
      startOffset = endOffset + 2
    }
    return paragraphs
  }

  private static func chunkIndicesForRange(start: Int, end: Int, supports: [GroundingSupport], sourcesCount: Int) -> [Int] {
    var set: Set<Int> = []
    for s in supports {
      guard s.startIndex < end, s.endIndex > start else { continue }
      for idx in s.groundingChunkIndices where idx >= 0 && idx < sourcesCount {
        set.insert(idx)
      }
    }
    return set.sorted()
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

// MARK: - Markdown Table / Block types (shared via MarkdownParsing.swift)

private enum ReplyContentBlock {
  case text(AttributedString)
  case bulletList([AttributedString]) // each item is one bullet
  case table(ParsedTable)
  case separator
  case codeBlock(String, String?) // code content, optional language
  case image(NSImage) // inline image (e.g. from Gemini image generation)
}

// MARK: - Code Block Extraction

/// Extracts fenced code blocks from raw markdown BEFORE splitting by \n\n,
/// replacing them with placeholder tokens so they survive paragraph splitting.
private struct CodeBlockExtractor {
  struct ExtractedCodeBlock {
    let code: String
    let language: String?
  }

  private static let placeholderPrefix = "⟦CODEBLOCK_"
  private static let placeholderSuffix = "⟧"

  /// Extracts all fenced code blocks, returns (processed text with placeholders, extracted blocks).
  static func extract(from content: String) -> (String, [ExtractedCodeBlock]) {
    var blocks: [ExtractedCodeBlock] = []
    var result = content
    // Match ```language\n...code...\n``` (multiline, non-greedy)
    let pattern = "```(\\w*)\\n([\\s\\S]*?)\\n```"
    guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
      return (content, [])
    }
    let nsContent = content as NSString
    let matches = regex.matches(in: content, range: NSRange(location: 0, length: nsContent.length))
    // Process matches in reverse order so replacement indices stay valid
    for match in matches.reversed() {
      let langRange = match.range(at: 1)
      let codeRange = match.range(at: 2)
      let language = langRange.location != NSNotFound ? nsContent.substring(with: langRange) : nil
      let code = codeRange.location != NSNotFound ? nsContent.substring(with: codeRange) : ""
      let lang = (language?.isEmpty ?? true) ? nil : language
      let index = blocks.count
      blocks.insert(ExtractedCodeBlock(code: code, language: lang), at: 0)
      let placeholder = "\n\n\(placeholderPrefix)\(index)\(placeholderSuffix)\n\n"
      result = (result as NSString).replacingCharacters(in: match.range, with: placeholder)
    }
    return (result, blocks)
  }

  /// Checks if a trimmed paragraph is a code block placeholder and returns the index.
  static func placeholderIndex(_ trimmed: String) -> Int? {
    guard trimmed.hasPrefix(placeholderPrefix), trimmed.hasSuffix(placeholderSuffix) else { return nil }
    let inner = trimmed.dropFirst(placeholderPrefix.count).dropLast(placeholderSuffix.count)
    return Int(inner)
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

/// Carries the intended AppKit font metrics (size + weight) for prose runs whose SwiftUI `.font`
/// would otherwise be lost when we render the prose in an `NSTextView` (SwiftUI `Font` does not
/// bridge to `NSFont`). Stamped on headings and the heading rule line; everything else falls back
/// to the 16-pt body font. A plain Hashable struct so it survives in the segment NSCache.
private struct ProseFontMetrics: Hashable, Sendable {
  let size: CGFloat
  let weight: CGFloat
}

private enum ProseFontHint: AttributedStringKey {
  typealias Value = ProseFontMetrics
  static let name = "chat.proseFontHint"
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

  /// Markdown parsing (buildReplyBlocks + mergedSegments) is expensive and would otherwise run on
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
    let blocks = buildReplyBlocks(content: content, sources: sources, groundingSupports: groundingSupports)
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

  /// A citation marker like " [3]" as PLAIN text — deliberately NO `.link` and NO per-run
  /// font. An inline `.link` run (or a per-run font that differs from the body font) inside a
  /// `.textSelection(.enabled)` Text drives SwiftUI's macOS `SelectionOverlay` into a
  /// non-terminating `setFont:` / `_effectiveFontDidChangeTo:` loop (100% CPU hang). The
  /// clickable source still lives in `sourcesView`'s chip row, so nothing is lost.
  private static func citationMarker(_ oneBased: Int) -> AttributedString {
    AttributedString(" [\(oneBased)]")
  }

  /// Appends citation markers for every in-range chunk index. `sourcesCount` bounds the indices so
  /// we never reference a source that doesn't exist.
  private static func appendCitations(to attr: inout AttributedString, indices: [Int], sourcesCount: Int) {
    for idx in indices where idx < sourcesCount {
      attr.append(citationMarker(idx + 1))
    }
  }

  private static func buildReplyBlocks(
    content: String,
    sources: [GroundingSource],
    groundingSupports: [GroundingSupport]
  ) -> [ReplyContentBlock] {
    let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    if groundingSupports.isEmpty || sources.isEmpty {
      return buildContentOnlyBlocks(content: content, options: options)
    }
    let paragraphs = ParagraphCitationBuilder.buildParagraphs(
      content: content, supports: groundingSupports, sourcesCount: sources.count)
    var blocks: [ReplyContentBlock] = []
    for para in paragraphs {
      let trimmed = para.text.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.isEmpty { continue }
      if Self.shouldSkipGeneratedImagePlaceholder(trimmed, in: content) { continue }
      if let pieces = Self.splitImageMarkerPieces(trimmed) {
        // Generated image(s) — previously only the content-only builder knew about markers,
        // so a grounded reply (sources ⇒ this builder) rendered the raw base64 as text.
        // Citations attach to the last text piece; an image-only paragraph drops them.
        let lastTextIdx = pieces.lastIndex {
          if case .text = $0 { return true } else { return false }
        }
        for (i, piece) in pieces.enumerated() {
          switch piece {
          case .image(let image):
            blocks.append(.image(image))
          case .text(let text):
            guard !GeminiAPIClient.isGeneratedImagePlaceholder(text) else { continue }
            var attr = buildSingleParagraphAttributed(text, options: options)
            if i == lastTextIdx {
              appendCitations(to: &attr, indices: para.chunkIndices, sourcesCount: sources.count)
            }
            blocks.append(.text(attr))
          }
        }
      } else if MarkdownParsing.isSeparatorParagraph(trimmed) {
        blocks.append(.separator)
      } else if MarkdownParsing.looksLikeMarkdownTable(trimmed), let parsed = MarkdownParsing.parseMarkdownTable(trimmed) {
        blocks.append(.table(parsed))
      } else if let bulletItems = parseBulletItems(trimmed) {
        // Pure bullet block — attach citations to the last item
        if para.chunkIndices.isEmpty {
          blocks.append(.bulletList(bulletItems))
        } else {
          var items = bulletItems
          var lastItem = items.removeLast()
          appendCitations(to: &lastItem, indices: para.chunkIndices, sourcesCount: sources.count)
          items.append(lastItem)
          blocks.append(.bulletList(items))
        }
      } else if let (headingPart, bulletPart) = splitHeadingAndBullets(trimmed) {
        // Heading followed by bullets — heading gets citations, bullets rendered separately
        var headingAttr = buildSingleParagraphAttributed(headingPart, options: options)
        appendCitations(to: &headingAttr, indices: para.chunkIndices, sourcesCount: sources.count)
        blocks.append(.text(headingAttr))
        if let items = parseBulletItems(bulletPart) {
          blocks.append(.bulletList(items))
        } else {
          blocks.append(.text(buildSingleParagraphAttributed(bulletPart, options: options)))
        }
      } else {
        // A model may glue several `**…:**` sections into one \n\n-paragraph with no
        // separators. Split them here (after citation offsets are already resolved, so
        // alignment is unaffected) and attach the paragraph's citations to the last part.
        let subParts = MarkdownParsing.splitInlineSectionHeadings(trimmed)
          .components(separatedBy: "\n\n")
          .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
          .filter { !$0.isEmpty }
        for (i, sub) in subParts.enumerated() {
          var attrText = buildSingleParagraphAttributed(sub, options: options)
          if i == subParts.count - 1 {
            appendCitations(to: &attrText, indices: para.chunkIndices, sourcesCount: sources.count)
          }
          blocks.append(.text(attrText))
        }
      }
    }
    // Strip markers in the fallback too: a message whose only marker failed to decode would
    // otherwise dump the raw multi-MB base64 into the UI as text.
    return blocks.isEmpty
      ? [.text(AttributedString(GeminiAPIClient.stripImageMarkers(content)))]
      : blocks
  }

  private static func buildContentOnlyBlocks(
    content: String,
    options: AttributedString.MarkdownParsingOptions
  ) -> [ReplyContentBlock] {
    // Extract fenced code blocks BEFORE splitting by \n\n
    let (processed, codeBlocks) = CodeBlockExtractor.extract(from: content)
    let paragraphs = MarkdownParsing.normalizeMarkdownParagraphBreaks(processed).components(separatedBy: "\n\n")
    var blocks: [ReplyContentBlock] = []
    for para in paragraphs {
      let trimmed = para.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.isEmpty { continue }
      if Self.shouldSkipGeneratedImagePlaceholder(trimmed, in: content) { continue }
      if let idx = CodeBlockExtractor.placeholderIndex(trimmed), idx < codeBlocks.count {
        let cb = codeBlocks[idx]
        if cb.language == "markdown" && Self.looksLikeStructuredAnswer(cb.code) {
          blocks.append(contentsOf: buildContentOnlyBlocks(content: cb.code, options: options))
        } else {
          blocks.append(.codeBlock(cb.code, cb.language))
        }
      } else if let pieces = Self.splitImageMarkerPieces(trimmed) {
        for piece in pieces {
          switch piece {
          case .image(let image):
            blocks.append(.image(image))
          case .text(let text):
            guard !GeminiAPIClient.isGeneratedImagePlaceholder(text) else { continue }
            blocks.append(.text(buildSingleParagraphAttributed(text, options: options)))
          }
        }
      } else if MarkdownParsing.isSeparatorParagraph(trimmed) {
        blocks.append(.separator)
      } else if MarkdownParsing.looksLikeMarkdownTable(trimmed), let parsed = MarkdownParsing.parseMarkdownTable(trimmed) {
        blocks.append(.table(parsed))
      } else if let bulletItems = parseBulletItems(trimmed) {
        DebugLogger.log("BLOCKS: bulletList with \(bulletItems.count) items")
        blocks.append(.bulletList(bulletItems))
      } else if let (headingPart, bulletPart) = splitHeadingAndBullets(trimmed) {
        DebugLogger.log("BLOCKS: split heading+bullets")
        blocks.append(.text(buildSingleParagraphAttributed(headingPart, options: options)))
        if let items = parseBulletItems(bulletPart) {
          blocks.append(.bulletList(items))
        } else {
          DebugLogger.log("BLOCKS: bullet part failed parse: \(bulletPart.prefix(80))")
          blocks.append(.text(buildSingleParagraphAttributed(bulletPart, options: options)))
        }
      } else {
        DebugLogger.log("BLOCKS: text block: \(trimmed.prefix(80))")
        blocks.append(.text(buildSingleParagraphAttributed(trimmed, options: options)))
      }
    }
    // Strip markers in the fallback too: a message whose only marker failed to decode would
    // otherwise dump the raw multi-MB base64 into the UI as text.
    return blocks.isEmpty
      ? [.text(AttributedString(GeminiAPIClient.stripImageMarkers(content)))]
      : blocks
  }

  /// Splits a paragraph that has non-bullet text followed by bullet lines.
  /// Returns (textPart, bulletPart) if found; nil otherwise.
  private static func splitHeadingAndBullets(_ trimmed: String) -> (String, String)? {
    let lines = trimmed.components(separatedBy: "\n")
    guard lines.count >= 2 else { return nil }
    // Find the first bullet line
    guard let bulletStart = lines.firstIndex(where: { MarkdownParsing.parseBullet($0.trimmingCharacters(in: .whitespaces)) != nil }) else { return nil }
    guard bulletStart > 0 else { return nil }
    let headingPart = lines[0..<bulletStart].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    let bulletPart = lines[bulletStart...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !headingPart.isEmpty, !bulletPart.isEmpty else { return nil }
    return (headingPart, bulletPart)
  }

  private static func looksLikeStructuredAnswer(_ code: String) -> Bool {
    let lines = code.components(separatedBy: "\n")
    let headingCount = lines.filter { $0.hasPrefix("#") }.count
    return headingCount >= 2
  }

  /// Hides the internal `[generated image]` placeholder in the UI when the message still
  /// carries a renderable ⟦GEMINI_IMG:…⟧ marker (model echo from API history, or its own paragraph).
  private static func shouldSkipGeneratedImagePlaceholder(_ trimmed: String, in content: String) -> Bool {
    GeminiAPIClient.isGeneratedImagePlaceholder(trimmed)
      && GeminiAPIClient.containsImageMarker(in: content)
  }

  /// One ordered piece of a paragraph that mixes ⟦GEMINI_IMG:…⟧ markers with prose.
  private enum ImageMarkerPiece {
    case image(NSImage)
    case text(String)
  }

  /// Decoded marker images keyed by marker hash. While the post-image narration streams,
  /// every token invalidates the segment cache and re-parses the paragraph — without this,
  /// each re-parse base64-decodes the multi-MB marker and re-inits an NSImage on the main
  /// thread, per token.
  private static let markerImageCache = NSCache<NSString, NSImage>()

  /// Order-preserving split of a paragraph containing ⟦GEMINI_IMG:…⟧ markers. Streaming can
  /// glue the model's narration directly onto a marker (`…⟧Ich habe…`), so markers must be
  /// recognized anywhere in a paragraph — not only when they make up the whole paragraph.
  /// Returns nil when the paragraph has no marker (caller falls through to normal handling).
  /// A marker whose base64 fails to decode is dropped (logged) rather than dumped as raw text.
  private static func splitImageMarkerPieces(_ trimmed: String) -> [ImageMarkerPiece]? {
    guard GeminiAPIClient.containsImageMarker(in: trimmed) else { return nil }
    var pieces: [ImageMarkerPiece] = []
    GeminiAPIClient.walkImageMarkers(
      trimmed,
      onText: { segment in
        let before = segment.trimmingCharacters(in: .whitespacesAndNewlines)
        if !before.isEmpty, !GeminiAPIClient.isGeneratedImagePlaceholder(before) {
          pieces.append(.text(before))
        }
      },
      onMarker: { markerSegment in
        let key = "\(markerSegment.count)_\(markerSegment.hashValue)" as NSString
        if let cached = markerImageCache.object(forKey: key) {
          pieces.append(.image(cached))
        } else if let data = GeminiAPIClient.decodeImageMarkerData(String(markerSegment)),
                  let image = NSImage(data: data) {
          markerImageCache.setObject(image, forKey: key)
          pieces.append(.image(image))
        } else {
          DebugLogger.logWarning("BLOCKS: image marker failed base64 decode (\(markerSegment.count) chars)")
        }
      },
      onUnterminatedMarker: { trailing in
        // Unterminated marker (e.g. truncated stream) — drop it instead of dumping base64.
        DebugLogger.logWarning("BLOCKS: dropped unterminated image marker (\(trailing.count) chars)")
      }
    )
    return pieces
  }

  /// Parses a paragraph block that consists entirely of bullet/numbered-list lines.
  /// Returns individual attributed strings for each bullet item, or nil if not a bullet block.
  private static func parseBulletItems(_ trimmed: String) -> [AttributedString]? {
    // Group indented continuation lines under the previous bullet so multi-line list items
    // (a common pattern in numbered lists like `1. **Heading:**\n   continuation`) are
    // rendered as a single bullet instead of being rejected by an all-or-nothing check.
    let rawLines = trimmed.components(separatedBy: .newlines)
    var groups: [String] = []
    for line in rawLines {
      let trimmedLine = line.trimmingCharacters(in: .whitespaces)
      if trimmedLine.isEmpty { continue }
      if MarkdownParsing.parseBullet(trimmedLine) != nil {
        groups.append(trimmedLine)
      } else if let first = line.first, first.isWhitespace {
        if groups.isEmpty { return nil }
        groups[groups.count - 1] += " " + trimmedLine
      } else {
        return nil
      }
    }
    guard !groups.isEmpty else { return nil }
    let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    return groups.compactMap { group in
      guard let parsed = MarkdownParsing.parseBullet(group) else { return nil }
      let rawContent = parsed.trimmingCharacters(in: .whitespaces)
      let content = MarkdownParsing.renderLatexToUnicode(rawContent)
      var contentAttr = MarkdownParsing.inlineAttributedString(content, options: opts)
      contentAttr.font = .system(size: ChatTheme.bodyFontSize, weight: .regular)
      return contentAttr
    }
  }

  private static func buildSingleParagraphAttributed(
    _ trimmed: String,
    options: AttributedString.MarkdownParsingOptions
  ) -> AttributedString {
    if MarkdownParsing.isSeparatorParagraph(trimmed) {
      var lineAttr = AttributedString(MarkdownParsing.separatorLineContent)
      lineAttr.foregroundColor = ChatTheme.primaryText.opacity(0.4)
      return lineAttr
    }
    if let (level, title) = MarkdownParsing.parseATXHeading(trimmed) {
      let parts = trimmed.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
      let bodyPart = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
      var headingAttr = MarkdownParsing.inlineAttributedString(title, options: options)
      headingAttr.font = MarkdownParsing.fontForHeadingLevel(level, baseSize: ChatTheme.bodyFontSize)
      let headingMetrics = MarkdownParsing.nsHeadingMetrics(level, baseSize: ChatTheme.bodyFontSize)
      headingAttr[ProseFontHint.self] = ProseFontMetrics(size: headingMetrics.size, weight: headingMetrics.weight.rawValue)
      if !bodyPart.isEmpty {
        headingAttr.append(AttributedString("\n\n"))
        var bodyAttr = MarkdownParsing.inlineAttributedString(bodyPart, options: options)
        bodyAttr.font = .system(size: ChatTheme.bodyFontSize, weight: .regular)
        headingAttr.append(bodyAttr)
      }
      return headingAttr
    }
    // Bullet lists are now handled at the block level, not here
    // Convert LaTeX formulas to Unicode before markdown parsing
    let latexProcessed = MarkdownParsing.renderLatexToUnicode(trimmed)
    let fullOptions = AttributedString.MarkdownParsingOptions(interpretedSyntax: .full)
    let inlineOptions = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    var attr = (try? AttributedString(markdown: latexProcessed, options: fullOptions))
      ?? (try? AttributedString(markdown: latexProcessed, options: inlineOptions))
      ?? AttributedString(latexProcessed)
    attr.font = .system(size: 16, weight: .regular)
    return attr
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
  @State private var isHovered = false

  var body: some View {
    Button {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(text(), forType: .string)
    } label: {
      Image(systemName: "doc.on.doc")
        .font(.system(size: 13))
        .foregroundColor(isHovered ? ChatTheme.primaryText : ChatTheme.secondaryText.opacity(0.75))
        .frame(width: 28, height: 28)
        .contentShape(Rectangle())
        .background(
          RoundedRectangle(cornerRadius: 6)
            .fill(isHovered ? ChatTheme.primaryText.opacity(0.08) : Color.clear)
        )
    }
    .buttonStyle(.plain)
    .onHover { inside in
      isHovered = inside
    }
    .pointerCursorOnHover()
    .help("Copy this reply to the clipboard")
    .accessibilityLabel("Copy this reply to the clipboard")
  }
}

// MARK: - Download Image Button (under model replies that contain an image)

/// Saves the first generated image in a reply to disk via a save panel.
private struct DownloadImageButtonView: View {
  /// Resolved on click, not per render — decoding the marker rebuilds a multi-MB Data blob.
  let image: () -> (data: Data, mimeType: String)?
  @State private var isHovered = false

  var body: some View {
    Button {
      saveImage()
    } label: {
      Image(systemName: "square.and.arrow.down")
        .font(.system(size: 13))
        .foregroundColor(isHovered ? ChatTheme.primaryText : ChatTheme.secondaryText.opacity(0.75))
        .frame(width: 28, height: 28)
        .contentShape(Rectangle())
        .background(
          RoundedRectangle(cornerRadius: 6)
            .fill(isHovered ? ChatTheme.primaryText.opacity(0.08) : Color.clear)
        )
    }
    .buttonStyle(.plain)
    .onHover { inside in
      isHovered = inside
    }
    .pointerCursorOnHover()
    .help("Download this image")
    .accessibilityLabel("Download this image")
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

// MARK: - Retry Button (under the last user message)

/// Re-sends the message (same text and attachments) and regenerates the response.
private struct RetryButtonView: View {
  let action: () -> Void
  @State private var isHovered = false

  var body: some View {
    Button(action: action) {
      Image(systemName: "arrow.clockwise")
        .font(.system(size: 13))
        .foregroundColor(isHovered ? ChatTheme.primaryText : ChatTheme.secondaryText.opacity(0.75))
        .frame(width: 28, height: 28)
        .contentShape(Rectangle())
        .background(
          RoundedRectangle(cornerRadius: 6)
            .fill(isHovered ? ChatTheme.primaryText.opacity(0.08) : Color.clear)
        )
    }
    .buttonStyle(.plain)
    .onHover { inside in
      isHovered = inside
    }
    .pointerCursorOnHover()
    .help("Send this message again and regenerate the response")
    .accessibilityLabel("Retry this message")
  }
}

// MARK: - Read Aloud Button (under model replies)

private struct ReadAloudButtonView: View {
  /// Resolved on click, not per render — see `CopyReplyButtonView.text`.
  let text: () -> String
  @State private var isHovered = false
  @State private var isTTSActive = false

  var body: some View {
    Button {
      if isTTSActive {
        NotificationCenter.default.post(name: .chatReadAloudStop, object: nil)
      } else {
        NotificationCenter.default.post(
          name: .chatReadAloud,
          object: nil,
          userInfo: [Notification.Name.chatReadAloudTextKey: text()]
        )
      }
    } label: {
      Image(systemName: isTTSActive ? "stop.fill" : "speaker.wave.2")
        .font(.system(size: 13))
        .foregroundColor(isTTSActive ? ChatTheme.primaryText : (isHovered ? ChatTheme.primaryText : ChatTheme.secondaryText.opacity(0.75)))
        .frame(width: 28, height: 28)
        .contentShape(Rectangle())
        .background(
          RoundedRectangle(cornerRadius: 6)
            .fill(isTTSActive ? ChatTheme.primaryText.opacity(0.08) : (isHovered ? ChatTheme.primaryText.opacity(0.08) : Color.clear))
        )
    }
    .buttonStyle(.plain)
    .onHover { inside in
      isHovered = inside
    }
    .pointerCursorOnHover()
    .onReceive(NotificationCenter.default.publisher(for: .ttsDidStart)) { _ in
      isTTSActive = true
    }
    .onReceive(NotificationCenter.default.publisher(for: .ttsDidStop)) { _ in
      isTTSActive = false
    }
    .help(isTTSActive ? "Click to stop" : "Read this reply aloud")
    .accessibilityLabel(isTTSActive ? "Reading aloud; click to stop" : "Read this reply aloud")
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
      .padding(.vertical, 12)
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
