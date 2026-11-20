import Foundation

/// The one way to open "Report a Problem". Every menu row, error popup, chat command,
/// settings button and MCP problem report calls `open`.
enum ProblemReport {
  /// Set once by MenuBarController at startup: builds the candidates (it owns speechService).
  static var candidatesProvider: (() -> [ResultReport.Candidate])?

  /// Which row the window selects. The general candidate is always last, so the first row is the
  /// newest result unless the caller asks to start on general feedback.
  static func initialSelection(
    candidates: [ResultReport.Candidate], startOnGeneral: Bool
  ) -> String {
    if startOnGeneral, candidates.contains(where: { $0.id == "general" }) {
      return "general"
    }
    return candidates.first?.id ?? ""
  }

  /// Opens the report window. `message` prefills "What went wrong?". `startOnGeneral` selects the
  /// general candidate instead of the newest result.
  @MainActor static func open(message: String? = nil, startOnGeneral: Bool = false) {
    let provided = candidatesProvider?() ?? []
    let candidates = provided.isEmpty
      ? ResultReport.candidates(
        dictations: [], glossaryTerms: [], offlineMode: OfflineMode.isEnabled,
        prompt: nil, readAloud: nil)
      : provided
    DictationReportWindowController.shared.show(
      candidates: candidates, message: message, startOnGeneral: startOnGeneral)
  }
}
