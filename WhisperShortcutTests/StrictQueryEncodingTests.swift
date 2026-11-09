import Foundation
import Testing
@testable import WhisperShortcut_AppStore

@Suite("Strict query encoding")
struct StrictQueryEncodingTests {

  @Test("Plus in a due offset and in C++ is percent-encoded")
  func plusIsPercentEncoded() {
    var components = URLComponents(string: "https://example.com/search")!
    components.setQueryItemsStrictly([
      URLQueryItem(name: "due", value: "2026-11-10T09:00:00+01:00"),
      URLQueryItem(name: "name", value: "C++"),
    ])
    let encoded = components.percentEncodedQuery ?? ""
    #expect(encoded.contains("2026-11-10T09:00:00%2B01:00"))
    #expect(encoded.contains("name=C%2B%2B"))
    #expect(!encoded.contains("+"))
  }
}
