import SwiftUI

/// Smart Improvement Settings Tab — usage-data collection, the "Improve from usage" runner,
/// auto-run scheduling, the model used for improvement, and context-data management.
/// Split out of the General tab so each screen stays focused and scannable.
struct ImprovementSettingsTab: View {
  @ObservedObject var viewModel: SettingsViewModel
  @AppStorage(UserDefaultsKeys.contextLoggingEnabled) private var saveUsageData = true
  @AppStorage(UserDefaultsKeys.improveFromUsageAutoRunInterval) private var autoRunIntervalRaw: Int = ImproveFromUsageAutoRunInterval.every7Days.rawValue
  @State private var showDeleteInteractionConfirmation = false
  @State private var isImprovementRunning = false
  @State private var queuedJobCount = 0

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      smartImprovementSection

      SpacedSectionDivider()

      contextDataSection
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

  // MARK: - Context Data Section
  @ViewBuilder
  private var contextDataSection: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "Context data",
        systemImage: "tray.full",
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
        systemImage: "wand.and.stars",
        subtitle: "Improve prompts from your usage logs"
      )

      VStack(alignment: .leading, spacing: 16) {
        VStack(alignment: .leading, spacing: 8) {
          Toggle("Save usage data", isOn: $saveUsageData)
            .toggleStyle(.switch)
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
            .accessibilityLabel("Run Improve from usage automatically")
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
          subtitle: "Used for Smart Improvement (Improve from usage). Pick any provider you have a key for.",
          showSectionHeader: false,
          selectedModel: Binding(
            get: { viewModel.data.selectedImprovementModel },
            set: { newValue in
              var d = viewModel.data
              d.selectedImprovementModel = newValue
              viewModel.data = d
            }
          ),
          // Smart Improvement is a text task — offer every text-producing chat model
          // (Gemini / OpenAI / xAI), excluding image-generation models which return images,
          // not the text analysis this feature needs.
          availableModels: PromptModel.textChatModels,
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
