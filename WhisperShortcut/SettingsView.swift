import SwiftUI

struct SettingsView: View {
  @State private var apiKey: String = ""
  @State private var startShortcut: String = ""
  @State private var stopShortcut: String = ""
  @State private var errorMessage: String = ""
  @State private var showError: Bool = false
  @State private var isLoading: Bool = false

  @FocusState private var apiKeyFocused: Bool
  @FocusState private var startShortcutFocused: Bool
  @FocusState private var stopShortcutFocused: Bool

  @Environment(\.dismiss) private var dismiss

  init() {
    let currentConfig = ShortcutConfigManager.shared.loadConfiguration()
    _startShortcut = State(initialValue: currentConfig.startRecording.textDisplayString)
    _stopShortcut = State(initialValue: currentConfig.stopRecording.textDisplayString)
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

          Text(
            "• Symbols: minus, equal, leftbracket, rightbracket, backslash, semicolon, quote, grave, comma, period, slash"
          )
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

      // Error Message
      if showError {
        Text(errorMessage)
          .foregroundColor(.red)
          .font(.callout)
          .fontWeight(.medium)
          .multilineTextAlignment(.center)
          .textSelection(.enabled)
          .padding(.vertical, 8)
      }

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
    .padding(.horizontal, 32)
    .padding(.vertical, 16)
    .frame(width: 520, height: 650)
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
    showError = false

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
    showError = true
    isLoading = false
  }

  private func validateAPIKey(completion: @escaping (Bool) -> Void) {
    let transcriptionService = TranscriptionService()
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
