import SwiftUI

/// Wiederverwendbare Komponente für Model-Auswahl
struct ModelSelectionView: View {
  @Binding var selectedTranscriptionModel: TranscriptionModel
  let title: String
  let models: [TranscriptionModel]
  let onModelChanged: (() -> Void)?

  init(
    title: String = "Transcription Model",
    selectedTranscriptionModel: Binding<TranscriptionModel>,
    models: [TranscriptionModel] = TranscriptionModel.allCases,
    onModelChanged: (() -> Void)? = nil
  ) {
    self.title = title
    self._selectedTranscriptionModel = selectedTranscriptionModel
    self.models = models
    self.onModelChanged = onModelChanged
  }

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: title,
        subtitle: "Choose the transcription model for speech recognition"
      )

      LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 2), spacing: SettingsConstants.modelSpacing) {
        ForEach(models, id: \.self) { model in
          ZStack {
            Rectangle()
              .fill(selectedTranscriptionModel == model ? Color.accentColor : Color.clear)
              .cornerRadius(SettingsConstants.cornerRadius)

            Text(model.displayName)
              .font(.system(.body, design: .default))
              .fontWeight(.medium)
              .foregroundColor(selectedTranscriptionModel == model ? .white : .primary)
          }
          .frame(maxWidth: .infinity, minHeight: SettingsConstants.modelSelectionHeight)
          .contentShape(Rectangle())
          .onTapGesture {
            selectedTranscriptionModel = model
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
            .foregroundColor(costLevelColor(for: selectedTranscriptionModel.costLevel))
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
