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
  @Published var pendingScreenshot: Data? = nil
  @Published var screenshotCaptureInProgress: Bool = false
  @Published var pendingFileAttachment: PendingFile? = nil

  struct PendingFile {
    let data: Data
    let mimeType: String
    let filename: String
  }
  @Published private(set) var recentSessions: [ChatSession] = []
  @Published private(set) var currentSessionId: UUID = UUID()

  private var session: ChatSession
  private let store = GeminiChatSessionStore.shared
  private let apiClient = GeminiAPIClient()

  /// In-flight send tasks keyed by session ID — multiple sessions can be sending simultaneously.
  private var sendTasks: [UUID: Task<Void, Never>] = [:]

  /// Returns true if the given session has an in-flight request (for tab spinner).
  func isSendingSession(_ id: UUID) -> Bool { sendingSessionIds.contains(id) }

  /// Maximum number of messages to send as context (older messages are kept in UI but not sent to the API).
  private static let maxMessagesInContext = 30
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

  /// All slash commands with descriptions for autocomplete.
  static let commandSuggestions: [(command: String, description: String)] = [
    ("/new", "Start a new chat (previous chat stays in history)"),
    ("/back", "Navigate to the previous chat"),
    ("/next", "Navigate to the next chat"),
    ("/clear", "Clear current chat messages"),
    ("/screenshot", "Capture screen (attached to your next message)"),
    ("/settings", "Open Settings"),
    ("/pin", "Toggle whether the window stays open when losing focus"),
    ("/stop", "Stop sending (while a message is being sent)")
  ]

  /// Returns commands whose command string matches the given prefix (e.g. "/" or "/sc").
  func suggestedCommands(for input: String) -> [String] {
    let prefix = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard prefix.hasPrefix("/") else { return [] }
    return Self.commandSuggestions
      .map(\.command)
      .filter { $0.lowercased().hasPrefix(prefix) || prefix.isEmpty }
  }

  var canGoBack: Bool { store.canGoBack() }
  var canGoForward: Bool { store.canGoForward() }

  init() {
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
    pendingScreenshot = nil
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
    pendingScreenshot = nil
    refreshRecentSessions()
  }

  func captureScreenshot() async {
    guard !screenshotCaptureInProgress else { return }
    screenshotCaptureInProgress = true
    errorMessage = nil
    DebugLogger.log("GEMINI-CHAT: Starting screen capture (window will hide briefly)")
    let data = await GeminiWindowManager.shared.captureScreenExcludingGeminiWindow()
    screenshotCaptureInProgress = false
    if let data = data {
      pendingScreenshot = data
      DebugLogger.log("GEMINI-CHAT: Screenshot attached to next message")
    } else {
      errorMessage = "Screen capture failed. Check Screen Recording permission for this app in System Preferences > Privacy & Security."
      DebugLogger.log("GEMINI-CHAT: Screen capture returned nil")
    }
  }

  func clearPendingScreenshot() {
    pendingScreenshot = nil
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
    pendingScreenshot = nil
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
    let hasContent = !raw.isEmpty || pendingScreenshot != nil || pendingFileAttachment != nil
    guard hasContent, !isSending else { return }

    // Slash commands: do not send to API
    if lower == Self.newChatCommand || lower == Self.backChatCommand || lower == Self.nextChatCommand
        || Self.clearChatCommands.contains(lower) || lower == Self.screenshotCommand
        || lower == Self.settingsCommand || lower == Self.pinCommand {
      inputText = ""
      if lower == Self.newChatCommand { createNewSession() }
      else if lower == Self.backChatCommand { goBack() }
      else if lower == Self.nextChatCommand { goForward() }
      else if Self.clearChatCommands.contains(lower) { clearMessages() }
      else if lower == Self.settingsCommand { SettingsManager.shared.showSettings() }
      else if lower == Self.pinCommand { togglePin() }
      else { await captureScreenshot() }
      return
    }

    guard let apiKey = KeychainManager.shared.getGoogleAPIKey(), !apiKey.isEmpty else {
      errorMessage = "No API key configured. Please add your Google API key in Settings."
      return
    }

    let sessionId = session.id
    inputText = ""
    errorMessage = nil
    let attachment: (data: Data, mimeType: String, filename: String)?
    if let file = pendingFileAttachment {
      attachment = (file.data, file.mimeType, file.filename)
    } else if let screenshot = pendingScreenshot {
      attachment = (screenshot, "image/png", "screenshot.png")
    } else {
      attachment = nil
    }
    let userMsg = ChatMessage(
      role: .user, content: raw,
      attachedImageData: attachment?.data,
      attachedFileMimeType: attachment?.mimeType,
      attachedFilename: attachment?.filename)
    appendMessage(userMsg, toSessionId: sessionId)
    let contents = buildContents()
    pendingScreenshot = nil
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
          model: model, contents: contents, apiKey: apiKey, useGrounding: true,
          systemInstruction: Self.buildGeminiChatSystemInstruction())
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
    session.lastUpdated = Date()
    store.save(session)
    refreshRecentSessions()
    DebugLogger.log("GEMINI-CHAT: Cleared current chat messages")
  }

  // MARK: - Private

  /// Builds the system instruction for the Open Gemini chat from the stored Gemini Chat system prompt (Settings > Context > system-prompts.md).
  private static func buildGeminiChatSystemInstruction() -> [String: Any] {
    let text = SystemPromptsStore.shared.loadGeminiChatSystemPrompt()
    return ["parts": [["text": text]]]
  }

  /// Resolves the model ID for the Open Gemini chat window from UserDefaults (Settings > Open Gemini).
  private static func resolveOpenGeminiModel() -> String {
    openGeminiModel.rawValue
  }

  /// Resolves the selected Open Gemini model for display (e.g. "Gemini 3 Flash").
  static var openGeminiModel: PromptModel {
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
      let oneLine = message.content.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
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
    guard let apiKey = KeychainManager.shared.getGoogleAPIKey(), !apiKey.isEmpty else { return }
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
        model: "gemini-2.5-flash-lite", prompt: prompt, apiKey: apiKey)
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
    let toSend = Array(messages.suffix(Self.maxMessagesInContext))
    return toSend.enumerated().map { index, msg in
      let isLastUserWithImage = index == toSend.count - 1 && msg.role == .user && msg.attachedImageData != nil
      if isLastUserWithImage, let imageData = msg.attachedImageData {
        let base64 = imageData.base64EncodedString()
        let mimeType = msg.attachedFileMimeType ?? "image/png"
        var parts: [[String: Any]] = [["inline_data": ["mime_type": mimeType, "data": base64]]]
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
  @StateObject private var viewModel = GeminiChatViewModel()
  /// Image data to show in the full-size preview sheet (from pending screenshot or from a sent message thumbnail).
  @State private var previewImageData: Data? = nil
  @State private var scrollActions = GeminiScrollActions()
  @State private var hoveredTabId: UUID? = nil

  var body: some View {
    GeometryReader { geometry in
      VStack(spacing: 0) {
        tabStripHeader(containerWidth: geometry.size.width)
        Divider()
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
      viewModel.createNewSession()
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
        VStack(alignment: .leading, spacing: 18) {
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
        .padding(.horizontal, 20)
        .padding(.top, 10)
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
    VStack(alignment: .leading, spacing: 12) {
      Text("Commands")
        .font(.headline)
        .fontWeight(.semibold)
        .foregroundColor(GeminiChatTheme.secondaryText)
      VStack(alignment: .leading, spacing: 8) {
        Text("/new — Start a new chat (previous chat stays in history)")
          .font(.body)
          .foregroundColor(GeminiChatTheme.secondaryText)
        Text("/back — Navigate to the previous chat")
          .font(.body)
          .foregroundColor(GeminiChatTheme.secondaryText)
        Text("/next — Navigate to the next chat")
          .font(.body)
          .foregroundColor(GeminiChatTheme.secondaryText)
        Text("/screenshot — Capture screen (attached to your next message)")
          .font(.body)
          .foregroundColor(GeminiChatTheme.secondaryText)
        Text("/clear — Clear current chat messages")
          .font(.body)
          .foregroundColor(GeminiChatTheme.secondaryText)
        Text("/settings — Open Settings")
          .font(.body)
          .foregroundColor(GeminiChatTheme.secondaryText)
        Text("/pin — Toggle whether the window stays open when losing focus")
          .font(.body)
          .foregroundColor(GeminiChatTheme.secondaryText)
        Text("/stop — Stop sending (while a message is being sent)")
          .font(.body)
          .foregroundColor(GeminiChatTheme.secondaryText)
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
  @AppStorage(UserDefaultsKeys.geminiCloseOnFocusLoss) private var closeOnFocusLoss: Bool = SettingsDefaults.geminiCloseOnFocusLoss

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
  }

  // MARK: - Command autocomplete

  private var commandSuggestionsOverlay: some View {
    Group {
      if inputText.hasPrefix("/") {
        let suggestions = GeminiChatViewModel.commandSuggestions
          .filter { $0.command.lowercased().hasPrefix(inputText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) }
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
          .padding(.horizontal, 20)
          .padding(.bottom, 4)
        }
      }
    }
  }

  // MARK: - Action Buttons Row

  private var actionButtonsRow: some View {
    HStack(spacing: 4) {
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
    }
  }

  // MARK: - Input Bar

  private var inputBar: some View {
    VStack(alignment: .leading, spacing: 8) {
      actionButtonsRow
      if viewModel.pendingScreenshot != nil {
        pendingScreenshotThumbnail
      }
      if viewModel.pendingFileAttachment != nil {
        pendingFileThumbnail
      }
      HStack(alignment: .center, spacing: 8) {
        ZStack(alignment: .topLeading) {
          Text(inputTextForSizing)
            .font(.body)
            .padding(.horizontal, 15)
            .padding(.vertical, 10)
            .fixedSize(horizontal: false, vertical: true)
            .background(GeometryReader { geo in
              Color.clear.preference(key: InputTextHeightKey.self, value: geo.size.height)
            })
            .frame(maxWidth: .infinity, maxHeight: Self.inputMaxHeight, alignment: .leading)
            .opacity(0)
            .accessibilityHidden(true)

          if inputText.isEmpty {
            Text("Message Gemini…")
              .font(.body)
              .foregroundColor(GeminiChatTheme.secondaryText.opacity(0.5))
              .padding(.leading, 15)
              .padding(.trailing, 10)
              .padding(.vertical, 10)
              .allowsHitTesting(false)
          }
          TextEditor(text: $inputText)
            .scrollContentBackground(.hidden)
            .font(.body)
            .foregroundColor(GeminiChatTheme.primaryText)
            .focused($inputFocused)
            .onKeyPress(.tab) {
              let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
              if text.hasPrefix("/"), !text.isEmpty {
                let matches = viewModel.suggestedCommands(for: text)
                if let first = matches.first {
                  inputText = ""
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
              guard keyPress.key == .return else { return .ignored }
              if keyPress.modifiers.contains(.shift) {
                // Let NSTextView handle Shift+Return natively: inserts "\n" at cursor position
                // and automatically scrolls the cursor into view — no SwiftUI string reset.
                return .ignored
              }
              let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
              if text.hasPrefix("/"), !text.isEmpty {
                let matches = viewModel.suggestedCommands(for: text)
                if let first = matches.first, text.lowercased() == first.lowercased() {
                  let toSend = inputText
                  inputText = ""
                  Task { await viewModel.sendMessage(userInput: toSend) }
                  return .handled
                }
              }
              let toSend = inputText
              inputText = ""
              Task { await viewModel.sendMessage(userInput: toSend) }
              return .handled
            }
            .onAppear { inputFocused = true }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .frame(height: inputHeight)
            .background(GeminiInputScrollViewAutohideAnchor())
        }
        .frame(height: inputHeight)
        .onPreferenceChange(InputTextHeightKey.self) { measuredInputHeight = $0 }
        .background(GeminiChatTheme.controlBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))

        if viewModel.isSending {
          Button(action: { viewModel.cancelSend() }) {
            Image(systemName: "stop.circle.fill")
              .font(.system(size: 24))
              .foregroundColor(GeminiChatTheme.secondaryText)
          }
          .buttonStyle(.plain)
          .help("Stop sending (/stop)")
          .frame(width: 28, height: 28)
          .pointerCursorOnHover()
        }

        Button(action: {
          let toSend = inputText
          inputText = ""
          Task { await viewModel.sendMessage(userInput: toSend) }
        }) {
          if viewModel.isSending {
            ProgressView()
              .controlSize(.small)
              .frame(width: 28, height: 28)
          } else {
            Image(systemName: "arrow.up.circle.fill")
              .font(.system(size: 24))
              .foregroundColor(
                (inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && viewModel.pendingScreenshot == nil)
                  ? GeminiChatTheme.secondaryText : .accentColor)
          }
        }
        .buttonStyle(.plain)
        .disabled(
          (inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && viewModel.pendingScreenshot == nil)
            || viewModel.isSending)
        .frame(width: 28, height: 28)
        .pointerCursorOnHover()
      }
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 10)
    .contentShape(Rectangle())
    .onTapGesture {
      inputFocused = true
    }
  }

  private var pendingFileThumbnail: some View {
    HStack(spacing: 8) {
      if let file = viewModel.pendingFileAttachment {
        if file.mimeType.hasPrefix("image/"), let img = NSImage(data: file.data) {
          Image(nsImage: img)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: 48, height: 32)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
          Image(systemName: file.mimeType == "application/pdf" ? "doc.richtext" : "doc")
            .font(.system(size: 22))
            .foregroundColor(GeminiChatTheme.secondaryText)
            .frame(width: 48, height: 32)
        }
        VStack(alignment: .leading, spacing: 2) {
          Text(file.filename)
            .font(.caption)
            .foregroundColor(GeminiChatTheme.primaryText)
            .lineLimit(1)
          Text("Will be attached to your next message")
            .font(.caption)
            .foregroundColor(GeminiChatTheme.secondaryText)
        }
      }
      Spacer()
      Button(action: { viewModel.clearPendingFile() }) {
        Image(systemName: "xmark.circle.fill")
          .font(.system(size: 18))
          .foregroundColor(GeminiChatTheme.secondaryText)
      }
      .buttonStyle(.plain)
      .help("Remove attachment")
      .pointerCursorOnHover()
    }
    .padding(8)
    .background(GeminiChatTheme.controlBackground.opacity(0.8))
    .clipShape(RoundedRectangle(cornerRadius: 8))
  }

  private var pendingScreenshotThumbnail: some View {
    HStack(spacing: 8) {
      if let data = viewModel.pendingScreenshot,
         let nsImage = NSImage(data: data) {
        Image(nsImage: nsImage)
          .resizable()
          .aspectRatio(contentMode: .fill)
          .frame(width: 48, height: 32)
          .clipped()
          .clipShape(RoundedRectangle(cornerRadius: 6))
          .contentShape(Rectangle())
          .onTapGesture { onTapScreenshotThumbnail(data) }
          .help("Click to view full size")
          .pointerCursorOnHover()
      }
      Text("Screenshot will be attached to your next message")
        .font(.caption)
        .foregroundColor(GeminiChatTheme.secondaryText)
      Spacer()
      Button(action: { viewModel.clearPendingScreenshot() }) {
        Image(systemName: "xmark.circle.fill")
          .font(.system(size: 18))
          .foregroundColor(GeminiChatTheme.secondaryText)
      }
      .buttonStyle(.plain)
      .help("Remove screenshot")
      .pointerCursorOnHover()
    }
    .padding(8)
    .background(GeminiChatTheme.controlBackground.opacity(0.8))
    .clipShape(RoundedRectangle(cornerRadius: 8))
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

// MARK: - Model Reply View

private struct ModelReplyView: View {
  let content: String
  let sources: [GroundingSource]
  let groundingSupports: [GroundingSupport]

  /// Single Text view so the user can select across the entire reply. With grounding, citation markers [1], [2] appear at the end of each paragraph and are clickable links. No bubble background — answers use the window background only.
  var body: some View {
    Text(Self.buildAttributedReply(content: content, sources: sources, groundingSupports: groundingSupports))
      .font(.system(size: 15))
      .lineSpacing(4)
      .foregroundColor(GeminiChatTheme.primaryText)
      .padding(.horizontal, 14)
      .padding(.vertical, 12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .fixedSize(horizontal: false, vertical: true)
      .contentShape(Rectangle())
      .textSelection(.enabled)
      .onHover { inside in
        if inside {
          NSCursor.iBeam.push()
        } else {
          NSCursor.pop()
        }
      }
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
      let attrText = buildAttributedReplyContentOnly(content: para.text, options: options)
      result.append(attrText)
      for idx in para.chunkIndices {
        let oneBased = idx + 1
        let marker = " [\(oneBased)]"
        var markerAttr = AttributedString(marker)
        markerAttr.font = .system(size: 13)
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
    let paragraphs = content.components(separatedBy: "\n\n")
    var result = AttributedString()
    let separator = AttributedString("\n\n")
    for (index, para) in paragraphs.enumerated() {
      let trimmed = para.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.isEmpty { continue }
      if index > 0 { result.append(separator) }
      var attr: AttributedString
      if trimmed.hasPrefix("## ") {
        let title = String(trimmed.dropFirst(3))
        attr = (try? AttributedString(markdown: title, options: options)) ?? AttributedString(title)
        attr.font = .system(size: 15, weight: .bold)
      } else if trimmed.hasPrefix("### ") {
        let title = String(trimmed.dropFirst(4))
        attr = (try? AttributedString(markdown: title, options: options)) ?? AttributedString(title)
        attr.font = .system(size: 14, weight: .semibold)
      } else if trimmed.hasPrefix("```") && trimmed.hasSuffix("```") {
        // Fenced code block (e.g. from code execution): show in monospace so it is visibly distinct
        let codeContent = String(trimmed.dropFirst(3).dropLast(3).trimmingCharacters(in: .whitespacesAndNewlines))
        attr = AttributedString(codeContent)
        attr.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
      } else {
        attr = (try? AttributedString(markdown: trimmed, options: options)) ?? AttributedString(trimmed)
        attr.font = .system(size: 15, weight: .regular)
      }
      result.append(attr)
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
        if !message.content.isEmpty {
          Text(message.content)
            .font(.system(size: 15))
            .foregroundColor(GeminiChatTheme.primaryText)
            .textSelection(.enabled)
        }
        if let filename = message.attachedFilename {
          Text(filename)
            .font(.caption)
            .foregroundColor(GeminiChatTheme.primaryText.opacity(0.6))
        }
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 10)
      .contentShape(Rectangle())
      .background(
        RoundedRectangle(cornerRadius: 14)
          .fill(Color.accentColor)
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
    HStack(alignment: .top, spacing: 12) {
      HStack(spacing: 4) {
        Image(systemName: "globe")
          .font(.caption2)
          .foregroundColor(GeminiChatTheme.secondaryText)
        Text("Sources")
          .font(.caption2)
          .foregroundColor(GeminiChatTheme.secondaryText)
      }
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
    }
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
