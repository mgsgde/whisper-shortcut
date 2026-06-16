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
      Text("A quick setup: privacy, an API key for your preferred AI provider, and a couple of macOS permissions. Takes about a minute.")
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

      HStack(spacing: 12) {
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

        Button {
          if let url = URL(string: AppConstants.githubRepositoryURL) {
            NSWorkspace.shared.open(url)
          }
        } label: {
          Label("View on GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
            .font(.callout)
        }
        .buttonStyle(.bordered)
        .pointerCursorOnHover()
      }

      Spacer()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
}

struct WelcomeAPIKeysStep: View {
  @Binding var hasGeminiKey: Bool
  @Binding var hasOpenAIKey: Bool
  @Binding var hasXAIKey: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Add at least one API key")
          .font(.title2)
          .fontWeight(.semibold)
        Text("You need a key from at least one AI provider — any single key unlocks every feature. Keys are stored in the macOS Keychain and only sent in requests to that provider.")
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      ScrollView {
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

      if !(hasGeminiKey || hasOpenAIKey || hasXAIKey) {
        Label("Add at least one key to continue.", systemImage: "exclamationmark.circle")
          .font(.caption)
          .foregroundStyle(.orange)
      } else {
        Label("Ready to continue.", systemImage: "checkmark.circle.fill")
          .font(.caption)
          .foregroundStyle(.green)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
  @Binding var axStatus: PermissionStatus
  @Binding var screenStatus: PermissionStatus

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 4) {
        Text("macOS permissions")
          .font(.title2)
          .fontWeight(.semibold)
        Text("Microphone access is required for dictation. Screen Recording is optional — enable it now or any time later in Settings → Privacy & Permissions.")
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      ScrollView {
        VStack(spacing: 14) {
          OnboardingPermissionRow(
            icon: "mic.fill",
            title: "Microphone",
            required: true,
            description: "Records what you say. Audio is sent only to the provider you chose, then deleted.",
            status: micStatus,
            kind: .microphone
          ) {
            if micStatus == .notDetermined {
              Button {
                PermissionStatusChecker.requestMicrophoneAccess { granted in
                  micStatus = granted ? .granted : .denied
                }
              } label: {
                Label("Continue", systemImage: "mic")
                  .font(.callout)
              }
              .buttonStyle(.borderedProminent)
              .pointerCursorOnHover()
            }
            if micStatus == .denied {
              Text("Enable WhisperShortcut under Privacy → Microphone.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
          }

          // Accessibility is intentionally NOT requested during onboarding. It is
          // only needed for the optional auto-paste feature (⌘V keystroke), which is
          // off by default. Users can enable it later in Settings → Privacy &
          // Permissions. Requiring it up front would imply the app needs Accessibility
          // for core functionality, which it does not (App Store Guideline 2.4.5).

          OnboardingPermissionRow(
            icon: "rectangle.inset.filled.and.person.filled",
            title: "Screen Recording",
            required: false,
            description: "Enables screenshot attachments in chat and screen context in Dictate Prompt. You may need to relaunch the app after granting. Everything except screenshot attachments works without it.",
            status: screenStatus,
            kind: .screenRecording
          ) {
            if screenStatus != .granted {
              Button {
                let granted = PermissionStatusChecker.requestScreenRecordingAccess()
                screenStatus = PermissionStatusChecker.status(for: .screenRecording)
                if !granted {
                  // CGRequestScreenCaptureAccess() only shows the native consent prompt on
                  // the very first request. Once macOS has any record of a decision it
                  // returns silently with no dialog, so the click feels dead (especially
                  // when macOS already registered the app from an earlier launch). Re-check
                  // shortly after and deep-link into System Settings if we still aren't
                  // granted, so the button always produces a visible next step.
                  DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    let current = PermissionStatusChecker.status(for: .screenRecording)
                    screenStatus = current
                    if current != .granted {
                      PermissionStatusChecker.openSystemSettings(for: .screenRecording)
                    }
                  }
                }
              } label: {
                Label("Grant Screen Recording", systemImage: "rectangle.inset.filled.and.person.filled")
                  .font(.callout)
              }
              .buttonStyle(.bordered)
              .pointerCursorOnHover()
            }
          }
        }
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
  private struct FeatureHint: Identifiable {
    let shortcut: String
    let name: String
    let detail: String
    var id: String { name }
  }

  private let shortcuts = ShortcutConfigManager.shared.loadConfiguration()

  private var dictationShortcut: String {
    shortcuts.startRecording.displayStringWithSeparator
  }

  /// Dictation is the hero CTA above; these are the secondary features worth
  /// discovering. Disabled shortcuts are hidden rather than shown as "Disabled".
  private var moreFeatures: [FeatureHint] {
    var hints: [FeatureHint] = []
    if shortcuts.startPrompting.isEnabled {
      hints.append(
        FeatureHint(
          shortcut: shortcuts.startPrompting.displayString,
          name: "Dictate Prompt",
          detail: "select text, speak an instruction — the selection is rewritten in place"))
    }
    if shortcuts.openChat.isEnabled {
      hints.append(
        FeatureHint(
          shortcut: shortcuts.openChat.displayString,
          name: "Chat",
          detail: "a full conversation window, with screenshots"))
    }
    if shortcuts.readAloud.isEnabled {
      hints.append(
        FeatureHint(
          shortcut: shortcuts.readAloud.displayString,
          name: "Read Aloud",
          detail: "select text anywhere and hear it spoken"))
    }
    return hints
  }

  var body: some View {
    VStack(spacing: 24) {
      Image(systemName: "checkmark.seal.fill")
        .font(.system(size: 64))
        .foregroundStyle(.green)
      VStack(spacing: 10) {
        Text("You're ready")
          .font(.largeTitle)
          .fontWeight(.semibold)
        Text("Press \(dictationShortcut) and start speaking.")
          .font(.title3)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
      }

      if !moreFeatures.isEmpty {
        VStack(alignment: .leading, spacing: 10) {
          Text("Also try:")
            .font(.callout)
            .fontWeight(.semibold)
          ForEach(moreFeatures) { hint in
            HStack(alignment: .firstTextBaseline, spacing: 10) {
              Text(hint.shortcut)
                .font(.system(.callout, design: .monospaced))
                .frame(minWidth: 44, alignment: .leading)
              Text("\(Text(hint.name).fontWeight(.medium)) — \(hint.detail)")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
          }
        }
        .padding(16)
        .frame(maxWidth: 540, alignment: .leading)
        .background(
          RoundedRectangle(cornerRadius: 10)
            .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
          RoundedRectangle(cornerRadius: 10)
            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
      }

      Text("You can revisit this tour any time from Settings → Privacy & Permissions.")
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 540)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
