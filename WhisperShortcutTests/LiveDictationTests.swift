import AppKit
import Foundation
import HotKey
import Testing

@testable import WhisperShortcut_AppStore

/// Dictate Live (plans/active/live-dictate-insert.md), slice S1 and the session logic: who may use
/// it, how pieces are joined at the cursor, what is held back, and how the result is reported.
@Suite("Dictate Live")
struct LiveDictationTests {

  // MARK: - Availability

  @Test("Available with a downloaded Parakeet on Apple Silicon outside a meeting")
  func available() {
    #expect(
      LiveDictation.unavailableReason(
        model: .parakeetUltra, downloaded: true, appleSilicon: true, duringMeeting: false) == nil)
  }

  @Test("Each missing condition names its own reason")
  func reasons() {
    #expect(
      LiveDictation.unavailableReason(
        model: .parakeetUltra, downloaded: true, appleSilicon: true, duringMeeting: true) == .duringMeeting)
    #expect(
      LiveDictation.unavailableReason(
        model: .parakeetUltra, downloaded: true, appleSilicon: false, duringMeeting: false) == .intelMac)
    #expect(
      LiveDictation.unavailableReason(
        model: .parakeetUltra, downloaded: false, appleSilicon: true, duringMeeting: false) == .notDownloaded)
    for model in TranscriptionModel.allCases where model.offlineModelType?.engine != .parakeet {
      #expect(
        LiveDictation.unavailableReason(
          model: model, downloaded: true, appleSilicon: true, duringMeeting: false) == .notParakeet,
        "\(model.rawValue) must not offer Dictate Live")
    }
  }

  @Test("The shortcut ships disabled and is hidden in the App Store build")
  func shortcutDefaults() {
    #expect(!ShortcutConfig.default.liveDictate.isEnabled)
    var input = ShortcutConfig.default
    input.liveDictate = ShortcutDefinition(key: .five, modifiers: [.control, .option], isEnabled: true)
    #expect(!ShortcutConfig.availableInThisBuild(input, isAppStore: true).liveDictate.isEnabled)
    #expect(ShortcutConfig.availableInThisBuild(input, isAppStore: false).liveDictate.isEnabled)
  }

  // MARK: - Rotation policy

  @Test("Normal Dictate keeps its 10 s / 1 s cuts; Dictate Live cuts at 0.6 s pauses")
  func rotationPolicies() {
    #expect(ChunkedDictateRecorder.RotationPolicy.standard.minDuration == AppConstants.dictateChunkMinDuration)
    #expect(
      ChunkedDictateRecorder.RotationPolicy.standard.silenceDuration == AppConstants.dictateChunkSilenceDuration)
    #expect(ChunkedDictateRecorder.rotationSilenceSamplesNeeded(for: .standard) == 5)
    #expect(ChunkedDictateRecorder.rotationSilenceSamplesNeeded(for: .live) == 3)
    #expect(ChunkedDictateRecorder.RotationPolicy.live.minDuration == 1.5)
  }

  // MARK: - Punctuation mode

  @Test("Only when spoken: a spoken Punkt ends the piece with a period")
  func spokenOnlyPeriod() {
    #expect(LiveDictation.finishPiece("befund Punkt", mode: .spokenOnly).hasSuffix("."))
  }

  @Test("Only when spoken: the model's period is kept, its comma is stripped, automatic keeps both")
  func spokenOnlyKeepsModelPeriod() {
    #expect(LiveDictation.finishPiece("Der Befund ist unauffällig.", mode: .spokenOnly) == "Der Befund ist unauffällig.")
    #expect(LiveDictation.finishPiece("Gangbild, unauffällig.", mode: .spokenOnly) == "Gangbild unauffällig.")
    #expect(LiveDictation.finishPiece("Der Befund ist unauffällig.", mode: .automatic) == "Der Befund ist unauffällig.")
  }

  @Test("Only when spoken: the joiner holds a spoken final period like a model one")
  func spokenOnlyJoins() {
    var joiner = LiveChunkJoiner()
    #expect(joiner.next(LiveDictation.finishPiece("befund Punkt", mode: .spokenOnly)).hasPrefix("befund"))
    #expect(joiner.next(LiveDictation.finishPiece("Keine Auffälligkeiten", mode: .spokenOnly)) == ". Keine Auffälligkeiten")
  }

  @Test("Only when spoken: a spoken period is never held, even before a lowercase word")
  func spokenOnlyNeverHoldsPeriod() {
    var joiner = LiveChunkJoiner()
    joiner.holdsPeriods = false
    #expect(joiner.next("klagt.") == "klagt.")
    #expect(joiner.next("seit gestern") == " seit gestern")
    #expect(joiner.inserted == "klagt. seit gestern")
  }

  @Test("Only when spoken: a function word at the next piece start is lower-cased mid-sentence")
  func spokenOnlyLowercasesFunctionWordAtPieceStart() {
    var joiner = LiveChunkJoiner()
    joiner.holdsPeriods = false
    #expect(joiner.next("Sie klagt") == "Sie klagt")
    #expect(joiner.next("Über Schmerzen") == " über Schmerzen")
    #expect(joiner.inserted == "Sie klagt über Schmerzen")
  }

  @Test("Only when spoken: \"Diese\" at a piece boundary is lower-cased mid-sentence")
  func spokenOnlyLowercasesDiese() {
    var joiner = LiveChunkJoiner()
    joiner.holdsPeriods = false
    #expect(joiner.next("Ich habe das System") == "Ich habe das System")
    #expect(joiner.next("Diese Woche nicht genutzt.") == " diese Woche nicht genutzt.")
    #expect(joiner.inserted == "Ich habe das System diese Woche nicht genutzt.")
  }

  @Test("Only when spoken: a kept model period at the end of piece 1 lets piece 2 keep its capital")
  func spokenOnlyKeptModelPeriodThenCapital() {
    var joiner = LiveChunkJoiner()
    joiner.holdsPeriods = false
    #expect(joiner.next(LiveDictation.finishPiece("Die Patientin klagt.", mode: .spokenOnly)) == "Die Patientin klagt.")
    #expect(joiner.next(LiveDictation.finishPiece("Über Schmerzen", mode: .spokenOnly)) == " Über Schmerzen")
    #expect(joiner.inserted == "Die Patientin klagt. Über Schmerzen")
  }

  @Test("Only when spoken: a capital stays when the previous piece ended the sentence")
  func spokenOnlyKeepsCapitalAfterSentenceMark() {
    var joiner = LiveChunkJoiner()
    joiner.holdsPeriods = false
    #expect(joiner.next("Ende.") == "Ende.")
    #expect(joiner.next("Über Schmerzen") == " Über Schmerzen")
    #expect(joiner.inserted == "Ende. Über Schmerzen")
  }

  @Test("Standalone fillers are dropped; real words stay")
  func fillersDropped() {
    #expect(LiveDictation.finishPiece("Mm-hmm", mode: .automatic) == "")
    #expect(LiveDictation.finishPiece("Hmm, was ist das", mode: .automatic) == "was ist das")
    #expect(LiveDictation.finishPiece("Hmmm", mode: .automatic) == "")
    #expect(LiveDictation.finishPiece("Basistherapie ähm Punkt", mode: .spokenOnly) == "Basistherapie.")
    #expect(LiveDictation.finishPiece("Um zehn Uhr", mode: .automatic) == "Um zehn Uhr")
    #expect(
      LiveDictation.finishPiece("Ah stimmt, aha und achso oh", mode: .automatic)
        == "Ah stimmt, aha und achso oh")
  }

  @Test("With periods held, a capital at a piece start stays")
  func heldPeriodsKeepPieceStartCapital() {
    var joiner = LiveChunkJoiner()
    #expect(joiner.next("Sie klagt") == "Sie klagt")
    #expect(joiner.next("Über Schmerzen") == " Über Schmerzen")
    #expect(joiner.inserted == "Sie klagt Über Schmerzen")
  }

  // MARK: - Last insertion memory

  private let memoryNow = Date(timeIntervalSince1970: 1_000_000)
  private func memory(_ character: Character = "s", bundle: String = "com.app.a", age: TimeInterval = 5)
    -> LiveDictation.LastInsertion
  {
    LiveDictation.LastInsertion(character: character, bundleId: bundle, at: memoryNow.addingTimeInterval(-age))
  }

  @Test("Unknown caret, same app, fresh memory: the remembered character")
  func memorySeedsUnknown() {
    let seeded = LiveDictation.LastInsertion.seed(
      caret: .unknown, last: memory(), frontmostBundle: "com.app.a", now: memoryNow)
    #expect(seeded == .character("s"))
  }

  @Test("Unknown caret, other app / expired / no memory: stays unknown")
  func memoryIgnored() {
    #expect(
      LiveDictation.LastInsertion.seed(
        caret: .unknown, last: memory(), frontmostBundle: "com.app.b", now: memoryNow) == .unknown)
    #expect(
      LiveDictation.LastInsertion.seed(
        caret: .unknown, last: memory(age: 601), frontmostBundle: "com.app.a", now: memoryNow) == .unknown)
    #expect(
      LiveDictation.LastInsertion.seed(
        caret: .unknown, last: nil, frontmostBundle: "com.app.a", now: memoryNow) == .unknown)
    #expect(
      LiveDictation.LastInsertion.seed(
        caret: .unknown, last: memory(), frontmostBundle: nil, now: memoryNow) == .unknown)
  }

  @Test("A readable caret wins over the memory")
  func readableCaretWins() {
    #expect(
      LiveDictation.LastInsertion.seed(
        caret: .startOfText, last: memory(), frontmostBundle: "com.app.a", now: memoryNow) == .startOfText)
    #expect(
      LiveDictation.LastInsertion.seed(
        caret: .character("."), last: memory(), frontmostBundle: "com.app.a", now: memoryNow)
        == .character("."))
  }

  @Test("make keeps the last character, nothing for empty text or unknown target")
  func memoryMake() {
    #expect(LiveDictation.LastInsertion.make(insertedText: "… Dosis", bundleId: "x", now: memoryNow)?.character == "s")
    #expect(LiveDictation.LastInsertion.make(insertedText: "", bundleId: "x", now: memoryNow) == nil)
    #expect(LiveDictation.LastInsertion.make(insertedText: "a", bundleId: nil, now: memoryNow) == nil)
  }

  @Test("Seeded with the previous dictation's ending, the next piece is spaced and cased")
  func joinerAfterRememberedDictation() {
    var afterWord = LiveChunkJoiner()
    afterWord.seed(.character("s"))
    #expect(afterWord.next("Weiter geht's") == " Weiter geht's")

    var afterPeriod = LiveChunkJoiner()
    afterPeriod.seed(.character("."))
    afterPeriod.holdsPeriods = false
    #expect(afterPeriod.next("Weiter geht's") == " Weiter geht's")

    var spokenOnly = LiveChunkJoiner()
    spokenOnly.holdsPeriods = false
    spokenOnly.seed(.character("s"))
    #expect(spokenOnly.next("Und dann") == " und dann")
  }

  // MARK: - Joiner

  @Test("A seeded caret spaces the first piece and is not part of the inserted text")
  func seededCaret() {
    var afterLetter = LiveChunkJoiner()
    afterLetter.seed(.character("e"))
    #expect(afterLetter.next("Ah stimmt") == " Ah stimmt")
    #expect(afterLetter.inserted == " Ah stimmt")

    var afterSpace = LiveChunkJoiner()
    afterSpace.seed(.character(" "))
    #expect(afterSpace.next("Ah stimmt") == "Ah stimmt")

    var afterNewline = LiveChunkJoiner()
    afterNewline.seed(.character("\n"))
    #expect(afterNewline.next("Ah stimmt") == "Ah stimmt")

    var atStart = LiveChunkJoiner()
    atStart.seed(.startOfText)
    #expect(atStart.next("Ah stimmt") == "Ah stimmt")

    var unknown = LiveChunkJoiner()
    unknown.seed(.unknown)
    var today = LiveChunkJoiner()
    #expect(unknown.next("Der Patient") == today.next("Der Patient"))
    #expect(unknown.next("klagt über Schmerzen") == today.next("klagt über Schmerzen"))
    #expect(unknown.inserted == today.inserted)
  }

  @Test("Only when spoken: a seeded letter lower-cases a leading function word")
  func seededFunctionWord() {
    var joiner = LiveChunkJoiner()
    joiner.holdsPeriods = false
    joiner.seed(.character("g"))
    #expect(joiner.next("Und weiter") == " und weiter")
    #expect(joiner.inserted == " und weiter")
  }

  @Test("Pieces are joined with single spaces, none at the start")
  func spacing() {
    var joiner = LiveChunkJoiner()
    #expect(joiner.next("Der Patient") == "Der Patient")
    #expect(joiner.next("  klagt über Schmerzen ") == " klagt über Schmerzen")
    #expect(joiner.inserted == "Der Patient klagt über Schmerzen")
  }

  @Test("No space after or before a line break, none before closing punctuation")
  func lineBreaksAndPunctuation() {
    var joiner = LiveChunkJoiner()
    #expect(joiner.next("Befund:\n") == "Befund:\n")
    #expect(joiner.next("Knie rechts") == "Knie rechts")
    #expect(joiner.next("\n\nTherapie") == "\n\nTherapie")
    #expect(joiner.next(", Kühlung") == ", Kühlung")
  }

  @Test("A period at a breath is dropped when the sentence goes on in lowercase")
  func breathPeriodDropped() {
    var joiner = LiveChunkJoiner()
    #expect(joiner.next("Der Patient klagt über Schmerzen.") == "Der Patient klagt über Schmerzen")
    #expect(joiner.next("seit drei Tagen.") == " seit drei Tagen")
    #expect(joiner.finish() == ".")
    #expect(joiner.inserted == "Der Patient klagt über Schmerzen seit drei Tagen.")
  }

  @Test("A held period is kept when the next piece starts a new sentence")
  func periodKeptBeforeCapital() {
    var joiner = LiveChunkJoiner()
    #expect(joiner.next("Keine Schwellung.") == "Keine Schwellung")
    #expect(joiner.next("Röntgen unauffällig") == ". Röntgen unauffällig")
    #expect(joiner.finish() == "")
    #expect(joiner.inserted == "Keine Schwellung. Röntgen unauffällig")
  }

  @Test("Abbreviations, short words, numbers and ellipses keep their period at once")
  func periodsNotHeld() {
    #expect(!LiveChunkJoiner.holdsFinalPeriod("zum Beispiel z.B."))
    #expect(!LiveChunkJoiner.holdsFinalPeriod("bei Dr."))
    #expect(!LiveChunkJoiner.holdsFinalPeriod("ca."))
    #expect(!LiveChunkJoiner.holdsFinalPeriod("am 12."))
    #expect(!LiveChunkJoiner.holdsFinalPeriod("und dann..."))
    #expect(!LiveChunkJoiner.holdsFinalPeriod("Was nun?"))
    #expect(LiveChunkJoiner.holdsFinalPeriod("über Schmerzen."))
    #expect(LiveChunkJoiner.holdsFinalPeriod("Knie-Endoprothese."))
  }

  @Test("Empty pieces insert nothing and keep a held period")
  func emptyPieces() {
    var joiner = LiveChunkJoiner()
    #expect(joiner.next("   ") == "")
    #expect(joiner.next("Schmerzen.") == "Schmerzen")
    #expect(joiner.next("") == "")
    #expect(joiner.finish() == ".")
  }

  @Test("A spoken paragraph break at the very end of a piece is not lost")
  func trailingParagraphBreakSurvives() {
    var joiner = LiveChunkJoiner()
    let first = LiveDictation.finishPiece("Befund neuer Absatz", mode: .automatic)
    let second = LiveDictation.finishPiece("Inspektion unauffällig", mode: .automatic)
    #expect(joiner.next(first) == "Befund\n\n")
    #expect(joiner.next(second) == "Inspektion unauffällig")
    #expect(joiner.inserted == "Befund\n\nInspektion unauffällig")
  }

  @Test("A slash said across two pieces gets no space on either side")
  func slashAcrossPieces() {
    var afterSlash = LiveChunkJoiner()
    #expect(afterSlash.next("L4/") == "L4/")
    #expect(afterSlash.next("L5") == "L5")
    #expect(afterSlash.inserted == "L4/L5")

    var beforeSlash = LiveChunkJoiner()
    #expect(beforeSlash.next("L4") == "L4")
    #expect(beforeSlash.next("/L5") == "/L5")
    #expect(beforeSlash.inserted == "L4/L5")
  }

  @Test("No space after an opening parenthesis from \"Klammer auf\"")
  func noSpaceAfterOpeningParen() {
    #expect(LiveDictation.finishPiece("ist es Klammer auf", mode: .spokenOnly) == "ist es (")
    var joiner = LiveChunkJoiner()
    #expect(joiner.next("es (") == "es (")
    #expect(joiner.next("soweit ich kann)") == "soweit ich kann)")
    #expect(joiner.next("deutlich") == " deutlich")
    #expect(joiner.inserted == "es (soweit ich kann) deutlich")
  }

  @Test("A mark already ending the text is not repeated at the next piece, held or not")
  func duplicateMarkAcrossPieces() {
    // "gut" is shorter than five letters, so the period is not held in either mode.
    for holds in [false, true] {
      var period = LiveChunkJoiner()
      period.holdsPeriods = holds
      #expect(period.next("ganz gut.") == "ganz gut.")
      #expect(period.next(".") == "")
      #expect(period.inserted == "ganz gut.")

      var comma = LiveChunkJoiner()
      comma.holdsPeriods = holds
      #expect(comma.next("Hallo Herr Müller,") == "Hallo Herr Müller,")
      #expect(comma.next(", ganz lieben Dank") == " ganz lieben Dank")
      #expect(comma.inserted == "Hallo Herr Müller, ganz lieben Dank")
    }
    // A period that IS held is still emitted once when the next piece is only that mark.
    var held = LiveChunkJoiner()
    #expect(held.next("über Schmerzen.") == "über Schmerzen")
    #expect(held.next(".") == ".")
    #expect(held.inserted == "über Schmerzen.")
    #expect(held.finish() == "")

    var spoken = LiveChunkJoiner()
    spoken.holdsPeriods = false
    #expect(spoken.next("über Schmerzen.") == "über Schmerzen.")
    #expect(spoken.next(".") == "")
    #expect(spoken.inserted == "über Schmerzen.")
  }

  // MARK: - Drift

  @Test("Drift counts word edits, ignoring case and punctuation")
  func drift() {
    let same = LiveDictation.drift(inserted: "der patient klagt", wholeFile: "Der Patient klagt.")
    #expect(same.editDistance == 0)
    let changed = LiveDictation.drift(
      inserted: "Röntgen des rechten Knies", wholeFile: "Röntgen des rechten Kniegelenks in zwei Ebenen")
    #expect(changed.insertedWords == 4)
    #expect(changed.wholeFileWords == 7)
    #expect(changed.editDistance == 4)
  }

  // MARK: - Session

  @MainActor
  private final class Cursor {
    var texts: [String] = []
    var appInFront = true
    var document: String { texts.joined() }
  }

  private static func url(_ name: String) -> URL { URL(fileURLWithPath: "/tmp/\(name).wav") }

  @MainActor
  private static func session(
    _ cursor: Cursor, texts: [String: String], delaysMs: [String: UInt64] = [:], failing: Set<String> = []
  ) -> LiveDictationSession {
    LiveDictationSession(
      decode: { url in
        let name = url.deletingPathExtension().lastPathComponent
        if let delay = delaysMs[name] { try await Task.sleep(nanoseconds: delay * 1_000_000) }
        if failing.contains(name) { throw URLError(.cannotDecodeContentData) }
        return texts[name] ?? ""
      },
      insert: { text in
        guard cursor.appInFront else { return false }
        cursor.texts.append(text)
        return true
      })
  }

  @Test("Pieces reach the cursor in speaking order even when an earlier decode is slower")
  @MainActor
  func order() async throws {
    let cursor = Cursor()
    let s = Self.session(cursor, texts: ["a": "Erstens", "b": "zweitens"], delaysMs: ["a": 80])
    s.add(Self.url("a"), isSilent: false)
    s.add(Self.url("b"), isSilent: false)
    let outcome = try await s.finish(deliveredAudio: Self.url("merged"))
    #expect(cursor.document == "Erstens zweitens")
    #expect(outcome == .init(text: "Erstens zweitens", heldText: "", pieces: 2, failedPieces: 0))
  }

  @Test("Text is held while another app is in front and goes in when it is back")
  @MainActor
  func heldThenInserted() async throws {
    let cursor = Cursor()
    let s = Self.session(cursor, texts: ["a": "Befund", "b": "unauffällig"])
    cursor.appInFront = false
    s.add(Self.url("a"), isSilent: false)
    s.add(Self.url("b"), isSilent: false)
    await s.drain()  // both pieces decoded and refused; no timing assumption
    #expect(cursor.texts.isEmpty)
    cursor.appInFront = true
    s.retryHeld()
    let outcome = try await s.finish(deliveredAudio: Self.url("merged"))
    #expect(cursor.texts == ["Befund unauffällig"])
    #expect(outcome.heldText == "")
  }

  @Test("Text still held at Stop is handed back, never inserted elsewhere")
  @MainActor
  func heldAtStop() async throws {
    let cursor = Cursor()
    cursor.appInFront = false
    let s = Self.session(cursor, texts: ["a": "Diagnose Gonarthrose."])
    s.add(Self.url("a"), isSilent: false)
    let outcome = try await s.finish(deliveredAudio: Self.url("merged"))
    #expect(cursor.texts.isEmpty)
    #expect(outcome.heldText == "Diagnose Gonarthrose.")
    #expect(outcome.text == "Diagnose Gonarthrose.")
  }

  @Test("A recording that never rotated is decoded from the delivered file")
  @MainActor
  func shortDictation() async throws {
    let cursor = Cursor()
    let s = Self.session(cursor, texts: ["merged": "Kurzer Satz."])
    let outcome = try await s.finish(deliveredAudio: Self.url("merged"))
    #expect(cursor.document == "Kurzer Satz.")
    #expect(outcome.pieces == 1)
  }

  @Test("Silent pieces are skipped, and the delivered file is not decoded on top")
  @MainActor
  func silentPieces() async throws {
    let cursor = Cursor()
    let s = Self.session(cursor, texts: ["a": "Hallo", "merged": "Hallo doppelt"])
    s.add(Self.url("a"), isSilent: false)
    s.add(Self.url("tail"), isSilent: true)
    let outcome = try await s.finish(deliveredAudio: Self.url("merged"))
    #expect(cursor.document == "Hallo")
    #expect(outcome.pieces == 1)
  }

  @Test("A failed piece is counted, the others still go in")
  @MainActor
  func failedPiece() async throws {
    let cursor = Cursor()
    let s = Self.session(cursor, texts: ["a": "eins", "c": "drei"], failing: ["b"])
    for name in ["a", "b", "c"] { s.add(Self.url(name), isSilent: false) }
    let outcome = try await s.finish(deliveredAudio: Self.url("merged"))
    #expect(cursor.document == "eins drei")
    #expect(outcome.failedPieces == 1)
    #expect(outcome.pieces == 3)
  }

  @Test("After cancel nothing more is inserted and finish throws")
  @MainActor
  func cancel() async throws {
    let cursor = Cursor()
    let s = Self.session(cursor, texts: ["a": "eins", "b": "zwei"], delaysMs: ["a": 80])
    s.add(Self.url("a"), isSilent: false)
    s.add(Self.url("b"), isSilent: false)
    s.cancel()
    await #expect(throws: CancellationError.self) {
      _ = try await s.finish(deliveredAudio: Self.url("merged"))
    }
    #expect(cursor.texts.isEmpty)
  }

  // MARK: - Dictate mode

  @Test("Dictate mode defaults to normal Dictate")
  func dictateModeDefaultIsDictate() {
    #expect(SettingsDefaults.dictateMode == .dictate)
    #expect(SettingsData().dictateMode == .dictate)
  }

  @Test("Dictate mode raw values round-trip and reject unknown ones")
  func dictateModeRawValues() {
    for mode in DictateMode.allCases {
      #expect(DictateMode(rawValue: mode.rawValue) == mode)
    }
    #expect(DictateMode(rawValue: "bogus") == nil)
  }

  @Test("Start decision: Dictate never depends on availability")
  func decisionDictate() {
    let reasons: [LiveDictation.Unavailable?] = [nil, .duringMeeting, .intelMac, .notParakeet, .notDownloaded]
    for reason in reasons {
      #expect(LiveDictation.startDecision(mode: .dictate, unavailable: reason) == .startDictate)
    }
  }

  @Test("Start decision: Live starts when available and refuses with the reason otherwise")
  func decisionLive() {
    #expect(LiveDictation.startDecision(mode: .live, unavailable: nil) == .startLive)
    let reasons: [LiveDictation.Unavailable] = [.intelMac, .notParakeet, .notDownloaded]
    for reason in reasons {
      #expect(LiveDictation.startDecision(mode: .live, unavailable: reason) == .refuse(reason))
    }
  }

  @Test("Start decision: Live during a meeting starts a Dictate meeting segment instead of refusing")
  func decisionLiveDuringMeeting() {
    #expect(LiveDictation.startDecision(mode: .live, unavailable: .duringMeeting) == .startDictate)
  }
}
