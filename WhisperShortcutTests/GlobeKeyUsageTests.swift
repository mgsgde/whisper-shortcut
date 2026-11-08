import Testing

@testable import WhisperShortcut_AppStore

@Suite("Globe key usage")
struct GlobeKeyUsageTests {

  @Test("AppleFnUsageType 0-3 map to the documented cases; an undocumented or missing value is unknown, never Do Nothing", arguments: [
    (0 as Int?, GlobeKeyUsage.doNothing),
    (1, .changeInputSource),
    (2, .emojiAndSymbols),
    (3, .startDictation),
    (7, .unknown),
    (nil, .unknown),
  ])
  func usageFromRawValue(raw: Int?, expected: GlobeKeyUsage) {
    #expect(GlobeKeyUsage.usage(fromRawValue: raw) == expected, "raw \(String(describing: raw))")
  }

  @Test("Only a known system action counts as a conflict; Do Nothing and unknown do not")
  func conflicts() {
    #expect(!GlobeKeyUsage.doNothing.conflictsWithFnDictation)
    #expect(!GlobeKeyUsage.unknown.conflictsWithFnDictation)
    #expect(GlobeKeyUsage.changeInputSource.conflictsWithFnDictation)
    #expect(GlobeKeyUsage.emojiAndSymbols.conflictsWithFnDictation)
    #expect(GlobeKeyUsage.startDictation.conflictsWithFnDictation)
  }

  @Test("The Fn step blocks only while Fn is on and macOS still owns the 🌐 key")
  func fnSetupMayContinue() {
    let all: [GlobeKeyUsage] = [.doNothing, .changeInputSource, .emojiAndSymbols, .startDictation, .unknown]
    // Fn off: the shortcut is the trigger, the 🌐 setting does not matter.
    for usage in all {
      #expect(GlobeKeyUsage.fnSetupMayContinue(fnEnabled: false, usage: usage))
    }
    #expect(GlobeKeyUsage.fnSetupMayContinue(fnEnabled: true, usage: .doNothing))
    #expect(GlobeKeyUsage.fnSetupMayContinue(fnEnabled: true, usage: .unknown))
    #expect(!GlobeKeyUsage.fnSetupMayContinue(fnEnabled: true, usage: .emojiAndSymbols))
    #expect(!GlobeKeyUsage.fnSetupMayContinue(fnEnabled: true, usage: .changeInputSource))
    #expect(!GlobeKeyUsage.fnSetupMayContinue(fnEnabled: true, usage: .startDictation))
  }
}
