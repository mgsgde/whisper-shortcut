import SwiftUI

/// Reusable component for shortcut input fields in Settings.
struct ShortcutInputRow: View {
  let label: String
  let placeholder: String
  @Binding var text: String
  @Binding var isEnabled: Bool
  let focusedField: SettingsFocusField
  @FocusState.Binding var currentFocus: SettingsFocusField?
  let onShortcutChanged: (() -> Void)?
  let validateShortcut: ((String, SettingsFocusField) -> String?)?

  @State private var validationError: String?

  init(
    label: String,
    placeholder: String,
    text: Binding<String>,
    isEnabled: Binding<Bool>,
    focusedField: SettingsFocusField,
    currentFocus: FocusState<SettingsFocusField?>.Binding,
    onShortcutChanged: (() -> Void)? = nil,
    validateShortcut: ((String, SettingsFocusField) -> String?)? = nil
  ) {
    self.label = label
    self.placeholder = placeholder
    self._text = text
    self._isEnabled = isEnabled
    self.focusedField = focusedField
    self._currentFocus = currentFocus
    self.onShortcutChanged = onShortcutChanged
    self.validateShortcut = validateShortcut
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
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
          .overlay(
            RoundedRectangle(cornerRadius: 6)
              .stroke(validationError != nil ? Color.red.opacity(0.7) : Color.clear, lineWidth: 1)
              .padding(0)
          )
          .onChange(of: text) { _, newValue in
            // Validate in real-time
            if isEnabled {
              validationError = validateShortcut?(newValue, focusedField)
            } else {
              validationError = nil
            }

            // Only save if validation passes
            if validationError == nil {
              onShortcutChanged?()
            }
          }
          .onChange(of: isEnabled) { _, _ in
            validationError = nil
            onShortcutChanged?()
          }

        Toggle("", isOn: $isEnabled)
          .toggleStyle(.checkbox)
          .help("Enable/disable this shortcut")

        Spacer()
      }

      // Show validation error
      if let error = validationError {
        HStack {
          Spacer()
            .frame(width: SettingsConstants.labelWidth)

          HStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill")
              .font(.caption2)
              .foregroundColor(.red.opacity(0.8))

            Text(error)
              .font(.caption)
              .foregroundColor(.secondary)
          }
          .frame(maxWidth: SettingsConstants.shortcutMaxWidth, alignment: .leading)

          Spacer()
        }
        .padding(.top, 2)
      }
    }
  }
}

