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
  /// Stored "previous" value (before last Apply); used for toggle button label/action.
  let previousValue: String?
  /// Stored "last applied" value; used for toggle button label/action.
  let lastAppliedValue: String?
  let onResetToPrevious: (() -> Void)?
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
    previousValue: String? = nil,
    lastAppliedValue: String? = nil,
    onResetToPrevious: (() -> Void)? = nil,
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
    self.previousValue = previousValue
    self.lastAppliedValue = lastAppliedValue
    self.onResetToPrevious = onResetToPrevious
    self.onResetToLatest = onResetToLatest
    self.trailingContent = trailingContent
  }

  /// One toggle button: "Reset to Previous" when current is latest, "Reset to Latest" when current is previous.
  private var showToggleButton: Bool { previousValue != nil || lastAppliedValue != nil }
  private var toggleButtonLabel: String {
    if text == lastAppliedValue { return "Reset to Previous" }
    if text == previousValue { return "Reset to Latest" }
    return "Reset to Previous"
  }
  private var toggleButtonAction: (() -> Void)? {
    if text == lastAppliedValue { return onResetToPrevious }
    if text == previousValue { return onResetToLatest }
    return onResetToPrevious
  }
  private var toggleButtonEnabled: Bool {
    if text == lastAppliedValue { return onResetToPrevious != nil }
    if text == previousValue { return onResetToLatest != nil }
    return onResetToPrevious != nil
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
          if showToggleButton, let action = toggleButtonAction {
            Button(toggleButtonLabel) {
              action()
            }
            .buttonStyle(.bordered)
            .font(.callout)
            .disabled(!toggleButtonEnabled)
          }
          if let trailingContent {
            trailingContent
          }
        }
      }
    }
  }
}
