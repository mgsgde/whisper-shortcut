import SwiftUI

/// The API-key row for one LLM provider: header + status badge, masked/visible key field,
/// Keychain-failure warning, and the provider's "get a key here" links.
///
/// One view for all providers — everything that differs (titles, placeholder, links, where the
/// key is stored) comes from `APIKeyProvider`. Previously this was four near-identical 89-line
/// files, so every fix to the reveal button, the Keychain-failure warning, or the
/// don't-blank-on-failed-read rule had to be made four times.
struct APIKeyEntrySection: View {
  let provider: APIKeyProvider

  /// Where the typed key lives. Google binds `viewModel.data.googleAPIKey` because
  /// `SettingsViewModel` mirrors that one; the others pass a local `@State`.
  @Binding var key: String

  /// Only Google participates in Settings' focus chain.
  var focusBinding: FocusState<SettingsFocusField?>.Binding?
  var focusField: SettingsFocusField?

  @State private var isKeyVisible: Bool = false
  @State private var keychainSaveError: OSStatus?

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      HStack(alignment: .top) {
        SectionHeader(
          title: provider.sectionTitle,
          systemImage: "key.fill",
          subtitle: provider.sectionSubtitle
        )
        Spacer()
        APIKeyStatusBadge(provider: provider, key: key)
      }

      HStack(alignment: .center, spacing: 16) {
        Text("API Key:")
          .font(.body)
          .fontWeight(.medium)
          .frame(width: SettingsConstants.labelWidth, alignment: .leading)
          .textSelection(.enabled)

        ZStack {
          if isKeyVisible {
            focused(TextField(provider.keyPlaceholder, text: $key))
          } else {
            focused(SecureField(provider.keyPlaceholder, text: $key))
          }
        }
        .frame(maxWidth: SettingsConstants.apiKeyMaxWidth)
        .onAppear {
          // Only overwrite the field when the read actually returns a stored key. A failed
          // Keychain read must not blank the binding — the onChange below would then persist
          // "" and wipe the real key (seen in the wild as "my API keys disappear").
          if let stored = KeychainManager.shared.get(provider.credential), !stored.isEmpty {
            key = stored
          }
        }
        .onChange(of: key) { _, newValue in
          // Off the main thread: `SecItemUpdate` is a synchronous IPC round-trip to securityd
          // that has been observed to stall for seconds (see the cache note in KeychainManager).
          Task {
            let saved = KeychainManager.shared.save(newValue, for: provider.credential)
            await MainActor.run {
              keychainSaveError = saved ? nil : KeychainManager.shared.lastWriteError(for: provider.credential)
            }
            ModelSelectionReconciler.reconcileAll()
          }
        }

        Button(action: { isKeyVisible.toggle() }) {
          Image(systemName: isKeyVisible ? "eye.slash" : "eye")
            .foregroundColor(.secondary)
        }
        .buttonStyle(.plain)
        .help(isKeyVisible ? "Hide API key" : "Show API key")
        .accessibilityLabel(isKeyVisible ? "Hide API key" : "Show API key")

        Spacer()
      }

      if let keychainSaveError {
        KeychainSaveWarning(status: keychainSaveError)
      }

      ForEach(provider.helpLinks) { link in
        HStack(spacing: 0) {
          Text(link.intro)
            .font(.callout)
            .foregroundColor(.secondary)
            .textSelection(.enabled)

          Link(destination: link.url) {
            Text(link.label)
              .font(.callout)
              .foregroundColor(.blue)
              .underline()
              .textSelection(.enabled)
          }
          .pointerCursorOnHover()
        }
        .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  /// Applies the shared field styling, plus focus binding for the one provider that has one.
  @ViewBuilder
  private func focused<F: View>(_ field: F) -> some View {
    let styled = field
      .textFieldStyle(.roundedBorder)
      .font(.system(.body, design: .monospaced))
      .frame(height: SettingsConstants.textFieldHeight)

    if let focusBinding, let focusField {
      styled.focused(focusBinding, equals: focusField)
    } else {
      styled
    }
  }
}
