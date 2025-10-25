import SwiftUI

/// Unified model selection component for Prompt Mode (GPT-5 and GPT-Audio models)
struct PromptModelSelectionView: View {
  let title: String
  @Binding var selectedModel: PromptModel
  let onModelChanged: (() -> Void)?

  init(
    title: String,
    selectedModel: Binding<PromptModel>,
    onModelChanged: (() -> Void)? = nil
  ) {
    self.title = title
    self._selectedModel = selectedModel
    self.onModelChanged = onModelChanged
  }

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: title,
        subtitle: "Choose between GPT-5 models (text-based) and GPT-Audio models (direct audio input)"
      )

      // Model Selection Grid
      LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 2), spacing: SettingsConstants.modelSpacing) {
        ForEach(PromptModel.allCases, id: \.self) { model in
          ZStack {
            Rectangle()
              .fill(selectedModel == model ? Color.accentColor : Color.clear)
              .cornerRadius(SettingsConstants.cornerRadius)

            VStack(spacing: 4) {
              Text(model.displayName)
                .font(.system(.body, design: .default))
                .fontWeight(.medium)
                .foregroundColor(selectedModel == model ? .white : .primary)
            }
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

#if DEBUG
  struct PromptModelSelectionView_Previews: PreviewProvider {
    static var previews: some View {
      @State var selectedModel: PromptModel = .gpt5Mini

      PromptModelSelectionView(title: "Model Selection", selectedModel: $selectedModel)
        .padding()
        .frame(width: 600)
    }
  }
#endif
