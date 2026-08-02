import SwiftUI

/// Configuration for the explicit **Custom endpoint** chat model (OpenRouter, OpenInference, LiteLLM, …).
/// Shown in Settings → Chat. Select the custom-endpoint chat model
/// picker (or `/custom` in chat) to use this URL — regular OpenAI models keep using api.openai.com.
struct CustomOpenAIChatEndpointSection: View {
  @ObservedObject private var oauthService = OpenRouterOAuthService.shared

  @State private var endpointURL: String = ""
  @State private var modelID: String = ""
  @State private var apiKey: String = ""
  @State private var isKeyVisible: Bool = false

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "Custom OpenAI-compatible Endpoint",
        systemImage: "arrow.triangle.branch",
        subtitle: "Configure your proxy here, then pick it as the chat model (or type `/custom` in chat). Regular OpenAI models (GPT-5, …) are unchanged."
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
              apiKey = KeychainManager.shared.get(.customOpenAIChatAPIKey) ?? ""
            }
            .onChange(of: apiKey) { _, newValue in
              _ = KeychainManager.shared.save(newValue, for: .customOpenAIChatAPIKey)
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

          // Always state which credential is in play, not just the empty case. This field is one
          // slot shared by every custom endpoint, so a key left over from a *different* proxy is
          // invisible here — and used to be silently preferred, which surfaced as
          // "API key is invalid for the custom endpoint" right after a successful sign-in.
          if let source = OpenAIChatPreferences.resolvedCredential?.source {
            HStack(spacing: 6) {
              Image(systemName: source == .openRouterAccount ? "checkmark.circle.fill" : "info.circle")
                .foregroundColor(source == .openRouterAccount ? .green : .secondary)
              Text("Using \(source.description).")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
          } else {
            Text("No usable key yet. Enter an endpoint-specific key here, or — for an OpenRouter base URL — connect your account in Settings → General.")
              .font(.caption)
              .foregroundColor(.orange)
              .fixedSize(horizontal: false, vertical: true)
          }

          if OpenAIChatPreferences.isOpenRouterEndpoint
            && !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && oauthService.isConnected {
            Text("This endpoint-specific key is ignored while your OpenRouter account is connected. Clear it if you meant to use it.")
              .font(.caption)
              .foregroundColor(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }

        Spacer()
      }

      HStack(spacing: 12) {
        Button("Use OpenRouter preset") {
          OpenAIChatPreferences.applyOpenRouterPreset()
          endpointURL = SettingsDefaults.openRouterChatEndpointURL
          modelID = SettingsDefaults.openRouterChatModelID
          ModelSelectionReconciler.reconcileAll()
        }
        .help("Point chat at OpenRouter. If you connected your account in Settings → Dictate, no key is needed.")

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
