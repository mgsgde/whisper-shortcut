import SwiftUI

/// Smart Improvement Settings Tab — one switch that lets the app learn from how it is used
/// (usage logs for Improve from usage + the writing style), plus a collapsed Details group with
/// the knobs, the scorecard, the writing style profile and context-data management.
/// Magnus, 2026-10-30: "Ich will einfach, dass das Ding selbstständig herausbekommt, wie es am
/// besten funktioniert … aber ich will mich nicht mit irgendeinem Writing Style selbst beschäftigen."
struct ImprovementSettingsTab: View {
  @ObservedObject var viewModel: SettingsViewModel
  @FocusState.Binding var focusedField: SettingsFocusField?
  @AppStorage(UserDefaultsKeys.contextLoggingEnabled) private var saveUsageData = false
  @AppStorage(UserDefaultsKeys.writingStyleEnabled) private var writingStyleEnabled = false
  @AppStorage(UserDefaultsKeys.improveFromUsageAutoRunInterval) private var autoRunIntervalRaw: Int = ImproveFromUsageAutoRunInterval.every7Days.rawValue
  @State private var showDeleteInteractionConfirmation = false
  @State private var isImprovementRunning = false
  @State private var queuedJobCount = 0
  @State private var showDetails = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      learningSection

      SpacedSectionDivider()

      DisclosureGroup(isExpanded: $showDetails) {
        VStack(alignment: .leading, spacing: 0) {
          improveFromUsageControls
            .padding(.top, 16)

          SpacedSectionDivider()

          SmartImprovementScorecardSection()

          SpacedSectionDivider()

          WritingStyleSettingsSection()

          SpacedSectionDivider()

          contextDataSection
        }
      } label: {
        Text("Details")
          .font(.callout)
          .fontWeight(.medium)
      }
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

  // MARK: - Learning (the one switch)

  /// On when either half is on, so a user who enabled only one of them earlier still sees "on".
  private var learningEnabled: Binding<Bool> {
    Binding(
      get: { saveUsageData || writingStyleEnabled },
      set: { enabled in
        saveUsageData = enabled
        writingStyleEnabled = enabled
        // The Writing Style section that normally fires this sits collapsed under Details.
        WritingStyleSettingsSection.handleToggle(enabled: enabled)
        if enabled && autoRunIntervalRaw == ImproveFromUsageAutoRunInterval.off.rawValue {
          autoRunIntervalRaw = ImproveFromUsageAutoRunInterval.every7Days.rawValue
        }
      }
    )
  }

  private var learningSection: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "Smart Improvement",
        systemImage: "wand.and.stars",
        subtitle: "WhisperShortcut learns from how you use it and gets better on its own: spellings, prompts, and the way you write messages. There is nothing to set up."
      )

      VStack(alignment: .leading, spacing: 10) {
        Toggle("Learn from how I use WhisperShortcut", isOn: learningEnabled)
          .toggleStyle(.switch)
          .help("Keeps your dictations and prompts on this Mac and lets the Smart Improvement model suggest better prompts and learn your writing style. Off by default.")

        HStack(spacing: 8) {
          if isImprovementRunning {
            ProgressView().controlSize(.small)
          } else {
            Image(systemName: learningEnabled.wrappedValue ? "checkmark.circle.fill" : "pause.circle")
              .foregroundColor(learningEnabled.wrappedValue ? .green : .secondary)
          }
          Text(learningStatusText)
            .font(.callout)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }

        Text("Your usage data stays on this Mac. When it learns, a sample goes to your Smart Improvement model, and you review every change before it is saved.")
          .font(.caption)
          .foregroundColor(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private var learningStatusText: String {
    if isImprovementRunning { return String(localized: "Learning from your recent usage…") }
    return learningEnabled.wrappedValue
      ? String(localized: "On. You get a notification when there is something to review.")
      : String(localized: "Off. Nothing is learned or stored.")
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
      return queuedJobCount > 0
        ? String(localized: "Running… (\(queuedJobCount) in queue)")
        : String(localized: "Running…")
    }
    return String(localized: "Improve from usage")
  }

  /// Manual run, schedule and model — the knobs behind the one switch.
  @ViewBuilder
  private var improveFromUsageControls: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      VStack(alignment: .leading, spacing: 16) {
        VStack(alignment: .leading, spacing: 8) {
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

          Text("Runs in the background; you get a notification when it is done. Needs learning to be on.")
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
          Text("Runs Improve from usage on its own at this interval.")
            .font(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .disabled(!saveUsageData)

        let improvementSubscriptionMode = false
        PromptModelSelectionView(
          title: "Smart Improvement Model",
          subtitle: "The model that reviews your usage and suggests better prompts.",
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
            Task {
              await viewModel.saveSettings()
            }
          }
        )
      }
    }
  }
}
