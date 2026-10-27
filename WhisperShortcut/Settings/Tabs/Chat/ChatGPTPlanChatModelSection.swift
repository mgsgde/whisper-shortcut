import SwiftUI

/// Which model Chat uses on the ChatGPT plan. Shown in Settings → Chat while "ChatGPT plan" is the
/// selected chat model.
///
/// No credential here: the account is signed in once in Settings → Accounts
/// (`ChatGPTPlanConnectionSection`); this section only reports that and picks the model from the
/// list OpenAI returns for the signed-in account.
struct ChatGPTPlanChatModelSection: View {
  @ObservedObject private var service = ChatGPTPlanOAuthService.shared

  @State private var models: [ChatGPTPlanModelCatalog.Entry] = ChatGPTPlanModelCatalog.cachedModels()
  @State private var modelID: String = ChatGPTPlanPreferences.modelID
  @State private var isLoading = false
  @State private var loadError: String?

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "ChatGPT plan",
        systemImage: "person.crop.circle.badge.checkmark",
        subtitle: "Chat runs on your ChatGPT Plus or Pro plan and counts toward its usage limits."
      )

      ChatGPTPlanAccountStatusRow()

      HStack(alignment: .center, spacing: 16) {
        Text("Model:")
          .font(.body)
          .fontWeight(.medium)
          .frame(width: SettingsConstants.labelWidth, alignment: .leading)

        modelPicker

        if isLoading {
          ProgressView()
            .controlSize(.small)
        }

        Spacer()
      }

      if let loadError {
        Text(loadError)
          .font(.caption)
          .foregroundColor(.red)
          .fixedSize(horizontal: false, vertical: true)
      }

      HStack(alignment: .firstTextBaseline, spacing: 4) {
        Text("Text and images only for now: web search and connected services (Google, Trello, mail) don't run on the ChatGPT plan yet. Limits:")
          .font(.caption)
          .foregroundColor(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        Link("ChatGPT Settings → Usage", destination: ChatGPTPlanOAuthConfig.usageSettingsURL)
          .font(.caption)
          .pointerCursorOnHover()
      }
    }
    .onAppear {
      modelID = ChatGPTPlanPreferences.modelID
      reload()
    }
    .onChange(of: service.accountEmail) { _, _ in reload() }
    // An AI app may have changed this through MCP while the window was open.
    .onReceive(NotificationCenter.default.publisher(for: .settingsChangedExternally)) { _ in
      modelID = ChatGPTPlanPreferences.modelID
    }
  }

  private var currentModelLabel: String {
    models.first(where: { $0.slug == modelID })?.displayName ?? ChatGPTPlanPreferences.displayName
  }

  private var modelPicker: some View {
    Menu {
      ForEach(models, id: \.slug) { model in
        Button {
          modelID = model.slug
          ChatGPTPlanPreferences.setModelID(model.slug)
        } label: {
          if model.slug == modelID {
            Label(model.displayName, systemImage: "checkmark")
          } else {
            Text(model.displayName)
          }
        }
      }
      if models.isEmpty {
        Text(service.planEnabled ? "No models loaded yet" : "Sign in to see your models")
      }
    } label: {
      HStack {
        Text(currentModelLabel)
          .lineLimit(1)
          .truncationMode(.middle)
        Spacer()
      }
    }
    .frame(maxWidth: SettingsConstants.apiKeyMaxWidth)
    .disabled(models.isEmpty)
  }

  /// Loads the account's model list. Only runs while plan use is on; the cached list keeps the
  /// picker populated across launches and while offline.
  private func reload() {
    guard service.planEnabled, !service.needsSignIn, !isLoading else { return }
    isLoading = true
    loadError = nil
    Task {
      do {
        let fresh = try await ChatGPTPlanModelCatalog.refresh()
        if !fresh.isEmpty { models = fresh }
        modelID = ChatGPTPlanPreferences.modelID
      } catch {
        // A stale list is still useful; only say something when there is nothing to show.
        if models.isEmpty { loadError = "Couldn't load your ChatGPT models: \(error.localizedDescription)" }
      }
      isLoading = false
    }
  }
}
