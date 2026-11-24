import SwiftUI

/// Settings row for an opt-in that sends something off the Mac. Turning it on only asks; the
/// setting changes on Allow. Turning it off takes effect at once. The two Screen Context
/// consents in Dictate Prompt were hand-cloned copies of this.
struct ConsentToggleRow: View {
  let label: LocalizedStringKey
  let accessibilityLabel: LocalizedStringKey
  /// `UserDefaults` key the setting is stored under (written on Allow, see below).
  let defaultsKey: String
  @Binding var isOn: Bool
  let alertTitle: LocalizedStringKey
  /// Already localized. The Screen Context rows pass `MCPSetting.consentText`.
  let alertMessage: String
  /// Extra work after consent, e.g. a permission request. Runs only behind Allow, never from
  /// `onChange`: `onChange` also fires when `data` is reloaded programmatically, which must
  /// never trigger a system prompt.
  var onAllow: () -> Void = {}
  let save: () -> Void

  @State private var showConsent = false

  var body: some View {
    HStack(alignment: .center, spacing: 16) {
      Text(label)
        .font(.body)
        .fontWeight(.medium)
        .frame(width: SettingsConstants.labelWidth, alignment: .leading)

      Toggle("", isOn: Binding(
        get: { isOn },
        set: { newValue in
          if newValue {
            showConsent = true
          } else {
            isOn = false
            save()
          }
        }
      ))
        .toggleStyle(SwitchToggleStyle())
        .accessibilityLabel(accessibilityLabel)

      Spacer()
    }
    .alert(alertTitle, isPresented: $showConsent) {
      Button("Cancel", role: .cancel) {}
      Button("Allow") {
        // Written to disk before anything else: when the alert closes, the Settings window
        // becomes key again and `reloadFromDisk()` runs before the save Task does, so a value
        // only held in `data` is reverted and the switch never turns on.
        UserDefaults.standard.set(true, forKey: defaultsKey)
        onAllow()
        isOn = true
        save()
      }
    } message: {
      Text(verbatim: alertMessage)
    }
  }
}
