import Foundation
import Testing

@testable import WhisperShortcut_AppStore

/// Offline Mode's promise is "nothing leaves this Mac", and the whole promise rests on one
/// host rule plus the switch that decides when it applies. Both are asserted here rather than
/// inferred from behaviour: a wrong answer from `isLocalHost` does not crash, it just quietly
/// sends a patient's dictation to a cloud API.
/// Serialized because one test flips the stored preference; the rest pass the mode in explicitly
/// rather than switching it on process-wide, which would otherwise block the live-provider suites
/// running concurrently in the same process.
@Suite("Offline Mode", .serialized)
struct OfflineModeTests {

  // MARK: - Host rule

  @Test("Loopback, link-local and RFC 1918 hosts stay allowed")
  func localHostsAreAllowed() {
    for host in [
      "localhost", "LOCALHOST", "localhost.", "app.localhost",
      "127.0.0.1", "127.1.2.3", "::1", "[::1]",
      "praxis-server.local", "Mac-mini.local",
      "10.0.0.5", "10.255.255.255",
      "192.168.1.10",
      "172.16.0.1", "172.31.255.254",
      "169.254.10.10",
    ] {
      #expect(OfflineMode.isLocalHost(host), "\(host) should count as local")
    }
  }

  @Test("Everything routable on the internet is blocked")
  func remoteHostsAreBlocked() {
    for host in [
      "generativelanguage.googleapis.com", "api.openai.com", "api.x.ai", "openrouter.ai",
      "8.8.8.8", "1.1.1.1",
      // 172.32 is outside the private range even though 172.16–31 is inside it.
      "172.32.0.1", "172.15.255.255",
      // Hostnames that merely *contain* a private-looking label are not private.
      "127.0.0.1.evil.com", "not-local", "10.0.0.5.example.com",
      "", "999.1.1.1", "10.0.0",
    ] {
      #expect(!OfflineMode.isLocalHost(host), "\(host) should not count as local")
    }
    #expect(!OfflineMode.isLocalHost(nil))
  }

  @Test("Only http(s) is judged by host; other schemes pass through")
  func nonHTTPSchemesArePassedThrough() {
    #expect(OfflineMode.allows(URL(string: "file:///tmp/audio.wav")))
    #expect(OfflineMode.allows(URL(string: "http://localhost:11434/v1/chat/completions")))
    #expect(OfflineMode.allows(URL(string: "https://192.168.1.20:8000/v1/audio/transcriptions")))
    #expect(!OfflineMode.allows(URL(string: "https://api.openai.com/v1/audio/transcriptions")))
    #expect(!OfflineMode.allows(nil))
  }

  // MARK: - The switch

  /// The guard must be inert while the mode is off — it sits in front of every session the app
  /// makes, so a decision that answered "block" unconditionally would take the whole app offline.
  @Test("The network guard only engages while the mode is on")
  func guardIsInertWhenModeIsOff() {
    let remote = URL(string: "https://api.openai.com/v1/models")
    let local = URL(string: "http://127.0.0.1:11434/v1/models")

    #expect(!OfflineMode.shouldBlock(remote, offlineMode: false))
    #expect(!OfflineMode.shouldBlock(local, offlineMode: false))

    #expect(OfflineMode.shouldBlock(remote, offlineMode: true))
    #expect(!OfflineMode.shouldBlock(local, offlineMode: true))

    // And the URLProtocol asks exactly that question, so the two cannot drift apart.
    #expect(
      OfflineModeURLProtocol.canInit(with: URLRequest(url: remote!))
        == OfflineMode.shouldBlock(remote, offlineMode: OfflineMode.isEnabled))
  }

  @Test("Dictation pickers offer on-device models only while the mode is on")
  func pickersNarrowToOnDeviceModels() {
    let offered = TranscriptionModel.selectableForDictation(offlineMode: true)
    #expect(!offered.isEmpty)
    for model in offered {
      #expect(model.runsOnThisMac, "\(model.rawValue) must not be offered in Offline Mode")
    }
    #expect(offered.contains(.whisperLargeTurbo))
    #expect(!offered.contains(.gemini31FlashLite))

    #expect(TranscriptionModel.selectableForDictation(offlineMode: false).contains(.gemini31FlashLite))
  }

  @Test("Usage data is never written to disk while the mode is on")
  func contextLoggingIsSuppressed() {
    let previousMode = OfflineMode.isEnabled
    let previousFlag = UserDefaults.standard.object(forKey: UserDefaultsKeys.contextLoggingEnabled)
    defer {
      OfflineMode.setEnabled(previousMode)
      UserDefaults.standard.set(previousFlag, forKey: UserDefaultsKeys.contextLoggingEnabled)
    }

    UserDefaults.standard.set(true, forKey: UserDefaultsKeys.contextLoggingEnabled)
    OfflineMode.setEnabled(false)
    #expect(ContextLoggingPreference.isEnabled)

    OfflineMode.setEnabled(true)
    // The user's own preference is untouched — it is overridden, not overwritten, so turning the
    // mode off again restores what they had chosen.
    #expect(!ContextLoggingPreference.isEnabled)
    #expect(ContextLoggingPreference.storedFlag)
  }

  // MARK: - The turbo model

  @Test("large-v3-turbo maps to the dated WhisperKit variant, not the v2-era one")
  func turboResolvesToTheRightVariant() {
    #expect(OfflineModelType.mostAccurate == .whisperLargeTurbo)
    #expect(OfflineModelType.whisperLargeTurbo.whisperKitModelName == "large-v3-v20240930_turbo")
    #expect(TranscriptionModel.whisperLargeTurbo.offlineModelType == .whisperLargeTurbo)
    #expect(TranscriptionModel.forOfflineModel(.whisperLargeTurbo) == .whisperLargeTurbo)
    #expect(TranscriptionModel.whisperLargeTurbo.provider == .offline)

    // `byAccuracy` drives the model Offline Mode picks; a case missing from it would be invisible
    // to that choice while still existing in the picker.
    #expect(Set(OfflineModelType.byAccuracy) == Set(OfflineModelType.allCases))
    #expect(OfflineModelType.byAccuracy.last == OfflineModelType.mostAccurate)
  }

  /// Every on-device model must round-trip through both directions of the mapping, or Offline
  /// Mode's reconciler could select a `TranscriptionModel` that resolves to a different file.
  @Test("Offline model mapping round-trips in both directions")
  func offlineModelMappingRoundTrips() {
    for type in OfflineModelType.allCases {
      #expect(TranscriptionModel.forOfflineModel(type).offlineModelType == type, "\(type.rawValue)")
    }
  }
}
