import SwiftUI

/// General Settings Tab - API Key und Support & Feedback
struct GeneralSettingsTab: View {
  @ObservedObject var viewModel: SettingsViewModel
  @FocusState.Binding var focusedField: SettingsFocusField?
  
  var body: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.spacing) {
      // API Key Section
      apiKeySection
      
      // Support & Feedback Section
      supportFeedbackSection
    }
  }
  
  // MARK: - API Key Section
  @ViewBuilder
  private var apiKeySection: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.sectionSpacing) {
      SectionHeader(title: "OpenAI API Key")

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
      .padding(.top, 4)
      .textSelection(.enabled)
    }
  }
  
  // MARK: - Support & Feedback Section
  @ViewBuilder
  private var supportFeedbackSection: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.sectionSpacing) {
      SectionHeader(title: "Support & Feedback")

      Button(action: {
        viewModel.openWhatsAppFeedback()
      }) {
        HStack(alignment: .top, spacing: 16) {
          Image("WhatsApp")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 12))

          VStack(alignment: .leading, spacing: 8) {
            Text("Thanks for using WhisperShortcut!")
              .font(.body)
              .fontWeight(.medium)
              .textSelection(.enabled)

            Text(
              "If you have feedback, if something doesn't work, or if you have suggestions for improvement, feel free to contact me via WhatsApp."
            )
            .font(.callout)
            .foregroundColor(.secondary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
          }

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
