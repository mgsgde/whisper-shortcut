import SwiftUI

/// Reusable component for transcription model selection.
struct ModelSelectionView: View {
  @Binding var selectedTranscriptionModel: TranscriptionModel
  let title: String
  let systemImage: String?
  let models: [TranscriptionModel]
  let onModelChanged: (() -> Void)?
  /// When true, Gemini models are shown as disabled and cannot be selected (e.g. when no API key is set).
  let geminiDisabled: Bool
  /// When true, OpenAI cloud transcription models are shown as disabled (e.g. when no OpenAI API key is set).
  let openAIDisabled: Bool
  /// When true, xAI (Grok) transcription models are shown as disabled (e.g. when no xAI API key is set).
  let xaiDisabled: Bool
  /// When true, user is on subscription (proxy); only Gemini models are fixed; offline Whisper models remain selectable.
  let subscriptionMode: Bool

  init(
    title: String = "Transcription Model",
    systemImage: String? = nil,
    selectedTranscriptionModel: Binding<TranscriptionModel>,
    models: [TranscriptionModel] = TranscriptionModel.selectableForDictation,
    geminiDisabled: Bool = false,
    openAIDisabled: Bool = false,
    xaiDisabled: Bool = false,
    subscriptionMode: Bool = false,
    onModelChanged: (() -> Void)? = nil
  ) {
    self.title = title
    self.systemImage = systemImage
    self._selectedTranscriptionModel = selectedTranscriptionModel
    self.models = models
    self.geminiDisabled = geminiDisabled
    self.openAIDisabled = openAIDisabled
    self.xaiDisabled = xaiDisabled
    self.subscriptionMode = subscriptionMode
    self.onModelChanged = onModelChanged
  }

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: title,
        systemImage: systemImage,
        subtitle: subscriptionMode
          ? "With a subscription, cloud transcription uses Gemini 2.5 Flash. You can also choose an offline Whisper model for local transcription."
          : "Choose the transcription model for speech recognition"
      )

      if subscriptionMode {
        Text("Cloud: Gemini 2.5 Flash (fixed). Offline: select any Whisper model above.")
          .font(.callout)
          .foregroundColor(.secondary)
          .textSelection(.enabled)
          .padding(.vertical, 8)
      }

      // Grouped by `TranscriptionProvider.Group` rather than the old cloud/offline split.
      //
      // The split that mattered was never cloud vs. offline — it was **direct vs. routed**.
      // "Gemini 3.5 Flash-Lite" is a tile here *and* an entry in OpenRouter's own model list below,
      // and with one undifferentiated "Cloud" block nothing said that the tile bills your Google key
      // while the router bills your OpenRouter balance. Naming the groups is what removes that.
      let visibleGroups = Self.groupOrder.compactMap { group -> (TranscriptionProvider.Group, [TranscriptionModel])? in
        let matching = models.filter { $0.provider.group == group }
        return matching.isEmpty ? nil : (group, matching)
      }
      let grouped = visibleGroups.count > 1

      VStack(alignment: .leading, spacing: 0) {
        if grouped {
          ForEach(Array(visibleGroups.enumerated()), id: \.offset) { index, entry in
            if index > 0 {
              Divider().padding(.vertical, 10)
            }
            groupHeader(
              symbol: Self.symbol(for: entry.0),
              title: Self.title(for: entry.0),
              subtitle: Self.subtitle(for: entry.0))
            modelGrid(entry.1)
          }
        } else {
          modelGrid(models)
        }
      }
      .padding(grouped ? 10 : 0)
      .background(Color(.controlBackgroundColor))
      .cornerRadius(8)
      .overlay(
        RoundedRectangle(cornerRadius: 8)
          .stroke(Color(.separatorColor), lineWidth: 1)
      )

      // Model Details
      VStack(alignment: .leading, spacing: 8) {
        Text(selectedTranscriptionModel.description)
          .font(.callout)
          .foregroundColor(.secondary)
          .textSelection(.enabled)

        HStack {
          Text("Cost:")
            .font(.callout)
            .fontWeight(.medium)
            .foregroundColor(.secondary)

          Text(selectedTranscriptionModel.costLevel)
            .font(.callout)
            .fontWeight(.semibold)
            .foregroundColor(SettingsConstants.costLevelColor(for: selectedTranscriptionModel.costLevel))
        }

        if selectedTranscriptionModel.isRecommended {
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

        if selectedTranscriptionModel.isDeprecated {
          HStack {
            Image(systemName: "exclamationmark.triangle.fill")
              .foregroundColor(.orange)
              .font(.caption)
            Text("Deprecated – no longer available to new users. Consider switching to Gemini 2.5 Flash.")
              .font(.callout)
              .foregroundColor(.secondary)
          }
        }

        HStack(alignment: .firstTextBaseline, spacing: 4) {
          Text("Tip: Compare Gemini models (speed, intelligence, pricing):")
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

  // MARK: - Group helpers

  /// Direct first (what most users want), routed second, offline last.
  private static let groupOrder: [TranscriptionProvider.Group] = [.direct, .routed, .offline]

  private static func symbol(for group: TranscriptionProvider.Group) -> String {
    switch group {
    case .direct: return "cloud"
    case .routed: return "arrow.triangle.branch"
    case .offline: return "desktopcomputer"
    }
  }

  private static func title(for group: TranscriptionProvider.Group) -> String {
    switch group {
    case .direct: return "Direct"
    case .routed: return "Routed"
    case .offline: return "Offline"
    }
  }

  private static func subtitle(for group: TranscriptionProvider.Group) -> String {
    switch group {
    case .direct: return "Billed to that provider's own API key"
    case .routed: return "One account or your own server · pick the model below"
    case .offline: return "Private · runs on your Mac"
    }
  }

  /// Second line for routed tiles: what the router is actually calling right now.
  ///
  /// Without it, "OpenRouter" reads as a model name sitting next to real model names — which is
  /// exactly the confusion this grouping is meant to end.
  private static func routedSubtitle(for model: TranscriptionModel) -> String? {
    switch model.provider {
    case .openRouter:
      let slug = TranscriptionTuning.openRouterModelID
      // Prefer the catalogue's display name; fall back to the raw slug before it loads.
      let name = OpenRouterModelCatalog.shared.audioModels.first { $0.id == slug }?.name
      return "→ \(name ?? slug)"
    case .selfHosted:
      let url = UserDefaults.standard.string(forKey: UserDefaultsKeys.customTranscriptionAPIURL)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      guard let host = URL(string: url)?.host, !host.isEmpty else { return "→ not configured" }
      return "→ \(host)"
    case .google, .openAI, .xai, .offline:
      return nil
    }
  }

  @ViewBuilder
  private func groupHeader(symbol: String, title: String, subtitle: String) -> some View {
    ModelGroupHeader(symbol: symbol, title: title, subtitle: subtitle)
  }

  private func modelGrid(_ models: [TranscriptionModel]) -> some View {
    ModelGrid(models: models) { modelCell($0) }
  }

  @ViewBuilder
  private func modelCell(_ model: TranscriptionModel) -> some View {
    let isDisabled = (geminiDisabled && model.isGemini) || (openAIDisabled && model.isOpenAI) || (xaiDisabled && model.isXAI)
    ModelTile(
      title: model.displayName,
      subtitle: Self.routedSubtitle(for: model),
      isSelected: selectedTranscriptionModel == model,
      isDisabled: isDisabled,
      isRecommended: model.isRecommended,
      onTap: {
        selectedTranscriptionModel = model
        onModelChanged?()
      }
    )
  }

}
