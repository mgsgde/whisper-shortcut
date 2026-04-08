import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - ViewModel

@MainActor
class GeminiChatViewModel: ObservableObject {
  @Published var messages: [ChatMessage] = []
  @Published var inputText: String = ""
  @Published private(set) var sendingSessionIds: Set<UUID> = []
  /// True when the currently visible session has an in-flight request.
  var isSending: Bool { sendingSessionIds.contains(session.id) }
  @Published var errorMessage: String? = nil
  @Published var pendingScreenshots: [Data] = []
  @Published var screenshotCaptureInProgress: Bool = false
  @Published var pendingFileAttachment: PendingFile? = nil
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
      /// Text captured via Open Gemini shortcut (front-app selection).
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
  @Published private(set) var currentSessionId: UUID = UUID()

  /// In-memory ring buffer of recently closed sessions for Cmd+Shift+T undo.
  /// Only sessions that had at least one message are stored — empty tabs are
  /// considered disposable and not worth restoring.
  private var recentlyClosedSessions: [ChatSession] = []
  private static let recentlyClosedCapacity = 10

  private var session: ChatSession
  private let store: GeminiChatSessionStore
  private let apiClient = GeminiAPIClient()

  /// In-flight send tasks keyed by session ID — multiple sessions can be sending simultaneously.
  private var sendTasks: [UUID: Task<Void, Never>] = [:]
  /// True while a background memory update is in flight. Prevents concurrent updates.
  private var isUpdatingMemory = false
  /// Set when the last memory update failed. Blocks retries for 60 seconds.
  private var memoryUpdateFailureTime: Date? = nil

  /// Returns true if the given session has an in-flight request (for tab spinner).
  func isSendingSession(_ id: UUID) -> Bool { sendingSessionIds.contains(id) }
  /// Maximum length for auto-generated session title from first user message.
  private static let maxSessionTitleLength = 50
  /// Commands are slash-only (e.g. /stop, /new); do not use hotkeys/shortcuts for command actions.
  private static let newChatCommand = "/new"
  private static let backChatCommand = "/back"
  private static let nextChatCommand = "/next"
  private static let clearChatCommands = ["/clear"]
  static let screenshotCommand = "/screenshot"
  private static let stopCommand = "/stop"
  private static let settingsCommand = "/settings"
  private static let pinCommand = "/pin"
  private static let unpinCommand = "/unpin"
  private static let rememberCommand = "/remember"
  private static let contextCommand = "/context"
  private static let modelCommand = "/model"

  /// All slash commands with descriptions for autocomplete.
  static let commandSuggestions: [(command: String, description: String)] = [
    ("/new", "Start a new chat (previous chat stays in history)"),
    ("/back", "Navigate to the previous chat"),
    ("/next", "Navigate to the next chat"),
    ("/clear", "Clear current chat messages"),
    ("/screenshot", "Add a screenshot to your next message (can add multiple)"),
    ("/remember", "Trigger an immediate session memory update"),
    ("/context", "Show or edit your context (e.g. /context always use bullet points)"),
    ("/model", "Switch Open Gemini model (e.g. /model 3.1 flash lite)"),
    ("/settings", "Open Settings"),
    ("/pin", "Toggle whether the window stays open when losing focus"),
    ("/unpin", "Make the window close when losing focus"),
    ("/stop", "Stop sending (while a message is being sent)")
  ]

  /// Commands to show in UI (excludes /new, /back, /next when single-chat mode).
  var commandSuggestionsForDisplay: [(command: String, description: String)] {
    if singleChatOnly {
      return Self.commandSuggestions.filter { !["/new", "/back", "/next"].contains($0.command) }
    }
    return Self.commandSuggestions
  }

  /// Returns commands whose command string matches the given prefix (e.g. "/" or "/sc").
  func suggestedCommands(for input: String) -> [String] {
    let prefix = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard prefix.hasPrefix("/") else { return [] }
    return commandSuggestionsForDisplay
      .map(\.command)
      .filter { $0.lowercased().hasPrefix(prefix) || prefix.isEmpty }
  }

  var canGoBack: Bool { store.canGoBack() }
  var canGoForward: Bool { store.canGoForward() }

  /// When non-nil, this provider supplies extra context (e.g. meeting summary + recent transcript) appended to the system instruction. Used by the Meeting Chat window.
  private let meetingContextProvider: (() -> String?)?
  /// When true, exactly one chat per meeting: no tabs, no /new /back /next, no "New chat" button.
  let singleChatOnly: Bool

  init(meetingContextProvider: (() -> String?)? = nil, store: GeminiChatSessionStore = .shared, singleChatOnly: Bool = false) {
    self.meetingContextProvider = meetingContextProvider
    self.store = store
    self.singleChatOnly = singleChatOnly
    session = store.load()
    currentSessionId = session.id
    messages = session.messages
    recentSessions = store.recentSessions(limit: 20)
  }

  func createNewSession() {
    // Reuse the current tab if it is already an empty "New chat" — avoids
    // spawning a row of identical empty tabs when the user hits Cmd+N
    // repeatedly. The user's composer draft is global and unaffected.
    if session.messages.isEmpty && (session.title?.isEmpty ?? true) {
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

  func goBack() {
    guard store.navigateBack() != nil else { return }
    switchToCurrentStoreSession()
    DebugLogger.log("GEMINI-CHAT: Navigated back to \(session.id)")
  }

  func goForward() {
    guard store.navigateForward() != nil else { return }
    switchToCurrentStoreSession()
    DebugLogger.log("GEMINI-CHAT: Navigated forward to \(session.id)")
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

  /// Sends a message whose content and attachments were already assembled by the inline
  /// composer in document order. Handles slash commands via `typedText`, bypasses the
  /// VM-side chip model, and otherwise queues / dispatches via `performSend`.
  func sendComposed(typedText: String, finalContent: String, attachedParts: [AttachedImagePart]) async {
    let raw = typedText.trimmingCharacters(in: .whitespacesAndNewlines)
    let lower = raw.lowercased()

    if lower == Self.stopCommand {
      cancelSend()
      return
    }

    // /context with possible argument — only when no other content.
    if attachedParts.isEmpty && !finalContent.contains("<pasted_") {
      if lower == Self.contextCommand {
        await handleContextCommand(instruction: nil); return
      } else if lower.hasPrefix(Self.contextCommand + " ") {
        let instruction = String(raw.dropFirst(Self.contextCommand.count + 1)).trimmingCharacters(in: .whitespaces)
        if !instruction.isEmpty {
          await handleContextCommand(instruction: instruction); return
        }
      }
    }

    // Bare slash commands — never carry attachments, never queue.
    if attachedParts.isEmpty && !finalContent.contains("<pasted_") {
      if lower == Self.newChatCommand || lower == Self.backChatCommand || lower == Self.nextChatCommand
          || Self.clearChatCommands.contains(lower) || lower == Self.screenshotCommand
          || lower == Self.settingsCommand || lower == Self.pinCommand || lower == Self.unpinCommand
          || lower == Self.rememberCommand {
        if lower == Self.newChatCommand { if !singleChatOnly { createNewSession() } }
        else if lower == Self.backChatCommand { if !singleChatOnly { goBack() } }
        else if lower == Self.nextChatCommand { if !singleChatOnly { goForward() } }
        else if Self.clearChatCommands.contains(lower) { clearMessages() }
        else if lower == Self.settingsCommand { SettingsManager.shared.showSettings() }
        else if lower == Self.pinCommand { togglePin() }
        else if lower == Self.unpinCommand { unpin() }
        else if lower == Self.rememberCommand {
          guard !session.messages.isEmpty else { return }
          Task { await updateSessionMemory() }
        }
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
    let data = await GeminiWindowManager.shared.captureScreenExcludingGeminiWindow()
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

  func clearPendingFile() {
    pendingFileAttachment = nil
  }

  /// Clears text/paste state and file attachment before shortcut-driven prefill from selection. Pending screenshots are kept.
  func resetPendingComposerContent() {
    pastedBlocks = []
    pendingFileAttachment = nil
    inputText = ""
  }

  func attachFile() {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.allowedContentTypes = [.pdf, .png, .jpeg, .gif, .webP, .plainText]
    panel.message = "Select a file to attach to your next message"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    guard let data = try? Data(contentsOf: url) else { return }
    let mimeType = Self.mimeType(for: url)
    pendingFileAttachment = PendingFile(data: data, mimeType: mimeType, filename: url.lastPathComponent)
    pendingScreenshots = []
    DebugLogger.log("GEMINI-CHAT: File attached: \(url.lastPathComponent) (\(mimeType), \(data.count) bytes)")
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
    let closeOnFocusLoss = UserDefaults.standard.object(forKey: UserDefaultsKeys.geminiCloseOnFocusLoss) as? Bool
      ?? SettingsDefaults.geminiCloseOnFocusLoss
    let newValue = !closeOnFocusLoss
    UserDefaults.standard.set(newValue, forKey: UserDefaultsKeys.geminiCloseOnFocusLoss)
    let nowPinned = !newValue
    DebugLogger.log("GEMINI-CHAT: /pin — window is now \(nowPinned ? "pinned (stays open)" : "unpinned (closes on focus loss)")")
  }

  func unpin() {
    UserDefaults.standard.set(true, forKey: UserDefaultsKeys.geminiCloseOnFocusLoss)
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
      guard let credential = await GeminiCredentialProvider.shared.getCredential() else {
        errorMessage = "Add your Google API key in Settings or sign in with Google to use Gemini Chat."
        return
      }
      let userMsg = ChatMessage(role: .user, content: content, attachedImageParts: attachedParts)
      appendMessage(userMsg, toSessionId: sessionId)
      var currentContents = buildContents()
      do {
        let model = Self.resolveOpenGeminiModel()
        // Placeholder model message that we update as stream deltas arrive.
        let placeholderId = UUID()
        let placeholder = ChatMessage(id: placeholderId, role: .model, content: "")
        appendMessage(placeholder, toSessionId: sessionId)

        var accumulated = ""
        var finalSources: [GroundingSource] = []
        var finalSupports: [GroundingSupport] = []

        // Function-call loop: if Gemini calls a local tool we execute it,
        // append the call + response turns to `currentContents`, and re-stream.
        // Hard cap to prevent runaway tool loops.
        let maxToolRounds = 5
        toolLoop: for round in 0..<(maxToolRounds + 1) {
          var pendingCalls: [(name: String, args: [String: Any])] = []
          var sawFinished = false
          let stream = apiClient.sendChatMessageStream(
            model: model,
            contents: currentContents,
            credential: credential,
            useGrounding: true,
            systemInstruction: self.buildSystemInstruction(),
            functionDeclarations: GeminiChatToolRegistry.functionDeclarations)
          for try await event in stream {
            try Task.checkCancellation()
            switch event {
            case .textDelta(let delta):
              accumulated += delta
              await MainActor.run {
                self.updateStreamingMessage(
                  id: placeholderId, sessionId: sessionId,
                  content: accumulated, sources: [], supports: [])
              }
            case .functionCall(let name, let args):
              pendingCalls.append((name, args))
            case .finished(let sources, let supports, _):
              finalSources = sources
              finalSupports = supports
              sawFinished = true
            }
          }
          if pendingCalls.isEmpty {
            break toolLoop
          }
          if round == maxToolRounds {
            DebugLogger.logWarning("GEMINI-CHAT: tool loop exceeded \(maxToolRounds) rounds — stopping")
            break toolLoop
          }
          _ = sawFinished
          // Append model turn with the functionCall parts, then a user turn with
          // matching functionResponse parts. Gemini requires this exact shape.
          let callParts: [[String: Any]] = pendingCalls.map { call in
            ["functionCall": ["name": call.name, "args": call.args]]
          }
          currentContents.append(["role": "model", "parts": callParts])
          var responseParts: [[String: Any]] = []
          for call in pendingCalls {
            let result = await MainActor.run {
              GeminiChatToolRegistry.execute(name: call.name, args: call.args)
            }
            responseParts.append([
              "functionResponse": [
                "name": call.name,
                "response": result,
              ]
            ])
          }
          currentContents.append(["role": "user", "parts": responseParts])
          DebugLogger.log("GEMINI-CHAT: executed \(pendingCalls.count) tool call(s), continuing stream")
        }

        // Finalize placeholder with grounding metadata.
        await MainActor.run {
          self.updateStreamingMessage(
            id: placeholderId, sessionId: sessionId,
            content: accumulated, sources: finalSources, supports: finalSupports)
        }
        let result = (text: accumulated, sources: finalSources, supports: finalSupports)
        ContextLogger.shared.logGeminiChat(userMessage: content, modelResponse: result.text, model: model)
        if let s = store.session(by: sessionId), s.messages.count == 2 {
          Task { await generateAITitle(sessionId: sessionId) }
        }
        // Rolling memory is no longer triggered automatically — we send the full
        // conversation history each turn and rely on Gemini's 1–2M context window.
        // The `/remember` slash command still runs on-demand compaction as a
        // fallback for pathologically large sessions.
      } catch is CancellationError {
        DebugLogger.log("GEMINI-CHAT: Send cancelled by user")
      } catch {
        if sessionId == session.id { errorMessage = friendlyError(error) }
        DebugLogger.logError("GEMINI-CHAT: \(error.localizedDescription)")
      }
    }
    sendTasks[sessionId] = task
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
    if lower == Self.stopCommand {
      inputText = ""
      cancelSend()
      return
    }
    let hasContent = !raw.isEmpty || !pendingScreenshots.isEmpty || pendingFileAttachment != nil || !pastedBlocks.isEmpty
    guard hasContent else { return }

    // /context command (show or update system prompts)
    if lower == Self.contextCommand {
      inputText = ""
      await handleContextCommand(instruction: nil)
      return
    } else if lower.hasPrefix(Self.contextCommand + " ") {
      let instruction = String(raw.dropFirst(Self.contextCommand.count + 1)).trimmingCharacters(in: .whitespaces)
      inputText = ""
      if !instruction.isEmpty {
        await handleContextCommand(instruction: instruction)
        return
      }
    }

    // /model command (switch Open Gemini model with fuzzy matching)
    if lower == Self.modelCommand || lower.hasPrefix(Self.modelCommand + " ") {
      inputText = ""
      let arg = lower == Self.modelCommand
        ? ""
        : String(raw.dropFirst(Self.modelCommand.count + 1)).trimmingCharacters(in: .whitespaces)
      handleModelCommand(argument: arg)
      return
    }

    // Slash commands: always immediate, never queued
    if lower == Self.newChatCommand || lower == Self.backChatCommand || lower == Self.nextChatCommand
        || Self.clearChatCommands.contains(lower) || lower == Self.screenshotCommand
        || lower == Self.settingsCommand || lower == Self.pinCommand || lower == Self.unpinCommand
        || lower == Self.rememberCommand {
      inputText = ""
      if lower == Self.newChatCommand { if !singleChatOnly { createNewSession() } }
      else if lower == Self.backChatCommand { if !singleChatOnly { goBack() } }
      else if lower == Self.nextChatCommand { if !singleChatOnly { goForward() } }
      else if Self.clearChatCommands.contains(lower) { clearMessages() }
      else if lower == Self.settingsCommand { SettingsManager.shared.showSettings() }
      else if lower == Self.pinCommand { togglePin() }
      else if lower == Self.unpinCommand { unpin() }
      else if lower == Self.rememberCommand {
        guard !session.messages.isEmpty else { return }
        Task { await updateSessionMemory() }
      }
      else { await captureScreenshot() }
      return
    }

    // Build attachment parts before clearing input (needed for queue snapshot)
    let attachedParts: [AttachedImagePart]
    if let file = pendingFileAttachment {
      attachedParts = [AttachedImagePart(data: file.data, mimeType: file.mimeType, filename: file.filename)]
    } else if !pendingScreenshots.isEmpty {
      attachedParts = pendingScreenshots.enumerated().map { index, data in
        let filename = pendingScreenshots.count == 1 ? "screenshot.png" : "screenshot \(index + 1).png"
        return AttachedImagePart(data: data, mimeType: "image/png", filename: filename)
      }
    } else {
      attachedParts = []
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
    pendingFileAttachment = nil

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
    session.sessionMemory = nil
    session.lastUpdated = Date()
    store.save(session)
    refreshRecentSessions()
    DebugLogger.log("GEMINI-CHAT: Cleared current chat messages")
  }

  // MARK: - Private

  /// Returns user-visible content for the session tab title (typed text, else first pasted/selection body).
  private static func contentForSessionTitle(_ rawContent: String) -> String {
    let parsed = parseUserMessagePastedXML(rawContent)
    if !parsed.userText.isEmpty { return parsed.userText }
    if let first = parsed.sections.first { return first.body }
    return rawContent.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Builds the system instruction: current date, base Gemini Chat prompt, plus optional meeting context (summary + recent transcript).
  private func buildSystemInstruction() -> [String: Any] {
    var text = SystemPromptsStore.shared.loadGeminiChatSystemPrompt()
    let formatter = DateFormatter()
    formatter.dateFormat = "EEEE, MMMM d, yyyy"
    formatter.locale = Locale(identifier: "en_US")
    text = "Today's date: \(formatter.string(from: Date())).\n\n\(text)"
    if let extra = meetingContextProvider?(), !extra.isEmpty {
      text = "\(text)\n\n---\n\n[Meeting context for calibration only — do not reference directly]\n\(extra)"
    }
    if let memory = session.sessionMemory, !memory.isEmpty {
      text = "\(text)\n\n--- Session Memory (use for all answers) ---\n\(memory)\n---"
    }
    return ["parts": [["text": text]]]
  }

  /// Resolves the model ID for the Open Gemini chat window from UserDefaults (Settings > Open Gemini), or subscription fixed model when on subscription.
  private static func resolveOpenGeminiModel() -> String {
    openGeminiModel.rawValue
  }

  private static var isSubscription: Bool {
    #if SUBSCRIPTION_ENABLED
    return !KeychainManager.shared.hasValidGoogleAPIKey() && DefaultGoogleAuthService.shared.isSignedIn()
    #else
    return false
    #endif
  }

  /// Resolves the selected Open Gemini model for display and API. In subscription mode returns the fixed model (e.g. Gemini 3 Flash).
  static var openGeminiModel: PromptModel {
    if isSubscription { return SubscriptionModelsConfigService.effectiveOpenGeminiModel() }
    let raw = UserDefaults.standard.string(forKey: UserDefaultsKeys.selectedOpenGeminiModel)
      ?? SettingsDefaults.selectedOpenGeminiModel.rawValue
    return PromptModel(rawValue: raw).map { PromptModel.migrateIfDeprecated($0) }
      ?? SettingsDefaults.selectedOpenGeminiModel
  }

  /// Display name for the current Open Gemini model (e.g. "Gemini 3 Flash") for the nav bar.
  var openGeminiModelDisplayName: String {
    Self.openGeminiModel.displayName
  }

  /// Updates an existing model message in-place (used during streaming).
  /// Persists to the store and, if it's the current session, refreshes the UI.
  private func updateStreamingMessage(
    id: UUID, sessionId: UUID, content: String,
    sources: [GroundingSource], supports: [GroundingSupport]
  ) {
    let isCurrentSession = sessionId == session.id
    var target: ChatSession
    if isCurrentSession {
      target = session
    } else {
      guard let s = store.session(by: sessionId) else { return }
      target = s
    }
    guard let idx = target.messages.firstIndex(where: { $0.id == id }) else { return }
    target.messages[idx].content = content
    target.messages[idx].sources = sources
    target.messages[idx].groundingSupports = supports
    target.lastUpdated = Date()
    // Persist throttled-ish: save on every update is fine for typical chat volumes;
    // the alternative would be to save only on .finished, but crash recovery benefits from frequent saves.
    store.save(target)
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

  private func generateAITitle(sessionId: UUID) async {
    guard let credential = await GeminiCredentialProvider.shared.getCredential() else { return }
    guard let target = store.session(by: sessionId),
          target.messages.count >= 2,
          target.messages[0].role == .user,
          target.messages[1].role == .model else { return }
    let userText = String(target.messages[0].content.prefix(400))
    let modelText = String(target.messages[1].content.prefix(400))
    let prompt = """
      Give this conversation a two-word title that captures its core topic. \
      Put each word on its own line. \
      Reply with only the two words, one per line — no quotes, no punctuation, no explanation.

      User: \(userText)
      Assistant: \(modelText)
      """
    do {
      let raw = try await apiClient.generateText(
        model: "gemini-2.5-flash-lite", prompt: prompt, credential: credential)
      let lines = raw
        .components(separatedBy: .newlines)
        .map {
          $0.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "'", with: "")
        }
        .filter { !$0.isEmpty }
      let title = lines.prefix(2).joined(separator: "\n")
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

  // MARK: - /context command

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
    let sub = Self.isSubscription
    let current = Self.openGeminiModel
    let outcome = OpenGeminiModelCommandResolver.resolve(
      argument: argument,
      isSubscription: sub,
      currentSelection: current
    )
    switch outcome {
    case .subscriptionLocked(let effective):
      appendModelMessage(
        "Subscription mode uses a fixed chat model: **\(effective.displayName)**. Add your own Google API key in Settings to choose a different model."
      )
    case .usage(let cur):
      appendModelMessage(
        "Current model: **\(cur.displayName)**. Example: `/model 3.1 flash lite` or `/model 2.5 pro`."
      )
    case .applied(let model):
      let migrated = PromptModel.migrateIfDeprecated(model)
      UserDefaults.standard.set(migrated.rawValue, forKey: UserDefaultsKeys.selectedOpenGeminiModel)
      appendModelMessage("Model set to **\(migrated.displayName)**.")
    case .ambiguous(let candidates):
      let list = candidates.map { "• **\($0.displayName)**" }.joined(separator: "\n")
      appendModelMessage("Multiple matches. Be more specific:\n\(list)")
    case .noMatch(let query):
      appendModelMessage("No model matched \"\(query)\". Try a version and variant, e.g. `3.1 flash lite` or `2.5 pro`.")
    }
    DebugLogger.log("GEMINI-CHAT: /model argument=\(argument) outcome=\(outcome)")
  }

  /// Handles the /context command. With no instruction: shows current context. With instruction: updates via Gemini.
  private func handleContextCommand(instruction: String?) async {
    guard let instruction = instruction else {
      // Show current context
      let sections: [(String, SystemPromptSection)] = [
        ("Dictation", .dictation),
        ("Prompt Mode", .promptMode),
        ("Prompt & Read", .promptAndRead),
        ("Gemini Chat", .geminiChat),
        ("Whisper Glossary", .whisperGlossary),
      ]
      var lines = ["**Your current context:**"]
      for (label, section) in sections {
        let content = SystemPromptsStore.shared.loadSection(section)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        lines.append("\n---\n**\(label)**\n\(content.isEmpty ? "_not set_" : content)")
      }
      lines.append("\n_Use `/context <instruction>` to update, e.g. `/context always format responses as bullet points`_")
      appendModelMessage(lines.joined(separator: "\n"))
      return
    }

    // Show user command in chat
    let userMsg = ChatMessage(role: .user, content: "/context \(instruction)")
    messages.append(userMsg)
    session.messages = messages
    store.save(session)

    // Add placeholder while working
    let placeholderMsg = ChatMessage(role: .model, content: "Updating your context…")
    messages.append(placeholderMsg)
    session.messages = messages
    store.save(session)

    guard let credential = await GeminiCredentialProvider.shared.getCredential() else {
      replaceLastModelMessage("Could not update context: no API credential available.")
      return
    }

    let oldContent = SystemPromptsStore.shared.loadFullContent()
    let prompt = """
      You are updating the user's personal context for WhisperShortcut, a voice transcription app.

      Current context file:
      ---
      \(oldContent)
      ---

      The user wants to: \(instruction)

      Update the relevant section(s) based on this instruction. Return ONLY the complete updated file content in the exact same format, preserving all section headers (=== ... ===). Do not add any explanation — only the file content.
      """

    let model = Self.resolveOpenGeminiModel()
    do {
      let response = try await apiClient.generateText(model: model, prompt: prompt, credential: credential)
      let newContent = response.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !newContent.isEmpty else {
        replaceLastModelMessage("Context update failed: empty response from Gemini.")
        return
      }

      // Compare sections to summarize what changed
      let oldSections = extractSections(from: oldContent)
      SystemPromptsStore.shared.saveFullContent(newContent)
      NotificationCenter.default.post(name: .contextFileDidUpdate, object: nil)
      let newSections = extractSections(from: SystemPromptsStore.shared.loadFullContent())

      var changed: [String] = []
      for section in SystemPromptSection.allCases {
        if oldSections[section] != newSections[section] {
          changed.append(section.fileHeader.replacingOccurrences(of: "===", with: "").trimmingCharacters(in: .whitespaces))
        }
      }
      let summary = changed.isEmpty
        ? "Context saved (no section content changed)."
        : "Context updated. Changed: \(changed.joined(separator: ", "))."
      replaceLastModelMessage(summary)
      DebugLogger.log("GEMINI-CHAT: /context updated: \(summary)")
    } catch {
      replaceLastModelMessage("Context update failed: \(error.localizedDescription)")
      DebugLogger.logError("GEMINI-CHAT: /context error: \(error.localizedDescription)")
    }
  }

  /// Replaces the last model message in the chat (used to swap placeholder with result).
  @MainActor
  private func replaceLastModelMessage(_ content: String) {
    if let idx = messages.indices.last(where: { messages[$0].role == .model }) {
      messages[idx] = ChatMessage(role: .model, content: content)
      session.messages = messages
      store.save(session)
    }
  }

  /// Extracts section content map from a raw system-prompts file string.
  private func extractSections(from content: String) -> [SystemPromptSection: String] {
    var result: [SystemPromptSection: String] = [:]
    let lines = content.components(separatedBy: "\n")
    var currentSection: SystemPromptSection? = nil
    var body: [String] = []
    func flush() {
      if let s = currentSection {
        result[s] = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
      }
    }
    for line in lines {
      if let section = SystemPromptSection.section(forHeader: line) {
        flush()
        currentSection = section
        body = []
      } else {
        body.append(line)
      }
    }
    flush()
    return result
  }

  /// Distils undistilled messages outside the volatile window into `session.sessionMemory`.
  /// Guards: empty session, concurrency lock, 60-second failure backoff.
  /// Called from actor-inheriting `Task { }` — no MainActor.run{} wrappers needed.
  private func updateSessionMemory() async {
    guard !session.messages.isEmpty else { return }
    guard !isUpdatingMemory else {
      DebugLogger.log("GEMINI-MEMORY: Skipped — update already in flight")
      return
    }
    if let failTime = memoryUpdateFailureTime, Date().timeIntervalSince(failTime) < 60 {
      DebugLogger.log("GEMINI-MEMORY: Skipped — within 60s backoff after last failure")
      return
    }
    guard let credential = await GeminiCredentialProvider.shared.getCredential() else {
      DebugLogger.logError("GEMINI-MEMORY: No credential available")
      return
    }

    let toDistill = Array(session.messages.dropLast(AppConstants.geminiChatVolatileWindowSize))
      .filter { !$0.includedInMemory }
    guard !toDistill.isEmpty else {
      DebugLogger.log("GEMINI-MEMORY: Nothing new to distil")
      return
    }

    isUpdatingMemory = true
    DebugLogger.log("GEMINI-MEMORY: Distilling \(toDistill.count) message(s) into session memory")

    // Build multi-turn contents for the memory call — include images for all messages (not just last).
    let contents: [[String: Any]] = toDistill.map { msg in
      if msg.role == .user && !msg.attachedImageParts.isEmpty {
        var parts: [[String: Any]] = msg.attachedImageParts.map { part in
          ["inline_data": ["mime_type": part.mimeType ?? "image/png", "data": part.data.base64EncodedString()]]
        }
        if !msg.content.isEmpty { parts.append(["text": msg.content]) }
        return ["role": msg.role.rawValue, "parts": parts]
      }
      return ["role": msg.role.rawValue, "parts": [["text": msg.content]]]
    }

    do {
      var updatedMemory = try await apiClient.updateSessionMemory(
        currentMemory: session.sessionMemory,
        newMessageContents: contents,
        credential: credential)
      // Safety clamp.
      if updatedMemory.count > AppConstants.geminiChatSessionMemoryMaxChars {
        updatedMemory = String(updatedMemory.prefix(AppConstants.geminiChatSessionMemoryMaxChars))
      }
      // Mark distilled messages and persist.
      let distilledIds = Set(toDistill.map { $0.id })
      session.messages = session.messages.map { msg in
        guard distilledIds.contains(msg.id) else { return msg }
        var m = msg; m.includedInMemory = true; return m
      }
      messages = session.messages
      session.sessionMemory = updatedMemory
      memoryUpdateFailureTime = nil
      store.save(session)
      DebugLogger.log("GEMINI-MEMORY: Memory updated (\(updatedMemory.count) chars)")
    } catch {
      memoryUpdateFailureTime = Date()
      DebugLogger.logError("GEMINI-MEMORY: Update failed — \(error.localizedDescription)")
    }
    isUpdatingMemory = false
  }

  // MARK: - Tab navigation

  private func refreshRecentSessions() {
    recentSessions = store.recentSessions(limit: 20)
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
    guard id != session.id else { return }
    store.switchToSession(id: id)
    switchToCurrentStoreSession()
    DebugLogger.log("GEMINI-CHAT: Switched to session \(id) via tab")
  }

  func closeTab(id: UUID) {
    rememberClosed(id: id)
    store.deleteSession(id: id)
    if id == session.id {
      switchToCurrentStoreSession()
    } else {
      refreshRecentSessions()
    }
    DebugLogger.log("GEMINI-CHAT: Closed tab \(id)")
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
    // Previously this used a small volatile window + a separate LLM call to distil older
    // turns into `sessionMemory` — that lost information and added latency on every turn.
    let maxMessages = AppConstants.geminiChatFullHistoryMaxMessages
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
private final class GeminiScrollActions {
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

struct GeminiChatView: View {
  @StateObject private var viewModel: GeminiChatViewModel
  /// Image data to show in the full-size preview sheet (from pending screenshot or from a sent message thumbnail).
  @State private var previewImageData: Data? = nil
  @State private var scrollActions = GeminiScrollActions()
  @State private var hoveredTabId: UUID? = nil
  /// Session id currently being renamed via the context-menu alert.
  @State private var renamingTabId: UUID? = nil
  @State private var renameDraft: String = ""
  /// When true, create a new chat session on first appear (e.g. for the meeting window so it opens with a fresh chat).
  @State private var createNewSessionOnAppear: Bool
  @State private var hasTriggeredNewSessionOnAppear: Bool = false

  init(meetingContextProvider: (() -> String?)? = nil, createNewSessionOnAppear: Bool = false, store: GeminiChatSessionStore = .shared, singleChatOnly: Bool = false) {
    _viewModel = StateObject(wrappedValue: GeminiChatViewModel(meetingContextProvider: meetingContextProvider, store: store, singleChatOnly: singleChatOnly))
    _createNewSessionOnAppear = State(initialValue: createNewSessionOnAppear)
  }

  var body: some View {
    GeometryReader { geometry in
      VStack(spacing: 0) {
        if !viewModel.singleChatOnly {
          tabStripHeader(containerWidth: geometry.size.width)
          Divider()
        }
        messageList(scrollActions: scrollActions, containerWidth: geometry.size.width)
        if let error = viewModel.errorMessage {
          errorBanner(error)
        }
        Divider()
        GeminiInputAreaView(viewModel: viewModel, onTapScreenshotThumbnail: { data in
          previewImageData = data
        })
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(GeminiChatTheme.windowBackground)
    .sheet(isPresented: Binding(
      get: { previewImageData != nil },
      set: { if !$0 { previewImageData = nil } }
    )) {
      if let data = previewImageData, let nsImage = NSImage(data: data) {
        screenshotPreviewSheet(image: nsImage, onDone: { previewImageData = nil })
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: .geminiNewChat)) { _ in
      if !viewModel.singleChatOnly { viewModel.createNewSession() }
    }
    .onReceive(NotificationCenter.default.publisher(for: .geminiCaptureScreenshot)) { _ in
      Task { await viewModel.captureScreenshot() }
    }
    .onReceive(NotificationCenter.default.publisher(for: .geminiClearChat)) { _ in
      viewModel.clearMessages()
    }
    .onReceive(NotificationCenter.default.publisher(for: .geminiCloseTab)) { _ in
      viewModel.closeTab(id: viewModel.currentSessionId)
    }
    .onReceive(NotificationCenter.default.publisher(for: .geminiReopenLastClosedTab)) { _ in
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
    .onReceive(NotificationCenter.default.publisher(for: .geminiScrollToTop)) { _ in
      scrollActions.scrollToTop?()
    }
    .onReceive(NotificationCenter.default.publisher(for: .geminiScrollToBottom)) { _ in
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
      tabOverflowMenu(sessions: allSessions)
        .frame(width: iconWidth, height: 52)

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
      ForEach(sessions, id: \.id) { session in
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
        .foregroundColor(GeminiChatTheme.secondaryText)
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
      .background(isActive ? GeminiChatTheme.controlBackground : Color.clear)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .foregroundColor(isActive ? GeminiChatTheme.primaryText : GeminiChatTheme.secondaryText)
    .overlay(alignment: .bottom) {
      if isActive {
        Rectangle().fill(Color.accentColor).frame(height: 2)
      }
    }
    .overlay(alignment: .trailing) {
      Rectangle()
        .fill(GeminiChatTheme.primaryText.opacity(0.1))
        .frame(width: 1)
    }
    .overlay(alignment: .topTrailing) {
      if hoveredTabId == session.id {
        Button(action: { viewModel.closeTab(id: session.id) }) {
          Image(systemName: "xmark")
            .font(.system(size: 7, weight: .bold))
            .foregroundColor(GeminiChatTheme.secondaryText)
            .frame(width: 13, height: 13)
            .background(GeminiChatTheme.controlBackground)
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

  private func messageList(scrollActions: GeminiScrollActions, containerWidth: CGFloat) -> some View {
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
                    .foregroundColor(GeminiChatTheme.secondaryText)
                }
                .buttonStyle(.plain)
                .help("Remove from queue")
                Text(queued.displayContent)
                  .font(.system(size: 14))
                  .foregroundColor(GeminiChatTheme.secondaryText)
                  .padding(.horizontal, 12)
                  .padding(.vertical, 8)
                  .background(GeminiChatTheme.controlBackground)
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
        .frame(maxWidth: 680)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.top, 14)
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
    return VStack(alignment: .leading, spacing: 12) {
      Text("Commands")
        .font(.headline)
        .fontWeight(.semibold)
        .foregroundColor(GeminiChatTheme.secondaryText)
      VStack(alignment: .leading, spacing: 8) {
        ForEach(suggestions, id: \.command) { item in
          Text("\(item.command) — \(item.description)")
            .font(.system(size: 15))
            .foregroundColor(GeminiChatTheme.secondaryText)
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

  private func errorBanner(_ message: String) -> some View {
    HStack(spacing: 8) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundColor(.white)
        .font(.footnote)
      Text(message)
        .font(.footnote)
        .foregroundColor(.white)
        .fixedSize(horizontal: false, vertical: true)
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
        .background(GeminiChatTheme.windowBackground)
    }
    .frame(minWidth: 800, minHeight: 600)
    .frame(idealWidth: 1000, idealHeight: 700)
  }
}

// MARK: - Input Area (isolated to avoid full-view re-renders on each keystroke)

/// Standalone view that owns the input text state. Typing only invalidates this subtree,
/// not the parent's message list, header, or other heavy views.
struct GeminiInputAreaView: View {
  @ObservedObject var viewModel: GeminiChatViewModel
  var onTapScreenshotThumbnail: (Data) -> Void

  @StateObject private var composer = GeminiComposerController()
  @AppStorage(UserDefaultsKeys.geminiCloseOnFocusLoss) private var closeOnFocusLoss: Bool = SettingsDefaults.geminiCloseOnFocusLoss
  @AppStorage(UserDefaultsKeys.selectedOpenGeminiModel) private var selectedOpenGeminiModelRaw: String = SettingsDefaults.selectedOpenGeminiModel.rawValue

  private static let inputMinHeight: CGFloat = 40
  private static let inputMaxHeight: CGFloat = 180

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

  /// Current Open Gemini model for display (with migration); syncs with UserDefaults via @AppStorage.
  private var resolvedOpenGeminiModel: PromptModel {
    PromptModel(rawValue: selectedOpenGeminiModelRaw)
      .map { PromptModel.migrateIfDeprecated($0) }
      ?? SettingsDefaults.selectedOpenGeminiModel
  }

  private var isSubscription: Bool {
    #if SUBSCRIPTION_ENABLED
    return !KeychainManager.shared.hasValidGoogleAPIKey() && DefaultGoogleAuthService.shared.isSignedIn()
    #else
    return false
    #endif
  }

  var body: some View {
    VStack(spacing: 0) {
      commandSuggestionsOverlay
      inputBar
    }
    .onAppear {
      viewModel.composerScreenshotCountProvider = { [weak composer] in composer?.screenshotCount ?? 0 }
      // Cold-start prefill path
      if let buffered = GeminiWindowManager.shared.pendingPrefillText {
        GeminiWindowManager.shared.pendingPrefillText = nil
        composer.clearAll()
        composer.insertPastedBlock(text: buffered, kind: .shortcutSelection)
        Task { @MainActor in
          try? await Task.sleep(for: .milliseconds(50))
          composer.focus()
        }
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: .geminiFocusInput)) { _ in
      Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(50))
        composer.focus()
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: .geminiPrefillComposer)) { note in
      Task { @MainActor in
        guard let text = note.userInfo?[Notification.Name.geminiPrefillComposerTextKey] as? String else { return }
        GeminiWindowManager.shared.pendingPrefillText = nil
        composer.clearAll()
        composer.insertPastedBlock(text: text, kind: .shortcutSelection)
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
    .onChange(of: viewModel.pendingFileAttachment?.filename) { _ in
      guard let f = viewModel.pendingFileAttachment else { return }
      composer.insertFile(data: f.data, mimeType: f.mimeType, filename: f.filename)
      viewModel.pendingFileAttachment = nil
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

  private static let knownSlashCommands: Set<String> = [
    "/new", "/back", "/next", "/clear", "/screenshot", "/remember",
    "/context", "/settings", "/pin", "/unpin", "/stop"
  ]

  /// Sends the current composer contents. Recognized slash commands strip just
  /// the slash token (preserving any other attachments / text) and dispatch
  /// through the legacy `sendMessage`. Everything else is sent in document order.
  private func submitComposer() {
    let output = composer.serialize()
    let typed = output.typedText
    let lower = typed.lowercased()
    let isContextCommand = lower == "/context" || lower.hasPrefix("/context ")
    let isModelCommand = lower == "/model" || lower.hasPrefix("/model ")
    let isRecognizedSlashCommand =
      Self.knownSlashCommands.contains(lower) || isContextCommand || isModelCommand
    if isRecognizedSlashCommand {
      if isContextCommand || isModelCommand {
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
    guard word.hasPrefix("/"), !word.isEmpty else { return false }
    let matches = viewModel.suggestedCommands(for: word)
    guard let first = matches.first else { return false }
    // Commands that take an argument: complete inline so the user can type
    // the argument; do not dispatch yet.
    let takesArgument = (first == "/context" || first == "/model")
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
      if lastWord.hasPrefix("/") {
        let suggestions = viewModel.commandSuggestionsForDisplay
          .filter { $0.command.lowercased().hasPrefix(lastWord.lowercased()) }
        if !suggestions.isEmpty {
          VStack(alignment: .leading, spacing: 0) {
            ForEach(suggestions, id: \.command) { item in
              HStack(alignment: .top, spacing: 8) {
                Text(item.command)
                  .font(.system(.body, design: .monospaced))
                  .fontWeight(.medium)
                  .foregroundColor(GeminiChatTheme.primaryText)
                Text(item.description)
                  .font(.caption)
                  .foregroundColor(GeminiChatTheme.secondaryText)
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
          .background(GeminiChatTheme.controlBackground)
          .overlay(
            RoundedRectangle(cornerRadius: 8)
              .strokeBorder(GeminiChatTheme.primaryText.opacity(GeminiChatTheme.borderOpacity), lineWidth: 1)
          )
          .clipShape(RoundedRectangle(cornerRadius: 8))
          .frame(maxWidth: 680)
          .frame(maxWidth: .infinity, alignment: .center)
          .padding(.horizontal, 20)
          .padding(.bottom, 4)
        }
      }
    }
  }

  // MARK: - Input Bar (Claude-style: composer on top, toolbar below)

  private var inputBar: some View {
    VStack(spacing: 0) {
      // Composer: NSTextView with inline screenshot/paste/file attachments.
      GeminiComposerTextView(
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
            .foregroundColor(GeminiChatTheme.secondaryText)
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
          .foregroundColor(GeminiChatTheme.secondaryText)
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
          .foregroundColor(viewModel.screenshotCaptureInProgress ? GeminiChatTheme.secondaryText.opacity(0.6) : GeminiChatTheme.secondaryText)
          .padding(.horizontal, 8)
          .padding(.vertical, 5)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(viewModel.screenshotCaptureInProgress || viewModel.isSending)
        .help("Capture screen without this window; image will be attached to your next message.")
        .pointerCursorOnHover()

        Spacer()

        if isSubscription {
          HStack(spacing: 4) {
            Image(systemName: "cpu").font(.caption)
            Text(SubscriptionModelsConfigService.effectiveOpenGeminiModel().displayName).font(.caption)
          }
          .foregroundColor(GeminiChatTheme.secondaryText)
          .padding(.horizontal, 8)
          .padding(.vertical, 5)
          .help("Model is fixed in subscription mode")
        } else {
          Menu {
            ForEach(PromptModel.allCases, id: \.self) { model in
              Button(action: {
                selectedOpenGeminiModelRaw = model.rawValue
              }) {
                Text(model.displayName)
              }
            }
          } label: {
            HStack(spacing: 4) {
              Image(systemName: "cpu").font(.caption)
              Text(resolvedOpenGeminiModel.displayName).font(.caption)
            }
            .foregroundColor(GeminiChatTheme.secondaryText)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
          }
          .menuStyle(.borderlessButton)
          .fixedSize()
          .help("Select model")
        }

        // Queue count indicator
        if viewModel.isSending && !viewModel.messageQueue.isEmpty {
          Text("\(viewModel.messageQueue.count) queued")
            .font(.caption2)
            .foregroundColor(GeminiChatTheme.secondaryText)
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
                .foregroundColor(GeminiChatTheme.primaryText)
            } else {
              Image(systemName: "arrow.up")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(hasContent ? GeminiChatTheme.windowBackground : GeminiChatTheme.secondaryText.opacity(0.5))
            }
          }
          .frame(width: 30, height: 30)
          .background(
            RoundedRectangle(cornerRadius: 8)
              .fill(viewModel.isSending ? Color.red.opacity(0.8) : (hasContent ? GeminiChatTheme.primaryText : GeminiChatTheme.controlBackground))
          )
        }
        .buttonStyle(.plain)
        .disabled(!hasContent && !viewModel.isSending)
        .help(viewModel.isSending ? "Stop sending (/stop)" : "Send message")
        .pointerCursorOnHover()
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 8)
    }
    .frame(maxWidth: 680)
    .background(GeminiChatTheme.controlBackground)
    .clipShape(RoundedRectangle(cornerRadius: 14))
    .overlay(
      RoundedRectangle(cornerRadius: 14)
        .strokeBorder(GeminiChatTheme.primaryText.opacity(GeminiChatTheme.borderOpacity), lineWidth: 1)
    )
    .frame(maxWidth: .infinity, alignment: .center)
    .padding(.horizontal, 20)
    .padding(.vertical, 12)
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
          .foregroundColor(GeminiChatTheme.secondaryText)
      }
      Text(label)
        .font(.caption)
        .foregroundColor(GeminiChatTheme.primaryText)
      Button(action: { viewModel.removePendingScreenshot(at: index); inputFocused = true }) {
        Image(systemName: "xmark")
          .font(.system(size: 8, weight: .bold))
          .foregroundColor(GeminiChatTheme.secondaryText)
      }
      .buttonStyle(.plain)
      .help("Remove screenshot")
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 5)
    .background(GeminiChatTheme.windowBackground.opacity(0.6))
    .clipShape(RoundedRectangle(cornerRadius: 8))
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .strokeBorder(
          isFocused ? Color.accentColor : GeminiChatTheme.primaryText.opacity(GeminiChatTheme.borderOpacity),
          lineWidth: isFocused ? 1.5 : 1)
    )
    .focusable()
    .focused($focusedAttachment, equals: .screenshot(index))
    .onKeyPress(.deleteForward)  { viewModel.removePendingScreenshot(at: index); inputFocused = true; return .handled }
    .onKeyPress(.delete)         { viewModel.removePendingScreenshot(at: index); inputFocused = true; return .handled }
    .accessibilityLabel("\(label) attachment. Press Delete to remove.")
  }

  private var fileChip: some View {
    let file = viewModel.pendingFileAttachment
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
          .foregroundColor(GeminiChatTheme.secondaryText)
      }
      Text(file?.filename ?? "File")
        .font(.caption)
        .foregroundColor(GeminiChatTheme.primaryText)
        .lineLimit(1)
        .frame(maxWidth: 120, alignment: .leading)
      Button(action: { viewModel.clearPendingFile(); inputFocused = true }) {
        Image(systemName: "xmark")
          .font(.system(size: 8, weight: .bold))
          .foregroundColor(GeminiChatTheme.secondaryText)
      }
      .buttonStyle(.plain)
      .help("Remove attachment")
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 5)
    .background(GeminiChatTheme.windowBackground.opacity(0.6))
    .clipShape(RoundedRectangle(cornerRadius: 8))
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .strokeBorder(
          isFocused ? Color.accentColor : GeminiChatTheme.primaryText.opacity(GeminiChatTheme.borderOpacity),
          lineWidth: isFocused ? 1.5 : 1)
    )
    .focusable()
    .focused($focusedAttachment, equals: .file)
    .onKeyPress(.deleteForward)  { viewModel.clearPendingFile(); inputFocused = true; return .handled }
    .onKeyPress(.delete)         { viewModel.clearPendingFile(); inputFocused = true; return .handled }
    .accessibilityLabel("File attachment \(file?.filename ?? ""). Press Delete to remove.")
  }

  private func pastedBlockChip(_ block: GeminiChatViewModel.PastedBlock) -> some View {
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
        .foregroundColor(GeminiChatTheme.secondaryText)
      Text(chipLabel)
        .font(.caption)
        .foregroundColor(GeminiChatTheme.primaryText)
      Button(action: { viewModel.removePastedBlock(id: block.id); inputFocused = true }) {
        Image(systemName: "xmark")
          .font(.system(size: 8, weight: .bold))
          .foregroundColor(GeminiChatTheme.secondaryText)
      }
      .buttonStyle(.plain)
      .help(removeHelp)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 5)
    .background(GeminiChatTheme.windowBackground.opacity(0.6))
    .clipShape(RoundedRectangle(cornerRadius: 8))
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .strokeBorder(
          isFocused ? Color.accentColor : GeminiChatTheme.primaryText.opacity(GeminiChatTheme.borderOpacity),
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
private struct GeminiInputScrollViewAutohideAnchor: NSViewRepresentable {
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

private struct ModelReplyView: View {
  let content: String
  let sources: [GroundingSource]
  let groundingSupports: [GroundingSupport]

  var body: some View {
    let blocks = Self.buildReplyBlocks(content: content, sources: sources, groundingSupports: groundingSupports)
    return VStack(alignment: .leading, spacing: 24) {
      ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
        switch block {
        case .text(let attrStr):
          Text(attrStr)
            .font(.system(size: 16))
            .lineSpacing(10)
            .foregroundColor(GeminiChatTheme.primaryText)
            .textSelection(.enabled)
        case .table(let parsed):
          MarkdownTableView(headers: parsed.headers, rows: parsed.rows)
        case .separator:
          Rectangle()
            .fill(GeminiChatTheme.primaryText.opacity(0.15))
            .frame(height: 1)
            .frame(maxWidth: .infinity)
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
    .padding(.horizontal, 16)
    .padding(.vertical, 14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .fixedSize(horizontal: false, vertical: true)
    .contentShape(Rectangle())
    .onHover { inside in
      if inside { NSCursor.iBeam.push() } else { NSCursor.pop() }
    }
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
        blocks.append(.codeBlock(cb.code, cb.language))
      } else if let imageData = Self.extractInlineImageData(trimmed) {
        blocks.append(.image(imageData))
      } else if MarkdownParsing.isSeparatorParagraph(trimmed) {
        blocks.append(.separator)
      } else if MarkdownParsing.looksLikeMarkdownTable(trimmed), let parsed = MarkdownParsing.parseMarkdownTable(trimmed) {
        blocks.append(.table(parsed))
      } else {
        blocks.append(.text(buildSingleParagraphAttributed(trimmed, options: options)))
      }
    }
    return blocks.isEmpty ? [.text(AttributedString(content))] : blocks
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

  /// Renders a paragraph block that consists entirely of bullet/numbered-list lines.
  /// Returns nil if the block contains any non-bullet lines.
  private static func buildBulletListAttributed(_ trimmed: String) -> AttributedString? {
    let lines = trimmed.components(separatedBy: .newlines)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
    guard !lines.isEmpty, lines.allSatisfy({ MarkdownParsing.parseBullet($0) != nil }) else { return nil }
    let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    var result = AttributedString()
    for (i, line) in lines.enumerated() {
      let rawContent = MarkdownParsing.parseBullet(line)!.trimmingCharacters(in: .whitespaces)
      let content = MarkdownParsing.renderLatexToUnicode(rawContent)
      if i > 0 { result.append(AttributedString("\n")) }
      var bullet = AttributedString("• ")
      bullet.font = .system(size: 16, weight: .regular)
      result.append(bullet)
      var contentAttr = MarkdownParsing.inlineAttributedString(content, options: opts)
      contentAttr.font = .system(size: 16, weight: .regular)
      result.append(contentAttr)
    }
    return result
  }

  private static func buildSingleParagraphAttributed(
    _ trimmed: String,
    options: AttributedString.MarkdownParsingOptions
  ) -> AttributedString {
    if MarkdownParsing.isSeparatorParagraph(trimmed) {
      var lineAttr = AttributedString(MarkdownParsing.separatorLineContent)
      lineAttr.foregroundColor = GeminiChatTheme.primaryText.opacity(0.4)
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
    if let bulletAttr = buildBulletListAttributed(trimmed) { return bulletAttr }
    // Convert LaTeX formulas to Unicode before markdown parsing
    let latexProcessed = MarkdownParsing.renderLatexToUnicode(trimmed)
    let fullOptions = AttributedString.MarkdownParsingOptions(interpretedSyntax: .full)
    var attr = (try? AttributedString(markdown: latexProcessed, options: fullOptions)) ?? AttributedString(latexProcessed)
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
        lineAttr.foregroundColor = GeminiChatTheme.primaryText.opacity(0.4)
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
        let label = cb.language.map { "[\($0)] " } ?? ""
        var attr = AttributedString("\(label)\(cb.code)")
        attr.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        result.append(attr)
      } else if trimmed.hasPrefix(GeminiAPIClient.imageMarkerPrefix) && trimmed.hasSuffix(GeminiAPIClient.imageMarkerSuffix) {
        // Inline image marker — skip in AttributedString fallback path (rendered in SwiftUI path)
        var attr = AttributedString("[Image]")
        attr.font = .system(size: 14, weight: .medium)
        attr.foregroundColor = GeminiChatTheme.primaryText.opacity(0.5)
        result.append(attr)
      } else if MarkdownParsing.isSeparatorParagraph(trimmed) {
        var lineAttr = AttributedString(MarkdownParsing.separatorLineContent)
        lineAttr.foregroundColor = GeminiChatTheme.primaryText.opacity(0.4)
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
      } else if let bulletAttr = buildBulletListAttributed(trimmed) {
        result.append(bulletAttr)
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
          .foregroundColor(GeminiChatTheme.primaryText.opacity(0.5))
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
          .foregroundColor(GeminiChatTheme.primaryText.opacity(0.5))
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
          .foregroundColor(GeminiChatTheme.primaryText.opacity(0.9))
          .textSelection(.enabled)
          .padding(14)
      }
    }
    .background(Color.black.opacity(0.25))
    .clipShape(RoundedRectangle(cornerRadius: 8))
  }
}

// MARK: - Read Aloud Button (under model replies)

private struct ReadAloudButtonView: View {
  let messageContent: String
  @State private var isHovered = false
  @State private var isTTSActive = false

  var body: some View {
    Button {
      if isTTSActive {
        NotificationCenter.default.post(name: .geminiReadAloudStop, object: nil)
      } else {
        NotificationCenter.default.post(
          name: .geminiReadAloud,
          object: nil,
          userInfo: [Notification.Name.geminiReadAloudTextKey: messageContent]
        )
      }
    } label: {
      HStack(spacing: 5) {
        Image(systemName: isTTSActive ? "stop.fill" : "speaker.wave.2")
          .font(.system(size: 12))
        Text(isTTSActive ? "Reading…" : "Read Aloud")
          .font(.caption)
      }
      .foregroundColor(isHovered ? GeminiChatTheme.primaryText : GeminiChatTheme.secondaryText)
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .frame(minHeight: 28)
      .contentShape(Rectangle())
      .background(
        RoundedRectangle(cornerRadius: 6)
          .fill(isHovered ? GeminiChatTheme.controlBackground.opacity(0.9) : GeminiChatTheme.controlBackground.opacity(0.5))
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
      .foregroundColor(isHovered ? GeminiChatTheme.primaryText : GeminiChatTheme.secondaryText)
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .frame(minHeight: 28)
      .contentShape(Rectangle())
      .background(
        RoundedRectangle(cornerRadius: 6)
          .fill(isHovered ? GeminiChatTheme.controlBackground.opacity(0.9) : GeminiChatTheme.controlBackground.opacity(0.5))
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

fileprivate struct UserMessagePastedSection: Equatable {
  let body: String
  /// True when wrapped as `<pasted_selection>` (shortcut selection); false for `<pasted_content>`.
  let isSelection: Bool
}

fileprivate func unwrapUserMessageTypedByUser(_ s: String) -> String {
  let open = "<typed_by_user>"
  let close = "</typed_by_user>"
  guard let r1 = s.range(of: open), let r2 = s.range(of: close), r1.upperBound <= r2.lowerBound else {
    return s
  }
  return String(s[r1.upperBound..<r2.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Strips leading `<pasted_content>` / `<pasted_selection>` blocks in order, then unwraps `<typed_by_user>`.
fileprivate func parseUserMessagePastedXML(_ content: String) -> (sections: [UserMessagePastedSection], userText: String) {
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
      if !isUser {
        readAloudButtonRow
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
            .foregroundColor(GeminiChatTheme.primaryText.opacity(0.7))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.white.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        if !parsed.userText.isEmpty {
          Text(parsed.userText)
            .font(.system(size: 16))
            .foregroundColor(GeminiChatTheme.primaryText)
            .textSelection(.enabled)
        }
        if !message.attachedImageParts.isEmpty {
          let summary = message.attachedImageParts.count == 1
            ? (message.attachedImageParts[0].filename ?? "1 image")
            : "\(message.attachedImageParts.count) screenshots"
          Text(summary)
            .font(.caption)
            .foregroundColor(GeminiChatTheme.primaryText.opacity(0.6))
        }
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 12)
      .contentShape(Rectangle())
      .background(
        RoundedRectangle(cornerRadius: 14)
          .fill(GeminiChatTheme.userBubbleBackground)
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

  /// Read Aloud and Copy action row for assistant replies; hidden when content is empty.
  private var readAloudButtonRow: some View {
    let trimmed = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
    return Group {
      if !trimmed.isEmpty {
        HStack(spacing: 8) {
          ReadAloudButtonView(messageContent: message.content)
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
            .fill(GeminiChatTheme.secondaryText)
            .frame(width: 7, height: 7)
            .scaleEffect(scale(at: t, index: i), anchor: .center)
        }
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 10)
      .compositingGroup()
      .background(
        RoundedRectangle(cornerRadius: 14)
          .fill(GeminiChatTheme.controlBackground)
      )
      .clipShape(RoundedRectangle(cornerRadius: 14))
    }
  }
}
