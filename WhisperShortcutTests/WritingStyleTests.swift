import Foundation
import Testing

@testable import WhisperShortcut_AppStore

@Suite("Writing Style")
struct WritingStyleTests {

  // MARK: - Profile due rule

  private struct DueCase: Sendable {
    let since: Int
    let total: Int
    let dismissed: Bool
    let isDue: Bool
    let label: String
  }

  @Test(
    "isProfileDue: offered once enough samples exist, and again after 20 new samples once dismissed",
    arguments: [
      DueCase(since: 0, total: 25, dismissed: false, isDue: true, label: "never offered with enough samples"),
      DueCase(since: 5, total: 25, dismissed: true, isDue: false, label: "dismissed with fewer than 20 new samples"),
      DueCase(since: 20, total: 40, dismissed: true, isDue: true, label: "dismissed with 20 new samples"),
    ])
  private func profileDue(_ c: DueCase) {
    #expect(
      WritingStyleAutoUpdater.isProfileDue(
        since: c.since, total: c.total, hasProfile: false, dismissed: c.dismissed,
        lastProposedAt: nil, now: Date()) == c.isDue,
      "\(c.label)")
  }

  @Test("isProfileDue: 14-day cooldown applies to updates only")
  private func profileDueCooldown() {
    let now = Date()
    let day: TimeInterval = 24 * 3600
    func due(since: Int, total: Int = 40, hasProfile: Bool = true, last: Date?) -> Bool {
      WritingStyleAutoUpdater.isProfileDue(
        since: since, total: total, hasProfile: hasProfile, dismissed: false,
        lastProposedAt: last, now: now)
    }
    #expect(due(since: 20, last: nil))
    #expect(!due(since: 25, last: now.addingTimeInterval(-13 * day)))
    #expect(due(since: 25, last: now.addingTimeInterval(-14 * day)))
    #expect(due(since: 0, total: 20, hasProfile: false, last: now.addingTimeInterval(-1 * day)))
    #expect(!due(since: 19, last: nil))
    #expect(!due(since: 19, last: now.addingTimeInterval(-30 * day)))
  }

  @Test("markProposed sets lastProposedAt and clearAll removes it")
  private func markProposedRoundTrip() {
    let store = makeStore()
    defer { store.clearAll() }
    #expect(store.lastProposedAt == nil)
    let stamp = Date(timeIntervalSince1970: 1_800_000_000)
    store.markProposed(now: stamp)
    #expect(store.lastProposedAt == stamp)
    store.clearAll()
    #expect(store.lastProposedAt == nil)
  }

  // MARK: - Cleaning sent mail

  private struct CleanCase: Sendable {
    let raw: String
    let expected: String
    let label: String
  }

  @Test(
    "cleanSentBody cuts reply headers, quotes, signature delimiters and device footers, and turns HTML into text",
    arguments: [
      CleanCase(
        raw: "Hi Anna,\n\npasst, Donnerstag geht.\n\nGrüße Magnus\n\nAm Mo., 1. Sept. 2026 um 10:00 Uhr schrieb Anna Muster <anna@example.com>:\n> Geht Mittwoch oder Donnerstag?",
        expected: "Hi Anna,\n\npasst, Donnerstag geht.\n\nGrüße Magnus",
        label: "German reply header and quoted text"),
      CleanCase(
        raw: "Sounds good, see you Thursday.\n\nOn Mon, Sep 1, 2026 at 10:00 AM Anna Muster <\nanna@example.com> wrote:\n> Wednesday or Thursday?",
        expected: "Sounds good, see you Thursday.",
        label: "English reply header wrapped over two lines"),
      CleanCase(
        raw: "Thanks, I'll send it tomorrow.\n-- \nMagnus Gödde\nSome Street 1",
        expected: "Thanks, I'll send it tomorrow.", label: "signature delimiter"),
      CleanCase(
        raw: "Klar, mache ich morgen früh.\n\nVon meinem iPhone gesendet",
        expected: "Klar, mache ich morgen früh.", label: "device footer"),
      CleanCase(
        raw: "Yes, that works for me.\n> earlier line\n> another",
        expected: "Yes, that works for me.", label: "quote lines"),
      CleanCase(
        raw: "<div dir=\"ltr\">Hi Anna,<br><br>passt &amp; danke.</div><div class=\"gmail_quote\">Am Mo. schrieb Anna:<blockquote>alt</blockquote></div>",
        expected: "Hi Anna,\n\npasst & danke.", label: "HTML body becomes plain text"),
    ])
  private func cleansSentBody(_ c: CleanCase) {
    #expect(WritingStyleImporter.cleanSentBody(c.raw) == c.expected, "\(c.label)")
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
    let defaults = UserDefaults(suiteName: "writing-style-tests-\(UUID().uuidString)")!
    return WritingStyleStore(directory: dir, isEnabled: { enabled }, defaults: defaults)
  }

  private func sample(_ text: String, context: WritingContext = .email, id: String = UUID().uuidString) -> WritingSample {
    WritingSample(id: id, context: context, source: "manual", recipient: nil,
                  sentAt: Date(), incomingChars: nil, text: text)
  }

  @Test("hasProfile is false with no file or headers only, true once a section has a line")
  func hasProfile() {
    let store = makeStore()
    defer { store.clearAll() }
    #expect(!store.hasProfile)
    store.saveProfile(WritingStyleStore.emptyProfile)
    #expect(!store.hasProfile)
    store.saveProfile("=== Email ===\nGreeting: \"Hi\"\n\n=== Messenger ===\n")
    #expect(store.hasProfile)
  }

  @Test("Saving and dismissing a profile write this store's defaults and reset its counter")
  func profileBookkeeping() {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("writing-style-tests-\(UUID().uuidString)")
    let defaults = UserDefaults(suiteName: "writing-style-tests-\(UUID().uuidString)")!
    let store = WritingStyleStore(directory: dir, isEnabled: { true }, defaults: defaults)
    defer { store.clearAll() }
    #expect(store.addSamples([sample("First message worth keeping.", id: "a")]) == 1)
    #expect(store.samplesSinceProfile == 1)
    store.markProfileDismissed(now: Date(timeIntervalSince1970: 10))
    #expect(
      (defaults.object(forKey: UserDefaultsKeys.writingStyleProfileDismissedAt) as? Date)?
        .timeIntervalSince1970 == 10)
    #expect(store.samplesSinceProfile == 0)
    let savedAt = Date(timeIntervalSince1970: 1_700_000_000)
    store.markProfileSaved(now: savedAt)
    #expect(store.profileUpdatedAt?.timeIntervalSince1970 == savedAt.timeIntervalSince1970)
    #expect(defaults.object(forKey: UserDefaultsKeys.writingStyleProfileDismissedAt) == nil)
    #expect(store.samplesSinceProfile == 0)
    #expect(store.addSamples([sample("Second message worth keeping.", id: "b")]) == 1)
    store.markProfileDismissed(now: Date(timeIntervalSince1970: 1_700_000_100))
    #expect(store.samplesSinceProfile == 0)
    #expect(store.profileUpdatedAt?.timeIntervalSince1970 == savedAt.timeIntervalSince1970)
    #expect(
      (defaults.object(forKey: UserDefaultsKeys.writingStyleProfileDismissedAt) as? Date)?
        .timeIntervalSince1970 == 1_700_000_100)
  }

  @Test("Profile sections are parsed by header")
  func profileSections() {
    let profile = "=== Email ===\nGreeting: \"Hi <name>,\"\n\n=== Messenger ===\nlowercase, no greeting\n=== Work Chat ===\n"
    #expect(WritingStyleStore.profileSection(in: profile, for: .email) == "Greeting: \"Hi <name>,\"")
    #expect(WritingStyleStore.profileSection(in: profile, for: .messenger) == "lowercase, no greeting")
    #expect(WritingStyleStore.profileSection(in: profile, for: .workChat) == "")
    #expect(WritingStyleStore.profileSection(in: profile, for: .defaultContext) == "")
  }

  @Test("Re-derive keeps hand-written sections of contexts without samples, and leaves unsampled ones empty")
  func mergeUnsampledSections() {
    let current = "=== Default ===\nhand-written\n\n=== Email ===\nold email\n"
    let merged = WritingStyleImporter.mergedProfile(
      derived: [.email: " new email \n", .defaultContext: "filler"],
      current: current, contextsWithSamples: [.email])
    #expect(WritingStyleStore.profileSection(in: merged, for: .defaultContext) == "hand-written")
    #expect(WritingStyleStore.profileSection(in: merged, for: .email) == "new email")

    // Without samples and without an existing section the section stays empty.
    let empty = WritingStyleImporter.mergedProfile(
      derived: [.messenger: "No examples."], current: "=== Email ===\nold\n", contextsWithSamples: [])
    #expect(WritingStyleStore.profileSection(in: empty, for: .messenger) == "")
    #expect(WritingStyleStore.profileSection(in: empty, for: .email) == "old")
  }

  private func profileText(_ bodies: [WritingContext: String]) -> String {
    WritingContext.allCases.map { context in
      "\(context.profileHeader)\n\(bodies[context] ?? "")\n"
    }.joined(separator: "\n")
  }

  private func operation(
    _ op: WritingStyleImporter.ProfileOperation.Op,
    context: WritingContext = .email,
    oldLine: String = "",
    newLine: String = "",
    evidence: [String]
  ) -> WritingStyleImporter.ProfileOperation {
    WritingStyleImporter.ProfileOperation(
      context: context, op: op, oldLine: oldLine, newLine: newLine, evidence: evidence)
  }

  @Test("applyRevision adds a line quoted from two samples and leaves other sections unchanged")
  func revisionAddsWithTwoSamples() {
    let current = profileText([
      .email: "Length: short",
      .messenger: "lowercase, no greeting",
      .defaultContext: "hand-written default",
    ])
    let samples = [
      sample("Hi Anna, Thursday works for me.", context: .email, id: "1"),
      sample("Hi Ben, Friday works for me.", context: .email, id: "2"),
    ]
    let op = operation(.add, newLine: "Greeting: \"Hi\"", evidence: ["THURSDAY   works", "friday works"])
    let result = WritingStyleImporter.applyRevision(current: current, operations: [op], samples: samples)
    #expect(result.applied == [op])
    #expect(WritingStyleStore.profileSection(in: result.profile, for: .email) == "Length: short\nGreeting: \"Hi\"")
    #expect(result.profile.contains("=== Messenger ===\nlowercase, no greeting\n"))
    #expect(result.profile.contains("=== Default ===\nhand-written default\n"))
    #expect(WritingStyleStore.profileSection(in: result.profile, for: .workChat) == "")
  }

  @Test("applyRevision drops an operation when a quote is not in any sample")
  func revisionDropsUnknownQuote() {
    let current = profileText([.email: "Length: short"])
    let samples = [
      sample("Hi Anna, Thursday works for me.", context: .email, id: "1"),
      sample("Hi Ben, Thursday works for me too.", context: .email, id: "2"),
    ]
    let op = operation(.add, newLine: "Greeting: \"Hi\"", evidence: ["Thursday works", "absolutely nowhere"])
    let result = WritingStyleImporter.applyRevision(current: current, operations: [op], samples: samples)
    #expect(result.applied.isEmpty)
    #expect(WritingStyleStore.profileSection(in: result.profile, for: .email) == "Length: short")
  }

  @Test("applyRevision drops quotes that are both found only in one sample")
  func revisionDropsSingleSample() {
    let current = profileText([.email: "Length: short"])
    let samples = [
      sample("Hi Anna, Thursday works and Friday works.", context: .email, id: "1"),
      sample("See you at the office tomorrow morning.", context: .email, id: "2"),
    ]
    let op = operation(.add, newLine: "Greeting: \"Hi\"", evidence: ["Thursday works", "Friday works"])
    let result = WritingStyleImporter.applyRevision(current: current, operations: [op], samples: samples)
    #expect(result.applied.isEmpty)
  }

  @Test("applyRevision drops a replace when the old line is not in the section")
  func revisionDropsUnknownLine() {
    let current = profileText([.email: "Greeting: \"Hi\""])
    let samples = [
      sample("Hi Anna, Thursday works for me.", context: .email, id: "1"),
      sample("Hi Ben, Friday works for me.", context: .email, id: "2"),
    ]
    let op = operation(
      .replace, oldLine: "Closing: bye", newLine: "Closing: \"Bis dann\"",
      evidence: ["Thursday works", "Friday works"])
    let result = WritingStyleImporter.applyRevision(current: current, operations: [op], samples: samples)
    #expect(result.applied.isEmpty)
    #expect(WritingStyleStore.profileSection(in: result.profile, for: .email) == "Greeting: \"Hi\"")
  }

  @Test("applyRevision replaces and removes an existing line")
  func revisionReplaceAndRemove() {
    let current = profileText([
      .email: "Greeting: \"Hi\"\n- Length: short\nEmoji: none",
      .messenger: "lowercase, no greeting",
    ])
    let samples = [
      sample("Hi Anna, Thursday works. I write about ten words.", context: .email, id: "1"),
      sample("Hi Ben, Friday works. I write about ten words.", context: .email, id: "2"),
    ]
    let replace = operation(
      .replace, oldLine: "Length: short", newLine: "Length: about ten words",
      evidence: ["Thursday works", "Friday works"])
    let remove = operation(
      .remove, oldLine: "- Emoji: none", evidence: ["about ten words", "Hi Anna"])
    let result = WritingStyleImporter.applyRevision(
      current: current, operations: [replace, remove], samples: samples)
    #expect(result.applied == [replace, remove])
    #expect(
      WritingStyleStore.profileSection(in: result.profile, for: .email)
        == "Greeting: \"Hi\"\nLength: about ten words")
    #expect(result.profile.contains("=== Messenger ===\nlowercase, no greeting\n"))
  }

  @Test("revisionRationale lists each applied change with quoted, truncated evidence")
  func revisionRationale() {
    let long = String(repeating: "w", count: 81)
    let clipped = String(repeating: "w", count: 80) + "…"
    let add = operation(.add, newLine: "Greeting: \"Hi\"", evidence: ["Thursday works", long])
    let changed = operation(
      .replace, oldLine: "Length: short", newLine: "Length: about ten words", evidence: ["ten words"])
    let removed = operation(.remove, oldLine: "Emoji: none", evidence: ["no emoji", "still none"])
    let text = WritingStyleImporter.revisionRationale(applied: [add, changed, removed])
    let header = String(localized: "\(3) changes, each backed by at least 2 of your messages.")
    let added = String(localized: "Added")
    let changedLabel = String(localized: "Changed")
    let removedLabel = String(localized: "Removed")
    let expected = """
    \(header)

    \(added): Greeting: "Hi"
      „Thursday works“, „\(clipped)“

    \(changedLabel): Length: about ten words
      „ten words“

    \(removedLabel): Emoji: none
      „no emoji“, „still none“
    """
    #expect(text == expected)

    let exact = String(repeating: "q", count: 80)
    let only = operation(.add, newLine: "Phrases: exact", evidence: [exact])
    let exactText = WritingStyleImporter.revisionRationale(applied: [only])
    #expect(exactText.contains("„\(exact)“"))
    #expect(!exactText.contains("…"))
  }

  @Test("applyRevision does not count quotes from another context")
  func revisionIgnoresOtherContext() {
    let current = profileText([
      .email: "Length: short",
      .messenger: "lowercase, no greeting",
    ])
    let samples = [
      sample("See you at the office tomorrow.", context: .email, id: "e"),
      sample("Hi Anna, Thursday works for me.", context: .messenger, id: "m1"),
      sample("Hi Ben, Friday works for me.", context: .messenger, id: "m2"),
    ]
    let op = operation(.add, newLine: "Greeting: \"Hi\"", evidence: ["Thursday works", "Friday works"])
    let result = WritingStyleImporter.applyRevision(current: current, operations: [op], samples: samples)
    #expect(result.applied.isEmpty)
    #expect(WritingStyleStore.profileSection(in: result.profile, for: .email) == "Length: short")
    #expect(result.profile.contains("=== Messenger ===\nlowercase, no greeting\n"))
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

  // MARK: - Auto-update bookkeeping

  @Test("Counter counts only samples actually added; reset and clearAll zero it")
  func sampleCounter() {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let defaults = UserDefaults(suiteName: UUID().uuidString)!
    let store = WritingStyleStore(directory: dir, isEnabled: { true }, defaults: defaults)
    func sample(_ id: String, _ text: String) -> WritingSample {
      WritingSample(id: id, context: .email, source: "manual", recipient: nil,
                    sentAt: Date(), incomingChars: nil, text: text)
    }
    #expect(store.addSamples([sample("a", "First message text"), sample("b", "Second message text")]) == 2)
    #expect(store.samplesSinceProfile == 2)
    #expect(store.addSamples([sample("a", "First message text"), sample("c", "Third message text")]) == 1)
    #expect(store.samplesSinceProfile == 3)
    store.resetSamplesSinceProfile()
    #expect(store.samplesSinceProfile == 0)
    store.addSamples([sample("d", "Fourth message text")])
    defaults.set(Date(), forKey: UserDefaultsKeys.writingStyleProfileUpdatedAt)
    #expect(store.profileUpdatedAt != nil)
    store.clearAll()
    #expect(store.samplesSinceProfile == 0)
    #expect(store.profileUpdatedAt == nil)
  }

  @Test("Dictated sample: too short is nil, normal is trimmed with source dictated")
  func dictatedSample() {
    #expect(WritingStyleStore.dictatedSample(text: " ok danke ", context: .messenger) == nil)
    let sample = WritingStyleStore.dictatedSample(
      text: "  Passt, Donnerstag um 10 Uhr geht bei mir.  \n", context: .messenger)
    #expect(sample?.source == "dictated")
    #expect(sample?.context == .messenger)
    #expect(sample?.text == "Passt, Donnerstag um 10 Uhr geht bei mir.")
  }
}
