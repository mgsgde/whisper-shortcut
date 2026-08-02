import SwiftUI

/// Connect / disconnect an OpenRouter account, plus the manual key field as a fallback.
///
/// Rendered in **two** places on purpose: Settings → General next to the other provider keys, where
/// somebody looking for "how do I add a provider" will actually find it, and Settings → Dictate
/// above the model picker, where it is needed in context. It used to live only in the Dictate
/// section, which is shown only once OpenRouter is *already* the selected transcription model — so
/// the one thing that makes OpenRouter selectable was invisible until you had selected it.
///
/// Both copies observe the same `OpenRouterOAuthService`, so connecting in one updates the other.
struct OpenRouterConnectionSection: View {
  /// Set on the General tab, where this stands alone as a provider entry. The Dictate section
  /// brings its own header, so it renders this without one.
  var showsHeader: Bool = true

  @ObservedObject private var oauthService = OpenRouterOAuthService.shared

  @State private var apiKey: String = ""
  @State private var isKeyVisible: Bool = false
  @State private var isAuthorizing = false
  @State private var errorMessage: String?
  @State private var isManualKeyExpanded = false

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      if showsHeader {
        SectionHeader(
          title: "OpenRouter",
          systemImage: "arrow.triangle.branch",
          subtitle: "One account for models from every provider. Sign in once — there is no API key to copy."
        )
      }

      connectionRow

      if isAuthorizing {
        HStack(spacing: 8) {
          ProgressView()
            .controlSize(.small)
          Text("Waiting for OpenRouter sign-in...")
            .font(.caption)
            .foregroundColor(.secondary)
        }
      }

      if let errorMessage {
        Text(errorMessage)
          .font(.caption)
          .foregroundColor(.red)
          .fixedSize(horizontal: false, vertical: true)
      }

      // Kept as a second path rather than a replacement: users who already hold an OpenRouter key,
      // or who provision keys centrally for a team, have nothing to gain from the browser round
      // trip. Both paths write the same Keychain slot.
      DisclosureGroup("Enter an API key manually instead", isExpanded: $isManualKeyExpanded) {
        manualKeyField
          .padding(.top, 8)
      }
      .font(.caption)
    }
    .onAppear {
      apiKey = KeychainManager.shared.get(.openRouter) ?? ""
      oauthService.refreshConnectionState()
    }
  }

  // MARK: - Connection

  @ViewBuilder
  private var connectionRow: some View {
    HStack(spacing: 12) {
      if oauthService.isConnected {
        Image(systemName: "checkmark.circle.fill")
          .foregroundColor(.green)
        Text("Connected")
          .font(.callout)
        Spacer()
        Link("Credits", destination: OpenRouterOAuthConfig.creditsURL)
          .font(.callout)
          .pointerCursorOnHover()
        Button("Disconnect") {
          oauthService.disconnect()
          apiKey = ""
          errorMessage = nil
          // Chat may have been running on this key via the OpenRouter base URL; re-check what is
          // still selectable so the picker cannot keep pointing at a model we can no longer reach.
          ModelSelectionReconciler.reconcileAll()
        }
      } else {
        Image(systemName: "circle")
          .foregroundColor(.secondary)
        Text("Not connected")
          .font(.callout)
          .foregroundColor(.secondary)
        Spacer()
        Button("Connect OpenRouter Account") {
          startAuthorization()
        }
        .disabled(isAuthorizing)
      }
    }

    if !oauthService.isConnected && !isAuthorizing {
      Text("Sign in once — no API key to copy. New to OpenRouter? The same flow creates the account. You pay OpenRouter directly for what you use.")
        .font(.caption)
        .foregroundColor(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func startAuthorization() {
    isAuthorizing = true
    errorMessage = nil
    Task {
      do {
        if try await oauthService.connect() {
          apiKey = KeychainManager.shared.get(.openRouter) ?? ""
          isManualKeyExpanded = false
          // The key may have just unlocked the OpenRouter chat endpoint too.
          ModelSelectionReconciler.reconcileAll()
        }
      } catch {
        errorMessage = error.localizedDescription
      }
      isAuthorizing = false
    }
  }

  // MARK: - Manual key entry

  private var manualKeyField: some View {
    VStack(alignment: .leading, spacing: 8) {
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
        .onChange(of: apiKey) { _, newValue in
          _ = KeychainManager.shared.save(newValue, for: .openRouter)
          // Keeps the Connected/Not connected row honest when the key is typed rather than granted.
          oauthService.refreshConnectionState()
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
        Text("Required. Dictation through OpenRouter will fail until you connect an account or set this.")
          .font(.caption)
          .foregroundColor(.orange)
          .padding(.leading, SettingsConstants.labelWidth + 16)
      }
    }
  }
}
