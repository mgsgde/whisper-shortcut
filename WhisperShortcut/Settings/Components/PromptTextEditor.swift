import SwiftUI

/// Wiederverwendbare Komponente für Prompt-Texteditoren
struct PromptTextEditor: View {
  let title: String
  let subtitle: String
  let helpText: String
  let defaultValue: String
  @Binding var text: String
  let focusedField: SettingsFocusField
  @FocusState.Binding var currentFocus: SettingsFocusField?

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(title: title, subtitle: subtitle)

      VStack(alignment: .leading, spacing: 8) {
        TextEditor(text: $text)
          .font(.system(.body, design: .default))
          .frame(height: SettingsConstants.textEditorHeight)
          .padding(8)
          .background(Color(.controlBackgroundColor))
          .cornerRadius(SettingsConstants.cornerRadius)
          .overlay(
            RoundedRectangle(cornerRadius: SettingsConstants.cornerRadius)
              .stroke(Color(.separatorColor), lineWidth: 1)
          )
          .focused($currentFocus, equals: focusedField)

        Text(helpText)
          .font(.callout)
          .foregroundColor(.secondary)
          .textSelection(.enabled)

        HStack {
          Spacer()
          Button("Reset to Default") {
            text = defaultValue
          }
          .buttonStyle(.bordered)
          .font(.callout)
        }
      }
    }
  }
}

#if DEBUG
  struct PromptTextEditor_Previews: PreviewProvider {
    static var previews: some View {
      @State var text = "Enter your custom prompt here..."
      @FocusState var currentFocus: SettingsFocusField?

      PromptTextEditor(
        title: "Custom Prompt",
        subtitle: "Domain Terms & Context:",
        helpText:
          "Describe domain terms for better transcription quality. Leave empty to use OpenAI's default.",
        defaultValue: "Default prompt text",
        text: $text,
        focusedField: .customPrompt,
        currentFocus: $currentFocus
      )
      .padding()
      .frame(width: 600)
    }
  }
#endif
