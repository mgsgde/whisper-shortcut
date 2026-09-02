import SwiftUI

/// Download / progress / cancel card for a Whisper model. Used in onboarding and on the
/// Privacy tab when Offline Mode is on. Defaults to Base (≈140 MB); Turbo is an upgrade
/// offered in Settings → Dictate.
struct WhisperModelDownloadCard: View {
  var modelType: OfflineModelType = .whisperBase
  var onReady: (() -> Void)? = nil

  @ObservedObject private var modelManager = ModelManager.shared
  @State private var downloadError: String?

  private var isDownloading: Bool { modelManager.downloadingModels.contains(modelType) }
  private var isAvailable: Bool { modelManager.isModelAvailable(modelType) }
  private var progress: Double? { modelManager.downloadProgress[modelType] }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        Image(systemName: "laptopcomputer.and.arrow.down")
          .foregroundStyle(.tint)
        Text("Run offline with local Whisper")
          .font(.callout)
          .fontWeight(.semibold)
        Spacer()
      }

      Text("No key required — audio never leaves your Mac. Whisper Base (≈\(OfflineModelType.whisperBase.estimatedSizeMB) MB) is enough to start. For higher accuracy, download Whisper Large v3 Turbo later in Settings → Dictate.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      if isAvailable {
        Label("\(modelType.displayName) ready — you can continue.", systemImage: "checkmark.seal.fill")
          .font(.caption)
          .foregroundStyle(.green)
      } else if isDownloading {
        VStack(alignment: .leading, spacing: 8) {
          if let progress {
            ProgressView(value: progress)
              .progressViewStyle(.linear)
            HStack {
              Text("Downloading \(modelType.displayName) — \(Int(progress * 100))%")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
              Spacer()
              Text(sizeLabel(progress: progress))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
          } else {
            HStack(spacing: 8) {
              ProgressView().controlSize(.small)
              Text("Starting \(modelType.displayName)…")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
          Button("Cancel") {
            Task { @MainActor in
              ModelManager.shared.cancelDownload(modelType)
            }
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
          .pointerCursorOnHover()
        }
      } else {
        Button(action: download) {
          Label(
            "Download \(modelType.displayName) (≈\(modelType.estimatedSizeMB) MB)",
            systemImage: "arrow.down.circle")
            .font(.callout)
        }
        .buttonStyle(.bordered)
        .pointerCursorOnHover()
      }

      if let downloadError {
        Label(downloadError, systemImage: "exclamationmark.triangle.fill")
          .font(.caption2)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 10)
        .fill(Color(nsColor: .controlBackgroundColor))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 10)
        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
    )
    .onAppear(perform: notifyIfReady)
    .onChange(of: isAvailable) { _, available in
      if available { notifyIfReady() }
    }
  }

  private func sizeLabel(progress: Double) -> String {
    let downloadedMB = Int((progress * Double(modelType.estimatedSizeMB)).rounded())
    return "\(downloadedMB) / \(modelType.estimatedSizeMB) MB"
  }

  private func download() {
    downloadError = nil
    Task {
      do {
        try await ModelManager.shared.downloadModel(modelType)
        await MainActor.run { notifyIfReady() }
      } catch is CancellationError {
        await MainActor.run { downloadError = nil }
      } catch {
        if ModelManager.isCancellation(error) {
          await MainActor.run { downloadError = nil }
          return
        }
        await MainActor.run {
          downloadError = SpeechErrorFormatter.formatForUser(error)
        }
        DebugLogger.logError("ONBOARDING: \(modelType.displayName) download failed: \(error.localizedDescription)")
      }
    }
  }

  private func notifyIfReady() {
    guard modelManager.isModelAvailable(modelType) else { return }
    onReady?()
  }
}
