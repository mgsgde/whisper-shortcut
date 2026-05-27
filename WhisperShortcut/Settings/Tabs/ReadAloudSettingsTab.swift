import SwiftUI

/// Read Aloud Settings Tab — keyboard shortcut, smart-rewrite toggle, and rewrite prompt editor.
struct ReadAloudSettingsTab: View {
  @ObservedObject var viewModel: SettingsViewModel
  @FocusState.Binding var focusedField: SettingsFocusField?

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      keyboardShortcutSection

      SpacedSectionDivider()

      playbackSpeedSection

      SpacedSectionDivider()

      smartRewriteSection

      SpacedSectionDivider()

      SystemPromptSectionEditor(
        title: "Rewrite prompt",
        subtitle: "Instructions sent to Gemini when Smart Rewriting is enabled. The model receives the selected text and returns a speech-friendly version.",
        section: .readAloudRewrite,
        defaultContent: AppConstants.defaultReadAloudRewritePrompt
      )

      SpacedSectionDivider()

      usageSection
    }
  }

  // MARK: - Keyboard Shortcut Section
  @ViewBuilder
  private var keyboardShortcutSection: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "⌨️ Keyboard Shortcut",
        subtitle: "Select text, then press the shortcut to have it read aloud"
      )

      ShortcutRecorderRow(
        label: "Read Aloud:",
        shortcut: $viewModel.data.readAloud,
        defaultShortcut: ShortcutConfig.default.readAloud,
        focusedField: .readAloudShortcut,
        currentFocus: $focusedField,
        onChanged: {
          Task {
            await viewModel.saveSettings()
          }
        },
        findConflict: viewModel.findShortcutConflict,
        clearShortcut: viewModel.clearShortcut
      )
    }
  }

  // MARK: - Playback Speed Section
  @ViewBuilder
  private var playbackSpeedSection: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "⏩ Playback Speed",
        subtitle: "How fast the audio is played back. Pitch is preserved."
      )

      HStack(alignment: .center, spacing: 16) {
        Text("Speed:")
          .font(.body)
          .fontWeight(.medium)
          .frame(width: SettingsConstants.labelWidth, alignment: .leading)

        Picker("", selection: $viewModel.data.readAloudSpeed) {
          ForEach(ReadAloudSpeed.allCases, id: \.rawValue) { speed in
            HStack {
              Text(speed.displayName)
              if speed.isRecommended {
                Text("(Recommended)")
                  .font(.caption)
                  .foregroundColor(.secondary)
              }
            }
            .tag(speed)
          }
        }
        .pickerStyle(MenuPickerStyle())
        .frame(width: 200)
        .onChange(of: viewModel.data.readAloudSpeed) { _ in
          Task { await viewModel.saveSettings() }
        }

        Spacer()
      }
    }
  }

  // MARK: - Smart Rewrite Section
  @ViewBuilder
  private var smartRewriteSection: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "🧠 Smart Rewriting",
        subtitle: "Let Gemini decide whether the selection should be read verbatim or rewritten for natural speech"
      )

      Toggle(isOn: $viewModel.data.readAloudSmartRewriteEnabled) {
        VStack(alignment: .leading, spacing: 2) {
          Text("Rewrite text for speech before reading aloud")
            .font(.callout)
          Text("When on, code, markdown, tables and other non-prose content are summarized into a speakable form. Plain prose is passed through unchanged. Adds one short Gemini call before TTS.")
            .font(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .toggleStyle(.switch)
      .onChange(of: viewModel.data.readAloudSmartRewriteEnabled) { _ in
        Task { await viewModel.saveSettings() }
      }
    }
  }

  // MARK: - Usage Section
  @ViewBuilder
  private var usageSection: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "📋 How to Use",
        subtitle: "Read selected text aloud anywhere on your Mac"
      )

      VStack(alignment: .leading, spacing: 8) {
        Text("Highlight any text with the mouse or keyboard, then press the Read Aloud shortcut.")
          .textSelection(.enabled)
        Text("Press the shortcut again to stop playback.")
          .textSelection(.enabled)
        Text("Requires a Gemini API key (Settings → General) or sign in with Google.")
          .textSelection(.enabled)
      }
      .font(.callout)
      .foregroundColor(.secondary)
    }
  }
}
