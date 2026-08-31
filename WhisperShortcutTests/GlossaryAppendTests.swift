import Foundation
import Testing

@testable import WhisperShortcut_AppStore

/// "Add Selection to Glossary" writes straight into the file every dictation is conditioned with,
/// from a keystroke, with no review step. The rules that keep that safe — it is a term, it is not
/// already there, it still fits in what Whisper reads — are therefore asserted rather than trusted.
@Suite("Glossary append")
struct GlossaryAppendTests {

  @Test("A selection is trimmed to a term, not stored as the user happened to select it")
  func selectionIsNormalised() {
    #expect(SystemPromptsStore.normaliseTerm("  Iliosakralgelenk  ") == "Iliosakralgelenk")
    #expect(SystemPromptsStore.normaliseTerm("Iliosakralgelenk.") == "Iliosakralgelenk")
    #expect(SystemPromptsStore.normaliseTerm("\"Gödde\",") == "Gödde")
    // Line breaks inside a selection collapse; a term dragged across a wrap is still one term.
    #expect(SystemPromptsStore.normaliseTerm("Fascia\n thoracolumbalis") == "Fascia thoracolumbalis")
    // Capitalisation is part of the spelling being asserted and must survive untouched.
    #expect(SystemPromptsStore.normaliseTerm("HVLA") == "HVLA")
  }

  @Test("Membership ignores case and accepts both separators users actually write")
  func duplicateDetectionMatchesHowPeopleWrite() {
    let glossary = "Iliosakralgelenk, Fascia thoracolumbalis\nHVLA, Gödde"
    #expect(SystemPromptsStore.glossaryContains("Iliosakralgelenk", in: glossary))
    #expect(SystemPromptsStore.glossaryContains("iliosakralgelenk", in: glossary))
    // Newline-separated entries count too — the editor is free text, not a comma-only field.
    #expect(SystemPromptsStore.glossaryContains("HVLA", in: glossary))
    #expect(SystemPromptsStore.glossaryContains("Fascia thoracolumbalis", in: glossary))
    #expect(!SystemPromptsStore.glossaryContains("Sakrumtorsion", in: glossary))
    // A substring of an entry is not an entry: "Fascia" must still be addable.
    #expect(!SystemPromptsStore.glossaryContains("Fascia", in: glossary))
  }

  /// The failure this guards against is not a crash but a silently degraded transcript: a whole
  /// sentence in the conditioning text biases Whisper toward reproducing it.
  @Test("A sentence is refused; a term is accepted")
  func sentencesAreRefused() {
    let store = SystemPromptsStore.shared
    let sentence = "Die Patientin klagt über ziehende Schmerzen im unteren Rücken seit drei Wochen"
    #expect(store.appendToWhisperGlossary(sentence) == .notATerm(sentence))
    #expect(store.appendToWhisperGlossary("   ") == .notATerm(""))
  }
}
