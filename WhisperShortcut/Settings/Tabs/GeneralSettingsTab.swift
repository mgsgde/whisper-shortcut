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

      // Open ChatGPT Shortcut Section
      openChatGPTSection

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
        title: "OpenAI API Key",
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

        Spacer()
      }

      Text(
        "💡 Need an API key? Get one at [platform.openai.com/account/api-keys](https://platform.openai.com/account/api-keys)"
      )
      .font(.callout)
      .foregroundColor(.secondary)
      .textSelection(.enabled)
      .fixedSize(horizontal: false, vertical: true)
    }
  }

  // MARK: - Open ChatGPT Shortcut Section
  @ViewBuilder
  private var openChatGPTSection: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "Open ChatGPT Shortcut",
        subtitle: "Quick access to ChatGPT in your browser"
      )

      ShortcutInputRow(
        label: "Open ChatGPT:",
        placeholder: "e.g., command+1",
        text: $viewModel.data.openChatGPT,
        isEnabled: $viewModel.data.openChatGPTEnabled,
        focusedField: .openChatGPT,
        currentFocus: $focusedField
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

  // MARK: - Support & Feedback Section
  @ViewBuilder
  private var supportFeedbackSection: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "Support & Feedback",
        subtitle:
          "If you have feedback, if something doesn't work, or if you have suggestions for improvement, feel free to contact me via WhatsApp."
      )

      Button(action: {
        viewModel.openWhatsAppFeedback()
      }) {
        HStack(alignment: .center, spacing: 16) {
          Image("WhatsApp")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 12))

          Text("Thanks for using my app! :)")
            .font(.body)
            .fontWeight(.medium)
            .textSelection(.enabled)

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
