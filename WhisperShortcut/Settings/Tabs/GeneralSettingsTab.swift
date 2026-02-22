import SwiftUI
import AppKit

/// General Settings Tab - API Key and Support & Feedback
struct GeneralSettingsTab: View {
  @ObservedObject var viewModel: SettingsViewModel
  @FocusState.Binding var focusedField: SettingsFocusField?
  @State private var userContextText: String = ""
  @State private var showResetToDefaultsConfirmation = false
  @State private var googleSignInEmail: String? = nil
  @State private var googleSignInRefresh: Int = 0
  @State private var googleSignInError: String? = nil
  @State private var isSigningIn = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Google account (Sign in with Google)
      googleAccountSection

      SpacedSectionDivider()

      // Google API Key Section
      googleAPIKeySection

      SpacedSectionDivider()

      // User Context Section
      userContextSection

      SpacedSectionDivider()

      // Launch at Login Section
      launchAtLoginSection

      SpacedSectionDivider()

      // Popup Notifications Section
      popupNotificationsSection

      SpacedSectionDivider()

      // Recording Safeguards Section
      recordingSafeguardsSection

      SpacedSectionDivider()

      // Clipboard Behavior Section
      clipboardBehaviorSection

      SpacedSectionDivider()

      // Keyboard Shortcut Section
      keyboardShortcutsSection

      SpacedSectionDivider()

      // Data & Reset Section
      resetSection

      SpacedSectionDivider()

      // Support & Feedback Section (always last)
      supportFeedbackSection
    }
    .confirmationDialog("Reset app to default?", isPresented: $showResetToDefaultsConfirmation, titleVisibility: .visible) {
      Button("Reset and quit app", role: .destructive) {
        viewModel.resetAllDataAndRestart()
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("This will set all system prompts to default, all settings to default, model selection to default, and delete all user interactions. The API key is preserved.\n\nThe app will close automatically after the reset. You can start it again from the menu bar or Applications. Continue?")
    }
  }

  // MARK: - Launch at Login Section
  @ViewBuilder
  private var launchAtLoginSection: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "🚀 Startup",
        subtitle: "Automatically start WhisperShortcut when you log in"
      )

      HStack(alignment: .center, spacing: 16) {
        Text("Launch at Login:")
          .font(.body)
          .fontWeight(.medium)
          .frame(width: SettingsConstants.labelWidth, alignment: .leading)

        Toggle("", isOn: Binding(
          get: { viewModel.data.launchAtLogin },
          set: { newValue in
            viewModel.setLaunchAtLogin(newValue)
          }
        ))
        .toggleStyle(SwitchToggleStyle())

        Spacer()
      }
    }
  }

  // MARK: - Keyboard Shortcut Section
  @ViewBuilder
  private var keyboardShortcutsSection: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "⌨️ Keyboard Shortcut",
        subtitle: "Configure keyboard shortcuts for various features"
      )

      ShortcutInputRow(
        label: "Toggle Settings:",
        placeholder: "e.g., command+6",
        text: $viewModel.data.openSettings,
        isEnabled: $viewModel.data.openSettingsEnabled,
        focusedField: .toggleSettings,
        currentFocus: $focusedField,
        onShortcutChanged: {
          Task {
            await viewModel.saveSettings()
          }
        },
        validateShortcut: viewModel.validateShortcut
      )

      // Available Keys Information
      VStack(alignment: .leading, spacing: 8) {
        Text("Available keys:")
          .font(.callout)
          .fontWeight(.semibold)
          .foregroundColor(.secondary)
          .textSelection(.enabled)

        Text(
          "command • option • control • shift • a-z • 0-9 • f1-f12 • escape • up • down • left • right • comma • period"
        )
        .font(.callout)
        .foregroundColor(.secondary)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
      }
      .textSelection(.enabled)
    }
  }

  // MARK: - Google Account Section (Sign in with Google)
  @ViewBuilder
  private var googleAccountSection: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "Google Account",
        subtitle: "Sign in with Google to use Gemini without an API key"
      )
      .id(googleSignInRefresh)

      let authService = DefaultGoogleAuthService.shared
      let isSignedIn = authService.isSignedIn()

      if isSignedIn {
        HStack(alignment: .center, spacing: 16) {
          if let email = googleSignInEmail ?? authService.signedInUserEmail() {
            Text("Signed in as \(email)")
              .font(.callout)
              .foregroundColor(.secondary)
              .lineLimit(1)
              .truncationMode(.tail)
          }
          Button("Sign out") {
            authService.signOut()
            googleSignInEmail = nil
            googleSignInRefresh += 1
          }
          .buttonStyle(.bordered)
        }
      } else {
        HStack(alignment: .center, spacing: 16) {
          Button("Sign in with Google") {
            isSigningIn = true
            googleSignInError = nil
            Task {
              do {
                try await authService.signIn()
                await MainActor.run {
                  googleSignInEmail = authService.signedInUserEmail()
                  googleSignInRefresh += 1
                  isSigningIn = false
                }
              } catch {
                await MainActor.run {
                  googleSignInError = error.localizedDescription
                  isSigningIn = false
                  googleSignInRefresh += 1
                }
              }
            }
          }
          .buttonStyle(.borderedProminent)
          .disabled(isSigningIn)
          if isSigningIn {
            ProgressView()
              .scaleEffect(0.8)
          }
        }
        if let err = googleSignInError {
          Text(err)
            .font(.caption)
            .foregroundColor(.red)
        }
      }

      Text("When signed in, Gemini usage is billed to the app’s Google Cloud project. You can also use an API key below instead.")
        .font(.caption)
        .foregroundColor(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .onAppear {
      googleSignInEmail = DefaultGoogleAuthService.shared.signedInUserEmail()
    }
  }

  // MARK: - Google API Key Section
  @ViewBuilder
  private var googleAPIKeySection: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "🔑 Google API Key",
        subtitle: "Optional when signed in with Google. Required for Gemini if you don’t sign in."
      )

      HStack(alignment: .center, spacing: 16) {
        Text("API Key:")
          .font(.body)
          .fontWeight(.medium)
          .frame(width: SettingsConstants.labelWidth, alignment: .leading)
          .textSelection(.enabled)

        TextField("AIza...", text: $viewModel.data.googleAPIKey)
          .textFieldStyle(.roundedBorder)
          .font(.system(.body, design: .monospaced))
          .frame(height: SettingsConstants.textFieldHeight)
          .frame(maxWidth: SettingsConstants.apiKeyMaxWidth)
          .onAppear {
            viewModel.data.googleAPIKey = KeychainManager.shared.getGoogleAPIKey() ?? ""
          }
          .focused($focusedField, equals: .googleAPIKey)
          .onChange(of: viewModel.data.googleAPIKey) { _, newValue in
            // Auto-save Google API key to keychain
            Task {
              _ = KeychainManager.shared.saveGoogleAPIKey(newValue)
            }
          }

        Spacer()
      }

      HStack(spacing: 0) {
        Text("Need an API key? Get one at ")
          .font(.callout)
          .foregroundColor(.secondary)
          .textSelection(.enabled)

        Link(
          destination: URL(string: "https://aistudio.google.com/api-keys")!
        ) {
          Text("aistudio.google.com/api-keys")
            .font(.callout)
            .foregroundColor(.blue)
            .underline()
            .textSelection(.enabled)
        }
        .onHover { isHovered in
          if isHovered {
            NSCursor.pointingHand.push()
          } else {
            NSCursor.pop()
          }
        }

        Text(" 💡")
          .font(.callout)
          .foregroundColor(.secondary)
      }
      .fixedSize(horizontal: false, vertical: true)

      HStack(spacing: 0) {
        Text("Configure rate limits at ")
          .font(.callout)
          .foregroundColor(.secondary)
          .textSelection(.enabled)

        Link(
          destination: URL(string: "https://console.cloud.google.com/apis/api/generativelanguage.googleapis.com/quotas")!
        ) {
          Text("console.cloud.google.com/.../quotas")
            .font(.callout)
            .foregroundColor(.blue)
            .underline()
            .textSelection(.enabled)
        }
        .onHover { isHovered in
          if isHovered {
            NSCursor.pointingHand.push()
          } else {
            NSCursor.pop()
          }
        }
      }
      .fixedSize(horizontal: false, vertical: true)
    }
  }

  // MARK: - Popup Notifications Section
  @ViewBuilder
  private var popupNotificationsSection: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "🔔 Popup Notifications",
        subtitle: "Show popup windows with transcription and AI response text"
      )

      HStack(alignment: .center, spacing: 16) {
        Text("Show Notifications:")
          .font(.body)
          .fontWeight(.medium)
          .frame(width: SettingsConstants.labelWidth, alignment: .leading)

        Toggle("", isOn: $viewModel.data.showPopupNotifications)
          .toggleStyle(SwitchToggleStyle())
          .onChange(of: viewModel.data.showPopupNotifications) { _, _ in
            Task {
              await viewModel.saveSettings()
            }
          }

        Spacer()
      }

      // Position Selection
      HStack(alignment: .center, spacing: 16) {
        Text("Position:")
          .font(.body)
          .fontWeight(.medium)
          .frame(width: SettingsConstants.labelWidth, alignment: .leading)

        Picker("", selection: $viewModel.data.notificationPosition) {
          ForEach(NotificationPosition.allCases, id: \.rawValue) { position in
            Text(position.displayName)
              .tag(position)
          }
        }
        .pickerStyle(MenuPickerStyle())
        .frame(width: 200)
        .onChange(of: viewModel.data.notificationPosition) { _, _ in
          Task {
            await viewModel.saveSettings()
          }
        }

        Spacer()
      }

      // Duration Selection
      HStack(alignment: .center, spacing: 16) {
        Text("Duration:")
          .font(.body)
          .fontWeight(.medium)
          .frame(width: SettingsConstants.labelWidth, alignment: .leading)

        Picker("", selection: $viewModel.data.notificationDuration) {
          ForEach(NotificationDuration.allCases, id: \.rawValue) { duration in
            HStack {
              Text(duration.displayName)
              if duration.isRecommended {
                Text("(Recommended)")
                  .font(.caption)
                  .foregroundColor(.secondary)
              }
            }
            .tag(duration)
          }
        }
        .pickerStyle(MenuPickerStyle())
        .frame(width: 200)
        .onChange(of: viewModel.data.notificationDuration) { _, _ in
          Task {
            await viewModel.saveSettings()
          }
        }

        Spacer()
      }

      Text(
        "When enabled, popup windows will appear showing the transcribed text, AI responses, and voice response text."
      )
      .font(.callout)
      .foregroundColor(.secondary)
      .fixedSize(horizontal: false, vertical: true)
    }
  }

  // MARK: - Recording Safeguards Section
  @ViewBuilder
  private var recordingSafeguardsSection: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "🛡️ Recording Safeguards",
        subtitle: "Ask before processing long recordings to avoid accidental API usage"
      )

      HStack(alignment: .center, spacing: 16) {
        Text("Ask when recording longer than:")
          .font(.body)
          .fontWeight(.medium)
          .frame(width: SettingsConstants.labelWidth, alignment: .leading)

        Picker("", selection: $viewModel.data.confirmAboveDuration) {
          ForEach(ConfirmAboveDuration.allCases, id: \.rawValue) { duration in
            HStack {
              Text(duration.displayName)
              if duration.isRecommended {
                Text("(Recommended)")
                  .font(.caption)
                  .foregroundColor(.secondary)
              }
            }
            .tag(duration)
          }
        }
        .pickerStyle(MenuPickerStyle())
        .frame(width: 200)
        .onChange(of: viewModel.data.confirmAboveDuration) { _, _ in
          Task {
            await viewModel.saveSettings()
          }
        }

        Spacer()
      }
    }
  }

  // MARK: - Clipboard Behavior Section
  @ViewBuilder
  private var clipboardBehaviorSection: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "📋 Clipboard Behavior",
        subtitle: "Configure what happens after dictation or prompt mode completes"
      )

      HStack(alignment: .center, spacing: 16) {
        Text("Auto-paste:")
          .font(.body)
          .fontWeight(.medium)
          .frame(width: SettingsConstants.labelWidth, alignment: .leading)

        Toggle("", isOn: $viewModel.data.autoPasteAfterDictation)
          .toggleStyle(SwitchToggleStyle())
          .onChange(of: viewModel.data.autoPasteAfterDictation) { _, _ in
            Task {
              await viewModel.saveSettings()
            }
          }

        Spacer()
      }

      Text("When enabled, transcriptions and AI responses are automatically pasted at the cursor position (simulates ⌘V). Works for both Dictate and Dictate Prompt modes.")
        .font(.callout)
        .foregroundColor(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  // MARK: - User Context Section
  @ViewBuilder
  private var userContextSection: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      PromptTextEditor(
        title: "🧠 User Context",
        subtitle: "Optional. Describe your language, topics, and style. Included in Dictate Prompt and Dictate Prompt & Read system prompts.",
        helpText: "This text is appended to the system prompt in prompt modes when non-empty. Leave empty to use no extra context.",
        defaultValue: "",
        text: $userContextText,
        focusedField: .userContext,
        currentFocus: $focusedField,
        onTextChanged: {
          saveUserContextToFile()
        }
      )
    }
    .onAppear {
      loadUserContextFromFile()
    }
    .onReceive(NotificationCenter.default.publisher(for: .userContextFileDidUpdate)) { _ in
      loadUserContextFromFile()
    }
  }

  private func loadUserContextFromFile() {
    let contextDir = UserContextLogger.shared.directoryURL
    let fileURL = contextDir.appendingPathComponent("user-context.md")
    userContextText = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
  }

  private func saveUserContextToFile() {
    let contextDir = UserContextLogger.shared.directoryURL
    if !FileManager.default.fileExists(atPath: contextDir.path) {
      try? FileManager.default.createDirectory(at: contextDir, withIntermediateDirectories: true)
    }
    let fileURL = contextDir.appendingPathComponent("user-context.md")
    if userContextText.isEmpty {
      try? FileManager.default.removeItem(at: fileURL)
    } else {
      try? userContextText.write(to: fileURL, atomically: true, encoding: .utf8)
    }
  }

  private func openDataFolderInFinder() {
    let url = AppSupportPaths.whisperShortcutApplicationSupportURL()
    if !FileManager.default.fileExists(atPath: url.path) {
      try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    NSWorkspace.shared.open(url)
  }

  private var dataFolderDisplayPath: String {
    let path = AppSupportPaths.whisperShortcutApplicationSupportURL().path
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    if path.hasPrefix(home) {
      return "~" + String(path.dropFirst(home.count))
    }
    return path
  }

  // MARK: - Support & Feedback Section
  @ViewBuilder
  private var supportFeedbackSection: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "💬 Support & Feedback",
        subtitle:
          "If you have feedback, if something doesn't work, or if you have suggestions for improvement, feel free to contact me via WhatsApp."
      )

      VStack(alignment: .leading, spacing: 20) {
        // Main Action Buttons
        VStack(spacing: 12) {
          // WhatsApp Contact Button
          Button(action: {
            viewModel.openWhatsAppFeedback()
          }) {
            HStack(alignment: .center, spacing: 12) {
              Image("WhatsApp")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 18, height: 18)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .opacity(0.85)
              
              Text("Contact me on WhatsApp")
                .font(.body)
                .fontWeight(.medium)
                .textSelection(.enabled)

              Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(12)
          }
          .buttonStyle(PlainButtonStyle())
          .help("Contact via WhatsApp")
          .onHover { isHovered in
            if isHovered {
              NSCursor.pointingHand.push()
            } else {
              NSCursor.pop()
            }
          }

          // App Store Review Button
          Button(action: {
            viewModel.openAppStoreReview()
          }) {
            HStack(alignment: .center, spacing: 12) {
              Image(systemName: "star.fill")
                .font(.system(size: 18))
                .foregroundColor(.orange)
                .opacity(0.85)
              
              Text("Leave a Review")
                .font(.body)
                .fontWeight(.medium)
                .textSelection(.enabled)

              Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(12)
          }
          .buttonStyle(PlainButtonStyle())
          .help("Leave a review on the App Store")
          .onHover { isHovered in
            if isHovered {
              NSCursor.pointingHand.push()
            } else {
              NSCursor.pop()
            }
          }
          // Share with Friends Button
          Button(action: {
            viewModel.copyAppStoreLink()
          }) {
            HStack(alignment: .center, spacing: 12) {
              Image(systemName: viewModel.data.appStoreLinkCopied ? "checkmark.circle.fill" : "link")
                .font(.system(size: 18))
                .foregroundColor(viewModel.data.appStoreLinkCopied ? .green : .blue)
                .opacity(0.85)
              
              Text(viewModel.data.appStoreLinkCopied ? "Link copied!" : "Share with Friends")
                .font(.body)
                .fontWeight(.medium)
                .textSelection(.enabled)

              Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(12)
          }
          .buttonStyle(PlainButtonStyle())
          .help(viewModel.data.appStoreLinkCopied ? "App Store link copied to clipboard" : "Copy App Store link to clipboard")
          .onHover { isHovered in
            if isHovered {
              NSCursor.pointingHand.push()
            } else {
              NSCursor.pop()
            }
          }

          // GitHub Button
          Button(action: {
            viewModel.openGitHub()
          }) {
            HStack(alignment: .center, spacing: 12) {
              Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 18))
                .foregroundColor(.secondary)
                .opacity(0.85)

              Text("Open on GitHub")
                .font(.body)
                .fontWeight(.medium)
                .textSelection(.enabled)

              Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(12)
          }
          .buttonStyle(PlainButtonStyle())
          .help("Open the WhisperShortcut repository on GitHub")
          .onHover { isHovered in
            if isHovered {
              NSCursor.pointingHand.push()
            } else {
              NSCursor.pop()
            }
          }
        }
        
        // Developer Footer (no divider)
        HStack(spacing: 16) {
          Image("me")
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: 64, height: 64)
            .clipShape(Circle())
          
          VStack(alignment: .leading, spacing: 4) {
            Text("— Magnus • Developer")
              .font(.body)
              .foregroundColor(.secondary)
              .opacity(0.8)
            
            Text("Karlsruhe, Germany 🇩🇪")
              .font(.subheadline)
              .foregroundColor(.secondary)
              .opacity(0.7)
          }
          
          Spacer()
        }
        .padding(.top, 12)
      }
    }
  }

  // MARK: - Data & Reset Section
  @ViewBuilder
  private var resetSection: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "Data & Reset",
        subtitle: "Resets the app to its original state: all system prompts to default, all settings to default, model selection to default, and all user interactions deleted. API key is preserved. To delete only interaction data, use the Smart Improvement tab."
      )

      HStack(alignment: .center, spacing: 12) {
        Button(action: { openDataFolderInFinder() }) {
          Label("Open app data folder", systemImage: "folder")
            .font(.callout)
        }
        .buttonStyle(.bordered)
        .help("Open app data folder in Finder")

        Button("Reset all to defaults", role: .destructive) {
          showResetToDefaultsConfirmation = true
        }
        .buttonStyle(.bordered)
        .tint(.red)
        .help("Reset app to original state; app will quit after reset")
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}
