import SwiftUI

/// Wiederverwendbare Komponente für Shortcut-Eingabefelder
struct ShortcutInputRow: View {
  let label: String
  let placeholder: String
  @Binding var text: String
  @Binding var isEnabled: Bool
  let focusedField: SettingsFocusField
  @FocusState.Binding var currentFocus: SettingsFocusField?
  let onShortcutChanged: (() -> Void)?

  init(
    label: String,
    placeholder: String,
    text: Binding<String>,
    isEnabled: Binding<Bool>,
    focusedField: SettingsFocusField,
    currentFocus: FocusState<SettingsFocusField?>.Binding,
    onShortcutChanged: (() -> Void)? = nil
  ) {
    self.label = label
    self.placeholder = placeholder
    self._text = text
    self._isEnabled = isEnabled
    self.focusedField = focusedField
    self._currentFocus = currentFocus
    self.onShortcutChanged = onShortcutChanged
  }

  var body: some View {
    HStack(alignment: .center, spacing: 16) {
      Text(label)
        .font(.body)
        .fontWeight(.medium)
        .frame(width: SettingsConstants.labelWidth, alignment: .leading)
        .textSelection(.enabled)

      TextField(placeholder, text: $text)
        .textFieldStyle(.roundedBorder)
        .font(.system(.body, design: .monospaced))
        .frame(height: SettingsConstants.textFieldHeight)
        .frame(maxWidth: SettingsConstants.shortcutMaxWidth)
        .focused($currentFocus, equals: focusedField)
        .disabled(!isEnabled)
        .onChange(of: text) { _, _ in
          onShortcutChanged?()
        }
        .onChange(of: isEnabled) { _, _ in
          onShortcutChanged?()
        }

      Toggle("", isOn: $isEnabled)
        .toggleStyle(.checkbox)
        .help("Enable/disable this shortcut")

      Spacer()
    }
  }
}

#if DEBUG
  struct ShortcutInputRow_Previews: PreviewProvider {
    static var previews: some View {
      @State var text = "command+e"
      @State var isEnabled = true
      @FocusState var currentFocus: SettingsFocusField?

      ShortcutInputRow(
        label: "Toggle Dictation:",
        placeholder: "e.g., command+e",
        text: $text,
        isEnabled: $isEnabled,
        focusedField: .toggleDictation,
        currentFocus: $currentFocus
      )
      .padding()
      .frame(width: 600)
    }
  }
#endif
