import SwiftUI

/// The API-key row for one LLM provider: header + status badge, masked/visible key field,
/// Keychain-failure warning, and the provider's "get a key here" links.
///
/// One view for all providers — everything that differs (titles, placeholder, links, where the
/// key is stored) comes from `APIKeyProvider`. Previously this was four near-identical 89-line
/// files, so every fix to the reveal button, the Keychain-failure warning, or the
/// don't-blank-on-failed-read rule had to be made four times.
struct APIKeyEntrySection: View {
  /// Long enough that a paste or typed key is one Keychain write, short enough
  /// that leaving the field still persists before the user dictates.
  static let saveDelay: Duration = .milliseconds(500)

  let provider: APIKeyProvider

  /// Where the typed key lives. Google binds `viewModel.data.googleAPIKey` because
  /// `SettingsViewModel` mirrors that one; the others pass a local `@State`.
  @Binding var key: String

  /// Only Google participates in Settings' focus chain.
  var focusBinding: FocusState<SettingsFocusField?>.Binding?
  var focusField: SettingsFocusField?

  @State private var isKeyVisible: Bool = false
  @State private var keychainSaveError: OSStatus?
  @State private var saveCommit: DebouncedAsyncCommit<String>?

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
          ensureSaveCommit()
        }
        .onDisappear { flushSave() }
        .onChange(of: key) { _, newValue in
          // `onAppear` loading the stored key also fires this. Treat that as a load, not a save:
          // otherwise merely opening Settings → Accounts rewrites every key and pops the
          // "use the cloud models instead?" offer, which promises to ask only when a key is saved.
          guard newValue != (KeychainManager.shared.get(provider.credential) ?? "") else { return }
          ensureSaveCommit()
          saveCommit?.schedule(newValue)
        }

        Button(action: { isKeyVisible.toggle() }) {
          Image(systemName: isKeyVisible ? "eye.slash" : "eye")
            .foregroundColor(.secondary)
        }
        .buttonStyle(.plain)
        .help(isKeyVisible ? ("Hide API key" as LocalizedStringKey) : "Show API key")
        .accessibilityLabel(isKeyVisible ? ("Hide API key" as LocalizedStringKey) : "Show API key")

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

  private func ensureSaveCommit() {
    guard saveCommit == nil else { return }
    saveCommit = DebouncedAsyncCommit(delay: Self.saveDelay) { value in
      keychainSaveError = await provider.store(value)
    }
  }

  private func flushSave() {
    let value = key
    guard value != (KeychainManager.shared.get(provider.credential) ?? "") else {
      saveCommit?.cancel()
      return
    }
    ensureSaveCommit()
    Task { await saveCommit?.flush(value) }
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
