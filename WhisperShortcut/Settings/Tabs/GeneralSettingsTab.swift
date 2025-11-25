import SwiftUI

/// General Settings Tab - API Key und Support & Feedback
struct GeneralSettingsTab: View {
  @ObservedObject var viewModel: SettingsViewModel
  @FocusState.Binding var focusedField: SettingsFocusField?

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
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

      // API Key Section
      apiKeySection

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

      // Support & Feedback Section
      supportFeedbackSection
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

  // MARK: - API Key Section
  @ViewBuilder
  private var apiKeySection: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "🔑 OpenAI API Key",
        subtitle: "Required for transcription and AI assistant functionality"
      )

      HStack(alignment: .center, spacing: 16) {
        Text("API Key:")
          .font(.body)
          .fontWeight(.medium)
          .frame(width: SettingsConstants.labelWidth, alignment: .leading)
          .textSelection(.enabled)

        TextField("sk-...", text: $viewModel.data.apiKey)
          .textFieldStyle(.roundedBorder)
          .font(.system(.body, design: .monospaced))
          .frame(height: SettingsConstants.textFieldHeight)
          .frame(maxWidth: SettingsConstants.apiKeyMaxWidth)
          .onAppear {
            viewModel.data.apiKey = KeychainManager.shared.getAPIKey() ?? ""
          }
          .focused($focusedField, equals: .apiKey)
          .onChange(of: viewModel.data.apiKey) { _, newValue in
            // Auto-save API key to keychain
            Task {
              _ = KeychainManager.shared.saveAPIKey(newValue)
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
          destination: URL(string: "https://platform.openai.com/account/api-keys")!
        ) {
          Text("platform.openai.com/account/api-keys")
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
        Text("Dauer:")
          .font(.body)
          .fontWeight(.medium)
          .frame(width: SettingsConstants.labelWidth, alignment: .leading)

        Picker("", selection: $viewModel.data.notificationDuration) {
          ForEach(NotificationDuration.allCases, id: \.rawValue) { duration in
            HStack {
              Text(duration.displayName)
              if duration.isRecommended {
                Text("(Empfohlen)")
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

  // MARK: - Support & Feedback Section
  @ViewBuilder
  private var supportFeedbackSection: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "💬 Support & Feedback",
        subtitle:
          "If you have feedback, if sth doesn't work, or if you have suggestions for improvement, feel free to contact me via WhatsApp."
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
}

#if DEBUG
  struct GeneralSettingsTab_Previews: PreviewProvider {
    static var previews: some View {
      @FocusState var focusedField: SettingsFocusField?

      GeneralSettingsTab(viewModel: SettingsViewModel(), focusedField: $focusedField)
        .padding()
        .frame(width: 600, height: 400)
    }
  }
#endif
