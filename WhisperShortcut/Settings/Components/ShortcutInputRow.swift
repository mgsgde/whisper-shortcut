import SwiftUI

/// Wiederverwendbare Komponente für Shortcut-Eingabefelder
struct ShortcutInputRow: View {
  let label: String
  let placeholder: String
  @Binding var text: String
  @Binding var isEnabled: Bool
  let focusedField: SettingsFocusField
  @FocusState.Binding var currentFocus: SettingsFocusField?
  
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
    @State var text = "command+shift+e"
    @State var isEnabled = true
    @FocusState var currentFocus: SettingsFocusField?
    
    ShortcutInputRow(
      label: "Start Dictation:",
      placeholder: "e.g., command+shift+e",
      text: $text,
      isEnabled: $isEnabled,
      focusedField: .startShortcut,
      currentFocus: $currentFocus
    )
    .padding()
    .frame(width: 600)
  }
}
#endif
