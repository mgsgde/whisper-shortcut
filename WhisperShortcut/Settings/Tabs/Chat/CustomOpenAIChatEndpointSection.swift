import SwiftUI

/// Configuration for the explicit **Custom endpoint** chat model (OpenRouter, OpenInference, LiteLLM, …).
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
          TextField(SettingsDefaults.openInferenceEndpointURL, text: $endpointURL)
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

          Text("Up to /v1 — the app appends /chat/completions. Example: \(SettingsDefaults.openInferenceEndpointURL)")
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
          TextField(SettingsDefaults.openInferenceModelID, text: $modelID)
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

          Text("Model id sent to your server. OpenInference: `\(SettingsDefaults.openInferenceModelID)`. OpenRouter: e.g. `openai/gpt-4o`.")
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
                TextField("sk-oi-… (OpenInference) or proxy key", text: $apiKey)
                  .textFieldStyle(.roundedBorder)
                  .font(.system(.body, design: .monospaced))
                  .frame(height: SettingsConstants.textFieldHeight)
              } else {
                SecureField("sk-oi-… (OpenInference) or proxy key", text: $apiKey)
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
            .accessibilityLabel(isKeyVisible ? "Hide API key" : "Show API key")
          }

          Text("Proxy-specific key (e.g. OpenInference `sk-oi-…`). When empty, the OpenAI API key from Settings → General is used.")
            .font(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }

        Spacer()
      }

      HStack(spacing: 12) {
        Button("Use OpenInference preset") {
          OpenAIChatPreferences.applyOpenInferencePreset()
          endpointURL = SettingsDefaults.openInferenceEndpointURL
          modelID = SettingsDefaults.openInferenceModelID
          ModelSelectionReconciler.reconcileAll()
        }
        .help("Fill URL and model for openinference.de (GLM 5.2). You still need your sk-oi-… API key above.")

        Spacer()
      }

      if !OpenAIChatPreferences.isConfigured {
        Text("Set a base URL and API key, then choose **Custom endpoint** in the chat model picker (or type `/custom` in chat).")
          .font(.caption)
          .foregroundColor(.orange)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}
