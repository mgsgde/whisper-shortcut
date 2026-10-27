import Foundation
import Testing

@testable import WhisperShortcut_AppStore

@Suite("Review diff collapsing")
struct SmartImprovementDiffCollapseTests {

  private func render(_ original: [String], _ suggested: [String]) -> [String] {
    let lines = collapseUnchangedDiffLines(
      computeSmartImprovementDiff(
        original: original.joined(separator: "\n"), suggested: suggested.joined(separator: "\n")))
    return lines.map { line in
      switch line.kind {
      case .unchanged: return " \(line.text)"
      case .removed: return "-\(line.text)"
      case .added: return "+\(line.text)"
      case .skipped: return "~\(line.text)"
      }
    }
  }

  @Test("A line appended to a long prompt shows only its neighbours")
  func appendedLine() {
    let prompt = (1...30).map { "line \($0)" }
    #expect(render(prompt, prompt + ["new rule"]) == ["~⋯ 28 unchanged lines", " line 29", " line 30", "+new rule"])
  }

  @Test("A change in the middle keeps two lines of context on each side")
  func middleChange() {
    let prompt = (1...20).map { "line \($0)" }
    var edited = prompt
    edited[9] = "changed"
    #expect(
      render(prompt, edited) == [
        "~⋯ 7 unchanged lines", " line 8", " line 9", "-line 10", "+changed", " line 11", " line 12",
        "~⋯ 8 unchanged lines",
      ])
  }

  @Test("Short unchanged runs are left alone")
  func shortRunsStay() {
    #expect(render(["a", "b", "c"], ["a", "x", "c"]) == [" a", "-b", "+x", " c"])
  }
}
