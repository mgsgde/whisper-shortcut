import Testing
@testable import WhisperShortcut_AppStore

@Suite("Speech activity gate")
struct SpeechActivityGateTests {

  @Test("No segments in an 11s clip is no speech")
  func noSegments() {
    expect(.noSpeech, SpeechActivityGate.decision(segments: [], duration: 11))
  }

  @Test("A single 0.2s segment is no speech")
  func tooLittleSpeech() {
    expect(
      .noSpeech,
      SpeechActivityGate.decision(segments: [(start: 0, end: 0.2)], duration: 11))
  }

  @Test("Speech from 0.5s to 9.0s in 11s trims the quiet ends")
  func trimsLongSilence() {
    expect(
      .trim(start: 0.1, end: 9.6),
      SpeechActivityGate.decision(segments: [(start: 0.5, end: 9.0)], duration: 11))
  }

  @Test("Speech from 0.3s to 10.8s in 11s stays whole")
  func keepsWhenLittleIsRemovable() {
    expect(
      .keep,
      SpeechActivityGate.decision(segments: [(start: 0.3, end: 10.8)], duration: 11))
  }

  @Test("Two segments use the first start and the last end")
  func trimsAroundTheOuterSegments() {
    expect(
      .trim(start: 0.6, end: 7.6),
      SpeechActivityGate.decision(
        segments: [(start: 1.0, end: 2.0), (start: 6.0, end: 7.0)], duration: 11))
  }

  private func expect(
    _ expected: SpeechActivityGate.Decision,
    _ decision: SpeechActivityGate.Decision,
    sourceLocation: SourceLocation = #_sourceLocation
  ) {
    switch (decision, expected) {
    case (.noSpeech, .noSpeech), (.keep, .keep):
      break
    case (.trim(let start, let end), .trim(let wantStart, let wantEnd)):
      #expect(abs(start - wantStart) < 0.001, sourceLocation: sourceLocation)
      #expect(abs(end - wantEnd) < 0.001, sourceLocation: sourceLocation)
    default:
      Issue.record("got \(decision), expected \(expected)", sourceLocation: sourceLocation)
    }
  }
}
