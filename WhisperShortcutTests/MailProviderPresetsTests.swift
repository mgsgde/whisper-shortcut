import Testing

@testable import WhisperShortcut_AppStore

@Suite("Mail provider presets")
struct MailProviderPresetsTests {
  @Test("Known domains resolve to an IMAP host or are unsupported", arguments: [
    ("a@ionos.de", Optional("imap.ionos.de"), "ionos"),
    ("a@gmx.net", Optional("imap.gmx.net"), "gmx.net"),
    ("a@icloud.com", Optional("imap.mail.me.com"), "icloud"),
    ("a@outlook.com", nil, "outlook"),
    ("a@gmail.com", nil, "gmail"),
  ])
  func knownDomains(email: String, host: String?, label: String) {
    let result = MailProviderPresets.lookup(email: email)
    if let host {
      guard case .preset(let preset) = result else {
        Issue.record("\(label): expected a preset")
        return
      }
      #expect(preset.host == host, "\(label)")
      #expect(preset.port == 993, "\(label)")
    } else {
      guard case .unsupported = result else {
        Issue.record("\(label): expected unsupported")
        return
      }
    }
  }

  @Test func unknownDomain() {
    #expect(MailProviderPresets.lookup(email: "a@example.com") == .unknown(suggestedHost: "imap.example.com"))
    #expect(MailProviderPresets.lookup(email: "not-an-email") == .unknown(suggestedHost: ""))
  }

  @Test func lookupIsCaseInsensitive() {
    #expect(MailProviderPresets.lookup(email: "User@Ionos.DE") == .preset(
      MailServerPreset(host: "imap.ionos.de", port: 993, note: nil)))
    #expect(MailProviderPresets.lookup(email: "A@Gmx.NET") == .preset(
      MailServerPreset(host: "imap.gmx.net", port: 993, note: nil)))
    #expect(MailProviderPresets.lookup(email: "A@Gmail.com") == .unsupported(
      reason: "Gmail is read through the Google connection: Settings → Accounts → Google Account."))
  }
}
