import SwiftUI

/// Configuration for the **Custom endpoint** chat model: an OpenAI-compatible server the user runs
/// or rents — OpenInference, LiteLLM, a self-hosted gateway, or a customer's own tenant (Azure
/// OpenAI / Microsoft Foundry, Vertex AI). Shown in Settings → Chat while Custom endpoint is the
/// selected chat model (or after `/custom` in chat). Regular OpenAI models keep using api.openai.com.
///
/// OpenRouter is deliberately not configured here any more. It is its own chat provider with its
/// account in Settings → Accounts; offering it here as well meant two places to enter the same
/// credential, and a key field whose owner depended on whichever URL happened to be typed above it.
/// The key on this form belongs to this server and nothing else.
///
/// The tenant case is why the URL and auth header are not simple string work: see
/// `CustomEndpointAuth`, which picks `api-key` over `Authorization: Bearer` for Azure and shapes
/// the path without destroying an `?api-version=` query.
struct CustomOpenAIChatEndpointSection: View {
  @State private var endpointURL: String = ""
  @State private var modelID: String = ""
  @State private var apiKey: String = ""
  @State private var isKeyVisible: Bool = false

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "Custom endpoint",
        systemImage: "network",
        subtitle: "Your own OpenAI-compatible server: OpenInference, Azure OpenAI, Vertex AI, LiteLLM or self-hosted. The key entered here is sent only to this server."
      )

      presetRow

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

          Text("Up to /v1 — the app appends /chat/completions.")
            .font(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)

          if pointsAtOpenRouter {
            Label(
              "For OpenRouter, pick OpenRouter in the chat model picker instead. It uses the account from Settings → Accounts, with no URL or key to enter here.",
              systemImage: "arrow.triangle.branch")
              .font(.caption)
              .foregroundColor(.orange)
              .fixedSize(horizontal: false, vertical: true)
          }
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
            // An AI app may have changed this through MCP while the window was open.
            .onReceive(NotificationCenter.default.publisher(for: .settingsChangedExternally)) { _ in
              modelID = UserDefaults.standard.string(forKey: UserDefaultsKeys.customOpenAIChatModelID) ?? ""
            }
            .onChange(of: modelID) { _, newValue in
              UserDefaults.standard.set(newValue, forKey: UserDefaultsKeys.customOpenAIChatModelID)
            }

          Text("The model id your server expects. On Azure, your deployment name.")
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
                TextField("This server's API key", text: $apiKey)
                  .textFieldStyle(.roundedBorder)
                  .font(.system(.body, design: .monospaced))
                  .frame(height: SettingsConstants.textFieldHeight)
              } else {
                SecureField("This server's API key", text: $apiKey)
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

          credentialStatus
        }

        Spacer()
      }

      bringYourOwnTenantNotes
    }
  }

  // MARK: - Presets

  /// Presets fill the URL shape (and a plausible model) — the part that is easy to get wrong. They
  /// sit above the fields because that is what they write into.
  private var presetRow: some View {
    HStack(spacing: 12) {
      Text("Fill in:")
        .font(.body)
        .fontWeight(.medium)
        .frame(width: SettingsConstants.labelWidth, alignment: .leading)

      Button("OpenInference") {
        OpenAIChatPreferences.applyOpenInferencePreset()
        reloadFromPreferences()
      }
      .help("URL and model for openinference.de (GLM 5.2). Enter your sk-oi-… key below.")

      Button("Azure OpenAI") {
        OpenAIChatPreferences.applyAzureOpenAIPreset()
        reloadFromPreferences()
      }
      .help("The Azure OpenAI / Foundry URL shape. Replace <resource> with your resource name and set Model to your deployment name.")

      Button("Vertex AI") {
        OpenAIChatPreferences.applyVertexAIPreset()
        reloadFromPreferences()
      }
      .help("The Vertex AI OpenAI-compatible URL shape. Replace <project> with your Google Cloud project id.")

      Spacer()
    }
  }

  private func reloadFromPreferences() {
    endpointURL = UserDefaults.standard.string(forKey: UserDefaultsKeys.customOpenAIChatEndpointURL) ?? ""
    modelID = UserDefaults.standard.string(forKey: UserDefaultsKeys.customOpenAIChatModelID) ?? ""
    ModelSelectionReconciler.reconcileAll()
  }

  // MARK: - Credential status

  /// States which credential is in play, not only the empty case: with the field blank a proxy
  /// endpoint falls back to the OpenAI key from General, and that should be visible rather than
  /// discovered through a 401.
  @ViewBuilder
  private var credentialStatus: some View {
    if endpointURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      Text("Enter a base URL above first.")
        .font(.caption)
        .foregroundColor(.secondary)
    } else {
      switch OpenAIChatPreferences.resolvedCredential?.source {
      case .proxyKey:
        Label("Sent only to the server above.", systemImage: "checkmark.circle.fill")
          .labelStyle(CaptionStatusLabelStyle(tint: .green))
      case .openAIKey:
        Label(
          "No key entered, so your OpenAI key from Settings → Accounts is used. That only works if this server forwards to OpenAI.",
          systemImage: "info.circle")
          .labelStyle(CaptionStatusLabelStyle(tint: .secondary))
      case nil:
        Label("Enter this server's API key to use it.", systemImage: "exclamationmark.circle.fill")
          .labelStyle(CaptionStatusLabelStyle(tint: .orange))
      }
    }
  }

  private var pointsAtOpenRouter: Bool {
    guard let host = URLComponents(string: endpointURL.trimmingCharacters(in: .whitespacesAndNewlines))?
      .host?.lowercased()
    else { return false }
    return host == "openrouter.ai" || host.hasSuffix(".openrouter.ai")
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

/// Tinted icon, caption-coloured text — a status line under a field.
private struct CaptionStatusLabelStyle: LabelStyle {
  let tint: Color

  func makeBody(configuration: Configuration) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      configuration.icon.foregroundColor(tint)
      configuration.title
        .foregroundColor(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .font(.caption)
  }
}
