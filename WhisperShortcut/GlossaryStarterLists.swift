import Foundation

/// A curated set of German specialist terms a user can append to the Glossary in one click.
struct GlossaryStarterList: Identifiable {
  let id: String
  let name: String
  let terms: [String]
}

enum GlossaryStarterLists {
  static let all: [GlossaryStarterList] = [
    GlossaryStarterList(
      id: "orthopaedics",
      name: String(localized: "Orthopedics"),
      terms: [
        "Gonarthrose", "Coxarthrose", "Spondylarthrose", "Osteochondrose", "Lumboischialgie",
        "Zervikobrachialgie", "Spondylolisthesis", "Bandscheibenprotrusion", "Impingement-Syndrom",
        "Rotatorenmanschette", "Supraspinatussehne", "Epicondylitis humeri radialis",
        "Chondromalazie", "Iliosakralgelenk", "Lasègue",
      ]),
    GlossaryStarterList(
      id: "psychiatry",
      name: String(localized: "Psychiatry & Psychotherapy"),
      terms: [
        "Anhedonie", "Antriebsminderung", "Affektverflachung", "Agoraphobie", "Dysthymie",
        "Hypomanie", "Derealisation", "Depersonalisation", "Suizidalität", "formalgedanklich",
        "Psychoedukation", "Escitalopram", "Venlafaxin", "Mirtazapin", "Quetiapin",
      ]),
    GlossaryStarterList(
      id: "expertReports",
      name: String(localized: "Expert Reports"),
      terms: [
        "Minderung der Erwerbsfähigkeit", "MdE", "Grad der Behinderung", "GdB",
        "Erwerbsminderungsrente", "Leistungsvermögen", "haftungsbegründende Kausalität",
        "Aggravation", "Beschwerdevalidierung", "Anknüpfungstatsachen", "Beweisfrage",
        "Berufsgenossenschaft", "Gliedertaxe", "Invaliditätsgrad", "Versorgungsmedizin-Verordnung",
      ]),
  ]

  /// Pure planning step, same separator and budget arithmetic as
  /// `SystemPromptsStore.appendToWhisperGlossary`. A term that does not fit is skipped; a shorter
  /// one later in the list may still fit.
  static func plan(
    adding terms: [String], to glossary: String,
    budget: Int = SystemPromptsStore.glossaryCharBudget
  ) -> (updated: String, added: [String], alreadyThere: [String], didNotFit: [String]) {
    var current = glossary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : glossary
    var added: [String] = []
    var alreadyThere: [String] = []
    var didNotFit: [String] = []
    for term in terms {
      if SystemPromptsStore.glossaryContains(term, in: current) {
        alreadyThere.append(term)
        continue
      }
      guard current.count + term.count + 2 <= budget else {
        didNotFit.append(term)
        continue
      }
      current = current.isEmpty ? term : current + ", " + term
      added.append(term)
    }
    return (current, added, alreadyThere, didNotFit)
  }
}

extension SystemPromptsStore {
  /// Appends a starter list in one write (one history entry), skipping terms already present.
  @discardableResult
  func appendStarterList(_ list: GlossaryStarterList) -> (added: Int, alreadyThere: Int, didNotFit: Int) {
    let result = GlossaryStarterLists.plan(adding: list.terms, to: loadWhisperGlossary())
    if !result.added.isEmpty {
      updateSection(.whisperGlossary, content: result.updated, source: .glossaryStarterList)
      DebugLogger.log(
        "GLOSSARY: Added starter list \(list.id), \(result.added.count) terms (\(result.updated.count) chars total)")
    }
    return (result.added.count, result.alreadyThere.count, result.didNotFit.count)
  }
}
