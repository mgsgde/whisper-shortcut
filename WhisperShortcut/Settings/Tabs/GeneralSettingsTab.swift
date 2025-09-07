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

      // Conversation Timeout Section
      conversationTimeoutSection

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
        Text("💡 Need an API key? Get one at ")
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
      }
      .fixedSize(horizontal: false, vertical: true)
    }
  }

  // MARK: - Conversation Timeout Section
  @ViewBuilder
  private var conversationTimeoutSection: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "🧠 Conversation Memory",
        subtitle:
          "Automatically clear conversation history after this time to save costs (only applies when dictating prompts, not transcription)"
      )

      ConversationTimeoutSelectionView(selectedTimeout: $viewModel.data.conversationTimeout)
        .onChange(of: viewModel.data.conversationTimeout) { _, _ in
          // Auto-save timeout setting
          Task {
            await viewModel.saveSettings()
          }
        }
    }
  }

  // MARK: - GPT-5 Reasoning Effort Section
  @ViewBuilder
  private var reasoningEffortSection: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "🧠 GPT-5 Reasoning Effort",
        subtitle:
          "Control the depth of analysis for GPT-5 models. Higher effort provides better quality but slower responses."
      )

      VStack(alignment: .leading, spacing: 16) {
        ReasoningEffortSelectionView(
          selectedEffort: $viewModel.data.promptReasoningEffort,
          title: "Prompt Reasoning Effort",
          description: "Controls analysis depth for 'Dictate, Prompt' mode"
        )
        .onChange(of: viewModel.data.promptReasoningEffort) { _, _ in
          Task {
            await viewModel.saveSettings()
          }
        }

        Divider()
          .padding(.vertical, 8)

        ReasoningEffortSelectionView(
          selectedEffort: $viewModel.data.voiceResponseReasoningEffort,
          title: "Voice Response Reasoning Effort",
          description: "Controls analysis depth for 'Dictate, Prompt and Speak' mode"
        )
        .onChange(of: viewModel.data.voiceResponseReasoningEffort) { _, _ in
          Task {
            await viewModel.saveSettings()
          }
        }
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
