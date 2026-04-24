//
//  GoogleAPIKeySection.swift
//  WhisperShortcut
//

import SwiftUI
import AppKit

struct GoogleAPIKeySection: View {
  @ObservedObject var viewModel: SettingsViewModel
  @FocusState.Binding var focusedField: SettingsFocusField?
  @State private var isKeyVisible: Bool = false

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "🔑 Google API Key",
        subtitle: "Or use a Google API key (billed to your account). Get a key from Google AI Studio (link below)."
      )

      HStack(alignment: .center, spacing: 16) {
        Text("API Key:")
          .font(.body)
          .fontWeight(.medium)
          .frame(width: SettingsConstants.labelWidth, alignment: .leading)
          .textSelection(.enabled)

        ZStack {
          if isKeyVisible {
            TextField("AIza...", text: $viewModel.data.googleAPIKey)
              .textFieldStyle(.roundedBorder)
              .font(.system(.body, design: .monospaced))
              .frame(height: SettingsConstants.textFieldHeight)
              .focused($focusedField, equals: .googleAPIKey)
          } else {
            SecureField("AIza...", text: $viewModel.data.googleAPIKey)
              .textFieldStyle(.roundedBorder)
              .font(.system(.body, design: .monospaced))
              .frame(height: SettingsConstants.textFieldHeight)
              .focused($focusedField, equals: .googleAPIKey)
          }
        }
        .frame(maxWidth: SettingsConstants.apiKeyMaxWidth)
        .onAppear {
          viewModel.data.googleAPIKey = KeychainManager.shared.getGoogleAPIKey() ?? ""
        }
        .onChange(of: viewModel.data.googleAPIKey) { _, newValue in
          Task {
            _ = KeychainManager.shared.saveGoogleAPIKey(newValue)
          }
        }

        Button(action: { isKeyVisible.toggle() }) {
          Image(systemName: isKeyVisible ? "eye.slash" : "eye")
            .foregroundColor(.secondary)
        }
        .buttonStyle(.plain)
        .help(isKeyVisible ? "Hide API key" : "Show API key")

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
        .pointerCursorOnHover()

        Text(" 💡")
          .font(.callout)
          .foregroundColor(.secondary)
      }
      .fixedSize(horizontal: false, vertical: true)

      HStack(spacing: 0) {
        Text("Configure rate limits at ")
          .font(.callout)
          .foregroundColor(.secondary)
          .textSelection(.enabled)

        Link(
          destination: URL(string: "https://console.cloud.google.com/apis/api/generativelanguage.googleapis.com/quotas")!
        ) {
          Text("console.cloud.google.com/.../quotas")
            .font(.callout)
            .foregroundColor(.blue)
            .underline()
            .textSelection(.enabled)
        }
        .pointerCursorOnHover()
      }
      .fixedSize(horizontal: false, vertical: true)
    }
  }
}
