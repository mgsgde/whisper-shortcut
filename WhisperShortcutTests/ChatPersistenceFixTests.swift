import AppKit
import Foundation
import Testing
@testable import WhisperShortcut_AppStore

/// A quit mid-stream used to persist the empty model placeholder `performSend` appends
/// before the first token. The next Gemini request then contained
/// `{"role":"model","parts":[{"text":""}]}` and was rejected, and the empty bubble hid
/// Regenerate. Loading drops that placeholder; `buildContents` never emits an empty text part.
@MainActor
@Suite("Empty assistant placeholders")
struct ChatEmptyAssistantTests {

  private static func makeStore() -> (ChatSessionStore, URL, String) {
    let scope = "empty-assistant-\(UUID().uuidString)"
    let store = ChatSessionStore(scope: scope)
    let url = AppSupportPaths.whisperShortcutApplicationSupportURL()
      .appendingPathComponent("gemini-sessions-\(scope).json")
    return (store, url, scope)
  }

  @Test("Reloading a session drops empty model placeholders and keeps real turns")
  func reloadDropsEmptyAssistantPlaceholders() {
    let (store, url, scope) = Self.makeStore()
    var opened: ChatSessionStore?
    defer {
      // Flush the reloaded store, not the writer: the writer's cache still holds the
      // placeholder that a quit would have left on disk.
      opened?.flushToDisk()
      try? FileManager.default.removeItem(at: url)
    }

    var session = store.load()
    let tool = ChatToolCallRecord(name: "gmail_search", argsJSON: "{}", resultJSON: "{\"n\":1}")
    let attachment = AttachedImagePart(data: Data([0x01, 0x02]), mimeType: "image/png", filename: "shot.png")
    session.messages = [
      ChatMessage(role: .user, content: "hello"),
      ChatMessage(role: .model, content: ""),
      ChatMessage(role: .model, content: "kept"),
      ChatMessage(role: .model, content: "note", isLocalNotice: true),
      ChatMessage(role: .model, content: " \n"),
      ChatMessage(role: .model, content: "", toolCalls: [tool]),
      ChatMessage(role: .model, content: "", attachedImageParts: [attachment]),
    ]
    store.save(session)
    store.flushToDisk()

    let reloaded = ChatSessionStore(scope: scope)
    opened = reloaded
    let messages = reloaded.session(by: session.id)?.messages ?? []
    #expect(messages.count == 5)
    #expect(messages.contains { $0.role == .user && $0.content == "hello" })
    #expect(messages.contains { $0.content == "kept" })
    #expect(messages.contains { $0.isLocalNotice && $0.content == "note" })
    #expect(messages.contains { $0.toolCalls.map(\.name) == ["gmail_search"] })
    #expect(messages.contains { $0.attachedImageParts.first?.filename == "shot.png" })
    #expect(messages.allSatisfy { !$0.isEmptyAssistantPlaceholder })
  }

  @Test("buildContents omits an empty model turn and still sends the surrounding user turns")
  func buildContentsOmitsEmptyModelTurn() {
    let (store, url, _) = Self.makeStore()
    defer {
      store.flushToDisk()
      try? FileManager.default.removeItem(at: url)
    }

    let user = ChatMessage(role: .user, content: "hello")
    let empty = ChatMessage(role: .model, content: "")
    let blank = ChatMessage(role: .model, content: " \n\t")
    let follow = ChatMessage(role: .user, content: "still there?")
    let sessionId = UUID()
    let contents = ChatRequestBuilder.buildContents(
      sessionId: sessionId,
      currentSessionId: sessionId,
      messages: [user, empty, blank, follow],
      store: store,
      model: .gemini38Flash)

    // Dropping the empty reply leaves two user turns in a row. Current Gemini, OpenAI and
    // Anthropic APIs accept consecutive same-role turns.
    let roles = contents.compactMap { $0["role"] as? String }
    #expect(roles == ["user", "user"])
    for turn in contents {
      let parts = turn["parts"] as? [[String: Any]] ?? []
      #expect(!parts.isEmpty)
      for part in parts {
        if let text = part["text"] as? String {
          #expect(!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      }
    }
  }

  @Test("An empty model turn that already ran tools is still sent")
  func buildContentsKeepsToolOnlyModelTurn() {
    let (store, url, _) = Self.makeStore()
    defer {
      store.flushToDisk()
      try? FileManager.default.removeItem(at: url)
    }

    let tool = ChatToolCallRecord(name: "gmail_search", argsJSON: "{}", resultJSON: "{\"n\":1}")
    let withTools = ChatMessage(role: .model, content: "", toolCalls: [tool])
    let sessionId = UUID()
    let contents = ChatRequestBuilder.buildContents(
      sessionId: sessionId,
      currentSessionId: sessionId,
      messages: [ChatMessage(role: .user, content: "find it"), withTools],
      store: store,
      model: .gemini38Flash)

    #expect(contents.count == 2)
    let modelTurn = contents[1]
    #expect(modelTurn["role"] as? String == "model")
    let parts = modelTurn["parts"] as? [[String: Any]] ?? []
    let text = parts.first?["text"] as? String ?? ""
    #expect(text.contains("gmail_search"))
    #expect(!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
  }
}

/// Pasting a file from Finder used to send every image through `insertScreenshot`, which
/// stored `image/png` / `screenshot.png`, and used to attach any other type. The allow-list
/// is the attach panel's.
@MainActor
@Suite("Pasted file types")
struct ChatComposerPasteTests {

  private func writeTemp(name: String, bytes: Data) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("composer-paste-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent(name)
    try bytes.write(to: url)
    return url
  }

  @Test("A pasted JPEG keeps its MIME type and filename")
  func pastedJpegKeepsTypeAndName() throws {
    let url = try writeTemp(name: "photo.jpg", bytes: Data("jpeg-bytes".utf8))
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    let decision = ComposerFilePaste.decision(for: url, maxBytes: AppConstants.maxFileSizeBytes)
    guard case .attach(let data, let mime, let filename) = decision else {
      Issue.record("expected attach, got \(decision)")
      return
    }
    #expect(mime == "image/jpeg")
    #expect(filename == "photo.jpg")
    #expect(filename != "screenshot.png")
    #expect(data == Data("jpeg-bytes".utf8))

    let controller = GeminiComposerController()
    controller.textView = ChatComposerNSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 80))
    #expect(controller.insertFile(data: data, mimeType: mime, filename: filename))
    let part = controller.serialize().attachedParts.first
    #expect(part?.mimeType == "image/jpeg")
    #expect(part?.filename == "photo.jpg")
  }

  @Test("Pasted PNG, PDF and plain text keep their MIME type and filename", arguments: [
    ("diagram.png", "png", "image/png", "diagram.png"),
    ("notes.pdf", "%PDF", "application/pdf", "notes.pdf"),
    ("notes.txt", "hello", "text/plain", "notes.txt"),
  ])
  func pastedDocumentTypes(name: String, bytes: String, mime: String, filename: String) throws {
    let url = try writeTemp(name: name, bytes: Data(bytes.utf8))
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    guard case .attach(_, let gotMime, let gotName) =
      ComposerFilePaste.decision(for: url, maxBytes: AppConstants.maxFileSizeBytes) else {
      Issue.record("expected attach for \(name)")
      return
    }
    #expect(gotMime == mime, "\(name)")
    #expect(gotName == filename, "\(name)")
  }

  private func bitmap(alpha: Bool) -> NSBitmapImageRep {
    let info: CGImageAlphaInfo = alpha ? .premultipliedLast : .noneSkipLast
    let ctx = CGContext(
      data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info.rawValue)!
    ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: alpha ? 0.5 : 1)
    ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
    return NSBitmapImageRep(cgImage: ctx.makeImage()!)
  }

  @Test("A pasted TIFF without alpha is converted to JPEG")
  func tiffWithoutAlphaBecomesJpeg() throws {
    let tiff = try #require(bitmap(alpha: false).tiffRepresentation)
    let url = try writeTemp(name: "scan.tiff", bytes: tiff)
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let decision = ComposerFilePaste.decision(for: url, maxBytes: AppConstants.maxFileSizeBytes)
    guard case .attach(let data, let mime, let filename) = decision else {
      Issue.record("expected attach, got \(decision)")
      return
    }
    #expect(mime == "image/jpeg")
    #expect(filename == "scan.jpg")
    #expect(data.starts(with: [0xFF, 0xD8]))
    #expect(NSImage(data: data) != nil)
  }

  @Test("A pasted TIFF with alpha is converted to PNG")
  func tiffWithAlphaBecomesPng() throws {
    let tiff = try #require(bitmap(alpha: true).tiffRepresentation)
    let url = try writeTemp(name: "logo.tif", bytes: tiff)
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let decision = ComposerFilePaste.decision(for: url, maxBytes: AppConstants.maxFileSizeBytes)
    guard case .attach(let data, let mime, let filename) = decision else {
      Issue.record("expected attach, got \(decision)")
      return
    }
    #expect(mime == "image/png")
    #expect(filename == "logo.png")
    #expect(data.starts(with: [0x89, 0x50, 0x4E, 0x47]))
  }

  @Test("A pasted HEIC is converted to JPEG")
  func heicBecomesJpeg() throws {
    let rep = bitmap(alpha: false)
    let cg = try #require(rep.cgImage)
    let out = NSMutableData()
    let dest = try #require(
      CGImageDestinationCreateWithData(out, "public.heic" as CFString, 1, nil))
    CGImageDestinationAddImage(dest, cg, nil)
    try #require(CGImageDestinationFinalize(dest))
    let url = try writeTemp(name: "IMG_0001.HEIC", bytes: out as Data)
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let decision = ComposerFilePaste.decision(for: url, maxBytes: AppConstants.maxFileSizeBytes)
    guard case .attach(let data, let mime, let filename) = decision else {
      Issue.record("expected attach, got \(decision)")
      return
    }
    #expect(mime == "image/jpeg")
    #expect(filename == "IMG_0001.jpg")
    #expect(data.starts(with: [0xFF, 0xD8]))
  }

  @Test("An undecodable HEIC is unreadable, not attached")
  func corruptHeicIsUnreadable() throws {
    let url = try writeTemp(name: "broken.heic", bytes: Data("not an image".utf8))
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let decision = ComposerFilePaste.decision(for: url, maxBytes: AppConstants.maxFileSizeBytes)
    guard case .reject(_, let reason) = decision else {
      Issue.record("expected reject, got \(decision)")
      return
    }
    #expect(reason == .unreadable)
  }

  @Test("Types the attach panel hides are rejected")
  func disallowedTypesAreRejected() throws {
    let zip = try writeTemp(name: "archive.zip", bytes: Data("zip".utf8))
    defer { try? FileManager.default.removeItem(at: zip.deletingLastPathComponent()) }
    let decision = ComposerFilePaste.decision(for: zip, maxBytes: AppConstants.maxFileSizeBytes)
    guard case .reject(let filename, let reason) = decision else {
      Issue.record("archive.zip was attached: \(decision)")
      return
    }
    #expect(filename == "archive.zip")
    #expect(reason == .unsupportedType)
    let message = ChatViewModel.attachmentUnsupportedMessage(filenames: ["archive.zip"])
    #expect(message.contains("archive.zip"))
  }

  @Test("An oversized paste is rejected with the same message as the attach panel")
  func oversizedPasteMatchesAttachFeedback() throws {
    let url = try writeTemp(name: "big.pdf", bytes: Data("0123456789".utf8))
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let decision = ComposerFilePaste.decision(for: url, maxBytes: 4)
    guard case .reject(let filename, let reason) = decision else {
      Issue.record("expected tooLarge, got \(decision)")
      return
    }
    #expect(filename == "big.pdf")
    #expect(reason == .tooLarge)
    let message = ChatViewModel.attachmentTooLargeMessage(filenames: [filename])
    #expect(message.contains("big.pdf"))
    #expect(message.contains("wasn't attached"))
  }

  @Test("A missing file is unreadable rather than attached")
  func missingFileIsUnreadable() {
    let url = URL(fileURLWithPath: "/tmp/whisper-missing-\(UUID().uuidString).pdf")
    let decision = ComposerFilePaste.decision(for: url, maxBytes: AppConstants.maxFileSizeBytes)
    guard case .reject(let filename, let reason) = decision else {
      Issue.record("expected unreadable, got \(decision)")
      return
    }
    #expect(filename == url.lastPathComponent)
    #expect(reason == .unreadable)
  }
}

/// The AI title used to replace whatever the row currently said, including a name the user
/// had typed while the title request was in flight.
@MainActor
@Suite("Generated chat titles")
struct ChatGeneratedTitleTests {

  @Test("A generated title replaces the first-message fallback and nothing else")
  func generatedTitleReplacesFallbackOnly() {
    let session = ChatSession(
      messages: [ChatMessage(role: .user, content: "how do I reset the router")])
    let fallback = ChatViewModel.meetingFirstMessageFallbackTitle(for: session)
    #expect(fallback == "how do I reset the router")
    #expect(ChatViewModel.mayApplyGeneratedTitle(current: fallback, firstMessageFallback: fallback))
    #expect(ChatViewModel.mayApplyGeneratedTitle(current: nil, firstMessageFallback: fallback))
    #expect(ChatViewModel.mayApplyGeneratedTitle(current: "", firstMessageFallback: fallback))
    #expect(ChatViewModel.mayApplyGeneratedTitle(current: "   ", firstMessageFallback: fallback))
    #expect(!ChatViewModel.mayApplyGeneratedTitle(current: "Router help", firstMessageFallback: fallback))
  }

  @Test("The fallback compared against a rename is the unwrapped first message, including the ellipsis")
  func fallbackMatchesWhatAppendMessageStamps() {
    let raw = "<typed_by_user>\nreset the router\n</typed_by_user>"
    let wrapped = ChatSession(messages: [ChatMessage(role: .user, content: raw)])
    let fallback = ChatViewModel.meetingFirstMessageFallbackTitle(for: wrapped)
    #expect(fallback == "reset the router")
    #expect(!ChatViewModel.mayApplyGeneratedTitle(current: "Home network", firstMessageFallback: fallback))

    let long = String(repeating: "a", count: 80)
    let truncated = ChatViewModel.meetingFirstMessageFallbackTitle(
      for: ChatSession(messages: [ChatMessage(role: .user, content: long)]))
    #expect(truncated?.hasSuffix("…") == true)
    #expect(truncated != long)
    #expect(ChatViewModel.mayApplyGeneratedTitle(current: truncated, firstMessageFallback: truncated))
    #expect(!ChatViewModel.mayApplyGeneratedTitle(current: "Short name", firstMessageFallback: truncated))
  }
}
