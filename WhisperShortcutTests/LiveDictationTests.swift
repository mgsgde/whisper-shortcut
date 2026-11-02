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

  // MARK: - Joiner

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
}
