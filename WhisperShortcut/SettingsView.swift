import SwiftUI

struct SettingsView: View {

  // MARK: - Constants
  private enum Constants {
    static let labelWidth: CGFloat = 140
    static let apiKeyMaxWidth: CGFloat = 300
    static let shortcutMaxWidth: CGFloat = 250
    static let minWindowWidth: CGFloat = 520
    static let minWindowHeight: CGFloat = 600
    static let modelSelectionHeight: CGFloat = 44
    static let textFieldHeight: CGFloat = 36
    static let topPadding: CGFloat = 24
    static let spacing: CGFloat = 20
    static let sectionSpacing: CGFloat = 12
    static let modelSpacing: CGFloat = 0
    static let dividerHeight: CGFloat = 20
    static let cornerRadius: CGFloat = 6
    static let textEditorHeight: CGFloat = 80
    static let buttonSpacing: CGFloat = 16
    static let bottomPadding: CGFloat = 24
    static let horizontalPadding: CGFloat = 48
    static let verticalPadding: CGFloat = 32
  }

  // MARK: - State Variables
  @State private var apiKey: String = ""
  @State private var startShortcut: String = ""
  @State private var stopShortcut: String = ""
  @State private var selectedModel: TranscriptionModel = .gpt4oTranscribe
  @State private var errorMessage: String = ""
  @State private var isLoading: Bool = false
  @State private var showAlert: Bool = false
  @State private var customPromptText: String = ""

  // MARK: - Focus State
  @FocusState private var apiKeyFocused: Bool
  @FocusState private var startShortcutFocused: Bool
  @FocusState private var stopShortcutFocused: Bool
  @FocusState private var customPromptFocused: Bool

  // MARK: - Environment
  @Environment(\.dismiss) private var dismiss

  init() {
    let currentConfig = ShortcutConfigManager.shared.loadConfiguration()
    _startShortcut = State(initialValue: currentConfig.startRecording.textDisplayString)
    _stopShortcut = State(initialValue: currentConfig.stopRecording.textDisplayString)

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
      // Use default prompt if no custom prompt is saved
      _customPromptText = State(initialValue: TranscriptionPrompt.defaultPrompt.text)
    }
  }

  var body: some View {
    VStack(spacing: Constants.spacing) {
      // Title
      Text("WhisperShortcut Settings")
        .font(.title)
        .fontWeight(.bold)
        .padding(.top, Constants.topPadding)

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
              .textSelection(.enabled)
            Text("• Best for: Critical applications, maximum quality, difficult audio")
              .font(.callout)
              .foregroundColor(.secondary)
              .textSelection(.enabled)
          case .gpt4oMiniTranscribe:
            Text("• GPT-4o Mini Transcribe: Recommended - Great quality at lower cost")
              .font(.callout)
              .foregroundColor(.secondary)
              .textSelection(.enabled)
            Text("• Best for: Everyday use, balanced performance and cost")
              .font(.callout)
              .foregroundColor(.secondary)
              .textSelection(.enabled)
          }
        }
      }

      // Custom Prompt Section (only show for GPT-4o models)
      if selectedModel == .gpt4oTranscribe || selectedModel == .gpt4oMiniTranscribe {
        VStack(alignment: .leading, spacing: Constants.sectionSpacing) {
          Text("Transcription Prompt")
            .font(.title3)
            .fontWeight(.semibold)

          VStack(alignment: .leading, spacing: Constants.sectionSpacing) {
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
                "Describe the domain terms and context of your recordings for better transcription quality."
              )
              .font(.callout)
              .foregroundColor(.secondary)
              .textSelection(.enabled)
            }
          }
        }
      }

      // Shortcuts Section
      VStack(alignment: .leading, spacing: Constants.sectionSpacing) {
        Text("Keyboard Shortcuts")
          .font(.title3)
          .fontWeight(.semibold)

        VStack(alignment: .leading, spacing: Constants.sectionSpacing) {
          HStack(alignment: .center, spacing: 12) {
            Text("Start Recording:")
              .font(.body)
              .fontWeight(.medium)
              .frame(width: Constants.labelWidth, alignment: .leading)
            TextField("e.g., command+option+r", text: $startShortcut)
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
            TextField("e.g., command+r", text: $stopShortcut)
              .textFieldStyle(.roundedBorder)
              .font(.system(.body, design: .monospaced))
              .frame(height: Constants.textFieldHeight)
              .frame(maxWidth: Constants.shortcutMaxWidth)
              .focused($stopShortcutFocused)
            Spacer()
          }
        }

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
      }

      // Error Message - Now shown as popup alert
      // Removed fixed height to give more space for buttons

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
    .padding(.horizontal, Constants.horizontalPadding)
    .padding(.vertical, Constants.verticalPadding)
    .frame(minWidth: Constants.minWindowWidth, maxWidth: 600, minHeight: Constants.minWindowHeight)
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
    .onChange(of: selectedModel) { oldValue, newValue in
      // Auto-resize window when model changes (affects content visibility)
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
        if let window = NSApp.windows.first(where: { $0.isKeyWindow }) {
          window.setContentSize(
            window.contentView?.fittingSize
              ?? NSSize(width: Constants.minWindowWidth, height: Constants.minWindowHeight))
        }
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
      if let window = NSApp.windows.first(where: { $0.isKeyWindow }) {
        window.level = .floating
      }
    }

  }

  private func saveSettings() {
    isLoading = true

    guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      showErrorMessage("Please enter your OpenAI API key")
      return
    }

    guard !startShortcut.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      showErrorMessage("Please enter a start recording shortcut")
      return
    }

    guard !stopShortcut.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      showErrorMessage("Please enter a stop recording shortcut")
      return
    }

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

    // Check for duplicate shortcuts
    if startShortcutParsed == stopShortcutParsed {
      showErrorMessage(
        "Start and stop shortcuts cannot be the same. Please use different shortcuts.")
      return
    }

    _ = KeychainManager.shared.saveAPIKey(apiKey)

    // Save model preference
    UserDefaults.standard.set(selectedModel.rawValue, forKey: "selectedTranscriptionModel")

    // Save custom prompt
    UserDefaults.standard.set(customPromptText, forKey: "customPromptText")

    // Notify that model has changed
    NotificationCenter.default.post(name: .modelChanged, object: selectedModel)

    let newConfig = ShortcutConfig(
      startRecording: startShortcutParsed,
      stopRecording: stopShortcutParsed
    )
    ShortcutConfigManager.shared.saveConfiguration(newConfig)

    validateAPIKey { isValid in
      DispatchQueue.main.async {
        isLoading = false
        if isValid {
          dismiss()
        } else {
          showErrorMessage("Invalid API key. Please check your OpenAI API key.")
        }
      }
    }
  }

  private func showErrorMessage(_ message: String) {
    errorMessage = message
    showAlert = true
    isLoading = false
  }

  private func validateAPIKey(completion: @escaping (Bool) -> Void) {
    let transcriptionService = TranscriptionService()
    transcriptionService.setModel(selectedModel)
    Task {
      do {
        let isValid = try await transcriptionService.validateAPIKey(apiKey)
        completion(isValid)
      } catch {
        completion(false)
      }
    }
  }
}

#Preview {
  SettingsView()
}
