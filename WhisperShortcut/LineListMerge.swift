import Foundation

/// Merge rule for the line-per-entry files the user edits by hand while the model may append to
/// them (Chat memory, folder map). The user's edit wins for every line they saw; lines added on
/// disk since the editor loaded are kept, so Save never deletes what the model just learned.
enum LineListMerge {
  static func textToSave(edited: String, loaded: String, onDisk: String) -> String {
    guard onDisk != loaded else { return edited }
    let seen = Set(lines(loaded))
    let editedLines = Set(lines(edited))
    let addedMeanwhile = lines(onDisk).filter { !seen.contains($0) && !editedLines.contains($0) }
    guard !addedMeanwhile.isEmpty else { return edited }
    let base = edited.trimmingCharacters(in: .newlines)
    return ((base.isEmpty ? [] : [base]) + addedMeanwhile).joined(separator: "\n")
  }

  private static func lines(_ text: String) -> [String] {
    text.components(separatedBy: "\n")
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
  }
}
