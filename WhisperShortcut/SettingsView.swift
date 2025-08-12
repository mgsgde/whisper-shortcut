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

  private let currentConfig: ShortcutConfig

  init() {
    self.currentConfig = ShortcutConfigManager.shared.loadConfiguration()
    _startShortcut = State(initialValue: currentConfig.startRecording.textDisplayString)
    _stopShortcut = State(initialValue: currentConfig.stopRecording.textDisplayString)
  }

  var body: some View {
    VStack(spacing: 20) {
      // Title
      Text("WhisperShortcut Settings")
        .font(.title2)
        .fontWeight(.semibold)
        .padding(.top, 20)

      // API Key Section
      VStack(alignment: .leading, spacing: 8) {
        Text("OpenAI API Key")
          .font(.headline)

        TextField("sk-...", text: $apiKey)
          .textFieldStyle(.roundedBorder)
          .font(.system(.body, design: .monospaced))
          .onAppear {
            apiKey = KeychainManager.shared.getAPIKey() ?? ""
          }
          .textFieldStyle(.roundedBorder)
          .allowsHitTesting(true)
          .focused($apiKeyFocused)
      }

      // Shortcuts Section
      VStack(alignment: .leading, spacing: 12) {
        Text("Keyboard Shortcuts")
          .font(.headline)

        VStack(alignment: .leading, spacing: 8) {
          HStack {
            Text("Start Recording:")
              .frame(width: 120, alignment: .leading)
            TextField("e.g., command+option+r", text: $startShortcut)
              .textFieldStyle(.roundedBorder)
              .font(.system(.body, design: .monospaced))
              .allowsHitTesting(true)
              .focused($startShortcutFocused)
          }

          HStack {
            Text("Stop Recording:")
              .frame(width: 120, alignment: .leading)
            TextField("e.g., command+r", text: $stopShortcut)
              .textFieldStyle(.roundedBorder)
              .font(.system(.body, design: .monospaced))
              .allowsHitTesting(true)
              .focused($stopShortcutFocused)
          }
        }

        VStack(alignment: .leading, spacing: 4) {
          Text("Available modifiers:")
            .font(.caption)
            .fontWeight(.medium)
            .foregroundColor(.secondary)

          Text("• command")
            .font(.caption)
            .foregroundColor(.secondary)

          Text("• option")
            .font(.caption)
            .foregroundColor(.secondary)

          Text("• control")
            .font(.caption)
            .foregroundColor(.secondary)

          Text("• shift")
            .font(.caption)
            .foregroundColor(.secondary)

        }
        .textSelection(.enabled)
      }

      // Error Message
      if showError {
        Text(errorMessage)
          .foregroundColor(.red)
          .font(.caption)
          .multilineTextAlignment(.center)
          .textSelection(.enabled)
      }

      Spacer()

      // Buttons
      HStack(spacing: 12) {
        Button("Skip for now") {
          dismiss()
        }

        Button("Save Settings") {
          saveSettings()
        }
        .buttonStyle(.borderedProminent)
        .disabled(isLoading)

        if isLoading {
          ProgressView()
            .scaleEffect(0.8)
        }
      }
      .padding(.bottom, 20)
    }
    .padding(.horizontal, 24)
    .frame(width: 480, height: 400)
    .onAppear {
      // Make window key and main when it appears
      DispatchQueue.main.async {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.isKeyWindow }) {
          window.makeKeyAndOrderFront(nil)
        }
        // Set focus to first text field
        apiKeyFocused = true
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
      // Ensure window can handle keyboard events
      if let window = NSApp.windows.first(where: { $0.isKeyWindow }) {
        window.level = .floating
      }
    }
  }

  private func saveSettings() {
    isLoading = true
    showError = false

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

    // Parse shortcuts
    guard let startShortcutParsed = ShortcutConfigManager.parseShortcut(from: startShortcut) else {
      showErrorMessage(
        "Invalid start recording shortcut format. Try: command+option+r, control+shift+t")
      return
    }

    guard let stopShortcutParsed = ShortcutConfigManager.parseShortcut(from: stopShortcut) else {
      showErrorMessage("Invalid stop recording shortcut format. Try: command+r, control+t")
      return
    }

    // Save API key
    KeychainManager.shared.saveAPIKey(apiKey)

    // Save shortcuts
    let newConfig = ShortcutConfig(
      startRecording: startShortcutParsed,
      stopRecording: stopShortcutParsed
    )
    ShortcutConfigManager.shared.saveConfiguration(newConfig)

    // Validate API key with OpenAI
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
