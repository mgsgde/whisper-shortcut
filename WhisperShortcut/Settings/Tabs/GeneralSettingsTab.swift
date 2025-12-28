import SwiftUI

/// General Settings Tab - API Key und Support & Feedback
struct GeneralSettingsTab: View {
  @ObservedObject var viewModel: SettingsViewModel
  @FocusState.Binding var focusedField: SettingsFocusField?
  @ObservedObject var modelManager = ModelManager.shared
  @State private var errorMessage: String?
  @State private var showError = false
  @State private var successMessage: String?
  @State private var showSuccess = false
  @State private var refreshTrigger = UUID() // Trigger to force view refresh

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Google API Key Section
      googleAPIKeySection

      // Section Divider with spacing
      VStack(spacing: 0) {
        Spacer()
          .frame(height: SettingsConstants.sectionSpacing)
        SectionDivider()
        Spacer()
          .frame(height: SettingsConstants.sectionSpacing)
      }

      // Offline Models Section
      offlineModelsSection

      // Section Divider with spacing
      VStack(spacing: 0) {
        Spacer()
          .frame(height: SettingsConstants.sectionSpacing)
        SectionDivider()
        Spacer()
          .frame(height: SettingsConstants.sectionSpacing)
      }

      // Launch at Login Section
      launchAtLoginSection

      // Section Divider with spacing
      VStack(spacing: 0) {
        Spacer()
          .frame(height: SettingsConstants.sectionSpacing)
        SectionDivider()
        Spacer()
          .frame(height: SettingsConstants.sectionSpacing)
      }

      // Popup Notifications Section
      popupNotificationsSection

      // Section Divider with spacing
      VStack(spacing: 0) {
        Spacer()
          .frame(height: SettingsConstants.sectionSpacing)
        SectionDivider()
        Spacer()
          .frame(height: SettingsConstants.sectionSpacing)
      }

      // Keyboard Shortcuts Section
      keyboardShortcutsSection

      // Section Divider with spacing
      VStack(spacing: 0) {
        Spacer()
          .frame(height: SettingsConstants.sectionSpacing)
        SectionDivider()
        Spacer()
          .frame(height: SettingsConstants.sectionSpacing)
      }

      // Support & Feedback Section
      supportFeedbackSection
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

  // MARK: - Launch at Login Section
  @ViewBuilder
  private var launchAtLoginSection: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "🚀 Startup",
        subtitle: "Automatically start WhisperShortcut when you log in"
      )

      HStack(alignment: .center, spacing: 16) {
        Text("Launch at Login:")
          .font(.body)
          .fontWeight(.medium)
          .frame(width: SettingsConstants.labelWidth, alignment: .leading)

        Toggle("", isOn: Binding(
          get: { viewModel.data.launchAtLogin },
          set: { newValue in
            viewModel.setLaunchAtLogin(newValue)
          }
        ))
        .toggleStyle(SwitchToggleStyle())

        Spacer()
      }
    }
  }

  // MARK: - Keyboard Shortcuts Section
  @ViewBuilder
  private var keyboardShortcutsSection: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "⌨️ Keyboard Shortcuts",
        subtitle: "Configure keyboard shortcuts for various features"
      )

      ShortcutInputRow(
        label: "Toggle Settings:",
        placeholder: "e.g., command+5",
        text: $viewModel.data.openSettings,
        isEnabled: $viewModel.data.openSettingsEnabled,
        focusedField: .toggleSettings,
        currentFocus: $focusedField,
        onShortcutChanged: {
          Task {
            await viewModel.saveSettings()
          }
        },
        validateShortcut: viewModel.validateShortcut
      )

      // Available Keys Information
      VStack(alignment: .leading, spacing: 8) {
        Text("Available keys:")
          .font(.callout)
          .fontWeight(.semibold)
          .foregroundColor(.secondary)
          .textSelection(.enabled)

        Text(
          "command • option • control • shift • a-z • 0-9 • f1-f12 • escape • up • down • left • right • comma • period"
        )
        .font(.callout)
        .foregroundColor(.secondary)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
      }
      .textSelection(.enabled)
    }
  }

  // MARK: - Google API Key Section
  @ViewBuilder
  private var googleAPIKeySection: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "🔑 Google API Key",
        subtitle: "Recommended • Required for Gemini transcription functionality"
      )

      HStack(alignment: .center, spacing: 16) {
        Text("API Key:")
          .font(.body)
          .fontWeight(.medium)
          .frame(width: SettingsConstants.labelWidth, alignment: .leading)
          .textSelection(.enabled)

        TextField("AIza...", text: $viewModel.data.googleAPIKey)
          .textFieldStyle(.roundedBorder)
          .font(.system(.body, design: .monospaced))
          .frame(height: SettingsConstants.textFieldHeight)
          .frame(maxWidth: SettingsConstants.apiKeyMaxWidth)
          .onAppear {
            viewModel.data.googleAPIKey = KeychainManager.shared.getGoogleAPIKey() ?? ""
          }
          .focused($focusedField, equals: .googleAPIKey)
          .onChange(of: viewModel.data.googleAPIKey) { _, newValue in
            // Auto-save Google API key to keychain
            Task {
              _ = KeychainManager.shared.saveGoogleAPIKey(newValue)
            }
          }

        Spacer()
      }

      HStack(spacing: 0) {
        Text("Need an API key? Get one at ")
          .font(.callout)
          .foregroundColor(.secondary)
          .textSelection(.enabled)

        Link(
          destination: URL(string: "https://aistudio.google.com/api-keys")!
        ) {
          Text("aistudio.google.com/api-keys")
            .font(.callout)
            .foregroundColor(.blue)
            .underline()
            .textSelection(.enabled)
        }
        .onHover { isHovered in
          if isHovered {
            NSCursor.pointingHand.push()
          } else {
            NSCursor.pop()
          }
        }

        Text(" 💡")
          .font(.callout)
          .foregroundColor(.secondary)
      }
      .fixedSize(horizontal: false, vertical: true)
    }
  }

  // MARK: - Popup Notifications Section
  @ViewBuilder
  private var popupNotificationsSection: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "🔔 Popup Notifications",
        subtitle: "Show popup windows with transcription and AI response text"
      )

      HStack(alignment: .center, spacing: 16) {
        Text("Show Notifications:")
          .font(.body)
          .fontWeight(.medium)
          .frame(width: SettingsConstants.labelWidth, alignment: .leading)

        Toggle("", isOn: $viewModel.data.showPopupNotifications)
          .toggleStyle(SwitchToggleStyle())
          .onChange(of: viewModel.data.showPopupNotifications) { _, _ in
            Task {
              await viewModel.saveSettings()
            }
          }

        Spacer()
      }

      // Position Selection
      HStack(alignment: .center, spacing: 16) {
        Text("Position:")
          .font(.body)
          .fontWeight(.medium)
          .frame(width: SettingsConstants.labelWidth, alignment: .leading)

        Picker("", selection: $viewModel.data.notificationPosition) {
          ForEach(NotificationPosition.allCases, id: \.rawValue) { position in
            Text(position.displayName)
              .tag(position)
          }
        }
        .pickerStyle(MenuPickerStyle())
        .frame(width: 200)
        .onChange(of: viewModel.data.notificationPosition) { _, _ in
          Task {
            await viewModel.saveSettings()
          }
        }

        Spacer()
      }

      // Duration Selection
      HStack(alignment: .center, spacing: 16) {
        Text("Duration:")
          .font(.body)
          .fontWeight(.medium)
          .frame(width: SettingsConstants.labelWidth, alignment: .leading)

        Picker("", selection: $viewModel.data.notificationDuration) {
          ForEach(NotificationDuration.allCases, id: \.rawValue) { duration in
            HStack {
              Text(duration.displayName)
              if duration.isRecommended {
                Text("(Recommended)")
                  .font(.caption)
                  .foregroundColor(.secondary)
              }
            }
            .tag(duration)
          }
        }
        .pickerStyle(MenuPickerStyle())
        .frame(width: 200)
        .onChange(of: viewModel.data.notificationDuration) { _, _ in
          Task {
            await viewModel.saveSettings()
          }
        }

        Spacer()
      }

      Text(
        "When enabled, popup windows will appear showing the transcribed text, AI responses, and voice response text."
      )
      .font(.callout)
      .foregroundColor(.secondary)
      .fixedSize(horizontal: false, vertical: true)
    }
  }

  // MARK: - Offline Models Section
  @ViewBuilder
  private var offlineModelsSection: some View {
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

      // Available Models
      VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
        SectionHeader(
          title: "Available Models",
          subtitle: "Select a model to download or manage. Note: The first execution may take longer as the model needs to be initialized. Subsequent prompts will be faster."
        )

        VStack(spacing: 12) {
          ForEach(OfflineModelType.allCases, id: \.self) { modelType in
            offlineModelRow(for: modelType)
              .id("\(modelType.rawValue)-\(refreshTrigger)") // Force refresh when trigger changes
          }
        }
      }
      .padding(.top, SettingsConstants.internalSectionSpacing)
    }
  }

  // MARK: - Offline Model Row
  @ViewBuilder
  private func offlineModelRow(for modelType: OfflineModelType) -> some View {
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
            deleteOfflineModel(modelType)
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
          .foregroundColor(.red)
        } else {
          // Download button
          Button("Download") {
            downloadOfflineModel(modelType)
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

  // MARK: - Offline Models Actions
  private func downloadOfflineModel(_ modelType: OfflineModelType) {
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

  private func deleteOfflineModel(_ modelType: OfflineModelType) {
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

  // MARK: - Support & Feedback Section
  @ViewBuilder
  private var supportFeedbackSection: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "💬 Support & Feedback",
        subtitle:
          "If you have feedback, if sth doesn't work, or if you have suggestions for improvement, feel free to contact me via WhatsApp."
      )

      VStack(alignment: .leading, spacing: 20) {
        // Main Action Buttons
        VStack(spacing: 12) {
          // WhatsApp Contact Button
          Button(action: {
            viewModel.openWhatsAppFeedback()
          }) {
            HStack(alignment: .center, spacing: 12) {
              Image("WhatsApp")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 18, height: 18)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .opacity(0.85)
              
              Text("Contact me on WhatsApp")
                .font(.body)
                .fontWeight(.medium)
                .textSelection(.enabled)

              Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(12)
          }
          .buttonStyle(PlainButtonStyle())
          .help("Contact via WhatsApp")
          .onHover { isHovered in
            if isHovered {
              NSCursor.pointingHand.push()
            } else {
              NSCursor.pop()
            }
          }

          // App Store Review Button
          Button(action: {
            viewModel.openAppStoreReview()
          }) {
            HStack(alignment: .center, spacing: 12) {
              Image(systemName: "star.fill")
                .font(.system(size: 18))
                .foregroundColor(.orange)
                .opacity(0.85)
              
              Text("Leave a Review")
                .font(.body)
                .fontWeight(.medium)
                .textSelection(.enabled)

              Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(12)
          }
          .buttonStyle(PlainButtonStyle())
          .help("Leave a review on the App Store")
          .onHover { isHovered in
            if isHovered {
              NSCursor.pointingHand.push()
            } else {
              NSCursor.pop()
            }
          }
          // Share with Friends Button
          Button(action: {
            viewModel.copyAppStoreLink()
          }) {
            HStack(alignment: .center, spacing: 12) {
              Image(systemName: viewModel.data.appStoreLinkCopied ? "checkmark.circle.fill" : "link")
                .font(.system(size: 18))
                .foregroundColor(viewModel.data.appStoreLinkCopied ? .green : .blue)
                .opacity(0.85)
              
              Text(viewModel.data.appStoreLinkCopied ? "Link copied!" : "Share with Friends")
                .font(.body)
                .fontWeight(.medium)
                .textSelection(.enabled)

              Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(12)
          }
          .buttonStyle(PlainButtonStyle())
          .help(viewModel.data.appStoreLinkCopied ? "App Store link copied to clipboard" : "Copy App Store link to clipboard")
          .onHover { isHovered in
            if isHovered {
              NSCursor.pointingHand.push()
            } else {
              NSCursor.pop()
            }
          }
        }
        
        // Developer Footer (no divider)
        HStack(spacing: 16) {
          Image("me")
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: 64, height: 64)
            .clipShape(Circle())
          
          VStack(alignment: .leading, spacing: 4) {
            Text("— Magnus • Developer")
              .font(.body)
              .foregroundColor(.secondary)
              .opacity(0.8)
            
            Text("Karlsruhe, Germany 🇩🇪")
              .font(.subheadline)
              .foregroundColor(.secondary)
              .opacity(0.7)
          }
          
          Spacer()
        }
        .padding(.top, 12)
      }
    }
  }
}

#if DEBUG
  struct GeneralSettingsTab_Previews: PreviewProvider {
    static var previews: some View {
      @FocusState var focusedField: SettingsFocusField?

      GeneralSettingsTab(viewModel: SettingsViewModel(), focusedField: $focusedField)
        .padding()
        .frame(width: 600, height: 400)
    }
  }
#endif
