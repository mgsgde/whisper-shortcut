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
