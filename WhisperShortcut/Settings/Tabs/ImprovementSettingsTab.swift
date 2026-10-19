import SwiftUI

/// Smart Improvement Settings Tab — usage-data collection, the "Improve from usage" runner,
/// auto-run scheduling, the model used for improvement, and context-data management.
/// Split out of the General tab so each screen stays focused and scannable.
struct ImprovementSettingsTab: View {
  @ObservedObject var viewModel: SettingsViewModel
  @FocusState.Binding var focusedField: SettingsFocusField?
  @AppStorage(UserDefaultsKeys.contextLoggingEnabled) private var saveUsageData = true
  @AppStorage(UserDefaultsKeys.offlineModeEnabled) private var offlineMode = false
  @AppStorage(UserDefaultsKeys.offlineModeKeepsUsageData) private var keepsUsageDataOffline = false
  @AppStorage(UserDefaultsKeys.improveFromUsageAutoRunInterval) private var autoRunIntervalRaw: Int = ImproveFromUsageAutoRunInterval.every7Days.rawValue
  @State private var showDeleteInteractionConfirmation = false
  @State private var isImprovementRunning = false
  @State private var queuedJobCount = 0

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      smartImprovementSection

      SpacedSectionDivider()

      SmartImprovementScorecardSection()

      SpacedSectionDivider()

      voiceFeedbackSection

      SpacedSectionDivider()

      WritingStyleSettingsSection()

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

  // MARK: - Voice Feedback Section
  @ViewBuilder
  private var voiceFeedbackSection: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "Voice Feedback",
        systemImage: "megaphone",
        subtitle: "Press the shortcut and speak an instruction (e.g. \"my name is spelled G-ö-d-d-e\"). The model turns it into a proposed change to your context, which you review before it's applied."
      )

      ShortcutRecorderRow(
        label: "Voice Feedback:",
        shortcut: $viewModel.data.voiceFeedback,
        focusedField: .voiceFeedbackShortcut,
        currentFocus: $focusedField,
        onChanged: {
          Task {
            await viewModel.saveSettings()
          }
        },
        findConflict: viewModel.findShortcutConflict,
        clearShortcut: viewModel.clearShortcut
      )

      Text("Uses the same model as Smart Improvement. Changes are proposed in a review window and go to the system-prompts history, so you can revert them.")
        .font(.caption)
        .foregroundColor(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  // MARK: - Context Data Section
  @ViewBuilder
  private var contextDataSection: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "Context Data",
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

          if offlineMode {
            offlineUsageDataCard
          }

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
            .disabled(isImprovementRunning || !canRunImprovement)
            .help("Improve prompts and context from your usage")
            .pointerCursorOnHover()

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
        .disabled(!isCollectingUsageData)

        let improvementSubscriptionMode = false
        PromptModelSelectionView(
          title: "Smart Improvement Model",
          subtitle: "Used for Smart Improvement (Improve from usage). Pick any provider you have a key for, or an offline model that runs on this Mac.",
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
          recommendedModel: SettingsDefaults.selectedImprovementModel,
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

        if selectedImprovementModel.provider == .localMLX {
          Text("The offline MLX model only updates your glossary (recurring names and terms). Rewriting your prompts needs a larger model: a cloud model, or Ollama / LM Studio running a bigger one.")
            .font(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }

  // MARK: - Offline Mode

  private var selectedImprovementModel: PromptModel { viewModel.data.selectedImprovementModel }

  /// Whether interactions are actually written right now — the same rule as
  /// `ContextLoggingPreference.isEnabled`, read from the `@AppStorage` values so the view updates
  /// when either switch flips.
  private var isCollectingUsageData: Bool {
    saveUsageData && (!offlineMode || keepsUsageDataOffline)
  }

  /// Offline Mode blocks every cloud model, so a run there needs an on-device one.
  private var canRunImprovement: Bool {
    isCollectingUsageData && (!offlineMode || selectedImprovementModel.runsOnThisMac)
  }

  /// Under Offline Mode the usage log is off unless the user keeps it here on purpose: in a
  /// practice the transcript is the regulated content, so the default stays "nothing at rest".
  @ViewBuilder
  private var offlineUsageDataCard: some View {
    VStack(alignment: .leading, spacing: 8) {
      Toggle("Keep usage data in Offline Mode", isOn: $keepsUsageDataOffline)
        .toggleStyle(.switch)
        .disabled(!saveUsageData)

      Text("Offline Mode is on. Usage data is off unless you keep it here. It stays in this Mac's app data folder and is never sent anywhere; dictation audio is never kept. Lets Smart Improvement learn your terms with an offline model.")
        .font(.caption)
        .foregroundColor(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      if keepsUsageDataOffline && !selectedImprovementModel.runsOnThisMac {
        Label("\(selectedImprovementModel.displayName) is a cloud model and cannot run in Offline Mode. Pick an offline model below.", systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: SettingsConstants.cornerRadius)
        .fill(Color(nsColor: .controlBackgroundColor))
    )
    .overlay(
      RoundedRectangle(cornerRadius: SettingsConstants.cornerRadius)
        .stroke(Color.accentColor.opacity(0.6), lineWidth: 1)
    )
  }
}
