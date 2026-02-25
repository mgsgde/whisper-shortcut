import SwiftUI

// MARK: - ViewModel

@MainActor
class GeminiChatViewModel: ObservableObject {
  @Published var messages: [ChatMessage] = []
  @Published var inputText: String = ""
  @Published var isSending: Bool = false
  @Published var errorMessage: String? = nil

  private var session: ChatSession
  private let store = GeminiChatSessionStore.shared
  private let apiClient = GeminiAPIClient()

  /// Maximum number of messages to send as context (older messages are kept in UI but not sent to the API).
  private static let maxMessagesInContext = 30
  /// Maximum length for auto-generated session title from first user message.
  private static let maxSessionTitleLength = 50
  private static let newChatCommand = "/new"
  private static let backChatCommand = "/back"

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
    DebugLogger.log("GEMINI-CHAT: Switched to new chat")
  }

  func goBack() {
    let prevId = store.idForBack() ?? store.previousSessionId(current: session.id)
    guard let prevId = prevId else { return }
    store.setCurrentSession(id: prevId, clearBack: true)
    session = store.load()
    messages = session.messages
    errorMessage = nil
    DebugLogger.log("GEMINI-CHAT: Switched back to previous chat \(prevId)")
  }

  func sendMessage() async {
    let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, !isSending else { return }

    // Slash commands: do not send to API
    let lower = text.lowercased()
    if lower == Self.newChatCommand {
      inputText = ""
      createNewSession()
      return
    }
    if lower == Self.backChatCommand {
      inputText = ""
      goBack()
      return
    }

    guard let apiKey = KeychainManager.shared.getGoogleAPIKey(), !apiKey.isEmpty else {
      errorMessage = "No API key configured. Please add your Google API key in Settings."
      return
    }

    inputText = ""
    errorMessage = nil
    isSending = true

    let userMsg = ChatMessage(role: .user, content: text)
    appendMessage(userMsg)

    let contents = buildContents()

    do {
      let model = Self.resolveOpenGeminiModel()
      let result = try await apiClient.sendChatMessage(
        model: model, contents: contents, apiKey: apiKey, useGrounding: true)
      let modelMsg = ChatMessage(role: .model, content: result.text, sources: result.sources)
      appendMessage(modelMsg)
    } catch {
      errorMessage = friendlyError(error)
      DebugLogger.logError("GEMINI-CHAT: \(error.localizedDescription)")
    }

    isSending = false
  }

  func clearMessages() {
    messages = []
    session.messages = []
    session.lastUpdated = Date()
    store.save(session)
    DebugLogger.log("GEMINI-CHAT: Cleared current chat messages")
  }

  // MARK: - Private

  /// Resolves the model ID for the Open Gemini chat window from UserDefaults (Settings > Open Gemini).
  private static func resolveOpenGeminiModel() -> String {
    let raw = UserDefaults.standard.string(forKey: UserDefaultsKeys.selectedOpenGeminiModel)
      ?? SettingsDefaults.selectedOpenGeminiModel.rawValue
    let model = PromptModel(rawValue: raw).map { PromptModel.migrateIfDeprecated($0) }
      ?? SettingsDefaults.selectedOpenGeminiModel
    return model.rawValue
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
    let toSend = messages.suffix(Self.maxMessagesInContext)
    return toSend.map { msg in
      ["role": msg.role.rawValue, "parts": [["text": msg.content]]]
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

struct GeminiChatView: View {
  @StateObject private var viewModel = GeminiChatViewModel()
  @FocusState private var inputFocused: Bool

  var body: some View {
    VStack(spacing: 0) {
      headerBar
      Divider()
      messageList
      if let error = viewModel.errorMessage {
        errorBanner(error)
      }
      Divider()
      inputBar
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(NSColor.windowBackgroundColor))
  }

  // MARK: - Header

  private var headerBar: some View {
    HStack {
      HStack(spacing: 6) {
        Image(systemName: "sparkles")
          .foregroundColor(.accentColor)
        Text("Gemini")
          .font(.headline)
      }
      Spacer()
      Button(action: { viewModel.createNewSession() }) {
        HStack(spacing: 4) {
          Image(systemName: "square.and.pencil")
            .font(.system(size: 12))
          Text("New chat")
            .font(.caption)
        }
        .foregroundColor(.secondary)
      }
      .buttonStyle(.plain)
      .help("Start a new chat (previous chat stays in history)")

      Button(action: { viewModel.goBack() }) {
        HStack(spacing: 4) {
          Image(systemName: "chevron.left")
            .font(.system(size: 12))
          Text("Back")
            .font(.caption)
        }
        .foregroundColor(viewModel.canGoBack ? .secondary : .secondary.opacity(0.5))
      }
      .buttonStyle(.plain)
      .disabled(!viewModel.canGoBack)
      .help("Switch to the previous chat")

      if !viewModel.messages.isEmpty {
        Button(action: { viewModel.clearMessages() }) {
          Image(systemName: "trash")
            .foregroundColor(.secondary)
        }
        .buttonStyle(.plain)
        .help("Clear conversation")
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
  }

  // MARK: - Message List

  private var messageList: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 10) {
          if viewModel.messages.isEmpty && !viewModel.isSending {
            emptyStateCommandHints
          }
          ForEach(viewModel.messages) { message in
            MessageBubbleView(message: message)
              .id(message.id)
          }
          if viewModel.isSending {
            TypingIndicatorView()
              .id("typing")
          }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
      }
      .onChange(of: viewModel.messages.count) { _ in
        scrollToBottom(proxy: proxy)
      }
      .onChange(of: viewModel.isSending) { sending in
        if sending { scrollToBottom(proxy: proxy, target: "typing") }
      }
    }
  }

  private var emptyStateCommandHints: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Commands")
        .font(.subheadline)
        .fontWeight(.semibold)
        .foregroundColor(.secondary)
      VStack(alignment: .leading, spacing: 6) {
        Text("/new — Start a new chat (previous chat stays in history)")
          .font(.callout)
          .foregroundColor(.secondary)
        Text("/back — Switch to the previous chat")
          .font(.callout)
          .foregroundColor(.secondary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, 16)
  }

  private func scrollToBottom(proxy: ScrollViewProxy, target: AnyHashable? = nil) {
    withAnimation(.easeOut(duration: 0.2)) {
      if let t = target {
        proxy.scrollTo(t, anchor: .bottom)
      } else if let last = viewModel.messages.last {
        proxy.scrollTo(last.id, anchor: .bottom)
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
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(Color.red.opacity(0.85))
  }

  // MARK: - Input Bar

  private var inputBar: some View {
    HStack(alignment: .bottom, spacing: 8) {
      TextField("Message Gemini…", text: $viewModel.inputText, axis: .vertical)
        .textFieldStyle(.plain)
        .lineLimit(1...6)
        .focused($inputFocused)
        .onSubmit {
          Task { await viewModel.sendMessage() }
        }
        .onAppear { inputFocused = true }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))

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
              viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? .secondary : .accentColor)
        }
      }
      .buttonStyle(.plain)
      .disabled(
        viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          || viewModel.isSending)
      .frame(width: 28, height: 28)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
  }
}

// MARK: - Message Bubble

private struct MessageBubbleView: View {
  let message: ChatMessage

  var isUser: Bool { message.role == .user }

  var body: some View {
    HStack(alignment: .top, spacing: 0) {
      if isUser { Spacer(minLength: 40) }

      VStack(alignment: isUser ? .trailing : .leading, spacing: 5) {
        bubbleContent
        if !message.sources.isEmpty {
          sourcesView
        }
      }

      if !isUser { Spacer(minLength: 40) }
    }
    .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
  }

  private var bubbleContent: some View {
    Group {
      if isUser {
        Text(message.content)
      } else {
        // Paragraph-aware Markdown: split by double newline so line breaks are preserved
        paragraphMarkdownView(message.content)
      }
    }
    .font(.body)
    .lineSpacing(5)
    .textSelection(.enabled)
    .foregroundColor(isUser ? .white : .primary)
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .background(
      RoundedRectangle(cornerRadius: 14)
        .fill(isUser ? Color.accentColor : Color(NSColor.controlBackgroundColor))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 14)
        .stroke(isUser ? Color.clear : Color(NSColor.separatorColor), lineWidth: 0.5)
    )
  }

  /// Renders model reply with paragraph breaks preserved. Splits on "\n\n", renders each block as Markdown.
  @ViewBuilder
  private func paragraphMarkdownView(_ content: String) -> some View {
    let paragraphs = content.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    if paragraphs.isEmpty {
      Text(content)
    } else {
      VStack(alignment: .leading, spacing: 8) {
        ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, block in
          if let attr = try? AttributedString(markdown: block) {
            Text(attr)
          } else {
            Text(block)
          }
        }
      }
    }
  }

  private var sourcesView: some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(spacing: 4) {
        Image(systemName: "globe")
          .font(.caption2)
          .foregroundColor(.secondary)
        Text("Sources")
          .font(.caption2)
          .foregroundColor(.secondary)
      }
      ForEach(message.sources) { source in
        if let url = URL(string: source.uri) {
          Link(destination: url) {
            HStack(spacing: 4) {
              Image(systemName: "link")
                .font(.caption2)
              Text(source.title)
                .font(.caption)
                .lineLimit(1)
            }
            .foregroundColor(.accentColor)
          }
        }
      }
    }
    .padding(.horizontal, 4)
  }
}

// MARK: - Typing Indicator

private struct TypingIndicatorView: View {
  @State private var dotScale: [CGFloat] = [1, 1, 1]

  var body: some View {
    HStack(spacing: 4) {
      ForEach(0..<3, id: \.self) { i in
        Circle()
          .fill(Color.secondary)
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
        .fill(Color(NSColor.controlBackgroundColor))
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
