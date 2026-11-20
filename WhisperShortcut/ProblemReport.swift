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

  /// Opens the report window. `message` prefills "What went wrong?". `details`, when set, is placed
  /// above the general candidate's own lines (the chat tail from `/feedback`). `startOnGeneral`
  /// selects that candidate instead of the newest result. `activate` is false when the window
  /// must not take the keyboard from the app the user is typing in. `onHandedOff` runs once, with
  /// the report text, the first time the user sends, shares or copies; Cancel does not call it.
  @MainActor static func open(
    message: String? = nil,
    details: String? = nil,
    startOnGeneral: Bool = false,
    activate: Bool = true,
    onHandedOff: ((_ body: String) -> Void)? = nil
  ) {
    let candidates = preparedCandidates(details: details)
    DictationReportWindowController.shared.show(
      candidates: candidates,
      message: message,
      startOnGeneral: startOnGeneral,
      activate: activate,
      onHandedOff: onHandedOff)
  }

  /// The candidates `open` shows. `details` is written above the general candidate's lines.
  static func preparedCandidates(details: String? = nil) -> [ResultReport.Candidate] {
    let provided = candidatesProvider?() ?? []
    let base = provided.isEmpty
      ? ResultReport.candidates(
        dictations: [], glossaryTerms: [], offlineMode: OfflineMode.isEnabled,
        prompt: nil, readAloud: nil)
      : provided
    return ResultReport.applyingExtraDetails(details, to: base)
  }
}
