import SwiftUI

/// Reusable component for Read Aloud (TTS) model selection across providers.
/// Mirrors `ModelSelectionView` (transcription) but for `TTSModel`. A provider whose key is
/// missing keeps its tiles selectable with a "Needs key" badge, like every other picker.
struct TTSModelSelectionView: View {
  @Binding var selectedModel: TTSModel
  let title: String
  let systemImage: String?
  let subtitle: String
  let models: [TTSModel]
  let onModelChanged: (() -> Void)?

  init(
    title: String = "Voice Model",
    systemImage: String? = "speaker.wave.2.fill",
    subtitle: String = "Which provider generates the spoken audio. Pick the specific voice below.",
    selectedModel: Binding<TTSModel>,
    models: [TTSModel] = TTSModel.readAloudModels,
    onModelChanged: (() -> Void)? = nil
  ) {
    self.title = title
    self.systemImage = systemImage
    self.subtitle = subtitle
    self._selectedModel = selectedModel
    self.models = models
    self.onModelChanged = onModelChanged
  }

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(title: title, systemImage: systemImage, subtitle: subtitle)

      CuratedModelPicker(
        curation: ModelPickerCuration(
          models: models, recommended: SettingsDefaults.readAloudModel, selected: selectedModel),
        cell: { model, badges in modelCell(model, badges: badges) },
        more: { ModelGrid(models: $0) { modelCell($0, badges: []) } })

      // Selected model details
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
            .foregroundColor(SettingsConstants.costLevelColor(for: selectedModel.costLevel))
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

        if !selectedModel.hasRequiredCredential {
          HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill")
              .foregroundColor(.orange)
              .font(.caption)
            Text("Add the matching API key in Settings → Accounts to use this model.")
              .font(.caption)
              .foregroundColor(.secondary)
          }
        }
      }
    }
  }

  private func modelCell(_ model: TTSModel, badges: [ModelPickerBadge]) -> some View {
    ModelTile(
      title: model.displayName,
      isSelected: selectedModel == model,
      isDisabled: false,
      badges: badges,
      setupBadge: model.pickerSetupBadge,
      setupHelp: model.apiKeyRequiredMessage,
      onTap: {
        selectedModel = model
        onModelChanged?()
      }
    )
  }
}
