import SwiftUI

struct SettingsView: View {

  // MARK: - Tab Selection
  enum SettingsTab: String, CaseIterable {
    case general = "General"
    case shortcuts = "Shortcuts"
    case prompts = "Prompts"
  }

  // MARK: - Constants
  private enum Constants {
    static let labelWidth: CGFloat = 160
    static let apiKeyMaxWidth: CGFloat = 350
    static let shortcutMaxWidth: CGFloat = 300
    static let minWindowWidth: CGFloat = 600
    static let minWindowHeight: CGFloat = 550
    static let modelSelectionHeight: CGFloat = 48
    static let textFieldHeight: CGFloat = 40
    static let topPadding: CGFloat = 30
    static let spacing: CGFloat = 24
    static let sectionSpacing: CGFloat = 16
    static let modelSpacing: CGFloat = 0
    static let dividerHeight: CGFloat = 20
    static let cornerRadius: CGFloat = 8
    static let textEditorHeight: CGFloat = 80
    static let buttonSpacing: CGFloat = 20
    static let bottomPadding: CGFloat = 30
    static let horizontalPadding: CGFloat = 40
    static let verticalPadding: CGFloat = 24

  }

  // MARK: - State Variables
  @State private var selectedTab: SettingsTab = .general
  @State private var apiKey: String = ""
  @State private var startShortcut: String = ""
  @State private var stopShortcut: String = ""
  @State private var startPrompting: String = ""
  @State private var stopPrompting: String = ""
  @State private var openChatGPT: String = ""
  @State private var startShortcutEnabled: Bool = true
  @State private var stopShortcutEnabled: Bool = true
  @State private var startPromptingEnabled: Bool = true
  @State private var stopPromptingEnabled: Bool = true
  @State private var openChatGPTEnabled: Bool = true
  @State private var selectedModel: TranscriptionModel = .gpt4oTranscribe
  @State private var errorMessage: String = ""
  @State private var isLoading: Bool = false
  @State private var showAlert: Bool = false
  @State private var customPromptText: String = ""
  @State private var promptModeSystemPrompt: String = ""

  // MARK: - Focus State
  @FocusState private var apiKeyFocused: Bool
  @FocusState private var startShortcutFocused: Bool
  @FocusState private var stopShortcutFocused: Bool
  @FocusState private var startPromptingFocused: Bool
  @FocusState private var stopPromptingFocused: Bool
  @FocusState private var openChatGPTFocused: Bool
  @FocusState private var customPromptFocused: Bool
  @FocusState private var promptModeSystemPromptFocused: Bool

  // MARK: - Environment
  @Environment(\.dismiss) private var dismiss

  init() {
    let currentConfig = ShortcutConfigManager.shared.loadConfiguration()
    _startShortcut = State(initialValue: currentConfig.startRecording.textDisplayString)
    _stopShortcut = State(initialValue: currentConfig.stopRecording.textDisplayString)
    _startPrompting = State(initialValue: currentConfig.startPrompting.textDisplayString)
    _stopPrompting = State(initialValue: currentConfig.stopPrompting.textDisplayString)
    _openChatGPT = State(initialValue: currentConfig.openChatGPT.textDisplayString)
    _startShortcutEnabled = State(initialValue: currentConfig.startRecording.isEnabled)
    _stopShortcutEnabled = State(initialValue: currentConfig.stopRecording.isEnabled)
    _startPromptingEnabled = State(initialValue: currentConfig.startPrompting.isEnabled)
    _stopPromptingEnabled = State(initialValue: currentConfig.stopPrompting.isEnabled)
    _openChatGPTEnabled = State(initialValue: currentConfig.openChatGPT.isEnabled)

    // Load saved model preference
    if let savedModelString = UserDefaults.standard.string(forKey: "selectedTranscriptionModel"),
      let savedModel = TranscriptionModel(rawValue: savedModelString)
    {
      _selectedModel = State(initialValue: savedModel)
    } else {
      _selectedModel = State(initialValue: .gpt4oMiniTranscribe)
    }

    // Load saved custom prompt or use default
    if let savedCustomPrompt = UserDefaults.standard.string(forKey: "customPromptText") {
      _customPromptText = State(initialValue: savedCustomPrompt)
    } else {
      _customPromptText = State(initialValue: TranscriptionPrompt.defaultPrompt.text)
    }

    // Load saved prompt mode system prompt
    if let savedSystemPrompt = UserDefaults.standard.string(forKey: "promptModeSystemPrompt") {
      _promptModeSystemPrompt = State(initialValue: savedSystemPrompt)
    } else {
      _promptModeSystemPrompt = State(
        initialValue: AppConstants.defaultSystemPrompt
      )
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      // Title
      Text("WhisperShortcut Settings")
        .font(.title)
        .fontWeight(.bold)
        .padding(.top, Constants.topPadding)
        .padding(.bottom, 16)

      // Tab Selection
      Picker("", selection: $selectedTab) {
        ForEach(SettingsTab.allCases, id: \.self) { tab in
          Text(tab.rawValue).tag(tab)
        }
      }
      .pickerStyle(.segmented)
      .padding(.horizontal, Constants.horizontalPadding)
      .padding(.bottom, Constants.spacing)

      // Tab Content
      ScrollView {
        VStack(spacing: Constants.spacing) {
          switch selectedTab {
          case .general:
            generalTabContent
          case .shortcuts:
            shortcutsTabContent
          case .prompts:
            promptsTabContent
          }
        }
        .padding(.horizontal, Constants.horizontalPadding)
        .padding(.bottom, 20)
      }

      Spacer(minLength: 4)

      // Buttons
      HStack(spacing: Constants.buttonSpacing) {
        Button("Skip for now") {
          dismiss()
        }
        .font(.body)
        .fontWeight(.medium)

        Button("Save Settings") {
          saveSettings()
        }
        .font(.body)
        .fontWeight(.semibold)
        .buttonStyle(.borderedProminent)
        .disabled(isLoading)

        if isLoading {
          ProgressView()
            .scaleEffect(1.0)
        }
      }
      .padding(.bottom, Constants.bottomPadding)
    }
    .frame(width: Constants.minWindowWidth, height: Constants.minWindowHeight)
    .alert("Error", isPresented: $showAlert) {
      Button("OK") {
        showAlert = false
      }
    } message: {
      Text(errorMessage)
        .textSelection(.enabled)
    }
    .onAppear {
      DispatchQueue.main.async {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.isKeyWindow }) {
          window.makeKeyAndOrderFront(nil)
        }
        apiKeyFocused = true
      }
    }

    .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
      if let window = NSApp.windows.first(where: { $0.isKeyWindow }) {
        window.level = .floating
      }
    }
  }

  // MARK: - Tab Content Views

  @ViewBuilder
  private var generalTabContent: some View {
    VStack(alignment: .leading, spacing: Constants.spacing) {
      // API Key Section
      VStack(alignment: .leading, spacing: Constants.sectionSpacing) {
        Text("OpenAI API Key")
          .font(.title3)
          .fontWeight(.semibold)
          .textSelection(.enabled)

        HStack(alignment: .center, spacing: 16) {
          Text("API Key:")
            .font(.body)
            .fontWeight(.medium)
            .frame(width: Constants.labelWidth, alignment: .leading)
            .textSelection(.enabled)
          TextField("sk-...", text: $apiKey)
            .textFieldStyle(.roundedBorder)
            .font(.system(.body, design: .monospaced))
            .frame(height: Constants.textFieldHeight)
            .frame(maxWidth: Constants.apiKeyMaxWidth)
            .onAppear {
              apiKey = KeychainManager.shared.getAPIKey() ?? ""
            }
            .focused($apiKeyFocused)
          Spacer()
        }

        Text(
          "💡 Need an API key? Get one at [platform.openai.com/account/api-keys](https://platform.openai.com/account/api-keys)"
        )
        .font(.callout)
        .foregroundColor(.secondary)
        .padding(.top, 4)
        .textSelection(.enabled)
      }

      // Model Selection Section
      VStack(alignment: .leading, spacing: Constants.sectionSpacing) {
        Text("Transcription Model")
          .font(.title3)
          .fontWeight(.semibold)
          .textSelection(.enabled)

        HStack(spacing: Constants.modelSpacing) {
          ForEach(TranscriptionModel.allCases, id: \.self) { model in
            ZStack {
              Rectangle()
                .fill(selectedModel == model ? Color.accentColor : Color.clear)
                .cornerRadius(Constants.cornerRadius)

              Text(model.displayName)
                .font(.system(.body, design: .default))
                .foregroundColor(selectedModel == model ? .white : .primary)
            }
            .frame(maxWidth: .infinity, minHeight: Constants.modelSelectionHeight)
            .contentShape(Rectangle())
            .onTapGesture {
              selectedModel = model
            }

            if model != TranscriptionModel.allCases.last {
              Divider()
                .frame(height: Constants.dividerHeight)
            }
          }
        }
        .background(Color(.controlBackgroundColor))
        .cornerRadius(8)
        .overlay(
          RoundedRectangle(cornerRadius: 8)
            .stroke(Color(.separatorColor), lineWidth: 1)
        )
        .frame(height: Constants.modelSelectionHeight)

        VStack(alignment: .leading, spacing: 8) {
          Text("Model Details:")
            .font(.callout)
            .fontWeight(.semibold)
            .foregroundColor(.secondary)
            .textSelection(.enabled)

          switch selectedModel {
          case .gpt4oTranscribe:
            Text("• GPT-4o Transcribe: Highest accuracy and quality")
              .font(.callout)
              .foregroundColor(.secondary)
              .textSelection(.enabled)
            Text("• Best for: Critical applications, maximum quality")
              .font(.callout)
              .foregroundColor(.secondary)
              .textSelection(.enabled)
          case .gpt4oMiniTranscribe:
            Text("• GPT-4o Mini: Recommended - Great quality at lower cost")
              .font(.callout)
              .foregroundColor(.secondary)
              .textSelection(.enabled)
            Text("• Best for: Everyday use, balanced performance")
              .font(.callout)
              .foregroundColor(.secondary)
              .textSelection(.enabled)
          }
        }
      }
    }
  }

  @ViewBuilder
  private var shortcutsTabContent: some View {
    VStack(alignment: .leading, spacing: Constants.spacing) {
      // Transcription Mode Shortcuts
      VStack(alignment: .leading, spacing: Constants.sectionSpacing) {
        Text("Transcription Mode")
          .font(.title3)
          .fontWeight(.semibold)
          .textSelection(.enabled)

        Text("Dictate → Text Conversion")
          .font(.callout)
          .foregroundColor(.secondary)
          .textSelection(.enabled)

        HStack(alignment: .center, spacing: 16) {
          Text("Dictate:")
            .font(.body)
            .fontWeight(.medium)
            .frame(width: Constants.labelWidth, alignment: .leading)
            .textSelection(.enabled)
          TextField("e.g., command+shift+e", text: $startShortcut)
            .textFieldStyle(.roundedBorder)
            .font(.system(.body, design: .monospaced))
            .frame(height: Constants.textFieldHeight)
            .frame(maxWidth: Constants.shortcutMaxWidth)
            .focused($startShortcutFocused)
            .disabled(!startShortcutEnabled)
          Toggle("", isOn: $startShortcutEnabled)
            .toggleStyle(.checkbox)
            .help("Enable/disable this shortcut")
          Spacer()
        }

        HStack(alignment: .center, spacing: 16) {
          Text("Stop Recording:")
            .font(.body)
            .fontWeight(.medium)
            .frame(width: Constants.labelWidth, alignment: .leading)
            .textSelection(.enabled)
          TextField("e.g., command+e", text: $stopShortcut)
            .textFieldStyle(.roundedBorder)
            .font(.system(.body, design: .monospaced))
            .frame(height: Constants.textFieldHeight)
            .frame(maxWidth: Constants.shortcutMaxWidth)
            .focused($stopShortcutFocused)
            .disabled(!stopShortcutEnabled)
          Toggle("", isOn: $stopShortcutEnabled)
            .toggleStyle(.checkbox)
            .help("Enable/disable this shortcut")
          Spacer()
        }
      }

      // Prompt Mode Shortcuts
      VStack(alignment: .leading, spacing: Constants.sectionSpacing) {
        Text("Prompt Mode")
          .font(.title3)
          .fontWeight(.semibold)
          .textSelection(.enabled)

        Text("Dictate Prompt → AI Assistant Response (uses clipboard as context)")
          .font(.callout)
          .foregroundColor(.secondary)
          .textSelection(.enabled)

        HStack(alignment: .center, spacing: 16) {
          Text("Select text and dictate prompt:")
            .font(.body)
            .fontWeight(.medium)
            .frame(width: Constants.labelWidth, alignment: .leading)
            .textSelection(.enabled)
          TextField("e.g., command+shift+p", text: $startPrompting)
            .textFieldStyle(.roundedBorder)
            .font(.system(.body, design: .monospaced))
            .frame(height: Constants.textFieldHeight)
            .frame(maxWidth: Constants.shortcutMaxWidth)
            .focused($startPromptingFocused)
            .disabled(!startPromptingEnabled)
          Toggle("", isOn: $startPromptingEnabled)
            .toggleStyle(.checkbox)
            .help("Enable/disable this shortcut")
          Spacer()
        }

        HStack(alignment: .center, spacing: 16) {
          Text("Stop Prompting:")
            .font(.body)
            .fontWeight(.medium)
            .frame(width: Constants.labelWidth, alignment: .leading)
            .textSelection(.enabled)
          TextField("e.g., command+p", text: $stopPrompting)
            .textFieldStyle(.roundedBorder)
            .font(.system(.body, design: .monospaced))
            .frame(height: Constants.textFieldHeight)
            .frame(maxWidth: Constants.shortcutMaxWidth)
            .focused($stopPromptingFocused)
            .disabled(!stopPromptingEnabled)
          Toggle("", isOn: $stopPromptingEnabled)
            .toggleStyle(.checkbox)
            .help("Enable/disable this shortcut")
          Spacer()
        }
      }

      // ChatGPT Shortcut
      VStack(alignment: .leading, spacing: Constants.sectionSpacing) {
        Text("Quick Access")
          .font(.title3)
          .fontWeight(.semibold)
          .textSelection(.enabled)

        Text("Open ChatGPT in browser")
          .font(.callout)
          .foregroundColor(.secondary)
          .textSelection(.enabled)

        HStack(alignment: .center, spacing: 16) {
          Text("Open ChatGPT:")
            .font(.body)
            .fontWeight(.medium)
            .frame(width: Constants.labelWidth, alignment: .leading)
            .textSelection(.enabled)
          TextField("e.g., command+1", text: $openChatGPT)
            .textFieldStyle(.roundedBorder)
            .font(.system(.body, design: .monospaced))
            .frame(height: Constants.textFieldHeight)
            .frame(maxWidth: Constants.shortcutMaxWidth)
            .focused($openChatGPTFocused)
            .disabled(!openChatGPTEnabled)
          Toggle("", isOn: $openChatGPTEnabled)
            .toggleStyle(.checkbox)
            .help("Enable/disable this shortcut")
          Spacer()
        }
      }

      // Available Keys Information
      VStack(alignment: .leading, spacing: 8) {
        Text("Available keys:")
          .font(.callout)
          .fontWeight(.semibold)
          .foregroundColor(.secondary)
          .textSelection(.enabled)

        Text(
          "command • option • control • shift • a-z • 0-9 • f1-f12 • space • return • escape • tab • delete • home • end • pageup • pagedown • up • down • left • right • minus • equal • leftbracket • rightbracket • backslash • semicolon • quote • grave • comma • period • slash"
        )
        .font(.callout)
        .foregroundColor(.secondary)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
      }
      .textSelection(.enabled)

      // Prompt Mode Usage Instructions
      VStack(alignment: .leading, spacing: 8) {
        Text("How to use Prompt Mode:")
          .font(.callout)
          .fontWeight(.semibold)
          .foregroundColor(.secondary)
          .textSelection(.enabled)

        VStack(alignment: .leading, spacing: 8) {
          Text("1. Copy any text to clipboard (⌘C)")
            .textSelection(.enabled)
          Text("2. Dictate your prompt (e.g., ⌘⌥P)")
            .textSelection(.enabled)
          Text("3. AI receives both your voice and clipboard text")
            .textSelection(.enabled)
        }
        .font(.callout)
        .foregroundColor(.secondary)

        Text(
          "💡 Auto-copy: [GitHub version](https://github.com/mgsgde/whisper-shortcut) automatically copies selected text. Mac App Store version requires manual ⌘C."
        )
        .font(.callout)
        .foregroundColor(.orange)
        .padding(.top, 4)
        .textSelection(.enabled)
      }
      .padding(12)
      .background(Color(.controlBackgroundColor).opacity(0.5))
      .cornerRadius(Constants.cornerRadius)
      .overlay(
        RoundedRectangle(cornerRadius: Constants.cornerRadius)
          .stroke(Color(.separatorColor), lineWidth: 1)
      )
    }
  }

  @ViewBuilder
  private var promptsTabContent: some View {
    VStack(alignment: .leading, spacing: Constants.spacing) {
      // Transcription Prompt Section
      if selectedModel == .gpt4oTranscribe || selectedModel == .gpt4oMiniTranscribe {
        VStack(alignment: .leading, spacing: Constants.sectionSpacing) {
          Text("Transcription Prompt")
            .font(.title3)
            .fontWeight(.semibold)
            .textSelection(.enabled)

          VStack(alignment: .leading, spacing: 8) {
            Text("Domain Terms & Context:")
              .font(.callout)
              .fontWeight(.semibold)
              .foregroundColor(.secondary)
              .textSelection(.enabled)

            TextEditor(text: $customPromptText)
              .font(.system(.body, design: .default))
              .frame(height: Constants.textEditorHeight)
              .padding(8)
              .background(Color(.controlBackgroundColor))
              .cornerRadius(Constants.cornerRadius)
              .overlay(
                RoundedRectangle(cornerRadius: Constants.cornerRadius)
                  .stroke(Color(.separatorColor), lineWidth: 1)
              )
              .focused($customPromptFocused)

            Text(
              "Describe domain terms for better transcription quality. Leave empty to use OpenAI's default."
            )
            .font(.callout)
            .foregroundColor(.secondary)
            .textSelection(.enabled)

            HStack {
              Spacer()
              Button("Reset to Default") {
                customPromptText = TranscriptionPrompt.defaultPrompt.text
              }
              .buttonStyle(.bordered)
              .font(.callout)
            }
          }
        }
      }

      // Prompt Mode System Prompt
      VStack(alignment: .leading, spacing: Constants.sectionSpacing) {
        Text("AI Assistant System Prompt")
          .font(.title3)
          .fontWeight(.semibold)
          .textSelection(.enabled)

        VStack(alignment: .leading, spacing: 8) {
          Text("System Instructions for AI Assistant:")
            .font(.callout)
            .fontWeight(.semibold)
            .foregroundColor(.secondary)
            .textSelection(.enabled)

          TextEditor(text: $promptModeSystemPrompt)
            .font(.system(.body, design: .default))
            .frame(height: Constants.textEditorHeight)
            .padding(8)
            .background(Color(.controlBackgroundColor))
            .cornerRadius(Constants.cornerRadius)
            .overlay(
              RoundedRectangle(cornerRadius: Constants.cornerRadius)
                .stroke(Color(.separatorColor), lineWidth: 1)
            )
            .focused($promptModeSystemPromptFocused)

          Text(
            "Additional instructions that will be combined with the base system prompt. The base prompt ensures concise responses without intros or meta text."
          )
          .font(.callout)
          .foregroundColor(.secondary)
          .textSelection(.enabled)

          HStack {
            Spacer()
            Button("Reset to Default") {
              promptModeSystemPrompt = AppConstants.defaultSystemPrompt
            }
            .buttonStyle(.bordered)
            .font(.callout)
          }
        }
      }
    }
  }

  // MARK: - Functions
  private func saveSettings() {
    isLoading = true
    errorMessage = ""

    // Validate API key
    guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      showErrorMessage("Please enter your OpenAI API key")
      return
    }

    // Validate shortcuts (only if enabled)
    if startShortcutEnabled {
      guard !startShortcut.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        showErrorMessage("Please enter a start recording shortcut")
        return
      }
    }

    if stopShortcutEnabled {
      guard !stopShortcut.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        showErrorMessage("Please enter a stop recording shortcut")
        return
      }
    }

    if startPromptingEnabled {
      guard !startPrompting.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        showErrorMessage("Please enter a start prompting shortcut")
        return
      }
    }

    if stopPromptingEnabled {
      guard !stopPrompting.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        showErrorMessage("Please enter a stop prompting shortcut")
        return
      }
    }

    if openChatGPTEnabled {
      guard !openChatGPT.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        showErrorMessage("Please enter an open ChatGPT shortcut")
        return
      }
    }

    // Parse shortcuts (only if enabled)
    let startShortcutParsed =
      startShortcutEnabled
      ? ShortcutConfigManager.parseShortcut(from: startShortcut)
      : ShortcutDefinition(key: .e, modifiers: [.command, .shift], isEnabled: false)

    let stopShortcutParsed =
      stopShortcutEnabled
      ? ShortcutConfigManager.parseShortcut(from: stopShortcut)
      : ShortcutDefinition(key: .e, modifiers: [.command], isEnabled: false)

    let startPromptingParsed =
      startPromptingEnabled
      ? ShortcutConfigManager.parseShortcut(from: startPrompting)
      : ShortcutDefinition(key: .p, modifiers: [.command, .shift], isEnabled: false)

    let stopPromptingParsed =
      stopPromptingEnabled
      ? ShortcutConfigManager.parseShortcut(from: stopPrompting)
      : ShortcutDefinition(key: .p, modifiers: [.command], isEnabled: false)

    let openChatGPTParsed =
      openChatGPTEnabled
      ? ShortcutConfigManager.parseShortcut(from: openChatGPT)
      : ShortcutDefinition(key: .one, modifiers: [.command], isEnabled: false)

    // Validate parsed shortcuts
    if startShortcutEnabled {
      guard let parsed = startShortcutParsed else {
        showErrorMessage(
          "Invalid start recording shortcut format. Use: command+option+r, control+shift+space, f1, command+up"
        )
        return
      }
    }

    if stopShortcutEnabled {
      guard let parsed = stopShortcutParsed else {
        showErrorMessage(
          "Invalid stop recording shortcut format. Use: command+r, control+space, f2, command+down")
        return
      }
    }

    if startPromptingEnabled {
      guard let parsed = startPromptingParsed else {
        showErrorMessage("Invalid start prompting shortcut format")
        return
      }
    }

    if stopPromptingEnabled {
      guard let parsed = stopPromptingParsed else {
        showErrorMessage("Invalid stop prompting shortcut format")
        return
      }
    }

    if openChatGPTEnabled {
      guard let parsed = openChatGPTParsed else {
        showErrorMessage("Invalid open ChatGPT shortcut format")
        return
      }
    }

    // Check for duplicate shortcuts (only among enabled ones)
    let enabledShortcuts = [
      startShortcutEnabled ? startShortcutParsed : nil,
      stopShortcutEnabled ? stopShortcutParsed : nil,
      startPromptingEnabled ? startPromptingParsed : nil,
      stopPromptingEnabled ? stopPromptingParsed : nil,
      openChatGPTEnabled ? openChatGPTParsed : nil,
    ].compactMap { $0 }

    let uniqueShortcuts = Set(enabledShortcuts)
    if enabledShortcuts.count != uniqueShortcuts.count {
      showErrorMessage("All enabled shortcuts must be different. Please use unique shortcuts.")
      return
    }

    // Save API key
    KeychainManager.shared.saveAPIKey(apiKey)

    // Save model preference
    UserDefaults.standard.set(selectedModel.rawValue, forKey: "selectedTranscriptionModel")

    // Save custom prompt
    UserDefaults.standard.set(customPromptText, forKey: "customPromptText")

    // Save prompt mode system prompt
    UserDefaults.standard.set(promptModeSystemPrompt, forKey: "promptModeSystemPrompt")

    // Notify that model has changed
    NotificationCenter.default.post(name: .modelChanged, object: selectedModel)

    let newConfig = ShortcutConfig(
      startRecording: startShortcutParsed
        ?? ShortcutDefinition(key: .e, modifiers: [.command, .shift], isEnabled: false),
      stopRecording: stopShortcutParsed
        ?? ShortcutDefinition(key: .e, modifiers: [.command], isEnabled: false),
      startPrompting: startPromptingParsed
        ?? ShortcutDefinition(key: .p, modifiers: [.command, .shift], isEnabled: false),
      stopPrompting: stopPromptingParsed
        ?? ShortcutDefinition(key: .p, modifiers: [.command], isEnabled: false),
      openChatGPT: openChatGPTParsed
        ?? ShortcutDefinition(key: .one, modifiers: [.command], isEnabled: false)
    )
    ShortcutConfigManager.shared.saveConfiguration(newConfig)

    // Reset loading state
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
      isLoading = false
      dismiss()
    }
  }

  private func showErrorMessage(_ message: String) {
    errorMessage = message
    showAlert = true
    isLoading = false
  }
}
