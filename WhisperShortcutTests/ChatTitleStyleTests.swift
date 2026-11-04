import Testing
import Foundation
@testable import WhisperShortcut_AppStore

/// Date-based session titles (`ChatTitleStyle`).
///
/// The style is applied at display time, never baked into the stored title — that is what lets a
/// user switch back to first-message titles and get their old rows back. These tests pin the
/// formatting rules and the meeting date source, because both are easy to "fix" into something
/// that looks right in one case and wrong in another (a follow-up question re-dating an old
/// meeting, a locale turning the digits non-ASCII).
@Suite("Chat title style")
struct ChatTitleStyleTests {

  /// Fixed date so the expectation does not depend on when the suite runs. 10:36:49 local time is
  /// the same instant the meeting stem below encodes, so a stem-vs-`lastUpdated` mix-up shows up
  /// as a different day only when the two genuinely disagree.
  private static func date(_ y: Int, _ m: Int, _ d: Int, _ hh: Int = 10, _ mm: Int = 36, _ ss: Int = 49) -> Date {
    var c = DateComponents()
    c.year = y; c.month = m; c.day = d; c.hour = hh; c.minute = mm; c.second = ss
    return Calendar(identifier: .gregorian).date(from: c)!
  }

  // MARK: - Formatting

  @Test("First message keeps the topic and adds no date")
  func firstMessageIsUnchanged() {
    let title = ChatTitleStyle.title(
      topic: "why does the build fail", date: Self.date(2026, 11, 3), style: .firstMessage)
    #expect(title == "why does the build fail")
  }

  @Test("Date and topic prefixes the day")
  func dateTopicPrefixesDay() {
    let title = ChatTitleStyle.title(
      topic: "Vendor Negotiation", date: Self.date(2026, 11, 3), style: .dateTopic)
    #expect(title == "2026-11-03 Vendor Negotiation")
  }

  @Test("Date only drops the topic")
  func dateOnlyDropsTopic() {
    let title = ChatTitleStyle.title(
      topic: "Vendor Negotiation", date: Self.date(2026, 11, 3), style: .dateOnly)
    #expect(title == "2026-11-03")
  }

  /// `datedTitle` is what `displayTitle` calls for a date style, so it must never be nil — a
  /// meeting with no summary title yet still has to render a row.
  @Test("A date style always yields text, even with no topic")
  func datedTitleIsNeverEmpty() {
    let date = Self.date(2026, 11, 3)
    #expect(ChatTitleStyle.datedTitle(topic: nil, date: date, style: .dateOnly) == "2026-11-03")
    #expect(ChatTitleStyle.datedTitle(topic: nil, date: date, style: .dateTopic) == "2026-11-03")
    #expect(ChatTitleStyle.datedTitle(topic: "Topic", date: date, style: .dateOnly) == "2026-11-03")
  }

  /// A chat with no first message yet has no topic. `dateTopic` must still show something useful
  /// rather than a dangling separator, and `firstMessage` must stay nil so the caller can fall
  /// back to "New chat".
  @Test("A session with no title yet falls back to the bare date")
  func noTopicYet() {
    let date = Self.date(2026, 11, 3)
    #expect(ChatTitleStyle.title(topic: nil, date: date, style: .dateTopic) == "2026-11-03")
    #expect(ChatTitleStyle.title(topic: "", date: date, style: .dateTopic) == "2026-11-03")
    #expect(ChatTitleStyle.title(topic: nil, date: date, style: .dateOnly) == "2026-11-03")
    #expect(ChatTitleStyle.title(topic: nil, date: date, style: .firstMessage) == nil)
  }

  /// The digits must stay ASCII and the field order fixed regardless of the user's locale — the
  /// point of the style is that rows sort like the transcript filenames they mirror.
  @Test("The day string is always yyyy-MM-dd")
  func dayStringIsStable() {
    #expect(ChatTitleStyle.dayString(from: Self.date(2026, 1, 5)) == "2026-01-05")
    #expect(ChatTitleStyle.dayString(from: Self.date(2026, 12, 31)) == "2026-12-31")
  }

  // MARK: - Date source

  /// A meeting is dated by when it happened, not by when it was last read: asking a follow-up
  /// question about Tuesday's notes must not re-date them to Thursday.
  @Test("A meeting takes its date from the transcript stem")
  func meetingUsesStemDate() {
    let session = ChatSession(
      lastUpdated: Self.date(2026, 11, 5, 9, 0, 0),
      title: "🤝 Vendor Negotiation",
      isMeeting: true,
      meetingStem: "Meeting-2026-11-03-103649")
    #expect(ChatTitleStyle.date(for: session) == Self.date(2026, 11, 3))
    #expect(
      ChatTitleStyle.title(
        topic: "🤝 Vendor Negotiation", date: ChatTitleStyle.date(for: session), style: .dateTopic)
        == "2026-11-03 🤝 Vendor Negotiation")
  }

  @Test("A normal chat takes its date from lastUpdated")
  func chatUsesLastUpdated() {
    let session = ChatSession(lastUpdated: Self.date(2026, 11, 3), title: "Budget chat")
    #expect(ChatTitleStyle.date(for: session) == Self.date(2026, 11, 3))
  }

  /// An unparseable stem must not throw the row back to 1970 — fall through to `lastUpdated`.
  @Test("An unparseable meeting stem falls back to lastUpdated")
  func unparseableStemFallsBack() {
    let session = ChatSession(
      lastUpdated: Self.date(2026, 11, 3),
      isMeeting: true,
      meetingStem: "not-a-meeting-stem")
    #expect(ChatTitleStyle.date(for: session) == Self.date(2026, 11, 3))
  }

  // MARK: - Display

  /// The whole point of the meeting case: the date is known before the summary title exists, so a
  /// date style shows it immediately instead of the "Meeting" placeholder.
  @Test("A meeting without a summary title still shows its date")
  @MainActor
  func untitledMeetingShowsDate() {
    let session = ChatSession(
      lastUpdated: Self.date(2026, 11, 5),
      isMeeting: true,
      meetingStem: "Meeting-2026-11-03-103649")
    // The summary-title guard is untouched: this meeting still needs its title generated.
    #expect(ChatViewModel.meetingTitleNeedsGeneration(session))
    // …and it has no topic to show yet.
    #expect(ChatViewModel.derivedTopicTitle(for: session) == nil)
    // So the date style is what makes the row readable.
    #expect(
      ChatTitleStyle.title(
        topic: ChatViewModel.derivedTopicTitle(for: session),
        date: ChatTitleStyle.date(for: session),
        style: .dateOnly) == "2026-11-03")
  }

  /// A stale first-message fallback title on a meeting must not leak into a date row either — the
  /// summary title is still coming, and the fallback is the question the user happened to ask.
  @Test("A stale meeting fallback title is not shown as the topic")
  @MainActor
  func staleMeetingFallbackIsNotATopic() {
    let session = ChatSession(
      lastUpdated: Self.date(2026, 11, 3),
      messages: [ChatMessage(role: .user, content: "what did we decide about pricing")],
      title: "what did we decide about pricing",
      isMeeting: true,
      meetingStem: "Meeting-2026-11-03-103649")
    #expect(ChatViewModel.derivedTopicTitle(for: session) == nil)
  }

  @Test("A normal chat's first message becomes the topic")
  @MainActor
  func chatFirstMessageIsTopic() {
    let session = ChatSession(
      lastUpdated: Self.date(2026, 11, 3),
      messages: [ChatMessage(role: .user, content: "why does the build fail on CI")])
    #expect(ChatViewModel.derivedTopicTitle(for: session) == "why does the build fail on CI")
  }

  // MARK: - Project names

  /// The explicit form is the one signal trusted on a single mention — it is the user saying
  /// "this is the project", not a guess about capitalisation.
  @Test("An explicit Projekt/Project mention is used")
  func explicitProjectMention() {
    #expect(ChatTitleStyle.projectName(in: "Wir sprechen heute über das Projekt ParkDepot.") == "ParkDepot")
    #expect(ChatTitleStyle.projectName(in: "Let's review project Northwind tomorrow.") == "Northwind")
    #expect(ChatTitleStyle.projectName(in: "Projekt Neue Webseite: Status?") == "Neue Webseite")
  }

  /// A name the transcript keeps repeating is the next best signal. Two words minimum, because a
  /// single capitalised word is a person or a noun far more often than a project.
  @Test("A repeated multi-word name is used")
  func repeatedMultiWordName() {
    let text = """
      Park Depot hat den Vertrag unterschrieben. Die Migration zu Park Depot läuft seit März, \
      und Park Depot will im April live gehen.
      """
    #expect(ChatTitleStyle.projectName(in: text) == "Park Depot")
  }

  /// A CamelCase or all-caps token carries its own "this is a name" signal, so one word is enough —
  /// but it still has to be repeated.
  @Test("A repeated CamelCase or acronym token is used")
  func repeatedCamelOrAcronym() {
    #expect(ChatTitleStyle.projectName(in: "ParkDepot braucht mehr Zeit. ParkDepot liefert im Mai.") == "ParkDepot")
    #expect(ChatTitleStyle.projectName(in: "SAP ist down. SAP meldet sich nicht.") == "SAP")
  }

  /// The conservative half: nothing confident found means nil, and the caller falls back to a
  /// generated title. A wrong project name in a sidebar is worse than no project name.
  @Test("No project mentioned yields nil")
  func noProjectMentioned() {
    #expect(ChatTitleStyle.projectName(in: "") == nil)
    #expect(ChatTitleStyle.projectName(in: "   \n ") == nil)
    // Ordinary meeting talk: capitalised sentence openers and meeting vocabulary only.
    #expect(ChatTitleStyle.projectName(in: "Das Meeting war gut. Die Migration läuft. Wir sind zufrieden.") == nil)
    #expect(ChatTitleStyle.projectName(in: "Heute besprechen wir den Status und die nächsten Schritte.") == nil)
    // A single capitalised word is not enough, however often it appears.
    #expect(ChatTitleStyle.projectName(in: "Magnus sagt ja. Magnus hat recht. Magnus macht das.") == nil)
    // A one-off proper noun is not a project the meeting is about.
    #expect(ChatTitleStyle.projectName(in: "Wir treffen uns in Berlin und reden über den Plan.") == nil)
  }

  // MARK: - Project name in the date row

  /// The composed row the user actually reads: a project name takes the topic slot, so the date
  /// style shows `2026-11-03 Park Depot` rather than a generated title.
  @Test("A project name composes with the date in dateTopic")
  func projectComposesWithDate() {
    let date = Self.date(2026, 11, 3)
    let project = ChatTitleStyle.projectName(in: "Projekt ParkDepot: Stand der Migration")
    #expect(project == "ParkDepot")
    #expect(ChatTitleStyle.title(topic: project, date: date, style: .dateTopic) == "2026-11-03 ParkDepot")
    #expect(ChatTitleStyle.title(topic: project, date: date, style: .dateOnly) == "2026-11-03")
    #expect(ChatTitleStyle.title(topic: project, date: date, style: .firstMessage) == "ParkDepot")
  }

  /// The meeting case end to end, without a model: a transcript-derived title is what the row
  /// shows, and the date style puts the day in front of it.
  @Test("A meeting titled from its transcript shows date and title")
  @MainActor
  func transcriptTitledMeetingShowsDateAndTitle() {
    let session = ChatSession(
      lastUpdated: Self.date(2026, 11, 5),
      title: "🤝 Vendor Negotiation",
      isMeeting: true,
      meetingStem: "Meeting-2026-11-03-103649")
    #expect(!ChatViewModel.meetingTitleNeedsGeneration(session))
    #expect(ChatViewModel.derivedTopicTitle(for: session) == "🤝 Vendor Negotiation")
    #expect(
      ChatTitleStyle.title(
        topic: ChatViewModel.derivedTopicTitle(for: session),
        date: ChatTitleStyle.date(for: session),
        style: .dateTopic) == "2026-11-03 🤝 Vendor Negotiation")
  }

  /// The trigger threshold is a pure predicate, so it can be pinned without a meeting or a model.
  @Test("A meeting is only titled once the transcript says enough")
  @MainActor
  func transcriptThreshold() {
    #expect(!ChatViewModel.hasEnoughTextForMeetingTitle("Hallo, hört ihr mich?"))
    #expect(!ChatViewModel.hasEnoughTextForMeetingTitle(String(repeating: "a", count: 199)))
    #expect(ChatViewModel.hasEnoughTextForMeetingTitle(String(repeating: "a", count: 200)))
  }

  @Test("Trailing stop-words are stripped from an explicit project name")
  func trailingStopWordsStripped() {
    #expect(ChatTitleStyle.projectName(in: "Projekt ParkDepot Meeting Termin heute") == "ParkDepot")
    #expect(ChatTitleStyle.explicitProjectName(in: "Projekt ParkDepot Meeting Termin") == "ParkDepot")
  }

  @Test("explicitProjectName ignores names found only by repetition")
  func explicitOnly() {
    let text = "Wir sprechen über ParkDepot. ParkDepot ist wichtig."
    #expect(ChatTitleStyle.projectName(in: text) == "ParkDepot")
    #expect(ChatTitleStyle.explicitProjectName(in: text) == nil)
  }

  @Test("A generated title never replaces a user-renamed chat title")
  @MainActor
  func renamedTitleKept() {
    #expect(!ChatViewModel.mayApplyGeneratedTitle(current: "My rename", firstMessageFallback: "hello"))
    #expect(ChatViewModel.mayApplyGeneratedTitle(current: "hello", firstMessageFallback: "hello"))
  }
}
