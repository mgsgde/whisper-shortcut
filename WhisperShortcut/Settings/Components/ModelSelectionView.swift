import SwiftUI

/// Reusable component for transcription model selection.
struct ModelSelectionView: View {
  @Binding var selectedTranscriptionModel: TranscriptionModel
  let title: String
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
    selectedTranscriptionModel: Binding<TranscriptionModel>,
    models: [TranscriptionModel] = TranscriptionModel.allCases,
    geminiDisabled: Bool = false,
    openAIDisabled: Bool = false,
    xaiDisabled: Bool = false,
    subscriptionMode: Bool = false,
    onModelChanged: (() -> Void)? = nil
  ) {
    self.title = title
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

      // Split the flat list into Cloud (needs an API key) and Offline (on-device Whisper)
      // groups. When only one group is present we render a single plain grid so lists
      // without offline models (or vice versa) keep their original look.
      let cloudModels = models.filter { !$0.isOffline }
      let offlineModels = models.filter { $0.isOffline }
      let grouped = !cloudModels.isEmpty && !offlineModels.isEmpty

      VStack(alignment: .leading, spacing: 0) {
        if grouped {
          groupHeader(symbol: "cloud", title: "Cloud", subtitle: "Fast · needs an API key")
          modelGrid(cloudModels)
          Divider().padding(.vertical, 10)
          groupHeader(symbol: "desktopcomputer", title: "Offline", subtitle: "Private · runs on your Mac")
          modelGrid(offlineModels)
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

  @ViewBuilder
  private func groupHeader(symbol: String, title: String, subtitle: String) -> some View {
    HStack(spacing: 6) {
      Image(systemName: symbol)
        .font(.caption)
        .foregroundColor(.secondary)
      Text(title)
        .font(.callout)
        .fontWeight(.semibold)
      Text("· \(subtitle)")
        .font(.caption)
        .foregroundColor(.secondary)
    }
    .padding(.horizontal, 4)
    .padding(.bottom, 6)
  }

  private func modelGrid(_ models: [TranscriptionModel]) -> some View {
    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 2), spacing: SettingsConstants.modelSpacing) {
      ForEach(models, id: \.self) { model in
        modelCell(model)
      }
    }
  }

  @ViewBuilder
  private func modelCell(_ model: TranscriptionModel) -> some View {
    let isDisabled = (geminiDisabled && model.isGemini) || (openAIDisabled && model.isOpenAI) || (xaiDisabled && model.isXAI)
    ZStack {
      Rectangle()
        .fill(selectedTranscriptionModel == model ? Color.accentColor : Color.clear)
        .cornerRadius(SettingsConstants.cornerRadius)

      Text(model.displayName)
        .font(.system(.body, design: .default))
        .fontWeight(.medium)
        .foregroundColor(selectedTranscriptionModel == model ? .white : (isDisabled ? .secondary : .primary))
    }
    .frame(maxWidth: .infinity, minHeight: SettingsConstants.modelSelectionHeight)
    .contentShape(Rectangle())
    .opacity(isDisabled ? 0.6 : 1)
    .onTapGesture {
      if isDisabled { return }
      selectedTranscriptionModel = model
      onModelChanged?()
    }
    .pointerCursorOnHover()
  }

}
