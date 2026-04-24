import SwiftUI
import AppKit

/// General Settings Tab - API Key, shortcuts, preferences, context data, and Smart Improvement
struct GeneralSettingsTab: View {
  @ObservedObject var viewModel: SettingsViewModel
  @FocusState.Binding var focusedField: SettingsFocusField?
  @State private var showResetToDefaultsConfirmation = false
  @AppStorage(UserDefaultsKeys.contextLoggingEnabled) private var saveUsageData = false
  @AppStorage(UserDefaultsKeys.improveFromUsageAutoRunInterval) private var autoRunIntervalRaw: Int = ImproveFromUsageAutoRunInterval.every7Days.rawValue
  @State private var showDeleteInteractionConfirmation = false
  @State private var isImprovementRunning = false
  @State private var queuedJobCount = 0

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      GoogleAPIKeySection(viewModel: viewModel, focusedField: $focusedField)

      SpacedSectionDivider()

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

      contextDataSection

      SpacedSectionDivider()

      smartImprovementSection

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
    .confirmationDialog("Delete context data?", isPresented: $showDeleteInteractionConfirmation, titleVisibility: .visible) {
      Button("Delete", role: .destructive) {
        viewModel.deleteInteractionData()
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("All interaction data and everything in context files will be deleted. System prompts will be recreated with defaults. Settings are preserved. Continue?")
    }
    .onAppear {
      refreshImprovementState()
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

  // MARK: - Context Data Section
  @ViewBuilder
  private var contextDataSection: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "Context data",
        subtitle: "Interaction logs, context data, and suggested prompts are stored here. You can open the folder or delete all of this data; settings are preserved."
      )

      HStack(alignment: .center, spacing: 12) {
        Button(action: { viewModel.openContextFolder() }) {
          Label("Open context data", systemImage: "folder")
            .font(.callout)
        }
        .buttonStyle(.bordered)
        .help("Open context data in Finder")
        .pointerCursorOnHover()

        Button("Delete context data", role: .destructive) {
          showDeleteInteractionConfirmation = true
        }
        .buttonStyle(.bordered)
        .tint(.red)
        .help("Only delete interaction history and context; settings are preserved")
        .pointerCursorOnHover()
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  // MARK: - Smart Improvement Section
  private func refreshImprovementState() {
    isImprovementRunning = AutoPromptImprovementScheduler.shared.isRunning
    queuedJobCount = AutoPromptImprovementScheduler.shared.queuedJobCount
  }

  private var improveFromUsageButtonLabel: String {
    if isImprovementRunning {
      return queuedJobCount > 0 ? "Running… (\(queuedJobCount) in queue)" : "Running…"
    }
    return "Improve from usage"
  }

  @ViewBuilder
  private var smartImprovementSection: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "Smart Improvement",
        subtitle: "Improve prompts from your usage logs"
      )

      VStack(alignment: .leading, spacing: 16) {
        VStack(alignment: .leading, spacing: 8) {
          Toggle("Save usage data", isOn: $saveUsageData)
            .toggleStyle(.checkbox)
            .help("When enabled, interaction logs (dictation, dictate prompt, chat) are stored so \"Improve from usage\" can suggest better prompts. On by default.")

          HStack(alignment: .center, spacing: 12) {
            Text("Improve from usage")
              .font(.callout)
              .fontWeight(.medium)
            Spacer(minLength: 16)
            Button(action: {
              guard !isImprovementRunning else { return }
              isImprovementRunning = true
              queuedJobCount = 0
              Task {
                await AutoPromptImprovementScheduler.shared.runImprovementNow()
                await MainActor.run { refreshImprovementState() }
              }
            }) {
              Label(improveFromUsageButtonLabel, systemImage: "sparkles")
                .font(.callout)
            }
            .buttonStyle(.bordered)
            .disabled(isImprovementRunning || !saveUsageData)
            .help("Improve prompts and context from your usage")
            .pointerCursorOnHover()
          }

          Text("Runs in the background using your interaction logs. Enable \"Save usage data\" to collect logs. You can switch to another tab; you'll be notified when it's done.")
            .font(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }

        VStack(alignment: .leading, spacing: 8) {
          HStack(alignment: .center, spacing: 12) {
            Text("Run Improve from usage automatically")
              .font(.callout)
              .fontWeight(.medium)
            Spacer(minLength: 16)
            Picker("", selection: $autoRunIntervalRaw) {
              ForEach(ImproveFromUsageAutoRunInterval.allCases, id: \.rawValue) { interval in
                Text(interval.displayName).tag(interval.rawValue)
              }
            }
            .labelsHidden()
            .fixedSize()
            .onChange(of: autoRunIntervalRaw) { _, _ in
              Task { @MainActor in
                await ImproveFromUsageAutoRunCoordinator.shared.checkAndRunIfDue()
              }
            }
          }
          Text("When not Off, Improve from usage runs in the background at the chosen interval (e.g. every 14 days). You will be notified when it finishes.")
            .font(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .disabled(!saveUsageData)

        let improvementSubscriptionMode = false
        PromptModelSelectionView(
          title: "Model for Smart Improvement",
          subtitle: "Used for Smart Improvement (Improve from usage).",
          showSectionHeader: false,
          selectedModel: Binding(
            get: { viewModel.data.selectedImprovementModel },
            set: { newValue in
              var d = viewModel.data
              d.selectedImprovementModel = newValue
              viewModel.data = d
            }
          ),
          subscriptionMode: improvementSubscriptionMode,
          onModelChanged: {
            UserDefaults.standard.set(
              viewModel.data.selectedImprovementModel.rawValue,
              forKey: UserDefaultsKeys.selectedImprovementModel)
            Task {
              await viewModel.saveSettings()
            }
          }
        )
      }
    }
  }
}
