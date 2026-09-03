import SwiftUI

/// Configuration for the explicit **Custom endpoint** chat model — a shared proxy (OpenRouter,
/// OpenInference, LiteLLM, …) or a customer's own tenant (Azure OpenAI / Microsoft Foundry,
/// Vertex AI). Shown in Settings → Chat. Select the custom-endpoint chat model picker (or `/custom`
/// in chat) to use this URL — regular OpenAI models keep using api.openai.com.
///
/// The tenant case is why the URL and auth header are not simple string work: see
/// `CustomEndpointAuth`, which picks `api-key` over `Authorization: Bearer` for Azure and shapes
/// the path without destroying an `?api-version=` query.
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

      HStack(spacing: 12) {
        Button("Use Azure OpenAI preset") {
          OpenAIChatPreferences.applyAzureOpenAIPreset()
          endpointURL = SettingsDefaults.azureOpenAIEndpointURL
          modelID = SettingsDefaults.azureOpenAIModelID
          ModelSelectionReconciler.reconcileAll()
        }
        .help("Fill the Azure OpenAI / Foundry URL shape. Replace <resource> with your resource name and set Model to your deployment name.")

        Button("Use Vertex AI preset") {
          OpenAIChatPreferences.applyVertexAIPreset()
          endpointURL = SettingsDefaults.vertexAIEndpointURL
          modelID = SettingsDefaults.vertexAIModelID
          ModelSelectionReconciler.reconcileAll()
        }
        .help("Fill the Vertex AI OpenAI-compatible URL shape. Replace <project> with your Google Cloud project id.")

        Spacer()
      }

      bringYourOwnTenantNotes

      if !OpenAIChatPreferences.isConfigured {
        Text("Set a base URL and API key, then choose **Custom endpoint** in the chat model picker (or type `/custom` in chat).")
          .font(.caption)
          .foregroundColor(.orange)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  // MARK: - Bring-your-own-tenant notes

  /// What the two tenant presets actually do, and — just as importantly — what they do not.
  ///
  /// The claim worth being careful with is the privacy one. Pointing the app at a customer's own
  /// Azure or Google project genuinely changes *who* processes the text and under whose contract,
  /// and that is the real benefit. It does not make this app certified against anything, and it
  /// does not by itself discharge a professional confidentiality duty. Offline Mode is the option
  /// that keeps dictation on the Mac; this one is a network call the customer controls.
  @ViewBuilder
  private var bringYourOwnTenantNotes: some View {
    VStack(alignment: .leading, spacing: 6) {
      if OpenAIChatPreferences.isAzureEndpoint {
        Label(
          "Azure detected — your key is sent as the `api-key` header, which is what Azure expects. "
            + "A bare resource URL is expanded to `/openai/v1`; on that surface Model must be your "
            + "deployment name, not an OpenAI model id.",
          systemImage: "key.horizontal")
          .font(.caption)
          .foregroundColor(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      Text(
        "Azure OpenAI / Vertex AI: chat requests go to the endpoint you enter here, in the region "
          + "your own resource or project runs in, under your Microsoft or Google contract — not "
          + "through any server of ours. Vertex takes a short-lived `gcloud auth print-access-token` "
          + "value as the API key above, so it stops working after about an hour and has to be "
          + "pasted again; Azure keys do not expire."
      )
      .font(.caption)
      .foregroundColor(.secondary)
      .fixedSize(horizontal: false, vertical: true)

      Text(
        "That covers where inference runs and who your data-processing agreement is with. It is not "
          + "a certification of this app, and whether it satisfies a professional confidentiality "
          + "duty is your call to make with your own counsel. For dictation that never leaves this "
          + "Mac, use Offline Mode instead."
      )
      .font(.caption)
      .foregroundColor(.secondary)
      .fixedSize(horizontal: false, vertical: true)
    }
  }
}
