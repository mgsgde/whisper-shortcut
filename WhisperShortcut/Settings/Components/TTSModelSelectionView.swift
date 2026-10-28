import SwiftUI

/// Reusable component for Read Aloud (TTS) model selection across providers.
/// Mirrors `ModelSelectionView` (transcription) but for `TTSModel`. A provider whose key is
/// missing keeps its tiles selectable with a "Needs key" badge, like every other picker.
struct TTSModelSelectionView: View {
  @Binding var selectedModel: TTSModel
  let title: LocalizedStringResource
  let systemImage: String?
  let subtitle: LocalizedStringResource
  let models: [TTSModel]
  let onModelChanged: (() -> Void)?

  init(
    title: LocalizedStringResource = "Voice Model",
    systemImage: String? = "speaker.wave.2.fill",
    subtitle: LocalizedStringResource = "Which provider generates the spoken audio. Pick the specific voice below.",
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

      ModelDetailsFooter(description: selectedModel.description, costLevel: selectedModel.costLevel)
    }
  }

  private func modelCell(_ model: TTSModel, badges: [ModelPickerBadge]) -> some View {
    ModelTile(
      title: model.pickerTitle,
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
