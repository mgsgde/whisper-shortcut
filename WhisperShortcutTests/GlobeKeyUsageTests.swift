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
