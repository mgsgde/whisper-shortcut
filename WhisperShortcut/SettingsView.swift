import SwiftUI

/// Hauptsächliche Settings-View - schlanker Container für Tab-Management
struct SettingsView: View {
  @StateObject private var viewModel = SettingsViewModel()
  @State private var selectedTab: SettingsTab = .general
  @Environment(\.dismiss) private var dismiss
  @FocusState private var focusedField: SettingsFocusField?

  var body: some View {
    VStack(spacing: 0) {
      // Title
      titleSection

      // Tab Selection
      tabPicker

      // Tab Content
      tabContentContainer

      Spacer(minLength: SettingsConstants.spacing)

      // Action Buttons
      actionButtons
    }
    .frame(width: SettingsConstants.minWindowWidth, height: SettingsConstants.minWindowHeight)
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

  // MARK: - Title Section
  @ViewBuilder
  private var titleSection: some View {
    Text("WhisperShortcut Settings")
      .font(.title)
      .fontWeight(.bold)
      .padding(.top, SettingsConstants.topPadding)
      .padding(.bottom, 24)  // Increased from 16 to 24 for better spacing
  }

  // MARK: - Tab Picker
  @ViewBuilder
  private var tabPicker: some View {
    Picker("", selection: $selectedTab) {
      ForEach(SettingsTab.allCases, id: \.self) { tab in
        Text(tab.rawValue).tag(tab)
      }
    }
    .pickerStyle(.segmented)
    .padding(.horizontal, SettingsConstants.horizontalPadding + 20)  // Increased horizontal padding for more space from edges
    .padding(.bottom, SettingsConstants.spacing)
    .frame(maxWidth: .infinity)
    .scaleEffect(1.1)  // Make tabs slightly larger
  }

  // MARK: - Tab Content Container
  @ViewBuilder
  private var tabContentContainer: some View {
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
        }
      }
      .padding(.horizontal, SettingsConstants.horizontalPadding)
      .padding(.bottom, SettingsConstants.spacing)
    }
  }

  // MARK: - Action Buttons
  @ViewBuilder
  private var actionButtons: some View {
    HStack(spacing: SettingsConstants.buttonSpacing) {
      Button("Cancel") {
        dismiss()
      }
      .font(.body)
      .fontWeight(.medium)

      Button("Save Settings") {
        Task {
          await saveSettings()
        }
      }
      .font(.body)
      .fontWeight(.semibold)
      .buttonStyle(.borderedProminent)
      .disabled(viewModel.data.isLoading)

      if viewModel.data.isLoading {
        ProgressView()
          .scaleEffect(1.0)
      }
    }
    .padding(.bottom, SettingsConstants.bottomPadding)
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
