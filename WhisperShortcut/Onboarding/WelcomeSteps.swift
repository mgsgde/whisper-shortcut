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
      Text("A quick setup: privacy, a provider API key — or fully offline Whisper, no key needed — and a couple of macOS permissions. Takes about a minute.")
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 540)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

struct WelcomePrivacyStep: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack(spacing: 12) {
        Image(systemName: "lock.shield")
          .font(.system(size: 32))
          .foregroundStyle(.tint)
        VStack(alignment: .leading, spacing: 4) {
          Text(PrivacyCopy.promiseTitle)
            .font(.title2)
            .fontWeight(.semibold)
          Text("What this app does — and doesn't do — with your data.")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
      }
      OpenSourceBanner()

      VStack(alignment: .leading, spacing: 12) {
        ForEach(PrivacyCopy.promiseBullets, id: \.self) { bullet in
          HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
              .foregroundStyle(.green)
            Text(bullet)
              .font(.callout)
              .textSelection(.enabled)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }
      .padding(18)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: 10)
          .fill(Color(nsColor: .controlBackgroundColor))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 10)
          .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
      )

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

      Spacer()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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

struct WelcomeAPIKeysStep: View {
  @Binding var hasGeminiKey: Bool
  @Binding var hasOpenAIKey: Bool
  @Binding var hasXAIKey: Bool
  @Binding var offlineReady: Bool

  private var canContinue: Bool {
    hasGeminiKey || hasOpenAIKey || hasXAIKey || offlineReady
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Add a key — or start offline")
          .font(.title2)
          .fontWeight(.semibold)
        Text("Any single provider key unlocks every feature and is stored in the macOS Keychain. Or skip the key entirely and dictate fully offline with local Whisper.")
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      ScrollView(showsIndicators: true) {
        VStack(spacing: 14) {
          OnboardingAPIKeyRow(
            providerName: "Google Gemini",
            placeholder: "AIza…",
            linkTitle: "aistudio.google.com/api-keys",
            linkURL: URL(string: "https://aistudio.google.com/api-keys")!,
            isConfigured: $hasGeminiKey,
            load: { KeychainManager.shared.getGoogleAPIKey() ?? "" },
            save: { KeychainManager.shared.saveGoogleAPIKey($0) },
            recommended: true
          )
          OnboardingAPIKeyRow(
            providerName: "OpenAI",
            placeholder: "sk-…",
            linkTitle: "platform.openai.com/api-keys",
            linkURL: URL(string: "https://platform.openai.com/api-keys")!,
            isConfigured: $hasOpenAIKey,
            load: { KeychainManager.shared.getOpenAIAPIKey() ?? "" },
            save: { KeychainManager.shared.saveOpenAIAPIKey($0) },
            recommended: false
          )
          OnboardingAPIKeyRow(
            providerName: "xAI (Grok)",
            placeholder: "xai-…",
            linkTitle: "console.x.ai",
            linkURL: URL(string: "https://console.x.ai")!,
            description: "Dictate Prompt is not available with Grok.",
            isConfigured: $hasXAIKey,
            load: { KeychainManager.shared.getXAIAPIKey() ?? "" },
            save: { KeychainManager.shared.saveXAIAPIKey($0) },
            recommended: false
          )
        }
        .padding(.bottom, 8)
      }

      // The no-key path stays outside the scroll area so "or start offline" —
      // promised in the headline — is always visible without scrolling.
      HStack(spacing: 10) {
        VStack { Divider() }
        Text("or")
          .font(.caption)
          .foregroundStyle(.secondary)
        VStack { Divider() }
      }
      .padding(.vertical, 2)

      OnboardingOfflineRow(offlineReady: $offlineReady)

      if canContinue {
        Label("Ready to continue.", systemImage: "checkmark.circle.fill")
          .font(.caption)
          .foregroundStyle(.green)
      } else {
        Label("Add a key or download offline Whisper to continue.", systemImage: "exclamationmark.circle")
          .font(.caption)
          .foregroundStyle(.orange)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
}

/// Lets a new user finish setup with no provider key by downloading a local
/// Whisper model. Dictation then runs fully offline; cloud-only features
/// (Dictate Prompt, Chat, Read Aloud) still need a key added later in Settings.
struct OnboardingOfflineRow: View {
  @Binding var offlineReady: Bool
  @ObservedObject private var modelManager = ModelManager.shared
  @State private var downloadError: String?

  private let modelType: OfflineModelType = .whisperBase

  private var isDownloading: Bool { modelManager.downloadingModels.contains(modelType) }
  private var isAvailable: Bool { modelManager.isModelAvailable(modelType) }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        Image(systemName: "laptopcomputer.and.arrow.down")
          .foregroundStyle(.tint)
        Text("Run offline with local Whisper")
          .font(.callout)
          .fontWeight(.semibold)
        Spacer()
      }

      Text("No key required — audio never leaves your Mac. Dictation works offline; Dictate Prompt, Chat and Read Aloud still need a provider key you can add later in Settings.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      if isAvailable {
        Label("Whisper Base ready — you can continue.", systemImage: "checkmark.seal.fill")
          .font(.caption)
          .foregroundStyle(.green)
      } else if isDownloading {
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text("Downloading Whisper Base…")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      } else {
        Button(action: download) {
          Label("Download Whisper Base (≈140 MB)", systemImage: "arrow.down.circle")
            .font(.callout)
        }
        .buttonStyle(.bordered)
        .pointerCursorOnHover()
      }

      if let downloadError {
        Label(downloadError, systemImage: "exclamationmark.triangle.fill")
          .font(.caption2)
          .foregroundStyle(.red)
      }
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
    .onAppear(perform: syncReady)
  }

  private func download() {
    downloadError = nil
    Task {
      do {
        try await ModelManager.shared.downloadModel(modelType)
        await MainActor.run { syncReady() }
      } catch {
        await MainActor.run {
          downloadError = "Download failed. Check your connection and try again."
        }
        DebugLogger.logError("ONBOARDING: Whisper Base download failed: \(error.localizedDescription)")
      }
    }
  }

  /// Marks offline setup as ready and — only when no cloud key is configured —
  /// makes the offline model the active transcription backend so the app works
  /// immediately. A cloud user's higher-quality default is left untouched.
  private func syncReady() {
    guard modelManager.isModelAvailable(modelType) else { return }
    offlineReady = true
    let hasCloudKey = KeychainManager.shared.hasValidGoogleAPIKey()
      || KeychainManager.shared.hasValidOpenAIAPIKey()
      || KeychainManager.shared.hasValidXAIAPIKey()
    if !hasCloudKey {
      UserDefaults.standard.set(
        TranscriptionModel.whisperBase.rawValue,
        forKey: UserDefaultsKeys.selectedTranscriptionModel)
      DebugLogger.log("ONBOARDING: offline Whisper Base ready; set as default transcription model")
    }
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
        .help(isVisible ? "Hide key" : "Show key")

        Button("Save") {
          let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
          guard !trimmed.isEmpty else { return }
          if save(trimmed) {
            saveError = nil
            isConfigured = true
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

struct WelcomePermissionsStep: View {
  @Binding var micStatus: PermissionStatus

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 4) {
        Text("macOS permissions")
          .font(.title2)
          .fontWeight(.semibold)
        Text("Microphone is required for dictation. Screen Recording is optional — for screenshots in chat and Dictate Prompt. You can change these any time in Settings → Permissions.")
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      ScrollView {
        // The same overview used in Settings → Permissions and on permission errors —
        // one component, one behavior. Accessibility is omitted here on purpose
        // (App Store Guideline 2.4.5: don't imply the app needs it up front).
        PermissionsOverview(mode: .onboarding, onMicStatusChange: { micStatus = $0 })
          .padding(.bottom, 8)
      }

      if micStatus == .granted {
        Label("Ready to continue.", systemImage: "checkmark.circle.fill")
          .font(.caption)
          .foregroundStyle(.green)
      } else {
        Label("Grant microphone access to continue.", systemImage: "exclamationmark.circle")
          .font(.caption)
          .foregroundStyle(.orange)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
}

struct OnboardingPermissionRow<Actions: View>: View {
  let icon: String
  let title: String
  let required: Bool
  let description: String
  let status: PermissionStatus
  let kind: PermissionKind
  @ViewBuilder let actions: () -> Actions

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        Image(systemName: icon)
          .font(.system(size: 18))
          .foregroundStyle(.tint)
          .frame(width: 26)
        Text(title)
          .font(.callout)
          .fontWeight(.semibold)
        requirementTag
        Spacer()
        WelcomePermissionBadge(status: status)
      }

      Text(description)
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      HStack(spacing: 8) {
        actions()
        settingsButton
      }
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

  /// Always visible so the user can review or change the permission in System
  /// Settings at any time — prominent when the permission was denied, since
  /// System Settings is then the only way to grant it.
  @ViewBuilder
  private var settingsButton: some View {
    let button = Button {
      PermissionStatusChecker.openSystemSettings(for: kind)
    } label: {
      Label("Open System Settings", systemImage: "arrow.up.right.square")
        .font(.callout)
    }
    if status == .denied {
      button.buttonStyle(.borderedProminent).pointerCursorOnHover()
    } else {
      button.buttonStyle(.bordered).pointerCursorOnHover()
    }
  }

  private var requirementTag: some View {
    Text(required ? "Required" : "Optional")
      .font(.caption2)
      .fontWeight(.medium)
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background((required ? Color.accentColor : Color.gray).opacity(0.15))
      .foregroundColor(required ? .accentColor : .secondary)
      .clipShape(Capsule())
  }
}

/// Optional onboarding step that introduces auto-paste and its Accessibility requirement.
/// Default off — the toggle is the opt-in, and only flipping it on requests Accessibility
/// (App Store Guideline 2.4.5: never imply the app needs Accessibility up front). Never gates
/// Continue. Mirrors `WelcomeSmartImprovementStep`'s structure for visual consistency.
struct WelcomeAutoPasteStep: View {
  @Binding var autoPasteEnabled: Bool

  /// Live Accessibility status so the user sees, on this very page, whether the grant succeeded
  /// after enabling the toggle. Refreshed on appear and whenever the app reactivates (e.g. after
  /// returning from the System Settings prompt).
  @State private var axStatus: PermissionStatus = PermissionStatusChecker.status(for: .accessibility)

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      HStack(spacing: 12) {
        Image(systemName: "doc.on.clipboard")
          .font(.system(size: 32))
          .foregroundStyle(.tint)
        VStack(alignment: .leading, spacing: 4) {
          Text("Auto-paste")
            .font(.title2)
            .fontWeight(.semibold)
          Text("Optional — insert dictated text right where you're typing.")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
      }

      Text("With auto-paste on, transcriptions and Dictate Prompt results appear at your cursor automatically (a simulated ⌘V) instead of just on the clipboard. macOS allows that only with Accessibility permission, so enabling it asks for that now. Dictation works fine without it — your text is always copied so you can paste manually.")
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      VStack(alignment: .leading, spacing: 12) {
        Toggle(isOn: $autoPasteEnabled) {
          VStack(alignment: .leading, spacing: 2) {
            Text("Enable auto-paste")
              .font(.callout)
              .fontWeight(.medium)
            Text("You can change this any time in Settings → General.")
              .font(.caption)
              .foregroundStyle(.secondary)
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
          Divider()
          HStack(spacing: 8) {
            WelcomePermissionBadge(status: axStatus)
            Text(accessibilityHint)
              .font(.caption)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            // Always offered (even when granted) so the user can review or change the grant
            // in System Settings — consistent with the permissions step's per-row button.
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

      Spacer()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .onAppear(perform: refreshStatus)
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      refreshStatus()
    }
  }

  private var accessibilityHint: String {
    switch axStatus {
    case .granted: return "Accessibility granted — auto-paste is ready."
    default: return "Accessibility needed. Enable WhisperShortcut in System Settings, then return here."
    }
  }

  private func refreshStatus() {
    axStatus = PermissionStatusChecker.status(for: .accessibility)
  }
}

struct WelcomeSmartImprovementStep: View {
  @Binding var saveUsageData: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      HStack(spacing: 12) {
        Image(systemName: "sparkles")
          .font(.system(size: 32))
          .foregroundStyle(.tint)
        VStack(alignment: .leading, spacing: 4) {
          Text("Smart Improvement")
            .font(.title2)
            .fontWeight(.semibold)
          Text("Optional — refines your prompts over time.")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
      }

      Text("To do this, WhisperShortcut stores your interaction logs (dictation, Dictate Prompt, and chat) locally, and periodically sends them to your configured AI provider to suggest better prompts. Nothing goes to us or any third party — only to the provider you already use.")
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      Toggle(isOn: $saveUsageData) {
        VStack(alignment: .leading, spacing: 2) {
          Text("Save usage data for Smart Improvement")
            .font(.callout)
            .fontWeight(.medium)
          Text("You can change this any time in Settings → General.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .toggleStyle(.switch)
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

      Spacer()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
    var id: String { name }
  }

  private let shortcuts = ShortcutConfigManager.shared.loadConfiguration()

  /// Live permission state so each row's green/red status is accurate, and flips the moment the
  /// user grants a permission and returns (didBecomeActive) without leaving onboarding.
  @State private var micStatus = PermissionStatusChecker.status(for: .microphone)
  @State private var axStatus = PermissionStatusChecker.status(for: .accessibility)
  @State private var screenStatus = PermissionStatusChecker.status(for: .screenRecording)

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
          requirements: [.microphone]))
    }
    if shortcuts.startPrompting.isEnabled {
      list.append(
        ShortcutFeature(
          shortcut: shortcuts.startPrompting.displayString,
          name: "Dictate Prompt",
          detail: "select text, speak an instruction — the selection is rewritten in place",
          requirements: [.microphone, .accessibility]))
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
    if shortcuts.readAloud.isEnabled {
      list.append(
        ShortcutFeature(
          shortcut: shortcuts.readAloud.displayString,
          name: "Read Aloud",
          detail: "select text anywhere and hear it spoken",
          requirements: [.accessibility]))
    }
    return list
  }

  var body: some View {
    VStack(spacing: 18) {
      Image(systemName: "checkmark.seal.fill")
        .font(.system(size: 40))
        .foregroundStyle(.green)
      VStack(spacing: 8) {
        Text("You're ready")
          .font(.largeTitle)
          .fontWeight(.semibold)
        Text("Here's everything you can do. Green is ready to use; red still needs a permission.")
          .font(.title3)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
      }

      VStack(spacing: 0) {
        ForEach(Array(features.enumerated()), id: \.element.id) { index, feature in
          if index > 0 { Divider() }
          shortcutRow(feature)
        }
      }
      .frame(maxWidth: 560, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: 10)
          .fill(Color(nsColor: .controlBackgroundColor))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 10)
          .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
      )

      VStack(spacing: 6) {
        // The app has no Dock icon or main window, so tell first-time users where it lives.
        Text("WhisperShortcut lives in your menu bar — look for the \(Image(systemName: "mic.fill")) icon at the top of your screen.")
          .font(.callout)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
        Text("You can revisit this tour any time from Settings → General.")
          .font(.caption)
          .foregroundStyle(.tertiary)
          .multilineTextAlignment(.center)
      }
      .frame(maxWidth: 560)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .onAppear(perform: refreshStatuses)
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      refreshStatuses()
    }
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
    if let missing = missingRequirement(for: feature) {
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

  private func refreshStatuses() {
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
