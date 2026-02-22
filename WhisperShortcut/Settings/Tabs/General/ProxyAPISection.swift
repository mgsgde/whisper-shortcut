//
//  ProxyAPISection.swift
//  WhisperShortcut
//
//  Phase 1: Proxy API URL and toggle for sending Gemini requests via backend (latency testing).
//

import SwiftUI
import AppKit

struct ProxyAPISection: View {
  @ObservedObject var viewModel: SettingsViewModel

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "Proxy API (testing)",
        subtitle: "Optional. When enabled, generateContent requests are sent to your proxy API instead of Google directly. Use this to test latency (e.g. Cloud Run in your region). Leave empty to use direct Gemini."
      )

      HStack(alignment: .center, spacing: 16) {
        Text("Proxy base URL:")
          .font(.body)
          .fontWeight(.medium)
          .frame(width: SettingsConstants.labelWidth, alignment: .leading)
          .textSelection(.enabled)

        TextField("https://your-service.run.app", text: $viewModel.data.proxyAPIBaseURL)
          .textFieldStyle(.roundedBorder)
          .font(.system(.body, design: .monospaced))
          .frame(height: SettingsConstants.textFieldHeight)
          .frame(maxWidth: SettingsConstants.apiKeyMaxWidth)
          .onChange(of: viewModel.data.proxyAPIBaseURL) { _, newValue in
            UserDefaults.standard.set(newValue, forKey: UserDefaultsKeys.proxyAPIBaseURL)
          }

        Spacer()
      }

      HStack(alignment: .center, spacing: 16) {
        Text("Use Gemini via Proxy:")
          .font(.body)
          .fontWeight(.medium)
          .frame(width: SettingsConstants.labelWidth, alignment: .leading)

        Toggle("", isOn: $viewModel.data.useGeminiViaProxy)
          .toggleStyle(.switch)
          .onChange(of: viewModel.data.useGeminiViaProxy) { _, newValue in
            UserDefaults.standard.set(newValue, forKey: UserDefaultsKeys.useGeminiViaProxy)
          }

        Spacer()
      }
    }
  }
}
