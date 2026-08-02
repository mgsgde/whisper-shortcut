import Testing
import Foundation
@testable import WhisperShortcut_AppStore

/// `gpt-audio-1.5` intermittently answers a Dictate Prompt instruction with a JSON edit object
/// instead of the edited text (measured at ~20–30% of "make this shorter" requests, 2026-08-02).
/// `unwrappingJSONEditResponse` is the backstop that keeps that JSON out of the user's clipboard.
///
/// The interesting half of these tests is the *negative* cases: an over-eager unwrapper that
/// mangles a legitimate reply is worse than the bug it fixes, because it corrupts edits that were
/// working fine. Every bail-out must return the input untouched.
@Suite("JSON edit-response unwrapping")
struct JSONEditResponseTests {

    private static func unwrap(_ text: String, selection: String? = nil) -> String {
        TextProcessingUtility.unwrappingJSONEditResponse(text, selectedText: selection)
    }

    // MARK: - Shapes observed from the model

    @Test("Unwraps a bare text field")
    func bareTextField() {
        #expect(Self.unwrap(#"{"text": "Komme morgen später."}"#) == "Komme morgen später.")
    }

    @Test("Unwraps a text field alongside metadata")
    func textFieldWithMetadata() {
        let reply = #"{"edit_type": "shorten", "text": "Ich schaffe es morgen leider nicht."}"#
        #expect(Self.unwrap(reply) == "Ich schaffe es morgen leider nicht.")
    }

    @Test("Unwraps a key name the exact-match list would have missed")
    func varyingKeyName() {
        // Observed live: the same model that returns {"text": …} also returns {"final_text": …}.
        // Matching on the shape of the key rather than a fixed list is what stops this from
        // needing a code change every time the model picks a new name.
        #expect(Self.unwrap(#"{"final_text": "Passt so."}"#) == "Passt so.")
        #expect(Self.unwrap(#"{"edited_message": "Passt so."}"#) == "Passt so.")
    }

    @Test("A metadata label never wins over the actual text")
    func metadataKeyLoses() {
        // Regression: `edit_type` matches the "edit" token and sorted ahead of `text`, so the
        // first version of the shape-matching returned the label "shorten" as the user's text.
        let reply = #"{"edit_type": "shorten", "final_text": "Ich schaffe es morgen nicht."}"#
        #expect(Self.unwrap(reply) == "Ich schaffe es morgen nicht.")
        // And with no content field at all, a lone metadata label is not treated as the answer.
        let labelOnly = #"{"edit_type": "shorten"}"#
        #expect(Self.unwrap(labelOnly) == labelOnly)
    }

    @Test("A one-field config object is not mistaken for a text wrapper")
    func singleFieldConfigSurvives() {
        // The generalised key matching must not degrade into "unwrap any single string field" —
        // this is a plausible thing to dictate an edit for, and its value is not a transcript.
        let text = #"{"host": "localhost"}"#
        #expect(Self.unwrap(text) == text)
    }

    @Test("Applies a single find/replacement edit to the selection")
    func singleEdit() {
        let selection = "Hallo Anna, ich komme morgen gegen neun Uhr vorbei."
        let reply = #"{"edits": [{"find": "gegen neun Uhr", "replacement": "etwas später"}]}"#
        #expect(Self.unwrap(reply, selection: selection)
                == "Hallo Anna, ich komme morgen etwas später vorbei.")
    }

    @Test("Applies several edits in order, and accepts the original/new key spelling")
    func multipleEdits() {
        let selection = "Der Termin ist am Montag um neun."
        let reply = #"{"edits": [{"original": "Montag", "new": "Dienstag"}, {"original": "neun", "new": "zehn"}]}"#
        #expect(Self.unwrap(reply, selection: selection) == "Der Termin ist am Dienstag um zehn.")
    }

    @Test("A single index-based edit falls back to its replacement as the full rewrite")
    func indexBasedEdit() {
        // Observed live: {"edits": [{"start": 0, "end": 178, "replacement": "…"}]}. The offsets
        // are unreliable (the model's `end` was 41 chars short of the selection), so they are
        // ignored and the replacement is taken as the finished text.
        let selection = "Ich wollte dir nur ganz kurz Bescheid geben, dass ich den Termin morgen leider nicht wahrnehmen kann."
        let reply = #"{"edits": [{"start": 0, "end": 60, "replacement": "Ich kann den Termin morgen leider nicht wahrnehmen."}]}"#
        #expect(Self.unwrap(reply, selection: selection)
                == "Ich kann den Termin morgen leider nicht wahrnehmen.")
    }

    @Test("A single bare-string edit is unwrapped")
    func bareStringEdit() {
        let selection = "Ich wollte dir nur kurz Bescheid geben, dass es morgen nicht klappt."
        let reply = #"{"edits": ["Morgen klappt es bei mir leider nicht, tut mir leid."]}"#
        #expect(Self.unwrap(reply, selection: selection)
                == "Morgen klappt es bei mir leider nicht, tut mir leid.")
    }

    @Test("A fragment replacement that cannot be located is NOT used as the whole text")
    func fragmentReplacementBails() {
        // The dangerous case for the fallback above: a short replacement is a fragment of the
        // text, not a rewrite of it. Returning it would delete everything around it, so the raw
        // reply is passed through instead.
        let selection = "Hallo Anna, ich wollte dir kurz Bescheid geben, dass ich morgen gegen neun Uhr vorbeikomme und dann bleibe."
        let reply = #"{"edits": [{"start": 40, "end": 55, "replacement": "später"}]}"#
        #expect(Self.unwrap(reply, selection: selection) == reply)
    }

    // MARK: - Must not fire

    @Test("Plain text is returned untouched")
    func plainTextUntouched() {
        let text = "Ich komme morgen etwas später, sag der Anna bitte Bescheid."
        #expect(Self.unwrap(text) == text)
    }

    @Test("Prose containing braces is not treated as JSON")
    func proseWithBraces() {
        let text = "Setze { und } um den Block, dann kompiliert es."
        #expect(Self.unwrap(text) == text)
    }

    @Test("A JSON snippet the user actually asked for survives when it is not an edit object")
    func userRequestedJSON() {
        // A config the user dictated an edit for. It parses as an object but carries no key the
        // unwrapper understands, so it must come back verbatim rather than half-decoded.
        let text = #"{"host": "localhost", "port": 8080}"#
        #expect(Self.unwrap(text) == text)
    }

    @Test("An edits array whose find string is absent from the selection aborts the rewrite")
    func unmatchedFindAborts() {
        let selection = "Hallo Anna, ich komme morgen vorbei."
        let reply = #"{"edits": [{"find": "gegen neun Uhr", "replacement": "später"}]}"#
        // The fragment does not occur — reconstructing would silently drop the edit, so the raw
        // reply is passed through and the user sees something is off.
        #expect(Self.unwrap(reply, selection: selection) == reply)
    }

    @Test("An edits array without the selection at hand aborts")
    func editsWithoutSelection() {
        let reply = #"{"edits": [{"find": "a", "replacement": "b"}]}"#
        #expect(Self.unwrap(reply, selection: nil) == reply)
    }

    @Test("Malformed JSON is returned untouched")
    func malformedJSON() {
        let text = #"{"text": "unterminated"#
        #expect(Self.unwrap(text) == text)
    }

    @Test("An empty text field is not treated as a successful unwrap")
    func emptyTextField() {
        // Returning "" here would look to the caller like "no speech detected" and silently
        // discard the user's edit.
        let reply = #"{"text": "   "}"#
        #expect(Self.unwrap(reply) == reply)
    }

    @Test("A JSON array is left alone")
    func jsonArray() {
        let text = #"[{"text": "one"}, {"text": "two"}]"#
        #expect(Self.unwrap(text) == text)
    }

    @Test("Surrounding whitespace does not prevent unwrapping")
    func whitespaceTolerant() {
        #expect(Self.unwrap("\n  {\"text\": \"Fertig.\"}  \n") == "Fertig.")
    }
}
