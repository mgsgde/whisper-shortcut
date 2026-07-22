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
  /// Model to mark with the "Recommended" star. Defaults to the Dictate Prompt default, so a
  /// role with a different default (e.g. Chat) must pass its own `SettingsDefaults` value —
  /// otherwise the star would advertise another role's recommendation.
  let recommendedModel: PromptModel

  init(
    title: String,
    systemImage: String? = nil,
    subtitle: String? = nil,
    showSectionHeader: Bool = true,
    selectedModel: Binding<PromptModel>,
    availableModels: [PromptModel]? = nil,
    recommendedModel: PromptModel = SettingsDefaults.selectedPromptModel,
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
    return subtitle ?? "Choose between GPT-Audio and Gemini multimodal models for direct audio input processing"
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

      // Model Selection Grid, grouped by provider with image-generation models split out
      // (Nano Banana generates images, not chat replies). When only one group is present we
      // render a single plain grid so short lists keep their original look.
      let groups = modelGroups
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
      .padding(groups.count > 1 ? 10 : 0)
      .background(Color(.controlBackgroundColor))
      .cornerRadius(8)
      .overlay(
        RoundedRectangle(cornerRadius: 8)
          .stroke(Color(.separatorColor), lineWidth: 1)
      )

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

        if displayModel == recommendedModel {
          HStack {
            Image(systemName: "star.fill")
              .foregroundColor(.yellow)
              .font(.caption)
            Text("Recommended")
              .font(.callout)
              .fontWeight(.medium)
              .foregroundColor(.secondary)
          }
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

  /// Models split into provider groups (Gemini / Grok / OpenAI), preserving order, with
  /// image-generation models pulled into their own trailing group. Empty groups are dropped.
  private var modelGroups: [ModelGroup] {
    let textModels = models.filter { !$0.generatesImages }
    let imageModels = models.filter { $0.generatesImages }

    let providerOrder: [(ChatModelProvider, String, String)] = [
      (.gemini, "sparkles", "Gemini"),
      (.grok, "bolt.fill", "Grok (xAI)"),
      (.openai, "brain", "OpenAI"),
      (.anthropic, "quote.bubble", "Claude (Anthropic)"),
      (.customOpenAI, "arrow.triangle.branch", "Custom endpoint"),
      (.local, "desktopcomputer", "Local (Ollama / LM Studio)"),
    ]

    var groups: [ModelGroup] = providerOrder.compactMap { provider, symbol, title in
      let group = textModels.filter { $0.provider == provider }
      guard !group.isEmpty else { return nil }
      return ModelGroup(symbol: symbol, title: title, subtitle: nil, models: group)
    }

    if !imageModels.isEmpty {
      groups.append(ModelGroup(symbol: "photo", title: "Image generation",
                               subtitle: "Generates images, not chat replies", models: imageModels))
    }
    return groups
  }

  @ViewBuilder
  private func groupHeader(symbol: String, title: String, subtitle: String?) -> some View {
    HStack(spacing: 6) {
      Image(systemName: symbol)
        .font(.caption)
        .foregroundColor(.secondary)
      Text(title)
        .font(.callout)
        .fontWeight(.semibold)
      if let subtitle {
        Text("· \(subtitle)")
          .font(.caption)
          .foregroundColor(.secondary)
      }
    }
    .padding(.horizontal, 4)
    .padding(.bottom, 6)
  }

  private func modelGrid(_ models: [PromptModel]) -> some View {
    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 2), spacing: SettingsConstants.modelSpacing) {
      ForEach(models, id: \.self) { model in
        modelCell(model)
      }
    }
  }

  @ViewBuilder
  private func modelCell(_ model: PromptModel) -> some View {
    ModelTile(
      title: model.displayName,
      isSelected: displayModel == model,
      isDisabled: subscriptionMode,
      isRecommended: model == recommendedModel,
      onTap: {
        selectedModel = model
        onModelChanged?()
      }
    )
  }

}

