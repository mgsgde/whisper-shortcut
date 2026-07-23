import SwiftUI
import AppKit

struct SelfHostedTranscriptionEndpointSection: View {
  @State private var apiURL: String = ""
  @State private var bearerToken: String = ""
  @State private var isTokenVisible: Bool = false
  @State private var customHeaders: [HeaderEntry] = []

  private struct HeaderEntry: Identifiable {
    var id = UUID()
    var key: String
    var value: String
    var isValueVisible: Bool = false
  }

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "Self-hosted Transcription Endpoint",
        systemImage: "server.rack",
        subtitle: "For your own OpenAI-compatible /v1/audio/transcriptions server (faster-whisper-server, whisper-asr-webservice, or any proxy). If you want OpenAI's hosted models, use the OpenAI entries in the model picker instead."
      )

      HStack(alignment: .center, spacing: 16) {
        Text("Endpoint:")
          .font(.body)
          .fontWeight(.medium)
          .frame(width: SettingsConstants.labelWidth, alignment: .leading)

        VStack(alignment: .leading, spacing: 4) {
          TextField(
            "https://your-whisper.example.com/v1/audio/transcriptions",
            text: $apiURL
          )
          .textFieldStyle(.roundedBorder)
          .font(.system(.body, design: .monospaced))
          .frame(height: SettingsConstants.textFieldHeight)
          .frame(maxWidth: SettingsConstants.apiKeyMaxWidth)
          .onAppear {
            apiURL = UserDefaults.standard.string(forKey: UserDefaultsKeys.customTranscriptionAPIURL) ?? ""
          }
          .onChange(of: apiURL) { _, newValue in
            UserDefaults.standard.set(newValue, forKey: UserDefaultsKeys.customTranscriptionAPIURL)
          }

          if apiURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text("Required. Dictation will fail until you set this.")
              .font(.caption)
              .foregroundColor(.orange)
          }
        }

        Spacer()
      }

      HStack(alignment: .center, spacing: 16) {
        Text("Bearer Token:")
          .font(.body)
          .fontWeight(.medium)
          .frame(width: SettingsConstants.labelWidth, alignment: .leading)

        ZStack {
          if isTokenVisible {
            TextField("sk-...", text: $bearerToken)
              .textFieldStyle(.roundedBorder)
              .font(.system(.body, design: .monospaced))
              .frame(height: SettingsConstants.textFieldHeight)
          } else {
            SecureField("sk-...", text: $bearerToken)
              .textFieldStyle(.roundedBorder)
              .font(.system(.body, design: .monospaced))
              .frame(height: SettingsConstants.textFieldHeight)
          }
        }
        .frame(maxWidth: SettingsConstants.apiKeyMaxWidth)
        .onAppear {
          bearerToken = KeychainManager.shared.getCustomTranscriptionBearerToken() ?? ""
        }
        .onChange(of: bearerToken) { _, newValue in
          _ = KeychainManager.shared.saveCustomTranscriptionBearerToken(newValue)
        }

        Button(action: { isTokenVisible.toggle() }) {
          Image(systemName: isTokenVisible ? "eye.slash" : "eye")
            .foregroundColor(.secondary)
        }
        .buttonStyle(.plain)
        .help(isTokenVisible ? "Hide token" : "Show token")
        .accessibilityLabel(isTokenVisible ? "Hide token" : "Show token")

        Spacer()
      }

      HStack(alignment: .center, spacing: 16) {
        Text("Headers:")
          .font(.body)
          .fontWeight(.medium)
          .frame(width: SettingsConstants.labelWidth, alignment: .leading)

        Button(action: addHeader) {
          Image(systemName: "plus.circle")
            .foregroundColor(.secondary)
        }
        .buttonStyle(.plain)
        .help("Add custom header")
        .accessibilityLabel("Add custom header")

        Spacer()
      }
      .onAppear {
        let stored = KeychainManager.shared.getCustomTranscriptionHeaders()
        customHeaders = stored.map { HeaderEntry(key: $0["key"] ?? "", value: $0["value"] ?? "") }
      }

      ForEach($customHeaders) { $header in
        HStack(alignment: .center, spacing: 8) {
          Spacer().frame(width: SettingsConstants.labelWidth)

          TextField("Header name", text: $header.key)
            .textFieldStyle(.roundedBorder)
            .font(.system(.body, design: .monospaced))
            .frame(height: SettingsConstants.textFieldHeight)
            .onChange(of: header.key) { _, _ in saveHeaders() }

          ZStack {
            if header.isValueVisible {
              TextField("Value", text: $header.value)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .frame(height: SettingsConstants.textFieldHeight)
            } else {
              SecureField("Value", text: $header.value)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .frame(height: SettingsConstants.textFieldHeight)
            }
          }
          .onChange(of: header.value) { _, _ in saveHeaders() }

          Button(action: { header.isValueVisible.toggle() }) {
            Image(systemName: header.isValueVisible ? "eye.slash" : "eye")
              .foregroundColor(.secondary)
          }
          .buttonStyle(.plain)
          .help(header.isValueVisible ? "Hide value" : "Show value")
          .accessibilityLabel(header.isValueVisible ? "Hide value" : "Show value")

          Button(action: { removeHeader(id: header.id) }) {
            Image(systemName: "minus.circle")
              .foregroundColor(.red)
          }
          .buttonStyle(.plain)
          .help("Remove header")
        }
      }

      Text("Works with any OpenAI /v1/audio/transcriptions–compatible endpoint (OpenAI, self-hosted Whisper, faster-whisper-server, or any other compatible backend). Use custom headers for Cloudflare Access (CF-Access-Client-Id / CF-Access-Client-Secret) or other auth schemes.")
        .font(.caption)
        .foregroundColor(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      Text("Note: the Dictation system prompt does not apply here — OpenAI's transcription endpoint accepts no system instruction. Your Whisper Glossary is forwarded as the `prompt` bias hint and your language selection as the `language` parameter.")
        .font(.caption)
        .foregroundColor(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func addHeader() {
    customHeaders.append(HeaderEntry(key: "", value: ""))
  }

  private func removeHeader(id: UUID) {
    customHeaders.removeAll { $0.id == id }
    saveHeaders()
  }

  private func saveHeaders() {
    let toStore = customHeaders.map { ["key": $0.key, "value": $0.value] }
    _ = KeychainManager.shared.saveCustomTranscriptionHeaders(toStore)
  }
}
