import Foundation
import Testing

@testable import WhisperShortcut_AppStore

@Suite("Glossary starter lists")
struct GlossaryStarterListTests {

  private var orthopaedics: GlossaryStarterList {
    GlossaryStarterLists.all.first { $0.id == "orthopaedics" }!
  }

  @Test("Empty glossary: every term is added, joined by comma")
  func emptyGlossary() {
    let terms = orthopaedics.terms
    let r = GlossaryStarterLists.plan(adding: terms, to: "")
    #expect(terms.count == 15)
    #expect(r.added == terms)
    #expect(r.alreadyThere.isEmpty && r.didNotFit.isEmpty)
    #expect(r.updated == terms.joined(separator: ", "))
  }

  @Test("Terms already present, in any case, are skipped")
  func existingTermsSkipped() {
    let r = GlossaryStarterLists.plan(adding: orthopaedics.terms, to: "gonarthrose, Lasègue")
    #expect(Set(r.alreadyThere) == ["Gonarthrose", "Lasègue"])
    #expect(r.added.count == 13)
    #expect(r.updated.hasPrefix("gonarthrose, Lasègue, Coxarthrose"))
  }

  @Test("A term that does not fit is skipped, a later shorter one still fits")
  func budgetSkipsLongTerm() {
    let r = GlossaryStarterLists.plan(
      adding: ["Versorgungsmedizin-Verordnung", "GdB"], to: "MdE", budget: 15)
    #expect(r.didNotFit == ["Versorgungsmedizin-Verordnung"])
    #expect(r.added == ["GdB"])
    #expect(r.updated == "MdE, GdB")
  }

  @Test("Every term is already normalised and short enough")
  func termsAreValid() {
    for list in GlossaryStarterLists.all {
      for t in list.terms {
        #expect(SystemPromptsStore.normaliseTerm(t) == t)
        #expect(t.split(separator: " ").count <= GlossaryDocument.maxTermWords)
      }
    }
  }

  @Test("All lists together fit an empty glossary")
  func allFit() {
    let all = GlossaryStarterLists.all.flatMap(\.terms)
    let r = GlossaryStarterLists.plan(adding: all, to: "")
    #expect(r.didNotFit.isEmpty)
    #expect(r.updated.count <= SystemPromptsStore.glossaryCharBudget)
  }
}
