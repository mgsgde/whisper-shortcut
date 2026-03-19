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

  struct PendingFile {
    let data: Data
    let mimeType: String
    let filename: String
  }

  struct PastedBlock: Identifiable {
    let id = UUID()
    let content: String
    var lineCount: Int { content.components(separatedBy: .newlines).filter { !$0.isEmpty }.count }
  }

  static let pasteThresholdLines = 30
  static let pasteThresholdChars = 1500

  func addPastedBlock(_ text: String) {
    pastedBlocks.append(PastedBlock(content: text))
  }

  func removePastedBlock(id: UUID) {
    pastedBlocks.removeAll { $0.id == id }
  }

  @Published private(set) var recentSessions: [ChatSession] = []
  @Published private(set) var currentSessionId: UUID = UUID()

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

  /// All slash commands with descriptions for autocomplete.
  static let commandSuggestions: [(command: String, description: String)] = [
    ("/new", "Start a new chat (previous chat stays in history)"),
    ("/back", "Navigate to the previous chat"),
    ("/next", "Navigate to the next chat"),
    ("/clear", "Clear current chat messages"),
    ("/screenshot", "Add a screenshot to your next message (can add multiple)"),
    ("/remember", "Trigger an immediate session memory update"),
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

  func captureScreenshot() async {
    guard !screenshotCaptureInProgress else { return }
    if pendingScreenshots.count >= Self.maxPendingScreenshots {
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

  /// Sends the current message. Pass `userInput` when the view holds the text in local state to avoid re-renders on every keystroke.
  func sendMessage(userInput: String? = nil) async {
    let raw = (userInput ?? inputText).trimmingCharacters(in: .whitespacesAndNewlines)
    let lower = raw.lowercased()
    if lower == Self.stopCommand {
      inputText = ""
      cancelSend()
      return
    }
    let hasContent = !raw.isEmpty || !pendingScreenshots.isEmpty || pendingFileAttachment != nil || !pastedBlocks.isEmpty
    guard hasContent, !isSending else { return }

    // Slash commands: do not send to API
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

    guard let credential = await GeminiCredentialProvider.shared.getCredential() else {
      errorMessage = "Add your Google API key in Settings or sign in with Google to use Gemini Chat."
      return
    }

    let sessionId = session.id
    inputText = ""
    errorMessage = nil
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
        .map { "<pasted_content>\n\($0.content)\n</pasted_content>" }
        .joined(separator: "\n\n")
      parts.append(pastedSection)
    }
    if !raw.isEmpty {
      parts.append("<typed_by_user>\n\(raw)\n</typed_by_user>")
    }
    let finalContent = parts.joined(separator: "\n\n")
    DebugLogger.log("GEMINI-CHAT: finalContent (first 300 chars): \(String(finalContent.prefix(300)))")
    pastedBlocks = []
    let userMsg = ChatMessage(role: .user, content: finalContent, attachedImageParts: attachedParts)
    appendMessage(userMsg, toSessionId: sessionId)
    let contents = buildContents()
    pendingScreenshots = []
    pendingFileAttachment = nil

    let task = Task {
      sendingSessionIds.insert(sessionId)
      defer {
        sendingSessionIds.remove(sessionId)
        sendTasks.removeValue(forKey: sessionId)
      }
      do {
        let model = Self.resolveOpenGeminiModel()
        let result = try await apiClient.sendChatMessage(
          model: model, contents: contents, credential: credential, useGrounding: true,
          systemInstruction: buildSystemInstruction())
        let modelMsg = ChatMessage(
          role: .model,
          content: result.text,
          sources: result.sources,
          groundingSupports: result.supports)
        appendMessage(modelMsg, toSessionId: sessionId)
        ContextLogger.shared.logGeminiChat(userMessage: raw, modelResponse: result.text, model: model)
        // Trigger AI title generation after the first full exchange.
        if let s = store.session(by: sessionId), s.messages.count == 2 {
          Task { await generateAITitle(sessionId: sessionId) }
        }
        // Screenshot trigger: fire immediately when the user message had attachments.
        if !attachedParts.isEmpty {
          Task { await updateSessionMemory() }
        } else {
          // Auto trigger: fire when >= geminiChatMemoryUpdateInterval undistilled messages sit outside the volatile window.
          let outsideWindow = session.messages.dropLast(AppConstants.geminiChatVolatileWindowSize)
          let undistilledCount = outsideWindow.filter { !$0.includedInMemory }.count
          if undistilledCount >= AppConstants.geminiChatMemoryUpdateInterval {
            Task { await updateSessionMemory() }
          }
        }
      } catch is CancellationError {
        DebugLogger.log("GEMINI-CHAT: Send cancelled by user")
      } catch {
        if sessionId == session.id { errorMessage = friendlyError(error) }
        DebugLogger.logError("GEMINI-CHAT: \(error.localizedDescription)")
      }
    }
    sendTasks[sessionId] = task
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

  /// Returns user-visible content for the session tab title (unwraps `<typed_by_user>...</typed_by_user>` if present).
  private static func contentForSessionTitle(_ rawContent: String) -> String {
    let open = "<typed_by_user>"
    let close = "</typed_by_user>"
    guard let r1 = rawContent.range(of: open), let r2 = rawContent.range(of: close), r1.upperBound <= r2.lowerBound else {
      return rawContent
    }
    return String(rawContent[r1.upperBound..<r2.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
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
    store.deleteSession(id: id)
    if id == session.id {
      switchToCurrentStoreSession()
    } else {
      refreshRecentSessions()
    }
    DebugLogger.log("GEMINI-CHAT: Closed tab \(id)")
  }

  private func buildContents() -> [[String: Any]] {
    let toSend = Array(messages.suffix(AppConstants.geminiChatVolatileWindowSize))
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

  private func tabStripHeader(containerWidth: CGFloat) -> some View {
    let iconWidth: CGFloat = 40
    let tabsWidth = containerWidth - iconWidth
    let tabMinWidth: CGFloat = 90
    let tabMaxWidth: CGFloat = 200
    let maxTabsFromWidth = max(1, Int(tabsWidth / tabMinWidth))
    let sessions = viewModel.visibleTabs(maxCount: maxTabsFromWidth)
    let tabWidth = min(tabMaxWidth, sessions.isEmpty ? tabMaxWidth : tabsWidth / CGFloat(sessions.count))

    return HStack(spacing: 0) {
      Image(systemName: "sparkles")
        .foregroundColor(.accentColor)
        .font(.system(size: 13, weight: .medium))
        .frame(width: iconWidth, height: 52)

      ForEach(sessions, id: \.id) { session in
        sessionTab(session: session, width: tabWidth)
      }

      Spacer()
    }
    .frame(height: 52)
  }

  private func sessionTab(session: ChatSession, width: CGFloat) -> some View {
    let isActive = session.id == viewModel.currentSessionId
    let isProcessing = viewModel.isSendingSession(session.id)
    let title = (session.title?.isEmpty == false ? session.title! : "New chat")

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
          if viewModel.isSending {
            TypingIndicatorView()
              .id("typing")
          }
          Color.clear.frame(height: 1).id("listBottom")
        }
        .frame(maxWidth: 760)
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

  @State private var inputText: String = ""
  @FocusState private var inputFocused: Bool
  @State private var measuredInputHeight: CGFloat = 0
  @State private var pasteMonitor: Any? = nil
  @AppStorage(UserDefaultsKeys.geminiCloseOnFocusLoss) private var closeOnFocusLoss: Bool = SettingsDefaults.geminiCloseOnFocusLoss
  @AppStorage(UserDefaultsKeys.selectedOpenGeminiModel) private var selectedOpenGeminiModelRaw: String = SettingsDefaults.selectedOpenGeminiModel.rawValue

  private enum AttachmentFocus: Hashable {
    case screenshot(Int), file, pastedBlock(UUID)
  }
  @FocusState private var focusedAttachment: AttachmentFocus?

  private static let inputMinHeight: CGFloat = 40
  private static let inputMaxHeight: CGFloat = 180
  private static let inputMeasurementMaxLines = 30

  private var inputHeight: CGFloat {
    min(Self.inputMaxHeight, max(Self.inputMinHeight, measuredInputHeight))
  }

  private var inputTextForSizing: String {
    var text = inputText
    if text.count > 500 { text = String(text.prefix(500)) }
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    let truncated = lines.prefix(Self.inputMeasurementMaxLines).joined(separator: "\n")
    return truncated.isEmpty ? " " : truncated
  }

  // Last whitespace-separated word at end of input — for slash-command detection.
  // Works whether "/command" is on its own line OR after other text on the same line.
  private var lastWord: String {
    let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.components(separatedBy: .whitespacesAndNewlines).last(where: { !$0.isEmpty }) ?? ""
  }

  // Input text with the last word removed (kept when a last-word command is executed).
  private var contentWithoutLastWord: String {
    let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
    let word = lastWord
    guard !word.isEmpty, let range = trimmed.range(of: word, options: .backwards),
          range.lowerBound > trimmed.startIndex else { return "" }
    return trimmed[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
  }

  // True when the composer has anything to send
  private var hasContent: Bool {
    !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || !viewModel.pendingScreenshots.isEmpty
      || viewModel.pendingFileAttachment != nil
      || !viewModel.pastedBlocks.isEmpty
  }

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
    .onReceive(NotificationCenter.default.publisher(for: .geminiFocusInput)) { _ in
      Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(50))
        inputFocused = true
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: .geminiNewChat)) { _ in
      inputText = ""
    }
    .onAppear {
      pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
        guard event.modifierFlags.contains(.command),
              event.charactersIgnoringModifiers == "v",
              let str = NSPasteboard.general.string(forType: .string) else { return event }
        let lineCount = str.components(separatedBy: .newlines).filter { !$0.isEmpty }.count
        guard lineCount >= GeminiChatViewModel.pasteThresholdLines
                || str.count >= GeminiChatViewModel.pasteThresholdChars else { return event }
        Task { @MainActor in viewModel.addPastedBlock(str) }
        return nil
      }
    }
    .onDisappear {
      if let monitor = pasteMonitor { NSEvent.removeMonitor(monitor) }
    }
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
          .frame(maxWidth: 760)
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
      // Composer box: chips + text editor
      VStack(spacing: 0) {
        if !viewModel.pendingScreenshots.isEmpty || viewModel.pendingFileAttachment != nil || !viewModel.pastedBlocks.isEmpty {
          attachmentChipsRow
        }
        ZStack(alignment: .topLeading) {
          Text(inputTextForSizing)
            .font(.system(size: 16))
            .padding(.horizontal, 18)
            .padding(.vertical, 13)
            .fixedSize(horizontal: false, vertical: true)
            .background(GeometryReader { geo in
              Color.clear.preference(key: InputTextHeightKey.self, value: geo.size.height)
            })
            .frame(maxWidth: .infinity, maxHeight: Self.inputMaxHeight, alignment: .leading)
            .opacity(0)
            .accessibilityHidden(true)

          if inputText.isEmpty {
            Text("Message Gemini…")
              .font(.system(size: 16))
              .foregroundColor(GeminiChatTheme.secondaryText.opacity(0.5))
              .padding(.leading, 18)
              .padding(.trailing, 12)
              .padding(.vertical, 13)
              .allowsHitTesting(false)
          }
          TextEditor(text: $inputText)
            .scrollContentBackground(.hidden)
            .font(.system(size: 16))
            .foregroundColor(GeminiChatTheme.primaryText)
            .focused($inputFocused)
            .onKeyPress(.tab) {
              let word = lastWord
              if word.hasPrefix("/"), !word.isEmpty {
                let matches = viewModel.suggestedCommands(for: word)
                if let first = matches.first {
                  inputText = contentWithoutLastWord
                  Task { await viewModel.sendMessage(userInput: first) }
                  return .handled
                }
              }
              return .ignored
            }
            .onKeyPress { keyPress in
              if keyPress.modifiers.contains(.command), keyPress.characters == ".", viewModel.isSending {
                viewModel.cancelSend()
                return .handled
              }
              if keyPress.key == .delete, inputText.isEmpty {
                if !viewModel.pastedBlocks.isEmpty {
                  viewModel.removePastedBlock(id: viewModel.pastedBlocks.last!.id)
                  return .handled
                } else if viewModel.pendingFileAttachment != nil {
                  viewModel.clearPendingFile()
                  return .handled
                } else if !viewModel.pendingScreenshots.isEmpty {
                  viewModel.removePendingScreenshot(at: viewModel.pendingScreenshots.count - 1)
                  return .handled
                }
              }
              guard keyPress.key == .return else { return .ignored }
              if keyPress.modifiers.contains(.shift) {
                return .ignored
              }
              let word = lastWord
              if word.hasPrefix("/"), !word.isEmpty {
                let matches = viewModel.suggestedCommands(for: word)
                if let first = matches.first, word.lowercased() == first.lowercased() {
                  inputText = contentWithoutLastWord
                  Task { await viewModel.sendMessage(userInput: word) }
                  return .handled
                }
              }
              let toSend = inputText
              inputText = ""
              Task { await viewModel.sendMessage(userInput: toSend) }
              return .handled
            }
            .onAppear { inputFocused = true }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .frame(height: inputHeight)
            .background(GeminiInputScrollViewAutohideAnchor())
        }
        .frame(height: inputHeight)
        .onPreferenceChange(InputTextHeightKey.self) { measuredInputHeight = $0 }
      }

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

        // Send / Stop button
        Button(action: {
          if viewModel.isSending {
            viewModel.cancelSend()
          } else {
            let toSend = inputText
            inputText = ""
            Task { await viewModel.sendMessage(userInput: toSend) }
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
    .frame(maxWidth: 760)
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
      inputFocused = true
    }
  }

  // MARK: - Attachment chips row (inside composer box)

  private var attachmentChipsRow: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 6) {
        ForEach(Array(viewModel.pendingScreenshots.enumerated()), id: \.offset) { index, data in
          screenshotChip(data: data, index: index)
        }
        if viewModel.pendingFileAttachment != nil {
          fileChip
        }
        ForEach(viewModel.pastedBlocks) { block in
          pastedBlockChip(block)
        }
      }
      .padding(.horizontal, 10)
      .padding(.top, 8)
      .padding(.bottom, 4)
    }
  }

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
    return HStack(spacing: 5) {
      Image(systemName: "doc.plaintext")
        .font(.caption)
        .foregroundColor(GeminiChatTheme.secondaryText)
      Text("Pasted · \(block.lineCount) lines")
        .font(.caption)
        .foregroundColor(GeminiChatTheme.primaryText)
      Button(action: { viewModel.removePastedBlock(id: block.id); inputFocused = true }) {
        Image(systemName: "xmark")
          .font(.system(size: 8, weight: .bold))
          .foregroundColor(GeminiChatTheme.secondaryText)
      }
      .buttonStyle(.plain)
      .help("Remove pasted text")
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
    .accessibilityLabel("Pasted content, \(block.lineCount) lines. Press Delete to remove.")
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
}

// MARK: - Model Reply View

private struct ModelReplyView: View {
  let content: String
  let sources: [GroundingSource]
  let groundingSupports: [GroundingSupport]

  var body: some View {
    if Self.contentHasTable(content) {
      tableAwareBody
    } else {
      Text(Self.buildAttributedReply(content: content, sources: sources, groundingSupports: groundingSupports))
        .font(.system(size: 16))
        .lineSpacing(8)
        .foregroundColor(GeminiChatTheme.primaryText)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .contentShape(Rectangle())
        .textSelection(.enabled)
        .onHover { inside in
          if inside { NSCursor.iBeam.push() } else { NSCursor.pop() }
        }
    }
  }

  private var tableAwareBody: some View {
    let blocks = Self.buildReplyBlocks(content: content, sources: sources, groundingSupports: groundingSupports)
    return VStack(alignment: .leading, spacing: 16) {
      ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
        switch block {
        case .text(let attrStr):
          Text(attrStr)
            .font(.system(size: 16))
            .lineSpacing(8)
            .foregroundColor(GeminiChatTheme.primaryText)
            .textSelection(.enabled)
        case .table(let parsed):
          MarkdownTableView(headers: parsed.headers, rows: parsed.rows)
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
    var textBuffer = AttributedString()
    let separator = AttributedString("\n\n")
    var hasTextContent = false
    for para in paragraphs {
      let trimmed = para.text.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.isEmpty { continue }
      if MarkdownParsing.looksLikeMarkdownTable(trimmed), let parsed = MarkdownParsing.parseMarkdownTable(trimmed) {
        if hasTextContent {
          blocks.append(.text(textBuffer))
          textBuffer = AttributedString()
          hasTextContent = false
        }
        blocks.append(.table(parsed))
      } else {
        if hasTextContent { textBuffer.append(separator) }
        let attrText = buildSingleParagraphAttributed(trimmed, options: options)
        textBuffer.append(attrText)
        for idx in para.chunkIndices where idx < sources.count {
          let oneBased = idx + 1
          var markerAttr = AttributedString(" [\(oneBased)]")
          markerAttr.font = .system(size: 14)
          if let url = URL(string: sources[idx].uri) { markerAttr.link = url }
          textBuffer.append(markerAttr)
        }
        hasTextContent = true
      }
    }
    if hasTextContent { blocks.append(.text(textBuffer)) }
    return blocks.isEmpty ? [.text(AttributedString(content))] : blocks
  }

  private static func buildContentOnlyBlocks(
    content: String,
    options: AttributedString.MarkdownParsingOptions
  ) -> [ReplyContentBlock] {
    let paragraphs = MarkdownParsing.normalizeMarkdownParagraphBreaks(content).components(separatedBy: "\n\n")
    var blocks: [ReplyContentBlock] = []
    var textBuffer = AttributedString()
    let separator = AttributedString("\n\n")
    var hasTextContent = false
    for para in paragraphs {
      let trimmed = para.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.isEmpty { continue }
      if MarkdownParsing.looksLikeMarkdownTable(trimmed), let parsed = MarkdownParsing.parseMarkdownTable(trimmed) {
        if hasTextContent {
          blocks.append(.text(textBuffer))
          textBuffer = AttributedString()
          hasTextContent = false
        }
        blocks.append(.table(parsed))
      } else {
        if hasTextContent { textBuffer.append(separator) }
        let attrText = buildSingleParagraphAttributed(trimmed, options: options)
        textBuffer.append(attrText)
        hasTextContent = true
      }
    }
    if hasTextContent { blocks.append(.text(textBuffer)) }
    return blocks.isEmpty ? [.text(AttributedString(content))] : blocks
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
      let content = MarkdownParsing.parseBullet(line)!.trimmingCharacters(in: .whitespaces)
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
    if trimmed.hasPrefix("```") && trimmed.hasSuffix("```") {
      let codeContent = String(trimmed.dropFirst(3).dropLast(3).trimmingCharacters(in: .whitespacesAndNewlines))
      var attr = AttributedString(codeContent)
      attr.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
      return attr
    }
    if let bulletAttr = buildBulletListAttributed(trimmed) { return bulletAttr }
    let fullOptions = AttributedString.MarkdownParsingOptions(interpretedSyntax: .full)
    var attr = (try? AttributedString(markdown: trimmed, options: fullOptions)) ?? AttributedString(trimmed)
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
    let paragraphs = MarkdownParsing.normalizeMarkdownParagraphBreaks(content).components(separatedBy: "\n\n")
    var result = AttributedString()
    let separator = AttributedString("\n\n")
    for (index, para) in paragraphs.enumerated() {
      let trimmed = para.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.isEmpty { continue }
      if index > 0 { result.append(separator) }
      if MarkdownParsing.isSeparatorParagraph(trimmed) {
        var lineAttr = AttributedString(MarkdownParsing.separatorLineContent)
        lineAttr.foregroundColor = GeminiChatTheme.primaryText.opacity(0.4)
        result.append(lineAttr)
        continue
      }
      if let (level, title) = MarkdownParsing.parseATXHeading(trimmed) {
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
      } else if trimmed.hasPrefix("```") && trimmed.hasSuffix("```") {
        let codeContent = String(trimmed.dropFirst(3).dropLast(3).trimmingCharacters(in: .whitespacesAndNewlines))
        var attr = AttributedString(codeContent)
        attr.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        result.append(attr)
      } else if let bulletAttr = buildBulletListAttributed(trimmed) {
        result.append(bulletAttr)
      } else {
        let fullOptions = AttributedString.MarkdownParsingOptions(interpretedSyntax: .full)
        var attr = (try? AttributedString(markdown: trimmed, options: fullOptions)) ?? AttributedString(trimmed)
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

// MARK: - Message Bubble

private struct MessageBubbleView: View {
  let message: ChatMessage
  var onTapAttachedImage: ((Data) -> Void)? = nil

  var isUser: Bool { message.role == .user }

  static func parsePastedContent(_ content: String) -> (pastedSections: [String], userText: String) {
    var remaining = content
    var pasted: [String] = []
    let open = "<pasted_content>"
    let close = "</pasted_content>"
    while let r1 = remaining.range(of: open), let r2 = remaining.range(of: close), r1.upperBound <= r2.lowerBound {
      pasted.append(String(remaining[r1.upperBound..<r2.lowerBound]))
      remaining = String(remaining[r2.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    let userText = Self.unwrapTypedByUser(remaining)
    return (pasted, userText)
  }

  /// Extracts inner text from `<typed_by_user>...</typed_by_user>` for display; returns unchanged if no wrapper.
  private static func unwrapTypedByUser(_ s: String) -> String {
    let open = "<typed_by_user>"
    let close = "</typed_by_user>"
    guard let r1 = s.range(of: open), let r2 = s.range(of: close), r1.upperBound <= r2.lowerBound else {
      return s
    }
    return String(s[r1.upperBound..<r2.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
  }

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
    .frame(maxWidth: isUser ? 560 : .infinity, alignment: isUser ? .trailing : .leading)
    .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
  }

  @ViewBuilder
  private var bubbleContent: some View {
    if isUser {
      VStack(alignment: .trailing, spacing: 6) {
        let parsed = Self.parsePastedContent(message.content)
        ForEach(Array(parsed.pastedSections.enumerated()), id: \.offset) { _, pasted in
          let lines = pasted.components(separatedBy: .newlines).filter { !$0.isEmpty }.count
          Label("\(lines) lines pasted", systemImage: "doc.plaintext")
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
  @State private var dotScale: [CGFloat] = [1, 1, 1]

  var body: some View {
    HStack(spacing: 4) {
      ForEach(0..<3, id: \.self) { i in
        Circle()
          .fill(GeminiChatTheme.secondaryText)
          .frame(width: 7, height: 7)
          .scaleEffect(dotScale[i])
          .animation(
            .easeInOut(duration: 0.5)
              .repeatForever()
              .delay(Double(i) * 0.15),
            value: dotScale[i]
          )
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .background(
      RoundedRectangle(cornerRadius: 14)
        .fill(GeminiChatTheme.controlBackground)
    )
    .onAppear {
      for i in 0..<3 {
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.15) {
          dotScale[i] = 0.4
        }
      }
    }
  }
}
