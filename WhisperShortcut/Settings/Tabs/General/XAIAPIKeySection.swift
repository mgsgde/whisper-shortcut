import SwiftUI

struct XAIAPIKeySection: View {
  @ObservedObject var viewModel: SettingsViewModel
  @State private var xaiAPIKey: String = ""
  @State private var isKeyVisible: Bool = false
  @State private var keychainSaveError: OSStatus?

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      HStack(alignment: .top) {
        SectionHeader(
          title: "xAI API Key (Grok)",
          systemImage: "key.fill",
          subtitle: "Add an xAI API key to use Grok models in the chat window. Get a key from the xAI console (link below)."
        )
        Spacer()
        APIKeyStatusBadge(provider: .xai, key: xaiAPIKey)
      }

      HStack(alignment: .center, spacing: 16) {
        Text("API Key:")
          .font(.body)
          .fontWeight(.medium)
          .frame(width: SettingsConstants.labelWidth, alignment: .leading)
          .textSelection(.enabled)

        ZStack {
          if isKeyVisible {
            TextField("xai-...", text: $xaiAPIKey)
              .textFieldStyle(.roundedBorder)
              .font(.system(.body, design: .monospaced))
              .frame(height: SettingsConstants.textFieldHeight)
          } else {
            SecureField("xai-...", text: $xaiAPIKey)
              .textFieldStyle(.roundedBorder)
              .font(.system(.body, design: .monospaced))
              .frame(height: SettingsConstants.textFieldHeight)
          }
        }
        .frame(maxWidth: SettingsConstants.apiKeyMaxWidth)
        .onAppear {
          // Don't blank the field on a failed Keychain read — see GoogleAPIKeySection.
          if let stored = KeychainManager.shared.getXAIAPIKey(), !stored.isEmpty {
            xaiAPIKey = stored
          }
        }
        .onChange(of: xaiAPIKey) { _, newValue in
          let saved = KeychainManager.shared.saveXAIAPIKey(newValue)
          keychainSaveError = saved ? nil : KeychainManager.shared.lastWriteError(for: .xai)
          ModelSelectionReconciler.reconcileAll()
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

      HStack(spacing: 0) {
        Text("Get an API key at ")
          .font(.callout)
          .foregroundColor(.secondary)
          .textSelection(.enabled)

        Link(
          destination: URL(string: "https://console.x.ai")!
        ) {
          Text("console.x.ai")
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
