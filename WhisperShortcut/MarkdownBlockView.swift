import SwiftUI

// MARK: - Shared Markdown Parsing Utilities

struct ParsedTable {
  let headers: [String]
  let rows: [[String]]
}

/// Shared Markdown parsing functions used by both ModelReplyView (chat) and MarkdownBlockView (summary).
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

  /// Returns the font for a heading level, scaled relative to `baseSize` (chat = 16, summary = 14).
  static func fontForHeadingLevel(_ level: Int, baseSize: CGFloat = 16) -> Font {
    switch level {
    case 1: return .system(size: baseSize + 10, weight: .bold)
    case 2: return .system(size: baseSize + 6, weight: .bold)
    case 3: return .system(size: baseSize + 2, weight: .semibold)
    case 4: return .system(size: baseSize, weight: .semibold)
    case 5: return .system(size: baseSize - 1, weight: .semibold)
    case 6: return .system(size: baseSize - 2, weight: .semibold)
    default: return .system(size: baseSize, weight: .bold)
    }
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

  /// True if the paragraph has multiple lines and at least two lines contain a pipe (Markdown table).
  static func looksLikeMarkdownTable(_ trimmed: String) -> Bool {
    let lines = trimmed.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    guard lines.count >= 2 else { return false }
    let withPipe = lines.filter { $0.contains("|") }
    return withPipe.count >= 2
  }

  static func parseMarkdownTable(_ trimmed: String) -> ParsedTable? {
    let lines = trimmed.components(separatedBy: .newlines)
      .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    guard lines.count >= 2 else { return nil }
    var dataRows: [[String]] = []
    for line in lines {
      let cells = line
        .split(separator: "|", omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: .whitespaces) }
      var row: [String]
      if cells.first == "" && cells.last == "" && cells.count >= 2 {
        row = Array(cells.dropFirst().dropLast())
      } else {
        row = cells
      }
      let isSeparator = !row.isEmpty && row.allSatisfy { cell in
        let t = cell.trimmingCharacters(in: .whitespaces)
        return !t.isEmpty && t.allSatisfy { $0 == "-" || $0 == ":" }
      }
      if isSeparator { continue }
      dataRows.append(row)
    }
    guard dataRows.count >= 2 else { return nil }
    return ParsedTable(headers: dataRows[0], rows: Array(dataRows.dropFirst()))
  }

  /// Inserts blank lines so bold section headers and bullet lists are never collapsed
  /// into the preceding paragraph (a common Gemini output pattern).
  static func normalizeMarkdownParagraphBreaks(_ content: String) -> String {
    let lines = content.components(separatedBy: "\n")
    var result: [String] = []
    for (i, line) in lines.enumerated() {
      let trimmedLine = line.trimmingCharacters(in: .whitespaces)
      if i > 0,
         let last = result.last,
         !last.trimmingCharacters(in: .whitespaces).isEmpty {
        // Blank line before bold section headers
        if trimmedLine.hasPrefix("**") {
          result.append("")
        }
        // Blank line before a bullet list that follows non-bullet text
        else if parseBullet(trimmedLine) != nil,
                parseBullet(last.trimmingCharacters(in: .whitespaces)) == nil {
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
    return (try? AttributedString(markdown: content, options: opts)) ?? AttributedString(content)
  }

  // MARK: - LaTeX to Unicode

  /// Converts common LaTeX math notation to Unicode characters.
  /// Handles both inline `$...$` and display `$$...$$` delimiters.
  static func renderLatexToUnicode(_ text: String) -> String {
    // Quick check: skip processing if no LaTeX markers present
    guard text.contains("$") || text.contains("\\") else { return text }

    var result = text

    // Step 1: Strip display math delimiters $$...$$
    result = regexReplace(result, pattern: "\\$\\$(.+?)\\$\\$", template: "$1", options: .dotMatchesLineSeparators)

    // Step 2: Strip inline math delimiters $...$
    result = regexReplace(result, pattern: "(?<!\\$)\\$(?!\\$)(.+?)(?<!\\$)\\$(?!\\$)", template: "$1")

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

    // Step 4: Simple command → Unicode replacements
    let replacements: [(String, String)] = [
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
    for (latex, unicode) in replacements {
      result = result.replacingOccurrences(of: latex, with: unicode)
    }

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
    let colCount = headers.count
    Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
      GridRow {
        ForEach(0..<colCount, id: \.self) { col in
          Text(Self.parseCellText(headers[col], isHeader: true, fontSize: fontSize))
            .foregroundColor(GeminiChatTheme.primaryText)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      .background(GeminiChatTheme.controlBackground)

      Rectangle()
        .fill(GeminiChatTheme.primaryText.opacity(0.2))
        .frame(height: 1)

      ForEach(Array(rows.enumerated()), id: \.offset) { rowIdx, row in
        GridRow {
          ForEach(0..<colCount, id: \.self) { col in
            Text(Self.parseCellText(col < row.count ? row[col] : "", isHeader: false, fontSize: fontSize))
              .foregroundColor(GeminiChatTheme.primaryText)
              .padding(.horizontal, 10)
              .padding(.vertical, 8)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
        if rowIdx < rows.count - 1 {
          Rectangle()
            .fill(GeminiChatTheme.primaryText.opacity(0.08))
            .frame(height: 1)
        }
      }
    }
    .textSelection(.enabled)
    .clipShape(RoundedRectangle(cornerRadius: 8))
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .strokeBorder(GeminiChatTheme.primaryText.opacity(0.15), lineWidth: 1)
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
        attr.font = .system(size: fontSize, weight: baseWeight)
        result.append(attr)
      }
      remaining = remaining[boldStart.upperBound...]
      if let boldEnd = remaining.range(of: "**") {
        let boldText = String(remaining[remaining.startIndex..<boldEnd.lowerBound])
        var attr = AttributedString(boldText)
        attr.font = .system(size: fontSize, weight: .bold)
        result.append(attr)
        remaining = remaining[boldEnd.upperBound...]
      } else {
        var attr = AttributedString("**" + String(remaining))
        attr.font = .system(size: fontSize, weight: baseWeight)
        result.append(attr)
        remaining = remaining[remaining.endIndex...]
      }
    }
    if !remaining.isEmpty {
      var attr = AttributedString(String(remaining))
      attr.font = .system(size: fontSize, weight: baseWeight)
      result.append(attr)
    }
    return result.characters.isEmpty ? AttributedString(text) : result
  }
}

// MARK: - Block-Level Markdown View (for meeting summary and other non-chat contexts)

/// Renders Markdown text with proper block-level formatting: headings, bullet lists, tables, and paragraphs.
/// Uses the same parsing logic as the chat's ModelReplyView for consistency.
struct MarkdownBlockView: View {
  let text: String
  var baseSize: CGFloat = 14

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      ForEach(Array(parseBlocks().enumerated()), id: \.offset) { _, block in
        blockView(block)
      }
    }
    .textSelection(.enabled)
  }

  @ViewBuilder
  private func blockView(_ block: MarkdownBlock) -> some View {
    switch block {
    case .heading(let level, let content):
      inlineText(content)
        .font(MarkdownParsing.fontForHeadingLevel(level, baseSize: baseSize))
        .foregroundColor(GeminiChatTheme.primaryText)
        .padding(.top, level <= 1 ? 6 : 4)
        .padding(.bottom, 2)
    case .bullet(let content):
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Text("\u{2022}")
          .font(.system(size: baseSize))
          .foregroundColor(GeminiChatTheme.primaryText)
        inlineText(content)
          .font(.system(size: baseSize))
          .foregroundColor(GeminiChatTheme.primaryText)
      }
    case .paragraph(let content):
      inlineText(content)
        .font(.system(size: baseSize))
        .foregroundColor(GeminiChatTheme.primaryText)
        .padding(.vertical, 1)
    case .separator:
      Text(MarkdownParsing.separatorLineContent)
        .font(.system(size: baseSize))
        .foregroundColor(GeminiChatTheme.primaryText.opacity(0.4))
    case .table(let parsed):
      MarkdownTableView(headers: parsed.headers, rows: parsed.rows, fontSize: baseSize)
    case .codeBlock(let content):
      Text(content)
        .font(.system(size: baseSize - 1, design: .monospaced))
        .foregroundColor(GeminiChatTheme.primaryText)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GeminiChatTheme.controlBackground.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
  }

  private func inlineText(_ content: String) -> Text {
    Text(MarkdownParsing.inlineAttributedString(content))
  }

  // MARK: - Block Parsing

  private func parseBlocks() -> [MarkdownBlock] {
    let paragraphs = text.components(separatedBy: "\n\n")
    var blocks: [MarkdownBlock] = []

    for para in paragraphs {
      let trimmed = para.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.isEmpty { continue }

      if MarkdownParsing.isSeparatorParagraph(trimmed) {
        blocks.append(.separator)
        continue
      }

      if MarkdownParsing.looksLikeMarkdownTable(trimmed), let parsed = MarkdownParsing.parseMarkdownTable(trimmed) {
        blocks.append(.table(parsed))
        continue
      }

      if trimmed.hasPrefix("```") && trimmed.hasSuffix("```") {
        let code = String(trimmed.dropFirst(3).dropLast(3).trimmingCharacters(in: .whitespacesAndNewlines))
        blocks.append(.codeBlock(code))
        continue
      }

      let lines = trimmed.components(separatedBy: .newlines)
      for line in lines {
        let lineTrimmed = line.trimmingCharacters(in: .whitespaces)
        if lineTrimmed.isEmpty { continue }

        if let (level, title) = MarkdownParsing.parseATXHeading(lineTrimmed) {
          blocks.append(.heading(level: level, content: title))
        } else if let bulletContent = MarkdownParsing.parseBullet(lineTrimmed) {
          blocks.append(.bullet(content: bulletContent))
        } else {
          blocks.append(.paragraph(content: lineTrimmed))
        }
      }
    }
    return blocks
  }
}

private enum MarkdownBlock {
  case heading(level: Int, content: String)
  case bullet(content: String)
  case paragraph(content: String)
  case separator
  case table(ParsedTable)
  case codeBlock(String)
}
