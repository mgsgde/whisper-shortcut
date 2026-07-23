import SwiftUI

/// Configuration for the local OpenAI-compatible server (Ollama / LM Studio) used by the
/// "Local" Dictate Prompt model. Shown only when that model is selected. No API key — local
/// servers don't require auth; reachability surfaces as an actionable error at request time.
struct LocalLLMEndpointSection: View {
  @State private var endpointURL: String = ""
  @State private var modelID: String = ""

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "Local Server",
        systemImage: "desktopcomputer",
        subtitle: "Fully offline recipe: (1) Dictate → Offline Whisper, (2) Dictate Prompt → Local (this page), (3) keep Ollama or LM Studio running. Audio is transcribed on-device first, then rewritten by your local model — no cloud, no API key."
      )

      HStack(alignment: .center, spacing: 16) {
        Text("Endpoint:")
          .font(.body)
          .fontWeight(.medium)
          .frame(width: SettingsConstants.labelWidth, alignment: .leading)

        VStack(alignment: .leading, spacing: 4) {
          TextField(SettingsDefaults.localEndpointURL, text: $endpointURL)
            .textFieldStyle(.roundedBorder)
            .font(.system(.body, design: .monospaced))
            .frame(height: SettingsConstants.textFieldHeight)
            .frame(maxWidth: SettingsConstants.apiKeyMaxWidth)
            .onAppear {
              endpointURL = UserDefaults.standard.string(forKey: UserDefaultsKeys.localPromptEndpointURL) ?? ""
            }
            .onChange(of: endpointURL) { _, newValue in
              UserDefaults.standard.set(newValue, forKey: UserDefaultsKeys.localPromptEndpointURL)
            }

          Text("Base URL up to /v1 (the app appends /chat/completions). Default: \(SettingsDefaults.localEndpointURL)")
            .font(.caption)
            .foregroundColor(.secondary)
        }

        Spacer()
      }

      HStack(alignment: .center, spacing: 16) {
        Text("Model:")
          .font(.body)
          .fontWeight(.medium)
          .frame(width: SettingsConstants.labelWidth, alignment: .leading)

        VStack(alignment: .leading, spacing: 4) {
          TextField(SettingsDefaults.localModelID, text: $modelID)
            .textFieldStyle(.roundedBorder)
            .font(.system(.body, design: .monospaced))
            .frame(height: SettingsConstants.textFieldHeight)
            .frame(maxWidth: SettingsConstants.apiKeyMaxWidth)
            .onAppear {
              modelID = UserDefaults.standard.string(forKey: UserDefaultsKeys.localPromptModelID) ?? ""
            }
            .onChange(of: modelID) { _, newValue in
              UserDefaults.standard.set(newValue, forKey: UserDefaultsKeys.localPromptModelID)
            }

          Text("Model tag served locally (e.g. an Ollama tag like `qwen3`). Pull it first: `ollama pull <model>`. Default: \(SettingsDefaults.localModelID)")
            .font(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }

        Spacer()
      }
    }
  }
}
