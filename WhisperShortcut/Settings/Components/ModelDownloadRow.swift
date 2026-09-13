import SwiftUI

/// One "Available Models" row — name, badge, status, size, then Download / progress + Cancel /
/// Delete — for any `ModelStore` family. The Whisper and MLX lists render the same row; only the
/// badge text and the post-download hint differ.
struct ModelDownloadRow<M: DownloadableModel, Badge: View>: View {
  @ObservedObject var store: ModelStore<M>
  let model: M
  /// Shown in the "Model Downloaded" popup after a successful download.
  let downloadedMessage: String
  /// Receives a ready-to-show message when a download or delete fails.
  let onError: (String) -> Void
  @ViewBuilder let badge: () -> Badge

  var body: some View {
    let isDownloading = store.downloadingModels.contains(model)
    // Only check availability when not downloading (prevents a "Downloaded / 0 MB" glitch).
    let isAvailable = !isDownloading && store.isModelAvailable(model)
    // Only when it is going to be shown: `getModelSize` enumerates the whole model directory —
    // gigabytes of shards — and this body re-runs on every download-progress tick.
    let modelSize = isAvailable ? store.getModelSize(model) : nil

    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .center, spacing: 12) {
        VStack(alignment: .leading, spacing: 4) {
          HStack(spacing: 8) {
            Text(model.displayName)
              .font(.body)
              .fontWeight(.semibold)
            badge()
          }

          HStack(spacing: 12) {
            HStack(spacing: 4) {
              if isDownloading {
                Image(systemName: "arrow.down.circle.fill")
                  .foregroundColor(.blue)
                  .font(.caption)
                // A gigabyte-scale download with no number reads as a hang; show how far it is.
                let fraction = store.downloadProgress[model]
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
              Text("• \(store.formatSize(size))")
                .font(.caption)
                .foregroundColor(.secondary)
            } else if !isDownloading {
              Text("• \(model.estimatedSizeLabel)")
                .font(.caption)
                .foregroundColor(.secondary)
            }
          }
        }

        Spacer()

        if isDownloading {
          HStack(spacing: 8) {
            if let fraction = store.downloadProgress[model], fraction > 0 {
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
              store.cancelDownload(model)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .pointerCursorOnHover()
          }
        } else if isAvailable {
          Button("Delete", action: delete)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .foregroundColor(.red)
            .pointerCursorOnHover()
        } else {
          Button("Download", action: download)
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

  private func download() {
    Task {
      do {
        try await store.downloadModel(model)
        DebugLogger.logSuccess("\(store.logPrefix): UI download finished for \(model.displayName)")
        // The status-bar-level popup the rest of the app uses for dictation/prompt feedback: it
        // sits above the Settings window regardless of focus. 10 s — longer than the 1 s info
        // default — because this is a rare event with first-run information worth reading.
        PopupNotificationWindow.showInfo(
          downloadedMessage,
          title: "Model Downloaded",
          customDisplayDuration: 10
        )
      } catch is CancellationError {
        // Cancelled from the Cancel button.
      } catch {
        DebugLogger.logError("\(store.logPrefix): UI download failed for \(model.displayName): \(error.localizedDescription)")
        onError("Failed to download \(model.displayName): \(SpeechErrorFormatter.formatForUser(error))")
      }
    }
  }

  private func delete() {
    do {
      try store.deleteModel(model)
    } catch {
      DebugLogger.logError("\(store.logPrefix): UI delete failed for \(model.displayName): \(error.localizedDescription)")
      onError("Failed to delete \(model.displayName): \(SpeechErrorFormatter.formatForUser(error))")
    }
  }
}

extension DownloadableModel {
  /// "~1600 MB" — what a row shows before the model is on disk. Families with a nicer unit
  /// (MLX's "≈2.5 GB") provide their own.
  var estimatedSizeLabel: String { "~\(estimatedSizeMB) MB" }
}
