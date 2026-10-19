import SwiftUI

/// Chat Settings Tab — model, prompt, commands, memory and folders. Meetings and the
/// connected services (Google, Trello, mail) have their own tabs.
struct ChatSettingsTab: View {
  @ObservedObject var viewModel: SettingsViewModel
  @FocusState.Binding var focusedField: SettingsFocusField?

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      modelSection

      // Provider-specific setup appears under the picker only for the provider in use, the way
      // Settings → Dictate does it — neither is needed by anyone on a built-in model.
      switch viewModel.data.selectedChatModel.provider {
      case .openRouter:
        SpacedSectionDivider()
        OpenRouterChatModelSection()
      case .customOpenAI:
        SpacedSectionDivider()
        CustomOpenAIChatEndpointSection()
      default:
        EmptyView()
      }

      SpacedSectionDivider()

      ClaudeWebSearchSection()

      SpacedSectionDivider()

      // Chat system prompt editor
      SystemPromptSectionEditor(
        title: "System Prompt",
        systemImage: "text.alignleft",
        subtitle: "Instructions sent to the model in Chat mode. Edit to customize chat behavior.",
        section: .chat,
        defaultContent: AppConstants.defaultChatSystemPrompt
      )

      SpacedSectionDivider()

      UserCommandsSection()

      SpacedSectionDivider()

      ChatMemoryEditor()

      SpacedSectionDivider()

      WorkspaceFoldersSection()

      SpacedSectionDivider()

      usageSection

      SpacedSectionDivider()

      // Knobs most people never touch: the defaults are the tuned choice, and every visible row is
      // one more thing a new user has to read past. Values are unchanged — only where they live.
      AdvancedSettingsGroup {
        XSearchHandlesSection()
        windowBehaviorSection
      }
    }
  }

  // MARK: - Model Section
  @ViewBuilder
  private var modelSection: some View {
    PromptModelSelectionView(
      title: "Chat Model",
      subtitle: "Choose which model powers the chat. API keys and your OpenRouter account are set in Settings → Accounts. “Custom endpoint” is for your own OpenAI-compatible server and is set up below once you pick it.",
      selectedModel: $viewModel.data.selectedChatModel,
      availableModels: PromptModel.chatModels,
      recommendedModel: SettingsDefaults.selectedChatModel,
      subscriptionMode: false,
      onModelChanged: {
        UserDefaults.standard.set(
          viewModel.data.selectedChatModel.rawValue,
          forKey: UserDefaultsKeys.selectedChatModel)
        NotificationCenter.default.post(
          name: .promptModelChanged,
          object: viewModel.data.selectedChatModel)
        Task {
          await viewModel.saveSettings()
        }
      }
    )
  }

  // MARK: - Window Behavior Section
  @ViewBuilder
  private var windowBehaviorSection: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "Window Behavior",
        systemImage: "macwindow",
        subtitle: "Control how the chat window behaves"
      )

      Toggle(isOn: $viewModel.data.chatCloseOnFocusLoss) {
        VStack(alignment: .leading, spacing: 2) {
          Text("Close Chat when clicking outside")
            .font(.callout)
          Text("Closes Chat when another app is focused. Pin the window with /pin if you want it to stay open.")
            .font(.caption)
            .foregroundColor(.secondary)
        }
      }
      .toggleStyle(.switch)
      .onChange(of: viewModel.data.chatCloseOnFocusLoss) { _ in
        Task { await viewModel.saveSettings() }
      }
    }
  }

  // MARK: - Usage Section
  @ViewBuilder
  private var usageSection: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "How to Use",
        systemImage: "questionmark.circle",
        subtitle: nil
      )

      ShortcutHintRow(label: "Shortcut:", shortcut: viewModel.data.openChat)

      VStack(alignment: .leading, spacing: 8) {
        Text("Use the shortcut or the menu bar item \"Chat\" to open the chat window.")
          .textSelection(.enabled)
        Text("Type / in the chat to see its commands. Meetings are set up in Settings → Meetings.")
          .textSelection(.enabled)
      }
      .font(.callout)
      .foregroundColor(.secondary)
    }
  }
}
