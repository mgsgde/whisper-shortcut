import SwiftUI

/// User Context Settings Tab - Interaction logging, context derivation, and suggestions
struct UserContextSettingsTab: View {
  @ObservedObject var viewModel: SettingsViewModel
  @AppStorage(UserDefaultsKeys.userContextLoggingEnabled) private var loggingEnabled = false
  @AppStorage(UserDefaultsKeys.userContextInPromptEnabled) private var contextInPromptEnabled = true
  @AppStorage(UserDefaultsKeys.hasPreviousPromptModeSystemPrompt) private var hasPreviousPrompt = false
  @AppStorage(UserDefaultsKeys.hasPreviousDictationDifficultWords) private var hasPreviousDifficultWords = false

  @State private var isUpdatingContext = false
  @State private var showDeleteConfirmation = false
  @State private var suggestedSystemPrompt: String?
  @State private var suggestedDifficultWords: String?
  @State private var statusMessage: String?

  private var hasAPIKey: Bool {
    KeychainManager.shared.hasGoogleAPIKey()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Logging Toggle Section
      loggingSection

      sectionDivider

      // Context in Prompt Section
      contextInPromptSection

      sectionDivider

      // Update Context Section
      updateContextSection

      sectionDivider

      // Suggestions Section (visible only when files exist)
      if suggestedSystemPrompt != nil || suggestedDifficultWords != nil {
        suggestionsSection
        sectionDivider
      }

      // Delete Data Section
      deleteDataSection

      sectionDivider

      // Data Notice
      dataNoticeSection
    }
    .onAppear {
      loadSuggestions()
    }
  }

  // MARK: - Section Divider Helper

  @ViewBuilder
  private var sectionDivider: some View {
    VStack(spacing: 0) {
      Spacer()
        .frame(height: SettingsConstants.sectionSpacing)
      SectionDivider()
      Spacer()
        .frame(height: SettingsConstants.sectionSpacing)
    }
  }

  // MARK: - Logging Section

  @ViewBuilder
  private var loggingSection: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "Interaction Logging",
        subtitle: "Log interactions to build personalized context"
      )

      Toggle("Enable interaction logging", isOn: $loggingEnabled)
        .toggleStyle(.checkbox)

      Text("When enabled, transcriptions, prompts, and read-aloud actions are logged locally in JSONL format. Logs are automatically deleted after 90 days.")
        .font(.callout)
        .foregroundColor(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  // MARK: - Context in Prompt Section

  @ViewBuilder
  private var contextInPromptSection: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "Use Context in Prompts",
        subtitle: "Automatically include derived context in prompt mode"
      )

      Toggle("Include user context in system prompt", isOn: $contextInPromptEnabled)
        .toggleStyle(.checkbox)

      Text("When enabled, your derived user context is appended to the system prompt in Dictate Prompt and Dictate Prompt & Read modes.")
        .font(.callout)
        .foregroundColor(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  // MARK: - Update Context Section

  @ViewBuilder
  private var updateContextSection: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "Update Context",
        subtitle: "Analyze interaction logs to derive user profile and suggestions"
      )

      HStack(spacing: 12) {
        Button(action: updateContext) {
          if isUpdatingContext {
            HStack(spacing: 6) {
              ProgressView()
                .controlSize(.small)
              Text("Updating...")
            }
          } else {
            Text("Update Context")
          }
        }
        .disabled(!hasAPIKey || isUpdatingContext)

        if !hasAPIKey {
          Text("Requires Google API key")
            .font(.callout)
            .foregroundColor(.secondary)
        }
      }

      if let statusMessage {
        Text(statusMessage)
          .font(.callout)
          .foregroundColor(statusMessage.contains("Error") || statusMessage.contains("Failed") ? .red : .green)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  // MARK: - Suggestions Section

  @ViewBuilder
  private var suggestionsSection: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "Suggestions",
        subtitle: "Apply AI-generated suggestions to your settings"
      )

      if let prompt = suggestedSystemPrompt {
        VStack(alignment: .leading, spacing: 8) {
          Text("Suggested System Prompt:")
            .font(.callout)
            .fontWeight(.semibold)

          ScrollView {
            Text(prompt)
              .frame(maxWidth: .infinity, alignment: .leading)
              .textSelection(.enabled)
              .font(.system(.callout, design: .monospaced))
              .foregroundColor(.secondary)
              .padding(8)
          }
          .scrollIndicators(.visible)
          .frame(height: SettingsConstants.textEditorHeight)
          .background(Color(.controlBackgroundColor))
          .cornerRadius(SettingsConstants.cornerRadius)
          .overlay(
            RoundedRectangle(cornerRadius: SettingsConstants.cornerRadius)
              .stroke(Color(.separatorColor), lineWidth: 1)
          )

          HStack(spacing: 12) {
            Button("Apply") {
              applySuggestedSystemPrompt(prompt)
            }
            Button("Restore Previous") {
              restorePreviousSystemPrompt()
            }
            .disabled(!hasPreviousPrompt)
          }

          if hasPreviousPrompt {
            Text("Applied. Use Restore Previous to undo.")
              .font(.callout)
              .foregroundColor(.green)
          }
        }
      }

      if let words = suggestedDifficultWords {
        VStack(alignment: .leading, spacing: 8) {
          Text("Suggested Difficult Words:")
            .font(.callout)
            .fontWeight(.semibold)

          ScrollView {
            Text(words)
              .frame(maxWidth: .infinity, alignment: .leading)
              .textSelection(.enabled)
              .font(.system(.callout, design: .monospaced))
              .foregroundColor(.secondary)
              .padding(8)
          }
          .scrollIndicators(.visible)
          .frame(height: SettingsConstants.textEditorHeight)
          .background(Color(.controlBackgroundColor))
          .cornerRadius(SettingsConstants.cornerRadius)
          .overlay(
            RoundedRectangle(cornerRadius: SettingsConstants.cornerRadius)
              .stroke(Color(.separatorColor), lineWidth: 1)
          )

          HStack(spacing: 12) {
            Button("Apply") {
              applySuggestedDifficultWords(words)
            }
            Button("Restore Previous") {
              restorePreviousDifficultWords()
            }
            .disabled(!hasPreviousDifficultWords)
          }

          if hasPreviousDifficultWords {
            Text("Applied. Use Restore Previous to undo.")
              .font(.callout)
              .foregroundColor(.green)
          }
        }
      }
    }
  }

  // MARK: - Delete Data Section

  @ViewBuilder
  private var deleteDataSection: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "Data Management",
        subtitle: "Delete all logged interactions and derived context"
      )

      Button("Delete All Context Data", role: .destructive) {
        showDeleteConfirmation = true
      }
      .alert("Delete All Context Data?", isPresented: $showDeleteConfirmation) {
        Button("Cancel", role: .cancel) {}
        Button("Delete", role: .destructive) {
          UserContextLogger.shared.deleteAllData()
          suggestedSystemPrompt = nil
          suggestedDifficultWords = nil
          UserDefaults.standard.set(false, forKey: UserDefaultsKeys.hasPreviousPromptModeSystemPrompt)
          UserDefaults.standard.set(false, forKey: UserDefaultsKeys.hasPreviousDictationDifficultWords)
          UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.previousPromptModeSystemPrompt)
          UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.previousDictationDifficultWords)
          statusMessage = "All context data deleted"
        }
      } message: {
        Text("This will permanently delete all interaction logs, user context, and suggestions. This action cannot be undone.")
      }
    }
  }

  // MARK: - Data Notice Section

  @ViewBuilder
  private var dataNoticeSection: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "Data Notice",
        subtitle: "How your data is handled"
      )

      Text("Interaction logs are stored locally in ~/Library/Application Support/WhisperShortcut/UserContext/. When you click \"Update Context\", aggregated interaction data is sent to Google Gemini for analysis. Logs older than 90 days are automatically deleted.")
        .font(.callout)
        .foregroundColor(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      Button("Open User Context Folder in Finder") {
        openUserContextFolder()
      }
    }
  }

  // MARK: - Actions

  private func updateContext() {
    isUpdatingContext = true
    statusMessage = nil

    Task {
      do {
        let derivation = UserContextDerivation()
        try await derivation.updateContextFromLogs()

        await MainActor.run {
          isUpdatingContext = false
          statusMessage = "Context updated successfully"
          loadSuggestions()
        }
      } catch {
        await MainActor.run {
          isUpdatingContext = false
          statusMessage = "Failed: \(error.localizedDescription)"
        }
      }
    }
  }

  private func openUserContextFolder() {
    let url = UserContextLogger.shared.directoryURL
    if !FileManager.default.fileExists(atPath: url.path) {
      try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    NSWorkspace.shared.open(url)
  }

  private func applySuggestedSystemPrompt(_ prompt: String) {
    let current = viewModel.data.promptModeSystemPrompt
    UserDefaults.standard.set(current, forKey: UserDefaultsKeys.previousPromptModeSystemPrompt)
    UserDefaults.standard.set(true, forKey: UserDefaultsKeys.hasPreviousPromptModeSystemPrompt)
    UserDefaults.standard.set(prompt, forKey: UserDefaultsKeys.promptModeSystemPrompt)
    var data = viewModel.data
    data.promptModeSystemPrompt = prompt
    viewModel.data = data
  }

  private func restorePreviousSystemPrompt() {
    guard let previous = UserDefaults.standard.string(forKey: UserDefaultsKeys.previousPromptModeSystemPrompt) else { return }
    UserDefaults.standard.set(previous, forKey: UserDefaultsKeys.promptModeSystemPrompt)
    var data = viewModel.data
    data.promptModeSystemPrompt = previous
    viewModel.data = data
    UserDefaults.standard.set(false, forKey: UserDefaultsKeys.hasPreviousPromptModeSystemPrompt)
    UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.previousPromptModeSystemPrompt)
  }

  private func applySuggestedDifficultWords(_ words: String) {
    let current = viewModel.data.dictationDifficultWords
    UserDefaults.standard.set(current, forKey: UserDefaultsKeys.previousDictationDifficultWords)
    UserDefaults.standard.set(true, forKey: UserDefaultsKeys.hasPreviousDictationDifficultWords)
    UserDefaults.standard.set(words, forKey: UserDefaultsKeys.dictationDifficultWords)
    var data = viewModel.data
    data.dictationDifficultWords = words
    viewModel.data = data
  }

  private func restorePreviousDifficultWords() {
    guard let previous = UserDefaults.standard.string(forKey: UserDefaultsKeys.previousDictationDifficultWords) else { return }
    UserDefaults.standard.set(previous, forKey: UserDefaultsKeys.dictationDifficultWords)
    var data = viewModel.data
    data.dictationDifficultWords = previous
    viewModel.data = data
    UserDefaults.standard.set(false, forKey: UserDefaultsKeys.hasPreviousDictationDifficultWords)
    UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.previousDictationDifficultWords)
  }

  private func loadSuggestions() {
    let contextDir = UserContextLogger.shared.directoryURL

    let promptURL = contextDir.appendingPathComponent("suggested-prompt-mode-system-prompt.txt")
    if FileManager.default.fileExists(atPath: promptURL.path),
       let content = try? String(contentsOf: promptURL, encoding: .utf8),
       !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      suggestedSystemPrompt = content.trimmingCharacters(in: .whitespacesAndNewlines)
    } else {
      suggestedSystemPrompt = nil
    }

    let wordsURL = contextDir.appendingPathComponent("suggested-difficult-words.txt")
    if FileManager.default.fileExists(atPath: wordsURL.path),
       let content = try? String(contentsOf: wordsURL, encoding: .utf8),
       !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      suggestedDifficultWords = content.trimmingCharacters(in: .whitespacesAndNewlines)
    } else {
      suggestedDifficultWords = nil
    }
  }
}
