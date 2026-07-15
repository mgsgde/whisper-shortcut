import SwiftUI

struct AnthropicAPIKeySection: View {
  @ObservedObject var viewModel: SettingsViewModel
  @State private var anthropicAPIKey: String = ""
  @State private var isKeyVisible: Bool = false

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      HStack(alignment: .top) {
        SectionHeader(
          title: "Anthropic API Key (Claude)",
          systemImage: "key.fill",
          subtitle: "Add an Anthropic API key to use Claude models in the chat window. Get a key from the Anthropic Console (link below)."
        )
        Spacer()
        APIKeyStatusBadge(provider: .anthropic, key: anthropicAPIKey)
      }

      HStack(alignment: .center, spacing: 16) {
        Text("API Key:")
          .font(.body)
          .fontWeight(.medium)
          .frame(width: SettingsConstants.labelWidth, alignment: .leading)
          .textSelection(.enabled)

        ZStack {
          if isKeyVisible {
            TextField("sk-ant-...", text: $anthropicAPIKey)
              .textFieldStyle(.roundedBorder)
              .font(.system(.body, design: .monospaced))
              .frame(height: SettingsConstants.textFieldHeight)
          } else {
            SecureField("sk-ant-...", text: $anthropicAPIKey)
              .textFieldStyle(.roundedBorder)
              .font(.system(.body, design: .monospaced))
              .frame(height: SettingsConstants.textFieldHeight)
          }
        }
        .frame(maxWidth: SettingsConstants.apiKeyMaxWidth)
        .onAppear {
          anthropicAPIKey = KeychainManager.shared.getAnthropicAPIKey() ?? ""
        }
        .onChange(of: anthropicAPIKey) { _, newValue in
          _ = KeychainManager.shared.saveAnthropicAPIKey(newValue)
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

      HStack(spacing: 0) {
        Text("Get an API key at ")
          .font(.callout)
          .foregroundColor(.secondary)
          .textSelection(.enabled)

        Link(
          destination: URL(string: "https://console.anthropic.com/settings/keys")!
        ) {
          Text("console.anthropic.com")
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
