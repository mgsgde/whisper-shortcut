import Testing

@testable import WhisperShortcut_AppStore

@Suite("Mail host detector")
struct MailHostDetectorTests {
  @Test func guess() {
    #expect(MailHostDetector.guess(mxHosts: ["mx00.ionos.de", "mx01.ionos.de"]) == .imapHost("imap.ionos.de"))
    #expect(MailHostDetector.guess(mxHosts: ["smtpin.rzone.de"]) == .imapHost("imap.strato.de"))
    #expect(MailHostDetector.guess(mxHosts: ["aspmx.l.google.com"]) == .google)
    #expect(MailHostDetector.guess(mxHosts: ["x-com.mail.protection.outlook.com"]) == .microsoft)
    #expect(MailHostDetector.guess(mxHosts: ["mx1.example.org"]) == nil)
    #expect(MailHostDetector.guess(mxHosts: ["notionos.de"]) == nil)
    #expect(MailHostDetector.guess(mxHosts: []) == nil)
  }
}

@Suite("Mail provider table")
struct MailProviderTableTests {
  @Test func icloudCustomDomainViaMXGetsIcloudNote() {
    guard case .imapHost(let host)? = MailHostDetector.guess(mxHosts: ["mx01.mail.icloud.com"]) else {
      Issue.record("iCloud MX not detected")
      return
    }
    #expect(host == "imap.mail.me.com")
    #expect(MailProvider.provider(forHost: host)?.note == "Use an app-specific password from account.apple.com.")
  }

  @Test func everyProviderHasNameAndHost() {
    for provider in MailProvider.all {
      #expect(!provider.name.isEmpty)
      #expect(!provider.host.isEmpty)
      #expect(provider.port == 993)
    }
  }

  @Test func pickerListsCustomDomainHostsOnly() {
    let hosts = MailCredentialRequest.hostedProviders.map(\.host)
    #expect(hosts.contains("posteo.de"))
    #expect(!hosts.contains("secureimap.t-online.de"))
    #expect(!hosts.contains("imap.mail.yahoo.com"))
    #expect(!hosts.contains("mx.freenet.de"))
  }
}
