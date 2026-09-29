import Testing
import Foundation
@testable import WhisperShortcut_AppStore

/// Edit-and-resend swaps only the typed part of a user message; pasted blocks survive, and
/// messages whose typed text can't be mapped onto one field don't offer Edit at all.
@MainActor
@Suite("Chat edit and resend")
struct ChatEditResendTests {

  @Test func plainLegacyContentIsEditableWhole() {
    #expect(ChatViewModel.editableTypedText(of: "hello") == "hello")
    #expect(ChatViewModel.replacingTypedText(in: "hello", with: "bye") == "bye")
  }

  @Test func singleTypedBlockKeepsPastedContent() {
    let content = "<pasted_content>\nLOG\n</pasted_content>\n\n<typed_by_user>\nwhat broke?\n</typed_by_user>"
    #expect(ChatViewModel.editableTypedText(of: content) == "what broke?")
    let edited = ChatViewModel.replacingTypedText(in: content, with: "why?")
    #expect(edited == "<pasted_content>\nLOG\n</pasted_content>\n\n<typed_by_user>\nwhy?\n</typed_by_user>")
  }

  @Test func multipleTypedBlocksAreNotEditable() {
    let content = "<typed_by_user>\na\n</typed_by_user>\n\n<pasted_content>\nX\n</pasted_content>\n\n<typed_by_user>\nb\n</typed_by_user>"
    #expect(ChatViewModel.editableTypedText(of: content) == nil)
    #expect(ChatViewModel.replacingTypedText(in: content, with: "c") == nil)
  }

  @Test func pasteOnlyMessageIsNotEditable() {
    #expect(ChatViewModel.editableTypedText(of: "<pasted_selection>\nX\n</pasted_selection>") == nil)
  }

  @Test func localNoticeRoundTripsAndDefaultsToFalse() throws {
    let notice = ChatMessage(role: .model, content: "Model set to X.", isLocalNotice: true)
    let decoded = try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(notice))
    #expect(decoded.isLocalNotice)
    let plain = ChatMessage(role: .model, content: "hi")
    let plainJSON = try JSONEncoder().encode(plain)
    #expect(!String(decoding: plainJSON, as: UTF8.self).contains("isLocalNotice"))
    #expect(try JSONDecoder().decode(ChatMessage.self, from: plainJSON).isLocalNotice == false)
  }
}
