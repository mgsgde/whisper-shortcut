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
        Text("You need a key from at least one AI provider. Keys are stored in the macOS Keychain and only sent in requests to that provider.")
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
            description: "Used for transcription, Dictate Prompt, and chat with Gemini models.",
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
            description: "Used for chat and Dictate Prompt with GPT models.",
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
            description: "Used for chat with Grok models.",
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
  let description: String
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

      Text(description)
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

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

struct WelcomeMicStep: View {
  @Binding var status: PermissionStatus

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      HStack(spacing: 12) {
        Image(systemName: "mic.fill")
          .font(.system(size: 32))
          .foregroundStyle(.tint)
        VStack(alignment: .leading, spacing: 4) {
          Text("Microphone access")
            .font(.title2)
            .fontWeight(.semibold)
          Text("Required to record what you say.")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        Spacer()
        WelcomePermissionBadge(status: status)
      }

      Text("Audio is sent only to the provider you chose, then deleted. Click below — macOS will ask you to allow microphone access.")
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      HStack(spacing: 12) {
        if status == .notDetermined {
          Button {
            PermissionStatusChecker.requestMicrophoneAccess { granted in
              status = granted ? .granted : .denied
            }
          } label: {
            Label("Grant Microphone Access", systemImage: "mic")
              .font(.callout)
          }
          .buttonStyle(.borderedProminent)
          .pointerCursorOnHover()
        }
        if status == .denied {
          Button {
            PermissionStatusChecker.openSystemSettings(for: .microphone)
          } label: {
            Label("Open System Settings", systemImage: "arrow.up.right.square")
              .font(.callout)
          }
          .buttonStyle(.borderedProminent)
          .pointerCursorOnHover()
          Text("If denied previously, enable WhisperShortcut under Privacy → Microphone.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        if status == .granted {
          Label("Microphone access granted.", systemImage: "checkmark.circle.fill")
            .foregroundStyle(.green)
        }
      }
      Spacer()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
}

struct WelcomeAccessibilityStep: View {
  @Binding var status: PermissionStatus

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      HStack(spacing: 12) {
        Image(systemName: "accessibility")
          .font(.system(size: 32))
          .foregroundStyle(.tint)
        VStack(alignment: .leading, spacing: 4) {
          Text("Accessibility access")
            .font(.title2)
            .fontWeight(.semibold)
          Text("Optional — only needed for auto-paste into other apps.")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        Spacer()
        WelcomePermissionBadge(status: status)
      }

      Text("With Accessibility enabled, WhisperShortcut can paste your transcribed text into whatever app you're using. Grant it below — macOS pre-adds WhisperShortcut to the list, so you only have to flip the switch under Privacy → Accessibility.")
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      HStack(spacing: 12) {
        if status != .granted {
          Button {
            AccessibilityPermissionManager.requestAccessibilityPermission()
          } label: {
            Label("Grant Accessibility", systemImage: "accessibility")
              .font(.callout)
          }
          .buttonStyle(.borderedProminent)
          .pointerCursorOnHover()
          Button {
            PermissionStatusChecker.openSystemSettings(for: .accessibility)
          } label: {
            Label("Open System Settings", systemImage: "arrow.up.right.square")
              .font(.callout)
          }
          .buttonStyle(.bordered)
          .pointerCursorOnHover()
        } else {
          Label("Accessibility access granted.", systemImage: "checkmark.circle.fill")
            .foregroundStyle(.green)
        }
      }

      Text("You can skip this — dictation still works, you just won't get automatic paste-into-app.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.top, 4)

      Spacer()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
}

struct WelcomeScreenRecordingStep: View {
  @Binding var status: PermissionStatus

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      HStack(spacing: 12) {
        Image(systemName: "rectangle.inset.filled.and.person.filled")
          .font(.system(size: 32))
          .foregroundStyle(.tint)
        VStack(alignment: .leading, spacing: 4) {
          Text("Screen Recording access")
            .font(.title2)
            .fontWeight(.semibold)
          Text("Optional — only needed to attach screenshots to chat.")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        Spacer()
        WelcomePermissionBadge(status: status)
      }

      Text("With Screen Recording enabled, you can capture your screen and attach it to a chat message. macOS asks for this the first time you grant it — you may need to relaunch the app afterwards.")
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      HStack(spacing: 12) {
        if status == .granted {
          Label("Screen Recording access granted.", systemImage: "checkmark.circle.fill")
            .foregroundStyle(.green)
        } else {
          Button {
            PermissionStatusChecker.requestScreenRecordingAccess()
            status = PermissionStatusChecker.status(for: .screenRecording)
          } label: {
            Label("Grant Screen Recording", systemImage: "rectangle.inset.filled.and.person.filled")
              .font(.callout)
          }
          .buttonStyle(.borderedProminent)
          .pointerCursorOnHover()
          Button {
            PermissionStatusChecker.openSystemSettings(for: .screenRecording)
          } label: {
            Label("Open System Settings", systemImage: "arrow.up.right.square")
              .font(.callout)
          }
          .buttonStyle(.bordered)
          .pointerCursorOnHover()
        }
      }

      Text("You can skip this — everything except screenshot attachments works without it.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.top, 4)

      Spacer()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
  private var dictationShortcut: String {
    ShortcutConfigManager.shared.loadConfiguration().startRecording.displayStringWithSeparator
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
