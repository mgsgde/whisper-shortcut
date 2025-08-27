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
    static let labelWidth: CGFloat = 140
    static let apiKeyMaxWidth: CGFloat = 300
    static let shortcutMaxWidth: CGFloat = 250
    static let minWindowWidth: CGFloat = 520
    static let minWindowHeight: CGFloat = 450
    static let modelSelectionHeight: CGFloat = 44
    static let textFieldHeight: CGFloat = 36
    static let topPadding: CGFloat = 20
    static let spacing: CGFloat = 16
    static let sectionSpacing: CGFloat = 10
    static let modelSpacing: CGFloat = 0
    static let dividerHeight: CGFloat = 20
    static let cornerRadius: CGFloat = 6
    static let textEditorHeight: CGFloat = 70
    static let buttonSpacing: CGFloat = 16
    static let bottomPadding: CGFloat = 20
    static let horizontalPadding: CGFloat = 32
    static let verticalPadding: CGFloat = 20
  }

  // MARK: - State Variables
  @State private var selectedTab: SettingsTab = .general
  @State private var apiKey: String = ""
  @State private var startShortcut: String = ""
  @State private var stopShortcut: String = ""
  @State private var startPrompting: String = ""
  @State private var stopPrompting: String = ""
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
        initialValue:
          "You are a helpful assistant that executes user commands. Provide clear, actionable responses."
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
      Picker("Settings Tab", selection: $selectedTab) {
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

        HStack(alignment: .center, spacing: 12) {
          Text("API Key:")
            .font(.body)
            .fontWeight(.medium)
            .frame(width: Constants.labelWidth, alignment: .leading)
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
      }

      // Model Selection Section
      VStack(alignment: .leading, spacing: Constants.sectionSpacing) {
        Text("Transcription Model")
          .font(.title3)
          .fontWeight(.semibold)

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

        VStack(alignment: .leading, spacing: 4) {
          Text("Model Details:")
            .font(.callout)
            .fontWeight(.semibold)
            .foregroundColor(.secondary)

          switch selectedModel {
          case .gpt4oTranscribe:
            Text("• GPT-4o Transcribe: Highest accuracy and quality")
              .font(.callout)
              .foregroundColor(.secondary)
            Text("• Best for: Critical applications, maximum quality")
              .font(.callout)
              .foregroundColor(.secondary)
          case .gpt4oMiniTranscribe:
            Text("• GPT-4o Mini: Recommended - Great quality at lower cost")
              .font(.callout)
              .foregroundColor(.secondary)
            Text("• Best for: Everyday use, balanced performance")
              .font(.callout)
              .foregroundColor(.secondary)
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

        Text("Dictate → Text Conversion")
          .font(.callout)
          .foregroundColor(.secondary)

        HStack(alignment: .center, spacing: 12) {
          Text("Dictate:")
            .font(.body)
            .fontWeight(.medium)
            .frame(width: Constants.labelWidth, alignment: .leading)
          TextField("e.g., command+shift+e", text: $startShortcut)
            .textFieldStyle(.roundedBorder)
            .font(.system(.body, design: .monospaced))
            .frame(height: Constants.textFieldHeight)
            .frame(maxWidth: Constants.shortcutMaxWidth)
            .focused($startShortcutFocused)
          Spacer()
        }

        HStack(alignment: .center, spacing: 12) {
          Text("Stop Recording:")
            .font(.body)
            .fontWeight(.medium)
            .frame(width: Constants.labelWidth, alignment: .leading)
          TextField("e.g., command+e", text: $stopShortcut)
            .textFieldStyle(.roundedBorder)
            .font(.system(.body, design: .monospaced))
            .frame(height: Constants.textFieldHeight)
            .frame(maxWidth: Constants.shortcutMaxWidth)
            .focused($stopShortcutFocused)
          Spacer()
        }
      }

      // Prompt Mode Shortcuts
      VStack(alignment: .leading, spacing: Constants.sectionSpacing) {
        Text("Prompt Mode")
          .font(.title3)
          .fontWeight(.semibold)

        Text("Dictate Prompt → AI Assistant Response (uses clipboard as context)")
          .font(.callout)
          .foregroundColor(.secondary)

        HStack(alignment: .center, spacing: 12) {
          Text("Select text and dictate prompt:")
            .font(.body)
            .fontWeight(.medium)
            .frame(width: Constants.labelWidth, alignment: .leading)
          TextField("e.g., command+shift+p", text: $startPrompting)
            .textFieldStyle(.roundedBorder)
            .font(.system(.body, design: .monospaced))
            .frame(height: Constants.textFieldHeight)
            .frame(maxWidth: Constants.shortcutMaxWidth)
            .focused($startPromptingFocused)
          Spacer()
        }

        HStack(alignment: .center, spacing: 12) {
          Text("Stop Prompting:")
            .font(.body)
            .fontWeight(.medium)
            .frame(width: Constants.labelWidth, alignment: .leading)
          TextField("e.g., command+p", text: $stopPrompting)
            .textFieldStyle(.roundedBorder)
            .font(.system(.body, design: .monospaced))
            .frame(height: Constants.textFieldHeight)
            .frame(maxWidth: Constants.shortcutMaxWidth)
            .focused($stopPromptingFocused)
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

        VStack(alignment: .leading, spacing: 4) {
          Text("1. Optional: Copy any text to clipboard (⌘C)")
          Text("2. Dictate your prompt (e.g., ⌘⌥P)")
          Text("3. AI receives both your voice and clipboard text")
        }
        .font(.callout)
        .foregroundColor(.secondary)

        Text(
          "💡 Tip: When installing the app directly from the GitHub repository (https://github.com/mgsgde/whisper-shortcut), any text you select will be automatically copied to the clipboard for use in Prompt Mode."
        )
        .font(.callout)
        .foregroundColor(.orange)
        .padding(.top, 4)
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

          VStack(alignment: .leading, spacing: 8) {
            Text("Domain Terms & Context:")
              .font(.callout)
              .fontWeight(.semibold)
              .foregroundColor(.secondary)

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

        VStack(alignment: .leading, spacing: 8) {
          Text(
            "Usage: This prompt defines how the AI assistant behaves when you use Prompt Mode. The AI receives both your spoken command AND any selected text from your clipboard as context."
          )
          .font(.callout)
          .foregroundColor(.secondary)
          .padding(.bottom, 4)

          Text("System Instructions for AI Assistant:")
            .font(.callout)
            .fontWeight(.semibold)
            .foregroundColor(.secondary)

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

          Text("Define how the AI assistant should behave when processing your voice commands.")
            .font(.callout)
            .foregroundColor(.secondary)

          HStack {
            Spacer()
            Button("Reset to Default") {
              promptModeSystemPrompt =
                "You are a helpful assistant that executes user commands. Provide clear, actionable responses."
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

    // Validate shortcuts
    guard !startShortcut.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      showErrorMessage("Please enter a start recording shortcut")
      return
    }

    guard !stopShortcut.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      showErrorMessage("Please enter a stop recording shortcut")
      return
    }

    guard !startPrompting.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      showErrorMessage("Please enter a start prompting shortcut")
      return
    }

    guard !stopPrompting.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      showErrorMessage("Please enter a stop prompting shortcut")
      return
    }

    // Parse shortcuts
    guard let startShortcutParsed = ShortcutConfigManager.parseShortcut(from: startShortcut) else {
      showErrorMessage(
        "Invalid start recording shortcut format. Use: command+option+r, control+shift+space, f1, command+up"
      )
      return
    }

    guard let stopShortcutParsed = ShortcutConfigManager.parseShortcut(from: stopShortcut) else {
      showErrorMessage(
        "Invalid stop recording shortcut format. Use: command+r, control+space, f2, command+down")
      return
    }

    guard let startPromptingParsed = ShortcutConfigManager.parseShortcut(from: startPrompting)
    else {
      showErrorMessage("Invalid start prompting shortcut format")
      return
    }

    guard let stopPromptingParsed = ShortcutConfigManager.parseShortcut(from: stopPrompting) else {
      showErrorMessage("Invalid stop prompting shortcut format")
      return
    }

    // Check for duplicate shortcuts
    let shortcuts = [
      startShortcutParsed, stopShortcutParsed, startPromptingParsed, stopPromptingParsed,
    ]
    let uniqueShortcuts = Set(shortcuts)
    if shortcuts.count != uniqueShortcuts.count {
      showErrorMessage("All shortcuts must be different. Please use unique shortcuts.")
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
      startRecording: startShortcutParsed,
      stopRecording: stopShortcutParsed,
      startPrompting: startPromptingParsed,
      stopPrompting: stopPromptingParsed
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
