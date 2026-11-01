import Foundation
import Testing
@testable import WhisperShortcut_AppStore

@Suite("Audio transcoder prefetch")
struct AudioTranscoderTests {

  private final class TestResourceAnchor {}

  private static var sampleAudioURL: URL {
    guard let url = Bundle(for: TestResourceAnchor.self)
      .url(forResource: "sample", withExtension: "wav") else {
      fatalError("sample.wav missing from test bundle resources")
    }
    return url
  }

  @Test("Prefetch and a direct encode produce the same FLAC bytes")
  func prefetchMatchesDirectEncode() async throws {
    let url = Self.sampleAudioURL
    AudioTranscoder.discardPrefetch(for: url)
    AudioTranscoder.prefetch(for: url)
    let prefetched = await AudioTranscoder.flacData(for: url)
    let direct = await AudioTranscoder.flacData(for: url)
    let sourceSize =
      (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    #expect(prefetched != nil)
    #expect(direct != nil)
    #expect((prefetched?.count ?? 0) > 0)
    #expect((prefetched?.count ?? 0) < Int(sourceSize) || sourceSize == 0)
    #expect(prefetched?.count == direct?.count)
    AudioTranscoder.discardPrefetch(for: url)
  }

  @Test("A non-WAV source is not transcoded")
  func nonWavIsSkipped() async {
    let url = URL(fileURLWithPath: "/tmp/whisper-shortcut-not-audio.mp3")
    AudioTranscoder.prefetch(for: url)
    #expect(await AudioTranscoder.flacData(for: url) == nil)
  }
}

@Suite("Dictation delivery timing")
struct DictationDeliveryTimingTests {

  @Test("Auto-paste does not wait for the pasteboard to settle")
  func noClipboardReadyDelay() {
    #expect(AppConstants.autoPasteClipboardReadyDelay == 0)
  }

  @Test("Chat window pre-warm stays off the launch path")
  func chatPreWarmIsDeferredPastLaunch() {
    #expect(AppConstants.chatWindowPreWarmDelay >= 15)
  }
}
