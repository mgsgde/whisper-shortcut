import Foundation
import Testing
@testable import WhisperShortcut_AppStore

/// Gemini sometimes writes its reasoning into the visible answer between `start_thought` and
/// `end_thought`. `ChatViewModel` is `@MainActor`, and so is this static.
@MainActor
@Suite("Leaked thought strip")
struct LeakedThoughtStripTests {

  @Test("Text without markers is unchanged, apart from the leading whitespace trim")
  func noMarkersUnchanged() {
    #expect(ChatViewModel.stripLeakedThoughtTokens("Hello there") == "Hello there")
    #expect(ChatViewModel.stripLeakedThoughtTokens("Hello\nthere") == "Hello\nthere")
    #expect(ChatViewModel.stripLeakedThoughtTokens("  \nHello") == "Hello")
  }

  @Test("A full block at the start is removed and the answer is kept")
  func fullBlockAtStartRemoved() {
    let leaked = """
    start_thought
    Context: Work Chat (Teams) with colleague Mark.
    Wait, let's keep it close to dictation.
    end_thought
    Thanks Mark, I'll send the notes.
    """
    #expect(ChatViewModel.stripLeakedThoughtTokens(leaked) == "Thanks Mark, I'll send the notes.")
  }

  @Test("An end_thought with no opener drops the prefix")
  func orphanEndThoughtDropsPrefix() {
    let leaked = """
    Context: Work Chat with colleague Mark.
    Wait, let's keep it close to dictation.
    end_thought
    Thanks Mark, I'll send the notes.
    """
    #expect(ChatViewModel.stripLeakedThoughtTokens(leaked) == "Thanks Mark, I'll send the notes.")
  }

  @Test("A start_thought with no closer drops the tail")
  func unclosedStartThoughtDropsTail() {
    let leaked = "Thanks Mark, I'll send the notes.\nstart_thought\nStill checking the spelling."
    #expect(ChatViewModel.stripLeakedThoughtTokens(leaked) == "Thanks Mark, I'll send the notes.\n")
  }

  @Test("Two blocks are both removed")
  func twoBlocksRemoved() {
    let leaked = "start_thought first end_thought Hello start_thought second end_thought there"
    #expect(ChatViewModel.stripLeakedThoughtTokens(leaked) == "Hello  there")
  }

  @Test("An orphan end_thought before an unclosed start_thought is still removed")
  func orphanEndBeforeUnclosedStart() {
    #expect(ChatViewModel.stripLeakedThoughtTokens("A end_thought B start_thought C") == "B")
  }

  @Test("The thought flag decodes on a response part")
  func thoughtFlagDecodes() throws {
    let response = try Self.decodeResponse(
      #"{"candidates":[{"content":{"parts":[{"text":"thinking...","thought":true},{"text":"Hallo Mark"}]}}]}"#)
    let parts = response.candidates[0].content.parts
    #expect(parts[0].thought == true)
    #expect(parts[1].thought == nil)
  }

  @Test("Dictate Prompt text skips thought parts")
  func dictatePromptSkipsThoughtParts() throws {
    let response = try Self.decodeResponse(
      #"{"candidates":[{"content":{"parts":[{"text":"thinking...","thought":true},{"text":"Hallo Mark"}]}}]}"#)
    #expect(SpeechService.dictatePromptText(from: response) == "Hallo Mark")
  }

  @Test("Dictate Prompt text strips a leaked thought block in a single part")
  func dictatePromptStripsLeakedBlock() throws {
    let response = try Self.decodeResponse(
      #"{"candidates":[{"content":{"parts":[{"text":"start_thought Check spelling... end_thought\nHallo Mark"}]}}]}"#)
    #expect(SpeechService.dictatePromptText(from: response) == "Hallo Mark")
  }

  private static let exampleAPlanning = """
    Notice from the audio:
    "Hi Christina, wir haben ...?"

    User voice style:
    Hi Kristina,
    Work chat register, informal.
    Keep it concise and clear.
    """

  private static let exampleAAnswer =
    "Hi Christina, wir haben für die IT mal drei Telekom SIM-Karten bestellt. Kannst du mal schauen, was das im Monat kostet?"

  private static let exampleBPlanning = """
    The user dictates an email to "Herr Irion".
    Content:
    - Two open mediCAD invoices

    Formatting:
    - E-Mail style

    Details:
    "Hallo Herr Irion, ..."

    Check prompt constraints:
    - No markdown bold/headers.
    - Return ONLY plain text.
    """

  private static let exampleBAnswer = """
    Hallo Herr Irion,

    bei mir liegen noch zwei offene Rechnungen.

    Mit freundlichen Grüßen
    """

  @Test("Example A as two parts drops the planning part")
  func exampleATwoParts() {
    #expect(LeakedPlanningStrip.strip(parts: [Self.exampleAPlanning, Self.exampleAAnswer]) == Self.exampleAAnswer)
  }

  @Test("Example B as two parts drops the planning part")
  func exampleBTwoParts() {
    #expect(LeakedPlanningStrip.strip(parts: [Self.exampleBPlanning, Self.exampleBAnswer]) == Self.exampleBAnswer)
  }

  @Test("Example B glued into one part keeps the email")
  func exampleBOnePart() {
    #expect(LeakedPlanningStrip.strip(parts: [Self.exampleBPlanning + Self.exampleBAnswer]) == Self.exampleBAnswer)
  }

  @Test("Example A glued into one part keeps the message")
  func exampleAOnePart() {
    #expect(LeakedPlanningStrip.strip(parts: [Self.exampleAPlanning + Self.exampleAAnswer]) == Self.exampleAAnswer)
  }

  @Test("A normal German answer is unchanged")
  func germanAnswerUnchanged() {
    let answer = "Hallo Mark,\n\nkurz: Danke."
    #expect(LeakedPlanningStrip.strip(parts: [answer]) == answer)
    #expect(LeakedPlanningStrip.looksLikePlanning("Hallo Herr Irion,") == false)
    #expect(LeakedPlanningStrip.looksLikePlanning("Betreff: Rechnung") == false)
  }

  @Test("A two-part answer that is not planning is joined")
  func normalTwoPartsJoined() {
    #expect(LeakedPlanningStrip.strip(parts: ["Hallo ", "Mark"]) == "Hallo Mark")
  }

  @Test("A Formatting label with no glue point is unchanged")
  func formattingWithoutGlueUnchanged() {
    let text = "Formatting: keep this whole note."
    #expect(LeakedPlanningStrip.strip(parts: [text]) == text)
  }

  @Test("A planning part is dropped even when the answer is not glued to it")
  func separatePlanningPartWithoutGlue() {
    let planning = "Notice from the audio:\n\"Hi?\""
    let answer = "Hi Christina, danke."
    #expect(LeakedPlanningStrip.strip(parts: [planning, answer]) == answer)
  }

  @Test("When every part is planning, the joined text is kept")
  func allPlanningPartsUnchanged() {
    let parts = ["Plan: draft the note.", "Formatting: plain text."]
    #expect(LeakedPlanningStrip.strip(parts: parts) == parts.joined())
  }

  @Test("A glue point accepts Unicode uppercase letters")
  func gluePointAcceptsUnicodeUppercase() {
    #expect(LeakedPlanningStrip.strip(parts: ["Task: note.Ähne"]) == "Ähne")
    #expect(LeakedPlanningStrip.strip(parts: ["Task: note.Öl"]) == "Öl")
    #expect(LeakedPlanningStrip.strip(parts: ["Task: note.Übung"]) == "Übung")
  }

  @Test("Dictate Prompt drops a separate planning part before pasting")
  func dictatePromptDropsSeparatePlanningPart() throws {
    let response = try Self.decodeResponse(
      #"{"candidates":[{"content":{"parts":[{"text":"Notice from the audio:\n\"Hi?\""},{"text":"Hi Christina, danke."}]}}]}"#)
    #expect(SpeechService.dictatePromptText(from: response) == "Hi Christina, danke.")
  }

  private static func decodeResponse(_ json: String) throws -> GeminiChatResponse {
    try JSONDecoder().decode(GeminiChatResponse.self, from: Data(json.utf8))
  }
}
