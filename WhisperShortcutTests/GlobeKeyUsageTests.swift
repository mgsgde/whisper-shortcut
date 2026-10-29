import Testing

@testable import WhisperShortcut_AppStore

@Suite("Globe key usage")
struct GlobeKeyUsageTests {

  @Test("AppleFnUsageType 0, 1, 2 and 3 map to the documented cases")
  func documentedValues() {
    #expect(GlobeKeyUsage.usage(fromRawValue: 0) == .doNothing)
    #expect(GlobeKeyUsage.usage(fromRawValue: 1) == .changeInputSource)
    #expect(GlobeKeyUsage.usage(fromRawValue: 2) == .emojiAndSymbols)
    #expect(GlobeKeyUsage.usage(fromRawValue: 3) == .startDictation)
  }

  @Test("An undocumented or missing value is unknown, never Do Nothing")
  func unknownValues() {
    #expect(GlobeKeyUsage.usage(fromRawValue: 7) == .unknown)
    #expect(GlobeKeyUsage.usage(fromRawValue: nil) == .unknown)
  }

  @Test("Do Nothing has no System Settings label to change")
  func doNothingHasNoLabel() {
    #expect(GlobeKeyUsage.doNothing.systemSettingsLabel == nil)
  }
}
