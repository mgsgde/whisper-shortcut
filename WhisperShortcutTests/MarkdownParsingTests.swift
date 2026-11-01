import Testing
import Foundation
@testable import WhisperShortcut_AppStore

/// Pins `renderLatexToUnicode`: dollars and backslash commands are math only when they
/// look like math, and code is copied through. Each case below is a string the old
/// converter rewrote.
@Suite("Markdown parsing — LaTeX")
struct MarkdownParsingTests {

  @Test("Prices are not treated as inline math")
  func pricesStay() {
    #expect(MarkdownParsing.renderLatexToUnicode("costs $5 per month, or $50")
      == "costs $5 per month, or $50")
    // Digit immediately after the opening `$`, even when a closing `$` is present.
    #expect(MarkdownParsing.renderLatexToUnicode("$5$") == "$5$")
    #expect(MarkdownParsing.renderLatexToUnicode("$50") == "$50")
  }

  @Test("Whitespace just inside a dollar pair is not math")
  func whitespaceInsideDollarsStays() {
    #expect(MarkdownParsing.renderLatexToUnicode("$ x $") == "$ x $")
    #expect(MarkdownParsing.renderLatexToUnicode("$x $") == "$x $")
    #expect(MarkdownParsing.renderLatexToUnicode("$ x$") == "$ x$")
  }

  @Test("Dollars and commands inside backtick spans are left alone")
  func inlineCodeIsNotLatex() {
    #expect(MarkdownParsing.renderLatexToUnicode("`echo $HOME and $PATH`")
      == "`echo $HOME and $PATH`")
    // These would convert if the span were prose. The math after the span still does.
    #expect(MarkdownParsing.renderLatexToUnicode("`$x^2$` and $x^2$") == "`$x^2$` and x²")
    #expect(MarkdownParsing.renderLatexToUnicode(#"`\to` and \to"#) == "`\\to` and →")
  }

  @Test("Fenced code is not treated as LaTeX")
  func fencedCodeIsNotLatex() {
    let fenced = "```\n\\to\n$x^2$\nC:\\Users\\tom\\index.txt\n```"
    #expect(MarkdownParsing.renderLatexToUnicode(fenced) == fenced)
    let tilde = "~~~\n\\alpha\n~~~"
    #expect(MarkdownParsing.renderLatexToUnicode(tilde) == tilde)
    // Prose after the fence still converts.
    let mixed = fenced + "\n$x^2$"
    #expect(MarkdownParsing.renderLatexToUnicode(mixed) == fenced + "\nx²")
  }

  @Test("A Windows path is not rewritten as LaTeX commands")
  func windowsPathStays() {
    #expect(MarkdownParsing.renderLatexToUnicode(#"C:\Users\tom\index.txt"#)
      == #"C:\Users\tom\index.txt"#)
  }

  @Test("Real math still converts")
  func mathStillConverts() {
    #expect(MarkdownParsing.renderLatexToUnicode("$x^2$") == "x²")
    #expect(MarkdownParsing.renderLatexToUnicode(#"$\alpha \to \beta$"#) == "α → β")
    #expect(MarkdownParsing.renderLatexToUnicode("$$x^2$$") == "x²")
    #expect(MarkdownParsing.renderLatexToUnicode(#"$$\alpha \to \beta$$"#) == "α → β")
    #expect(MarkdownParsing.renderLatexToUnicode("$$\n\\alpha \\to \\beta\n$$") == "\nα → β\n")
    // Longer commands must win over prefixes (`\in` inside `\infty`, `\to` is not `\rightarrow`).
    #expect(MarkdownParsing.renderLatexToUnicode(#"$\infty$"#) == "∞")
    #expect(MarkdownParsing.renderLatexToUnicode(#"$\rightarrow$"#) == "→")
    #expect(MarkdownParsing.renderLatexToUnicode(#"$\frac{1}{2}$"#) == "1/2")
    #expect(MarkdownParsing.renderLatexToUnicode(#"$\lim_{x}$"#) == "limₓ")
  }
}
