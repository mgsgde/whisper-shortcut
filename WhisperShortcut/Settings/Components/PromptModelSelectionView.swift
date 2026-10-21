import SwiftUI

/// Unified model selection component for Dictate Prompt (GPT-Audio and Gemini multimodal models) and Smart Improvement.
struct PromptModelSelectionView: View {
  let title: String
  /// Optional SF Symbol shown next to the section header title.
  let systemImage: String?
  /// When nil, uses the default Dictate Prompt subtitle.
  let subtitle: String?
  /// When false, renders a small label instead of SectionHeader (e.g. when embedded in another section).
  let showSectionHeader: Bool
  @Binding var selectedModel: PromptModel
  let onModelChanged: (() -> Void)?
  /// When true, user is on subscription (proxy); model selection is fixed by the backend. All options disabled.
  let subscriptionMode: Bool
  /// When in subscription mode, optional custom text for the fixed model (e.g. "The chat window uses Gemini 3.1 Flash-Lite (fixed)."). If nil, shows Dictate Prompt / Smart Improvement text.
  let subscriptionFixedModelDescription: String?
  /// When in subscription mode, if set, this model is shown as selected in the grid and used for Model Details (so only this tile is highlighted, others grayed out).
  let subscriptionEffectiveModel: PromptModel?
  /// Models to display. When nil, shows all `PromptModel.allCases`.
  let availableModels: [PromptModel]?
  /// Model to mark with the "Recommended" star. Required — every role passes its own
  /// `SettingsDefaults` value. It used to default to the Dictate Prompt default, which
  /// silently made Smart Improvement star a model that was not its default.
  let recommendedModel: PromptModel
  @ObservedObject private var mlxManager = LocalLLMModelManager.shared

  init(
    title: String,
    systemImage: String? = nil,
    subtitle: String? = nil,
    showSectionHeader: Bool = true,
    selectedModel: Binding<PromptModel>,
    availableModels: [PromptModel]? = nil,
    recommendedModel: PromptModel,
    subscriptionMode: Bool = false,
    subscriptionFixedModelDescription: String? = nil,
    subscriptionEffectiveModel: PromptModel? = nil,
    onModelChanged: (() -> Void)? = nil
  ) {
    self.title = title
    self.systemImage = systemImage
    self.subtitle = subtitle
    self.showSectionHeader = showSectionHeader
    self._selectedModel = selectedModel
    self.availableModels = availableModels
    self.recommendedModel = recommendedModel
    self.subscriptionMode = subscriptionMode
    self.subscriptionFixedModelDescription = subscriptionFixedModelDescription
    self.subscriptionEffectiveModel = subscriptionEffectiveModel
    self.onModelChanged = onModelChanged
  }

  private var models: [PromptModel] {
    availableModels ?? PromptModel.dictatePromptCapableModels
  }

  /// Model to show as selected and for details: when in subscription with a fixed model, use that; otherwise use the binding.
  private var displayModel: PromptModel {
    if subscriptionMode, let effective = subscriptionEffectiveModel { return effective }
    return selectedModel
  }

  private var effectiveSubtitle: String {
    if subscriptionMode {
      if let custom = subscriptionFixedModelDescription {
        return "In subscription mode, model selection is not available. \(custom)"
      }
      return "In subscription mode, model selection is not available. Dictate Prompt uses Gemini 3.1 Flash-Lite; Smart Improvement uses \(subscriptionEffectiveModel?.displayName ?? "Gemini 3 Flash") (fixed)."
    }
    return subtitle ?? "Choose the model that hears your spoken instruction and applies it to the selected text"
  }

  private var subscriptionModeFixedModelLine: String {
    if let custom = subscriptionFixedModelDescription { return custom }
    return "Dictate Prompt: Gemini 3.1 Flash-Lite · Smart Improvement: \(subscriptionEffectiveModel?.displayName ?? "Gemini 3 Flash") (fixed)"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      if showSectionHeader {
        SectionHeader(
          title: title,
          systemImage: systemImage,
          subtitle: effectiveSubtitle
        )
      } else {
        VStack(alignment: .leading, spacing: 8) {
          Text(title)
            .font(.callout)
            .fontWeight(.medium)
          Text(effectiveSubtitle)
            .font(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }

      if subscriptionMode {
        Text(subscriptionModeFixedModelLine)
          .font(.callout)
          .foregroundColor(.secondary)
          .textSelection(.enabled)
          .padding(.vertical, 4)
      }

      CuratedModelPicker(
        curation: ModelPickerCuration(models: models, recommended: recommendedModel, selected: displayModel),
        cell: { model, badges in modelCell(model, badges: badges) },
        more: { groupedGrids($0) })

      if let downloading = LocalLLMModelType.offerable.first(where: { mlxManager.downloadingModels.contains($0) }) {
        HStack {
          let fraction = mlxManager.downloadProgress[downloading] ?? 0
          Text(fraction > 0 ? "Downloading \(downloading.displayName)… \(Int(fraction * 100))%" : "Starting \(downloading.displayName)…")
            .font(.callout)
            .foregroundColor(.secondary)
          Spacer()
          Button("Cancel") {
            mlxManager.cancelDownload(downloading)
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
          .pointerCursorOnHover()
        }
      }

      if models.contains(where: { $0.localMLXModelType != nil }) {
        LocalLLMModelsSection(models: models.compactMap(\.localMLXModelType))
      }

      // Model Details (use displayModel so subscription shows the fixed model's description and cost)
      VStack(alignment: .leading, spacing: 8) {
        Text(displayModel.description)
          .font(.callout)
          .foregroundColor(.secondary)
          .textSelection(.enabled)

        HStack {
          Text("Cost:")
            .font(.callout)
            .fontWeight(.medium)
            .foregroundColor(.secondary)

          Text(displayModel.costLevel)
            .font(.callout)
            .fontWeight(.semibold)
            .foregroundColor(SettingsConstants.costLevelColor(for: displayModel.costLevel))
        }

        HStack(alignment: .firstTextBaseline, spacing: 4) {
          Text("Tip: Compare models (speed, intelligence, pricing):")
            .font(.caption)
            .foregroundColor(.secondary)
          if let url = URL(string: AppConstants.geminiModelsComparisonURL) {
            Link("gemini-models", destination: url)
              .font(.caption)
              .lineLimit(1)
              .pointerCursorOnHover()
          }
        }
      }
    }
  }

  // MARK: - Grouping

  private struct ModelGroup {
    let symbol: String
    let title: String
    let subtitle: String?
    let models: [PromptModel]
  }

  /// The "More models" remainder, grouped by provider with image-generation models split out
  /// (Nano Banana generates images, not chat replies). A single group renders as a plain grid.
  @ViewBuilder
  private func groupedGrids(_ models: [PromptModel]) -> some View {
    let groups = Self.modelGroups(models)
    VStack(alignment: .leading, spacing: 0) {
      if groups.count > 1 {
        ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
          if index > 0 { Divider().padding(.vertical, 10) }
          groupHeader(symbol: group.symbol, title: group.title, subtitle: group.subtitle)
          modelGrid(group.models)
        }
      } else {
        modelGrid(models)
      }
    }
  }

  /// Models split into provider groups (Gemini / Grok / OpenAI), preserving order, with
  /// image-generation models pulled into their own trailing group. Empty groups are dropped.
  private static func modelGroups(_ models: [PromptModel]) -> [ModelGroup] {
    let textModels = models.filter { !$0.generatesImages }
    let imageModels = models.filter { $0.generatesImages }

    let providerOrder: [(ChatModelProvider, String, String, String?)] = [
      (.gemini, "sparkles", "Gemini", nil),
      (.grok, "bolt.fill", "Grok (xAI)", nil),
      (.openai, "brain", "OpenAI", nil),
      (.anthropic, "quote.bubble", "Claude (Anthropic)", nil),
      (.chatGPTPlan, "person.crop.circle.badge.checkmark", "ChatGPT plan", "Your ChatGPT Plus or Pro plan · no API key"),
      (.openRouter, "arrow.triangle.branch", "OpenRouter", "Any model on your OpenRouter account"),
      (.customOpenAI, "network", "Custom endpoint", "Your own OpenAI-compatible server"),
      (.localMLX, "desktopcomputer", "Offline", "Runs on your Mac · nothing to install"),
      (.local, "server.rack", "Local Server", "Your own Ollama / LM Studio · any model you have pulled"),
    ]

    var groups: [ModelGroup] = providerOrder.compactMap { provider, symbol, title, subtitle in
      let group = textModels.filter { $0.provider == provider }
      guard !group.isEmpty else { return nil }
      return ModelGroup(symbol: symbol, title: title, subtitle: subtitle, models: group)
    }

    if !imageModels.isEmpty {
      groups.append(ModelGroup(symbol: "photo", title: "Image generation",
                               subtitle: "Generates images, not chat replies", models: imageModels))
    }
    return groups
  }

  @ViewBuilder
  private func groupHeader(symbol: String, title: String, subtitle: String?) -> some View {
    ModelGroupHeader(symbol: symbol, title: title, subtitle: subtitle)
  }

  private func modelGrid(_ models: [PromptModel]) -> some View {
    ModelGrid(models: models) { modelCell($0, badges: []) }
  }

  @ViewBuilder
  private func modelCell(_ model: PromptModel, badges: [ModelPickerBadge]) -> some View {
    ModelTile(
      title: model.displayName,
      subtitle: mlxTileSubtitle(for: model),
      isSelected: displayModel == model,
      isDisabled: subscriptionMode,
      // `badges` comes from the curation, whose Recommended is this picker's `recommendedModel`.
      // Letting an MLX model carry its own catalogue star put a second star into Smart
      // Improvement and meeting-summary pickers, whose recommendation is a cloud model — the
      // exact confusion the `recommendedModel` doc above was introduced to end. The catalogue's
      // own star lives in `LocalLLMModelsSection`, where it means "best offline model".
      badges: badges,
      setupBadge: subscriptionMode ? nil : model.pickerSetupBadge,
      setupHelp: model.provider.credentialRequiredMessage,
      onTap: {
        selectedModel = model
        onModelChanged?()
      }
    )
  }

  private func mlxTileSubtitle(for model: PromptModel) -> String? {
    guard let type = model.localMLXModelType else { return nil }
    if mlxManager.downloadingModels.contains(type) {
      if let fraction = mlxManager.downloadProgress[type] {
        return "Downloading… \(Int(fraction * 100))%"
      }
      return "Downloading…"
    }
    return mlxManager.isModelAvailable(type) ? nil : "Not downloaded"
  }

}

