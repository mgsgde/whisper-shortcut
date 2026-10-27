import SwiftUI

/// Which OpenRouter model Chat talks to. Shown in Settings → Chat while OpenRouter is the selected
/// chat model.
///
/// Deliberately has **no credential field**. OpenRouter is one account, connected once in
/// Settings → Accounts and shared by Dictate and Chat; this section only reports whether that
/// connection exists and links to it. It replaces the old route of pointing the custom endpoint at
/// openrouter.ai, which gave OpenRouter a second key field and made the user type a URL and a slug.
struct OpenRouterChatModelSection: View {
  @ObservedObject private var catalog = OpenRouterModelCatalog.shared

  @State private var modelID: String = OpenRouterChatPreferences.modelID
  @State private var showCustomSlugField = false

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "OpenRouter",
        systemImage: "arrow.triangle.branch",
        subtitle: "Chat with any model OpenRouter routes to, billed to your OpenRouter account."
      )

      OpenRouterAccountStatusRow()

      HStack(alignment: .center, spacing: 16) {
        Text("Model:")
          .font(.body)
          .fontWeight(.medium)
          .frame(width: SettingsConstants.labelWidth, alignment: .leading)

        modelPicker

        Spacer()
      }

      catalogStatus

      if isCustomModelID || showCustomSlugField {
        HStack(alignment: .center, spacing: 16) {
          Text("Slug:")
            .font(.body)
            .fontWeight(.medium)
            .frame(width: SettingsConstants.labelWidth, alignment: .leading)

          TextField(SettingsDefaults.openRouterChatModelID, text: $modelID)
            .textFieldStyle(.roundedBorder)
            .font(.system(.body, design: .monospaced))
            .frame(height: SettingsConstants.textFieldHeight)
            .frame(maxWidth: SettingsConstants.apiKeyMaxWidth)
            .onSubmit { commit(modelID) }
            .onChange(of: modelID) { _, newValue in
              // Typing can pass through an empty field or a catalogue slug ("openai/gpt-4o" on the
              // way to "openai/gpt-4o-mini"); keep the field while the user is in it.
              showCustomSlugField = true
              commit(newValue)
            }

          Spacer()
        }
      }

      HStack(alignment: .firstTextBaseline, spacing: 4) {
        Text("Replies come through OpenRouter's chat API, so web search and image attachments aren't available here. Full catalogue:")
          .font(.caption)
          .foregroundColor(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        if let url = URL(string: "https://openrouter.ai/models") {
          Link("openrouter.ai/models", destination: url)
            .font(.caption)
            .pointerCursorOnHover()
        }
      }
    }
    .onAppear {
      catalog.loadIfNeeded()
      modelID = OpenRouterChatPreferences.modelID
    }
    // An AI app may have changed this through MCP while the window was open.
    .onReceive(NotificationCenter.default.publisher(for: .settingsChangedExternally)) { _ in
      modelID = OpenRouterChatPreferences.modelID
    }
  }

  // MARK: - Model selection

  /// OpenRouter lists hundreds of chat models; a flat menu that long is unusable, so they are
  /// grouped by the vendor prefix of the slug (`anthropic/…`, `google/…`).
  private var vendorGroups: [(vendor: String, models: [OpenRouterModel])] {
    let grouped = Dictionary(grouping: catalog.chatModels) { model in
      model.id.split(separator: "/").first.map(String.init) ?? model.id
    }
    return grouped
      .map { (vendor: $0.key, models: $0.value) }
      .sorted { $0.vendor.localizedCaseInsensitiveCompare($1.vendor) == .orderedAscending }
  }

  /// True when the stored slug is not in the catalogue — typed by hand, or the list has not
  /// loaded. The raw field must stay visible then, or a working setup would hide behind a picker
  /// that cannot show it.
  private var isCustomModelID: Bool {
    let current = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
    if current.isEmpty || catalog.chatModels.isEmpty { return false }
    return !catalog.chatModels.contains { $0.id == current }
  }

  private var currentModelLabel: String {
    let current = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
    let slug = current.isEmpty ? SettingsDefaults.openRouterChatModelID : current
    return catalog.chatModels.first(where: { $0.id == slug })?.name ?? slug
  }

  private var modelPicker: some View {
    Menu {
      ForEach(vendorGroups, id: \.vendor) { group in
        Menu(group.vendor) {
          ForEach(group.models) { model in
            Button {
              modelID = model.id
              showCustomSlugField = false
              commit(model.id)
            } label: {
              if let price = model.pricePerMillionLabel {
                Text("\(model.name) — \(price)")
              } else {
                Text(model.name)
              }
            }
          }
        }
      }

      if !catalog.chatModels.isEmpty {
        Divider()
      }

      Button("Custom slug…") {
        showCustomSlugField = true
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
    .disabled(catalog.isLoading)
  }

  @ViewBuilder
  private var catalogStatus: some View {
    if catalog.isLoading {
      HStack(spacing: 8) {
        ProgressView().controlSize(.small)
        Text("Loading OpenRouter's model list...")
          .font(.caption)
          .foregroundColor(.secondary)
      }
      .padding(.leading, SettingsConstants.labelWidth + 16)
    } else if let loadError = catalog.loadError {
      // The list is a convenience, not a gate: chat keeps working with the stored slug.
      HStack(spacing: 8) {
        Text("Couldn't load the model list (\(loadError)). Type a slug instead.")
          .font(.caption)
          .foregroundColor(.orange)
          .fixedSize(horizontal: false, vertical: true)
        Button("Retry") { Task { await catalog.reload() } }
          .buttonStyle(.link)
          .font(.caption)
        Button("Custom slug…") { showCustomSlugField = true }
          .buttonStyle(.link)
          .font(.caption)
      }
      .padding(.leading, SettingsConstants.labelWidth + 16)
    }
  }

  /// Read at request time, so the next chat message already uses it.
  private func commit(_ slug: String) {
    let trimmed = slug.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed != OpenRouterChatPreferences.modelID else { return }
    OpenRouterChatPreferences.setModelID(trimmed)
  }
}
