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
      .cardChrome(fill: Color.accentColor.opacity(0.10), stroke: Color.accentColor.opacity(0.35))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .pointerCursorOnHover()
    .help("Open the WhisperShortcut source code on GitHub")
  }
}

/// Where onboarding points Dictate after the user picks Cloud or connects OpenRouter.
///
/// Those two sites used to choose independently: one walked `TranscriptionModel.allCases` (app
/// default first), the other a four-provider "any other key" chain. Both disagreed with
/// `ModelSelectionReconciler.providerPreference`. A cloud model that can already run stays. An
/// offline selection, or a cloud one that cannot run (the factory default is OpenAI, which a
/// Gemini-only user cannot reach), moves. The offline download card does not call this — that
/// answer is "keep this on the Mac", and the reconciler's cloud pick would undo it.
@MainActor
enum OnboardingTranscriptionChoice {
  /// `onlyIfCurrentCannotRun` is for a step that is already showing Cloud (a revisited tour).
  /// Tapping Cloud still replaces a working offline model — that was the user's answer. Merely
  /// opening the step must not, or a key they keep for Chat would move dictation off this Mac.
  static func preferCloud(onlyIfCurrentCannotRun: Bool = false) {
    guard let model = ModelSelectionReconciler.preferredCloudTranscription() else { return }
    let current = TranscriptionModel.loadSelected()
    if current == model { return }
    if current.hasRequiredCredential && (onlyIfCurrentCannotRun || current.provider != .offline) {
      return
    }
    UserDefaults.standard.set(model.rawValue, forKey: UserDefaultsKeys.selectedTranscriptionModel)
    DebugLogger.log("ONBOARDING: chose Cloud; transcription model set to \(model.rawValue)")
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
  @ObservedObject var setup: OnboardingSetupState
  @AppStorage(UserDefaultsKeys.offlineModeEnabled) private var offlineMode = false
  /// Shown and changeable under Offline, so the language the app just picked from the Mac's is
  /// visible right where it was set (`DictationLanguagePreselect`).
  @AppStorage(UserDefaultsKeys.whisperLanguage) private var dictationLanguage: WhisperLanguage =
    SettingsDefaults.whisperLanguage
  /// The language on screen came from the Mac's language on this visit, not from the user.
  @State private var languageFromMac = false
  @State private var showOtherProviders = false
  @State private var showPrivacyDetails = false

  /// Same bit Continue uses. `setup` is what re-publishes it after a key, OAuth, or download.
  private var canContinue: Bool { setup.dictationCanAdvance }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      WelcomeStepHeader(
        systemImage: "waveform.badge.mic",
        title: "How should dictation run?",
        subtitle: "Pick one to start. You can add the other any time in Settings.")

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
    // A revisited tour can already be on Cloud with a key, without `select` running again.
    // The factory default is a cloud model the user may not have a key for; move it now.
    .onAppear {
      if choice == .cloud { OnboardingTranscriptionChoice.preferCloud(onlyIfCurrentCannotRun: true) }
      setup.refresh()
    }
  }

  /// A key was saved or OpenRouter connected/disconnected. Cloud must re-pick a model that
  /// can run before Continue re-reads `hasRequiredCredential`, or a Gemini key leaves the
  /// OpenAI default selected and the step stays blocked.
  private func credentialChanged() {
    if choice == .cloud { OnboardingTranscriptionChoice.preferCloud() }
    setup.refresh()
  }

  // MARK: - Choice cards

  private func choiceCard(
    _ value: DictationChoice, icon: String, title: LocalizedStringKey, tagline: LocalizedStringKey, facts: [LocalizedStringKey]
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
          ForEach(Array(facts.enumerated()), id: \.offset) { _, fact in
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
      .cardChrome(
        fill: selected ? Color.accentColor.opacity(0.10) : Color(nsColor: .controlBackgroundColor),
        stroke: selected ? Color.accentColor : Color(nsColor: .separatorColor),
        lineWidth: selected ? 2 : 1)
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
      OfflineMode.switchTo(false, reason: "onboarding chose Cloud")
    }
    if value == .cloud { OnboardingTranscriptionChoice.preferCloud() }
    // Only while the language is still Auto, and only to one the offline model can transcribe.
    if value == .offline, DictationLanguagePreselect.applyForOfflineOnboarding() != nil {
      languageFromMac = true
    }
    setup.refresh()
  }

  // MARK: - Details per choice

  @ViewBuilder
  private var offlineDetails: some View {
    OnboardingOfflineRow(onReady: { setup.refresh() })

    dictationLanguageRow

    // For regulated dictation (patient findings, case notes): the recording may not leave the
    // device, and neither may Chat or anything else. Offered here, where the user just said
    // "offline", rather than in Settings where they would have to know to look.
    VStack(alignment: .leading, spacing: 4) {
      Toggle("Block all cloud features (Offline Mode)", isOn: $offlineMode)
        .toggleStyle(.switch)
        .font(.callout)
        .onChange(of: offlineMode) { isOn in
          OfflineMode.switchTo(isOn, reason: "during onboarding")
        }
      Text("For patient data or case notes: nothing leaves this Mac, not even Chat. Change it later in Settings → Permissions & Privacy.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 4)
  }

  /// "Dictation language: German", changeable on the spot. Lists only what the offline model can
  /// transcribe (plus whatever is stored, so the picker never shows an empty selection).
  private var dictationLanguageRow: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 8) {
        Text("Dictation language:")
          .font(.callout)
        Picker("Dictation language", selection: $dictationLanguage) {
          ForEach(offlineLanguageOptions, id: \.self) { language in
            Text(language.displayName).tag(language)
          }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .fixedSize()
        Spacer(minLength: 0)
      }
      if languageFromMac && dictationLanguage != .auto {
        Text("Taken from your Mac’s language. Choose Auto-detect if you switch languages while dictating.")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(.horizontal, 14)
  }

  private var offlineLanguageOptions: [WhisperLanguage] {
    let model = DictationLanguagePreselect.onboardingOfflineModel
    return WhisperLanguage.allCases.filter { $0 == dictationLanguage || model.supports($0) }
  }

  @ViewBuilder
  private var cloudDetails: some View {
    // First because it is the only row a brand-new user can finish without leaving the app,
    // opening a dashboard, or copying anything — including creating the account itself.
    OnboardingOpenRouterRow(onCredentialChanged: credentialChanged)

    OnboardingAPIKeyRow(
      provider: .google,
      note: "Already have a Google AI Studio key? Paste it here.",
      onStored: credentialChanged
    )

    DisclosureGroup(isExpanded: $showOtherProviders) {
      VStack(spacing: 12) {
        OnboardingAPIKeyRow(provider: .openai, onStored: credentialChanged)
        OnboardingAPIKeyRow(
          provider: .anthropic,
          note: "Chat only — Dictate Prompt is not available with Claude.",
          onStored: credentialChanged
        )
        OnboardingAPIKeyRow(
          provider: .xai,
          note: "Dictate Prompt is not available with Grok.",
          onStored: credentialChanged
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

  private var pendingHint: LocalizedStringKey {
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
        ForEach(Array(PrivacyCopy.promiseBullets.enumerated()), id: \.offset) { _, bullet in
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
  /// Continue re-reads the selected model after the download (or an already-present file) has
  /// been made the transcription backend.
  var onReady: () -> Void = {}
  private let modelType = OfflineModelType.mostAccurate
  @ObservedObject private var modelManager = ModelManager.shared

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      OfflineModelDownloadCard(modelType: modelType, onReady: syncReady)
      if modelManager.isModelAvailable(modelType) { OnboardingOfflinePromptNote() }
    }
  }

  /// Marks offline setup as ready and makes an offline model the active transcription backend.
  /// This row is shown only after the user answered "Offline" to "How should dictation run?", so
  /// that answer wins over a cloud key they may also have. A user already on another offline
  /// model (e.g. a Whisper model for a language Parakeet lacks) keeps it.
  private func syncReady() {
    if TranscriptionModel.loadSelected().provider != .offline {
      UserDefaults.standard.set(
        TranscriptionModel.forOfflineModel(modelType).rawValue,
        forKey: UserDefaultsKeys.selectedTranscriptionModel)
      DebugLogger.log(
        "ONBOARDING: chose Offline; \(modelType.displayName) set as transcription model")
    }
    prepareOfflinePromptModel()
    onReady()
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
  /// Parent re-picks a transcription model and re-reads Continue. Replaces the `isConfigured`
  /// binding that used to be one of five Keychain booleans.
  var onCredentialChanged: () -> Void = {}
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
            // Chat may have been running on this key. Same re-check Settings does on Disconnect,
            // so onboarding cannot keep a slot pointed at an account that is now gone.
            ModelSelectionReconciler.reconcileAll()
            onCredentialChanged()
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
    }
  }

  private func connect() {
    isAuthorizing = true
    errorMessage = nil
    Task {
      do {
        if try await oauthService.connect() {
          // A brand-new user has no other credential, so leaving the default transcription model
          // selected would send them to a provider they cannot reach. Same pick as the Cloud
          // card: reconciler order, OpenRouter only when nothing else can transcribe.
          OnboardingTranscriptionChoice.preferCloud()
          ModelSelectionReconciler.reconcileAll()
          onCredentialChanged()
        }
      } catch {
        errorMessage = error.localizedDescription
      }
      isAuthorizing = false
    }
  }

}

struct OnboardingAPIKeyRow: View {
  let provider: APIKeyProvider
  /// Extra line under the title. The provider's own subtitle is the Settings paragraph;
  /// onboarding keeps the shorter note it already showed.
  var note: LocalizedStringKey? = nil
  /// Runs after a successful save, once `store` has reconciled. The setup step re-picks a
  /// transcription model and re-reads Continue from here.
  var onStored: () -> Void = {}

  @State private var key: String = ""
  /// Last value read or saved. The Save button used to call `load()` inside `.disabled`, which
  /// hit the Keychain on every render.
  @State private var storedKey: String = ""
  @State private var isVisible: Bool = false
  @State private var isSaving: Bool = false
  @State private var savedConfirmation: Bool = false
  @State private var saveError: OSStatus?

  private var link: APIKeyHelpLink? { provider.helpLinks.first }
  private var isConfigured: Bool { !storedKey.isEmpty }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        Text(provider.sectionTitle)
          .font(.callout)
          .fontWeight(.semibold)
        statusBadge
        Spacer()
        if let link {
          Link(link.label, destination: link.url)
            .font(.caption)
            .pointerCursorOnHover()
        }
      }

      if let note {
        Text(note)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      HStack(spacing: 8) {
        ZStack {
          if isVisible {
            TextField(provider.keyPlaceholder, text: $key)
              .textFieldStyle(.roundedBorder)
              .font(.system(.body, design: .monospaced))
          } else {
            SecureField(provider.keyPlaceholder, text: $key)
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
        .accessibilityLabel(isVisible ? ("Hide key" as LocalizedStringKey) : "Show key")
        .help(isVisible ? ("Hide key" as LocalizedStringKey) : "Show key")

        Button("Save") {
          let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
          guard !trimmed.isEmpty, !isSaving else { return }
          isSaving = true
          savedConfirmation = false
          Task {
            let status = await provider.store(trimmed)
            isSaving = false
            saveError = status
            guard status == nil else { return }
            storedKey = trimmed
            key = trimmed
            onStored()
            savedConfirmation = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
              savedConfirmation = false
            }
          }
        }
        .buttonStyle(.bordered)
        .disabled(
          isSaving || key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || key == storedKey
        )
        .pointerCursorOnHover()
      }

      if savedConfirmation {
        Label("Saved to Keychain", systemImage: "checkmark.seal.fill")
          .font(.caption2)
          .foregroundStyle(.green)
      }
      if let saveError {
        KeychainSaveWarning(status: saveError)
      }
    }
    .padding(14)
    .cardChrome()
    .onAppear {
      let stored = KeychainManager.shared.get(provider.credential) ?? ""
      storedKey = stored
      key = stored
    }
  }

  private var statusBadge: some View {
    HStack(spacing: 4) {
      Image(systemName: "circle.fill")
        .font(.system(size: 7))
        .foregroundStyle(isConfigured ? .green : .gray)
      Text(isConfigured ? ("Configured" as LocalizedStringKey) : "Not set")
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
  /// A disabled Dictate binding renders as "Disabled", which used to read
  /// "Later, Disabled does the same…". There is no other wording for that case, so the
  /// "Later, … does the same" clause is dropped and only the instruction to try it remains.
  private var tryItDetail: LocalizedStringKey {
    let shortcut = ShortcutConfigManager.shared.loadConfiguration()[keyPath: ShortcutAction.dictate.keyPath]
    guard shortcut.isEnabled else { return "Say a sentence." }
    return "Say a sentence. Later, \(shortcut.displayStringWithSeparator) does the same in any app and puts the text where your cursor is."
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      WelcomeStepHeader(
        systemImage: "waveform",
        title: "Try it now",
        subtitle: tryItDetail)
      OnboardingTryItPanel()
      Spacer(minLength: 0)
    }
  }
}

struct WelcomePermissionsStep: View {
  @Binding var micStatus: PermissionStatus
  /// False while Fn dictation is on and macOS still owns the 🌐 key; Continue waits for it.
  var fnSetupResolved: Bool = true

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      WelcomeStepHeader(
        systemImage: "checkmark.shield",
        title: "macOS permissions",
        subtitle: "Only the microphone is required. The rest is optional and can wait — change any of it later in Settings → Permissions & Privacy.")

      ScrollView {
        // The same overview used in Settings → Privacy & Permissions and on permission errors —
        // one component, one behavior. Accessibility is omitted here on purpose
        // (App Store Guideline 2.4.5: don't imply the app needs it up front).
        VStack(alignment: .leading, spacing: 14) {
          PermissionsOverview(
            mode: .onboarding,
            includeScreenRecording: false,
            onMicStatusChange: { micStatus = $0 })
          Text("Other features ask for access the first time you use them.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          // Accessibility appears only for the two features that need it (Fn dictation,
          // auto-paste), and only in the direct build: the App Store build has neither
          // (Guideline 2.4.5).
          #if !APP_STORE
          Divider()
          OnboardingAccessibilityCard()
          #endif
        }
        .padding(.bottom, 8)
      }

      if (micStatus == .granted || micStatus == .denied) && !fnSetupResolved {
        Label("Free the 🌐 key above, or turn off Fn dictation, to continue.", systemImage: "exclamationmark.circle")
          .font(.caption)
          .foregroundStyle(.orange)
      } else if micStatus == .granted {
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

/// The two direct-build features that need Accessibility, on the permissions step: Fn dictation
/// and auto-paste. Never gates Continue, and nothing here prompts on its own — the system prompt
/// appears only when the user flips a toggle on or taps Allow (Guideline 2.4.5 spirit: don't
/// imply the app needs it up front).
///
/// Fn arrives already on when the 🌐 key is free (`SettingsDefaults.fnKeyDictation`): it is the
/// most comfortable trigger, and here is where one grant covers both features. When macOS still
/// uses the 🌐 key itself, Fn stays off by default and turning it on shows `GlobeKeyConflictCard`;
/// Continue then waits until the key is freed or Fn is turned off again (`WelcomeStep.canAdvance`).
struct OnboardingAccessibilityCard: View {
  @AppStorage(UserDefaultsKeys.fnKeyDictation) private var fnEnabled = SettingsDefaults.fnKeyDictation
  /// What auto-paste does now: the stored choice, or `AutoPasteDefault.effectiveDefault` while the
  /// key is unset. Not `@AppStorage`: its default is fixed when the card appears, and assigning
  /// it would write the key — a user who only grants Accessibility must not get a stored
  /// preference. `@State` so a flip redraws the switch and fires `featureToggle`'s `onChange`;
  /// `refreshStatus` re-reads it, so granting Accessibility turns the unset default on visibly.
  @State private var autoPasteShown = AutoPasteDefault.currentValue

  /// Writes the key only when the user flips the switch.
  private var autoPasteEnabled: Binding<Bool> {
    Binding(
      get: { autoPasteShown },
      set: { newValue in
        autoPasteShown = newValue
        UserDefaults.standard.set(newValue, forKey: UserDefaultsKeys.autoPasteAfterDictation)
      }
    )
  }

  /// Live Accessibility status, so the card reflects what the user just changed in System
  /// Settings. Refreshed on appear and whenever the app reactivates. The 🌐 setting is
  /// `GlobeKeyStatus`, which the conflict card refreshes itself.
  @State private var axStatus: PermissionStatus = PermissionStatusChecker.status(for: .accessibility)
  /// The user asked for Accessibility from here (toggle or button), so macOS showed its prompt or
  /// System Settings.
  @State private var requestedAccessibility = false
  /// …and came back (or asked a second time) without the grant: time for the drag fallback.
  @State private var returnedWithoutGrant = false

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 8) {
          Text("Accessibility")
            .font(.callout)
            .fontWeight(.semibold)
          Text("Optional")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        Text("Two extras need it. macOS asks once, when you first turn one on.")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      featureToggle(
        $fnEnabled,
        title: "Dictate with 🌐 Fn",
        detail: "Press Fn once to start, again to stop. The quickest way to dictate.")

      if fnEnabled {
        GlobeKeyConflictCard(onTurnOffFn: {
          DebugLogger.log("ONBOARDING: turned Fn dictation off from the 🌐 conflict card")
          fnEnabled = false
        })
      }

      featureToggle(
        autoPasteEnabled,
        title: "Auto-paste",
        detail: "Puts dictated text straight at your cursor (a simulated ⌘V). Without it, your text is copied and you paste it yourself.")

      if fnEnabled || autoPasteShown {
        HStack(spacing: 8) {
          PermissionStatusBadge(status: axStatus)
          Text(axStatus == .granted
            ? ("Accessibility granted — ready." as LocalizedStringKey)
            : "Not allowed yet. Allow WhisperShortcut in System Settings, then return here.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          Spacer(minLength: 8)
          if axStatus != .granted {
            Button {
              // Native prompt the first time, the System Settings pane once it was answered.
              if requestedAccessibility { returnedWithoutGrant = true }
              requestedAccessibility = true
              AccessibilityPermissionManager.requestAccessibilityAtOptIn()
              refreshStatus()
            } label: {
              Label("Allow Accessibility", systemImage: "arrow.up.right.square")
                .font(.callout)
            }
            .buttonStyle(.bordered)
            .pointerCursorOnHover()
          }
        }

        if returnedWithoutGrant && axStatus != .granted {
          AccessibilityDragFallback()
        }
      }
    }
    .onAppear(perform: refreshStatus)
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      if requestedAccessibility { returnedWithoutGrant = true }
      refreshStatus()
    }
  }

  private func featureToggle(
    _ isOn: Binding<Bool>, title: LocalizedStringKey, detail: LocalizedStringKey
  ) -> some View {
    Toggle(isOn: isOn) {
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.callout)
        Text(detail)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      // Full width so both switches line up on the trailing edge, whatever the text length.
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .toggleStyle(.switch)
    .onChange(of: isOn.wrappedValue) { newValue in
      guard newValue else { return }
      // Request now (native prompt + pre-registration), matching the Settings opt-in path.
      if axStatus != .granted { requestedAccessibility = true }
      AccessibilityPermissionManager.requestAccessibilityAtOptIn()
      refreshStatus()
    }
  }

  private func refreshStatus() {
    axStatus = PermissionStatusChecker.status(for: .accessibility)
    autoPasteShown = AutoPasteDefault.currentValue
    GlobeKeyStatus.shared.refresh()
  }
}

/// Shown on the permissions step when the user went to System Settings for Accessibility and came
/// back without the grant. Usually WhisperShortcut is simply missing from the list — a pilot user
/// (2026-11-02) had to find it with "+" and a file picker, then met a Touch ID prompt she did not
/// trust. Dragging the icon into the list adds the app in one move.
struct AccessibilityDragFallback: View {
  var body: some View {
    HStack(alignment: .center, spacing: 12) {
      Image(nsImage: NSApp.applicationIconImage)
        .resizable()
        .frame(width: 48, height: 48)
        // A file URL of the running bundle — what System Settings accepts when an app is dropped
        // on its Accessibility list.
        .onDrag { NSItemProvider(object: Bundle.main.bundleURL as NSURL) }
        .help(Text("Drag into the Accessibility list"))
        .accessibilityLabel(Text("WhisperShortcut app icon, draggable"))
      VStack(alignment: .leading, spacing: 4) {
        Text("Don’t see WhisperShortcut in the list? Drag this icon into the list.")
          .font(.callout)
          .fontWeight(.medium)
          .fixedSize(horizontal: false, vertical: true)
        Text("If macOS then asks for your password or Touch ID, that request comes from macOS itself — WhisperShortcut never sees it.")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 0)
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .cardChrome()
  }
}

struct WelcomeDoneStep: View {
  /// One shortcut the user can trigger, plus the OS permissions it needs to actually work.
  /// `requirements` is "all must be granted" — a single missing one makes the row red.
  private struct ShortcutFeature: Identifiable {
    let shortcut: String
    let name: LocalizedStringResource
    let detail: LocalizedStringKey
    let requirements: [PermissionKind]
    /// Dictate also needs a transcription model that can run (a key or a downloaded model).
    var needsTranscriptionModel = false
    var id: String { shortcut }
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
  /// True when the user already picked an offline model that is not downloaded yet — the state that
  /// must ask for a download, not for an API key.
  @State private var needsOfflineModelDownload = TranscriptionModel.loadSelected().needsOfflineModelDownload
  @StateObject private var settingsViewModel = SettingsViewModel()
  @FocusState private var focusedField: SettingsFocusField?

  /// Every shortcut the user can use, rendered uniformly. Dictation is just the first row — no
  /// special hero treatment — so the whole page reads as one consistent list. Disabled shortcuts
  /// are hidden rather than shown as "Disabled".
  private var features: [ShortcutFeature] {
    var list: [ShortcutFeature] = []
    func binding(_ action: ShortcutAction) -> ShortcutDefinition {
      shortcuts[keyPath: action.keyPath]
    }
    let dictate = binding(.dictate)
    if dictate.isEnabled {
      list.append(
        ShortcutFeature(
          shortcut: dictate.displayString,
          name: ShortcutAction.dictate.localizedTitle,
          detail: "press and start speaking — your words land as text",
          requirements: [.microphone],
          needsTranscriptionModel: true))
    }
    let prompting = binding(.dictatePrompt)
    if prompting.isEnabled {
      // Per selected model: screenshot → Screen Recording; App Store local → clipboard the user
      // copied, so no extra permission; direct build → Accessibility for the synthetic ⌘C.
      let promptModel = settingsViewModel.data.selectedPromptModel
      var promptRequirements: [PermissionKind] = [.microphone]
      if let selection = promptModel.dictatePromptSelectionPermission {
        promptRequirements.append(selection)
      }
      #if APP_STORE
      let promptDetail: LocalizedStringKey =
        "select text, speak an instruction — the selection is rewritten in place. This build reads the highlighted text from a screenshot (Screen Recording). Offline models need you to copy the selection with ⌘C first."
      #else
      let promptDetail: LocalizedStringKey =
        "select text, speak an instruction — the selection is rewritten in place"
      #endif
      list.append(
        ShortcutFeature(
          shortcut: prompting.displayString,
          name: ShortcutAction.dictatePrompt.localizedTitle,
          detail: promptDetail,
          requirements: promptRequirements))
    }
    let screenshot = binding(.screenshot)
    if screenshot.isEnabled {
      list.append(
        ShortcutFeature(
          shortcut: screenshot.displayString,
          name: ShortcutAction.screenshot.localizedTitle,
          detail: "capture your screen straight to the clipboard or a folder",
          requirements: [.screenRecording]))
    }
    // Chat stays ahead of Read Aloud. The menu and the assistant list put Read Aloud first;
    // this page was already the other way, and Settings is not a row here at all.
    let chat = binding(.chat)
    if chat.isEnabled {
      list.append(
        ShortcutFeature(
          shortcut: chat.displayString,
          name: ShortcutAction.chat.localizedTitle,
          detail: "a full conversation window, with screenshots",
          requirements: []))
    }
    // Selection-based Read Aloud copies via ⌘C (Accessibility) — the feature is omitted
    // from the App Store build entirely (no menu item, no hotkey), so don't advertise it.
    // The Done step keeps `displayString` (compact), unlike the Try-it step.
    if ShortcutAction.readAloud.isInThisBuild, binding(.readAloud).isEnabled {
      list.append(
        ShortcutFeature(
          shortcut: binding(.readAloud).displayString,
          name: ShortcutAction.readAloud.localizedTitle,
          detail: "select text anywhere and hear it spoken",
          requirements: [.accessibility]))
    }
    return list
  }

  var body: some View {
    ScrollView {
    VStack(spacing: 18) {
      Image(systemName: dictationReady ? "checkmark.seal.fill" : "exclamationmark.circle.fill")
        .font(.system(size: 40))
        .foregroundStyle(dictationReady ? .green : .orange)
      VStack(spacing: 8) {
        Text(dictationReady ? ("You're ready" as LocalizedStringKey) : "Almost ready")
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
        .cardChrome()
      }
      .frame(maxWidth: 560, alignment: .leading)

      // Asked last, once the user has seen what the app does: a yes here is an informed one.
      UsageStatisticsToggle()
        .padding(14)
        .frame(maxWidth: 560, alignment: .leading)
        .cardChrome()

      onboardingShortcutRecorder
        .frame(maxWidth: 560)

      Text("You can revisit this tour any time from Welcome Tour… in the menu bar.")
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
    .cardChrome()
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

  /// Green "Ready" when every required permission is granted. Screen Recording alone is not a
  /// red badge: macOS asks the first time that feature is used. Any other missing permission
  /// (the microphone, Accessibility) stays a red, tappable badge that opens System Settings.
  @ViewBuilder
  private func statusBadge(for feature: ShortcutFeature) -> some View {
    if feature.needsTranscriptionModel && !canTranscribe {
      badgeContent(icon: "exclamationmark.circle.fill", color: .orange, text: "Needs a model")
    } else if asksOnFirstUse(feature) {
      Text("Asks on first use")
        .font(.caption)
        .foregroundStyle(.secondary)
    } else if let missing = missingRequirement(for: feature) {
      Button {
        PermissionStatusChecker.requestThenOpenSystemSettings(for: missing)
      } label: {
        badgeContent(
          icon: "xmark.circle.fill", color: .red, text: "Needs \(missing.displayName)")
      }
      .buttonStyle(.plain)
      .pointerCursorOnHover()
      .help("Open System Settings to grant \(missing.displayName) access")
    } else {
      badgeContent(icon: "checkmark.circle.fill", color: .green, text: "Ready")
    }
  }

  /// True when Screen Recording is the only requirement that is not granted.
  private func asksOnFirstUse(_ feature: ShortcutFeature) -> Bool {
    let missing = feature.requirements.filter { status(for: $0) != .granted }
    return missing.count == 1 && missing[0] == .screenRecording
  }

  private func badgeContent(icon: String, color: Color, text: LocalizedStringKey) -> some View {
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

  private var dictationReady: Bool { canTranscribe && micStatus == .granted }

  private var menuBarHint: Text {
    if !canTranscribe && needsOfflineModelDownload {
      return Text("WhisperShortcut lives in your menu bar. It shows ⚠️ until dictation is set up — click it, choose Settings…, and download the selected offline model.")
    }
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
    let model = TranscriptionModel.loadSelected()
    canTranscribe = model.hasRequiredCredential
    needsOfflineModelDownload = model.needsOfflineModelDownload
    hasAnyCredential = ProviderCredentials.anyChatCredentialConfigured
    micStatus = PermissionStatusChecker.status(for: .microphone)
    axStatus = PermissionStatusChecker.status(for: .accessibility)
    screenStatus = PermissionStatusChecker.status(for: .screenRecording)
  }
}
