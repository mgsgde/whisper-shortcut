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
