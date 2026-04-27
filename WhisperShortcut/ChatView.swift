import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

// MARK: - ViewModel

@MainActor
class ChatViewModel: ObservableObject {
  @Published var messages: [ChatMessage] = []
  @Published var inputText: String = ""
  @Published private(set) var sendingSessionIds: Set<UUID> = []
  /// True when the currently visible session has an in-flight request.
  var isSending: Bool { sendingSessionIds.contains(session.id) }
  @Published var errorMessage: String? = nil
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
  @Published private(set) var archivedSessionsList: [ChatSession] = []
  @Published private(set) var allSessionsList: [ChatSession] = []
  @Published private(set) var currentSessionId: UUID = UUID()
  @Published private(set) var isMeetingActive: Bool = false
  @Published private(set) var meetingSessionId: UUID? = nil
  var isCurrentSessionMeeting: Bool { session.isMeeting }
  var isCurrentSessionTheActiveMeeting: Bool { isMeetingActive && meetingSessionId == session.id }
  private var meetingCancellable: AnyCancellable?

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

  /// Returns true if the given session has an in-flight request (for tab spinner).
  func isSendingSession(_ id: UUID) -> Bool { sendingSessionIds.contains(id) }
  /// Maximum length for auto-generated session title from first user message.
  private static let maxSessionTitleLength = 50

  /// Canonical command names (without prefix). Combined with `commandPrefix` at runtime.
  /// Use `command(_:)` to resolve a name to its full string (e.g. "new" → "/new" or ">new").
  private static let newName = "new"
  static let screenshotName = "screenshot"
  private static let settingsName = "settings"
  private static let pinName = "pin"
  private static let unpinName = "unpin"
  private static let modelName = "model"
  private static let grokName = "grok"
  private static let geminiName = "gemini"
  private static let connectGoogleName = "connect-google"
  private static let disconnectGoogleName = "disconnect-google"
  private static let meetingName = "meeting"

  /// User-configured command prefix (e.g. `/`, `>`). Read from settings each access so
  /// changes in the Settings tab take effect without restarting.
  var commandPrefix: String {
    if let raw = UserDefaults.standard.string(forKey: UserDefaultsKeys.chatCommandPrefix),
       let prefix = ChatCommandPrefix(rawValue: raw) {
      return prefix.character
    }
    return SettingsDefaults.chatCommandPrefix.character
  }

  /// Resolves a canonical command name to its full prefixed string.
  func command(_ name: String) -> String { commandPrefix + name }

  /// Backwards-compatible accessors used throughout this view. Read prefix per call.
  static var screenshotCommand: String {
    let raw = UserDefaults.standard.string(forKey: UserDefaultsKeys.chatCommandPrefix) ?? SettingsDefaults.chatCommandPrefix.rawValue
    let prefix = ChatCommandPrefix(rawValue: raw)?.character ?? SettingsDefaults.chatCommandPrefix.character
    return prefix + screenshotName
  }

  /// All commands (canonical name + description) for autocomplete and help.
  /// `description` is rendered with the live prefix at display time.
  static let commandCatalog: [(name: String, description: String)] = [
    ("new", "Start a new chat (previous chat stays in history)"),
    ("screenshot", "Add a screenshot to your next message (can add multiple)"),
    ("model", "Switch chat model (e.g. {p}model 3.1 flash lite)"),
    ("gemini", "Switch to Gemini 3 Flash"),
    ("grok", "Switch to Grok 4"),
    ("settings", "Open Settings"),
    ("pin", "Toggle whether the window stays open when losing focus"),
    ("unpin", "Make the window close when losing focus"),
    ("connect-google", "Connect Google account (Calendar, Tasks, Gmail)"),
    ("disconnect-google", "Disconnect Google account"),
    ("meeting", "Start or stop live meeting recording"),
  ]

  /// All commands resolved with the current prefix.
  var commandSuggestionsForDisplay: [(command: String, description: String)] {
    let prefix = commandPrefix
    let entries = Self.commandCatalog
      .filter { !singleChatOnly || $0.name != Self.newName }
      .map { (command: prefix + $0.name, description: $0.description.replacingOccurrences(of: "{p}", with: prefix)) }
    return entries
  }

  /// Returns commands whose command string matches the given prefix (e.g. "/" or "/sc").
  func suggestedCommands(for input: String) -> [String] {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let cp = commandPrefix
    guard trimmed.hasPrefix(cp) else { return [] }
    return commandSuggestionsForDisplay
      .map(\.command)
      .filter { $0.lowercased().hasPrefix(trimmed) || trimmed.isEmpty }
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
    archivedSessionsList = store.archivedSessions()
    allSessionsList = store.allSessions()
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
  }

  /// Maximum number of screenshots that can be attached to one message.
  private static let maxPendingScreenshots = 5

  /// Injected by the view so the VM can respect the in-composer screenshot count
  /// when the inline composer already holds the attachments (legacy `pendingScreenshots`
  /// is drained into the composer by the view).
  var composerScreenshotCountProvider: () -> Int = { 0 }

  /// Injected by the view so the VM can respect the in-composer file count.
  var composerFileCountProvider: () -> Int = { 0 }

  /// Sends a message whose content and attachments were already assembled by the inline
  /// composer in document order. Handles slash commands via `typedText`, bypasses the
  /// VM-side chip model, and otherwise queues / dispatches via `performSend`.
  func sendComposed(typedText: String, finalContent: String, attachedParts: [AttachedImagePart]) async {
    let raw = typedText.trimmingCharacters(in: .whitespacesAndNewlines)
    let lower = raw.lowercased()

    // Bare slash commands — never carry attachments, never queue.
    if attachedParts.isEmpty && !finalContent.contains("<pasted_") {
      if lower == command(Self.connectGoogleName) {
        await handleConnectGoogle()
        return
      }
      if lower == command(Self.disconnectGoogleName) {
        handleDisconnectGoogle()
        return
      }
      if lower == command(Self.meetingName) {
        handleMeetingButtonTap()
        return
      }
      let newCmd = command(Self.newName)
      let screenshotCmd = command(Self.screenshotName)
      let settingsCmd = command(Self.settingsName)
      let pinCmd = command(Self.pinName)
      let unpinCmd = command(Self.unpinName)
      let grokCmd = command(Self.grokName)
      let geminiCmd = command(Self.geminiName)
      if [newCmd, screenshotCmd, settingsCmd, pinCmd, unpinCmd, grokCmd, geminiCmd].contains(lower) {
        if lower == newCmd { if !singleChatOnly { createNewSession() } }
        else if lower == settingsCmd { SettingsManager.shared.showSettings() }
        else if lower == pinCmd { togglePin() }
        else if lower == unpinCmd { unpin() }
        else if lower == grokCmd { switchToModel(.grok4) }
        else if lower == geminiCmd { switchToModel(.gemini3Flash) }
        else { await captureScreenshot() }
        return
      }
    }

    let hasContent = !finalContent.isEmpty || !attachedParts.isEmpty
    guard hasContent else { return }

    errorMessage = nil
    if isSending {
      messageQueue.append(QueuedChatMessage(content: finalContent, attachedParts: attachedParts))
      DebugLogger.log("GEMINI-CHAT: Queued composed message, queue size: \(messageQueue.count)")
      return
    }
    performSend(content: finalContent, attachedParts: attachedParts)
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
    } else {
      errorMessage = "Screen capture failed. Opening Screen Recording settings..."
      DebugLogger.logWarning("GEMINI-CHAT: Screen capture returned nil, opening Screen Recording settings")
      if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
        NSWorkspace.shared.open(url)
      }
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

  /// Maximum number of file attachments (images, PDFs, etc.) per message.
  private static let maxFileAttachments = 5

  func attachFile() {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false
    panel.allowedContentTypes = [.pdf, .png, .jpeg, .gif, .webP, .plainText]
    panel.message = "Select files to attach to your next message"
    guard panel.runModal() == .OK else { return }

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
    switch url.pathExtension.lowercased() {
    case "pdf": return "application/pdf"
    case "jpg", "jpeg": return "image/jpeg"
    case "gif": return "image/gif"
    case "webp": return "image/webp"
    default: return "image/png"
    }
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

  // MARK: - Send helpers & Queue

  /// Core send: appends the user message, calls the API, and drains the next queued message on completion.
  private func performSend(content: String, attachedParts: [AttachedImagePart]) {
    let sessionId = session.id
    let task = Task {
      sendingSessionIds.insert(sessionId)
      defer {
        sendingSessionIds.remove(sessionId)
        sendTasks.removeValue(forKey: sessionId)
        Task { @MainActor in self.processNextQueued() }
      }
      let selectedModel = Self.openChatModel
      guard await validateCredential(for: selectedModel) else { return }

      let provider = LLMProviderFactory.provider(for: selectedModel)
      let model = selectedModel.rawValue

      let userMsg = ChatMessage(role: .user, content: content, attachedImageParts: attachedParts)
      appendMessage(userMsg, toSessionId: sessionId)
      var currentContents = buildContents()
      let placeholderId = UUID()
      var accumulated = ""
      do {
        let placeholder = ChatMessage(id: placeholderId, role: .model, content: "")
        appendMessage(placeholder, toSessionId: sessionId)

        var finalSources: [GroundingSource] = []
        var finalSupports: [GroundingSupport] = []
        let tools = await buildToolDeclarations()
        let maxToolRounds = 5
        let useGrounding = selectedModel.supportsGrounding

        toolLoop: for round in 0..<(maxToolRounds + 1) {
          var pendingCalls: [(name: String, args: [String: Any], thoughtSignature: String?)] = []
          let stream = provider.sendChatStream(
            model: model,
            contents: currentContents,
            systemInstruction: self.buildSystemInstruction(),
            tools: tools,
            useGrounding: useGrounding)
          for try await event in stream {
            try Task.checkCancellation()
            switch event {
            case .textDelta(let delta):
              accumulated += delta
              await MainActor.run {
                self.updateStreamingMessage(
                  id: placeholderId, sessionId: sessionId,
                  content: accumulated, sources: [], supports: [], persist: false)
              }
            case .functionCall(let name, let args, let thoughtSignature):
              pendingCalls.append((name, args, thoughtSignature))
            case .finished(let sources, let supports, _):
              finalSources = sources
              finalSupports = supports
            }
          }
          if pendingCalls.isEmpty { break toolLoop }
          if round == maxToolRounds {
            DebugLogger.logWarning("CHAT: tool loop exceeded \(maxToolRounds) rounds — stopping")
            break toolLoop
          }
          let turns = await executeToolCalls(pendingCalls)
          currentContents.append(contentsOf: turns)
        }

        await MainActor.run {
          self.updateStreamingMessage(
            id: placeholderId, sessionId: sessionId,
            content: accumulated, sources: finalSources, supports: finalSupports)
        }
        let result = (text: accumulated, sources: finalSources, supports: finalSupports)
        ContextLogger.shared.logChat(userMessage: content, modelResponse: result.text, model: model)
        if let s = store.session(by: sessionId), s.messages.count == 2 {
          Task { await generateAITitle(sessionId: sessionId) }
        }
      } catch is CancellationError {
        DebugLogger.log("CHAT: Send cancelled by user")
        if accumulated.isEmpty {
          await MainActor.run {
            self.removeMessage(id: placeholderId, fromSessionId: sessionId)
          }
        }
      } catch {
        if sessionId == session.id { errorMessage = friendlyError(error) }
        DebugLogger.logError("CHAT: \(error.localizedDescription)")
      }
    }
    sendTasks[sessionId] = task
  }

  private func validateCredential(for model: PromptModel) async -> Bool {
    if model.provider == .grok {
      guard KeychainManager.shared.hasValidXAIAPIKey() else {
        errorMessage = "Add your xAI API key in Settings to use Grok models."
        return false
      }
    } else {
      guard await GeminiCredentialProvider.shared.getCredential() != nil else {
        errorMessage = "Add your Google API key in Settings or sign in with Google to use Chat."
        return false
      }
    }
    return true
  }

  private func buildToolDeclarations() async -> [LLMToolDeclaration] {
    let calendarConnected = await MainActor.run { GoogleAccountOAuthService.shared.isConnected }
    return ChatToolRegistry.allDeclarations(calendarConnected: calendarConnected).compactMap { decl in
      guard let name = decl["name"] as? String,
            let desc = decl["description"] as? String,
            let params = decl["parameters"] as? [String: Any] else { return nil }
      return LLMToolDeclaration(name: name, description: desc, parameters: params)
    }
  }

  private func executeToolCalls(
    _ calls: [(name: String, args: [String: Any], thoughtSignature: String?)]
  ) async -> [[String: Any]] {
    let callParts: [[String: Any]] = calls.map { call in
      var part: [String: Any] = ["functionCall": ["name": call.name, "args": call.args]]
      if let sig = call.thoughtSignature { part["thoughtSignature"] = sig }
      return part
    }
    var responseParts: [[String: Any]] = []
    for call in calls {
      let result = await ChatToolRegistry.execute(name: call.name, args: call.args)
      responseParts.append(["functionResponse": ["name": call.name, "response": result]])
    }
    DebugLogger.log("CHAT: executed \(calls.count) tool call(s), continuing stream")
    return [
      ["role": "model", "parts": callParts],
      ["role": "user", "parts": responseParts],
    ]
  }

  /// Auto-processes the next queued message once the current one finishes.
  private func processNextQueued() {
    guard !messageQueue.isEmpty, !isSending else { return }
    let next = messageQueue.removeFirst()
    DebugLogger.log("GEMINI-CHAT: Processing next queued message, \(messageQueue.count) remaining")
    performSend(content: next.content, attachedParts: next.attachedParts)
  }

  /// Removes a queued message by ID (called from the pending bubble's delete button).
  func removeQueuedMessage(id: UUID) {
    messageQueue.removeAll { $0.id == id }
  }

  /// Sends the current message. Pass `userInput` when the view holds the text in local state to avoid re-renders on every keystroke.
  /// If a message is already in-flight, the new message is queued and auto-sent when the current one finishes.
  func sendMessage(userInput: String? = nil) async {
    let raw = (userInput ?? inputText).trimmingCharacters(in: .whitespacesAndNewlines)
    let lower = raw.lowercased()
    let hasContent = !raw.isEmpty || !pendingScreenshots.isEmpty || !pendingFileAttachments.isEmpty || !pastedBlocks.isEmpty
    guard hasContent else { return }

    let modelCmd = command(Self.modelName)

    // /model command (switch chat model with fuzzy matching)
    if lower == modelCmd || lower.hasPrefix(modelCmd + " ") {
      inputText = ""
      let arg = lower == modelCmd
        ? ""
        : String(raw.dropFirst(modelCmd.count + 1)).trimmingCharacters(in: .whitespaces)
      handleModelCommand(argument: arg)
      return
    }

    // Google account commands
    if lower == command(Self.connectGoogleName) {
      inputText = ""
      await handleConnectGoogle()
      return
    }
    if lower == command(Self.disconnectGoogleName) {
      inputText = ""
      handleDisconnectGoogle()
      return
    }
    if lower == command(Self.meetingName) {
      inputText = ""
      handleMeetingButtonTap()
      return
    }

    // Slash commands: always immediate, never queued
    let newCmd = command(Self.newName)
    let screenshotCmd = command(Self.screenshotName)
    let settingsCmd = command(Self.settingsName)
    let pinCmd = command(Self.pinName)
    let unpinCmd = command(Self.unpinName)
    let grokCmd = command(Self.grokName)
    let geminiCmd = command(Self.geminiName)
    if [newCmd, screenshotCmd, settingsCmd, pinCmd, unpinCmd, grokCmd, geminiCmd].contains(lower) {
      inputText = ""
      if lower == newCmd { if !singleChatOnly { createNewSession() } }
      else if lower == settingsCmd { SettingsManager.shared.showSettings() }
      else if lower == pinCmd { togglePin() }
      else if lower == unpinCmd { unpin() }
      else if lower == grokCmd { switchToModel(.grok4) }
      else if lower == geminiCmd { switchToModel(.gemini3Flash) }
      else { await captureScreenshot() }
      return
    }

    // Build attachment parts before clearing input (needed for queue snapshot)
    var attachedParts: [AttachedImagePart] = []
    for file in pendingFileAttachments {
      attachedParts.append(AttachedImagePart(data: file.data, mimeType: file.mimeType, filename: file.filename))
    }
    if !pendingScreenshots.isEmpty {
      attachedParts += pendingScreenshots.enumerated().map { index, data in
        let filename = pendingScreenshots.count == 1 ? "screenshot.png" : "screenshot \(index + 1).png"
        return AttachedImagePart(data: data, mimeType: "image/png", filename: filename)
      }
    }
    var parts: [String] = []
    if !pastedBlocks.isEmpty {
      let pastedSection = pastedBlocks
        .map { block -> String in
          switch block.kind {
          case .largePaste:
            return "<pasted_content>\n\(block.content)\n</pasted_content>"
          case .shortcutSelection:
            return "<pasted_selection>\n\(block.content)\n</pasted_selection>"
          }
        }
        .joined(separator: "\n\n")
      parts.append(pastedSection)
    }
    if !raw.isEmpty {
      parts.append("<typed_by_user>\n\(raw)\n</typed_by_user>")
    }
    let finalContent = parts.joined(separator: "\n\n")
    DebugLogger.log("GEMINI-CHAT: finalContent (first 300 chars): \(String(finalContent.prefix(300)))")

    // Clear input and attachments immediately for responsive UX
    inputText = ""
    errorMessage = nil
    pastedBlocks = []
    pendingScreenshots = []
    pendingFileAttachments = []

    if isSending {
      // Queue for sequential processing while current message is in-flight
      messageQueue.append(QueuedChatMessage(content: finalContent, attachedParts: attachedParts))
      DebugLogger.log("GEMINI-CHAT: Queued message, queue size: \(messageQueue.count)")
      return
    }

    performSend(content: finalContent, attachedParts: attachedParts)
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

  /// Builds the system instruction: current date, base chat prompt, plus optional meeting context (summary + recent transcript).
  private func buildSystemInstruction() -> [String: Any] {
    var text = SystemPromptsStore.shared.loadChatSystemPrompt()
    let formatter = DateFormatter()
    formatter.dateFormat = "EEEE, MMMM d, yyyy"
    formatter.locale = Locale(identifier: "en_US")
    text = "Today's date: \(formatter.string(from: Date())).\n\n\(text)"
    // Only inject live meeting context when the current chat IS the active meeting
    // session — otherwise switching to an unrelated chat would leak meeting content.
    let meetingContext = meetingContextProvider?()
      ?? (isCurrentSessionTheActiveMeeting ? LiveMeetingTranscriptStore.shared.meetingContextForChat(lastMinutes: 5) : nil)
    if let extra = meetingContext, !extra.isEmpty {
      text = "\(text)\n\n---\n\n[Meeting context for calibration only — do not reference directly]\n\(extra)"
    }
    if GoogleAccountOAuthService.shared.isConnected {
      text += "\n\nIMPORTANT — you have three distinct Google integrations:\n1. **Google Calendar** (scheduled events with start/end times): google_calendar_list_events, google_calendar_create_event, google_calendar_delete_event\n2. **Google Tasks** (to-do items, reminders): google_tasks_list_tasklists, google_tasks_list, google_tasks_create, google_tasks_complete, google_tasks_delete\n3. **Gmail** (read-only email access): gmail_search, gmail_read\nWhen the user says 'task', 'to-do', or 'reminder', ALWAYS use google_tasks_* tools. Only use google_calendar_* when the user explicitly asks for a calendar event, meeting, or appointment with a specific time.\nThe user has multiple task lists. Call google_tasks_list_tasklists first to discover available lists and their IDs, then pass the correct task_list_id to other google_tasks_* tools.\nFor Gmail: use gmail_search to find emails (supports Gmail query syntax like 'is:unread', 'from:user@example.com', 'newer_than:2d'). Use gmail_read to get the full body of a specific email. Gmail access is read-only.\nUse the user's local time zone (\(TimeZone.current.identifier)) when creating calendar events. Always confirm details before creating, deleting, or modifying events and tasks."
    }
    return ["parts": [["text": text]]]
  }

  /// Resolves the model ID for the chat window from UserDefaults (Settings > Chat), or subscription fixed model when on subscription.
  private static func resolveOpenGeminiModel() -> String {
    openChatModel.rawValue
  }

  static var openChatModel: PromptModel {
    let raw = UserDefaults.standard.string(forKey: UserDefaultsKeys.selectedChatModel)
      ?? SettingsDefaults.selectedChatModel.rawValue
    let migratedRaw = PromptModel.migrateLegacyPromptRawValue(raw)
    return PromptModel(rawValue: migratedRaw).map { PromptModel.migrateIfDeprecated($0) }
      ?? SettingsDefaults.selectedChatModel
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
      session = target
      messages = target.messages
    }
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

    let isFirstUserMessage = message.role == .user && target.messages.isEmpty
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
      session = target
      messages = target.messages
    }
  }

  private func generateAITitle(sessionId: UUID) async {
    guard let credential = await GeminiCredentialProvider.shared.getCredential() else { return }
    guard let target = store.session(by: sessionId),
          target.messages.count >= 2,
          target.messages[0].role == .user,
          target.messages[1].role == .model else { return }
    let userText = String(target.messages[0].content.prefix(400))
    let modelText = String(target.messages[1].content.prefix(400))
    let prompt = """
      Give this conversation a short title (2–3 words) that captures its core topic. \
      Reply with only the title on a single line — no quotes, no punctuation, no explanation.

      User: \(userText)
      Assistant: \(modelText)
      """
    do {
      let raw = try await apiClient.generateText(
        model: "gemini-2.5-flash-lite", prompt: prompt, credential: credential)
      let title = raw
        .components(separatedBy: .newlines)
        .map {
          $0.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "'", with: "")
        }
        .first { !$0.isEmpty } ?? ""
      guard !title.isEmpty else { return }
      guard var updated = store.session(by: sessionId) else { return }
      updated.title = String(title.prefix(Self.maxSessionTitleLength))
      store.save(updated)
      if sessionId == session.id { session.title = updated.title }
      refreshRecentSessions()
      DebugLogger.log("GEMINI-CHAT: AI title generated for \(sessionId): \(title)")
    } catch {
      DebugLogger.log("GEMINI-CHAT: AI title generation failed, keeping fallback: \(error.localizedDescription)")
    }
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
      let modelCmd = command(Self.modelName)
      appendModelMessage(
        "Current model: **\(cur.displayName)**. Example: `\(modelCmd) 3.1 flash lite` or `\(modelCmd) 2.5 pro`."
      )
    case .applied(let model):
      let migrated = PromptModel.migrateIfDeprecated(model)
      UserDefaults.standard.set(migrated.rawValue, forKey: UserDefaultsKeys.selectedChatModel)
      appendModelMessage("Model set to **\(migrated.displayName)**.")
    case .ambiguous(let candidates):
      let list = candidates.map { "• **\($0.displayName)**" }.joined(separator: "\n")
      appendModelMessage("Multiple matches. Be more specific:\n\(list)")
    case .noMatch(let query):
      appendModelMessage("No model matched \"\(query)\". Try a version and variant, e.g. `3.1 flash lite` or `2.5 pro`.")
    }
    DebugLogger.log("GEMINI-CHAT: /model argument=\(argument) outcome=\(outcome)")
  }

  /// Switches the chat model directly (used by /grok and /gemini shortcuts).
  private func switchToModel(_ model: PromptModel) {
    let migrated = PromptModel.migrateIfDeprecated(model)
    UserDefaults.standard.set(migrated.rawValue, forKey: UserDefaultsKeys.selectedChatModel)
    appendModelMessage("Model set to **\(migrated.displayName)**.")
    DebugLogger.log("GEMINI-CHAT: switchToModel \(migrated.displayName)")
  }

  @MainActor
  private func handleConnectGoogle() async {
    if GoogleAccountOAuthService.shared.isConnected {
      appendModelMessage("Google is already connected. Use `/disconnect-google` to disconnect.")
      return
    }
    appendModelMessage("Opening Google sign-in...")
    do {
      try await GoogleAccountOAuthService.shared.startAuthorization()
      appendModelMessage("Google connected. You can now use Calendar, Tasks, and Gmail.")
    } catch {
      appendModelMessage("Failed to connect Google: \(error.localizedDescription)")
    }
  }

  @MainActor
  private func handleDisconnectGoogle() {
    guard GoogleAccountOAuthService.shared.isConnected else {
      appendModelMessage("Google is not connected. Use `/connect-google` to connect.")
      return
    }
    GoogleAccountOAuthService.shared.disconnect()
    appendModelMessage("Google disconnected.")
  }

  // MARK: - Tab navigation

  private func refreshRecentSessions() {
    recentSessions = store.recentSessions(limit: 20)
    archivedSessionsList = store.archivedSessions()
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
    // Archive instead of delete — session moves to the Archive section in the sidebar
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

  /// Translates a meeting-button tap into the right intent based on current session state:
  /// stop the active meeting, resume a finished meeting, or start a fresh one.
  func handleMeetingButtonTap() {
    if isCurrentSessionTheActiveMeeting {
      NotificationCenter.default.post(name: .chatStopLiveMeeting, object: nil)
    } else if isMeetingActive {
      // A meeting is running on a different session; treat as stop request
      NotificationCenter.default.post(name: .chatStopLiveMeeting, object: nil)
    } else if isCurrentSessionMeeting {
      NotificationCenter.default.post(name: .chatResumeMeeting, object: nil)
    } else {
      NotificationCenter.default.post(name: .chatStartNewMeeting, object: nil)
    }
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
    DebugLogger.log("SIDEBAR: archiveSession done. recentSessions=\(recentSessions.count) archived=\(archivedSessionsList.count) currentSession=\(session.id)")
  }

  func archiveOlderSessions(than date: Date) {
    store.archiveOlderSessions(than: date)
    if store.load().id != session.id { switchToCurrentStoreSession() }
    else { refreshRecentSessions() }
    DebugLogger.log("SIDEBAR: Archived sessions older than \(date)")
  }

  func restoreSession(id: UUID) {
    DebugLogger.log("SIDEBAR: restoreSession id=\(id) currentSession=\(session.id)")
    store.restoreSession(id: id)
    refreshRecentSessions()
    DebugLogger.log("SIDEBAR: restoreSession done. recentSessions=\(recentSessions.count) archived=\(archivedSessionsList.count)")
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

  func deleteOlderSessions(than date: Date) {
    // Stop the active meeting if its owning session will be deleted by this call.
    if isMeetingActive, let mid = meetingSessionId,
       let mSession = store.allSessions().first(where: { $0.id == mid }),
       mSession.lastUpdated < date {
      DebugLogger.log("SIDEBAR: Bulk delete includes active meeting session — stopping recorder first")
      NotificationCenter.default.post(name: .chatStopLiveMeeting, object: nil)
      meetingSessionId = nil
    }
    let count = store.deleteOlderSessions(than: date)
    if store.load().id != session.id { switchToCurrentStoreSession() }
    else { refreshRecentSessions() }
    DebugLogger.log("SIDEBAR: Deleted \(count) sessions older than \(date)")
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

  private func buildContents() -> [[String: Any]] {
    // Send the full conversation history. Gemini 2.x has a 1M–2M token context window,
    // so truncation is only a safeguard against pathological sessions.
    let maxMessages = AppConstants.chatFullHistoryMaxMessages
    let toSend = messages.count > maxMessages
      ? Array(messages.suffix(maxMessages))
      : messages
    return toSend.enumerated().map { index, msg in
      let isLastUserWithImages = index == toSend.count - 1 && msg.role == .user && !msg.attachedImageParts.isEmpty
      if isLastUserWithImages {
        var parts: [[String: Any]] = msg.attachedImageParts.map { part in
          ["inline_data": ["mime_type": part.mimeType ?? "image/png", "data": part.data.base64EncodedString()]]
        }
        if !msg.content.isEmpty {
          parts.append(["text": msg.content])
        }
        return ["role": msg.role.rawValue, "parts": parts]
      }
      return ["role": msg.role.rawValue, "parts": [["text": msg.content]]]
    }
  }

  private func friendlyError(_ error: Error) -> String {
    if let te = error as? TranscriptionError {
      switch te {
      case .invalidAPIKey, .incorrectAPIKey:
        return "Invalid API key. Please check your Google API key in Settings."
      case .rateLimited:
        return "Rate limit reached. Please wait a moment and try again."
      case .quotaExceeded:
        return "API quota exceeded. Please try again later."
      case .networkError(let msg):
        return "Network error: \(msg)"
      default:
        return "Request failed. Please try again."
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
            messageList(scrollActions: scrollActions, containerWidth: geometry.size.width)
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
            ChatInputAreaView(viewModel: viewModel, onTapScreenshotThumbnail: { data in
              previewImageData = data
            })
          }
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(ChatTheme.windowBackground)
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

  private func tabOverflowMenu(sessions: [ChatSession]) -> some View {
    Menu {
      ForEach(sessions.reversed(), id: \.id) { session in
        let title = session.title.flatMap { $0.isEmpty ? nil : $0 } ?? "New chat"
        Button {
          viewModel.switchToSession(id: session.id)
        } label: {
          if session.id == viewModel.currentSessionId {
            Label(title, systemImage: "checkmark")
          } else {
            Text(title)
          }
        }
      }
      Divider()
      Button("Reopen Closed Tab") { viewModel.reopenLastClosedTab() }
        .keyboardShortcut("t", modifiers: [.command, .shift])
    } label: {
      Image(systemName: "chevron.down")
        .font(.system(size: 11, weight: .medium))
        .foregroundColor(ChatTheme.secondaryText)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .help("All tabs")
    .pointerCursorOnHover()
  }

  private func sessionTab(session: ChatSession, width: CGFloat) -> some View {
    let isActive = session.id == viewModel.currentSessionId
    let isProcessing = viewModel.isSendingSession(session.id)
    let title = session.title.flatMap { $0.isEmpty ? nil : $0 } ?? "New chat"

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
      Divider()
      Button("Close Tab") { viewModel.closeTab(id: session.id) }
      Button("Close Other Tabs") { viewModel.closeOtherTabs(keep: session.id) }
      Button("Close Tabs to the Right") { viewModel.closeTabsToTheRight(of: session.id) }
    }
  }

  // MARK: - Message List

  private func messageList(scrollActions: ChatScrollActions, containerWidth: CGFloat) -> some View {
    /// Rounded to 50pt steps so resize doesn't constantly recreate the list (preserves scroll position for small moves).
    let widthBucket = (containerWidth / 50).rounded(.down) * 50
    return ScrollViewReader { proxy in
      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          Color.clear.frame(height: 1).id("listTop")
          if viewModel.messages.isEmpty && !viewModel.isSending {
            emptyStateCommandHints
          }
          ForEach(viewModel.messages) { message in
            MessageBubbleView(message: message, onTapAttachedImage: { previewImageData = $0 })
              .id(message.id)
          }
          ForEach(viewModel.messageQueue) { queued in
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
          if viewModel.isSending {
            TypingIndicatorView()
              .id("typing")
          }
          Color.clear.frame(height: 1).id("listBottom")
        }
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .padding(.bottom, 28)
        .id(widthBucket)
      }
      .onAppear {
        scrollActions.scrollToTop = { scrollToTop(proxy: proxy) }
        scrollActions.scrollToBottom = { scrollToBottom(proxy: proxy) }
        // Scroll to bottom when the chat view first appears so the user sees the latest messages.
        // We do not scroll when new messages arrive — the user stays where they are.
        scrollToBottom(proxy: proxy)
      }
      .task {
        // Layout is not ready on first frame; repeat once so the scroll position sticks.
        try? await Task.sleep(for: .milliseconds(400))
        scrollToBottom(proxy: proxy)
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
      (config.startRecording.displayString, "Speech-to-Text"),
      (config.startPrompting.displayString, "Speech-to-Prompt"),
      (config.openChat.displayString, "Chat"),
      (config.openSettings.displayString, "Settings"),
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
            }
            .buttonStyle(.plain)
          }
        }

        Spacer()

        Button(action: {
          NotificationCenter.default.post(
            name: isRecording ? .chatStopLiveMeeting : .chatResumeMeeting,
            object: nil
          )
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
    .background(ChatTheme.controlBackground)
  }

  private var meetingTranscriptView: some View {
    let liveChunks = LiveMeetingTranscriptStore.shared.chunks
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
    let liveSummary = LiveMeetingTranscriptStore.shared.summary
    let diskSummary = liveSummary.isEmpty ? viewModel.loadMeetingSummaryFromDisk() : nil
    let text = !liveSummary.isEmpty ? liveSummary : diskSummary
    return ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        if let text, !text.isEmpty {
          Text(text)
            .font(.system(size: 14))
            .foregroundColor(ChatTheme.primaryText)
            .textSelection(.enabled)
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
  private var resolvedOpenGeminiModel: PromptModel {
    let migratedRaw = PromptModel.migrateLegacyPromptRawValue(selectedChatModelRaw)
    return PromptModel(rawValue: migratedRaw)
      .map { PromptModel.migrateIfDeprecated($0) }
      ?? SettingsDefaults.selectedChatModel
  }


  var body: some View {
    VStack(spacing: 0) {
      commandSuggestionsOverlay
      inputBar
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
    // Per-session composer drafts: save the current document under the
    // outgoing session id, then load the incoming session's draft (or clear).
  }

  /// Returns true if `word` looks like the user is typing a command (starts with the
  /// configured prefix, and the next character is a letter or end-of-word).
  /// The letter-check avoids false positives for `>` used as a Markdown blockquote
  /// (`> text` should not trigger autocomplete; `>new` should).
  private func isCommandTrigger(_ word: String) -> Bool {
    let cp = viewModel.commandPrefix
    guard word.hasPrefix(cp) else { return false }
    let after = word.dropFirst(cp.count)
    if after.isEmpty { return true }
    return after.first?.isLetter == true
  }

  /// Recognized command names without prefix. Combined with the live prefix at runtime.
  private static let knownCommandNames: Set<String> = [
    "new", "screenshot",
    "settings", "pin", "unpin",
    "grok", "gemini",
    "connect-google", "disconnect-google",
    "meeting"
  ]

  /// Returns true iff `lower` (already lowercased) matches one of the known commands
  /// using the currently-configured prefix.
  private func isKnownCommand(_ lower: String) -> Bool {
    let cp = viewModel.commandPrefix
    guard lower.hasPrefix(cp) else { return false }
    let name = String(lower.dropFirst(cp.count))
    return Self.knownCommandNames.contains(name)
  }

  /// Sends the current composer contents. Recognized slash commands strip just
  /// the slash token (preserving any other attachments / text) and dispatch
  /// through the legacy `sendMessage`. Everything else is sent in document order.
  private func submitComposer() {
    let output = composer.serialize()
    let typed = output.typedText
    let lower = typed.lowercased()
    let modelCmd = viewModel.command("model")
    let isModelCommand = lower == modelCmd || lower.hasPrefix(modelCmd + " ")
    let isRecognizedSlashCommand = isKnownCommand(lower) || isModelCommand
    if isRecognizedSlashCommand {
      if isModelCommand {
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
        typedText: typed,
        finalContent: output.finalContent,
        attachedParts: output.attachedParts)
    }
  }

  /// Tab key in composer: complete a slash-command prefix and dispatch the
  /// matched command without clearing the rest of the composer.
  private func handleTabComplete() -> Bool {
    let word = lastWord
    let cp = viewModel.commandPrefix
    guard word.hasPrefix(cp), !word.isEmpty else { return false }
    let matches = viewModel.suggestedCommands(for: word)
    guard let first = matches.first else { return false }
    // Commands that take an argument: complete inline so the user can type
    // the argument; do not dispatch yet.
    let takesArgument = (first == viewModel.command("model"))
    composer.removeTrailingWord()
    if takesArgument {
      composer.textView?.insertText(first + " ", replacementRange: NSRange(location: NSNotFound, length: 0))
      return true
    }
    Task { await viewModel.sendMessage(userInput: first) }
    return true
  }

  // MARK: - Command autocomplete

  private var commandSuggestionsOverlay: some View {
    Group {
      if isCommandTrigger(lastWord) {
        let suggestions = viewModel.commandSuggestionsForDisplay
          .filter { $0.command.lowercased().hasPrefix(lastWord.lowercased()) }
        if !suggestions.isEmpty {
          VStack(alignment: .leading, spacing: 0) {
            ForEach(suggestions, id: \.command) { item in
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
            }
          }
          .allowsHitTesting(false)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.vertical, 6)
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
        onSubmit: { submitComposer() },
        onCancel: {
          if viewModel.isSending { viewModel.cancelSend() }
        },
        onTabComplete: { handleTabComplete() },
        onClickScreenshot: { data in onTapScreenshotThumbnail(data) }
      )
      .frame(height: inputHeight)

      // Toolbar row below composer: action buttons left, model selector + send right
      HStack(spacing: 4) {
        if !viewModel.singleChatOnly {
          Button(action: { viewModel.createNewSession() }) {
            HStack(spacing: 4) {
              Image(systemName: "square.and.pencil").font(.caption)
              Text("New chat").font(.caption)
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

        Button(action: { viewModel.attachFile() }) {
          HStack(spacing: 4) {
            Image(systemName: "paperclip").font(.caption)
            Text("Attach").font(.caption)
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
            Text("Screenshot").font(.caption)
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

        Button(action: {
          viewModel.handleMeetingButtonTap()
        }) {
          HStack(spacing: 4) {
            Image(systemName: viewModel.isMeetingActive ? "record.circle" : "record.circle")
              .font(.caption)
              .foregroundColor(viewModel.isMeetingActive ? .red : ChatTheme.secondaryText)
            Text(viewModel.isMeetingActive ? "Stop meeting" : "Meeting")
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
          ForEach(PromptModel.allCases, id: \.self) { model in
            Button(action: {
              selectedChatModelRaw = model.rawValue
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

        // Queue count indicator
        if viewModel.isSending && !viewModel.messageQueue.isEmpty {
          Text("\(viewModel.messageQueue.count) queued")
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
    .background(ChatTheme.controlBackground)
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

  // (Legacy chip helpers removed — attachments are now inline in the composer.)
  #if false
  private func screenshotChip(data: Data, index: Int) -> some View {
    let isFocused = focusedAttachment == .screenshot(index)
    let label = viewModel.pendingScreenshots.count == 1 ? "Screenshot" : "Screenshot \(index + 1)"
    return HStack(spacing: 5) {
      if let nsImage = NSImage(data: data) {
        Image(nsImage: nsImage)
          .resizable()
          .aspectRatio(contentMode: .fill)
          .frame(width: 22, height: 16)
          .clipped()
          .clipShape(RoundedRectangle(cornerRadius: 3))
          .onTapGesture { onTapScreenshotThumbnail(data) }
          .help("Click to view full size")
      } else {
        Image(systemName: "camera.viewfinder")
          .font(.caption)
          .foregroundColor(ChatTheme.secondaryText)
      }
      Text(label)
        .font(.caption)
        .foregroundColor(ChatTheme.primaryText)
      Button(action: { viewModel.removePendingScreenshot(at: index); inputFocused = true }) {
        Image(systemName: "xmark")
          .font(.system(size: 8, weight: .bold))
          .foregroundColor(ChatTheme.secondaryText)
      }
      .buttonStyle(.plain)
      .help("Remove screenshot")
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 5)
    .background(ChatTheme.windowBackground.opacity(0.6))
    .clipShape(RoundedRectangle(cornerRadius: 8))
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .strokeBorder(
          isFocused ? Color.accentColor : ChatTheme.primaryText.opacity(ChatTheme.borderOpacity),
          lineWidth: isFocused ? 1.5 : 1)
    )
    .focusable()
    .focused($focusedAttachment, equals: .screenshot(index))
    .onKeyPress(.deleteForward)  { viewModel.removePendingScreenshot(at: index); inputFocused = true; return .handled }
    .onKeyPress(.delete)         { viewModel.removePendingScreenshot(at: index); inputFocused = true; return .handled }
    .accessibilityLabel("\(label) attachment. Press Delete to remove.")
  }

  private var fileChip: some View {
    let file = viewModel.pendingFileAttachments.first
    let isFocused = focusedAttachment == .file
    return HStack(spacing: 5) {
      if let f = file, f.mimeType.hasPrefix("image/"), let img = NSImage(data: f.data) {
        Image(nsImage: img)
          .resizable()
          .aspectRatio(contentMode: .fill)
          .frame(width: 22, height: 16)
          .clipped()
          .clipShape(RoundedRectangle(cornerRadius: 3))
      } else {
        Image(systemName: file?.mimeType == "application/pdf" ? "doc.richtext" : "doc")
          .font(.caption)
          .foregroundColor(ChatTheme.secondaryText)
      }
      Text(file?.filename ?? "File")
        .font(.caption)
        .foregroundColor(ChatTheme.primaryText)
        .lineLimit(1)
        .frame(maxWidth: 120, alignment: .leading)
      Button(action: { viewModel.clearPendingFiles(); inputFocused = true }) {
        Image(systemName: "xmark")
          .font(.system(size: 8, weight: .bold))
          .foregroundColor(ChatTheme.secondaryText)
      }
      .buttonStyle(.plain)
      .help("Remove attachment")
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 5)
    .background(ChatTheme.windowBackground.opacity(0.6))
    .clipShape(RoundedRectangle(cornerRadius: 8))
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .strokeBorder(
          isFocused ? Color.accentColor : ChatTheme.primaryText.opacity(ChatTheme.borderOpacity),
          lineWidth: isFocused ? 1.5 : 1)
    )
    .focusable()
    .focused($focusedAttachment, equals: .file)
    .onKeyPress(.deleteForward)  { viewModel.clearPendingFiles(); inputFocused = true; return .handled }
    .onKeyPress(.delete)         { viewModel.clearPendingFiles(); inputFocused = true; return .handled }
    .accessibilityLabel("File attachment \(file?.filename ?? ""). Press Delete to remove.")
  }

  private func pastedBlockChip(_ block: ChatViewModel.PastedBlock) -> some View {
    let isFocused = focusedAttachment == .pastedBlock(block.id)
    let chipLabel: String
    let chipIcon: String
    let removeHelp: String
    let a11yLabel: String
    switch block.kind {
    case .shortcutSelection:
      chipLabel = "Selection · \(block.lineCount) lines"
      chipIcon = "text.cursor"
      removeHelp = "Remove selection"
      a11yLabel = "Text from selection, \(block.lineCount) lines. Press Delete to remove."
    case .largePaste:
      chipLabel = "Pasted · \(block.lineCount) lines"
      chipIcon = "doc.plaintext"
      removeHelp = "Remove pasted text"
      a11yLabel = "Pasted content, \(block.lineCount) lines. Press Delete to remove."
    }
    return HStack(spacing: 5) {
      Image(systemName: chipIcon)
        .font(.caption)
        .foregroundColor(ChatTheme.secondaryText)
      Text(chipLabel)
        .font(.caption)
        .foregroundColor(ChatTheme.primaryText)
      Button(action: { viewModel.removePastedBlock(id: block.id); inputFocused = true }) {
        Image(systemName: "xmark")
          .font(.system(size: 8, weight: .bold))
          .foregroundColor(ChatTheme.secondaryText)
      }
      .buttonStyle(.plain)
      .help(removeHelp)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 5)
    .background(ChatTheme.windowBackground.opacity(0.6))
    .clipShape(RoundedRectangle(cornerRadius: 8))
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .strokeBorder(
          isFocused ? Color.accentColor : ChatTheme.primaryText.opacity(ChatTheme.borderOpacity),
          lineWidth: isFocused ? 1.5 : 1)
    )
    .focusable()
    .focused($focusedAttachment, equals: .pastedBlock(block.id))
    .onKeyPress(.deleteForward)  { viewModel.removePastedBlock(id: block.id); inputFocused = true; return .handled }
    .onKeyPress(.delete)         { viewModel.removePastedBlock(id: block.id); inputFocused = true; return .handled }
    .accessibilityLabel(a11yLabel)
  }
  #endif

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

// MARK: - Markdown Table / Block types (shared via MarkdownBlockView.swift)

private enum ReplyContentBlock {
  case text(AttributedString)
  case bulletList([AttributedString]) // each item is one bullet
  case table(ParsedTable)
  case separator
  case codeBlock(String, String?) // code content, optional language
  case image(Data) // inline image data (e.g. from Gemini image generation)
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

/// One selectable prose region, or a non-text block (tables/code/images stay separate so layout stays correct).
private enum ModelReplyRenderSegment {
  case prose(AttributedString)
  case table(ParsedTable)
  case codeBlock(String, String?)
  case image(Data)
}

private struct ModelReplyView: View {
  let content: String
  let sources: [GroundingSource]
  let groundingSupports: [GroundingSupport]

  var body: some View {
    let blocks = Self.buildReplyBlocks(content: content, sources: sources, groundingSupports: groundingSupports)
    let segments = Self.mergedSegments(from: blocks)
    return VStack(alignment: .leading, spacing: 18) {
      ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
        switch segment {
        case .prose(let attrStr):
          Text(attrStr)
            .font(.system(size: 16))
            .lineSpacing(8)
            .foregroundColor(ChatTheme.primaryText)
        case .table(let parsed):
          MarkdownTableView(headers: parsed.headers, rows: parsed.rows)
        case .codeBlock(let code, let language):
          CodeBlockView(code: code, language: language)
        case .image(let imageData):
          if let nsImage = NSImage(data: imageData) {
            Image(nsImage: nsImage)
              .resizable()
              .scaledToFit()
              .frame(maxWidth: .infinity)
              .clipShape(RoundedRectangle(cornerRadius: 8))
          }
        }
      }
    }
    .textSelection(.enabled)
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
    dashes.foregroundColor = ChatTheme.primaryText.opacity(0.14)
    prose.append(dashes)
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
      case .image(let data):
        flushProse()
        segments.append(.image(data))
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
          bullet.font = .system(size: 16, weight: .regular)
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

  private static func contentHasTable(_ content: String) -> Bool {
    content.components(separatedBy: "\n\n").contains {
      MarkdownParsing.looksLikeMarkdownTable($0.trimmingCharacters(in: .whitespacesAndNewlines))
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
      if MarkdownParsing.isSeparatorParagraph(trimmed) {
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
          for idx in para.chunkIndices where idx < sources.count {
            let oneBased = idx + 1
            var markerAttr = AttributedString(" [\(oneBased)]")
            markerAttr.font = .system(size: 14)
            if let url = URL(string: sources[idx].uri) { markerAttr.link = url }
            lastItem.append(markerAttr)
          }
          items.append(lastItem)
          blocks.append(.bulletList(items))
        }
      } else if let (headingPart, bulletPart) = splitHeadingAndBullets(trimmed) {
        // Heading followed by bullets — heading gets citations, bullets rendered separately
        var headingAttr = buildSingleParagraphAttributed(headingPart, options: options)
        for idx in para.chunkIndices where idx < sources.count {
          let oneBased = idx + 1
          var markerAttr = AttributedString(" [\(oneBased)]")
          markerAttr.font = .system(size: 14)
          if let url = URL(string: sources[idx].uri) { markerAttr.link = url }
          headingAttr.append(markerAttr)
        }
        blocks.append(.text(headingAttr))
        if let items = parseBulletItems(bulletPart) {
          blocks.append(.bulletList(items))
        } else {
          blocks.append(.text(buildSingleParagraphAttributed(bulletPart, options: options)))
        }
      } else {
        var attrText = buildSingleParagraphAttributed(trimmed, options: options)
        for idx in para.chunkIndices where idx < sources.count {
          let oneBased = idx + 1
          var markerAttr = AttributedString(" [\(oneBased)]")
          markerAttr.font = .system(size: 14)
          if let url = URL(string: sources[idx].uri) { markerAttr.link = url }
          attrText.append(markerAttr)
        }
        blocks.append(.text(attrText))
      }
    }
    return blocks.isEmpty ? [.text(AttributedString(content))] : blocks
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
      if let idx = CodeBlockExtractor.placeholderIndex(trimmed), idx < codeBlocks.count {
        let cb = codeBlocks[idx]
        if cb.language == "markdown" && Self.looksLikeStructuredAnswer(cb.code) {
          blocks.append(contentsOf: buildContentOnlyBlocks(content: cb.code, options: options))
        } else {
          blocks.append(.codeBlock(cb.code, cb.language))
        }
      } else if let imageData = Self.extractInlineImageData(trimmed) {
        blocks.append(.image(imageData))
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
    return blocks.isEmpty ? [.text(AttributedString(content))] : blocks
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

  /// Checks if a paragraph is a Gemini inline image marker and returns the decoded image data.
  private static func extractInlineImageData(_ trimmed: String) -> Data? {
    let prefix = GeminiAPIClient.imageMarkerPrefix
    let suffix = GeminiAPIClient.imageMarkerSuffix
    guard trimmed.hasPrefix(prefix), trimmed.hasSuffix(suffix) else { return nil }
    // Format: ⟦GEMINI_IMG:base64data:mimetype⟧
    let inner = String(trimmed.dropFirst(prefix.count).dropLast(suffix.count))
    // Split on last ":" to separate base64 from mimetype (base64 may contain "+" but not ":")
    guard let lastColon = inner.lastIndex(of: ":") else { return nil }
    let base64 = String(inner[inner.startIndex..<lastColon])
    guard !base64.isEmpty else { return nil }
    return Data(base64Encoded: base64)
  }

  /// Parses a paragraph block that consists entirely of bullet/numbered-list lines.
  /// Returns individual attributed strings for each bullet item, or nil if not a bullet block.
  private static func parseBulletItems(_ trimmed: String) -> [AttributedString]? {
    let lines = trimmed.components(separatedBy: .newlines)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
    guard !lines.isEmpty, lines.allSatisfy({ MarkdownParsing.parseBullet($0) != nil }) else { return nil }
    let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    return lines.map { line in
      let rawContent = MarkdownParsing.parseBullet(line)!.trimmingCharacters(in: .whitespaces)
      let content = MarkdownParsing.renderLatexToUnicode(rawContent)
      var contentAttr = MarkdownParsing.inlineAttributedString(content, options: opts)
      contentAttr.font = .system(size: 16, weight: .regular)
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
      headingAttr.font = MarkdownParsing.fontForHeadingLevel(level, baseSize: 16)
      if !bodyPart.isEmpty {
        headingAttr.append(AttributedString("\n\n"))
        var bodyAttr = MarkdownParsing.inlineAttributedString(bodyPart, options: options)
        bodyAttr.font = .system(size: 16, weight: .regular)
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

  private static func buildAttributedReply(
    content: String,
    sources: [GroundingSource],
    groundingSupports: [GroundingSupport]
  ) -> AttributedString {
    let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    if groundingSupports.isEmpty || sources.isEmpty {
      return buildAttributedReplyContentOnly(content: content, options: options)
    }
    let paragraphs = ParagraphCitationBuilder.buildParagraphs(content: content, supports: groundingSupports, sourcesCount: sources.count)
    var result = AttributedString()
    let paragraphSeparator = AttributedString("\n\n")
    for para in paragraphs {
      let trimmed = para.text.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.isEmpty { continue }
      if !result.description.isEmpty { result.append(paragraphSeparator) }
      if MarkdownParsing.isSeparatorParagraph(trimmed) {
        var lineAttr = AttributedString(MarkdownParsing.separatorLineContent)
        lineAttr.foregroundColor = ChatTheme.primaryText.opacity(0.4)
        result.append(lineAttr)
        continue
      }
      let attrText = buildAttributedReplyContentOnly(content: para.text, options: options)
      result.append(attrText)
      for idx in para.chunkIndices {
        let oneBased = idx + 1
        let marker = " [\(oneBased)]"
        var markerAttr = AttributedString(marker)
        markerAttr.font = .system(size: 14)
        if let url = URL(string: sources[idx].uri) {
          markerAttr.link = url
        }
        result.append(markerAttr)
      }
    }
    return result.description.isEmpty
      ? buildAttributedReplyContentOnly(content: content, options: options)
      : result
  }

  private static func buildAttributedReplyContentOnly(content: String, options: AttributedString.MarkdownParsingOptions) -> AttributedString {
    // Extract fenced code blocks before splitting
    let (processed, codeBlocks) = CodeBlockExtractor.extract(from: content)
    let paragraphs = MarkdownParsing.normalizeMarkdownParagraphBreaks(processed).components(separatedBy: "\n\n")
    var result = AttributedString()
    let separator = AttributedString("\n\n")
    for (index, para) in paragraphs.enumerated() {
      let trimmed = para.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.isEmpty { continue }
      if index > 0 { result.append(separator) }
      if let idx = CodeBlockExtractor.placeholderIndex(trimmed), idx < codeBlocks.count {
        let cb = codeBlocks[idx]
        if cb.language == "markdown" && looksLikeStructuredAnswer(cb.code) {
          let unwrapped = buildAttributedReplyContentOnly(content: cb.code, options: options)
          result.append(unwrapped)
          continue
        }
        let label = cb.language.map { "[\($0)] " } ?? ""
        var attr = AttributedString("\(label)\(cb.code)")
        attr.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        result.append(attr)
      } else if trimmed.hasPrefix(GeminiAPIClient.imageMarkerPrefix) && trimmed.hasSuffix(GeminiAPIClient.imageMarkerSuffix) {
        // Inline image marker — skip in AttributedString fallback path (rendered in SwiftUI path)
        var attr = AttributedString("[Image]")
        attr.font = .system(size: 14, weight: .medium)
        attr.foregroundColor = ChatTheme.primaryText.opacity(0.5)
        result.append(attr)
      } else if MarkdownParsing.isSeparatorParagraph(trimmed) {
        var lineAttr = AttributedString(MarkdownParsing.separatorLineContent)
        lineAttr.foregroundColor = ChatTheme.primaryText.opacity(0.4)
        result.append(lineAttr)
      } else if let (level, title) = MarkdownParsing.parseATXHeading(trimmed) {
        let parts = trimmed.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let bodyPart = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
        var headingAttr = MarkdownParsing.inlineAttributedString(title, options: options)
        headingAttr.font = MarkdownParsing.fontForHeadingLevel(level, baseSize: 16)
        result.append(headingAttr)
        if !bodyPart.isEmpty {
          result.append(AttributedString("\n\n"))
          var bodyAttr = MarkdownParsing.inlineAttributedString(bodyPart, options: options)
          bodyAttr.font = .system(size: 16, weight: .regular)
          result.append(bodyAttr)
        }
      } else if MarkdownParsing.looksLikeMarkdownTable(trimmed) {
        var tableAttr = AttributedString(trimmed)
        tableAttr.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        result.append(tableAttr)
      } else if let bulletItems = parseBulletItems(trimmed) {
        // Flatten bullet items into a single AttributedString for this legacy path
        for (i, item) in bulletItems.enumerated() {
          if i > 0 { result.append(AttributedString("\n")) }
          var bullet = AttributedString("• ")
          bullet.font = .system(size: 16, weight: .regular)
          result.append(bullet)
          result.append(item)
        }
      } else {
        let latexProcessed = MarkdownParsing.renderLatexToUnicode(trimmed)
        let fullOptions = AttributedString.MarkdownParsingOptions(interpretedSyntax: .full)
        var attr = (try? AttributedString(markdown: latexProcessed, options: fullOptions)) ?? AttributedString(latexProcessed)
        attr.font = .system(size: 16, weight: .regular)
        result.append(attr)
      }
    }
    if result.description.isEmpty {
      return (try? AttributedString(markdown: content)) ?? AttributedString(content)
    }
    return result
  }
}

// MARK: - Code Block View

private struct CodeBlockView: View {
  let code: String
  let language: String?
  @State private var copied = false

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

      // Code content
      ScrollView(.horizontal, showsIndicators: false) {
        Text(code)
          .font(.system(size: 13, design: .monospaced))
          .foregroundColor(ChatTheme.primaryText.opacity(0.9))
          .textSelection(.enabled)
          .padding(14)
      }
    }
    .background(Color.black.opacity(0.25))
    .clipShape(RoundedRectangle(cornerRadius: 8))
  }
}

// MARK: - Copy Reply Button (under model replies)

private struct CopyReplyButtonView: View {
  let messageContent: String
  @State private var isHovered = false

  var body: some View {
    Button {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(messageContent, forType: .string)
    } label: {
      HStack(spacing: 5) {
        Image(systemName: "doc.on.doc")
          .font(.system(size: 12))
        Text("Copy")
          .font(.caption)
      }
      .foregroundColor(isHovered ? ChatTheme.primaryText : ChatTheme.secondaryText)
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .frame(minHeight: 28)
      .contentShape(Rectangle())
      .background(
        RoundedRectangle(cornerRadius: 6)
          .fill(isHovered ? ChatTheme.controlBackground.opacity(0.9) : ChatTheme.controlBackground.opacity(0.5))
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

private struct MessageBubbleView: View {
  let message: ChatMessage
  var onTapAttachedImage: ((Data) -> Void)? = nil

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
          Text(parsed.userText)
            .font(.system(size: 16))
            .foregroundColor(ChatTheme.primaryText)
            .textSelection(.enabled)
        }
        if !message.attachedImageParts.isEmpty {
          Text(message.attachedImageParts.count == 1
               ? (message.attachedImageParts[0].filename ?? "1 attachment")
               : "\(message.attachedImageParts.count) attachments")
            .font(.caption)
            .foregroundColor(ChatTheme.primaryText.opacity(0.6))
        }
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 12)
      .contentShape(Rectangle())
      .background(
        RoundedRectangle(cornerRadius: 14)
          .fill(ChatTheme.userBubbleBackground)
      )
      .onHover { inside in
        if inside {
          NSCursor.iBeam.push()
        } else {
          NSCursor.pop()
        }
      }
    } else {
      ModelReplyView(
        content: message.content,
        sources: message.sources,
        groundingSupports: message.groundingSupports)
    }
  }

  private var userCopyButtonRow: some View {
    let parsed = parseUserMessagePastedXML(message.content)
    let text = parsed.userText.trimmingCharacters(in: .whitespacesAndNewlines)
    return Group {
      if !text.isEmpty {
        HStack(spacing: 8) {
          CopyReplyButtonView(messageContent: text)
        }
        .padding(.top, 4)
      }
    }
  }

  /// Copy action row for assistant replies; hidden when content is empty.
  private var assistantCopyButtonRow: some View {
    let trimmed = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
    return Group {
      if !trimmed.isEmpty {
        HStack(spacing: 8) {
          CopyReplyButtonView(messageContent: message.content)
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
