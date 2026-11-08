import Testing
import Foundation
import HotKey
@testable import WhisperShortcut_AppStore

@Suite("Status menu titles")
struct StatusMenuTitleTests {
  @Test("Key equivalents: single characters only")
  func keyEquivalents() {
    #expect(StatusMenuTitle.keyEquivalentCharacter(for: .one) == "1")
    #expect(StatusMenuTitle.keyEquivalentCharacter(for: .space) == " ")
    #expect(StatusMenuTitle.keyEquivalentCharacter(for: .f5) == "")
  }

  @Test("A native key equivalent or a disabled shortcut leaves the title alone")
  func plainTitle() {
    #expect(StatusMenuTitle.render(base: "Dictate", isEnabled: true, keyEquivalent: "1", display: "⌃⌥1") == "Dictate")
    #expect(StatusMenuTitle.render(base: "Dictate", isEnabled: false, keyEquivalent: "", display: "F5") == "Dictate")
  }

  @Test("Complex keys are padded into a column; retitled rows keep it")
  func padded() {
    let title = StatusMenuTitle.render(base: "Dictate", isEnabled: true, keyEquivalent: "", display: "F5")
    #expect(title == "Dictate".padding(toLength: 26, withPad: " ", startingAt: 0) + "F5")
    let long = String(repeating: "x", count: 30)
    #expect(StatusMenuTitle.render(base: long, isEnabled: true, keyEquivalent: "", display: "F5") == long + "  F5")
    // Retitled rows keep the shortcut column.
    let stop = StatusMenuTitle.render(base: "Stop Dictate", isEnabled: true, keyEquivalent: "", display: "F5")
    #expect(title.count == stop.count)
    #expect(stop.hasSuffix("F5"))
  }
}
