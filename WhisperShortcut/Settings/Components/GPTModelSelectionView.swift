import SwiftUI

/// Wiederverwendbare Komponente für die GPT-Audio-Modellauswahl
struct GPTModelSelectionView: View {
  let title: String
  @Binding var selectedModel: GPTAudioModel
  let onModelChanged: (() -> Void)?

  init(
    title: String,
    selectedModel: Binding<GPTAudioModel>,
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
        subtitle: "Choose between GPT-Audio Mini (fast & cheap) or GPT-Audio (best quality)"
      )

      HStack(spacing: SettingsConstants.modelSpacing) {
        ForEach(GPTAudioModel.allCases, id: \.self) { model in
          ZStack {
            Rectangle()
              .fill(selectedModel == model ? Color.accentColor : Color.clear)
              .cornerRadius(SettingsConstants.cornerRadius)

            Text(model.displayName)
              .font(.system(.body, design: .default))
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
      .frame(height: SettingsConstants.modelSelectionHeight)

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
  struct GPTModelSelectionView_Previews: PreviewProvider {
    static var previews: some View {
      @State var selectedModel: GPTAudioModel = .gptAudioMini

      GPTModelSelectionView(title: "GPT-Audio Model", selectedModel: $selectedModel)
        .padding()
        .frame(width: 600)
    }
  }
#endif
