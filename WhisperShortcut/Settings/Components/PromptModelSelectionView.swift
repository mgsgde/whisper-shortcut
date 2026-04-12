import SwiftUI

/// Unified model selection component for Prompt Mode (GPT-Audio and Gemini multimodal models) and Smart Improvement.
struct PromptModelSelectionView: View {
  let title: String
  /// When nil, uses the default Prompt Mode subtitle.
  let subtitle: String?
  /// When false, renders a small label instead of SectionHeader (e.g. when embedded in another section).
  let showSectionHeader: Bool
  @Binding var selectedModel: PromptModel
  let onModelChanged: (() -> Void)?
  /// When true, user is on subscription (proxy); model selection is fixed by the backend. All options disabled.
  let subscriptionMode: Bool
  /// When in subscription mode, optional custom text for the fixed model (e.g. "The Open Gemini window uses Gemini 3.1 Flash-Lite (fixed)."). If nil, shows Dictate Prompt / Smart Improvement text.
  let subscriptionFixedModelDescription: String?
  /// When in subscription mode, if set, this model is shown as selected in the grid and used for Model Details (so only this tile is highlighted, others grayed out).
  let subscriptionEffectiveModel: PromptModel?
  /// Models to display. When nil, shows all `PromptModel.allCases`.
  let availableModels: [PromptModel]?

  init(
    title: String,
    subtitle: String? = nil,
    showSectionHeader: Bool = true,
    selectedModel: Binding<PromptModel>,
    availableModels: [PromptModel]? = nil,
    subscriptionMode: Bool = false,
    subscriptionFixedModelDescription: String? = nil,
    subscriptionEffectiveModel: PromptModel? = nil,
    onModelChanged: (() -> Void)? = nil
  ) {
    self.title = title
    self.subtitle = subtitle
    self.showSectionHeader = showSectionHeader
    self._selectedModel = selectedModel
    self.availableModels = availableModels
    self.subscriptionMode = subscriptionMode
    self.subscriptionFixedModelDescription = subscriptionFixedModelDescription
    self.subscriptionEffectiveModel = subscriptionEffectiveModel
    self.onModelChanged = onModelChanged
  }

  private var models: [PromptModel] {
    availableModels ?? PromptModel.geminiOnlyModels
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

      // Model Selection Grid (when subscription + effectiveModel set, only that model is highlighted; others grayed out)
      LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 2), spacing: SettingsConstants.modelSpacing) {
        ForEach(models, id: \.self) { model in
          let isDisabled = subscriptionMode
          let isSelected = displayModel == model
          ZStack {
            Rectangle()
              .fill(isSelected ? Color.accentColor : Color.clear)
              .cornerRadius(SettingsConstants.cornerRadius)

            Text(model.displayName)
              .font(.system(.body, design: .default))
              .fontWeight(.medium)
              .foregroundColor(isSelected ? .white : (isDisabled ? .secondary : .primary))
          }
          .frame(maxWidth: .infinity, minHeight: SettingsConstants.modelSelectionHeight)
          .contentShape(Rectangle())
          .opacity(isDisabled && !isSelected ? 0.6 : 1)
          .onTapGesture {
            if isDisabled { return }
            selectedModel = model
            onModelChanged?()
          }
          .pointerCursorOnHover()
        }
      }
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
            .foregroundColor(costLevelColor(for: displayModel.costLevel))
        }

        if displayModel.isRecommended {
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

  // MARK: - Helper Functions
  private func costLevelColor(for costLevel: String) -> Color {
    switch costLevel {
    case "Minimal":
      return .green
    case "Low":
      return .green
    case "Medium":
      return .orange
    case "High":
      return .red
    default:
      return .secondary
    }
  }
}

