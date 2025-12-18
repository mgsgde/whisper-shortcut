import SwiftUI

/// Offline Models Settings Tab - Download and manage offline Whisper models
struct OfflineModelsSettingsTab: View {
  @ObservedObject var viewModel: SettingsViewModel
  @ObservedObject var modelManager = ModelManager.shared
  @State private var errorMessage: String?
  @State private var showError = false
  @State private var successMessage: String?
  @State private var showSuccess = false
  @State private var refreshTrigger = UUID() // Trigger to force view refresh

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Info Section
      infoSection

      // Section Divider
      sectionDivider

      // Models List Section
      modelsListSection
    }
    .alert("Error", isPresented: $showError) {
      Button("OK") {
        showError = false
        errorMessage = nil
      }
    } message: {
      if let errorMessage = errorMessage {
        Text(errorMessage)
          .textSelection(.enabled)
      }
    }
    .alert("Success", isPresented: $showSuccess) {
      Button("OK") {
        showSuccess = false
        successMessage = nil
      }
    } message: {
      if let successMessage = successMessage {
        Text(successMessage)
          .textSelection(.enabled)
      }
    }
  }

  // MARK: - Info Section
  @ViewBuilder
  private var infoSection: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "📦 Offline Models",
        subtitle: "Download and manage offline Whisper models for transcription"
      )

      Text("Offline models allow you to transcribe audio without an internet connection. Models are automatically downloaded from HuggingFace and cached locally.")
        .font(.callout)
        .foregroundColor(.secondary)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  // MARK: - Section Divider Helper
  @ViewBuilder
  private var sectionDivider: some View {
    VStack(spacing: 0) {
      Spacer()
        .frame(height: SettingsConstants.sectionSpacing)
      SectionDivider()
      Spacer()
        .frame(height: SettingsConstants.sectionSpacing)
    }
  }

  // MARK: - Models List Section
  @ViewBuilder
  private var modelsListSection: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "Available Models",
        subtitle: "Select a model to download or manage. Note: The first execution may take longer as the model needs to be initialized. Subsequent prompts will be faster."
      )

      VStack(spacing: 12) {
        ForEach(OfflineModelType.allCases, id: \.self) { modelType in
          modelRow(for: modelType)
            .id("\(modelType.rawValue)-\(refreshTrigger)") // Force refresh when trigger changes
        }
      }
    }
  }

  // MARK: - Model Row
  @ViewBuilder
  private func modelRow(for modelType: OfflineModelType) -> some View {
    // Check if model is currently downloading (takes precedence)
    let isDownloading = modelManager.downloadingModels.contains(modelType)
    // Only check availability if not downloading (prevents "Downloaded / 0 MB" glitch)
    let isAvailable = !isDownloading && ModelManager.shared.isModelAvailable(modelType)
    let modelSize = ModelManager.shared.getModelSize(modelType)

    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .center, spacing: 12) {
        // Model Info
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
            // Status - prioritize downloading status
            HStack(spacing: 4) {
              if isDownloading {
                Image(systemName: "arrow.down.circle.fill")
                  .foregroundColor(.blue)
                  .font(.caption)
                Text("Downloading...")
                  .font(.caption)
                  .foregroundColor(.secondary)
              } else {
                Image(systemName: isAvailable ? "checkmark.circle.fill" : "circle")
                  .foregroundColor(isAvailable ? .green : .secondary)
                  .font(.caption)
                Text(isAvailable ? "Downloaded" : "Not downloaded")
                  .font(.caption)
                  .foregroundColor(.secondary)
              }
            }

            // Size - only show if not downloading and model is available
            if !isDownloading, let size = modelSize {
              Text("• \(ModelManager.shared.formatSize(size))")
                .font(.caption)
                .foregroundColor(.secondary)
            } else if !isDownloading {
              Text("• ~\(modelType.estimatedSizeMB) MB")
                .font(.caption)
                .foregroundColor(.secondary)
            }
          }
        }

        Spacer()

        // Action Button
        if isDownloading {
          // Download in progress
          HStack(spacing: 8) {
            ProgressView()
              .scaleEffect(0.8)
            Text("Downloading...")
              .font(.caption)
              .foregroundColor(.secondary)
          }
        } else if isAvailable {
          // Delete button
          Button("Delete") {
            deleteModel(modelType)
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
          .foregroundColor(.red)
        } else {
          // Download button
          Button("Download") {
            downloadModel(modelType)
          }
          .buttonStyle(.borderedProminent)
          .controlSize(.small)
        }
      }
    }
    .padding(12)
    .background(Color(.controlBackgroundColor))
    .cornerRadius(8)
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .stroke(Color(.separatorColor), lineWidth: 1)
    )
  }

  // MARK: - Actions
  private func downloadModel(_ modelType: OfflineModelType) {
    // ModelManager now handles the downloading state internally
    Task {
      do {
        try await ModelManager.shared.downloadModel(modelType)
        await MainActor.run {
          DebugLogger.logSuccess("OFFLINE-UI: Successfully downloaded \(modelType.displayName)")
          
          // Show success message
          successMessage = "\(modelType.displayName) was successfully downloaded.\n\nNote: The first execution may take longer as the model needs to be initialized. Subsequent prompts will be faster."
          showSuccess = true
          
          // Give WhisperKit a moment to finish writing files
          Task {
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
            await MainActor.run {
              // Trigger view update to show new model status
              refreshTrigger = UUID()
              DebugLogger.log("OFFLINE-UI: Refreshed view after download")
            }
          }
        }
      } catch {
        await MainActor.run {
          errorMessage = "Failed to download \(modelType.displayName): \(error.localizedDescription)"
          showError = true
          DebugLogger.logError("OFFLINE-UI: Failed to download \(modelType.displayName): \(error.localizedDescription)")
        }
      }
    }
  }

  private func deleteModel(_ modelType: OfflineModelType) {
    do {
      try ModelManager.shared.deleteModel(modelType)
      DebugLogger.logSuccess("OFFLINE-UI: Successfully deleted \(modelType.displayName)")
      // Trigger view update to show new model status
      refreshTrigger = UUID()
    } catch {
      errorMessage = "Failed to delete \(modelType.displayName): \(error.localizedDescription)"
      showError = true
      DebugLogger.logError("OFFLINE-UI: Failed to delete \(modelType.displayName): \(error.localizedDescription)")
    }
  }
}

#if DEBUG
  struct OfflineModelsSettingsTab_Previews: PreviewProvider {
    static var previews: some View {
      OfflineModelsSettingsTab(viewModel: SettingsViewModel())
        .padding()
        .frame(width: 600, height: 600)
    }
  }
#endif
