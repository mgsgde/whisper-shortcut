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

enum MailProviderPresets {
  static func lookup(email: String) -> MailProviderLookup {
    guard let domain = domain(of: email) else {
      return .unknown(suggestedHost: "")
    }
    if isMicrosoft(domain) {
      return .unsupported(reason: "Microsoft accounts only allow sign-in through Microsoft, which WhisperShortcut doesn't support yet.")
    }
    if domain == "gmail.com" || domain == "googlemail.com" {
      return .unsupported(reason: "Gmail is read through the Google connection: Settings → Chat → Google Account.")
    }
    if let preset = presets[domain] {
      return .preset(MailServerPreset(host: preset.host, port: 993, note: preset.note))
    }
    return .unknown(suggestedHost: "imap.\(domain)")
  }

  private static let icloudNote = "Use an app-specific password from account.apple.com."
  private static let tOnlineNote = "Use your T-Online e-mail password, not the login password."
  private static let yahooNote = "Use an app password from Yahoo account security."

  private static let presets: [String: (host: String, note: String?)] = [
    "ionos.de": ("imap.ionos.de", nil),
    "ionos.com": ("imap.ionos.de", nil),
    "1und1.de": ("imap.ionos.de", nil),
    "online.de": ("imap.ionos.de", nil),
    "gmx.de": ("imap.gmx.net", nil),
    "gmx.net": ("imap.gmx.net", nil),
    "gmx.at": ("imap.gmx.net", nil),
    "gmx.ch": ("imap.gmx.net", nil),
    "web.de": ("imap.web.de", nil),
    "icloud.com": ("imap.mail.me.com", icloudNote),
    "me.com": ("imap.mail.me.com", icloudNote),
    "mac.com": ("imap.mail.me.com", icloudNote),
    "posteo.de": ("posteo.de", nil),
    "posteo.net": ("posteo.de", nil),
    "mailbox.org": ("imap.mailbox.org", nil),
    "strato.de": ("imap.strato.de", nil),
    "t-online.de": ("secureimap.t-online.de", tOnlineNote),
    "yahoo.com": ("imap.mail.yahoo.com", yahooNote),
    "yahoo.de": ("imap.mail.yahoo.com", yahooNote),
    "freenet.de": ("mx.freenet.de", nil),
  ]

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
      if opened { try? await session.logout() }
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
