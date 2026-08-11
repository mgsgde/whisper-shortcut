import AppKit
import Foundation
import SwiftUI

// Turns a model reply's markdown into render blocks. Split out of `ChatView.swift` because it is
// parsing, not view code — and because keeping it inside a private view made the one decision it
// exists to own untestable, which is how the two copies it replaced drifted apart in the first
// place. `ModelReplyView` consumes `buildBlocks` and does nothing else with markdown.

// MARK: - Paragraphs with citations at end

/// One paragraph with its character range and grounding chunk indices (for citations at end of paragraph).
struct ParagraphWithCitations {
  let text: String
  let chunkIndices: [Int]
}

enum ParagraphCitationBuilder {
  /// Splits content by "\n\n" and assigns to each paragraph all chunk indices from supports whose
  /// segment overlaps that paragraph. Citations are then rendered at the end of each paragraph.
  ///
  /// `offsets` translates paragraph positions back into the original content when `content` has
  /// already had fenced code blocks swapped for placeholders — supports index the original, so
  /// without the translation every citation after the first code block would land a paragraph off.
  static func buildParagraphs(
    content: String, supports: [GroundingSupport], sourcesCount: Int,
    offsets: OffsetMap = .identity
  ) -> [ParagraphWithCitations] {
    let parts = content.components(separatedBy: "\n\n")
    var paragraphs: [ParagraphWithCitations] = []
    var startOffset = 0
    for part in parts {
      let endOffset = startOffset + part.count
      let indices = chunkIndicesForRange(
        start: offsets.original(startOffset), end: offsets.original(endOffset),
        supports: supports, sourcesCount: sourcesCount)
      paragraphs.append(ParagraphWithCitations(text: part, chunkIndices: indices))
      startOffset = endOffset + 2
    }
    return paragraphs
  }

  private static func chunkIndicesForRange(start: Int, end: Int, supports: [GroundingSupport], sourcesCount: Int) -> [Int] {
    var set: Set<Int> = []
    for s in supports {
      guard s.startIndex < end, s.endIndex > start else { continue }
      for idx in s.groundingChunkIndices where idx >= 0 && idx < sourcesCount {
        set.insert(idx)
      }
    }
    return set.sorted()
  }
}
// MARK: - Markdown Table / Block types (shared via MarkdownParsing.swift)

enum ReplyContentBlock {
  case text(AttributedString)
  case bulletList([AttributedString]) // each item is one bullet
  case table(ParsedTable)
  case separator
  case codeBlock(String, String?) // code content, optional language
  case image(NSImage) // inline image (e.g. from Gemini image generation)
}

// MARK: - Code Block Extraction

/// Translates an offset in placeholder-substituted text back to the original content.
///
/// Grounding supports index into the raw model output, so any transform that changes the text's
/// length before paragraph splitting would silently misattribute citations. Carrying the shift
/// alongside the substitution is what lets the grounded and ungrounded paths run the *same*
/// extraction — previously only the ungrounded one could, so fenced code in a grounded reply
/// rendered as literal ``` text.
struct OffsetMap {
  /// One substitution: where the placeholder ends in processed space, and how many characters were
  /// removed at that point. Sorted by `processedEnd`.
  private let shifts: [(processedEnd: Int, delta: Int)]

  static let identity = OffsetMap(shifts: [])

  init(shifts: [(processedEnd: Int, delta: Int)]) { self.shifts = shifts }

  /// The original-content offset for `processed`. Offsets that land inside a placeholder map to the
  /// start of the text it replaced, which is all a paragraph-granular citation needs.
  func original(_ processed: Int) -> Int {
    var result = processed
    for shift in shifts {
      guard shift.processedEnd <= processed else { break }
      result += shift.delta
    }
    return result
  }
}

/// Extracts fenced code blocks from raw markdown BEFORE splitting by \n\n,
/// replacing them with placeholder tokens so they survive paragraph splitting.
struct CodeBlockExtractor {
  struct ExtractedCodeBlock {
    let code: String
    let language: String?
  }

  private static let placeholderPrefix = "⟦CODEBLOCK_"
  private static let placeholderSuffix = "⟧"

  /// Extracts all fenced code blocks, returning the placeholder-substituted text, the extracted
  /// blocks, and the map back to original offsets (see `OffsetMap`).
  static func extract(from content: String) -> (
    processed: String, blocks: [ExtractedCodeBlock], offsets: OffsetMap
  ) {
    var blocks: [ExtractedCodeBlock] = []
    var result = content
    // Match ```language\n...code...\n``` (multiline, non-greedy)
    let pattern = "```(\\w*)\\n([\\s\\S]*?)\\n```"
    guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
      return (content, [], .identity)
    }
    let nsContent = content as NSString
    let matches = regex.matches(in: content, range: NSRange(location: 0, length: nsContent.length))
    // Process matches in reverse order so replacement indices stay valid
    var placeholderLengths: [Int] = []
    var originalRanges: [(start: Int, length: Int)] = []
    for match in matches.reversed() {
      let langRange = match.range(at: 1)
      let codeRange = match.range(at: 2)
      let language = langRange.location != NSNotFound ? nsContent.substring(with: langRange) : nil
      let code = codeRange.location != NSNotFound ? nsContent.substring(with: codeRange) : ""
      let lang = (language?.isEmpty ?? true) ? nil : language
      let index = blocks.count
      blocks.insert(ExtractedCodeBlock(code: code, language: lang), at: 0)
      let placeholder = "\n\n\(placeholderPrefix)\(index)\(placeholderSuffix)\n\n"
      // Character (not UTF-16) units, to match the paragraph offsets in ParagraphCitationBuilder.
      placeholderLengths.insert(placeholder.count, at: 0)
      originalRanges.insert(
        (start: nsContent.substring(to: match.range.location).count,
         length: nsContent.substring(with: match.range).count),
        at: 0)
      result = (result as NSString).replacingCharacters(in: match.range, with: placeholder)
    }

    var shifts: [(processedEnd: Int, delta: Int)] = []
    var running = 0
    for (i, range) in originalRanges.enumerated() {
      let placeholderLength = placeholderLengths[i]
      let processedStart = range.start - running
      let delta = range.length - placeholderLength
      running += delta
      shifts.append((processedEnd: processedStart + placeholderLength, delta: running))
    }
    return (result, blocks, OffsetMap(shifts: shifts))
  }

  /// Checks if a trimmed paragraph is a code block placeholder and returns the index.
  static func placeholderIndex(_ trimmed: String) -> Int? {
    guard trimmed.hasPrefix(placeholderPrefix), trimmed.hasSuffix(placeholderSuffix) else { return nil }
    let inner = trimmed.dropFirst(placeholderPrefix.count).dropLast(placeholderSuffix.count)
    return Int(inner)
  }
}
/// Carries the intended AppKit font metrics (size + weight) for prose runs whose SwiftUI `.font`
/// would otherwise be lost when we render the prose in an `NSTextView` (SwiftUI `Font` does not
/// bridge to `NSFont`). Stamped on headings and the heading rule line; everything else falls back
/// to the 16-pt body font. A plain Hashable struct so it survives in the segment NSCache.
struct ProseFontMetrics: Hashable, Sendable {
  let size: CGFloat
  let weight: CGFloat
}

enum ProseFontHint: AttributedStringKey {
  typealias Value = ProseFontMetrics
  static let name = "chat.proseFontHint"
}
// MARK: - Reply block building

/// Markdown → `[ReplyContentBlock]`, for both grounded and ungrounded replies.
enum ReplyBlockBuilder {
  /// A citation marker like " [3]" as PLAIN text — deliberately NO `.link` and NO per-run
  /// font. An inline `.link` run (or a per-run font that differs from the body font) inside a
  /// `.textSelection(.enabled)` Text drives SwiftUI's macOS `SelectionOverlay` into a
  /// non-terminating `setFont:` / `_effectiveFontDidChangeTo:` loop (100% CPU hang). The
  /// clickable source still lives in `sourcesView`'s chip row, so nothing is lost.
  private static func citationMarker(_ oneBased: Int) -> AttributedString {
    AttributedString(" [\(oneBased)]")
  }

  /// Appends citation markers for every in-range chunk index. `sourcesCount` bounds the indices so
  /// we never reference a source that doesn't exist.
  private static func appendCitations(to attr: inout AttributedString, indices: [Int], sourcesCount: Int) {
    for idx in indices where idx < sourcesCount {
      attr.append(citationMarker(idx + 1))
    }
  }

  /// One paragraph's rendered blocks, plus which of them a grounded paragraph's citation markers
  /// attach to. The target is not always the last block — a "heading + bullets" paragraph cites on
  /// the heading — so it is carried explicitly rather than re-derived.
  struct ClassifiedParagraph {
    var blocks: [ReplyContentBlock]
    var citationTarget: Int?
  }

  /// Turns one trimmed paragraph into render blocks.
  ///
  /// **The single classifier for both the grounded and ungrounded paths.** It used to be written
  /// twice — once with citation threading, once without — and the copies drifted every time either
  /// gained a feature: the grounded copy rendered raw base64 for generated images until that was
  /// noticed, and it never learned about fenced code blocks at all, so a reply that came back with
  /// search sources showed ``` fences as literal text.
  static func classify(
    _ trimmed: String,
    codeBlocks: [CodeBlockExtractor.ExtractedCodeBlock],
    options: AttributedString.MarkdownParsingOptions
  ) -> ClassifiedParagraph {
    if let idx = CodeBlockExtractor.placeholderIndex(trimmed), idx < codeBlocks.count {
      let cb = codeBlocks[idx]
      if cb.language == "markdown" && Self.looksLikeStructuredAnswer(cb.code) {
        // A whole structured answer fenced as ```markdown — render it as the answer it is.
        return ClassifiedParagraph(
          blocks: buildBlocks(content: cb.code, sources: [], groundingSupports: []),
          citationTarget: nil)
      }
      return ClassifiedParagraph(blocks: [.codeBlock(cb.code, cb.language)], citationTarget: nil)
    }

    if let pieces = Self.splitImageMarkerPieces(trimmed) {
      // Generated image(s). Citations attach to the last text piece; an image-only paragraph
      // drops them.
      var blocks: [ReplyContentBlock] = []
      var target: Int?
      for piece in pieces {
        switch piece {
        case .image(let image):
          blocks.append(.image(image))
        case .text(let text):
          guard !GeminiAPIClient.isGeneratedImagePlaceholder(text) else { continue }
          target = blocks.count
          blocks.append(.text(buildSingleParagraphAttributed(text, options: options)))
        }
      }
      return ClassifiedParagraph(blocks: blocks, citationTarget: target)
    }

    if MarkdownParsing.isSeparatorParagraph(trimmed) {
      return ClassifiedParagraph(blocks: [.separator], citationTarget: nil)
    }

    if MarkdownParsing.looksLikeMarkdownTable(trimmed),
       let parsed = MarkdownParsing.parseMarkdownTable(trimmed) {
      return ClassifiedParagraph(blocks: [.table(parsed)], citationTarget: nil)
    }

    if let bulletItems = parseBulletItems(trimmed) {
      DebugLogger.log("BLOCKS: bulletList with \(bulletItems.count) items")
      return ClassifiedParagraph(blocks: [.bulletList(bulletItems)], citationTarget: 0)
    }

    if let (headingPart, bulletPart) = splitHeadingAndBullets(trimmed) {
      DebugLogger.log("BLOCKS: split heading+bullets")
      var blocks: [ReplyContentBlock] = [
        .text(buildSingleParagraphAttributed(headingPart, options: options))
      ]
      if let items = parseBulletItems(bulletPart) {
        blocks.append(.bulletList(items))
      } else {
        DebugLogger.log("BLOCKS: bullet part failed parse: \(bulletPart.prefix(80))")
        blocks.append(.text(buildSingleParagraphAttributed(bulletPart, options: options)))
      }
      // Heading gets the citations, bullets render separately.
      return ClassifiedParagraph(blocks: blocks, citationTarget: 0)
    }

    // A model may glue several `**…:**` sections into one \n\n-paragraph with no separators. Split
    // them here (after citation offsets are already resolved, so alignment is unaffected) and
    // attach the paragraph's citations to the last part.
    DebugLogger.log("BLOCKS: text block: \(trimmed.prefix(80))")
    let subParts = MarkdownParsing.splitInlineSectionHeadings(trimmed)
      .components(separatedBy: "\n\n")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    let blocks = subParts.map {
      ReplyContentBlock.text(buildSingleParagraphAttributed($0, options: options))
    }
    return ClassifiedParagraph(blocks: blocks, citationTarget: blocks.isEmpty ? nil : blocks.count - 1)
  }

  /// Stamps a grounded paragraph's citation markers onto its designated block.
  static func applyCitations(
    to classified: inout ClassifiedParagraph, indices: [Int], sourcesCount: Int
  ) {
    guard !indices.isEmpty, let target = classified.citationTarget,
          classified.blocks.indices.contains(target) else { return }
    switch classified.blocks[target] {
    case .text(var attr):
      appendCitations(to: &attr, indices: indices, sourcesCount: sourcesCount)
      classified.blocks[target] = .text(attr)
    case .bulletList(var items):
      guard var lastItem = items.popLast() else { return }
      appendCitations(to: &lastItem, indices: indices, sourcesCount: sourcesCount)
      items.append(lastItem)
      classified.blocks[target] = .bulletList(items)
    case .table, .separator, .codeBlock, .image:
      break
    }
  }

  static func buildBlocks(
    content: String,
    sources: [GroundingSource],
    groundingSupports: [GroundingSupport]
  ) -> [ReplyContentBlock] {
    let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    // Fenced code blocks must come out before ANY paragraph split — a fence can contain blank
    // lines. `offsets` carries the resulting length shift so grounded citations still line up.
    let (processed, codeBlocks, offsets) = CodeBlockExtractor.extract(from: content)

    // Paragraph *production* is the one place the two paths genuinely differ, and it is the
    // citation offsets that force it: the grounded path must not run
    // `normalizeMarkdownParagraphBreaks`, which inserts blank lines and would move every support
    // range. Classification below is shared.
    let paragraphs: [ParagraphWithCitations]
    if groundingSupports.isEmpty || sources.isEmpty {
      paragraphs = MarkdownParsing.normalizeMarkdownParagraphBreaks(processed)
        .components(separatedBy: "\n\n")
        .map { ParagraphWithCitations(text: $0, chunkIndices: []) }
    } else {
      paragraphs = ParagraphCitationBuilder.buildParagraphs(
        content: processed, supports: groundingSupports, sourcesCount: sources.count,
        offsets: offsets)
    }

    var blocks: [ReplyContentBlock] = []
    for para in paragraphs {
      let trimmed = para.text.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.isEmpty { continue }
      if Self.shouldSkipGeneratedImagePlaceholder(trimmed, in: content) { continue }
      var classified = classify(trimmed, codeBlocks: codeBlocks, options: options)
      applyCitations(to: &classified, indices: para.chunkIndices, sourcesCount: sources.count)
      blocks.append(contentsOf: classified.blocks)
    }
    // Strip markers in the fallback too: a message whose only marker failed to decode would
    // otherwise dump the raw multi-MB base64 into the UI as text.
    return blocks.isEmpty
      ? [.text(AttributedString(GeminiAPIClient.stripImageMarkers(content)))]
      : blocks
  }

  /// Splits a paragraph that has non-bullet text followed by bullet lines.
  /// Returns (textPart, bulletPart) if found; nil otherwise.
  private static func splitHeadingAndBullets(_ trimmed: String) -> (String, String)? {
    let lines = trimmed.components(separatedBy: "\n")
    guard lines.count >= 2 else { return nil }
    // Find the first bullet line
    guard let bulletStart = lines.firstIndex(where: { MarkdownParsing.parseBullet($0.trimmingCharacters(in: .whitespaces)) != nil }) else { return nil }
    guard bulletStart > 0 else { return nil }
    let headingPart = lines[0..<bulletStart].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    let bulletPart = lines[bulletStart...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !headingPart.isEmpty, !bulletPart.isEmpty else { return nil }
    return (headingPart, bulletPart)
  }

  private static func looksLikeStructuredAnswer(_ code: String) -> Bool {
    let lines = code.components(separatedBy: "\n")
    let headingCount = lines.filter { $0.hasPrefix("#") }.count
    return headingCount >= 2
  }

  /// Hides the internal `[generated image]` placeholder in the UI when the message still
  /// carries a renderable ⟦GEMINI_IMG:…⟧ marker (model echo from API history, or its own paragraph).
  private static func shouldSkipGeneratedImagePlaceholder(_ trimmed: String, in content: String) -> Bool {
    GeminiAPIClient.isGeneratedImagePlaceholder(trimmed)
      && GeminiAPIClient.containsImageMarker(in: content)
  }

  /// One ordered piece of a paragraph that mixes ⟦GEMINI_IMG:…⟧ markers with prose.
  private enum ImageMarkerPiece {
    case image(NSImage)
    case text(String)
  }

  /// Decoded marker images keyed by marker hash. While the post-image narration streams,
  /// every token invalidates the segment cache and re-parses the paragraph — without this,
  /// each re-parse base64-decodes the multi-MB marker and re-inits an NSImage on the main
  /// thread, per token.
  private static let markerImageCache = NSCache<NSString, NSImage>()

  /// Order-preserving split of a paragraph containing ⟦GEMINI_IMG:…⟧ markers. Streaming can
  /// glue the model's narration directly onto a marker (`…⟧Ich habe…`), so markers must be
  /// recognized anywhere in a paragraph — not only when they make up the whole paragraph.
  /// Returns nil when the paragraph has no marker (caller falls through to normal handling).
  /// A marker whose base64 fails to decode is dropped (logged) rather than dumped as raw text.
  private static func splitImageMarkerPieces(_ trimmed: String) -> [ImageMarkerPiece]? {
    guard GeminiAPIClient.containsImageMarker(in: trimmed) else { return nil }
    var pieces: [ImageMarkerPiece] = []
    GeminiAPIClient.walkImageMarkers(
      trimmed,
      onText: { segment in
        let before = segment.trimmingCharacters(in: .whitespacesAndNewlines)
        if !before.isEmpty, !GeminiAPIClient.isGeneratedImagePlaceholder(before) {
          pieces.append(.text(before))
        }
      },
      onMarker: { markerSegment in
        let key = "\(markerSegment.count)_\(markerSegment.hashValue)" as NSString
        if let cached = markerImageCache.object(forKey: key) {
          pieces.append(.image(cached))
        } else if let data = GeminiAPIClient.decodeImageMarkerData(String(markerSegment)),
                  let image = NSImage(data: data) {
          markerImageCache.setObject(image, forKey: key)
          pieces.append(.image(image))
        } else {
          DebugLogger.logWarning("BLOCKS: image marker failed base64 decode (\(markerSegment.count) chars)")
        }
      },
      onUnterminatedMarker: { trailing in
        // Unterminated marker (e.g. truncated stream) — drop it instead of dumping base64.
        DebugLogger.logWarning("BLOCKS: dropped unterminated image marker (\(trailing.count) chars)")
      }
    )
    return pieces
  }

  /// Parses a paragraph block that consists entirely of bullet/numbered-list lines.
  /// Returns individual attributed strings for each bullet item, or nil if not a bullet block.
  private static func parseBulletItems(_ trimmed: String) -> [AttributedString]? {
    // Group indented continuation lines under the previous bullet so multi-line list items
    // (a common pattern in numbered lists like `1. **Heading:**\n   continuation`) are
    // rendered as a single bullet instead of being rejected by an all-or-nothing check.
    let rawLines = trimmed.components(separatedBy: .newlines)
    var groups: [String] = []
    for line in rawLines {
      let trimmedLine = line.trimmingCharacters(in: .whitespaces)
      if trimmedLine.isEmpty { continue }
      if MarkdownParsing.parseBullet(trimmedLine) != nil {
        groups.append(trimmedLine)
      } else if let first = line.first, first.isWhitespace {
        if groups.isEmpty { return nil }
        groups[groups.count - 1] += " " + trimmedLine
      } else {
        return nil
      }
    }
    guard !groups.isEmpty else { return nil }
    let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    return groups.compactMap { group in
      guard let parsed = MarkdownParsing.parseBullet(group) else { return nil }
      let rawContent = parsed.trimmingCharacters(in: .whitespaces)
      let content = MarkdownParsing.renderLatexToUnicode(rawContent)
      var contentAttr = MarkdownParsing.inlineAttributedString(content, options: opts)
      contentAttr.font = .system(size: ChatTheme.bodyFontSize, weight: .regular)
      return contentAttr
    }
  }

  private static func buildSingleParagraphAttributed(
    _ trimmed: String,
    options: AttributedString.MarkdownParsingOptions
  ) -> AttributedString {
    if MarkdownParsing.isSeparatorParagraph(trimmed) {
      var lineAttr = AttributedString(MarkdownParsing.separatorLineContent)
      lineAttr.foregroundColor = ChatTheme.primaryText.opacity(0.4)
      return lineAttr
    }
    if let (level, title) = MarkdownParsing.parseATXHeading(trimmed) {
      let parts = trimmed.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
      let bodyPart = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
      var headingAttr = MarkdownParsing.inlineAttributedString(title, options: options)
      headingAttr.font = MarkdownParsing.fontForHeadingLevel(level, baseSize: ChatTheme.bodyFontSize)
      let headingMetrics = MarkdownParsing.nsHeadingMetrics(level, baseSize: ChatTheme.bodyFontSize)
      headingAttr[ProseFontHint.self] = ProseFontMetrics(size: headingMetrics.size, weight: headingMetrics.weight.rawValue)
      if !bodyPart.isEmpty {
        headingAttr.append(AttributedString("\n\n"))
        var bodyAttr = MarkdownParsing.inlineAttributedString(bodyPart, options: options)
        bodyAttr.font = .system(size: ChatTheme.bodyFontSize, weight: .regular)
        headingAttr.append(bodyAttr)
      }
      return headingAttr
    }
    // Bullet lists are now handled at the block level, not here
    // Convert LaTeX formulas to Unicode before markdown parsing
    let latexProcessed = MarkdownParsing.renderLatexToUnicode(trimmed)
    let fullOptions = AttributedString.MarkdownParsingOptions(interpretedSyntax: .full)
    let inlineOptions = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    var attr = (try? AttributedString(markdown: latexProcessed, options: fullOptions))
      ?? (try? AttributedString(markdown: latexProcessed, options: inlineOptions))
      ?? AttributedString(latexProcessed)
    attr.font = ChatTheme.bodyFont(size: ChatTheme.bodyFontSize)
    return attr
  }
}
