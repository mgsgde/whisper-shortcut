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
  @State private var keychainSaveError: OSStatus?

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      HStack(alignment: .top) {
        SectionHeader(
          title: "Google API Key",
          systemImage: "key.fill",
          subtitle: "Powers Gemini transcription, Dictate Prompt, Read Aloud, and Chat. Get a key from Google AI Studio (link below)."
        )
        Spacer()
        APIKeyStatusBadge(provider: .google, key: viewModel.data.googleAPIKey)
      }

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
          // Only overwrite the field when the read actually returns a stored key. A failed
          // Keychain read must not blank the binding — the onChange below would then persist
          // "" and wipe the real key (seen in the wild as "my API keys disappear").
          if let stored = KeychainManager.shared.getGoogleAPIKey(), !stored.isEmpty {
            viewModel.data.googleAPIKey = stored
          }
        }
        .onChange(of: viewModel.data.googleAPIKey) { _, newValue in
          Task {
            let saved = KeychainManager.shared.saveGoogleAPIKey(newValue)
            await MainActor.run {
              keychainSaveError = saved ? nil : KeychainManager.shared.lastWriteError(for: .google)
            }
            ModelSelectionReconciler.reconcileAll()
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

      if let keychainSaveError {
        KeychainSaveWarning(status: keychainSaveError)
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
