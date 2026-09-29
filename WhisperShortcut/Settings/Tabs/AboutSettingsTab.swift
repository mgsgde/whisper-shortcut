import SwiftUI

/// About Settings Tab — privacy promise, keyboard-shortcut overview, reset-to-defaults, and support.
struct AboutSettingsTab: View {
  @ObservedObject var viewModel: SettingsViewModel
  @State private var showResetToDefaultsConfirmation = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      WhatsNewSection()

      welcomeTourSection

      SpacedSectionDivider()

      PrivacySection()

      SpacedSectionDivider()

      ShortcutsOverviewSection(viewModel: viewModel)

      SpacedSectionDivider()

      ResetSection(viewModel: viewModel, showResetToDefaultsConfirmation: $showResetToDefaultsConfirmation)

      SpacedSectionDivider()

      SupportFeedbackSection(viewModel: viewModel)

      SpacedSectionDivider()

      acknowledgementsSection
    }
    .confirmationDialog("Reset app to default?", isPresented: $showResetToDefaultsConfirmation, titleVisibility: .visible) {
      Button("Reset and quit app", role: .destructive) {
        viewModel.resetAllDataAndRestart()
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("This will delete all settings, system prompts, model selection, chat sessions, meeting transcripts, and interaction data. API keys are preserved.\n\nThe app will close automatically after the reset. You can start it again from the menu bar or Applications. Continue?")
    }
  }

  /// Credits the licences require. The Parakeet weights are CC BY 4.0, which asks for attribution
  /// wherever they are used — this is where a user of the app can see it.
  private var acknowledgementsSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Acknowledgements")
        .font(.callout)
        .fontWeight(.medium)
      Text("Offline dictation: Parakeet Ultra by Moondream, a retraining of NVIDIA Parakeet TDT 0.6B v3 — both licensed CC BY 4.0 — run through FluidAudio (Apache 2.0) by FluidInference. Whisper models by OpenAI (MIT), run through WhisperKit (MIT) by Argmax.")
        .font(.caption)
        .foregroundColor(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
      HStack(spacing: 12) {
        Link("Parakeet Ultra", destination: URL(string: "https://huggingface.co/moondream/parakeet-ultra")!)
        Link("NVIDIA Parakeet", destination: URL(string: "https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3")!)
        Link("FluidAudio", destination: URL(string: "https://github.com/FluidInference/FluidAudio")!)
        Link("CC BY 4.0", destination: URL(string: "https://creativecommons.org/licenses/by/4.0/")!)
      }
      .font(.caption)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder
  private var welcomeTourSection: some View {
    HStack(spacing: 12) {
      Image(systemName: "sparkles")
        .font(.title2)
        .foregroundColor(.accentColor)

      VStack(alignment: .leading, spacing: 2) {
        Text("Welcome Tour")
          .font(.callout)
          .fontWeight(.medium)
        Text("Replay the guided walkthrough of WhisperShortcut's features.")
          .font(.caption)
          .foregroundColor(.secondary)
      }

      Spacer(minLength: 12)

      Button {
        SettingsManager.shared.closeSettings()
        WelcomeWindowController.shared.show()
      } label: {
        Label("Show Tour", systemImage: "play.fill")
          .font(.callout)
      }
      .buttonStyle(.borderedProminent)
      .pointerCursorOnHover()
    }
    .padding(SettingsConstants.cardPadding)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: SettingsConstants.cornerRadius)
        .fill(Color(nsColor: .controlBackgroundColor))
    )
    .overlay(
      RoundedRectangle(cornerRadius: SettingsConstants.cornerRadius)
        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
    )
  }
}
