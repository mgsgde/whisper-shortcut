import AppKit
import SwiftUI

struct WelcomeIntroStep: View {
  var body: some View {
    VStack(spacing: 28) {
      Image(systemName: "waveform.and.mic")
        .font(.system(size: 64))
        .foregroundStyle(.tint)
      VStack(spacing: 10) {
        Text("Welcome to WhisperShortcut")
          .font(.largeTitle)
          .fontWeight(.semibold)
        Text("Turn your voice into text in any app.")
          .font(.title3)
          .foregroundStyle(.secondary)
      }
      Text("Three quick steps: choose offline or cloud dictation, allow the microphone, and try it once. About a minute.")
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 540)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

/// Prominent, tappable "this app is open source" banner with a direct link to
/// the public repository. Surfaced on the privacy step (and in Settings) so the
/// open-source nature is obvious at a glance rather than hidden in a small button.
/// Uses the official GitHub mark (`GitHubMark` asset, rendered as a tintable
/// template image) — the same symbol the app uses for GitHub elsewhere.
struct OpenSourceBanner: View {
  private var repoURL: URL? { URL(string: AppConstants.githubRepositoryURL) }

  /// The recognizable "owner/repo" handle, without the scheme/host.
  private var repoHandle: String {
    AppConstants.githubRepositoryURL
      .replacingOccurrences(of: "https://github.com/", with: "")
      .replacingOccurrences(of: "http://github.com/", with: "")
  }

  var body: some View {
    Button {
      if let repoURL { NSWorkspace.shared.open(repoURL) }
    } label: {
      HStack(spacing: 14) {
        Image("GitHubMark")
          .renderingMode(.template)
          .resizable()
          .aspectRatio(contentMode: .fit)
          .frame(width: 24, height: 24)
          .foregroundStyle(.tint)
          .frame(width: 30)
        VStack(alignment: .leading, spacing: 3) {
          Text(PrivacyCopy.openSourceHeadline)
            .font(.callout)
            .fontWeight(.semibold)
            .foregroundStyle(.primary)
          Text(PrivacyCopy.openSourceDetail)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          HStack(spacing: 4) {
            Image(systemName: "link")
              .font(.caption2)
            Text(repoHandle)
              .font(.caption.monospaced())
          }
          .foregroundStyle(.tint)
          .padding(.top, 1)
        }
        Spacer(minLength: 8)
        Image(systemName: "arrow.up.right")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      .padding(14)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: 10)
          .fill(Color.accentColor.opacity(0.10))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 10)
          .stroke(Color.accentColor.opacity(0.35), lineWidth: 1)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .pointerCursorOnHover()
    .help("Open the WhisperShortcut source code on GitHub")
  }
}

/// The one decision of the tour. Offline and Cloud are the two honest answers to "where does my
/// audio go?", so the privacy promise is answered by the choice itself instead of a page of its own.
enum DictationChoice {
  case offline
  case cloud

  /// What a revisited tour should show as already chosen. Nil on a fresh install: nothing is
  /// pre-selected, because either answer is a real trade-off the user should make.
  static func inferred() -> DictationChoice? {
    if UserDefaults.standard.bool(forKey: UserDefaultsKeys.offlineModeEnabled) { return .offline }
    if ProviderCredentials.anyChatCredentialConfigured { return .cloud }
    if OfflineModelType.byAccuracy.contains(where: { ModelManager.shared.isModelAvailable($0) }) {
      return .offline
    }
    return nil
  }
}

struct WelcomeDictationSetupStep: View {
  @Binding var choice: DictationChoice?
  @Binding var hasGeminiKey: Bool
  @Binding var hasOpenAIKey: Bool
  @Binding var hasXAIKey: Bool
  @Binding var hasAnthropicKey: Bool
  @Binding var hasOpenRouterKey: Bool
  @Binding var offlineReady: Bool
  @AppStorage(UserDefaultsKeys.offlineModeEnabled) private var offlineMode = false
  @State private var showOtherProviders = false
  @State private var showPrivacyDetails = false

  private var hasCloudKey: Bool {
    hasGeminiKey || hasOpenAIKey || hasXAIKey || hasAnthropicKey || hasOpenRouterKey
  }

  private var canContinue: Bool { hasCloudKey || offlineReady }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack(spacing: 12) {
        Image(systemName: "waveform.badge.mic")
          .font(.system(size: 32))
          .foregroundStyle(.tint)
        VStack(alignment: .leading, spacing: 4) {
          Text("How should dictation run?")
            .font(.title2)
            .fontWeight(.semibold)
          Text("Pick one to start. You can add the other any time in Settings.")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
      }

      HStack(alignment: .top, spacing: 12) {
        choiceCard(
          .offline,
          icon: "lock.laptopcomputer",
          title: "Offline",
          tagline: "Private and free",
          facts: [
            "Audio never leaves this Mac",
            "Works without internet, no account",
            "One-time download, \(OfflineModelType.mostAccurate.estimatedSizeLabel)",
          ])
        choiceCard(
          .cloud,
          icon: "cloud",
          title: "Cloud",
          tagline: "Most accurate",
          facts: [
            "Best accuracy, in more languages",
            "Also powers Chat and Read Aloud",
            "Needs one account; you pay the provider",
          ])
      }

      if let choice {
        ScrollView(showsIndicators: true) {
          VStack(alignment: .leading, spacing: 12) {
            switch choice {
            case .offline: offlineDetails
            case .cloud: cloudDetails
            }
          }
          .padding(.bottom, 8)
          .padding(.trailing, 4)
        }
      } else {
        Spacer(minLength: 0)
      }

      privacyLine
      statusLine
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    // Cloud picked first, key pasted afterwards: the pick found no credential yet and left the
    // offline model selected, so run the switch again once a key exists.
    .onChange(of: hasCloudKey) { _, configured in
      if configured && choice == .cloud { preferCloudTranscription() }
    }
  }

  // MARK: - Choice cards

  private func choiceCard(
    _ value: DictationChoice, icon: String, title: String, tagline: String, facts: [String]
  ) -> some View {
    let selected = choice == value
    return Button {
      select(value)
    } label: {
      VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 10) {
          Image(systemName: icon)
            .font(.system(size: 22))
            .foregroundStyle(.tint)
            .frame(width: 28)
          VStack(alignment: .leading, spacing: 1) {
            Text(title)
              .font(.headline)
              .foregroundStyle(.primary)
            Text(tagline)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Spacer(minLength: 4)
          Image(systemName: selected ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 18))
            .foregroundStyle(selected ? Color.accentColor : Color.secondary.opacity(0.5))
        }
        VStack(alignment: .leading, spacing: 4) {
          ForEach(facts, id: \.self) { fact in
            HStack(alignment: .firstTextBaseline, spacing: 6) {
              Text("•").foregroundStyle(.secondary)
              Text(fact)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption)
          }
        }
      }
      .padding(14)
      .frame(maxWidth: .infinity, alignment: .topLeading)
      .background(
        RoundedRectangle(cornerRadius: 10)
          .fill(selected ? Color.accentColor.opacity(0.10) : Color(nsColor: .controlBackgroundColor))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 10)
          .stroke(
            selected ? Color.accentColor : Color(nsColor: .separatorColor),
            lineWidth: selected ? 2 : 1)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .pointerCursorOnHover()
    .accessibilityAddTraits(selected ? .isSelected : [])
  }

  private func select(_ value: DictationChoice) {
    choice = value
    // Offline Mode hides every cloud provider. Someone who just picked Cloud means it, so the
    // switch goes off here rather than leaving them with key fields that do nothing.
    if value == .cloud && offlineMode {
      offlineMode = false
      ModelSelectionReconciler.reconcileAll()
      DebugLogger.log("OFFLINE-MODE: disabled during onboarding (user chose Cloud)")
    }
    if value == .cloud { preferCloudTranscription() }
  }

  /// Picking Cloud after Offline (or on a Mac that was dictating offline) should mean cloud
  /// dictation once a usable credential exists: the app default first, else any cloud model the
  /// configured credentials can run. Without one, the offline model stays — it still works.
  private func preferCloudTranscription() {
    guard TranscriptionModel.loadSelected().provider == .offline else { return }
    let cloud = TranscriptionModel.allCases.filter {
      $0.provider != .offline && $0 != .selfHostedTranscription && $0.isSelectableForDictation
    }
    let preferred = [SettingsDefaults.selectedTranscriptionModel] + cloud
    guard let model = preferred.first(where: { $0.hasRequiredCredential }) else { return }
    UserDefaults.standard.set(model.rawValue, forKey: UserDefaultsKeys.selectedTranscriptionModel)
    DebugLogger.log("ONBOARDING: chose Cloud; transcription model set to \(model.rawValue)")
  }

  // MARK: - Details per choice

  @ViewBuilder
  private var offlineDetails: some View {
    OnboardingOfflineRow(offlineReady: $offlineReady)

    // For regulated dictation (patient findings, case notes): the recording may not leave the
    // device, and neither may Chat or anything else. Offered here, where the user just said
    // "offline", rather than in Settings where they would have to know to look.
    VStack(alignment: .leading, spacing: 4) {
      Toggle("Block all cloud features (Offline Mode)", isOn: $offlineMode)
        .toggleStyle(.switch)
        .font(.callout)
        .onChange(of: offlineMode) { isOn in
          ModelSelectionReconciler.reconcileAll()
          PromptConversationHistory.shared.clearAll()
          DebugLogger.log("OFFLINE-MODE: \(isOn ? "enabled" : "disabled") during onboarding")
        }
      Text("For patient data or case notes: nothing leaves this Mac, not even Chat. Change it later in Settings → Privacy & Permissions.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 4)
  }

  @ViewBuilder
  private var cloudDetails: some View {
    // First because it is the only row a brand-new user can finish without leaving the app,
    // opening a dashboard, or copying anything — including creating the account itself.
    OnboardingOpenRouterRow(isConfigured: $hasOpenRouterKey)

    OnboardingAPIKeyRow(
      providerName: "Google Gemini",
      placeholder: "AIza…",
      linkTitle: "aistudio.google.com/api-keys",
      linkURL: URL(string: "https://aistudio.google.com/api-keys")!,
      description: "Already have a Google AI Studio key? Paste it here.",
      isConfigured: $hasGeminiKey,
      load: { KeychainManager.shared.get(.google) ?? "" },
      save: { KeychainManager.shared.save($0, for: .google) },
      recommended: false
    )

    DisclosureGroup(isExpanded: $showOtherProviders) {
      VStack(spacing: 12) {
        OnboardingAPIKeyRow(
          providerName: "OpenAI",
          placeholder: "sk-…",
          linkTitle: "platform.openai.com/api-keys",
          linkURL: URL(string: "https://platform.openai.com/api-keys")!,
          isConfigured: $hasOpenAIKey,
          load: { KeychainManager.shared.get(.openAI) ?? "" },
          save: { KeychainManager.shared.save($0, for: .openAI) },
          recommended: false
        )
        OnboardingAPIKeyRow(
          providerName: "Anthropic (Claude)",
          placeholder: "sk-ant-…",
          linkTitle: "console.anthropic.com",
          linkURL: URL(string: "https://console.anthropic.com/settings/keys")!,
          description: "Chat only — Dictate Prompt is not available with Claude.",
          isConfigured: $hasAnthropicKey,
          load: { KeychainManager.shared.get(.anthropic) ?? "" },
          save: { KeychainManager.shared.save($0, for: .anthropic) },
          recommended: false
        )
        OnboardingAPIKeyRow(
          providerName: "xAI (Grok)",
          placeholder: "xai-…",
          linkTitle: "console.x.ai",
          linkURL: URL(string: "https://console.x.ai")!,
          description: "Dictate Prompt is not available with Grok.",
          isConfigured: $hasXAIKey,
          load: { KeychainManager.shared.get(.xai) ?? "" },
          save: { KeychainManager.shared.save($0, for: .xai) },
          recommended: false
        )
      }
      .padding(.top, 8)
    } label: {
      Text("Other providers — OpenAI, Anthropic, xAI")
        .font(.callout)
        .foregroundStyle(.secondary)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation { showOtherProviders.toggle() } }
    }
    .padding(.horizontal, 4)
  }

  // MARK: - Privacy and status

  /// The privacy promise in one line, with the full version one click away. It used to be a step of
  /// its own; the choice above already answers its main question.
  private var privacyLine: some View {
    HStack(spacing: 8) {
      Image(systemName: "lock.shield")
        .foregroundStyle(.secondary)
      Text("Your audio goes only where you pick here — never to us. Keys stay in your Keychain.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 8)
      Button("Privacy details") { showPrivacyDetails.toggle() }
        .buttonStyle(.link)
        .font(.caption)
        .pointerCursorOnHover()
        .popover(isPresented: $showPrivacyDetails, arrowEdge: .top) {
          WelcomePrivacyDetails()
        }
    }
  }

  @ViewBuilder
  private var statusLine: some View {
    if canContinue {
      Label("Ready to continue.", systemImage: "checkmark.circle.fill")
        .font(.caption)
        .foregroundStyle(.green)
    } else {
      Label(pendingHint, systemImage: "exclamationmark.circle")
        .font(.caption)
        .foregroundStyle(.orange)
    }
  }

  private var pendingHint: String {
    switch choice {
    case nil: return "Pick Offline or Cloud to continue."
    case .offline: return "Download the offline model to continue."
    case .cloud: return "Connect OpenRouter or save a key to continue."
    }
  }
}

/// The full privacy promise, shown from the setup step's "Privacy details" link.
struct WelcomePrivacyDetails: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(PrivacyCopy.promiseTitle)
        .font(.headline)
      VStack(alignment: .leading, spacing: 10) {
        ForEach(PrivacyCopy.promiseBullets, id: \.self) { bullet in
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
              .foregroundStyle(.green)
            Text(bullet)
              .font(.callout)
              .textSelection(.enabled)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }
      OpenSourceBanner()
      Button {
        if let url = URL(string: AppConstants.privacyPolicyURL) {
          NSWorkspace.shared.open(url)
        }
      } label: {
        Label("View full privacy policy", systemImage: "doc.text")
          .font(.callout)
      }
      .buttonStyle(.bordered)
      .pointerCursorOnHover()
    }
    .padding(18)
    .frame(width: 480)
  }
}

/// Lets a new user finish setup with no provider key by downloading the recommended offline
/// model (Parakeet Ultra, ≈700 MB — `plans/active/parakeet-offline.md` D1: new setups get it).
struct OnboardingOfflineRow: View {
  @Binding var offlineReady: Bool
  private let modelType = OfflineModelType.mostAccurate

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      OfflineModelDownloadCard(modelType: modelType, onReady: syncReady)
      if offlineReady { OnboardingOfflinePromptNote() }
    }
  }

  /// Marks offline setup as ready and makes an offline model the active transcription backend.
  /// This row is shown only after the user answered "Offline" to "How should dictation run?", so
  /// that answer wins over a cloud key they may also have. A user already on another offline
  /// model (e.g. a Whisper model for a language Parakeet lacks) keeps it.
  private func syncReady() {
    offlineReady = true
    if TranscriptionModel.loadSelected().provider != .offline {
      UserDefaults.standard.set(
        TranscriptionModel.forOfflineModel(modelType).rawValue,
        forKey: UserDefaultsKeys.selectedTranscriptionModel)
      DebugLogger.log(
        "ONBOARDING: chose Offline; \(modelType.displayName) set as transcription model")
    }
    prepareOfflinePromptModel()
  }

  /// Without a key Dictate Prompt and Chat would otherwise fail on their first use. The reconciler
  /// selects the offline MLX default for them; this fetches it in the background so the first
  /// Dictate Prompt does not start with a 2.3 GB wait. Download only — loading into RAM happens
  /// on first use or at the next launch.
  ///
  /// Keyed to the reconciler's rule, not to "any cloud key": Grok, Claude and OpenRouter keys cannot
  /// run Dictate Prompt, so those users land on the offline model too and need it downloaded.
  private func prepareOfflinePromptModel() {
    guard ModelSelectionReconciler.keylessOfflineModel(
      among: PromptModel.dictatePromptCapableModels,
      hasKey: { ModelSelectionReconciler.hasKey($0) }) != nil
    else { return }
    ModelSelectionReconciler.reconcileAll()
    let model = LocalLLMModelType.defaultModel
    let manager = LocalLLMModelManager.shared
    guard !manager.isModelAvailable(model), !manager.downloadingModels.contains(model) else { return }
    DebugLogger.log("ONBOARDING: no cloud key — downloading \(model.displayName) for Dictate Prompt")
    Task {
      do {
        try await manager.downloadModel(model)
      } catch {
        DebugLogger.logWarning(
          "ONBOARDING: \(model.displayName) download failed: \(error.localizedDescription)")
      }
    }
  }
}

/// Tells a key-less user that Dictate Prompt works offline too, with the download's state. Shown
/// only while Dictate Prompt is on the offline model — with a usable key it is not, and there is
/// nothing to say.
struct OnboardingOfflinePromptNote: View {
  @ObservedObject private var manager = LocalLLMModelManager.shared
  private let model = LocalLLMModelType.defaultModel

  private var applies: Bool {
    LocalLLMModelType.isSupportedOnThisMac
      && PromptModel.loadPromptModel(
        forKey: UserDefaultsKeys.selectedPromptModel,
        default: SettingsDefaults.selectedPromptModel).localMLXModelType != nil
  }

  var body: some View {
    if applies {
      if manager.isModelAvailable(model) {
        Label("Dictate Prompt runs offline too — \(model.displayName) is ready.",
              systemImage: "checkmark.circle")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else if manager.downloadingModels.contains(model) {
        let percent = Int((manager.downloadProgress[model] ?? 0) * 100)
        Label("Dictate Prompt runs offline too — downloading \(model.displayName) (\(model.estimatedSizeLabel)) in the background… \(percent)%. You can continue.",
              systemImage: "arrow.down.circle")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}

/// One-click OpenRouter sign-in for onboarding.
///
/// Every other row here assumes the user already went to a provider dashboard and generated a key.
/// This one does not: OpenRouter's PKCE flow creates the account, takes the payment details, and
/// hands the app a key without the user ever seeing one — so it is the only row that can take
/// somebody from "just installed this" to "dictation works" without leaving the window.
struct OnboardingOpenRouterRow: View {
  @Binding var isConfigured: Bool
  @ObservedObject private var oauthService = OpenRouterOAuthService.shared

  @State private var isAuthorizing = false
  @State private var errorMessage: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        Text("OpenRouter")
          .font(.callout)
          .fontWeight(.semibold)
        Text("No key needed")
          .font(.caption2)
          .fontWeight(.medium)
          .padding(.horizontal, 6)
          .padding(.vertical, 2)
          .background(Color.accentColor.opacity(0.15))
          .foregroundColor(.accentColor)
          .clipShape(Capsule())
        if oauthService.isConnected {
          Label("Connected", systemImage: "checkmark.seal.fill")
            .font(.caption)
            .foregroundStyle(.green)
        }
        Spacer()
        Link("openrouter.ai", destination: URL(string: "https://openrouter.ai")!)
          .font(.caption)
          .pointerCursorOnHover()
      }

      Text("Sign in once and use models from every provider through one account. No account yet? The same flow creates one. You pay OpenRouter directly for what you use.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      HStack(spacing: 8) {
        if oauthService.isConnected {
          Button("Disconnect") {
            oauthService.disconnect()
            isConfigured = false
          }
          Link("Add credits", destination: OpenRouterOAuthConfig.creditsURL)
            .font(.callout)
            .pointerCursorOnHover()
        } else {
          Button("Connect OpenRouter Account") {
            connect()
          }
          .buttonStyle(.borderedProminent)
          .disabled(isAuthorizing)

          if isAuthorizing {
            ProgressView()
              .controlSize(.small)
          }
        }
        Spacer()
      }

      if let errorMessage {
        Text(errorMessage)
          .font(.caption)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(12)
    .background(Color.primary.opacity(0.04))
    .clipShape(RoundedRectangle(cornerRadius: 8))
    .onAppear {
      oauthService.refreshConnectionState()
      isConfigured = oauthService.isConnected
    }
  }

  private func connect() {
    isAuthorizing = true
    errorMessage = nil
    Task {
      do {
        if try await oauthService.connect() {
          isConfigured = true
          // A brand-new user has no other credential, so leaving the default transcription model
          // selected would send them to a provider they cannot reach. Point Dictate at what they
          // just connected.
          adoptOpenRouterAsTranscriptionModelIfNoOtherCredential()
          ModelSelectionReconciler.reconcileAll()
        }
      } catch {
        errorMessage = error.localizedDescription
      }
      isAuthorizing = false
    }
  }

  private func adoptOpenRouterAsTranscriptionModelIfNoOtherCredential() {
    let hasOtherCloudKey = KeychainManager.shared.hasNonEmpty(.google)
      || KeychainManager.shared.hasNonEmpty(.openAI)
      || KeychainManager.shared.hasNonEmpty(.xai)
      || KeychainManager.shared.hasNonEmpty(.anthropic)
    guard !hasOtherCloudKey else { return }
    UserDefaults.standard.set(
      TranscriptionModel.openRouterTranscription.rawValue,
      forKey: UserDefaultsKeys.selectedTranscriptionModel)
    DebugLogger.log("ONBOARDING: OpenRouter connected; set as default transcription model")
  }
}

struct OnboardingAPIKeyRow: View {
  let providerName: String
  let placeholder: String
  let linkTitle: String
  let linkURL: URL
  var description: String? = nil
  @Binding var isConfigured: Bool
  let load: () -> String
  let save: (String) -> Bool
  let recommended: Bool

  @State private var key: String = ""
  @State private var isVisible: Bool = false
  @State private var savedConfirmation: Bool = false
  @State private var saveError: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        Text(providerName)
          .font(.callout)
          .fontWeight(.semibold)
        if recommended {
          Text("Recommended")
            .font(.caption2)
            .fontWeight(.medium)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.accentColor.opacity(0.15))
            .foregroundColor(.accentColor)
            .clipShape(Capsule())
        }
        statusBadge
        Spacer()
        Link(linkTitle, destination: linkURL)
          .font(.caption)
          .pointerCursorOnHover()
      }

      if let description {
        Text(description)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      HStack(spacing: 8) {
        ZStack {
          if isVisible {
            TextField(placeholder, text: $key)
              .textFieldStyle(.roundedBorder)
              .font(.system(.body, design: .monospaced))
          } else {
            SecureField(placeholder, text: $key)
              .textFieldStyle(.roundedBorder)
              .font(.system(.body, design: .monospaced))
          }
        }
        Button {
          isVisible.toggle()
        } label: {
          Image(systemName: isVisible ? "eye.slash" : "eye")
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isVisible ? "Hide key" : "Show key")
        .help(isVisible ? "Hide key" : "Show key")

        Button("Save") {
          let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
          guard !trimmed.isEmpty else { return }
          if save(trimmed) {
            saveError = nil
            isConfigured = true
            CloudModelOffer.scheduleCheck()
            savedConfirmation = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
              savedConfirmation = false
            }
          } else {
            savedConfirmation = false
            saveError = "Couldn't save to Keychain. Try again."
          }
        }
        .buttonStyle(.bordered)
        .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || key == load())
        .pointerCursorOnHover()
      }

      if savedConfirmation {
        Label("Saved to Keychain", systemImage: "checkmark.seal.fill")
          .font(.caption2)
          .foregroundStyle(.green)
      }
      if let saveError {
        Label(saveError, systemImage: "exclamationmark.triangle.fill")
          .font(.caption2)
          .foregroundStyle(.red)
      }
    }
    .padding(14)
    .background(
      RoundedRectangle(cornerRadius: 10)
        .fill(Color(nsColor: .controlBackgroundColor))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 10)
        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
    )
    .onAppear {
      key = load()
      isConfigured = !key.isEmpty
    }
  }

  private var statusBadge: some View {
    HStack(spacing: 4) {
      Image(systemName: "circle.fill")
        .font(.system(size: 7))
        .foregroundStyle(isConfigured ? .green : .gray)
      Text(isConfigured ? "Configured" : "Not set")
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
    .padding(.horizontal, 6)
    .padding(.vertical, 2)
    .background(Capsule().fill((isConfigured ? Color.green : Color.gray).opacity(0.12)))
  }
}

/// The first successful dictation, as early as the tour can offer it: a provider or offline model
/// is set up (previous steps) and the microphone is granted. Everything after this is optional.
struct WelcomeTryItStep: View {
  private var dictateShortcut: String {
    ShortcutConfigManager.shared.loadConfiguration().startRecording.displayStringWithSeparator
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      HStack(spacing: 12) {
        Image(systemName: "waveform")
          .font(.system(size: 32))
          .foregroundStyle(.tint)
        VStack(alignment: .leading, spacing: 4) {
          Text("Try it now")
            .font(.title2)
            .fontWeight(.semibold)
          Text("Say a sentence. Later, \(dictateShortcut) does the same in any app and puts the text where your cursor is.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      OnboardingTryItPanel()
      Spacer(minLength: 0)
    }
  }
}

struct WelcomePermissionsStep: View {
  @Binding var micStatus: PermissionStatus

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      HStack(spacing: 12) {
        Image(systemName: "checkmark.shield")
          .font(.system(size: 32))
          .foregroundStyle(.tint)
        VStack(alignment: .leading, spacing: 4) {
          Text("macOS permissions")
            .font(.title2)
            .fontWeight(.semibold)
          Text("Only the microphone is required. The rest is optional and can wait — change any of it later in Settings → Privacy & Permissions.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }

      ScrollView {
        // The same overview used in Settings → Privacy & Permissions and on permission errors —
        // one component, one behavior. Accessibility is omitted here on purpose
        // (App Store Guideline 2.4.5: don't imply the app needs it up front).
        VStack(alignment: .leading, spacing: 14) {
          PermissionsOverview(mode: .onboarding, onMicStatusChange: { micStatus = $0 })
          // Accessibility appears only as the auto-paste opt-in, and only in the direct build:
          // the App Store build has no auto-paste (Guideline 2.4.5).
          #if !APP_STORE
          Divider()
          OnboardingAutoPasteCard()
          #endif
        }
        .padding(.bottom, 8)
      }

      if micStatus == .granted {
        Label("Ready to continue.", systemImage: "checkmark.circle.fill")
          .font(.caption)
          .foregroundStyle(.green)
      } else if micStatus == .denied {
        Label("Microphone is off in System Settings. You can continue and enable it later.", systemImage: "exclamationmark.circle")
          .font(.caption)
          .foregroundStyle(.orange)
      } else {
        Label("Grant microphone access to continue.", systemImage: "exclamationmark.circle")
          .font(.caption)
          .foregroundStyle(.orange)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
}

/// Auto-paste opt-in, shown on the permissions step of the direct build because it is the only
/// thing Accessibility is for. Default off — only flipping the toggle requests Accessibility (App
/// Store Guideline 2.4.5: never imply the app needs it up front). Never gates Continue.
struct OnboardingAutoPasteCard: View {
  @AppStorage(UserDefaultsKeys.autoPasteAfterDictation) private var autoPasteEnabled =
    SettingsDefaults.autoPasteAfterDictation

  /// Live Accessibility status so the user sees here whether the grant succeeded. Refreshed on
  /// appear and whenever the app reactivates (e.g. after returning from System Settings).
  @State private var axStatus: PermissionStatus = PermissionStatusChecker.status(for: .accessibility)

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Toggle(isOn: $autoPasteEnabled) {
        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: 8) {
            Text("Accessibility — auto-paste")
              .font(.callout)
              .fontWeight(.semibold)
            Text("Optional")
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
          Text("Puts dictated text straight at your cursor (a simulated ⌘V). macOS asks for Accessibility when you turn this on. Without it, your text is copied and you paste it yourself.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .toggleStyle(.switch)
      .onChange(of: autoPasteEnabled) { newValue in
        guard newValue else { return }
        if !AccessibilityPermissionManager.hasAccessibilityPermission() {
          // Request now (native prompt + pre-registration), matching the Settings opt-in path.
          AccessibilityPermissionManager.requestAccessibilityAtOptIn()
        }
        refreshStatus()
      }

      if autoPasteEnabled {
        HStack(spacing: 8) {
          WelcomePermissionBadge(status: axStatus)
          Text(axStatus == .granted
            ? "Accessibility granted — auto-paste is ready."
            : "Enable WhisperShortcut in System Settings, then return here.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          Spacer(minLength: 8)
          if axStatus != .granted {
            Button {
              PermissionStatusChecker.openSystemSettings(for: .accessibility)
            } label: {
              Label("Open System Settings", systemImage: "arrow.up.right.square")
                .font(.callout)
            }
            .buttonStyle(.bordered)
            .pointerCursorOnHover()
          }
        }
      }
    }
    .onAppear(perform: refreshStatus)
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      refreshStatus()
    }
  }

  private func refreshStatus() {
    axStatus = PermissionStatusChecker.status(for: .accessibility)
  }
}

struct WelcomeDoneStep: View {
  /// One shortcut the user can trigger, plus the OS permissions it needs to actually work.
  /// `requirements` is "all must be granted" — a single missing one makes the row red.
  private struct ShortcutFeature: Identifiable {
    let shortcut: String
    let name: String
    let detail: String
    let requirements: [PermissionKind]
    /// Dictate also needs a transcription model that can run (a key or a downloaded model).
    var needsTranscriptionModel = false
    var id: String { name }
  }

  /// Read from the recorders' model, so a shortcut re-recorded on this step shows up in the list
  /// right away (a `let` here was read once when the step appeared).
  private var shortcuts: ShortcutConfig { SettingsViewModel.shortcutConfig(from: settingsViewModel.data) }

  /// Live permission state so each row's green/red status is accurate, and flips the moment the
  /// user grants a permission and returns (didBecomeActive) without leaving onboarding.
  @State private var micStatus = PermissionStatusChecker.status(for: .microphone)
  @State private var axStatus = PermissionStatusChecker.status(for: .accessibility)
  @State private var screenStatus = PermissionStatusChecker.status(for: .screenRecording)
  /// Mirrors the menu bar's rule (`MenuBarController.updateMenuItems`): the icon turns into ⚠️
  /// when no provider key is set and the selected transcription model cannot run.
  @State private var canTranscribe = TranscriptionModel.loadSelected().hasRequiredCredential
  @State private var hasAnyCredential = ProviderCredentials.anyChatCredentialConfigured
  @StateObject private var settingsViewModel = SettingsViewModel()
  @FocusState private var focusedField: SettingsFocusField?

  /// Every shortcut the user can use, rendered uniformly. Dictation is just the first row — no
  /// special hero treatment — so the whole page reads as one consistent list. Disabled shortcuts
  /// are hidden rather than shown as "Disabled".
  private var features: [ShortcutFeature] {
    var list: [ShortcutFeature] = []
    if shortcuts.startRecording.isEnabled {
      list.append(
        ShortcutFeature(
          shortcut: shortcuts.startRecording.displayString,
          name: "Dictate",
          detail: "press and start speaking — your words land as text",
          requirements: [.microphone],
          needsTranscriptionModel: true))
    }
    if shortcuts.startPrompting.isEnabled {
      // The App Store build reads the selection from a screenshot (Screen Recording);
      // the direct build copies it via a synthetic ⌘C (Accessibility).
      let selectionRequirement: PermissionKind =
        AppConstants.dictatePromptUsesScreenshotSelection ? .screenRecording : .accessibility
      #if APP_STORE
      let promptDetail =
        "select text, speak an instruction — the selection is rewritten in place. This build reads the highlighted text from a screenshot (Screen Recording). Offline models need you to copy the selection with ⌘C first."
      #else
      let promptDetail =
        "select text, speak an instruction — the selection is rewritten in place"
      #endif
      list.append(
        ShortcutFeature(
          shortcut: shortcuts.startPrompting.displayString,
          name: "Dictate Prompt",
          detail: promptDetail,
          requirements: [.microphone, selectionRequirement]))
    }
    if shortcuts.screenshotCapture.isEnabled {
      list.append(
        ShortcutFeature(
          shortcut: shortcuts.screenshotCapture.displayString,
          name: "Screenshot",
          detail: "capture your screen straight to the clipboard or a folder",
          requirements: [.screenRecording]))
    }
    if shortcuts.openChat.isEnabled {
      list.append(
        ShortcutFeature(
          shortcut: shortcuts.openChat.displayString,
          name: "Chat",
          detail: "a full conversation window, with screenshots",
          requirements: []))
    }
    // Selection-based Read Aloud copies via ⌘C (Accessibility) — the feature is omitted
    // from the App Store build entirely (no menu item, no hotkey), so don't advertise it.
    #if !APP_STORE
    if shortcuts.readAloud.isEnabled {
      list.append(
        ShortcutFeature(
          shortcut: shortcuts.readAloud.displayString,
          name: "Read Aloud",
          detail: "select text anywhere and hear it spoken",
          requirements: [.accessibility]))
    }
    #endif
    return list
  }

  var body: some View {
    ScrollView {
    VStack(spacing: 18) {
      Image(systemName: dictationReady ? "checkmark.seal.fill" : "exclamationmark.circle.fill")
        .font(.system(size: 40))
        .foregroundStyle(dictationReady ? .green : .orange)
      VStack(spacing: 8) {
        Text(dictationReady ? "You're ready" : "Almost ready")
          .font(.largeTitle)
          .fontWeight(.semibold)
        // The app has no Dock icon or main window, so say where it lives — and describe the icon
        // the user will actually see: ⚠️ while nothing can transcribe, the mic otherwise.
        menuBarHint
          .font(.callout)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: 560)

      VStack(alignment: .leading, spacing: 8) {
        Text("Your shortcuts — green is ready, red still needs a permission.")
          .font(.caption)
          .foregroundStyle(.secondary)
        VStack(spacing: 0) {
          ForEach(Array(features.enumerated()), id: \.element.id) { index, feature in
            if index > 0 { Divider() }
            shortcutRow(feature)
          }
        }
        .background(
          RoundedRectangle(cornerRadius: 10)
            .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
          RoundedRectangle(cornerRadius: 10)
            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
      }
      .frame(maxWidth: 560, alignment: .leading)

      // Asked last, once the user has seen what the app does: a yes here is an informed one.
      UsageStatisticsToggle()
        .padding(14)
        .frame(maxWidth: 560, alignment: .leading)
        .background(
          RoundedRectangle(cornerRadius: 10)
            .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
          RoundedRectangle(cornerRadius: 10)
            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )

      onboardingShortcutRecorder
        .frame(maxWidth: 560)

      Text("You can revisit this tour any time from Settings → About.")
        .font(.caption)
        .foregroundStyle(.tertiary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 560)
    }
    .frame(maxWidth: .infinity)
    .padding(.bottom, 8)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .onAppear(perform: refreshStatuses)
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      refreshStatuses()
    }
  }

  /// Writes the shortcut bindings and leaves every other settings slot alone.
  /// `saveSettings()` would persist the snapshot taken when this step appeared,
  /// so a model picked in Settings meanwhile would be reverted.
  /// `saveConfiguration` posts `.shortcutsChanged`, which re-registers hotkeys.
  private func saveRecordedShortcuts() {
    ShortcutConfigManager.shared.saveConfiguration(
      SettingsViewModel.shortcutConfig(from: settingsViewModel.data))
  }

  @ViewBuilder
  private var onboardingShortcutRecorder: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Shortcuts")
        .font(.callout)
        .fontWeight(.semibold)
      Text("Record a different combination for any of these if it clashes with an app you use.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      ShortcutRecorderRow(
        label: "Dictate:",
        shortcut: $settingsViewModel.data.toggleDictation,
        focusedField: .toggleDictation,
        currentFocus: $focusedField,
        onChanged: { saveRecordedShortcuts() },
        findConflict: settingsViewModel.findShortcutConflict,
        clearShortcut: settingsViewModel.clearShortcut
      )
      ShortcutRecorderRow(
        label: "Dictate Prompt:",
        shortcut: $settingsViewModel.data.togglePrompting,
        focusedField: .togglePrompting,
        currentFocus: $focusedField,
        onChanged: { saveRecordedShortcuts() },
        findConflict: settingsViewModel.findShortcutConflict,
        clearShortcut: settingsViewModel.clearShortcut
      )
      ShortcutRecorderRow(
        label: "Screenshot:",
        shortcut: $settingsViewModel.data.screenshotCapture,
        focusedField: .screenshotCapture,
        currentFocus: $focusedField,
        onChanged: { saveRecordedShortcuts() },
        findConflict: settingsViewModel.findShortcutConflict,
        clearShortcut: settingsViewModel.clearShortcut
      )
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 10)
        .fill(Color(nsColor: .controlBackgroundColor))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 10)
        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
    )
  }

  @ViewBuilder
  private func shortcutRow(_ feature: ShortcutFeature) -> some View {
    HStack(spacing: 12) {
      Text(feature.shortcut)
        .font(.system(.callout, design: .monospaced))
        .fontWeight(.medium)
        .frame(minWidth: 52, alignment: .leading)
      VStack(alignment: .leading, spacing: 2) {
        Text(feature.name)
          .font(.callout)
          .fontWeight(.medium)
        Text(feature.detail)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 8)
      statusBadge(for: feature)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
  }

  /// Green "Ready" when every required permission is granted; otherwise a red, tappable badge
  /// naming the first missing permission and opening the right System Settings pane.
  @ViewBuilder
  private func statusBadge(for feature: ShortcutFeature) -> some View {
    if feature.needsTranscriptionModel && !canTranscribe {
      badgeContent(icon: "exclamationmark.circle.fill", color: .orange, text: "Needs a model")
    } else if let missing = missingRequirement(for: feature) {
      Button {
        PermissionStatusChecker.openSystemSettings(for: missing)
      } label: {
        badgeContent(
          icon: "xmark.circle.fill", color: .red, text: "Needs \(permissionName(missing))")
      }
      .buttonStyle(.plain)
      .pointerCursorOnHover()
      .help("Open System Settings to grant \(permissionName(missing)) access")
    } else {
      badgeContent(icon: "checkmark.circle.fill", color: .green, text: "Ready")
    }
  }

  private func badgeContent(icon: String, color: Color, text: String) -> some View {
    HStack(spacing: 4) {
      Image(systemName: icon)
        .foregroundStyle(color)
      Text(text)
        .foregroundStyle(.secondary)
    }
    .font(.caption)
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .background(Capsule().fill(color.opacity(0.12)))
  }

  /// First required permission that isn't granted, or nil when the feature is fully usable.
  private func missingRequirement(for feature: ShortcutFeature) -> PermissionKind? {
    feature.requirements.first { status(for: $0) != .granted }
  }

  private func status(for kind: PermissionKind) -> PermissionStatus {
    switch kind {
    case .microphone: return micStatus
    case .accessibility: return axStatus
    case .screenRecording: return screenStatus
    }
  }

  private func permissionName(_ kind: PermissionKind) -> String {
    switch kind {
    case .microphone: return "Microphone"
    case .accessibility: return "Accessibility"
    case .screenRecording: return "Screen Recording"
    }
  }

  private var dictationReady: Bool { canTranscribe && micStatus == .granted }

  private var menuBarHint: Text {
    if !canTranscribe && !hasAnyCredential {
      return Text("WhisperShortcut lives in your menu bar. It shows ⚠️ until dictation is set up — click it, choose Settings…, and add a key or download the offline model.")
    }
    if !canTranscribe {
      return Text("WhisperShortcut lives in your menu bar — the \(Image(systemName: "mic.fill")) icon at the top of your screen. Dictation still needs a transcription model: pick one in Settings → Dictate.")
    }
    if micStatus != .granted {
      return Text("WhisperShortcut lives in your menu bar — the \(Image(systemName: "mic.fill")) icon at the top of your screen. Dictation needs the microphone: allow it in System Settings → Privacy & Security → Microphone.")
    }
    return Text("WhisperShortcut lives in your menu bar — the \(Image(systemName: "mic.fill")) icon at the top of your screen.")
  }

  private func refreshStatuses() {
    canTranscribe = TranscriptionModel.loadSelected().hasRequiredCredential
    hasAnyCredential = ProviderCredentials.anyChatCredentialConfigured
    micStatus = PermissionStatusChecker.status(for: .microphone)
    axStatus = PermissionStatusChecker.status(for: .accessibility)
    screenStatus = PermissionStatusChecker.status(for: .screenRecording)
  }
}

struct WelcomePermissionBadge: View {
  let status: PermissionStatus

  var body: some View {
    HStack(spacing: 5) {
      Image(systemName: "circle.fill")
        .font(.system(size: 8))
        .foregroundStyle(color)
      Text(label)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 3)
    .background(Capsule().fill(color.opacity(0.12)))
  }

  private var color: Color {
    switch status {
    case .granted: return .green
    case .denied: return .red
    case .notDetermined: return .yellow
    case .notApplicable: return .gray
    }
  }

  private var label: String {
    switch status {
    case .granted: return "Granted"
    case .denied: return "Denied"
    case .notDetermined: return "Not requested"
    case .notApplicable: return "Not applicable"
    }
  }
}
