import SwiftUI

/// Configuration for dictating through OpenRouter. Shown in Settings → Dictate when the OpenRouter
/// transcription model is selected.
///
/// OpenRouter is one key in front of many providers' audio models, so the point of this section is
/// the **model slug**: switching from a Gemini tier to `openai/gpt-audio` to hunt for the best
/// accuracy/latency trade-off should be a one-field edit, not a new provider setup.
struct OpenRouterTranscriptionSection: View {
  @ObservedObject var viewModel: SettingsViewModel
  @ObservedObject private var catalog = OpenRouterModelCatalog.shared

  @State private var showCustomSlugField = false

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "OpenRouter",
        systemImage: "arrow.triangle.branch",
        subtitle: "Dictate through any audio-capable model OpenRouter routes to, with one account."
      )

      // Same view as on the General tab, sharing one service — connecting in either place updates
      // both. Header suppressed here because this section already has one.
      OpenRouterConnectionSection(showsHeader: false)

      HStack(alignment: .center, spacing: 16) {
        Text("Model:")
          .font(.body)
          .fontWeight(.medium)
          .frame(width: SettingsConstants.labelWidth, alignment: .leading)

        modelPicker

        Spacer()
      }

      if catalog.isLoading {
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text("Loading OpenRouter's model list...")
            .font(.caption)
            .foregroundColor(.secondary)
        }
        .padding(.leading, SettingsConstants.labelWidth + 16)
      } else if let loadError = catalog.loadError {
        // The picker is a convenience, not a gate — dictation still works with whatever slug is
        // stored, so this degrades to the manual field rather than blocking.
        HStack(spacing: 8) {
          Text("Couldn't load the model list (\(loadError)). Type a slug below instead.")
            .font(.caption)
            .foregroundColor(.orange)
            .fixedSize(horizontal: false, vertical: true)
          Button("Retry") { Task { await catalog.reload() } }
            .buttonStyle(.link)
            .font(.caption)
        }
        .padding(.leading, SettingsConstants.labelWidth + 16)
      }

      if isCustomModelID || showCustomSlugField {
        HStack(alignment: .center, spacing: 16) {
          Text("Slug:")
            .font(.body)
            .fontWeight(.medium)
            .frame(width: SettingsConstants.labelWidth, alignment: .leading)

          TextField(
            SettingsDefaults.openRouterTranscriptionModelID,
            text: $viewModel.data.openRouterTranscriptionModelID
          )
          .textFieldStyle(.roundedBorder)
          .font(.system(.body, design: .monospaced))
          .frame(height: SettingsConstants.textFieldHeight)
          .frame(maxWidth: SettingsConstants.apiKeyMaxWidth)
          .onChange(of: viewModel.data.openRouterTranscriptionModelID) { _, _ in
            Task { await viewModel.saveSettings() }
          }

          Spacer()
        }
      }

      HStack(alignment: .firstTextBaseline, spacing: 4) {
        Text("Only models with audio input are listed — anything else fails at request time. Full catalogue:")
          .font(.caption)
          .foregroundColor(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        if let url = URL(string: "https://openrouter.ai/models?modality=text%2Baudio-%3Etext") {
          Link("audio models", destination: url)
            .font(.caption)
            .pointerCursorOnHover()
        }
      }

      // OpenRouter has no /v1/audio/transcriptions, so this path sends the audio as a chat-completion
      // content part. Worth saying out loud: it changes which knobs apply.
      Text("Audio is sent as a chat message (OpenRouter has no dedicated transcription endpoint), so your Dictation system prompt and Glossary apply here — unlike the OpenAI and self-hosted transcription endpoints. Temperature below applies too; Thinking effort is Gemini-only.")
        .font(.caption)
        .foregroundColor(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .onAppear {
      catalog.loadIfNeeded()
    }
  }

  // MARK: - Model selection

  /// True when the stored slug is not one the catalogue offers — either the user typed something
  /// bespoke, or the catalogue has not loaded. Both cases need the raw text field visible, since
  /// hiding it would strand a working configuration behind a picker that cannot represent it.
  private var isCustomModelID: Bool {
    let current = viewModel.data.openRouterTranscriptionModelID
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if current.isEmpty { return false }
    return !catalog.audioModels.contains { $0.id == current }
  }

  private var currentModelLabel: String {
    let current = viewModel.data.openRouterTranscriptionModelID
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if current.isEmpty { return SettingsDefaults.openRouterTranscriptionModelID }
    if let match = catalog.audioModels.first(where: { $0.id == current }) { return match.name }
    return current
  }

  private var modelPicker: some View {
    Menu {
      ForEach(catalog.audioModels) { model in
        Button {
          viewModel.data.openRouterTranscriptionModelID = model.id
          Task { await viewModel.saveSettings() }
        } label: {
          if let price = model.pricePerMillionLabel {
            Text("\(model.name) — \(price)")
          } else {
            Text(model.name)
          }
        }
      }

      if !catalog.audioModels.isEmpty {
        Divider()
      }

      Button("Custom slug…") {
        showCustomSlugField = true
      }
    } label: {
      HStack {
        Text(currentModelLabel)
          .lineLimit(1)
          .truncationMode(.middle)
        Spacer()
      }
    }
    .frame(maxWidth: SettingsConstants.apiKeyMaxWidth)
    .disabled(catalog.isLoading)
  }
}
