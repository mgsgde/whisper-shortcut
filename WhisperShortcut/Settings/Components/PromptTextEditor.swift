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
  let hasPrevious: Bool
  let onResetToPrevious: (() -> Void)?
  let hasLastApplied: Bool
  let onResetToLatest: (() -> Void)?
  let trailingContent: AnyView?

  init(
    title: String,
    subtitle: String,
    helpText: String,
    defaultValue: String,
    text: Binding<String>,
    focusedField: SettingsFocusField,
    currentFocus: FocusState<SettingsFocusField?>.Binding,
    onTextChanged: (() -> Void)? = nil,
    hasPrevious: Bool = false,
    onResetToPrevious: (() -> Void)? = nil,
    hasLastApplied: Bool = false,
    onResetToLatest: (() -> Void)? = nil,
    trailingContent: AnyView? = nil
  ) {
    self.title = title
    self.subtitle = subtitle
    self.helpText = helpText
    self.defaultValue = defaultValue
    self._text = text
    self.focusedField = focusedField
    self._currentFocus = currentFocus
    self.onTextChanged = onTextChanged
    self.hasPrevious = hasPrevious
    self.onResetToPrevious = onResetToPrevious
    self.hasLastApplied = hasLastApplied
    self.onResetToLatest = onResetToLatest
    self.trailingContent = trailingContent
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
          if hasPrevious, let onResetToPrevious {
            Button("Reset to Previous") {
              onResetToPrevious()
            }
            .buttonStyle(.bordered)
            .font(.callout)
          }
          if hasLastApplied, let onResetToLatest {
            Button("Reset to Latest") {
              onResetToLatest()
            }
            .buttonStyle(.bordered)
            .font(.callout)
          }
          if let trailingContent {
            trailingContent
          }
        }
      }
    }
  }
}
