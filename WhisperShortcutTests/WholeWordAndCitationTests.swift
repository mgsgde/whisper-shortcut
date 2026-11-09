import Foundation
import Testing
@testable import WhisperShortcut_AppStore

@Suite("Quick action classification (R217b)")
struct QuickActionClassifyTests {

  @Test("substrings inside other words do not classify")
  func noSubstringMatches() {
    #expect(QuickActionKind.classify("check the information") == .other)
    #expect(QuickActionKind.classify("keyboard shortcut") == .other)
    #expect(QuickActionKind.classify("make me comfortable") == .other)
    #expect(QuickActionKind.classify("open the tablet app") == .other)
  }

  @Test("real instructions still classify, including inflected stems")
  func realInstructions() {
    #expect(QuickActionKind.classify("mach es kürzer") == .shorten)
    #expect(QuickActionKind.classify("make it short") == .shorten)
    #expect(QuickActionKind.classify("format as bullets") == .format)
    #expect(QuickActionKind.classify("als tabelle") == .format)
    #expect(QuickActionKind.classify("put in a table") == .format)
    #expect(QuickActionKind.classify("korrigiere das") == .correct)
    #expect(QuickActionKind.classify("fix typos") == .correct)
    #expect(QuickActionKind.classify("übersetze ins englische") == .translate)
    #expect(QuickActionKind.classify("formuliere neu") == .rewrite)
    #expect(QuickActionKind.classify("to-do liste") == .format)
  }
}

@Suite("Citation stripping vs inline code (R217a)")
struct CitationInCodeTests {

  @Test("a [web:1] marker is stripped in prose")
  func strippedInProse() {
    let r = InlineCitationExtractor.extract(from: "A claim [web:1] here", knownSources: [])
    #expect(r.text == "A claim here")
  }

  @Test("a [web:1] marker inside an inline code span is kept")
  func keptInCode() {
    let r = InlineCitationExtractor.extract(from: "Grok emits `[web:1]` tokens", knownSources: [])
    #expect(r.text == "Grok emits `[web:1]` tokens")
  }

  @Test("prose marker removed while the code-span one stays")
  func mixed() {
    let r = InlineCitationExtractor.extract(from: "See `[web:2]` [web:3] now", knownSources: [])
    #expect(r.text == "See `[web:2]` now")
  }

  @Test("code span detection")
  func spans() {
    #expect(InlineCitationExtractor.inlineCodeSpans(in: "a `b` c").count == 1)
    #expect(InlineCitationExtractor.inlineCodeSpans(in: "a `b c").isEmpty)
    #expect(InlineCitationExtractor.inlineCodeSpans(in: "``a ` b`` c").count == 1)
  }
}
