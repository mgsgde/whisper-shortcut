import ScreenCaptureKit
import SwiftUI

/// Dictate Prompt Settings Tab — model, screen context, tools and prompt. The shortcut is set in General.
struct SpeechToPromptSettingsTab: View {
  @ObservedObject var viewModel: SettingsViewModel
  @FocusState.Binding var focusedField: SettingsFocusField?

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
      SectionHeader(
        title: "Screen Context",
        systemImage: "menubar.dock.rectangle",
        subtitle: "Send a screenshot of your screen with each spoken Dictate Prompt, so the model sees what you see."
      )

      HStack(alignment: .center, spacing: 16) {
        Text("Include screenshot:")
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
                } catch {
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
          .accessibilityLabel("Screenshot context")

        Spacer()
      }

      Text("Needs Screen Recording permission.")
        .font(.callout)
        .foregroundColor(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
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
