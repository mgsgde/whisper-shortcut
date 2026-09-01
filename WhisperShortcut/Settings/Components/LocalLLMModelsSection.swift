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
        subtitle: "Download and manage offline MLX models for Dictate Prompt and Chat"
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

  @ViewBuilder
  private func row(for modelType: LocalLLMModelType) -> some View {
    let isDownloading = manager.downloadingModels.contains(modelType)
    let isAvailable = !isDownloading && manager.isModelAvailable(modelType)
    // Only when it is going to be shown: `getModelSize` enumerates the whole model directory —
    // gigabytes of shards — and this body re-runs on every download-progress tick.
    let modelSize = isAvailable ? manager.getModelSize(modelType) : nil

    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .center, spacing: 12) {
        VStack(alignment: .leading, spacing: 4) {
          HStack(spacing: 8) {
            Text(modelType.displayName)
              .font(.body)
              .fontWeight(.semibold)

            if modelType.isRecommended {
              HStack(spacing: 4) {
                Image(systemName: "star.fill")
                  .foregroundColor(.yellow)
                  .font(.caption)
                Text("Recommended")
                  .font(.caption)
                  .foregroundColor(.secondary)
              }
            }
          }

          HStack(spacing: 12) {
            HStack(spacing: 4) {
              if isDownloading {
                Image(systemName: "arrow.down.circle.fill")
                  .foregroundColor(.blue)
                  .font(.caption)
                let fraction = manager.downloadProgress[modelType]
                Text(fraction.map { "Downloading… \(Int($0 * 100))%" } ?? "Downloading…")
                  .font(.caption)
                  .foregroundColor(.secondary)
                  .monospacedDigit()
              } else {
                Image(systemName: isAvailable ? "checkmark.circle.fill" : "circle")
                  .foregroundColor(isAvailable ? .green : .secondary)
                  .font(.caption)
                Text(isAvailable ? "Downloaded" : "Not downloaded")
                  .font(.caption)
                  .foregroundColor(.secondary)
              }
            }

            if !isDownloading, let size = modelSize {
              Text("• \(manager.formatSize(size))")
                .font(.caption)
                .foregroundColor(.secondary)
            } else if !isDownloading {
              Text("• \(modelType.estimatedSizeLabel)")
                .font(.caption)
                .foregroundColor(.secondary)
            }
          }
        }

        Spacer()

        if isDownloading {
          HStack(spacing: 8) {
            if let fraction = manager.downloadProgress[modelType], fraction > 0 {
              ProgressView(value: fraction)
                .progressViewStyle(.linear)
                .frame(width: 90)
              Text("\(Int(fraction * 100))%")
                .font(.caption)
                .foregroundColor(.secondary)
                .monospacedDigit()
            } else {
              ProgressView()
                .scaleEffect(0.8)
              Text("Starting…")
                .font(.caption)
                .foregroundColor(.secondary)
            }
            Button("Cancel") {
              manager.cancelDownload(modelType)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .pointerCursorOnHover()
          }
        } else if isAvailable {
          Button("Delete") {
            delete(modelType)
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
          .foregroundColor(.red)
          .pointerCursorOnHover()
        } else {
          Button("Download") {
            download(modelType)
          }
          .buttonStyle(.borderedProminent)
          .controlSize(.small)
          .pointerCursorOnHover()
        }
      }
    }
    .padding(SettingsConstants.rowPadding)
    .background(Color(.controlBackgroundColor))
    .cornerRadius(8)
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .stroke(Color(.separatorColor), lineWidth: 1)
    )
  }

  private func download(_ modelType: LocalLLMModelType) {
    errorMessage = nil
    Task {
      do {
        try await LocalLLMModelManager.shared.downloadModel(modelType)
        await MainActor.run {
          PopupNotificationWindow.showInfo(
            "\(modelType.displayName) was successfully downloaded. The first reply may take a moment to load the model into memory.",
            title: "Model Downloaded",
            customDisplayDuration: 10
          )
        }
      } catch is CancellationError {
        // cancelled from the Cancel button
      } catch {
        await MainActor.run {
          errorMessage = SpeechErrorFormatter.formatForUser(error)
        }
      }
    }
  }

  private func delete(_ modelType: LocalLLMModelType) {
    errorMessage = nil
    do {
      try LocalLLMModelManager.shared.deleteModel(modelType)
    } catch {
      errorMessage = SpeechErrorFormatter.formatForUser(error)
    }
  }
}
