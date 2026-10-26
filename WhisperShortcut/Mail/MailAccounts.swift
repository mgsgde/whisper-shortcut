import Foundation

struct MailAccount: Codable, Equatable, Identifiable, Sendable {
  let email: String
  let host: String
  let port: Int
  let connectedAt: Date

  var id: String { email.lowercased() }
}

struct MailServerPreset: Equatable, Sendable {
  let host: String
  let port: Int
  let note: String?
}

enum MailProviderLookup: Equatable {
  case preset(MailServerPreset)
  case unsupported(reason: String)
  case unknown(suggestedHost: String)
}

/// One row per mail provider: the single source for domain presets, MX detection and the picker
/// on the credential card. The card looks the note up by IMAP host, so a custom domain detected
/// via MX gets the same note as the provider's own addresses.
struct MailProvider: Sendable {
  enum Security: Sendable { case ssl }

  let name: String
  let host: String
  let port: Int
  let security: Security
  /// Shown on the credential card for this provider's server.
  let note: String?
  /// Addresses at these domains belong to the provider itself (server fixed on the card).
  let domains: [String]
  /// MX host suffixes that mean a custom domain is hosted here.
  let mxSuffixes: [String]

  private static let icloudNote = "Use an app-specific password from account.apple.com."
  private static let tOnlineNote = "Use your T-Online e-mail password, not the login password."
  private static let yahooNote = "Use an app password from Yahoo account security."

  private static func make(
    _ name: String, _ host: String, note: String? = nil,
    domains: [String] = [], mx: [String] = []
  ) -> MailProvider {
    MailProvider(name: name, host: host, port: 993, security: .ssl, note: note, domains: domains, mxSuffixes: mx)
  }

  /// Order is the picker order on the card.
  static let all: [MailProvider] = [
    make("IONOS", "imap.ionos.de",
         domains: ["ionos.de", "ionos.com", "1und1.de", "online.de"],
         mx: ["ionos.de", "ionos.com", "ionos.co.uk", "kundenserver.de", "1and1.com"]),
    make("Strato", "imap.strato.de", domains: ["strato.de"], mx: ["rzone.de"]),
    make("GMX", "imap.gmx.net", domains: ["gmx.de", "gmx.net", "gmx.at", "gmx.ch"], mx: ["gmx.net"]),
    make("WEB.DE", "imap.web.de", domains: ["web.de"], mx: ["web.de"]),
    make("Hetzner", "mail.your-server.de", mx: ["your-server.de"]),
    make("iCloud+ custom domain", "imap.mail.me.com", note: icloudNote,
         domains: ["icloud.com", "me.com", "mac.com"], mx: ["mail.icloud.com"]),
    make("mailbox.org", "imap.mailbox.org", domains: ["mailbox.org"], mx: ["mailbox.org"]),
    make("Fastmail", "imap.fastmail.com", mx: ["messagingengine.com"]),
    make("Zoho Mail (EU)", "imap.zoho.eu", mx: ["zoho.eu"]),
    make("Zoho Mail", "imap.zoho.com", mx: ["zoho.com"]),
    make("Hostinger", "imap.hostinger.com", mx: ["hostinger.com"]),
    make("Posteo", "posteo.de", domains: ["posteo.de", "posteo.net"], mx: ["posteo.de"]),
    make("T-Online", "secureimap.t-online.de", note: tOnlineNote,
         domains: ["t-online.de"], mx: ["t-online.de"]),
    make("Yahoo", "imap.mail.yahoo.com", note: yahooNote,
         domains: ["yahoo.com", "yahoo.de"], mx: ["yahoodns.net"]),
    // TODO(verify MX): freenet.de's MX host names are not confirmed, so no MX suffix yet.
    make("freenet", "mx.freenet.de", domains: ["freenet.de"]),
  ]

  static func provider(forDomain domain: String) -> MailProvider? {
    all.first { $0.domains.contains(domain) }
  }

  static func provider(forHost host: String) -> MailProvider? {
    let host = host.lowercased()
    return all.first { $0.host == host }
  }

  static func provider(forMXHost host: String) -> MailProvider? {
    all.first { provider in
      provider.mxSuffixes.contains { host == $0 || host.hasSuffix("." + $0) }
    }
  }
}

enum MailProviderPresets {
  static func lookup(email: String) -> MailProviderLookup {
    guard let domain = domain(of: email) else {
      return .unknown(suggestedHost: "")
    }
    if isMicrosoft(domain) {
      return .unsupported(reason: "Microsoft accounts only allow sign-in through Microsoft, which WhisperShortcut doesn't support yet.")
    }
    if domain == "gmail.com" || domain == "googlemail.com" {
      return .unsupported(reason: "Gmail is read through the Google connection: Settings → Accounts → Google Account.")
    }
    if let provider = MailProvider.provider(forDomain: domain) {
      return .preset(MailServerPreset(host: provider.host, port: provider.port, note: provider.note))
    }
    return .unknown(suggestedHost: "imap.\(domain)")
  }

  private static func domain(of email: String) -> String? {
    let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else { return nil }
    let parts = trimmed.split(separator: "@", omittingEmptySubsequences: false)
    guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
    let domain = String(parts[1]).lowercased()
    guard domain.contains("."), !domain.hasPrefix("."), !domain.hasSuffix(".") else { return nil }
    return domain
  }

  private static func isMicrosoft(_ domain: String) -> Bool {
    if domain == "msn.com" || domain.hasSuffix(".msn.com") { return true }
    for name in ["outlook", "hotmail", "live"] {
      if domain == name || domain.hasPrefix(name + ".") || domain.contains("." + name + ".") {
        return true
      }
    }
    return false
  }
}

struct MailConnectSummary: Equatable, Sendable {
  let folderCount: Int
  let inboxCount: Int
}

enum MailToolError: Error, Equatable, Sendable, LocalizedError {
  case noAccounts
  case ambiguous([String])
  case unknownAccount(String)
  case missingPassword(String)

  var message: String {
    switch self {
    case .noAccounts:
      return "No IMAP mailbox is connected. Call connect_mail_account with the email address to connect one."
    case .ambiguous(let emails):
      return "Several mailboxes are connected (\(emails.joined(separator: ", "))). Pass account with one of these addresses."
    case .unknownAccount(let email):
      return "No connected mailbox matches \(email)."
    case .missingPassword(let email):
      return "The password for \(email) is missing from the Keychain. Connect that mailbox again."
    }
  }

  var errorDescription: String? { message }
}

@MainActor
enum MailAccountStore {
  private static let storageKey = "mailAccounts.v1"

  static func accounts() -> [MailAccount] {
    guard let data = UserDefaults.standard.data(forKey: storageKey),
          let decoded = try? JSONDecoder().decode([MailAccount].self, from: data) else {
      return []
    }
    return decoded
  }

  static var hasAccounts: Bool { !accounts().isEmpty }

  /// Logs in, lists folders, and examines INBOX. The password reaches the Keychain only after that succeeds.
  static func connect(email: String, host: String, port: Int, password: String) async throws -> MailConnectSummary {
    let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmedEmail.isEmpty || !trimmedEmail.contains("@") {
      throw IMAPError.protocolError("The email address is not valid.")
    }
    if trimmedHost.isEmpty {
      throw IMAPError.connectionFailed("the mail server")
    }
    if password.contains("\r") || password.contains("\n") {
      throw IMAPError.unsupportedPassword
    }
    let account = MailAccount(email: trimmedEmail, host: trimmedHost, port: port, connectedAt: Date())
    let summary = try await withSession(account: account, password: password) { session in
      let folders = try await session.listMailboxes()
      let inboxCount = try await session.examine("INBOX")
      return MailConnectSummary(folderCount: folders.count, inboxCount: inboxCount)
    }
    let key = keychainAccount(trimmedEmail)
    guard KeychainManager.shared.saveSecret(password, account: key) else {
      KeychainManager.shared.deleteSecret(account: key)
      throw IMAPError.protocolError("Couldn't save the password in the Keychain.")
    }
    do {
      try upsert(account)
    } catch {
      KeychainManager.shared.deleteSecret(account: key)
      throw IMAPError.protocolError("Couldn't save the mailbox.")
    }
    return summary
  }

  static func remove(email: String) {
    let id = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    KeychainManager.shared.deleteSecret(account: keychainAccount(id))
    let remaining = accounts().filter { $0.id != id }
    if let data = try? JSONEncoder().encode(remaining) {
      UserDefaults.standard.set(data, forKey: storageKey)
    }
  }

  static func resolve(_ email: String?) -> Result<(MailAccount, String), MailToolError> {
    let all = accounts()
    if all.isEmpty { return .failure(.noAccounts) }
    let account: MailAccount
    let trimmed = email?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !trimmed.isEmpty {
      guard let found = all.first(where: { $0.id == trimmed.lowercased() }) else {
        return .failure(.unknownAccount(trimmed))
      }
      account = found
    } else if all.count == 1 {
      account = all[0]
    } else {
      return .failure(.ambiguous(all.map(\.email)))
    }
    guard let password = KeychainManager.shared.secret(account: keychainAccount(account.email)),
          !password.isEmpty else {
      return .failure(.missingPassword(account.email))
    }
    return .success((account, password))
  }

  static func withSession<T>(
    account: MailAccount,
    password: String,
    _ body: (IMAPSession) async throws -> T
  ) async throws -> T {
    let transport = NWIMAPTransport(host: account.host, port: account.port)
    let session = IMAPSession(transport: transport, host: account.host)
    var opened = false
    do {
      try await transport.open()
      opened = true
      try await session.login(user: account.email, password: password)
      let value = try await body(session)
      // Logout always runs after a successful open. `defer` cannot await.
      try? await session.logout()
      transport.close()
      return value
    } catch {
      // A dead connection cannot answer LOGOUT; skip it after a transport error or timeout.
      if opened, !((error as? IMAPError)?.isTransportFailure ?? false) { try? await session.logout() }
      transport.close()
      throw error
    }
  }

  static func keychainAccount(_ email: String) -> String {
    "imap:" + email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  private static func upsert(_ account: MailAccount) throws {
    var all = accounts()
    if let index = all.firstIndex(where: { $0.id == account.id }) {
      all[index] = account
    } else {
      all.append(account)
    }
    let data = try JSONEncoder().encode(all)
    UserDefaults.standard.set(data, forKey: storageKey)
  }
}
