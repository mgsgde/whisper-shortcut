import SwiftUI

/// Wiederverwendbare Komponente für Model-Auswahl
struct ModelSelectionView: View {
  @Binding var selectedModel: TranscriptionModel
  let title: String
  let models: [TranscriptionModel]

  init(
    title: String = "Transcription Model",
    selectedModel: Binding<TranscriptionModel>,
    models: [TranscriptionModel] = TranscriptionModel.allCases
  ) {
    self.title = title
    self._selectedModel = selectedModel
    self.models = models
  }

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: title,
        subtitle: "Choose the transcription model for speech recognition"
      )

      HStack(spacing: SettingsConstants.modelSpacing) {
        ForEach(models, id: \.self) { model in
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
          }

          if model != models.last {
            Divider()
              .frame(height: SettingsConstants.dividerHeight)
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
        Text("Model Details:")
          .font(.callout)
          .fontWeight(.semibold)
          .foregroundColor(.secondary)
          .textSelection(.enabled)

        switch selectedModel {
        case .gpt4oTranscribe:
          Text("• GPT-4o Transcribe: Highest accuracy and quality")
            .font(.callout)
            .foregroundColor(.secondary)
            .textSelection(.enabled)
          Text("• Best for: Critical applications, maximum quality")
            .font(.callout)
            .foregroundColor(.secondary)
            .textSelection(.enabled)
        case .gpt4oMiniTranscribe:
          Text("• GPT-4o Mini: Recommended - Great quality at lower cost")
            .font(.callout)
            .foregroundColor(.secondary)
            .textSelection(.enabled)
          Text("• Best for: Everyday use, balanced performance")
            .font(.callout)
            .foregroundColor(.secondary)
            .textSelection(.enabled)
        }
      }
    }
  }
}

#if DEBUG
  struct ModelSelectionView_Previews: PreviewProvider {
    static var previews: some View {
      @State var selectedModel: TranscriptionModel = .gpt4oMiniTranscribe

      ModelSelectionView(selectedModel: $selectedModel)
        .padding()
        .frame(width: 600)
    }
  }
#endif
