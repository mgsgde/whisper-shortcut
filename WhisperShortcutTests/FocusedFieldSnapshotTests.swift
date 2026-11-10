import Testing
@testable import WhisperShortcut_AppStore

@Suite("Focused field context")
struct FocusedFieldSnapshotTests {

  @Test("Clip keeps the text nearest the caret")
  func clipCutsAwayFromCaret() {
    let before = "START" + String(repeating: "x", count: FocusedFieldSnapshot.beforeLimit)
    let after = String(repeating: "y", count: FocusedFieldSnapshot.afterLimit) + "END"
    let clipped = FocusedFieldSnapshot.clip(before: before, after: after)
    #expect(clipped.before == String(repeating: "x", count: FocusedFieldSnapshot.beforeLimit))
    #expect(clipped.after == String(repeating: "y", count: FocusedFieldSnapshot.afterLimit))
    let short = FocusedFieldSnapshot.clip(before: "hi", after: "there")
    #expect(short.before == "hi")
    #expect(short.after == "there")
  }

  @Test("UTF-16 caret split stays on character boundaries")
  func caretSplit() {
    let middle = FocusedFieldSnapshot.splitAtCaret(text: "abcdef", utf16Location: 3)
    #expect(middle.before == "abc")
    #expect(middle.after == "def")

    let missing = FocusedFieldSnapshot.splitAtCaret(text: "abcdef", utf16Location: nil)
    #expect(missing.before == "abcdef")
    #expect(missing.after == "")

    let pastEnd = FocusedFieldSnapshot.splitAtCaret(text: "abcdef", utf16Location: 99)
    #expect(pastEnd.before == "abcdef")
    #expect(pastEnd.after == "")

    let negative = FocusedFieldSnapshot.splitAtCaret(text: "abcdef", utf16Location: -1)
    #expect(negative.before == "abcdef")
    #expect(negative.after == "")

    let emoji = "a😀b"
    let afterA = FocusedFieldSnapshot.splitAtCaret(text: emoji, utf16Location: 1)
    #expect(afterA.before == "a")
    #expect(afterA.after == "😀b")
    let afterEmoji = FocusedFieldSnapshot.splitAtCaret(text: emoji, utf16Location: 3)
    #expect(afterEmoji.before == "a😀")
    #expect(afterEmoji.after == "b")
    let midSurrogate = FocusedFieldSnapshot.splitAtCaret(text: emoji, utf16Location: 2)
    #expect(midSurrogate.before == emoji)
    #expect(midSurrogate.after == "")
  }

  @Test("Password-manager bundle ids are excluded")
  func excludedBundles() {
    for bundleID in FocusedFieldSnapshot.excludedBundleIDs {
      #expect(FocusedFieldSnapshot.isExcluded(bundleID: bundleID))
    }
    let alsoExcluded = [
      "com.dashlane.Dashlane",
      "me.proton.pass.electron",
      "com.markmcguill.strongbox.mac",
      "in.sinew.Enpass-Desktop",
      "com.hicknhacksoftware.MacPass",
    ]
    for bundleID in alsoExcluded {
      #expect(FocusedFieldSnapshot.excludedBundleIDs.contains(bundleID))
    }
    #expect(!FocusedFieldSnapshot.isExcluded(bundleID: "com.apple.Notes"))
    #expect(!FocusedFieldSnapshot.isExcluded(bundleID: nil))
  }

  @Test("A window image is only the fallback for a short or missing field")
  func windowImageBoundaries() {
    #expect(PromptScreenContextDecision.wantsWindowImage(
      isComposeTurn: true, field: nil, settingEnabled: true, modelAcceptsImages: true, isTemplate: false))
    #expect(PromptScreenContextDecision.wantsWindowImage(
      isComposeTurn: true, field: field(199), settingEnabled: true, modelAcceptsImages: true, isTemplate: false))
    #expect(!PromptScreenContextDecision.wantsWindowImage(
      isComposeTurn: true, field: field(200), settingEnabled: true, modelAcceptsImages: true, isTemplate: false))
    #expect(!PromptScreenContextDecision.wantsWindowImage(
      isComposeTurn: true, field: nil, settingEnabled: true, modelAcceptsImages: true, isTemplate: true))
    #expect(!PromptScreenContextDecision.wantsWindowImage(
      isComposeTurn: false, field: nil, settingEnabled: true, modelAcceptsImages: true, isTemplate: false))
    #expect(!PromptScreenContextDecision.wantsWindowImage(
      isComposeTurn: true, field: nil, settingEnabled: false, modelAcceptsImages: true, isTemplate: false))
    #expect(!PromptScreenContextDecision.wantsWindowImage(
      isComposeTurn: true, field: nil, settingEnabled: true, modelAcceptsImages: false, isTemplate: false))
  }

  @Test("The field block is compose-only and marks the caret")
  func fieldBlockText() {
    let notes = FocusedFieldSnapshot(appName: "Notes", textBeforeCaret: "Hello ", textAfterCaret: "world")
    #expect(PromptScreenContextDecision.fieldBlock(notes, isComposeTurn: true, isTemplate: false, fieldTextEnabled: true) ==
      "TEXT FIELD THE RESULT WILL BE INSERTED INTO (app: Notes). Context only: match its language, tone and names, and continue or answer it. Do not repeat it. [CURSOR] marks where the result goes:\nHello [CURSOR]world")
    let unnamed = FocusedFieldSnapshot(appName: nil, textBeforeCaret: "Hi", textAfterCaret: "")
    #expect(PromptScreenContextDecision.fieldBlock(unnamed, isComposeTurn: true, isTemplate: false, fieldTextEnabled: true)?.contains("(app: unknown)") == true)
    #expect(PromptScreenContextDecision.fieldBlock(notes, isComposeTurn: false, isTemplate: false, fieldTextEnabled: true) == nil)
    #expect(PromptScreenContextDecision.fieldBlock(nil, isComposeTurn: true, isTemplate: false, fieldTextEnabled: true) == nil)
    let empty = FocusedFieldSnapshot(appName: "Notes", textBeforeCaret: "", textAfterCaret: "")
    #expect(PromptScreenContextDecision.fieldBlock(empty, isComposeTurn: true, isTemplate: false, fieldTextEnabled: true) == nil)
  }

  @Test("A template turn with a long field gets no field block")
  func fieldBlockTemplate() {
    #expect(PromptScreenContextDecision.fieldBlock(field(500), isComposeTurn: true, isTemplate: true, fieldTextEnabled: true) == nil)
  }

  @Test("Field text is opt-in")
  func fieldTextOptIn() {
    let f = field(500)
    #expect(PromptScreenContextDecision.fieldBlock(f, isComposeTurn: true, isTemplate: false, fieldTextEnabled: false) == nil)
    let on = PromptScreenContextDecision.fieldBlock(f, isComposeTurn: true, isTemplate: false, fieldTextEnabled: true)
    #expect(on?.contains(f.textBeforeCaret) == true)
    #expect(on?.contains("[CURSOR]") == true)
    #expect(PromptScreenContextDecision.effectiveField(f, fieldTextEnabled: false) == nil)
    #expect(PromptScreenContextDecision.effectiveField(f, fieldTextEnabled: true)?.totalCount == f.totalCount)
  }

  @Test("With field text off, a long field does not suppress the window image")
  func longFieldIgnoredForImage() {
    let long = PromptScreenContextDecision.effectiveField(field(300), fieldTextEnabled: false)
    #expect(PromptScreenContextDecision.wantsWindowImage(
      isComposeTurn: true, field: long, settingEnabled: true, modelAcceptsImages: true, isTemplate: false))
    #expect(!PromptScreenContextDecision.wantsWindowImage(
      isComposeTurn: true, field: long, settingEnabled: false, modelAcceptsImages: true, isTemplate: false))
  }

  @Test("Screen context settings default to off")
  func screenContextDefaultsOff() {
    #expect(SettingsDefaults.promptSendsFocusedFieldText == false)
    #expect(SettingsDefaults.screenshotInPromptMode == false)
  }

  private func field(_ count: Int) -> FocusedFieldSnapshot {
    FocusedFieldSnapshot(appName: "Notes", textBeforeCaret: String(repeating: "a", count: count), textAfterCaret: "")
  }
}
