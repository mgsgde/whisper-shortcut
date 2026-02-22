import SwiftUI

/// Dedicated tab for Smart Improvement: settings, interaction data path, open folder, and delete.
struct SmartImprovementSettingsTab: View {
  @ObservedObject var viewModel: SettingsViewModel
  @FocusState.Binding var focusedField: SettingsFocusField?
  @State private var selectedInterval: AutoImprovementInterval = .default
  @State private var selectedDictationThreshold: Int = AppConstants.promptImprovementDictationThreshold
  @State private var showDeleteInteractionConfirmation = false
  @State private var isImprovementRunning = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      howItWorksSection

      VStack(spacing: 0) {
        Spacer().frame(height: SettingsConstants.sectionSpacing)
        SectionDivider()
        Spacer().frame(height: SettingsConstants.sectionSpacing)
      }

      settingsSection

      VStack(spacing: 0) {
        Spacer().frame(height: SettingsConstants.sectionSpacing)
        SectionDivider()
        Spacer().frame(height: SettingsConstants.sectionSpacing)
      }

      interactionDataSection
    }
    .confirmationDialog("Delete interaction data", isPresented: $showDeleteInteractionConfirmation, titleVisibility: .visible) {
      Button("Delete", role: .destructive) {
        viewModel.deleteInteractionData()
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Interaction history and derived context (user-context, suggestions) will be deleted. Settings are preserved. Continue?")
    }
  }

  // MARK: - How it works
  @ViewBuilder
  private var howItWorksSection: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "How it works",
        subtitle: "Smart Improvement runs automatically after successful dictations. When the dictation count reaches your threshold and the cooldown has passed, the app analyzes your usage and suggests updates for User Context, Dictation prompt, Dictate Prompt prompt, and Prompt & Read prompt. Suggestions are applied automatically; you can revert anytime via \"Restore Previous\" in the relevant settings tabs."
      )
    }
  }

  // MARK: - Settings
  @ViewBuilder
  private var settingsSection: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "Smart Improvement",
        subtitle: "Automatically improve system prompts based on your usage"
      )

      VStack(alignment: .leading, spacing: 16) {
        VStack(alignment: .leading, spacing: 8) {
          HStack(alignment: .center, spacing: 12) {
            Text("Automatic system prompt improvement")
              .font(.callout)
              .fontWeight(.medium)
            Spacer(minLength: 16)
            Picker("", selection: $selectedInterval) {
              ForEach(AutoImprovementInterval.allCases, id: \.self) { interval in
                Text(interval.displayName).tag(interval)
              }
            }
            .pickerStyle(.menu)
            .frame(width: 160, alignment: .trailing)
            .onChange(of: selectedInterval) { newValue in
              UserDefaults.standard.set(newValue.rawValue, forKey: UserDefaultsKeys.autoPromptImprovementIntervalDays)
              let enabled = newValue != .never
              UserDefaults.standard.set(enabled, forKey: UserDefaultsKeys.userContextLoggingEnabled)
              DebugLogger.log("AUTO-IMPROVEMENT: Interval changed to \(newValue.displayName), logging = \(enabled)")
            }
          }

          Text("Minimum cooldown between improvement runs (from the second run onwards). Set to \"Always\" for no cooldown.")
            .font(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }

        VStack(alignment: .leading, spacing: 8) {
          HStack(alignment: .center, spacing: 12) {
            Text("Improvement after N dictations")
              .font(.callout)
              .fontWeight(.medium)
            Spacer(minLength: 16)
            Picker("", selection: $selectedDictationThreshold) {
              Text("2 dictations").tag(2)
              Text("5 dictations").tag(5)
              Text("10 dictations").tag(10)
              Text("20 dictations").tag(20)
              Text("50 dictations").tag(50)
            }
            .pickerStyle(.menu)
            .frame(width: 160, alignment: .trailing)
            .onChange(of: selectedDictationThreshold) { _, newValue in
              UserDefaults.standard.set(newValue, forKey: UserDefaultsKeys.promptImprovementDictationThreshold)
              DebugLogger.log("AUTO-IMPROVEMENT: Dictation threshold changed to \(newValue)")
            }
          }

          Text("The first improvement runs after this many dictations; from the second run onwards, cooldown and minimum usage history also apply.")
            .font(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }

        VStack(alignment: .leading, spacing: 8) {
          HStack(alignment: .center, spacing: 12) {
            Text("Run improvement now")
              .font(.callout)
              .fontWeight(.medium)
            Spacer(minLength: 16)
            Button(action: {
              guard !isImprovementRunning else { return }
              isImprovementRunning = true
              Task {
                await AutoPromptImprovementScheduler.shared.runImprovementNow()
                await MainActor.run { isImprovementRunning = false }
              }
            }) {
              Label(isImprovementRunning ? "Running…" : "Run improvement now", systemImage: "sparkles")
                .font(.callout)
            }
            .buttonStyle(.bordered)
            .disabled(isImprovementRunning)
            .help("Run improvement pipeline now; ignores cooldown and dictation count")
          }

          Text("Runs in the background. You can switch to another tab; you'll be notified when it's done. Ignores cooldown and dictation count.")
            .font(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }

        PromptModelSelectionView(
          title: "Model for Smart Improvement",
          subtitle: "Used for automatic Smart Improvement (suggested prompts and user context).",
          showSectionHeader: false,
          selectedModel: Binding(
            get: { viewModel.data.selectedImprovementModel },
            set: { newValue in
              var d = viewModel.data
              d.selectedImprovementModel = newValue
              viewModel.data = d
            }
          ),
          onModelChanged: nil
        )
      }
    }
    .onAppear {
      isImprovementRunning = AutoPromptImprovementScheduler.shared.isRunning
      let rawValue = UserDefaults.standard.integer(forKey: UserDefaultsKeys.autoPromptImprovementIntervalDays)
      selectedInterval = AutoImprovementInterval(rawValue: rawValue) ?? .default
      let enabled = selectedInterval != .never
      UserDefaults.standard.set(enabled, forKey: UserDefaultsKeys.userContextLoggingEnabled)
      if UserDefaults.standard.object(forKey: UserDefaultsKeys.promptImprovementDictationThreshold) == nil {
        selectedDictationThreshold = AppConstants.promptImprovementDictationThreshold
      } else {
        selectedDictationThreshold = UserDefaults.standard.integer(forKey: UserDefaultsKeys.promptImprovementDictationThreshold)
      }
    }
  }

  // MARK: - Interaction data
  @ViewBuilder
  private var interactionDataSection: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "Interaction data",
        subtitle: "Interaction logs, user context, and suggested prompts are stored here. You can open the folder or delete all of this data; settings are preserved."
      )

      HStack(alignment: .center, spacing: 12) {
        Button(action: { viewModel.openUserContextFolder() }) {
          Label("Open interaction data folder", systemImage: "folder")
            .font(.callout)
        }
        .buttonStyle(.bordered)
        .help("Open UserContext folder in Finder")

        Button("Delete interaction data", role: .destructive) {
          showDeleteInteractionConfirmation = true
        }
        .buttonStyle(.bordered)
        .tint(.red)
        .help("Only delete interaction history and context; settings are preserved")
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}
