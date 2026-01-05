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
  let onTextChanged: (() -> Void)?
  
  init(
    title: String,
    subtitle: String,
    helpText: String,
    defaultValue: String,
    text: Binding<String>,
    focusedField: SettingsFocusField,
    currentFocus: FocusState<SettingsFocusField?>.Binding,
    onTextChanged: (() -> Void)? = nil
  ) {
    self.title = title
    self.subtitle = subtitle
    self.helpText = helpText
    self.defaultValue = defaultValue
    self._text = text
    self.focusedField = focusedField
    self._currentFocus = currentFocus
    self.onTextChanged = onTextChanged
  }

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
          .onChange(of: text) { _, _ in
            onTextChanged?()
          }

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
