import SwiftUI

/// About Settings Tab — keyboard-shortcut overview, reset-to-defaults, and support/feedback.
/// Split out of the General tab so destructive reset and "about" info live in their own place.
struct AboutSettingsTab: View {
  @ObservedObject var viewModel: SettingsViewModel
  @State private var showResetToDefaultsConfirmation = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
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
}
