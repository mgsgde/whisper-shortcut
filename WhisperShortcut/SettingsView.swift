import SwiftUI

struct SettingsView: View {
  @State private var apiKey: String = ""
  @State private var startShortcut: String = ""
  @State private var stopShortcut: String = ""
  @State private var selectedModel: TranscriptionModel = .gpt4oTranscribe
  @State private var errorMessage: String = ""
  @State private var isLoading: Bool = false
  @State private var showAlert: Bool = false

  @FocusState private var apiKeyFocused: Bool
  @FocusState private var startShortcutFocused: Bool
  @FocusState private var stopShortcutFocused: Bool

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
      _selectedModel = State(initialValue: .gpt4oTranscribe)
    }
  }

  var body: some View {
    VStack(spacing: 20) {
      // Title
      Text("WhisperShortcut Settings")
        .font(.title)
        .fontWeight(.bold)
        .padding(.top, 24)

      // API Key Section
      VStack(alignment: .leading, spacing: 12) {
        Text("OpenAI API Key")
          .font(.title3)
          .fontWeight(.semibold)

        TextField("sk-...", text: $apiKey)
          .textFieldStyle(.roundedBorder)
          .font(.system(.body, design: .monospaced))
          .frame(height: 36)
          .onAppear {
            apiKey = KeychainManager.shared.getAPIKey() ?? ""
          }
          .focused($apiKeyFocused)
      }

      // Model Selection Section
      VStack(alignment: .leading, spacing: 12) {
        Text("Transcription Model")
          .font(.title3)
          .fontWeight(.semibold)

        HStack(spacing: 0) {
          ForEach(TranscriptionModel.allCases, id: \.self) { model in
            ZStack {
              Rectangle()
                .fill(selectedModel == model ? Color.accentColor : Color.clear)
                .cornerRadius(6)

              Text(model.displayName)
                .font(.system(.body, design: .default))
                .foregroundColor(selectedModel == model ? .white : .primary)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
            .onTapGesture {
              selectedModel = model
            }

            if model != TranscriptionModel.allCases.last {
              Divider()
                .frame(height: 20)
            }
          }
        }
        .background(Color(.controlBackgroundColor))
        .cornerRadius(8)
        .overlay(
          RoundedRectangle(cornerRadius: 8)
            .stroke(Color(.separatorColor), lineWidth: 1)
        )
        .frame(height: 44)

        VStack(alignment: .leading, spacing: 4) {
          Text("Model Details:")
            .font(.callout)
            .fontWeight(.semibold)
            .foregroundColor(.secondary)

          switch selectedModel {
          case .whisper1:
            Text("• Whisper-1: Most cost-effective, stable and proven")
              .font(.callout)
              .foregroundColor(.secondary)
            Text("• Best for: Budget-conscious users, clear audio sources")
              .font(.callout)
              .foregroundColor(.secondary)
          case .gpt4oTranscribe:
            Text("• GPT-4o Transcribe: Highest accuracy, best for difficult audio")
              .font(.callout)
              .foregroundColor(.secondary)
            Text("• Best for: Critical applications, maximum quality")
              .font(.callout)
              .foregroundColor(.secondary)
          case .gpt4oMiniTranscribe:
            Text("• GPT-4o Mini Transcribe: Balanced quality and speed")
              .font(.callout)
              .foregroundColor(.secondary)
            Text("• Best for: Everyday use, good quality with lower cost")
              .font(.callout)
              .foregroundColor(.secondary)
          }
        }
      }

      // Shortcuts Section
      VStack(alignment: .leading, spacing: 16) {
        Text("Keyboard Shortcuts")
          .font(.title3)
          .fontWeight(.semibold)

        VStack(alignment: .leading, spacing: 12) {
          HStack {
            Text("Start Recording:")
              .font(.body)
              .fontWeight(.medium)
              .frame(width: 140, alignment: .leading)
            TextField("e.g., command+option+r", text: $startShortcut)
              .textFieldStyle(.roundedBorder)
              .font(.system(.body, design: .monospaced))
              .frame(height: 36)
              .focused($startShortcutFocused)
          }

          HStack {
            Text("Stop Recording:")
              .font(.body)
              .fontWeight(.medium)
              .frame(width: 140, alignment: .leading)
            TextField("e.g., command+r", text: $stopShortcut)
              .textFieldStyle(.roundedBorder)
              .font(.system(.body, design: .monospaced))
              .frame(height: 36)
              .focused($stopShortcutFocused)
          }
        }

        VStack(alignment: .leading, spacing: 8) {
          Text("Available keys:")
            .font(.callout)
            .fontWeight(.semibold)
            .foregroundColor(.secondary)

          Text("• Modifiers: command, option, control, shift, fn")
            .font(.callout)
            .foregroundColor(.secondary)
            .textSelection(.enabled)

          Text("• Letters: a-z")
            .font(.callout)
            .foregroundColor(.secondary)
            .textSelection(.enabled)

          Text("• Numbers: 0-9")
            .font(.callout)
            .foregroundColor(.secondary)
            .textSelection(.enabled)

          Text("• Function keys: f1-f12")
            .font(.callout)
            .foregroundColor(.secondary)
            .textSelection(.enabled)

          Text("• Special keys: space, return, escape, tab, delete")
            .font(.callout)
            .foregroundColor(.secondary)
            .textSelection(.enabled)

          Text("• Symbols: minus, equal, leftbracket, rightbracket, backslash")
            .font(.callout)
            .foregroundColor(.secondary)
            .textSelection(.enabled)

          Text("• Symbols: semicolon, quote, grave, comma, period, slash")
            .font(.callout)
            .foregroundColor(.secondary)
            .textSelection(.enabled)

          Text("• Navigation: home, end, pageup, pagedown, up, down, left, right")
            .font(.callout)
            .foregroundColor(.secondary)
            .textSelection(.enabled)

        }
        .textSelection(.enabled)
      }

      // Error Message - Now shown as popup alert
      // Removed fixed height to give more space for buttons

      Spacer(minLength: 4)

      // Buttons
      HStack(spacing: 16) {
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
      .padding(.bottom, 24)
    }
    .padding(.horizontal, 48)
    .padding(.vertical, 32)
    .frame(width: 580, height: 720)
    .alert("Error", isPresented: $showAlert) {
      Button("OK") {
        showAlert = false
      }
    } message: {
      Text(errorMessage)
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
