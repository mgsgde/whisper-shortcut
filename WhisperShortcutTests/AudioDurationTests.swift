import Foundation
import Testing
@testable import WhisperShortcut_AppStore

/// Pins the two duration measurements that used to be copied at every call site.
/// They agree on a plain WAV; a missing file still throws (asset) or comes back nil
/// (the sync `SpeechService` wrapper, which catches the file reader's throw).
@Suite("Audio duration")
struct AudioDurationTests {

  private final class TestResourceAnchor {}

  private static var sampleAudioURL: URL {
    guard let url = Bundle(for: TestResourceAnchor.self)
      .url(forResource: "sample", withExtension: "wav") else {
      fatalError("sample.wav missing from test bundle resources")
    }
    return url
  }

  private static var missingAudioURL: URL {
    URL(fileURLWithPath: "/tmp/whisper-shortcut-missing-\(UUID().uuidString).wav")
  }

  @Test("AVURLAsset and AVAudioFile agree on the bundled WAV")
  func sampleWavDurationsAgree() async throws {
    let url = Self.sampleAudioURL
    let assetSeconds = try await AudioDuration.avURLAssetSeconds(url)
    let fileSeconds = try AudioDuration.avAudioFileSeconds(url)
    #expect(assetSeconds > 0)
    #expect(fileSeconds > 0)
    #expect(abs(assetSeconds - fileSeconds) < 0.01)
  }

  @Test("A missing file throws from both measurements")
  func missingFileThrows() async {
    let url = Self.missingAudioURL
    await #expect(throws: (any Error).self) {
      try await AudioDuration.avURLAssetSeconds(url)
    }
    #expect(throws: (any Error).self) {
      try AudioDuration.avAudioFileSeconds(url)
    }
  }

  @Test("SpeechService still reports nil when the sync read fails")
  func missingFileIsNilFromSpeechService() {
    #expect(SpeechService().getAudioDuration(url: Self.missingAudioURL) == nil)
  }
}
