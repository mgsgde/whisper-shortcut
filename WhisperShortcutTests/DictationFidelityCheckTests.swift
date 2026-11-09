import Testing
import Foundation
@testable import WhisperShortcut_AppStore

/// The ⌘2 output may reorder and normalize the dictation but must not add content. These cases pin
/// what passes (reordering, number and segment normalization, inflection) and what is flagged.
@Suite("Dictation fidelity check")
struct DictationFidelityCheckTests {

  private static let transcript =
    "Patient klagt seit fünf Tagen über Schmerzen im Nacken links, morgens schlimmer, kein Schwindel. Befund C5 C6 links eingeschränkt. Levator scapulae links hyperton. Rotation nach links sechzig Grad."

  private func check(_ output: String, _ sources: [String]) -> [String] {
    DictationFidelityCheck.unsupportedWords(in: output, sources: sources)
  }

  @Test("A faithful reorder with headings and a marker passes")
  func faithfulReorder() {
    let output =
      "Anamnese:\nPatient klagt seit 5 Tagen über Schmerzen im Nacken links, morgens schlimmer, kein Schwindel.\n\nBefund:\nC5/C6 links eingeschränkt. Levator scapulae links hyperton. Rotation nach links 60 Grad.\n\nTherapie:\n(nicht diktiert)"
    #expect(check(output, [Self.transcript]).isEmpty)
  }

  @Test("An invented Therapie section is flagged")
  func inventedTherapy() {
    let output =
      "Therapie:\nMobilisation C5/C6 links, Muskel-Energie-Technik Levator scapulae links, Dehnübung mitgegeben. Nächster Termin in einer Woche."
    let flagged = check(output, [Self.transcript])
    for word in ["Mobilisation", "Muskel", "Energie", "Technik", "Dehnübung", "mitgegeben", "Nächster", "Termin", "Woche"] {
      #expect(flagged.contains(word), "expected \(word) to be flagged")
    }
    for word in ["links", "Levator", "C5"] {
      #expect(!flagged.contains(word), "\(word) must not be flagged")
    }
  }

  private struct PassCase: Sendable {
    let output: String, sources: [String], label: String
  }

  @Test("Inflection, segment normalization, markers, case, a second source and split compounds all pass", arguments: [
    PassCase(output: "kraniosakraler Technik", sources: ["kraniosakrale Technik"], label: "inflection adjective"),
    PassCase(output: "Schmerz", sources: ["Schmerzen"], label: "inflection noun"),
    PassCase(output: "L4/L5 und Th12/L1", sources: ["L4 L5 und Th12 L1"], label: "segments"),
    PassCase(output: "Psoas links [?] hyperton [Zuordnung prüfen]", sources: ["Psoas links hyperton"], label: "markers"),
    PassCase(output: "Psoas", sources: ["psoas"], label: "case does not matter"),
    PassCase(output: "Lumbago links", sources: ["links", "Lumbago"], label: "selected text as second source"),
    PassCase(output: "Lendenwirbelsäule", sources: ["Lenden Wirbelsäule"], label: "dictated compound split in two words"),
  ])
  private func passes(_ c: PassCase) {
    #expect(check(c.output, c.sources).isEmpty, "\(c.label)")
  }

  private struct FlagCase: Sendable {
    let output: String, sources: [String], flagged: [String], label: String
  }

  @Test("Added abbreviations, invented diagnoses, wrong numbers and field values are flagged", arguments: [
    FlagCase(output: "M. psoas links hyperton", sources: ["Psoas links hyperton"], flagged: ["M"], label: "added abbreviation"),
    // The heading line "Diagnose:" is skipped, the invented value is not.
    FlagCase(output: "Diagnose:\nLumbago", sources: ["Patient klagt über Schmerzen im Rücken"], flagged: ["Lumbago"], label: "invented diagnosis"),
    FlagCase(output: "Rotation 45 Grad", sources: ["Rotation sechzig Grad"], flagged: ["45"], label: "wrong number"),
    // A field name with a value stays checked.
    FlagCase(output: "Befund: Psoas rechts", sources: ["Psoas links"], flagged: ["rechts"], label: "heading word with content"),
  ])
  private func flagged(_ c: FlagCase) {
    #expect(check(c.output, c.sources) == c.flagged, "\(c.label)")
  }

  @Test("Repeated invented words are reported once, in first-occurrence order")
  func dedupAndOrder() {
    let flagged = check("Zebra Apfel zebra Apfel Birne", ["links"])
    #expect(flagged == ["Zebra", "Apfel", "Birne"])
  }

  @Test("A template label is allowed; a drug named only in the template is flagged")
  func templateLabelIsAllowedButExampleDrugIsFlagged() {
    let template = """
      Procedere:
      Ibuprofen 600 bei Bedarf.
      # Nachsorge
      Dosis: Ibuprofen
      """
    let output = "Procedere: Ibuprofen. Nachsorge bleibt."
    let flagged = DictationFidelityCheck.unsupportedWords(
      in: output, sources: ["bleibt"], templateInstructions: template)
    #expect(!flagged.contains("Procedere"))
    #expect(!flagged.contains("Nachsorge"))
    #expect(flagged.contains("Ibuprofen"))
    // Without the template, the custom label is an ordinary word.
    let without = check(output, ["bleibt"])
    #expect(without.contains("Procedere"))
    #expect(without.contains("Ibuprofen"))
  }
}
