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

  @Test("Inflected forms match")
  func inflection() {
    #expect(check("kraniosakraler Technik", ["kraniosakrale Technik"]).isEmpty)
    #expect(check("Schmerz", ["Schmerzen"]).isEmpty)
  }

  @Test("Segment normalization passes")
  func segments() {
    #expect(check("L4/L5 und Th12/L1", ["L4 L5 und Th12 L1"]).isEmpty)
  }

  @Test("Markers are not flagged")
  func markers() {
    #expect(check("Psoas links [?] hyperton [Zuordnung prüfen]", ["Psoas links hyperton"]).isEmpty)
  }

  @Test("Case does not matter")
  func caseInsensitive() {
    #expect(check("Psoas", ["psoas"]).isEmpty)
  }

  @Test("An added abbreviation is flagged")
  func addedAbbreviation() {
    #expect(check("M. psoas links hyperton", ["Psoas links hyperton"]) == ["M"])
  }

  @Test("An invented diagnosis is flagged although its heading line is skipped")
  func inventedDiagnosis() {
    let flagged = check("Diagnose:\nLumbago", ["Patient klagt über Schmerzen im Rücken"])
    #expect(flagged == ["Lumbago"])
  }

  @Test("Words from the selected text count as supported")
  func selectionAsSecondSource() {
    #expect(check("Lumbago links", ["links", "Lumbago"]).isEmpty)
  }

  @Test("A dictated compound split in two words matches the joined word")
  func compound() {
    #expect(check("Lendenwirbelsäule", ["Lenden Wirbelsäule"]).isEmpty)
  }

  @Test("Repeated invented words are reported once, in first-occurrence order")
  func dedupAndOrder() {
    let flagged = check("Zebra Apfel zebra Apfel Birne", ["links"])
    #expect(flagged == ["Zebra", "Apfel", "Birne"])
  }

  @Test("A wrong number is flagged")
  func wrongNumber() {
    #expect(check("Rotation 45 Grad", ["Rotation sechzig Grad"]) == ["45"])
  }

  @Test("A field name with a value stays checked")
  func headingWordWithContent() {
    #expect(check("Befund: Psoas rechts", ["Psoas links"]) == ["rechts"])
  }
}
