import SwiftUI

struct OpenAIAPIKeySection: View {
  @ObservedObject var viewModel: SettingsViewModel
  @State private var openAIAPIKey: String = ""
  @State private var isKeyVisible: Bool = false
  @State private var keychainSaveError: OSStatus?

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      HStack(alignment: .top) {
        SectionHeader(
          title: "OpenAI API Key",
          systemImage: "key.fill",
          subtitle: "Add an OpenAI API key to use OpenAI's transcription models (gpt-4o-transcribe, gpt-4o-mini-transcribe). Get a key from the OpenAI platform (link below)."
        )
        Spacer()
        APIKeyStatusBadge(provider: .openai, key: openAIAPIKey)
      }

      HStack(alignment: .center, spacing: 16) {
        Text("API Key:")
          .font(.body)
          .fontWeight(.medium)
          .frame(width: SettingsConstants.labelWidth, alignment: .leading)
          .textSelection(.enabled)

        ZStack {
          if isKeyVisible {
            TextField("sk-...", text: $openAIAPIKey)
              .textFieldStyle(.roundedBorder)
              .font(.system(.body, design: .monospaced))
              .frame(height: SettingsConstants.textFieldHeight)
          } else {
            SecureField("sk-...", text: $openAIAPIKey)
              .textFieldStyle(.roundedBorder)
              .font(.system(.body, design: .monospaced))
              .frame(height: SettingsConstants.textFieldHeight)
          }
        }
        .frame(maxWidth: SettingsConstants.apiKeyMaxWidth)
        .onAppear {
          // Don't blank the field on a failed Keychain read — see GoogleAPIKeySection.
          if let stored = KeychainManager.shared.getOpenAIAPIKey(), !stored.isEmpty {
            openAIAPIKey = stored
          }
        }
        .onChange(of: openAIAPIKey) { _, newValue in
          let saved = KeychainManager.shared.saveOpenAIAPIKey(newValue)
          keychainSaveError = saved ? nil : KeychainManager.shared.lastWriteError(for: .openai)
          ModelSelectionReconciler.reconcileAll()
        }

        Button(action: { isKeyVisible.toggle() }) {
          Image(systemName: isKeyVisible ? "eye.slash" : "eye")
            .foregroundColor(.secondary)
        }
        .buttonStyle(.plain)
        .help(isKeyVisible ? "Hide API key" : "Show API key")

        Spacer()
      }

      if let keychainSaveError {
        KeychainSaveWarning(status: keychainSaveError)
      }

      HStack(spacing: 0) {
        Text("Get an API key at ")
          .font(.callout)
          .foregroundColor(.secondary)
          .textSelection(.enabled)

        Link(
          destination: URL(string: "https://platform.openai.com/api-keys")!
        ) {
          Text("platform.openai.com/api-keys")
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
