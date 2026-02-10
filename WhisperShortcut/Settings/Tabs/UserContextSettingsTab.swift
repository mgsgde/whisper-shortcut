import SwiftUI

/// User Context Settings Tab - Interaction logging, context derivation, and suggestions
struct UserContextSettingsTab: View {
  @ObservedObject var viewModel: SettingsViewModel
  @AppStorage(UserDefaultsKeys.userContextLoggingEnabled) private var loggingEnabled = false
  @AppStorage(UserDefaultsKeys.userContextInPromptEnabled) private var contextInPromptEnabled = true
  @AppStorage(UserDefaultsKeys.userContextMaxEntriesPerMode) private var maxEntriesPerMode: Int = AppConstants.userContextDefaultMaxEntriesPerMode
  @AppStorage(UserDefaultsKeys.userContextMaxTotalChars) private var maxTotalChars: Int = AppConstants.userContextDefaultMaxTotalChars
  @AppStorage(UserDefaultsKeys.hasPreviousPromptModeSystemPrompt) private var hasPreviousPrompt = false
  @AppStorage(UserDefaultsKeys.hasPreviousPromptAndReadSystemPrompt) private var hasPreviousPromptAndRead = false
  @AppStorage(UserDefaultsKeys.hasPreviousCustomPromptText) private var hasPreviousDictationPrompt = false
  @AppStorage(UserDefaultsKeys.hasPreviousDictationDifficultWords) private var hasPreviousDifficultWords = false
  @AppStorage(UserDefaultsKeys.hasPreviousUserContext) private var hasPreviousUserContext = false

  @State private var isUpdatingContext = false
  @State private var showDeleteConfirmation = false
  @State private var suggestedSystemPrompt: String?
  @State private var suggestedPromptAndReadSystemPrompt: String?
  @State private var suggestedDictationPrompt: String?
  @State private var suggestedDifficultWords: String?
  @State private var suggestedUserContext: String?
  @State private var statusMessage: String?
  @State private var userContextFeedback: String?
  @State private var systemPromptFeedback: String?
  @State private var promptAndReadFeedback: String?
  @State private var dictationPromptFeedback: String?
  @State private var difficultWordsFeedback: String?

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

      // Update Limits Section
      limitsSection

      sectionDivider

      // Suggestions Section (visible when suggestions or previous values exist)
      if suggestedUserContext != nil || suggestedSystemPrompt != nil || suggestedPromptAndReadSystemPrompt != nil || suggestedDictationPrompt != nil || suggestedDifficultWords != nil
          || hasPreviousUserContext || hasPreviousPrompt || hasPreviousPromptAndRead || hasPreviousDictationPrompt || hasPreviousDifficultWords {
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

  // MARK: - Update Limits Section

  @ViewBuilder
  private var limitsSection: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "Update Limits",
        subtitle: "Control how much data is analyzed"
      )

      Stepper("Max entries per mode: \(maxEntriesPerMode)", value: $maxEntriesPerMode, in: 10...100, step: 10)

      Stepper("Max total characters: \(maxTotalChars / 1000)k", value: $maxTotalChars, in: 20_000...150_000, step: 10_000)

      Text("Recent interactions are prioritized: 50% from last 7 days, 30% from days 8–14, 20% from older.")
        .font(.callout)
        .foregroundColor(.secondary)
        .fixedSize(horizontal: false, vertical: true)
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

      if suggestedUserContext != nil || hasPreviousUserContext {
        suggestionBlock(
          title: "User Context",
          suggestion: suggestedUserContext,
          hasPrevious: hasPreviousUserContext,
          feedback: userContextFeedback,
          onApply: { context in
            applySuggestedUserContext(context)
            userContextFeedback = "Applied."
          },
          onRestore: {
            restorePreviousUserContext()
            userContextFeedback = "Previous version restored."
          }
        )
      }

      if suggestedSystemPrompt != nil || hasPreviousPrompt {
        suggestionBlock(
          title: "Dictate Prompt System Prompt",
          suggestion: suggestedSystemPrompt,
          hasPrevious: hasPreviousPrompt,
          feedback: systemPromptFeedback,
          onApply: { prompt in
            applySuggestedSystemPrompt(prompt)
            systemPromptFeedback = "Applied."
          },
          onRestore: {
            restorePreviousSystemPrompt()
            systemPromptFeedback = "Previous version restored."
          }
        )
      }

      if suggestedPromptAndReadSystemPrompt != nil || hasPreviousPromptAndRead {
        suggestionBlock(
          title: "Prompt & Read System Prompt",
          suggestion: suggestedPromptAndReadSystemPrompt,
          hasPrevious: hasPreviousPromptAndRead,
          feedback: promptAndReadFeedback,
          onApply: { prompt in
            applySuggestedPromptAndReadSystemPrompt(prompt)
            promptAndReadFeedback = "Applied."
          },
          onRestore: {
            restorePreviousPromptAndReadSystemPrompt()
            promptAndReadFeedback = "Previous version restored."
          }
        )
      }

      if suggestedDictationPrompt != nil || hasPreviousDictationPrompt {
        suggestionBlock(
          title: "Dictation Prompt",
          suggestion: suggestedDictationPrompt,
          hasPrevious: hasPreviousDictationPrompt,
          feedback: dictationPromptFeedback,
          onApply: { prompt in
            applySuggestedDictationPrompt(prompt)
            dictationPromptFeedback = "Applied."
          },
          onRestore: {
            restorePreviousDictationPrompt()
            dictationPromptFeedback = "Previous version restored."
          }
        )
      }

      if suggestedDifficultWords != nil || hasPreviousDifficultWords {
        suggestionBlock(
          title: "Difficult Words",
          suggestion: suggestedDifficultWords,
          hasPrevious: hasPreviousDifficultWords,
          feedback: difficultWordsFeedback,
          onApply: { words in
            applySuggestedDifficultWords(words)
            difficultWordsFeedback = "Applied."
          },
          onRestore: {
            restorePreviousDifficultWords()
            difficultWordsFeedback = "Previous version restored."
          }
        )
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
          suggestedPromptAndReadSystemPrompt = nil
          suggestedDictationPrompt = nil
          suggestedDifficultWords = nil
          suggestedUserContext = nil
          UserDefaults.standard.set(false, forKey: UserDefaultsKeys.hasPreviousPromptModeSystemPrompt)
          UserDefaults.standard.set(false, forKey: UserDefaultsKeys.hasPreviousPromptAndReadSystemPrompt)
          UserDefaults.standard.set(false, forKey: UserDefaultsKeys.hasPreviousCustomPromptText)
          UserDefaults.standard.set(false, forKey: UserDefaultsKeys.hasPreviousDictationDifficultWords)
          UserDefaults.standard.set(false, forKey: UserDefaultsKeys.hasPreviousUserContext)
          UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.previousPromptModeSystemPrompt)
          UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.previousPromptAndReadSystemPrompt)
          UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.previousCustomPromptText)
          UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.previousDictationDifficultWords)
          UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.previousUserContext)
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

  // MARK: - Suggestion Block Helper

  @ViewBuilder
  private func suggestionBlock(
    title: String,
    suggestion: String?,
    hasPrevious: Bool,
    feedback: String?,
    onApply: @escaping (String) -> Void,
    onRestore: @escaping () -> Void
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("\(title):")
        .font(.callout)
        .fontWeight(.semibold)

      if let text = suggestion {
        ScrollView {
          Text(text)
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
      }

      HStack(spacing: 12) {
        if let text = suggestion {
          Button("Apply") {
            onApply(text)
          }
        }

        if hasPrevious {
          Button("Restore Previous") {
            onRestore()
          }
        }

        if let feedback {
          Text(feedback)
            .font(.callout)
            .foregroundColor(.green)
        }
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
        let loaded = try await derivation.updateContextFromLogs()

        await MainActor.run {
          isUpdatingContext = false
          statusMessage = "Context updated (\(loaded.entryCount) entries, ~\(loaded.charCount / 1000)k chars)"
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
    let current = viewModel.data.promptModeSystemPrompt
    UserDefaults.standard.set(current, forKey: UserDefaultsKeys.previousPromptModeSystemPrompt)
    UserDefaults.standard.set(previous, forKey: UserDefaultsKeys.promptModeSystemPrompt)
    var data = viewModel.data
    data.promptModeSystemPrompt = previous
    viewModel.data = data
  }

  private func applySuggestedPromptAndReadSystemPrompt(_ prompt: String) {
    let current = viewModel.data.promptAndReadSystemPrompt
    UserDefaults.standard.set(current, forKey: UserDefaultsKeys.previousPromptAndReadSystemPrompt)
    UserDefaults.standard.set(true, forKey: UserDefaultsKeys.hasPreviousPromptAndReadSystemPrompt)
    UserDefaults.standard.set(prompt, forKey: UserDefaultsKeys.promptAndReadSystemPrompt)
    var data = viewModel.data
    data.promptAndReadSystemPrompt = prompt
    viewModel.data = data
  }

  private func restorePreviousPromptAndReadSystemPrompt() {
    guard let previous = UserDefaults.standard.string(forKey: UserDefaultsKeys.previousPromptAndReadSystemPrompt) else { return }
    let current = viewModel.data.promptAndReadSystemPrompt
    UserDefaults.standard.set(current, forKey: UserDefaultsKeys.previousPromptAndReadSystemPrompt)
    UserDefaults.standard.set(previous, forKey: UserDefaultsKeys.promptAndReadSystemPrompt)
    var data = viewModel.data
    data.promptAndReadSystemPrompt = previous
    viewModel.data = data
  }

  private func applySuggestedDictationPrompt(_ prompt: String) {
    let current = viewModel.data.customPromptText
    UserDefaults.standard.set(current, forKey: UserDefaultsKeys.previousCustomPromptText)
    UserDefaults.standard.set(true, forKey: UserDefaultsKeys.hasPreviousCustomPromptText)
    UserDefaults.standard.set(prompt, forKey: UserDefaultsKeys.customPromptText)
    var data = viewModel.data
    data.customPromptText = prompt
    viewModel.data = data
  }

  private func restorePreviousDictationPrompt() {
    guard let previous = UserDefaults.standard.string(forKey: UserDefaultsKeys.previousCustomPromptText) else { return }
    let current = viewModel.data.customPromptText
    UserDefaults.standard.set(current, forKey: UserDefaultsKeys.previousCustomPromptText)
    UserDefaults.standard.set(previous, forKey: UserDefaultsKeys.customPromptText)
    var data = viewModel.data
    data.customPromptText = previous
    viewModel.data = data
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
    let current = viewModel.data.dictationDifficultWords
    UserDefaults.standard.set(current, forKey: UserDefaultsKeys.previousDictationDifficultWords)
    UserDefaults.standard.set(previous, forKey: UserDefaultsKeys.dictationDifficultWords)
    var data = viewModel.data
    data.dictationDifficultWords = previous
    viewModel.data = data
  }

  private func applySuggestedUserContext(_ context: String) {
    let contextDir = UserContextLogger.shared.directoryURL
    let fileURL = contextDir.appendingPathComponent("user-context.md")
    let current = (try? String(contentsOf: fileURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    UserDefaults.standard.set(current, forKey: UserDefaultsKeys.previousUserContext)
    UserDefaults.standard.set(true, forKey: UserDefaultsKeys.hasPreviousUserContext)
    try? context.write(to: fileURL, atomically: true, encoding: .utf8)
  }

  private func restorePreviousUserContext() {
    guard let previous = UserDefaults.standard.string(forKey: UserDefaultsKeys.previousUserContext) else { return }
    let contextDir = UserContextLogger.shared.directoryURL
    let fileURL = contextDir.appendingPathComponent("user-context.md")
    let current = (try? String(contentsOf: fileURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    UserDefaults.standard.set(current, forKey: UserDefaultsKeys.previousUserContext)
    if previous.isEmpty {
      try? FileManager.default.removeItem(at: fileURL)
    } else {
      try? previous.write(to: fileURL, atomically: true, encoding: .utf8)
    }
  }

  private func loadSuggestions() {
    userContextFeedback = nil
    systemPromptFeedback = nil
    promptAndReadFeedback = nil
    dictationPromptFeedback = nil
    difficultWordsFeedback = nil

    let contextDir = UserContextLogger.shared.directoryURL

    let userContextURL = contextDir.appendingPathComponent("suggested-user-context.md")
    if FileManager.default.fileExists(atPath: userContextURL.path),
       let content = try? String(contentsOf: userContextURL, encoding: .utf8),
       !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      suggestedUserContext = content.trimmingCharacters(in: .whitespacesAndNewlines)
    } else {
      suggestedUserContext = nil
    }

    let promptURL = contextDir.appendingPathComponent("suggested-prompt-mode-system-prompt.txt")
    if FileManager.default.fileExists(atPath: promptURL.path),
       let content = try? String(contentsOf: promptURL, encoding: .utf8),
       !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      suggestedSystemPrompt = content.trimmingCharacters(in: .whitespacesAndNewlines)
    } else {
      suggestedSystemPrompt = nil
    }

    let promptAndReadURL = contextDir.appendingPathComponent("suggested-prompt-and-read-system-prompt.txt")
    if FileManager.default.fileExists(atPath: promptAndReadURL.path),
       let content = try? String(contentsOf: promptAndReadURL, encoding: .utf8),
       !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      suggestedPromptAndReadSystemPrompt = content.trimmingCharacters(in: .whitespacesAndNewlines)
    } else {
      suggestedPromptAndReadSystemPrompt = nil
    }

    let dictationURL = contextDir.appendingPathComponent("suggested-dictation-prompt.txt")
    if FileManager.default.fileExists(atPath: dictationURL.path),
       let content = try? String(contentsOf: dictationURL, encoding: .utf8),
       !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      suggestedDictationPrompt = content.trimmingCharacters(in: .whitespacesAndNewlines)
    } else {
      suggestedDictationPrompt = nil
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
