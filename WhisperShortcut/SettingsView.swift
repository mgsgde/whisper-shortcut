import SwiftUI

/// Modern Settings view with sidebar navigation (macOS System Settings style).
struct SettingsView: View {
  @StateObject private var viewModel = SettingsViewModel()
  @AppStorage(UserDefaultsKeys.settingsSelectedTab) private var selectedTabRaw: String =
    SettingsTab.general.rawValue
  @Environment(\.dismiss) private var dismiss
  @FocusState private var focusedField: SettingsFocusField?

  /// A stored or requested tab that "Dictation only" hides falls back to General; the stored
  /// raw value is left as it is, so the full app returns to the tab the user had.
  private var selectedTab: SettingsTab {
    let tab = SettingsTab(rawValue: selectedTabRaw) ?? .general
    return DictationOnlyMode.visibleTabs([tab], enabled: DictationOnlyMode.isEnabled).first ?? .general
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
    .onReceive(NotificationCenter.default.publisher(for: .dictationOnlyModeChanged)) { _ in
      // The sidebar and the selected tab read the flag when the body runs; a changed
      // `@AppStorage` value forces that.
      selectedTabRaw = selectedTab.rawValue
    }
    .onReceive(NotificationCenter.default.publisher(for: .openPrivacyPermissionsTab)) { _ in
      selectedTabRaw = SettingsTab.permissions.rawValue
    }
    .onReceive(NotificationCenter.default.publisher(for: .openSettingsTab)) { note in
      if let raw = note.object as? String, SettingsTab(rawValue: raw) != nil {
        selectedTabRaw = raw
      }
    }
  }

  // MARK: - Sidebar
  @ViewBuilder
  private var sidebar: some View {
    List(selection: Binding<SettingsTab?>(
      get: { selectedTab },
      set: { if let tab = $0 { selectedTabRaw = tab.rawValue } }
    )) {
      ForEach(SettingsTab.sections, id: \.self) { section in
        Section {
          ForEach(section.tabs, id: \.self) { tab in
            sidebarRow(for: tab)
          }
        } header: {
          Text(section.displayName)
        }
      }
    }
    .listStyle(.sidebar)
    .frame(minWidth: 270, idealWidth: 270, maxWidth: 300)
  }

  /// One sidebar row. The `NavigationLink` carries the tab as its value, which is what the
  /// `List`'s selection binding above tracks.
  private func sidebarRow(for tab: SettingsTab) -> some View {
    NavigationLink(value: tab) {
      HStack(spacing: 10) {
        Image(systemName: iconName(for: tab))
          .font(.body)
          .foregroundColor(.accentColor)
          .frame(width: 20, height: 20)

        Text(tab.displayName)
          .font(.body)
      }
      .padding(.vertical, 2)
    }
    .help(Text(description(for: tab)))
    .pointerCursorOnHover()
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
      ScrollViewReader { proxy in
        ScrollView {
          VStack(spacing: SettingsConstants.spacing) {
            switch selectedTab {
            case .general:
              GeneralSettingsTab(viewModel: viewModel, focusedField: $focusedField)
            case .accounts:
              AccountsSettingsTab(viewModel: viewModel, focusedField: $focusedField)
            case .speechToText:
              SpeechToTextSettingsTab(viewModel: viewModel, focusedField: $focusedField)
            case .speechToPrompt:
              SpeechToPromptSettingsTab(viewModel: viewModel, focusedField: $focusedField)
            case .templates:
              TemplatesSettingsTab(viewModel: viewModel, focusedField: $focusedField)
            case .screenshot:
              ScreenshotSettingsTab(viewModel: viewModel, focusedField: $focusedField)
            case .chat:
              ChatSettingsTab(viewModel: viewModel, focusedField: $focusedField)
            case .meetings:
              MeetingsSettingsTab(viewModel: viewModel, focusedField: $focusedField)
            case .readAloud:
              ReadAloudSettingsTab(viewModel: viewModel, focusedField: $focusedField)
            case .aiApps:
              AIAppsSettingsTab()
            case .permissions:
              PermissionsTab(viewModel: viewModel)
            case .about:
              AboutSettingsTab(viewModel: viewModel)
            }
          }
          .padding(.horizontal, SettingsConstants.horizontalPadding)
          .padding(.top, SettingsConstants.topPadding)
          .padding(.bottom, SettingsConstants.bottomPadding)
        }
        .settingsSoftTopScrollEdge()
        .onReceive(NotificationCenter.default.publisher(for: .openSettingsTab)) { note in
          guard let anchor = note.userInfo?[SettingsAnchor.userInfoKey] as? String else { return }
          // The tab switch from the same post renders on the next pass; scroll once it has.
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            withAnimation { proxy.scrollTo(anchor, anchor: .top) }
          }
        }
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
    case .accounts:
      return "key"
    case .speechToText:
      return "mic"
    case .speechToPrompt:
      return "text.bubble"
    case .templates:
      return "doc.text"
    case .screenshot:
      return "camera.viewfinder"
    case .chat:
      return "sparkles"
    case .meetings:
      return "record.circle"
    case .readAloud:
      return "speaker.wave.2.fill"
    case .aiApps:
      return "point.3.connected.trianglepath.dotted"
    case .permissions:
      return "checkmark.shield"
    case .about:
      return "info.circle"
    }
  }

  private func description(for tab: SettingsTab) -> LocalizedStringKey {
    switch tab {
    case .general:
      return "Shortcuts, app behavior, updates, and reset"
    case .accounts:
      return "API keys, OpenRouter, and connected services"
    case .speechToText:
      return "Model, system prompt, and shortcut"
    case .speechToPrompt:
      return "Model, system prompt, and shortcut"
    case .templates:
      return "Formats to dictate into, and their shortcut"
    case .screenshot:
      return "Shortcut and save-to-folder settings"
    case .chat:
      return "Model, system prompt, commands, and memory"
    case .meetings:
      return "Meeting transcription and summaries"
    case .readAloud:
      return "Shortcut and smart-rewrite settings"
    case .aiApps:
      return "Connect Claude and other AI apps to set up WhisperShortcut and read your meetings"
    case .permissions:
      return "Offline Mode, macOS permissions, and privacy"
    case .about:
      return "What's new, support, and acknowledgements"
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
    // Focus the key field only where it is on screen: Accounts. Jumping to Accounts on every open
    // would trap users who work offline or through OpenRouter.
    if selectedTab == .accounts && !GeminiCredentialProvider.shared.hasCredential() {
      focusedField = .googleAPIKey
    }
  }
}

private extension View {
  /// macOS 26 draws a hard, semi-opaque band under the unified toolbar when content scrolls
  /// beneath it, which covers section headers. A soft edge fades the content out instead.
  @ViewBuilder
  func settingsSoftTopScrollEdge() -> some View {
    if #available(macOS 26.0, *) {
      scrollEdgeEffectStyle(.soft, for: .top)
    } else {
      self
    }
  }
}
