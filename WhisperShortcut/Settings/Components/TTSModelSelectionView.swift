import SwiftUI

/// Reusable component for Read Aloud (TTS) model selection across providers.
/// Mirrors `ModelSelectionView` (transcription) but for `TTSModel`, disabling a provider's
/// models when its API key / credential is missing so the user can see — but not pick — a
/// model they can't currently use.
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
    models: [TTSModel] = TTSModel.allCases,
    onModelChanged: (() -> Void)? = nil
  ) {
    self.title = title
    self.systemImage = systemImage
    self.subtitle = subtitle
    self._selectedModel = selectedModel
    self.models = models
    self.onModelChanged = onModelChanged
  }

  /// A provider's models are disabled when its key/credential is missing.
  private func isDisabled(_ model: TTSModel) -> Bool {
    switch model.provider {
    case .gemini:
      return !GeminiCredentialProvider.shared.hasCredential()
    case .openai:
      return !KeychainManager.shared.hasValidOpenAIAPIKey()
    case .xai:
      return !KeychainManager.shared.hasValidXAIAPIKey()
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(title: title, systemImage: systemImage, subtitle: subtitle)

      LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 2), spacing: SettingsConstants.modelSpacing) {
        ForEach(models, id: \.self) { model in
          let disabled = isDisabled(model)
          ModelTile(
            title: model.displayName,
            isSelected: selectedModel == model,
            isDisabled: disabled,
            isRecommended: model.isRecommended,
            onTap: {
              selectedModel = model
              onModelChanged?()
            }
          )
        }
      }
      .background(Color(.controlBackgroundColor))
      .cornerRadius(8)
      .overlay(
        RoundedRectangle(cornerRadius: 8)
          .stroke(Color(.separatorColor), lineWidth: 1)
      )

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

        if isDisabled(selectedModel) {
          HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill")
              .foregroundColor(.orange)
              .font(.caption)
            Text("Add the matching API key in Settings → General to use this model.")
              .font(.caption)
              .foregroundColor(.secondary)
          }
        }
      }
    }
  }
}
