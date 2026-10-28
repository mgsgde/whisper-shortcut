import SwiftUI

/// The one **Own server** form: an OpenAI-compatible server the user runs or rents — LiteLLM,
/// OpenInference, a self-hosted gateway, or a customer's own tenant (Azure OpenAI / Microsoft
/// Foundry, Vertex AI). Dictate, Dictate Prompt and Chat all read the same base URL, key and
/// headers (`CustomEndpointPreferences`); only the model id differs per route.
///
/// It used to be two forms with two URL shapes ("full URL to /v1/audio/transcriptions" in Dictate,
/// "base URL up to /v1" in Chat) and two names for the same key ("Bearer Token" / "API Key"). A
/// LiteLLM user had to discover both behind tiles named "Self-hosted" and "Custom endpoint", and
/// Dictate Prompt could not use either. Now each tab shows this view with its `Route`: unset, it is
/// the full form; once set, it collapses to a status line plus the model field that tab needs, so
/// the second tab says "already set up" instead of asking again.
///
/// The URL and auth shaping lives in `CustomEndpointAuth` (Azure `api-key`, `?api-version=`).
struct OwnServerEndpointSection: View {
  /// Which tab is showing the form — decides which model fields appear.
  enum Route {
    case dictate, dictatePrompt, chat

    var showsTranscriptionModel: Bool { self != .chat }
    var showsChatModel: Bool { self != .dictate }
  }

  let route: Route

  @State private var endpointURL: String = ""
  @State private var chatModelID: String = ""
  @State private var transcriptionModelID: String = ""
  @State private var apiKey: String = ""
  @State private var isKeyVisible = false
  @State private var transcriptionOverride: String = ""
  @State private var headers: [HeaderEntry] = []
  /// Decided when the view appears and by Edit / Done, never while typing: a URL that starts to
  /// parse half-way through would otherwise fold the form away under the cursor.
  @State private var showsSummary = false
  @State private var showsAdvanced = false
  @State private var showsTenantNotes = false

  private struct HeaderEntry: Identifiable {
    var id = UUID()
    var key: String
    var value: String
    var isValueVisible = false
  }

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "Own server",
        systemImage: "server.rack",
        subtitle: "One OpenAI-compatible server for Dictate, Dictate Prompt and Chat: LiteLLM, Azure OpenAI, Vertex AI, OpenInference or self-hosted. You set it up once; all three use the same URL and key."
      )

      if showsSummary {
        summary
      } else {
        form
      }
    }
    .onAppear {
      reloadFromPreferences()
      showsSummary = isReadyForRoute
    }
    // Reconciling on every keystroke moved Dictate Prompt off this server before its URL was
    // complete, and the form vanished under the cursor. Settle the selections once editing ends.
    .onDisappear { ModelSelectionReconciler.reconcileAll() }
    // An AI app may have changed a model id through MCP while the window was open.
    .onReceive(NotificationCenter.default.publisher(for: .settingsChangedExternally)) { _ in
      reloadFromPreferences()
    }
  }

  // MARK: - Summary (already set up)

  private var summary: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Image(systemName: "checkmark.circle.fill")
          .foregroundColor(.green)
        VStack(alignment: .leading, spacing: 2) {
          Text("Set up: \(hostLabel)")
            .font(.body)
            .fontWeight(.medium)
          Text("Shared with Dictate, Dictate Prompt and Chat. Changing the server changes it for all three.")
            .font(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer()
        Button("Edit server…") { showsSummary = false }
      }

      modelFields
    }
  }

  // MARK: - Full form

  private var form: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      presetRow

      fieldRow("Base URL:") {
        TextField("http://localhost:4000/v1", text: $endpointURL)
          .textFieldStyle(.roundedBorder)
          .font(.system(.body, design: .monospaced))
          .frame(height: SettingsConstants.textFieldHeight)
          .frame(maxWidth: SettingsConstants.apiKeyMaxWidth)
          .onChange(of: endpointURL) { _, newValue in
            UserDefaults.standard.set(newValue, forKey: UserDefaultsKeys.customOpenAIChatEndpointURL)
          }
      } caption: {
        Text("Up to /v1, e.g. http://localhost:4000/v1 for LiteLLM. The app adds /audio/transcriptions for Dictate and /chat/completions for Chat.")
          .font(.caption)
          .foregroundColor(.secondary)
          .fixedSize(horizontal: false, vertical: true)

        if pointsAtOpenRouter {
          Label(
            "For OpenRouter, pick OpenRouter in the model picker instead. It uses the account from Settings → Accounts, with no URL or key to enter here.",
            systemImage: "arrow.triangle.branch")
            .font(.caption)
            .foregroundColor(.orange)
            .fixedSize(horizontal: false, vertical: true)
        }
      }

      fieldRow("API key:") {
        HStack(spacing: 8) {
          ZStack {
            if isKeyVisible {
              TextField(keyPlaceholder, text: $apiKey)
                .textFieldStyle(.roundedBorder)
            } else {
              SecureField(keyPlaceholder, text: $apiKey)
                .textFieldStyle(.roundedBorder)
            }
          }
          .font(.system(.body, design: .monospaced))
          .frame(height: SettingsConstants.textFieldHeight)
          .frame(maxWidth: SettingsConstants.apiKeyMaxWidth)
          .onChange(of: apiKey) { _, newValue in
            _ = KeychainManager.shared.save(newValue, for: .customOpenAIChatAPIKey)
          }

          Button(action: { isKeyVisible.toggle() }) {
            Image(systemName: isKeyVisible ? "eye.slash" : "eye")
              .foregroundColor(.secondary)
          }
          .buttonStyle(.plain)
          .help(isKeyVisible ? ("Hide API key" as LocalizedStringKey) : "Show API key")
          .accessibilityLabel(isKeyVisible ? ("Hide API key" as LocalizedStringKey) : "Show API key")
        }
      } caption: {
        credentialStatus
      }

      modelFields

      advanced

      if isReadyForRoute {
        HStack {
          Spacer().frame(width: SettingsConstants.labelWidth + 16)
          Button("Done") {
            showsSummary = true
            ModelSelectionReconciler.reconcileAll()
          }
        }
      }
    }
  }

  // MARK: - Model fields

  @ViewBuilder
  private var modelFields: some View {
    if route.showsTranscriptionModel {
      fieldRow("Dictate model:") {
        TextField(SettingsDefaults.customTranscriptionModelID, text: $transcriptionModelID)
          .textFieldStyle(.roundedBorder)
          .font(.system(.body, design: .monospaced))
          .frame(height: SettingsConstants.textFieldHeight)
          .frame(maxWidth: SettingsConstants.apiKeyMaxWidth)
          .onChange(of: transcriptionModelID) { _, newValue in
            UserDefaults.standard.set(newValue, forKey: UserDefaultsKeys.customTranscriptionModelID)
          }
      } caption: {
        Text(route == .dictatePrompt
          ? "Transcribes your spoken instruction first, e.g. whisper-1 or the model name in your LiteLLM config."
          : "The speech-to-text model your server serves, e.g. whisper-1 or the model name in your LiteLLM config.")
          .font(.caption)
          .foregroundColor(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }

    if route.showsChatModel {
      fieldRow("Chat model:") {
        TextField(SettingsDefaults.openInferenceModelID, text: $chatModelID)
          .textFieldStyle(.roundedBorder)
          .font(.system(.body, design: .monospaced))
          .frame(height: SettingsConstants.textFieldHeight)
          .frame(maxWidth: SettingsConstants.apiKeyMaxWidth)
          .onChange(of: chatModelID) { _, newValue in
            UserDefaults.standard.set(newValue, forKey: UserDefaultsKeys.customOpenAIChatModelID)
          }
      } caption: {
        Text(route == .dictatePrompt
          ? "Then applies it to your selected text. On Azure, your deployment name."
          : "The model id your server expects. On Azure, your deployment name.")
          .font(.caption)
          .foregroundColor(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }

    if route == .dictatePrompt && AppConstants.dictatePromptUsesScreenshotSelection {
      Text("Copy the text you want edited (⌘C) before you start dictating. Your own server reads the clipboard, not the screen.")
        .font(.caption)
        .foregroundColor(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  // MARK: - Presets

  /// Presets fill the URL shape (and a plausible chat model): the part that is easy to get wrong.
  /// Small and short-named so all four fit the field column at the window's minimum width.
  private var presetRow: some View {
    fieldRow("Fill in:") {
      HStack(spacing: 6) {
        presetButton("LiteLLM", help: "http://localhost:4000/v1, LiteLLM's default port. The model fields take the model_name entries from your LiteLLM config.") {
          UserDefaults.standard.set("http://localhost:4000/v1", forKey: UserDefaultsKeys.customOpenAIChatEndpointURL)
        }
        presetButton("OpenInference", help: "URL and chat model for openinference.de (GLM 5.2). Enter your sk-oi-… key below.") {
          OpenAIChatPreferences.applyOpenInferencePreset()
        }
        presetButton("Azure", help: "The Azure OpenAI / Foundry URL shape. Replace <resource> with your resource name and set the models to your deployment names.") {
          OpenAIChatPreferences.applyAzureOpenAIPreset()
        }
        presetButton("Vertex", help: "The Vertex AI OpenAI-compatible URL shape. Replace <project> with your Google Cloud project id.") {
          OpenAIChatPreferences.applyVertexAIPreset()
        }
      }
    } caption: {
      EmptyView()
    }
  }

  private func presetButton(_ title: LocalizedStringKey, help: LocalizedStringKey, apply: @escaping () -> Void) -> some View {
    Button(title) {
      apply()
      reloadFromPreferences()
    }
    .controlSize(.small)
    .fixedSize()
    .help(help)
  }

  // MARK: - Advanced: headers, transcription URL, tenant notes

  private var advanced: some View {
    DisclosureGroup(isExpanded: $showsAdvanced) {
      VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
        fieldRow("Headers:") {
          Button(action: addHeader) {
            Label("Add header", systemImage: "plus.circle")
          }
          .buttonStyle(.borderless)
        } caption: {
          Text("Sent with every request to this server, e.g. CF-Access-Client-Id / CF-Access-Client-Secret for Cloudflare Access.")
            .font(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }

        ForEach($headers) { $header in
          headerRow($header)
        }

        fieldRow("Dictate URL:") {
          TextField(derivedTranscriptionURL ?? "https://…/v1/audio/transcriptions", text: $transcriptionOverride)
            .textFieldStyle(.roundedBorder)
            .font(.system(.body, design: .monospaced))
            .frame(height: SettingsConstants.textFieldHeight)
            .frame(maxWidth: SettingsConstants.apiKeyMaxWidth)
            .onChange(of: transcriptionOverride) { _, newValue in
              UserDefaults.standard.set(newValue, forKey: UserDefaultsKeys.customTranscriptionAPIURL)
              }
        } caption: {
          Text("Leave empty to use the base URL. Only for a speech server that lives elsewhere, e.g. whisper-asr-webservice's /asr.")
            .font(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }

        tenantNotes
      }
      .padding(.top, 8)
    } label: {
      Text("Advanced: headers, separate Dictate URL, Azure and Vertex notes")
        .font(.callout)
        .foregroundColor(.secondary)
    }
  }

  private func headerRow(_ header: Binding<HeaderEntry>) -> some View {
    HStack(alignment: .center, spacing: 8) {
      Spacer().frame(width: SettingsConstants.labelWidth + 8)

      TextField("Header name", text: header.key)
        .textFieldStyle(.roundedBorder)
        .font(.system(.body, design: .monospaced))
        .frame(height: SettingsConstants.textFieldHeight)
        .onChange(of: header.wrappedValue.key) { _, _ in saveHeaders() }

      ZStack {
        if header.wrappedValue.isValueVisible {
          TextField("Value", text: header.value).textFieldStyle(.roundedBorder)
        } else {
          SecureField("Value", text: header.value).textFieldStyle(.roundedBorder)
        }
      }
      .font(.system(.body, design: .monospaced))
      .frame(height: SettingsConstants.textFieldHeight)
      .onChange(of: header.wrappedValue.value) { _, _ in saveHeaders() }

      Button(action: { header.wrappedValue.isValueVisible.toggle() }) {
        Image(systemName: header.wrappedValue.isValueVisible ? "eye.slash" : "eye")
          .foregroundColor(.secondary)
      }
      .buttonStyle(.plain)
      .help(header.wrappedValue.isValueVisible ? ("Hide value" as LocalizedStringKey) : "Show value")
      .accessibilityLabel(header.wrappedValue.isValueVisible ? ("Hide value" as LocalizedStringKey) : "Show value")

      Button(action: { removeHeader(id: header.wrappedValue.id) }) {
        Image(systemName: "minus.circle")
          .foregroundColor(.red)
      }
      .buttonStyle(.plain)
      .help("Remove header")
      .accessibilityLabel("Remove header")
    }
    .frame(maxWidth: SettingsConstants.labelWidth + 24 + SettingsConstants.apiKeyMaxWidth)
  }

  /// What the tenant presets do, and what they do not. Pointing the app at a customer's own Azure
  /// or Google project changes who processes the text and under whose contract. It does not make
  /// this app certified against anything; Offline Mode is the option that keeps dictation on the Mac.
  @ViewBuilder
  private var tenantNotes: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(
        "Azure OpenAI / Vertex AI: requests go to the endpoint you enter here, in the region "
          + "your own resource or project runs in, under your Microsoft or Google contract, not "
          + "through any server of ours. Vertex takes a short-lived `gcloud auth print-access-token` "
          + "value as the API key, so it stops working after about an hour and has to be "
          + "pasted again; Azure keys do not expire."
      )
      Text(
        "That covers where inference runs and who your data-processing agreement is with. It is not "
          + "a certification of this app, and whether it satisfies a professional confidentiality "
          + "duty is your call to make with your own counsel. For dictation that never leaves this "
          + "Mac, use Offline Mode instead."
      )
    }
    .font(.caption)
    .foregroundColor(.secondary)
    .fixedSize(horizontal: false, vertical: true)
  }

  // MARK: - Status

  /// States which credential is in play, not only the empty case: with the field blank a proxy
  /// falls back to the OpenAI key from Accounts, and that should be visible rather than found
  /// through a 401.
  @ViewBuilder
  private var credentialStatus: some View {
    if endpointURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      Text("Enter a base URL above first.")
        .font(.caption)
        .foregroundColor(.secondary)
    } else {
      VStack(alignment: .leading, spacing: 4) {
        switch OpenAIChatPreferences.resolvedCredential?.source {
        case .proxyKey:
          Label("Sent only to the server above.", systemImage: "checkmark.circle.fill")
            .labelStyle(OwnServerStatusLabelStyle(tint: .green))
        case .openAIKey:
          Label(
            "No key entered, so your OpenAI key from Settings → Accounts is used. That only works if this server forwards to OpenAI.",
            systemImage: "info.circle")
            .labelStyle(OwnServerStatusLabelStyle(tint: .secondary))
        case nil:
          if route == .dictate {
            Label("No key: fine for a local speech server without auth.", systemImage: "info.circle")
              .labelStyle(OwnServerStatusLabelStyle(tint: .secondary))
          } else {
            Label("Chat needs this server's key.", systemImage: "exclamationmark.circle.fill")
              .labelStyle(OwnServerStatusLabelStyle(tint: .orange))
          }
        }

        if isAzure {
          Label(
            "Azure detected: the key goes in the `api-key` header. A bare resource URL becomes `/openai/v1`, and the models are your deployment names.",
            systemImage: "key.horizontal")
            .labelStyle(OwnServerStatusLabelStyle(tint: .secondary))
        }
      }
    }
  }

  // MARK: - Layout helper

  private func fieldRow<Field: View, Caption: View>(
    _ label: LocalizedStringKey,
    @ViewBuilder field: () -> Field,
    @ViewBuilder caption: () -> Caption
  ) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 16) {
      Text(label)
        .font(.body)
        .fontWeight(.medium)
        .frame(width: SettingsConstants.labelWidth, alignment: .leading)

      VStack(alignment: .leading, spacing: 4) {
        field()
        caption()
      }
      .frame(maxWidth: SettingsConstants.apiKeyMaxWidth, alignment: .leading)

      Spacer(minLength: 0)
    }
  }

  // MARK: - State

  /// Dictate runs without a key (a local Whisper server needs none); Chat and Dictate Prompt's
  /// rewrite step do not.
  private var isReadyForRoute: Bool {
    switch route {
    case .dictate: return CustomEndpointPreferences.isTranscriptionConfigured
    case .dictatePrompt, .chat: return CustomEndpointPreferences.isConfigured
    }
  }

  private var hostLabel: String {
    let source = CustomEndpointPreferences.baseURL ?? CustomEndpointPreferences.transcriptionURLOverride ?? ""
    guard let components = URLComponents(string: source), let host = components.host else { return source }
    return components.port.map { "\(host):\($0)" } ?? host
  }

  /// Dictate works against a keyless local Whisper server; Chat does not.
  private var keyPlaceholder: LocalizedStringKey {
    route == .dictate ? "Optional for a local server" : "This server's API key"
  }

  private var derivedTranscriptionURL: String? {
    CustomEndpointAuth.endpointURL(appending: "audio/transcriptions", to: endpointURL)
  }

  private var isAzure: Bool {
    CustomEndpointAuth.flavor(forBaseURL: endpointURL) == .azure
  }

  private var pointsAtOpenRouter: Bool {
    guard let host = URLComponents(string: endpointURL.trimmingCharacters(in: .whitespacesAndNewlines))?
      .host?.lowercased()
    else { return false }
    return host == "openrouter.ai" || host.hasSuffix(".openrouter.ai")
  }

  private func reloadFromPreferences() {
    let defaults = UserDefaults.standard
    endpointURL = defaults.string(forKey: UserDefaultsKeys.customOpenAIChatEndpointURL) ?? ""
    chatModelID = defaults.string(forKey: UserDefaultsKeys.customOpenAIChatModelID) ?? ""
    transcriptionModelID = defaults.string(forKey: UserDefaultsKeys.customTranscriptionModelID) ?? ""
    transcriptionOverride = defaults.string(forKey: UserDefaultsKeys.customTranscriptionAPIURL) ?? ""
    apiKey = KeychainManager.shared.get(.customOpenAIChatAPIKey) ?? ""
    headers = KeychainManager.shared.getCustomTranscriptionHeaders()
      .map { HeaderEntry(key: $0["key"] ?? "", value: $0["value"] ?? "") }
    // A legacy separate Dictate URL or headers should not hide behind a closed disclosure.
    if !transcriptionOverride.isEmpty || !headers.isEmpty { showsAdvanced = true }
  }

  private func addHeader() {
    headers.append(HeaderEntry(key: "", value: ""))
  }

  private func removeHeader(id: UUID) {
    headers.removeAll { $0.id == id }
    saveHeaders()
  }

  private func saveHeaders() {
    _ = KeychainManager.shared.saveCustomTranscriptionHeaders(headers.map { ["key": $0.key, "value": $0.value] })
  }
}

/// Tinted icon, caption-coloured text: a status line under a field.
private struct OwnServerStatusLabelStyle: LabelStyle {
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
