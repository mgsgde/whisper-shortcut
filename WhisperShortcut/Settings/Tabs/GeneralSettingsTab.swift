import SwiftUI
import AppKit

/// General Settings Tab - shortcuts and app behavior preferences. API keys live in Accounts.
/// Smart Improvement and About/Reset live in their own tabs to keep this screen focused.
struct GeneralSettingsTab: View {
  @ObservedObject var viewModel: SettingsViewModel
  @FocusState.Binding var focusedField: SettingsFocusField?

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      KeyboardShortcutsSection(viewModel: viewModel, focusedField: $focusedField)

      SpacedSectionDivider()

      LaunchAtLoginSection(viewModel: viewModel)

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
    }
  }

  // MARK: - Window Behavior Section
  @ViewBuilder
  private var windowBehaviorSection: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "Window Behavior",
        systemImage: "macwindow",
        subtitle: "Control how the Settings window behaves"
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
    }
  }
}
