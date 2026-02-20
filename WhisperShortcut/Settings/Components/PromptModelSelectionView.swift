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

  init(
    title: String,
    subtitle: String? = nil,
    showSectionHeader: Bool = true,
    selectedModel: Binding<PromptModel>,
    onModelChanged: (() -> Void)? = nil
  ) {
    self.title = title
    self.subtitle = subtitle
    self.showSectionHeader = showSectionHeader
    self._selectedModel = selectedModel
    self.onModelChanged = onModelChanged
  }

  private var effectiveSubtitle: String {
    subtitle ?? "Choose between GPT-Audio and Gemini multimodal models for direct audio input processing"
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

      // Model Selection Grid
      LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 2), spacing: SettingsConstants.modelSpacing) {
        ForEach(PromptModel.allCases, id: \.self) { model in
          ZStack {
            Rectangle()
              .fill(selectedModel == model ? Color.accentColor : Color.clear)
              .cornerRadius(SettingsConstants.cornerRadius)

            Text(model.displayName)
              .font(.system(.body, design: .default))
              .fontWeight(.medium)
              .foregroundColor(selectedModel == model ? .white : .primary)
          }
          .frame(maxWidth: .infinity, minHeight: SettingsConstants.modelSelectionHeight)
          .contentShape(Rectangle())
          .onTapGesture {
            
            selectedModel = model
            onModelChanged?()
          }
        }
      }
      .background(Color(.controlBackgroundColor))
      .cornerRadius(8)
      .overlay(
        RoundedRectangle(cornerRadius: 8)
          .stroke(Color(.separatorColor), lineWidth: 1)
      )

      // Model Details
      VStack(alignment: .leading, spacing: 8) {
        Text(selectedModel.description)
          .font(.callout)
          .foregroundColor(.secondary)
          .textSelection(.enabled)

        HStack {
          Text("Cost:")
            .font(.callout)
            .fontWeight(.medium)
            .foregroundColor(.secondary)

          Text(selectedModel.costLevel)
            .font(.callout)
            .fontWeight(.semibold)
            .foregroundColor(costLevelColor(for: selectedModel.costLevel))
        }

        if selectedModel.isRecommended {
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

