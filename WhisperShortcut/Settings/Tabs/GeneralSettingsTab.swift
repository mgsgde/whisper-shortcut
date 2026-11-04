import SwiftUI
import AppKit

/// General Settings Tab - shortcuts, app behavior, updates, and Data & Reset. API keys live in
/// Accounts, Smart Improvement in its own tab; About holds information only.
struct GeneralSettingsTab: View {
  @ObservedObject var viewModel: SettingsViewModel
  @FocusState.Binding var focusedField: SettingsFocusField?
  @State private var showResetToDefaultsConfirmation = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      KeyboardShortcutsSection(viewModel: viewModel, focusedField: $focusedField)

      SpacedSectionDivider()

      LaunchAtLoginSection(viewModel: viewModel)

      SpacedSectionDivider()

      #if !APP_STORE && canImport(Sparkle)
      UpdatesSection()

      SpacedSectionDivider()
      #endif

      LanguageSection()

      SpacedSectionDivider()

      PopupNotificationsSection(viewModel: viewModel, includePlacement: false)

      SpacedSectionDivider()

      // In the App Store build the section explains why auto-paste is unavailable there.
      ClipboardBehaviorSection(viewModel: viewModel)

      SpacedSectionDivider()

      AdvancedSettingsGroup {
        windowBehaviorSection
        PopupNotificationsSection(viewModel: viewModel, includeToggle: false)
        RecordingSafeguardsSection(viewModel: viewModel)
      }

      SpacedSectionDivider()

      // Last on the page, where macOS apps put destructive actions.
      ResetSection(viewModel: viewModel, showResetToDefaultsConfirmation: $showResetToDefaultsConfirmation)
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

  // MARK: - Window Behavior Section
  @ViewBuilder
  private var windowBehaviorSection: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "Window Behavior",
        systemImage: "macwindow",
        subtitle: nil
      )

      Toggle(isOn: $viewModel.data.settingsCloseOnFocusLoss) {
        VStack(alignment: .leading, spacing: 2) {
          Text("Close Settings when clicking outside")
            .font(.callout)
          Text("Closes Settings as soon as another app or window is focused. Turn this off if you follow API-key links — the browser would otherwise dismiss Settings.")
            .font(.caption)
            .foregroundColor(.secondary)
        }
      }
      .toggleStyle(.switch)
      .onChange(of: viewModel.data.settingsCloseOnFocusLoss) { _ in
        Task { await viewModel.saveSettings() }
      }

      Toggle(isOn: $viewModel.data.showDockIcon) {
        VStack(alignment: .leading, spacing: 2) {
          Text("Show a Dock icon")
            .font(.callout)
          Text("WhisperShortcut is a menu-bar app and normally has no Dock icon. Turn this on to get one, so you can switch to the app with ⌘-Tab. Takes effect immediately.")
            .font(.caption)
            .foregroundColor(.secondary)
        }
      }
      .toggleStyle(.switch)
      .onChange(of: viewModel.data.showDockIcon) { _ in
        Task {
          // Only apply what was actually persisted. `saveSettings()` returns the validation error
          // and writes nothing when another setting in this window is invalid (a duplicate
          // shortcut, say); switching the activation policy anyway would show a Dock icon the
          // stored preference does not have, and the next launch would silently take it away.
          guard await viewModel.saveSettings() == nil else { return }
          DockIconPreference.apply()
        }
      }
    }
  }
}
