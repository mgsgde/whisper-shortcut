import SwiftUI

/// Configuration for dictating through OpenRouter. Shown in Settings → Dictate when the OpenRouter
/// transcription model is selected.
///
/// OpenRouter is one key in front of many providers' audio models, so the point of this section is
/// the **model slug**: switching from a Gemini tier to `openai/gpt-audio` to hunt for the best
/// accuracy/latency trade-off should be a one-field edit, not a new provider setup.
struct OpenRouterTranscriptionSection: View {
  @ObservedObject var viewModel: SettingsViewModel

  @State private var apiKey: String = ""
  @State private var isKeyVisible: Bool = false

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "OpenRouter",
        systemImage: "arrow.triangle.branch",
        subtitle: "Dictate through any audio-capable model OpenRouter routes to, with one API key."
      )

      HStack(alignment: .center, spacing: 16) {
        Text("API Key:")
          .font(.body)
          .fontWeight(.medium)
          .frame(width: SettingsConstants.labelWidth, alignment: .leading)

        ZStack {
          if isKeyVisible {
            TextField("sk-or-v1-...", text: $apiKey)
              .textFieldStyle(.roundedBorder)
              .font(.system(.body, design: .monospaced))
              .frame(height: SettingsConstants.textFieldHeight)
          } else {
            SecureField("sk-or-v1-...", text: $apiKey)
              .textFieldStyle(.roundedBorder)
              .font(.system(.body, design: .monospaced))
              .frame(height: SettingsConstants.textFieldHeight)
          }
        }
        .frame(maxWidth: SettingsConstants.apiKeyMaxWidth)
        .onAppear {
          apiKey = KeychainManager.shared.get(.openRouter) ?? ""
        }
        .onChange(of: apiKey) { _, newValue in
          _ = KeychainManager.shared.save(newValue, for: .openRouter)
        }

        Button(action: { isKeyVisible.toggle() }) {
          Image(systemName: isKeyVisible ? "eye.slash" : "eye")
            .foregroundColor(.secondary)
        }
        .buttonStyle(.plain)
        .help(isKeyVisible ? "Hide key" : "Show key")
        .accessibilityLabel(isKeyVisible ? "Hide key" : "Show key")

        Spacer()
      }

      if apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        Text("Required. Dictation will fail until you set this.")
          .font(.caption)
          .foregroundColor(.orange)
          .padding(.leading, SettingsConstants.labelWidth + 16)
      }

      HStack(alignment: .center, spacing: 16) {
        Text("Model:")
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

      HStack(alignment: .firstTextBaseline, spacing: 4) {
        Text("Any model with audio input works, e.g. `google/gemini-3.5-flash-lite`, `openai/gpt-audio-mini`. Browse them:")
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
  }
}
