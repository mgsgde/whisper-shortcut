import SwiftUI
import AppKit

/// General Settings Tab - API keys, shortcuts, and app behavior preferences.
/// Smart Improvement and About/Reset live in their own tabs to keep this screen focused.
struct GeneralSettingsTab: View {
  @ObservedObject var viewModel: SettingsViewModel
  @FocusState.Binding var focusedField: SettingsFocusField?

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      welcomeTourSection

      SpacedSectionDivider()

      GoogleAPIKeySection(viewModel: viewModel, focusedField: $focusedField)

      SpacedSectionDivider()

      XAIAPIKeySection(viewModel: viewModel)

      SpacedSectionDivider()

      AnthropicAPIKeySection(viewModel: viewModel)

      SpacedSectionDivider()

      OpenAIAPIKeySection(viewModel: viewModel)

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

      // In the App Store build the section explains why auto-paste is unavailable there.
      ClipboardBehaviorSection(viewModel: viewModel)
    }
  }

  // MARK: - Welcome Tour Section

  /// Re-entry point for the first-run guided tour. Kept at the very top of the first tab
  /// so returning users can always find their way back to the walkthrough.
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
    .padding(16)
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
