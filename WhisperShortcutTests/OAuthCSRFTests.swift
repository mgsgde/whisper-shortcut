import Testing
import Foundation
@testable import WhisperShortcut_AppStore

@Suite("OAuth CSRF state")
struct OAuthCSRFTests {

  @Test("Matching state is accepted")
  func matchingStateAccepted() {
    #expect(OAuthCSRF.accept(expected: "abc", received: "abc", logPrefix: "TEST"))
  }

  @Test("Wrong or missing state is refused")
  func wrongStateRefused() {
    #expect(!OAuthCSRF.accept(expected: "abc", received: "xyz", logPrefix: "TEST"))
    #expect(!OAuthCSRF.accept(expected: "abc", received: nil, logPrefix: "TEST"))
    #expect(!OAuthCSRF.accept(expected: "abc", received: "", logPrefix: "TEST"))
  }

  @Test("Generated state is non-empty and unique")
  func generatedStateIsRandom() {
    let a = OAuthCSRF.makeState()
    let b = OAuthCSRF.makeState()
    #expect(!a.isEmpty)
    #expect(a != b)
  }
}
