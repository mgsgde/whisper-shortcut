import SwiftUI

/// Whisper-style "Available Models" list for in-process MLX: Download, percent, Delete.
struct LocalLLMModelsSection: View {
  @ObservedObject private var manager = LocalLLMModelManager.shared
  @State private var errorMessage: String?

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "Available Models",
        systemImage: "arrow.down.circle",
        subtitle: "Download and manage offline MLX models for Dictate Prompt and Chat. They run in the app itself — no server to install."
      )

      Text("Offline MLX models run on your Mac with no server. They download from Hugging Face and stay cached locally.")
        .font(.callout)
        .foregroundColor(.secondary)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)

      VStack(spacing: 12) {
        ForEach(LocalLLMModelType.offerable, id: \.self) { modelType in
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
      downloadedMessage:
        "\(modelType.displayName) was successfully downloaded. The first reply may take a moment to load the model into memory.",
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
