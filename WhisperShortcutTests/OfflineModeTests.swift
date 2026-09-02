import Foundation
import Testing

@testable import WhisperShortcut_AppStore

/// Offline Mode's promise is "nothing leaves this Mac", and the whole promise rests on one
/// host rule plus the switch that decides when it applies. Both are asserted here rather than
/// inferred from behaviour: a wrong answer from `isLocalHost` does not crash, it just quietly
/// sends a patient's dictation to a cloud API.
/// Every test here passes the mode in explicitly instead of switching it on process-wide: the same
/// test process makes live provider calls, and a global flip blocks those mid-run — observed as a
/// blocked Gemini request in an unrelated suite before this was cleaned up.
@Suite("Offline Mode")
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
    #expect(ContextLoggingPreference.isEnabled(offlineMode: false, storedFlag: true))
    #expect(!ContextLoggingPreference.isEnabled(offlineMode: true, storedFlag: true))
    // Offline Mode overrides the preference; it must not silently rewrite it, or turning the mode
    // off again would leave logging off with no explanation.
    #expect(!ContextLoggingPreference.isEnabled(offlineMode: false, storedFlag: false))
    #expect(!ContextLoggingPreference.isEnabled(offlineMode: true, storedFlag: false))
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

  /// Exactly one on-device model may wear the star, and both enums have to name the same one —
  /// they are rendered in two different pickers, and a disagreement means the app recommends two
  /// different models depending on where you look.
  @Test("One on-device model is recommended, and both enums agree on which")
  func recommendationIsSingleAndConsistent() {
    let recommendedTypes = OfflineModelType.allCases.filter(\.isRecommended)
    #expect(recommendedTypes == [.whisperLargeTurbo])

    let recommendedModels = TranscriptionModel.allCases.filter { $0.isOffline && $0.isRecommended }
    #expect(recommendedModels == [.whisperLargeTurbo])

    // The quick-start label is a separate slot, never a second recommendation.
    let quickStart = OfflineModelType.allCases.filter(\.isQuickStart)
    #expect(quickStart == [.whisperBase])
    #expect(!OfflineModelType.whisperBase.isRecommended)
  }

  /// Every on-device model must round-trip through both directions of the mapping, or Offline
  /// Mode's reconciler could select a `TranscriptionModel` that resolves to a different file.
  @Test("Offline model mapping round-trips in both directions")
  func offlineModelMappingRoundTrips() {
    for type in OfflineModelType.allCases {
      #expect(TranscriptionModel.forOfflineModel(type).offlineModelType == type, "\(type.rawValue)")
    }
  }

  // MARK: - URLProtocol guard

  @Test("canonicalRequest is the request unchanged")
  func canonicalRequestIsIdentity() {
    let request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
    #expect(OfflineModeURLProtocol.canonicalRequest(for: request) == request)
  }

  @Test("install prepends the guard in front of the system protocols")
  func installPrependsTheProtocol() throws {
    let configuration = URLSessionConfiguration.ephemeral
    let before = configuration.protocolClasses ?? []
    OfflineModeURLProtocol.install(on: configuration)
    let after = try #require(configuration.protocolClasses)
    #expect(after.count == before.count + 1)
    #expect(ObjectIdentifier(after[0]) == ObjectIdentifier(OfflineModeURLProtocol.self))
  }

  @Test("startLoading fails with cannotConnectToHost and the Offline Mode message")
  func startLoadingReportsTheBlockedError() throws {
    let url = URL(string: "https://api.openai.com/v1/models")!
    let request = URLRequest(url: url)
    let client = URLProtocolClientSpy()
    let proto = OfflineModeURLProtocol(request: request, cachedResponse: nil, client: client)
    proto.startLoading()

    let nsError = try #require(client.failedError as NSError?)
    #expect(nsError.domain == NSURLErrorDomain)
    #expect(nsError.code == NSURLErrorCannotConnectToHost)
    let message = nsError.localizedDescription
    #expect(message.contains("Offline Mode is on"))
    #expect(message.contains("api.openai.com"))
  }
}

/// Captures the transport error `OfflineModeURLProtocol.startLoading` delivers.
private final class URLProtocolClientSpy: NSObject, URLProtocolClient {
  var failedError: Error?

  func urlProtocol(_ `protocol`: URLProtocol, wasRedirectedTo request: URLRequest, redirectResponse: URLResponse) {}
  func urlProtocol(_ `protocol`: URLProtocol, cachedResponseIsValid cachedResponse: CachedURLResponse) {}
  func urlProtocol(_ `protocol`: URLProtocol, didReceive response: URLResponse, cacheStoragePolicy policy: URLCache.StoragePolicy) {}
  func urlProtocol(_ `protocol`: URLProtocol, didLoad data: Data) {}
  func urlProtocolDidFinishLoading(_ `protocol`: URLProtocol) {}
  func urlProtocol(_ `protocol`: URLProtocol, didFailWithError error: Error) { failedError = error }
  func urlProtocol(_ `protocol`: URLProtocol, didReceive challenge: URLAuthenticationChallenge) {}
  func urlProtocol(_ `protocol`: URLProtocol, didCancel challenge: URLAuthenticationChallenge) {}
}
