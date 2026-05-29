import SwiftUI

struct OpenAIAPIKeySection: View {
  @ObservedObject var viewModel: SettingsViewModel
  @State private var openAIAPIKey: String = ""
  @State private var isKeyVisible: Bool = false

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "🔑 OpenAI API Key",
        subtitle: "Add an OpenAI API key to use OpenAI's transcription models (gpt-4o-transcribe, gpt-4o-mini-transcribe). Get a key from the OpenAI platform (link below)."
      )

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
          openAIAPIKey = KeychainManager.shared.getOpenAIAPIKey() ?? ""
        }
        .onChange(of: openAIAPIKey) { _, newValue in
          _ = KeychainManager.shared.saveOpenAIAPIKey(newValue)
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
