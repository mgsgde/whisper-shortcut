import SwiftUI
import AppKit

// MARK: - Inline composer for Gemini Chat
//
// This file implements a Claude-style inline composer built on AppKit's
// NSTextView + NSTextAttachment. Screenshots, pasted blocks and file
// attachments live **inside** the text buffer as atomic attachment glyphs,
// so Backspace/Delete next to the caret removes them natively — matching the
// "delete the token before the cursor" behavior we want.

// MARK: - Attachment model

enum ComposerAttachmentKind {
  case screenshot(Data)
  case pastedBlock(id: UUID, content: String, kind: GeminiChatViewModel.PastedBlock.Kind)
  case file(data: Data, mimeType: String, filename: String)
}

/// Custom NSTextAttachment that carries a typed payload and draws a chip/thumbnail cell.
final class ComposerTextAttachment: NSTextAttachment {
  let kind: ComposerAttachmentKind

  init(kind: ComposerAttachmentKind) {
    self.kind = kind
    super.init(data: nil, ofType: nil)
    self.attachmentCell = ComposerAttachmentCell(kind: kind)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
}

/// Draws the attachment as a rounded chip. Screenshots get a small thumbnail preview.
final class ComposerAttachmentCell: NSTextAttachmentCell {
  let kind: ComposerAttachmentKind
  private let thumbnail: NSImage?
  private let label: String

  init(kind: ComposerAttachmentKind) {
    self.kind = kind
    switch kind {
    case .screenshot(let data):
      self.thumbnail = NSImage(data: data)
      self.label = "Screenshot"
    case .pastedBlock(_, let content, let bkind):
      self.thumbnail = nil
      let lines = content.components(separatedBy: .newlines).filter { !$0.isEmpty }.count
      switch bkind {
      case .largePaste: self.label = "Pasted · \(lines) lines"
      case .shortcutSelection: self.label = "Selection · \(lines) lines"
      }
    case .file(_, let mime, let filename):
      self.thumbnail = nil
      let prefix = mime == "application/pdf" ? "PDF" : (mime.hasPrefix("image/") ? "Image" : "File")
      self.label = "\(prefix) · \(filename)"
    }
    super.init(textCell: "")
  }
  required init(coder: NSCoder) { fatalError("init(coder:) not supported") }

  private static let labelFont = NSFont.systemFont(ofSize: 11, weight: .medium)
  private static let horizontalPadding: CGFloat = 8
  private static let chipHeight: CGFloat = 22
  private static let thumbnailWidth: CGFloat = 22
  private static let maxChipWidth: CGFloat = 240

  override func cellSize() -> NSSize {
    let labelSize = (label as NSString).size(withAttributes: [.font: Self.labelFont])
    var width = labelSize.width + Self.horizontalPadding * 2
    if thumbnail != nil { width += Self.thumbnailWidth + 4 }
    width = min(Self.maxChipWidth, width)
    return NSSize(width: width, height: Self.chipHeight)
  }

  override func cellBaselineOffset() -> NSPoint { NSPoint(x: 0, y: -4) }

  override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
    let rect = cellFrame.insetBy(dx: 0.5, dy: 1)
    let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
    NSColor(calibratedWhite: 1.0, alpha: 0.08).setFill()
    path.fill()
    NSColor.separatorColor.withAlphaComponent(0.6).setStroke()
    path.lineWidth = 1
    path.stroke()

    var textX = rect.minX + Self.horizontalPadding
    if let img = thumbnail {
      let thumbRect = NSRect(
        x: rect.minX + 4,
        y: rect.minY + 3,
        width: Self.thumbnailWidth,
        height: rect.height - 6
      )
      NSGraphicsContext.current?.saveGraphicsState()
      let clip = NSBezierPath(roundedRect: thumbRect, xRadius: 3, yRadius: 3)
      clip.addClip()
      img.draw(in: thumbRect, from: .zero, operation: .sourceOver, fraction: 1.0)
      NSGraphicsContext.current?.restoreGraphicsState()
      textX = thumbRect.maxX + 4
    }

    let attrs: [NSAttributedString.Key: Any] = [
      .font: Self.labelFont,
      .foregroundColor: NSColor.labelColor,
    ]
    // Draw single-line at a point — draw(in:) word-wraps when the rect is
    // narrow, which clips the trailing portion of the label.
    let textSize = (label as NSString).size(withAttributes: attrs)
    let drawPoint = NSPoint(x: textX, y: rect.midY - textSize.height / 2)
    (label as NSString).draw(at: drawPoint, withAttributes: attrs)
  }
}

// MARK: - NSTextView subclass (placeholder, paste intercept, key handling)

final class GeminiComposerNSTextView: NSTextView {
  var onSubmit: (() -> Void)?
  var onCancel: (() -> Void)?
  var onTabComplete: (() -> Bool)?
  var onLargePaste: ((String) -> Bool)?
  var onAttachmentClicked: ((ComposerTextAttachment) -> Void)?
  var placeholder: String = "Message Gemini…"

  override var acceptsFirstResponder: Bool { true }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    guard (textStorage?.length ?? 0) == 0 else { return }
    let origin = textContainerOrigin
    let rect = NSRect(
      x: origin.x + 4,
      y: origin.y + 2,
      width: bounds.width - origin.x - 16,
      height: 24
    )
    let attrs: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 16),
      .foregroundColor: NSColor.secondaryLabelColor.withAlphaComponent(0.5),
    ]
    (placeholder as NSString).draw(in: rect, withAttributes: attrs)
  }

  override func keyDown(with event: NSEvent) {
    if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "." {
      onCancel?()
      return
    }
    super.keyDown(with: event)
  }

  override func insertNewline(_ sender: Any?) {
    if let e = NSApp.currentEvent, e.modifierFlags.contains(.shift) {
      super.insertNewline(sender)
      return
    }
    onSubmit?()
  }

  override func insertTab(_ sender: Any?) {
    if onTabComplete?() == true { return }
    super.insertTab(sender)
  }

  override func paste(_ sender: Any?) {
    if let str = NSPasteboard.general.string(forType: .string) {
      let lineCount = str.components(separatedBy: .newlines).filter { !$0.isEmpty }.count
      if lineCount >= GeminiChatViewModel.pasteThresholdLines
          || str.count >= GeminiChatViewModel.pasteThresholdChars {
        if onLargePaste?(str) == true { return }
      }
      // Always insert as plain text with standard typing attributes so
      // pasted text never inherits foreign fonts, colors, or link styling.
      let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 16),
        .foregroundColor: NSColor.labelColor,
      ]
      let plain = NSAttributedString(string: str, attributes: attrs)
      insertText(plain, replacementRange: selectedRange())
      return
    }
    super.paste(sender)
  }

  override func mouseDown(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    guard let lm = layoutManager, let tc = textContainer else {
      super.mouseDown(with: event); return
    }
    let adjusted = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
    let index = lm.characterIndex(for: adjusted, in: tc, fractionOfDistanceBetweenInsertionPoints: nil)
    if index < (textStorage?.length ?? 0),
       let a = textStorage?.attribute(.attachment, at: index, effectiveRange: nil) as? ComposerTextAttachment {
      onAttachmentClicked?(a)
      return
    }
    super.mouseDown(with: event)
  }
}

// MARK: - Controller

@MainActor
final class GeminiComposerController: ObservableObject {
  static let maxScreenshots = 5

  weak var textView: GeminiComposerNSTextView?

  @Published var plainText: String = ""
  @Published var isEmpty: Bool = true
  @Published var measuredHeight: CGFloat = 40

  // MARK: Queries

  var screenshotCount: Int {
    guard let storage = textView?.textStorage else { return 0 }
    var count = 0
    storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length), options: []) { val, _, _ in
      if let a = val as? ComposerTextAttachment, case .screenshot = a.kind { count += 1 }
    }
    return count
  }

  // MARK: Insertions

  func insertScreenshot(_ data: Data) {
    guard screenshotCount < Self.maxScreenshots else { return }
    removeAllFileAttachments()
    insertAttachment(ComposerTextAttachment(kind: .screenshot(data)))
  }

  func insertPastedBlock(text: String, kind: GeminiChatViewModel.PastedBlock.Kind) {
    insertAttachment(ComposerTextAttachment(kind: .pastedBlock(id: UUID(), content: text, kind: kind)))
  }

  func insertFile(data: Data, mimeType: String, filename: String) {
    removeAllScreenshots()
    removeAllFileAttachments()
    insertAttachment(ComposerTextAttachment(kind: .file(data: data, mimeType: mimeType, filename: filename)))
  }

  private func insertAttachment(_ attach: ComposerTextAttachment) {
    guard let tv = textView, let storage = tv.textStorage else { return }
    let baseAttrs: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 16),
      .foregroundColor: NSColor.labelColor,
    ]
    let attrStr = NSMutableAttributedString(attachment: attach)
    attrStr.addAttributes(baseAttrs, range: NSRange(location: 0, length: attrStr.length))
    // Trailing space for visual breathing room and so subsequent typing
    // does not inherit the .attachment attribute from the glyph before it.
    let space = NSAttributedString(string: " ", attributes: baseAttrs)
    let insertion = tv.selectedRange().location
    let clamped = min(max(0, insertion), storage.length)
    storage.insert(attrStr, at: clamped)
    storage.insert(space, at: clamped + attrStr.length)
    let cursorAfter = clamped + attrStr.length + space.length
    tv.setSelectedRange(NSRange(location: cursorAfter, length: 0))
    // Reset typing attributes so newly typed text is plain (no inherited .attachment).
    var typing = baseAttrs
    typing.removeValue(forKey: .attachment as NSAttributedString.Key)
    tv.typingAttributes = typing
    tv.didChangeText()
    tv.needsDisplay = true
    refreshState()
  }

  private func removeAllScreenshots() {
    removeAttachments { if case .screenshot = $0 { return true }; return false }
  }
  private func removeAllFileAttachments() {
    removeAttachments { if case .file = $0 { return true }; return false }
  }
  private func removeAttachments(where predicate: (ComposerAttachmentKind) -> Bool) {
    guard let tv = textView, let storage = tv.textStorage else { return }
    var rangesToRemove: [NSRange] = []
    storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length), options: []) { val, range, _ in
      if let a = val as? ComposerTextAttachment, predicate(a.kind) {
        rangesToRemove.append(range)
      }
    }
    for r in rangesToRemove.reversed() { storage.deleteCharacters(in: r) }
    tv.didChangeText()
    tv.needsDisplay = true
    refreshState()
  }

  /// Removes the trailing word (including any preceding whitespace) from the
  /// document, preserving attachments. Used to strip a slash-command token
  /// when dispatching a command without wiping the rest of the composer.
  func removeTrailingWord() {
    guard let tv = textView, let storage = tv.textStorage else { return }
    let nsStr = storage.string as NSString
    let len = nsStr.length
    var end = len
    while end > 0 {
      let ch = nsStr.character(at: end - 1)
      if let s = Unicode.Scalar(ch), CharacterSet.whitespacesAndNewlines.contains(s) {
        end -= 1
      } else { break }
    }
    var start = end
    while start > 0 {
      let ch = nsStr.character(at: start - 1)
      if ch == 0xFFFC { break }
      if let s = Unicode.Scalar(ch), CharacterSet.whitespacesAndNewlines.contains(s) { break }
      start -= 1
    }
    if start < len {
      storage.deleteCharacters(in: NSRange(location: start, length: len - start))
      tv.setSelectedRange(NSRange(location: start, length: 0))
      tv.didChangeText()
      tv.needsDisplay = true
      refreshState()
    }
  }

  /// Removes the exact `suffix` substring from the end of the document, if
  /// present (after trimming trailing whitespace). Used to strip a full slash
  /// command line such as `/model 3.1 flash lite` without touching attachments
  /// or earlier text. No-op if the suffix is not actually at the end.
  func removeTrailingPlainText(suffix: String) {
    guard let tv = textView, let storage = tv.textStorage else { return }
    guard !suffix.isEmpty else { return }
    let nsStr = storage.string as NSString
    let len = nsStr.length

    // Trim trailing whitespace from the document end.
    var end = len
    while end > 0 {
      let ch = nsStr.character(at: end - 1)
      if let s = Unicode.Scalar(ch), CharacterSet.whitespacesAndNewlines.contains(s) {
        end -= 1
      } else { break }
    }

    let suffixNS = suffix as NSString
    let suffixLen = suffixNS.length
    guard suffixLen <= end else { return }
    let start = end - suffixLen
    let candidate = nsStr.substring(with: NSRange(location: start, length: suffixLen))
    guard candidate == suffix else { return }

    // Optional boundary check: char before start must be start-of-string,
    // whitespace, or attachment marker — avoids matching inside a word.
    if start > 0 {
      let prev = nsStr.character(at: start - 1)
      let isWhitespace = Unicode.Scalar(prev).map { CharacterSet.whitespacesAndNewlines.contains($0) } ?? false
      if !isWhitespace && prev != 0xFFFC { return }
    }

    let removeRange = NSRange(location: start, length: len - start)
    storage.deleteCharacters(in: removeRange)
    tv.setSelectedRange(NSRange(location: start, length: 0))
    tv.didChangeText()
    tv.needsDisplay = true
    refreshState()
  }

  func clearAll() {
    guard let tv = textView else { return }
    tv.textStorage?.setAttributedString(NSAttributedString())
    tv.didChangeText()
    tv.needsDisplay = true
    refreshState()
  }

  func focus() {
    guard let tv = textView else { return }
    tv.window?.makeFirstResponder(tv)
  }

  func refreshState() {
    guard let tv = textView, let storage = tv.textStorage else {
      self.plainText = ""; self.isEmpty = true; return
    }
    // Plain text: concatenate non-attachment runs. A range counts as an
    // attachment only when it is the single attachment-marker character;
    // otherwise treat it as plain text (defends against attribute leaks).
    var pt = ""
    let nsStr = storage.string as NSString
    storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length), options: []) { val, range, _ in
      let isRealAttachment = val is ComposerTextAttachment
        && range.length == 1
        && nsStr.character(at: range.location) == 0xFFFC
      if !isRealAttachment {
        pt += nsStr.substring(with: range)
      }
    }
    self.plainText = pt
    self.isEmpty = storage.length == 0

    if let lm = tv.layoutManager, let tc = tv.textContainer {
      lm.ensureLayout(for: tc)
      let used = lm.usedRect(for: tc)
      let h = max(24, used.height) + tv.textContainerInset.height * 2 + 4
      self.measuredHeight = h
    }
  }

  // MARK: Serialization

  struct ComposedOutput {
    let typedText: String
    let finalContent: String
    let attachedParts: [AttachedImagePart]
  }

  /// Walks the document in order and produces the XML-wrapped `finalContent`
  /// plus ordered `attachedParts`. Document order (not a fixed stack order)
  /// determines how pasted sections interleave with `<typed_by_user>` blocks.
  func serialize() -> ComposedOutput {
    guard let storage = textView?.textStorage else {
      return ComposedOutput(typedText: "", finalContent: "", attachedParts: [])
    }

    enum Segment {
      case text(String)
      case pasted(String, GeminiChatViewModel.PastedBlock.Kind)
      case screenshot(Data)
      case file(Data, String, String)
    }
    var segments: [Segment] = []
    var cursor = 0
    let full = NSRange(location: 0, length: storage.length)
    let nsStr = storage.string as NSString
    storage.enumerateAttribute(.attachment, in: full, options: []) { val, range, _ in
      let isRealAttachment = val is ComposerTextAttachment
        && range.length == 1
        && nsStr.character(at: range.location) == 0xFFFC
      if !isRealAttachment {
        // Treat as plain text run.
        if range.length > 0 {
          let s = nsStr.substring(with: range)
          if !s.isEmpty { segments.append(.text(s)) }
        }
        cursor = range.location + range.length
        return
      }
      if range.location > cursor {
        let textRange = NSRange(location: cursor, length: range.location - cursor)
        let s = nsStr.substring(with: textRange)
        if !s.isEmpty { segments.append(.text(s)) }
      }
      if let a = val as? ComposerTextAttachment {
        switch a.kind {
        case .screenshot(let d): segments.append(.screenshot(d))
        case .pastedBlock(_, let content, let kind): segments.append(.pasted(content, kind))
        case .file(let d, let m, let n): segments.append(.file(d, m, n))
        }
      }
      cursor = range.location + range.length
    }
    if cursor < storage.length {
      let s = (storage.string as NSString).substring(with: NSRange(location: cursor, length: storage.length - cursor))
      if !s.isEmpty { segments.append(.text(s)) }
    }

    var typedText = ""
    for seg in segments { if case .text(let s) = seg { typedText += s } }
    let typedTrimmed = typedText.trimmingCharacters(in: .whitespacesAndNewlines)

    let totalScreenshots = segments.reduce(0) { acc, s in
      if case .screenshot = s { return acc + 1 }
      return acc
    }
    var screenshotCounter = 0
    var parts: [String] = []
    var attached: [AttachedImagePart] = []

    for seg in segments {
      switch seg {
      case .text(let s):
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty {
          parts.append("<typed_by_user>\n\(t)\n</typed_by_user>")
        }
      case .pasted(let content, let kind):
        switch kind {
        case .largePaste:
          parts.append("<pasted_content>\n\(content)\n</pasted_content>")
        case .shortcutSelection:
          parts.append("<pasted_selection>\n\(content)\n</pasted_selection>")
        }
      case .screenshot(let d):
        screenshotCounter += 1
        let filename = totalScreenshots == 1 ? "screenshot.png" : "screenshot \(screenshotCounter).png"
        attached.append(AttachedImagePart(data: d, mimeType: "image/png", filename: filename))
      case .file(let d, let m, let n):
        attached.append(AttachedImagePart(data: d, mimeType: m, filename: n))
      }
    }

    let finalContent = parts.joined(separator: "\n\n")
    return ComposedOutput(typedText: typedTrimmed, finalContent: finalContent, attachedParts: attached)
  }
}

// MARK: - NSViewRepresentable

struct GeminiComposerTextView: NSViewRepresentable {
  @ObservedObject var controller: GeminiComposerController
  var onSubmit: () -> Void
  var onCancel: () -> Void
  /// Return true if tab was consumed for slash-command completion.
  var onTabComplete: () -> Bool
  var onClickScreenshot: (Data) -> Void

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  func makeNSView(context: Context) -> NSScrollView {
    let scroll = NSScrollView()
    scroll.drawsBackground = false
    scroll.borderType = .noBorder
    scroll.hasVerticalScroller = true
    scroll.hasHorizontalScroller = false
    scroll.autohidesScrollers = true

    let container = NSTextContainer(containerSize: NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude))
    container.widthTracksTextView = true
    let layout = NSLayoutManager()
    let storage = NSTextStorage()
    storage.addLayoutManager(layout)
    layout.addTextContainer(container)

    let tv = GeminiComposerNSTextView(frame: .zero, textContainer: container)
    tv.isEditable = true
    tv.isRichText = true
    tv.allowsUndo = true
    tv.drawsBackground = false
    tv.backgroundColor = .clear
    tv.font = NSFont.systemFont(ofSize: 16)
    tv.textColor = NSColor.labelColor
    tv.insertionPointColor = NSColor.labelColor
    tv.typingAttributes = [
      .font: NSFont.systemFont(ofSize: 16),
      .foregroundColor: NSColor.labelColor,
    ]
    tv.textContainerInset = NSSize(width: 8, height: 10)
    tv.isAutomaticQuoteSubstitutionEnabled = false
    tv.isAutomaticDashSubstitutionEnabled = false
    tv.isAutomaticTextReplacementEnabled = false
    tv.isAutomaticSpellingCorrectionEnabled = false
    tv.isAutomaticLinkDetectionEnabled = false
    tv.importsGraphics = false
    tv.allowsImageEditing = false
    tv.minSize = NSSize(width: 0, height: 0)
    tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    tv.isVerticallyResizable = true
    tv.isHorizontallyResizable = false
    tv.autoresizingMask = [.width]
    tv.delegate = context.coordinator

    tv.onSubmit = { [weak controller] in
      _ = controller
      DispatchQueue.main.async { self.onSubmit() }
    }
    tv.onCancel = { DispatchQueue.main.async { self.onCancel() } }
    tv.onTabComplete = { self.onTabComplete() }
    tv.onLargePaste = { [weak controller] str in
      guard let c = controller else { return false }
      c.insertPastedBlock(text: str, kind: .largePaste)
      return true
    }
    tv.onAttachmentClicked = { attachment in
      if case .screenshot(let data) = attachment.kind {
        self.onClickScreenshot(data)
      }
    }

    scroll.documentView = tv
    controller.textView = tv
    context.coordinator.parent = self

    DispatchQueue.main.async {
      controller.refreshState()
      tv.window?.makeFirstResponder(tv)
    }
    return scroll
  }

  func updateNSView(_ nsView: NSScrollView, context: Context) {
    context.coordinator.parent = self
  }

  final class Coordinator: NSObject, NSTextViewDelegate {
    var parent: GeminiComposerTextView
    init(_ parent: GeminiComposerTextView) { self.parent = parent }

    func textDidChange(_ notification: Notification) {
      let ctrl = parent.controller
      Task { @MainActor in ctrl.refreshState() }
    }
  }
}
