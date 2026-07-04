import SwiftUI

/// Configuration for the explicit **Custom endpoint** chat model (OpenRouter, LiteLLM, …).
/// Shown in Settings → Chat. Select **Custom endpoint (OpenRouter / proxy)** in the chat model
/// picker (or `/custom` in chat) to use this URL — regular OpenAI models keep using api.openai.com.
struct CustomOpenAIChatEndpointSection: View {
  @State private var endpointURL: String = ""
  @State private var modelID: String = ""
  @State private var apiKey: String = ""
  @State private var isKeyVisible: Bool = false

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "Custom OpenAI-compatible Endpoint",
        systemImage: "arrow.triangle.branch",
        subtitle: "Configure your proxy here, then select **Custom endpoint (OpenRouter / proxy)** as the chat model (or type `/custom` in chat). Regular OpenAI models (GPT-5, …) are unchanged."
      )

      HStack(alignment: .center, spacing: 16) {
        Text("Base URL:")
          .font(.body)
          .fontWeight(.medium)
          .frame(width: SettingsConstants.labelWidth, alignment: .leading)

        VStack(alignment: .leading, spacing: 4) {
          TextField("https://openrouter.ai/api/v1", text: $endpointURL)
            .textFieldStyle(.roundedBorder)
            .font(.system(.body, design: .monospaced))
            .frame(height: SettingsConstants.textFieldHeight)
            .frame(maxWidth: SettingsConstants.apiKeyMaxWidth)
            .onAppear {
              endpointURL = UserDefaults.standard.string(forKey: UserDefaultsKeys.customOpenAIChatEndpointURL) ?? ""
            }
            .onChange(of: endpointURL) { _, newValue in
              UserDefaults.standard.set(newValue, forKey: UserDefaultsKeys.customOpenAIChatEndpointURL)
              ModelSelectionReconciler.reconcileAll()
            }

          Text("Up to /v1 — the app appends /chat/completions. Example: https://openrouter.ai/api/v1")
            .font(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }

        Spacer()
      }

      HStack(alignment: .center, spacing: 16) {
        Text("Model:")
          .font(.body)
          .fontWeight(.medium)
          .frame(width: SettingsConstants.labelWidth, alignment: .leading)

        VStack(alignment: .leading, spacing: 4) {
          TextField(SettingsDefaults.customOpenAIChatModelID, text: $modelID)
            .textFieldStyle(.roundedBorder)
            .font(.system(.body, design: .monospaced))
            .frame(height: SettingsConstants.textFieldHeight)
            .frame(maxWidth: SettingsConstants.apiKeyMaxWidth)
            .onAppear {
              modelID = UserDefaults.standard.string(forKey: UserDefaultsKeys.customOpenAIChatModelID) ?? ""
            }
            .onChange(of: modelID) { _, newValue in
              UserDefaults.standard.set(newValue, forKey: UserDefaultsKeys.customOpenAIChatModelID)
            }

          Text("Model id sent to your proxy (e.g. `openai/gpt-4o` or `anthropic/claude-sonnet-4` on OpenRouter). Default: \(SettingsDefaults.customOpenAIChatModelID)")
            .font(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }

        Spacer()
      }

      HStack(alignment: .center, spacing: 16) {
        Text("API Key:")
          .font(.body)
          .fontWeight(.medium)
          .frame(width: SettingsConstants.labelWidth, alignment: .leading)

        VStack(alignment: .leading, spacing: 4) {
          HStack(spacing: 8) {
            ZStack {
              if isKeyVisible {
                TextField("Optional — falls back to General OpenAI key", text: $apiKey)
                  .textFieldStyle(.roundedBorder)
                  .font(.system(.body, design: .monospaced))
                  .frame(height: SettingsConstants.textFieldHeight)
              } else {
                SecureField("Optional — falls back to General OpenAI key", text: $apiKey)
                  .textFieldStyle(.roundedBorder)
                  .font(.system(.body, design: .monospaced))
                  .frame(height: SettingsConstants.textFieldHeight)
              }
            }
            .frame(maxWidth: SettingsConstants.apiKeyMaxWidth)
            .onAppear {
              apiKey = KeychainManager.shared.getCustomOpenAIChatAPIKey() ?? ""
            }
            .onChange(of: apiKey) { _, newValue in
              _ = KeychainManager.shared.saveCustomOpenAIChatAPIKey(newValue)
              ModelSelectionReconciler.reconcileAll()
            }

            Button(action: { isKeyVisible.toggle() }) {
              Image(systemName: isKeyVisible ? "eye.slash" : "eye")
                .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help(isKeyVisible ? "Hide API key" : "Show API key")
          }

          Text("Proxy-specific key (e.g. OpenRouter). When empty, the OpenAI API key from Settings → General is used.")
            .font(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }

        Spacer()
      }

      if !OpenAIChatPreferences.isConfigured {
        Text("Set a base URL and API key, then choose **Custom endpoint** in the chat model picker.")
          .font(.caption)
          .foregroundColor(.orange)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}
