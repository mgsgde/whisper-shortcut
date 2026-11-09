import SwiftUI

/// Download / progress / cancel card for an offline model. Used in onboarding and on the
/// Privacy tab when Offline Mode is on. Defaults to the recommended model (Parakeet Ultra,
/// ≈700 MB); the Whisper models, for other languages, are in Settings → Dictate.
struct OfflineModelDownloadCard: View {
  var modelType: OfflineModelType = OfflineModelType.mostAccurate
  var onReady: (() -> Void)? = nil
  /// Start the download as soon as the card appears. Onboarding sets this: the card shows only
  /// after the user picked "Offline", whose card already says "One-time download", so a second
  /// click on a Download button was a step people missed — they sat in front of a greyed-out
  /// Continue without seeing why (Magnus, 2026-11-09).
  var startsDownloadOnAppear = false

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
        Text("Run offline with an on-device model")
          .font(.callout)
          .fontWeight(.semibold)
        Spacer()
      }

      Text(modelType.engine == .parakeet
        ? ("No key required — audio never leaves your Mac. \(modelType.displayName) transcribes 25 European languages, German and English included, in a fraction of a second. For other languages, pick a Whisper model later in Settings → Dictate." as LocalizedStringKey)
        : "No key required — audio never leaves your Mac. \(modelType.displayName) runs on this Mac; other offline models are in Settings → Dictate.")
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
        // Reached only when nothing is running: before the first click, or after a cancel or a
        // failed download. In onboarding it is the one thing standing before Continue, so it
        // gets the prominent style instead of looking like an optional extra.
        .buttonStyle(.borderedProminent)
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
    .cardChrome()
    .onAppear {
      notifyIfReady()
      if startsDownloadOnAppear && !isAvailable && !isDownloading { download() }
    }
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
        DebugLogger.logError("ONBOARDING: \(modelType.displayName) download failed: \(error.logDescription)")
      }
    }
  }

  private func notifyIfReady() {
    guard modelManager.isModelAvailable(modelType) else { return }
    onReady?()
  }
}
