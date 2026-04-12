import SwiftUI
import AppKit

/// General Settings Tab - API Key and Support & Feedback
struct GeneralSettingsTab: View {
  @ObservedObject var viewModel: SettingsViewModel
  @FocusState.Binding var focusedField: SettingsFocusField?
  @State private var showResetToDefaultsConfirmation = false
  #if SUBSCRIPTION_ENABLED
  @State private var isSignedIn = DefaultGoogleAuthService.shared.isSignedIn()
  #endif

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      #if SUBSCRIPTION_ENABLED
      Text("Choose one: sign in with Google (Whisper Shortcut API) or use an API key. You don't need both.")
        .font(.subheadline)
        .fontWeight(.medium)
        .foregroundColor(.secondary)
        .padding(.bottom, SettingsConstants.internalSectionSpacing)

      GoogleAccountSection()

      SpacedSectionDivider()

      if !isSignedIn {
        GoogleAPIKeySection(viewModel: viewModel, focusedField: $focusedField)

        SpacedSectionDivider()
      }
      #else
      GoogleAPIKeySection(viewModel: viewModel, focusedField: $focusedField)

      SpacedSectionDivider()
      #endif

      XAIAPIKeySection(viewModel: viewModel)

      SpacedSectionDivider()

      KeyboardShortcutsSection(viewModel: viewModel, focusedField: $focusedField)

      SpacedSectionDivider()

      windowBehaviorSection

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
    #if SUBSCRIPTION_ENABLED
    .onReceive(NotificationCenter.default.publisher(for: .googleSignInDidChange)) { _ in
      isSignedIn = DefaultGoogleAuthService.shared.isSignedIn()
    }
    #endif
    .confirmationDialog("Reset app to default?", isPresented: $showResetToDefaultsConfirmation, titleVisibility: .visible) {
      Button("Reset and quit app", role: .destructive) {
        viewModel.resetAllDataAndRestart()
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("This will set all system prompts to default, all settings to default, model selection to default, and delete all user interactions. The API key is preserved.\n\nThe app will close automatically after the reset. You can start it again from the menu bar or Applications. Continue?")
    }
  }

  // MARK: - Window Behavior Section
  @ViewBuilder
  private var windowBehaviorSection: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "Window Behavior",
        subtitle: "Control how the Settings window behaves"
      )

      Toggle(isOn: $viewModel.data.settingsCloseOnFocusLoss) {
        VStack(alignment: .leading, spacing: 2) {
          Text("Close window when losing focus")
            .font(.callout)
          Text("Automatically closes the Settings window when it loses focus.")
            .font(.caption)
            .foregroundColor(.secondary)
        }
      }
      .toggleStyle(.switch)
      .onChange(of: viewModel.data.settingsCloseOnFocusLoss) { _ in
        Task { await viewModel.saveSettings() }
      }
    }
  }
}
