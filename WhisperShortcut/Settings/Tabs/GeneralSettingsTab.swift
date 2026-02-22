import SwiftUI
import AppKit

/// General Settings Tab - API Key and Support & Feedback
struct GeneralSettingsTab: View {
  @ObservedObject var viewModel: SettingsViewModel
  @FocusState.Binding var focusedField: SettingsFocusField?
  @State private var showResetToDefaultsConfirmation = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      GoogleAPIKeySection(viewModel: viewModel, focusedField: $focusedField)

      SpacedSectionDivider()

      GoogleAccountSection()

      SpacedSectionDivider()

      BalanceSection(viewModel: viewModel)

      SpacedSectionDivider()

      ProxyAPISection(viewModel: viewModel)

      SpacedSectionDivider()

      KeyboardShortcutsSection(viewModel: viewModel, focusedField: $focusedField)

      SpacedSectionDivider()

      LaunchAtLoginSection(viewModel: viewModel)

      SpacedSectionDivider()

      PopupNotificationsSection(viewModel: viewModel)

      SpacedSectionDivider()

      RecordingSafeguardsSection(viewModel: viewModel)

      SpacedSectionDivider()

      ClipboardBehaviorSection(viewModel: viewModel)

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
      Text("This will set all system prompts to default, all settings to default, model selection to default, and delete all user interactions. The API key is preserved.\n\nThe app will close automatically after the reset. You can start it again from the menu bar or Applications. Continue?")
    }
  }
}
