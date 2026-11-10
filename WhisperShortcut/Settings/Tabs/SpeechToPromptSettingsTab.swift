#if !APP_STORE
import ScreenCaptureKit
#endif
import AppKit
import SwiftUI

/// Dictate Prompt Settings Tab — model, screen context, tools and prompt. The shortcut is set in General.
struct SpeechToPromptSettingsTab: View {
  @ObservedObject var viewModel: SettingsViewModel
  @FocusState.Binding var focusedField: SettingsFocusField?
  /// Live Screen Recording status for the caption under Front window as fallback.
  @State private var screenRecordingStatus = PermissionStatusChecker.status(for: .screenRecording)
  @State private var showFieldContextConsent = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Model Selection Section
      modelSection

      // Local server configuration (only when the Local model is selected)
      if viewModel.data.selectedPromptModel.provider == .local {
        SpacedSectionDivider()
        LocalLLMEndpointSection()
      }

      // The same server as Dictate and Chat; shown already set up when either configured it.
      if viewModel.data.selectedPromptModel.provider == .customOpenAI {
        SpacedSectionDivider()
        OwnServerEndpointSection(route: .dictatePrompt)
      }

      SpacedSectionDivider()

      // Screen context for voice Dictate Prompt (same UserDefaults key as before)
      screenshotContextSection

      SpacedSectionDivider()

      QuickPromptsSection()

      SpacedSectionDivider()

      DictatePromptToolsSection()

      SpacedSectionDivider()

      // Dictate Prompt system prompt editor
      SystemPromptSectionEditor(
        title: "System Prompt",
        systemImage: "text.alignleft",
        subtitle: "Instructions sent to the model in Dictate Prompt mode. Edit to customize how voice instructions are applied to text.",
        section: .promptMode,
        defaultContent: AppConstants.defaultPromptModeSystemPrompt
      )

      SpacedSectionDivider()

      // Moved here from the removed Smart Improvement tab: the profile only shapes Dictate Prompt.
      WritingStyleSettingsSection()

      writingStyleModelSection
        .padding(.top, 16)

      SpacedSectionDivider()

      // Usage Instructions Section
      usageInstructionsSection
    }
  }

  
  // MARK: - Model Selection Section
  @ViewBuilder
  private var modelSection: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      promptModelPicker
      speechRecognitionNote
    }
  }

  @ViewBuilder
  private var promptModelPicker: some View {
    PromptModelSelectionView(
      title: "Dictate Prompt Model",
      systemImage: "cpu",
      selectedModel: $viewModel.data.selectedPromptModel,
      recommendedModel: SettingsDefaults.selectedPromptModel,
      subscriptionMode: false,
      onModelChanged: {
        Task {
          await viewModel.saveSettings()
        }
      }
    )
  }

  // MARK: - Writing Style model
  /// The model that drafts the Writing Style profile. Stored under `selectedImprovementModel`, the
  /// key Smart Improvement used before it was removed, so existing choices carry over.
  @ViewBuilder
  private var writingStyleModelSection: some View {
    PromptModelSelectionView(
      title: "Writing Style Model",
      subtitle: "The model that drafts your writing style profile from your messages.",
      showSectionHeader: false,
      selectedModel: $viewModel.data.selectedImprovementModel,
      // A text task: every text-producing chat model, no image-generation models.
      availableModels: PromptModel.textChatModels,
      recommendedModel: SettingsDefaults.selectedImprovementModel,
      subscriptionMode: false,
      onModelChanged: {
        Task {
          await viewModel.saveSettings()
        }
      }
    )
  }

  // MARK: - Speech recognition note
  /// Dictate Prompt has no transcription picker of its own, and the Glossary lives on the Dictate
  /// tab, so users read the Glossary as Dictate-only (the pilot practice did). Text-only prompt
  /// models transcribe the spoken instruction first (`executePromptWithLocal`): local and MLX with
  /// the Dictate model, the own server with its speech model, both with the Glossary. Gemini and
  /// GPT take the audio directly and never see the Glossary.
  @ViewBuilder
  private var speechRecognitionNote: some View {
    let provider = viewModel.data.selectedPromptModel.provider
    let transcribesFirst = [.local, .localMLX, .customOpenAI].contains(provider)
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      Image(systemName: "character.book.closed")
      Group {
        switch provider {
        case .local, .localMLX:
          Text("Speech recognition: \(viewModel.data.selectedTranscriptionModel.displayName) with your Glossary, both set in Dictate.")
        case .customOpenAI:
          Text("Speech recognition uses your server's speech model and your Glossary.")
        default:
          Text("This model hears your voice directly, so the Glossary isn't applied.")
        }
      }
      .fixedSize(horizontal: false, vertical: true)
      if transcribesFirst {
        Button("Edit Glossary") {
          NotificationCenter.default.post(
            name: .openSettingsTab, object: SettingsTab.speechToText.rawValue,
            userInfo: [SettingsAnchor.userInfoKey: SettingsAnchor.glossary])
        }
        .buttonStyle(.link)
        .pointerCursorOnHover()
      }
    }
    .font(.callout)
    .foregroundColor(.secondary)
  }

  // MARK: - Screen context (voice Dictate Prompt)
  @ViewBuilder
  private var screenshotContextSection: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      #if APP_STORE
      SectionHeader(
        title: "Screen Context",
        systemImage: "menubar.dock.rectangle",
        subtitle: "Dictate Prompt reads your selection from a picture of the front window, never the whole screen."
      )
      screenRecordingStatusRow
      #else
      SectionHeader(
        title: "Screen Context",
        systemImage: "menubar.dock.rectangle",
        subtitle: "Dictate Prompt sends what you said and what you selected. The options below add more from your screen, and only once you turn them on."
      )

      HStack(alignment: .center, spacing: 16) {
        Text("Text around the cursor:")
          .font(.body)
          .fontWeight(.medium)
          .frame(width: SettingsConstants.labelWidth, alignment: .leading)

        // Turning it on only asks; the setting changes when the user agrees in the alert.
        // Turning it off takes effect at once.
        Toggle("", isOn: Binding(
          get: { viewModel.data.promptFieldContextEnabled },
          set: { newValue in
            if newValue {
              showFieldContextConsent = true
            } else {
              viewModel.data.promptFieldContextEnabled = false
              Task { await viewModel.saveSettings() }
            }
          }
        ))
          .toggleStyle(SwitchToggleStyle())
          .accessibilityLabel("Text around the cursor")

        Spacer()
      }
      .alert("Send the text around the cursor?", isPresented: $showFieldContextConsent) {
        Button("Cancel", role: .cancel) {}
        Button("Allow") {
          viewModel.data.promptFieldContextEnabled = true
          Task { await viewModel.saveSettings() }
        }
      } message: {
        Text("Each time you use Dictate Prompt, it reads up to 4,000 characters around the cursor in the app you are writing in, plus that app's name, and sends them to your Dictate Prompt model. With a cloud model, that text goes to its provider.\n\nPassword fields and password managers are never read. You can turn this off here at any time.")
      }

      Text("Off unless you agree. When on, the text already in the field you are writing in goes to the model, so the result fits it. Never password fields or password managers.")
        .font(.callout)
        .foregroundColor(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      HStack(alignment: .center, spacing: 16) {
        Text("Front window as fallback:")
          .font(.body)
          .fontWeight(.medium)
          .frame(width: SettingsConstants.labelWidth, alignment: .leading)

        // The permission prompt lives in the binding's setter, not `onChange`: `onChange` also
        // fires when `data` is reloaded programmatically, which must never trigger a system
        // prompt. The setter only runs when the user flips this toggle.
        Toggle("", isOn: Binding(
          get: { viewModel.data.screenshotInPromptMode },
          set: { newValue in
            if newValue {
              Task {
                do {
                  _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                  UserDefaults.standard.set(true, forKey: UserDefaultsKeys.hasRequestedScreenRecording)
                } catch {
                  // The call itself is the request, including when macOS refuses it.
                  UserDefaults.standard.set(true, forKey: UserDefaultsKeys.hasRequestedScreenRecording)
                  DebugLogger.logWarning("SCREENSHOT SETTINGS: Screen recording permission not granted")
                }
              }
            }
            viewModel.data.screenshotInPromptMode = newValue
            Task {
              await viewModel.saveSettings()
            }
          }
        ))
          .toggleStyle(SwitchToggleStyle())
          .accessibilityLabel("Front window as fallback")

        Spacer()
      }

      Text("Adds a picture of the front window, never the whole screen, when the text around the cursor is off, short or unreadable. Never in password fields or password managers.")
        .font(.callout)
        .foregroundColor(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      screenRecordingStatusRow
      #endif
    }
    .onAppear(perform: refreshScreenRecordingStatus)
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      refreshScreenRecordingStatus()
    }
  }

  /// Live Screen Recording status, plus Allow… while it is not granted.
  @ViewBuilder
  private var screenRecordingStatusRow: some View {
    HStack(spacing: 8) {
      PermissionStatusBadge(status: screenRecordingStatus)
      if screenRecordingStatus != .granted {
        Button("Allow…") {
          PermissionStatusChecker.requestThenOpenSystemSettings(for: .screenRecording)
          refreshScreenRecordingStatus()
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            refreshScreenRecordingStatus()
          }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .pointerCursorOnHover()
      }
    }
  }

  private func refreshScreenRecordingStatus() {
    screenRecordingStatus = PermissionStatusChecker.status(for: .screenRecording)
  }

  // MARK: - Usage Instructions
  @ViewBuilder
  private var usageInstructionsSection: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "How to Use",
        systemImage: "questionmark.circle",
        subtitle: nil
      )

      ShortcutHintRow(label: "Shortcut:", shortcut: viewModel.data.togglePrompting)

      VStack(alignment: .leading, spacing: 8) {
        Text("1. Select text")
          .textSelection(.enabled)
        Text("2. Press your configured shortcut")
          .textSelection(.enabled)
        Text("3. Speak your prompt instruction")
          .textSelection(.enabled)
        Text("4. Press the shortcut again to stop")
          .textSelection(.enabled)
        Text("5. Modified text is automatically copied to clipboard")
          .textSelection(.enabled)
      }
      .font(.callout)
      .foregroundColor(.secondary)
    }
  }

}
