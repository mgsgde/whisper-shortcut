import SwiftUI
import AppKit

/// General Settings Tab - API Key and Support & Feedback
struct GeneralSettingsTab: View {
  @ObservedObject var viewModel: SettingsViewModel
  @FocusState.Binding var focusedField: SettingsFocusField?
  @State private var userContextText: String = ""
  @State private var selectedInterval: AutoImprovementInterval = .default
  @State private var selectedDictationThreshold: Int = AppConstants.promptImprovementDictationThreshold
  @State private var showDeleteInteractionConfirmation = false
  @State private var showResetToDefaultsConfirmation = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Google API Key Section
      googleAPIKeySection

      // Section Divider with spacing
      VStack(spacing: 0) {
        Spacer()
          .frame(height: SettingsConstants.sectionSpacing)
        SectionDivider()
        Spacer()
          .frame(height: SettingsConstants.sectionSpacing)
      }

      // Launch at Login Section
      launchAtLoginSection

      // Section Divider with spacing
      VStack(spacing: 0) {
        Spacer()
          .frame(height: SettingsConstants.sectionSpacing)
        SectionDivider()
        Spacer()
          .frame(height: SettingsConstants.sectionSpacing)
      }

      // Popup Notifications Section
      popupNotificationsSection

      // Section Divider with spacing
      VStack(spacing: 0) {
        Spacer()
          .frame(height: SettingsConstants.sectionSpacing)
        SectionDivider()
        Spacer()
          .frame(height: SettingsConstants.sectionSpacing)
      }

      // Recording Safeguards Section
      recordingSafeguardsSection

      // Section Divider with spacing
      VStack(spacing: 0) {
        Spacer()
          .frame(height: SettingsConstants.sectionSpacing)
        SectionDivider()
        Spacer()
          .frame(height: SettingsConstants.sectionSpacing)
      }

      // Clipboard Behavior Section
      clipboardBehaviorSection

      // Section Divider with spacing
      VStack(spacing: 0) {
        Spacer()
          .frame(height: SettingsConstants.sectionSpacing)
        SectionDivider()
        Spacer()
          .frame(height: SettingsConstants.sectionSpacing)
      }

      // Keyboard Shortcuts Section
      keyboardShortcutsSection

      // Section Divider with spacing
      VStack(spacing: 0) {
        Spacer()
          .frame(height: SettingsConstants.sectionSpacing)
        SectionDivider()
        Spacer()
          .frame(height: SettingsConstants.sectionSpacing)
      }

      // User Context Section
      userContextSection

      // Section Divider with spacing
      VStack(spacing: 0) {
        Spacer()
          .frame(height: SettingsConstants.sectionSpacing)
        SectionDivider()
        Spacer()
          .frame(height: SettingsConstants.sectionSpacing)
      }

      // Auto-Improvement Section
      autoImprovementSection

      // Section Divider with spacing
      VStack(spacing: 0) {
        Spacer()
          .frame(height: SettingsConstants.sectionSpacing)
        SectionDivider()
        Spacer()
          .frame(height: SettingsConstants.sectionSpacing)
      }

      // Daten & Zurücksetzen Section
      resetSection

      // Section Divider with spacing
      VStack(spacing: 0) {
        Spacer()
          .frame(height: SettingsConstants.sectionSpacing)
        SectionDivider()
        Spacer()
          .frame(height: SettingsConstants.sectionSpacing)
      }

      // Support & Feedback Section (always last)
      supportFeedbackSection
    }
    .confirmationDialog("Interaktionsdaten löschen", isPresented: $showDeleteInteractionConfirmation, titleVisibility: .visible) {
      Button("Löschen", role: .destructive) {
        viewModel.deleteInteractionData()
      }
      Button("Abbrechen", role: .cancel) {}
    } message: {
      Text("Interaktionsverlauf und abgeleiteter Kontext (user-context, Vorschläge) werden gelöscht. Einstellungen bleiben erhalten. Fortfahren?")
    }
    .confirmationDialog("Alles auf Default zurücksetzen", isPresented: $showResetToDefaultsConfirmation, titleVisibility: .visible) {
      Button("Zurücksetzen", role: .destructive) {
        viewModel.resetAllDataAndRestart()
      }
      Button("Abbrechen", role: .cancel) {}
    } message: {
      Text("Alle Einstellungen, Shortcuts und Interaktionsdaten werden gelöscht. Der API-Schlüssel bleibt erhalten. Die App wird beendet. Fortfahren?")
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

  // MARK: - Keyboard Shortcuts Section
  @ViewBuilder
  private var keyboardShortcutsSection: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "⌨️ Keyboard Shortcuts",
        subtitle: "Configure keyboard shortcuts for various features"
      )

      ShortcutInputRow(
        label: "Toggle Settings:",
        placeholder: "e.g., command+5",
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

  // MARK: - Google API Key Section
  @ViewBuilder
  private var googleAPIKeySection: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "🔑 Google API Key",
        subtitle: "Recommended • Required for Gemini transcription functionality"
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
        },
        previousValue: UserDefaults.standard.string(forKey: UserDefaultsKeys.previousUserContext),
        lastAppliedValue: UserDefaults.standard.string(forKey: UserDefaultsKeys.lastAppliedUserContext),
        onResetToPrevious: { viewModel.restorePreviousUserContext() },
        onResetToLatest: { viewModel.restoreToLastAppliedUserContext() }
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

  private func openInteractionsDirectoryInFinder() {
    let url = UserContextLogger.shared.directoryURL
    if !FileManager.default.fileExists(atPath: url.path) {
      try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    NSWorkspace.shared.open(url)
  }

  private var interactionsFolderDisplayPath: String {
    let path = UserContextLogger.shared.directoryURL.path
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    if path.hasPrefix(home) {
      return "~" + String(path.dropFirst(home.count))
    }
    return path
  }

  // MARK: - Auto-Improvement Section
  @ViewBuilder
  private var autoImprovementSection: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "🤖 Smart Improvement",
        subtitle: "Automatically improve system prompts based on your usage"
      )

      VStack(alignment: .leading, spacing: 16) {
        // Interval Picker
        VStack(alignment: .leading, spacing: 8) {
          Text("Automatic system prompt improvement")
            .font(.callout)
            .fontWeight(.medium)

          Picker("", selection: $selectedInterval) {
            ForEach(AutoImprovementInterval.allCases, id: \.self) { interval in
              Text(interval.displayName).tag(interval)
            }
          }
          .pickerStyle(.menu)
          .frame(maxWidth: 200)
          .onChange(of: selectedInterval) { newValue in
            UserDefaults.standard.set(newValue.rawValue, forKey: UserDefaultsKeys.autoPromptImprovementIntervalDays)
            let enabled = newValue != .never
            UserDefaults.standard.set(enabled, forKey: UserDefaultsKeys.userContextLoggingEnabled)
            DebugLogger.log("AUTO-IMPROVEMENT: Interval changed to \(newValue.displayName), logging = \(enabled)")
          }

          Text("Minimum cooldown between improvement runs. Set to \"Always\" for no cooldown.")
            .font(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }

        // Dictation Threshold Picker
        VStack(alignment: .leading, spacing: 8) {
          Text("Improvement after N dictations")
            .font(.callout)
            .fontWeight(.medium)

          Picker("", selection: $selectedDictationThreshold) {
            Text("2 dictations").tag(2)
            Text("5 dictations").tag(5)
            Text("10 dictations").tag(10)
            Text("20 dictations").tag(20)
            Text("50 dictations").tag(50)
          }
          .pickerStyle(.menu)
          .frame(maxWidth: 200)
          .onChange(of: selectedDictationThreshold) { _, newValue in
            UserDefaults.standard.set(newValue, forKey: UserDefaultsKeys.promptImprovementDictationThreshold)
            DebugLogger.log("AUTO-IMPROVEMENT: Dictation threshold changed to \(newValue)")
          }

          Text("An improvement run is triggered after this many successful dictations, provided the cooldown has passed.")
            .font(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }

        // Model selection for Smart Improvement
        PromptModelSelectionView(
          title: "🧠 Model for Smart Improvement",
          subtitle: "Used for automatic Smart Improvement (suggested prompts and user context).",
          selectedModel: Binding(
            get: { viewModel.data.selectedImprovementModel },
            set: { newValue in
              var d = viewModel.data
              d.selectedImprovementModel = newValue
              viewModel.data = d
            }
          ),
          onModelChanged: nil
        )

        // Interactions folder location (consistent with Live Meeting transcript location)
        VStack(alignment: .leading, spacing: 4) {
          Text("Interactions location:")
            .font(.callout)
            .fontWeight(.semibold)
            .foregroundColor(.secondary)
          Text(interactionsFolderDisplayPath)
            .font(.system(.callout, design: .monospaced))
            .foregroundColor(.secondary)
            .textSelection(.enabled)
          Button("Open Interactions Folder") {
            openInteractionsDirectoryInFinder()
          }
          .buttonStyle(.bordered)
          .font(.callout)
        }
        .padding(8)
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(6)
      }
    }
    .onAppear {
      // Load current settings
      let rawValue = UserDefaults.standard.integer(forKey: UserDefaultsKeys.autoPromptImprovementIntervalDays)
      selectedInterval = AutoImprovementInterval(rawValue: rawValue) ?? .default
      
      // Ensure logging matches the interval setting
      let enabled = selectedInterval != .never
      UserDefaults.standard.set(enabled, forKey: UserDefaultsKeys.userContextLoggingEnabled)

      // Load dictation threshold setting
      if UserDefaults.standard.object(forKey: UserDefaultsKeys.promptImprovementDictationThreshold) == nil {
        selectedDictationThreshold = AppConstants.promptImprovementDictationThreshold
      } else {
        selectedDictationThreshold = UserDefaults.standard.integer(forKey: UserDefaultsKeys.promptImprovementDictationThreshold)
      }

    }
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

  // MARK: - Daten & Zurücksetzen Section
  @ViewBuilder
  private var resetSection: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "Daten & Zurücksetzen",
        subtitle: "Interaktionsdaten (Verlauf, Kontext, Vorschläge) einzeln löschen oder alles auf Standardwerte zurücksetzen. API-Schlüssel bleibt erhalten."
      )

      // Interaktionsdaten löschen
      Button(action: {
        showDeleteInteractionConfirmation = true
      }) {
        HStack(alignment: .center, spacing: 12) {
          Image(systemName: "trash")
            .font(.system(size: 18))
            .foregroundColor(.secondary)

          Text("Interaktionsdaten löschen")
            .font(.body)
            .fontWeight(.medium)
            .foregroundColor(.primary)
            .textSelection(.enabled)

          Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(12)
      }
      .buttonStyle(PlainButtonStyle())
      .help("Nur Interaktionsverlauf und Kontext löschen; Einstellungen bleiben erhalten")
      .onHover { isHovered in
        if isHovered {
          NSCursor.pointingHand.push()
        } else {
          NSCursor.pop()
        }
      }

      // Alles auf Default zurücksetzen
      Button(action: {
        showResetToDefaultsConfirmation = true
      }) {
        HStack(alignment: .center, spacing: 12) {
          Image(systemName: "arrow.counterclockwise")
            .font(.system(size: 18))
            .foregroundColor(.red)
            .opacity(0.9)

          Text("Alles auf Default zurücksetzen")
            .font(.body)
            .fontWeight(.medium)
            .foregroundColor(.red)
            .textSelection(.enabled)

          Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(12)
      }
      .buttonStyle(PlainButtonStyle())
      .help("Alle Einstellungen und Daten zurücksetzen; App wird beendet")
      .onHover { isHovered in
        if isHovered {
          NSCursor.pointingHand.push()
        } else {
          NSCursor.pop()
        }
      }
    }
  }
}
