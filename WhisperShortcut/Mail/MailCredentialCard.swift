import SwiftUI

// MARK: - Request

enum MailCredentialOutcome: Equatable {
  case connected(account: MailAccount, summary: MailConnectSummary)
  case cancelled
}

/// A `connect_mail_account` call waiting for the user on the inline password card. One per session
/// at a time, like `ToolApprovalRequest`. Everything on the card is decided here, by the app: the
/// model only names the address, so text it read in an email can't put a password prompt of its
/// own wording on screen.
struct MailCredentialRequest: Identifiable {
  enum Server: Equatable {
    /// The address belongs to a known provider (gmx.de, web.de, …): the server is not editable.
    case fixed(host: String, port: Int, note: String?)
    /// Own domain: the user picks where the mailbox is hosted. `detected`: `initialHost` came from
    /// the domain's MX records rather than a guess.
    case choose(initialHost: String, detected: Bool)
  }

  let id: UUID
  /// The chat the turn belongs to. The login can finish after the user switched tabs.
  let sessionId: UUID
  let email: String
  let server: Server
  let continuation: CheckedContinuation<MailCredentialOutcome, Never>

  static let imapsPort = 993

  /// Where custom-domain mailboxes are commonly hosted. Offered on the card for own domains.
  static let hostedProviders: [(name: String, host: String)] = [
    ("IONOS", "imap.ionos.de"),
    ("Strato", "imap.strato.de"),
    ("GMX", "imap.gmx.net"),
    ("WEB.DE", "imap.web.de"),
    ("Hetzner", "mail.your-server.de"),
    ("iCloud+ custom domain", "imap.mail.me.com"),
    ("mailbox.org", "imap.mailbox.org"),
    ("Fastmail", "imap.fastmail.com"),
    ("Zoho Mail (EU)", "imap.zoho.eu"),
    ("Zoho Mail", "imap.zoho.com"),
    ("Hostinger", "imap.hostinger.com"),
  ]

  /// The server the card preselects for an own domain. A host the model suggested is used only when
  /// it is a listed provider's server or lies under the address's own domain; anything else falls
  /// back to `imap.<domain>`.
  static func trustedInitialHost(requested: String?, email: String, fallback: String) -> String {
    guard let requested = requested?.lowercased(), !requested.isEmpty else { return fallback }
    if hostedProviders.contains(where: { $0.host == requested }) { return requested }
    let domain = email.split(separator: "@").last.map { $0.lowercased() } ?? ""
    if !domain.isEmpty, requested == domain || requested.hasSuffix("." + domain) { return requested }
    return fallback
  }
}

// MARK: - Card

/// Inline password card for connecting an IMAP mailbox. The password exists only in this view's
/// state until the login succeeds and `MailAccountStore` moves it into the Keychain.
struct MailCredentialCardView: View {
  let request: MailCredentialRequest
  let onResolve: (MailCredentialOutcome) -> Void

  private enum Phase: Equatable {
    case editing
    case verifying
    case connected
    case failed(String)
  }

  private static let otherProviderTag = "__other__"

  @State private var password = ""
  @State private var phase: Phase = .editing
  /// Host of the selected provider, or `otherProviderTag` for a custom server.
  @State private var providerTag = ""
  @State private var customHost = ""
  @FocusState private var focusedField: Field?
  /// The running login, so Cancel can stop it.
  @State private var loginTask: Task<Void, Never>?

  private enum Field { case password, host }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      header
      if phase != .connected {
        fields
        footer
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(RoundedRectangle(cornerRadius: 12).fill(ChatTheme.controlBackground))
    .overlay(
      RoundedRectangle(cornerRadius: 12)
        .strokeBorder(ChatTheme.primaryText.opacity(ChatTheme.borderOpacity * 2), lineWidth: 1)
    )
    .animation(.easeOut(duration: 0.15), value: phase)
    .onAppear(perform: setUp)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Password needed to connect \(request.email)")
  }

  // MARK: Sections

  private var header: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: phase == .connected ? "checkmark.circle.fill" : "lock")
        .foregroundColor(phase == .connected ? .green : ChatTheme.secondaryText)
      VStack(alignment: .leading, spacing: 3) {
        Text(phase == .connected ? "Connected \(request.email)" : "Connect \(request.email)")
          .font(.system(size: 13, weight: .semibold))
          .foregroundColor(ChatTheme.primaryText)
          .lineLimit(1)
          .truncationMode(.middle)
        Text(phase == .connected
             ? "Saved in your Keychain. Read-only access."
             : "Read-only. Your password stays in your Keychain and is never sent to the AI.")
          .font(.system(size: 12))
          .foregroundColor(ChatTheme.secondaryText)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private var fields: some View {
    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 8) {
      switch request.server {
      case .fixed(let host, let port, _):
        GridRow {
          label("Server")
          Text("\(host) · SSL, port \(port)")
            .font(.system(size: 12))
            .foregroundColor(ChatTheme.secondaryText)
            .textSelection(.enabled)
        }
      case .choose(_, let detected):
        GridRow {
          label("Hosted at")
          Picker("", selection: $providerTag) {
            ForEach(MailCredentialRequest.hostedProviders, id: \.host) { provider in
              Text(provider.name).tag(provider.host)
            }
            Divider()
            Text("Other server…").tag(Self.otherProviderTag)
          }
          .labelsHidden()
          .pickerStyle(.menu)
          .fixedSize()
          .disabled(phase == .verifying)
        }
        if detected && providerTag == initialHost {
          GridRow {
            Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
            Text("Detected from your domain's mail settings.")
              .font(.system(size: 11))
              .foregroundColor(ChatTheme.secondaryText)
          }
        }
        if providerTag == Self.otherProviderTag {
          GridRow {
            label("IMAP server")
            TextField("imap.example.com", text: $customHost)
              .textFieldStyle(.roundedBorder)
              .font(.system(size: 12))
              .frame(maxWidth: 260)
              .focused($focusedField, equals: .host)
              .disabled(phase == .verifying)
              .onSubmit(connect)
          }
        }
      }
      GridRow {
        label("Password")
        SecureField("Password", text: $password)
          .textFieldStyle(.roundedBorder)
          .font(.system(size: 12))
          .frame(maxWidth: 260)
          .focused($focusedField, equals: .password)
          .disabled(phase == .verifying)
          .onSubmit(connect)
          .onChange(of: password) { _, _ in
            if case .failed = phase { phase = .editing }
          }
      }
    }
  }

  private var footer: some View {
    VStack(alignment: .leading, spacing: 8) {
      if case .failed(let message) = phase {
        Label(message, systemImage: "exclamationmark.triangle.fill")
          .font(.system(size: 12))
          .foregroundColor(.orange)
          .fixedSize(horizontal: false, vertical: true)
      } else if let note = providerNote {
        Label(note, systemImage: "info.circle")
          .font(.system(size: 12))
          .foregroundColor(ChatTheme.secondaryText)
          .fixedSize(horizontal: false, vertical: true)
      }
      HStack(spacing: 8) {
        Spacer()
        // Stays enabled while checking: a server that never answers must not trap the user.
        Button("Cancel", action: cancel)
          .keyboardShortcut(.cancelAction)
        if phase == .verifying {
          HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text("Checking…")
              .font(.system(size: 12))
              .foregroundColor(ChatTheme.secondaryText)
          }
        } else {
          Button("Connect", action: connect)
            .keyboardShortcut(.defaultAction)
            .disabled(!canConnect)
        }
      }
      .controlSize(.small)
    }
  }

  private func label(_ text: String) -> some View {
    Text(text)
      .font(.system(size: 12))
      .foregroundColor(ChatTheme.secondaryText)
      .gridColumnAlignment(.trailing)
  }

  // MARK: State

  private var providerNote: String? {
    if case .fixed(_, _, let note) = request.server { return note }
    return nil
  }

  private var initialHost: String? {
    if case .choose(let host, _) = request.server { return host }
    return nil
  }

  private var selectedHost: String {
    switch request.server {
    case .fixed(let host, _, _): return host
    case .choose:
      let host = providerTag == Self.otherProviderTag ? customHost : providerTag
      return host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
  }

  private var selectedPort: Int {
    if case .fixed(_, let port, _) = request.server { return port }
    return MailCredentialRequest.imapsPort
  }

  private var canConnect: Bool {
    !password.isEmpty && selectedHost.contains(".") && !selectedHost.contains(" ")
  }

  private func setUp() {
    if case .choose(let initialHost, _) = request.server {
      if MailCredentialRequest.hostedProviders.contains(where: { $0.host == initialHost }) {
        providerTag = initialHost
      } else {
        providerTag = Self.otherProviderTag
        customHost = initialHost
      }
    }
    // After the card is in the hierarchy; focusing in the same pass is dropped.
    DispatchQueue.main.async { focusedField = .password }
  }

  private func connect() {
    guard canConnect, phase != .verifying else { return }
    let email = request.email
    let host = selectedHost
    let port = selectedPort
    let secret = password
    phase = .verifying
    loginTask = Task { @MainActor in
      do {
        let summary = try await MailAccountStore.connect(
          email: email, host: host, port: port, password: secret)
        // Cancelled while the login was still in flight but it went through anyway: the user
        // said no, so don't keep the account.
        if Task.isCancelled {
          MailAccountStore.remove(email: email)
          return
        }
        password = ""
        phase = .connected
        // Long enough to read the confirmation before the card leaves with the step.
        try? await Task.sleep(for: .milliseconds(900))
        onResolve(.connected(
          account: MailAccount(email: email, host: host, port: port, connectedAt: Date()),
          summary: summary))
      } catch {
        guard !Task.isCancelled else { return }
        phase = .failed(error.localizedDescription)
        focusedField = .password
      }
    }
  }

  private func cancel() {
    loginTask?.cancel()
    loginTask = nil
    password = ""
    onResolve(.cancelled)
  }
}
