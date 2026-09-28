import Foundation
import Testing

@testable import WhisperShortcut_AppStore

@Suite("Writing Style")
struct WritingStyleTests {

  // MARK: - Cleaning sent mail

  @Test("German reply header and quoted text are cut")
  func cutsGermanReplyHeader() {
    let raw = """
      Hi Anna,

      passt, Donnerstag geht.

      Grüße Magnus

      Am Mo., 1. Sept. 2026 um 10:00 Uhr schrieb Anna Muster <anna@example.com>:
      > Geht Mittwoch oder Donnerstag?
      """
    #expect(WritingStyleImporter.cleanSentBody(raw) == "Hi Anna,\n\npasst, Donnerstag geht.\n\nGrüße Magnus")
  }

  @Test("English reply header wrapped over two lines is cut")
  func cutsWrappedEnglishReplyHeader() {
    let raw = "Sounds good, see you Thursday.\n\nOn Mon, Sep 1, 2026 at 10:00 AM Anna Muster <\nanna@example.com> wrote:\n> Wednesday or Thursday?"
    #expect(WritingStyleImporter.cleanSentBody(raw) == "Sounds good, see you Thursday.")
  }

  @Test("Signature delimiter, device footer and quote lines are dropped")
  func dropsSignatureAndQuotes() {
    let withSignature = "Thanks, I'll send it tomorrow.\n-- \nMagnus Gödde\nSome Street 1"
    #expect(WritingStyleImporter.cleanSentBody(withSignature) == "Thanks, I'll send it tomorrow.")

    let withFooter = "Klar, mache ich morgen früh.\n\nVon meinem iPhone gesendet"
    #expect(WritingStyleImporter.cleanSentBody(withFooter) == "Klar, mache ich morgen früh.")

    let withQuotes = "Yes, that works for me.\n> earlier line\n> another"
    #expect(WritingStyleImporter.cleanSentBody(withQuotes) == "Yes, that works for me.")
  }

  @Test("A sentence of the user's that starts with Am/On and has a digit is not a reply header")
  func userSentenceIsNotHeader() {
    let german = "Hi Anna,\nAm Donnerstag um 14 Uhr passt mir gut.\n\nViele Grüße\nMagnus\n\nAm Mi., 10. Sept. 2026 um 09:12 Uhr schrieb Anna Müller <anna@x.de>:\n> alt"
    #expect(WritingStyleImporter.cleanSentBody(german) == "Hi Anna,\nAm Donnerstag um 14 Uhr passt mir gut.\n\nViele Grüße\nMagnus")

    let english = "On Thursday at 3 works for me.\nThanks, Magnus\n\nOn Wed, Sep 10, 2026 at 9:12 AM Anna <a@x.de> wrote:\n> old"
    #expect(WritingStyleImporter.cleanSentBody(english) == "On Thursday at 3 works for me.\nThanks, Magnus")

    let noPunctuation = "Passt für mich.\nOn Monday 3pm\nOn Wed, Sep 10, 2026 at 9:12 AM Anna <a@x.de> wrote:\n> old"
    #expect(WritingStyleImporter.cleanSentBody(noPunctuation) == "Passt für mich.\nOn Monday 3pm")
  }

  @Test("Outlook header needs a second header field; separator line is cut")
  func outlookHeader() {
    let ownText = "Hi Anna,\ndas Treffen:\nVon: 10 Uhr\nBis: 12 Uhr\nGrüße Magnus"
    #expect(WritingStyleImporter.cleanSentBody(ownText) == ownText)

    let outlook = "Passt, danke dir.\n\nVon: Anna Müller <anna@x.de>\nGesendet: Mittwoch, 10. September 2026 09:12\nAn: Magnus\nBetreff: Termin"
    #expect(WritingStyleImporter.cleanSentBody(outlook) == "Passt, danke dir.")

    let separator = "Klingt gut, bis Freitag.\n\n________________________________\nFrom: Anna"
    #expect(WritingStyleImporter.cleanSentBody(separator) == "Klingt gut, bis Freitag.")
  }

  @Test("Numeric and named HTML entities are decoded")
  func entities() {
    #expect(WritingStyleImporter.decodeEntities("It&#8217;s 10&ndash;12 &amp; fine &#x2764;") == "It’s 10–12 & fine ❤")
    #expect(WritingStyleImporter.decodeEntities("&amp;lt;") == "&lt;")
  }

  @Test("Drafts are neither samples nor the incoming message")
  func draftsSkipped() {
    let thread: [[String: Any]] = [
      ["message_id": "a", "labels": ["INBOX"], "body": "Geht Mittwoch?", "internal_date_ms": "1000"],
      ["message_id": "d", "labels": ["DRAFT"], "body": "Ein sehr langer alter Entwurf, der nie gesendet wurde.", "internal_date_ms": "1500"],
      ["message_id": "b", "labels": ["SENT"], "body": "Mittwoch passt mir, bis dann.", "internal_date_ms": "2000"],
    ]
    let samples = WritingStyleImporter.samplesFromThread(thread, sentIDs: ["b", "d"])
    #expect(samples.map(\.id) == ["b"])
    #expect(samples.first?.incomingChars == "Geht Mittwoch?".count)
  }

  @Test("Repeated corporate signature is cut, the sign-off above it stays")
  func signatures() {
    let signature = "\n\nViele Grüße\nMagnus\n\nMagnus Gödde\nTel. +49 170 1234567\nwww.example.com"
    let samples = ["Passt, danke.", "Mache ich morgen.", "Klingt gut, bis dann."].map {
      sample($0 + signature)
    }
    let stripped = WritingStyleImporter.stripRepeatedSignatures(samples)
    #expect(stripped[0].text == "Passt, danke.\n\nViele Grüße\nMagnus\n\nMagnus Gödde")
    // Below the repeat threshold nothing is touched
    let two = WritingStyleImporter.stripRepeatedSignatures(Array(samples.prefix(2)))
    #expect(two[0].text == samples[0].text)
  }

  @Test("Too short and forwards are rejected")
  func rejectsShortAndForwards() {
    #expect(WritingStyleImporter.cleanSentBody("ok") == nil)
    #expect(WritingStyleImporter.isForward(subject: "WG: Rechnung"))
    #expect(WritingStyleImporter.isForward(subject: "Fwd: invoice"))
    #expect(!WritingStyleImporter.isForward(subject: "Re: invoice"))
  }

  @Test("HTML body becomes plain text")
  func htmlBody() {
    let raw = "<div dir=\"ltr\">Hi Anna,<br><br>passt &amp; danke.</div><div class=\"gmail_quote\">Am Mo. schrieb Anna:<blockquote>alt</blockquote></div>"
    #expect(WritingStyleImporter.cleanSentBody(raw) == "Hi Anna,\n\npasst & danke.")
  }

  @Test("Recipient is the first address, lowercased")
  func firstAddress() {
    #expect(WritingStyleImporter.firstAddress(in: "Anna Muster <Anna@Example.com>, bob@x.de") == "anna@example.com")
    #expect(WritingStyleImporter.firstAddress(in: nil) == nil)
  }

  @Test("Thread import pairs each sent message with the incoming one before it")
  func threadPairsIncomingLength() {
    let thread: [[String: Any]] = [
      ["message_id": "a", "labels": ["INBOX"], "body": "Geht Mittwoch oder Donnerstag?", "internal_date_ms": "1000"],
      ["message_id": "b", "labels": ["SENT"], "body": "Donnerstag passt mir gut, bis dann.", "internal_date_ms": "2000",
       "to": "Anna <anna@example.com>", "subject": "Re: Termin"],
    ]
    let samples = WritingStyleImporter.samplesFromThread(thread, sentIDs: ["b"])
    #expect(samples.count == 1)
    #expect(samples.first?.incomingChars == "Geht Mittwoch oder Donnerstag?".count)
    #expect(samples.first?.recipient == "anna@example.com")
  }

  // MARK: - Context

  @Test("Bundle ids map to writing contexts")
  func contextMapping() {
    #expect(WritingContextResolver.context(forBundleID: "com.apple.mail") == .email)
    #expect(WritingContextResolver.context(forBundleID: "net.whatsapp.WhatsApp") == .messenger)
    #expect(WritingContextResolver.context(forBundleID: "com.tinyspeck.slackmacgap") == .workChat)
    #expect(WritingContextResolver.context(forBundleID: "com.apple.Safari") == .defaultContext)
    #expect(WritingContextResolver.context(forBundleID: nil) == .defaultContext)
  }

  // MARK: - Store

  private func makeStore(enabled: Bool = true) -> WritingStyleStore {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("writing-style-tests-\(UUID().uuidString)")
    return WritingStyleStore(directory: dir, isEnabled: { enabled })
  }

  private func sample(_ text: String, context: WritingContext = .email, id: String = UUID().uuidString) -> WritingSample {
    WritingSample(id: id, context: context, source: "manual", recipient: nil,
                  sentAt: Date(), incomingChars: nil, text: text)
  }

  @Test("Profile sections are parsed by header")
  func profileSections() {
    let profile = "=== Email ===\nGreeting: \"Hi <name>,\"\n\n=== Messenger ===\nlowercase, no greeting\n=== Work Chat ===\n"
    #expect(WritingStyleStore.profileSection(in: profile, for: .email) == "Greeting: \"Hi <name>,\"")
    #expect(WritingStyleStore.profileSection(in: profile, for: .messenger) == "lowercase, no greeting")
    #expect(WritingStyleStore.profileSection(in: profile, for: .workChat) == "")
    #expect(WritingStyleStore.profileSection(in: profile, for: .defaultContext) == "")
  }

  @Test("Duplicates by id and by text are skipped")
  func dedupe() {
    let store = makeStore()
    defer { store.clearAll() }
    #expect(store.addSamples([sample("Passt, bis Donnerstag.", id: "1")]) == 1)
    #expect(store.addSamples([sample("Something else", id: "1"), sample("  passt, bis donnerstag. ")]) == 0)
    #expect(store.loadSamples().count == 1)
  }

  @Test("No block when disabled or nothing learned")
  func noBlock() {
    let disabled = makeStore(enabled: false)
    defer { disabled.clearAll() }
    disabled.addSamples([sample("Passt, bis Donnerstag.")])
    #expect(disabled.promptBlock(for: .email, incoming: nil, maxChars: 4_000) == nil)

    let empty = makeStore()
    #expect(empty.promptBlock(for: .email, incoming: nil, maxChars: 4_000) == nil)
  }

  @Test("Unlearned context falls back to the default context")
  func fallback() {
    let store = makeStore()
    defer { store.clearAll() }
    store.addSamples([sample("hey, klingt gut", context: .defaultContext)])
    let block = store.promptBlock(for: .messenger, incoming: nil, maxChars: 4_000)
    #expect(block?.text.contains("hey, klingt gut") == true)
    #expect(block?.context == .defaultContext)
    #expect(block?.exampleCount == 1)
  }

  @Test("Budget drops examples before the profile")
  func budget() {
    let profile = "Greeting: \"Hi <name>,\""
    let examples = (1...5).map { "Example message number \($0) " + String(repeating: "x", count: 300) }
    let full = WritingStyleStore.renderBlock(
      context: .email, profileSection: profile, targetWords: 40, examples: examples, maxChars: 10_000)
    #expect(full.text.contains("--- example 5 ---"))
    #expect(full.exampleCount == 5)

    let tight = WritingStyleStore.renderBlock(
      context: .email, profileSection: profile, targetWords: 40, examples: examples, maxChars: 1_300)
    #expect(tight.text.contains(profile))
    #expect(tight.text.contains("--- example 1 ---"))
    #expect(!tight.text.contains("--- example 5 ---"))
    #expect(tight.text.count <= 1_300)
    #expect(tight.exampleCount < 5)
  }

  @Test("Reply length follows the incoming text, clamped around the median")
  func targetWords() {
    let samples = (0..<5).map { _ in
      WritingSample(id: UUID().uuidString, context: .email, source: "gmail", recipient: nil,
                    sentAt: Date(), incomingChars: 200, text: String(repeating: "word ", count: 20))
    }
    // ratio ≈ 100/200 = 0.5; 40 incoming words → 20, inside [10, 40]
    let incoming = String(repeating: "word ", count: 40)
    #expect(WritingStyleStore.targetWords(samples: samples, incoming: incoming) == 20)
    // A huge incoming mail is clamped to twice the median
    let huge = String(repeating: "word ", count: 1_000)
    #expect(WritingStyleStore.targetWords(samples: samples, incoming: huge) == 40)
    #expect(WritingStyleStore.targetWords(samples: samples, incoming: nil) == 20)
  }
}
