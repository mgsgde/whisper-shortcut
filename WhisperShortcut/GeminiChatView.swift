import SwiftUI

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

  func sendMessage() async {
    let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
    let hasContent = !text.isEmpty || pendingScreenshot != nil
    guard hasContent, !isSending else { return }

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

    let contents = buildContents(pendingImage: pendingScreenshot)
    pendingScreenshot = nil

    do {
      let model = Self.resolveOpenGeminiModel()
      let result = try await apiClient.sendChatMessage(
        model: model, contents: contents, apiKey: apiKey, useGrounding: true,
        systemInstruction: Self.openGeminiSystemInstruction)
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

  /// System instruction for the Open Gemini chat: structure, emojis in headings, bold for key terms.
  private static var openGeminiSystemInstruction: [String: Any] {
    let text = """
    Answer in a natural way:

    - For simple questions that need only a brief answer (e.g. "What's the weather?", "What time is it?"), reply directly with that answer. Do not add "In short:" or similar.

    - For complex questions or when your answer has multiple sections, use this structure:
      1) First paragraph: Start with "In short:" (or the equivalent in the user's language, e.g. "Kurz gesagt:") followed by one or two sentences that directly answer the question.
      2) Then a blank line and the detailed answer. Use markdown headings for each section: ## for main sections, ### for subsections. Start every heading with a relevant emoji (e.g. "## 🌍 Europa"). Leave a blank line before and after each heading.

    Use **bold** for key terms when helpful.
    """
    return ["parts": [["text": text]]]
  }

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

  private func buildContents(pendingImage: Data? = nil) -> [[String: Any]] {
    let toSend = Array(messages.suffix(Self.maxMessagesInContext))
    return toSend.enumerated().map { index, msg in
      let isLastUserWithImage = index == toSend.count - 1 && msg.role == .user && pendingImage != nil
      if isLastUserWithImage, let imageData = pendingImage {
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

struct GeminiChatView: View {
  @StateObject private var viewModel = GeminiChatViewModel()
  @FocusState private var inputFocused: Bool
  @State private var showingScreenshotPreview = false

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
    .sheet(isPresented: $showingScreenshotPreview) {
      if let data = viewModel.pendingScreenshot, let nsImage = NSImage(data: data) {
        screenshotPreviewSheet(image: nsImage)
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
        HStack(spacing: 6) {
          Image(systemName: "square.and.pencil")
            .font(.system(size: 15))
          Text("New chat")
            .font(.subheadline)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .foregroundColor(.secondary)
      }
      .buttonStyle(.plain)
      .help("Start a new chat (previous chat stays in history)")

      Button(action: { viewModel.goBack() }) {
        HStack(spacing: 6) {
          Image(systemName: "chevron.left")
            .font(.system(size: 15))
          Text("Back")
            .font(.subheadline)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .foregroundColor(viewModel.canGoBack ? .secondary : .secondary.opacity(0.5))
      }
      .buttonStyle(.plain)
      .disabled(!viewModel.canGoBack)
      .help("Switch to the previous chat")

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
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .foregroundColor(viewModel.screenshotCaptureInProgress ? .secondary.opacity(0.6) : .secondary)
      }
      .buttonStyle(.plain)
      .disabled(viewModel.screenshotCaptureInProgress || viewModel.isSending)
      .help("Capture screen without this window; image will be attached to your next message.")
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
  }

  // MARK: - Message List

  private var messageList: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 18) {
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
        .padding(.top, 10)
        .padding(.bottom, 28)
      }
      .onChange(of: viewModel.messages.count) { _ in
        scrollToBottom(proxy: proxy)
      }
      .onChange(of: viewModel.isSending) { sending in
        if sending { scrollToBottom(proxy: proxy, target: "typing") }
      }
      .onAppear {
        if !viewModel.messages.isEmpty {
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            scrollToBottom(proxy: proxy)
          }
        }
      }
      .background(
        GeometryReader { geo in
          Color.clear.onChange(of: geo.size) { _ in
            DispatchQueue.main.async {
              scrollToBottom(proxy: proxy)
            }
          }
        }
      )
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
    VStack(alignment: .leading, spacing: 8) {
      if viewModel.pendingScreenshot != nil {
        pendingScreenshotThumbnail(onTapThumbnail: { showingScreenshotPreview = true })
      }
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
          .padding(.vertical, 10)
          .frame(minHeight: 36)
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
                (viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && viewModel.pendingScreenshot == nil)
                  ? .secondary : .accentColor)
          }
        }
        .buttonStyle(.plain)
        .disabled(
          (viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && viewModel.pendingScreenshot == nil)
            || viewModel.isSending)
        .frame(width: 28, height: 28)
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
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
      }
      Text("Screenshot will be attached to your next message")
        .font(.caption)
        .foregroundColor(.secondary)
      Spacer()
      Button(action: { viewModel.clearPendingScreenshot() }) {
        Image(systemName: "xmark.circle.fill")
          .font(.system(size: 18))
          .foregroundColor(.secondary)
      }
      .buttonStyle(.plain)
      .help("Remove screenshot")
    }
    .padding(8)
    .background(Color(NSColor.controlBackgroundColor).opacity(0.8))
    .clipShape(RoundedRectangle(cornerRadius: 8))
  }

  private func screenshotPreviewSheet(image: NSImage) -> some View {
    VStack(spacing: 0) {
      HStack {
        Spacer()
        Button("Done") {
          showingScreenshotPreview = false
        }
        .keyboardShortcut(.cancelAction)
        .padding()
      }
      Image(nsImage: image)
        .resizable()
        .scaledToFit()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
    }
    .frame(minWidth: 800, minHeight: 600)
    .frame(idealWidth: 1000, idealHeight: 700)
  }
}

// MARK: - Markdown Blocks

private enum MarkdownBlock {
  case heading2(String)
  case heading3(String)
  case codeBlock(String)
  case bulletList([String])
  case numberedList([String])
  case paragraph(String)
}

private func parseMarkdownBlocks(_ content: String) -> [MarkdownBlock] {
  var blocks: [MarkdownBlock] = []
  let lines = content.components(separatedBy: "\n")
  var i = 0
  let numberedPrefix = #"^\d+\.\s+"#

  while i < lines.count {
    let trimmed = lines[i].trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { i += 1; continue }

    // Code block
    if trimmed.hasPrefix("```") {
      var codeLines: [String] = []
      i += 1
      while i < lines.count {
        if lines[i].trimmingCharacters(in: .whitespacesAndNewlines) == "```" { i += 1; break }
        codeLines.append(lines[i])
        i += 1
      }
      blocks.append(.codeBlock(codeLines.joined(separator: "\n")))
      continue
    }

    // ### before ## to avoid mismatching
    if trimmed.hasPrefix("### ") {
      blocks.append(.heading3(String(trimmed.dropFirst(4))))
      i += 1; continue
    }
    if trimmed.hasPrefix("## ") {
      blocks.append(.heading2(String(trimmed.dropFirst(3))))
      i += 1; continue
    }

    // Bullet list
    if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
      var items: [String] = []
      while i < lines.count {
        let t = lines[i].trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("- ") { items.append(String(t.dropFirst(2))); i += 1 }
        else if t.hasPrefix("* ") { items.append(String(t.dropFirst(2))); i += 1 }
        else { break }
      }
      if !items.isEmpty { blocks.append(.bulletList(items)) }
      continue
    }

    // Numbered list
    if trimmed.range(of: numberedPrefix, options: .regularExpression) != nil {
      var items: [String] = []
      while i < lines.count {
        let t = lines[i].trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = t.range(of: numberedPrefix, options: .regularExpression) {
          items.append(String(t[r.upperBound...])); i += 1
        } else { break }
      }
      if !items.isEmpty { blocks.append(.numberedList(items)) }
      continue
    }

    // Paragraph — collect consecutive non-special lines
    var paraLines: [String] = []
    while i < lines.count {
      let t = lines[i].trimmingCharacters(in: .whitespacesAndNewlines)
      if t.isEmpty { i += 1; break }
      if t.hasPrefix("## ") || t.hasPrefix("### ") || t.hasPrefix("```") { break }
      if t.hasPrefix("- ") || t.hasPrefix("* ") { break }
      if t.range(of: numberedPrefix, options: .regularExpression) != nil { break }
      paraLines.append(lines[i])
      i += 1
    }
    if !paraLines.isEmpty {
      blocks.append(.paragraph(paraLines.joined(separator: "\n")))
    }
  }

  return blocks
}

// MARK: - Model Reply View

private struct ModelReplyView: View {
  let content: String

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      ForEach(Array(parseMarkdownBlocks(content).enumerated()), id: \.offset) { _, block in
        blockView(for: block)
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 12)
        .fill(Color(NSColor.controlBackgroundColor))
    )
    .textSelection(.enabled)
  }

  @ViewBuilder
  private func blockView(for block: MarkdownBlock) -> some View {
    switch block {
    case .heading2(let text):
      inlineMarkdown(text)
        .font(.system(size: 15, weight: .bold))
        .padding(.top, 4)

    case .heading3(let text):
      inlineMarkdown(text)
        .font(.system(size: 14, weight: .semibold))
        .padding(.top, 2)

    case .codeBlock(let code):
      Text(code.isEmpty ? " " : code)
        .font(.system(size: 12.5, design: .monospaced))
        .foregroundColor(.primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
          RoundedRectangle(cornerRadius: 6)
            .fill(Color(NSColor.textBackgroundColor))
        )
        .overlay(
          RoundedRectangle(cornerRadius: 6)
            .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
        )

    case .bulletList(let items):
      VStack(alignment: .leading, spacing: 7) {
        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("•")
              .font(.system(size: 15))
              .foregroundColor(.secondary)
            inlineMarkdown(item)
              .font(.system(size: 15))
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }

    case .numberedList(let items):
      VStack(alignment: .leading, spacing: 7) {
        ForEach(Array(items.enumerated()), id: \.offset) { index, item in
          HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(index + 1).")
              .font(.system(size: 15))
              .foregroundColor(.secondary)
              .frame(minWidth: 20, alignment: .trailing)
            inlineMarkdown(item)
              .font(.system(size: 15))
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }

    case .paragraph(let text):
      inlineMarkdown(text)
        .font(.system(size: 15))
        .lineSpacing(4)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func inlineMarkdown(_ text: String) -> Text {
    let options = AttributedString.MarkdownParsingOptions(
      interpretedSyntax: .inlineOnlyPreservingWhitespace)
    let attr = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    return Text(attr)
  }
}

// MARK: - Message Bubble

private struct MessageBubbleView: View {
  let message: ChatMessage

  var isUser: Bool { message.role == .user }

  var body: some View {
    HStack(alignment: .top, spacing: 0) {
      if isUser { Spacer(minLength: 40) }

      VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
        bubbleContent
        if !message.sources.isEmpty {
          sourcesView
        }
      }
      .frame(maxWidth: isUser ? 560 : .infinity)

      if !isUser { Spacer(minLength: 0) }
    }
    .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
  }

  @ViewBuilder
  private var bubbleContent: some View {
    if isUser {
      Text(message.content)
        .font(.body)
        .foregroundColor(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .textSelection(.enabled)
        .background(
          RoundedRectangle(cornerRadius: 14)
            .fill(Color.accentColor)
        )
    } else {
      ModelReplyView(content: message.content)
    }
  }

  private var sourcesView: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 4) {
        Image(systemName: "globe")
          .font(.caption2)
          .foregroundColor(.secondary)
        Text("Sources")
          .font(.caption2)
          .foregroundColor(.secondary)
      }
      LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 16) {
        ForEach(message.sources) { source in
          if let url = URL(string: source.uri) {
            Link(destination: url) {
              HStack(spacing: 4) {
                Image(systemName: "link")
                  .font(.caption2)
                Text(source.title)
                  .font(.caption)
                  .lineLimit(1)
                  .truncationMode(.tail)
              }
              .foregroundColor(.accentColor)
            }
            .onHover { inside in
              if inside {
                NSCursor.pointingHand.push()
              } else {
                NSCursor.pop()
              }
            }
          }
        }
      }
    }
    .padding(.horizontal, 12)
    .padding(.top, 14)
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
