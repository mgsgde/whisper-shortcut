import SwiftUI

struct XAIAPIKeySection: View {
  @ObservedObject var viewModel: SettingsViewModel
  @State private var xaiAPIKey: String = ""

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "🔑 xAI API Key (Grok)",
        subtitle: "Add an xAI API key to use Grok models in the chat window. Get a key from the xAI console (link below)."
      )

      HStack(alignment: .center, spacing: 16) {
        Text("API Key:")
          .font(.body)
          .fontWeight(.medium)
          .frame(width: SettingsConstants.labelWidth, alignment: .leading)
          .textSelection(.enabled)

        TextField("xai-...", text: $xaiAPIKey)
          .textFieldStyle(.roundedBorder)
          .font(.system(.body, design: .monospaced))
          .frame(height: SettingsConstants.textFieldHeight)
          .frame(maxWidth: SettingsConstants.apiKeyMaxWidth)
          .onAppear {
            xaiAPIKey = KeychainManager.shared.getXAIAPIKey() ?? ""
          }
          .onChange(of: xaiAPIKey) { _, newValue in
            _ = KeychainManager.shared.saveXAIAPIKey(newValue)
          }

        Spacer()
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
