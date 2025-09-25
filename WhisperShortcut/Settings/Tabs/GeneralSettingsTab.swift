import SwiftUI

/// General Settings Tab - API Key und Support & Feedback
struct GeneralSettingsTab: View {
  @ObservedObject var viewModel: SettingsViewModel
  @FocusState.Binding var focusedField: SettingsFocusField?

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
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
          "If you have feedback, if something doesn't work, or if you have suggestions for improvement, feel free to contact me via WhatsApp."
      )

      VStack(spacing: 12) {
        // WhatsApp Feedback Button
        Button(action: {
          viewModel.openWhatsAppFeedback()
        }) {
          HStack(alignment: .center, spacing: 16) {
            Text("Thanks for using my app! :)")
              .font(.body)
              .fontWeight(.medium)
              .textSelection(.enabled)

            Image("WhatsApp")
              .resizable()
              .aspectRatio(contentMode: .fit)
              .frame(width: 32, height: 32)
              .clipShape(RoundedRectangle(cornerRadius: 8))

            Spacer()
          }
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

        // App Store Link Copy Button
        Button(action: {
          viewModel.copyAppStoreLink()
        }) {
          HStack(alignment: .center, spacing: 16) {
            Text(viewModel.data.appStoreLinkCopied ? "Link copied!" : "Share with friends")
              .font(.body)
              .fontWeight(.medium)
              .textSelection(.enabled)
              .foregroundColor(viewModel.data.appStoreLinkCopied ? .green : .primary)

            Image(systemName: viewModel.data.appStoreLinkCopied ? "checkmark.circle.fill" : "link")
              .font(.system(size: 20))
              .foregroundColor(viewModel.data.appStoreLinkCopied ? .green : .blue)

            Spacer()
          }
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
