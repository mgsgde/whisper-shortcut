import SwiftUI

/// Modern Settings-View mit Sidebar-Navigation (macOS System Settings Style)
struct SettingsView: View {
  @StateObject private var viewModel = SettingsViewModel()
  @State private var selectedTab: SettingsTab = .general
  @Environment(\.dismiss) private var dismiss
  @FocusState private var focusedField: SettingsFocusField?

  var body: some View {
    NavigationSplitView {
      // MARK: - Sidebar
      sidebar
    } detail: {
      // MARK: - Detail View
      detailView
    }
    .navigationSplitViewStyle(.balanced)
    .alert("Error", isPresented: $viewModel.data.showAlert) {
      Button("OK") {
        viewModel.clearError()
      }
    } message: {
      Text(viewModel.data.errorMessage)
        .textSelection(.enabled)
    }
    .onAppear {
      setupWindow()
    }
    .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
      setupFloatingWindow()
    }
  }

  // MARK: - Sidebar
  @ViewBuilder
  private var sidebar: some View {
    List(SettingsTab.allCases, id: \.self, selection: $selectedTab) { tab in
      NavigationLink(value: tab) {
        HStack(spacing: 12) {
          Image(systemName: iconName(for: tab))
            .font(.title2)
            .foregroundColor(.accentColor)
            .frame(width: 24, height: 24)

          VStack(alignment: .leading, spacing: 2) {
            Text(tab.rawValue)
              .font(.body)
              .fontWeight(.medium)

            Text(description(for: tab))
              .font(.caption)
              .foregroundColor(.secondary)
              .lineLimit(2)
          }
        }
        .padding(.vertical, 4)
      }
    }
    .listStyle(.sidebar)
    .frame(minWidth: 240, idealWidth: 280, maxWidth: 320)
  }

  // MARK: - Detail View
  @ViewBuilder
  private var detailView: some View {
    // Content only - no action buttons for Apple's System Settings consistency
    contentSection
  }

  // MARK: - Content Section
  @ViewBuilder
  private var contentSection: some View {
    ScrollView {
      VStack(spacing: SettingsConstants.spacing) {
        switch selectedTab {
        case .general:
          GeneralSettingsTab(viewModel: viewModel, focusedField: $focusedField)
        case .speechToText:
          SpeechToTextSettingsTab(viewModel: viewModel, focusedField: $focusedField)
        case .speechToPrompt:
          SpeechToPromptSettingsTab(viewModel: viewModel, focusedField: $focusedField)
        case .speechToPromptWithVoiceResponse:
          SpeechToPromptWithVoiceResponseSettingsTab(
            viewModel: viewModel, focusedField: $focusedField)
        case .readClipboard:
          ReadClipboardSettingsTab(viewModel: viewModel, focusedField: $focusedField)
        }
      }
      .padding(.horizontal, 24)
      .padding(.top, 20)
      .padding(.bottom, 40)  // Extra margin for better scrolling experience
    }
  }

  // MARK: - Helper Functions
  private func iconName(for tab: SettingsTab) -> String {
    switch tab {
    case .general:
      return "gear"
    case .speechToText:
      return "mic"
    case .speechToPrompt:
      return "text.bubble"
    case .speechToPromptWithVoiceResponse:
      return "speaker.wave.2"
    case .readClipboard:
      return "doc.on.clipboard"
    }
  }

  private func description(for tab: SettingsTab) -> String {
    switch tab {
    case .general:
      return "API Key, ChatGPT Shortcut and Feedback"
    case .speechToText:
      return "Model, Prompt and Shortcut"
    case .speechToPrompt:
      return "Model, Prompt and Shortcut"
    case .speechToPromptWithVoiceResponse:
      return "Model, Prompt, Shortcut and Playback Speed"
    case .readClipboard:
      return "Text-to-Speech for Clipboard Content"
    }
  }

  // MARK: - Functions
  private func saveSettings() async {
    if let error = await viewModel.saveSettings() {
      viewModel.showError(error)
    } else {
      // Settings saved successfully, keep window open
    }
  }

  private func setupWindow() {
    DispatchQueue.main.async {
      NSApp.activate(ignoringOtherApps: true)
      if let window = NSApp.windows.first(where: { $0.isKeyWindow }) {
        window.makeKeyAndOrderFront(nil)
      }
      focusedField = .apiKey
    }
  }

  private func setupFloatingWindow() {
    if let window = NSApp.windows.first(where: { $0.isKeyWindow }) {
      window.level = .floating
    }
  }
}

#if DEBUG
  struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
      SettingsView()
    }
  }
#endif
