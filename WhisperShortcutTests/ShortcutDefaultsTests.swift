import AppKit
import Foundation
import HotKey
import Testing

@testable import WhisperShortcut_AppStore

/// New installs must not get bare ⌘-digit shortcuts (they switch tabs in browsers, Slack, VS
/// Code), and the pinned legacy set for existing installs must be exactly what they had.
@Suite("Shortcut defaults")
struct ShortcutDefaultsTests {

  private func all(_ c: ShortcutConfig) -> [ShortcutDefinition] {
    [c.startRecording, c.startPrompting, c.openSettings, c.openChat, c.screenshotCapture,
     c.readAloud, c.voiceFeedback, c.meetingMarker, c.addToGlossary]
  }

  @Test("New-install defaults avoid bare ⌘-digits and do not collide")
  func newDefaults() {
    let defs = all(ShortcutConfig.default)
    #expect(!defs.contains { $0.modifiers == [.command] })
    #expect(Set(defs.map { "\($0.key)-\($0.modifiers.rawValue)" }).count == defs.count)
    #expect(ShortcutConfig.default.startRecording.modifiers == [.control, .option])
  }

  @Test("Legacy defaults are the ⌘-digit set existing installs were running on")
  func legacyDefaults() {
    let legacy = ShortcutConfig.legacyCommandDigit
    #expect(legacy.startRecording == ShortcutDefinition(key: .one, modifiers: [.command]))
    #expect(legacy.openSettings.key == .zero && legacy.openSettings.modifiers == [.command])
    #expect(legacy.openChat == ShortcutConfig.default.openChat)
  }
}
