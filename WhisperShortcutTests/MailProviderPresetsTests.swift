import Testing

@testable import WhisperShortcut_AppStore

@Suite("Mail provider presets")
struct MailProviderPresetsTests {
  @Test func ionos() {
    #expect(MailProviderPresets.lookup(email: "a@ionos.de") == .preset(
      MailServerPreset(host: "imap.ionos.de", port: 993, note: nil)))
  }

  @Test func gmxNet() {
    #expect(MailProviderPresets.lookup(email: "a@gmx.net") == .preset(
      MailServerPreset(host: "imap.gmx.net", port: 993, note: nil)))
  }

  @Test func icloudNote() {
    #expect(MailProviderPresets.lookup(email: "a@icloud.com") == .preset(
      MailServerPreset(
        host: "imap.mail.me.com", port: 993,
        note: "Use an app-specific password from account.apple.com.")))
  }

  @Test func outlookUnsupported() {
    #expect(MailProviderPresets.lookup(email: "a@outlook.com") == .unsupported(
      reason: "Microsoft accounts only allow sign-in through Microsoft, which WhisperShortcut doesn't support yet."))
  }

  @Test func gmailUnsupported() {
    #expect(MailProviderPresets.lookup(email: "a@gmail.com") == .unsupported(
      reason: "Connect Google in Settings → Integrations; Gmail is read through that connection."))
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
      reason: "Connect Google in Settings → Integrations; Gmail is read through that connection."))
  }
}
