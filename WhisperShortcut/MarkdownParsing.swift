import SwiftUI
import AppKit

// MARK: - Shared Markdown Parsing Utilities

struct ParsedTable {
  let headers: [String]
  let rows: [[String]]
}

/// Shared Markdown parsing functions used by ModelReplyView (chat).
enum MarkdownParsing {

  /// Returns (level 1...6, title text) if the string is an ATX-style heading; otherwise nil.
  static func parseATXHeading(_ trimmed: String) -> (level: Int, title: String)? {
    let prefixes = ["###### ", "##### ", "#### ", "### ", "## ", "# "]
    for (idx, prefix) in prefixes.enumerated() {
      if trimmed.hasPrefix(prefix) {
        let level = 6 - idx
        let firstLine = trimmed.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)[0]
        let title = String(firstLine.dropFirst(prefix.count))
        return (level, title)
      }
    }
    return nil
  }

  /// Single source of truth for heading sizes/weights; the SwiftUI and AppKit accessors
  /// below both derive from it so they can never drift apart.
  private static func headingMetrics(_ level: Int, baseSize: CGFloat) -> (size: CGFloat, bold: Bool) {
    switch level {
    case 1: return (baseSize + 7, true)
    case 2: return (baseSize + 4, true)
    case 3: return (baseSize + 2, false)
    case 4: return (baseSize, false)
    case 5: return (baseSize - 1, false)
    case 6: return (baseSize - 2, false)
    default: return (baseSize, true)
    }
  }

  /// Returns the font for a heading level, scaled relative to `baseSize` (chat = 16, summary = 14).
  /// Goes through `ChatTheme.bodyFont` so headings follow the typeface picked in Settings instead
  /// of staying San Francisco while the body prose turns serif.
  static func fontForHeadingLevel(_ level: Int, baseSize: CGFloat = 16) -> Font {
    let m = headingMetrics(level, baseSize: baseSize)
    return ChatTheme.bodyFont(size: m.size, weight: m.bold ? .bold : .semibold)
  }

  /// AppKit twin of `fontForHeadingLevel`, used when rendering prose in an `NSTextView`
  /// (where SwiftUI `Font` cannot be read back).
  static func nsHeadingMetrics(_ level: Int, baseSize: CGFloat = 16) -> (size: CGFloat, weight: NSFont.Weight) {
    let m = headingMetrics(level, baseSize: baseSize)
    return (m.size, m.bold ? .bold : .semibold)
  }

  /// Returns the bullet content if the line is a list item (`- `, `* `, or `1. `); otherwise nil.
  static func parseBullet(_ line: String) -> String? {
    if line.hasPrefix("- ") { return String(line.dropFirst(2)) }
    if line.hasPrefix("* ") { return String(line.dropFirst(2)) }
    if let dotIndex = line.firstIndex(of: "."),
       dotIndex > line.startIndex,
       line[line.startIndex..<dotIndex].allSatisfy(\.isNumber),
       line.index(after: dotIndex) < line.endIndex,
       line[line.index(after: dotIndex)] == " " {
      return String(line[line.index(dotIndex, offsetBy: 2)...])
    }
    return nil
  }

  /// A parsed list line: content without the marker, the number as written (ordered lists only),
  /// and the indentation in columns (a tab counts as 4).
  struct ParsedListLine: Equatable {
    let content: String
    let ordinal: Int?
    let indent: Int
  }

  /// Like `parseBullet`, but tolerates leading indentation and keeps the ordinal (R213).
  static func parseListLine(_ line: String) -> ParsedListLine? {
    var indent = 0
    var idx = line.startIndex
    while idx < line.endIndex, line[idx] == " " || line[idx] == "\t" {
      indent += line[idx] == "\t" ? 4 : 1
      idx = line.index(after: idx)
    }
    let rest = String(line[idx...])
    guard let content = parseBullet(rest) else { return nil }
    var ordinal: Int?
    if let first = rest.first, first.isNumber, let dot = rest.firstIndex(of: ".") {
      ordinal = Int(rest[rest.startIndex..<dot])
    }
    return ParsedListLine(content: content, ordinal: ordinal, indent: indent)
  }

  /// Maps raw indents of consecutive list items to nesting levels (0...3). An item nests one level
  /// deeper when it is indented at least 2 columns past the previous level's indent; dedenting
  /// returns to the matching (or nearest shallower) level.
  static func listLevels(forIndents indents: [Int]) -> [Int] {
    var stack: [Int] = []
    var levels: [Int] = []
    for indent in indents {
      while let top = stack.last, indent < top { stack.removeLast() }
      if let top = stack.last {
        if indent >= top + 2 { stack.append(indent) }
      } else {
        stack.append(indent)
      }
      levels.append(min(stack.count - 1, 3))
    }
    return levels
  }

  /// True if the paragraph is a horizontal-rule line, optionally with trailing citation markers.
  static func isSeparatorParagraph(_ trimmed: String) -> Bool {
    let t = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
    guard t.count >= 2, t.hasPrefix("--") else { return false }
    let afterDashes = t.drop(while: { $0 == "-" })
    let rest = String(afterDashes).trimmingCharacters(in: .whitespacesAndNewlines)
    if rest.isEmpty { return true }
    return rest.range(of: #"^(\s*\[\d+\])+\s*$"#, options: .regularExpression) != nil
  }

  static let separatorLineContent = String(repeating: "─", count: 28)

  /// GFM table delimiter row, e.g. `| --- | :---: |`.
  private static let tableDelimiterPattern = #"^\s*\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)*\|?\s*$"#

  static func isTableDelimiterRow(_ line: String) -> Bool {
    line.range(of: tableDelimiterPattern, options: .regularExpression) != nil
  }

  /// True if the paragraph is a GFM table: a header line containing a pipe followed by a
  /// delimiter row (R214). Two lines that merely contain "|" are prose, not a table.
  static func looksLikeMarkdownTable(_ trimmed: String) -> Bool {
    let lines = trimmed.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    guard lines.count >= 2 else { return false }
    return lines[0].contains("|") && isTableDelimiterRow(lines[1])
  }

  /// Splits one table row into trimmed cells; `\|` is a literal pipe, a leading/trailing
  /// border pipe yields no empty edge cell.
  static func splitTableRow(_ line: String) -> [String] {
    var cells: [String] = []
    var current = ""
    var chars = Array(line)
    var i = 0
    while i < chars.count {
      let c = chars[i]
      if c == "\\", i + 1 < chars.count, chars[i + 1] == "|" {
        current.append("|")
        i += 2
        continue
      }
      if c == "|" {
        cells.append(current)
        current = ""
      } else {
        current.append(c)
      }
      i += 1
    }
    cells.append(current)
    chars = []
    var trimmed = cells.map { $0.trimmingCharacters(in: .whitespaces) }
    if trimmed.count >= 2, trimmed.first == "", trimmed.last == "" {
      trimmed = Array(trimmed.dropFirst().dropLast())
    }
    return trimmed
  }

  static func parseMarkdownTable(_ trimmed: String) -> ParsedTable? {
    let lines = trimmed.components(separatedBy: .newlines)
      .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    guard lines.count >= 2, isTableDelimiterRow(lines[1]) else { return nil }
    var dataRows: [[String]] = []
    for (index, line) in lines.enumerated() where index != 1 {
      dataRows.append(splitTableRow(line))
    }
    guard dataRows.count >= 1 else { return nil }
    // Never drop cells beyond the header count: widen the header with empty cells instead.
    let width = dataRows.map(\.count).max() ?? 0
    var headers = dataRows[0]
    while headers.count < width { headers.append("") }
    return ParsedTable(headers: headers, rows: Array(dataRows.dropFirst()))
  }

  /// Inserts a paragraph break before — and a space after — a bold section header
  /// that a model glued directly onto surrounding text with no separator. Covers two
  /// label shapes:
  ///   A. `**Heading:**` — colon inside the bold span. Example:
  ///      `…frei befahrbar.**Die Sperrung …:**Die Vollsperrung…`
  ///   B. `**Heading** *(meta)*:` — colon after an italic parenthetical (the App Store-
  ///      style metadata shape, e.g. `**Untertitel** *(29 von 30 Zeichen)*:Diktieren…`).
  /// Both variants require `:` as the section-label signal so ordinary mid-sentence
  /// emphasis is left alone. Idempotent: only fires where the header touches a non-space
  /// char, so already-separated headers and re-runs are no-ops.
  static func splitInlineSectionHeadings(_ content: String) -> String {
    // No bold markers at all → there is no header to split; skip every pass.
    guard content.contains("**") else { return content }
    // Both variants get the same treatment — break the paragraph before a glued header
    // and add a space after it — so they share one loop over their header-span patterns.
    // Boundary classes exclude `*` so a bold-italic `***…:***` run is never split apart
    // (a bare `\S` would match its leading/trailing asterisk). Variant B keeps a distinct
    // after-class (`[^\s]`, not `[^\s*]`) so a header followed by inline emphasis still fires.
    let headerShapes: [(span: String, afterClass: String)] = [
      ("\\*\\*[^*\\n]+:\\*\\*", "[^\\s*]"),                      // A: `**Heading:**`
      ("\\*\\*[^*\\n]+\\*\\*\\s+\\*[^*\\n]+\\*\\s*:", "[^\\s]"), // B: `**Heading** *(meta)*:`
    ]
    var result = content
    for shape in headerShapes {
      result = regexReplace(result, pattern: "([^\\s*])(\(shape.span))", template: "$1\n\n$2")
      result = regexReplace(result, pattern: "(\(shape.span))(\(shape.afterClass))", template: "$1 $2")
    }
    return result
  }

  /// Inserts blank lines so bold section headers and bullet lists are never collapsed
  /// into the preceding paragraph (a common Gemini output pattern).
  static func normalizeMarkdownParagraphBreaks(_ content: String) -> String {
    // Split inline section headers first; the line-based pass below only catches
    // headers that already sit at a line start.
    let lines = splitInlineSectionHeadings(content).components(separatedBy: "\n")
    var result: [String] = []
    // True while the previous non-blank line is a list item or an indented continuation of one.
    var inListContext = false
    for (i, line) in lines.enumerated() {
      let trimmedLine = line.trimmingCharacters(in: .whitespaces)
      let isBullet = parseBullet(trimmedLine) != nil
      defer {
        if isBullet { inListContext = true }
        else if let f = line.first, f.isWhitespace, !trimmedLine.isEmpty, inListContext { /* continuation */ }
        else { inListContext = false }
      }
      if i > 0,
         let last = result.last,
         !last.trimmingCharacters(in: .whitespaces).isEmpty {
        // Blank line before bold section headers
        if trimmedLine.hasPrefix("**") {
          result.append("")
        }
        // Blank line before a bullet list that follows non-bullet text
        else if isBullet, !inListContext {
          result.append("")
        }
      }
      result.append(line)
    }
    return result.joined(separator: "\n")
  }

  /// Renders inline Markdown (bold, italic, code, links) within a single line as an `AttributedString`.
  static func inlineAttributedString(_ content: String, options: AttributedString.MarkdownParsingOptions? = nil) -> AttributedString {
    let opts = options ?? AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    // Convert LaTeX formulas to Unicode so every inline path (headings, bullets, body) benefits.
    // Idempotent: renderLatexToUnicode early-outs when no `$`/`\` markers are present.
    let processed = renderLatexToUnicode(content)
    return (try? AttributedString(markdown: processed, options: opts)) ?? AttributedString(processed)
  }

  // MARK: - LaTeX to Unicode

  /// Converts common LaTeX math notation to Unicode characters.
  /// Handles both inline `$...$` and display `$$...$$` delimiters.
  ///
  /// Inline dollars count as math only when the contents look like math (Pandoc's
  /// rule): no whitespace just inside either `$`, and no digit right after the
  /// closing `$`. `$2^n$` converts; `$5 per month, or $50`, `$5-$10` and `$ x $` stay
  /// literal. Fenced code and backtick spans are copied through unchanged, and a
  /// command name is replaced only when the next character is not a letter, so
  /// `\to` matches `\to` but not the `\tom` in `C:\Users\tom`.
  static func renderLatexToUnicode(_ text: String) -> String {
    // Quick check: skip processing if no LaTeX markers present
    guard text.contains("$") || text.contains("\\") else { return text }

    let (masked, tokens) = maskCodeRegions(text)
    let converted = (masked.contains("$") || masked.contains("\\")) ? convertLatexMarkup(masked) : masked
    return unmaskCodeRegions(converted, tokens: tokens)
  }

  /// LaTeX conversion for one prose span. Callers mask code regions first.
  private static func convertLatexMarkup(_ text: String) -> String {
    var result = text

    // Step 1: Strip display math delimiters $$...$$ (may span lines; whitespace inside is fine)
    result = regexReplace(result, pattern: "\\$\\$(.+?)\\$\\$", template: "$1", options: .dotMatchesLineSeparators)

    // Step 2: Strip inline math delimiters $...$ only when the contents look like math.
    // Pandoc's rule: no whitespace just inside either `$`, and no digit right after the
    // closing `$`. The pair cannot cross a newline. So `$2^n$` and `$1/2$` convert, while
    // `$5 per month, or $50`, `$5-$10` and `$HOME and $PATH` are not a pair.
    result = regexReplace(
      result,
      pattern: "(?<!\\$)\\$(?!\\$)(?!\\s)([^\\n$]*?[^\\s$])(?<!\\$)\\$(?!\\$)(?!\\d)",
      template: "$1")

    // Step 3: Structural commands FIRST (before simple replacements, so nested braces are intact)
    result = regexReplaceAll(result, pattern: "\\\\frac\\{([^}]+)\\}\\{([^}]+)\\}") { match, nsStr in
      let num = nsStr.substring(with: match.range(at: 1))
      let den = nsStr.substring(with: match.range(at: 2))
      return "\(num)/\(den)"
    }
    result = regexReplaceAll(result, pattern: "\\\\sqrt\\{([^}]+)\\}") { match, nsStr in
      "√\(nsStr.substring(with: match.range(at: 1)))"
    }
    result = regexReplaceAll(result, pattern: "\\\\mathbf\\{([^}]+)\\}") { match, nsStr in
      "**\(nsStr.substring(with: match.range(at: 1)))**"
    }
    result = regexReplaceAll(result, pattern: "\\\\text\\{([^}]+)\\}") { match, nsStr in
      nsStr.substring(with: match.range(at: 1))
    }
    result = regexReplaceAll(result, pattern: "\\\\mathrm\\{([^}]+)\\}") { match, nsStr in
      nsStr.substring(with: match.range(at: 1))
    }
    result = regexReplaceAll(result, pattern: "\\\\lim_\\{([^}]+)\\}") { match, nsStr in
      "lim_{\(nsStr.substring(with: match.range(at: 1)))}"
    }

    // Step 4: Simple command → Unicode replacements. Letter-named commands match
    // only at the end of the name (`\to` but not `\tom`, `\in` but not `\index`).
    // A regex `\b` would miss subscripts, because `_` counts as a word character.
    result = replaceLatexCommands(result)

    // Step 5: Superscripts ^{...} and ^x (AFTER structural commands)
    let superscriptMap: [Character: Character] = [
      "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴",
      "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
      "+": "⁺", "-": "⁻", "=": "⁼", "(": "⁽", ")": "⁾",
      "n": "ⁿ", "i": "ⁱ", "x": "ˣ",
    ]
    result = regexReplaceAll(result, pattern: "\\^\\{([^}]+)\\}") { match, nsStr in
      let content = nsStr.substring(with: match.range(at: 1))
      return String(content.map { superscriptMap[$0] ?? $0 })
    }
    result = regexReplaceAll(result, pattern: "\\^([0-9nix])") { match, nsStr in
      let ch = nsStr.substring(with: match.range(at: 1))
      if let c = ch.first, let sup = superscriptMap[c] { return String(sup) }
      return ch
    }

    // Step 6: Subscripts _{...} and _x
    let subscriptMap: [Character: Character] = [
      "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄",
      "5": "₅", "6": "₆", "7": "₇", "8": "₈", "9": "₉",
      "+": "₊", "-": "₋", "=": "₌", "(": "₍", ")": "₎",
      "a": "ₐ", "e": "ₑ", "i": "ᵢ", "o": "ₒ", "x": "ₓ",
    ]
    result = regexReplaceAll(result, pattern: "_\\{([^}]+)\\}") { match, nsStr in
      let content = nsStr.substring(with: match.range(at: 1))
      return String(content.map { subscriptMap[$0] ?? $0 })
    }

    return result
  }

  /// Command → Unicode pairs. Letter-named commands get an end-of-name check;
  /// the rest are literal (they already end on punctuation, so they cannot eat
  /// the following word).
  private static let latexReplacements: [(String, String)] = [
    ("\\times", "×"), ("\\div", "÷"), ("\\pm", "±"), ("\\mp", "∓"),
    ("\\cdot", "·"), ("\\ldots", "…"), ("\\dots", "…"),
    ("\\leq", "≤"), ("\\geq", "≥"), ("\\neq", "≠"), ("\\approx", "≈"),
    ("\\equiv", "≡"), ("\\sim", "∼"), ("\\propto", "∝"),
    ("\\infty", "∞"), ("\\partial", "∂"), ("\\nabla", "∇"),
    ("\\to", "→"), ("\\mapsto", "↦"),
    ("\\sum", "∑"), ("\\prod", "∏"), ("\\int", "∫"),
    ("\\lim", "lim"),
    ("\\log", "log"), ("\\ln", "ln"), ("\\sin", "sin"), ("\\cos", "cos"), ("\\tan", "tan"),
    ("\\min", "min"), ("\\max", "max"),
    ("\\alpha", "α"), ("\\beta", "β"), ("\\gamma", "γ"), ("\\delta", "δ"),
    ("\\epsilon", "ε"), ("\\varepsilon", "ε"), ("\\zeta", "ζ"), ("\\eta", "η"), ("\\theta", "θ"),
    ("\\lambda", "λ"), ("\\mu", "μ"), ("\\nu", "ν"), ("\\xi", "ξ"),
    ("\\pi", "π"), ("\\rho", "ρ"), ("\\sigma", "σ"), ("\\tau", "τ"),
    ("\\phi", "φ"), ("\\varphi", "φ"), ("\\chi", "χ"), ("\\psi", "ψ"), ("\\omega", "ω"),
    ("\\Alpha", "Α"), ("\\Beta", "Β"), ("\\Gamma", "Γ"), ("\\Delta", "Δ"),
    ("\\Theta", "Θ"), ("\\Lambda", "Λ"), ("\\Pi", "Π"), ("\\Sigma", "Σ"),
    ("\\Phi", "Φ"), ("\\Psi", "Ψ"), ("\\Omega", "Ω"),
    ("\\leftarrow", "←"), ("\\rightarrow", "→"), ("\\leftrightarrow", "↔"),
    ("\\Leftarrow", "⇐"), ("\\Rightarrow", "⇒"),
    ("\\forall", "∀"), ("\\exists", "∃"), ("\\in", "∈"), ("\\notin", "∉"),
    ("\\subset", "⊂"), ("\\supset", "⊃"), ("\\subseteq", "⊆"), ("\\supseteq", "⊇"),
    ("\\cup", "∪"), ("\\cap", "∩"),
    ("\\emptyset", "∅"), ("\\neg", "¬"), ("\\land", "∧"), ("\\lor", "∨"),
    ("\\quad", "  "), ("\\qquad", "    "), ("\\,", " "),
    ("\\left(", "("), ("\\right)", ")"),
    ("\\left[", "["), ("\\right]", "]"),
    ("\\left\\{", "{"), ("\\right\\}", "}"),
    ("\\{", "{"), ("\\}", "}"),
  ]

  /// Longer names first so `\infty` wins over `\in` when both could start at the same `\`.
  private static let letterCommandRegex: NSRegularExpression = {
    let pattern = latexReplacements
      .filter { $0.0.last?.isLetter == true }
      .sorted { $0.0.count > $1.0.count }
      .map { NSRegularExpression.escapedPattern(for: $0.0) + "(?![A-Za-z])" }
      .joined(separator: "|")
    return try! NSRegularExpression(pattern: pattern)
  }()

  private static let letterCommandMap: [String: String] = {
    Dictionary(uniqueKeysWithValues: latexReplacements.filter { $0.0.last?.isLetter == true })
  }()

  private static func replaceLatexCommands(_ text: String) -> String {
    var result = text
    let matches = letterCommandRegex.matches(
      in: result, range: NSRange(location: 0, length: (result as NSString).length))
    for match in matches.reversed() {
      let token = (result as NSString).substring(with: match.range)
      let replacement = letterCommandMap[token] ?? token
      result = (result as NSString).replacingCharacters(in: match.range, with: replacement)
    }
    for (latex, unicode) in latexReplacements where latex.last?.isLetter != true {
      result = result.replacingOccurrences(of: latex, with: unicode)
    }
    return result
  }

  private static let fencedRegex = try! NSRegularExpression(pattern: "```[^\\n]*\\n[\\s\\S]*?```")
  private static let tildeRegex = try! NSRegularExpression(pattern: "~~~[^\\n]*\\n[\\s\\S]*?~~~")
  private static let inlineCodeRegex = try! NSRegularExpression(pattern: "`[^`\\n]+`")

  /// Fenced ``` / ~~~ blocks, then single-backtick spans. Placeholders use private-use
  /// sentinels so the LaTeX pass cannot rewrite them; unclosed delimiters stay prose.
  private static func maskCodeRegions(_ text: String) -> (String, [String]) {
    var tokens: [String] = []
    var masked = captureRegions(text, regex: fencedRegex, into: &tokens)
    masked = captureRegions(masked, regex: tildeRegex, into: &tokens)
    masked = captureRegions(masked, regex: inlineCodeRegex, into: &tokens)
    return (masked, tokens)
  }

  private static func captureRegions(_ text: String, regex: NSRegularExpression, into tokens: inout [String]) -> String {
    let ns = text as NSString
    let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
    guard !matches.isEmpty else { return text }
    let base = tokens.count
    tokens.append(contentsOf: matches.map { ns.substring(with: $0.range) })
    var result = text
    for (offset, match) in matches.enumerated().reversed() {
      result = (result as NSString).replacingCharacters(in: match.range, with: codePlaceholder(base + offset))
    }
    return result
  }

  private static func unmaskCodeRegions(_ text: String, tokens: [String]) -> String {
    var result = text
    for index in tokens.indices.reversed() {
      result = result.replacingOccurrences(of: codePlaceholder(index), with: tokens[index])
    }
    return result
  }

  private static func codePlaceholder(_ index: Int) -> String {
    "\u{E000}L\(index)\u{E001}"
  }

  // MARK: - Regex Helpers

  private static func regexReplace(_ text: String, pattern: String, template: String, options: NSRegularExpression.Options = []) -> String {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return text }
    return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
  }

  private static func regexReplaceAll(_ text: String, pattern: String, replacer: (NSTextCheckingResult, NSString) -> String) -> String {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return text }
    var result = text
    let nsResult = result as NSString
    let matches = regex.matches(in: result, range: NSRange(location: 0, length: nsResult.length))
    for match in matches.reversed() {
      let replacement = replacer(match, result as NSString)
      result = (result as NSString).replacingCharacters(in: match.range, with: replacement)
    }
    return result
  }
}

// MARK: - Shared Markdown Table View

struct MarkdownTableView: View {
  let headers: [String]
  let rows: [[String]]
  var fontSize: CGFloat = 14

  var body: some View {
    let colCount = max(headers.count, rows.map(\.count).max() ?? 0)
    Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
      GridRow {
        ForEach(0..<colCount, id: \.self) { col in
          Text(Self.parseCellText(col < headers.count ? headers[col] : "", isHeader: true, fontSize: fontSize))
            .foregroundColor(ChatTheme.primaryText)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      .background(ChatTheme.controlBackground)

      Rectangle()
        .fill(ChatTheme.primaryText.opacity(0.2))
        .frame(height: 1)

      ForEach(Array(rows.enumerated()), id: \.offset) { rowIdx, row in
        GridRow {
          ForEach(0..<colCount, id: \.self) { col in
            Text(Self.parseCellText(col < row.count ? row[col] : "", isHeader: false, fontSize: fontSize))
              .foregroundColor(ChatTheme.primaryText)
              .padding(.horizontal, 10)
              .padding(.vertical, 8)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
        if rowIdx < rows.count - 1 {
          Rectangle()
            .fill(ChatTheme.primaryText.opacity(0.08))
            .frame(height: 1)
        }
      }
    }
    // DELIBERATELY not selectable: `.textSelection(.enabled)` on a container whose Texts carry
    // per-run mixed fonts (semibold headers / **bold** cells) installs macOS's `SelectionOverlay`,
    // which can loop in `_invalidateEffectiveFont` and wedge the main thread at 100% CPU — the
    // same bug documented on the chat prose path (see MessageBubbleView). The comment there
    // already promises "tables ... are simply not selectable"; this makes the code match it.
    .clipShape(RoundedRectangle(cornerRadius: 8))
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .strokeBorder(ChatTheme.primaryText.opacity(0.15), lineWidth: 1)
    )
  }

  private static func parseCellText(_ text: String, isHeader: Bool, fontSize: CGFloat) -> AttributedString {
    let baseWeight: Font.Weight = isHeader ? .semibold : .regular
    var result = AttributedString()
    var remaining = text[text.startIndex...]
    while let boldStart = remaining.range(of: "**") {
      let before = String(remaining[remaining.startIndex..<boldStart.lowerBound])
      if !before.isEmpty {
        var attr = AttributedString(before)
        attr.font = ChatTheme.bodyFont(size: fontSize, weight: baseWeight)
        result.append(attr)
      }
      remaining = remaining[boldStart.upperBound...]
      if let boldEnd = remaining.range(of: "**") {
        let boldText = String(remaining[remaining.startIndex..<boldEnd.lowerBound])
        var attr = AttributedString(boldText)
        attr.font = ChatTheme.bodyFont(size: fontSize, weight: .bold)
        result.append(attr)
        remaining = remaining[boldEnd.upperBound...]
      } else {
        var attr = AttributedString("**" + String(remaining))
        attr.font = ChatTheme.bodyFont(size: fontSize, weight: baseWeight)
        result.append(attr)
        remaining = remaining[remaining.endIndex...]
      }
    }
    if !remaining.isEmpty {
      var attr = AttributedString(String(remaining))
      attr.font = ChatTheme.bodyFont(size: fontSize, weight: baseWeight)
      result.append(attr)
    }
    return result.characters.isEmpty ? AttributedString(text) : result
  }
}

