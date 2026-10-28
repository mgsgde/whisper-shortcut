import SwiftUI

/// Whisper-style "Available Models" list for in-process MLX: Download, percent, Delete.
struct LocalLLMModelsSection: View {
  @ObservedObject private var manager = LocalLLMModelManager.shared
  @State private var errorMessage: String?
  /// Catalogue entries to list; callers narrow it to the models their picker can actually select.
  var models: [LocalLLMModelType] = LocalLLMModelType.offerable

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "Offline Models",
        systemImage: "arrow.down.circle",
        subtitle: "Runs on this Mac, nothing to install. Each model downloads once and stays on disk."
      )

      VStack(spacing: 12) {
        ForEach(models, id: \.self) { modelType in
          row(for: modelType)
        }
      }

      if let errorMessage {
        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundColor(.red)
          .textSelection(.enabled)
      }
    }
  }

  private func row(for modelType: LocalLLMModelType) -> some View {
    ModelDownloadRow(
      store: manager,
      model: modelType,
      downloadedMessage: String(
        localized: "\(modelType.displayName) was successfully downloaded. The first reply may take a moment to load the model into memory."),
      onError: { errorMessage = $0 }
    ) {
      if modelType.isRecommended {
        HStack(spacing: 4) {
          Image(systemName: "star.fill")
            .foregroundColor(.yellow)
            .font(.caption)
          // "Best of these", not "recommended": the star picks between the two MLX models.
          // A quiet machine can match a local server; under memory pressure it does not.
          Text("Best of these")
            .font(.caption)
            .foregroundColor(.secondary)
        }
      }
    }
  }
}
