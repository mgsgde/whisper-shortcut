import SwiftUI

/// Chat Settings Tab — model, prompt, commands, memory and folders. Meetings and the
/// connected services (Google, Trello, mail) have their own tabs.
struct ChatSettingsTab: View {
  @ObservedObject var viewModel: SettingsViewModel
  @FocusState.Binding var focusedField: SettingsFocusField?

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      modelSection

      SpacedSectionDivider()

      appearanceSection

      // Provider-specific setup appears under the picker only for the provider in use, the way
      // Settings → Dictate does it — neither is needed by anyone on a built-in model.
      switch viewModel.data.selectedChatModel.provider {
      case .openRouter:
        SpacedSectionDivider()
        OpenRouterChatModelSection()
      case .customOpenAI:
        SpacedSectionDivider()
        OwnServerEndpointSection(route: .chat)
      case .chatGPTPlan:
        SpacedSectionDivider()
        ChatGPTPlanChatModelSection()
      default:
        EmptyView()
      }

      SpacedSectionDivider()

      titleStyleSection

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
        windowBehaviorSection
      }
    }
  }

  // MARK: - Model Section
  @ViewBuilder
  private var modelSection: some View {
    PromptModelSelectionView(
      title: "Chat Model",
      subtitle: "Which model answers in the chat. Keys and accounts live under Accounts.",
      selectedModel: $viewModel.data.selectedChatModel,
      availableModels: PromptModel.chatModels,
      recommendedModel: SettingsDefaults.selectedChatModel,
      subscriptionMode: false,
      onModelChanged: {
        Task {
          await viewModel.saveSettings()
        }
      }
    )
  }

  // MARK: - Appearance Section
  @ViewBuilder
  private var appearanceSection: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "Appearance",
        systemImage: "textformat",
        subtitle: "The typeface the chat writes in. Sans is the macOS system font; Serif and Rounded are Apple's other system designs."
      )

      Picker("Chat Font", selection: $viewModel.data.chatFontDesign) {
        ForEach(ChatFontDesign.allCases, id: \.self) { design in
          Text(design.displayName)
            .tag(design)
        }
      }
      .pickerStyle(.menu)
      .frame(maxWidth: .infinity, alignment: .leading)
      .onChange(of: viewModel.data.chatFontDesign) {
        Task {
          await viewModel.saveSettings()
        }
      }

      Toggle(isOn: $viewModel.data.chatFollowNewContent) {
        VStack(alignment: .leading, spacing: 2) {
          Text("Scroll along with new text")
            .font(.callout)
          Text("Keeps the newest text in view while a reply or live meeting notes are being written. Scrolling up stops it.")
            .font(.caption)
            .foregroundColor(.secondary)
        }
      }
      .toggleStyle(.switch)
      .onChange(of: viewModel.data.chatFollowNewContent) { _ in
        Task { await viewModel.saveSettings() }
      }
    }
  }

  // MARK: - Title Style Section
  /// Where the date-based naming lives. Deliberately a top-level section rather than a row inside
  /// Advanced: the people who want it are the ones writing meeting notes, and they should not have
  /// to know that a collapsed "Advanced" group exists to find it.
  @ViewBuilder
  private var titleStyleSection: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "Session Titles",
        systemImage: "textformat.123",
        subtitle: "How chat and meeting rows are named in the sidebar."
      )

      HStack(alignment: .center, spacing: 16) {
        Text("Title:")
          .font(.body)
          .fontWeight(.medium)
          .frame(width: SettingsConstants.labelWidth, alignment: .leading)

        Picker("", selection: $viewModel.data.chatTitleStyle) {
          ForEach(ChatTitleStyle.allCases, id: \.self) { style in
            Text(style.displayName).tag(style)
          }
        }
        .pickerStyle(MenuPickerStyle())
        .frame(width: 200)
        .onChange(of: viewModel.data.chatTitleStyle) { _ in
          Task { await viewModel.saveSettings() }
        }

        Spacer()
      }

      Text("Date styles put the day in front of the row, e.g. \"2026-11-03 Topic\". Meetings use the day they were recorded. Existing titles are not changed.")
        .font(.callout)
        .foregroundColor(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  // MARK: - Window Behavior Section
  @ViewBuilder
  private var windowBehaviorSection: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "Window Behavior",
        systemImage: "macwindow",
        subtitle: nil
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
