import SwiftUI
import AppKit

// MARK: - ViewModel

@MainActor
class GeminiChatViewModel: ObservableObject {
  @Published var messages: [ChatMessage] = []
  @Published var inputText: String = ""
  @Published var isSending: Bool = false
  @Published var errorMessage: String? = nil
  @Published var pendingScreenshot: Data? = nil
  @Published var screenshotCaptureInProgress: Bool = false

  private var session: ChatSession
  private let store = GeminiChatSessionStore.shared
  private let apiClient = GeminiAPIClient()

  /// Current send task; cancelled by Stop button.
  private var sendTask: Task<Void, Never>?

  /// Maximum number of messages to send as context (older messages are kept in UI but not sent to the API).
  private static let maxMessagesInContext = 30
  /// Maximum length for auto-generated session title from first user message.
  private static let maxSessionTitleLength = 50
  /// Commands are slash-only (e.g. /stop, /new); do not use hotkeys/shortcuts for command actions.
  private static let newChatCommand = "/new"
  private static let backChatCommand = "/back"
  private static let clearChatCommands = ["/clear"]
  static let screenshotCommand = "/screenshot"
  private static let stopCommand = "/stop"
  private static let settingsCommand = "/settings"

  /// All slash commands with descriptions for autocomplete.
  static let commandSuggestions: [(command: String, description: String)] = [
    ("/new", "Start a new chat (previous chat stays in history)"),
    ("/back", "Switch to the previous chat"),
    ("/clear", "Clear current chat messages"),
    ("/screenshot", "Capture screen (attached to your next message)"),
    ("/settings", "Open Settings"),
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

  var canGoBack: Bool {
    store.idForBack() != nil || store.previousSessionId(current: session.id) != nil
  }

  init() {
    session = store.load()
    messages = session.messages
  }

  func createNewSession() {
    let newSession = store.createNewSession()
    session = newSession
    messages = []
    errorMessage = nil
    inputText = ""
    pendingScreenshot = nil
    DebugLogger.log("GEMINI-CHAT: Switched to new chat")
  }

  func goBack() {
    let prevId = store.idForBack() ?? store.previousSessionId(current: session.id)
    guard let prevId = prevId else { return }
    store.setCurrentSession(id: prevId, clearBack: true)
    session = store.load()
    messages = session.messages
    errorMessage = nil
    pendingScreenshot = nil
    DebugLogger.log("GEMINI-CHAT: Switched back to previous chat \(prevId)")
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

  /// Cancels the in-flight send request. Call from the Stop button.
  func cancelSend() {
    sendTask?.cancel()
  }

  func sendMessage() async {
    let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
    let lower = text.lowercased()
    if lower == Self.stopCommand {
      inputText = ""
      cancelSend()
      return
    }
    let hasContent = !text.isEmpty || pendingScreenshot != nil
    guard hasContent, !isSending else { return }

    // Slash commands: do not send to API
    if lower == Self.newChatCommand || lower == Self.backChatCommand
        || Self.clearChatCommands.contains(lower) || lower == Self.screenshotCommand
        || lower == Self.settingsCommand {
      inputText = ""
      if lower == Self.newChatCommand { createNewSession() }
      else if lower == Self.backChatCommand { goBack() }
      else if Self.clearChatCommands.contains(lower) { clearMessages() }
      else if lower == Self.settingsCommand { SettingsManager.shared.showSettings() }
      else { await captureScreenshot() }
      return
    }

    guard let apiKey = KeychainManager.shared.getGoogleAPIKey(), !apiKey.isEmpty else {
      errorMessage = "No API key configured. Please add your Google API key in Settings."
      return
    }

    inputText = ""
    errorMessage = nil
    let userMsg = ChatMessage(role: .user, content: text, attachedImageData: pendingScreenshot)
    appendMessage(userMsg)
    let contents = buildContents()
    pendingScreenshot = nil

    sendTask = Task {
      isSending = true
      defer {
        isSending = false
        sendTask = nil
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
        appendMessage(modelMsg)
        ContextLogger.shared.logGeminiChat(userMessage: text, modelResponse: result.text, model: model)
      } catch is CancellationError {
        // User tapped Stop; do not append model message or set errorMessage
        DebugLogger.log("GEMINI-CHAT: Send cancelled by user")
      } catch {
        errorMessage = friendlyError(error)
        DebugLogger.logError("GEMINI-CHAT: \(error.localizedDescription)")
      }
    }
  }

  func clearMessages() {
    messages = []
    session.messages = []
    session.lastUpdated = Date()
    store.save(session)
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

  private func appendMessage(_ message: ChatMessage) {
    let isFirstUserMessage = message.role == .user && messages.isEmpty
    messages.append(message)
    session.messages = messages
    session.lastUpdated = Date()
    if isFirstUserMessage {
      let oneLine = message.content.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
      session.title = String(oneLine.prefix(Self.maxSessionTitleLength))
      if oneLine.count > Self.maxSessionTitleLength { session.title? += "…" }
    }
    store.save(session)
  }

  private func buildContents() -> [[String: Any]] {
    let toSend = Array(messages.suffix(Self.maxMessagesInContext))
    return toSend.enumerated().map { index, msg in
      let isLastUserWithImage = index == toSend.count - 1 && msg.role == .user && msg.attachedImageData != nil
      if isLastUserWithImage, let imageData = msg.attachedImageData {
        let base64 = imageData.base64EncodedString()
        var parts: [[String: Any]] = [["inline_data": ["mime_type": "image/png", "data": base64]]]
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
  @FocusState private var inputFocused: Bool
  /// Image data to show in the full-size preview sheet (from pending screenshot or from a sent message thumbnail).
  @State private var previewImageData: Data? = nil
  @State private var scrollActions = GeminiScrollActions()
  @State private var measuredInputHeight: CGFloat = 0

  var body: some View {
    GeometryReader { geometry in
      VStack(spacing: 0) {
        headerBar
        Divider()
        messageList(scrollActions: scrollActions, containerWidth: geometry.size.width)
        if let error = viewModel.errorMessage {
          errorBanner(error)
        }
        Divider()
        commandSuggestionsOverlay
        inputBar
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
    .onReceive(NotificationCenter.default.publisher(for: .geminiScrollToTop)) { _ in
      scrollActions.scrollToTop?()
    }
    .onReceive(NotificationCenter.default.publisher(for: .geminiScrollToBottom)) { _ in
      scrollActions.scrollToBottom?()
    }
  }

  // MARK: - Header

  private var headerBar: some View {
    HStack {
      HStack(spacing: 6) {
        Image(systemName: "sparkles")
          .foregroundColor(.accentColor)
        Text(viewModel.openGeminiModelDisplayName)
          .font(.headline)
          .foregroundColor(GeminiChatTheme.primaryText)
      }
      Spacer()
      Button(action: { viewModel.createNewSession() }) {
        HStack(spacing: 6) {
          Image(systemName: "square.and.pencil")
            .font(.system(size: 15))
          Text("New chat")
            .font(.subheadline)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(minHeight: 36)
        .contentShape(Rectangle())
        .foregroundColor(GeminiChatTheme.secondaryText)
      }
      .buttonStyle(.plain)
      .help("Start a new chat (previous chat stays in history)")
      .pointerCursorOnHover()

      Button(action: { viewModel.goBack() }) {
        HStack(spacing: 6) {
          Image(systemName: "chevron.left")
            .font(.system(size: 15))
          Text("Back")
            .font(.subheadline)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(minHeight: 36)
        .contentShape(Rectangle())
        .foregroundColor(viewModel.canGoBack ? GeminiChatTheme.secondaryText : GeminiChatTheme.secondaryText.opacity(0.5))
      }
      .buttonStyle(.plain)
      .disabled(!viewModel.canGoBack)
      .help("Switch to the previous chat")
      .pointerCursorOnHover()

      Button(action: { Task { await viewModel.captureScreenshot() } }) {
        HStack(spacing: 6) {
          if viewModel.screenshotCaptureInProgress {
            ProgressView()
              .controlSize(.small)
              .frame(width: 15, height: 15)
          } else {
            Image(systemName: "camera.viewfinder")
              .font(.system(size: 15))
          }
          Text("Screenshot")
            .font(.subheadline)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(minHeight: 36)
        .contentShape(Rectangle())
        .foregroundColor(viewModel.screenshotCaptureInProgress ? GeminiChatTheme.secondaryText.opacity(0.6) : GeminiChatTheme.secondaryText)
      }
      .buttonStyle(.plain)
      .disabled(viewModel.screenshotCaptureInProgress || viewModel.isSending)
      .help("Capture screen without this window; image will be attached to your next message.")
      .pointerCursorOnHover()
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 10)
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
        Text("/back — Switch to the previous chat")
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

  // MARK: - Command autocomplete

  private var commandSuggestionsOverlay: some View {
    Group {
      if viewModel.inputText.hasPrefix("/") {
        let suggestions = GeminiChatViewModel.commandSuggestions
          .filter { $0.command.lowercased().hasPrefix(viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) }
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

  // MARK: - Input Bar

  /// Minimum input area height (one line).
  private static let inputMinHeight: CGFloat = 40
  /// Maximum input area height (many lines); content scrolls when taller.
  private static let inputMaxHeight: CGFloat = 180
  /// Max lines used for input height measurement; avoids layout blow-up when pasting very long text.
  private static let inputMeasurementMaxLines = 30

  private var inputHeight: CGFloat {
    min(Self.inputMaxHeight, max(Self.inputMinHeight, measuredInputHeight))
  }

  /// Truncated input text used only for measuring input area height.
  /// Caps both line count and character count to prevent layout blow-up when pasting very long text.
  private var inputTextForSizing: String {
    var text = viewModel.inputText
    if text.count > 500 { text = String(text.prefix(500)) }
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    let truncated = lines.prefix(Self.inputMeasurementMaxLines).joined(separator: "\n")
    return truncated.isEmpty ? " " : truncated
  }

  private var inputBar: some View {
    return VStack(alignment: .leading, spacing: 8) {
      if viewModel.pendingScreenshot != nil {
        pendingScreenshotThumbnail(onTapThumbnail: { previewImageData = viewModel.pendingScreenshot })
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

          if viewModel.inputText.isEmpty {
            Text("Message Gemini…")
              .font(.body)
              .foregroundColor(GeminiChatTheme.secondaryText.opacity(0.5))
              .padding(.leading, 15)
              .padding(.trailing, 10)
              .padding(.vertical, 10)
              .allowsHitTesting(false)
          }
          TextEditor(text: $viewModel.inputText)
            .scrollContentBackground(.hidden)
            .font(.body)
            .foregroundColor(GeminiChatTheme.primaryText)
            .focused($inputFocused)
            .onKeyPress(.tab) {
              let text = viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines)
              if text.hasPrefix("/"), !text.isEmpty {
                let matches = viewModel.suggestedCommands(for: text)
                if let first = matches.first {
                  if text.lowercased() == first.lowercased() {
                    Task { await viewModel.sendMessage() }
                    return .handled
                  }
                  viewModel.inputText = first
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
                viewModel.inputText += "\n"
                return .handled
              }
              let text = viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines)
              if text.hasPrefix("/"), !text.isEmpty {
                let matches = viewModel.suggestedCommands(for: text)
                if let first = matches.first, text.lowercased() == first.lowercased() {
                  Task { await viewModel.sendMessage() }
                  return .handled
                }
              }
              Task { await viewModel.sendMessage() }
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
          Task { await viewModel.sendMessage() }
        }) {
          if viewModel.isSending {
            ProgressView()
              .controlSize(.small)
              .frame(width: 28, height: 28)
          } else {
            Image(systemName: "arrow.up.circle.fill")
              .font(.system(size: 24))
              .foregroundColor(
                (viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && viewModel.pendingScreenshot == nil)
                  ? GeminiChatTheme.secondaryText : .accentColor)
          }
        }
        .buttonStyle(.plain)
        .disabled(
          (viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && viewModel.pendingScreenshot == nil)
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

  private func pendingScreenshotThumbnail(onTapThumbnail: @escaping () -> Void) -> some View {
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
          .onTapGesture(perform: onTapThumbnail)
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
      VStack(alignment: .trailing, spacing: 8) {
        if let data = message.attachedImageData, let nsImage = NSImage(data: data) {
          Image(nsImage: nsImage)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: 48, height: 32)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .onTapGesture {
              onTapAttachedImage?(data)
            }
            .help("Click to view full size")
        }
        if !message.content.isEmpty {
          Text(message.content)
            .font(.system(size: 15))
            .foregroundColor(GeminiChatTheme.primaryText)
            .textSelection(.enabled)
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
