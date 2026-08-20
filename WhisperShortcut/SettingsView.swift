import SwiftUI

/// Modern Settings view with sidebar navigation (macOS System Settings style).
struct SettingsView: View {
  @StateObject private var viewModel = SettingsViewModel()
  @AppStorage(UserDefaultsKeys.settingsSelectedTab) private var selectedTabRaw: String =
    SettingsTab.general.rawValue
  @Environment(\.dismiss) private var dismiss
  @FocusState private var focusedField: SettingsFocusField?

  private var selectedTab: SettingsTab {
    SettingsTab(rawValue: selectedTabRaw) ?? .general
  }

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
    .onReceive(NotificationCenter.default.publisher(for: .openPrivacyPermissionsTab)) { _ in
      selectedTabRaw = SettingsTab.permissions.rawValue
    }
  }

  // MARK: - Sidebar
  @ViewBuilder
  private var sidebar: some View {
    List(SettingsTab.allCases, id: \.self, selection: Binding<SettingsTab?>(
      get: { selectedTab },
      set: { if let tab = $0 { selectedTabRaw = tab.rawValue } }
    )) { tab in
      NavigationLink(value: tab) {
        HStack(spacing: 10) {
          Image(systemName: iconName(for: tab))
            .font(.body)
            .foregroundColor(.accentColor)
            .frame(width: 20, height: 20)

          Text(tab.rawValue)
            .font(.body)
        }
        .padding(.vertical, 2)
      }
      .help(description(for: tab))
      .pointerCursorOnHover()
    }
    .listStyle(.sidebar)
    .frame(minWidth: 210, idealWidth: 220, maxWidth: 260)
  }

  // MARK: - Detail View
  @ViewBuilder
  private var detailView: some View {
    contentSection
  }

  // MARK: - Content Section
  @ViewBuilder
  private var contentSection: some View {
    VStack(spacing: 0) {
      ScrollView {
        VStack(spacing: SettingsConstants.spacing) {
          switch selectedTab {
          case .general:
            GeneralSettingsTab(viewModel: viewModel, focusedField: $focusedField)
          case .speechToText:
            SpeechToTextSettingsTab(viewModel: viewModel, focusedField: $focusedField)
          case .speechToPrompt:
            SpeechToPromptSettingsTab(viewModel: viewModel, focusedField: $focusedField)
          case .screenshot:
            ScreenshotSettingsTab(viewModel: viewModel, focusedField: $focusedField)
          case .chat:
            ChatSettingsTab(viewModel: viewModel, focusedField: $focusedField)
          case .readAloud:
            ReadAloudSettingsTab(viewModel: viewModel, focusedField: $focusedField)
          case .improvement:
            ImprovementSettingsTab(viewModel: viewModel, focusedField: $focusedField)
          case .permissions:
            PermissionsTab()
          case .about:
            AboutSettingsTab(viewModel: viewModel)
          }
        }
        .padding(.horizontal, SettingsConstants.horizontalPadding)
        .padding(.top, SettingsConstants.topPadding)
        .padding(.bottom, SettingsConstants.bottomPadding)
      }

      versionFooter
    }
  }

  /// Always-visible footer so support / feedback doesn't require opening About.
  private var versionFooter: some View {
    HStack {
      Spacer()
      Text("Version \(AppConstants.appVersion)")
        .font(.caption)
        .foregroundColor(.secondary)
        .textSelection(.enabled)
    }
    .padding(.horizontal, SettingsConstants.horizontalPadding)
    .padding(.vertical, 8)
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
    case .screenshot:
      return "camera.viewfinder"
    case .chat:
      return "sparkles"
    case .readAloud:
      return "speaker.wave.2.fill"
    case .improvement:
      return "wand.and.stars"
    case .permissions:
      return "checkmark.shield"
    case .about:
      return "info.circle"
    }
  }

  private func description(for tab: SettingsTab) -> String {
    switch tab {
    case .general:
      return "API key, shortcuts, and preferences"
    case .speechToText:
      return "Model, system prompt, and shortcut"
    case .speechToPrompt:
      return "Model, system prompt, and shortcut"
    case .screenshot:
      return "Shortcut and save-to-folder settings"
    case .chat:
      return "Model, system prompt, and live meeting settings"
    case .readAloud:
      return "Shortcut and smart-rewrite settings"
    case .improvement:
      return "Improve prompts from your usage and manage context data"
    case .permissions:
      return "macOS permissions"
    case .about:
      return "Privacy, welcome tour, shortcuts, reset, and support"
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

  @MainActor
  private func setupWindow() {
    NSApp.activate(ignoringOtherApps: true)
    if let window = NSApp.windows.first(where: { $0.isKeyWindow }) {
      window.makeKeyAndOrderFront(nil)
    }
    if !GeminiCredentialProvider.shared.hasCredential() {
      focusedField = .googleAPIKey
    }
  }

  private func setupFloatingWindow() {
    if let window = NSApp.windows.first(where: { $0.isKeyWindow }) {
      window.level = .floating
    }
  }
}
